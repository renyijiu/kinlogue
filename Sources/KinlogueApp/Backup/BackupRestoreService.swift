import Foundation
import KinloguePlatform

/// Backend for both the Settings entry and the degraded startup entry. The file picker's
/// security scope stays with the caller; the archive's folder never becomes the backup folder.
actor BackupRestoreService {
    typealias DestructiveFence = @Sendable (
        @escaping @Sendable () async throws -> BackupRestoreActivationResult
    ) async throws -> BackupRestoreActivationResult

    struct Operations: Sendable {
        let prepare: @Sendable (URL) async throws -> BackupPreparedRestore
        let cancel: @Sendable (BackupPreparedRestore) throws -> Void
        let destructiveFence: DestructiveFence
        let revokeLifecycle: @Sendable () async -> Void
        let activate: @Sendable (
            BackupPreparedRestore,
            @escaping @Sendable () async throws -> Void
        ) async throws -> BackupRestoreActivationResult
        /// Runs inside the transaction once the old library is gone: keeps the backup folder
        /// but turns automatic backups off until the person turns them on again.
        let disableAutomaticBackup: @Sendable () async throws -> Void
        let reconcilePreflights: @Sendable () async throws -> Void
        let reconcile: @Sendable () async throws -> BackupRestoreReconciliationOutcome
    }

    private let operations: Operations

    init(
        verifier: BackupRestoreVerifier,
        transaction: BackupRestoreTransaction,
        settingsStore: BackupSettingsStore,
        operationCoordinator: BackupOperationCoordinator,
        lifecycle: LibraryLifecycleCoordinator,
        database: SQLiteLibraryStore? = nil
    ) {
        operations = Operations(
            prepare: { archiveURL in try await verifier.prepare(archiveURL: archiveURL) },
            cancel: { prepared in try verifier.cancel(prepared) },
            destructiveFence: { operation in
                try await operationCoordinator.withDestructiveFence(operation)
            },
            revokeLifecycle: { await lifecycle.revoke() },
            activate: { prepared, resetWriter in
                try database?.closeDatabaseForReplacement()
                return try await transaction.activate(
                    prepared: prepared,
                    resetWriter: resetWriter
                )
            },
            disableAutomaticBackup: { try settingsStore.disableAutomaticBackupForRestore() },
            reconcilePreflights: { try verifier.reconcileAbandonedPreflights() },
            reconcile: { try await transaction.reconcile() }
        )
    }

    init(operations: Operations) {
        self.operations = operations
    }

    /// Fully verifies and stages without changing the active library or the backup
    /// settings. The returned summary, free of health content, is what the person confirms.
    func prepare(archiveURL: URL) async throws -> BackupPreparedRestore {
        try await operations.prepare(archiveURL)
    }

    func cancel(_ prepared: BackupPreparedRestore) throws {
        try operations.cancel(prepared)
    }

    /// Called only after the person confirms replacement. The destructive fence cancels an
    /// unpublished backup, lifecycle revocation drains LAN, import, OCR and backup work, and
    /// the platform transaction then owns the library through its terminal receipt phase.
    func activateAfterConfirmation(
        _ prepared: BackupPreparedRestore
    ) async throws -> BackupRestoreActivationResult {
        try await operations.destructiveFence {
            await self.operations.revokeLifecycle()
            // Activation replaces the root and strictly validates it; both wait on storage.
            return try await LibraryStorageExecutor.run {
                try await self.operations.activate(prepared) {
                    try await self.operations.disableAutomaticBackup()
                }
            }
        }
    }

    /// Composition calls this before exposing storage-backed services. A
    /// committed restore keeps `requiresApplicationRestart`; this method is
    /// for next-launch convergence, never hot service rebinding.
    func reconcileBeforeStartingServices() async throws -> BackupRestoreReconciliationOutcome {
        try await LibraryStorageExecutor.run {
            let outcome = try await operations.reconcile()
            try await operations.reconcilePreflights()
            return outcome
        }
    }
}
