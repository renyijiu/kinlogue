import Foundation
import Network

public struct LANNetworkPathFingerprint: Equatable, Sendable {
    public let interfaceName: String
    public let host: String
    public let networkPrefixLength: Int
    public let routeIsSatisfied: Bool

    public init(
        interfaceName: String,
        host: String,
        networkPrefixLength: Int,
        routeIsSatisfied: Bool = true
    ) {
        self.interfaceName = interfaceName
        self.host = host
        self.networkPrefixLength = networkPrefixLength
        self.routeIsSatisfied = routeIsSatisfied
    }
}

public enum LANNetworkMonitorState: Equatable, Sendable {
    case idle
    case monitoring
    case invalidating
    case invalidated
    case stopped
}

public enum LANNetworkMonitorError: Error, Equatable, Sendable {
    case alreadyStarted
    case advertisedPathUnavailable
    case stopped
}

protocol LANNetworkPathUpdateSource: Sendable {
    func start(onUpdate: @escaping @Sendable (LANNetworkPathObservation) -> Void)
    func cancel()
}

struct LANNetworkPathObservation: Equatable, Sendable {
    enum Delivery: Equatable, Sendable {
        case initial
        case changed
    }

    let delivery: Delivery
    let routeIsSatisfied: Bool
}

/// Observes documented Network.framework path updates, then recomputes the
/// exact advertised interface/address with getifaddrs. It does not discover
/// peers, authorize subnets, advertise Bonjour services, or restart sessions.
public actor LANNetworkMonitor {
    public typealias Hook = @Sendable () async -> Void
    typealias SnapshotSource = @Sendable () throws -> [LANNetworkInterfaceSnapshot]

    public private(set) var state: LANNetworkMonitorState = .idle
    public let advertisedFingerprint: LANNetworkPathFingerprint
    private(set) var hasReceivedPathBaseline = false

    private let snapshotSource: SnapshotSource
    private let pathUpdateSource: any LANNetworkPathUpdateSource
    private let stopReceiving: Hook
    private let invalidateCredential: Hook

    public init(
        advertisedAddress: LANNetworkAddress,
        stopReceiving: @escaping Hook,
        invalidateCredential: @escaping Hook
    ) {
        self.advertisedFingerprint = .init(
            interfaceName: advertisedAddress.interfaceName,
            host: advertisedAddress.host,
            networkPrefixLength: advertisedAddress.networkPrefixLength
        )
        self.snapshotSource = { try LANNetworkInterfaceResolver.currentSnapshots() }
        self.pathUpdateSource = LANNWPathUpdateSource()
        self.stopReceiving = stopReceiving
        self.invalidateCredential = invalidateCredential
    }

    init(
        advertisedAddress: LANNetworkAddress,
        snapshotSource: @escaping SnapshotSource,
        pathUpdateSource: any LANNetworkPathUpdateSource,
        stopReceiving: @escaping Hook,
        invalidateCredential: @escaping Hook
    ) {
        self.advertisedFingerprint = .init(
            interfaceName: advertisedAddress.interfaceName,
            host: advertisedAddress.host,
            networkPrefixLength: advertisedAddress.networkPrefixLength
        )
        self.snapshotSource = snapshotSource
        self.pathUpdateSource = pathUpdateSource
        self.stopReceiving = stopReceiving
        self.invalidateCredential = invalidateCredential
    }

    public func start() throws {
        switch state {
        case .idle:
            break
        case .monitoring, .invalidating, .invalidated:
            throw LANNetworkMonitorError.alreadyStarted
        case .stopped:
            throw LANNetworkMonitorError.stopped
        }

        guard currentFingerprint() == advertisedFingerprint else {
            throw LANNetworkMonitorError.advertisedPathUnavailable
        }
        state = .monitoring
        pathUpdateSource.start { [weak self] observation in
            Task { await self?.handlePathUpdate(observation) }
        }
    }

    /// Stops observing without restarting or invalidating an otherwise-valid
    /// receiver. Session lifecycle code owns intentional/manual shutdown.
    public func stop() {
        guard state == .idle || state == .monitoring else { return }
        state = .stopped
        pathUpdateSource.cancel()
    }

    func handlePathUpdate(_ observation: LANNetworkPathObservation) async {
        guard state == .monitoring else { return }

        switch observation.delivery {
        case .initial:
            guard !hasReceivedPathBaseline else {
                await invalidateForPathChange()
                return
            }
            hasReceivedPathBaseline = true
            guard currentFingerprint(
                routeIsSatisfied: observation.routeIsSatisfied
            ) == advertisedFingerprint else {
                await invalidateForPathChange()
                return
            }
        case .changed:
            // `getifaddrs` cannot distinguish a Wi-Fi reconnect or route
            // replacement that reuses the same interface name and IP address.
            // NWPathMonitor's first delivery is the baseline; every later
            // documented path update therefore revokes this temporary session.
            // This conservative rule uses only public API and avoids silently
            // keeping credentials alive across an unobservable route generation.
            await invalidateForPathChange()
        }
    }

    private func invalidateForPathChange() async {
        guard state == .monitoring else { return }
        state = .invalidating
        pathUpdateSource.cancel()
        async let stop: Void = stopReceiving()
        async let invalidate: Void = invalidateCredential()
        _ = await (stop, invalidate)
        state = .invalidated
    }

    private func currentFingerprint(
        routeIsSatisfied: Bool = true
    ) -> LANNetworkPathFingerprint? {
        guard let snapshots = try? snapshotSource() else { return nil }
        let addresses = LANNetworkInterfaceResolver.eligibleAddresses(from: snapshots)
        guard let exact = addresses.first(where: {
            $0.interfaceName == advertisedFingerprint.interfaceName
                && $0.host == advertisedFingerprint.host
                && $0.networkPrefixLength == advertisedFingerprint.networkPrefixLength
        }) else {
            return nil
        }
        return .init(
            interfaceName: exact.interfaceName,
            host: exact.host,
            networkPrefixLength: exact.networkPrefixLength,
            routeIsSatisfied: routeIsSatisfied
        )
    }
}

