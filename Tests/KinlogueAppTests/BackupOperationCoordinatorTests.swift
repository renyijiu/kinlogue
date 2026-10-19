import Foundation
import Testing
@testable import KinlogueApp

@Suite("Backup operation coordinator", .serialized)
struct BackupOperationCoordinatorTests {
    @Test
    func secondArchiveWhileOneIsRunningIsRefusedNotQueued() async throws {
        let coordinator = BackupOperationCoordinator()
        let gate = AsyncOperationGate()
        let first = Task { try await coordinator.run { await gate.wait(); return 1 } }
        #expect(await gate.waitUntilStarted())

        await #expect(throws: BackupOperationCoordinatorError.operationInProgress) {
            _ = try await coordinator.run { 2 }
        }
        #expect(await coordinator.isBusy)
        await gate.open()
        #expect(try await first.value == 1)
        #expect(try await coordinator.run { 3 } == 3)
        #expect(!(await coordinator.isBusy))
    }

    @Test
    func destructiveFenceCancelsAnUnpublishedBackupAndRefusesNewOnes() async throws {
        let coordinator = BackupOperationCoordinator()
        let gate = AsyncOperationGate()
        let backup = Task {
            try await coordinator.run {
                await withTaskCancellationHandler { await gate.wait() } onCancel: { Task { await gate.open() } }
                try Task.checkCancellation()
                return 1
            }
        }
        #expect(await gate.waitUntilStarted())
        let destructiveGate = AsyncOperationGate()
        let destructive = Task {
            try await coordinator.withDestructiveFence {
                await destructiveGate.wait()
                return 9
            }
        }
        #expect(await destructiveGate.waitUntilStarted())
        await #expect(throws: CancellationError.self) { _ = try await backup.value }
        await #expect(throws: BackupOperationCoordinatorError.destructiveOperationInProgress) {
            _ = try await coordinator.run { 2 }
        }
        await destructiveGate.open()
        #expect(try await destructive.value == 9)
        #expect(try await coordinator.run { 4 } == 4)
    }

    @Test
    func cancellingTheActiveOperationStopsIt() async throws {
        let coordinator = BackupOperationCoordinator()
        let gate = AsyncOperationGate()
        let backup = Task {
            try await coordinator.run {
                await withTaskCancellationHandler { await gate.wait() } onCancel: { Task { await gate.open() } }
                try Task.checkCancellation()
                return 1
            }
        }
        #expect(await gate.waitUntilStarted())
        await coordinator.cancelActiveOperation()
        await #expect(throws: CancellationError.self) { _ = try await backup.value }
    }
}
