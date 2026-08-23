import Foundation
import KinlogueCore
import KinloguePlatform
import Testing
@testable import KinlogueApp

@Suite("Backup scheduler", .serialized)
struct BackupSchedulerTests {
    @Test
    func automaticBackupDefaultsOffAndDisableClearsDurableDueState() async throws {
        try await withSchedulerFixture { fixture in
            let outcome = try await fixture.scheduler.handle(
                .startup,
                currentPair: fixture.pair1,
                at: fixture.start
            )
            #expect(outcome == .disabled)
            #expect(await fixture.runner.callCount == 0)

            _ = try await fixture.scheduler.setAutomaticBackupEnabled(
                true,
                currentPair: fixture.pair1,
                at: fixture.start
            )
            var stored = try #require(await fixture.store.load())
            #expect(stored.scheduler.dueAt == fixture.start.addingTimeInterval(300))

            _ = try await fixture.scheduler.setAutomaticBackupEnabled(
                false,
                currentPair: fixture.pair1,
                at: fixture.start
            )
            stored = try #require(await fixture.store.load())
            #expect(!stored.automation.isAutomaticBackupEnabled)
            #expect(stored.scheduler.firstObservedRevisionPair == nil)
            #expect(stored.scheduler.dueAt == nil)
        }
    }

    @Test
    func burstResetsQuietForNewPairButRelaunchPreservesItsFirstObservationAndCatchesUpOnce() async throws {
        try await withSchedulerFixture { fixture in
            _ = try await fixture.scheduler.setAutomaticBackupEnabled(
                true,
                currentPair: fixture.pair1,
                at: fixture.start
            )
            _ = try await fixture.scheduler.observe(
                fixture.pair2,
                at: fixture.start.addingTimeInterval(4 * 60)
            )
            let stored = try #require(await fixture.store.load())
            #expect(stored.scheduler.firstObservedRevisionPair == fixture.pair2)
            #expect(stored.scheduler.dueAt == fixture.start.addingTimeInterval(9 * 60))

            let relaunched = BackupScheduler(
                configurationStore: fixture.store,
                automaticRunner: fixture.runner
            )
            let before = try await relaunched.handle(
                .startup,
                currentPair: fixture.pair2,
                at: fixture.start.addingTimeInterval(9 * 60 - 1)
            )
            #expect(before == .scheduled(fixture.start.addingTimeInterval(9 * 60)))
            let due = try await relaunched.handle(
                .activation,
                currentPair: fixture.pair2,
                at: fixture.start.addingTimeInterval(9 * 60)
            )
            #expect(due == .completed)
            #expect(await fixture.runner.callCount == 1)
            #expect(try await fixture.store.load()?.scheduler.lastCoveredRevisionPair == fixture.pair2)

            let wake = try await relaunched.handle(
                .wake,
                currentPair: fixture.pair2,
                at: fixture.start.addingTimeInterval(24 * 60 * 60)
            )
            #expect(wake == .alreadyCovered)
            #expect(await fixture.runner.callCount == 1)
        }
    }

