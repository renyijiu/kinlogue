import Foundation
import KinlogueCore

/// One composition-owned subscriber. Hints never stand in for a database read.
@MainActor
final class AppLibraryObservationCoordinator {
    typealias Subscribe = @Sendable () -> AsyncStream<LibraryRevision>
    typealias Reconcile = @MainActor () async -> LibraryRevision?
    private let subscribe: Subscribe
    private let readCurrent: Reconcile
    private let onDurableChange: @MainActor () async -> Void
    private var subscriptionTask: Task<Void, Never>?
    private var subscriptionID: UUID?
    private var reconciliationTask: Task<Void, Never>?
    private var reconciliationID: UUID?
    private var pendingReconciliation = false
    private var currentRevision: LibraryRevision?
    private var running = false

    init(subscribe: @escaping Subscribe, reconcile: @escaping Reconcile,
         onDurableChange: @escaping @MainActor () async -> Void) {
        self.subscribe = subscribe; readCurrent = reconcile; self.onDurableChange = onDurableChange
    }

    deinit { subscriptionTask?.cancel(); reconciliationTask?.cancel() }

    /// Synchronous subscription must precede the first authoritative startup read.
    func install() {
        guard subscriptionTask == nil else { return }
        running = true
        let id = UUID(); subscriptionID = id
        let stream = subscribe()
        subscriptionTask = Task { [weak self] in
            defer {
                if self?.subscriptionID == id { self?.subscriptionTask = nil; self?.subscriptionID = nil }
            }
            for await _ in stream {
                guard !Task.isCancelled, let self else { return }
                await reconcile()
            }
        }
    }

    /// Used after startup, activation, wake and observer reconstruction, including missed hints.
    func reconcile() async {
        guard running, !Task.isCancelled else { return }
        install()
        if let task = reconciliationTask {
            pendingReconciliation = true
            await task.value
            return
        }
        let id = UUID(); reconciliationID = id
        let task = Task { [weak self] in
            guard let self else { return }
            repeat {
                pendingReconciliation = false
                guard running, !Task.isCancelled else { break }
                if let revision = await readCurrent(), running, !Task.isCancelled {
                    let previous = currentRevision
                    currentRevision = revision
                    if let previous, previous != revision { await onDurableChange() }
                }
            } while pendingReconciliation && running && !Task.isCancelled
        }
        reconciliationTask = task
        await task.value
        if reconciliationID == id { reconciliationTask = nil; reconciliationID = nil }
    }

    func stop() async {
        running = false
        let subscriber = subscriptionTask, reader = reconciliationTask
        subscriber?.cancel(); reader?.cancel()
        subscriptionTask = nil; subscriptionID = nil; reconciliationTask = nil; reconciliationID = nil
        pendingReconciliation = false; currentRevision = nil
        await subscriber?.value
        await reader?.value
    }
}
