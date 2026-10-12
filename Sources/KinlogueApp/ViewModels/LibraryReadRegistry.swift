import Foundation

/// The library reads a model has started and has not yet seen end.
///
/// Models start reads as unstructured tasks so that a newer request or a library shutdown can
/// cancel them. Every one of them must have ended before the library is closed or replaced, so
/// each stays registered here for as long as it runs.
@MainActor
final class LibraryReadRegistry {
    /// Returns once the read it was taken from has ended.
    typealias Drain = @Sendable () async -> Void

    private struct Entry {
        let cancel: @Sendable () -> Void
        let drain: Drain
    }

    private var active: [UUID: Entry] = [:]

    /// Registers a task whose end the caller reports with `end`.
    func register<Value: Sendable, Failure: Error>(_ task: Task<Value, Failure>) -> UUID {
        let id = UUID()
        active[id] = Entry(cancel: { task.cancel() }, drain: { _ = await task.result })
        return id
    }

    func end(_ id: UUID) { active.removeValue(forKey: id) }

    /// Keeps `task` registered until it ends. Cancelling the caller cancels the task.
    func value<Value: Sendable>(of task: Task<Value, Error>) async throws -> Value {
        let id = register(task)
        defer { end(id) }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    func value<Value: Sendable>(of task: Task<Value, Never>) async -> Value {
        let id = register(task)
        defer { end(id) }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    /// Starts `read` as a registered task and returns its value.
    func run<Value: Sendable>(_ read: @escaping @MainActor @Sendable () async throws -> Value) async throws -> Value {
        try await value(of: Task { try await read() })
    }

    /// Starts work that no caller awaits; it stays registered until it ends.
    func start(_ work: @escaping @MainActor @Sendable () async -> Void) {
        let id = UUID()
        let task = Task { [weak self] in
            await work()
            self?.end(id)
        }
        active[id] = Entry(cancel: { task.cancel() }, drain: { await task.value })
    }

    /// Cancels every read that is active now. Awaiting the returned drains waits for those reads
    /// to end; cancellation itself has already happened when this returns.
    @discardableResult
    func cancelAll() -> [Drain] {
        let entries = Array(active.values)
        entries.forEach { $0.cancel() }
        return entries.map(\.drain)
    }
}
