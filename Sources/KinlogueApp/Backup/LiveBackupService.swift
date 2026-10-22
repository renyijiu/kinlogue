import AppKit
import Foundation
import KinlogueCore
import KinloguePlatform

/// What the settings page shows. Loading it reads only the app-private settings and checks
/// that the folder still resolves; it never captures or enumerates the library.
struct AppBackupStatus: Equatable, Sendable {
    let folderName: String?
    let isFolderConfigured: Bool
    let isAutomaticBackupEnabled: Bool
    let retentionCount: Int
    let lastBackupAt: Date?
    let lastBackupFileName: String?
    let managedBackupCount: Int
    let nextDueAt: Date?
    let lastFailure: BackupFailure?

    static let notConfigured = AppBackupStatus(
        folderName: nil, isFolderConfigured: false, isAutomaticBackupEnabled: false,
        retentionCount: BackupRetentionCount.default.value, lastBackupAt: nil, lastBackupFileName: nil,
        managedBackupCount: 0, nextDueAt: nil, lastFailure: nil
    )
}

enum BackupExportError: Error, Equatable, Sendable {
    case invalidDestination
    case insufficientSpace
    case destinationAccessDenied
    case sourceChanged
    case libraryUnreadable
    case archiveIntegrityFailure
    case publicationIndeterminate
    case busy
    case unavailable
}

enum AppBackupPhase: Equatable, Sendable {
    case preparing
    case writing
    case verifying
    case committing
}

struct AppBackupProgress: Equatable, Sendable {
    let phase: AppBackupPhase
    let completedByteCount: UInt64
    let totalByteCount: UInt64
    let isCancellable: Bool
}

struct BackupExportResult: Equatable, Sendable {
    let url: URL
    let originalCount: Int
    let byteCount: UInt64
}

protocol BackupServicing: Sendable {
    func loadStatus() async throws -> AppBackupStatus
    func chooseFolder(_ url: URL) async throws
    func setAutomaticBackupEnabled(_ enabled: Bool) async throws -> BackupSchedulerOutcome
    func setRetentionCount(_ count: Int) async throws
    func backUpNow() async throws -> BackupRunResult
    func showFolder() async throws
    func handleSchedulerEvent(_ event: BackupSchedulerEvent) async throws -> BackupSchedulerOutcome
    func cancelForApplicationTermination() async
}

/// The one-off "export a backup to…" flow; the archive is the same as a folder backup.
protocol BackupExportServicing: Sendable {
    func export(to url: URL, progress: @escaping @Sendable (AppBackupProgress) -> Void) async throws -> BackupExportResult
    @discardableResult
    func cancelExport() async -> Bool
}

extension BackupServicing {
    func cancelForApplicationTermination() async {}
}

protocol BackupFolderOpening: Sendable {
    func open(_ url: URL) async -> Bool
}

struct SystemBackupFolderOpener: BackupFolderOpening {
    func open(_ url: URL) async -> Bool {
        await MainActor.run { NSWorkspace.shared.open(url) }
    }
}

protocol BackupSelectedDirectorySecurityScope: Sendable {
    func startAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
}

struct SystemBackupSelectedDirectorySecurityScope: BackupSelectedDirectorySecurityScope {
    func startAccessing(_ url: URL) -> Bool { url.startAccessingSecurityScopedResource() }
    func stopAccessing(_ url: URL) { url.stopAccessingSecurityScopedResource() }
}

/// Writes one archive. Production uses `BackupArchiveWriter`; tests substitute it.
typealias BackupArchiveWriting = @Sendable (
    BackupArchiveDestination,
    BackupArchiveContent,
    @escaping @Sendable (BackupArchiveWriteProgress) -> Void
) async throws -> BackupArchiveWriteResult

