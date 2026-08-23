import Foundation
import KinlogueCore
import Testing
@testable import KinlogueApp

@Suite("Backup settings model")
@MainActor
struct BackupModelTests {
    @Test
    func setupRequiresIndependentSaveAndFullRecoveryCodeReentry() async {
        let service = BackupModelService()
        let model = BackupModel(service: service)

        await model.refresh()
        #expect(model.phase == .notConfigured)

        await model.beginSetup(selectedParent: URL(fileURLWithPath: "/chosen"))
        #expect(model.phase == .enrollmentPending)
        #expect(model.recoveryCode == "KLG-RECOVERY-CODE")

        model.recoveryCodeReentry = "KLG-RECOVERY-CODE"
        model.hasConfirmedIndependentSave = true
        await model.completeSetup()

        #expect(model.phase == .ready)
        #expect(model.recoveryCode == nil)
        #expect(model.recoveryCodeReentry.isEmpty)
        #expect(!model.hasConfirmedIndependentSave)
        #expect(await service.completedReentry == "KLG-RECOVERY-CODE")
        #expect(await service.completedIndependentSave == true)
    }

    @Test
    func automaticToggleRetentionAndManualBackupRouteThroughService() async {
        let service = BackupModelService(status: .readyFixture())
        let model = BackupModel(service: service)
        await model.refresh()

        await model.setAutomaticBackupEnabled(true)
        await model.setRetentionCount(30)
        await model.backUpNow()

        #expect(model.phase == .localCheckpointComplete)
        #expect(model.isAutomaticBackupEnabled)
        #expect(model.retentionCount == 30)
        #expect(await service.automaticValues == [true])
        #expect(await service.retentionValues == [30])
        #expect(await service.manualBackupCount == 1)
        #expect(model.cloudStatusText == AppLocalization.string("网盘同步状态未知"))
        #expect(model.localCheckpointText == AppLocalization.string("所选目录中的恢复点已完整验证"))
    }

    @Test
    func showingBackupRepositoryRoutesThroughService() async {
        let service = BackupModelService(status: .readyFixture())
        let model = BackupModel(service: service)
        await model.refresh()

        await model.showBackupRepository()

        #expect(await service.showRepositoryCount == 1)
        #expect(model.failure == nil)
        #expect(model.phase == .ready)
    }

    @Test
    func successfulRepositoryRevealClearsOnlyThePreviousRevealFailure() async {
        let service = BackupModelService(status: .readyFixture())
        let model = BackupModel(service: service)
        await model.refresh()
        await service.failNextRepositoryReveal()

        await model.showBackupRepository()
        #expect(model.failure == .semantic(.repositoryOffline))

        await model.showBackupRepository()

        #expect(await service.showRepositoryCount == 2)
        #expect(model.failure == nil)
        #expect(model.phase == .ready)
    }

    @Test
    func enablingAutomaticBackupArmsReturnedOfflineRetryWithoutAnotherAppEvent() async {
        let service = BackupModelService(status: .readyFixture())
        await service.returnImmediateOfflineRetryWhenEnabling()
        let model = BackupModel(service: service)
        await model.refresh()

        await model.setAutomaticBackupEnabled(true)
        await service.waitForSchedulerEvent()

        #expect(await service.schedulerEvents == [.mutation])
    }

    @Test
    func offlineRetryReturnedByAppEventAutomaticallyRunsItsDueMutation() async {
        let service = BackupModelService(status: .readyFixture())
        await service.returnImmediateOfflineRetryThenCompletion()
        let model = BackupModel(service: service)
        await model.refresh()

        await model.handleAppEvent(.activation)
        await service.waitForSchedulerEventCount(2)

        #expect(await service.schedulerEvents == [.activation, .mutation])
        #expect(model.phase == .ready)
    }

    @Test
    func applicationTerminationCancelsOnlyTheInMemoryTimer() async throws {
        let service = BackupModelService(status: .readyFixture())
        await service.returnFutureOfflineRetryWhenEnabling()
        let model = BackupModel(service: service)
        await model.refresh()
        await model.setAutomaticBackupEnabled(true)

        model.cancelForApplicationTermination()
        await service.waitForTerminationCancellation()

        #expect(await service.schedulerEvents.isEmpty)
        #expect(try await service.loadStatus().isAutomaticBackupEnabled)
        #expect(await service.terminationCancellationCount == 1)
    }

    @Test
    func failedLateSetupCannotReplaceAStartedNewOperation() async {
        let service = BackupModelService()
        await service.pauseNextSetup()
        let model = BackupModel(service: service)
        let first = Task { await model.beginSetup(selectedParent: URL(fileURLWithPath: "/first")) }
        await service.waitUntilPaused()

        model.cancelSetup()
        await service.resumeSetupWithFailure()
        await first.value

        #expect(model.phase == .notConfigured)
        #expect(model.failure == nil)
    }

