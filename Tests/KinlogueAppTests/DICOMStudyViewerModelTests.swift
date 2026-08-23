import Foundation
import Testing
@testable import KinlogueApp
@testable import KinlogueCore
@testable import KinloguePlatform

@MainActor
struct DICOMStudyViewerModelTests {
    @Test
    func loadPrefersTheSeriesWithTheMostSlicesOverAnArbitrarySingleImageSeries() async throws {
        let study = dicomSummary(state: .confirmed)
        let singleImage = try viewerSession(
            studyID: study.id,
            seriesID: UUID(),
            instanceCount: 1
        )
        let primaryStack = try viewerSession(
            studyID: study.id,
            seriesID: UUID(),
            instanceCount: 184
        )
        let model = DICOMStudyViewerModel(
            studyID: study.id,
            metadataService: ViewerMetadataService(content: viewerContent(
                study: study,
                series: [
                    viewerSeriesSummary(session: singleImage, ordinal: 1),
                    viewerSeriesSummary(session: primaryStack, ordinal: 2),
                ]
            )),
            sliceService: ViewerSliceServiceSpy(sessions: [singleImage, primaryStack])
        )

        await model.load()

        #expect(model.selectedSeriesID == primaryStack.seriesID)
        #expect(model.totalSliceCount == 184)
        #expect(model.image?.instanceID == primaryStack.instances[0].id)
    }

