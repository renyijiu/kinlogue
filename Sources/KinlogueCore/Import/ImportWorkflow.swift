import Foundation

public enum ImportStageOutcome: Equatable, Sendable {
    case created(ImportDraft.ID)
    case existingRecord(HealthRecord.ID)
    case existingDraft(ImportDraft.ID)
}

public struct ImportProcessingLease: Equatable, Sendable {
    public let draftID: ImportDraft.ID
    public let revision: UInt64
    public let attemptID: UUID

    public init(draftID: ImportDraft.ID, revision: UInt64, attemptID: UUID) {
        self.draftID = draftID
        self.revision = revision
        self.attemptID = attemptID
    }
}

/// The coherent data needed to present one import draft for review.
/// All fields originate from the same persisted catalog generation.
public struct ImportDraftReviewSnapshot: Equatable, Sendable {
    public let draft: ImportDraft
    public let document: ImportDraftDocument
    public let members: [FamilyMember]
    public let attachment: Attachment
    public let originalData: Data

    public init(
        draft: ImportDraft,
        document: ImportDraftDocument,
        members: [FamilyMember],
        attachment: Attachment,
        originalData: Data
    ) {
        self.draft = draft
        self.document = document
        self.members = members
        self.attachment = attachment
        self.originalData = originalData
    }
}

public protocol ImportDraftStore: Sendable {
    func stage(_ file: ValidatedImportedFile) async throws -> ImportStageOutcome
    func beginProcessing(draftID: ImportDraft.ID, attemptID: UUID) async throws -> ImportProcessingLease
    func loadSource(draftID: ImportDraft.ID) async throws -> ValidatedImportedFile
    func completeProcessing(
        lease: ImportProcessingLease,
        document: ImportDraftDocument
    ) async throws
    func failProcessing(
        lease: ImportProcessingLease,
        failureCode: ImportFailureCode
    ) async throws
    func resumableDraftIDs() async throws -> [ImportDraft.ID]
    func loadDocument(draftID: ImportDraft.ID) async throws -> ImportDraftDocument
    func loadReviewSnapshot(draftID: ImportDraft.ID) async throws -> ImportDraftReviewSnapshot
    /// Atomically saves the user's in-progress review fields and member selection.
    func saveReview(
        draftID: ImportDraft.ID,
        expectedRevision: UInt64,
        memberID: FamilyMember.ID?,
        document: ImportDraftDocument
    ) async throws
    /// Atomically publishes a confirmed record and removes its review draft.
    func confirm(
        draftID: ImportDraft.ID,
        expectedRevision: UInt64,
        record: HealthRecord
    ) async throws -> VaultCatalog
    func discard(
        draftID: ImportDraft.ID,
        expectedRevision: UInt64
    ) async throws -> VaultCatalog
}

public enum ImportWorkflowOutcome: Equatable, Sendable {
    case needsReview(ImportDraft.ID)
    case existingRecord(HealthRecord.ID)
    case existingDraft(ImportDraft.ID)
    case failed(ImportDraft.ID, ImportFailureCode)
}

public actor ImportWorkflow {
    private let store: any ImportDraftStore
    private let textExtractor: any TextExtractionService
    private let candidateExtractor: ReportCandidateExtractor

    public init(
        store: any ImportDraftStore,
        textExtractor: any TextExtractionService,
        candidateExtractor: ReportCandidateExtractor = ReportCandidateExtractor()
    ) {
        self.store = store
        self.textExtractor = textExtractor
        self.candidateExtractor = candidateExtractor
    }

    public func importFile(_ file: ValidatedImportedFile) async throws -> ImportWorkflowOutcome {
        switch try await store.stage(file) {
        case .existingRecord(let id): return .existingRecord(id)
        case .existingDraft(let id): return .existingDraft(id)
        case .created(let id): return try await process(draftID: id)
        }
    }

    public func retry(draftID: ImportDraft.ID) async throws -> ImportWorkflowOutcome {
        try await process(draftID: draftID)
    }

    public func resumeInterruptedImports() async throws -> [ImportWorkflowOutcome] {
        let draftIDs = try await store.resumableDraftIDs()
        return try await resumeInterruptedImports(draftIDs: draftIDs)
    }

    public func resumeInterruptedImports(
        draftIDs: [ImportDraft.ID]
    ) async throws -> [ImportWorkflowOutcome] {
        var outcomes: [ImportWorkflowOutcome] = []
        for id in draftIDs {
            outcomes.append(try await process(draftID: id))
        }
        return outcomes
    }

    private func process(draftID: ImportDraft.ID) async throws -> ImportWorkflowOutcome {
        let lease = try await store.beginProcessing(draftID: draftID, attemptID: UUID())
        let blocks: [OCRBlock]
        do {
            let source = try await store.loadSource(draftID: draftID)
            blocks = try await textExtractor.extractText(from: source)
            try Task.checkCancellation()
        } catch is CancellationError {
            try await store.failProcessing(lease: lease, failureCode: .cancelled)
            return .failed(draftID, .cancelled)
        } catch {
            try await store.failProcessing(lease: lease, failureCode: .textExtractionFailed)
            return .failed(draftID, .textExtractionFailed)
        }
        let document = ImportDraftDocument(
            blocks: blocks,
            candidates: candidateExtractor.extract(from: blocks)
        )
        try await store.completeProcessing(lease: lease, document: document)
        return .needsReview(draftID)
    }
}
