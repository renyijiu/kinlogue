import CoreGraphics
import Foundation
import Synchronization
import Testing
@testable import KinlogueApp
@testable import KinlogueCore
@testable import KinloguePlatform

@Suite("SQLite local and LAN OCR attribution", .serialized)
struct SQLiteOCRAttributionIntegrationTests {
    @Test
    func localAndLANPreserveExtractionAndAuthoritativeProvenance() async throws {
        let local = try SQLiteAppQueryFixture()
        defer { local.destroy() }
        let lan = try SQLiteAppQueryFixture()
        defer { lan.destroy() }
        let bytes = try pdf()
        let blocks = try rawBlocks()
        let localExtractor = SQLiteAttributionExtractor(blocks: blocks)
        let localService = try await service(local, extractor: localExtractor)
        let input = local.base.appendingPathComponent("synthetic.pdf")
        try bytes.write(to: input)
        guard case .needsReview(let id) = try await localService.importFile(at: input) else {
            Issue.record("Expected a local review draft"); return
        }
        let imported = try await local.reports.loadDocument(draftID: id)
        let draft = try await local.reports.draft(id)
        #expect(imported.blocks.map(\.id) == blocks.map(\.id))
        let member = try FamilyMember(displayName: "Synthetic member")
        try await local.reports.saveMember(member, replacing: nil)
        try await lan.reports.saveMember(member, replacing: nil)
        let date = Date(timeIntervalSince1970: 1_786_000_000)

        // Extractor attribution is not authoritative; even a transient projection is replaced.
        let foreign = try ReportSource(attachmentID: UUID(), pageCount: 2)
        let preceding = try ReportSource(attachmentID: UUID(), pageCount: 3)
        let projected = try blocks.map { block in
            try OCRBlock(id: block.id, sourceID: foreign.id, attachmentID: foreign.attachmentID,
                filePageNumber: block.filePageNumber, text: block.text, boundingBox: block.boundingBox,
                confidence: block.confidence, method: block.method, engineVersion: block.engineVersion)
                .projected(for: ReportSources([preceding, foreign]))
        }
        #expect(projected.map(\.pageNumber) == [4, 5, 5])
        let extractor = SQLiteAttributionExtractor(blocks: projected)
        let recognized = try await service(local, extractor: extractor).recognizeReview(RecognizeReviewCommand(
            draftID: id, expectedRevision: draft.revision, memberID: member.id,
            timelineDateSelection: .manual(date), userNote: "Synthetic retained note"))
        #expect(recognized.document.blocks == imported.blocks)
        #expect(recognized.draftRevision == draft.revision + 1)
        #expect(recognized.document.reviewState?.userNote == "Synthetic retained note")
        #expect(recognized.document.reviewState?.timelineDateSelection == .manual(try #require(ReportDateSemantics.canonicalDate(from: date))))
        #expect(try await local.reports.draft(id).memberID == member.id)
        #expect(try await local.reports.loadDocument(draftID: id) == recognized.document)

        let inbox = try SQLiteLANInboxStore(store: lan.store)
        let item = try await upload(bytes, inbox: inbox)
        let generated = Mutex<[UUID]>([])
        let preprocessor = LANItemPreprocessor(inbox: inbox, textExtractor: extractor, makeID: {
            generated.withLock { ids in let id = UUID(); ids.append(id); return id }
        })
        _ = try await preprocessor.preprocess(itemID: item.id)
        let prepared = try await preprocessor.preparedSelection(itemIDs: [item.id], canonicalReportDate: date)
        let ids = generated.withLock { $0 }
        #expect(ids.count == blocks.count + 1)
        #expect(prepared.sources.first.id == ids.first)
        #expect(prepared.document.blocks.map(\.id) == Array(ids.dropFirst()))
        #expect(Set(prepared.document.blocks.map(\.id)).isDisjoint(with: blocks.map(\.id)))
        let coordinator = LANReportArchiveCoordinator(inbox: inbox, preprocessor: preprocessor)
        guard case .accepted(let lanID) = try await coordinator.archive(itemIDs: [item.id],
            memberID: member.id, canonicalReportDate: date) else {
            Issue.record("Expected a LAN review draft"); return
        }
        #expect(generated.withLock { $0 } == ids)
        #expect(await extractor.digests == [ContentDigest.sha256(bytes), ContentDigest.sha256(bytes)])
        let lanDraft = try await lan.reports.draft(lanID)
        let archived = try await lan.reports.loadDocument(draftID: lanID)
        #expect(archived == prepared.document)
        #expect(lanDraft.state == .needsReview)
        #expect(try await inbox.loadSnapshot().items.isEmpty)
        #expect(try await local.reports.reportPage().items.isEmpty)
        #expect(try await lan.reports.reportPage().items.isEmpty)
        #expect(archived.reviewState?.title == recognized.document.reviewState?.title)
        #expect(archived.reviewState?.reportedResults == recognized.document.reviewState?.reportedResults)
        #expect(archived.reviewState?.timelineDateSelection == .manual(date))
        #expect(archived.reviewState?.userNote == "")
        try expectDocument(imported, source: draft.sources.first, expectedBlocks: blocks)
        try expectDocument(archived, source: lanDraft.sources.first, expectedBlocks: blocks)
        #expect(archived.candidates.dateCandidates.first?.date == imported.candidates.dateCandidates.first?.date)
        #expect(archived.candidates.dateCandidates.first?.kind == imported.candidates.dateCandidates.first?.kind)
    }