// SAFETY: `lock` protects lifecycle flags while Network.framework callbacks are
// delivered on the private serial queue.
private final class LANNWPathUpdateSource: LANNetworkPathUpdateSource, @unchecked Sendable {
    private let lock = NSLock()
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "app.kinlogue.lan-network-path")
    private var started = false
    private var cancelled = false
    private var deliveredInitialPath = false
    private var deliveredTerminalChange = false

    func start(onUpdate: @escaping @Sendable (LANNetworkPathObservation) -> Void) {
        let shouldStart = lock.withLock {
            guard !started, !cancelled else { return false }
            started = true
            monitor.pathUpdateHandler = { [weak self] path in
                guard let self else { return }
                let observation: LANNetworkPathObservation? = self.lock.withLock {
                    guard !self.cancelled else { return nil }
                    if !self.deliveredInitialPath {
                        self.deliveredInitialPath = true
                        return .init(
                            delivery: .initial,
                            routeIsSatisfied: path.status == .satisfied
                        )
                    }
                    guard !self.deliveredTerminalChange else { return nil }
                    self.deliveredTerminalChange = true
                    return .init(
                        delivery: .changed,
                        routeIsSatisfied: path.status == .satisfied
                    )
                }
                if let observation {
                    onUpdate(observation)
                }
            }
            return true
        }
        if shouldStart {
            monitor.start(queue: queue)
        }
    }

    func cancel() {
        let shouldCancel = lock.withLock {
            guard !cancelled else { return false }
            cancelled = true
            monitor.pathUpdateHandler = nil
            return true
        }
        if shouldCancel {
            monitor.cancel()
        }
    }
}
