import Darwin
import Foundation
import KinlogueCore
import Testing
@testable import KinlogueApp
@testable import KinloguePlatform

@Suite("Backup concurrency regressions")
@MainActor
struct BackupConcurrencyRegressionTests {
    @Test
    func activationMustNotClearAnActiveManualBackup() async {
        let service = ReviewBackupService()
        let model = BackupModel(service: service)
        await model.refresh()
        let backup = Task { await model.backUpNow() }
        await service.waitUntilStarted()
        await model.handleAppEvent(.activation)
        #expect(model.phase == .backingUp)
        await model.refresh()
        await model.backUpNow()
        #expect(await service.manualBackupCount == 1)
        await service.release()
        await backup.value
        #expect(model.phase == .localCheckpointComplete)
        #expect(!model.isManualBackupInFlight)
    }

    @Test
    func oldModelCompletionMustNotCancelNewPreparedRestore() async throws {
        let first = try reviewPrepared(sequence: 1)
        let second = try reviewPrepared(sequence: 2)
        let backend = BackupRestoreService(operations: .init(
            prepare: { _, code in code == "first" ? first : second },
            cancel: { _ in },
            destructiveFence: { operation in try await operation() },
            revokeLifecycle: {},
            activate: { prepared, _ in .init(summary: prepared.summary) },
            removeWriterConfiguration: {},
            reconcilePreflights: {},
            reconcile: { .noTransaction }
        ))
        let service = LiveRestoreService(service: backend)
        let scope = ReviewRestoreScope()
        let model = RestoreModel(service: service, securityScope: scope)
        model.present()
        model.recoveryCode = "first"
        let old = Task {
            await model.prepare(URL(fileURLWithPath: "/first.kinloguebackup"))
        }
        await scope.waitUntilStopped()
        await model.cancel()
        model.present()
        model.recoveryCode = "second"
        await model.prepare(URL(fileURLWithPath: "/second.kinloguebackup"))
        #expect(model.phase == .awaitingReplaceConfirmation(second.summary))
        await scope.release()
        await old.value
        await model.confirmReplacement()
        #expect(model.phase == .restartRequired(second.summary))
    }
}

private actor ReviewBackupService: BackupServicing {
    func reauthorizeDestination(selectedParent: URL) async throws {}
    private(set) var manualBackupCount = 0
    private var started = false
    private var entered: [CheckedContinuation<Void, Never>] = []
    private var gate: CheckedContinuation<Void, Never>?

    func loadStatus() -> AppBackupStatus {
        .init(enrollment: .ready, destinationDisplayName: "Synthetic",
              isAutomaticBackupEnabled: false, retentionCount: 5,
              localCheckpointState: .unavailable, lastLocalVerificationAt: nil,
              nextDueAt: nil, lastFailure: nil, estimate: nil)
    }
    func beginSetup(selectedParent: URL) -> String { "synthetic" }
    func completeSetup(recoveryCodeReentry: String, independentlySaved: Bool) {}
    func cancelSetup() {}
    func resumePending(recoveryCode: String) {}
    func abandonPending() {}
    func setAutomaticBackupEnabled(_ enabled: Bool) -> BackupSchedulerOutcome { .disabled }
    func setRetentionCount(_ count: Int) {}
    func showBackupRepository() {}
    func handleSchedulerEvent(_ event: BackupSchedulerEvent) -> BackupSchedulerOutcome { .disabled }
    func backUpNow() async -> BackupCleanupOutcome {
        manualBackupCount += 1
        started = true
        entered.forEach { $0.resume() }
        entered.removeAll()
        await withCheckedContinuation { gate = $0 }
        return .complete
    }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { entered.append($0) }
    }
    func release() { gate?.resume(); gate = nil }
}

private actor ReviewRestoreScope: RestoreFileSecurityScope {
    private var stopped = false
    private var entered: [CheckedContinuation<Void, Never>] = []
    private var gate: CheckedContinuation<Void, Never>?
    func startAccessing(_ url: URL) -> Bool { true }
    func stopAccessing(_ url: URL) async {
        guard url.lastPathComponent == "first.kinloguebackup" else { return }
        stopped = true
        entered.forEach { $0.resume() }
        entered.removeAll()
        await withCheckedContinuation { gate = $0 }
    }
    func waitUntilStopped() async {
        if stopped { return }
        await withCheckedContinuation { entered.append($0) }
    }
    func release() { gate?.resume(); gate = nil }
}

private func reviewPrepared(sequence: UInt64) throws -> BackupPreparedRestore {
    let revision = try BackupRevision(
        generation: 1, commitID: UUID(), manifestDigest: Data(repeating: 1, count: 32)
    )
    let summary = BackupRestoreSummary(
        checkpointID: try BackupCheckpointID(bytes: Data(repeating: UInt8(sequence), count: 16)),
        revisionPair: try BackupRevisionPair(vault: revision, lanInbox: revision),
        sequence: sequence, memberCount: 0, recordCount: 0, inboxItemCount: 0,
        plaintextByteCount: 1, formatVersion: .current
    )
    var metadata = stat()
    metadata.st_mode = mode_t(S_IFDIR | S_IRWXU)
    metadata.st_uid = geteuid()
    metadata.st_dev = 1
    metadata.st_ino = 2
    return BackupPreparedRestore(
        summary: summary, operationID: UUID(),
        stagingURL: URL(fileURLWithPath: "/synthetic/staging"),
        stagingIdentity: try BackupRestoreDirectoryIdentity(metadata),
        preflightReceiptURL: URL(fileURLWithPath: "/synthetic/receipt.json"),
        activeRootName: "Vault"
    )
}
