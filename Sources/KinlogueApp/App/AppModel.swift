import Foundation
import KinlogueCore
import KinloguePlatform

enum AppPhase: Equatable {
    case loading
    case ready
    case locked
    case failed
    case changingVault
    case restartRequired
    case vaultDeleted
}

struct AppBanner: Equatable, Identifiable {
    let id = UUID()
    let message: String
}

struct ReviewDraftPresentation: Equatable, Identifiable {
    let id: ImportDraft.ID
}

struct OriginalViewerPresentation: Equatable, Identifiable {
    let id: HealthRecord.ID
}

struct DICOMStudyReviewPresentation: Equatable, Identifiable {
    let id: DICOMStudy.ID
}

enum UpdateRecordResult: Equatable {
    case saved
    case recordChanged(latest: HealthRecord?)
    case failed
}

@MainActor
final class AppModel: ObservableObject {
    private enum RecordDetailState {
        case empty
        case loading(recordID: HealthRecord.ID)
        case loaded(
            record: HealthRecord,
            sourceID: ReportSource.ID,
            original: OriginalDocumentPayload?
        )
    }

    private let service: any AppDataServicing
    private let dicomService: any DICOMAppServicing
    private let dicomSliceServiceFactory: @Sendable () -> any DICOMSliceViewing
    private let dicomViewerRegistry: DICOMViewerRegistry
    private let onDurableStateChanged: @MainActor @Sendable () -> Void
    private var allRecords: [HealthRecord] = []
    private var membersByID: [FamilyMember.ID: FamilyMember] = [:]
    private var memberLabelsByID: [FamilyMember.ID: String] = [:]
    private var appliedCatalogGeneration: UInt64 = 0
    private var stateRequestID: UInt64 = 0
    private var originalLoadTask: Task<Void, Never>?
    private var originalLoadID: UUID?
    private var vaultLifecycleIsLocked = false
    private var shouldPresentDICOMFolderPickerAfterSheetDismissal = false
    private var deferredBanner: AppBanner?
    private var pendingAutomaticReviewID: ImportDraft.ID?
    private var pendingDiscardDraftCommand: DiscardDraftCommand?
    private var activeDICOMStudyReviewModel: DICOMStudyReviewModel?
    let comparisonModel: ComparisonModel
    let dicomImportModel: DICOMImportModel
    let dicomLibraryModel: DICOMLibraryModel
    let originalExportModel: OriginalExportModel

    @Published private(set) var phase: AppPhase = .loading
    @Published private(set) var members: [FamilyMember] = []
    @Published var selectedMemberID: FamilyMember.ID? {
        didSet {
            rebuildTimeline()
            rebuildSearch()
            clearSelection()
        }
    }
    @Published private(set) var timelineSections: [AppTimelineSection] = []
    @Published private(set) var searchResults: [HealthRecord] = []
    @Published var searchText = "" { didSet { rebuildSearch() } }
    @Published private(set) var reviewQueue: [DraftSummary] = []
    @Published private(set) var backgroundDrafts: [DraftSummary] = []
    @Published private var recordDetailState: RecordDetailState = .empty
    @Published private(set) var isOriginalLoading = false
    @Published var isImporterPresented = false
    @Published var isDICOMFolderPickerPresented = false
    @Published var isDICOMImportPresented = false
    @Published var reviewingDraft: ReviewDraftPresentation?
    @Published var reviewingDICOMStudy: DICOMStudyReviewPresentation?
    @Published var isMemberEditorPresented = false
    @Published var editingMember: FamilyMember?
    @Published var editingRecord: HealthRecord?
    @Published var viewingOriginal: OriginalViewerPresentation?
    @Published var isVaultDeletionPresented = false
    @Published var isOriginalExportPresented = false
    @Published var pendingDeleteRecordID: HealthRecord.ID?
    @Published var pendingDeleteMemberID: FamilyMember.ID?
    @Published var pendingDiscardDraftID: ImportDraft.ID?
    @Published private(set) var busyDraftIDs: Set<ImportDraft.ID> = []
    @Published var banner: AppBanner?
    @Published private(set) var searchFocusRequestID = 0

    init(
        service: any AppDataServicing,
        originalExportService: any OriginalExportServicing = UnavailableOriginalExportService(),
        dicomService: any DICOMAppServicing = UnavailableAppService(),
        dicomSliceServiceFactory: @escaping @Sendable () -> any DICOMSliceViewing = {
            UnavailableDICOMSliceService()
        },
        dicomViewerRegistry: DICOMViewerRegistry = DICOMViewerRegistry(),
        onDurableStateChanged: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        self.service = service
        self.dicomService = dicomService
        self.dicomSliceServiceFactory = dicomSliceServiceFactory
        self.dicomViewerRegistry = dicomViewerRegistry
        self.onDurableStateChanged = onDurableStateChanged
        comparisonModel = ComparisonModel(service: service)
        dicomImportModel = DICOMImportModel(service: dicomService)
        dicomLibraryModel = DICOMLibraryModel()
        originalExportModel = OriginalExportModel(service: originalExportService)
    }

