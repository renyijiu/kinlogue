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

enum AppPageState: Equatable { case loading, loaded, failed }

enum AppBannerMessage: Equatable {
    case archiveMember
    case deleteMember
    case memberUnavailable
    case fileUnreadable
    case importIncomplete
    case retryIncomplete
    case discardDraft
    case recordUnavailable
    case originalUnavailable
    case deleteRecord
    case memberReferenced(records: Int, drafts: Int)
    case memberStudyReferenced(Int)
    case importFailure(AppFailureCode)

    var localizedText: String {
        switch self {
        case .archiveMember: AppLocalization.string("无法归档家庭成员")
        case .deleteMember: AppLocalization.string("无法删除家庭成员")
        case .memberUnavailable: AppLocalization.string("无法读取家庭成员")
        case .fileUnreadable: AppLocalization.string("没有读取所选文件")
        case .importIncomplete: AppLocalization.string("导入未完成，可以稍后重试")
        case .retryIncomplete: AppLocalization.string("重试未完成，可以稍后再试")
        case .discardDraft: AppLocalization.string("无法放弃这份导入")
        case .recordUnavailable: AppLocalization.string("记录暂时无法打开")
        case .originalUnavailable: AppLocalization.string("原件暂时无法打开")
        case .deleteRecord: AppLocalization.string("无法删除这条记录")
        case .memberReferenced(let recordCount, let draftCount):
            AppLocalization.string("该成员仍关联 \(recordCount) 条记录和 \(draftCount) 份草稿。请先重分配这些内容，或逐条删除后再试。")
        case .memberStudyReferenced(let studyCount):
            AppLocalization.string("该成员仍关联 \(studyCount) 项医学影像检查。请先重分配或删除这些检查后再试。")
        case .importFailure(let code):
            switch code {
            case .unsupportedFile: AppLocalization.string("暂不支持这种文件")
            case .lockedPDF: AppLocalization.string("PDF 已加密，无法读取")
            case .resourceLimit: AppLocalization.string("文件超出首版支持范围")
            case .damagedFile: AppLocalization.string("文件无法读取")
            case .vaultUnavailable: AppLocalization.string("资料库当前不可写入")
            case .importFailed: AppLocalization.string("导入未完成，可以稍后重试")
            }
        }
    }
}

struct AppBanner: Equatable, Identifiable {
    let id = UUID()
    let state: AppBannerMessage
    var message: String { state.localizedText }
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

/// The file a report import or retry is on, counted from one.
struct ReportRecognitionActivity: Equatable {
    let position: Int
    let total: Int
}

enum ReportRecognitionNotice {
    /// How long recognition runs before the interface explains the wait. The
    /// system prepares its recognition model on first use, which takes far
    /// longer than any later recognition.
    static let slowDelay: Duration = .seconds(4)
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

    var onLibraryUnavailable: (@MainActor () async -> Void)?
    private let service: any AppDataServicing
    private let dicomService: any DICOMAppServicing
    private let dicomSliceServiceFactory: @Sendable () -> any DICOMSliceViewing
    private let dicomViewerRegistry: DICOMViewerRegistry
    private let onDurableStateChanged: @MainActor @Sendable () -> Void
    private var timelineEntries: [AppTimelineEntry] = []
    private var appliedRevision: LibraryRevision?
    var currentLibraryRevision: LibraryRevision? { phase == .ready ? appliedRevision : nil }
    private var detailLibraryRevision: LibraryRevision?
    private var applicationRequestID = UUID()
    /// Every read this model has started; a destructive library lifecycle cancels and drains it.
    private let reads = LibraryReadRegistry()
    private var detailReadTask: Task<LibraryRecordSelection, Error>?
    private var detailRequestID = UUID()
    private var memberRequestID = UUID()
    private var reviewRequestID = UUID()
    private var pageRequestID = UUID()
    private var pageLoadTask: Task<Void, Never>?
    private var pageCursor: LibraryQueryCursor?
    private var pageRevision: LibraryRevision?
    private var draftRequestID = UUID()
    private var draftCursors: [ImportState: LibraryQueryCursor] = [:]
    private var draftRevisions: [ImportState: LibraryRevision] = [:]
    private var draftPages: [ImportState: [DraftSummary]] = [:]
    private var clearingSensitiveState = false
    @Published private(set) var pageState: AppPageState = .loading
    @Published private(set) var draftLoadingStates: Set<ImportState> = []
    @Published private(set) var draftFailedStates: Set<ImportState> = []
    @Published private(set) var damagedItemIDs: Set<UUID> = []
    @Published private(set) var damagedMemberIDs: Set<UUID> = []
    var hasMoreRecords: Bool { pageCursor != nil }
    private var membersByID: [FamilyMember.ID: LibraryMemberSummary] = [:]
    private var memberLabelsByID: [FamilyMember.ID: String] = [:]
    private var stateRequestID: UInt64 = 0
    private var originalLoadTask: Task<Void, Never>?
    private var originalLoadID: UUID?
    private var vaultLifecycleIsLocked = false
    private var shouldPresentDICOMFolderPickerAfterSheetDismissal = false
    private var deferredBanner: AppBanner?
    private var pendingAutomaticReviewID: ImportDraft.ID?
    private var pendingDiscardDraftCommand: DiscardDraftCommand?
    private weak var activeImportReviewModel: ImportReviewModel?
    private var activeDICOMStudyReviewModel: DICOMStudyReviewModel?
    private let slowRecognitionNoticeDelay: Duration
    private var reportRecognitionJobs: [(id: UUID, activity: ReportRecognitionActivity)] = []
    private var slowRecognitionNoticeTask: Task<Void, Never>?
    let comparisonModel: ComparisonModel
    let dicomImportModel: DICOMImportModel
    let dicomLibraryModel: DICOMLibraryModel
    let originalExportModel: OriginalExportModel

