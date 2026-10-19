import Foundation
import KinlogueCore
import Testing
@testable import KinlogueApp

@Suite("Backup settings model")
@MainActor
struct BackupModelTests {
    @Test
    func choosingAFolderConfiguresBackupWithoutAnyRecoveryCode() async {
        let service = BackupModelService()
        let model = BackupModel(service: service)

        await model.refresh()
        #expect(model.phase == .notConfigured)

        await model.chooseFolder(URL(fileURLWithPath: "/chosen"))
        #expect(model.phase == .ready)
        #expect(model.status.folderName == "Selected Folder")
        #expect(await service.chosenFolders == [URL(fileURLWithPath: "/chosen")])
    }

    @Test
    func automaticToggleRetentionAndManualBackupRouteThroughService() async {
        let service = BackupModelService(status: .readyFixture())
        let model = BackupModel(service: service)
        await model.refresh()

        await model.setAutomaticBackupEnabled(true)
        await model.setRetentionCount(1)
        await model.setRetentionCount(31)
        await model.backUpNow()

        #expect(model.phase == .backupCompleted)
        #expect(model.isAutomaticBackupEnabled)
        #expect(model.retentionCount == 1)
        #expect(await service.automaticValues == [true])
        #expect(await service.retentionValues == [1])
        #expect(await service.manualBackupCount == 1)
    }

    @Test
    func aFinishedManualBackupNamesItsFileUntilTheStatusIsReloaded() async {
        let service = BackupModelService(status: .readyFixture())
        let model = BackupModel(service: service)
        await model.refresh()
        #expect(model.completionText == nil)

        await model.backUpNow()
        #expect(model.completionText == AppLocalization.string("已创建 \("Kinlogue Backup.zip")，并完整验证。"))
        #expect(model.cleanupDeferredText == nil)
        #expect(
            AppLocalization.string("已创建 \("Kinlogue Backup.zip")，并完整验证。", language: .english)
                == "Created Kinlogue Backup.zip and verified it completely."
        )

        await model.refresh()
        #expect(model.completionText == nil)
    }

    @Test
    func aManualBackupThatLeavesCleanupPendingSaysSoBesideTheSuccess() async {
        let service = BackupModelService(status: .readyFixture())
        let model = BackupModel(service: service)
        await model.refresh()
        await service.finishNextManualBackup(with: .success(true))

        await model.backUpNow()

        #expect(model.phase == .backupCompleted)
        #expect(model.completionText != nil)
        #expect(model.cleanupDeferredText != nil)
    }

    @Test
    func aManualBackupThatFailsIsNotConfirmedAndKeepsTheSemanticFailure() async {
        let service = BackupModelService(status: .readyFixture())
        let model = BackupModel(service: service)
        await model.refresh()
        await service.finishNextManualBackup(with: .failure(.folderUnavailable))

        await model.backUpNow()

        #expect(model.phase == .ready)
        #expect(model.failure == .folderUnavailable)
        #expect(model.completionText == nil)
        #expect(model.failureText == AppLocalization.string("备份文件夹当前不可用，请连接磁盘或恢复网络文件夹后重试。"))
    }

    @Test
    func failureMessagesFollowTheCurrentLanguage() {
        for failure in BackupFailure.allCases {
            let english = BackupModel.localizedMessage(for: failure, language: .english)
            let chinese = BackupModel.localizedMessage(for: failure, language: .simplifiedChinese)
            #expect(!english.isEmpty && english != chinese, "\(failure)")
        }
    }

    @Test
    func showingTheFolderRoutesThroughServiceAndClearsOnlyARevealFailure() async {
        let service = BackupModelService(status: .readyFixture())
        let model = BackupModel(service: service)
        await model.refresh()
        await service.failNextReveal()

        await model.showFolder()
        #expect(model.failure == .folderUnavailable)

        await model.showFolder()
        #expect(await service.showFolderCount == 2)
        #expect(model.failure == nil)
        #expect(model.phase == .ready)
    }

    @Test
    func enablingAutomaticBackupArmsAReturnedRetryWithoutAnotherAppEvent() async {
        let service = BackupModelService(status: .readyFixture())
        await service.returnImmediateRetryWhenEnabling()
        let model = BackupModel(service: service)
        await model.refresh()

        await model.setAutomaticBackupEnabled(true)
        await service.waitForSchedulerEventCount(1)

        #expect(await service.schedulerEvents == [.mutation])
    }

    @Test
    func aRetryReturnedByAnAppEventRunsItsDueMutation() async {
        let service = BackupModelService(status: .readyFixture())
        await service.returnImmediateRetryThenCompletion()
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
        await service.returnFutureRetryWhenEnabling()
        let model = BackupModel(service: service)
        await model.refresh()
        await model.setAutomaticBackupEnabled(true)

        model.cancelForApplicationTermination()
        await service.waitForTerminationCancellation()

        #expect(await service.schedulerEvents.isEmpty)
        #expect(try await service.loadStatus().isAutomaticBackupEnabled)
    }

    @Test
    func aStatusRefreshDuringAManualBackupKeepsItInFlight() async {
        let service = BackupModelService(status: .readyFixture())
        await service.pauseNextManualBackup()
        let model = BackupModel(service: service)
        await model.refresh()

        let backup = Task { await model.backUpNow() }
        await service.waitUntilManualBackupPaused()
        await model.refresh()
        await model.handleAppEvent(.activation)
        #expect(model.phase == .backingUp && model.isManualBackupInFlight)

        await service.resumeManualBackup()
        await backup.value
        #expect(model.phase == .backupCompleted && !model.isManualBackupInFlight)
    }
}

