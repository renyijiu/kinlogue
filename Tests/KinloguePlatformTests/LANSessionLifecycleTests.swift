import AppKit
import Foundation
import Testing
@testable import KinloguePlatform

struct LANSessionLifecycleTests {
    @Test(arguments: LANSessionLifecycleEvent.stoppingEvents)
    func publicLifecycleContractStopsAndInvalidates(
        _ event: LANSessionLifecycleEvent
    ) async {
        let hooks = PlatformLifecycleHooksSpy()
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
    func publicLifecycleContractDoesNotResumeOrStopForBenignEvents(
        _ event: LANSessionLifecycleEvent
    ) async {
        let hooks = PlatformLifecycleHooksSpy()
        let monitor = LANSessionLifecycleMonitor(
            stopReceiving: { await hooks.recordStop() },
            invalidateCredential: { await hooks.recordInvalidation() }
        )

        await monitor.handle(event)

        #expect(await monitor.state == .inactive)
        #expect(await hooks.snapshot() == .init(stops: 0, invalidations: 0))
    }

    @Test
    func aNewSessionIsRejectedUntilThePriorStopFinishes() async {
        let gate = LifecycleStopGate()
        let monitor = LANSessionLifecycleMonitor(
            stopReceiving: { await gate.wait() },
            invalidateCredential: { await gate.wait() }
        )
        let original = UUID()
        let replacement = UUID()
        #expect(await monitor.beginSession(credential: original))

        let stop = Task { await monitor.handle(.manualStop) }
        await gate.waitForCount(2)

        #expect(await monitor.state == .stopping)
        #expect(await monitor.beginSession(credential: replacement) == false)
        #expect(await monitor.isCredentialValid(replacement) == false)

        await gate.release()
        await stop.value
        #expect(await monitor.state == .inactive)
        #expect(await monitor.beginSession(credential: replacement))
        #expect(await monitor.isCredentialValid(replacement))
    }

    @Test @MainActor
    func documentedWorkspaceAndApplicationNotificationsDriveTheContract() async {
        let workspaceCenter = NotificationCenter()
        let applicationCenter = NotificationCenter()
        let hooks = PlatformLifecycleHooksSpy()
        let monitor = LANSessionLifecycleMonitor(
            stopReceiving: { await hooks.recordStop() },
            invalidateCredential: { await hooks.recordInvalidation() }
        )
        let adapter = LANSessionLifecycleNotificationAdapter(
            monitor: monitor,
            primaryWindow: nil,
            workspaceCenter: workspaceCenter,
            applicationCenter: applicationCenter
        )
        adapter.start()
        defer { adapter.stop() }
        #expect(await monitor.beginSession(credential: UUID()))

        applicationCenter.post(
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
        await Task.yield()
        #expect(await monitor.state == .receiving)

        workspaceCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        while await monitor.state != .inactive { await Task.yield() }
        #expect(await hooks.snapshot() == .init(stops: 1, invalidations: 1))
    }

    @Test @MainActor
    func onlyTheRegisteredPrimaryWindowCloseStopsReceiving() async {
        let workspaceCenter = NotificationCenter()
        let applicationCenter = NotificationCenter()
        let primary = NSWindow()
        let transient = NSWindow()
        let hooks = PlatformLifecycleHooksSpy()
        let monitor = LANSessionLifecycleMonitor(
            stopReceiving: { await hooks.recordStop() },
            invalidateCredential: { await hooks.recordInvalidation() }
        )
        let adapter = LANSessionLifecycleNotificationAdapter(
            monitor: monitor,
            primaryWindow: primary,
            workspaceCenter: workspaceCenter,
            applicationCenter: applicationCenter
        )
        adapter.start()
        defer { adapter.stop() }
        #expect(await monitor.beginSession(credential: UUID()))

        applicationCenter.post(name: NSWindow.willCloseNotification, object: transient)
        await Task.yield()
        #expect(await monitor.state == .receiving)

        applicationCenter.post(name: NSWindow.willCloseNotification, object: primary)
        while await monitor.state != .inactive { await Task.yield() }
        #expect(await hooks.snapshot() == .init(stops: 1, invalidations: 1))
    }
}

private actor PlatformLifecycleHooksSpy {
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

private actor LifecycleStopGate {
    private var count = 0
    private var released = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        count += 1
        guard !released else { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func waitForCount(_ expected: Int) async {
        while count < expected { await Task.yield() }
    }

    func release() {
        released = true
        let pending = continuations
        continuations.removeAll()
        for continuation in pending { continuation.resume() }
    }
}
