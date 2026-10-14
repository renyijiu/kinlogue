import CoreGraphics
import Foundation
import Testing
@testable import KinlogueApp
@testable import KinlogueCore
@testable import KinloguePlatform

@Suite("Report recognition snapshot boundaries", .serialized)
struct LiveAppServiceRecognitionIntegrationTests {
    @Test
    func recognitionProcessesOriginalsLargerThanTheCombinedSnapshotBudget() async throws {
        let fixture = try await RecognitionFixture.make(sourceByteCount: 65 * 1024 * 1024)
        defer { fixture.destroy() }
        let extractor = RecognitionExtractor()
        let service = fixture.service(extractor: extractor)

        let result = try await service.recognizeReview(fixture.command)

        #expect(await extractor.digests == fixture.digests)
        #expect(result.document.blocks.map(\.sourceID) == fixture.draft.sources.elements.map(\.id))
        let persisted = try await fixture.store.draft(fixture.draft.id)
        #expect(persisted.revision == fixture.draft.revision + 1)
        #expect(try await fixture.store.loadDocument(draftID: persisted.id) == result.document)
    }

    @Test
    func recognitionRejectsADraftChangedBetweenOriginals() async throws {
        let fixture = try await RecognitionFixture.make(sourceByteCount: 4096)
        defer { fixture.destroy() }
        let saved = ImportDraftDocument(
            blocks: [],
            candidates: ReportCandidates(),
            reviewState: ImportDraftReviewState(
                timelineDateSelection: .unknown,
                title: "Newer saved title",
                organization: "",
                department: "",
                reportType: "",
                reportedResults: "",
                conclusion: "",
                abnormalItems: [],
                userNote: ""
            )
        )
        let extractor = RecognitionExtractor {
            try await fixture.store.saveReview(
                draftID: fixture.draft.id,
                expectedRevision: fixture.draft.revision,
                memberID: fixture.member.id,
                document: saved
            )
        }

        await #expect(throws: AppServiceError.invalidReview) {
            try await fixture.service(extractor: extractor).recognizeReview(fixture.command)
        }

        #expect(await extractor.digests.count == 1)
        #expect(try await fixture.store.loadDocument(draftID: fixture.draft.id) == saved)
    }
}

private struct RecognitionFixture: Sendable {
    let base: URL
    let library: SQLiteLibraryStore
    let store: SQLiteReportRepository
    let studies: SQLiteDICOMRepository
    let member: FamilyMember
    let draft: ImportDraft
    let digests: [Data]

    /// A draft waiting for review whose two sources are separate PDF originals.
    static func make(sourceByteCount: Int) async throws -> Self {
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("kinlogue-recognition-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let library = try SQLiteLibraryStore(rootURL: base.appendingPathComponent("Library"))
        let store = SQLiteReportRepository(store: library)
        let member = try FamilyMember(displayName: "Synthetic member")
        try await store.saveMember(member, replacing: nil)
        var staged: [ImportDraft] = []
        var digests: [Data] = []
        for marker in [UInt8(32), 10] {
            let output = NSMutableData()
            let consumer = try #require(CGDataConsumer(data: output))
            var box = CGRect(x: 0, y: 0, width: 100, height: 100)
            let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
            context.beginPDFPage(nil)
            context.endPDFPage()
            context.closePDF()
            var bytes = output as Data
            bytes.append(Data(repeating: marker, count: max(0, sourceByteCount - bytes.count)))
            let file = try ImportedFileValidator().validate(data: bytes)
            guard case .created(let id) = try await store.stage(file) else { throw LibraryReportError.invalidDocument }
            staged.append(try await store.draft(id))
            digests.append(file.sha256Digest)
        }
        // Staging makes one draft per original. The draft under test owns both originals, as an
        // archived phone selection does, and the two single drafts are then discarded.
        let sources = try ReportSources(staged.map {
            try ReportSource(attachmentID: $0.sources.first.attachmentID, pageCount: $0.sources.first.pageCount)
        })
        let draft = ImportDraft(sources: sources, state: .needsReview, documentObjectID: UUID())
        try library.write { db in
            let digest = try SQLiteReportRows.saveDocument(
                ImportDraftDocument(blocks: [], candidates: ReportCandidates()),
                id: draft.documentObjectID!, revision: draft.revision, sources: sources, db)
            try SQLiteReportRows.saveDraft(draft, documentHash: digest, db, replaceSources: true)
            try SQLiteLibraryState.advance(in: db)
        }
        for single in staged { try await store.discard(draftID: single.id, expectedRevision: single.revision) }
        return Self(base: base, library: library, store: store, studies: try SQLiteDICOMRepository(store: library),
                    member: member, draft: draft, digests: digests)
    }

    var command: RecognizeReviewCommand {
        RecognizeReviewCommand(
            draftID: draft.id,
            expectedRevision: draft.revision,
            memberID: member.id,
            timelineDateSelection: .unknown,
            userNote: ""
        )
    }

    func service(extractor: RecognitionExtractor) -> LiveAppService {
        LiveAppService(
            reports: store,
            studies: studies,
            draftStore: store,
            workflow: ImportWorkflow(store: store, textExtractor: extractor),
            textExtractor: extractor,
            startupCompleted: true
        )
    }

    func destroy() {
        try? library.close()
        try? FileManager.default.removeItem(at: base)
    }
}

private actor RecognitionExtractor: TextExtractionService {
    private(set) var digests: [Data] = []
    private let afterFirst: (@Sendable () async throws -> Void)?

    init(afterFirst: (@Sendable () async throws -> Void)? = nil) {
        self.afterFirst = afterFirst
    }

    func extractText(from file: ValidatedImportedFile) async throws -> [OCRBlock] {
        digests.append(file.sha256Digest)
        if digests.count == 1 { try await afterFirst?() }
        return [try OCRBlock(
            pageNumber: 1,
            text: "标题: Synthetic report",
            boundingBox: NormalizedRect(x: 0.1, y: 0.1, width: 0.5, height: 0.1),
            confidence: 1,
            method: .vision,
            engineVersion: "synthetic"
        )]
    }
}
