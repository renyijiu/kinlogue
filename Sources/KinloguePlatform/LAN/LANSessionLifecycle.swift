import Foundation

public enum LANSessionLifecycleState: Equatable, Sendable {
    case inactive
    case receiving
    case stopping
}

public enum LANSessionLifecycleEvent: CaseIterable, Sendable {
    case manualStop
    case screenLocked
    case screenSaverStarted
    case systemWillSleep
    case userSessionResigned
    case networkPathChanged
    case lastPrimaryWindowClosed
    case applicationWillTerminate
    case focusLost
    case transientSheetPresented
    case transientSheetDismissed
    case systemDidWake
    case applicationDidRelaunch

    public static let stoppingEvents: [Self] = [
        .manualStop,
        .screenLocked,
        .screenSaverStarted,
        .systemWillSleep,
        .userSessionResigned,
        .networkPathChanged,
        .lastPrimaryWindowClosed,
        .applicationWillTerminate,
    ]

    public static let nonStoppingEvents: [Self] = [
        .focusLost,
        .transientSheetPresented,
        .transientSheetDismissed,
        .systemDidWake,
        .applicationDidRelaunch,
    ]

    public var endsSession: Bool { Self.stoppingEvents.contains(self) }
}

public actor LANSessionLifecycleMonitor {
    public typealias Hook = @Sendable () async -> Void

    public private(set) var state: LANSessionLifecycleState = .inactive
    private let stopReceiving: Hook
    private let invalidateCredential: Hook
    private var credential: UUID?

    public init(
        stopReceiving: @escaping Hook,
        invalidateCredential: @escaping Hook
    ) {
        self.stopReceiving = stopReceiving
        self.invalidateCredential = invalidateCredential
    }

    /// Returns false while a prior stop is still draining. This prevents an
    /// old stop hook from tearing down a newly issued credential or listener.
    @discardableResult
    public func beginSession(credential: UUID) -> Bool {
        guard state == .inactive else { return false }
        self.credential = credential
        state = .receiving
        return true
    }

    public func isCredentialValid(_ candidate: UUID) -> Bool {
        state == .receiving && credential == candidate
    }

    public func handle(_ event: LANSessionLifecycleEvent) async {
        guard event.endsSession, state == .receiving else { return }
        state = .stopping
        credential = nil
        async let stop: Void = stopReceiving()
        async let invalidate: Void = invalidateCredential()
        _ = await (stop, invalidate)
        state = .inactive
    }
}
