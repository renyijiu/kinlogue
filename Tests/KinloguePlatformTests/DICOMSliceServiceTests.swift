import Foundation
import KinlogueCore
import KinlogueDICOMIPC
import Testing
@testable import KinloguePlatform

struct DICOMSliceServiceTests {
    @Test
    func sameSliceConcurrentRequestsDeduplicateDecodeAndOnlyNewestReturns() async throws {
        let fixture = try SliceServiceFixture(instanceCount: 1, controlled: true)
        let service = DICOMSliceService(source: fixture.source)
        let session = try await service.openSeries(
            studyID: fixture.session.studyID,
            seriesID: fixture.session.seriesID
        )
        let instance = try #require(session.instances.first)

        let first = Task { try await service.render(session: session, instanceID: instance.id) }
        while await fixture.source.decodeCallCount == 0 {
            try await Task.sleep(for: .milliseconds(2))
        }
        let second = Task { try await service.render(session: session, instanceID: instance.id) }
        try await Task.sleep(for: .milliseconds(10))
        #expect(await fixture.source.decodeCallCount == 1)
        await fixture.source.release(instanceID: instance.id)

        let image = try await second.value
        #expect(try image.withGrayscaleBytes { Data($0) }
            == Data([0, 64, 128, 255]))
        await #expect(throws: DICOMSliceServiceError.cancelled) { _ = try await first.value }
        #expect(await fixture.source.decodeCallCount == 1)
    }

    @Test
    func newerForegroundPreventsLateOlderSliceFromRepainting() async throws {
        let fixture = try SliceServiceFixture(instanceCount: 2, controlled: true)
        let service = DICOMSliceService(source: fixture.source)
        let session = try await service.openSeries(
            studyID: fixture.session.studyID,
            seriesID: fixture.session.seriesID
        )
        let firstInstance = session.instances[0]
        let secondInstance = session.instances[1]
        let first = Task {
            try await service.render(session: session, instanceID: firstInstance.id)
        }
        while await fixture.source.decodeCallCount < 1 {
            try await Task.sleep(for: .milliseconds(2))
        }
        let second = Task {
            try await service.render(session: session, instanceID: secondInstance.id)
        }
        try await Task.sleep(for: .milliseconds(10))
        #expect(await fixture.source.decodeCallCount == 1)
        await fixture.source.release(instanceID: firstInstance.id)
        while await fixture.source.decodeCallCount < 2 {
            try await Task.sleep(for: .milliseconds(2))
        }
        await fixture.source.release(instanceID: secondInstance.id)
        #expect(try await second.value.instanceID == secondInstance.id)
        await #expect(throws: DICOMSliceServiceError.cancelled) { _ = try await first.value }
    }

    @Test
    func callerCancellationCannotPublishAndReleasesTheDecodeReservation() async throws {
        let fixture = try SliceServiceFixture(instanceCount: 1, controlled: true)
        let service = DICOMSliceService(source: fixture.source)
        let session = try await service.openSeries(
            studyID: fixture.session.studyID,
            seriesID: fixture.session.seriesID
        )
        let render = Task {
            try await service.render(
                session: session,
                instanceID: session.instances[0].id
            )
        }
        while await fixture.source.decodeCallCount == 0 {
            try await Task.sleep(for: .milliseconds(2))
        }

        render.cancel()
        await fixture.source.release(instanceID: session.instances[0].id)

        await #expect(throws: DICOMSliceServiceError.cancelled) {
            _ = try await render.value
        }
        let budget = await service.budgetSnapshotForTesting()
        #expect(budget.activeBytes == 0)
        #expect(budget.reservationCount == 0)
    }

    @Test
    func cancellingAnOlderSharedWaiterDoesNotCancelTheNewestWaiter() async throws {
        let fixture = try SliceServiceFixture(instanceCount: 1, controlled: true)
        let service = DICOMSliceService(source: fixture.source)
        let session = try await service.openSeries(
            studyID: fixture.session.studyID,
            seriesID: fixture.session.seriesID
        )
        let instance = session.instances[0]
        let older = Task {
            try await service.render(session: session, instanceID: instance.id)
        }
        while await fixture.source.decodeCallCount == 0 {
            try await Task.sleep(for: .milliseconds(2))
        }
        let newest = Task {
            try await service.render(session: session, instanceID: instance.id)
        }
        try await Task.sleep(for: .milliseconds(10))

        older.cancel()
        await fixture.source.release(instanceID: instance.id)

        await #expect(throws: DICOMSliceServiceError.cancelled) {
            _ = try await older.value
        }
        let image = try await newest.value
        #expect(try image.withGrayscaleBytes { Data($0) } == Data([0, 64, 128, 255]))
        #expect(await fixture.source.decodeCallCount == 1)
    }

    @Test
    func decoderFailureMapsToAStableErrorAndReleasesTheGlobalReservation() async throws {
        let session = try SliceServiceFixture.makeSession(instanceCount: 1)
        let source = StubVerifiedSliceSource(
            sessions: [session],
            controlled: false,
            failsDecode: true
        )
        let service = DICOMSliceService(source: source)
        let opened = try await service.openSeries(
            studyID: session.studyID,
            seriesID: session.seriesID
        )

        do {
            _ = try await service.render(
                session: opened,
                instanceID: opened.instances[0].id
            )
            Issue.record("Expected a stable decoder failure")
        } catch let error as DICOMSliceServiceError {
            #expect(error == .integrityFailure)
            #expect(String(describing: error) == "integrityFailure")
        }
        let budget = await service.budgetSnapshotForTesting()
        #expect(budget.activeBytes == 0)
        #expect(budget.reservationCount == 0)
    }

    @Test
    func windowHistoryIsNotACacheKeyAndPressureZeroizesCachedIntensity() async throws {
        let fixture = try SliceServiceFixture(instanceCount: 1, controlled: false)
        let service = DICOMSliceService(source: fixture.source)
        let session = try await service.openSeries(
            studyID: fixture.session.studyID,
            seriesID: fixture.session.seriesID
        )
        let instance = session.instances[0]
        _ = try await service.render(session: session, instanceID: instance.id)
        let adjusted = try await service.render(
            session: session,
            instanceID: instance.id,
            windowCenter: 64,
            windowWidth: 128
        )
        #expect(adjusted.windowCenter == 64)
        #expect(await fixture.source.decodeCallCount == 1)
        #expect(await service.cacheSnapshotForTesting().count == 1)

        await service.handleMemoryPressure()
        let cache = await service.cacheSnapshotForTesting()
        let budget = await service.budgetSnapshotForTesting()
        #expect(cache.count == 0)
        #expect(cache.zeroizedByteCount == 4 * MemoryLayout<Float>.stride)
        #expect(budget.activeBytes == 0)
        #expect(budget.cacheBytes == 0)
        #expect(budget.reservationCount == 0)
    }

    @Test
    func cachedRenderUsesTheDecodeLifecycleTicketAndRejectsRevocation() async throws {
        let fixture = try SliceServiceFixture(instanceCount: 1, controlled: false)
        let service = DICOMSliceService(source: fixture.source)
        let session = try await service.openSeries(
            studyID: fixture.session.studyID,
            seriesID: fixture.session.seriesID
        )
        let instance = session.instances[0]
        _ = try await service.render(session: session, instanceID: instance.id)

        await fixture.source.invalidateLifecycle()

        await #expect(throws: DICOMSliceServiceError.staleSession) {
            _ = try await service.render(
                session: session,
                instanceID: instance.id,
                windowCenter: 64,
                windowWidth: 128
            )
        }
    }

    @Test
    func closeInvalidatesTheReturnedRenderBufferWithoutLeavingBudgetOwnership() async throws {
        let fixture = try SliceServiceFixture(instanceCount: 1, controlled: false)
        let service = DICOMSliceService(source: fixture.source)
        let session = try await service.openSeries(
            studyID: fixture.session.studyID,
            seriesID: fixture.session.seriesID
        )
        let image = try await service.render(
            session: session,
            instanceID: session.instances[0].id
        )
        #expect(try image.withGrayscaleBytes { Data($0) }
            == Data([0, 64, 128, 255]))
        #expect(await service.budgetSnapshotForTesting().renderBytes > 0)

        await service.close()

        #expect(throws: DICOMSliceServiceError.cancelled) {
            _ = try image.withGrayscaleBytes { Data($0) }
        }
        let budget = await service.budgetSnapshotForTesting()
        #expect(budget.renderBytes == 0)
        #expect(budget.renderReservationCount == 0)
    }

    @Test
    func droppingAServiceInvalidatesItsImageAndReleasesItsRenderReservation() async throws {
        let fixture = try SliceServiceFixture(instanceCount: 1, controlled: false)
        let runtime = DICOMSliceRuntime(maximumMemoryBytes: 2_000)
        var service: DICOMSliceService? = DICOMSliceService(
            source: fixture.source,
            runtime: runtime
        )
        let weakService = WeakServiceBox(service)
        let session = try await service!.openSeries(
            studyID: fixture.session.studyID,
            seriesID: fixture.session.seriesID
        )
        let image = try await service!.render(
            session: session,
            instanceID: session.instances[0].id
        )
        #expect(runtime.budget.snapshot().renderBytes > 0)

        service = nil
        for _ in 0..<50 where weakService.value != nil {
            try await Task.sleep(for: .milliseconds(2))
        }

        #expect(weakService.value == nil)
        #expect(runtime.budget.snapshot().renderBytes == 0)
        #expect(throws: DICOMSliceServiceError.cancelled) {
            _ = try image.withGrayscaleBytes { Data($0) }
        }
    }

    @Test
    func prefetchWatcherDoesNotRetainAServiceWhileDecoderIsUnresponsive() async throws {
        let fixture = try SliceServiceFixture(instanceCount: 1, controlled: true)
        let runtime = DICOMSliceRuntime(maximumMemoryBytes: 2_000)
        var service: DICOMSliceService? = DICOMSliceService(
            source: fixture.source,
            runtime: runtime
        )
        let weakService = WeakServiceBox(service)
        let session = try await service!.openSeries(
            studyID: fixture.session.studyID,
            seriesID: fixture.session.seriesID
        )
        #expect(await service!.prefetch(
            session: session,
            instanceID: session.instances[0].id
        ))
        while await fixture.source.decodeCallCount == 0 {
            try await Task.sleep(for: .milliseconds(2))
        }

        service = nil
        for _ in 0..<50 where weakService.value != nil {
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(weakService.value == nil)

        await fixture.source.release(instanceID: session.instances[0].id)
    }

    @Test
    func foregroundPromotionOwnsTheCompletedPrefetchReservation() async throws {
        let fixture = try SliceServiceFixture(instanceCount: 1, controlled: true)
        let service = DICOMSliceService(source: fixture.source)
        let session = try await service.openSeries(
            studyID: fixture.session.studyID,
            seriesID: fixture.session.seriesID
        )
        let instance = session.instances[0]

        #expect(await service.prefetch(session: session, instanceID: instance.id))
        while await fixture.source.decodeCallCount == 0 {
            try await Task.sleep(for: .milliseconds(2))
        }
        let foreground = Task {
            try await service.render(session: session, instanceID: instance.id)
        }
        try await Task.sleep(for: .milliseconds(10))
        await fixture.source.release(instanceID: instance.id)

        let image = try await foreground.value
        #expect(image.instanceID == instance.id)
        #expect(await fixture.source.decodeCallCount == 1)
        #expect(await service.cacheSnapshotForTesting().count == 1)
    }

    @Test
    func closingOneServiceEvictsOnlyItsSessionTokenFromTheSharedCache() async throws {
        let firstFixture = try SliceServiceFixture(instanceCount: 1, controlled: false)
        let secondFixture = try SliceServiceFixture(instanceCount: 1, controlled: false)
        let runtime = DICOMSliceRuntime(maximumMemoryBytes: 4_000)
        let firstService = DICOMSliceService(source: firstFixture.source, runtime: runtime)
        let secondService = DICOMSliceService(source: secondFixture.source, runtime: runtime)
        let firstSession = try await firstService.openSeries(
            studyID: firstFixture.session.studyID,
            seriesID: firstFixture.session.seriesID
        )
        let secondSession = try await secondService.openSeries(
            studyID: secondFixture.session.studyID,
            seriesID: secondFixture.session.seriesID
        )
        _ = try await firstService.render(
            session: firstSession,
            instanceID: firstSession.instances[0].id
        )
        _ = try await secondService.render(
            session: secondSession,
            instanceID: secondSession.instances[0].id
        )
        #expect(await firstService.cacheSnapshotForTesting().count == 2)

        await firstService.close()

        #expect(await secondService.cacheSnapshotForTesting().count == 1)
        _ = try await secondService.render(
            session: secondSession,
            instanceID: secondSession.instances[0].id
        )
        #expect(await secondFixture.source.decodeCallCount == 1)
        await secondService.close()
    }

    @Test
    func switchingOneServicePreservesAnotherServicesSharedCacheEntry() async throws {
        let firstFixture = try SliceServiceFixture(instanceCount: 1, controlled: false)
        let replacement = try SliceServiceFixture.makeSession(instanceCount: 1)
        await firstFixture.source.add(replacement)
        let secondFixture = try SliceServiceFixture(instanceCount: 1, controlled: false)
        let runtime = DICOMSliceRuntime(maximumMemoryBytes: 4_000)
        let firstService = DICOMSliceService(source: firstFixture.source, runtime: runtime)
        let secondService = DICOMSliceService(source: secondFixture.source, runtime: runtime)
        let firstSession = try await firstService.openSeries(
            studyID: firstFixture.session.studyID,
            seriesID: firstFixture.session.seriesID
        )
        let secondSession = try await secondService.openSeries(
            studyID: secondFixture.session.studyID,
            seriesID: secondFixture.session.seriesID
        )
        _ = try await firstService.render(
            session: firstSession,
            instanceID: firstSession.instances[0].id
        )
        _ = try await secondService.render(
            session: secondSession,
            instanceID: secondSession.instances[0].id
        )

        _ = try await firstService.openSeries(
            studyID: replacement.studyID,
            seriesID: replacement.seriesID
        )

        #expect(await secondService.cacheSnapshotForTesting().count == 1)
        _ = try await secondService.render(
            session: secondSession,
            instanceID: secondSession.instances[0].id
        )
        #expect(await secondFixture.source.decodeCallCount == 1)
        await firstService.close()
        await secondService.close()
    }

    @Test
    func seriesSwitchAndCloseFenceLateDecodeAndFutureRequests() async throws {
        let firstFixture = try SliceServiceFixture(instanceCount: 1, controlled: true)
        let secondSession = try SliceServiceFixture.makeSession(instanceCount: 1)
        await firstFixture.source.add(secondSession)
        let service = DICOMSliceService(source: firstFixture.source)
        let firstSession = try await service.openSeries(
            studyID: firstFixture.session.studyID,
            seriesID: firstFixture.session.seriesID
        )
        let firstInstance = firstSession.instances[0]
        let old = Task {
            try await service.render(session: firstSession, instanceID: firstInstance.id)
        }
        while await firstFixture.source.decodeCallCount == 0 {
            try await Task.sleep(for: .milliseconds(2))
        }
        _ = try await service.openSeries(
            studyID: secondSession.studyID,
            seriesID: secondSession.seriesID
        )
        await firstFixture.source.release(instanceID: firstInstance.id)
        await #expect(throws: DICOMSliceServiceError.cancelled) { _ = try await old.value }

        await service.close()
        await #expect(throws: DICOMSliceServiceError.closed) {
            _ = try await service.openSeries(
                studyID: secondSession.studyID,
                seriesID: secondSession.seriesID
            )
        }
    }

    @Test
    func oversizedWorkingSetDisablesPrefetchAndFailsBeforeDecode() async throws {
        let attributes = try sliceAttributes(rows: 8_192, columns: 8_192)
        let session = try SliceServiceFixture.makeSession(
            instanceCount: 1,
            attributes: attributes
        )
        let source = StubVerifiedSliceSource(sessions: [session], controlled: false)
        let service = DICOMSliceService(source: source)
        let opened = try await service.openSeries(
            studyID: session.studyID,
            seriesID: session.seriesID
        )
        #expect(!(await service.prefetch(
            session: opened,
            instanceID: opened.instances[0].id
        )))
        await #expect(throws: DICOMSliceServiceError.resourceLimit) {
            _ = try await service.render(
                session: opened,
                instanceID: opened.instances[0].id
            )
        }
        #expect(await source.decodeCallCount == 0)
    }

    @Test
    func missingWindowPercentileScratchMustFitInsideTheGlobalBudget() async throws {
        let attributes = try sliceAttributes(windowCenter: nil, windowWidth: nil)
        let session = try SliceServiceFixture.makeSession(
            instanceCount: 1,
            attributes: attributes
        )
        let source = StubVerifiedSliceSource(sessions: [session], controlled: false)
        let service = DICOMSliceService(
            source: source,
            maximumMemoryBytes: 550
        )
        let opened = try await service.openSeries(
            studyID: session.studyID,
            seriesID: session.seriesID
        )

        await #expect(throws: DICOMSliceServiceError.resourceLimit) {
            _ = try await service.render(
                session: opened,
                instanceID: opened.instances[0].id
            )
        }
        #expect(await source.decodeCallCount == 0)
    }

    @Test
    func decoderReplyAndFrameRawCopiesMustBothFitInsideTheGlobalBudget() async throws {
        let session = try SliceServiceFixture.makeSession(instanceCount: 1)
        let source = StubVerifiedSliceSource(sessions: [session], controlled: false)
        let service = DICOMSliceService(
            source: source,
            maximumMemoryBytes: 548
        )
        let opened = try await service.openSeries(
            studyID: session.studyID,
            seriesID: session.seriesID
        )

        await #expect(throws: DICOMSliceServiceError.resourceLimit) {
            _ = try await service.render(
                session: opened,
                instanceID: opened.instances[0].id
            )
        }
        #expect(await source.decodeCallCount == 0)
    }

    @Test
    func lruCacheEnforcesCountAndZeroizesEvictions() async throws {
        let fixture = try SliceServiceFixture(instanceCount: 3, controlled: false)
        let service = DICOMSliceService(
            source: fixture.source,
            maximumCacheCount: 2,
            maximumCacheBytes: 1_024
        )
        let session = try await service.openSeries(
            studyID: fixture.session.studyID,
            seriesID: fixture.session.seriesID
        )
        for instance in session.instances {
            _ = try await service.render(session: session, instanceID: instance.id)
        }
        let cache = await service.cacheSnapshotForTesting()
        #expect(cache.count == 2)
        #expect(cache.byteCount == 2 * 4 * MemoryLayout<Float>.stride)
        #expect(cache.zeroizedByteCount == 4 * MemoryLayout<Float>.stride)
    }

    @Test
    func cacheEvictionZeroizesTheCanonicalStorageHeldByAllReferences() async throws {
        let fixture = try SliceServiceFixture(instanceCount: 1, controlled: false)
        let instance = fixture.session.instances[0]
        let canonical = try DICOMDisplayTransformer.canonicalize(
            sampleBytes: Data([0, 0, 64, 0, 128, 0, 255, 0]),
            attributes: instance.attributes
        )
        let budget = DICOMSliceMemoryBudget(maximumBytes: 1_024)
        let cache = DICOMSliceCache(
            maximumCount: 1,
            maximumBytes: 1_024,
            budget: budget
        )
        let reservation = try budget.reserveLease(512)
        _ = try await cache.insertTransferring(
            canonical,
            for: .init(
                token: fixture.session.token,
                contentDigest: instance.contentDigest,
                byteCount: instance.objectByteCount
            ),
            reservation: reservation,
            lifecycle: .transient(),
            renderBytes: 0
        )

        await cache.removeAll()

        #expect(canonical.withIntensities { Array($0) }.isEmpty)
        let snapshot = await cache.snapshot()
        #expect(snapshot.zeroizedByteCount == 4 * MemoryLayout<Float>.stride)
        #expect(budget.snapshot().cacheBytes == 0)
    }

    @Test
    func canonicalTooLargeForCacheIsZeroizedBeforeItsActiveLeaseTransfers() async throws {
        let fixture = try SliceServiceFixture(instanceCount: 1, controlled: false)
        let canonical = try DICOMDisplayTransformer.canonicalize(
            sampleBytes: Data([0, 0, 64, 0, 128, 0, 255, 0]),
            attributes: fixture.session.instances[0].attributes
        )
        let budget = DICOMSliceMemoryBudget(maximumBytes: 1_024)
        let cache = DICOMSliceCache(maximumCount: 1, maximumBytes: 8, budget: budget)
        let lease = try budget.reserveLease(512)

        _ = try await cache.insertTransferring(
            canonical,
            for: .init(
                token: fixture.session.token,
                contentDigest: fixture.session.instances[0].contentDigest,
                byteCount: fixture.session.instances[0].objectByteCount
            ),
            reservation: lease,
            lifecycle: .transient(),
            renderBytes: 0
        )

        #expect(canonical.withIntensities { Array($0) }.isEmpty)
        #expect(budget.snapshot().activeBytes == 0)
        #expect(budget.snapshot().cacheBytes == 0)
    }

    @Test
    func twoServicesShareOneProcessBudgetAcrossForegroundAndPrefetch() async throws {
        let firstFixture = try SliceServiceFixture(instanceCount: 1, controlled: true)
        let secondFixture = try SliceServiceFixture(instanceCount: 1, controlled: true)
        let runtime = DICOMSliceRuntime(
            maximumMemoryBytes: 1_000,
            maximumCacheCount: 32,
            maximumCacheBytes: 800
        )
        let firstService = DICOMSliceService(source: firstFixture.source, runtime: runtime)
        let secondService = DICOMSliceService(source: secondFixture.source, runtime: runtime)
        let firstSession = try await firstService.openSeries(
            studyID: firstFixture.session.studyID,
            seriesID: firstFixture.session.seriesID
        )
        let secondSession = try await secondService.openSeries(
            studyID: secondFixture.session.studyID,
            seriesID: secondFixture.session.seriesID
        )
        let firstTask = Task {
            try await firstService.render(
                session: firstSession,
                instanceID: firstSession.instances[0].id
            )
        }
        while await firstFixture.source.decodeCallCount == 0 {
            try await Task.sleep(for: .milliseconds(2))
        }
        let active = runtime.budget.snapshot()
        #expect(active.reservationCount == 1)
        #expect(active.activeBytes > 0)

        #expect(await secondService.prefetch(
            session: secondSession,
            instanceID: secondSession.instances[0].id
        ))
        try await Task.sleep(for: .milliseconds(10))
        #expect(await secondFixture.source.decodeCallCount == 0)
        let stillBounded = runtime.budget.snapshot()
        #expect(stillBounded.reservationCount == 1)
        #expect(stillBounded.activeBytes == active.activeBytes)

        await firstFixture.source.release(instanceID: firstSession.instances[0].id)
        _ = try await firstTask.value
        await firstService.close()
        await secondService.close()
        let released = runtime.budget.snapshot()
        #expect(released.activeBytes == 0)
        #expect(released.reservationCount == 0)
    }

    @Test
    func newestForegroundWaitsForTheCancelledActiveForegroundToFinish() async throws {
        let concurrency = DecodeConcurrencyProbe()
        let firstFixture = try SliceServiceFixture(
            instanceCount: 1,
            controlled: true,
            concurrency: concurrency
        )
        let secondFixture = try SliceServiceFixture(
            instanceCount: 1,
            controlled: true,
            concurrency: concurrency
        )
        let runtime = DICOMSliceRuntime(maximumMemoryBytes: 2_000)
        let firstService = DICOMSliceService(source: firstFixture.source, runtime: runtime)
        let secondService = DICOMSliceService(source: secondFixture.source, runtime: runtime)
        let firstSession = try await firstService.openSeries(
            studyID: firstFixture.session.studyID,
            seriesID: firstFixture.session.seriesID
        )
        let secondSession = try await secondService.openSeries(
            studyID: secondFixture.session.studyID,
            seriesID: secondFixture.session.seriesID
        )
        let first = Task {
            try await firstService.render(
                session: firstSession,
                instanceID: firstSession.instances[0].id
            )
        }
        while await firstFixture.source.decodeCallCount == 0 {
            try await Task.sleep(for: .milliseconds(2))
        }
        let second = Task {
            try await secondService.render(
                session: secondSession,
                instanceID: secondSession.instances[0].id
            )
        }
        try await Task.sleep(for: .milliseconds(25))

        #expect(await secondFixture.source.decodeCallCount == 0)
        #expect(await concurrency.maximumActiveCount == 1)

        await firstFixture.source.release(instanceID: firstSession.instances[0].id)
        while await secondFixture.source.decodeCallCount == 0 {
            try await Task.sleep(for: .milliseconds(2))
        }
        await secondFixture.source.release(instanceID: secondSession.instances[0].id)
        await #expect(throws: DICOMSliceServiceError.cancelled) { _ = try await first.value }
        #expect(try await second.value.instanceID == secondSession.instances[0].id)
        #expect(await concurrency.maximumActiveCount == 1)
    }

    @Test
    func newestPendingForegroundCancelsTheIntermediatePendingRequest() async throws {
        let concurrency = DecodeConcurrencyProbe()
        let activeFixture = try SliceServiceFixture(
            instanceCount: 1,
            controlled: true,
            concurrency: concurrency
        )
        let intermediateFixture = try SliceServiceFixture(
            instanceCount: 1,
            controlled: true,
            concurrency: concurrency
        )
        let newestFixture = try SliceServiceFixture(
            instanceCount: 1,
            controlled: true,
            concurrency: concurrency
        )
        let runtime = DICOMSliceRuntime(maximumMemoryBytes: 2_000)
        let activeService = DICOMSliceService(source: activeFixture.source, runtime: runtime)
        let intermediateService = DICOMSliceService(
            source: intermediateFixture.source,
            runtime: runtime
        )
        let newestService = DICOMSliceService(source: newestFixture.source, runtime: runtime)
        let activeSession = try await activeService.openSeries(
            studyID: activeFixture.session.studyID,
            seriesID: activeFixture.session.seriesID
        )
        let intermediateSession = try await intermediateService.openSeries(
            studyID: intermediateFixture.session.studyID,
            seriesID: intermediateFixture.session.seriesID
        )
        let newestSession = try await newestService.openSeries(
            studyID: newestFixture.session.studyID,
            seriesID: newestFixture.session.seriesID
        )
        let active = Task {
            try await activeService.render(
                session: activeSession,
                instanceID: activeSession.instances[0].id
            )
        }
        while await activeFixture.source.decodeCallCount == 0 {
            try await Task.sleep(for: .milliseconds(2))
        }
        let intermediate = Task {
            try await intermediateService.render(
                session: intermediateSession,
                instanceID: intermediateSession.instances[0].id
            )
        }
        try await Task.sleep(for: .milliseconds(5))
        let newest = Task {
            try await newestService.render(
                session: newestSession,
                instanceID: newestSession.instances[0].id
            )
        }
        try await Task.sleep(for: .milliseconds(10))
        #expect(await intermediateFixture.source.decodeCallCount == 0)
        #expect(await newestFixture.source.decodeCallCount == 0)

        await activeFixture.source.release(instanceID: activeSession.instances[0].id)
        while await newestFixture.source.decodeCallCount == 0 {
            try await Task.sleep(for: .milliseconds(2))
        }
        await newestFixture.source.release(instanceID: newestSession.instances[0].id)

        await #expect(throws: DICOMSliceServiceError.cancelled) { _ = try await active.value }
        await #expect(throws: DICOMSliceServiceError.cancelled) {
            _ = try await intermediate.value
        }
        #expect(try await newest.value.instanceID == newestSession.instances[0].id)
        #expect(await intermediateFixture.source.decodeCallCount == 0)
        #expect(await concurrency.maximumActiveCount == 1)
    }

    @Test
    func closingAPendingForegroundRemovesItWithoutStartingItsDecoder() async throws {
        let activeFixture = try SliceServiceFixture(instanceCount: 1, controlled: true)
        let pendingFixture = try SliceServiceFixture(instanceCount: 1, controlled: true)
        let runtime = DICOMSliceRuntime(maximumMemoryBytes: 2_000)
        let activeService = DICOMSliceService(source: activeFixture.source, runtime: runtime)
        let pendingService = DICOMSliceService(source: pendingFixture.source, runtime: runtime)
        let activeSession = try await activeService.openSeries(
            studyID: activeFixture.session.studyID,
            seriesID: activeFixture.session.seriesID
        )
        let pendingSession = try await pendingService.openSeries(
            studyID: pendingFixture.session.studyID,
            seriesID: pendingFixture.session.seriesID
        )
        let active = Task {
            try await activeService.render(
                session: activeSession,
                instanceID: activeSession.instances[0].id
            )
        }
        while await activeFixture.source.decodeCallCount == 0 {
            try await Task.sleep(for: .milliseconds(2))
        }
        let pending = Task {
            try await pendingService.render(
                session: pendingSession,
                instanceID: pendingSession.instances[0].id
            )
        }
        try await Task.sleep(for: .milliseconds(10))

        await pendingService.close()
        await activeFixture.source.release(instanceID: activeSession.instances[0].id)

        await #expect(throws: DICOMSliceServiceError.cancelled) { _ = try await active.value }
        await #expect(throws: DICOMSliceServiceError.cancelled) { _ = try await pending.value }
        #expect(await pendingFixture.source.decodeCallCount == 0)
    }

    @Test
    func retainedRenderCountsAgainstAnotherServicesDecodeReservation() async throws {
        let budget = DICOMSliceMemoryBudget(maximumBytes: 100)
        let decode = try budget.reserve(60)
        let transitioned = try budget.transition(
            decode,
            toCacheBytes: 0,
            renderBytes: 60
        )
        let render = try #require(transitioned)

        #expect(throws: DICOMSliceServiceError.resourceLimit) {
            _ = try budget.reserve(50)
        }

        budget.releaseRender(render)
        let released = budget.snapshot()
        #expect(released.activeBytes == 0)
        #expect(released.renderBytes == 0)
    }

    @Test
    func renderBudgetMaintainsACheckedCumulativeTotalAndIdempotentRelease() throws {
        let budget = DICOMSliceMemoryBudget(maximumBytes: 200)
        let first = try budget.reserveRender(60)
        let second = try budget.reserveRender(70)
        #expect(budget.snapshot().renderBytes == 130)

        budget.releaseRender(first)
        budget.releaseRender(first)
        #expect(budget.snapshot().renderBytes == 70)

        budget.releaseRender(second)
        let released = budget.snapshot()
        #expect(released.renderBytes == 0)
        #expect(released.renderReservationCount == 0)
    }

    @Test
    func lateOpenCannotOverwriteANewerSeriesSession() async throws {
        let first = try SliceServiceFixture.makeSession(instanceCount: 1)
        let second = try SliceServiceFixture.makeSession(instanceCount: 1)
        let source = ControlledOpenSliceSource(sessions: [first, second])
        let service = DICOMSliceService(source: source)
        let oldOpen = Task {
            try await service.openSeries(studyID: first.studyID, seriesID: first.seriesID)
        }
        while await source.openCallCount < 1 {
            try await Task.sleep(for: .milliseconds(2))
        }
        let newOpen = Task {
            try await service.openSeries(studyID: second.studyID, seriesID: second.seriesID)
        }
        while await source.openCallCount < 2 {
            try await Task.sleep(for: .milliseconds(2))
        }
        await source.release(seriesID: second.seriesID)
        let current = try await newOpen.value
        await source.release(seriesID: first.seriesID)
        await #expect(throws: DICOMSliceServiceError.cancelled) { _ = try await oldOpen.value }
        await #expect(throws: DICOMSliceServiceError.staleSession) {
            _ = try await service.render(
                session: first,
                instanceID: first.instances[0].id
            )
        }
        #expect(current.seriesID == second.seriesID)
    }
}

