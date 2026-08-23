import Foundation
import Testing
@testable import KinlogueApp

struct LANSessionLifecycleMonitorTests {
    @Test(arguments: LANSessionLifecycleEvent.stoppingEvents)
    func securitySensitiveEventsStopAndInvalidateBeforeReturning(
        _ event: LANSessionLifecycleEvent
    ) async throws {
        let hooks = LifecycleHooksSpy()
        let monitor = LANSessionLifecycleMonitor(
            stopReceiving: { await hooks.recordStop() },
            invalidateCredential: { await hooks.recordInvalidation() }
        )
        let credential = UUID()
        await monitor.beginSession(credential: credential)

        await monitor.handle(event)

        #expect(await monitor.state == .inactive)
        #expect(await monitor.isCredentialValid(credential) == false)
        #expect(await hooks.snapshot() == .init(stops: 1, invalidations: 1))
    }

    @Test(arguments: LANSessionLifecycleEvent.nonStoppingEvents)
    func focusSheetWakeAndRelaunchDoNotStopOrReactivate(
        _ event: LANSessionLifecycleEvent
    ) async {
        let hooks = LifecycleHooksSpy()
        let monitor = LANSessionLifecycleMonitor(
            stopReceiving: { await hooks.recordStop() },
            invalidateCredential: { await hooks.recordInvalidation() }
        )

        await monitor.handle(event)

        #expect(await monitor.state == .inactive)
        #expect(await hooks.snapshot() == .init(stops: 0, invalidations: 0))
    }

    @Test
    func focusLossAndTransientSheetDoNotEndAnActiveSession() async {
        let hooks = LifecycleHooksSpy()
        let monitor = LANSessionLifecycleMonitor(
            stopReceiving: { await hooks.recordStop() },
            invalidateCredential: { await hooks.recordInvalidation() }
        )
        let credential = UUID()
        await monitor.beginSession(credential: credential)

        await monitor.handle(.focusLost)
        await monitor.handle(.transientSheetPresented)
        await monitor.handle(.transientSheetDismissed)

        #expect(await monitor.state == .receiving)
        #expect(await monitor.isCredentialValid(credential))
        #expect(await hooks.snapshot() == .init(stops: 0, invalidations: 0))
    }

    @Test
    func aSecondStopSignalIsIdempotent() async {
        let hooks = LifecycleHooksSpy()
        let monitor = LANSessionLifecycleMonitor(
            stopReceiving: { await hooks.recordStop() },
            invalidateCredential: { await hooks.recordInvalidation() }
        )
        await monitor.beginSession(credential: UUID())

        await monitor.handle(.lastPrimaryWindowClosed)
        await monitor.handle(.applicationWillTerminate)

        #expect(await hooks.snapshot() == .init(stops: 1, invalidations: 1))
    }
}

private actor LifecycleHooksSpy {
    struct Snapshot: Equatable, Sendable {
        let stops: Int
        let invalidations: Int
    }

    private var stops = 0
    private var invalidations = 0

    func recordStop() { stops += 1 }
    func recordInvalidation() { invalidations += 1 }
    func snapshot() -> Snapshot { .init(stops: stops, invalidations: invalidations) }
}