    var selectedRecord: HealthRecord? {
        guard case .loaded(let record, _, _) = recordDetailState else { return nil }
        return record
    }

    var reviewDraftID: ImportDraft.ID? {
        reviewingDraft?.id
    }

    private var hasModalPresentation: Bool {
        isImporterPresented
            || isDICOMFolderPickerPresented
            || isDICOMImportPresented
            || reviewingDraft != nil
            || reviewingDICOMStudy != nil
            || isMemberEditorPresented
            || editingMember != nil
            || editingRecord != nil
            || viewingOriginal != nil
            || isOriginalExportPresented
            || isVaultDeletionPresented
            || comparisonModel.isPresented
            || pendingDeleteRecordID != nil
            || pendingDeleteMemberID != nil
            || pendingDiscardDraftID != nil
    }

    var hasBlockingPresentation: Bool {
        hasModalPresentation || banner != nil
    }

    var selectedRecordID: HealthRecord.ID? {
        switch recordDetailState {
        case .empty:
            nil
        case .loading(let recordID):
            recordID
        case .loaded(let record, _, _):
            record.id
        }
    }

    var originalDocument: OriginalDocumentPayload? {
        guard case .loaded(_, _, let original) = recordDetailState else { return nil }
        return original
    }

    var originalSources: ReportSources? {
        selectedRecord?.sources
    }

    var selectedOriginalSourceID: ReportSource.ID? {
        guard case .loaded(_, let sourceID, _) = recordDetailState else { return nil }
        return sourceID
    }

    func start() async {
        guard !vaultLifecycleIsLocked else { return }
        let requestID = beginStateRequest()
        phase = .loading
        await dicomViewerRegistry.withWholeVaultRevocation { [self] in
            guard requestID == stateRequestID, !vaultLifecycleIsLocked else { return }
            clearSensitiveState()
            do {
                let snapshot = try await service.bootstrap()
                guard requestID == stateRequestID, !vaultLifecycleIsLocked else { return }
                apply(snapshot)
                phase = .ready
            } catch AppServiceError.vaultUnavailable {
                guard requestID == stateRequestID, !vaultLifecycleIsLocked else { return }
                phase = .locked
            } catch {
                guard requestID == stateRequestID, !vaultLifecycleIsLocked else { return }
                phase = .failed
            }
        }
    }

    func refresh() async {
        guard !vaultLifecycleIsLocked else { return }
        let requestID = beginStateRequest()
        do {
            let snapshot = try await service.refresh()
            guard requestID == stateRequestID else { return }
            guard snapshot.generation >= appliedCatalogGeneration else { return }
            if appliedCatalogGeneration != 0,
               snapshot.generation > appliedCatalogGeneration {
                phase = .loading
                await dicomViewerRegistry.withWholeVaultRevocation { [self] in
                    guard requestID == stateRequestID, !vaultLifecycleIsLocked else { return }
                    apply(snapshot)
                    phase = .ready
                }
                return
            }
            guard requestID == stateRequestID, !vaultLifecycleIsLocked else { return }
            apply(snapshot)
            phase = .ready
        } catch {
            guard requestID == stateRequestID else { return }
            phase = .locked
            await dicomViewerRegistry.withWholeVaultRevocation { [self] in
                guard requestID == stateRequestID, !vaultLifecycleIsLocked else { return }
                clearSensitiveState()
                phase = .locked
            }
        }
    }

    func createMember(displayName: String, disambiguationLabel: String?) async -> Bool {
        do {
            await applyAfterRevokingStaleDICOMViewers(try await service.createMember(
                displayName: displayName,
                disambiguationLabel: disambiguationLabel
            ))
            return true
        } catch {
            return false
        }
    }

    func updateMember(_ member: FamilyMember) async -> Bool {
        do {
            await applyAfterRevokingStaleDICOMViewers(try await service.updateMember(member))
            return true
        } catch {
            return false
        }
    }

    func archiveMember(_ member: FamilyMember) async {
        do {
            await applyAfterRevokingStaleDICOMViewers(
                try await service.archiveMember(id: member.id)
            )
        } catch {
            reportBanner(AppLocalization.string("无法归档家庭成员"))
        }
    }