private struct SliceServiceFixture {
    let session: DICOMSliceSeriesSession
    let source: StubVerifiedSliceSource

    init(
        instanceCount: Int,
        controlled: Bool,
        concurrency: DecodeConcurrencyProbe? = nil
    ) throws {
        session = try Self.makeSession(instanceCount: instanceCount)
        source = StubVerifiedSliceSource(
            sessions: [session],
            controlled: controlled,
            concurrency: concurrency
        )
    }

    static func makeSession(
        instanceCount: Int,
        attributes: DICOMStudyIndex.ImageAttributes = try! sliceAttributes()
    ) throws -> DICOMSliceSeriesSession {
        let revision = try VaultRevision(
            generation: 3,
            commitID: UUID(),
            catalogDigest: Data(repeating: 0xa1, count: 32)
        )
        let token = try DICOMVaultSessionToken(vaultID: UUID(), revision: revision)
        return try DICOMSliceSeriesSession(
            token: token,
            studyID: UUID(),
            seriesID: UUID(),
            orderingProvenance: .geometryProjection,
            instances: (0..<instanceCount).map { ordinal in
                try DICOMSliceInstanceDescriptor(
                    id: UUID(),
                    attachmentID: UUID(),
                    contentDigest: Data(repeating: UInt8(ordinal + 1), count: 32),
                    objectByteCount: 512 + ordinal,
                    attributes: attributes
                )
            }
        )
    }
}