/// Production bridge for one App lifetime: folder backups, the scheduler and one-off exports
/// all go through one operation coordinator and count as active library operations, so a
/// restore, a deletion or an integrity shutdown waits for them.
actor LiveBackupService: BackupServicing, BackupExportServicing {
    let operationCoordinator: BackupOperationCoordinator
    let settingsStore: BackupSettingsStore

    private let activeVaultURL: URL
    private let authority: BackupFolderAuthority
    private let lifecycle: LibraryLifecycleCoordinator
    private let runner: FolderBackupRunner
    private let scheduler: BackupScheduler
    private let archive: BackupArchiveWriting
    private let currentRevision: @Sendable () async throws -> BackupLibraryRevision
    private let selectedDirectoryScope: any BackupSelectedDirectorySecurityScope
    private let requiresSelectedDirectoryScope: Bool
    private let folderOpener: any BackupFolderOpening
    private let content: @Sendable () -> BackupArchiveContent
    private let clock: @Sendable () -> Date
    private let lifecycleRegistrationID = UUID()
    private var lifecycleIsRegistered = false
    private var exportGate: BackupExportCancellationGate?
    #if DEBUG
    private var sourceRevisionReadCount = 0
    #endif

    init(
        store: SQLiteLibraryStore,
        settingsStore: BackupSettingsStore,
        lifecycle: LibraryLifecycleCoordinator,
        requiresSelectedDirectoryScope: Bool,
        authority: BackupFolderAuthority = BackupFolderAuthority(),
        selectedDirectoryScope: any BackupSelectedDirectorySecurityScope = SystemBackupSelectedDirectorySecurityScope(),
        folderOpener: any BackupFolderOpening = SystemBackupFolderOpener(),
        content: @escaping @Sendable () -> BackupArchiveContent = BackupArchiveText.content,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        let writer = BackupArchiveWriter(store: store, clock: clock)
        let source = SQLiteLogicalBackupSource(store: store)
        self.init(
            activeVaultURL: store.rootURL,
            settingsStore: settingsStore,
            lifecycle: lifecycle,
            requiresSelectedDirectoryScope: requiresSelectedDirectoryScope,
            authority: authority,
            selectedDirectoryScope: selectedDirectoryScope,
            folderOpener: folderOpener,
            archive: { destination, content, progress in
                try await writer.write(to: destination, content: content, progress: progress)
            },
            currentRevision: { try await LibraryStorageExecutor.run { try source.currentLibraryRevision() } },
            content: content,
            clock: clock
        )
    }

    init(
        activeVaultURL: URL,
        settingsStore: BackupSettingsStore,
        lifecycle: LibraryLifecycleCoordinator,
        requiresSelectedDirectoryScope: Bool,
        authority: BackupFolderAuthority = BackupFolderAuthority(),
        selectedDirectoryScope: any BackupSelectedDirectorySecurityScope = SystemBackupSelectedDirectorySecurityScope(),
        folderOpener: any BackupFolderOpening = SystemBackupFolderOpener(),
        archive: @escaping BackupArchiveWriting,
        currentRevision: @escaping @Sendable () async throws -> BackupLibraryRevision,
        content: @escaping @Sendable () -> BackupArchiveContent = BackupArchiveText.content,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        let coordinator = BackupOperationCoordinator()
        let runner = FolderBackupRunner(
            coordinator: coordinator, settingsStore: settingsStore, authority: authority, lifecycle: lifecycle,
            archive: archive, content: content, clock: clock
        )
        self.activeVaultURL = activeVaultURL.standardizedFileURL
        self.settingsStore = settingsStore
        self.authority = authority
        self.lifecycle = lifecycle
        self.runner = runner
        self.archive = archive
        self.currentRevision = currentRevision
        self.selectedDirectoryScope = selectedDirectoryScope
        self.requiresSelectedDirectoryScope = requiresSelectedDirectoryScope
        self.folderOpener = folderOpener
        self.content = content
        self.clock = clock
        operationCoordinator = coordinator
        scheduler = BackupScheduler(store: settingsStore, runner: runner)
    }

    func loadStatus() async throws -> AppBackupStatus {
        let settings = try settingsStore.load()
        guard let folder = settings.folder else {
            return .init(
                folderName: nil, isFolderConfigured: false, isAutomaticBackupEnabled: false,
                retentionCount: settings.retentionCount.value, lastBackupAt: settings.scheduler.lastBackupAt,
                lastBackupFileName: nil, managedBackupCount: 0, nextDueAt: nil, lastFailure: nil
            )
        }
        var folderName: String?
        var folderFailure: BackupFailure?
        do {
            let resolved = try authority.withFolder(folder) { $0.lastPathComponent }
            folderName = resolved.value
            try persist(refreshedBookmark: resolved.refreshedBookmarkData)
        } catch {
            folderFailure = FolderBackupRunner.failure(for: error)
        }
        return .init(
            folderName: folderName,
            isFolderConfigured: true,
            isAutomaticBackupEnabled: settings.isAutomaticBackupEnabled,
            retentionCount: settings.retentionCount.value,
            lastBackupAt: settings.scheduler.lastBackupAt,
            lastBackupFileName: settings.scheduler.lastBackupFileName,
            managedBackupCount: settings.ledger.count,
            nextDueAt: settings.isAutomaticBackupEnabled ? settings.scheduler.retryDueAt ?? settings.scheduler.dueAt : nil,
            lastFailure: folderFailure ?? settings.scheduler.lastFailure
        )
    }

    /// Records the folder from the open panel. Backups written into an earlier folder are left
    /// where they are and no longer managed.
    func chooseFolder(_ url: URL) async throws {
        if requiresSelectedDirectoryScope {
            guard selectedDirectoryScope.startAccessing(url) else { throw BackupFolderError.securityScopeUnavailable }
        }
        defer { if requiresSelectedDirectoryScope { selectedDirectoryScope.stopAccessing(url) } }
        let selection = try authority.select(url, activeVaultURL: activeVaultURL)
        try settingsStore.update { settings in
            if settings.folder?.identity != selection.identity { settings.ledger = [] }
            settings.folder = selection
            settings.scheduler.lastFailure = nil
            settings.scheduler.retryAttempt = 0
            settings.scheduler.retryDueAt = nil
        }
    }

    func setAutomaticBackupEnabled(_ enabled: Bool) async throws -> BackupSchedulerOutcome {
        guard enabled else { return try await scheduler.disableAutomaticBackup() }
        return try await scheduler.enableAutomaticBackup(current: currentLibraryRevision(), at: clock())
    }

    func setRetentionCount(_ count: Int) async throws {
        let value = try BackupRetentionCount(count)
        try settingsStore.update { $0.retentionCount = value }
    }

    func backUpNow() async throws -> BackupRunResult {
        try await ensureLifecycleRegistration()
        return try await runner.run()
    }

    func showFolder() async throws {
        guard let folder = try settingsStore.load().folder else { throw BackupFailure.notConfigured }
        let opener = folderOpener
        let resolved: BackupResolvedFolder<Bool>
        do {
            resolved = try await authority.withFolder(folder) { url in await opener.open(url) }
        } catch {
            throw FolderBackupRunner.failure(for: error)
        }
        try persist(refreshedBookmark: resolved.refreshedBookmarkData)
        guard resolved.value else { throw BackupFailure.folderUnavailable }
    }

    func handleSchedulerEvent(_ event: BackupSchedulerEvent) async throws -> BackupSchedulerOutcome {
        let settings = try settingsStore.load()
        guard let folder = settings.folder, settings.isAutomaticBackupEnabled else { return .disabled }
        do {
            let resolved = try authority.withFolder(folder) { _ in () }
            try persist(refreshedBookmark: resolved.refreshedBookmarkData)
        } catch BackupFolderError.folderUnavailable {
            return try await scheduler.recordFolderUnavailable(at: clock())
        } catch {
            // Reselection is the person's to do; record it so the settings page explains it.
            let failure = FolderBackupRunner.failure(for: error)
            try settingsStore.update { settings in
                settings.scheduler.lastFailure = failure
                settings.scheduler.retryDueAt = nil
            }
            return .failed(failure)
        }
        try await ensureLifecycleRegistration()
        return try await scheduler.handle(event, current: currentLibraryRevision(), at: clock())
    }

    func export(to url: URL, progress: @escaping @Sendable (AppBackupProgress) -> Void) async throws -> BackupExportResult {
        try await ensureLifecycleRegistration()
        let gate = BackupExportCancellationGate()
        exportGate = gate
        defer { if exportGate === gate { exportGate = nil } }
        let archive = self.archive, content = self.content(), lifecycle = self.lifecycle
        do {
            let result = try await operationCoordinator.run {
                try await lifecycle.withActiveOperation {
                    try await LibraryStorageExecutor.run {
                        try await archive(.file(url), content) { value in
                            gate.update(isCancellable: value.isCancellable)
                            progress(FolderBackupRunner.appProgress(value))
                        }
                    }
                }
            }
            return BackupExportResult(url: result.url, originalCount: result.counts.originals, byteCount: result.byteCount)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.exportError(for: error)
        }
    }

    func cancelExport() async -> Bool {
        guard let exportGate, exportGate.acceptsCancellation else { return false }
        await operationCoordinator.cancelActiveOperation()
        return true
    }

    func cancelForApplicationTermination() async {
        await operationCoordinator.cancelForApplicationTermination()
    }

    private func ensureLifecycleRegistration() async throws {
        guard !lifecycleIsRegistered else { return }
        let coordinator = operationCoordinator
        do {
            try await lifecycle.register(id: lifecycleRegistrationID) { await coordinator.cancelActiveOperation() }
        } catch {
            throw BackupFailure.operationInProgress
        }
        lifecycleIsRegistered = true
    }

    private func persist(refreshedBookmark: Data?) throws {
        guard let refreshedBookmark else { return }
        try settingsStore.update { settings in
            guard let folder = settings.folder,
                  let refreshed = try? BackupFolderSelection(bookmarkData: refreshedBookmark, identity: folder.identity) else { return }
            settings.folder = refreshed
        }
    }

    private func currentLibraryRevision() async throws -> BackupLibraryRevision {
        #if DEBUG
        sourceRevisionReadCount += 1
        #endif
        return try await currentRevision()
    }

    #if DEBUG
    func sourceRevisionReadCountForTesting() -> Int { sourceRevisionReadCount }
    #endif

    private static func exportError(for error: Error) -> BackupExportError {
        if error is BackupOperationCoordinatorError || error is LibraryLifecycleCoordinatorError { return .busy }
        guard let error = error as? BackupArchiveWriteError else { return .unavailable }
        switch error {
        case .invalidDestination: return .invalidDestination
        case .capacityInsufficient, .ioFailure(ENOSPC): return .insufficientSpace
        case .destinationAccessDenied: return .destinationAccessDenied
        case .sourceChanged: return .sourceChanged
        case .libraryUnreadable, .resourceLimit: return .libraryUnreadable
        case .archiveIntegrityFailure, .injectedFailure: return .archiveIntegrityFailure
        case .publicationIndeterminate: return .publicationIndeterminate
        case .ioFailure: return .unavailable
        }
    }
}

