import Foundation
import KinlogueCore

public enum BackupRetentionExecutionOutcome: Equatable, Sendable {
    case complete(deletedCount: Int)
    case deferred(BackupSemanticError)
}

/// Applies Core's conservative plan against exact repository leaves. One
/// authoritative scan freezes the batch while the repository mutation lease
/// excludes cooperating publishers. Every deletion still requires the same
/// configuration revision, an exact witness, the scan's directory generation,
/// and descriptor-rooted target/planned-keep revalidation after the coordinated
/// materialization window.
public actor BackupRetentionExecutor {
    private let repository: BackupRepository
    private let configurationStore: BackupLocalConfigurationStore
    private let continuityStartedAt: Date
    private let beforeDelete: @Sendable (BackupRepositoryEntry) throws -> Void
    private var previousEvaluationAt: Date?

    public init(
        repository: BackupRepository,
        configurationStore: BackupLocalConfigurationStore
    ) {
        self.repository = repository
        self.configurationStore = configurationStore
        // The witness ledger is already durable and bound to the exact
        // repository/file identity. A normal relaunch must not restart every
        // 24-hour dwell window, otherwise users who close the app daily would
        // never converge to their configured retention count. Callers use the
        // internal initializer with a concrete reset time only after an
        // identity/bookmark/ledger continuity break.
        continuityStartedAt = .distantPast
        beforeDelete = { _ in }
    }

    init(
        repository: BackupRepository,
        configurationStore: BackupLocalConfigurationStore,
        continuityStartedAt: Date,
        beforeDelete: @escaping @Sendable (BackupRepositoryEntry) throws -> Void = { _ in }
    ) {
        self.repository = repository
        self.configurationStore = configurationStore
        self.continuityStartedAt = continuityStartedAt
        self.beforeDelete = beforeDelete
    }

    init(
        repository: BackupRepository,
        configurationStore: BackupLocalConfigurationStore,
        beforeDelete: @escaping @Sendable (BackupRepositoryEntry) throws -> Void
    ) {
        self.repository = repository
        self.configurationStore = configurationStore
        continuityStartedAt = .distantPast
        self.beforeDelete = beforeDelete
    }

    public func execute(
        configuration: BackupLocalConfiguration,
        now: Date
    ) async -> BackupRetentionExecutionOutcome {
        guard now.timeIntervalSinceReferenceDate.isFinite else {
            return .deferred(.retentionDeferred)
        }
        do {
            let lease = try await repository.acquireMutationLease()
            defer { lease.release() }
            guard let loaded = try await configurationStore.load(),
                  loaded.phase == .enabled,
                  loaded.writerIdentity == configuration.writerIdentity else {
                return .deferred(.identityNeedsEnrollment)
            }
            var activeConfiguration = loaded
            let scan = try repository.scan(holding: lease)
            if case .fork = scan.history {
                return .deferred(.repositoryHistoryFork)
            }
            guard let activeWitnesses = try effectiveWitnesses(
                activeConfiguration.verificationWitnesses,
                now: now
            ) else {
                return .deferred(.retentionDeferred)
            }
            let initial = BackupRetentionPolicy.plan(
                candidates: scan.retentionCandidates,
                witnesses: activeWitnesses,
                context: context(
                    configuration: activeConfiguration,
                    history: scan.history,
                    now: now
                )
            )
            if initial.blocker == .historyFork {
                return .deferred(.repositoryHistoryFork)
            }
            if initial.blocker == .clockRollback
                || initial.blocker == .continuityUnproven {
                return .deferred(.retentionDeferred)
            }
            guard !initial.delete.isEmpty else {
                previousEvaluationAt = now
                return .complete(deletedCount: 0)
            }

            let entriesByCheckpointID: [BackupCheckpointID: BackupRepositoryEntry] = Dictionary(
                uniqueKeysWithValues: scan.entries.compactMap { entry in
                    guard case let .verified(point) = entry.verification else { return nil }
                    return (point.checkpointID, entry)
                }
            )
            guard initial.delete.allSatisfy({ entriesByCheckpointID[$0] != nil }) else {
                return .deferred(.retentionDeferred)
            }
            let protectedEntries = initial.keep.compactMap { entriesByCheckpointID[$0] }
            guard protectedEntries.count == initial.keep.count else {
                return .deferred(.retentionDeferred)
            }

            var deletedCount = 0
            for checkpointID in initial.delete {
                try Task.checkCancellation()
                guard let entry = entriesByCheckpointID[checkpointID] else {
                    return .deferred(.retentionDeferred)
                }
                guard let current = try await configurationStore.load(),
                      current.phase == .enabled,
                      current.writerIdentity == activeConfiguration.writerIdentity else {
                    return .deferred(.identityNeedsEnrollment)
                }
                guard current.revision == activeConfiguration.revision else {
                    return .deferred(.retentionDeferred)
                }
                guard let currentWitnesses = try effectiveWitnesses(
                    current.verificationWitnesses,
                    now: now
                ), hasExactDeletableWitness(
                    for: entry,
                    in: currentWitnesses,
                    configuration: current,
                    now: now
                ) else {
                    return .deferred(.retentionDeferred)
                }
                try beforeDelete(entry)
                try Task.checkCancellation()

                guard let afterHook = try await configurationStore.load(),
                      afterHook.phase == .enabled,
                      afterHook.writerIdentity == current.writerIdentity else {
                    return .deferred(.identityNeedsEnrollment)
                }
                guard afterHook.revision == current.revision,
                      let afterHookWitnesses = try effectiveWitnesses(
                        afterHook.verificationWitnesses,
                        now: now
                      ),
                      hasExactDeletableWitness(
                        for: entry,
                        in: afterHookWitnesses,
                        configuration: afterHook,
                        now: now
                      ) else {
                    return .deferred(.retentionDeferred)
                }
                do {
                    activeConfiguration = try await configurationStore
                        .removeVerificationWitness(
                            checkpointID: checkpointID,
                            expectedConfigurationRevision: afterHook.revision,
                            beforeRemoval: { [repository] in
                                // This reopens only the named leaf and verifies
                                // type, link count, inode, byte count, signed
                                // checkpoint, and repository identity digest.
                                // It also fences the authoritative scan's
                                // directory generation and every exact leaf
                                // that the retention plan promised to keep.
                                try repository.deleteExact(
                                    entry,
                                    preserving: protectedEntries,
                                    holding: lease
                                )
                            }
                        )
                } catch BackupRepositoryError.identityChanged {
                    return .deferred(.retentionDeferred)
                }
                deletedCount += 1
            }
            previousEvaluationAt = now
            return .complete(deletedCount: deletedCount)
        } catch is CancellationError {
            return .deferred(.retentionDeferred)
        } catch let error as BackupRepositoryError {
            switch error {
            case .historyFork:
                return .deferred(.repositoryHistoryFork)
            case .offline:
                return .deferred(.repositoryOffline)
            case .identityChanged:
                return .deferred(.repositoryIdentityConflict)
            case .resourceLimit:
                return .deferred(.resourceLimitExceeded)
            case .verificationFailed, .ioFailure, .synchronizationFailed:
                return .deferred(.retentionDeferred)
            }
        } catch {
            return .deferred(.retentionDeferred)
        }
    }

    private func context(
        configuration: BackupLocalConfiguration,
        history: BackupRepositoryHistory,
        now: Date
    ) -> BackupRetentionContext {
        BackupRetentionContext(
            currentSetID: configuration.descriptor.setID,
            currentWriterEpoch: configuration.writerEpoch,
            retentionCount: configuration.automation.retentionCount,
            history: history,
            continuity: .proven,
            now: now,
            previousEvaluationAt: previousEvaluationAt,
            completedNewLocalVerification: true
        )
    }

    private func hasExactDeletableWitness(
        for entry: BackupRepositoryEntry,
        in witnesses: [BackupDurableFullReaderWitness],
        configuration: BackupLocalConfiguration,
        now: Date
    ) -> Bool {
        guard case let .verified(point) = entry.verification,
              let identity = entry.repositoryIdentityDigest,
              identity.count == 32 else { return false }
        let matches = witnesses.filter { witness in
            witness.writerEpoch == configuration.writerEpoch
                && witness.setID == point.setID
                && witness.checkpointID == point.checkpointID
                && witness.deviceID == point.deviceID
                && witness.authorizationID == point.authorizationID
                && witness.sequence == point.sequence
                && witness.commitment == point.commitment
                && witness.repositoryIdentityDigest == identity
        }
        guard matches.count == 1, let witness = matches.first else { return false }
        return witness.continuousObservationStartedAt <= now
            && witness.lastObservedAt <= now
            && now.timeIntervalSince(witness.continuousObservationStartedAt)
                >= BackupDurableFullReaderWitness.conservativeDwell
    }

    private func effectiveWitnesses(
        _ witnesses: [BackupDurableFullReaderWitness],
        now: Date
    ) throws -> [BackupDurableFullReaderWitness]? {
        guard continuityStartedAt.timeIntervalSinceReferenceDate.isFinite,
              continuityStartedAt <= now else { return nil }
        return try witnesses.map { witness in
            guard witness.lastObservedAt <= now else {
                throw BackupRepositoryError.verificationFailed
            }
            let checkpoint = try BackupPublicCheckpoint(
                setID: witness.setID,
                checkpointID: witness.checkpointID,
                deviceID: witness.deviceID,
                authorizationID: witness.authorizationID,
                sequence: witness.sequence,
                commitment: witness.commitment
            )
            let observedStart = max(
                witness.continuousObservationStartedAt,
                continuityStartedAt
            )
            return try BackupDurableFullReaderWitness(
                checkpoint: checkpoint,
                writerEpoch: witness.writerEpoch,
                repositoryIdentityDigest: witness.repositoryIdentityDigest,
                continuousObservationStartedAt: observedStart,
                lastObservedAt: max(witness.lastObservedAt, observedStart)
            )
        }
    }
}