    @Test(arguments: [SQLiteAttributionFailure.extraction, .cancellation, .invalidPage])
    func unsuccessfulRecognitionKeepsPriorReviewAndLANSourceForRetry(failure: SQLiteAttributionFailure) async throws {
        let fixture = try SQLiteAppQueryFixture()
        defer { fixture.destroy() }
        let bytes = try pdf(), blocks = try rawBlocks()
        let good = SQLiteAttributionExtractor(blocks: blocks)
        let workflow = ImportWorkflow(store: fixture.reports, textExtractor: good)
        guard case .needsReview(let id) = try await workflow.importFile(ImportedFileValidator().validate(data: bytes)) else {
            Issue.record("Expected a local review draft"); return
        }
        let draft = try await fixture.reports.draft(id)
        let before = try await fixture.reports.loadDocument(draftID: id)
        let command = RecognizeReviewCommand(draftID: id, expectedRevision: draft.revision,
            memberID: nil, timelineDateSelection: .unknown, userNote: "")
        let failing = SQLiteAttributionExtractor(blocks: blocks, failure: failure)
        await #expect(throws: (any Error).self) {
            _ = try await service(fixture, extractor: failing).recognizeReview(command)
        }
        #expect(try await fixture.reports.draft(id) == draft)
        #expect(try await fixture.reports.loadDocument(draftID: id) == before)
        let inbox = try SQLiteLANInboxStore(store: fixture.store)
        let item = try await upload(bytes, inbox: inbox)
        let preprocessor = LANItemPreprocessor(inbox: inbox, textExtractor: failing)
        if failure == .cancellation {
            await #expect(throws: CancellationError.self) { _ = try await preprocessor.preprocess(itemID: item.id) }
            #expect(try await inbox.loadItems(ids: [item.id]).first == item)
        } else {
            let failed = try await preprocessor.preprocess(itemID: item.id)
            guard case .failed(_, .preprocessingFailed) = failed.state else {
                Issue.record("Expected a retryable preprocessing failure"); return
            }
        }
        #expect(try await inbox.loadItems(ids: [item.id]).first?.derivedArtifact == nil)
        let retry = try await LANItemPreprocessor(inbox: inbox, textExtractor: good).preprocess(itemID: item.id)
        #expect(retry.isReviewable)
        let recognized = try await service(fixture, extractor: good).recognizeReview(command)
        #expect(recognized.document.blocks == before.blocks)
        #expect(recognized.draftRevision == draft.revision + 1)
    }

    private func service(_ fixture: SQLiteAppQueryFixture, extractor: SQLiteAttributionExtractor) async throws -> LiveAppService {
        let service = LiveAppService(reports: fixture.reports, studies: fixture.studies, draftStore: fixture.reports,
            workflow: ImportWorkflow(store: fixture.reports, textExtractor: extractor), textExtractor: extractor)
        _ = try await service.bootstrap()
        return service
    }

    private func pdf() throws -> Data {
        let output = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: output))
        var box = CGRect(x: 0, y: 0, width: 100, height: 100)
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        for _ in 0..<2 { context.beginPDFPage(nil); context.endPDFPage() }
        context.closePDF()
        return output as Data
    }

    private func rawBlocks() throws -> [OCRBlock] {
        try ["标题：Synthetic report", "检查结果：Synthetic source result", "报告日期：2026-10-11"].enumerated().map { index, text in
            try OCRBlock(pageNumber: index == 0 ? 1 : 2, text: text,
                boundingBox: NormalizedRect(x: 0.1, y: 0.8 - Double(index) * 0.2, width: 0.8, height: 0.1),
                confidence: index == 0 ? nil : 0.875, method: index == 0 ? .pdfTextLayer : .vision,
                engineVersion: "synthetic-v1")
        }
    }

    private func upload(_ bytes: Data, inbox: SQLiteLANInboxStore) async throws -> LANInboxItem {
        guard case .sink(let sink) = try await inbox.startItemUpload(
            transport: LANInboxTransportIdentity(sessionID: UUID(), remoteFileID: UUID()),
            metadata: LANInboxTransportMetadata(displayName: LANInboxDisplayName(rawValue: "synthetic.pdf"), declaredByteCount: bytes.count),
            attemptRevision: 0) else { throw LANInboxError.invalidState }
        try await sink.write(bytes).value
        _ = try await sink.finish()
        return try #require(try await inbox.loadSnapshot().items.first)
    }

    private func expectDocument(_ document: ImportDraftDocument, source: ReportSource, expectedBlocks: [OCRBlock]) throws {
        #expect(document.blocks.count == expectedBlocks.count)
        for (block, expected) in zip(document.blocks, expectedBlocks) {
            #expect(block.sourceID == source.id)
            #expect(block.attachmentID == source.attachmentID)
            #expect(block.filePageNumber == expected.filePageNumber)
            #expect(block.pageNumber == expected.filePageNumber)
            #expect(block.text == expected.text)
            #expect(block.boundingBox == expected.boundingBox)
            #expect(block.confidence == expected.confidence)
            #expect(block.method == expected.method)
            #expect(block.engineVersion == expected.engineVersion)
        }
        let title = try #require(document.candidates.title)
        let results = try #require(document.candidates.reportedResults)
        let date = try #require(document.candidates.dateCandidates.first)
        #expect(title.originalTranscription == "Synthetic report")
        #expect(results.originalTranscription == "Synthetic source result")
        #expect(date.source.originalTranscription == "2026-10-11")
        #expect(document.candidates.dateCandidates.count == 1)
        #expect(document.candidates.memberName == nil)
        #expect(document.candidates.organization == nil)
        #expect(document.candidates.department == nil)
        #expect(document.candidates.reportType == nil)
        #expect(document.candidates.conclusion == nil)
        #expect(document.candidates.abnormalItems.isEmpty)
        for (index, field) in [title, results, date.source].enumerated() {
            #expect(field.correctedTranscription == nil)
            #expect(field.entryMethod == nil)
            #expect(field.references.count == 1)
            let reference = try #require(field.references.first)
            #expect(reference.sourceID == source.id)
            #expect(reference.attachmentID == source.attachmentID)
            #expect(reference.filePageNumber == expectedBlocks[index].filePageNumber)
            #expect(reference.blockID == document.blocks[index].id)
            #expect(reference.boundingBox == expectedBlocks[index].boundingBox)
        }
    }
}

enum SQLiteAttributionFailure: Error, Sendable {
    case extraction, cancellation, invalidPage
}

private actor SQLiteAttributionExtractor: TextExtractionService {
    let blocks: [OCRBlock]
    let failure: SQLiteAttributionFailure?
    private(set) var digests: [Data] = []
    init(blocks: [OCRBlock], failure: SQLiteAttributionFailure? = nil) {
        self.blocks = blocks; self.failure = failure
    }
    func extractText(from file: ValidatedImportedFile) async throws -> [OCRBlock] {
        digests.append(file.sha256Digest)
        switch failure {
        case .extraction: throw SQLiteAttributionFailure.extraction
        case .cancellation: throw CancellationError()
        case .invalidPage:
            return blocks + [try OCRBlock(pageNumber: file.pageCount + 1, text: "Invalid page",
                boundingBox: NormalizedRect(x: 0, y: 0, width: 1, height: 1), confidence: 1,
                method: .vision, engineVersion: "synthetic")]
        case nil: return blocks
        }
    }
}