    @Test
    func successfulLateSetupIsExplicitlyCancelledAndDoesNotRetainRecoveryMaterial() async {
        let service = BackupModelService()
        await service.pauseNextSetup()
        let model = BackupModel(service: service)
        let first = Task { await model.beginSetup(selectedParent: URL(fileURLWithPath: "/first")) }
        await service.waitUntilPaused()

        model.cancelSetup()
        await service.resumeSetupSuccessfully()
        await first.value

        #expect(model.phase == .notConfigured)
        #expect(model.recoveryCode == nil)
        #expect(await service.hasActiveSetup == false)
        #expect(await service.cancelCount >= 1)
    }

    @Test
    func persistedPendingEnrollmentCanBeResumedWithoutAnInMemorySetupCode() async {
        let service = BackupModelService(status: .pendingFixture())
        let model = BackupModel(service: service)

        await model.refresh()
        #expect(model.phase == .enrollmentPending)
        #expect(model.recoveryCode == nil)

        model.presentPendingEnrollmentRecovery()
        model.pendingEnrollmentRecoveryCode = "KLG-SAVED-RECOVERY-CODE"
        await model.resumePendingEnrollment()

        #expect(model.phase == .ready)
        #expect(!model.isPendingEnrollmentRecoveryPresented)
        #expect(model.pendingEnrollmentRecoveryCode.isEmpty)
        #expect(await service.resumedRecoveryCodes == ["KLG-SAVED-RECOVERY-CODE"])
    }

    @Test
    func wrongPendingRecoveryCodeReportsFailureAndDoesNotRetainInput() async {
        let service = BackupModelService(status: .pendingFixture())
        await service.failPendingResumeWithRecoveryCodeMismatch()
        let model = BackupModel(service: service)
        await model.refresh()

        model.presentPendingEnrollmentRecovery()
        model.pendingEnrollmentRecoveryCode = "KLG-WRONG-RECOVERY-CODE"
        await model.resumePendingEnrollment()

        #expect(model.phase == .enrollmentPending)
        #expect(model.failure == .recoveryCodeMismatch)
        #expect(model.isPendingEnrollmentRecoveryPresented)
        #expect(model.pendingEnrollmentRecoveryCode.isEmpty)

        model.pendingEnrollmentRecoveryCode = "KLG-SECOND-ATTEMPT"
        model.cancelPendingEnrollmentRecovery()
        #expect(!model.isPendingEnrollmentRecoveryPresented)
        #expect(model.pendingEnrollmentRecoveryCode.isEmpty)
    }

    @Test
    func statusRefreshDuringPendingResumeCannotLeaveRecoveryInputOrSheetLocked() async {
        let service = BackupModelService(status: .pendingFixture())
        await service.pauseNextPendingResume()
        let model = BackupModel(service: service)
        await model.refresh()
        model.presentPendingEnrollmentRecovery()
        model.pendingEnrollmentRecoveryCode = "KLG-SAVED-RECOVERY-CODE"

        let resuming = Task { await model.resumePendingEnrollment() }
        await service.waitUntilPendingResumePaused()
        #expect(model.pendingEnrollmentRecoveryCode.isEmpty)
        #expect(await service.resumedRecoveryCodes == ["KLG-SAVED-RECOVERY-CODE"])
        await model.refresh()
        await service.resumePendingResume()
        await resuming.value

        #expect(model.phase == .ready)
        #expect(!model.isPendingEnrollmentRecoveryPresented)
        #expect(!model.isPendingEnrollmentOperation)
        #expect(model.pendingEnrollmentRecoveryCode.isEmpty)
    }

    @Test
    func statusRefreshDuringFailedPendingResumeCannotLeaveRecoveryInputOrSheetLocked() async {
        let service = BackupModelService(status: .pendingFixture())
        await service.pauseNextPendingResume()
        await service.failPendingResumeWithRecoveryCodeMismatch()
        let model = BackupModel(service: service)
        await model.refresh()
        model.presentPendingEnrollmentRecovery()
        model.pendingEnrollmentRecoveryCode = "KLG-SAVED-RECOVERY-CODE"

        let resuming = Task { await model.resumePendingEnrollment() }
        await service.waitUntilPendingResumePaused()
        #expect(model.pendingEnrollmentRecoveryCode.isEmpty)
        #expect(await service.resumedRecoveryCodes == ["KLG-SAVED-RECOVERY-CODE"])
        await model.refresh()
        await service.resumePendingResume()
        await resuming.value

        #expect(model.phase == .enrollmentPending)
        #expect(model.isPendingEnrollmentRecoveryPresented)
        #expect(!model.isPendingEnrollmentOperation)
        #expect(model.pendingEnrollmentRecoveryCode.isEmpty)
    }

