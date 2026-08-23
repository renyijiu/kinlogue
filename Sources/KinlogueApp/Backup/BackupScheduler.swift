import Foundation
import KinlogueCore
import KinloguePlatform

enum BackupSchedulerEvent: Equatable, Sendable {
    case startup
    case activation
    case wake
    case mutation
}

enum BackupSchedulerOutcome: Equatable, Sendable {
    case disabled
    case alreadyCovered
    case scheduled(Date)
    case retryScheduled(Date)
    case completed
    case failed(BackupSemanticError)
}

/// App-lifetime scheduler. Its clocks and retry decisions live in the strict
/// app-private configuration record, so relaunch never grants a fresh quiet
/// period and never turns an actionable identity error into a busy loop.
actor BackupScheduler {
    static let quietPeriod: TimeInterval = 5 * 60
    static let minimumVerificationInterval: TimeInterval = 24 * 60 * 60
    static let mutationRetryDelays: [TimeInterval] = [60, 5 * 60, 15 * 60]

    private let configurationStore: BackupLocalConfigurationStore
    private let automaticRunner: any BackupAutomaticRunning

    init(
        configurationStore: BackupLocalConfigurationStore,
        automaticRunner: any BackupAutomaticRunning
    ) {
        self.configurationStore = configurationStore
        self.automaticRunner = automaticRunner
    }

    func setAutomaticBackupEnabled(
        _ enabled: Bool,
        currentPair: BackupRevisionPair,
        at now: Date = Date()
    ) async throws -> BackupSchedulerOutcome {
        guard enabled else { return try await disableAutomaticBackup() }
        let current = try await requireConfiguration()
        _ = try await configurationStore.updateAutomation(
            isAutomaticBackupEnabled: true,
            expectedRevision: current.revision
        )
        return try await observe(currentPair, at: now)
    }

    func disableAutomaticBackup() async throws -> BackupSchedulerOutcome {
        let current = try await requireConfiguration()
        _ = try await configurationStore.updateAutomation(
            isAutomaticBackupEnabled: false,
            expectedRevision: current.revision
        )
        return .disabled
    }

    func setRetentionCount(_ count: BackupRetentionCount) async throws {
        let current = try await requireConfiguration()
        _ = try await configurationStore.updateAutomation(
            retentionCount: count,
            expectedRevision: current.revision
        )
    }

    func disableForDestructiveReset() async throws {
        guard let current = try await configurationStore.load(), current.phase == .enabled else {
            return
        }
        _ = try await configurationStore.disableForDestructiveReset(
            expectedRevision: current.revision
        )
    }

    @discardableResult
    func observe(
        _ pair: BackupRevisionPair,
        at now: Date = Date()
    ) async throws -> BackupSchedulerOutcome {
        let current = try await requireConfiguration()
        guard current.automation.isAutomaticBackupEnabled else { return .disabled }
        if current.scheduler.lastCoveredRevisionPair == pair {
            return .alreadyCovered
        }
        if current.scheduler.firstObservedRevisionPair == pair,
           let dueAt = current.scheduler.dueAt {
            return .scheduled(current.scheduler.retryDueAt ?? dueAt)
        }
        guard clockIsContinuous(configuration: current, now: now) else {
            _ = try await configurationStore.markBackupFailure(
                .verificationFailed,
                retryAttempt: 0,
                retryDueAt: nil,
                expectedRevision: current.revision
            )
            return .failed(.verificationFailed)
        }
        let quietDue = now.addingTimeInterval(Self.quietPeriod)
        let minimumDue = current.scheduler.lastLocalVerificationAt?
            .addingTimeInterval(Self.minimumVerificationInterval)
        let dueAt = max(quietDue, minimumDue ?? quietDue)
        _ = try await configurationStore.observeRevisionPair(
            pair,
            observedAt: now,
            dueAt: dueAt,
            expectedRevision: current.revision
        )
        return .scheduled(dueAt)
    }

    func handle(
        _ event: BackupSchedulerEvent,
        currentPair: BackupRevisionPair,
        at now: Date = Date()
    ) async throws -> BackupSchedulerOutcome {
        _ = event
        var current = try await requireConfiguration()
        guard current.automation.isAutomaticBackupEnabled else { return .disabled }
        if current.scheduler.lastCoveredRevisionPair == currentPair {
            if let failure = current.scheduler.lastFailure,
               Self.isRecoverable(failure) {
                _ = try await configurationStore.observeRevisionPair(
                    currentPair,
                    observedAt: now,
                    dueAt: now,
                    expectedRevision: current.revision
                )
            }
            return .alreadyCovered
        }
        if current.scheduler.firstObservedRevisionPair != currentPair {
            _ = try await observe(currentPair, at: now)
            current = try await requireConfiguration()
        }
        guard clockIsContinuous(configuration: current, now: now) else {
            current = try await configurationStore.markBackupFailure(
                .verificationFailed,
                retryAttempt: 0,
                retryDueAt: nil,
                expectedRevision: current.revision
            )
            return .failed(current.scheduler.lastFailure ?? .verificationFailed)
        }
        if let terminal = Self.terminalFailure(for: current) { return terminal }
        guard let baseDue = current.scheduler.dueAt else {
            return try await observe(currentPair, at: now)
        }
        let dueAt = current.scheduler.retryDueAt ?? baseDue
        guard now >= dueAt else {
            return current.scheduler.retryDueAt == nil
                ? .scheduled(dueAt)
                : .retryScheduled(dueAt)
        }

        do {
            let result = try await automaticRunner.runAutomaticBackup(
                expectedPair: currentPair,
                at: now
            )
            guard result.revisionPair == currentPair else {
                return try await recordRecoverableFailure(
                    .sourceChanged,
                    current: current,
                    now: now
                )
            }
            let latest = try await requireConfiguration()
            _ = try await configurationStore.markBackupSuccess(
                result.revisionPair,
                verifiedAt: now,
                expectedRevision: latest.revision
            )
            return .completed
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as BackupOperationCoordinatorError {
            switch error {
            case .semantic(let semantic) where Self.isRecoverable(semantic):
                let latest = try await requireConfiguration()
                return try await recordRecoverableFailure(
                    semantic,
                    current: latest,
                    now: now
                )
            case .semantic(let semantic):
                let latest = try await requireConfiguration()
                _ = try await configurationStore.markBackupFailure(
                    semantic,
                    retryAttempt: 0,
                    retryDueAt: nil,
                    expectedRevision: latest.revision
                )
                return .failed(semantic)
            case .operationInProgress:
                return .failed(.operationInProgress)
            case .destructiveOperationInProgress:
                return .failed(.operationInProgress)
            }
        }
    }

    /// Persists an offline failure that happened while resolving the selected
    /// directory, before a source snapshot or automatic runner could be
    /// admitted. Existing source observation and quiet-period metadata remain
    /// authoritative; this method never invents a revision pair.
    func recordDestinationOffline(
        at now: Date = Date()
    ) async throws -> BackupSchedulerOutcome {
        let current = try await requireConfiguration()
        guard current.automation.isAutomaticBackupEnabled else { return .disabled }
        guard clockIsContinuous(configuration: current, now: now) else {
            _ = try await configurationStore.markBackupFailure(
                .verificationFailed,
                retryAttempt: 0,
                retryDueAt: nil,
                expectedRevision: current.revision
            )
            return .failed(.verificationFailed)
        }
        if let terminal = Self.terminalFailure(for: current) { return terminal }
        if let retryDueAt = current.scheduler.retryDueAt, now < retryDueAt {
            return .retryScheduled(retryDueAt)
        }
        return try await recordRecoverableFailure(
            .repositoryOffline,
            current: current,
            now: now
        )
    }

    private func recordRecoverableFailure(
        _ failure: BackupSemanticError,
        current: BackupLocalConfiguration,
        now: Date
    ) async throws -> BackupSchedulerOutcome {
        precondition(Self.isRecoverable(failure))
        let completedRetries = current.scheduler.mutationRetryAttempt
        guard completedRetries < Self.mutationRetryDelays.count else {
            _ = try await configurationStore.markBackupFailure(
                failure,
                retryAttempt: completedRetries,
                retryDueAt: nil,
                expectedRevision: current.revision
            )
            return .failed(failure)
        }
        let retryAttempt = completedRetries + 1
        let delayedDueAt = now.addingTimeInterval(
            Self.mutationRetryDelays[completedRetries]
        )
        let retryDueAt = max(delayedDueAt, current.scheduler.dueAt ?? delayedDueAt)
        _ = try await configurationStore.markBackupFailure(
            failure,
            retryAttempt: retryAttempt,
            retryDueAt: retryDueAt,
            expectedRevision: current.revision
        )
        return .retryScheduled(retryDueAt)
    }

    private static func terminalFailure(
        for configuration: BackupLocalConfiguration
    ) -> BackupSchedulerOutcome? {
        guard let failure = configuration.scheduler.lastFailure,
              configuration.scheduler.retryDueAt == nil else { return nil }
        if !isRecoverable(failure)
            || configuration.scheduler.mutationRetryAttempt >= mutationRetryDelays.count {
            return .failed(failure)
        }
        return nil
    }

    private nonisolated static func isRecoverable(
        _ failure: BackupSemanticError
    ) -> Bool {
        failure == .sourceChanged || failure == .repositoryOffline
    }

    private func requireConfiguration() async throws -> BackupLocalConfiguration {
        guard let configuration = try await configurationStore.load(),
              configuration.phase == .enabled else {
            throw BackupOperationCoordinatorError.semantic(.notConfigured)
        }
        return configuration
    }

    private func clockIsContinuous(
        configuration: BackupLocalConfiguration,
        now: Date
    ) -> Bool {
        guard now.timeIntervalSinceReferenceDate.isFinite else { return false }
        let scheduler = configuration.scheduler
        return scheduler.firstObservedAt.map { $0 <= now } ?? true
            && scheduler.lastLocalVerificationAt.map { $0 <= now } ?? true
    }
}