    @Test
    func verifiedManualPointEnforcesTwentyFourHourMinimumAcrossRestart() async throws {
        try await withSchedulerFixture { fixture in
            var current = try #require(await fixture.store.load())
            current = try await fixture.store.markBackupSuccess(
                fixture.pair1,
                verifiedAt: fixture.start,
                expectedRevision: current.revision
            )
            current = try await fixture.store.updateAutomation(
                isAutomaticBackupEnabled: true,
                expectedRevision: current.revision
            )
            _ = try await fixture.scheduler.observe(
                fixture.pair2,
                at: fixture.start.addingTimeInterval(60)
            )
            let dueAt = fixture.start.addingTimeInterval(24 * 60 * 60)
            #expect(try await fixture.store.load()?.scheduler.dueAt == dueAt)
            #expect(try await fixture.scheduler.handle(
                .wake,
                currentPair: fixture.pair2,
                at: dueAt.addingTimeInterval(-1)
            ) == .scheduled(dueAt))
            #expect(try await fixture.scheduler.handle(
                .wake,
                currentPair: fixture.pair2,
                at: dueAt
            ) == .completed)
        }
    }

    @Test
    func mutationConflictUsesOneFiveFifteenMinuteRetriesAndStopsAfterThreeRetries() async throws {
        try await withSchedulerFixture(
            failures: [.sourceChanged, .sourceChanged, .sourceChanged]
        ) { fixture in
            _ = try await fixture.scheduler.setAutomaticBackupEnabled(
                true,
                currentPair: fixture.pair1,
                at: fixture.start
            )
            let initialDue = fixture.start.addingTimeInterval(300)
            #expect(try await fixture.scheduler.handle(
                .startup,
                currentPair: fixture.pair1,
                at: initialDue
            ) == .retryScheduled(initialDue.addingTimeInterval(60)))
            #expect(try await fixture.scheduler.handle(
                .wake,
                currentPair: fixture.pair1,
                at: initialDue.addingTimeInterval(60)
            ) == .retryScheduled(initialDue.addingTimeInterval(6 * 60)))
            #expect(try await fixture.scheduler.handle(
                .activation,
                currentPair: fixture.pair1,
                at: initialDue.addingTimeInterval(6 * 60)
            ) == .retryScheduled(initialDue.addingTimeInterval(21 * 60)))
            #expect(try await fixture.scheduler.handle(
                .wake,
                currentPair: fixture.pair1,
                at: initialDue.addingTimeInterval(21 * 60)
            ) == .completed)
            #expect(await fixture.runner.callCount == 4)
        }

        try await withSchedulerFixture(
            failures: [.sourceChanged, .sourceChanged, .sourceChanged, .sourceChanged, .sourceChanged]
        ) { fixture in
            _ = try await fixture.scheduler.setAutomaticBackupEnabled(
                true,
                currentPair: fixture.pair1,
                at: fixture.start
            )
            let initialDue = fixture.start.addingTimeInterval(300)
            _ = try await fixture.scheduler.handle(.startup, currentPair: fixture.pair1, at: initialDue)
            _ = try await fixture.scheduler.handle(.wake, currentPair: fixture.pair1, at: initialDue + 60)
            _ = try await fixture.scheduler.handle(.wake, currentPair: fixture.pair1, at: initialDue + 360)
            #expect(try await fixture.scheduler.handle(
                .wake,
                currentPair: fixture.pair1,
                at: initialDue + 1_260
            ) == .failed(.sourceChanged))
            #expect(try await fixture.scheduler.handle(
                .wake,
                currentPair: fixture.pair1,
                at: initialDue + 20_000
            ) == .failed(.sourceChanged))
            #expect(await fixture.runner.callCount == 4)
        }
    }

    @Test
    func repositoryOfflineUsesDurableBoundedRetryAndSucceedsAfterRelaunch() async throws {
        try await withSchedulerFixture(
            failures: [.repositoryOffline, .repositoryOffline]
        ) { fixture in
            _ = try await fixture.scheduler.setAutomaticBackupEnabled(
                true,
                currentPair: fixture.pair1,
                at: fixture.start
            )
            let initialDue = fixture.start.addingTimeInterval(300)
            let firstRetry = initialDue.addingTimeInterval(60)
            #expect(try await fixture.scheduler.handle(
                .startup,
                currentPair: fixture.pair1,
                at: initialDue
            ) == .retryScheduled(firstRetry))

            let persisted = try #require(await fixture.store.load())
            #expect(persisted.scheduler.lastFailure == .repositoryOffline)
            #expect(persisted.scheduler.mutationRetryAttempt == 1)
            #expect(persisted.scheduler.retryDueAt == firstRetry)

            let relaunched = BackupScheduler(
                configurationStore: fixture.store,
                automaticRunner: fixture.runner
            )
            #expect(try await relaunched.handle(
                .activation,
                currentPair: fixture.pair1,
                at: firstRetry.addingTimeInterval(-1)
            ) == .retryScheduled(firstRetry))
            #expect(await fixture.runner.callCount == 1)

            let secondRetry = firstRetry.addingTimeInterval(5 * 60)
            #expect(try await relaunched.handle(
                .wake,
                currentPair: fixture.pair1,
                at: firstRetry
            ) == .retryScheduled(secondRetry))
            #expect(try await relaunched.handle(
                .wake,
                currentPair: fixture.pair1,
                at: secondRetry
            ) == .completed)

            let completed = try #require(await fixture.store.load())
            #expect(completed.scheduler.lastFailure == nil)
            #expect(completed.scheduler.mutationRetryAttempt == 0)
            #expect(completed.scheduler.retryDueAt == nil)
            #expect(completed.scheduler.lastCoveredRevisionPair == fixture.pair1)
        }
    }

    @Test
    func resolvedDestinationClearsOfflineRetryForAlreadyCoveredPairWithoutNewVerification() async throws {
        try await withSchedulerFixture { fixture in
            var current = try #require(await fixture.store.load())
            current = try await fixture.store.markBackupSuccess(
                fixture.pair1,
                verifiedAt: fixture.start,
                expectedRevision: current.revision
            )
            _ = try await fixture.store.updateAutomation(
                isAutomaticBackupEnabled: true,
                expectedRevision: current.revision
            )

            let offlineAt = fixture.start.addingTimeInterval(60)
            let retryDueAt = offlineAt.addingTimeInterval(60)
            #expect(try await fixture.scheduler.recordDestinationOffline(
                at: offlineAt
            ) == .retryScheduled(retryDueAt))

            let offline = try #require(await fixture.store.load())
            #expect(offline.scheduler.lastCoveredRevisionPair == fixture.pair1)
            #expect(offline.scheduler.lastLocalVerificationAt == fixture.start)
            #expect(offline.scheduler.lastFailure == .repositoryOffline)
            #expect(offline.scheduler.mutationRetryAttempt == 1)
            #expect(offline.scheduler.retryDueAt == retryDueAt)

            #expect(try await fixture.scheduler.handle(
                .activation,
                currentPair: fixture.pair1,
                at: retryDueAt
            ) == .alreadyCovered)

            let recovered = try #require(await fixture.store.load())
            #expect(recovered.scheduler.lastCoveredRevisionPair == fixture.pair1)
            #expect(recovered.scheduler.lastLocalVerificationAt == fixture.start)
            #expect(recovered.scheduler.lastFailure == nil)
            #expect(recovered.scheduler.mutationRetryAttempt == 0)
            #expect(recovered.scheduler.retryDueAt == nil)
            #expect(await fixture.runner.callCount == 0)
        }
    }

    @Test
    func alreadyCoveredPairDoesNotClearActionableFailure() async throws {
        try await withSchedulerFixture { fixture in
            var current = try #require(await fixture.store.load())
            current = try await fixture.store.markBackupSuccess(
                fixture.pair1,
                verifiedAt: fixture.start,
                expectedRevision: current.revision
            )
            current = try await fixture.store.updateAutomation(
                isAutomaticBackupEnabled: true,
                expectedRevision: current.revision
            )
            current = try await fixture.store.markBackupFailure(
                .authenticationFailed,
                retryAttempt: 0,
                retryDueAt: nil,
                expectedRevision: current.revision
            )

            #expect(try await fixture.scheduler.handle(
                .activation,
                currentPair: fixture.pair1,
                at: fixture.start.addingTimeInterval(60)
            ) == .alreadyCovered)

            let preserved = try #require(await fixture.store.load())
            #expect(preserved.revision == current.revision)
            #expect(preserved.scheduler.lastCoveredRevisionPair == fixture.pair1)
            #expect(preserved.scheduler.lastLocalVerificationAt == fixture.start)
            #expect(preserved.scheduler.lastFailure == .authenticationFailed)
            #expect(preserved.scheduler.mutationRetryAttempt == 0)
            #expect(preserved.scheduler.retryDueAt == nil)
            #expect(await fixture.runner.callCount == 0)
        }
    }

    @Test
    func repositoryOfflineStopsAfterThreeScheduledRetries() async throws {
        try await withSchedulerFixture(
            failures: Array(repeating: .repositoryOffline, count: 5)
        ) { fixture in
            _ = try await fixture.scheduler.setAutomaticBackupEnabled(
                true,
                currentPair: fixture.pair1,
                at: fixture.start
            )
            let initialDue = fixture.start.addingTimeInterval(300)
            _ = try await fixture.scheduler.handle(
                .startup,
                currentPair: fixture.pair1,
                at: initialDue
            )
            _ = try await fixture.scheduler.handle(
                .wake,
                currentPair: fixture.pair1,
                at: initialDue.addingTimeInterval(60)
            )
            _ = try await fixture.scheduler.handle(
                .wake,
                currentPair: fixture.pair1,
                at: initialDue.addingTimeInterval(6 * 60)
            )
            let stoppedAt = initialDue.addingTimeInterval(21 * 60)
            #expect(try await fixture.scheduler.handle(
                .wake,
                currentPair: fixture.pair1,
                at: stoppedAt
            ) == .failed(.repositoryOffline))
            #expect(try await fixture.scheduler.handle(
                .activation,
                currentPair: fixture.pair1,
                at: stoppedAt.addingTimeInterval(10_000)
            ) == .failed(.repositoryOffline))
            #expect(await fixture.runner.callCount == 4)

            let stored = try #require(await fixture.store.load())
            #expect(stored.scheduler.lastFailure == .repositoryOffline)
            #expect(stored.scheduler.mutationRetryAttempt == 3)
            #expect(stored.scheduler.retryDueAt == nil)
            #expect(try await fixture.scheduler.recordDestinationOffline(
                at: stoppedAt.addingTimeInterval(20_000)
            ) == .failed(.repositoryOffline))
            #expect(try await fixture.store.load()?.revision == stored.revision)
        }
    }

    @Test
    func actionableFailuresNeverEnterAutomaticRetry() async throws {
        let actionable: [BackupSemanticError] = [
            .identityNeedsEnrollment,
            .repositoryIdentityConflict,
            .repositoryHistoryFork,
            .authenticationFailed,
            .capacityInsufficient,
            .publicationIndeterminate,
            .resourceLimitExceeded,
            .verificationFailed,
        ]
        for failure in actionable {
            try await withSchedulerFixture(failures: [failure]) { fixture in
                _ = try await fixture.scheduler.setAutomaticBackupEnabled(
                    true,
                    currentPair: fixture.pair1,
                    at: fixture.start
                )
                let due = fixture.start.addingTimeInterval(300)
                #expect(try await fixture.scheduler.handle(
                    .startup,
                    currentPair: fixture.pair1,
                    at: due
                ) == .failed(failure))
                #expect(try await fixture.scheduler.handle(
                    .wake,
                    currentPair: fixture.pair1,
                    at: due.addingTimeInterval(10_000)
                ) == .failed(failure))
                #expect(await fixture.runner.callCount == 1)
                #expect(try await fixture.store.load()?.scheduler.retryDueAt == nil)
            }
        }
    }

    @Test
    func identityFailureAndClockRollbackPersistActionableFailureWithoutBusyRetry() async throws {
        try await withSchedulerFixture(failures: [.identityNeedsEnrollment]) { fixture in
            _ = try await fixture.scheduler.setAutomaticBackupEnabled(
                true,
                currentPair: fixture.pair1,
                at: fixture.start
            )
            let due = fixture.start.addingTimeInterval(300)
            #expect(try await fixture.scheduler.handle(
                .startup,
                currentPair: fixture.pair1,
                at: due
            ) == .failed(.identityNeedsEnrollment))
            #expect(try await fixture.scheduler.handle(
                .wake,
                currentPair: fixture.pair1,
                at: due.addingTimeInterval(10_000)
            ) == .failed(.identityNeedsEnrollment))
            #expect(await fixture.runner.callCount == 1)
        }

        try await withSchedulerFixture { fixture in
            _ = try await fixture.scheduler.setAutomaticBackupEnabled(
                true,
                currentPair: fixture.pair1,
                at: fixture.start
            )
            #expect(try await fixture.scheduler.handle(
                .startup,
                currentPair: fixture.pair1,
                at: fixture.start.addingTimeInterval(-1)
            ) == .failed(.verificationFailed))
            #expect(await fixture.runner.callCount == 0)
        }
    }
}