    @Test
    func failedPendingAbandonmentRemainsVisibleAndReportsTheFailure() async {
        let service = BackupModelService(status: .pendingFixture())
        await service.failPendingAbandonment()
        let model = BackupModel(service: service)
        await model.refresh()
        model.presentPendingEnrollmentRecovery()
        model.pendingEnrollmentRecoveryCode = "KLG-SENSITIVE-INPUT"

        await model.abandonPendingEnrollment()

        #expect(model.phase == .enrollmentPending)
        #expect(model.status.enrollment == .pending)
        #expect(model.failure == .semantic(.verificationFailed))
        #expect(!model.isPendingEnrollmentRecoveryPresented)
        #expect(model.pendingEnrollmentRecoveryCode.isEmpty)
        #expect(await service.abandonCount == 1)
    }
}

private actor BackupModelService: BackupServicing {
    private var status: AppBackupStatus
    private(set) var completedReentry: String?
    private(set) var completedIndependentSave: Bool?
    private(set) var automaticValues: [Bool] = []
    private(set) var retentionValues: [Int] = []
    private(set) var manualBackupCount = 0
    private(set) var showRepositoryCount = 0
    private var setupContinuation: CheckedContinuation<Void, Never>?
    private var setupPaused = false
    private var setupEntered = false
    private var setupWaiters: [CheckedContinuation<Void, Never>] = []
    private var setupShouldFail = false
    private(set) var hasActiveSetup = false
    private(set) var cancelCount = 0
    private var automaticOutcome: BackupSchedulerOutcome = .disabled
    private(set) var schedulerEvents: [BackupSchedulerEvent] = []
    private var schedulerEventWaiters: [CheckedContinuation<Void, Never>] = []
    private var schedulerOutcomes: [BackupSchedulerOutcome] = []
    private var schedulerEventCountWaiters: [(
        count: Int,
        continuation: CheckedContinuation<Void, Never>
    )] = []
    private(set) var terminationCancellationCount = 0
    private var terminationCancellationWaiters: [CheckedContinuation<Void, Never>] = []
    private var repositoryRevealShouldFail = false
    private(set) var resumedRecoveryCodes: [String] = []
    private(set) var abandonCount = 0
    private var pendingResumeShouldFail = false
    private var pendingAbandonShouldFail = false
    private var pendingResumePaused = false
    private var pendingResumeEntered = false
    private var pendingResumeContinuation: CheckedContinuation<Void, Never>?
    private var pendingResumeWaiters: [CheckedContinuation<Void, Never>] = []

    init(status: AppBackupStatus = .notConfigured) {
        self.status = status
    }

    func loadStatus() async throws -> AppBackupStatus { status }

    func beginSetup(selectedParent: URL) async throws -> String {
        _ = selectedParent
        setupEntered = true
        setupWaiters.forEach { $0.resume() }
        setupWaiters.removeAll()
        if setupPaused {
            await withCheckedContinuation { setupContinuation = $0 }
        }
        if setupShouldFail { throw BackupSemanticError.verificationFailed }
        hasActiveSetup = true
        return "KLG-RECOVERY-CODE"
    }

    func completeSetup(recoveryCodeReentry: String, independentlySaved: Bool) async throws {
        completedReentry = recoveryCodeReentry
        completedIndependentSave = independentlySaved
        status = .readyFixture()
    }

    func cancelSetup() async {
        cancelCount += 1
        hasActiveSetup = false
    }

    func resumePending(recoveryCode: String) async throws {
        resumedRecoveryCodes.append(recoveryCode)
        pendingResumeEntered = true
        pendingResumeWaiters.forEach { $0.resume() }
        pendingResumeWaiters.removeAll()
        if pendingResumePaused {
            await withCheckedContinuation { pendingResumeContinuation = $0 }
        }
        if pendingResumeShouldFail {
            throw BackupSetupError.recoveryCodeMismatch
        }
        status = .readyFixture()
    }

    func abandonPending() async throws {
        abandonCount += 1
        if pendingAbandonShouldFail {
            throw BackupSemanticError.verificationFailed
        }
        status = .notConfigured
    }

    func setAutomaticBackupEnabled(_ enabled: Bool) async throws -> BackupSchedulerOutcome {
        automaticValues.append(enabled)
        status = status.replacing(automatic: enabled)
        return enabled ? automaticOutcome : .disabled
    }

    func setRetentionCount(_ count: Int) async throws {
        retentionValues.append(count)
        status = status.replacing(retention: count)
    }

    func backUpNow() async throws -> BackupCleanupOutcome {
        manualBackupCount += 1
        status = status.replacing(localState: .verified, verifiedAt: Date(timeIntervalSince1970: 1))
        return .complete
    }

    func showBackupRepository() async throws {
        showRepositoryCount += 1
        if repositoryRevealShouldFail {
            repositoryRevealShouldFail = false
            throw BackupSemanticError.repositoryOffline
        }
    }

    func failNextRepositoryReveal() {
        repositoryRevealShouldFail = true
    }

    func failPendingResumeWithRecoveryCodeMismatch() {
        pendingResumeShouldFail = true
    }

    func failPendingAbandonment() {
        pendingAbandonShouldFail = true
    }

    func pauseNextPendingResume() {
        pendingResumePaused = true
    }

    func waitUntilPendingResumePaused() async {
        if pendingResumeEntered { return }
        await withCheckedContinuation { pendingResumeWaiters.append($0) }
    }

    func resumePendingResume() {
        pendingResumeContinuation?.resume()
        pendingResumeContinuation = nil
    }

    func handleSchedulerEvent(_ event: BackupSchedulerEvent) async throws -> BackupSchedulerOutcome {
        schedulerEvents.append(event)
        schedulerEventWaiters.forEach { $0.resume() }
        schedulerEventWaiters.removeAll()
        var waiting: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in schedulerEventCountWaiters {
            if schedulerEvents.count >= waiter.count {
                waiter.continuation.resume()
            } else {
                waiting.append(waiter)
            }
        }
        schedulerEventCountWaiters = waiting
        return schedulerOutcomes.isEmpty ? .disabled : schedulerOutcomes.removeFirst()
    }

    func cancelForApplicationTermination() {
        terminationCancellationCount += 1
        terminationCancellationWaiters.forEach { $0.resume() }
        terminationCancellationWaiters.removeAll()
    }

    func returnImmediateOfflineRetryWhenEnabling() {
        automaticOutcome = .retryScheduled(Date(timeIntervalSinceNow: -1))
    }

    func returnFutureOfflineRetryWhenEnabling() {
        automaticOutcome = .retryScheduled(Date(timeIntervalSinceNow: 60 * 60))
    }

    func returnImmediateOfflineRetryThenCompletion() {
        schedulerOutcomes = [
            .retryScheduled(Date(timeIntervalSinceNow: -1)),
            .completed,
        ]
    }

    func waitForSchedulerEvent() async {
        if !schedulerEvents.isEmpty { return }
        await withCheckedContinuation { schedulerEventWaiters.append($0) }
    }

    func waitForSchedulerEventCount(_ count: Int) async {
        if schedulerEvents.count >= count { return }
        await withCheckedContinuation {
            schedulerEventCountWaiters.append((count, $0))
        }
    }

    func waitForTerminationCancellation() async {
        if terminationCancellationCount > 0 { return }
        await withCheckedContinuation { terminationCancellationWaiters.append($0) }
    }

    func pauseNextSetup() { setupPaused = true }
    func waitUntilPaused() async {
        if setupEntered { return }
        await withCheckedContinuation { setupWaiters.append($0) }
    }
    func resumeSetupWithFailure() {
        setupShouldFail = true
        setupContinuation?.resume()
        setupContinuation = nil
    }
    func resumeSetupSuccessfully() {
        setupContinuation?.resume()
        setupContinuation = nil
    }
}

