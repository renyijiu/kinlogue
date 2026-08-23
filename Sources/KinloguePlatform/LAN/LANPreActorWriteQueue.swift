import Foundation
import KinlogueCore

/// Establishes a synchronous linearization point before a retained write body
/// can cross an actor or executor hop.
///
/// Each turn waits only until its predecessor has been admitted to the sink
/// actor, not until that predecessor's descriptor IO finishes. The actor can
/// therefore retain its existing bounded write pipeline while every queued
/// body is already covered by an admission permit.
// SAFETY: `lock` protects closure state and the tail signal; the two static
// tasks are immutable after initialization.
final class LANPreActorWriteQueue: @unchecked Sendable {
    private static let successfulNoOp = Task<Void, Error> {}
    private static let rejectedNoOp = Task<Void, Error> {
        throw LANInboxError.invalidState
    }

    // SAFETY: `lock` protects the signal flag and waiter array; continuations
    // are removed under the lock and resumed exactly once after unlocking.
    final class Signal: @unchecked Sendable {
        private let lock = NSLock()
        private var isSignaled = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            await withCheckedContinuation { continuation in
                let resumeImmediately = lock.withLock {
                    if isSignaled { return true }
                    waiters.append(continuation)
                    return false
                }
                if resumeImmediately { continuation.resume() }
            }
        }

        func signal() {
            let pending = lock.withLock {
                guard !isSignaled else { return [CheckedContinuation<Void, Never>]() }
                isSignaled = true
                defer { waiters.removeAll() }
                return waiters
            }
            for waiter in pending { waiter.resume() }
        }
    }

    struct Turn: Sendable {
        let predecessor: Signal?
        let admitted: Signal
    }

    private let lock = NSLock()
    private var isClosed = false
    private var tail: Signal?

    /// Empty writes perform no asynchronous work and therefore need neither a
    /// queue turn nor an admission permit. Reusing one completed task prevents
    /// empty HTTP body frames from manufacturing an unbounded task chain. The
    /// lock check is their linearization point relative to terminal closure.
    func noOpWrite() -> Task<Void, Error> {
        lock.withLock { isClosed ? Self.rejectedNoOp : Self.successfulNoOp }
    }

    /// Must be called from the synchronous public write facade before it
    /// retains or copies the transferred body for asynchronous processing.
    func beginTurn() throws -> Turn {
        try lock.withLock {
            guard !isClosed else { throw LANInboxError.invalidState }
            let admitted = Signal()
            let turn = Turn(predecessor: tail, admitted: admitted)
            tail = admitted
            return turn
        }
    }

    /// Prevents later submissions and returns the last already-created turn.
    /// Terminal actor operations wait for this signal before inspecting their
    /// internal write tail, so no pre-terminal submission can be skipped.
    func closeAndSnapshotTail() -> Signal? {
        lock.withLock {
            isClosed = true
            return tail
        }
    }
}
