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

    /// The composition on an opened SQLite library. `LibraryLaunchCoordinator` is its only caller.
    static func makeOpened(identity: AppRuntimeIdentity, services: LiveAppServiceEnvironment,
                           context: SQLiteStartupContext, database: SQLiteLibraryStore) -> Self {
        let live = LiveBackupService(store: database, settingsStore: context.backupSettings, lifecycle: context.lifecycle,
            requiresSelectedDirectoryScope: identity.mode == .production)
        let restore = BackupRestoreService(verifier: context.verifier, transaction: context.transaction,
            settingsStore: context.backupSettings, operationCoordinator: live.operationCoordinator,
            lifecycle: context.lifecycle, database: database)
        return makeComposition(services: services, backup: BackupRuntime(liveBackup: live,
            backupModel: BackupModel(service: live), restoreService: LiveRestoreService(service: restore)), restoreReconciled: true, database: database)
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
            backupExportService: backup.liveBackup,
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
                await appModel.refresh(skippingUnchanged: true)
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
            settingsStore: backup.liveBackup.settingsStore,
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

    /// The composition shown when the library could not be opened. It reads and writes nothing;
    /// `restoreService` is the seed-only restore offered for a library this launch owns but cannot read.
    static func makeUnavailable(restoreService: (any BackupRestoreServicing)?) -> Self {
        let unavailableAppService = UnavailableAppService()
        let dicomViewerRegistry = DICOMViewerRegistry()
        let appModel = AppModel(
            service: unavailableAppService,
            backupExportService: UnavailableBackupExportService(),
            dicomService: unavailableAppService,
            dicomSliceServiceFactory: { UnavailableDICOMSliceService() },
            dicomViewerRegistry: dicomViewerRegistry
        )
        let unavailableLANService = UnavailableLANInboxService()
        let processing = AppProcessingCoordinator(lanService: unavailableLANService)
        let lanInboxModel = LANInboxModel(
            service: unavailableLANService, processing: processing
        )
        let backupModel = BackupModel(service: UnavailableBackupService())
        let restoreModel = makeRestoreModel(
            service: restoreService ?? UnavailableRestoreService(),
            appModel: appModel,
            lanInboxModel: lanInboxModel
        )
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
                destroyService: UnavailableVaultDestroyService(),
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
    func loadStatus() async throws -> AppBackupStatus { .notConfigured }
    func chooseFolder(_ url: URL) async throws { throw BackupFailure.notConfigured }
    func setAutomaticBackupEnabled(_ enabled: Bool) async throws -> BackupSchedulerOutcome { throw BackupFailure.notConfigured }
    func setRetentionCount(_ count: Int) async throws { throw BackupFailure.notConfigured }
    func backUpNow() async throws -> BackupRunResult { throw BackupFailure.notConfigured }
    func showFolder() async throws { throw BackupFailure.notConfigured }
    func handleSchedulerEvent(_ event: BackupSchedulerEvent) async throws -> BackupSchedulerOutcome { .disabled }
}

private actor UnavailableRestoreService: BackupRestoreServicing {
    func reconcileBeforeStartingServices() async throws {}
    func prepare(archiveURL: URL) async throws -> BackupRestoreSummary { throw BackupRestoreError.stagingConflict }
    func cancelPreparedRestore() async throws {}
    func activatePreparedRestore() async throws -> BackupRestoreActivationResult {
        throw BackupRestoreError.activationConflict
    }
}

private actor BackupCoordinatedVaultDestroyService: VaultDestroyServicing {
    private let operationCoordinator: BackupOperationCoordinator
    private let settingsStore: BackupSettingsStore
    private let underlying: any VaultDestroyServicing

    init(
        operationCoordinator: BackupOperationCoordinator,
        settingsStore: BackupSettingsStore,
        underlying: any VaultDestroyServicing
    ) {
        self.operationCoordinator = operationCoordinator
        self.settingsStore = settingsStore
        self.underlying = underlying
    }

    /// Deleting the library also forgets the backup folder and its ledger on this Mac. The
    /// backups in the folder stay; they are the person's files.
    func destroyCurrentVault() async throws {
        let settingsStore = self.settingsStore
        let underlying = self.underlying
        try await operationCoordinator.withDestructiveFence {
            try settingsStore.remove()
            try await underlying.destroyCurrentVault()
        }
    }
}