    @Test
    func playbackLoopsThroughTheCurrentSeriesAndManualNavigationStopsIt() async throws {
        let study = dicomSummary(state: .confirmed)
        let session = try viewerSession(
            studyID: study.id,
            seriesID: UUID(),
            instanceCount: 3
        )
        let slices = ViewerSliceServiceSpy(sessions: [session])
        let model = DICOMStudyViewerModel(
            studyID: study.id,
            metadataService: ViewerMetadataService(content: viewerContent(
                study: study,
                series: [viewerSeriesSummary(session: session, ordinal: 1)]
            )),
            sliceService: slices,
            playbackSleep: { _ in try await Task.sleep(for: .milliseconds(1)) }
        )
        await model.load()

        model.startPlayback()
        #expect(model.isPlaying)
        await slices.waitForRenderCount(4)
        model.stopPlayback()

        let requests = await slices.renderRequests
        #expect(requests.prefix(4).map(\.instanceID) == [
            session.instances[0].id,
            session.instances[1].id,
            session.instances[2].id,
            session.instances[0].id,
        ])
        #expect(!model.isPlaying)

        model.startPlayback()
        await model.moveSlice(by: 1)
        #expect(!model.isPlaying)

        model.startPlayback()
        await model.close()
        #expect(!model.isPlaying)
    }

    @Test
    func stoppingPlaybackDuringAnInFlightRenderDoesNotBecomeASliceFailure() async throws {
        let study = dicomSummary(state: .confirmed)
        let session = try viewerSession(
            studyID: study.id,
            seriesID: UUID(),
            instanceCount: 3
        )
        let slices = ViewerSliceServiceSpy(sessions: [session])
        let model = DICOMStudyViewerModel(
            studyID: study.id,
            metadataService: ViewerMetadataService(content: viewerContent(
                study: study,
                series: [viewerSeriesSummary(session: session, ordinal: 1)]
            )),
            sliceService: slices,
            playbackSleep: { _ in try await Task.sleep(for: .milliseconds(1)) }
        )
        await model.load()
        await slices.delayNextRenderUntilCancelled()

        model.startPlayback()
        await slices.waitUntilCancellableRenderStarts()
        model.stopPlayback()
        try await Task.sleep(for: .milliseconds(10))

        #expect(model.phase == .ready)
        #expect(model.image?.instanceID == session.instances[0].id)
        #expect(model.currentSliceIndex == 0)
        #expect(!model.isPlaying)

        await model.moveSlice(by: 1)
        #expect(model.currentSliceIndex == 1)
        #expect(model.image?.instanceID == session.instances[1].id)
    }

    @Test
    func selectingAnotherSeriesStopsPlaybackAndRejectsItsInFlightRender() async throws {
        let study = dicomSummary(state: .confirmed)
        let first = try viewerSession(
            studyID: study.id,
            seriesID: UUID(),
            instanceCount: 3
        )
        let second = try viewerSession(
            studyID: study.id,
            seriesID: UUID(),
            instanceCount: 2
        )
        let slices = ViewerSliceServiceSpy(sessions: [first, second])
        let model = DICOMStudyViewerModel(
            studyID: study.id,
            metadataService: ViewerMetadataService(content: viewerContent(
                study: study,
                series: [
                    viewerSeriesSummary(session: first, ordinal: 1),
                    viewerSeriesSummary(session: second, ordinal: 2),
                ]
            )),
            sliceService: slices,
            playbackSleep: { _ in try await Task.sleep(for: .milliseconds(1)) }
        )
        await model.load()
        await slices.delayNextRenderUntilCancelled()

        model.startPlayback()
        await slices.waitUntilCancellableRenderStarts()
        await model.selectSeries(second.seriesID)

        #expect(!model.isPlaying)
        #expect(model.selectedSeriesID == second.seriesID)
        #expect(model.currentSliceIndex == 0)
        #expect(model.image?.instanceID == second.instances[0].id)
    }

    @Test
    func loadSelectsThePersistedFirstSliceAndPrefetchesOnlyItsNeighbor() async throws {
        let member = try FamilyMember(displayName: "Synthetic Viewer member")
        let date = Date(timeIntervalSinceReferenceDate: 8_000)
        let study = dicomSummary(
            state: .confirmed,
            memberID: member.id,
            effectiveDate: date
        )
        let seriesID = UUID()
        let session = try viewerSession(
            studyID: study.id,
            seriesID: seriesID,
            instanceCount: 2,
            ordering: .instanceNumberFallback
        )
        let metadata = ViewerMetadataService(content: viewerContent(
            study: study,
            series: [viewerSeriesSummary(session: session, ordinal: 1)],
            members: [member]
        ))
        let slices = ViewerSliceServiceSpy(sessions: [session])
        let model = DICOMStudyViewerModel(
            studyID: study.id,
            metadataService: metadata,
            sliceService: slices
        )

        await model.load()

        #expect(model.phase == .ready)
        #expect(model.selectedSeriesID == seriesID)
        #expect(model.currentSliceOrdinal == 1)
        #expect(model.totalSliceCount == 2)
        #expect(model.image?.instanceID == session.instances[0].id)
        #expect(model.memberLabel == member.displayName)
        #expect(model.effectiveDate == date)
        #expect(model.hasFallbackOrderingWarning)
        await slices.waitForPrefetchCount(1)
        #expect(await slices.prefetchedInstanceIDs == [session.instances[1].id])
    }

    @Test
    func reviewContentAvoidsASecondMetadataRead() async throws {
        let study = dicomSummary(state: .confirmed)
        let session = try viewerSession(
            studyID: study.id,
            seriesID: UUID(),
            instanceCount: 1
        )
        let content = viewerContent(
            study: study,
            series: [viewerSeriesSummary(session: session, ordinal: 1)]
        )
        let metadata = ViewerMetadataService(content: content)
        let model = DICOMStudyViewerModel(
            studyID: study.id,
            metadataService: metadata,
            sliceService: ViewerSliceServiceSpy(sessions: [session]),
            initialContent: content
        )

        await model.load()

        #expect(model.phase == .ready)
        #expect(await metadata.loadCallCount == 0)
    }

    @Test
    func latePriorSeriesResultCannotRepaintTheNewSeries() async throws {
        let study = dicomSummary(state: .confirmed)
        let first = try viewerSession(studyID: study.id, seriesID: UUID(), instanceCount: 1)
        let second = try viewerSession(studyID: study.id, seriesID: UUID(), instanceCount: 1)
        let metadata = ViewerMetadataService(content: viewerContent(
            study: study,
            series: [
                viewerSeriesSummary(session: first, ordinal: 1),
                viewerSeriesSummary(session: second, ordinal: 2),
            ]
        ))
        let slices = ViewerSliceServiceSpy(
            sessions: [first, second],
            delayedInstanceID: first.instances[0].id
        )
        let model = DICOMStudyViewerModel(
            studyID: study.id,
            metadataService: metadata,
            sliceService: slices
        )
        let initialLoad = Task { await model.load() }
        await slices.waitUntilDelayedRenderStarts()

        await model.selectSeries(second.seriesID)
        await slices.finishDelayedRender()
        await initialLoad.value

        #expect(model.phase == .ready)
        #expect(model.selectedSeriesID == second.seriesID)
        #expect(model.image?.instanceID == second.instances[0].id)
    }

    @Test
    func failedSliceKeepsNavigationAndOnlyCurrentRetryMayRepaint() async throws {
        let study = dicomSummary(state: .confirmed)
        let session = try viewerSession(studyID: study.id, seriesID: UUID(), instanceCount: 2)
        let metadata = ViewerMetadataService(content: viewerContent(
            study: study,
            series: [viewerSeriesSummary(session: session, ordinal: 1)]
        ))
        let slices = ViewerSliceServiceSpy(sessions: [session])
        let model = DICOMStudyViewerModel(
            studyID: study.id,
            metadataService: metadata,
            sliceService: slices
        )
        await model.load()
        await slices.failNextRender(for: session.instances[1].id)

        await model.selectSlice(at: 1)

        #expect(model.phase == .failed)
        #expect(model.image == nil)
        #expect(model.currentSliceOrdinal == 2)
        #expect(model.canRetry)

        await model.retry()

        #expect(model.phase == .ready)
        #expect(model.image?.instanceID == session.instances[1].id)
    }

    @Test
    func windowPanZoomFitAndResetRemainFiniteAndDeterministic() async throws {
        let study = dicomSummary(state: .confirmed)
        let session = try viewerSession(studyID: study.id, seriesID: UUID(), instanceCount: 1)
        let metadata = ViewerMetadataService(content: viewerContent(
            study: study,
            series: [viewerSeriesSummary(session: session, ordinal: 1)]
        ))
        let slices = ViewerSliceServiceSpy(sessions: [session])
        let model = DICOMStudyViewerModel(
            studyID: study.id,
            metadataService: metadata,
            sliceService: slices
        )
        await model.load()

        await model.adjustWindow(widthDelta: -1_000, centerDelta: 20)
        #expect(model.windowWidth == 1)
        #expect(model.windowCenter == 148)
        model.zoom(by: 2, anchorX: 0, anchorY: 0)
        model.pan(horizontal: 40, vertical: -10)
        #expect(model.zoomScale == 2)
        #expect(model.panOffset == .init(x: 40, y: -10))

        model.fit()
        #expect(model.zoomScale == 1)
        #expect(model.panOffset == .zero)

        await model.reset()
        #expect(model.windowCenter == 128)
        #expect(model.windowWidth == 256)
        #expect(model.zoomScale == 1)
        #expect(model.panOffset == .zero)
    }

    @Test
    func endpointNavigationDoesNotRenderTheSameSliceAgain() async throws {
        let study = dicomSummary(state: .confirmed)
        let session = try viewerSession(
            studyID: study.id,
            seriesID: UUID(),
            instanceCount: 2
        )
        let slices = ViewerSliceServiceSpy(sessions: [session])
        let model = DICOMStudyViewerModel(
            studyID: study.id,
            metadataService: ViewerMetadataService(content: viewerContent(
                study: study,
                series: [viewerSeriesSummary(session: session, ordinal: 1)]
            )),
            sliceService: slices
        )
        await model.load()
        let initialCount = await slices.renderRequests.count

        await model.moveSlice(by: -1)

        #expect(await slices.renderRequests.count == initialCount)
        #expect(model.currentSliceIndex == 0)
    }

    @Test
    func continuousWindowInputCoalescesToTheLatestRequestedWindow() async throws {
        let study = dicomSummary(state: .confirmed)
        let session = try viewerSession(
            studyID: study.id,
            seriesID: UUID(),
            instanceCount: 2
        )
        let slices = ViewerSliceServiceSpy(sessions: [session])
        let model = DICOMStudyViewerModel(
            studyID: study.id,
            metadataService: ViewerMetadataService(content: viewerContent(
                study: study,
                series: [viewerSeriesSummary(session: session, ordinal: 1)]
            )),
            sliceService: slices
        )
        await model.load()
        await slices.waitForPrefetchCount(1)
        await slices.delayNextWindowRender()

        let first = Task {
            await model.adjustWindow(widthDelta: 10, centerDelta: 1)
        }
        await slices.waitUntilDelayedWindowRenderStarts()
        let remaining = (0..<20).map { _ in
            Task { await model.adjustWindow(widthDelta: 1, centerDelta: 1) }
        }
        for task in remaining { await task.value }
        await slices.finishDelayedWindowRender()
        await first.value

        let windowRequests = await slices.renderRequests.filter {
            $0.windowCenter != nil
        }
        #expect(windowRequests.count == 2)
        #expect(windowRequests.last?.windowCenter == 149)
        #expect(windowRequests.last?.windowWidth == 286)
        #expect(model.windowCenter == 149)
        #expect(model.windowWidth == 286)
        #expect(await slices.prefetchedInstanceIDs.count == 1)
    }

    @Test
    func memoryPressureClearsTheImageAndCloseIsFinal() async throws {
        let study = dicomSummary(state: .confirmed)
        let session = try viewerSession(studyID: study.id, seriesID: UUID(), instanceCount: 1)
        let slices = ViewerSliceServiceSpy(sessions: [session])
        let model = DICOMStudyViewerModel(
            studyID: study.id,
            metadataService: ViewerMetadataService(content: viewerContent(
                study: study,
                series: [viewerSeriesSummary(session: session, ordinal: 1)]
            )),
            sliceService: slices
        )
        await model.load()

        await model.handleMemoryPressure()

        #expect(model.phase == .failed)
        #expect(model.image == nil)
        #expect(model.canRetry)
        #expect(await slices.memoryPressureCount == 1)

        await model.retry()
        #expect(model.phase == .ready)
        await model.close()

        #expect(model.phase == .closed)
        #expect(model.image == nil)
        #expect(model.series.isEmpty)
        #expect(model.windowCenter == nil)
        #expect(model.windowWidth == nil)
        #expect(model.zoomScale == 1)
        #expect(model.panOffset == .zero)
        #expect(await slices.closeCount == 1)
        await model.load()
        #expect(model.phase == .closed)
    }

    @Test
    func closePreventsAnInFlightRenderFromReappearing() async throws {
        let study = dicomSummary(state: .confirmed)
        let session = try viewerSession(studyID: study.id, seriesID: UUID(), instanceCount: 1)
        let slices = ViewerSliceServiceSpy(
            sessions: [session],
            delayedInstanceID: session.instances[0].id
        )
        let model = DICOMStudyViewerModel(
            studyID: study.id,
            metadataService: ViewerMetadataService(content: viewerContent(
                study: study,
                series: [viewerSeriesSummary(session: session, ordinal: 1)]
            )),
            sliceService: slices
        )
        let load = Task { await model.load() }
        await slices.waitUntilDelayedRenderStarts()

        await model.close()
        await slices.finishDelayedRender()
        await load.value

        #expect(model.phase == .closed)
        #expect(model.image == nil)
        #expect(await slices.closeCount == 1)
    }

    @Test
    func registryRevokesOnlyTheDeletedStudyThenRevokesEveryViewerForTheVault() async throws {
        let registry = DICOMViewerRegistry()
        let firstStudy = dicomSummary(state: .confirmed)
        let secondStudy = dicomSummary(state: .confirmed)
        let firstSession = try viewerSession(
            studyID: firstStudy.id,
            seriesID: UUID(),
            instanceCount: 1
        )
        let secondSession = try viewerSession(
            studyID: secondStudy.id,
            seriesID: UUID(),
            instanceCount: 1
        )
        let firstSlices = ViewerSliceServiceSpy(sessions: [firstSession])
        let secondSlices = ViewerSliceServiceSpy(sessions: [secondSession])
        let firstDismissal = ViewerDismissalRecorder()
        let secondDismissal = ViewerDismissalRecorder()
        let first = DICOMStudyViewerModel(
            studyID: firstStudy.id,
            metadataService: ViewerMetadataService(content: viewerContent(
                study: firstStudy,
                series: [viewerSeriesSummary(session: firstSession, ordinal: 1)]
            )),
            sliceService: firstSlices,
            viewerRegistry: registry
        )
        let second = DICOMStudyViewerModel(
            studyID: secondStudy.id,
            metadataService: ViewerMetadataService(content: viewerContent(
                study: secondStudy,
                series: [viewerSeriesSummary(session: secondSession, ordinal: 1)]
            )),
            sliceService: secondSlices,
            viewerRegistry: registry
        )
        first.activateWindow { firstDismissal.record() }
        second.activateWindow { secondDismissal.record() }
        await first.load()
        await second.load()
        await firstSlices.delayCloseUntilReleased()

        let singleStudyRevocation = Task {
            await registry.revoke(studyID: firstStudy.id)
        }
        await firstSlices.waitUntilCloseStarts()

        #expect(first.phase == .closed)
        #expect(first.image == nil)
        #expect(second.phase == .ready)
        #expect(second.image != nil)
        #expect(firstDismissal.count == 0)
        #expect(secondDismissal.count == 0)
        await firstSlices.finishDelayedClose()
        await singleStudyRevocation.value
        #expect(await firstSlices.closeCount == 1)
        #expect(await secondSlices.closeCount == 0)
        #expect(firstDismissal.count == 1)

        await registry.revokeAll()

        #expect(second.phase == .closed)
        #expect(second.image == nil)
        #expect(await secondSlices.closeCount == 1)
        #expect(secondDismissal.count == 1)
    }

    @Test
    func viewerRegisteredDuringWholeVaultRevocationIsClosedBeforeRevocationReturns() async throws {
        let registry = DICOMViewerRegistry()
        let firstStudy = dicomSummary(state: .confirmed)
        let secondStudy = dicomSummary(state: .confirmed)
        let firstSession = try viewerSession(
            studyID: firstStudy.id,
            seriesID: UUID(),
            instanceCount: 1
        )
        let firstSlices = ViewerSliceServiceSpy(sessions: [firstSession])
        let secondSlices = ViewerSliceServiceSpy(sessions: [])
        let firstDismissal = ViewerDismissalRecorder()
        let secondDismissal = ViewerDismissalRecorder()
        let first = DICOMStudyViewerModel(
            studyID: firstStudy.id,
            metadataService: ViewerMetadataService(content: viewerContent(
                study: firstStudy,
                series: [viewerSeriesSummary(session: firstSession, ordinal: 1)]
            )),
            sliceService: firstSlices,
            viewerRegistry: registry
        )
        first.activateWindow { firstDismissal.record() }
        await first.load()
        await firstSlices.delayCloseUntilReleased()

        let revocation = Task { await registry.revokeAll() }
        await firstSlices.waitUntilCloseStarts()
        let second = DICOMStudyViewerModel(
            studyID: secondStudy.id,
            metadataService: ViewerMetadataService(content: viewerContent(
                study: secondStudy,
                series: []
            )),
            sliceService: secondSlices,
            viewerRegistry: registry
        )
        second.activateWindow { secondDismissal.record() }

        #expect(second.phase == .closed)
        await firstSlices.finishDelayedClose()
        await revocation.value

        #expect(first.phase == .closed)
        #expect(second.phase == .closed)
        #expect(firstDismissal.count == 1)
        #expect(secondDismissal.count == 1)
        #expect(await firstSlices.closeCount == 1)
        #expect(await secondSlices.closeCount == 1)
    }

    @Test
    func viewerRegisteredWhileWholeVaultSnapshotPublicationIsPendingIsClosedBeforeFenceRelease() async throws {
        let registry = DICOMViewerRegistry()
        let study = dicomSummary(state: .confirmed)
        let slices = ViewerSliceServiceSpy(sessions: [])
        let dismissal = ViewerDismissalRecorder()
        let operationGate = ViewerRegistryOperationGate()

        let revocation = Task {
            await registry.withWholeVaultRevocation {
                await operationGate.wait()
            }
        }
        await operationGate.waitUntilStarted()
        let viewer = DICOMStudyViewerModel(
            studyID: study.id,
            metadataService: ViewerMetadataService(content: viewerContent(
                study: study,
                series: []
            )),
            sliceService: slices,
            viewerRegistry: registry
        )
        viewer.activateWindow { dismissal.record() }

        #expect(viewer.phase == .closed)
        await operationGate.release()
        await revocation.value

        #expect(viewer.phase == .closed)
        #expect(dismissal.count == 1)
        #expect(await slices.closeCount == 1)
    }

    @Test
    func aStudyWithoutViewableSeriesUsesAStableEmptyState() async {
        let study = dicomSummary(state: .confirmed)
        let model = DICOMStudyViewerModel(
            studyID: study.id,
            metadataService: ViewerMetadataService(content: viewerContent(
                study: study,
                series: []
            )),
            sliceService: ViewerSliceServiceSpy(sessions: [])
        )

        await model.load()

        #expect(model.phase == .empty)
        #expect(model.image == nil)
        #expect(model.totalSliceCount == 0)
        #expect(!model.hasFallbackOrderingWarning)
        #expect(model.statusAnnouncement == AppLocalization.string("这项检查没有可查看的影像序列"))
    }

    @Test
    func retainedSliceAnnouncementResolvesInTheRequestedLanguage() async throws {
        let study = dicomSummary(state: .confirmed)
        let session = try viewerSession(
            studyID: study.id,
            seriesID: UUID(),
            instanceCount: 2
        )
        let model = DICOMStudyViewerModel(
            studyID: study.id,
            metadataService: ViewerMetadataService(content: viewerContent(
                study: study,
                series: [viewerSeriesSummary(session: session, ordinal: 1)]
            )),
            sliceService: ViewerSliceServiceSpy(sessions: [session])
        )
        await model.load()
        await model.selectSlice(at: 1)

        #expect(
            model.statusAnnouncement(language: .simplifiedChinese)
                == "已显示第 2 张，共 2 张"
        )
        #expect(
            model.statusAnnouncement(language: .english)
                == "Showing slice 2 of 2"
        )
    }

    @Test
    func aSeriesOpenFailureCanRetryOnlyTheSelectedSeries() async throws {
        let study = dicomSummary(state: .confirmed)
        let session = try viewerSession(studyID: study.id, seriesID: UUID(), instanceCount: 1)
        let slices = ViewerSliceServiceSpy(sessions: [session])
        await slices.failNextOpen(for: session.seriesID)
        let model = DICOMStudyViewerModel(
            studyID: study.id,
            metadataService: ViewerMetadataService(content: viewerContent(
                study: study,
                series: [viewerSeriesSummary(session: session, ordinal: 1)]
            )),
            sliceService: slices
        )

        await model.load()
        #expect(model.phase == .failed)
        #expect(model.selectedSeriesID == session.seriesID)
        #expect(model.canRetry)

        await model.retry()

        #expect(model.phase == .ready)
        #expect(model.image?.instanceID == session.instances[0].id)
    }
}

