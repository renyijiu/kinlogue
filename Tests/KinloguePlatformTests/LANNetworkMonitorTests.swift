import Foundation
import Testing
@testable import KinloguePlatform

struct LANNetworkMonitorTests {
    private let advertised = LANNetworkAddress(
        interfaceName: "en0",
        host: "192.168.1.23",
        networkPrefixLength: 24
    )

    @Test
    func initialPathBaselineWithAdvertisedAddressDoesNotStopOrInvalidate() async throws {
        let snapshots = LockedNetworkSnapshots([eligibleAdvertisedSnapshot])
        let updates = FakeNetworkPathUpdateSource()
        let hooks = NetworkMonitorHooksSpy()
        let monitor = makeMonitor(
            snapshots: snapshots,
            updates: updates,
            hooks: hooks
        )
        try await monitor.start()

        snapshots.replace([
            eligibleAdvertisedSnapshot,
            .init(
                name: "en5",
                address: "10.0.0.8",
                networkPrefixLength: 8,
                isUp: true,
                isRunning: true
            ),
        ])
        updates.emitInitial()
        await waitUntilBaselineReceived(monitor)

        #expect(await monitor.state == .monitoring)
        #expect(await hooks.snapshot() == .init(stops: 0, invalidations: 0))
        #expect(updates.cancellationCount == 0)
        await monitor.stop()
    }

    @Test
    func disappearingAdvertisedAddressStopsAndInvalidatesExactlyOnce() async throws {
        let snapshots = LockedNetworkSnapshots([eligibleAdvertisedSnapshot])
        let updates = FakeNetworkPathUpdateSource()
        let hooks = NetworkMonitorHooksSpy()
        let monitor = makeMonitor(
            snapshots: snapshots,
            updates: updates,
            hooks: hooks
        )
        try await monitor.start()
        updates.emitInitial()
        await waitUntilBaselineReceived(monitor)

        snapshots.replace([
            .init(
                name: "en5",
                address: "10.0.0.8",
                networkPrefixLength: 8,
                isUp: true,
                isRunning: true
            ),
        ])
        updates.emitChange()
        await waitUntilInvalidated(monitor)
        updates.emitChange()
        await Task.yield()

        #expect(await hooks.snapshot() == .init(stops: 1, invalidations: 1))
        #expect(updates.cancellationCount == 1)
    }

    @Test
    func movingSameAddressToAnotherInterfaceInvalidatesTheAdvertisedPath() async throws {
        let snapshots = LockedNetworkSnapshots([eligibleAdvertisedSnapshot])
        let updates = FakeNetworkPathUpdateSource()
        let hooks = NetworkMonitorHooksSpy()
        let monitor = makeMonitor(
            snapshots: snapshots,
            updates: updates,
            hooks: hooks
        )
        try await monitor.start()
        updates.emitInitial()
        await waitUntilBaselineReceived(monitor)

        snapshots.replace([
            .init(
                name: "en5",
                address: advertised.host,
                networkPrefixLength: advertised.networkPrefixLength,
                isUp: true,
                isRunning: true
            ),
        ])
        updates.emitChange()
        await waitUntilInvalidated(monitor)

        #expect(await hooks.snapshot() == .init(stops: 1, invalidations: 1))
    }

    @Test
    func enumerationFailureAfterAPathUpdateFailsClosed() async throws {
        let snapshots = LockedNetworkSnapshots([eligibleAdvertisedSnapshot])
        let updates = FakeNetworkPathUpdateSource()
        let hooks = NetworkMonitorHooksSpy()
        let monitor = makeMonitor(
            snapshots: snapshots,
            updates: updates,
            hooks: hooks
        )
        try await monitor.start()

        snapshots.failReads()
        updates.emitInitial()
        await waitUntilInvalidated(monitor)

        #expect(await hooks.snapshot() == .init(stops: 1, invalidations: 1))
    }

    @Test
    func changedPrefixForTheSameInterfaceAndAddressFailsClosed() async throws {
        let snapshots = LockedNetworkSnapshots([eligibleAdvertisedSnapshot])
        let updates = FakeNetworkPathUpdateSource()
        let hooks = NetworkMonitorHooksSpy()
        let monitor = makeMonitor(
            snapshots: snapshots,
            updates: updates,
            hooks: hooks
        )
        try await monitor.start()

        snapshots.replace([.init(
            name: advertised.interfaceName,
            address: advertised.host,
            networkPrefixLength: 25,
            isUp: true,
            isRunning: true
        )])
        updates.emitInitial()
        await waitUntilInvalidated(monitor)

        #expect(await hooks.snapshot() == .init(stops: 1, invalidations: 1))
    }

    @Test
    func unsatisfiedDocumentedPathUpdateInvalidatesEvenBeforeFlagsSettle() async throws {
        let snapshots = LockedNetworkSnapshots([eligibleAdvertisedSnapshot])
        let updates = FakeNetworkPathUpdateSource()
        let hooks = NetworkMonitorHooksSpy()
        let monitor = makeMonitor(
            snapshots: snapshots,
            updates: updates,
            hooks: hooks
        )
        try await monitor.start()

        updates.emitInitial(routeIsSatisfied: false)
        await waitUntilInvalidated(monitor)

        #expect(await hooks.snapshot() == .init(stops: 1, invalidations: 1))
    }

