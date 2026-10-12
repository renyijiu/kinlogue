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
    let processingCoordinator: AppProcessingCoordinator
    var libraryObserver: AppLibraryObservationCoordinator? = nil
    var integrityCoordinator: AppIntegrityCoordinator? = nil

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
            guard let vault = services.vault else { return makeUnavailable() }
            let backup = try makeBackupRuntime(
                identity: identity,
                vault: vault,
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

    static func makeOpened(identity: AppRuntimeIdentity, services: LiveAppServiceEnvironment,
                           context: SQLiteStartupContext, database: SQLiteLibraryStore) -> Self {
        let live = LiveBackupService(store: database, configurationStore: context.configuration,
            requiresSelectedDirectoryScope: identity.mode == .production)
        let restore = BackupRestoreService(verifier: context.verifier, transaction: context.transaction,
            configurationStore: context.configuration, operationCoordinator: live.operationCoordinator,
            lifecycle: context.lifecycle, database: database)
        return makeComposition(services: services, backup: BackupRuntime(liveBackup: live,
            backupModel: BackupModel(service: live), restoreService: LiveRestoreService(service: restore)), restoreReconciled: true, database: database)
    }

    static func makeSQLiteUnavailable(restoreService: (any BackupRestoreServicing)?) -> Self {
        makeUnavailable(seedRestoreService: restoreService)
    }

    private static func makeComposition(
        services: LiveAppServiceEnvironment,
        backup: BackupRuntime,
        restoreReconciled: Bool = false,
        database: SQLiteLibraryStore? = nil
    ) -> Self {
        let dicomViewerRegistry = DICOMViewerRegistry()
        let appModel = AppModel(
            service: services.dataService,
            originalExportService: services.originalExportService,
            dicomService: services.dataService,
            dicomSliceServiceFactory: services.dicomSliceServiceFactory,
            dicomViewerRegistry: dicomViewerRegistry,
            onDurableStateChanged: { [weak backupModel = backup.backupModel] in
                if services.commitChanges == nil { Task { await backupModel?.handleAppEvent(.mutation) } }
            }
        )
        let processing = AppProcessingCoordinator(
            lanService: services.lanInboxService,
            lifecycle: services.lifecycle,
            onCatalogChanged: { [weak appModel] in
                await appModel?.refresh()
            },
            onDurableStateChanged: { [weak backupModel = backup.backupModel] in
                if services.commitChanges == nil { await backupModel?.handleAppEvent(.mutation) }
            }
        )
        let lanInboxModel = LANInboxModel(
            service: services.lanInboxService,
            processing: processing,
            onCatalogChanged: { [weak appModel] in
                await appModel?.refresh()
            },
            onDurableStateChanged: { [weak backupModel = backup.backupModel] in
                if services.commitChanges == nil { await backupModel?.handleAppEvent(.mutation) }
            }
        )
        let inspection = database.map { database in
            AppIntegrityCoordinator(store: database, lifecycle: services.lifecycle, onCompleted: { [weak appModel, weak lanInboxModel] in
                await appModel?.refresh(); await lanInboxModel?.refresh()
            }, onUnsafe: { [weak appModel, weak lanInboxModel] in
                lanInboxModel?.beginDestructiveVaultLifecycle()
                async let revocation: Void = services.lifecycle.revoke()
                await appModel?.beginDestructiveVaultLifecycle()
                await revocation
                appModel?.requireRestartAfterIntegrityFailure()
            })
        }
        if let inspection {
            appModel.onLibraryUnavailable = { [weak inspection] in await inspection?.requestUnsafeShutdown() }
        }
        let observer = services.commitChanges.map { subscribe in
            AppLibraryObservationCoordinator(subscribe: subscribe, reconcile: { [weak appModel, weak lanInboxModel] in
                guard let appModel, appModel.phase == .ready else { return nil }
                await appModel.refresh()
                await lanInboxModel?.refresh()
                return appModel.currentLibraryRevision
            }, onDurableChange: { [weak backupModel = backup.backupModel] in
                await inspection?.libraryChanged()
                await backupModel?.handleAppEvent(.mutation)
            })
        }
        let observationRegistrationID = UUID()
        let restoreModel = makeRestoreModel(
            service: backup.restoreService,
            appModel: appModel,
            lanInboxModel: lanInboxModel, libraryObserver: observer
        )
        let destroyService = BackupCoordinatedVaultDestroyService(
            operationCoordinator: backup.liveBackup.operationCoordinator,
            configurationStore: backup.liveBackup.configurationStore,
            underlying: services.destroyService
        )
        let startup = AppStartupCoordinator(
            reconcileRestore: { [weak restoreModel] in
                if restoreReconciled { return true }
                return await restoreModel?.reconcileBeforeStartingServices() ?? false
            },
            startStorage: { [weak appModel, weak lanInboxModel] in
                guard let appModel else { return false }
                if let observer {
                    do { try await services.lifecycle.register(id: observationRegistrationID) { await observer.stop() } }
                    catch { return false }
                }
                observer?.install()
                await appModel.start()
                guard appModel.phase == .ready else { return false }
                await lanInboxModel?.start()
                await observer?.reconcile()
                return true
            },
            startProcessing: {
                await processing.startRecovery(using: services.dataService)
                await inspection?.start()
            },
            startScheduler: { [weak backupModel = backup.backupModel] in
                await backupModel?.refresh()
                await backupModel?.handleAppEvent(.startup)
            },
            reconcileLibrary: {
                await inspection?.pause()
                await observer?.reconcile()
                await inspection?.libraryChanged()
            }
        )
        return Self(
            appModel: appModel,
            deletionModel: deletionModel(
                destroyService: destroyService,
                appModel: appModel,
                lanInboxModel: lanInboxModel, libraryObserver: observer
            ),
            lanInboxModel: lanInboxModel,
            backupModel: backup.backupModel,
            restoreModel: restoreModel,
            startupCoordinator: startup,
            processingCoordinator: processing, libraryObserver: observer, integrityCoordinator: inspection
        )
    }

    private static func makeUnavailable(backup: BackupRuntime? = nil, seedRestoreService: (any BackupRestoreServicing)? = nil) -> Self {
        let unavailableAppService = UnavailableAppService()
        let dicomViewerRegistry = DICOMViewerRegistry()
        let appModel = AppModel(
            service: unavailableAppService,
            originalExportService: UnavailableOriginalExportService(),
            dicomService: unavailableAppService,
            dicomSliceServiceFactory: { UnavailableDICOMSliceService() },
            dicomViewerRegistry: dicomViewerRegistry
        )
        let unavailableLANService = UnavailableLANInboxService()
        let processing = AppProcessingCoordinator(lanService: unavailableLANService)
        let lanInboxModel = LANInboxModel(
            service: unavailableLANService, processing: processing
        )
        let backupModel = backup?.backupModel ?? BackupModel(service: UnavailableBackupService())
        let restoreService: any BackupRestoreServicing = seedRestoreService ?? backup?.restoreService
            ?? UnavailableRestoreService()
        let restoreModel = makeRestoreModel(
            service: restoreService,
            appModel: appModel,
            lanInboxModel: lanInboxModel
        )
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
            startupCoordinator: startup,
            processingCoordinator: processing
        )
    }

    private static func deletionModel(
        destroyService: any VaultDestroyServicing,
        appModel: AppModel,
        lanInboxModel: LANInboxModel,
        libraryObserver: AppLibraryObservationCoordinator? = nil
    ) -> VaultDeletionModel {
        VaultDeletionModel(
            destroyService: destroyService,
            onDeletionBegan: { [weak appModel, weak lanInboxModel] in
                await libraryObserver?.stop()
                lanInboxModel?.beginDestructiveVaultLifecycle()
                await appModel?.beginDestructiveVaultLifecycle()
            },
            onVaultDeleted: { [weak appModel] in appModel?.finishVaultDeletion() },
            onDeletionFailed: { [weak appModel] in
                appModel?.requireRestartAfterVaultLifecycle()
            }
        )
    }

    static func makeRestoreModel(
        service: any BackupRestoreServicing,
        appModel: AppModel,
        lanInboxModel: LANInboxModel,
        securityScope: any RestoreFileSecurityScope = SystemRestoreFileSecurityScope(),
        libraryObserver: AppLibraryObservationCoordinator? = nil
    ) -> RestoreModel {
        RestoreModel(
            service: service,
            securityScope: securityScope,
            onReplacementBegan: { [weak appModel, weak lanInboxModel] in
                await libraryObserver?.stop()
                lanInboxModel?.beginDestructiveVaultLifecycle()
                await appModel?.beginDestructiveVaultLifecycle()
            },
            onReplacementEnded: { [weak appModel] in
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
            restoreService: liveRestore
        )
    }
}

private struct BackupRuntime {
    let liveBackup: LiveBackupService
    let backupModel: BackupModel
    let restoreService: any BackupRestoreServicing
}

private enum UnavailableVaultLifecycleError: Error { case unavailable }

private actor UnavailableVaultDestroyService: VaultDestroyServicing {
    func destroyCurrentVault() async throws { throw UnavailableVaultLifecycleError.unavailable }
}

private actor UnavailableBackupService: BackupServicing {
    func reauthorizeDestination(selectedParent: URL) async throws {
        throw BackupSemanticError.notConfigured
    }
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
