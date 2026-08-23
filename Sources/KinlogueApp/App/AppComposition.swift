import Foundation
import KinlogueCore
import KinloguePlatform

@MainActor
struct AppComposition {
    let appModel: AppModel
    let deletionModel: VaultDeletionModel
    let lanInboxModel: LANInboxModel
    let backupModel: BackupModel
    let restoreModel: RestoreModel
    let startupCoordinator: AppStartupCoordinator

    static func makeDefault() -> Self {
        do {
            return makeDefault(identity: try AppRuntimeIdentity.current())
        } catch {
            return makeUnavailable()
        }
    }

    static func makeDefault(identity: AppRuntimeIdentity) -> Self {
        do {
            let services = try LiveAppServiceEnvironment.makeDefault(identity: identity)
            let backup = try makeBackupRuntime(
                identity: identity,
                vault: services.vault,
                lifecycle: services.lifecycle
            )
            return makeComposition(services: services, backup: backup)
        } catch {
            do {
                // Damaged/unsupported Vaults still get the seed-only restore
                // stack. No writer configuration is created by construction.
                try VaultParentDirectoryPreparation.ensureParentDirectory(
                    for: identity.sourceVault.rootURL
                )
                let vault = try PlaintextVault(rootURL: identity.sourceVault.rootURL)
                let lifecycle = LibraryLifecycleCoordinator()
                let backup = try makeBackupRuntime(
                    identity: identity,
                    vault: vault,
                    lifecycle: lifecycle
                )
                return makeUnavailable(backup: backup)
            } catch {
                return makeUnavailable()
            }
        }
    }

    private static func makeComposition(
        services: LiveAppServiceEnvironment,
        backup: BackupRuntime
    ) -> Self {
        let dicomViewerRegistry = DICOMViewerRegistry()
        let appModel = AppModel(
            service: services.dataService,
            originalExportService: services.originalExportService,
            dicomService: services.dataService,
            dicomSliceServiceFactory: services.dicomSliceServiceFactory,
            dicomViewerRegistry: dicomViewerRegistry,
            onDurableStateChanged: { [weak backupModel = backup.backupModel] in
                Task { await backupModel?.handleAppEvent(.mutation) }
            }
        )
        let lanInboxModel = LANInboxModel(
            service: services.lanInboxService,
            onCatalogChanged: { [weak appModel] in
                await appModel?.refresh()
            },
            onDurableStateChanged: { [weak backupModel = backup.backupModel] in
                await backupModel?.handleAppEvent(.mutation)
            }
        )
        let destroyService = BackupCoordinatedVaultDestroyService(
            operationCoordinator: backup.liveBackup.operationCoordinator,
            configurationStore: backup.liveBackup.configurationStore,
            underlying: services.destroyService
        )
        let startup = AppStartupCoordinator(
            reconcileRestore: { [weak restoreModel = backup.restoreModel] in
                await restoreModel?.reconcileBeforeStartingServices() ?? false
            },
            startStorage: { [weak appModel, weak lanInboxModel] in
                guard let appModel else { return false }
                await appModel.start()
                guard appModel.phase == .ready else { return false }
                await lanInboxModel?.start()
                return true
            },
            startScheduler: { [weak backupModel = backup.backupModel] in
                await backupModel?.refresh()
                await backupModel?.handleAppEvent(.startup)
            }
        )
        return Self(
            appModel: appModel,
            deletionModel: deletionModel(
                destroyService: destroyService,
                appModel: appModel,
                lanInboxModel: lanInboxModel
            ),
            lanInboxModel: lanInboxModel,
            backupModel: backup.backupModel,
            restoreModel: backup.restoreModel,
            startupCoordinator: startup
        )
    }

    private static func makeUnavailable(backup: BackupRuntime? = nil) -> Self {
        let unavailableAppService = UnavailableAppService()
        let dicomViewerRegistry = DICOMViewerRegistry()
        let appModel = AppModel(
            service: unavailableAppService,
            originalExportService: UnavailableOriginalExportService(),
            dicomService: unavailableAppService,
            dicomSliceServiceFactory: { UnavailableDICOMSliceService() },
            dicomViewerRegistry: dicomViewerRegistry
        )
        let lanInboxModel = LANInboxModel(service: UnavailableLANInboxService())
        let backupModel = backup?.backupModel ?? BackupModel(service: UnavailableBackupService())
        let restoreModel = backup?.restoreModel ?? RestoreModel(service: UnavailableRestoreService())
        let destroy: any VaultDestroyServicing
        if let backup {
            destroy = BackupCoordinatedVaultDestroyService(
                operationCoordinator: backup.liveBackup.operationCoordinator,
                configurationStore: backup.liveBackup.configurationStore,
                underlying: UnavailableVaultDestroyService()
            )
        } else {
            destroy = UnavailableVaultDestroyService()
        }
        let startup = AppStartupCoordinator(
            reconcileRestore: { [weak restoreModel] in
                await restoreModel?.reconcileBeforeStartingServices() ?? false
            },
            startStorage: { [weak appModel] in
                await appModel?.start()
                return false
            },
            startScheduler: {}
        )
        return Self(
            appModel: appModel,
            deletionModel: deletionModel(
                destroyService: destroy,
                appModel: appModel,
                lanInboxModel: lanInboxModel
            ),
            lanInboxModel: lanInboxModel,
            backupModel: backupModel,
            restoreModel: restoreModel,
            startupCoordinator: startup
        )
    }

