import Darwin
import Foundation
import KinlogueCore
import Testing
@testable import KinlogueApp
@testable import KinloguePlatform

@Suite("Backup restore service")
struct BackupRestoreServiceTests {
    @Test
    func preparationDoesNotEnterDestructiveBoundary() async throws {
        let events = RestoreServiceEvents()
        let prepared = try makePreparedRestore()
        let service = BackupRestoreService(operations: makeOperations(
            events: events,
            prepared: prepared
        ))

        let returned = try await service.prepare(
            checkpointURL: URL(fileURLWithPath: "/synthetic.kinloguebackup"),
            recoveryCode: "synthetic"
        )

        #expect(returned.summary == prepared.summary)
        #expect(await events.values == ["prepare"])
    }

    @Test
    func confirmationFencesBackupsThenRevokesLifecycleBeforeActivationAndWriterReset() async throws {
        let events = RestoreServiceEvents()
        let prepared = try makePreparedRestore()
        let service = BackupRestoreService(operations: makeOperations(
            events: events,
            prepared: prepared
        ))

        let result = try await service.activateAfterConfirmation(prepared)

        #expect(result.requiresApplicationRestart)
        #expect(await events.values == [
            "fence-begin",
            "revoke",
            "activate-begin",
            "remove-writer",
            "activate-end",
            "fence-end",
        ])
    }

    @Test
    func startupReconciliationUsesTransactionBeforeServicesAreExposed() async throws {
        let events = RestoreServiceEvents()
        let prepared = try makePreparedRestore()
        let service = BackupRestoreService(operations: makeOperations(
            events: events,
            prepared: prepared
        ))

        #expect(try await service.reconcileBeforeStartingServices() == .committed)
        #expect(await events.values == ["reconcile-preflights", "reconcile"])
    }

    @Test
    func latePreparationCancelsOnlyItsOwnStagingAndLeavesTheNewerRestoreActivatable() async throws {
        let controller = RestorePreparationController()
        let backend = BackupRestoreService(operations: controller.operations)
        let service = LiveRestoreService(service: backend)

        let first = Task {
            try await service.prepare(
                checkpointURL: URL(fileURLWithPath: "/first.kinloguebackup"),
                recoveryCode: "first"
            )
        }
        await controller.waitUntilFirstPreparationEntered()

        let secondSummary = try await service.prepare(
            checkpointURL: URL(fileURLWithPath: "/second.kinloguebackup"),
            recoveryCode: "second"
        )
        await controller.resumeFirstPreparation()

        await #expect(throws: CancellationError.self) {
            _ = try await first.value
        }
        let activation = try await service.activatePreparedRestore()

        #expect(secondSummary.sequence == 2)
        #expect(activation.summary.sequence == 2)
        #expect(controller.cancelledSequences == [1])
        #expect(controller.activatedSequences == [2])
    }
}

private actor RestorePreparationController {
    private let first: BackupPreparedRestore
    private let second: BackupPreparedRestore
    private var firstEntered = false
    private var firstWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstContinuation: CheckedContinuation<Void, Never>?
    private nonisolated let sequenceRecorder = RestoreSequenceRecorder()

    init() {
        first = try! makePreparedRestore(sequence: 1)
        second = try! makePreparedRestore(sequence: 2)
    }

    nonisolated var operations: BackupRestoreService.Operations {
        BackupRestoreService.Operations(
            prepare: { [self] _, recoveryCode in
                try await prepare(recoveryCode: recoveryCode)
            },
            cancel: { [self] prepared in
                sequenceRecorder.recordCancellation(prepared.summary.sequence)
            },
            destructiveFence: { operation in try await operation() },
            revokeLifecycle: {},
            activate: { [self] prepared, resetWriter in
                try await resetWriter()
                sequenceRecorder.recordActivation(prepared.summary.sequence)
                return BackupRestoreActivationResult(summary: prepared.summary)
            },
            removeWriterConfiguration: {},
            reconcilePreflights: {},
            reconcile: { .noTransaction }
        )
    }

    func waitUntilFirstPreparationEntered() async {
        if firstEntered { return }
        await withCheckedContinuation { firstWaiters.append($0) }
    }

    func resumeFirstPreparation() {
        firstContinuation?.resume()
        firstContinuation = nil
    }

    private func prepare(recoveryCode: String) async throws -> BackupPreparedRestore {
        if recoveryCode == "first" {
            firstEntered = true
            firstWaiters.forEach { $0.resume() }
            firstWaiters.removeAll()
            await withCheckedContinuation { firstContinuation = $0 }
            return first
        }
        return second
    }

    nonisolated var cancelledSequences: [UInt64] {
        sequenceRecorder.cancelledSequences
    }

    nonisolated var activatedSequences: [UInt64] {
        sequenceRecorder.activatedSequences
    }
}

