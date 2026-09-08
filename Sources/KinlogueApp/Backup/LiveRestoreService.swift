import Foundation
import KinloguePlatform

protocol BackupRestoreServicing: Sendable {
    func reconcileBeforeStartingServices() async throws
    func prepare(checkpointURL: URL, recoveryCode: String) async throws -> BackupRestoreSummary
    func cancelPreparedRestore() async throws
    func activatePreparedRestore() async throws -> BackupRestoreActivationResult
}

actor LiveRestoreService: BackupRestoreServicing {
    private struct Preparation {
        let generation: UInt64
        let task: Task<BackupRestoreSummary, Error>
    }

    private let service: BackupRestoreService
    private var prepared: BackupPreparedRestore?
    private var preparation: Preparation?
    private var operationGeneration: UInt64 = 0
    private var isActivating = false

    init(service: BackupRestoreService) {
        self.service = service
    }

    func reconcileBeforeStartingServices() async throws {
        _ = try await service.reconcileBeforeStartingServices()
    }

    func prepare(
        checkpointURL: URL,
        recoveryCode: String
    ) async throws -> BackupRestoreSummary {
        guard !isActivating else { throw BackupRestoreError.activationConflict }
        let generation = invalidatePendingPreparation()
        await cancelPreparation()
        guard generation == operationGeneration else { throw CancellationError() }
        if let previous = prepared {
            prepared = nil
            try await service.cancel(previous)
        }
        guard generation == operationGeneration else { throw CancellationError() }
        let task = Task {
            try Task.checkCancellation()
            let next = try await service.prepare(
                checkpointURL: checkpointURL,
                recoveryCode: recoveryCode
            )
            guard generation == operationGeneration, !isActivating, !Task.isCancelled else {
                try await service.cancel(next)
                throw CancellationError()
            }
            prepared = next
            return next.summary
        }
        preparation = .init(generation: generation, task: task)
        defer { finishPreparation(generation: generation) }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func cancelPreparedRestore() async throws {
        let generation = invalidatePendingPreparation()
        await cancelPreparation()
        guard generation == operationGeneration else { return }
        guard let prepared else { return }
        self.prepared = nil
        try await service.cancel(prepared)
    }

    private func cancelPreparation() async {
        guard let preparation else { return }
        preparation.task.cancel()
        _ = await preparation.task.result
        finishPreparation(generation: preparation.generation)
    }

    private func finishPreparation(generation: UInt64) {
        guard preparation?.generation == generation else { return }
        preparation = nil
    }

    func activatePreparedRestore() async throws -> BackupRestoreActivationResult {
        _ = invalidatePendingPreparation()
        guard !isActivating else { throw BackupRestoreError.activationConflict }
        guard let prepared else { throw BackupRestoreError.receiptInvalid }
        self.prepared = nil
        isActivating = true
        defer { isActivating = false }
        return try await service.activateAfterConfirmation(prepared)
    }

    @discardableResult
    private func invalidatePendingPreparation() -> UInt64 {
        operationGeneration &+= 1
        return operationGeneration
    }
}
