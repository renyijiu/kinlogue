import Foundation
import KinlogueCore
import KinloguePlatform
import UniformTypeIdentifiers

struct LiveAppServiceEnvironment: Sendable {
    let dataService: LiveAppService
    let originalExportService: any OriginalExportServicing
    let destroyService: any VaultDestroyServicing
    let lanInboxService: any LANInboxServicing
    let dicomSliceServiceFactory: @Sendable () -> any DICOMSliceViewing
    let dicomImportMetrics: DICOMImportMetricsRecorder?
    let lifecycle: LibraryLifecycleCoordinator
    var commitChanges: (@Sendable () -> AsyncStream<LibraryRevision>)? = nil

    @concurrent
    static func makeOpened(identity: AppRuntimeIdentity, store: SQLiteLibraryStore,
                           lifecycle: LibraryLifecycleCoordinator) async throws -> Self {
        try await LibraryStorageExecutor.run {
            let reports = SQLiteReportRepository(store: store)
            let studies = try SQLiteDICOMRepository(store: store)
            let extractor = OnDeviceTextExtractionService()
            let metrics: DICOMImportMetricsRecorder? = if case .acceptance = identity.mode { DICOMImportMetricsRecorder() } else { nil }
            let scope: DICOMSecurityScopeRequirement = if case .acceptance = identity.mode { .notRequiredForTesting } else { .required }
            let workflow = ImportWorkflow(store: reports, textExtractor: extractor)
            let dicom = try DICOMImportWorkflow(repository: studies, metrics: metrics)
            return Self(dataService: LiveAppService(reports: reports, studies: studies, draftStore: reports,
                workflow: workflow, textExtractor: extractor, lifecycle: lifecycle,
                dicomRuntime: DICOMAppRuntime(workflow: dicom, lifecycle: lifecycle, securityScope: scope)),
                originalExportService: LiveOriginalExportService(store: store, lifecycle: lifecycle),
                destroyService: LifecycleCoordinatedVaultDestroyService(lifecycle: lifecycle,
                    underlying: SQLiteVaultDestroyService(store: store)),
                lanInboxService: try LiveLANInboxService(store: store, lifecycle: lifecycle),
                dicomSliceServiceFactory: { DICOMSliceService(repository: studies) }, dicomImportMetrics: metrics,
                lifecycle: lifecycle, commitChanges: { store.changes() })
        }
    }
}

struct DICOMAppRuntime: Sendable {
    let workflow: DICOMImportWorkflow
    let lifecycle: LibraryLifecycleCoordinator?
    let securityScope: DICOMSecurityScopeRequirement

    init(
        workflow: DICOMImportWorkflow,
        lifecycle: LibraryLifecycleCoordinator? = nil,
        securityScope: DICOMSecurityScopeRequirement = .required
    ) {
        self.workflow = workflow
        self.lifecycle = lifecycle
        self.securityScope = securityScope
    }
}