private actor ViewerMetadataService: DICOMStudyViewerMetadataServicing {
    let content: DICOMStudyViewerContent
    private(set) var loadCallCount = 0

    init(content: DICOMStudyViewerContent) { self.content = content }

    func loadDICOMStudyViewer(studyID: DICOMStudy.ID) async throws -> DICOMStudyViewerContent {
        loadCallCount += 1
        guard content.study.id == studyID else { throw AppServiceError.dicomStudyUnavailable }
        return content
    }
}

private actor ViewerRegistryOperationGate {
    private var started = false
    private var isOpen = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        started = true
        let pendingStartWaiters = startWaiters
        startWaiters.removeAll()
        pendingStartWaiters.forEach { $0.resume() }
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        isOpen = true
        let pendingWaiters = waiters
        waiters.removeAll()
        pendingWaiters.forEach { $0.resume() }
    }
}

private struct ViewerRenderRequest: Equatable, Sendable {
    let instanceID: DICOMStudyIndex.Instance.ID
    let windowCenter: Double?
    let windowWidth: Double?
}

private actor ViewerSliceServiceSpy: DICOMSliceViewing {
    private let sessions: [DICOMStudyIndex.Series.ID: DICOMSliceSeriesSession]
    private let delayedInstanceID: DICOMStudyIndex.Instance.ID?
    private var delayedRenderContinuation: CheckedContinuation<Void, Never>?
    private var delayedRenderStarted = false
    private var delayedRenderStartedContinuation: CheckedContinuation<Void, Never>?
    private var failingInstanceIDs: Set<DICOMStudyIndex.Instance.ID> = []
    private var failingSeriesIDs: Set<DICOMStudyIndex.Series.ID> = []
    private var delayWindowRender = false
    private var delayRenderUntilCancelled = false
    private var cancellableRenderStarted = false
    private var cancellableRenderStartedContinuation: CheckedContinuation<Void, Never>?
    private var delayedWindowRenderStarted = false
    private var delayedWindowRenderContinuation: CheckedContinuation<Void, Never>?
    private var delayedWindowRenderStartedContinuation: CheckedContinuation<Void, Never>?
    private var prefetchWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var renderWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var delayClose = false
    private var closeStarted = false
    private var closeContinuation: CheckedContinuation<Void, Never>?
    private var closeStartedContinuation: CheckedContinuation<Void, Never>?
    private(set) var renderRequests: [ViewerRenderRequest] = []
    private(set) var prefetchedInstanceIDs: [DICOMStudyIndex.Instance.ID] = []
    private(set) var memoryPressureCount = 0
    private(set) var closeCount = 0

    init(
        sessions: [DICOMSliceSeriesSession],
        delayedInstanceID: DICOMStudyIndex.Instance.ID? = nil
    ) {
        self.sessions = Dictionary(uniqueKeysWithValues: sessions.map { ($0.seriesID, $0) })
        self.delayedInstanceID = delayedInstanceID
    }

    func openSeries(
        studyID: DICOMStudy.ID,
        seriesID: DICOMStudyIndex.Series.ID
    ) async throws -> DICOMSliceSeriesSession {
        if failingSeriesIDs.remove(seriesID) != nil {
            throw DICOMSliceServiceError.decoderUnavailable
        }
        guard let session = sessions[seriesID], session.studyID == studyID else {
            throw DICOMSliceServiceError.seriesUnavailable
        }
        return session
    }

    func render(
        session: DICOMSliceSeriesSession,
        instanceID: DICOMStudyIndex.Instance.ID,
        windowCenter: Double?,
        windowWidth: Double?
    ) async throws -> DICOMSliceImage {
        renderRequests.append(ViewerRenderRequest(
            instanceID: instanceID,
            windowCenter: windowCenter,
            windowWidth: windowWidth
        ))
        let readyRenderWaiters = renderWaiters.filter { renderRequests.count >= $0.0 }
        renderWaiters.removeAll { renderRequests.count >= $0.0 }
        for (_, continuation) in readyRenderWaiters { continuation.resume() }
        if windowCenter != nil, delayWindowRender {
            delayWindowRender = false
            delayedWindowRenderStarted = true
            delayedWindowRenderStartedContinuation?.resume()
            delayedWindowRenderStartedContinuation = nil
            await withCheckedContinuation { delayedWindowRenderContinuation = $0 }
        }
        if instanceID == delayedInstanceID {
            delayedRenderStarted = true
            delayedRenderStartedContinuation?.resume()
            delayedRenderStartedContinuation = nil
            await withCheckedContinuation { delayedRenderContinuation = $0 }
        }
        if delayRenderUntilCancelled {
            delayRenderUntilCancelled = false
            cancellableRenderStarted = true
            cancellableRenderStartedContinuation?.resume()
            cancellableRenderStartedContinuation = nil
            try await Task.sleep(for: .seconds(30))
        }
        if failingInstanceIDs.remove(instanceID) != nil {
            throw DICOMSliceServiceError.decoderUnavailable
        }
        let instance = try #require(session.instances.first { $0.id == instanceID })
        return DICOMSliceImage(
            instanceID: instanceID,
            rows: instance.attributes.rows,
            columns: instance.attributes.columns,
            windowCenter: windowCenter ?? instance.attributes.windowCenter ?? 128,
            windowWidth: windowWidth ?? instance.attributes.windowWidth ?? 256,
            pixels: DICOMSlicePixelBuffer(bytes: Data([0, 64, 128, 255]))
        )
    }

    func prefetch(
        session: DICOMSliceSeriesSession,
        instanceID: DICOMStudyIndex.Instance.ID
    ) async -> Bool {
        prefetchedInstanceIDs.append(instanceID)
        let ready = prefetchWaiters.filter { prefetchedInstanceIDs.count >= $0.0 }
        prefetchWaiters.removeAll { prefetchedInstanceIDs.count >= $0.0 }
        for (_, continuation) in ready { continuation.resume() }
        return true
    }

    func handleMemoryPressure() async { memoryPressureCount += 1 }
    func close() async {
        closeCount += 1
        if delayClose {
            delayClose = false
            closeStarted = true
            closeStartedContinuation?.resume()
            closeStartedContinuation = nil
            await withCheckedContinuation { closeContinuation = $0 }
        }
    }

    func failNextRender(for instanceID: DICOMStudyIndex.Instance.ID) {
        failingInstanceIDs.insert(instanceID)
    }

    func failNextOpen(for seriesID: DICOMStudyIndex.Series.ID) {
        failingSeriesIDs.insert(seriesID)
    }

    func waitUntilDelayedRenderStarts() async {
        guard !delayedRenderStarted else { return }
        await withCheckedContinuation { delayedRenderStartedContinuation = $0 }
    }

    func finishDelayedRender() {
        delayedRenderContinuation?.resume()
        delayedRenderContinuation = nil
    }

    func waitForPrefetchCount(_ count: Int) async {
        guard prefetchedInstanceIDs.count < count else { return }
        await withCheckedContinuation { prefetchWaiters.append((count, $0)) }
    }

    func waitForRenderCount(_ count: Int) async {
        guard renderRequests.count < count else { return }
        await withCheckedContinuation { renderWaiters.append((count, $0)) }
    }

    func delayNextRenderUntilCancelled() {
        delayRenderUntilCancelled = true
        cancellableRenderStarted = false
    }

    func waitUntilCancellableRenderStarts() async {
        guard !cancellableRenderStarted else { return }
        await withCheckedContinuation { cancellableRenderStartedContinuation = $0 }
    }

    func delayNextWindowRender() {
        delayWindowRender = true
    }

    func waitUntilDelayedWindowRenderStarts() async {
        guard !delayedWindowRenderStarted else { return }
        await withCheckedContinuation {
            delayedWindowRenderStartedContinuation = $0
        }
    }

    func finishDelayedWindowRender() {
        delayedWindowRenderContinuation?.resume()
        delayedWindowRenderContinuation = nil
    }

    func delayCloseUntilReleased() {
        delayClose = true
        closeStarted = false
    }

    func waitUntilCloseStarts() async {
        guard !closeStarted else { return }
        await withCheckedContinuation { closeStartedContinuation = $0 }
    }

    func finishDelayedClose() {
        closeContinuation?.resume()
        closeContinuation = nil
    }
}

