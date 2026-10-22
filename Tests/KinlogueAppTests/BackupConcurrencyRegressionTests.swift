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
    func oldModelCompletionMustNotCancelNewPreparedRestore() async throws {
        let first = try reviewPrepared(ordinal: 1)
        let second = try reviewPrepared(ordinal: 2)
        let backend = BackupRestoreService(operations: .init(
            prepare: { url in url.lastPathComponent == "first.zip" ? first : second },
            cancel: { _ in },
            destructiveFence: { operation in try await operation() },
            revokeLifecycle: {},
            activate: { prepared, _ in .init(summary: prepared.summary) },
            disableAutomaticBackup: {},
            reconcilePreflights: {},
            reconcile: { .noTransaction }
        ))
        let service = LiveRestoreService(service: backend)
        let scope = ReviewRestoreScope()
        let model = RestoreModel(service: service, securityScope: scope)
        model.present()
        let old = Task { await model.prepare(URL(fileURLWithPath: "/first.zip")) }
        await scope.waitUntilStopped()
        await model.cancel()
        model.present()
        await model.prepare(URL(fileURLWithPath: "/second.zip"))
        #expect(model.phase == .awaitingReplaceConfirmation(second.summary))
        await scope.release()
        await old.value
        await model.confirmReplacement()
        #expect(model.phase == .restartRequired(second.summary))
    }
}

private actor ReviewRestoreScope: RestoreFileSecurityScope {
    private var stopped = false
    private var entered: [CheckedContinuation<Void, Never>] = []
    private var gate: CheckedContinuation<Void, Never>?
    func startAccessing(_ url: URL) -> Bool { true }
    func stopAccessing(_ url: URL) async {
        guard url.lastPathComponent == "first.zip" else { return }
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

private func reviewPrepared(ordinal: Int) throws -> BackupPreparedRestore {
    let revision = try BackupRevision(generation: 1, commitID: UUID(), manifestDigest: Data(repeating: 1, count: 32))
    let summary = BackupRestoreSummary(
        backupID: UUID(), revisionPair: try BackupRevisionPair(vault: revision, lanInbox: revision),
        createdAt: Date(timeIntervalSince1970: TimeInterval(ordinal)), creatorVersion: "1.0",
        memberCount: 0, recordCount: 0, inboxItemCount: 0, originalCount: 0, plaintextByteCount: 1,
        logicalDigest: Data(repeating: 0x5A, count: 32)
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