private actor StubVerifiedSliceSource: DICOMVerifiedSliceSource {
    private var sessions: [UUID: DICOMSliceSeriesSession]
    private let controlled: Bool
    private var continuations: [UUID: CheckedContinuation<KinlogueDICOMDecodedFrame, Error>] = [:]
    private(set) var decodeCallCount = 0
    private let failsDecode: Bool
    private let concurrency: DecodeConcurrencyProbe?
    private let lifecycle = SliceLifecycleValidity()

    init(
        sessions: [DICOMSliceSeriesSession],
        controlled: Bool,
        failsDecode: Bool = false,
        concurrency: DecodeConcurrencyProbe? = nil
    ) {
        self.sessions = Dictionary(uniqueKeysWithValues: sessions.map { ($0.seriesID, $0) })
        self.controlled = controlled
        self.failsDecode = failsDecode
        self.concurrency = concurrency
    }

    func add(_ session: DICOMSliceSeriesSession) {
        sessions[session.seriesID] = session
    }

    func openSeries(studyID: UUID, seriesID: UUID) async throws -> DICOMSliceSeriesSession {
        guard let session = sessions[seriesID], session.studyID == studyID else {
            throw DICOMSliceServiceError.seriesUnavailable
        }
        return session
    }

    func invalidateLifecycle() { lifecycle.invalidate() }

    func decode(
        _ instance: DICOMSliceInstanceDescriptor,
        in session: DICOMSliceSeriesSession
    ) async throws -> DICOMVerifiedDecodedFrame {
        decodeCallCount += 1
        if failsDecode { throw DICOMDecoderAdapterError.decoderFailed }
        guard controlled else {
            return DICOMVerifiedDecodedFrame(
                frame: frame(instance: instance),
                lifecycle: lifecycle.ticket()
            )
        }
        if let concurrency { await concurrency.started() }
        do {
            let frame = try await withCheckedThrowingContinuation { continuation in
                continuations[instance.id] = continuation
            }
            if let concurrency { await concurrency.finished() }
            return DICOMVerifiedDecodedFrame(frame: frame, lifecycle: lifecycle.ticket())
        } catch {
            if let concurrency { await concurrency.finished() }
            throw error
        }
    }

    func release(instanceID: UUID) {
        guard let continuation = continuations.removeValue(forKey: instanceID),
              let instance = sessions.values.flatMap(\.instances).first(where: {
                $0.id == instanceID
              }) else { return }
        continuation.resume(returning: frame(instance: instance))
    }

    private func frame(instance: DICOMSliceInstanceDescriptor) -> KinlogueDICOMDecodedFrame {
        let attributes = instance.attributes
        return KinlogueDICOMDecodedFrame(
            transferSyntaxUID: KinlogueDICOMSupportedObject.explicitVRLittleEndian,
            sopClassUID: KinlogueDICOMSupportedObject.mrImageStorage,
            studyInstanceUID: "2.25.9101",
            seriesInstanceUID: "2.25.9102",
            sopInstanceUID: "2.25.9103",
            modality: "MR",
            instanceNumber: 1,
            rows: attributes.rows,
            columns: attributes.columns,
            samplesPerPixel: attributes.samplesPerPixel,
            bitsAllocated: attributes.bitsAllocated,
            bitsStored: attributes.bitsStored,
            highBit: attributes.highBit,
            pixelRepresentation: attributes.pixelRepresentation == .unsigned ? 0 : 1,
            photometricInterpretation: attributes.photometricInterpretation == .monochrome1
                ? "MONOCHROME1" : "MONOCHROME2",
            numberOfFrames: 1,
            imagePositionPatient: attributes.imagePositionPatient.map { [$0.x, $0.y, $0.z] },
            imageOrientationPatient: attributes.imageOrientationPatientRow.flatMap { row in
                attributes.imageOrientationPatientColumn.map { column in
                    [row.x, row.y, row.z, column.x, column.y, column.z]
                }
            },
            windowCenter: attributes.windowCenter,
            windowWidth: attributes.windowWidth,
            rescaleIntercept: attributes.rescaleIntercept,
            rescaleSlope: attributes.rescaleSlope,
            sampleBytes: Data([0, 0, 64, 0, 128, 0, 255, 0])
        )
    }
}