    @Published private(set) var phase: AppPhase = .loading
    @Published private(set) var restartRequiredForIntegrity = false
    @Published private(set) var members: [LibraryMemberSummary] = []
    @Published var selectedMemberID: FamilyMember.ID? {
        didSet {
            clearSelection()
            filtersDidChange()
        }
    }
    @Published var timelineFilter: AppTimelineFilter = .all {
        didSet {
            guard timelineFilter != oldValue else { return }
            clearSelectionHiddenByTimelineFilter()
            filtersDidChange()
        }
    }
    @Published private(set) var isTimelineFilterAvailable = false
    @Published private(set) var timelineSections: [AppTimelineSection] = []
    @Published private(set) var searchResults: [LibraryReportSummary] = []
    @Published var searchText = "" { didSet { filtersDidChange() } }
    @Published private(set) var reviewQueue: [DraftSummary] = []
    @Published private(set) var backgroundDrafts: [DraftSummary] = []
    @Published private var recordDetailState: RecordDetailState = .empty {
        didSet { checkRuleUpdate() }
    }
    /// What the current extraction rules read differently from the open record, if anything.
    @Published private(set) var ruleUpdate: RecordRuleUpdate?
    @Published var reviewingRuleUpdate: RecordRuleUpdate?
    @Published private(set) var isOriginalLoading = false
    @Published var isImporterPresented = false
    @Published var isDICOMFolderPickerPresented = false
    @Published var isDICOMImportPresented = false
    @Published var reviewingDraft: ReviewDraftPresentation? {
        didSet {
            if oldValue?.id != reviewingDraft?.id {
                activeImportReviewModel?.closeReview()
                activeImportReviewModel = nil
            }
        }
    }
    @Published var reviewingDICOMStudy: DICOMStudyReviewPresentation?
    @Published var isMemberEditorPresented = false
    @Published var editingMember: FamilyMember?
    @Published var editingRecord: HealthRecord?
    @Published var viewingOriginal: OriginalViewerPresentation?
    private var ruleUpdateTask: Task<Void, Never>?
    private var ruleUpdateRecord: (id: HealthRecord.ID, revision: UInt64)?
    @Published var isVaultDeletionPresented = false
    @Published var isOriginalExportPresented = false
    @Published var pendingDeleteRecordID: HealthRecord.ID?
    @Published var pendingDeleteMemberID: FamilyMember.ID?
    @Published var pendingDiscardDraftID: ImportDraft.ID?
    @Published private(set) var busyDraftIDs: Set<ImportDraft.ID> = []
    @Published private(set) var reportRecognitionActivity: ReportRecognitionActivity?
    @Published private(set) var isReportRecognitionSlow = false
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
        slowRecognitionNoticeDelay: Duration = ReportRecognitionNotice.slowDelay,
        onDurableStateChanged: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        self.service = service
        self.slowRecognitionNoticeDelay = slowRecognitionNoticeDelay
        self.dicomService = dicomService
        self.dicomSliceServiceFactory = dicomSliceServiceFactory
        self.dicomViewerRegistry = dicomViewerRegistry
        self.onDurableStateChanged = onDurableStateChanged
        comparisonModel = ComparisonModel(service: service)
        dicomImportModel = DICOMImportModel(service: dicomService)
        dicomLibraryModel = DICOMLibraryModel()
        originalExportModel = OriginalExportModel(service: originalExportService)
        comparisonModel.onReadFailure = { [weak self] error in self?.scheduleLibraryFailure(error) }
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
            || reviewingRuleUpdate != nil
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
            let readRequestID = stateRequestID
            do {
                let snapshot = try await readHeader(bootstrap: true)
                guard readRequestID == stateRequestID, !vaultLifecycleIsLocked else { return }
                apply(snapshot)
                phase = .ready
                await reloadVisibleQueries()
            } catch AppServiceError.vaultUnavailable {
                guard readRequestID == stateRequestID, !vaultLifecycleIsLocked else { return }
                phase = .locked
            } catch {
                guard readRequestID == stateRequestID, !vaultLifecycleIsLocked else { return }
                phase = .failed
            }
        }
    }

    /// `skippingUnchanged` is for callers that only react to a possible change, such as a commit
    /// hint, activation or wake. The same revision is the same library, so nothing is reloaded.
    /// A plain refresh always reloads, because retry eligibility of a draft can change in memory
    /// without a commit.
    func refresh(skippingUnchanged: Bool = false) async {
        guard !vaultLifecycleIsLocked, phase != .locked else { return }
        let requestID = beginStateRequest()
        do {
            let snapshot = try await readHeader(bootstrap: false)
            guard requestID == stateRequestID, !vaultLifecycleIsLocked else { return }
            await applyAfterRevokingStaleDICOMViewers(snapshot, skippingUnchanged: skippingUnchanged)
        } catch is CancellationError {
            return
        } catch {
            guard requestID == stateRequestID, !vaultLifecycleIsLocked else { return }
            await lockUnavailableLibrary()
        }
    }

    /// A target content error stays local. Infrastructure failures revoke all sensitive UI.
    private func handleLibraryFailure(_ error: Error) async -> Bool {
        guard let failure = error as? SQLiteLibraryError, !vaultLifecycleIsLocked, phase == .ready else { return false }
        let identity = appliedRevision
        switch failure {
        case .closed, .staleRoot, .databaseUnavailable, .unsupportedFormat, .unsupportedConfiguration, .invalidPath, .ioFailure:
            break
        case .damaged:
            // Row hashes and library-state hashes share this legacy error case. This bounded
            // header distinguishes a bad target from damaged global state; SQL errors above
            // never use this fallback, because another table may remain readable.
            do { _ = try await readHeader(bootstrap: false); return false }
            catch is CancellationError { return false }
            catch { }
        default: return false
        }
        guard identity?.libraryID == appliedRevision?.libraryID, identity?.openEpoch == appliedRevision?.openEpoch,
              !vaultLifecycleIsLocked, phase == .ready else { return false }
        await lockUnavailableLibrary()
        return true
    }

    private func lockUnavailableLibrary() async {
        phase = .locked
        if let onLibraryUnavailable {
            await onLibraryUnavailable()
        } else {
            clearSensitiveState()
            await dicomViewerRegistry.revokeAll()
        }
    }

    private func scheduleLibraryFailure(_ error: Error) {
        guard error is SQLiteLibraryError, phase == .ready, !vaultLifecycleIsLocked else { return }
        let identity = appliedRevision
        reads.start { [weak self] in
            guard let self, !Task.isCancelled, identity?.libraryID == appliedRevision?.libraryID,
                  identity?.openEpoch == appliedRevision?.openEpoch else { return }
            _ = await handleLibraryFailure(error)
        }
    }

    private func readHeader(bootstrap: Bool) async throws -> AppSnapshot {
        let service = service
        return try await reads.run { try await bootstrap ? service.bootstrap() : service.refresh() }
    }

    private func readDraft(_ id: UUID) async throws -> ImportDraft {
        let service = service
        return try await reads.run { try await service.loadDraft(id: id) }
    }

    private func readRecords(_ ids: [UUID]) async throws -> LibraryRecordSelection {
        let service = service
        return try await reads.run { try await service.loadRecords(ids: ids) }
    }

    func createMember(displayName: String, disambiguationLabel: String?) async -> Bool {
        do {
            await applyAfterRevokingStaleDICOMViewers(try await service.createMember(
                displayName: displayName,
                disambiguationLabel: disambiguationLabel
            ), skippingUnchanged: true)
            return true
        } catch {
            return false
        }
    }

    func updateMember(_ member: FamilyMember, replacing expected: FamilyMember) async -> Bool {
        do {
            await applyAfterRevokingStaleDICOMViewers(try await service.updateMember(member, replacing: expected), skippingUnchanged: true)
            return true
        } catch {
            return false
        }
    }

    func archiveMember(_ member: FamilyMember) async {
        do {
            await applyAfterRevokingStaleDICOMViewers(
                try await service.archiveMember(id: member.id), skippingUnchanged: true
            )
        } catch {
            reportBanner(.archiveMember)
        }
    }

    func requestDeleteMember(_ member: LibraryMemberSummary) {
        guard !hasBlockingPresentation,
              members.contains(where: { $0.id == member.id }) else { return }
        pendingDeleteMemberID = member.id
    }

    func confirmDeleteMember(id: FamilyMember.ID) async {
        if pendingDeleteMemberID == id { pendingDeleteMemberID = nil }
        do {
            await applyAfterRevokingStaleDICOMViewers(
                try await service.deleteMember(id: id), skippingUnchanged: true
            )
        } catch AppServiceError.memberStillReferenced(let recordCount, let draftCount) {
            reportBanner(.memberReferenced(records: recordCount, drafts: draftCount))
        } catch AppServiceError.memberStillReferencedByDICOMStudy(let studyCount) {
            reportBanner(.memberStudyReferenced(studyCount))
        } catch {
            reportBanner(.deleteMember)
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
        case .timeline:
            revealDICOMStudy(result.studyID)
        }
        return result
    }

    func selectDICOMStudy(_ id: DICOMStudy.ID) {
        guard dicomLibraryModel.studies.contains(where: {
            $0.id == id && $0.state == .confirmed
        }) else { return }
        clearSelection()
        dicomLibraryModel.select(id)
    }

    private func revealDICOMStudy(_ id: DICOMStudy.ID) {
        guard let study = dicomLibraryModel.studies.first(where: {
            $0.id == id && $0.state == .confirmed
        }) else { return }
        if let selectedMemberID, study.confirmedMemberID != selectedMemberID {
            self.selectedMemberID = nil
        }
        if timelineFilter == .reports {
            timelineFilter = .all
        }
        if !searchText.isEmpty {
            searchText = ""
        }
        selectDICOMStudy(id)
    }

    func presentReviewDraft(_ id: ImportDraft.ID) async {
        guard phase == .ready, !hasBlockingPresentation else { return }
        let request = UUID(); reviewRequestID = request
        do {
            let draft = try await readDraft(id)
            guard request == reviewRequestID, phase == .ready, !hasBlockingPresentation,
                  draft.state == .needsReview else { return }
            reviewingDraft = ReviewDraftPresentation(id: id)
        } catch { }
    }

    func presentNewMemberEditor() {
        guard phase == .ready, !hasBlockingPresentation else { return }
        isMemberEditorPresented = true
    }

    func presentMemberEditor(_ member: LibraryMemberSummary) async {
        guard phase == .ready, !hasBlockingPresentation, !member.isArchived else { return }
        let request = UUID(); memberRequestID = request
        do {
            let service = service
            let full = try await reads.run { try await service.loadMember(id: member.id) }
            guard request == memberRequestID, !vaultLifecycleIsLocked, !hasBlockingPresentation else { return }
            editingMember = full
        } catch {
            guard request == memberRequestID, !vaultLifecycleIsLocked else { return }
            if await handleLibraryFailure(error) { return }
            reportBanner(.memberUnavailable)
        }
    }

    func presentRecordEditor() {
        guard phase == .ready,
              !hasBlockingPresentation,
              let selectedRecord else { return }
        editingRecord = selectedRecord
    }

    func presentRuleUpdate() {
        guard phase == .ready,
              !hasBlockingPresentation,
              let ruleUpdate,
              selectedRecord?.id == ruleUpdate.recordID else { return }
        reviewingRuleUpdate = ruleUpdate
    }

    /// Asks the current rules about the open record once per revision. The check is an aid: when
    /// it fails, the record is shown as it is, without a notice.
    private func checkRuleUpdate() {
        let record = selectedRecord
        guard record?.id != ruleUpdateRecord?.id || record?.revision != ruleUpdateRecord?.revision else { return }
        ruleUpdateTask?.cancel(); ruleUpdateTask = nil
        ruleUpdate = nil
        ruleUpdateRecord = record.map { ($0.id, $0.revision) }
        guard let record, !vaultLifecycleIsLocked else { return }
        let service = self.service, reads = self.reads
        ruleUpdateTask = Task { [weak self] in
            let update = try? await reads.value(of: Task { try await service.ruleUpdate(recordID: record.id) })
            guard !Task.isCancelled, let self, !self.vaultLifecycleIsLocked,
                  self.selectedRecord?.id == record.id, self.selectedRecord?.revision == record.revision else { return }
            self.ruleUpdate = update ?? nil
        }
    }

    /// Returns once the check of the open record against the current rules has ended.
    func waitForRuleUpdateCheck() async {
        await ruleUpdateTask?.value
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
            reportBanner(.fileUnreadable)
            return
        }
        guard !urls.isEmpty else { return }

        let jobID = beginReportRecognitionJob(total: urls.count)
        defer { endReportRecognitionJob(jobID) }
        var nextReviewID: ImportDraft.ID?
        for (index, url) in urls.enumerated() {
            advanceReportRecognitionJob(jobID, to: index + 1)
            do {
                switch try await service.importFile(at: url) {
                case .needsReview(let id), .existingDraft(let id):
                    nextReviewID = nextReviewID ?? id
                case .existingRecord(let id):
                    await selectRecord(id)
                case .failed(let code):
                    reportBanner(.importFailure(code))
                }
            } catch {
                reportBanner(.importIncomplete)
            }
        }
        await refresh()
        if let nextReviewID { queueAutomaticReview(nextReviewID) }
    }

    func retryDraft(_ id: ImportDraft.ID) async {
        guard busyDraftIDs.insert(id).inserted else { return }
        let jobID = beginReportRecognitionJob(total: 1)
        defer {
            busyDraftIDs.remove(id)
            endReportRecognitionJob(jobID)
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
                reportBanner(.importFailure(code))
            }
        } catch {
            await refresh()
            guard !vaultLifecycleIsLocked else { return }
            reportBanner(.retryIncomplete)
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
                try await service.discardDraft(command), skippingUnchanged: true
            )
            if pendingDiscardDraftID == id { pendingDiscardDraftID = nil }
        } catch {
            reportBanner(.discardDraft)
        }
    }

    func selectRecord(_ id: HealthRecord.ID) async {
        await selectRecord(id, reportsFailure: true)
    }

    private func selectRecord(_ id: HealthRecord.ID, reportsFailure: Bool) async {
        guard !vaultLifecycleIsLocked else { return }
        dicomLibraryModel.select(nil)
        if timelineFilter == .imaging {
            timelineFilter = .all
        }
        originalLoadTask?.cancel(); originalLoadID = nil
        let request = UUID(); detailRequestID = request
        recordDetailState = .loading(recordID: id)
        do {
            let service = self.service
            let task = Task { try await service.loadRecords(ids: [id]) }
            detailReadTask?.cancel(); detailReadTask = task
            let selection = try await reads.value(of: task)
            guard request == detailRequestID, !vaultLifecycleIsLocked else { return }
            detailReadTask = nil
            guard accepts(selection.revision), let record = selection.records.first else {
                recordDetailState = .empty
                if reportsFailure { reportBanner(.recordUnavailable) }
                return
            }
            detailLibraryRevision = selection.revision
            await loadOriginal(
                for: record,
                sourceID: record.sources.first.id,
                isInitialSelection: true,
                reportsFailure: reportsFailure
            )
        } catch {
            guard request == detailRequestID, !vaultLifecycleIsLocked else { return }
            if await handleLibraryFailure(error) { return }
            recordDetailState = .empty
            if reportsFailure { reportBanner(.recordUnavailable) }
        }
    }

    /// Opens the newest record of the visible timeline when it is entered with
    /// nothing open. An open record, a selected imaging study, a search, a
    /// comparison selection or a presented sheet is never disturbed.
    func openNewestRecordIfNothingIsOpen() async {
        // The timeline arrives a page at a time; the first page holds the newest record.
        await waitForCurrentPage()
        guard !Task.isCancelled,
              phase == .ready,
              selectedRecordID == nil,
              dicomLibraryModel.selectedStudyID == nil,
              !hasBlockingPresentation,
              !comparisonModel.isSelecting,
              searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let newest = timelineSections.lazy.flatMap(\.records).first else { return }
        // The user did not ask for this record, so a failed load stays in the
        // detail pane instead of raising an alert.
        await selectRecord(newest.id, reportsFailure: false)
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
        isInitialSelection: Bool,
        reportsFailure: Bool = true
    ) async {
        guard let library = detailLibraryRevision else { return }
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
                    sourceID: sourceID, expectedRevision: record.revision, expectedLibrary: library
                )
                try Task.checkCancellation()
                guard let self, self.originalLoadID == loadID else { return }
                guard self.detailLibraryRevision?.libraryID == library.libraryID,
                      self.detailLibraryRevision?.openEpoch == library.openEpoch else { return }
                let currentRecord = self.selectedRecord ?? record
                guard currentRecord.id == record.id,
                      currentRecord.sources.elements.first(where: { $0.id == sourceID }) == record.sources.elements.first(where: { $0.id == sourceID }) else { return }
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
                    if await self.handleLibraryFailure(error) { return }
                    let currentRecord = self.selectedRecord ?? record
                    self.recordDetailState = .loaded(
                        record: currentRecord,
                        sourceID: sourceID,
                        original: nil
                    )
                    self.isOriginalLoading = false
                    if reportsFailure {
                        self.reportBanner(.originalUnavailable)
                    }
                }
            }
        }
        if let task = originalLoadTask { await reads.value(of: task) }
    }

    func clearSelection() {
        detailRequestID = UUID(); detailLibraryRevision = nil
        detailReadTask?.cancel(); detailReadTask = nil
        originalLoadTask?.cancel()
        originalLoadTask = nil
        originalLoadID = nil
        isOriginalLoading = false
        recordDetailState = .empty
        editingRecord = nil
        reviewingRuleUpdate = nil
        viewingOriginal = nil
        dicomLibraryModel.select(nil)
    }

    private func clearSelectionHiddenByTimelineFilter() {
        switch timelineFilter {
        case .all:
            break
        case .reports:
            dicomLibraryModel.select(nil)
        case .imaging:
            if selectedRecordID != nil {
                clearSelection()
            }
        }
    }

    func requestDeleteRecord(_ record: HealthRecord) {
        guard !hasBlockingPresentation, record.importState == .confirmed else { return }
        pendingDeleteRecordID = record.id
    }

    func confirmDeleteRecord(id: HealthRecord.ID) async {
        if pendingDeleteRecordID == id { pendingDeleteRecordID = nil }
        if selectedRecord?.id == id {
            clearSelection()
        }
        do {
            await applyAfterRevokingStaleDICOMViewers(
                try await service.deleteRecord(id: id), skippingUnchanged: true
            )
        } catch {
            reportBanner(.deleteRecord)
        }
    }

    func member(for record: HealthRecord) -> LibraryMemberSummary? {
        membersByID[record.memberID]
    }

    func memberLabel(for record: HealthRecord) -> String {
        memberLabelsByID[record.memberID]
            ?? member(for: record)?.displayName
            ?? AppLocalization.string("家庭成员")
    }

    func memberLabel(for record: LibraryReportSummary) -> String {
        memberLabelsByID[record.memberID] ?? AppLocalization.string("家庭成员")
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
            return await updateMember(updated, replacing: existing)
        } catch {
            return false
        }
    }

    func makeReviewModel(draftID: ImportDraft.ID) -> ImportReviewModel {
        if let activeImportReviewModel, activeImportReviewModel.draftID == draftID { return activeImportReviewModel }
        let model = ImportReviewModel(draftID: draftID, service: service, onReadFailure: { [weak self] error in self?.scheduleLibraryFailure(error) })
        activeImportReviewModel = model
        return model
    }

    func makeDICOMStudyReviewModel(studyID: DICOMStudy.ID) -> DICOMStudyReviewModel {
        if let activeDICOMStudyReviewModel,
           activeDICOMStudyReviewModel.studyID == studyID {
            return activeDICOMStudyReviewModel
        }
        let model = DICOMStudyReviewModel(
            studyID: studyID,
            service: dicomService,
            onReadFailure: { [weak self] error in self?.scheduleLibraryFailure(error) },
            onSnapshotChanged: { [weak self] snapshot in
                await self?.applyAfterRevokingStaleDICOMViewers(snapshot, skippingUnchanged: true)
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
            viewerRegistry: dicomViewerRegistry,
            onReadFailure: { [weak self] error in self?.scheduleLibraryFailure(error) }
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
        await saveRecordChange(recordID: command.recordID) { try await $0.updateRecord(command) }
    }

    /// Saves the open rule update with the fields the user took; none still records the decision.
    func applyRuleUpdate(accepting fields: Set<RecordRuleUpdate.Field>) async -> UpdateRecordResult {
        guard let update = reviewingRuleUpdate else { return .failed }
        let command = ApplyRuleUpdateCommand(
            recordID: update.recordID,
            expectedRevision: update.recordRevision,
            extractionVersion: update.extractionVersion,
            acceptedFields: fields
        )
        return await saveRecordChange(recordID: update.recordID) { try await $0.applyRuleUpdate(command) }
    }

    private func saveRecordChange(
        recordID: HealthRecord.ID,
        _ save: (any AppDataServicing) async throws -> AppSnapshot
    ) async -> UpdateRecordResult {
        guard phase == .ready, !vaultLifecycleIsLocked else { return .failed }
        let epoch = appliedRevision
        func isCurrentLibrary() -> Bool {
            phase == .ready && !vaultLifecycleIsLocked && epoch?.libraryID == appliedRevision?.libraryID
                && epoch?.openEpoch == appliedRevision?.openEpoch
        }
        do {
            let existingOriginal = originalDocument
            let existingSourceID = selectedOriginalSourceID
            let snapshot = try await save(service)
            guard isCurrentLibrary() else { return .failed }
            await applyAfterRevokingStaleDICOMViewers(snapshot, skippingUnchanged: true)
            guard isCurrentLibrary() else { return .failed }
            let request = UUID(); detailRequestID = request
            let selection = try await readRecords([recordID])
            guard isCurrentLibrary(), request == detailRequestID, accepts(selection.revision) else { return .failed }
            detailLibraryRevision = selection.revision
            if let updatedRecord = selection.records.first {
                let sourceID = existingSourceID ?? updatedRecord.sources.first.id
                if updatedRecord.sources.elements.contains(where: { $0.id == sourceID }) {
                    recordDetailState = .loaded(record: updatedRecord, sourceID: sourceID, original: existingOriginal)
                }
            }
            return .saved
        } catch AppServiceError.recordChanged {
            do {
                let snapshot = try await readHeader(bootstrap: false)
                guard isCurrentLibrary() else { return .failed }
                await applyAfterRevokingStaleDICOMViewers(snapshot)
                guard isCurrentLibrary() else { return .failed }
                let request = UUID(); detailRequestID = request
                let selection = try await readRecords([recordID])
                guard isCurrentLibrary(), request == detailRequestID, accepts(selection.revision) else { return .failed }
                return .recordChanged(latest: selection.records.first)
            } catch {
                _ = await handleLibraryFailure(error)
                return .recordChanged(latest: nil)
            }
        } catch {
            _ = await handleLibraryFailure(error)
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
        let page = pageLoadTask
        let drains = reads.cancelAll()
        page?.cancel()
        let comparisonDrains = comparisonModel.cancelReads()
        clearSensitiveState()
        phase = .changingVault
        for drain in comparisonDrains { await drain() }
        await page?.value
        for drain in drains { await drain() }
        await dicomViewerRegistry.revokeAll()
    }

    func requireRestartAfterIntegrityFailure() {
        restartRequiredForIntegrity = true
        requireRestartAfterVaultLifecycle()
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
        clearingSensitiveState = true
        defer { clearingSensitiveState = false }
        let previous = appliedRevision
        appliedRevision = snapshot.revision
        members = snapshot.members
        membersByID = Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0) })
        memberLabelsByID = LibraryMemberSummary.labels(members)
        damagedMemberIDs = Set(snapshot.damagedMemberIDs)
        damagedItemIDs = Set(snapshot.damagedStudyIDs)
        dicomLibraryModel.update(studies: snapshot.dicomStudies, members: members)
        isTimelineFilterAvailable = !dicomLibraryModel.confirmedStudies(memberID: nil).isEmpty
        if !isTimelineFilterAvailable {
            timelineFilter = .all
        }
        if let selectedMemberID, !members.contains(where: { $0.id == selectedMemberID && !$0.isArchived }) {
            self.selectedMemberID = nil
        }
        if let reviewingDICOMStudy, !snapshot.dicomStudies.contains(where: { $0.id == reviewingDICOMStudy.id }) {
            self.reviewingDICOMStudy = nil
        }
        if let previous, previous != snapshot.revision { onDurableStateChanged() }
    }

    private func applyAfterRevokingStaleDICOMViewers(_ snapshot: AppSnapshot, skippingUnchanged: Bool = false) async {
        guard !vaultLifecycleIsLocked, phase != .locked else { return }
        // A commit hint and the mutation that caused it both deliver the same revision, and so
        // does activation when nothing happened. The lists are then current. What is open is
        // still read again, which is how a failure that changed no revision gets noticed.
        if skippingUnchanged, phase == .ready, appliedRevision == snapshot.revision {
            await reconcileOpenTargets()
            return
        }
        let request = UUID(); applicationRequestID = request
        if let previous = appliedRevision {
            if previous.libraryID != snapshot.revision.libraryID || previous.openEpoch != snapshot.revision.openEpoch {
                await dicomViewerRegistry.revokeAll()
                guard applicationRequestID == request, !vaultLifecycleIsLocked else { return }
                clearSensitiveState()
                applicationRequestID = request
            } else {
                guard snapshot.generation >= previous.generation else { return }
                let current = Dictionary(uniqueKeysWithValues: snapshot.dicomStudies.map { ($0.id, $0) })
                for study in dicomLibraryModel.studies where current[study.id] != study {
                    await dicomViewerRegistry.revoke(studyID: study.id)
                }
            }
        }
        guard !vaultLifecycleIsLocked, phase != .locked, applicationRequestID == request else { return }
        _ = beginStateRequest()
        apply(snapshot)
        phase = .ready
        await reloadVisibleQueries()
    }

    private func beginStateRequest() -> UInt64 {
        stateRequestID &+= 1
        return stateRequestID
    }

    private func clearSensitiveState() {
        _ = beginStateRequest()
        applicationRequestID = UUID()
        clearingSensitiveState = true
        defer { clearingSensitiveState = false }
        reads.cancelAll()
        originalLoadTask?.cancel(); detailReadTask?.cancel(); detailReadTask = nil
        pageLoadTask?.cancel(); pageLoadTask = nil
        pageRequestID = UUID(); draftRequestID = UUID(); detailRequestID = UUID(); memberRequestID = UUID(); reviewRequestID = UUID()
        pageCursor = nil; pageRevision = nil; detailLibraryRevision = nil; appliedRevision = nil
        draftCursors = [:]; draftRevisions = [:]; draftPages = [:]
        draftLoadingStates = []; draftFailedStates = []; damagedItemIDs = []; damagedMemberIDs = []
        originalLoadTask = nil
        originalLoadID = nil
        isOriginalLoading = false
        recordDetailState = .empty
        members = []
        membersByID = [:]
        memberLabelsByID = [:]
        timelineEntries = []
        timelineSections = []
        searchResults = []
        reviewQueue = []
        backgroundDrafts = []
        selectedMemberID = nil
        searchText = ""
        timelineFilter = .all
        isTimelineFilterAvailable = false
        isImporterPresented = false
        isDICOMFolderPickerPresented = false
        isDICOMImportPresented = false
        shouldPresentDICOMFolderPickerAfterSheetDismissal = false
        dicomImportModel.clear()
        dicomLibraryModel.clear()
        reviewingDraft = nil
        activeImportReviewModel?.closeReview()
        activeImportReviewModel = nil
        reviewingDICOMStudy = nil
        activeDICOMStudyReviewModel?.clear()
        activeDICOMStudyReviewModel = nil
        isMemberEditorPresented = false
        editingMember = nil
        editingRecord = nil
        reviewingRuleUpdate = nil
        viewingOriginal = nil
        isOriginalExportPresented = false
        originalExportModel.clear()
        isVaultDeletionPresented = false
        pendingDeleteRecordID = nil
        pendingDeleteMemberID = nil
        pendingDiscardDraftID = nil
        pendingDiscardDraftCommand = nil
        busyDraftIDs = []
        reportRecognitionJobs = []
        publishReportRecognitionActivity()
        banner = nil
        deferredBanner = nil
        pendingAutomaticReviewID = nil
        comparisonModel.closeComparison()
    }

    private func filtersDidChange() {
        guard !clearingSensitiveState, !vaultLifecycleIsLocked, phase == .ready else { return }
        invalidatePages(clear: true)
        let request = pageRequestID
        pageLoadTask = Task { [weak self] in await self?.loadRecordsPage(reset: true, request: request) }
    }

    func waitForCurrentPage() async { await pageLoadTask?.value }

    func loadNextRecordsPage() async {
        guard pageState != .loading, pageCursor != nil else { return }
        await loadRecordsPage(reset: false, request: pageRequestID)
    }

    func retryRecordsPage() async {
        await loadRecordsPage(reset: pageRevision == nil, request: pageRequestID)
    }

    private func invalidatePages(clear: Bool) {
        pageLoadTask?.cancel(); pageLoadTask = nil
        pageRequestID = UUID(); pageCursor = nil; pageRevision = nil
        if clear { timelineSections = []; searchResults = []; timelineEntries = [] }
        pageState = .loading
    }

    private struct RecordsPage {
        let revision: LibraryRevision
        var entries: [AppTimelineEntry]
        var next: LibraryQueryCursor?
        var damaged: [UUID]
        var damagedMembers: [UUID]
    }

    private func fetchRecordsPage(query: String, member: FamilyMember.ID?, filter: AppTimelineFilter,
                                  cursor: LibraryQueryCursor?) async throws -> RecordsPage {
        let service = service
        if query.isEmpty, filter == .all {
            let page = try await reads.run { try await service.timelinePage(memberID: member, cursor: cursor) }
            return RecordsPage(revision: page.revision, entries: page.items.map { switch $0 {
                case .report(let report): .record(report)
                case .study(let study): .dicomStudy(DICOMStudySummary(study: study))
            } }, next: page.nextCursor, damaged: page.damagedIDs, damagedMembers: [])
        }
        // An empty query lists every confirmed report in timeline order.
        let page = try await reads.run { try await service.reportPage(query: query, memberID: member, cursor: cursor) }
        return RecordsPage(revision: page.revision, entries: page.items.map(AppTimelineEntry.record),
                           next: page.nextCursor, damaged: page.damagedIDs, damagedMembers: page.damagedMemberIDs)
    }

    /// The number of rows the list shows now, which a reload reads again before replacing them.
    private var shownRecordCount: Int {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? timelineEntries.count : searchResults.count
    }

    /// Starts over from the first page without emptying the list, and reads `depth` rows before
    /// publishing so the list neither blanks nor shrinks back to one page.
    private func reloadRecords(depth: Int) async {
        invalidatePages(clear: false)
        await loadRecordsPage(reset: true, request: pageRequestID, depth: depth)
    }

    private func loadRecordsPage(reset: Bool, request: UUID, depth: Int = 0, isRetryAfterStaleCursor: Bool = false) async {
        guard request == pageRequestID, !vaultLifecycleIsLocked else { return }
        pageState = .loading
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let member = selectedMemberID
        let filter = timelineFilter
        // Confirmed studies arrive whole with the header, and imaging never enters search.
        if filter == .imaging {
            guard let appliedRevision else { pageState = .failed; return }
            pageRevision = appliedRevision; pageCursor = nil
            timelineEntries = query.isEmpty
                ? dicomLibraryModel.confirmedStudies(memberID: member).map(AppTimelineEntry.dicomStudy)
                : []
            searchResults = []
            rebuildTimeline()
            pageState = .loaded
            return
        }
        // One more page than is shown: a stale cursor on "load more" still ends with more rows.
        let shown = shownRecordCount
        do {
            var page = try await fetchRecordsPage(query: query, member: member, filter: filter, cursor: reset ? nil : pageCursor)
            try Task.checkCancellation()
            guard request == pageRequestID, !vaultLifecycleIsLocked else { return }
            guard accepts(page.revision) else { pageState = .failed; return }
            if !reset, let pageRevision, pageRevision != page.revision {
                await reloadRecords(depth: shown + 1)
                return
            }
            while reset, page.entries.count < depth, let cursor = page.next {
                let more = try await fetchRecordsPage(query: query, member: member, filter: filter, cursor: cursor)
                try Task.checkCancellation()
                guard request == pageRequestID, !vaultLifecycleIsLocked else { return }
                // The pages of one reload must describe one revision.
                guard more.revision == page.revision else { throw LibraryReportError.staleCursor }
                page.entries += more.entries; page.next = more.next
                page.damaged += more.damaged; page.damagedMembers += more.damagedMembers
            }
            pageRevision = page.revision; pageCursor = page.next
            damagedItemIDs.formUnion(page.damaged)
            damagedMemberIDs.formUnion(page.damagedMembers)
            if query.isEmpty {
                timelineEntries = reset ? page.entries : timelineEntries + page.entries
                rebuildTimeline()
            } else {
                let reports = page.entries.compactMap { if case .record(let record) = $0 { record } else { nil } }
                searchResults = reset ? reports : searchResults + reports
            }
            pageState = .loaded
        } catch LibraryReportError.staleCursor {
            guard request == pageRequestID, !vaultLifecycleIsLocked else { return }
            // A commit landed between pages. Read the same depth once more; if commits keep
            // arriving, fall back to the first page, which needs no cursor.
            if isRetryAfterStaleCursor {
                invalidatePages(clear: false)
                await loadRecordsPage(reset: true, request: pageRequestID)
            } else {
                invalidatePages(clear: false)
                await loadRecordsPage(reset: true, request: pageRequestID, depth: max(depth, reset ? 0 : shown + 1),
                                      isRetryAfterStaleCursor: true)
            }
        } catch is CancellationError {
            // Replacement requests own their own loading state.
        } catch {
            guard request == pageRequestID, !vaultLifecycleIsLocked else { return }
            if await handleLibraryFailure(error) { return }
            pageState = .failed
        }
    }

    private func accepts(_ revision: LibraryRevision) -> Bool {
        guard let appliedRevision else { return false }
        return revision.libraryID == appliedRevision.libraryID && revision.openEpoch == appliedRevision.openEpoch
            && revision.generation >= appliedRevision.generation
    }

    private func reloadVisibleQueries() async {
        guard !vaultLifecycleIsLocked else { return }
        // Rows stay on screen until fresh ones replace them; only a new query empties the list.
        let depth = shownRecordCount
        invalidatePages(clear: false)
        let request = pageRequestID
        let task = Task<Void, Never> { [weak self] in await self?.loadRecordsPage(reset: true, request: request, depth: depth) }
        pageLoadTask = task
        async let drafts: Void = reloadDraftPages()
        async let targets: Void = reconcileOpenTargets()
        await task.value
        await drafts
        await targets
    }

    private func reloadDraftPages() async {
        let request = UUID(); draftRequestID = request
        // Each state's rows stay until its fresh first page replaces them.
        draftCursors = [:]
        await withTaskGroup(of: Void.self) { group in
            for state in [ImportState.needsReview, .failed, .processing, .staging] {
                group.addTask { await self.loadDraftPage(state: state, reset: true, request: request) }
            }
        }
    }

    func loadNextDraftPage(state: ImportState) async {
        guard draftCursors[state] != nil, !draftLoadingStates.contains(state) else { return }
        await loadDraftPage(state: state, reset: false, request: draftRequestID)
    }

    private func loadDraftPage(state: ImportState, reset: Bool, request: UUID) async {
        guard request == draftRequestID, !vaultLifecycleIsLocked else { return }
        draftLoadingStates.insert(state)
        defer { if request == draftRequestID { draftLoadingStates.remove(state) } }
        do {
            let service = service, cursor = reset ? nil : draftCursors[state]
            let page = try await reads.run { try await service.draftPage(states: [state], cursor: cursor) }
            guard request == draftRequestID, !vaultLifecycleIsLocked else { return }
            guard accepts(page.revision) else { draftFailedStates.insert(state); return }
            if !reset, draftRevisions[state] != page.revision {
                draftPages[state] = []; draftCursors[state] = nil
                await loadDraftPage(state: state, reset: true, request: request)
                return
            }
            damagedItemIDs.formUnion(page.damagedIDs)
            draftPages[state] = reset ? page.items : (draftPages[state] ?? []) + page.items
            draftCursors[state] = page.nextCursor; draftRevisions[state] = page.revision
            draftFailedStates.remove(state)
            reviewQueue = draftPages[.needsReview] ?? []
            backgroundDrafts = [.failed, .processing, .staging].flatMap { draftPages[$0] ?? [] }
        } catch LibraryReportError.staleCursor {
            guard request == draftRequestID else { return }
            await loadDraftPage(state: state, reset: true, request: request)
        } catch {
            guard request == draftRequestID, !vaultLifecycleIsLocked else { return }
            if await handleLibraryFailure(error) { return }
            draftFailedStates.insert(state)
        }
    }

    func retryDraftPage(state: ImportState) async {
        guard !draftLoadingStates.contains(state) else { return }
        // Without a cursor there is no next page to continue from, so the state starts over.
        await loadDraftPage(state: state, reset: draftCursors[state] == nil, request: draftRequestID)
    }

    func hasMoreDrafts(state: ImportState) -> Bool { draftCursors[state] != nil }

    private func reconcileOpenTargets() async {
        if let id = selectedRecordID {
            let prior = selectedRecord
            if prior == nil { await selectRecord(id) }
            else {
            let request = UUID(); detailRequestID = request
            do {
                let selection = try await readRecords([id])
                guard request == detailRequestID, selectedRecordID == id,
                      accepts(selection.revision), let record = selection.records.first else { return }
                detailLibraryRevision = selection.revision
                if prior != record {
                    if let sourceID = selectedOriginalSourceID,
                       prior?.sources == record.sources {
                        recordDetailState = .loaded(record: record, sourceID: sourceID, original: originalDocument)
                    } else {
                        originalLoadTask?.cancel(); originalLoadID = nil
                        recordDetailState = .loaded(record: record, sourceID: record.sources.first.id, original: nil)
                    }
                }
            } catch LibraryReportError.recordNotFound { if request == detailRequestID { clearSelection() } }
            catch AppServiceError.recordUnavailable { if request == detailRequestID { clearSelection() } }
            catch {
                guard request == detailRequestID, selectedRecordID == id else { return }
                if await handleLibraryFailure(error) { return }
                guard request == detailRequestID, selectedRecordID == id else { return }
                if error as? SQLiteLibraryError == .damaged {
                    clearSelection()
                    reportBanner(.recordUnavailable)
                }
            }
            }
        }
        if let reviewID = reviewDraftID {
            let request = reviewRequestID
            do {
                let draft = try await readDraft(reviewID)
                if request == reviewRequestID, reviewingDraft?.id == reviewID, draft.state != .needsReview { reviewingDraft = nil }
            } catch LibraryReportError.draftNotFound { if request == reviewRequestID, reviewingDraft?.id == reviewID { reviewingDraft = nil } }
            catch AppServiceError.draftUnavailable { if request == reviewRequestID, reviewingDraft?.id == reviewID { reviewingDraft = nil } }
            catch {
                guard request == reviewRequestID, reviewingDraft?.id == reviewID else { return }
                if await handleLibraryFailure(error) { return }
                guard request == reviewRequestID, reviewingDraft?.id == reviewID else { return }
                if error as? SQLiteLibraryError == .damaged {
                    reviewingDraft = nil
                    reportBanner(.originalUnavailable)
                }
            }
        }
        await comparisonModel.reconcileSelection()
    }

    private func rebuildTimeline() {
        var sections: [AppTimelineSection] = []
        for entry in timelineEntries {
            let group = entry.timelineDate.map(TimelineDateGroup.dated) ?? .unknown
            if let last = sections.last, last.group == group {
                sections[sections.count - 1] = AppTimelineSection(group: group, entries: last.entries + [entry])
            } else { sections.append(AppTimelineSection(group: group, entries: [entry])) }
        }
        timelineSections = sections
    }

    private func reportBanner(_ message: AppBannerMessage) {
        let next = AppBanner(state: message)
        if hasModalPresentation || banner != nil {
            deferredBanner = next
        } else {
            banner = next
        }
    }

    private func beginReportRecognitionJob(total: Int) -> UUID {
        let id = UUID()
        reportRecognitionJobs.append(
            (id, ReportRecognitionActivity(position: 1, total: total))
        )
        publishReportRecognitionActivity()
        return id
    }

    private func advanceReportRecognitionJob(_ id: UUID, to position: Int) {
        guard let index = reportRecognitionJobs.firstIndex(where: { $0.id == id }) else { return }
        reportRecognitionJobs[index].activity = ReportRecognitionActivity(
            position: position,
            total: reportRecognitionJobs[index].activity.total
        )
        publishReportRecognitionActivity()
    }

    private func endReportRecognitionJob(_ id: UUID) {
        reportRecognitionJobs.removeAll { $0.id == id }
        publishReportRecognitionActivity()
    }

    /// Shows the most recently started job. The wait is explained once, for as
    /// long as any job keeps running.
    private func publishReportRecognitionActivity() {
        reportRecognitionActivity = reportRecognitionJobs.last?.activity
        guard !reportRecognitionJobs.isEmpty else {
            slowRecognitionNoticeTask?.cancel()
            slowRecognitionNoticeTask = nil
            isReportRecognitionSlow = false
            return
        }
        guard slowRecognitionNoticeTask == nil else { return }
        slowRecognitionNoticeTask = Task { [weak self, slowRecognitionNoticeDelay] in
            try? await Task.sleep(for: slowRecognitionNoticeDelay)
            guard !Task.isCancelled, let self, !self.reportRecognitionJobs.isEmpty else { return }
            self.isReportRecognitionSlow = true
        }
    }

    private func queueAutomaticReview(_ id: ImportDraft.ID) {
        pendingAutomaticReviewID = pendingAutomaticReviewID ?? id
        presentationDidEnd()
    }
}

