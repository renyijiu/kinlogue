import Foundation
import KinlogueCore

enum BackupModelPhase: Equatable {
    case loading
    case notConfigured
    case enrollmentPending
    case ready
    case backingUp
    case localCheckpointComplete
    case failed
}

enum BackupModelFailure: Equatable {
    case independentSaveRequired
    case recoveryCodeMismatch
    case destinationUnavailable
    case semantic(BackupSemanticError)
}

@MainActor
final class BackupModel: ObservableObject {
    private let service: any BackupServicing
    private var operationGeneration: UInt64 = 0
    private var pendingEnrollmentOperationGeneration: UInt64?
    private var scheduledTask: Task<Void, Never>?

    @Published private(set) var phase: BackupModelPhase = .loading
    @Published private(set) var status: AppBackupStatus = .notConfigured
    @Published private(set) var recoveryCode: String?
    @Published var recoveryCodeReentry = ""
    @Published var hasConfirmedIndependentSave = false
    @Published private(set) var isPendingEnrollmentRecoveryPresented = false
    @Published private(set) var isPendingEnrollmentOperation = false
    @Published var pendingEnrollmentRecoveryCode = ""
    @Published private(set) var failure: BackupModelFailure?

    init(service: any BackupServicing) {
        self.service = service
    }

    var isAutomaticBackupEnabled: Bool { status.isAutomaticBackupEnabled }
    var retentionCount: Int { status.retentionCount }

    var cloudStatusText: String {
        AppLocalization.string("网盘同步状态未知")
    }

    var localCheckpointText: String {
        switch status.localCheckpointState {
        case .unavailable:
            AppLocalization.string("尚无已验证的本地恢复点")
        case .verified:
            AppLocalization.string("所选目录中的恢复点已完整验证")
        case .overdue:
            AppLocalization.string("本地恢复点已过期或需要处理")
        }
    }

    var failureText: String? {
        guard let failure else { return nil }
        return switch failure {
        case .independentSaveRequired:
            AppLocalization.string("请先确认恢复码已保存在独立位置。")
        case .recoveryCodeMismatch:
            AppLocalization.string("恢复码不完整或与本次设置不一致。")
        case .destinationUnavailable:
            AppLocalization.string("无法使用所选备份目录，请重新选择。")
        case .semantic(let semantic):
            Self.localizedMessage(for: semantic)
        }
    }

    func refresh() async {
        let generation = beginOperation()
        do {
            let status = try await service.loadStatus()
            guard generation == operationGeneration else { return }
            apply(status)
        } catch {
            guard generation == operationGeneration else { return }
            failure = Self.map(error)
            phase = .failed
        }
    }

    func beginSetup(selectedParent: URL) async {
        let generation = beginOperation()
        phase = .enrollmentPending
        failure = nil
        do {
            let recoveryCode = try await service.beginSetup(selectedParent: selectedParent)
            guard generation == operationGeneration else {
                await service.cancelSetup()
                return
            }
            self.recoveryCode = recoveryCode
        } catch {
            guard generation == operationGeneration else { return }
            failure = Self.map(error)
            phase = .notConfigured
        }
    }

    func completeSetup() async {
        let generation = beginOperation()
        guard hasConfirmedIndependentSave else {
            failure = .independentSaveRequired
            phase = .enrollmentPending
            return
        }
        guard recoveryCodeReentry == recoveryCode else {
            failure = .recoveryCodeMismatch
            phase = .enrollmentPending
            return
        }
        do {
            try await service.completeSetup(
                recoveryCodeReentry: recoveryCodeReentry,
                independentlySaved: hasConfirmedIndependentSave
            )
            guard generation == operationGeneration else { return }
            clearRecoveryInput()
            apply(try await service.loadStatus())
        } catch {
            guard generation == operationGeneration else { return }
            failure = Self.map(error)
            phase = .enrollmentPending
        }
    }

    func cancelSetup() {
        let generation = beginOperation()
        clearRecoveryInput()
        failure = nil
        phase = status.enrollment == .ready ? .ready : .notConfigured
        Task { [weak self, service = self.service] in
            await service.cancelSetup()
            guard let self, generation == self.operationGeneration else { return }
            do {
                let status = try await service.loadStatus()
                guard generation == self.operationGeneration else { return }
                self.apply(status)
            } catch {
                guard generation == self.operationGeneration else { return }
                self.failure = Self.map(error)
                self.phase = .failed
            }
        }
    }

