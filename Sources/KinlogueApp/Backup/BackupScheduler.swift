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
    case failed(BackupFailure)
}

/// One automatic backup that finished and was recorded in the settings.
struct BackupRunResult: Equatable, Sendable {
    let fileName: String
    let completedAt: Date
    let revision: BackupLibraryRevision
    /// The backup was written, but older ones could not all be checked or removed.
    let cleanupDeferred: Bool
}

protocol BackupAutomaticRunning: Sendable {
    func runAutomaticBackup(expected: BackupLibraryRevision, at: Date) async throws -> BackupRunResult
}

/// Decides when automatic backups run. Its timing lives in the app-private settings, so a
/// relaunch never grants a fresh quiet period and a failure that needs the person never turns
/// into a busy loop.
actor BackupScheduler {
    static let quietPeriod: TimeInterval = 5 * 60
    static let minimumInterval: TimeInterval = 24 * 60 * 60
    static let retryDelays: [TimeInterval] = [60, 5 * 60, 15 * 60]

    private let store: BackupSettingsStore
    private let runner: any BackupAutomaticRunning

    init(store: BackupSettingsStore, runner: any BackupAutomaticRunning) {
        self.store = store
        self.runner = runner
    }

    func enableAutomaticBackup(current: BackupLibraryRevision, at now: Date) throws -> BackupSchedulerOutcome {
        try store.update { settings in
            guard settings.folder != nil else { throw BackupFailure.notConfigured }
            settings.isAutomaticBackupEnabled = true
        }
        return try observe(current, at: now)
    }

    /// Turning automatic backups off only changes the settings; it never reads the library.
    func disableAutomaticBackup() throws -> BackupSchedulerOutcome {
        try store.update { settings in
            settings.isAutomaticBackupEnabled = false
            settings.scheduler.firstObservedRevision = nil
            settings.scheduler.firstObservedAt = nil
            settings.scheduler.dueAt = nil
            settings.scheduler.retryDueAt = nil
            settings.scheduler.retryAttempt = 0
        }
        return .disabled
    }

    /// Records that the library reached `revision`; the backup is due after the quiet period,
    /// and never sooner than a day after the last one.
    @discardableResult
    func observe(_ revision: BackupLibraryRevision, at now: Date) throws -> BackupSchedulerOutcome {
        try store.update { settings in
            guard settings.folder != nil, settings.isAutomaticBackupEnabled else { return .disabled }
            var scheduler = settings.scheduler
            if scheduler.lastCoveredRevision == revision { return .alreadyCovered }
            if scheduler.firstObservedRevision == revision, let dueAt = scheduler.dueAt {
                return .scheduled(scheduler.retryDueAt ?? dueAt)
            }
            let quietDue = now.addingTimeInterval(Self.quietPeriod)
            // A clock set back must not push the next backup a day past what it would be.
            let minimumDue = scheduler.lastBackupAt.map { min($0, now).addingTimeInterval(Self.minimumInterval) }
            let dueAt = max(quietDue, minimumDue ?? quietDue)
            scheduler.firstObservedRevision = revision
            scheduler.firstObservedAt = now
            scheduler.dueAt = dueAt
            scheduler.lastFailure = nil
            scheduler.retryAttempt = 0
            scheduler.retryDueAt = nil
            settings.scheduler = scheduler
            return .scheduled(dueAt)
        }
    }

    func handle(
        _ event: BackupSchedulerEvent, current: BackupLibraryRevision, at now: Date
    ) async throws -> BackupSchedulerOutcome {
        _ = event
        var settings = try store.load()
        guard settings.folder != nil, settings.isAutomaticBackupEnabled else { return .disabled }
        if settings.scheduler.lastCoveredRevision == current {
            if let failure = settings.scheduler.lastFailure, failure.isRecoverable {
                try store.update { settings in
                    settings.scheduler.lastFailure = nil
                    settings.scheduler.retryAttempt = 0
                    settings.scheduler.retryDueAt = nil
                }
            }
            return .alreadyCovered
        }
        if settings.scheduler.firstObservedRevision != current {
            let outcome = try observe(current, at: now)
            guard case .scheduled = outcome else { return outcome }
            settings = try store.load()
        }
        if let terminal = Self.terminalFailure(settings.scheduler) { return terminal }
        guard let baseDue = settings.scheduler.dueAt else { return try observe(current, at: now) }
        let dueAt = settings.scheduler.retryDueAt ?? baseDue
        guard now >= dueAt else {
            return settings.scheduler.retryDueAt == nil ? .scheduled(dueAt) : .retryScheduled(dueAt)
        }
        do {
            let result = try await runner.runAutomaticBackup(expected: current, at: now)
            guard result.revision == current else { return try recordRecoverable(.sourceChanged, at: now) }
            return .completed
        } catch is CancellationError {
            throw CancellationError()
        } catch BackupOperationCoordinatorError.operationInProgress {
            return .failed(.operationInProgress)
        } catch BackupOperationCoordinatorError.destructiveOperationInProgress {
            return .failed(.operationInProgress)
        } catch let failure as BackupFailure where failure.isRecoverable {
            return try recordRecoverable(failure, at: now)
        } catch {
            let failure = error as? BackupFailure ?? .verificationFailed
            try store.update { settings in
                settings.scheduler.lastFailure = failure
                settings.scheduler.retryAttempt = 0
                settings.scheduler.retryDueAt = nil
            }
            return .failed(failure)
        }
    }

    /// The folder could not be reached before a backup could even start. Existing timing is
    /// kept; this only schedules a bounded retry.
    func recordFolderUnavailable(at now: Date) throws -> BackupSchedulerOutcome {
        let settings = try store.load()
        guard settings.folder != nil, settings.isAutomaticBackupEnabled else { return .disabled }
        if let terminal = Self.terminalFailure(settings.scheduler) { return terminal }
        if let retryDueAt = settings.scheduler.retryDueAt, now < retryDueAt { return .retryScheduled(retryDueAt) }
        return try recordRecoverable(.folderUnavailable, at: now)
    }

    private func recordRecoverable(_ failure: BackupFailure, at now: Date) throws -> BackupSchedulerOutcome {
        try store.update { settings in
            let attempts = settings.scheduler.retryAttempt
            settings.scheduler.lastFailure = failure
            guard attempts < Self.retryDelays.count else {
                settings.scheduler.retryDueAt = nil
                return .failed(failure)
            }
            let delayed = now.addingTimeInterval(Self.retryDelays[attempts])
            let retryDueAt = max(delayed, settings.scheduler.dueAt ?? delayed)
            settings.scheduler.retryAttempt = attempts + 1
            settings.scheduler.retryDueAt = retryDueAt
            return .retryScheduled(retryDueAt)
        }
    }

    private static func terminalFailure(_ scheduler: BackupSchedulerState) -> BackupSchedulerOutcome? {
        guard let failure = scheduler.lastFailure, scheduler.retryDueAt == nil else { return nil }
        if !failure.isRecoverable || scheduler.retryAttempt >= retryDelays.count { return .failed(failure) }
        return nil
    }
}