@MainActor
private final class ViewerDismissalRecorder {
    private(set) var count = 0
    func record() { count += 1 }
}

private func viewerContent(
    study: DICOMStudySummary,
    series: [DICOMSeriesSummary],
    members: [FamilyMember] = []
) -> DICOMStudyViewerContent {
    let labels = RecordQuery.selectionLabels(for: members)
    return DICOMStudyViewerContent(
        study: study,
        confirmedMemberLabel: study.confirmedMemberID.flatMap { labels[$0] },
        viewableInstanceCount: series.reduce(0) { $0 + $1.sliceCount },
        inertObjectCount: 0,
        series: series
    )
}

private func viewerSeriesSummary(
    session: DICOMSliceSeriesSession,
    ordinal: Int
) -> DICOMSeriesSummary {
    DICOMSeriesSummary(
        id: session.seriesID,
        ordinal: ordinal,
        sliceCount: session.instances.count,
        rows: session.instances[0].attributes.rows,
        columns: session.instances[0].attributes.columns,
        orderingProvenance: session.orderingProvenance
    )
}

private func viewerSession(
    studyID: DICOMStudy.ID,
    seriesID: DICOMStudyIndex.Series.ID,
    instanceCount: Int,
    ordering: DICOMStudyIndex.OrderingProvenance = .geometryProjection
) throws -> DICOMSliceSeriesSession {
    let attributes = try DICOMStudyIndex.ImageAttributes(
        rows: 2,
        columns: 2,
        samplesPerPixel: 1,
        bitsAllocated: 16,
        bitsStored: 12,
        highBit: 11,
        pixelRepresentation: .unsigned,
        photometricInterpretation: .monochrome2,
        imagePositionPatient: try .init(x: 0, y: 0, z: 0),
        imageOrientationPatientRow: try .init(x: 1, y: 0, z: 0),
        imageOrientationPatientColumn: try .init(x: 0, y: 1, z: 0),
        rescaleSlope: 1,
        rescaleIntercept: 0,
        windowCenter: 128,
        windowWidth: 256
    )
    let revision = try VaultRevision(
        generation: 4,
        commitID: UUID(),
        catalogDigest: Data(repeating: 0x42, count: 32)
    )
    return try DICOMSliceSeriesSession(
        token: DICOMVaultSessionToken(vaultID: UUID(), revision: revision),
        studyID: studyID,
        seriesID: seriesID,
        orderingProvenance: ordering,
        instances: (0..<instanceCount).map { ordinal in
            try DICOMSliceInstanceDescriptor(
                id: UUID(),
                attachmentID: UUID(),
                contentDigest: Data(repeating: UInt8(ordinal + 1), count: 32),
                objectByteCount: 512,
                attributes: attributes
            )
        }
    )
}