    func presentPendingEnrollmentRecovery() {
        guard status.enrollment == .pending else { return }
        _ = beginOperation()
        clearPendingEnrollmentRecoveryInput()
        failure = nil
        isPendingEnrollmentRecoveryPresented = true
    }

    func cancelPendingEnrollmentRecovery() {
        guard !isPendingEnrollmentOperation else { return }
        _ = beginOperation()
        clearPendingEnrollmentRecoveryInput()
        failure = status.lastFailure.map(BackupModelFailure.semantic)
        isPendingEnrollmentRecoveryPresented = false
    }

    func resumePendingEnrollment() async {
        guard status.enrollment == .pending else { return }
        let generation = beginOperation()
        let recoveryCode = pendingEnrollmentRecoveryCode
        clearPendingEnrollmentRecoveryInput()
        guard !recoveryCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            failure = .recoveryCodeMismatch
            phase = .enrollmentPending
            return
        }
        beginPendingEnrollmentOperation(generation: generation)
        defer { finishPendingEnrollmentOperation(generation: generation) }
        failure = nil
        do {
            try await service.resumePending(recoveryCode: recoveryCode)
            guard generation == operationGeneration else {
                await refresh()
                return
            }
            isPendingEnrollmentRecoveryPresented = false
            apply(try await service.loadStatus())
        } catch {
            guard generation == operationGeneration else { return }
            failure = Self.map(error)
            phase = .enrollmentPending
        }
    }

    func abandonPendingEnrollment() async {
        guard status.enrollment == .pending else { return }
        let generation = beginOperation()
        clearPendingEnrollmentRecoveryInput()
        isPendingEnrollmentRecoveryPresented = false
        beginPendingEnrollmentOperation(generation: generation)
        defer { finishPendingEnrollmentOperation(generation: generation) }
        failure = nil
        do {
            try await service.abandonPending()
            guard generation == operationGeneration else {
                await refresh()
                return
            }
            apply(.notConfigured)
            apply(try await service.loadStatus())
        } catch {
            guard generation == operationGeneration else { return }
            failure = Self.map(error)
            phase = .enrollmentPending
        }
    }

    func setAutomaticBackupEnabled(_ enabled: Bool) async {
        let generation = beginOperation()
        do {
            let outcome = try await service.setAutomaticBackupEnabled(enabled)
            guard generation == operationGeneration else { return }
            apply(try await service.loadStatus())
            if enabled {
                schedule(outcome)
            } else {
                scheduledTask?.cancel()
                scheduledTask = nil
            }
        } catch {
            guard generation == operationGeneration else { return }
            failure = Self.map(error)
            phase = .failed
        }
    }

    func setRetentionCount(_ count: Int) async {
        guard BackupRetentionCount.allowedRange.contains(count) else { return }
        let generation = beginOperation()
        do {
            try await service.setRetentionCount(count)
            guard generation == operationGeneration else { return }
            apply(try await service.loadStatus())
        } catch {
            guard generation == operationGeneration else { return }
            failure = Self.map(error)
            phase = .failed
        }
    }

    func backUpNow() async {
        let generation = beginOperation()
        phase = .backingUp
        failure = nil
        do {
            let cleanup = try await service.backUpNow()
            guard generation == operationGeneration else { return }
            status = try await service.loadStatus()
            if case .deferred(let semantic) = cleanup {
                failure = .semantic(semantic)
            }
            phase = .localCheckpointComplete
        } catch {
            guard generation == operationGeneration else { return }
            failure = Self.map(error)
            phase = .failed
        }
    }

    func showBackupRepository() async {
        let generation = operationGeneration
        do {
            try await service.showBackupRepository()
            guard generation == operationGeneration else { return }
            let refreshedStatus = try await service.loadStatus()
            guard generation == operationGeneration else { return }
            status = refreshedStatus
            failure = refreshedStatus.lastFailure.map(BackupModelFailure.semantic)
        } catch {
            guard generation == operationGeneration else { return }
            failure = Self.map(error)
        }
    }

    func handleAppEvent(_ event: BackupSchedulerEvent) async {
        scheduledTask?.cancel()
        do {
            let outcome = try await service.handleSchedulerEvent(event)
            apply(try await service.loadStatus())
            schedule(outcome)
        } catch is CancellationError {
            return
        } catch {
            failure = Self.map(error)
            phase = status.enrollment == .ready ? .ready : .failed
        }
    }

    func cancelForApplicationTermination() {
        scheduledTask?.cancel()
        scheduledTask = nil
        Task { await service.cancelForApplicationTermination() }
    }

    private func schedule(_ outcome: BackupSchedulerOutcome) {
        scheduledTask?.cancel()
        scheduledTask = nil
        let dueAt: Date
        switch outcome {
        case .scheduled(let date), .retryScheduled(let date):
            dueAt = date
        default:
            return
        }
        let delay = max(0, dueAt.timeIntervalSinceNow)
        scheduledTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
                guard let self else { return }
                self.scheduledTask = nil
                await self.handleAppEvent(.mutation)
            } catch {
                return
            }
        }
    }

    private func beginOperation() -> UInt64 {
        operationGeneration &+= 1
        return operationGeneration
    }

    private func beginPendingEnrollmentOperation(generation: UInt64) {
        pendingEnrollmentOperationGeneration = generation
        isPendingEnrollmentOperation = true
    }

    private func finishPendingEnrollmentOperation(generation: UInt64) {
        guard pendingEnrollmentOperationGeneration == generation else { return }
        pendingEnrollmentOperationGeneration = nil
        isPendingEnrollmentOperation = false
    }

    private func apply(_ status: AppBackupStatus) {
        self.status = status
        failure = status.lastFailure.map(BackupModelFailure.semantic)
        if status.enrollment != .pending {
            clearPendingEnrollmentRecoveryInput()
            isPendingEnrollmentRecoveryPresented = false
        }
        switch status.enrollment {
        case .notConfigured:
            phase = .notConfigured
        case .pending:
            phase = .enrollmentPending
        case .ready:
            phase = .ready
        }
    }

    private func clearRecoveryInput() {
        recoveryCode = nil
        recoveryCodeReentry = ""
        hasConfirmedIndependentSave = false
    }

    private func clearPendingEnrollmentRecoveryInput() {
        pendingEnrollmentRecoveryCode = ""
    }

    private static func map(_ error: Error) -> BackupModelFailure {
        if let semantic = error as? BackupSemanticError { return .semantic(semantic) }
        if let coordinator = error as? BackupOperationCoordinatorError {
            switch coordinator {
            case .operationInProgress, .destructiveOperationInProgress:
                return .semantic(.operationInProgress)
            case .semantic(let semantic):
                return .semantic(semantic)
            }
        }
        if let setup = error as? BackupSetupError {
            switch setup {
            case .independentSaveNotConfirmed:
                return .independentSaveRequired
            case .recoveryCodeMismatch:
                return .recoveryCodeMismatch
            default:
                return .destinationUnavailable
            }
        }
        if error is BackupDestinationAuthorityError { return .destinationUnavailable }
        return .semantic(.verificationFailed)
    }

    private static func localizedMessage(for error: BackupSemanticError) -> String {
        switch error {
        case .notConfigured:
            AppLocalization.string("尚未配置数据备份。")
        case .repositoryOffline:
            AppLocalization.string("备份目录当前不可用，请连接存储或恢复网盘目录后重试。")
        case .bookmarkNeedsReselection:
            AppLocalization.string("续页需要你重新选择备份目录。")
        case .identityNeedsEnrollment:
            AppLocalization.string("本机备份身份不可用，需要重新设置新的备份。")
        case .repositoryIdentityConflict:
            AppLocalization.string("备份目录身份发生变化，已暂停写入。")
        case .repositoryHistoryFork:
            AppLocalization.string("无法证明哪个恢复点最新，已暂停写入和清理。")
        case .capacityInsufficient:
            AppLocalization.string("所选位置没有足够空间完成备份。")
        case .publicationIndeterminate:
            AppLocalization.string("恢复点可能已写入，但无法确认本地同步状态。")
        case .sourceChanged:
            AppLocalization.string("备份期间资料库发生变化，续页会稍后重试。")
        case .retentionDeferred:
            AppLocalization.string("新恢复点已保留，但旧恢复点暂未清理。")
        case .operationInProgress:
            AppLocalization.string("另一项资料库操作正在进行。")
        case .unsupportedFormat, .authenticationFailed, .resourceLimitExceeded,
             .verificationFailed:
            AppLocalization.string("备份验证未完成，请检查目录后重试。")
        }
    }
}
