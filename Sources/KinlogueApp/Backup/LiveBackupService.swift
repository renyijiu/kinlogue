import AppKit
import Foundation
import KinlogueCore
import KinloguePlatform

enum AppBackupEnrollmentState: Equatable, Sendable {
    case notConfigured
    case pending
    case ready
}

struct AppBackupSpaceEstimate: Equatable, Sendable {
    let singleCheckpointBytes: UInt64
    let retainedBytes: UInt64
    let temporaryBytes: UInt64
}

struct AppBackupStatus: Equatable, Sendable {
    let enrollment: AppBackupEnrollmentState
    let destinationDisplayName: String?
    let isAutomaticBackupEnabled: Bool
    let retentionCount: Int
    let localCheckpointState: BackupLocalCheckpointState
    let lastLocalVerificationAt: Date?
    let nextDueAt: Date?
    let lastFailure: BackupSemanticError?
    let estimate: AppBackupSpaceEstimate?

    static let notConfigured = AppBackupStatus(
        enrollment: .notConfigured,
        destinationDisplayName: nil,
        isAutomaticBackupEnabled: false,
        retentionCount: BackupRetentionCount.default.value,
        localCheckpointState: .unavailable,
        lastLocalVerificationAt: nil,
        nextDueAt: nil,
        lastFailure: nil,
        estimate: nil
    )
}

protocol BackupServicing: Sendable {
    func loadStatus() async throws -> AppBackupStatus
    func beginSetup(selectedParent: URL) async throws -> String
    func completeSetup(recoveryCodeReentry: String, independentlySaved: Bool) async throws
    func cancelSetup() async
    func resumePending(recoveryCode: String) async throws
    func abandonPending() async throws
    func setAutomaticBackupEnabled(_ enabled: Bool) async throws -> BackupSchedulerOutcome
    func setRetentionCount(_ count: Int) async throws
    func backUpNow() async throws -> BackupCleanupOutcome
    func showBackupRepository() async throws
    func handleSchedulerEvent(_ event: BackupSchedulerEvent) async throws -> BackupSchedulerOutcome
    func cancelForApplicationTermination() async
}

protocol BackupRepositoryOpening: Sendable {
    func open(_ url: URL) async -> Bool
}

struct SystemBackupRepositoryOpener: BackupRepositoryOpening {
    func open(_ url: URL) async -> Bool {
        await MainActor.run {
            NSWorkspace.shared.open(url)
        }
    }
}

extension BackupServicing {
    func cancelForApplicationTermination() async {}
}

protocol BackupSelectedDirectorySecurityScope: Sendable {
    func startAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
}

struct SystemBackupSelectedDirectorySecurityScope: BackupSelectedDirectorySecurityScope {
    func startAccessing(_ url: URL) -> Bool {
        url.startAccessingSecurityScopedResource()
    }

    func stopAccessing(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }
}

