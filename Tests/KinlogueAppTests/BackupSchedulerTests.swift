import Foundation
import KinlogueCore
import KinloguePlatform
import Testing
@testable import KinlogueApp

@Suite("Backup scheduler", .serialized)
struct BackupSchedulerTests {
    @Test(arguments: [false, true])
    func aBackupFinishedAfterTheEventIsNotMistakenForAClockSetBack(offline: Bool) async throws {
        try await withSchedulerFixture { fixture in
            _ = try await fixture.scheduler.enableAutomaticBackup(current: fixture.revision1, at: fixture.start)
            try fixture.recordSuccess(fixture.revision1, at: fixture.start.addingTimeInterval(60))

            if offline {
                #expect(try await fixture.scheduler.recordFolderUnavailable(at: fixture.start)
                    == .retryScheduled(fixture.start.addingTimeInterval(60)))
            } else {
                #expect(try await fixture.scheduler.handle(.activation, current: fixture.revision2, at: fixture.start)
                    == .scheduled(fixture.start.addingTimeInterval(24 * 60 * 60)))
            }
            #expect(try fixture.store.load().scheduler.lastFailure != .verificationFailed)
            #expect(await fixture.runner.callCount == 0)
        }
    }

    @Test
    func automaticSuccessKeepsTheRunnersCompletionTime() async throws {
        try await withSchedulerFixture { fixture in
            _ = try await fixture.scheduler.enableAutomaticBackup(current: fixture.revision1, at: fixture.start)
            let dueAt = fixture.start.addingTimeInterval(300)
            let completedAt = dueAt.addingTimeInterval(60)
            await fixture.runner.setCompletionTime(completedAt)

            #expect(try await fixture.scheduler.handle(.wake, current: fixture.revision1, at: dueAt) == .completed)
            #expect(try fixture.store.load().scheduler.lastBackupAt == completedAt)
        }
    }

    @Test
    func automaticBackupDefaultsOffAndDisablingClearsTheDueState() async throws {
        try await withSchedulerFixture { fixture in
            #expect(try await fixture.scheduler.handle(.startup, current: fixture.revision1, at: fixture.start) == .disabled)
            #expect(await fixture.runner.callCount == 0)

            _ = try await fixture.scheduler.enableAutomaticBackup(current: fixture.revision1, at: fixture.start)
            #expect(try fixture.store.load().scheduler.dueAt == fixture.start.addingTimeInterval(300))

            #expect(try await fixture.scheduler.disableAutomaticBackup() == .disabled)
            let stored = try fixture.store.load()
            #expect(!stored.isAutomaticBackupEnabled)
            #expect(stored.scheduler.firstObservedRevision == nil && stored.scheduler.dueAt == nil)
        }
    }

    @Test
    func enablingWithoutAFolderIsRefused() async throws {
        try await withSchedulerFixture(configured: false) { fixture in
            await #expect(throws: BackupFailure.notConfigured) {
                _ = try await fixture.scheduler.enableAutomaticBackup(current: fixture.revision1, at: fixture.start)
            }
        }
    }

    @Test
    func aBurstRestartsTheQuietPeriodButARelaunchKeepsTheFirstObservation() async throws {
        try await withSchedulerFixture { fixture in
            _ = try await fixture.scheduler.enableAutomaticBackup(current: fixture.revision1, at: fixture.start)
            _ = try await fixture.scheduler.observe(fixture.revision2, at: fixture.start.addingTimeInterval(4 * 60))
            let stored = try fixture.store.load()
            #expect(stored.scheduler.firstObservedRevision == fixture.revision2)
            #expect(stored.scheduler.dueAt == fixture.start.addingTimeInterval(9 * 60))

            let relaunched = BackupScheduler(store: fixture.store, runner: fixture.runner)
            #expect(try await relaunched.handle(.startup, current: fixture.revision2, at: fixture.start.addingTimeInterval(9 * 60 - 1))
                == .scheduled(fixture.start.addingTimeInterval(9 * 60)))
            #expect(try await relaunched.handle(.activation, current: fixture.revision2, at: fixture.start.addingTimeInterval(9 * 60))
                == .completed)
            #expect(await fixture.runner.callCount == 1)
            #expect(try fixture.store.load().scheduler.lastCoveredRevision == fixture.revision2)
            #expect(try await relaunched.handle(.wake, current: fixture.revision2, at: fixture.start.addingTimeInterval(24 * 60 * 60))
                == .alreadyCovered)
            #expect(await fixture.runner.callCount == 1)
        }
    }

    @Test
    func aManualBackupHoldsTheNextAutomaticOneOffForADay() async throws {
        try await withSchedulerFixture { fixture in
            try fixture.recordSuccess(fixture.revision1, at: fixture.start)
            _ = try await fixture.scheduler.enableAutomaticBackup(current: fixture.revision2, at: fixture.start.addingTimeInterval(60))
            let dueAt = fixture.start.addingTimeInterval(24 * 60 * 60)
            #expect(try fixture.store.load().scheduler.dueAt == dueAt)
            #expect(try await fixture.scheduler.handle(.wake, current: fixture.revision2, at: dueAt.addingTimeInterval(-1)) == .scheduled(dueAt))
            #expect(try await fixture.scheduler.handle(.wake, current: fixture.revision2, at: dueAt) == .completed)
        }
    }

    @Test
    func aClockSetBackKeepsTheScheduleInsteadOfStopping() async throws {
        try await withSchedulerFixture { fixture in
            _ = try await fixture.scheduler.enableAutomaticBackup(current: fixture.revision1, at: fixture.start)
            let earlier = fixture.start.addingTimeInterval(-3_600)
            #expect(try await fixture.scheduler.handle(.startup, current: fixture.revision1, at: earlier)
                == .scheduled(fixture.start.addingTimeInterval(300)))
            #expect(try fixture.store.load().scheduler.lastFailure == nil)
        }
    }

    @Test
    func aChangedLibraryRetriesAfterOneFiveAndFifteenMinutesThenStops() async throws {
        try await withSchedulerFixture(failures: [.sourceChanged, .sourceChanged, .sourceChanged]) { fixture in
            _ = try await fixture.scheduler.enableAutomaticBackup(current: fixture.revision1, at: fixture.start)
            let due = fixture.start.addingTimeInterval(300)
            #expect(try await fixture.scheduler.handle(.startup, current: fixture.revision1, at: due) == .retryScheduled(due + 60))
            #expect(try await fixture.scheduler.handle(.wake, current: fixture.revision1, at: due + 60) == .retryScheduled(due + 360))
            #expect(try await fixture.scheduler.handle(.activation, current: fixture.revision1, at: due + 360) == .retryScheduled(due + 1_260))
            #expect(try await fixture.scheduler.handle(.wake, current: fixture.revision1, at: due + 1_260) == .completed)
            #expect(await fixture.runner.callCount == 4)
        }

        try await withSchedulerFixture(failures: Array(repeating: .sourceChanged, count: 5)) { fixture in
            _ = try await fixture.scheduler.enableAutomaticBackup(current: fixture.revision1, at: fixture.start)
            let due = fixture.start.addingTimeInterval(300)
            for offset in [0, 60, 360] as [TimeInterval] {
                _ = try await fixture.scheduler.handle(.wake, current: fixture.revision1, at: due + offset)
            }
            #expect(try await fixture.scheduler.handle(.wake, current: fixture.revision1, at: due + 1_260) == .failed(.sourceChanged))
            #expect(try await fixture.scheduler.handle(.wake, current: fixture.revision1, at: due + 20_000) == .failed(.sourceChanged))
            #expect(await fixture.runner.callCount == 4)
        }
    }

    @Test
    func anUnavailableFolderRetriesDurablyAndSucceedsAfterARelaunch() async throws {
        try await withSchedulerFixture(failures: [.folderUnavailable, .folderUnavailable]) { fixture in
            _ = try await fixture.scheduler.enableAutomaticBackup(current: fixture.revision1, at: fixture.start)
            let due = fixture.start.addingTimeInterval(300)
            let firstRetry = due.addingTimeInterval(60)
            #expect(try await fixture.scheduler.handle(.startup, current: fixture.revision1, at: due) == .retryScheduled(firstRetry))
            let persisted = try fixture.store.load()
            #expect(persisted.scheduler.lastFailure == .folderUnavailable)
            #expect(persisted.scheduler.retryAttempt == 1 && persisted.scheduler.retryDueAt == firstRetry)

            let relaunched = BackupScheduler(store: fixture.store, runner: fixture.runner)
            #expect(try await relaunched.handle(.activation, current: fixture.revision1, at: firstRetry - 1) == .retryScheduled(firstRetry))
            #expect(await fixture.runner.callCount == 1)
            let secondRetry = firstRetry.addingTimeInterval(5 * 60)
            #expect(try await relaunched.handle(.wake, current: fixture.revision1, at: firstRetry) == .retryScheduled(secondRetry))
            #expect(try await relaunched.handle(.wake, current: fixture.revision1, at: secondRetry) == .completed)

            let completed = try fixture.store.load()
            #expect(completed.scheduler.lastFailure == nil && completed.scheduler.retryAttempt == 0)
            #expect(completed.scheduler.retryDueAt == nil && completed.scheduler.lastCoveredRevision == fixture.revision1)
        }
    }

    @Test
    func aReachableFolderClearsARetryForACommitAlreadyBackedUp() async throws {
        try await withSchedulerFixture { fixture in
            try fixture.recordSuccess(fixture.revision1, at: fixture.start)
            try fixture.store.update { $0.isAutomaticBackupEnabled = true }
            let offlineAt = fixture.start.addingTimeInterval(60)
            #expect(try await fixture.scheduler.recordFolderUnavailable(at: offlineAt) == .retryScheduled(offlineAt + 60))
            #expect(try fixture.store.load().scheduler.lastFailure == .folderUnavailable)

            #expect(try await fixture.scheduler.handle(.activation, current: fixture.revision1, at: offlineAt + 60) == .alreadyCovered)
            let recovered = try fixture.store.load()
            #expect(recovered.scheduler.lastFailure == nil && recovered.scheduler.retryAttempt == 0 && recovered.scheduler.retryDueAt == nil)
            #expect(recovered.scheduler.lastBackupAt == fixture.start)
            #expect(await fixture.runner.callCount == 0)
        }
    }

    @Test
    func aCommitAlreadyBackedUpKeepsAFailureThatNeedsThePerson() async throws {
        try await withSchedulerFixture { fixture in
            try fixture.recordSuccess(fixture.revision1, at: fixture.start)
            try fixture.store.update { settings in
                settings.isAutomaticBackupEnabled = true
                settings.scheduler.lastFailure = .folderNeedsReselection
            }
            #expect(try await fixture.scheduler.handle(.activation, current: fixture.revision1, at: fixture.start + 60) == .alreadyCovered)
            #expect(try fixture.store.load().scheduler.lastFailure == .folderNeedsReselection)
        }
    }

    @Test
    func anUnavailableFolderStopsAfterThreeRetries() async throws {
        try await withSchedulerFixture(failures: Array(repeating: .folderUnavailable, count: 5)) { fixture in
            _ = try await fixture.scheduler.enableAutomaticBackup(current: fixture.revision1, at: fixture.start)
            let due = fixture.start.addingTimeInterval(300)
            for offset in [0, 60, 360] as [TimeInterval] {
                _ = try await fixture.scheduler.handle(.wake, current: fixture.revision1, at: due + offset)
            }
            let stoppedAt = due.addingTimeInterval(1_260)
            #expect(try await fixture.scheduler.handle(.wake, current: fixture.revision1, at: stoppedAt) == .failed(.folderUnavailable))
            #expect(try await fixture.scheduler.handle(.activation, current: fixture.revision1, at: stoppedAt + 10_000) == .failed(.folderUnavailable))
            #expect(await fixture.runner.callCount == 4)
            let stored = try fixture.store.load()
            #expect(stored.scheduler.retryAttempt == 3 && stored.scheduler.retryDueAt == nil)
            #expect(try await fixture.scheduler.recordFolderUnavailable(at: stoppedAt + 20_000) == .failed(.folderUnavailable))
            #expect(try fixture.store.load() == stored)
        }
    }

    @Test(arguments: [
        BackupFailure.folderNeedsReselection, .capacityInsufficient, .publicationIndeterminate,
        .resourceLimitExceeded, .verificationFailed, .libraryUnreadable,
    ])
    func failuresThatNeedThePersonNeverRetryOnTheirOwn(failure: BackupFailure) async throws {
        try await withSchedulerFixture(failures: [failure]) { fixture in
            _ = try await fixture.scheduler.enableAutomaticBackup(current: fixture.revision1, at: fixture.start)
            let due = fixture.start.addingTimeInterval(300)
            #expect(try await fixture.scheduler.handle(.startup, current: fixture.revision1, at: due) == .failed(failure))
            #expect(try await fixture.scheduler.handle(.wake, current: fixture.revision1, at: due + 10_000) == .failed(failure))
            #expect(await fixture.runner.callCount == 1)
            #expect(try fixture.store.load().scheduler.retryDueAt == nil)
            // The next change to the library tries again.
            #expect(try await fixture.scheduler.handle(.wake, current: fixture.revision2, at: due + 20_000)
                == .scheduled(due + 20_300))
        }
    }

    @Test
    func anotherOperationInProgressIsReportedWithoutBeingRecorded() async throws {
        try await withSchedulerFixture(busy: true) { fixture in
            _ = try await fixture.scheduler.enableAutomaticBackup(current: fixture.revision1, at: fixture.start)
            #expect(try await fixture.scheduler.handle(.wake, current: fixture.revision1, at: fixture.start + 300)
                == .failed(.operationInProgress))
            #expect(try fixture.store.load().scheduler.lastFailure == nil)
        }
    }
}