actor LiveAppService: AppDataServicing, DICOMAppServicing {
    private struct ActiveReportOperation: Sendable {
        let cancel: @Sendable () -> Void
        let waitForCompletion: @Sendable () async -> Void
    }

    private let reports: any LibraryReportStoring
    private let studies: any LibraryDICOMStoring
    private let draftStore: any ImportDraftStore
    private let workflow: ImportWorkflow
    private let textExtractor: any TextExtractionService
    private let validator: ImportedFileValidator
    private let lifecycle: LibraryLifecycleCoordinator?
    private let dicomRuntime: DICOMAppRuntime?
    private let reportLifecycleRegistrationID = UUID()
    private let dicomLifecycleRegistrationID = UUID()
    private var reportLifecycleRegistered = false
    private var reportLifecycleRevoked = false
    private var activeReportOperations: [UUID: ActiveReportOperation] = [:]
    private var dicomLifecycleRegistered = false
    private var startupTask: Task<AppSnapshot, Error>?
    private var startupAttemptID: UUID?
    private var startupCompleted: Bool
    private var recoveryDraftIDs: [UUID] = []
    private struct RecoveryAttempt {
        let originalRevision: UInt64
        let id: UUID
        var failed = false

        func stillMatches(_ draft: ImportDraft) -> Bool {
            draft.isResumableAfterInterruption && (
                draft.revision == originalRevision || (draft.state == .processing && draft.attemptID == id)
            )
        }
    }
    private var recoveryAttempts: [ImportDraft.ID: RecoveryAttempt] = [:]
    private var activeDICOMImportTask: Task<DICOMAppImportOutcome, Error>?
    private var activeDICOMImportID: UUID?
    private var terminalDICOMImportTask: Task<DICOMAppImportOutcome, Error>?
    private var terminalDICOMImportID: UUID?
    private var claimedDICOMImportID: UUID?
#if DEBUG
    private var startupWaitObserver: (@Sendable () async -> Void)?
    private var claimedDICOMImportWasActive = false
    private var dicomImportCancellationClaimWaiters: [
        UUID: [CheckedContinuation<Bool, Never>]
    ] = [:]
#endif

    init(reports: any LibraryReportStoring, studies: any LibraryDICOMStoring,
         draftStore: any ImportDraftStore, workflow: ImportWorkflow,
         textExtractor: any TextExtractionService = OnDeviceTextExtractionService(),
         validator: ImportedFileValidator = ImportedFileValidator(), startupCompleted: Bool = false,
         lifecycle: LibraryLifecycleCoordinator? = nil, dicomRuntime: DICOMAppRuntime? = nil) {
        self.reports = reports; self.studies = studies; self.draftStore = draftStore; self.workflow = workflow
        self.textExtractor = textExtractor; self.validator = validator; self.startupCompleted = startupCompleted
        self.lifecycle = lifecycle; self.dicomRuntime = dicomRuntime
    }

    func bootstrap() async throws -> AppSnapshot {
        try Task.checkCancellation()
        try await lifecycle?.requireActive()
        if startupCompleted {
            return AppSnapshot(header: try await reports.header())
        }
        if let startupTask, let startupAttemptID {
            return try await finishStartup(startupTask, attemptID: startupAttemptID)
        }

        if let lifecycle { try await registerReportLifecycleIfNeeded(on: lifecycle) }
        guard !reportLifecycleRevoked else { throw LibraryLifecycleCoordinatorError.revoked }
        if let startupTask, let startupAttemptID {
            return try await finishStartup(startupTask, attemptID: startupAttemptID)
        }
        let attemptID = UUID()
        let task = Task<AppSnapshot, Error> { [self] in
            do { _ = try await reports.initializeLibrary() }
            catch is VaultError { throw AppServiceError.vaultUnavailable }
            recoveryDraftIDs = try await draftStore.resumableDraftIDs()
            try Task.checkCancellation()
            return AppSnapshot(header: try await reports.header())
        }
        startupTask = task
        startupAttemptID = attemptID
        return try await finishStartup(task, attemptID: attemptID)
    }

#if DEBUG
    func installStartupWaitObserverForTesting(
        _ observer: (@Sendable () async -> Void)?
    ) {
        startupWaitObserver = observer
    }
#endif

    func resumeInterruptedImports(
        onDraftCompleted: @escaping @Sendable () async -> Void
    ) async {
        guard (try? await requireStartup()) != nil else { return }
        let ids = recoveryDraftIDs
        recoveryDraftIDs.removeAll()
        for id in ids {
            guard !Task.isCancelled else { return }
            do {
                _ = try await processRecoveryAttempt(for: reports.draft(id))
            } catch is CancellationError { return }
            catch LibraryLifecycleCoordinatorError.revoked { return }
            catch { /* The attempt retains its retry state; continue with the next draft. */ }
            guard !Task.isCancelled else { return }
            do { try await lifecycle?.requireActive() } catch { return }
            await onDraftCompleted()
        }
    }

    func refresh() async throws -> AppSnapshot {
        try await requireStartup()
        return try await withActiveReportOperation { [self] in
            try await performRefresh()
        }
    }

    private func performRefresh() async throws -> AppSnapshot {
        return AppSnapshot(header: try await reports.header())
    }

    func createMember(displayName: String, disambiguationLabel: String?) async throws -> AppSnapshot {
        try await requireStartup()
        return try await withActiveReportOperation { [self] in
            try await performCreateMember(displayName: displayName, disambiguationLabel: disambiguationLabel)
        }
    }

    private func performCreateMember(displayName: String, disambiguationLabel: String?) async throws -> AppSnapshot {
        try await reports.saveMember(FamilyMember(displayName: displayName, disambiguationLabel: disambiguationLabel), replacing: nil)
        return AppSnapshot(header: try await reports.header())
    }

    func loadMember(id: UUID) async throws -> FamilyMember {
        try await requireStartup()
        return try await withActiveReportOperation { [self] in
            try await performLoadMember(id: id)
        }
    }

    private func performLoadMember(id: UUID) async throws -> FamilyMember {
        return try await reports.member(id)
    }

    func updateMember(_ member: FamilyMember, replacing expected: FamilyMember) async throws -> AppSnapshot {
        try await requireStartup()
        return try await withActiveReportOperation { [self] in
            try await performUpdateMember(member, replacing: expected)
        }
    }

    private func performUpdateMember(_ member: FamilyMember, replacing expected: FamilyMember) async throws -> AppSnapshot {
        try await reports.saveMember(member, replacing: expected)
        return AppSnapshot(header: try await reports.header())
    }

    func archiveMember(id: UUID) async throws -> AppSnapshot {
        try await requireStartup()
        return try await withActiveReportOperation { [self] in
            try await performArchiveMember(id: id)
        }
    }

    private func performArchiveMember(id: UUID) async throws -> AppSnapshot {
        let current = try await reports.member(id)
        var archived = current; archived.isArchived = true
        try await reports.saveMember(archived, replacing: current)
        return AppSnapshot(header: try await reports.header())
    }

    func deleteMember(id: UUID) async throws -> AppSnapshot {
        try await requireStartup()
        return try await withActiveReportOperation { [self] in
            try await performDeleteMember(id: id)
        }
    }

    private func performDeleteMember(id: UUID) async throws -> AppSnapshot {
        do { try await reports.deleteMember(id) }
        catch CatalogDeletionError.memberStillReferenced(let records, let drafts) {
            throw AppServiceError.memberStillReferenced(recordCount: records, draftCount: drafts)
        } catch CatalogDeletionError.memberStillReferencedByDICOMStudy(let count) {
            throw AppServiceError.memberStillReferencedByDICOMStudy(studyCount: count)
        }
        return AppSnapshot(header: try await reports.header())
    }

    func timelinePage(memberID: UUID?, cursor: LibraryQueryCursor?) async throws -> LibraryTimelinePage {
        try await requireStartup()
        return try await withActiveReportOperation { [self] in
            try await performTimelinePage(memberID: memberID, cursor: cursor)
        }
    }

    private func performTimelinePage(memberID: UUID?, cursor: LibraryQueryCursor?) async throws -> LibraryTimelinePage {
        return try await reports.timelinePage(memberID: memberID, limit: 100, cursor: cursor)
    }
    func reportPage(query: String, memberID: UUID?, cursor: LibraryQueryCursor?) async throws -> LibraryReportPage {
        try await requireStartup()
        return try await withActiveReportOperation { [self] in
            try await performReportPage(query: query, memberID: memberID, cursor: cursor)
        }
    }

    private func performReportPage(query: String, memberID: UUID?, cursor: LibraryQueryCursor?) async throws -> LibraryReportPage {
        return try await reports.reportPage(query: query, memberID: memberID, limit: 100, cursor: cursor)
    }
    func draftPage(states: [ImportState], cursor: LibraryQueryCursor?) async throws -> AppDraftPage {
        try await requireStartup()
        return try await withActiveReportOperation { [self] in
            try await performDraftPage(states: states, cursor: cursor)
        }
    }

    private func performDraftPage(states: [ImportState], cursor: LibraryQueryCursor?) async throws -> AppDraftPage {
        let page = try await reports.draftPage(states: states, limit: 100, cursor: cursor)
        var items: [DraftSummary] = []
        for draft in page.items {
            var retry = false
            if let attempt = recoveryAttempts[draft.id], attempt.failed {
                // Only the few failed in-memory attempts need a full target read, never the whole queue.
                if let current = try? await reports.draft(draft.id), current.revision == draft.revision {
                    retry = attempt.stillMatches(current)
                }
            }
            items.append(DraftSummary(draft: draft, canRetryRecovery: retry))
        }
        return AppDraftPage(revision: page.revision, items: items, nextCursor: page.nextCursor, damagedIDs: page.damagedIDs)
    }
    func loadDraft(id: UUID) async throws -> ImportDraft {
        try await requireStartup()
        return try await withActiveReportOperation { [self] in
            try await performLoadDraft(id: id)
        }
    }

    private func performLoadDraft(id: UUID) async throws -> ImportDraft {
        return try await reports.draft(id)
    }
    func loadRecords(ids: [UUID]) async throws -> LibraryRecordSelection {
        try await requireStartup()
        return try await withActiveReportOperation { [self] in
            try await performLoadRecords(ids: ids)
        }
    }

    private func performLoadRecords(ids: [UUID]) async throws -> LibraryRecordSelection {
        do { return try await reports.recordSelection(ids) }
        catch LibraryReportError.recordNotFound { throw AppServiceError.recordUnavailable }
    }

    func importFile(at url: URL) async throws -> AppImportOutcome {
        try await requireStartup()
        let validated: ValidatedImportedFile
        do {
            validated = try coordinatedValidation(of: url)
        } catch let error as ImportedFileValidationError {
            return .failed(Self.failureCode(for: error))
        } catch {
            return .failed(.importFailed)
        }

        do {
            let workflow = self.workflow
            return try await withActiveReportOperation {
                AppImportOutcome(try await workflow.importFile(validated))
            }
        } catch {
            return .failed(.importFailed)
        }
    }

    func retryDraft(id: ImportDraft.ID) async throws -> AppImportOutcome {
        try await requireStartup()
        let draft = try await reports.draft(id)
        return try await processRecoveryAttempt(for: draft)
    }

    private func processRecoveryAttempt(for draft: ImportDraft) async throws -> AppImportOutcome {
        let attempt = RecoveryAttempt(originalRevision: draft.revision, id: UUID())
        recoveryAttempts[draft.id] = attempt
        let workflow = self.workflow
        do {
            let outcome = try await withActiveReportOperation {
                AppImportOutcome(try await workflow.retry(draftID: draft.id, attemptID: attempt.id))
            }
            if recoveryAttempts[draft.id]?.id == attempt.id {
                recoveryAttempts.removeValue(forKey: draft.id)
            }
            return outcome
        } catch {
            if recoveryAttempts[draft.id]?.id == attempt.id {
                switch error {
                case is CancellationError, LibraryLifecycleCoordinatorError.revoked,
                     ImportDraftError.staleAttempt, ImportDraftError.invalidState,
                     LibraryReportError.draftNotFound:
                    recoveryAttempts.removeValue(forKey: draft.id)
                default:
                    if Task.isCancelled || reportLifecycleRevoked {
                        recoveryAttempts.removeValue(forKey: draft.id)
                    } else {
                        recoveryAttempts[draft.id]?.failed = true
                    }
                }
            }
            throw error
        }
    }

    func loadReview(draftID: ImportDraft.ID) async throws -> ImportReviewContent {
        try await requireStartup()
        return try await withActiveReportOperation { [self] in
            try await performLoadReview(draftID: draftID)
        }
    }

    private func performLoadReview(draftID: ImportDraft.ID) async throws -> ImportReviewContent {
        let snapshot = try await reports.reviewContent(draftID: draftID)
        let source = snapshot.draft.sources.first
        return ImportReviewContent(
            revision: snapshot.revision,
            draft: snapshot.draft,
            document: try refreshedDocument(
                snapshot.document,
                sources: snapshot.draft.sources
            ),
            members: LibraryMemberSummary.selectable(snapshot.members),
            original: originalPayload(source: source, attachment: snapshot.attachment, data: snapshot.originalData)
        )
    }

    func recognizeReview(
        _ command: RecognizeReviewCommand
    ) async throws -> RecognizedReviewContent {
        try await requireStartup()
        return try await withActiveReportOperation { [self] in
            try await performRecognizeReview(command)
        }
    }

    private func performRecognizeReview(
        _ command: RecognizeReviewCommand
    ) async throws -> RecognizedReviewContent {
        let draft = try await reports.draft(command.draftID)
        guard draft.state == .needsReview, draft.revision == command.expectedRevision,
              draft.revision < UInt64.max else { throw AppServiceError.invalidReview }
        if let memberID = command.memberID, try await reports.member(memberID).isArchived {
            throw AppServiceError.invalidReview
        }

        let currentDocument = try refreshedDocument(
            try await draftStore.loadDocument(draftID: command.draftID),
            sources: draft.sources
        )
        let currentDateSelection = try persistedReviewDateSelection(
            candidates: currentDocument.candidates.dateCandidates,
            selection: command.timelineDateSelection,
            detectedDateCandidate: command.detectedDateCandidate
        )
        let recognized: ImportDraftDocument
        // Either store reports a draft that changed while its originals were being read.
        do { recognized = try await recognizeDocument(for: draft) }
        catch LibraryReportError.staleRevision { throw AppServiceError.invalidReview }
        catch ImportDraftError.staleAttempt { throw AppServiceError.invalidReview }
        try Task.checkCancellation()
        let persistedDateSelection = dateSelectionAfterRecognition(
            currentDateSelection,
            oldCandidates: currentDocument.candidates.dateCandidates,
            newCandidates: recognized.candidates.dateCandidates
        )
        let document = ImportDraftDocument(
            blocks: recognized.blocks,
            candidates: recognized.candidates,
            candidateExtractionVersion: recognized.candidateExtractionVersion,
            reviewState: ImportDraftReviewState(
                timelineDateSelection: persistedDateSelection,
                title: recognized.candidates.title?.transcription ?? "",
                organization: recognized.candidates.organization?.transcription ?? "",
                department: recognized.candidates.department?.transcription ?? "",
                reportType: recognized.candidates.reportType?.transcription ?? "",
                reportedResults: recognized.candidates.reportedResults?.transcription ?? "",
                conclusion: recognized.candidates.conclusion?.transcription ?? "",
                abnormalItems: recognized.candidates.abnormalItems.map(\.transcription),
                userNote: command.userNote
            )
        )
        try await draftStore.saveReview(
            draftID: command.draftID,
            expectedRevision: command.expectedRevision,
            memberID: command.memberID,
            document: document
        )
        return RecognizedReviewContent(
            draftRevision: command.expectedRevision + 1,
            document: document
        )
    }

    func loadReviewOriginal(draftID: UUID, sourceID: UUID, expectedRevision: UInt64, expectedLibrary: LibraryRevision) async throws -> OriginalDocumentPayload {
        try await requireStartup()
        return try await withActiveReportOperation { [self] in
            try await performLoadReviewOriginal(draftID: draftID, sourceID: sourceID, expectedRevision: expectedRevision, expectedLibrary: expectedLibrary)
        }
    }

    private func performLoadReviewOriginal(draftID: UUID, sourceID: UUID, expectedRevision: UInt64, expectedLibrary: LibraryRevision) async throws -> OriginalDocumentPayload {
        let draft = try await reports.draft(draftID)
        guard draft.revision == expectedRevision, draft.state == .needsReview,
              let source = draft.sources.elements.first(where: { $0.id == sourceID }) else { throw AppServiceError.draftUnavailable }
        let value = try await reports.original(draftID: draftID, expectedRevision: expectedRevision, sourceID: sourceID, expectedLibrary: expectedLibrary)
        return originalPayload(source: source, attachment: value.0, data: value.1)
    }

    func confirmDraft(_ command: ConfirmDraftCommand) async throws -> AppSnapshot {
        try await requireStartup()
        return try await withActiveReportOperation { [self] in
            try await performConfirmDraft(command)
        }
    }

    private func performConfirmDraft(_ command: ConfirmDraftCommand) async throws -> AppSnapshot {
        let draft = try await reports.draft(command.draftID)
        guard draft.state == .needsReview, draft.revision == command.expectedRevision,
              try await !reports.member(command.memberID).isArchived else { throw AppServiceError.invalidReview }
        let storedDocument = try await draftStore.loadDocument(draftID: command.draftID)
        let document = try refreshedDocument(storedDocument, sources: draft.sources)
        let candidates = document.candidates
        let dateSelection = try resolvedTimelineDateSelection(
            candidates: candidates.dateCandidates,
            selection: command.timelineDateSelection,
            detectedDateCandidate: command.detectedDateCandidate
        )
        let notes = command.userNote.trimmed.isEmpty
            ? []
            : [try UserNote(text: command.userNote)]
        let record = try HealthRecord(
            id: draft.id,
            memberID: command.memberID,
            sources: draft.sources,
            ocrDocumentObjectID: draft.documentObjectID,
            importState: .confirmed,
            title: try edited(candidates.title, value: command.title),
            organization: try edited(candidates.organization, value: command.organization),
            department: try edited(candidates.department, value: command.department),
            reportType: try edited(candidates.reportType, value: command.reportType),
            dateCandidates: dateSelection.candidates,
            timelineDateCandidateID: dateSelection.selectedID,
            reportedResults: try edited(candidates.reportedResults, value: command.reportedResults),
            conclusion: try edited(candidates.conclusion, value: command.conclusion),
            abnormalItems: try zip(candidates.abnormalItems, command.abnormalItems).compactMap {
                try edited($0.0, value: $0.1)
            },
            notes: notes
        )
        do {
            try await draftStore.confirm(
                draftID: command.draftID,
                expectedRevision: command.expectedRevision,
                record: record
            )
            return AppSnapshot(header: try await reports.header())
        } catch {
            if let disposition = try? await reports.draftDisposition(command.draftID),
               disposition.record == record, disposition.draft == nil {
                return AppSnapshot(header: try await reports.header())
            }
            throw error
        }
    }

    func updateRecord(_ command: UpdateRecordCommand) async throws -> AppSnapshot {
        try await requireStartup()
        return try await withActiveReportOperation { [self] in
            try await performUpdateRecord(command)
        }
    }

    private func performUpdateRecord(_ command: UpdateRecordCommand) async throws -> AppSnapshot {
        let current = try await reports.record(command.recordID)
        guard current.revision == command.expectedRevision else { throw AppServiceError.recordChanged }
        let nextRevision = current.revision.addingReportingOverflow(1)
        guard !nextRevision.overflow else { throw AppServiceError.recordChanged }
        let member = try await reports.member(command.memberID)
        guard !member.isArchived || member.id == current.memberID else { throw AppServiceError.recordUnavailable }
        let dateSelection = try resolvedTimelineDateSelection(
            candidates: current.dateCandidates,
            selection: command.timelineDateSelection
        )
        let notes = try updatedNotes(current.notes, text: command.userNote)
        let updated = try HealthRecord(
            id: current.id,
            memberID: command.memberID,
            sources: current.sources,
            ocrDocumentObjectID: current.ocrDocumentObjectID,
            importState: .confirmed,
            revision: nextRevision.partialValue,
            title: try edited(current.title, value: command.title),
            organization: try edited(current.organization, value: command.organization),
            department: try edited(current.department, value: command.department),
            reportType: try edited(current.reportType, value: command.reportType),
            dateCandidates: dateSelection.candidates,
            timelineDateCandidateID: dateSelection.selectedID,
            reportedResults: try edited(current.reportedResults, value: command.reportedResults),
            conclusion: try edited(current.conclusion, value: command.conclusion),
            abnormalItems: try zip(current.abnormalItems, command.abnormalItems).compactMap {
                try edited($0.0, value: $0.1)
            },
            notes: notes
        )
        do { try await reports.updateRecord(updated, expectedRevision: command.expectedRevision) }
        catch LibraryReportError.staleRevision { throw AppServiceError.recordChanged }
        return AppSnapshot(header: try await reports.header())
    }

    func deleteRecord(id: UUID) async throws -> AppSnapshot {
        try await requireStartup()
        return try await withActiveReportOperation { [self] in
            try await performDeleteRecord(id: id)
        }
    }

    private func performDeleteRecord(id: UUID) async throws -> AppSnapshot {
        let record = try await reports.record(id)
        try await reports.deleteRecord(id, expectedRevision: record.revision)
        return AppSnapshot(header: try await reports.header())
    }

    func deferDraft(_ command: DeferDraftCommand) async throws {
        try await requireStartup()
        return try await withActiveReportOperation { [self] in
            try await performDeferDraft(command)
        }
    }

    private func performDeferDraft(_ command: DeferDraftCommand) async throws {
        let draft = try await reports.draft(command.draftID)
        let document = try refreshedDocument(
            try await draftStore.loadDocument(draftID: command.draftID),
            sources: draft.sources
        )
        let dateSelection = try persistedReviewDateSelection(
            candidates: document.candidates.dateCandidates,
            selection: command.timelineDateSelection,
            detectedDateCandidate: command.detectedDateCandidate
        )
        let savedDocument = ImportDraftDocument(
            blocks: document.blocks,
            candidates: document.candidates,
            candidateExtractionVersion: document.candidateExtractionVersion,
            reviewState: ImportDraftReviewState(
                timelineDateSelection: dateSelection,
                title: command.title,
                organization: command.organization,
                department: command.department,
                reportType: command.reportType,
                reportedResults: command.reportedResults,
                conclusion: command.conclusion,
                abnormalItems: command.abnormalItems,
                userNote: command.userNote
            )
        )
        try await draftStore.saveReview(
            draftID: command.draftID,
            expectedRevision: command.expectedRevision,
            memberID: command.memberID,
            document: savedDocument
        )
    }

    func discardDraft(_ command: DiscardDraftCommand) async throws -> AppSnapshot {
        try await requireStartup()
        return try await withActiveReportOperation { [self] in
            try await performDiscardDraft(command)
        }
    }

    private func performDiscardDraft(_ command: DiscardDraftCommand) async throws -> AppSnapshot {
        do {
            try await draftStore.discard(
                draftID: command.draftID,
                expectedRevision: command.expectedRevision
            )
            return AppSnapshot(header: try await reports.header())
        } catch {
            if let disposition = try? await reports.draftDisposition(command.draftID),
               disposition.draft == nil, disposition.record == nil {
                return AppSnapshot(header: try await reports.header())
            }
            throw error
        }
    }

    func loadOriginal(recordID: UUID, sourceID: UUID, expectedRevision: UInt64, expectedLibrary: LibraryRevision) async throws -> OriginalDocumentPayload {
        try await requireStartup()
        return try await withActiveReportOperation { [self] in
            try await performLoadOriginal(recordID: recordID, sourceID: sourceID, expectedRevision: expectedRevision, expectedLibrary: expectedLibrary)
        }
    }

    private func performLoadOriginal(recordID: UUID, sourceID: UUID, expectedRevision: UInt64, expectedLibrary: LibraryRevision) async throws -> OriginalDocumentPayload {
        let selection = try await reports.recordSelection([recordID])
        guard let record = selection.records.first, record.revision == expectedRevision,
              let source = record.sources.elements.first(where: { $0.id == sourceID }) else { throw AppServiceError.recordUnavailable }
        let value = try await reports.original(recordID: recordID, expectedRevision: expectedRevision, sourceID: sourceID, expectedLibrary: expectedLibrary)
        return originalPayload(source: source, attachment: value.0, data: value.1)
    }

    func importDICOMDirectory(at url: URL) async throws -> DICOMAppImportOutcome {
        guard activeDICOMImportTask == nil else {
            throw DICOMImportError.publicationConflict
        }
        terminalDICOMImportTask = nil
        terminalDICOMImportID = nil
        claimedDICOMImportID = nil
#if DEBUG
        claimedDICOMImportWasActive = false
#endif
        let operationID = UUID()
        let task = Task { [self] in
            try await withActiveDICOMOperation { runtime in
                try await self.requireStartup()
                let result = try await runtime.workflow.importDirectory(
                    url,
                    securityScope: runtime.securityScope
                )
                return try await self.dicomImportOutcome(for: result)
            }
        }
        activeDICOMImportTask = task
        activeDICOMImportID = operationID
        do {
            let outcome = try await task.value
            retainTerminalDICOMImport(task, operationID: operationID)
            return outcome
        } catch {
            retainTerminalDICOMImport(task, operationID: operationID)
            throw error
        }
    }

    func cancelDICOMImport() async throws -> DICOMAppImportOutcome? {
        guard let dicomRuntime else { return nil }
        let task: Task<DICOMAppImportOutcome, Error>
        let operationID: UUID
        if let activeDICOMImportTask, let activeDICOMImportID {
            task = activeDICOMImportTask
            operationID = activeDICOMImportID
        } else if let terminalDICOMImportTask, let terminalDICOMImportID {
            task = terminalDICOMImportTask
            operationID = terminalDICOMImportID
        } else {
            return nil
        }
        guard claimedDICOMImportID != operationID else { return nil }
#if DEBUG
        claimedDICOMImportWasActive = activeDICOMImportID == operationID
#endif
        claimedDICOMImportID = operationID
#if DEBUG
        resumeDICOMImportCancellationClaimWaiters(operationID: operationID)
#endif
        defer { consumeDICOMImport(operationID: operationID) }
        if activeDICOMImportID == operationID {
            do {
                _ = try await dicomRuntime.workflow.cancelCurrentImport()
            } catch {
                // The shared App-level task below owns the canonical terminal
                // result, including publication recovery after workflow errors.
            }
        }
        do {
            return try await task.value
        } catch let error as DICOMImportError where error == .cancelled {
            return nil
        }
    }

#if DEBUG
    func waitUntilCurrentDICOMImportCancellationClaimedForTesting() async -> Bool {
        guard let operationID = activeDICOMImportID ?? terminalDICOMImportID else { return false }
        guard claimedDICOMImportID != operationID else { return claimedDICOMImportWasActive }
        return await withCheckedContinuation { continuation in
            dicomImportCancellationClaimWaiters[operationID, default: []].append(continuation)
        }
    }
#endif

    private func retainTerminalDICOMImport(
        _ task: Task<DICOMAppImportOutcome, Error>,
        operationID: UUID
    ) {
        guard activeDICOMImportID == operationID else { return }
        activeDICOMImportTask = nil
        activeDICOMImportID = nil
        terminalDICOMImportTask = task
        terminalDICOMImportID = operationID
    }

    private func consumeDICOMImport(operationID: UUID) {
        if activeDICOMImportID == operationID {
            activeDICOMImportTask = nil
            activeDICOMImportID = nil
        }
        if terminalDICOMImportID == operationID {
            terminalDICOMImportTask = nil
            terminalDICOMImportID = nil
        }
        if claimedDICOMImportID == operationID {
            claimedDICOMImportID = nil
#if DEBUG
            claimedDICOMImportWasActive = false
#endif
        }
    }

#if DEBUG
    private func resumeDICOMImportCancellationClaimWaiters(operationID: UUID) {
        let waiters = dicomImportCancellationClaimWaiters.removeValue(forKey: operationID) ?? []
        let wasActive = claimedDICOMImportWasActive
        waiters.forEach { $0.resume(returning: wasActive) }
    }
#endif

    private func dicomImportOutcome(
        for result: DICOMImportResult
    ) async throws -> DICOMAppImportOutcome {
        let study = try await studies.details(result.studyID).study
        return DICOMAppImportOutcome(
            studyID: result.studyID,
            destination: study.state == .needsReview ? .review : .timeline,
            wasExisting: result.wasExisting,
            viewableInstanceCount: result.viewableInstanceCount,
            inertObjectCount: result.inertObjectCount,
            ignoredNonDICOMCount: result.ignoredNonDICOMCount,
            ignoredDuplicateCount: result.ignoredDuplicateCount
        )
    }

    func loadDICOMStudyReview(studyID: UUID) async throws -> DICOMStudyReviewContent {
        try await requireStartup()
        return try await withActiveReportOperation { [self] in
            try await performLoadDICOMStudyReview(studyID: studyID)
        }
    }

    private func performLoadDICOMStudyReview(studyID: UUID) async throws -> DICOMStudyReviewContent {
        try await withActiveDICOMOperation { _ in
            try await self.requireStartup()
            return try await self.dicomStudyDetails(studyID: studyID)
        }
    }

    private func dicomStudyDetails(studyID: UUID) async throws -> DICOMStudyReviewContent {
        let details = try await studies.details(studyID)
        let members = LibraryMemberSummary.selectable(try await reports.header().members.filter {
            !$0.isArchived || $0.id == details.study.confirmedMemberID
        }, includeArchived: true)
        let labels = LibraryMemberSummary.labels(members)
        return DICOMStudyReviewContent(viewerContent: DICOMStudyViewerContent(
            study: DICOMStudySummary(study: details.study),
            confirmedMemberLabel: details.study.confirmedMemberID.flatMap { labels[$0] },
            viewableInstanceCount: details.study.viewableInstanceCount,
            inertObjectCount: details.study.retainedObjectCount - details.study.viewableInstanceCount,
            series: details.series.map { DICOMSeriesSummary(id: $0.id, ordinal: $0.ordinal, sliceCount: $0.sliceCount,
                rows: $0.rows, columns: $0.columns, orderingProvenance: $0.orderingProvenance) }), selectableMembers: members)
    }

    func saveDICOMStudy(_ command: SaveDICOMStudyCommand) async throws -> AppSnapshot {
        guard command.effectiveDate.timeIntervalSinceReferenceDate.isFinite,
              let date = ReportDateSemantics.canonicalDate(from: command.effectiveDate) else { throw AppServiceError.invalidReview }
        return try await withActiveDICOMOperation { _ in
            try await self.requireStartup()
            let current = try await self.studies.details(command.studyID).study
            if current.state == .confirmed, current.confirmedMemberID == command.memberID, current.effectiveDate == date {
                return AppSnapshot(header: try await self.reports.header())
            }
            guard current.contentRevision == command.expectedRevision else { throw AppServiceError.recordChanged }
            _ = try await self.studies.confirm(command.studyID, expectedRevision: command.expectedRevision, memberID: command.memberID, effectiveDate: date)
            return AppSnapshot(header: try await self.reports.header())
        }
    }
    func deleteDICOMStudy(id: UUID) async throws -> AppSnapshot {
        try await withActiveDICOMOperation { _ in
            try await self.requireStartup()
            let current = try await self.studies.details(id).study
            try await self.studies.delete(id, expectedRevision: current.contentRevision)
            return AppSnapshot(header: try await self.reports.header())
        }
    }

    private func originalPayload(source: ReportSource, attachment: Attachment, data: Data) -> OriginalDocumentPayload {
        OriginalDocumentPayload(data: data, contentTypeIdentifier: attachment.contentTypeIdentifier,
            sourceID: source.id, attachmentID: source.attachmentID, displayName: source.displayName, pageCount: source.pageCount)
    }

    private func recognizeDocument(
        for draft: ImportDraft
    ) async throws -> ImportDraftDocument {
        let revision = try await reports.header().revision
        var attributedBlocks: [OCRBlock] = []
        for source in draft.sources.elements {
            try Task.checkCancellation()
            let (attachment, data) = try await reports.original(draftID: draft.id, expectedRevision: draft.revision,
                sourceID: source.id, expectedLibrary: revision)
            guard let contentType = UTType(attachment.contentTypeIdentifier) else { throw AppServiceError.invalidReview }
            let kind: ImportedContentKind
            if contentType.conforms(to: .pdf) {
                kind = .pdf
            } else if contentType.conforms(to: .image) {
                kind = .image
            } else {
                throw AppServiceError.invalidReview
            }
            let file = try ValidatedImportedFile(
                data: data,
                kind: kind,
                contentTypeIdentifier: attachment.contentTypeIdentifier,
                sha256Digest: attachment.sha256Digest,
                pageCount: source.pageCount
            )
            let blocks = try await textExtractor.extractText(from: file)
            attributedBlocks.append(contentsOf: try blocks.map { block in
                try block.attributed(to: source, blockID: block.id)
            })
        }
        let candidates = try ReportCandidateExtractor().extract(
            from: attributedBlocks,
            sources: draft.sources
        )
        return try ImportDraftDocument(
            blocks: attributedBlocks,
            candidates: candidates
        ).attributedAndValidated(for: draft.sources)
    }

    private func dateSelectionAfterRecognition(
        _ selection: ImportDraftTimelineDateSelection,
        oldCandidates: [ReportDateCandidate],
        newCandidates: [ReportDateCandidate]
    ) -> ImportDraftTimelineDateSelection {
        guard case .detected(let oldID) = selection else { return selection }
        guard let oldCandidate = oldCandidates.first(where: { $0.id == oldID }),
              let replacement = newCandidates.first(where: {
                  $0.date == oldCandidate.date
                      && $0.kind == oldCandidate.kind
                      && $0.source.originalTranscription == oldCandidate.source.originalTranscription
              }) else {
            return .unknown
        }
        return .detected(replacement.id)
    }



    private func finishStartup(
        _ task: Task<AppSnapshot, Error>,
        attemptID: UUID
    ) async throws -> AppSnapshot {
        do {
            let snapshot = try await task.value
            try await lifecycle?.requireActive()
            if startupAttemptID == attemptID {
                startupCompleted = true
                startupTask = nil
                startupAttemptID = nil
            }
            try Task.checkCancellation()
            return snapshot
        } catch {
            if startupAttemptID == attemptID {
                startupTask = nil
                startupAttemptID = nil
            }
            throw error
        }
    }

    private func requireStartup() async throws {
        try Task.checkCancellation()
        try await lifecycle?.requireActive()
        guard !startupCompleted else { return }
        guard let startupTask, let startupAttemptID else {
            throw AppServiceError.vaultUnavailable
        }
#if DEBUG
        if let startupWaitObserver { await startupWaitObserver() }
#endif
        _ = try await finishStartup(startupTask, attemptID: startupAttemptID)
        try Task.checkCancellation()
    }

    private func requireDICOMRuntime() async throws -> DICOMAppRuntime {
        guard let dicomRuntime else { throw AppServiceError.runtimeUnavailable }
        if let lifecycle = dicomRuntime.lifecycle, !dicomLifecycleRegistered {
            let workflow = dicomRuntime.workflow
            try await lifecycle.register(id: dicomLifecycleRegistrationID) {
                _ = try? await workflow.cancelCurrentImport()
            }
            dicomLifecycleRegistered = true
        }
        return dicomRuntime
    }

    private func withActiveReportOperation<Result: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        guard let lifecycle else { return try await operation() }
        try await registerReportLifecycleIfNeeded(on: lifecycle)
        let operationID = UUID()
        let task = Task<Result, Error> {
            try await lifecycle.withActiveOperation(operation)
        }
        activeReportOperations[operationID] = ActiveReportOperation(
            cancel: { task.cancel() },
            waitForCompletion: { _ = try? await task.value }
        )
        do {
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            activeReportOperations.removeValue(forKey: operationID)
            return result
        } catch {
            activeReportOperations.removeValue(forKey: operationID)
            throw error
        }
    }

    private func registerReportLifecycleIfNeeded(
        on lifecycle: LibraryLifecycleCoordinator
    ) async throws {
        guard !reportLifecycleRegistered else { return }
        try await lifecycle.register(id: reportLifecycleRegistrationID) { [weak self] in
            await self?.cancelAndWaitForReportOperations()
        }
        reportLifecycleRegistered = true
    }

    private func cancelAndWaitForReportOperations() async {
        reportLifecycleRevoked = true
        let startup = startupTask
        startup?.cancel()
        let operations = Array(activeReportOperations.values)
        for operation in operations { operation.cancel() }
        _ = try? await startup?.value
        await withTaskGroup(of: Void.self) { group in
            for operation in operations {
                group.addTask { await operation.waitForCompletion() }
            }
        }
    }

    private func withActiveDICOMOperation<Result: Sendable>(
        _ operation: @escaping @Sendable (DICOMAppRuntime) async throws -> Result
    ) async throws -> Result {
        let runtime = try await requireDICOMRuntime()
        guard let lifecycle = runtime.lifecycle else {
            return try await operation(runtime)
        }
        return try await lifecycle.withActiveOperation {
            try await operation(runtime)
        }
    }

    private func startupIsReady() async -> Bool {
        do {
            try await requireStartup()
            return true
        } catch {
            return false
        }
    }



    private func coordinatedValidation(of url: URL) throws -> ValidatedImportedFile {
        let didStartScope = url.startAccessingSecurityScopedResource()
        defer { if didStartScope { url.stopAccessingSecurityScopedResource() } }

        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var validationResult: Result<ValidatedImportedFile, Error>?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) {
            coordinatedURL in
            validationResult = Result { try validator.validate(fileAt: coordinatedURL) }
        }
        if coordinationError != nil { throw AppServiceError.importFailed }
        guard let validationResult else { throw AppServiceError.importFailed }
        return try validationResult.get()
    }

    private func edited(_ source: SourceField?, value: String) throws -> SourceField? {
        let normalized = value.trimmed
        guard !normalized.isEmpty else { return nil }
        if let source {
            return try source.correctingTranscription(to: normalized)
        }
        return try SourceField.manualEntry(normalized)
    }

    private func refreshedDocument(
        _ document: ImportDraftDocument,
        sources: ReportSources
    ) throws -> ImportDraftDocument {
        guard !document.blocks.isEmpty,
              document.candidateExtractionVersion != ReportCandidateExtractor.extractionVersion else {
            return document
        }
        let stored = document.candidates
        let refreshed = try ReportCandidateExtractor().extract(
            from: document.blocks,
            sources: sources
        )
        return ImportDraftDocument(
            blocks: document.blocks,
            candidates: ReportCandidates(
                memberName: stored.memberName ?? refreshed.memberName,
                organization: stored.organization ?? refreshed.organization,
                department: stored.department ?? refreshed.department,
                reportType: stored.reportType ?? refreshed.reportType,
                title: stored.title ?? refreshed.title,
                dateCandidates: stored.dateCandidates.isEmpty
                    ? refreshed.dateCandidates
                    : stored.dateCandidates,
                reportedResults: stored.reportedResults ?? refreshed.reportedResults,
                conclusion: stored.conclusion ?? refreshed.conclusion,
                abnormalItems: stored.abnormalItems.isEmpty
                    ? refreshed.abnormalItems
                    : stored.abnormalItems
            ),
            candidateExtractionVersion: ReportCandidateExtractor.extractionVersion,
            reviewState: document.reviewState
        )
    }

    private func resolvedTimelineDateSelection(
        candidates: [ReportDateCandidate],
        selection: TimelineDateSelection,
        detectedDateCandidate: ReportDateCandidate? = nil
    ) throws -> (candidates: [ReportDateCandidate], selectedID: ReportDateCandidate.ID?) {
        let detectedCandidates = candidates.filter { $0.source.entryMethod != .manual }
        switch selection {
        case .unknown:
            return (detectedCandidates, nil)
        case .detected(let id):
            guard let matched = detectedCandidates.first(where: { $0.id == id })
                ?? detectedCandidates.first(where: {
                    guard let detectedDateCandidate,
                          detectedDateCandidate.id == id else { return false }
                    return Self.sameDateCandidateContent($0, detectedDateCandidate)
                }) else {
                throw AppServiceError.invalidReview
            }
            return (detectedCandidates, matched.id)
        case .manual(let date):
            let candidate = try manualDateCandidate(for: date)
            return (detectedCandidates + [candidate], candidate.id)
        }
    }

    private func persistedReviewDateSelection(
        candidates: [ReportDateCandidate],
        selection: TimelineDateSelection,
        detectedDateCandidate: ReportDateCandidate?
    ) throws -> ImportDraftTimelineDateSelection {
        switch selection {
        case .unknown:
            return .unknown
        case .detected(let id):
            let resolved = try resolvedTimelineDateSelection(
                candidates: candidates,
                selection: .detected(id),
                detectedDateCandidate: detectedDateCandidate
            )
            guard let selectedID = resolved.selectedID else {
                throw AppServiceError.invalidReview
            }
            return .detected(selectedID)
        case .manual(let date):
            return .manual(try manualDateCandidate(for: date).date)
        }
    }

    private static func sameDateCandidateContent(
        _ lhs: ReportDateCandidate,
        _ rhs: ReportDateCandidate
    ) -> Bool {
        lhs.date == rhs.date && lhs.kind == rhs.kind && lhs.source == rhs.source
    }

    private func manualDateCandidate(for date: Date) throws -> ReportDateCandidate {
        guard let normalized = ReportDateSemantics.canonicalDate(from: date),
              let transcription = ReportDateSemantics.transcription(for: normalized) else {
            throw AppServiceError.invalidReview
        }
        return ReportDateCandidate(
            date: normalized,
            kind: .other,
            source: try SourceField.manualEntry(transcription)
        )
    }

    private func updatedNotes(_ current: [UserNote], text: String) throws -> [UserNote] {
        let normalized = text.trimmed
        var notes = current
        guard !normalized.isEmpty else {
            if !notes.isEmpty { notes.removeFirst() }
            return notes
        }
        let replacement = try UserNote(id: notes.first?.id ?? UUID(), text: normalized)
        if notes.isEmpty {
            notes.append(replacement)
        } else {
            notes[0] = replacement
        }
        return notes
    }

    private static func failureCode(for error: ImportedFileValidationError) -> AppFailureCode {
        switch error {
        case .unsupportedType: .unsupportedFile
        case .lockedPDF: .lockedPDF
        case .fileTooLarge, .pdfPageCountExceeded, .pdfMediaBoxExceeded,
             .rasterDimensionsExceeded, .rasterPixelCountExceeded, .animatedOrMultipageImage:
            .resourceLimit
        case .unreadableFile: .damagedFile
        }
    }
}

private extension AppImportOutcome {
    init(_ outcome: ImportWorkflowOutcome) {
        switch outcome {
        case .needsReview(let id): self = .needsReview(id)
        case .existingRecord(let id): self = .existingRecord(id)
        case .existingDraft(let id): self = .existingDraft(id)
        case .failed: self = .failed(.importFailed)
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