/// Production bridge for one app lifetime. It owns the stable U5 coordinator;
/// every directory operation resolves the stored bookmark and keeps the
/// security scope open until its async writer/reader work has finished.
actor LiveBackupService: BackupServicing {
    let operationCoordinator: BackupOperationCoordinator
    let configurationStore: BackupLocalConfigurationStore

    private let activeVaultURL: URL
    private let setupService: BackupSetupService
    private let destinationAuthority: BackupDestinationAuthority
    private let source: PlaintextLibraryBackupSource
    private let scheduler: BackupScheduler
    private let selectedDirectoryScope: any BackupSelectedDirectorySecurityScope
    private let requiresSelectedDirectoryScope: Bool
    private let bookmarkRefreshObserver: BookmarkRefreshObserver
    private let repositoryOpener: any BackupRepositoryOpening
    private let clock: @Sendable () -> Date
    private var setupSession: BackupSetupSession?
    #if DEBUG
    private var sourcePreparationCount = 0
    #endif

    init(
        activeVaultURL: URL,
        configurationStore: BackupLocalConfigurationStore,
        vault: PlaintextVault,
        inboxStore: PlaintextLANInboxStore? = nil,
        requiresSelectedDirectoryScope: Bool,
        destinationAuthority: BackupDestinationAuthority = BackupDestinationAuthority(),
        selectedDirectoryScope: any BackupSelectedDirectorySecurityScope =
            SystemBackupSelectedDirectorySecurityScope(),
        repositoryOpener: any BackupRepositoryOpening = SystemBackupRepositoryOpener(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        self.activeVaultURL = activeVaultURL.standardizedFileURL
        self.configurationStore = configurationStore
        self.destinationAuthority = destinationAuthority
        self.selectedDirectoryScope = selectedDirectoryScope
        self.requiresSelectedDirectoryScope = requiresSelectedDirectoryScope
        self.repositoryOpener = repositoryOpener
        self.clock = clock
        if let inboxStore {
            source = try PlaintextLibraryBackupSource(vault: vault, inboxStore: inboxStore)
        } else {
            source = try PlaintextLibraryBackupSource(
                vault: vault,
                deferredInboxRootURL: activeVaultURL
            )
        }
        setupService = BackupSetupService(
            configurationStore: configurationStore,
            destinationAuthority: destinationAuthority
        )
        let refreshObserver = BookmarkRefreshObserver()
        bookmarkRefreshObserver = refreshObserver

        let checkpointCreator = BookmarkScopedCheckpointCreator(
            authority: destinationAuthority,
            source: source,
            configurationStore: configurationStore,
            bookmarkRefreshObserver: refreshObserver
        )
        let retention = BookmarkScopedRetentionExecutor(
            authority: destinationAuthority,
            configurationStore: configurationStore,
            bookmarkRefreshObserver: refreshObserver
        )
        let coordinator = BackupOperationCoordinator(
            configurationStore: configurationStore,
            checkpointCreator: checkpointCreator,
            retentionExecutor: retention
        )
        operationCoordinator = coordinator
        scheduler = BackupScheduler(
            configurationStore: configurationStore,
            automaticRunner: coordinator
        )
    }

    func loadStatus() async throws -> AppBackupStatus {
        guard let configuration = try await configurationStore.load() else {
            return .notConfigured
        }
        let enrollment: AppBackupEnrollmentState = configuration.phase == .pending
            ? .pending
            : .ready
        var destinationName: String?
        var destinationFailure: BackupSemanticError?
        do {
            let resolved = try destinationAuthority.withResolvedDestination(
                selection(for: configuration)
            ) { repositoryURL in
                repositoryURL.deletingLastPathComponent().lastPathComponent
            }
            destinationName = resolved.value
            if let refreshed = resolved.refreshedBookmarkData,
               configuration.phase == .enabled {
                await bookmarkRefreshObserver.record(refreshed)
                try await persistObservedBookmarkRefresh()
            }
        } catch {
            destinationFailure = Self.mapDestinationError(error)
        }

        let now = clock()
        let localState: BackupLocalCheckpointState
        if configuration.scheduler.lastLocalVerificationAt == nil {
            localState = .unavailable
        } else if configuration.scheduler.dueAt.map({ $0 <= now }) == true
                    || configuration.scheduler.lastFailure != nil {
            localState = .overdue
        } else {
            localState = .verified
        }
        return .init(
            enrollment: enrollment,
            destinationDisplayName: destinationName,
            isAutomaticBackupEnabled: configuration.automation.isAutomaticBackupEnabled,
            retentionCount: configuration.automation.retentionCount.value,
            localCheckpointState: localState,
            lastLocalVerificationAt: configuration.scheduler.lastLocalVerificationAt,
            nextDueAt: configuration.scheduler.retryDueAt ?? configuration.scheduler.dueAt,
            lastFailure: destinationFailure ?? configuration.scheduler.lastFailure,
            // A status refresh must stay metadata-only. Computing this value
            // requires freezing and enumerating the complete library source;
            // the real backup path still computes the authoritative plan.
            estimate: nil
        )
    }

    func beginSetup(selectedParent: URL) async throws -> String {
        if requiresSelectedDirectoryScope {
            guard selectedDirectoryScope.startAccessing(selectedParent) else {
                throw BackupDestinationAuthorityError.securityScopeUnavailable
            }
        }
        defer {
            if requiresSelectedDirectoryScope {
                selectedDirectoryScope.stopAccessing(selectedParent)
            }
        }
        let session = try await setupService.begin(
            selectedParent: selectedParent,
            activeVaultURL: activeVaultURL
        )
        setupSession = session
        return session.recoveryCode
    }

    func completeSetup(
        recoveryCodeReentry: String,
        independentlySaved: Bool
    ) async throws {
        guard let setupSession else { throw BackupSetupError.noPendingEnrollment }
        _ = try await setupService.complete(
            setupSession,
            recoveryCodeReentry: recoveryCodeReentry,
            independentlySaved: independentlySaved
        )
        self.setupSession = nil
    }

    func cancelSetup() async {
        setupSession = nil
    }

    func resumePending(recoveryCode: String) async throws {
        setupSession = nil
        _ = try await setupService.resumePending(recoveryCode: recoveryCode)
    }

    func abandonPending() async throws {
        setupSession = nil
        try await setupService.abandonPending()
    }

    func setAutomaticBackupEnabled(_ enabled: Bool) async throws -> BackupSchedulerOutcome {
        guard enabled else {
            return try await scheduler.disableAutomaticBackup()
        }
        let pair = try await prepareSource().revisionPair
        return try await scheduler.setAutomaticBackupEnabled(
            true,
            currentPair: pair,
            at: clock()
        )
    }

    func setRetentionCount(_ count: Int) async throws {
        try await scheduler.setRetentionCount(try BackupRetentionCount(count))
    }

    func backUpNow() async throws -> BackupCleanupOutcome {
        try await refreshDestinationBookmarkIfNeeded()
        do {
            let result = try await operationCoordinator.backUpNow().cleanup
            try await persistObservedBookmarkRefresh()
            return result
        } catch {
            try? await persistObservedBookmarkRefresh()
            throw error
        }
    }

    func showBackupRepository() async throws {
        guard let configuration = try await configurationStore.load(),
              configuration.phase == .enabled else {
            throw BackupSemanticError.notConfigured
        }
        let result = try await destinationAuthority.withResolvedDestination(
            selection(for: configuration)
        ) { [repositoryOpener] repositoryURL in
            await repositoryOpener.open(repositoryURL)
        }
        if let refreshed = result.refreshedBookmarkData {
            await bookmarkRefreshObserver.record(refreshed)
            try await persistObservedBookmarkRefresh()
        }
        guard result.value else { throw BackupSemanticError.repositoryOffline }
    }

    func cancelForApplicationTermination() async {
        await operationCoordinator.cancelForApplicationTermination()
    }

    func handleSchedulerEvent(
        _ event: BackupSchedulerEvent
    ) async throws -> BackupSchedulerOutcome {
        guard let configuration = try await configurationStore.load(),
              configuration.phase == .enabled else { return .disabled }
        guard configuration.automation.isAutomaticBackupEnabled else { return .disabled }
        let eventDate = clock()
        do {
            try await refreshDestinationBookmarkIfNeeded()
        } catch let error as BackupDestinationAuthorityError
            where error == .repositoryOffline {
            return try await scheduler.recordDestinationOffline(at: eventDate)
        }
        let pair = try await prepareSource().revisionPair
        do {
            let outcome = try await scheduler.handle(
                event,
                currentPair: pair,
                at: eventDate
            )
            try await persistObservedBookmarkRefresh()
            return outcome
        } catch {
            try? await persistObservedBookmarkRefresh()
            throw error
        }
    }

    private func refreshDestinationBookmarkIfNeeded() async throws {
        guard let configuration = try await configurationStore.load(),
              configuration.phase == .enabled else { return }
        let result = try destinationAuthority.withResolvedDestination(
            selection(for: configuration)
        ) { _ in () }
        guard let refreshed = result.refreshedBookmarkData else { return }
        _ = try await configurationStore.refreshEnabledBookmark(
            refreshed,
            expectedRevision: configuration.revision
        )
    }

    private func persistObservedBookmarkRefresh() async throws {
        guard let refreshed = await bookmarkRefreshObserver.takeLatest(),
              let current = try await configurationStore.load(),
              current.phase == .enabled,
              current.bookmarkData != refreshed else { return }
        _ = try await configurationStore.refreshEnabledBookmark(
            refreshed,
            expectedRevision: current.revision
        )
    }

    private func prepareSource() async throws -> PlaintextLibraryBackupPlan {
        #if DEBUG
        sourcePreparationCount += 1
        #endif
        return try await source.prepare()
    }

    #if DEBUG
    func sourcePreparationCountForTesting() -> Int {
        sourcePreparationCount
    }
    #endif

    fileprivate static func mapDestinationError(_ error: Error) -> BackupSemanticError {
        guard let error = error as? BackupDestinationAuthorityError else {
            return .verificationFailed
        }
        switch error {
        case .bookmarkInvalid, .securityScopeUnavailable:
            return .bookmarkNeedsReselection
        case .identityChanged, .repositoryIdentityConflict:
            return .repositoryIdentityConflict
        case .repositoryOffline, .readOnly:
            return .repositoryOffline
        default:
            return .verificationFailed
        }
    }
}

private func selection(
    for configuration: BackupLocalConfiguration
) -> BackupDestinationSelection {
    .init(
        repositoryURL: URL(fileURLWithPath: "/", isDirectory: true),
        bookmarkData: configuration.bookmarkData,
        selectedDirectoryIdentity: configuration.selectedDirectoryIdentity,
        repositoryDirectoryIdentity: configuration.repositoryDirectoryIdentity
    )
}

private func makeRepository(
    at repositoryURL: URL,
    configuration: BackupLocalConfiguration,
    configurationStore: BackupLocalConfigurationStore
) -> BackupRepository {
    BackupRepository(
        repositoryURL: repositoryURL,
        expectedIdentity: configuration.repositoryDirectoryIdentity,
        trustedDescriptor: configuration.descriptor,
        expectedAuthorizationID: configuration.authorization.authorizationID,
        leaseAuthority: .init(
            configurationRootURL: configurationStore.rootURL,
            configuration: configuration
        )
    )
}

private struct BookmarkScopedCheckpointCreator: BackupCheckpointCreating {
    let authority: BackupDestinationAuthority
    let source: PlaintextLibraryBackupSource
    let configurationStore: BackupLocalConfigurationStore
    let bookmarkRefreshObserver: BookmarkRefreshObserver

    func createCheckpoint(
        configuration: BackupLocalConfiguration
    ) async throws -> BackupCheckpointCreation {
        let result = try await authority.withResolvedDestination(selection(for: configuration)) { repositoryURL in
            let writer = EncryptedCheckpointWriter(
                source: source,
                configurationStore: configurationStore
            )
            let repository = makeRepository(
                at: repositoryURL,
                configuration: configuration,
                configurationStore: configurationStore
            )
            let result = try await BackupCheckpointPublisher(
                repository: repository,
                writer: writer,
                configurationStore: configurationStore
            ).publishNext(
                configuration: configuration
            )
            return BackupCheckpointCreation(revisionPair: result.revisionPair)
        }
        if let refreshed = result.refreshedBookmarkData {
            await bookmarkRefreshObserver.record(refreshed)
        }
        return result.value
    }
}

private struct BookmarkScopedRetentionExecutor: BackupRetentionExecuting {
    let authority: BackupDestinationAuthority
    let configurationStore: BackupLocalConfigurationStore
    let bookmarkRefreshObserver: BookmarkRefreshObserver

    func applyRetention(
        configuration: BackupLocalConfiguration,
        now: Date
    ) async -> BackupCleanupOutcome {
        do {
            let result = try await authority.withResolvedDestination(
                selection(for: configuration)
            ) { repositoryURL in
                let repository = makeRepository(
                    at: repositoryURL,
                    configuration: configuration,
                    configurationStore: configurationStore
                )
                let executor = BackupRetentionExecutor(
                    repository: repository,
                    configurationStore: configurationStore
                )
                return await LocalDirectoryRetentionAdapter(executor: executor)
                    .applyRetention(configuration: configuration, now: now)
            }
            if let refreshed = result.refreshedBookmarkData {
                await bookmarkRefreshObserver.record(refreshed)
            }
            return result.value
        } catch {
            return .deferred(LiveBackupService.mapDestinationError(error))
        }
    }
}

private actor BookmarkRefreshObserver {
    private var latest: Data?

    func record(_ bookmarkData: Data) {
        latest = bookmarkData
    }

    func takeLatest() -> Data? {
        defer { latest = nil }
        return latest
    }
}
