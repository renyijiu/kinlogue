import Foundation
import KinlogueCore
import KinloguePlatform

enum BackupOperationCoordinatorError: Error, Equatable, Sendable {
    case operationInProgress
    case destructiveOperationInProgress
    case semantic(BackupSemanticError)
}

struct BackupCheckpointCreation: Sendable {
    let revisionPair: BackupRevisionPair
}

enum BackupCleanupOutcome: Equatable, Sendable {
    case complete
    case deferred(BackupSemanticError)
}

struct BackupOperationResult: Sendable {
    let revisionPair: BackupRevisionPair
    let cleanup: BackupCleanupOutcome
}

protocol BackupCheckpointCreating: Sendable {
    func createCheckpoint(
        configuration: BackupLocalConfiguration
    ) async throws -> BackupCheckpointCreation
}

protocol BackupRetentionExecuting: Sendable {
    func applyRetention(
        configuration: BackupLocalConfiguration,
        now: Date
    ) async -> BackupCleanupOutcome
}

protocol BackupAutomaticRunning: Sendable {
    func runAutomaticBackup(
        expectedPair: BackupRevisionPair,
        at: Date
    ) async throws -> BackupOperationResult
}

/// One app-owned serialization point for checkpoint creation, automatic work,
/// retention, and future U6 destructive transactions. The Settings view is an
/// observer and cannot accidentally create a second writer by being reopened.
actor BackupOperationCoordinator: BackupAutomaticRunning {
    private struct ActiveOperation {
        let id: UUID
        let task: Task<BackupOperationResult, Error>
    }

    private let configurationStore: BackupLocalConfigurationStore
    private let checkpointCreator: any BackupCheckpointCreating
    private let retentionExecutor: any BackupRetentionExecuting
    private var activeOperation: ActiveOperation?
    private var destructiveFenceHeld = false

    init(
        configurationStore: BackupLocalConfigurationStore,
        checkpointCreator: any BackupCheckpointCreating,
        retentionExecutor: any BackupRetentionExecuting
    ) {
        self.configurationStore = configurationStore
        self.checkpointCreator = checkpointCreator
        self.retentionExecutor = retentionExecutor
    }

    func backUpNow(at now: Date = Date()) async throws -> BackupOperationResult {
        try await startBackup(expectedPair: nil, at: now, recordsCoverage: true)
    }

    func runAutomaticBackup(
        expectedPair: BackupRevisionPair,
        at now: Date
    ) async throws -> BackupOperationResult {
        try await startBackup(expectedPair: expectedPair, at: now, recordsCoverage: false)
    }

    func cancelForApplicationTermination() {
        activeOperation?.task.cancel()
    }

    func withDestructiveFence<Result: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        guard !destructiveFenceHeld else {
            throw BackupOperationCoordinatorError.destructiveOperationInProgress
        }
        destructiveFenceHeld = true
        if let activeOperation {
            activeOperation.task.cancel()
            _ = await activeOperation.task.result
            finishOperation(id: activeOperation.id)
        }
        defer { destructiveFenceHeld = false }
        return try await operation()
    }

    private func startBackup(
        expectedPair: BackupRevisionPair?,
        at now: Date,
        recordsCoverage: Bool
    ) async throws -> BackupOperationResult {
        guard !destructiveFenceHeld else {
            throw BackupOperationCoordinatorError.destructiveOperationInProgress
        }
        guard activeOperation == nil else {
            throw BackupOperationCoordinatorError.operationInProgress
        }
        let id = UUID()
        let configurationStore = self.configurationStore
        let checkpointCreator = self.checkpointCreator
        let retentionExecutor = self.retentionExecutor
        let task = Task<BackupOperationResult, Error> {
            try Task.checkCancellation()
            guard let configuration = try await configurationStore.load(),
                  configuration.phase == .enabled else {
                throw BackupOperationCoordinatorError.semantic(.notConfigured)
            }
            let creation: BackupCheckpointCreation
            do {
                creation = try await checkpointCreator.createCheckpoint(
                    configuration: configuration
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as BackupOperationCoordinatorError {
                throw error
            } catch let error as EncryptedCheckpointWriterError {
                throw Self.mapWriterError(error)
            } catch let error as BackupRepositoryError {
                switch error {
                case .historyFork:
                    throw BackupOperationCoordinatorError.semantic(.repositoryHistoryFork)
                case .resourceLimit:
                    throw BackupOperationCoordinatorError.semantic(.resourceLimitExceeded)
                case .offline:
                    throw BackupOperationCoordinatorError.semantic(.repositoryOffline)
                case .identityChanged:
                    throw BackupOperationCoordinatorError.semantic(.repositoryIdentityConflict)
                case .verificationFailed, .ioFailure, .synchronizationFailed:
                    throw BackupOperationCoordinatorError.semantic(.verificationFailed)
                }
            } catch {
                throw BackupOperationCoordinatorError.semantic(.verificationFailed)
            }
            if let expectedPair, creation.revisionPair != expectedPair {
                throw BackupOperationCoordinatorError.semantic(.sourceChanged)
            }

            var latest = try await configurationStore.load()
            guard let loaded = latest, loaded.phase == .enabled else {
                throw BackupOperationCoordinatorError.semantic(.identityNeedsEnrollment)
            }
            if recordsCoverage {
                latest = try await configurationStore.markBackupSuccess(
                    creation.revisionPair,
                    verifiedAt: now,
                    expectedRevision: loaded.revision
                )
            }
            guard let retentionConfiguration = latest else {
                throw BackupOperationCoordinatorError.semantic(.identityNeedsEnrollment)
            }
            let cleanup = await retentionExecutor.applyRetention(
                configuration: retentionConfiguration,
                now: now
            )
            return BackupOperationResult(
                revisionPair: creation.revisionPair,
                cleanup: cleanup
            )
        }
        activeOperation = .init(id: id, task: task)
        defer { finishOperation(id: id) }
        return try await task.value
    }

    private func finishOperation(id: UUID) {
        guard activeOperation?.id == id else { return }
        activeOperation = nil
    }

    private nonisolated static func mapWriterError(
        _ error: EncryptedCheckpointWriterError
    ) -> BackupOperationCoordinatorError {
        switch error {
        case .sourceChanged:
            .semantic(.sourceChanged)
        case .repositoryIdentityChanged:
            .semantic(.repositoryIdentityConflict)
        case .capacityInsufficient:
            .semantic(.capacityInsufficient)
        case .publicationIndeterminate:
            .semantic(.publicationIndeterminate)
        case .invalidConfiguration:
            .semantic(.identityNeedsEnrollment)
        case .resourceLimit:
            .semantic(.resourceLimitExceeded)
        case .finalAlreadyExists, .verificationFailed, .ioFailure:
            .semantic(.verificationFailed)
        }
    }
}

/// Concrete U4 bridge for an already-resolved, security-scoped local
/// repository. U7 owns opening/closing the bookmark scope around this adapter.
struct LocalDirectoryCheckpointCreator: BackupCheckpointCreating {
    let publisher: BackupCheckpointPublisher

    func createCheckpoint(
        configuration: BackupLocalConfiguration
    ) async throws -> BackupCheckpointCreation {
        let result = try await publisher.publishNext(configuration: configuration)
        return .init(revisionPair: result.revisionPair)
    }
}

struct LocalDirectoryRetentionAdapter: BackupRetentionExecuting {
    let executor: BackupRetentionExecutor

    func applyRetention(
        configuration: BackupLocalConfiguration,
        now: Date
    ) async -> BackupCleanupOutcome {
        switch await executor.execute(configuration: configuration, now: now) {
        case .complete:
            return .complete
        case .deferred(let error):
            return .deferred(error)
        }
    }
}
