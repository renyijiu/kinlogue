import Foundation
import KinlogueCore

enum LibraryLifecycleCoordinatorError: Error, Equatable, Sendable {
    case revoked
}

/// Process-local front half of whole-library destruction. Durable stores still
/// use the process-shared root lock; this coordinator first closes sockets and
/// revokes publication guards without holding that filesystem lease.
actor LibraryLifecycleCoordinator {
    typealias RevocationHook = @Sendable () async -> Void

    private enum State {
        case active
        case revoking
        case revoked
    }

    private var state: State = .active
    private var hooks: [UUID: RevocationHook] = [:]
    private var activeOperationCount = 0
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []
    private var revocationWaiters: [CheckedContinuation<Void, Never>] = []

    func requireActive() throws {
        guard state == .active else { throw LibraryLifecycleCoordinatorError.revoked }
    }

    func register(id: UUID, hook: @escaping RevocationHook) throws {
        try requireActive()
        hooks[id] = hook
    }

    func withActiveOperation<Result: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        try requireActive()
        activeOperationCount += 1
        defer { finishActiveOperation() }
        return try await operation()
    }

    func revoke() async {
        switch state {
        case .revoked:
            return
        case .revoking:
            await withCheckedContinuation { continuation in
                revocationWaiters.append(continuation)
            }
            return
        case .active:
            state = .revoking
        }
        let callbacks = Array(hooks.values)
        hooks.removeAll()
        await withTaskGroup(of: Void.self) { group in
            for callback in callbacks {
                group.addTask { await callback() }
            }
        }
        if activeOperationCount > 0 {
            await withCheckedContinuation { continuation in
                operationWaiters.append(continuation)
            }
        }
        state = .revoked
        let waiters = revocationWaiters
        revocationWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func finishActiveOperation() {
        precondition(activeOperationCount > 0)
        activeOperationCount -= 1
        guard activeOperationCount == 0 else { return }
        let waiters = operationWaiters
        operationWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

actor LifecycleCoordinatedVaultDestroyService: VaultDestroyServicing {
    private enum DestroyState {
        case idle
        case destroying(id: UUID, task: Task<Void, Error>)
        case destroyed
    }

    private let lifecycle: LibraryLifecycleCoordinator
    private let underlying: any VaultDestroyServicing
    private var destroyState: DestroyState = .idle

    init(
        lifecycle: LibraryLifecycleCoordinator,
        underlying: any VaultDestroyServicing
    ) {
        self.lifecycle = lifecycle
        self.underlying = underlying
    }

    func destroyCurrentVault() async throws {
        let id: UUID
        let task: Task<Void, Error>
        switch destroyState {
        case .destroyed:
            return
        case .destroying(let existingID, let existingTask):
            id = existingID
            task = existingTask
        case .idle:
            id = UUID()
            let lifecycle = self.lifecycle
            let underlying = self.underlying
            task = Task {
                await lifecycle.revoke()
                try await underlying.destroyCurrentVault()
            }
            destroyState = .destroying(id: id, task: task)
        }

        do {
            try await task.value
            finishDestroySuccessfully(id: id)
        } catch {
            finishDestroyAfterFailure(id: id)
            throw error
        }
    }

    private func finishDestroySuccessfully(id: UUID) {
        guard case .destroying(let activeID, _) = destroyState,
            activeID == id
        else { return }
        destroyState = .destroyed
    }

    private func finishDestroyAfterFailure(id: UUID) {
        guard case .destroying(let activeID, _) = destroyState,
            activeID == id
        else { return }
        destroyState = .idle
    }
}
