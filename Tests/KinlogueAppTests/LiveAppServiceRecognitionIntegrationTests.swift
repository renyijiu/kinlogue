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

        #expect(await extractor.digests == fixture.attachments.map(\.sha256Digest))
        #expect(result.document.blocks.map(\.sourceID) == fixture.draft.sources.elements.map(\.id))
        let persisted = try #require(try await fixture.vault.loadCatalog().importDrafts.first)
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
    let root: URL
    let vault: PlaintextVault
    let store: VaultImportDraftStore
    let member: FamilyMember
    let draft: ImportDraft
    let attachments: [KinlogueCore.Attachment]

    static func make(sourceByteCount: Int) async throws -> Self {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("kinlogue-recognition-\(UUID().uuidString)")
        let vault = try PlaintextVault(rootURL: root)
        let initial = try await vault.initialize()
        let member = try FamilyMember(displayName: "Synthetic member")
        var attachments: [KinlogueCore.Attachment] = []
        var sources: [ReportSource] = []
        var writes: [VaultObjectWrite] = []
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
            let attachment = try Attachment(
                contentTypeIdentifier: file.contentTypeIdentifier,
                byteCount: file.data.count,
                sha256Digest: file.sha256Digest
            )
            attachments.append(attachment)
            sources.append(try ReportSource(attachmentID: attachment.id, pageCount: file.pageCount))
            writes.append(VaultObjectWrite(
                reference: VaultObjectReference(id: attachment.id, kind: .attachment),
                plaintext: file.data
            ))
        }
        let documentID = UUID()
        let draft = ImportDraft(
            sources: try ReportSources(sources),
            state: .needsReview,
            documentObjectID: documentID
        )
        writes.append(VaultObjectWrite(
            reference: VaultObjectReference(id: documentID, kind: .ocr),
            plaintext: try CanonicalVaultJSON.encode(
                ImportDraftDocument(blocks: [], candidates: ReportCandidates())
            )
        ))
        _ = try await vault.commit(try VaultCommitRequest(
            expectedGeneration: initial.generation,
            catalog: VaultCatalog(
                vaultID: initial.vaultID,
                generation: initial.generation + 1,
                members: [member],
                attachments: attachments,
                importDrafts: [draft]
            ),
            writes: writes
        ))
        return Self(
            root: root,
            vault: vault,
            store: VaultImportDraftStore(vault: vault),
            member: member,
            draft: draft,
            attachments: attachments
        )
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
            vault: vault,
            draftStore: store,
            workflow: ImportWorkflow(store: store, textExtractor: extractor),
            textExtractor: extractor,
            startupCompleted: true
        )
    }

    func destroy() { try? FileManager.default.removeItem(at: root) }
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