private final class RestoreSequenceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellations: [UInt64] = []
    private var activations: [UInt64] = []

    var cancelledSequences: [UInt64] {
        lock.withLock { cancellations }
    }

    var activatedSequences: [UInt64] {
        lock.withLock { activations }
    }

    func recordCancellation(_ sequence: UInt64) {
        lock.withLock { cancellations.append(sequence) }
    }

    func recordActivation(_ sequence: UInt64) {
        lock.withLock { activations.append(sequence) }
    }
}

private actor RestoreServiceEvents {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}

private func makeOperations(
    events: RestoreServiceEvents,
    prepared: BackupPreparedRestore
) -> BackupRestoreService.Operations {
    BackupRestoreService.Operations(
        prepare: { _, _ in
            await events.append("prepare")
            return prepared
        },
        cancel: { _ in },
        destructiveFence: { operation in
            await events.append("fence-begin")
            let result = try await operation()
            await events.append("fence-end")
            return result
        },
        revokeLifecycle: {
            await events.append("revoke")
        },
        activate: { prepared, resetWriter in
            await events.append("activate-begin")
            try await resetWriter()
            await events.append("activate-end")
            return BackupRestoreActivationResult(summary: prepared.summary)
        },
        removeWriterConfiguration: {
            await events.append("remove-writer")
        },
        reconcilePreflights: {
            await events.append("reconcile-preflights")
        },
        reconcile: {
            await events.append("reconcile")
            return .committed
        }
    )
}

private func makePreparedRestore(sequence: UInt64 = 1) throws -> BackupPreparedRestore {
    let vault = try BackupRevision(
        generation: 1,
        commitID: UUID(),
        manifestDigest: Data(repeating: 0x11, count: 32)
    )
    let inbox = try BackupRevision(
        generation: 1,
        commitID: UUID(),
        manifestDigest: Data(repeating: 0x22, count: 32)
    )
    let summary = BackupRestoreSummary(
        checkpointID: try BackupCheckpointID(bytes: Data(repeating: 0x33, count: 16)),
        revisionPair: try BackupRevisionPair(vault: vault, lanInbox: inbox),
        sequence: sequence,
        memberCount: 0,
        recordCount: 0,
        inboxItemCount: 0,
        plaintextByteCount: 1,
        formatVersion: .current
    )
    let base = URL(fileURLWithPath: "/synthetic-parent", isDirectory: true)
    var stagingMetadata = stat()
    stagingMetadata.st_mode = mode_t(S_IFDIR | S_IRWXU)
    stagingMetadata.st_uid = geteuid()
    stagingMetadata.st_dev = 1
    stagingMetadata.st_ino = 2
    return BackupPreparedRestore(
        summary: summary,
        operationID: UUID(),
        stagingURL: base.appendingPathComponent("staging", isDirectory: true),
        stagingIdentity: try BackupRestoreDirectoryIdentity(stagingMetadata),
        preflightReceiptURL: base.appendingPathComponent("receipt.json"),
        activeRootName: "Vault"
    )
}
