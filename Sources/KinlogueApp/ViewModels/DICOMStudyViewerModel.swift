import Foundation
import KinlogueCore
import KinloguePlatform

enum DICOMStudyViewerPhase: Equatable {
    case idle
    case loading
    case ready
    case empty
    case failed
    case closed
}

struct DICOMViewerOffset: Equatable, Sendable {
    var x: Double
    var y: Double

    static let zero = DICOMViewerOffset(x: 0, y: 0)
}

enum DICOMPlaybackRate: Int, CaseIterable, Identifiable, Sendable {
    case fps2 = 2
    case fps5 = 5
    case fps10 = 10
    case fps15 = 15

    var id: Int { rawValue }
    var interval: Duration { .seconds(1 / Double(rawValue)) }
}

private enum DICOMViewerStatusAnnouncement: Equatable {
    case loading
    case empty
    case viewerLoadFailed
    case memoryReleased
    case displayedSlice(ordinal: Int, total: Int)
    case sliceLoadFailed

    func localized(language: AppLanguage) -> String {
        switch self {
        case .loading:
            AppLocalization.string("正在加载影像切片", language: language)
        case .empty:
            AppLocalization.string("这项检查没有可查看的影像序列", language: language)
        case .viewerLoadFailed:
            AppLocalization.string("影像查看器加载失败", language: language)
        case .memoryReleased:
            AppLocalization.string("影像已从内存中释放，可以重试当前切片", language: language)
        case let .displayedSlice(ordinal, total):
            AppLocalization.string("已显示第 \(ordinal) 张，共 \(total) 张", language: language)
        case .sliceLoadFailed:
            AppLocalization.string("当前影像切片加载失败，可以重试", language: language)
        }
    }
}

@MainActor
final class DICOMStudyViewerModel: ObservableObject {
    private struct WindowRequest: Equatable, Sendable {
        let center: Double
        let width: Double
    }

    private struct PrefetchRequest: Equatable, Sendable {
        let token: DICOMVaultSessionToken
        let seriesID: DICOMStudyIndex.Series.ID
        let instanceID: DICOMStudyIndex.Instance.ID
    }

    let studyID: DICOMStudy.ID
    private let metadataService: any DICOMStudyViewerMetadataServicing
    private let sliceService: any DICOMSliceViewing
    private let viewerRegistry: DICOMViewerRegistry?
    private let playbackSleep: @Sendable (Duration) async throws -> Void
    private var initialContent: DICOMStudyViewerContent?
    private var currentSession: DICOMSliceSeriesSession?
    private var requestGeneration: UInt64 = 0
    private var requestedWindow: WindowRequest?
    private var pendingWindowRequest: WindowRequest?
    private var windowDrainID: UUID?
    private var lastPrefetchRequest: PrefetchRequest?
    private var playbackTask: Task<Void, Never>?
    private var playbackID: UUID?
    private var viewerRegistrationID: UUID?
    private var dismissWindow: (@MainActor () -> Void)?
    private var sliceServiceCloseTask: Task<Void, Never>?

    @Published private(set) var phase: DICOMStudyViewerPhase = .idle
    @Published private(set) var study: DICOMStudySummary?
    @Published private(set) var memberLabel: String?
    @Published private(set) var effectiveDate: Date?
    @Published private(set) var series: [DICOMSeriesSummary] = []
    @Published private(set) var inertObjectCount = 0
    @Published private(set) var selectedSeriesID: DICOMStudyIndex.Series.ID?
    @Published private(set) var currentSliceIndex = 0
    @Published private(set) var image: DICOMSliceImage?
    @Published private(set) var windowCenter: Double?
    @Published private(set) var windowWidth: Double?
    @Published private(set) var zoomScale = 1.0
    @Published private(set) var panOffset = DICOMViewerOffset.zero
    @Published private var statusAnnouncementState: DICOMViewerStatusAnnouncement?
    @Published private(set) var isPlaying = false
    @Published private(set) var playbackRate = DICOMPlaybackRate.fps10