private actor DecodeConcurrencyProbe {
    private var activeCount = 0
    private(set) var maximumActiveCount = 0

    func started() {
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
    }

    func finished() {
        activeCount -= 1
    }
}

private final class WeakServiceBox {
    weak var value: DICOMSliceService?

    init(_ value: DICOMSliceService?) {
        self.value = value
    }
}

private final class SliceLifecycleValidity: @unchecked Sendable {
    private let lock = NSLock()
    private var isCurrent = true

    func ticket() -> DICOMSliceLifecycleTicket {
        DICOMSliceLifecycleTicket { [self] in
            guard lock.withLock({ isCurrent }) else {
                throw DICOMSliceServiceError.staleSession
            }
        }
    }

    func invalidate() {
        lock.withLock { isCurrent = false }
    }
}

private actor ControlledOpenSliceSource: DICOMVerifiedSliceSource {
    private let sessions: [UUID: DICOMSliceSeriesSession]
    private var continuations: [UUID: CheckedContinuation<DICOMSliceSeriesSession, Error>] = [:]
    private(set) var openCallCount = 0

    init(sessions: [DICOMSliceSeriesSession]) {
        self.sessions = Dictionary(uniqueKeysWithValues: sessions.map { ($0.seriesID, $0) })
    }

    func openSeries(studyID: UUID, seriesID: UUID) async throws -> DICOMSliceSeriesSession {
        openCallCount += 1
        guard sessions[seriesID]?.studyID == studyID else {
            throw DICOMSliceServiceError.seriesUnavailable
        }
        return try await withCheckedThrowingContinuation { continuation in
            continuations[seriesID] = continuation
        }
    }

    func release(seriesID: UUID) {
        guard let session = sessions[seriesID] else { return }
        continuations.removeValue(forKey: seriesID)?.resume(returning: session)
    }

    func decode(
        _ instance: DICOMSliceInstanceDescriptor,
        in session: DICOMSliceSeriesSession
    ) async throws -> DICOMVerifiedDecodedFrame {
        throw DICOMSliceServiceError.decoderUnavailable
    }
}

private func sliceAttributes(
    rows: Int = 2,
    columns: Int = 2,
    windowCenter: Double? = 128,
    windowWidth: Double? = 256
) throws -> DICOMStudyIndex.ImageAttributes {
    try .init(
        rows: rows,
        columns: columns,
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
        windowCenter: windowCenter,
        windowWidth: windowWidth
    )
}
