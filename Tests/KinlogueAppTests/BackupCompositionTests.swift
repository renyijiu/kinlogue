import Foundation
import Testing
@testable import KinlogueApp

@Suite("Backup composition", .serialized)
@MainActor
struct BackupCompositionTests {
    @Test
    func constructingCompositionDoesNotCreateBackupIdentity() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "KinlogueBackupComposition-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let identity = try AppRuntimeIdentity.resolve(
            bundleInfo: ["CFBundleIdentifier": AppRuntimeIdentity.productionBundleIdentifier],
            arguments: ["Kinlogue"],
            trustedApplicationSupportDirectory: base
        )

        _ = AppComposition.makeDefault(identity: identity)

        #expect(!FileManager.default.fileExists(atPath: identity.backupIdentity.rootURL.path))
    }

    @Test
    func anAbsentVaultUsesNormalFirstLaunchBootstrapInsteadOfDamagedVaultRecovery() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "KinlogueBackupFirstLaunch-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let identity = try AppRuntimeIdentity.resolve(
            bundleInfo: ["CFBundleIdentifier": AppRuntimeIdentity.productionBundleIdentifier],
            arguments: ["Kinlogue"],
            trustedApplicationSupportDirectory: base
        )
        let composition = AppComposition.makeDefault(identity: identity)

        await composition.startupCoordinator.start()

        #expect(composition.appModel.phase == .ready)
        #expect(composition.restoreModel.phase == .idle)
        #expect(!FileManager.default.fileExists(atPath: identity.backupIdentity.rootURL.path))
    }

    @Test
    func startupReconcilesRestoreBeforeStorageAndScheduler() async {
        let events = StartupEvents()
        let coordinator = AppStartupCoordinator(
            reconcileRestore: { await events.append("restore-reconcile"); return true },
            startStorage: { await events.append("storage-start"); return true },
            startScheduler: { await events.append("scheduler-start") }
        )

        await coordinator.start()

        #expect(await events.values == [
            "restore-reconcile",
            "storage-start",
            "scheduler-start",
        ])
    }

    @Test
    func failedStartupCanRetryWithoutBypassingRestoreReconciliation() async {
        let events = StartupEvents(storageResults: [false, true])
        let coordinator = AppStartupCoordinator(
            reconcileRestore: { await events.append("restore-reconcile"); return true },
            startStorage: {
                await events.append("storage-start")
                return await events.nextStorageResult()
            },
            startScheduler: { await events.append("scheduler-start") }
        )

        #expect(await coordinator.start() == false)
        #expect(await coordinator.start() == true)
        #expect(await coordinator.start() == true)

        #expect(await events.values == [
            "restore-reconcile",
            "storage-start",
            "restore-reconcile",
            "storage-start",
            "scheduler-start",
        ])
    }
}

private actor StartupEvents {
    private(set) var values: [String] = []
    private var storageResults: [Bool]

    init(storageResults: [Bool] = []) {
        self.storageResults = storageResults
    }

    func append(_ value: String) { values.append(value) }

    func nextStorageResult() -> Bool {
        storageResults.isEmpty ? true : storageResults.removeFirst()
    }
}
