import Foundation
import Testing
@testable import KinlogueApp

@Suite("Backup composition", .serialized)
@MainActor
struct BackupCompositionTests {
    @Test
    func startupReconcilesRestoreBeforeStorageAndScheduler() async {
        let events = StartupEvents()
        let coordinator = AppStartupCoordinator(
            reconcileRestore: { await events.append("restore-reconcile"); return true },
            startStorage: { await events.append("storage-start"); return true },
            startProcessing: { await events.append("processing-start") },
            startScheduler: { await events.append("scheduler-start") }
        )

        await coordinator.start()

        #expect(await events.values == [
            "restore-reconcile",
            "storage-start",
            "processing-start",
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
