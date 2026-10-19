import Foundation
import KinlogueCore

enum BackupModelPhase: Equatable {
    case loading
    case notConfigured
    case ready
    case backingUp
    case backupCompleted
    case failed
}

/// A manual backup that finished in this session, kept as data so its notice follows the
/// current language.
struct BackupModelCompletion: Equatable {
    let fileName: String
    let cleanupDeferred: Bool
}

@MainActor
final class BackupModel: ObservableObject {
    private let service: any BackupServicing
    private var operationGeneration: UInt64 = 0
    private var scheduledTask: Task<Void, Never>?

    @Published private(set) var phase: BackupModelPhase = .loading
    @Published private(set) var isManualBackupInFlight = false
    @Published private(set) var status: AppBackupStatus = .notConfigured
    @Published private(set) var completion: BackupModelCompletion?
    @Published private(set) var failure: BackupFailure?

    init(service: any BackupServicing) {
        self.service = service
    }

    var isAutomaticBackupEnabled: Bool { status.isAutomaticBackupEnabled }
    var retentionCount: Int { status.retentionCount }

    var completionText: String? {
        guard phase == .backupCompleted, let completion, failure == nil else { return nil }
        return AppLocalization.string("已创建 \(completion.fileName)，并完整验证。")
    }

    var cleanupDeferredText: String? {
        guard phase == .backupCompleted, completion?.cleanupDeferred == true else { return nil }
        return AppLocalization.string("新备份已保存，但有较早的备份暂时没能检查或删除，续页会在下次备份时再试。")
    }

    var failureText: String? {
        failure.map { Self.localizedMessage(for: $0) }
    }

    func refresh() async {
        guard !isManualBackupInFlight else { return }
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

    func chooseFolder(_ url: URL) async {
        guard !isManualBackupInFlight else { return }
        let generation = beginOperation()
        do {
            try await service.chooseFolder(url)
            let status = try await service.loadStatus()
            guard generation == operationGeneration else { return }
            completion = nil
            apply(status)
        } catch {
            guard generation == operationGeneration else { return }
            failure = Self.map(error)
        }
    }

    func setAutomaticBackupEnabled(_ enabled: Bool) async {
        guard !isManualBackupInFlight else { return }
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
        }
    }

    func setRetentionCount(_ count: Int) async {
        guard !isManualBackupInFlight, BackupRetentionCount.allowedRange.contains(count) else { return }
        let generation = beginOperation()
        do {
            try await service.setRetentionCount(count)
            guard generation == operationGeneration else { return }
            apply(try await service.loadStatus())
        } catch {
            guard generation == operationGeneration else { return }
            failure = Self.map(error)
        }
    }

    func backUpNow() async {
        guard !isManualBackupInFlight else { return }
        isManualBackupInFlight = true
        defer { isManualBackupInFlight = false }
        let generation = beginOperation()
        phase = .backingUp
        failure = nil
        completion = nil
        do {
            let result = try await service.backUpNow()
            guard generation == operationGeneration else { return }
            status = try await service.loadStatus()
            guard generation == operationGeneration else { return }
            completion = BackupModelCompletion(fileName: result.fileName, cleanupDeferred: result.cleanupDeferred)
            phase = .backupCompleted
        } catch {
            guard generation == operationGeneration else { return }
            failure = Self.map(error)
            phase = status.isFolderConfigured ? .ready : .notConfigured
        }
    }

    func showFolder() async {
        let generation = operationGeneration
        do {
            try await service.showFolder()
            guard generation == operationGeneration else { return }
            let refreshed = try await service.loadStatus()
            guard generation == operationGeneration else { return }
            status = refreshed
            failure = refreshed.lastFailure
        } catch {
            guard generation == operationGeneration else { return }
            failure = Self.map(error)
        }
    }

    func handleAppEvent(_ event: BackupSchedulerEvent) async {
        scheduledTask?.cancel()
        do {
            let outcome = try await service.handleSchedulerEvent(event)
            let status = try await service.loadStatus()
            if isManualBackupInFlight {
                self.status = status
            } else {
                apply(status)
            }
            schedule(outcome)
        } catch is CancellationError {
            return
        } catch {
            failure = Self.map(error)
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
        case .scheduled(let date), .retryScheduled(let date): dueAt = date
        default: return
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

    private func apply(_ status: AppBackupStatus) {
        self.status = status
        guard !isManualBackupInFlight else { return }
        failure = status.lastFailure
        // The notice about a finished manual backup lasts until the status is read again.
        completion = nil
        phase = status.isFolderConfigured ? .ready : .notConfigured
    }

    private static func map(_ error: Error) -> BackupFailure {
        if let failure = error as? BackupFailure { return failure }
        if error is BackupOperationCoordinatorError { return .operationInProgress }
        if let folder = error as? BackupFolderError {
            return folder == .folderUnavailable ? .folderUnavailable : .folderNeedsReselection
        }
        return .verificationFailed
    }

    static func localizedMessage(for failure: BackupFailure, language: AppLanguage = AppLocalization.selectedLanguage()) -> String {
        switch failure {
        case .notConfigured:
            AppLocalization.string("尚未选择备份文件夹。", language: language)
        case .folderUnavailable:
            AppLocalization.string("备份文件夹当前不可用，请连接磁盘或恢复网络文件夹后重试。", language: language)
        case .folderNeedsReselection:
            AppLocalization.string("续页需要你重新选择备份文件夹。", language: language)
        case .capacityInsufficient:
            AppLocalization.string("备份文件夹所在磁盘没有足够空间。", language: language)
        case .resourceLimitExceeded:
            AppLocalization.string("资料库超出了单个备份能容纳的大小。", language: language)
        case .sourceChanged:
            AppLocalization.string("备份期间资料库发生了变化，续页会稍后重试。", language: language)
        case .libraryUnreadable:
            AppLocalization.string("资料库的部分内容无法读取，备份未完成。", language: language)
        case .verificationFailed:
            AppLocalization.string("备份文件验证未通过，没有保存不完整的备份。", language: language)
        case .publicationIndeterminate:
            AppLocalization.string("备份可能已经写入，但无法确认磁盘同步状态。请检查备份文件夹。", language: language)
        case .operationInProgress:
            AppLocalization.string("另一项资料库操作正在进行。", language: language)
        }
    }
}