/// Writes one backup into the folder, records it in the ledger and applies retention. Manual
/// and automatic backups share it, so both count towards the same retention.
struct FolderBackupRunner: BackupAutomaticRunning {
    let coordinator: BackupOperationCoordinator
    let settingsStore: BackupSettingsStore
    let authority: BackupFolderAuthority
    let lifecycle: LibraryLifecycleCoordinator
    let archive: BackupArchiveWriting
    let content: @Sendable () -> BackupArchiveContent
    let clock: @Sendable () -> Date

    func runAutomaticBackup(expected: BackupLibraryRevision, at: Date) async throws -> BackupRunResult {
        _ = expected
        return try await run()
    }

    func run() async throws -> BackupRunResult {
        let (settingsStore, authority, archive, clock, lifecycle) = (self.settingsStore, self.authority, self.archive, self.clock, self.lifecycle)
        let content = self.content()
        do {
            return try await coordinator.run {
                try await lifecycle.withActiveOperation {
                    try await LibraryStorageExecutor.run {
                        guard let folder = try settingsStore.load().folder else { throw BackupFailure.notConfigured }
                        let resolved = try await authority.withFolder(folder) { url in
                            let stem = BackupArchiveText.fileNameStem(clock())
                            let written = try await archive(.folder(url, fileNameStem: stem), content) { _ in }
                            let completedAt = clock()
                            let (ledger, count, sequence) = try settingsStore.update { settings in
                                let sequence = settings.nextSequence
                                settings.nextSequence += 1
                                settings.ledger.append(BackupLedgerEntry(
                                    sequence: sequence, fileName: written.fileName, inode: written.inode,
                                    byteCount: written.byteCount, modifiedSeconds: written.modifiedSeconds,
                                    modifiedNanoseconds: written.modifiedNanoseconds, backupID: written.backupID,
                                    createdAt: written.createdAt, library: written.library
                                ))
                                // Past the ledger's bound the oldest entries are forgotten, never deleted.
                                if settings.ledger.count > BackupSettings.maximumLedgerCount {
                                    settings.ledger.removeFirst(settings.ledger.count - BackupSettings.maximumLedgerCount)
                                }
                                var scheduler = BackupSchedulerState()
                                scheduler.lastCoveredRevision = written.library
                                scheduler.lastBackupAt = completedAt
                                scheduler.lastBackupFileName = written.fileName
                                settings.scheduler = scheduler
                                return (settings.ledger, settings.retentionCount, sequence)
                            }
                            let retention = BackupFolderRetention.apply(folder: url, ledger: ledger, count: count, newest: sequence)
                            try? settingsStore.update { settings in
                                let kept = Set(retention.ledger.map(\.sequence))
                                settings.ledger.removeAll { $0.sequence <= sequence && !kept.contains($0.sequence) }
                            }
                            return BackupRunResult(fileName: written.fileName, completedAt: completedAt,
                                                   revision: written.library, cleanupDeferred: retention.deferred)
                        }
                        if let refreshed = resolved.refreshedBookmarkData {
                            try? settingsStore.update { settings in
                                guard let folder = settings.folder,
                                      let selection = try? BackupFolderSelection(bookmarkData: refreshed, identity: folder.identity) else { return }
                                settings.folder = selection
                            }
                        }
                        return resolved.value
                    }
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as BackupOperationCoordinatorError {
            throw error
        } catch {
            throw Self.failure(for: error)
        }
    }

    static func failure(for error: Error) -> BackupFailure {
        if let failure = error as? BackupFailure { return failure }
        if error is LibraryLifecycleCoordinatorError { return .operationInProgress }
        if let error = error as? BackupFolderError {
            switch error {
            case .folderUnavailable: return .folderUnavailable
            default: return .folderNeedsReselection
            }
        }
        guard let error = error as? BackupArchiveWriteError else { return .verificationFailed }
        switch error {
        case .capacityInsufficient, .ioFailure(ENOSPC): return .capacityInsufficient
        case .resourceLimit: return .resourceLimitExceeded
        case .sourceChanged: return .sourceChanged
        case .libraryUnreadable: return .libraryUnreadable
        case .invalidDestination, .destinationAccessDenied: return .folderNeedsReselection
        case .publicationIndeterminate: return .publicationIndeterminate
        case .ioFailure: return .folderUnavailable
        case .archiveIntegrityFailure, .injectedFailure: return .verificationFailed
        }
    }

    static func appProgress(_ value: BackupArchiveWriteProgress) -> AppBackupProgress {
        let phase: AppBackupPhase
        switch value.phase {
        case .preparing: phase = .preparing
        case .writing: phase = .writing
        case .verifying: phase = .verifying
        case .committing: phase = .committing
        }
        return AppBackupProgress(phase: phase, completedByteCount: value.completedByteCount,
                                 totalByteCount: value.totalByteCount, isCancellable: value.isCancellable)
    }
}

// SAFETY: `lock` guards the only mutable state.
final class BackupExportCancellationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancellable = true

    var acceptsCancellation: Bool { lock.withLock { isCancellable } }

    func update(isCancellable: Bool) {
        lock.withLock { self.isCancellable = isCancellable }
    }
}
