import Foundation

enum BackupOperationCoordinatorError: Error, Equatable, Sendable {
    case operationInProgress
    case destructiveOperationInProgress
}

/// One serialization point for every archive the App writes (manual, automatic and one-off
/// exports) and for whole-library replacement. A restore or a deletion takes the destructive
/// fence, which cancels an unpublished backup and waits for it before anything is replaced.
actor BackupOperationCoordinator {
    private struct ActiveOperation {
        let id: UUID
        let cancel: @Sendable () -> Void
        let wait: @Sendable () async -> Void
    }

    private var active: ActiveOperation?
    private var destructiveFenceHeld = false

    var isBusy: Bool { active != nil || destructiveFenceHeld }

    func run<Result: Sendable>(_ operation: @escaping @Sendable () async throws -> Result) async throws -> Result {
        guard !destructiveFenceHeld else { throw BackupOperationCoordinatorError.destructiveOperationInProgress }
        guard active == nil else { throw BackupOperationCoordinatorError.operationInProgress }
        let id = UUID()
        let task = Task<Result, Error> { try await operation() }
        active = ActiveOperation(id: id, cancel: { task.cancel() }, wait: { _ = await task.result })
        defer { finish(id) }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func cancelActiveOperation() {
        active?.cancel()
    }

    func cancelForApplicationTermination() {
        active?.cancel()
    }

    func withDestructiveFence<Result: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        guard !destructiveFenceHeld else { throw BackupOperationCoordinatorError.destructiveOperationInProgress }
        destructiveFenceHeld = true
        defer { destructiveFenceHeld = false }
        if let active {
            active.cancel()
            await active.wait()
            finish(active.id)
        }
        return try await operation()
    }

    private func finish(_ id: UUID) {
        guard active?.id == id else { return }
        active = nil
    }
}