    init(
        studyID: DICOMStudy.ID,
        metadataService: any DICOMStudyViewerMetadataServicing,
        sliceService: any DICOMSliceViewing,
        initialContent: DICOMStudyViewerContent? = nil,
        viewerRegistry: DICOMViewerRegistry? = nil,
        playbackSleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await ContinuousClock().sleep(for: $0)
        }
    ) {
        self.studyID = studyID
        self.metadataService = metadataService
        self.sliceService = sliceService
        self.initialContent = initialContent
        self.viewerRegistry = viewerRegistry
        self.playbackSleep = playbackSleep
    }

    func activateWindow(onDismiss: @escaping @MainActor () -> Void) {
        dismissWindow = onDismiss
        guard let viewerRegistry, viewerRegistrationID == nil, phase != .closed else {
            return
        }
        viewerRegistrationID = viewerRegistry.register(
            studyID: studyID,
            invalidate: { [weak self] in self?.invalidateForRegistryRevocation() },
            finishRevocation: { [weak self] in await self?.finishRegistryRevocation() }
        )
    }

    var selectedSeries: DICOMSeriesSummary? {
        guard let selectedSeriesID else { return nil }
        return series.first { $0.id == selectedSeriesID }
    }

    var currentSliceOrdinal: Int { currentSession == nil ? 0 : currentSliceIndex + 1 }
    var totalSliceCount: Int { currentSession?.instances.count ?? 0 }
    var totalViewableSliceCount: Int { series.reduce(0) { $0 + $1.sliceCount } }
    var selectedSeriesPosition: Int? {
        guard let selectedSeriesID,
              let index = series.firstIndex(where: { $0.id == selectedSeriesID }) else {
            return nil
        }
        return index
    }
    var canMoveToPreviousSeries: Bool { (selectedSeriesPosition ?? 0) > 0 }
    var canMoveToNextSeries: Bool {
        guard let selectedSeriesPosition else { return false }
        return selectedSeriesPosition < series.count - 1
    }
    var canPlay: Bool { phase == .ready && totalSliceCount > 1 }
    var canRetry: Bool { phase == .failed && selectedSeriesID != nil }
    var hasFallbackOrderingWarning: Bool {
        guard let selectedSeries else { return false }
        return selectedSeries.orderingProvenance != .geometryProjection
    }

    var errorMessage: String? {
        guard phase == .failed else { return nil }
        return AppLocalization.string("无法显示当前影像切片")
    }

    var statusAnnouncement: String? {
        statusAnnouncement(language: AppLocalization.selectedLanguage())
    }

    func statusAnnouncement(language: AppLanguage) -> String? {
        statusAnnouncementState?.localized(language: language)
    }

    func load() async {
        guard phase == .idle else { return }
        let generation = beginRequest(clearImage: true, announceLoading: true)
        do {
            let content: DICOMStudyViewerContent
            if let initialContent {
                self.initialContent = nil
                content = initialContent
            } else {
                content = try await metadataService.loadDICOMStudyViewer(studyID: studyID)
            }
            guard isCurrent(generation) else { return }
            study = content.study
            memberLabel = content.confirmedMemberLabel
            effectiveDate = content.study.effectiveDate
            inertObjectCount = content.inertObjectCount
            series = content.series.sorted { $0.ordinal < $1.ordinal }
            guard let preferred = series.min(by: Self.preferredSeriesPrecedes) else {
                phase = .empty
                statusAnnouncementState = .empty
                return
            }
            await selectSeries(preferred.id)
        } catch {
            guard isCurrent(generation) else { return }
            phase = .failed
            statusAnnouncementState = .viewerLoadFailed
        }
    }

    func selectSeries(_ id: DICOMStudyIndex.Series.ID) async {
        guard series.contains(where: { $0.id == id }), phase != .closed else { return }
        stopPlayback()
        invalidateWindowDrain()
        let generation = beginRequest(clearImage: true, announceLoading: true)
        selectedSeriesID = id
        currentSliceIndex = 0
        currentSession = nil
        requestedWindow = nil
        lastPrefetchRequest = nil
        windowCenter = nil
        windowWidth = nil
        fit()
        do {
            let session = try await sliceService.openSeries(studyID: studyID, seriesID: id)
            guard isCurrent(generation), selectedSeriesID == id else { return }
            currentSession = session
            await renderCurrent(generation: generation, window: nil)
        } catch {
            guard !Task.isCancelled else { return }
            failIfCurrent(generation)
        }
    }

    func selectSlice(at index: Int) async {
        stopPlayback()
        await displaySlice(at: index)
    }

    private func displaySlice(at index: Int, forPlayback: Bool = false) async {
        guard let session = currentSession,
              session.instances.indices.contains(index), phase != .closed else { return }
        invalidateWindowDrain()
        let generation = beginRequest(
            clearImage: !forPlayback,
            announceLoading: !forPlayback
        )
        if !forPlayback { currentSliceIndex = index }
        requestedWindow = nil
        windowCenter = nil
        windowWidth = nil
        await renderCurrent(
            generation: generation,
            window: nil,
            sliceIndex: index,
            commitsSliceIndex: forPlayback,
            announcesSlice: !forPlayback
        )
    }

    func moveSlice(by delta: Int) async {
        stopPlayback()
        guard totalSliceCount > 0 else { return }
        let target = min(max(0, currentSliceIndex + delta), totalSliceCount - 1)
        guard target != currentSliceIndex else { return }
        await displaySlice(at: target)
    }

    func moveSeries(by delta: Int) async {
        guard let selectedSeriesPosition else { return }
        let target = selectedSeriesPosition + delta
        guard series.indices.contains(target) else { return }
        await selectSeries(series[target].id)
    }

    func setPlaybackRate(_ rate: DICOMPlaybackRate) {
        playbackRate = rate
    }

    func togglePlayback() {
        isPlaying ? stopPlayback() : startPlayback()
    }

    func startPlayback() {
        guard canPlay else { return }
        stopPlayback()
        let id = UUID()
        let sleep = playbackSleep
        playbackID = id
        isPlaying = true
        playbackTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.playbackRate.interval else { return }
                do {
                    try await sleep(interval)
                } catch {
                    break
                }
                guard let self else { break }
                guard await self.advancePlayback(id: id) else { break }
            }
            self?.finishPlayback(id: id)
        }
    }

    func stopPlayback() {
        playbackID = nil
        playbackTask?.cancel()
        playbackTask = nil
        isPlaying = false
    }

    func adjustWindow(widthDelta: Double, centerDelta: Double) async {
        guard phase != .closed,
              widthDelta.isFinite, centerDelta.isFinite,
              currentSession != nil else { return }
        let base = pendingWindowRequest
            ?? requestedWindow
            ?? windowCenter.flatMap { center in
                windowWidth.map { WindowRequest(center: center, width: $0) }
            }
        guard let base else { return }
        let center = base.center + centerDelta
        let width = max(1, base.width + widthDelta)
        guard center.isFinite, width.isFinite else { return }
        let request = WindowRequest(center: center, width: width)
        requestedWindow = request
        pendingWindowRequest = request
        guard windowDrainID == nil else { return }

        let drainID = UUID()
        windowDrainID = drainID
        defer {
            if windowDrainID == drainID { windowDrainID = nil }
        }
        while windowDrainID == drainID, let pending = pendingWindowRequest {
            pendingWindowRequest = nil
            let generation = beginRequest(clearImage: false, announceLoading: false)
            await renderCurrent(
                generation: generation,
                window: pending,
                announcesSlice: false,
                prefetchesNeighbor: false
            )
        }
    }

    func zoom(by factor: Double, anchorX: Double, anchorY: Double) {
        guard factor.isFinite, factor > 0, anchorX.isFinite, anchorY.isFinite else { return }
        let oldScale = zoomScale
        let newScale = min(8, max(0.25, oldScale * factor))
        let ratio = newScale / oldScale
        panOffset = DICOMViewerOffset(
            x: anchorX - ((anchorX - panOffset.x) * ratio),
            y: anchorY - ((anchorY - panOffset.y) * ratio)
        )
        zoomScale = newScale
    }

    func pan(horizontal: Double, vertical: Double) {
        guard horizontal.isFinite, vertical.isFinite else { return }
        let x = panOffset.x + horizontal
        let y = panOffset.y + vertical
        guard x.isFinite, y.isFinite else { return }
        panOffset = DICOMViewerOffset(x: x, y: y)
    }

    func fit() {
        zoomScale = 1
        panOffset = .zero
    }

    func reset() async {
        guard currentSession != nil, phase != .closed else { return }
        stopPlayback()
        invalidateWindowDrain()
        fit()
        requestedWindow = nil
        let generation = beginRequest(clearImage: true, announceLoading: true)
        await renderCurrent(generation: generation, window: nil)
    }

    func retry() async {
        guard canRetry else { return }
        guard currentSession != nil else {
            if let selectedSeriesID { await selectSeries(selectedSeriesID) }
            return
        }
        let generation = beginRequest(clearImage: true, announceLoading: true)
        await renderCurrent(generation: generation, window: requestedWindow)
    }

    func handleMemoryPressure() async {
        guard phase != .closed else { return }
        stopPlayback()
        invalidateWindowDrain()
        requestGeneration &+= 1
        image = nil
        lastPrefetchRequest = nil
        await sliceService.handleMemoryPressure()
        if currentSession != nil {
            phase = .failed
            statusAnnouncementState = .memoryReleased
        } else {
            phase = .idle
        }
    }

    func close() async {
        if let viewerRegistrationID {
            viewerRegistry?.unregister(viewerRegistrationID)
            self.viewerRegistrationID = nil
        }
        guard phase != .closed else {
            await finishSliceServiceClose()
            return
        }
        invalidateForClose()
        await finishSliceServiceClose()
    }

    private func invalidateForRegistryRevocation() {
        viewerRegistrationID = nil
        invalidateForClose()
    }

    private func finishRegistryRevocation() async {
        await finishSliceServiceClose()
        let dismissWindow = dismissWindow
        self.dismissWindow = nil
        dismissWindow?()
    }

    private func invalidateForClose() {
        guard phase != .closed else { return }
        stopPlayback()
        invalidateWindowDrain()
        requestGeneration &+= 1
        image = nil
        currentSession = nil
        selectedSeriesID = nil
        series = []
        study = nil
        memberLabel = nil
        effectiveDate = nil
        inertObjectCount = 0
        currentSliceIndex = 0
        requestedWindow = nil
        lastPrefetchRequest = nil
        windowCenter = nil
        windowWidth = nil
        fit()
        phase = .closed
        statusAnnouncementState = nil
    }

    private func finishSliceServiceClose() async {
        if let sliceServiceCloseTask {
            await sliceServiceCloseTask.value
            return
        }
        let sliceService = sliceService
        let task = Task { await sliceService.close() }
        sliceServiceCloseTask = task
        await task.value
    }

    private func advancePlayback(id: UUID) async -> Bool {
        guard playbackID == id, !Task.isCancelled,
              totalSliceCount > 1 else { return false }
        let target = (currentSliceIndex + 1) % totalSliceCount
        await displaySlice(at: target, forPlayback: true)
        return playbackID == id && phase == .ready && !Task.isCancelled
    }

    private func finishPlayback(id: UUID) {
        guard playbackID == id else { return }
        playbackID = nil
        playbackTask = nil
        isPlaying = false
    }

    private func renderCurrent(
        generation: UInt64,
        window: WindowRequest?,
        sliceIndex: Int? = nil,
        commitsSliceIndex: Bool = false,
        announcesSlice: Bool = true,
        prefetchesNeighbor: Bool = true
    ) async {
        let targetIndex = sliceIndex ?? currentSliceIndex
        guard let session = currentSession,
              session.instances.indices.contains(targetIndex) else {
            failIfCurrent(generation)
            return
        }
        let instance = session.instances[targetIndex]
        do {
            let rendered = try await sliceService.render(
                session: session,
                instanceID: instance.id,
                windowCenter: window?.center,
                windowWidth: window?.width
            )
            guard isCurrent(generation), currentSession == session,
                  session.instances[targetIndex].id == rendered.instanceID,
                  commitsSliceIndex || currentSliceIndex == targetIndex else { return }
            if commitsSliceIndex { currentSliceIndex = targetIndex }
            image = rendered
            windowCenter = rendered.windowCenter
            windowWidth = rendered.windowWidth
            if phase != .ready { phase = .ready }
            if announcesSlice {
                let announcement = DICOMViewerStatusAnnouncement.displayedSlice(
                    ordinal: currentSliceOrdinal,
                    total: totalSliceCount
                )
                if statusAnnouncementState != announcement {
                    statusAnnouncementState = announcement
                }
            }
            if prefetchesNeighbor, let neighbor = prefetchNeighbor(in: session) {
                prefetchIfNeeded(session: session, instanceID: neighbor.id)
            }
        } catch {
            guard !Task.isCancelled else { return }
            failIfCurrent(generation)
        }
    }

    private func prefetchNeighbor(
        in session: DICOMSliceSeriesSession
    ) -> DICOMSliceInstanceDescriptor? {
        let next = currentSliceIndex + 1
        if session.instances.indices.contains(next) { return session.instances[next] }
        let previous = currentSliceIndex - 1
        if session.instances.indices.contains(previous) { return session.instances[previous] }
        return nil
    }

    private func prefetchIfNeeded(
        session: DICOMSliceSeriesSession,
        instanceID: DICOMStudyIndex.Instance.ID
    ) {
        let request = PrefetchRequest(
            token: session.token,
            seriesID: session.seriesID,
            instanceID: instanceID
        )
        guard request != lastPrefetchRequest else { return }
        lastPrefetchRequest = request
        Task { [weak self, sliceService] in
            let succeeded = await sliceService.prefetch(
                session: session,
                instanceID: instanceID
            )
            guard !succeeded else { return }
            await MainActor.run {
                guard self?.lastPrefetchRequest == request else { return }
                self?.lastPrefetchRequest = nil
            }
        }
    }

    private func invalidateWindowDrain() {
        windowDrainID = nil
        pendingWindowRequest = nil
    }

    private func beginRequest(
        clearImage: Bool,
        announceLoading: Bool
    ) -> UInt64 {
        requestGeneration &+= 1
        if clearImage { image = nil }
        if announceLoading {
            phase = .loading
            statusAnnouncementState = .loading
        }
        return requestGeneration
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        generation == requestGeneration && phase != .closed
    }

    private func failIfCurrent(_ generation: UInt64) {
        guard isCurrent(generation) else { return }
        image = nil
        phase = .failed
        statusAnnouncementState = .sliceLoadFailed
    }

    private static func preferredSeriesPrecedes(
        _ lhs: DICOMSeriesSummary,
        _ rhs: DICOMSeriesSummary
    ) -> Bool {
        if lhs.sliceCount != rhs.sliceCount { return lhs.sliceCount > rhs.sliceCount }
        return lhs.ordinal < rhs.ordinal
    }
}