    @Test
    func subsequentPathChangeInvalidatesWhenInterfaceAndIPAddressAreIdentical() async throws {
        let snapshots = LockedNetworkSnapshots([eligibleAdvertisedSnapshot])
        let updates = FakeNetworkPathUpdateSource()
        let hooks = NetworkMonitorHooksSpy()
        let monitor = makeMonitor(
            snapshots: snapshots,
            updates: updates,
            hooks: hooks
        )
        try await monitor.start()
        updates.emitInitial()
        await waitUntilBaselineReceived(monitor)

        // A Wi-Fi reconnect may recreate the route while retaining en0 and
        // 192.168.1.23. The public getifaddrs projection is intentionally left
        // identical; the subsequent NWPath delivery must still revoke R18.
        updates.emitChange()
        await waitUntilInvalidated(monitor)

        #expect(await hooks.snapshot() == .init(stops: 1, invalidations: 1))
        #expect(updates.cancellationCount == 1)
    }

    @Test
    func intentionalMonitorStopSuppressesLaterPathUpdates() async throws {
        let snapshots = LockedNetworkSnapshots([eligibleAdvertisedSnapshot])
        let updates = FakeNetworkPathUpdateSource()
        let hooks = NetworkMonitorHooksSpy()
        let monitor = makeMonitor(
            snapshots: snapshots,
            updates: updates,
            hooks: hooks
        )
        try await monitor.start()
        updates.emitInitial()
        await waitUntilBaselineReceived(monitor)
        await monitor.stop()

        snapshots.replace([])
        updates.emitChange()
        await Task.yield()

        #expect(await monitor.state == .stopped)
        #expect(await hooks.snapshot() == .init(stops: 0, invalidations: 0))
        #expect(updates.cancellationCount == 1)
    }

    @Test
    func unavailableAdvertisedPathCannotStartMonitoring() async {
        let snapshots = LockedNetworkSnapshots([])
        let updates = FakeNetworkPathUpdateSource()
        let hooks = NetworkMonitorHooksSpy()
        let monitor = makeMonitor(
            snapshots: snapshots,
            updates: updates,
            hooks: hooks
        )

        await #expect(throws: LANNetworkMonitorError.advertisedPathUnavailable) {
            try await monitor.start()
        }
        #expect(updates.startCount == 0)
        #expect(await hooks.snapshot() == .init(stops: 0, invalidations: 0))
    }

    @Test
    func monitorIsSingleUseAndNeverAutoRestarts() async throws {
        let snapshots = LockedNetworkSnapshots([eligibleAdvertisedSnapshot])
        let updates = FakeNetworkPathUpdateSource()
        let hooks = NetworkMonitorHooksSpy()
        let monitor = makeMonitor(
            snapshots: snapshots,
            updates: updates,
            hooks: hooks
        )
        try await monitor.start()

        await #expect(throws: LANNetworkMonitorError.alreadyStarted) {
            try await monitor.start()
        }
        await monitor.stop()
        await #expect(throws: LANNetworkMonitorError.stopped) {
            try await monitor.start()
        }
        #expect(updates.startCount == 1)
    }

    private var eligibleAdvertisedSnapshot: LANNetworkInterfaceSnapshot {
        .init(
            name: advertised.interfaceName,
            address: advertised.host,
            networkPrefixLength: advertised.networkPrefixLength,
            isUp: true,
            isRunning: true
        )
    }

    private func makeMonitor(
        snapshots: LockedNetworkSnapshots,
        updates: FakeNetworkPathUpdateSource,
        hooks: NetworkMonitorHooksSpy
    ) -> LANNetworkMonitor {
        LANNetworkMonitor(
            advertisedAddress: advertised,
            snapshotSource: { try snapshots.snapshot() },
            pathUpdateSource: updates,
            stopReceiving: { await hooks.recordStop() },
            invalidateCredential: { await hooks.recordInvalidation() }
        )
    }

    private func waitUntilInvalidated(_ monitor: LANNetworkMonitor) async {
        while await monitor.state != .invalidated {
            await Task.yield()
        }
    }

    private func waitUntilBaselineReceived(_ monitor: LANNetworkMonitor) async {
        while await monitor.hasReceivedPathBaseline == false {
            await Task.yield()
        }
    }
}

private enum SyntheticNetworkSnapshotError: Error {
    case failed
}

private final class LockedNetworkSnapshots: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [LANNetworkInterfaceSnapshot]
    private var shouldFail = false

    init(_ snapshots: [LANNetworkInterfaceSnapshot]) {
        self.snapshots = snapshots
    }

    func replace(_ snapshots: [LANNetworkInterfaceSnapshot]) {
        lock.withLock {
            self.snapshots = snapshots
            shouldFail = false
        }
    }

    func failReads() {
        lock.withLock { shouldFail = true }
    }

    func snapshot() throws -> [LANNetworkInterfaceSnapshot] {
        try lock.withLock {
            if shouldFail { throw SyntheticNetworkSnapshotError.failed }
            return snapshots
        }
    }
}

private final class FakeNetworkPathUpdateSource: LANNetworkPathUpdateSource, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (LANNetworkPathObservation) -> Void)?
    private var starts = 0
    private var cancellations = 0

    var startCount: Int { lock.withLock { starts } }
    var cancellationCount: Int { lock.withLock { cancellations } }

    func start(onUpdate: @escaping @Sendable (LANNetworkPathObservation) -> Void) {
        lock.withLock {
            starts += 1
            handler = onUpdate
        }
    }

    func cancel() {
        lock.withLock {
            cancellations += 1
            handler = nil
        }
    }

    func emitInitial(routeIsSatisfied: Bool = true) {
        emit(.init(
            delivery: .initial,
            routeIsSatisfied: routeIsSatisfied
        ))
    }

    func emitChange(routeIsSatisfied: Bool = true) {
        emit(.init(
            delivery: .changed,
            routeIsSatisfied: routeIsSatisfied
        ))
    }

    private func emit(_ observation: LANNetworkPathObservation) {
        let callback = lock.withLock { handler }
        callback?(observation)
    }
}

private actor NetworkMonitorHooksSpy {
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
