import Foundation
import Testing
@testable import KinlogueCore
@testable import KinloguePlatform

// `ImportWorkflow` driven against the SQLite report repository. Draft transitions, duplicate
// claims and confirmation on the repository itself are covered by `LibraryQueryIntegrationTests`.

@Test
func workflowStoresTheOriginalAndItsReviewDocumentInTheLibrary() async throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let kernel = try SQLiteLibraryStore(rootURL: root)
    let repository = SQLiteReportRepository(store: kernel)
    let workflow = ImportWorkflow(store: repository, textExtractor: SyntheticWorkflowExtractor())
    let plaintext = Data("SYNTHETIC-ATTACHMENT-BYTES".utf8)
    let file = try ValidatedImportedFile(
        data: plaintext,
        kind: .image,
        contentTypeIdentifier: "public.png",
        sha256Digest: ContentDigest.sha256(plaintext)
    )

    let outcome = try await workflow.importFile(file)
    guard case .needsReview(let draftID) = outcome else {
        Issue.record("Expected a review draft")
        return
    }

    let draft = try await repository.draft(draftID)
    #expect(draft.state == .needsReview)
    #expect(draft.memberID == nil)
    let originalID = try #require(draft.soleAttachmentID)
    #expect(try await repository.loadSource(draftID: draftID) == file)
    let document = try await repository.loadDocument(draftID: draftID)
    #expect(document.candidates.memberName?.transcription == "合成成员")
    #expect(document.blocks.map(\.sourceID) == [draft.sources.first.id])

    #expect(try await workflow.importFile(file) == .existingDraft(draftID))

    // The original is one plain file named by its identifier, and nothing else was written for it.
    let originals = root.appendingPathComponent("originals", isDirectory: true)
    #expect(try FileManager.default.contentsOfDirectory(atPath: originals.path) == [originalID.uuidString.lowercased() + ".data"])
    #expect(try Data(contentsOf: originals.appendingPathComponent(originalID.uuidString.lowercased() + ".data")) == plaintext)

    try kernel.close()
    let reopened = try SQLiteLibraryStore(rootURL: root)
    defer { try? reopened.close() }
    let reopenedRepository = SQLiteReportRepository(store: reopened)
    #expect(try await reopenedRepository.loadSource(draftID: draftID).data == plaintext)
    #expect(try await reopenedRepository.loadDocument(draftID: draftID) == document)
}

@Test
func reviewSnapshotCarriesTheDocumentTheFirstOriginalAndTheMembers() async throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let kernel = try SQLiteLibraryStore(rootURL: root)
    defer { try? kernel.close() }
    let repository = SQLiteReportRepository(store: kernel)
    let member = try FamilyMember(displayName: "Synthetic review member")
    try await repository.saveMember(member, replacing: nil)
    let bytes = Data("SYNTHETIC-FIRST-REVIEW-SOURCE".utf8)
    let file = try ValidatedImportedFile(data: bytes, kind: .image, contentTypeIdentifier: "public.png",
                                         sha256Digest: ContentDigest.sha256(bytes))
    let workflow = ImportWorkflow(store: repository, textExtractor: SyntheticWorkflowExtractor())
    guard case .needsReview(let draftID) = try await workflow.importFile(file) else {
        Issue.record("Expected a review draft")
        return
    }

    let snapshot = try await repository.loadReviewSnapshot(draftID: draftID)

    #expect(snapshot.draft == (try await repository.draft(draftID)))
    #expect(snapshot.document == (try await repository.loadDocument(draftID: draftID)))
    #expect(snapshot.originalData == bytes)
    #expect(snapshot.attachment.id == snapshot.draft.sources.first.attachmentID)
    #expect(snapshot.attachment.sha256Digest == ContentDigest.sha256(bytes))
    #expect(snapshot.members.map(\.id) == [member.id])
}

@Test
func loadingAStagedMultiPageSourcePreservesItsPageCount() async throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let kernel = try SQLiteLibraryStore(rootURL: root)
    defer { try? kernel.close() }
    let repository = SQLiteReportRepository(store: kernel)
    let bytes = Data("SYNTHETIC-MULTIPAGE".utf8)
    let file = try ValidatedImportedFile(
        data: bytes,
        kind: .pdf,
        contentTypeIdentifier: "com.adobe.pdf",
        sha256Digest: ContentDigest.sha256(bytes),
        pageCount: 3
    )
    guard case .created(let draftID) = try await repository.stage(file) else {
        Issue.record("Expected a draft")
        return
    }

    #expect(try await repository.loadSource(draftID: draftID).pageCount == 3)
    #expect(try await repository.loadSource(draftID: draftID).kind == .pdf)
}

