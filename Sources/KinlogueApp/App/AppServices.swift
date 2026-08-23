import Foundation
import KinlogueCore
import KinloguePlatform
import UniformTypeIdentifiers

struct LiveAppServiceEnvironment {
    let dataService: LiveAppService
    let originalExportService: any OriginalExportServicing
    let destroyService: any VaultDestroyServicing
    let lanInboxService: any LANInboxServicing
    let dicomSliceServiceFactory: @Sendable () -> any DICOMSliceViewing
    let dicomImportMetrics: DICOMImportMetricsRecorder?
    let vault: PlaintextVault
    let lifecycle: LibraryLifecycleCoordinator

    static func makeDefault() throws -> Self {
        try makeDefault(identity: AppRuntimeIdentity.current())
    }

    static func makeDefault(identity: AppRuntimeIdentity) throws -> Self {
        let source = identity.sourceVault
        try VaultParentDirectoryPreparation.ensureParentDirectory(
            for: source.rootURL
        )
        let vault = try PlaintextVault(rootURL: source.rootURL)
        let lifecycle = LibraryLifecycleCoordinator()
        let lanInboxService = LiveLANInboxService(
            rootURL: source.rootURL,
            vault: vault,
            lifecycle: lifecycle
        )
        let destroyService = LifecycleCoordinatedVaultDestroyService(
            lifecycle: lifecycle,
            underlying: PlaintextVaultDestroyService(vault: vault)
        )
        let originalExportService = LiveOriginalExportService(
            vault: vault,
            lifecycle: lifecycle
        )
        let store = VaultImportDraftStore(vault: vault)
        let textExtractor = OnDeviceTextExtractionService()
        let workflow = ImportWorkflow(
            store: store,
            textExtractor: textExtractor
        )
        let acceptanceMetrics: DICOMImportMetricsRecorder?
        let securityScope: DICOMSecurityScopeRequirement
        if case .acceptance = identity.mode {
            acceptanceMetrics = DICOMImportMetricsRecorder()
            securityScope = .notRequiredForTesting
        } else {
            acceptanceMetrics = nil
            securityScope = .required
        }
        let dicomWorkflow = try DICOMImportWorkflow(
            rootURL: source.rootURL,
            vault: vault,
            metrics: acceptanceMetrics
        )
        return Self(
            dataService: LiveAppService(
                vault: vault,
                draftStore: store,
                workflow: workflow,
                textExtractor: textExtractor,
                lifecycle: lifecycle,
                dicomRuntime: DICOMAppRuntime(
                    workflow: dicomWorkflow,
                    lifecycle: lifecycle,
                    securityScope: securityScope
                )
            ),
            originalExportService: originalExportService,
            destroyService: destroyService,
            lanInboxService: lanInboxService,
            dicomSliceServiceFactory: { DICOMSliceService(vault: vault) },
            dicomImportMetrics: acceptanceMetrics,
            vault: vault,
            lifecycle: lifecycle
        )
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

actor PlaintextVaultDestroyService: VaultDestroyServicing {
    private let vault: PlaintextVault

    init(vault: PlaintextVault) {
        self.vault = vault
    }

    func destroyCurrentVault() async throws {
        try await vault.destroy()
    }
}

actor LiveAppService: AppDataServicing, DICOMAppServicing {
    private struct ActiveReportOperation: Sendable {
        let cancel: @Sendable () -> Void
        let waitForCompletion: @Sendable () async -> Void
    }

    private let vault: any VaultStore
    private let draftStore: any ImportDraftStore
    private let workflow: ImportWorkflow
    private let textExtractor: any TextExtractionService
    private let validator: ImportedFileValidator
    private let lifecycle: LibraryLifecycleCoordinator?
    private let dicomRuntime: DICOMAppRuntime?
    private let reportLifecycleRegistrationID = UUID()
    private let dicomLifecycleRegistrationID = UUID()
    private var reportLifecycleRegistered = false
    private var activeReportOperations: [UUID: ActiveReportOperation] = [:]
    private var dicomLifecycleRegistered = false
    private var startupTask: Task<AppSnapshot, Error>?
    private var startupAttemptID: UUID?
    private var startupCompleted: Bool
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

    init(
        vault: any VaultStore,
        draftStore: any ImportDraftStore,
        workflow: ImportWorkflow,
        textExtractor: any TextExtractionService = OnDeviceTextExtractionService(),
        validator: ImportedFileValidator = ImportedFileValidator(),
        startupCompleted: Bool = false,
        lifecycle: LibraryLifecycleCoordinator? = nil,
        dicomRuntime: DICOMAppRuntime? = nil
    ) {
        self.vault = vault
        self.draftStore = draftStore
        self.workflow = workflow
        self.textExtractor = textExtractor
        self.validator = validator
        self.startupCompleted = startupCompleted
        self.lifecycle = lifecycle
        self.dicomRuntime = dicomRuntime
    }

    func bootstrap() async throws -> AppSnapshot {
        try Task.checkCancellation()
        if startupCompleted {
            return Self.snapshot(from: try await vault.loadCatalog())
        }
        if let startupTask, let startupAttemptID {
            return try await finishStartup(startupTask, attemptID: startupAttemptID)
        }

        let vault = self.vault
        let workflow = self.workflow
        let attemptID = UUID()
        let task = Task<AppSnapshot, Error> {
            let initialCatalog: VaultCatalog
            do {
                initialCatalog = try await vault.loadValidatedCatalog()
            } catch VaultError.vaultMissing {
                initialCatalog = try await vault.initialize()
            } catch {
                throw AppServiceError.vaultUnavailable
            }
            let resumableDraftIDs = initialCatalog.importDrafts
                .filter(\.isResumableAfterInterruption)
                .map(\.id)
            _ = try await workflow.resumeInterruptedImports(
                draftIDs: resumableDraftIDs
            )
            return Self.snapshot(from: try await vault.loadCatalog())
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

    func refresh() async throws -> AppSnapshot {
        try await requireStartup()
        return Self.snapshot(from: try await vault.loadCatalog())
    }

    func createMember(
        displayName: String,
        disambiguationLabel: String?
    ) async throws -> AppSnapshot {
        try await requireStartup()
        let member = try FamilyMember(
            displayName: displayName,
            disambiguationLabel: disambiguationLabel
        )
        return try await mutateCatalog(
            { catalog in
                var members = catalog.members
                members.append(member)
                return try catalog.next(members: members)
            },
            isApplied: { catalog, _ in catalog.members.contains(member) }
        )
    }

    func updateMember(_ member: FamilyMember) async throws -> AppSnapshot {
        try await requireStartup()
        return try await mutateCatalog(
            { catalog in
                guard let index = catalog.members.firstIndex(where: { $0.id == member.id }) else {
                    throw AppServiceError.memberUnavailable
                }
                var members = catalog.members
                members[index] = member
                return try catalog.next(members: members)
            },
            isApplied: { catalog, _ in catalog.members.contains(member) }
        )
    }

    func archiveMember(id: FamilyMember.ID) async throws -> AppSnapshot {
        try await requireStartup()
        return try await mutateCatalog(
            { catalog in
                guard let index = catalog.members.firstIndex(where: { $0.id == id }) else {
                    throw AppServiceError.memberUnavailable
                }
                var members = catalog.members
                members[index].isArchived = true
                return try catalog.next(members: members)
            },
            isApplied: { catalog, _ in
                catalog.members.contains(where: { $0.id == id && $0.isArchived })
            }
        )
    }

    func deleteMember(id: FamilyMember.ID) async throws -> AppSnapshot {
        try await requireStartup()
        return try await mutateCatalog(
            { catalog in
                do {
                    return try catalog.deletingMember(id: id)
                } catch CatalogDeletionError.memberNotFound {
                    throw AppServiceError.memberUnavailable
                } catch CatalogDeletionError.memberStillReferenced(
                    let recordCount,
                    let draftCount
                ) {
                    throw AppServiceError.memberStillReferenced(
                        recordCount: recordCount,
                        draftCount: draftCount
                    )
                } catch CatalogDeletionError.memberStillReferencedByDICOMStudy(
                    let studyCount
                ) {
                    throw AppServiceError.memberStillReferencedByDICOMStudy(
                        studyCount: studyCount
                    )
                }
            },
            isApplied: { catalog, _ in
                !catalog.members.contains(where: { $0.id == id })
            }
        )
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
        let workflow = self.workflow
        return try await withActiveReportOperation {
            AppImportOutcome(try await workflow.retry(draftID: id))
        }
    }

    func loadReview(draftID: ImportDraft.ID) async throws -> ImportReviewContent {
        try await requireStartup()
        let snapshot: ImportDraftReviewSnapshot
        do {
            snapshot = try await draftStore.loadReviewSnapshot(draftID: draftID)
        } catch let error as VaultImportDraftStoreError {
            switch error {
            case .draftNotFound, .attachmentNotFound:
                throw AppServiceError.draftUnavailable
            case .documentNotFound, .invalidDraftDocument:
                throw error
            }
        }
        let source = snapshot.draft.sources.first
        return ImportReviewContent(
            draft: snapshot.draft,
            document: try refreshedDocument(
                snapshot.document,
                sources: snapshot.draft.sources
            ),
            members: RecordQuery.selectableMembers(from: snapshot.members),
            original: OriginalDocumentPayload(
                data: snapshot.originalData,
                contentTypeIdentifier: snapshot.attachment.contentTypeIdentifier,
                sourceID: source.id,
                attachmentID: source.attachmentID,
                displayName: source.displayName,
                pageCount: source.pageCount
            )
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
        let catalog = try await vault.loadCatalog()
        guard let draft = catalog.importDrafts.first(where: {
            $0.id == command.draftID
                && $0.state == .needsReview
                && $0.revision == command.expectedRevision
        }), draft.revision < UInt64.max,
        command.memberID == nil || catalog.members.contains(where: {
            $0.id == command.memberID && !$0.isArchived
        }) else {
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
        let recognized = try await recognizeDocument(for: draft)
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

    func loadReviewOriginal(
        draftID: ImportDraft.ID,
        sourceID: ReportSource.ID
    ) async throws -> OriginalDocumentPayload {
        try await requireStartup()
        let snapshot = try await vault.readSnapshot { catalog in
            guard let draft = catalog.importDrafts.first(where: {
                $0.id == draftID && $0.state == .needsReview
            }), let source = draft.sources.elements.first(where: { $0.id == sourceID }) else {
                throw AppServiceError.draftUnavailable
            }
            return [VaultObjectReference(id: source.attachmentID, kind: .attachment)]
        }
        let catalog = snapshot.catalog
        guard let draft = catalog.importDrafts.first(where: {
            $0.id == draftID && $0.state == .needsReview
        }), let source = draft.sources.elements.first(where: { $0.id == sourceID }) else {
            throw AppServiceError.draftUnavailable
        }
        return try originalPayload(
            source: source,
            snapshot: snapshot,
            unavailableError: .draftUnavailable
        )
    }

    func confirmDraft(_ command: ConfirmDraftCommand) async throws -> AppSnapshot {
        try await requireStartup()
        let catalog = try await vault.loadCatalog()
        guard let draft = catalog.importDrafts.first(where: {
            $0.id == command.draftID
                && $0.state == .needsReview
                && $0.revision == command.expectedRevision
        }),
              catalog.members.contains(where: { $0.id == command.memberID && !$0.isArchived }) else {
            throw AppServiceError.invalidReview
        }
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
            return Self.snapshot(from: try await draftStore.confirm(
                draftID: command.draftID,
                expectedRevision: command.expectedRevision,
                record: record
            ))
        } catch {
            if let reconciled = try? await vault.loadCatalog(),
               reconciled.records.contains(record),
               !reconciled.importDrafts.contains(where: { $0.id == command.draftID }) {
                return Self.snapshot(from: reconciled)
            }
            throw error
        }
    }

    func updateRecord(_ command: UpdateRecordCommand) async throws -> AppSnapshot {
        try await requireStartup()
        return try await mutateCatalog(
            { catalog in
                guard let index = catalog.records.firstIndex(where: {
                    $0.id == command.recordID && $0.importState == .confirmed
                }) else { throw AppServiceError.recordUnavailable }
                let current = catalog.records[index]
                guard current.revision == command.expectedRevision else {
                    throw AppServiceError.recordChanged
                }
                let nextRevision = current.revision.addingReportingOverflow(1)
                guard !nextRevision.overflow else { throw AppServiceError.recordChanged }
                guard catalog.members.contains(where: {
                    $0.id == command.memberID
                        && (!$0.isArchived || $0.id == current.memberID)
                }) else { throw AppServiceError.recordUnavailable }
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
                var records = catalog.records
                records[index] = updated
                return try catalog.next(records: records)
            },
            conflictError: { catalog, _ in
                guard let current = catalog.records.first(where: {
                    $0.id == command.recordID
                }) else {
                    return AppServiceError.recordUnavailable
                }
                return current.revision == command.expectedRevision
                    ? nil
                    : AppServiceError.recordChanged
            },
            isApplied: { catalog, intended in
                guard let record = intended.records.first(where: { $0.id == command.recordID }) else {
                    return false
                }
                return catalog.records.contains(record)
            }
        )
    }

    func deleteRecord(id: HealthRecord.ID) async throws -> AppSnapshot {
        try await requireStartup()
        return try await mutateCatalog(
            { catalog in
                do {
                    return try catalog.deletingRecord(id: id)
                } catch CatalogDeletionError.recordNotFound {
                    throw AppServiceError.recordUnavailable
                }
            },
            isApplied: { catalog, _ in
                !catalog.records.contains(where: { $0.id == id })
            }
        )
    }

    func deferDraft(_ command: DeferDraftCommand) async throws {
        try await requireStartup()
        let catalog = try await vault.loadCatalog()
        guard let draft = catalog.importDrafts.first(where: { $0.id == command.draftID }) else {
            throw AppServiceError.draftUnavailable
        }
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
        do {
            return Self.snapshot(from: try await draftStore.discard(
                draftID: command.draftID,
                expectedRevision: command.expectedRevision
            ))
        } catch {
            if let reconciled = try? await vault.loadCatalog(),
               !reconciled.importDrafts.contains(where: { $0.id == command.draftID }),
               !reconciled.records.contains(where: { $0.id == command.draftID }) {
                return Self.snapshot(from: reconciled)
            }
            throw error
        }
    }

    func loadOriginal(
        recordID: HealthRecord.ID,
        sourceID: ReportSource.ID
    ) async throws -> OriginalDocumentPayload {
        try await requireStartup()
        let snapshot = try await vault.readSnapshot { catalog in
            guard let record = catalog.records.first(where: {
                $0.id == recordID && $0.importState == .confirmed
            }), let source = record.sources.elements.first(where: { $0.id == sourceID }) else {
                throw AppServiceError.recordUnavailable
            }
            return [VaultObjectReference(id: source.attachmentID, kind: .attachment)]
        }
        let catalog = snapshot.catalog
        guard let record = catalog.records.first(where: {
            $0.id == recordID && $0.importState == .confirmed
        }), let source = record.sources.elements.first(where: { $0.id == sourceID }) else {
            throw AppServiceError.recordUnavailable
        }
        return try originalPayload(
            source: source,
            snapshot: snapshot,
            unavailableError: .recordUnavailable
        )
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
        let vault = self.vault
        let operationID = UUID()
        let task = Task { [self] in
            try await withActiveDICOMOperation { runtime in
                try await self.requireStartup()
                let result = try await runtime.workflow.importDirectory(
                    url,
                    securityScope: runtime.securityScope
                )
                return try await self.dicomImportOutcome(for: result, vault: vault)
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
        for result: DICOMImportResult,
        vault: any VaultStore
    ) async throws -> DICOMAppImportOutcome {
        let catalog = try await vault.loadCatalog()
        guard let study = catalog.dicomStudies.first(where: {
            $0.id == result.studyID
        }) else {
            throw AppServiceError.dicomStudyUnavailable
        }
        return DICOMAppImportOutcome(
            studyID: result.studyID,
            destination: study.state == .needsReview ? .review : .library,
            wasExisting: result.wasExisting,
            viewableInstanceCount: result.viewableInstanceCount,
            inertObjectCount: result.inertObjectCount,
            ignoredNonDICOMCount: result.ignoredNonDICOMCount,
            ignoredDuplicateCount: result.ignoredDuplicateCount
        )
    }

    func loadDICOMStudyReview(
        studyID: DICOMStudy.ID
    ) async throws -> DICOMStudyReviewContent {
        let vault = self.vault
        return try await withActiveDICOMOperation { _ in
            try await self.requireStartup()
            let details = try await self.dicomStudyDetails(
                studyID: studyID,
                vault: vault
            )
            return DICOMStudyReviewContent(
                viewerContent: details.viewerContent,
                selectableMembers: details.selectableMembers
            )
        }
    }

    private func dicomStudyDetails(
        studyID: DICOMStudy.ID,
        vault: any VaultStore
    ) async throws -> (
        viewerContent: DICOMStudyViewerContent,
        selectableMembers: [FamilyMember]
    ) {
        let snapshot = try await vault.readSnapshot { catalog in
            guard let study = catalog.dicomStudies.first(where: { $0.id == studyID }) else {
                throw AppServiceError.dicomStudyUnavailable
            }
            return [VaultObjectReference(id: study.indexObjectID, kind: .record)]
        }
        let catalog = snapshot.catalog
        guard let study = catalog.dicomStudies.first(where: {
            $0.id == studyID
        }) else {
            throw AppServiceError.dicomStudyUnavailable
        }
        let data = try snapshot.data(for: VaultObjectReference(
            id: study.indexObjectID,
            kind: .record
        ))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let index: DICOMStudyIndex
        do {
            index = try decoder.decode(DICOMStudyIndex.self, from: data)
        } catch {
            throw AppServiceError.dicomStudyUnavailable
        }
        let instancesByID = Dictionary(
            uniqueKeysWithValues: index.instances.map { ($0.id, $0) }
        )
        let series = try index.series.sorted { $0.ordinal < $1.ordinal }.map { item in
            guard let firstID = item.instanceIDs.first,
                  let first = instancesByID[firstID] else {
                throw AppServiceError.dicomStudyUnavailable
            }
            return DICOMSeriesSummary(
                id: item.id,
                ordinal: item.ordinal,
                sliceCount: item.instanceIDs.count,
                rows: first.attributes.rows,
                columns: first.attributes.columns,
                orderingProvenance: item.orderingProvenance
            )
        }
        let selectableMembers = RecordQuery.selectableMembers(
            from: catalog.members.filter {
                !$0.isArchived || $0.id == study.confirmedMemberID
            },
            includeArchived: true
        )
        let memberLabels = RecordQuery.selectionLabels(for: selectableMembers)
        return (
            viewerContent: DICOMStudyViewerContent(
                study: DICOMStudySummary(study: study),
                confirmedMemberLabel: study.confirmedMemberID.flatMap { memberLabels[$0] },
                viewableInstanceCount: index.instances.count,
                inertObjectCount: index.retainedObjects.count {
                    $0.kind == .inertAttachment
                },
                series: series
            ),
            selectableMembers: selectableMembers
        )
    }

    func saveDICOMStudy(_ command: SaveDICOMStudyCommand) async throws -> AppSnapshot {
        guard command.effectiveDate.timeIntervalSinceReferenceDate.isFinite,
              let effectiveDate = ReportDateSemantics.canonicalDate(
                from: command.effectiveDate
              ) else {
            throw AppServiceError.invalidReview
        }
        return try await withActiveDICOMOperation { _ in
            try await self.requireStartup()
            return try await self.mutateCatalog(
                { current in
                    guard current.members.contains(where: {
                        $0.id == command.memberID && !$0.isArchived
                    }), let index = current.dicomStudies.firstIndex(where: {
                        $0.id == command.studyID
                    }) else {
                        throw AppServiceError.invalidReview
                    }
                    let existing = current.dicomStudies[index]
                    if existing.state == .confirmed,
                       existing.confirmedMemberID == command.memberID,
                       existing.effectiveDate == effectiveDate {
                        return current
                    }
                    var studies = current.dicomStudies
                    studies[index] = try existing.reassigning(
                        memberID: command.memberID,
                        effectiveDate: effectiveDate
                    )
                    return try current.next(dicomStudies: studies)
                },
                isApplied: { catalog, _ in
                    catalog.dicomStudies.contains(where: {
                        $0.id == command.studyID
                            && $0.state == .confirmed
                            && $0.confirmedMemberID == command.memberID
                            && $0.effectiveDate == effectiveDate
                    })
                }
            )
        }
    }

    func deleteDICOMStudy(id: DICOMStudy.ID) async throws -> AppSnapshot {
        try await withActiveDICOMOperation { _ in
            try await self.requireStartup()
            return try await self.mutateCatalog(
                { catalog in
                    do {
                        return try catalog.deletingDICOMStudy(id: id)
                    } catch CatalogDeletionError.dicomStudyNotFound {
                        throw AppServiceError.dicomStudyUnavailable
                    }
                },
                removedDICOMStudyIDs: [id],
                isApplied: { catalog, _ in
                    !catalog.dicomStudies.contains(where: { $0.id == id })
                }
            )
        }
    }

    private func originalPayload(
        source: ReportSource,
        snapshot: VaultReadSnapshot,
        unavailableError: AppServiceError
    ) throws -> OriginalDocumentPayload {
        let catalog = snapshot.catalog
        guard let attachment = catalog.attachments.first(where: {
            $0.id == source.attachmentID
        }) else { throw unavailableError }
        let data = try snapshot.data(for: VaultObjectReference(
            id: attachment.id,
            kind: .attachment
        ))
        return OriginalDocumentPayload(
            data: data,
            contentTypeIdentifier: attachment.contentTypeIdentifier,
            sourceID: source.id,
            attachmentID: source.attachmentID,
            displayName: source.displayName,
            pageCount: source.pageCount
        )
    }

    private func recognizeDocument(
        for draft: ImportDraft
    ) async throws -> ImportDraftDocument {
        let snapshot = try await vault.readSnapshot { catalog in
            guard catalog.importDrafts.contains(draft) else {
                throw AppServiceError.invalidReview
            }
            let attachmentIDs = Set(draft.sources.attachmentIDs)
            guard attachmentIDs.allSatisfy({ id in
                catalog.attachments.contains(where: { $0.id == id })
            }) else { throw AppServiceError.invalidReview }
            return attachmentIDs.map {
                VaultObjectReference(id: $0, kind: .attachment)
            }
        }
        let catalog = snapshot.catalog
        var attributedBlocks: [OCRBlock] = []
        for source in draft.sources.elements {
            try Task.checkCancellation()
            guard let attachment = catalog.attachments.first(where: {
                $0.id == source.attachmentID
            }), let contentType = UTType(attachment.contentTypeIdentifier) else {
                throw AppServiceError.invalidReview
            }
            let kind: ImportedContentKind
            if contentType.conforms(to: .pdf) {
                kind = .pdf
            } else if contentType.conforms(to: .image) {
                kind = .image
            } else {
                throw AppServiceError.invalidReview
            }
            let data = try snapshot.data(for: VaultObjectReference(
                id: attachment.id,
                kind: .attachment
            ))
            let file = try ValidatedImportedFile(
                data: data,
                kind: kind,
                contentTypeIdentifier: attachment.contentTypeIdentifier,
                sha256Digest: attachment.sha256Digest,
                pageCount: source.pageCount
            )
            let blocks = try await textExtractor.extractText(from: file)
            attributedBlocks.append(contentsOf: try blocks.map { block in
                try OCRBlock(
                    id: block.id,
                    sourceID: source.id,
                    attachmentID: source.attachmentID,
                    filePageNumber: block.filePageNumber,
                    text: block.text,
                    boundingBox: block.boundingBox,
                    confidence: block.confidence,
                    method: block.method,
                    engineVersion: block.engineVersion
                )
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

    private func mutateCatalog(
        _ transform: (VaultCatalog) throws -> VaultCatalog,
        removedDICOMStudyIDs: Set<DICOMStudy.ID> = [],
        conflictError: (VaultCatalog, VaultCatalog) -> (any Error)? = { _, _ in nil },
        isApplied: (VaultCatalog, VaultCatalog) -> Bool
    ) async throws -> AppSnapshot {
        let current = try await vault.loadCatalog()
        let next = try transform(current)
        if next == current { return Self.snapshot(from: current) }
        do {
            let committed = try await vault.commit(try VaultCommitRequest(
                expectedGeneration: current.generation,
                catalog: next,
                writes: [],
                removedDICOMStudyIDs: removedDICOMStudyIDs
            ))
            return Self.snapshot(from: committed)
        } catch {
            if let reconciled = try? await vault.loadCatalog() {
                if isApplied(reconciled, next) {
                    return Self.snapshot(from: reconciled)
                }
                if let conflict = conflictError(reconciled, next) {
                    throw conflict
                }
            }
            throw error
        }
    }

    private func finishStartup(
        _ task: Task<AppSnapshot, Error>,
        attemptID: UUID
    ) async throws -> AppSnapshot {
        do {
            let snapshot = try await task.value
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
        let operations = Array(activeReportOperations.values)
        for operation in operations { operation.cancel() }
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

    private static func snapshot(from catalog: VaultCatalog) -> AppSnapshot {
        AppSnapshot(
            generation: catalog.generation,
            members: catalog.members,
            records: catalog.records.filter { $0.importState == .confirmed },
            drafts: catalog.importDrafts.map(DraftSummary.init),
            dicomStudies: catalog.dicomStudies.map(DICOMStudySummary.init)
        )
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

private extension VaultCatalog {
    func next(members: [FamilyMember]) throws -> VaultCatalog {
        try advancing(members: members)
    }

    func next(records: [HealthRecord]) throws -> VaultCatalog {
        try advancing(records: records)
    }

    func next(dicomStudies: [DICOMStudy]) throws -> VaultCatalog {
        try advancing(dicomStudies: dicomStudies)
    }

    private func advancing(
        members: [FamilyMember]? = nil,
        records: [HealthRecord]? = nil,
        dicomStudies: [DICOMStudy]? = nil
    ) throws -> VaultCatalog {
        try VaultCatalog(
            formatVersion: formatVersion,
            vaultID: vaultID,
            generation: try VaultGeneration.successor(of: generation),
            members: members ?? self.members,
            records: records ?? self.records,
            attachments: attachments,
            importDrafts: importDrafts,
            dicomStudies: dicomStudies ?? self.dicomStudies
        )
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
