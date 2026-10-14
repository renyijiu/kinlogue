import Foundation
import GRDB
import KinlogueCore

/// A bounded hint stream. Consumers reconcile against authoritative reads, including after gaps.
// SAFETY: the lock owns continuations; callbacks are delivered after releasing it.
final class SQLiteCommitNotifications: @unchecked Sendable {
    private let lock = NSLock()
    private var observers: [UUID: AsyncStream<LibraryRevision>.Continuation] = [:]
    func subscribe() -> AsyncStream<LibraryRevision> {
        let id = UUID()
        let pair = AsyncStream<LibraryRevision>.makeStream(bufferingPolicy: .bufferingNewest(1))
        lock.withLock { observers[id] = pair.continuation }
        pair.continuation.onTermination = { [weak self] _ in
            self?.lock.withLock { _ = self?.observers.removeValue(forKey: id) }
        }
        return pair.stream
    }
    func finish() {
        let continuations = lock.withLock {
            let values = Array(observers.values); observers.removeAll(); return values
        }
        for continuation in continuations { continuation.finish() }
    }
    func publish(_ revision: LibraryRevision?) {
        guard let revision else { return }
        let continuations = lock.withLock { Array(observers.values) }
        for continuation in continuations { continuation.yield(revision) }
    }
}

extension SQLiteLibraryStore {
    package func changes() -> AsyncStream<LibraryRevision> { notifications.subscribe() }

    /// Called while admission is held. Captures only a committed semantic revision change.
    /// The entry point publishes capture from its outer defer, after admission is released.
    func commitTransaction<T: Sendable>(_ queue: DatabaseQueue, capture: inout LibraryRevision?, _ body: (Database) throws -> T) throws -> T {
        let committed = try queue.write { db in
            let previous = try SQLiteLibraryState.read(from: db)
            let value = try body(db)
            let current = try SQLiteLibraryState.read(from: db)
            let revision = previous == current ? nil : LibraryRevision(libraryID: current.libraryID,
                openEpoch: openEpoch, generation: UInt64(current.generation), commitID: current.commitID)
            return (value, revision)
        }
        capture = committed.1
        return committed.0
    }
}