    private static func deletionModel(
        destroyService: any VaultDestroyServicing,
        appModel: AppModel,
        lanInboxModel: LANInboxModel
    ) -> VaultDeletionModel {
        VaultDeletionModel(
            destroyService: destroyService,
            onDeletionBegan: { [weak appModel, weak lanInboxModel] in
                lanInboxModel?.beginDestructiveVaultLifecycle()
                await appModel?.beginDestructiveVaultLifecycle()
            },
            onVaultDeleted: { [weak appModel] in appModel?.finishVaultDeletion() },
            onDeletionFailed: { [weak appModel] in
                appModel?.requireRestartAfterVaultLifecycle()
            }
        )
    }

    private static func makeBackupRuntime(
        identity: AppRuntimeIdentity,
        vault: PlaintextVault,
        lifecycle: LibraryLifecycleCoordinator
    ) throws -> BackupRuntime {
        let store = BackupLocalConfigurationStore(rootURL: identity.backupIdentity.rootURL)
        let liveBackup = try LiveBackupService(
            activeVaultURL: identity.sourceVault.rootURL,
            configurationStore: store,
            vault: vault,
            requiresSelectedDirectoryScope: identity.mode == .production
        )
        let verifier = try BackupRestoreVerifier(
            stableParentURL: identity.sourceVault.rootURL.deletingLastPathComponent(),
            activeRootURL: identity.sourceVault.rootURL
        )
        let transaction = try BackupRestoreTransaction(activeRootURL: identity.sourceVault.rootURL)
        let restoreService = BackupRestoreService(
            verifier: verifier,
            transaction: transaction,
            configurationStore: store,
            operationCoordinator: liveBackup.operationCoordinator,
            lifecycle: lifecycle
        )
        let liveRestore = LiveRestoreService(service: restoreService)
        return .init(
            liveBackup: liveBackup,
            backupModel: BackupModel(service: liveBackup),
            restoreModel: RestoreModel(service: liveRestore)
        )
    }
}

private struct BackupRuntime {
    let liveBackup: LiveBackupService
    let backupModel: BackupModel
    let restoreModel: RestoreModel
}

private enum UnavailableVaultLifecycleError: Error { case unavailable }

private actor UnavailableVaultDestroyService: VaultDestroyServicing {
    func destroyCurrentVault() async throws { throw UnavailableVaultLifecycleError.unavailable }
}

private actor UnavailableBackupService: BackupServicing {
    func loadStatus() async throws -> AppBackupStatus { .notConfigured }
    func beginSetup(selectedParent: URL) async throws -> String {
        _ = selectedParent
        throw BackupSemanticError.verificationFailed
    }
    func completeSetup(recoveryCodeReentry: String, independentlySaved: Bool) async throws {
        _ = recoveryCodeReentry
        _ = independentlySaved
        throw BackupSemanticError.verificationFailed
    }
    func cancelSetup() async {}
    func resumePending(recoveryCode: String) async throws {
        _ = recoveryCode
        throw BackupSemanticError.notConfigured
    }
    func abandonPending() async throws {
        throw BackupSemanticError.notConfigured
    }
    func setAutomaticBackupEnabled(_ enabled: Bool) async throws -> BackupSchedulerOutcome {
        _ = enabled
        throw BackupSemanticError.notConfigured
    }
    func setRetentionCount(_ count: Int) async throws {
        _ = count
        throw BackupSemanticError.notConfigured
    }
    func backUpNow() async throws -> BackupCleanupOutcome {
        throw BackupSemanticError.notConfigured
    }
    func showBackupRepository() async throws {
        throw BackupSemanticError.notConfigured
    }
    func handleSchedulerEvent(_ event: BackupSchedulerEvent) async throws -> BackupSchedulerOutcome {
        _ = event
        return .disabled
    }
}

private actor UnavailableRestoreService: BackupRestoreServicing {
    func reconcileBeforeStartingServices() async throws {}
    func prepare(checkpointURL: URL, recoveryCode: String) async throws -> BackupRestoreSummary {
        _ = checkpointURL
        _ = recoveryCode
        throw BackupRestoreError.stagingConflict
    }
    func cancelPreparedRestore() async throws {}
    func activatePreparedRestore() async throws -> BackupRestoreActivationResult {
        throw BackupRestoreError.activationConflict
    }
}

private actor BackupCoordinatedVaultDestroyService: VaultDestroyServicing {
    private let operationCoordinator: BackupOperationCoordinator
    private let configurationStore: BackupLocalConfigurationStore
    private let underlying: any VaultDestroyServicing

    init(
        operationCoordinator: BackupOperationCoordinator,
        configurationStore: BackupLocalConfigurationStore,
        underlying: any VaultDestroyServicing
    ) {
        self.operationCoordinator = operationCoordinator
        self.configurationStore = configurationStore
        self.underlying = underlying
    }

    func destroyCurrentVault() async throws {
        let configurationStore = self.configurationStore
        let underlying = self.underlying
        try await operationCoordinator.withDestructiveFence {
            try await configurationStore.removeForDestructiveReset()
            try await underlying.destroyCurrentVault()
        }
    }
}