    func requestDeleteMember(_ member: FamilyMember) {
        guard !hasBlockingPresentation,
              members.contains(where: { $0.id == member.id }) else { return }
        pendingDeleteMemberID = member.id
    }

    func confirmDeleteMember(id: FamilyMember.ID) async {
        if pendingDeleteMemberID == id { pendingDeleteMemberID = nil }
        do {
            await applyAfterRevokingStaleDICOMViewers(
                try await service.deleteMember(id: id)
            )
        } catch AppServiceError.memberStillReferenced(let recordCount, let draftCount) {
            reportBanner(AppLocalization.string("该成员仍关联 \(recordCount) 条记录和 \(draftCount) 份草稿。请先重分配这些内容，或逐条删除后再试。"))
        } catch AppServiceError.memberStillReferencedByDICOMStudy(let studyCount) {
            reportBanner(AppLocalization.string("该成员仍关联 \(studyCount) 项医学影像检查。请先重分配或删除这些检查后再试。"))
        } catch {
            reportBanner(AppLocalization.string("无法删除家庭成员"))
        }
    }

    func presentImporter() {
        guard phase == .ready, !hasBlockingPresentation else { return }
        isImporterPresented = true
    }

    func presentDICOMImport() {
        guard phase == .ready, !hasBlockingPresentation else { return }
        dicomImportModel.beginSelection()
        isDICOMFolderPickerPresented = true
    }

    func retryDICOMImportSelection() {
        guard phase == .ready,
              isDICOMImportPresented,
              dicomImportModel.phase != .importing,
              dicomImportModel.phase != .cancelling else { return }
        shouldPresentDICOMFolderPickerAfterSheetDismissal = true
        isDICOMImportPresented = false
    }

    func dicomImportPresentationDidEnd() {
        guard shouldPresentDICOMFolderPickerAfterSheetDismissal else {
            presentationDidEnd()
            return
        }
        shouldPresentDICOMFolderPickerAfterSheetDismissal = false
        guard phase == .ready else { return }
        dicomImportModel.beginSelection()
        isDICOMFolderPickerPresented = true
    }

    func handleDICOMImporterResult(_ selection: Result<[URL], Error>) async {
        guard phase == .ready, !vaultLifecycleIsLocked else { return }
        if isDICOMFolderPickerPresented {
            isDICOMFolderPickerPresented = false
        }
        if dicomImportModel.disposition(for: selection) == .cancelled {
            if isDICOMImportPresented {
                isDICOMImportPresented = false
            }
            dicomImportModel.clear()
            presentationDidEnd()
            return
        }

        if !isDICOMImportPresented {
            isDICOMImportPresented = true
        }
        await dicomImportModel.handleImporterResult(selection)
    }

    func presentDICOMReview(_ id: DICOMStudy.ID) {
        guard phase == .ready,
              !hasBlockingPresentation,
              dicomLibraryModel.studies.contains(where: { $0.id == id }) else { return }
        reviewingDICOMStudy = DICOMStudyReviewPresentation(id: id)
    }