struct SchedulerFixture {
    let store: BackupSettingsStore
    let scheduler: BackupScheduler
    let runner: SchedulerRunner
    let revision1: BackupLibraryRevision
    let revision2: BackupLibraryRevision
    let start: Date

    func recordSuccess(_ revision: BackupLibraryRevision, at date: Date) throws {
        try store.update { settings in
            var scheduler = BackupSchedulerState()
            scheduler.lastCoveredRevision = revision
            scheduler.lastBackupAt = date
            settings.scheduler = scheduler
        }
    }
}

func withSchedulerFixture(
    failures: [BackupFailure] = [],
    configured: Bool = true,
    busy: Bool = false,
    _ body: (SchedulerFixture) async throws -> Void
) async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("KinlogueScheduler-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let store = BackupSettingsStore(rootURL: base.appendingPathComponent("Backup", isDirectory: true))
    if configured {
        let selection = try BackupFolderSelection(bookmarkData: Data([1]), identity: .init(device: 1, inode: 2))
        try store.update { $0.folder = selection }
    }
    let runner = SchedulerRunner(store: store, failures: failures, busy: busy)
    let libraryID = UUID()
    try await body(.init(
        store: store,
        scheduler: BackupScheduler(store: store, runner: runner),
        runner: runner,
        revision1: try BackupLibraryRevision(libraryID: libraryID, generation: 10, commitID: UUID()),
        revision2: try BackupLibraryRevision(libraryID: libraryID, generation: 11, commitID: UUID()),
        start: Date(timeIntervalSince1970: 100_000)
    ))
}

/// Records a success the way the folder runner does, without writing anything.
actor SchedulerRunner: BackupAutomaticRunning {
    private let store: BackupSettingsStore
    private var failures: [BackupFailure]
    private let busy: Bool
    private var completionTime: Date?
    private(set) var callCount = 0

    init(store: BackupSettingsStore, failures: [BackupFailure], busy: Bool) {
        self.store = store
        self.failures = failures
        self.busy = busy
    }

    func setCompletionTime(_ value: Date) { completionTime = value }

    func runAutomaticBackup(expected: BackupLibraryRevision, at: Date) async throws -> BackupRunResult {
        callCount += 1
        if busy { throw BackupOperationCoordinatorError.operationInProgress }
        if !failures.isEmpty { throw failures.removeFirst() }
        let completedAt = completionTime ?? at
        try store.update { settings in
            var scheduler = BackupSchedulerState()
            scheduler.lastCoveredRevision = expected
            scheduler.lastBackupAt = completedAt
            settings.scheduler = scheduler
        }
        return BackupRunResult(fileName: "Backup.zip", completedAt: completedAt, revision: expected, cleanupDeferred: false)
    }
}
