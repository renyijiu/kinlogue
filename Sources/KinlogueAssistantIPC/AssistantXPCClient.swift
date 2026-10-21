@preconcurrency import Foundation
import os

/// How the App reaches the bridge: encoded requests in, encoded replies out. Nil means the bridge
/// could not be reached or dropped the request.
public protocol KinlogueAssistantBridgeClient: Sendable {
    func status(_ request: Data) async -> Data?
    /// Cancelling the calling task asks the bridge to stop the turn with `requestID`.
    func respond(_ request: Data, requestID: UUID) async -> Data?
    func cancel(requestID: UUID) async -> Bool
}

/// The bridge over NSXPC. One connection is kept and replaced after it is invalidated; an
/// interrupted connection relaunches the service on the next message.
public final class KinlogueAssistantXPCClient: KinlogueAssistantBridgeClient {
    private let serviceName: String
    private let connection = OSAllocatedUnfairLock<NSXPCConnection?>(uncheckedState: nil)

    public init(serviceName: String = KinlogueAssistantService.name) {
        self.serviceName = serviceName
    }

    deinit {
        connection.withLockUnchecked { $0?.invalidate() }
    }

    public func status(_ request: Data) async -> Data? {
        await call { proxy, reply in proxy.status(request, reply: reply) }
    }

    public func respond(_ request: Data, requestID: UUID) async -> Data? {
        await withTaskCancellationHandler {
            await call { proxy, reply in proxy.respond(request, reply: reply) }
        } onCancel: {
            sendCancel(requestID)
        }
    }

    public func cancel(requestID: UUID) async -> Bool {
        await withCheckedContinuation { continuation in
            let once = Once()
            guard let proxy = proxy(onError: { if once.claim() { continuation.resume(returning: false) } }) else {
                if once.claim() { continuation.resume(returning: false) }
                return
            }
            proxy.cancel(requestID.uuidString) { cancelled in
                if once.claim() { continuation.resume(returning: cancelled) }
            }
        }
    }

    private func sendCancel(_ requestID: UUID) {
        proxy(onError: {})?.cancel(requestID.uuidString) { _ in }
    }

    private func call(_ send: (KinlogueAssistantBridgeXPCProtocol, @escaping @Sendable (Data) -> Void) -> Void) async -> Data? {
        await withCheckedContinuation { continuation in
            let once = Once()
            guard let proxy = proxy(onError: { if once.claim() { continuation.resume(returning: nil) } }) else {
                if once.claim() { continuation.resume(returning: nil) }
                return
            }
            send(proxy) { data in
                if once.claim() { continuation.resume(returning: data) }
            }
        }
    }

    private func proxy(onError: @escaping @Sendable () -> Void) -> KinlogueAssistantBridgeXPCProtocol? {
        let current = connection.withLockUnchecked { existing -> NSXPCConnection in
            if let existing { return existing }
            let created = NSXPCConnection(serviceName: serviceName)
            created.remoteObjectInterface = KinlogueAssistantXPCInterface.make()
            created.invalidationHandler = { [connection] in
                connection.withLockUnchecked { if $0 === created { $0 = nil } }
            }
            created.resume()
            existing = created
            return created
        }
        return current.remoteObjectProxyWithErrorHandler { _ in onError() } as? KinlogueAssistantBridgeXPCProtocol
    }
}

/// Exactly one of an XPC reply and its error handler resumes a continuation.
private final class Once: Sendable {
    private let claimed = OSAllocatedUnfairLock(initialState: false)

    func claim() -> Bool {
        claimed.withLock { claimed in
            defer { claimed = true }
            return !claimed
        }
    }
}