    func dicomViewerStudyID(for id: DICOMStudy.ID) -> DICOMStudy.ID? {
        guard phase == .ready,
              dicomLibraryModel.studies.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    func finishDICOMImport() async -> DICOMAppImportOutcome? {
        isDICOMImportPresented = false
        let result = dicomImportModel.takeResult()
        await refresh()
        guard phase == .ready, let result else { return nil }
        switch result.destination {
        case .review:
            presentDICOMReview(result.studyID)
        case .library:
            dicomLibraryModel.select(result.studyID)
        }
        return result
    }

    func presentReviewDraft(_ id: ImportDraft.ID) {
        guard phase == .ready,
              !hasBlockingPresentation,
              reviewQueue.contains(where: { $0.id == id }) else { return }
        reviewingDraft = ReviewDraftPresentation(id: id)
    }

    func presentNewMemberEditor() {
        guard phase == .ready, !hasBlockingPresentation else { return }
        isMemberEditorPresented = true
    }

    func presentMemberEditor(_ member: FamilyMember) {
        guard phase == .ready,
              !hasBlockingPresentation,
              members.contains(where: { $0.id == member.id && !$0.isArchived }) else { return }
        editingMember = member
    }

    func presentRecordEditor() {
        guard phase == .ready,
              !hasBlockingPresentation,
              let selectedRecord else { return }
        editingRecord = selectedRecord
    }

    func presentOriginalViewer() {
        guard phase == .ready,
              !hasBlockingPresentation,
              let selectedRecord,
              originalDocument != nil else { return }
        viewingOriginal = OriginalViewerPresentation(id: selectedRecord.id)
    }

    func presentVaultDeletion() {
        guard phase == .ready, !hasBlockingPresentation else { return }
        isVaultDeletionPresented = true
    }

    func presentOriginalExport() {
        guard phase == .ready, !hasBlockingPresentation else { return }
        originalExportModel.begin()
        isOriginalExportPresented = true
    }

    func toggleComparisonSelection() {
        guard phase == .ready else { return }
        if comparisonModel.isSelecting {
            comparisonModel.cancelSelection()
        } else {
            guard !hasBlockingPresentation else { return }
            comparisonModel.startSelection()
        }
    }

    func openComparison() async {
        guard phase == .ready,
              !hasBlockingPresentation,
              comparisonModel.canCompare else { return }
        await comparisonModel.openComparison()
    }

    func dismissBanner() {
        banner = nil
        presentationDidEnd()
    }

    func presentationDidEnd() {
        guard !hasModalPresentation, banner == nil else { return }
        if let deferredBanner {
            self.deferredBanner = nil
            banner = deferredBanner
            return
        }
        guard phase == .ready else { return }
        guard let pendingAutomaticReviewID else { return }
        self.pendingAutomaticReviewID = nil
        guard reviewQueue.contains(where: { $0.id == pendingAutomaticReviewID }) else { return }
        reviewingDraft = ReviewDraftPresentation(id: pendingAutomaticReviewID)
    }

    func requestSearchFocus() {
        guard phase == .ready else { return }
        searchFocusRequestID += 1
    }

    func handleImporterResult(_ result: Result<[URL], Error>) async {
        isImporterPresented = false
        defer { presentationDidEnd() }
        let urls: [URL]
        switch result {
        case .success(let selected):
            urls = selected
        case .failure(let error as CocoaError) where error.code == .userCancelled:
            return
        case .failure:
            reportBanner(AppLocalization.string("没有读取所选文件"))
            return
        }
        guard !urls.isEmpty else { return }

        var nextReviewID: ImportDraft.ID?
        for url in urls {
            do {
                switch try await service.importFile(at: url) {
                case .needsReview(let id), .existingDraft(let id):
                    nextReviewID = nextReviewID ?? id
                case .existingRecord(let id):
                    await selectRecord(id)
                case .failed(let code):
                    reportBanner(Self.importMessage(for: code))
                }
            } catch {
                reportBanner(AppLocalization.string("导入未完成，可以稍后重试"))
            }
        }
        await refresh()
        if let nextReviewID { queueAutomaticReview(nextReviewID) }
    }

    func retryDraft(_ id: ImportDraft.ID) async {
        guard busyDraftIDs.insert(id).inserted else { return }
        defer {
            busyDraftIDs.remove(id)
            presentationDidEnd()
        }
        do {
            let outcome = try await service.retryDraft(id: id)
            await refresh()
            guard phase == .ready else { return }
            switch outcome {
            case .needsReview(let reviewID), .existingDraft(let reviewID):
                queueAutomaticReview(reviewID)
            case .existingRecord(let recordID):
                await selectRecord(recordID)
            case .failed(let code):
                reportBanner(Self.importMessage(for: code))
            }
        } catch {
            reportBanner(AppLocalization.string("重试未完成，可以稍后再试"))
        }
    }

    func requestDiscardDraft(_ id: ImportDraft.ID) {
        guard !hasBlockingPresentation,
              let draft = backgroundDrafts.first(where: {
                  $0.id == id && $0.state == .failed
              }) else { return }
        pendingDiscardDraftCommand = DiscardDraftCommand(
            draftID: id,
            expectedRevision: draft.revision
        )
        pendingDiscardDraftID = id
    }

    func confirmDiscardDraft(id: ImportDraft.ID) async {
        guard let command = pendingDiscardDraftCommand,
              command.draftID == id,
              busyDraftIDs.insert(id).inserted else { return }
        defer {
            busyDraftIDs.remove(id)
            if pendingDiscardDraftCommand?.draftID == id {
                pendingDiscardDraftCommand = nil
            }
        }
        do {
            await applyAfterRevokingStaleDICOMViewers(
                try await service.discardDraft(command)
            )
            if pendingDiscardDraftID == id { pendingDiscardDraftID = nil }
        } catch {
            reportBanner(AppLocalization.string("无法放弃这份导入"))
        }
    }

    func selectRecord(_ id: HealthRecord.ID) async {
        guard let record = allRecords.first(where: {
            $0.id == id && $0.importState == .confirmed
        }) else { return }
        await loadOriginal(
            for: record,
            sourceID: record.sources.first.id,
            isInitialSelection: true
        )
    }

    func selectOriginalSource(_ sourceID: ReportSource.ID) async {
        guard let record = selectedRecord,
              record.sources.elements.contains(where: { $0.id == sourceID }),
              sourceID != selectedOriginalSourceID else { return }
        await loadOriginal(
            for: record,
            sourceID: sourceID,
            isInitialSelection: false
        )
    }

    private func loadOriginal(
        for record: HealthRecord,
        sourceID: ReportSource.ID,
        isInitialSelection: Bool
    ) async {
        originalLoadTask?.cancel()
        let loadID = UUID()
        originalLoadID = loadID
        isOriginalLoading = true
        if isInitialSelection {
            recordDetailState = .loading(recordID: record.id)
        } else {
            recordDetailState = .loaded(
                record: record,
                sourceID: sourceID,
                original: nil
            )
        }
        let service = service
        originalLoadTask = Task { [weak self] in
            do {
                let payload = try await service.loadOriginal(
                    recordID: record.id,
                    sourceID: sourceID
                )
                try Task.checkCancellation()
                guard let self, self.originalLoadID == loadID else { return }
                let currentRecord = self.allRecords.first(where: { $0.id == record.id })
                    ?? record
                self.recordDetailState = .loaded(
                    record: currentRecord,
                    sourceID: sourceID,
                    original: payload
                )
                self.isOriginalLoading = false
            } catch is CancellationError {
                // Changing selection deliberately releases this payload.
            } catch {
                if let self, self.originalLoadID == loadID {
                    let currentRecord = self.allRecords.first(where: { $0.id == record.id })
                        ?? record
                    self.recordDetailState = .loaded(
                        record: currentRecord,
                        sourceID: sourceID,
                        original: nil
                    )
                    self.isOriginalLoading = false
                    self.reportBanner(AppLocalization.string("原件暂时无法打开"))
                }
            }
        }
        await originalLoadTask?.value
    }

    func clearSelection() {
        originalLoadTask?.cancel()
        originalLoadTask = nil
        originalLoadID = nil
        isOriginalLoading = false
        recordDetailState = .empty
        editingRecord = nil
        viewingOriginal = nil
    }

    func requestDeleteRecord(_ record: HealthRecord) {
        guard !hasBlockingPresentation,
              allRecords.contains(where: {
            $0.id == record.id && $0.importState == .confirmed
        }) else { return }
        pendingDeleteRecordID = record.id
    }

    func confirmDeleteRecord(id: HealthRecord.ID) async {
        if pendingDeleteRecordID == id { pendingDeleteRecordID = nil }
        if selectedRecord?.id == id {
            clearSelection()
        }
        do {
            await applyAfterRevokingStaleDICOMViewers(
                try await service.deleteRecord(id: id)
            )
        } catch {
            reportBanner(AppLocalization.string("无法删除这条记录"))
        }
    }

    func member(for record: HealthRecord) -> FamilyMember? {
        membersByID[record.memberID]
    }

    func memberLabel(for record: HealthRecord) -> String {
        memberLabelsByID[record.memberID]
            ?? member(for: record)?.displayName
            ?? AppLocalization.string("家庭成员")
    }

    func saveMember(
        existing: FamilyMember?,
        displayName: String,
        disambiguationLabel: String?
    ) async -> Bool {
        guard let existing else {
            return await createMember(
                displayName: displayName,
                disambiguationLabel: disambiguationLabel
            )
        }
        do {
            let updated = try FamilyMember(
                id: existing.id,
                displayName: displayName,
                disambiguationLabel: disambiguationLabel,
                isArchived: existing.isArchived
            )
            return await updateMember(updated)
        } catch {
            return false
        }
    }

    func makeReviewModel(draftID: ImportDraft.ID) -> ImportReviewModel {
        ImportReviewModel(draftID: draftID, service: service)
    }

    func makeDICOMStudyReviewModel(studyID: DICOMStudy.ID) -> DICOMStudyReviewModel {
        if let activeDICOMStudyReviewModel,
           activeDICOMStudyReviewModel.studyID == studyID {
            return activeDICOMStudyReviewModel
        }
        let model = DICOMStudyReviewModel(
            studyID: studyID,
            service: dicomService,
            onSnapshotChanged: { [weak self] snapshot in
                await self?.applyAfterRevokingStaleDICOMViewers(snapshot)
            },
            onStudyMetadataChanged: { [weak self] studyID in
                await self?.dicomViewerRegistry.revoke(studyID: studyID)
            },
            onStudyDeletionBegan: { [weak self] studyID in
                await self?.dicomViewerRegistry.revoke(studyID: studyID)
            }
        )
        activeDICOMStudyReviewModel = model
        return model
    }

    func makeDICOMStudyViewerModel(
        studyID: DICOMStudy.ID,
        initialContent: DICOMStudyViewerContent? = nil
    ) -> DICOMStudyViewerModel {
        DICOMStudyViewerModel(
            studyID: studyID,
            metadataService: dicomService,
            sliceService: dicomSliceServiceFactory(),
            initialContent: initialContent,
            viewerRegistry: dicomViewerRegistry
        )
    }

    func dismissDICOMReviewIfAllowed() {
        guard reviewingDICOMStudy != nil,
              activeDICOMStudyReviewModel?.allowsDismissal == true else { return }
        reviewingDICOMStudy = nil
    }

    func dicomReviewPresentationDidEnd() {
        activeDICOMStudyReviewModel?.clear()
        activeDICOMStudyReviewModel = nil
        presentationDidEnd()
    }

    func updateRecord(_ command: UpdateRecordCommand) async -> UpdateRecordResult {
        do {
            let existingOriginal = originalDocument
            let existingSourceID = selectedOriginalSourceID
            await applyAfterRevokingStaleDICOMViewers(
                try await service.updateRecord(command)
            )
            if let updatedRecord = allRecords.first(where: { $0.id == command.recordID }) {
                let sourceID = existingSourceID ?? updatedRecord.sources.first.id
                if updatedRecord.sources.elements.contains(where: { $0.id == sourceID }) {
                    recordDetailState = .loaded(
                        record: updatedRecord,
                        sourceID: sourceID,
                        original: existingOriginal
                    )
                }
            }
            return .saved
        } catch AppServiceError.recordChanged {
            do {
                await applyAfterRevokingStaleDICOMViewers(try await service.refresh())
                let latest = allRecords.first(where: {
                    $0.id == command.recordID && $0.revision != command.expectedRevision
                })
                return .recordChanged(latest: latest)
            } catch {
                return .recordChanged(latest: nil)
            }
        } catch {
            return .failed
        }
    }

    /// Invalidates every outstanding UI request before a whole-vault switch
    /// starts. Once entered, only a process restart may reopen ordinary vault
    /// access; a late response from an older request must never repopulate the
    /// cleared health data.
    func beginDestructiveVaultLifecycle() async {
        guard !vaultLifecycleIsLocked else { return }
        vaultLifecycleIsLocked = true
        _ = beginStateRequest()
        clearSensitiveState()
        phase = .changingVault
        await dicomViewerRegistry.revokeAll()
    }

    func requireRestartAfterVaultLifecycle() {
        vaultLifecycleIsLocked = true
        _ = beginStateRequest()
        clearSensitiveState()
        phase = .restartRequired
    }

    func finishVaultDeletion() {
        vaultLifecycleIsLocked = true
        _ = beginStateRequest()
        clearSensitiveState()
        phase = .vaultDeleted
    }

    private func apply(_ snapshot: AppSnapshot) {
        guard !vaultLifecycleIsLocked else { return }
        guard snapshot.generation >= appliedCatalogGeneration else { return }
        let previousGeneration = appliedCatalogGeneration
        appliedCatalogGeneration = snapshot.generation
        members = snapshot.members
        membersByID = Dictionary(uniqueKeysWithValues: snapshot.members.map { ($0.id, $0) })
        memberLabelsByID = RecordQuery.selectionLabels(for: snapshot.members)
        allRecords = snapshot.records
        reviewQueue = snapshot.drafts.filter { $0.state == .needsReview }
        backgroundDrafts = snapshot.drafts.filter { $0.state != .needsReview }
        dicomLibraryModel.update(studies: snapshot.dicomStudies, members: snapshot.members)
        if let pendingAutomaticReviewID,
           !reviewQueue.contains(where: { $0.id == pendingAutomaticReviewID }) {
            self.pendingAutomaticReviewID = nil
        }
        if let reviewDraftID,
           !reviewQueue.contains(where: { $0.id == reviewDraftID }) {
            reviewingDraft = nil
        }
        if let reviewingDICOMStudy,
           !snapshot.dicomStudies.contains(where: { $0.id == reviewingDICOMStudy.id }) {
            self.reviewingDICOMStudy = nil
        }
        if let editingRecord,
           !allRecords.contains(where: { $0.id == editingRecord.id && $0.importState == .confirmed }) {
            self.editingRecord = nil
        }
        comparisonModel.updateAvailableRecords(snapshot.records)
        if let selectedMemberID,
           !members.contains(where: { $0.id == selectedMemberID && !$0.isArchived }) {
            self.selectedMemberID = nil
        }
        rebuildTimeline()
        rebuildSearch()
        if let selectedRecordID,
           !allRecords.contains(where: { $0.id == selectedRecordID && $0.importState == .confirmed }) {
            clearSelection()
        }
        if previousGeneration != 0, snapshot.generation > previousGeneration {
            onDurableStateChanged()
        }
    }

    private func applyAfterRevokingStaleDICOMViewers(_ snapshot: AppSnapshot) async {
        guard !vaultLifecycleIsLocked,
              snapshot.generation >= appliedCatalogGeneration else { return }
        if appliedCatalogGeneration != 0,
           snapshot.generation > appliedCatalogGeneration {
            await dicomViewerRegistry.withWholeVaultRevocation { [self] in
                guard !vaultLifecycleIsLocked,
                      snapshot.generation >= appliedCatalogGeneration else { return }
                apply(snapshot)
            }
            return
        }
        apply(snapshot)
    }

    private func beginStateRequest() -> UInt64 {
        stateRequestID &+= 1
        return stateRequestID
    }

    private func clearSensitiveState() {
        originalLoadTask?.cancel()
        appliedCatalogGeneration = 0
        originalLoadTask = nil
        originalLoadID = nil
        isOriginalLoading = false
        recordDetailState = .empty
        members = []
        membersByID = [:]
        memberLabelsByID = [:]
        allRecords = []
        timelineSections = []
        searchResults = []
        reviewQueue = []
        backgroundDrafts = []
        selectedMemberID = nil
        searchText = ""
        isImporterPresented = false
        isDICOMFolderPickerPresented = false
        isDICOMImportPresented = false
        shouldPresentDICOMFolderPickerAfterSheetDismissal = false
        dicomImportModel.clear()
        dicomLibraryModel.clear()
        reviewingDraft = nil
        reviewingDICOMStudy = nil
        activeDICOMStudyReviewModel?.clear()
        activeDICOMStudyReviewModel = nil
        isMemberEditorPresented = false
        editingMember = nil
        editingRecord = nil
        viewingOriginal = nil
        isOriginalExportPresented = false
        originalExportModel.clear()
        isVaultDeletionPresented = false
        pendingDeleteRecordID = nil
        pendingDeleteMemberID = nil
        pendingDiscardDraftID = nil
        pendingDiscardDraftCommand = nil
        busyDraftIDs = []
        banner = nil
        deferredBanner = nil
        pendingAutomaticReviewID = nil
        comparisonModel.updateAvailableRecords([])
        comparisonModel.closeComparison()
    }

    private func rebuildTimeline() {
        let confirmedRecords = allRecords.filter { record in
            record.importState == .confirmed
                && (selectedMemberID == nil || record.memberID == selectedMemberID)
        }
        let confirmedStudies = dicomLibraryModel.confirmedStudies(memberID: selectedMemberID)
        let entries = confirmedRecords.map(AppTimelineEntry.record)
            + confirmedStudies.map(AppTimelineEntry.dicomStudy)
        let orderedEntries = entries
            .map { (order: $0.stableOrder, entry: $0) }
            .sorted { $0.order < $1.order }
            .map(\.entry)
        let dated = Dictionary(
            grouping: orderedEntries.compactMap { entry in
                entry.timelineDate.map { ($0, entry) }
            },
            by: { $0.0 }
        )
        var sections = dated.map { date, groupedEntries in
            AppTimelineSection(
                group: .dated(date),
                entries: groupedEntries.map(\.1)
            )
        }
            .sorted {
                guard case .dated(let left) = $0.group,
                      case .dated(let right) = $1.group else { return false }
                return left > right
            }
        let unknown = orderedEntries.filter { $0.timelineDate == nil }
        if !unknown.isEmpty {
            sections.append(AppTimelineSection(group: .unknown, entries: unknown))
        }
        timelineSections = sections
    }

    private func rebuildSearch() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = []
            return
        }
        searchResults = RecordQuery.search(
            query,
            records: allRecords,
            members: members,
            memberID: selectedMemberID
        )
    }

    private static func importMessage(for code: AppFailureCode) -> String {
        switch code {
        case .unsupportedFile: AppLocalization.string("暂不支持这种文件")
        case .lockedPDF: AppLocalization.string("PDF 已加密，无法读取")
        case .resourceLimit: AppLocalization.string("文件超出首版支持范围")
        case .damagedFile: AppLocalization.string("文件无法读取")
        case .vaultUnavailable: AppLocalization.string("资料库当前不可写入")
        case .importFailed: AppLocalization.string("导入未完成，可以稍后重试")
        }
    }

    private func reportBanner(_ message: String) {
        let next = AppBanner(message: message)
        if hasModalPresentation || banner != nil {
            deferredBanner = next
        } else {
            banner = next
        }
    }

    private func queueAutomaticReview(_ id: ImportDraft.ID) {
        guard reviewQueue.contains(where: { $0.id == id }) else { return }
        pendingAutomaticReviewID = pendingAutomaticReviewID ?? id
        presentationDidEnd()
    }
}

