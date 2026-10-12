import Foundation
import KinloguePlatform

enum AppStartupError: Error, Equatable { case disclosureRequired }

enum SQLiteStartupFailure: Equatable {
    case occupied, unrecognized, recoveryUnresolved, unavailable, restartRequired

    var canRetry: Bool { self == .occupied || self == .unavailable }
    var message: String {
        switch self {
        case .occupied: AppLocalization.string("资料库正由另一个续页进程使用。请关闭该进程后重试。")
        case .unrecognized: AppLocalization.string("资料库格式不受支持或已损坏。现有内容已保留；你可以从数据备份恢复，或退出后检查资料库。")
        case .recoveryUnresolved: AppLocalization.string("上一次资料库操作尚未核实完成。现有内容已保留；请退出并保留资料库及恢复记录，暂时无法继续恢复。")
        case .unavailable: AppLocalization.string("暂时无法打开资料库。请稍后重试，或退出后检查本机存储。")
        case .restartRequired: AppLocalization.string("本次资料库操作已停止。请退出并重新打开续页，再检查资料库状态。")
        }
    }
}


/// One launch owns the root before restore receipts or a database are opened.
/// Construction is inert; the existing first-launch disclosure must be accepted first.
struct SQLiteStartupContext: Sendable {
    let owner: SQLiteLibraryOwner
    let verifier: BackupRestoreVerifier
    let transaction: BackupRestoreTransaction
    let lifecycle: LibraryLifecycleCoordinator
    let configuration: BackupLocalConfigurationStore

    @concurrent static func make(identity: AppRuntimeIdentity) async throws -> Self {
        try await LibraryStorageExecutor.run {
            try Task.checkCancellation()
            try VaultParentDirectoryPreparation.ensureParentDirectory(for: identity.sourceVault.rootURL)
            let owner = try SQLiteLibraryOwner(rootURL: identity.sourceVault.rootURL)
            return try Self(owner: owner, verifier: BackupRestoreVerifier(owner: owner),
                transaction: BackupRestoreTransaction(owner: owner), lifecycle: LibraryLifecycleCoordinator(),
                configuration: BackupLocalConfigurationStore(rootURL: identity.backupIdentity.rootURL))
        }
    }

    @concurrent func reconcile() async throws {
        try await LibraryStorageExecutor.run {
            _ = try await transaction.reconcile()
            try verifier.reconcileAbandonedPreflights()
            try owner.reconcilePendingDeletion()
        }
    }

    @concurrent func open() async throws -> SQLiteLibraryStore {
        try await LibraryStorageExecutor.run {
            try Task.checkCancellation()
            return try SQLiteLibraryStore(owner: owner)
        }
    }

    @concurrent static func close(_ database: SQLiteLibraryStore, releasingOwner: Bool) async throws {
        try await LibraryStorageExecutor.run {
            if releasingOwner { try database.close() } else { try database.closeDatabaseForReplacement() }
        }
    }

    func seedRestore() -> LiveRestoreService {
        LiveRestoreService(service: BackupRestoreService(operations: .init(
            prepare: { try await verifier.prepare(checkpointURL: $0, recoveryCode: $1) },
            cancel: { try verifier.cancel($0) }, destructiveFence: { try await $0() },
            revokeLifecycle: { await lifecycle.revoke() },
            activate: { try await transaction.activate(prepared: $0, resetWriter: $1) },
            removeWriterConfiguration: { try await configuration.removeForDestructiveReset() },
            reconcilePreflights: {}, reconcile: { .noTransaction })))
    }
}
