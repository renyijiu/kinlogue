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
        try Task.checkCancellation()
        try VaultParentDirectoryPreparation.ensureParentDirectory(for: identity.sourceVault.rootURL)
        let owner = try SQLiteLibraryOwner(rootURL: identity.sourceVault.rootURL)
        return try Self(owner: owner, verifier: BackupRestoreVerifier(owner: owner),
            transaction: BackupRestoreTransaction(owner: owner), lifecycle: LibraryLifecycleCoordinator(),
            configuration: BackupLocalConfigurationStore(rootURL: identity.backupIdentity.rootURL))
    }

    @concurrent func reconcile() async throws {
        _ = try await transaction.reconcile()
        try verifier.reconcileAbandonedPreflights()
        try owner.reconcilePendingDeletion()
    }

    @concurrent func open() async throws -> SQLiteLibraryStore {
        try Task.checkCancellation()
        return try SQLiteLibraryStore(owner: owner)
    }

    @concurrent static func close(_ database: SQLiteLibraryStore, releasingOwner: Bool) async throws {
        if releasingOwner { try database.close() } else { try database.closeDatabaseForReplacement() }
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

extension AppStartupCoordinator {
    func acknowledgeStorageDisclosure() { disclosureAccepted = true }

    func openEnvironment() async throws -> LiveAppServiceEnvironment {
        guard disclosureAccepted else { throw AppStartupError.disclosureRequired }
        guard !shutdownRequested else { throw LibraryLifecycleCoordinatorError.revoked }
        if let context { try await context.lifecycle.requireActive() }
        if let environment { return environment }
        if let openingTask { return try await openingTask.value }
        // A failed-format launch offers seed-only restore, never hot rebinding while
        // a confirmation prepared against that launch may still be outstanding.
        if seedRestoreService != nil, let openingFailure { throw openingFailure }
        let task = Task { try await performOpening() }
        openingTask = task
        defer { openingTask = nil }
        return try await task.value
    }

    private func performOpening() async throws -> LiveAppServiceEnvironment {
        guard let identity else { throw AppServiceError.runtimeUnavailable }
        if context == nil { context = try await SQLiteStartupContext.make(identity: identity) }
        guard let context else { throw AppServiceError.runtimeUnavailable }
        if !didReconcile {
            try await context.reconcile()
            didReconcile = true
        }
        do {
            let store = try await context.open()
            database = store
            let services = try await LiveAppServiceEnvironment.makeOpened(identity: identity, store: store, lifecycle: context.lifecycle)
            try Task.checkCancellation()
            try await context.lifecycle.requireActive()
            environment = services
            openingFailure = nil
            return services
        } catch {
            if let database {
                // Keep authority if closing cannot be proved; a later launch must recover.
                do { try await SQLiteStartupContext.close(database, releasingOwner: false); self.database = nil }
                catch { shutdownRequested = true; throw error }
            }
            openingFailure = error
            if let failure = error as? SQLiteLibraryError,
               [.unsupportedFormat, .unsupportedConfiguration, .damaged, .databaseUnavailable].contains(failure) {
                seedRestoreService = context.seedRestore()
            }
            throw error
        }
    }

    func startSQLiteCandidate() async -> Bool {
        if let candidateStartingTask { return await candidateStartingTask.value }
        isOpening = true
        let task = Task { await performCandidateStart() }
        candidateStartingTask = task
        defer { candidateStartingTask = nil; isOpening = false }
        return await task.value
    }

    private func performCandidateStart() async -> Bool {
        do {
            let services = try await openEnvironment()
            try Task.checkCancellation()
            if !hasOpenedComposition, let identity, let context, let database {
                publish(AppComposition.makeOpened(identity: identity, services: services, context: context, database: database))
                hasOpenedComposition = true
            }
            let ready = await composition?.startupCoordinator.start() ?? false
            candidateFailure = ready ? nil : .unavailable
            return ready
        } catch {
            if !disclosureAccepted { return false }
            if shutdownRequested || error is LibraryLifecycleCoordinatorError { candidateFailure = .restartRequired }
            else if error as? SQLiteLibraryError == .occupied { candidateFailure = .occupied }
            else if seedRestoreService != nil { candidateFailure = .unrecognized }
            else if context != nil && !didReconcile { candidateFailure = .recoveryUnresolved }
            else { candidateFailure = .unavailable }
            if composition == nil { publish(AppComposition.makeSQLiteUnavailable(restoreService: seedRestoreService)) }
            return false
        }
    }

    func shutdown() async {
        shutdownRequested = true
        candidateStartingTask?.cancel()
        let opening = openingTask
        opening?.cancel()
        _ = try? await opening?.value
        _ = await candidateStartingTask?.value
        await composition?.libraryObserver?.stop()
        await composition?.appModel.beginDestructiveVaultLifecycle()
        await context?.lifecycle.revoke()
        do { if let database { try await SQLiteStartupContext.close(database, releasingOwner: true) } } catch { return } // Preserve authority on a failed close.
        environment = nil; database = nil; publish(nil)
        seedRestoreService = nil; context = nil
    }
}