actor UnavailableAppService: AppDataServicing, DICOMAppServicing {
    func bootstrap() async throws -> AppSnapshot { throw AppServiceError.runtimeUnavailable }
    func refresh() async throws -> AppSnapshot { throw AppServiceError.vaultUnavailable }
    func createMember(displayName: String, disambiguationLabel: String?) async throws -> AppSnapshot { throw AppServiceError.vaultUnavailable }
    func updateMember(_ member: FamilyMember) async throws -> AppSnapshot { throw AppServiceError.vaultUnavailable }
    func archiveMember(id: FamilyMember.ID) async throws -> AppSnapshot { throw AppServiceError.vaultUnavailable }
    func deleteMember(id: FamilyMember.ID) async throws -> AppSnapshot { throw AppServiceError.vaultUnavailable }
    func importFile(at url: URL) async throws -> AppImportOutcome { throw AppServiceError.vaultUnavailable }
    func retryDraft(id: ImportDraft.ID) async throws -> AppImportOutcome { throw AppServiceError.vaultUnavailable }
    func loadReview(draftID: ImportDraft.ID) async throws -> ImportReviewContent { throw AppServiceError.vaultUnavailable }
    func recognizeReview(_ command: RecognizeReviewCommand) async throws -> RecognizedReviewContent { throw AppServiceError.vaultUnavailable }
    func loadReviewOriginal(
        draftID: ImportDraft.ID,
        sourceID: ReportSource.ID
    ) async throws -> OriginalDocumentPayload { throw AppServiceError.vaultUnavailable }
    func confirmDraft(_ command: ConfirmDraftCommand) async throws -> AppSnapshot { throw AppServiceError.vaultUnavailable }
    func updateRecord(_ command: UpdateRecordCommand) async throws -> AppSnapshot { throw AppServiceError.vaultUnavailable }
    func deleteRecord(id: HealthRecord.ID) async throws -> AppSnapshot { throw AppServiceError.vaultUnavailable }
    func deferDraft(_ command: DeferDraftCommand) async throws {
        throw AppServiceError.vaultUnavailable
    }
    func discardDraft(_ command: DiscardDraftCommand) async throws -> AppSnapshot {
        throw AppServiceError.vaultUnavailable
    }
    func loadOriginal(
        recordID: HealthRecord.ID,
        sourceID: ReportSource.ID
    ) async throws -> OriginalDocumentPayload { throw AppServiceError.vaultUnavailable }
    func importDICOMDirectory(at url: URL) async throws -> DICOMAppImportOutcome {
        throw AppServiceError.vaultUnavailable
    }
    func cancelDICOMImport() async throws -> DICOMAppImportOutcome? { nil }
    func loadDICOMStudyReview(studyID: DICOMStudy.ID) async throws -> DICOMStudyReviewContent {
        throw AppServiceError.vaultUnavailable
    }
    func saveDICOMStudy(_ command: SaveDICOMStudyCommand) async throws -> AppSnapshot {
        throw AppServiceError.vaultUnavailable
    }
    func deleteDICOMStudy(id: DICOMStudy.ID) async throws -> AppSnapshot {
        throw AppServiceError.vaultUnavailable
    }
}

actor UnavailableOriginalExportService: OriginalExportServicing {
    func prepare(undatedToken: String) async throws {
        throw OriginalExportServiceError.unavailable
    }

    func export(
        to destinationURL: URL,
        undatedToken: String,
        progress: @escaping @Sendable (AppOriginalExportProgress) -> Void
    ) async throws -> OriginalExportResult {
        throw OriginalExportServiceError.unavailable
    }

    func cancel() -> Bool { false }
}

actor UnavailableDICOMSliceService: DICOMSliceViewing {
    func openSeries(
        studyID: DICOMStudy.ID,
        seriesID: DICOMStudyIndex.Series.ID
    ) async throws -> DICOMSliceSeriesSession {
        throw DICOMSliceServiceError.closed
    }

    func render(
        session: DICOMSliceSeriesSession,
        instanceID: DICOMStudyIndex.Instance.ID,
        windowCenter: Double?,
        windowWidth: Double?
    ) async throws -> DICOMSliceImage {
        throw DICOMSliceServiceError.closed
    }

    func prefetch(
        session: DICOMSliceSeriesSession,
        instanceID: DICOMStudyIndex.Instance.ID
    ) async -> Bool { false }

    func handleMemoryPressure() async {}
    func close() async {}
}