actor UnavailableAppService: AppDataServicing, DICOMAppServicing {
    func timelinePage(memberID: UUID?, cursor: LibraryQueryCursor?) async throws -> LibraryTimelinePage { throw AppServiceError.vaultUnavailable }
    func reportPage(query: String, memberID: UUID?, cursor: LibraryQueryCursor?) async throws -> LibraryReportPage { throw AppServiceError.vaultUnavailable }
    func draftPage(states: [ImportState], cursor: LibraryQueryCursor?) async throws -> AppDraftPage { throw AppServiceError.vaultUnavailable }
    func loadRecords(ids: [UUID]) async throws -> LibraryRecordSelection { throw AppServiceError.vaultUnavailable }
    func loadMember(id: UUID) async throws -> FamilyMember { throw AppServiceError.vaultUnavailable }
    func loadDraft(id: UUID) async throws -> ImportDraft { throw AppServiceError.vaultUnavailable }
    func bootstrap() async throws -> AppSnapshot { throw AppServiceError.runtimeUnavailable }
    func refresh() async throws -> AppSnapshot { throw AppServiceError.vaultUnavailable }
    func createMember(displayName: String, disambiguationLabel: String?) async throws -> AppSnapshot { throw AppServiceError.vaultUnavailable }
    func updateMember(_ member: FamilyMember, replacing expected: FamilyMember) async throws -> AppSnapshot { throw AppServiceError.vaultUnavailable }
    func archiveMember(id: FamilyMember.ID) async throws -> AppSnapshot { throw AppServiceError.vaultUnavailable }
    func deleteMember(id: FamilyMember.ID) async throws -> AppSnapshot { throw AppServiceError.vaultUnavailable }
    func importFile(at url: URL) async throws -> AppImportOutcome { throw AppServiceError.vaultUnavailable }
    func retryDraft(id: ImportDraft.ID) async throws -> AppImportOutcome { throw AppServiceError.vaultUnavailable }
    func loadReview(draftID: ImportDraft.ID) async throws -> ImportReviewContent { throw AppServiceError.vaultUnavailable }
    func recognizeReview(_ command: RecognizeReviewCommand) async throws -> RecognizedReviewContent { throw AppServiceError.vaultUnavailable }
    func loadReviewOriginal(
        draftID: ImportDraft.ID,
        sourceID: ReportSource.ID,
        expectedRevision: UInt64,
        expectedLibrary: LibraryRevision
    ) async throws -> OriginalDocumentPayload { throw AppServiceError.vaultUnavailable }
    func confirmDraft(_ command: ConfirmDraftCommand) async throws -> AppSnapshot { throw AppServiceError.vaultUnavailable }
    func updateRecord(_ command: UpdateRecordCommand) async throws -> AppSnapshot { throw AppServiceError.vaultUnavailable }
    func ruleUpdate(recordID: HealthRecord.ID) async throws -> RecordRuleUpdate? { throw AppServiceError.vaultUnavailable }
    func applyRuleUpdate(_ command: ApplyRuleUpdateCommand) async throws -> AppSnapshot { throw AppServiceError.vaultUnavailable }
    func deleteRecord(id: HealthRecord.ID) async throws -> AppSnapshot { throw AppServiceError.vaultUnavailable }
    func deferDraft(_ command: DeferDraftCommand) async throws {
        throw AppServiceError.vaultUnavailable
    }
    func discardDraft(_ command: DiscardDraftCommand) async throws -> AppSnapshot {
        throw AppServiceError.vaultUnavailable
    }
    func loadOriginal(
        recordID: HealthRecord.ID,
        sourceID: ReportSource.ID,
        expectedRevision: UInt64,
        expectedLibrary: LibraryRevision
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