private actor BackupModelService: BackupServicing {
    private var status: AppBackupStatus
    private(set) var chosenFolders: [URL] = []
    private(set) var automaticValues: [Bool] = []
    private(set) var retentionValues: [Int] = []
    private(set) var manualBackupCount = 0
    private var nextManualBackupResult: Result<Bool, BackupFailure> = .success(false)
    private(set) var showFolderCount = 0
    private var revealShouldFail = false
    private var automaticOutcome: BackupSchedulerOutcome = .disabled
    private(set) var schedulerEvents: [BackupSchedulerEvent] = []
    private var schedulerOutcomes: [BackupSchedulerOutcome] = []
    private var schedulerEventCountWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var terminationCount = 0
    private var terminationWaiters: [CheckedContinuation<Void, Never>] = []
    private var manualPaused = false
    private var manualEntered = false
    private var manualContinuation: CheckedContinuation<Void, Never>?
    private var manualWaiters: [CheckedContinuation<Void, Never>] = []

    init(status: AppBackupStatus = .notConfigured) {
        self.status = status
    }

    func loadStatus() async throws -> AppBackupStatus { status }

    func chooseFolder(_ url: URL) async throws {
        chosenFolders.append(url)
        status = .readyFixture()
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

    func backUpNow() async throws -> BackupRunResult {
        manualBackupCount += 1
        manualEntered = true
        manualWaiters.forEach { $0.resume() }
        manualWaiters.removeAll()
        if manualPaused { await withCheckedContinuation { manualContinuation = $0 } }
        let result = nextManualBackupResult
        nextManualBackupResult = .success(false)
        let deferred = try result.get()
        status = status.replacing(lastBackupAt: Date(timeIntervalSince1970: 1))
        return BackupRunResult(fileName: "Kinlogue Backup.zip", completedAt: Date(timeIntervalSince1970: 1),
                               revision: try BackupLibraryRevision(libraryID: UUID(), generation: 1, commitID: UUID()),
                               cleanupDeferred: deferred)
    }

    func finishNextManualBackup(with result: Result<Bool, BackupFailure>) { nextManualBackupResult = result }
    func pauseNextManualBackup() { manualPaused = true }
    func waitUntilManualBackupPaused() async {
        if manualEntered { return }
        await withCheckedContinuation { manualWaiters.append($0) }
    }
    func resumeManualBackup() {
        manualPaused = false
        manualContinuation?.resume()
        manualContinuation = nil
    }

    func showFolder() async throws {
        showFolderCount += 1
        if revealShouldFail {
            revealShouldFail = false
            throw BackupFailure.folderUnavailable
        }
    }

    func failNextReveal() { revealShouldFail = true }

    func handleSchedulerEvent(_ event: BackupSchedulerEvent) async throws -> BackupSchedulerOutcome {
        schedulerEvents.append(event)
        var waiting: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in schedulerEventCountWaiters {
            if schedulerEvents.count >= waiter.count { waiter.continuation.resume() } else { waiting.append(waiter) }
        }
        schedulerEventCountWaiters = waiting
        return schedulerOutcomes.isEmpty ? .disabled : schedulerOutcomes.removeFirst()
    }

    func cancelForApplicationTermination() {
        terminationCount += 1
        terminationWaiters.forEach { $0.resume() }
        terminationWaiters.removeAll()
    }

    func returnImmediateRetryWhenEnabling() { automaticOutcome = .retryScheduled(Date(timeIntervalSinceNow: -1)) }
    func returnFutureRetryWhenEnabling() { automaticOutcome = .retryScheduled(Date(timeIntervalSinceNow: 60 * 60)) }
    func returnImmediateRetryThenCompletion() {
        schedulerOutcomes = [.retryScheduled(Date(timeIntervalSinceNow: -1)), .completed]
    }

    func waitForSchedulerEventCount(_ count: Int) async {
        if schedulerEvents.count >= count { return }
        await withCheckedContinuation { schedulerEventCountWaiters.append((count, $0)) }
    }

    func waitForTerminationCancellation() async {
        if terminationCount > 0 { return }
        await withCheckedContinuation { terminationWaiters.append($0) }
    }
}

private extension AppBackupStatus {
    static func readyFixture() -> Self {
        .init(folderName: "Selected Folder", isFolderConfigured: true, isAutomaticBackupEnabled: false,
              retentionCount: 5, lastBackupAt: nil, lastBackupFileName: nil, managedBackupCount: 0,
              nextDueAt: nil, lastFailure: nil)
    }

    func replacing(automatic: Bool? = nil, retention: Int? = nil, lastBackupAt: Date? = nil) -> Self {
        .init(folderName: folderName, isFolderConfigured: isFolderConfigured,
              isAutomaticBackupEnabled: automatic ?? isAutomaticBackupEnabled,
              retentionCount: retention ?? retentionCount, lastBackupAt: lastBackupAt ?? self.lastBackupAt,
              lastBackupFileName: lastBackupFileName, managedBackupCount: managedBackupCount,
              nextDueAt: nextDueAt, lastFailure: lastFailure)
    }
}
