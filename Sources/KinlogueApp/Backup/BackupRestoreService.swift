import Foundation
import KinloguePlatform

/// Backend for both the normal Settings entry and the U7 degraded bootstrap
/// entry. Folder/file picker security-scope ownership remains in the caller;
/// this service never adopts the checkpoint's directory as backup config.
actor BackupRestoreService {
    typealias DestructiveFence = @Sendable (
        @escaping @Sendable () async throws -> BackupRestoreActivationResult
    ) async throws -> BackupRestoreActivationResult

    struct Operations: Sendable {
        let prepare: @Sendable (URL, String) async throws -> BackupPreparedRestore
        let cancel: @Sendable (BackupPreparedRestore) throws -> Void
        let destructiveFence: DestructiveFence
        let revokeLifecycle: @Sendable () async -> Void
        let activate: @Sendable (
            BackupPreparedRestore,
            @escaping @Sendable () async throws -> Void
        ) async throws -> BackupRestoreActivationResult
        let removeWriterConfiguration: @Sendable () async throws -> Void
        let reconcilePreflights: @Sendable () async throws -> Void
        let reconcile: @Sendable () async throws -> BackupRestoreReconciliationOutcome
    }

    private let operations: Operations

    init(
        verifier: BackupRestoreVerifier,
        transaction: BackupRestoreTransaction,
        configurationStore: BackupLocalConfigurationStore,
        operationCoordinator: BackupOperationCoordinator,
        lifecycle: LibraryLifecycleCoordinator
    ) {
        operations = Operations(
            prepare: { checkpointURL, recoveryCode in
                try await verifier.prepare(
                    checkpointURL: checkpointURL,
                    recoveryCode: recoveryCode
                )
            },
            cancel: { prepared in try verifier.cancel(prepared) },
            destructiveFence: { operation in
                try await operationCoordinator.withDestructiveFence(operation)
            },
            revokeLifecycle: { await lifecycle.revoke() },
            activate: { prepared, resetWriter in
                try await transaction.activate(
                    prepared: prepared,
                    resetWriter: resetWriter
                )
            },
            removeWriterConfiguration: {
                try await configurationStore.removeForDestructiveReset()
            },
            reconcilePreflights: { try verifier.reconcileAbandonedPreflights() },
            reconcile: { try await transaction.reconcile() }
        )
    }

    init(operations: Operations) {
        self.operations = operations
    }

    /// Fully verifies and stages without changing the active Vault or local
    /// automatic-backup configuration. The returned PHI-free summary is the
    /// confirmation boundary for the UI.
    func prepare(
        checkpointURL: URL,
        recoveryCode: String
    ) async throws -> BackupPreparedRestore {
        try await operations.prepare(checkpointURL, recoveryCode)
    }

    func cancel(_ prepared: BackupPreparedRestore) throws {
        try operations.cancel(prepared)
    }

    /// Called only after the user confirms replacement. U5 serialization
    /// cancels an unpublished backup, lifecycle revocation drains LAN/import/
    /// OCR/export operations, and the platform transaction then owns the
    /// stable cross-process Vault fence through its terminal receipt phase.
    func activateAfterConfirmation(
        _ prepared: BackupPreparedRestore
    ) async throws -> BackupRestoreActivationResult {
        try await operations.destructiveFence {
            await self.operations.revokeLifecycle()
            return try await self.operations.activate(prepared) {
                try await self.operations.removeWriterConfiguration()
            }
        }
    }

    /// Composition calls this before exposing storage-backed services. A
    /// committed restore keeps `requiresApplicationRestart`; this method is
    /// for next-launch convergence, never hot service rebinding.
    func reconcileBeforeStartingServices() async throws -> BackupRestoreReconciliationOutcome {
        try await operations.reconcilePreflights()
        return try await operations.reconcile()
    }
}