private struct SchedulerFixture {
    let store: BackupLocalConfigurationStore
    let scheduler: BackupScheduler
    let runner: SchedulerRunner
    let pair1: BackupRevisionPair
    let pair2: BackupRevisionPair
    let start: Date
}

private func withSchedulerFixture(
    failures: [BackupSemanticError] = [],
    _ body: (SchedulerFixture) async throws -> Void
) async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(
        "KinlogueScheduler-\(UUID().uuidString)", isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let store = BackupLocalConfigurationStore(
        rootURL: base.appendingPathComponent("BackupIdentity", isDirectory: true)
    )
    _ = try await makeEnabledCoordinatorConfiguration(store: store)
    let runner = SchedulerRunner(failures: failures)
    let scheduler = BackupScheduler(configurationStore: store, automaticRunner: runner)
    try await body(.init(
        store: store,
        scheduler: scheduler,
        runner: runner,
        pair1: try coordinatorPair(10),
        pair2: try coordinatorPair(11),
        start: Date(timeIntervalSince1970: 100_000)
    ))
}

private actor SchedulerRunner: BackupAutomaticRunning {
    private var failures: [BackupSemanticError]
    private(set) var callCount = 0
    init(failures: [BackupSemanticError]) { self.failures = failures }

    func runAutomaticBackup(
        expectedPair: BackupRevisionPair,
        at: Date
    ) async throws -> BackupOperationResult {
        callCount += 1
        if !failures.isEmpty {
            throw BackupOperationCoordinatorError.semantic(failures.removeFirst())
        }
        return .init(revisionPair: expectedPair, cleanup: .complete)
    }
}