@Test
func deferredReviewEditsSurviveReopeningTheLibrary() async throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let kernel = try SQLiteLibraryStore(rootURL: root)
    let repository = SQLiteReportRepository(store: kernel)
    let member = try FamilyMember(displayName: "Synthetic deferred member")
    try await repository.saveMember(member, replacing: nil)
    let bytes = Data("SYNTHETIC-DEFERRED-REVIEW".utf8)
    let file = try ValidatedImportedFile(data: bytes, kind: .image, contentTypeIdentifier: "public.png",
                                         sha256Digest: ContentDigest.sha256(bytes))
    let workflow = ImportWorkflow(store: repository, textExtractor: SyntheticWorkflowExtractor())
    guard case .needsReview(let draftID) = try await workflow.importFile(file) else {
        Issue.record("Expected a review draft")
        return
    }
    let recognized = try await repository.loadDocument(draftID: draftID)
    let draft = try await repository.draft(draftID)
    let edited = ImportDraftDocument(
        blocks: recognized.blocks,
        candidates: recognized.candidates,
        candidateExtractionVersion: recognized.candidateExtractionVersion,
        reviewState: ImportDraftReviewState(
            timelineDateSelection: .unknown,
            title: "Synthetic deferred title",
            organization: "",
            department: "",
            reportType: "",
            reportedResults: "",
            conclusion: "Synthetic deferred conclusion",
            abnormalItems: ["Synthetic abnormal item"],
            userNote: "Synthetic note"
        )
    )

    try await repository.saveReview(draftID: draftID, expectedRevision: draft.revision, memberID: member.id, document: edited)
    try kernel.close()

    let reopened = try SQLiteLibraryStore(rootURL: root)
    defer { try? reopened.close() }
    let reopenedRepository = SQLiteReportRepository(store: reopened)
    let saved = try await reopenedRepository.draft(draftID)
    #expect(saved.state == .needsReview)
    #expect(saved.memberID == member.id)
    #expect(saved.revision == draft.revision + 1)
    #expect(try await reopenedRepository.loadDocument(draftID: draftID) == edited)
    // A review saved against the revision it replaced is refused and changes nothing.
    await #expect(throws: (any Error).self) {
        try await reopenedRepository.saveReview(draftID: draftID, expectedRevision: draft.revision, memberID: nil, document: edited)
    }
    #expect(try await reopenedRepository.draft(draftID) == saved)
}

@Test
func failedDraftIsNotAutomaticallyResumedButExplicitRetryStillProcessesIt() async throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let kernel = try SQLiteLibraryStore(rootURL: root)
    let repository = SQLiteReportRepository(store: kernel)
    let bytes = Data("SYNTHETIC-FAILED-RETRY".utf8)
    let file = try ValidatedImportedFile(
        data: bytes,
        kind: .image,
        contentTypeIdentifier: "public.png",
        sha256Digest: ContentDigest.sha256(bytes)
    )
    guard case .created(let draftID) = try await repository.stage(file) else {
        Issue.record("Expected a new draft")
        return
    }
    let lease = try await repository.beginProcessing(draftID: draftID, attemptID: UUID())
    try await repository.failProcessing(lease: lease, failureCode: .textExtractionFailed)
    let failed = try await repository.draft(draftID)
    #expect(failed.state == .failed)
    try kernel.close()

    let restarted = try SQLiteLibraryStore(rootURL: root)
    defer { try? restarted.close() }
    let restartedRepository = SQLiteReportRepository(store: restarted)
    let restartedWorkflow = ImportWorkflow(store: restartedRepository, textExtractor: SyntheticWorkflowExtractor())
    #expect(try await restartedRepository.resumableDraftIDs().isEmpty)
    #expect(try await restartedWorkflow.resumeInterruptedImports().isEmpty)
    #expect(try await restartedRepository.draft(draftID) == failed)

    #expect(try await restartedWorkflow.retry(draftID: draftID) == .needsReview(draftID))
    let retried = try await restartedRepository.draft(draftID)
    #expect(retried.state == .needsReview)
    #expect(retried.revision == failed.revision + 2)
    #expect(retried.failureCode == nil)
}

@Test
func aCancelledAttemptLeavesTheDraftInProcessingForTheNextLaunch() async throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let kernel = try SQLiteLibraryStore(rootURL: root)
    defer { try? kernel.close() }
    let repository = SQLiteReportRepository(store: kernel)
    let bytes = Data("SYNTHETIC-CANCELLED-ATTEMPT".utf8)
    let file = try ValidatedImportedFile(data: bytes, kind: .image, contentTypeIdentifier: "public.png",
                                         sha256Digest: ContentDigest.sha256(bytes))
    guard case .created(let draftID) = try await repository.stage(file) else {
        Issue.record("Expected a new draft")
        return
    }
    let lease = try await repository.beginProcessing(draftID: draftID, attemptID: UUID())

    // Recording the failure of a cancelled attempt would turn an interrupted import into one the
    // user has to retry by hand; the draft has to stay resumable instead.
    let cancelled = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        try await repository.failProcessing(lease: lease, failureCode: .cancelled)
    }
    await #expect(throws: CancellationError.self) { try await cancelled.value }

    #expect(try await repository.draft(draftID).state == .processing)
    #expect(try await repository.resumableDraftIDs() == [draftID])
}

private actor SyntheticWorkflowExtractor: TextExtractionService {
    func extractText(from file: ValidatedImportedFile) async throws -> [OCRBlock] {
        [try OCRBlock(
            pageNumber: 1,
            text: "姓名：合成成员",
            boundingBox: NormalizedRect(x: 0.1, y: 0.8, width: 0.4, height: 0.1),
            confidence: 1,
            method: .vision,
            engineVersion: "synthetic"
        )]
    }
}
