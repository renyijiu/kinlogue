import Foundation
import KinloguePlatform

protocol BackupRestoreServicing: Sendable {
    func reconcileBeforeStartingServices() async throws
    func prepare(checkpointURL: URL, recoveryCode: String) async throws -> BackupRestoreSummary
    func cancelPreparedRestore() async throws
    func activatePreparedRestore() async throws -> BackupRestoreActivationResult
}

actor LiveRestoreService: BackupRestoreServicing {
    private let service: BackupRestoreService
    private var prepared: BackupPreparedRestore?
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
        if let previous = prepared {
            prepared = nil
            try await service.cancel(previous)
        }
        let next = try await service.prepare(
            checkpointURL: checkpointURL,
            recoveryCode: recoveryCode
        )
        guard generation == operationGeneration, !isActivating else {
            try? await service.cancel(next)
            throw CancellationError()
        }
        prepared = next
        return next.summary
    }

    func cancelPreparedRestore() async throws {
        _ = invalidatePendingPreparation()
        guard let prepared else { return }
        self.prepared = nil
        try await service.cancel(prepared)
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