private extension AppBackupStatus {
    static func readyFixture() -> Self {
        .init(
            enrollment: .ready,
            destinationDisplayName: "Selected Folder",
            isAutomaticBackupEnabled: false,
            retentionCount: 5,
            localCheckpointState: .unavailable,
            lastLocalVerificationAt: nil,
            nextDueAt: nil,
            lastFailure: nil,
            estimate: .init(singleCheckpointBytes: 100, retainedBytes: 500, temporaryBytes: 100)
        )
    }

    static func pendingFixture() -> Self {
        .init(
            enrollment: .pending,
            destinationDisplayName: "Selected Folder",
            isAutomaticBackupEnabled: false,
            retentionCount: 5,
            localCheckpointState: .unavailable,
            lastLocalVerificationAt: nil,
            nextDueAt: nil,
            lastFailure: nil,
            estimate: nil
        )
    }

    func replacing(
        automatic: Bool? = nil,
        retention: Int? = nil,
        localState: BackupLocalCheckpointState? = nil,
        verifiedAt: Date?? = nil
    ) -> Self {
        .init(
            enrollment: enrollment,
            destinationDisplayName: destinationDisplayName,
            isAutomaticBackupEnabled: automatic ?? isAutomaticBackupEnabled,
            retentionCount: retention ?? retentionCount,
            localCheckpointState: localState ?? localCheckpointState,
            lastLocalVerificationAt: verifiedAt ?? lastLocalVerificationAt,
            nextDueAt: nextDueAt,
            lastFailure: lastFailure,
            estimate: estimate
        )
    }
}
