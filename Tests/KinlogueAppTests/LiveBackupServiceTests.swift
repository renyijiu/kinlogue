import Foundation
import KinlogueCore
@testable import KinloguePlatform
import Testing
@testable import KinlogueApp

@Test
@MainActor
func reauthorizingTheOriginalFolderPreservesWriterAndRejectsOtherDirectories() async throws {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("KinlogueReauthorization-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let selected = base.appendingPathComponent("selected", isDirectory: true)
    let other = base.appendingPathComponent("other", isDirectory: true)
    let vaultURL = base.appendingPathComponent("support/Vault", isDirectory: true)
    for url in [selected, other, vaultURL] {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    let bookmarks = LiveBackupMutableBookmarks(resolvedURL: selected)
    let store = BackupLocalConfigurationStore(rootURL: base.appendingPathComponent("support/BackupIdentity"))
    let service = try LiveBackupService(
        activeVaultURL: vaultURL, configurationStore: store,
        vault: PlaintextVault(rootURL: vaultURL),
        requiresSelectedDirectoryScope: true,
        destinationAuthority: BackupDestinationAuthority(bookmarks: bookmarks),
        selectedDirectoryScope: bookmarks
    )
    let code = try await service.beginSetup(selectedParent: selected)
    try await service.completeSetup(recoveryCodeReentry: code, independentlySaved: true)
    let original = try #require(await store.load())
    bookmarks.invalidBookmark = original.bookmarkData
    bookmarks.createdBookmark = Data("reauthorized-bookmark".utf8)
    #expect(try await service.loadStatus().lastFailure == .bookmarkNeedsReselection)

    await #expect(throws: BackupDestinationAuthorityError.repositoryIdentityConflict) {
        try await service.reauthorizeDestination(selectedParent: other)
    }
    #expect(try await store.load() == original)
    #expect(try FileManager.default.contentsOfDirectory(atPath: other.path).isEmpty)

    let model = BackupModel(service: service)
    await model.refresh()
    await model.beginSetup(selectedParent: selected)
    let updated = try #require(await store.load())
    #expect(updated.writerIdentity == original.writerIdentity)
    #expect(updated.scheduler == original.scheduler)
    #expect(updated.automation == original.automation)
    #expect(updated.verificationWitnesses == original.verificationWitnesses)
    #expect(updated.bookmarkData == bookmarks.createdBookmark)
    #expect(model.phase == .ready)
    #expect(model.failure == nil)
    #expect(model.recoveryCode == nil)
    #expect(try await BackupLocalConfigurationStore(rootURL: store.rootURL).load() == updated)

    let repository = selected.appendingPathComponent(BackupDestinationAuthority.repositoryDirectoryName)
    try FileManager.default.moveItem(at: repository, to: selected.appendingPathComponent("parked"))
    try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: false,
                                          attributes: [.posixPermissions: 0o700])
    await #expect(throws: BackupDestinationAuthorityError.repositoryIdentityConflict) {
        try await service.reauthorizeDestination(selectedParent: selected)
    }
    #expect(try await store.load() == updated)
    #expect(bookmarks.startCount == bookmarks.stopCount)
}

@Test
func loadingBackupStatusNeverPreparesOrEnumeratesTheLibrarySource() async throws {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("KinlogueLiveBackupStatusCost-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let selected = base.appendingPathComponent("selected", isDirectory: true)
    let vaultURL = base.appendingPathComponent("support/Kinlogue/Vault", isDirectory: true)
    try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
    let vault = try PlaintextVault(rootURL: vaultURL)
    let inbox = try PlaintextLANInboxStore(rootURL: vaultURL)
    _ = try await vault.initialize()
    _ = try await inbox.initialize()

    let store = BackupLocalConfigurationStore(
        rootURL: base.appendingPathComponent("support/Kinlogue/BackupIdentity", isDirectory: true)
    )
    let service = try LiveBackupService(
        activeVaultURL: vaultURL,
        configurationStore: store,
        vault: vault,
        inboxStore: inbox,
        requiresSelectedDirectoryScope: false,
        destinationAuthority: BackupDestinationAuthority(
            bookmarks: LiveBackupMutableBookmarks(resolvedURL: selected)
        )
    )
    let code = try await service.beginSetup(selectedParent: selected)
    try await service.completeSetup(recoveryCodeReentry: code, independentlySaved: true)

    let status = try await service.loadStatus()

    #expect(status.estimate == nil)
    #expect(await service.sourcePreparationCountForTesting() == 0)
    _ = try await service.setAutomaticBackupEnabled(true)
    #expect(await service.sourcePreparationCountForTesting() == 1)
    _ = try await service.setAutomaticBackupEnabled(false)
    #expect(await service.sourcePreparationCountForTesting() == 1)
    // Exercise the actual writer witness and retention clock together.
    #expect(try await service.backUpNow() == .complete)
}

@Test
func liveStatusPersistsAStaleBookmarkSoTheRefreshedGrantSurvivesRelaunch() async throws {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("KinlogueLiveBackup-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let selected = base.appendingPathComponent("selected", isDirectory: true)
    let vaultURL = base.appendingPathComponent("support/Kinlogue/Vault", isDirectory: true)
    try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)

    let bookmarks = LiveBackupMutableBookmarks(resolvedURL: selected)
    let authority = BackupDestinationAuthority(bookmarks: bookmarks)
    let storeRoot = base.appendingPathComponent(
        "support/Kinlogue/BackupIdentity",
        isDirectory: true
    )
    let store = BackupLocalConfigurationStore(rootURL: storeRoot)
    let service = try LiveBackupService(
        activeVaultURL: vaultURL,
        configurationStore: store,
        vault: PlaintextVault(rootURL: vaultURL),
        inboxStore: PlaintextLANInboxStore(rootURL: vaultURL),
        requiresSelectedDirectoryScope: false,
        destinationAuthority: authority
    )
    let code = try await service.beginSetup(selectedParent: selected)
    try await service.completeSetup(
        recoveryCodeReentry: code,
        independentlySaved: true
    )
    #expect(try await store.load()?.bookmarkData == Data("bookmark".utf8))

    bookmarks.stale = true
    _ = try await service.loadStatus()

    let relaunchedStore = BackupLocalConfigurationStore(rootURL: storeRoot)
    #expect(try await relaunchedStore.load()?.bookmarkData == Data("refreshed-bookmark".utf8))
    #expect(bookmarks.startCount == bookmarks.stopCount)
}

@Test
func showingBackupRepositoryOpensTheExactHiddenRepositoryWithBalancedScope() async throws {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("KinlogueLiveBackupReveal-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let selected = base.appendingPathComponent("selected", isDirectory: true)
    let vaultURL = base.appendingPathComponent("support/Kinlogue/Vault", isDirectory: true)
    try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)

    let bookmarks = LiveBackupMutableBookmarks(resolvedURL: selected)
    let opener = LiveBackupRepositoryOpener()
    let authority = BackupDestinationAuthority(bookmarks: bookmarks)
    let store = BackupLocalConfigurationStore(
        rootURL: base.appendingPathComponent("support/Kinlogue/BackupIdentity", isDirectory: true)
    )
    let service = try LiveBackupService(
        activeVaultURL: vaultURL,
        configurationStore: store,
        vault: PlaintextVault(rootURL: vaultURL),
        inboxStore: PlaintextLANInboxStore(rootURL: vaultURL),
        requiresSelectedDirectoryScope: false,
        destinationAuthority: authority,
        repositoryOpener: opener
    )
    let code = try await service.beginSetup(selectedParent: selected)
    try await service.completeSetup(recoveryCodeReentry: code, independentlySaved: true)
    bookmarks.stale = true

    try await service.showBackupRepository()

    #expect(await opener.openedURLs == [
        selected.appendingPathComponent(
            BackupDestinationAuthority.repositoryDirectoryName,
            isDirectory: true
        )
    ])
    #expect(try await store.load()?.bookmarkData == Data("refreshed-bookmark".utf8))
    #expect(bookmarks.startCount == bookmarks.stopCount)
}

@Test
func failedRepositoryRevealReportsOfflineAndBalancesScope() async throws {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("KinlogueLiveBackupRevealFailure-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let selected = base.appendingPathComponent("selected", isDirectory: true)
    let vaultURL = base.appendingPathComponent("support/Kinlogue/Vault", isDirectory: true)
    try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)

    let bookmarks = LiveBackupMutableBookmarks(resolvedURL: selected)
    let opener = LiveBackupRepositoryOpener(result: false)
    let authority = BackupDestinationAuthority(bookmarks: bookmarks)
    let store = BackupLocalConfigurationStore(
        rootURL: base.appendingPathComponent("support/Kinlogue/BackupIdentity", isDirectory: true)
    )
    let service = try LiveBackupService(
        activeVaultURL: vaultURL,
        configurationStore: store,
        vault: PlaintextVault(rootURL: vaultURL),
        inboxStore: PlaintextLANInboxStore(rootURL: vaultURL),
        requiresSelectedDirectoryScope: false,
        destinationAuthority: authority,
        repositoryOpener: opener
    )
    let code = try await service.beginSetup(selectedParent: selected)
    try await service.completeSetup(recoveryCodeReentry: code, independentlySaved: true)

    await #expect(throws: BackupSemanticError.repositoryOffline) {
        try await service.showBackupRepository()
    }

    #expect(bookmarks.startCount == bookmarks.stopCount)
}

@Test
func automaticBackupPersistsRetryWhenDestinationIsOfflineBeforeSchedulerEntry() async throws {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("KinlogueLiveBackupOfflineRetry-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let selected = base.appendingPathComponent("selected", isDirectory: true)
    let parked = base.appendingPathComponent("selected-offline", isDirectory: true)
    let vaultURL = base.appendingPathComponent("support/Kinlogue/Vault", isDirectory: true)
    try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)

    let vault = try PlaintextVault(rootURL: vaultURL)
    let inbox = try PlaintextLANInboxStore(rootURL: vaultURL)
    _ = try await vault.initialize()
    _ = try await inbox.initialize()
    let bookmarks = LiveBackupMutableBookmarks(resolvedURL: selected)
    let start = Date(timeIntervalSince1970: 100_000)
    let clock = LiveBackupTestClock(start)
    let store = BackupLocalConfigurationStore(
        rootURL: base.appendingPathComponent("support/Kinlogue/BackupIdentity", isDirectory: true)
    )
    let service = try LiveBackupService(
        activeVaultURL: vaultURL,
        configurationStore: store,
        vault: vault,
        inboxStore: inbox,
        requiresSelectedDirectoryScope: false,
        destinationAuthority: BackupDestinationAuthority(bookmarks: bookmarks),
        clock: { clock.now() }
    )
    let code = try await service.beginSetup(selectedParent: selected)
    try await service.completeSetup(recoveryCodeReentry: code, independentlySaved: true)
    let initialDue = start.addingTimeInterval(BackupScheduler.quietPeriod)
    #expect(try await service.setAutomaticBackupEnabled(true) == .scheduled(initialDue))

    try FileManager.default.moveItem(at: selected, to: parked)
    let outcome = try await service.handleSchedulerEvent(.activation)

    guard case .retryScheduled(let dueAt) = outcome else {
        Issue.record("Expected an automatic offline retry, got \(outcome)")
        return
    }
    let persisted = try #require(await store.load())
    #expect(persisted.scheduler.lastFailure == .repositoryOffline)
    #expect(persisted.scheduler.mutationRetryAttempt == 1)
    #expect(persisted.scheduler.retryDueAt == dueAt)
    #expect(bookmarks.startCount == bookmarks.stopCount)

    clock.set(start.addingTimeInterval(60))
    let relaunched = try LiveBackupService(
        activeVaultURL: vaultURL,
        configurationStore: BackupLocalConfigurationStore(rootURL: store.rootURL),
        vault: vault,
        inboxStore: inbox,
        requiresSelectedDirectoryScope: false,
        destinationAuthority: BackupDestinationAuthority(bookmarks: bookmarks),
        clock: { clock.now() }
    )
    #expect(try await relaunched.handleSchedulerEvent(.startup) == .retryScheduled(initialDue))
    #expect(try await store.load()?.scheduler.mutationRetryAttempt == 1)

    try FileManager.default.moveItem(at: parked, to: selected)
    clock.set(initialDue)
    #expect(try await relaunched.handleSchedulerEvent(.wake) == .completed)
    let completed = try #require(await store.load())
    #expect(completed.scheduler.lastFailure == nil)
    #expect(completed.scheduler.mutationRetryAttempt == 0)
    #expect(completed.scheduler.retryDueAt == nil)
    #expect(completed.scheduler.lastCoveredRevisionPair != nil)
}

@Test
@MainActor
func relaunchedModelResumesPersistedPendingEnrollmentWithTheOriginalRecoveryCode() async throws {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("KinlogueLiveBackupPending-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let selected = base.appendingPathComponent("selected", isDirectory: true)
    let vaultURL = base.appendingPathComponent("support/Kinlogue/Vault", isDirectory: true)
    try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)

    let bookmarks = LiveBackupMutableBookmarks(resolvedURL: selected)
    let authority = BackupDestinationAuthority(bookmarks: bookmarks)
    let storeRoot = base.appendingPathComponent(
        "support/Kinlogue/BackupIdentity",
        isDirectory: true
    )
    let store = BackupLocalConfigurationStore(rootURL: storeRoot)
    let savedRecoveryCode: String
    let pending: BackupLocalConfiguration
    do {
        let failingPublisher = LiveBackupFailingEnrollmentPublisher(authority: authority)
        let setup = BackupSetupService(
            configurationStore: store,
            destinationAuthority: authority,
            enrollmentPublisher: failingPublisher
        )
        let session = try await setup.begin(selectedParent: selected, activeVaultURL: vaultURL)
        savedRecoveryCode = session.recoveryCode
        await #expect(throws: BackupDestinationAuthorityError.repositoryOffline) {
            _ = try await setup.complete(
                session,
                recoveryCodeReentry: session.recoveryCode,
                independentlySaved: true
            )
        }
        pending = try #require(await store.load())
    }
    #expect(pending.phase == .pending)

    let relaunchedService = try LiveBackupService(
        activeVaultURL: vaultURL,
        configurationStore: BackupLocalConfigurationStore(rootURL: storeRoot),
        vault: PlaintextVault(rootURL: vaultURL),
        inboxStore: PlaintextLANInboxStore(rootURL: vaultURL),
        requiresSelectedDirectoryScope: false,
        destinationAuthority: authority
    )
    let model = BackupModel(service: relaunchedService)
    await model.refresh()
    #expect(model.phase == .enrollmentPending)
    #expect(model.recoveryCode == nil)

    model.presentPendingEnrollmentRecovery()
    model.pendingEnrollmentRecoveryCode = savedRecoveryCode
    await model.resumePendingEnrollment()

    let enabled = try #require(await store.load())
    #expect(enabled.phase == .enabled)
    #expect(enabled.descriptor == pending.descriptor)
    #expect(enabled.authorization == pending.authorization)
    #expect(enabled.deviceSigningSeed == pending.deviceSigningSeed)
    #expect(enabled.enrollmentEpoch == pending.enrollmentEpoch)
    #expect(enabled.writerEpoch == pending.writerEpoch)
    #expect(model.phase == .ready)
    #expect(model.pendingEnrollmentRecoveryCode.isEmpty)
}

private final class LiveBackupMutableBookmarks: BackupBookmarkAccessing,
    BackupSelectedDirectorySecurityScope, @unchecked Sendable {
    let resolvedURL: URL
    var stale = false
    var invalidBookmark: Data?
    var createdBookmark = Data("bookmark".utf8)
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(resolvedURL: URL) {
        self.resolvedURL = resolvedURL
    }

    func createBookmark(for url: URL) throws -> Data {
        _ = url
        return createdBookmark
    }

    func resolveBookmark(_ data: Data) throws -> BackupResolvedBookmark {
        if data == invalidBookmark { throw BackupDestinationAuthorityError.bookmarkInvalid }
        return .init(url: resolvedURL, isStale: stale)
    }

    func refreshBookmark(for url: URL) throws -> Data {
        _ = url
        return Data("refreshed-bookmark".utf8)
    }

    func startAccessing(_ url: URL) -> Bool {
        _ = url
        startCount += 1
        return true
    }

    func stopAccessing(_ url: URL) {
        _ = url
        stopCount += 1
    }
}

private final class LiveBackupTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func now() -> Date {
        lock.withLock { value }
    }

    func set(_ value: Date) {
        lock.withLock { self.value = value }
    }
}

private final class LiveBackupFailingEnrollmentPublisher: BackupEnrollmentPublishing,
    @unchecked Sendable {
    let authority: BackupDestinationAuthority

    init(authority: BackupDestinationAuthority) {
        self.authority = authority
    }

    func publish(
        descriptor: BackupSetDescriptor,
        authorization: BackupDeviceAuthorization,
        selection: BackupDestinationSelection
    ) throws -> Data? {
        _ = descriptor
        _ = authorization
        _ = selection
        throw BackupDestinationAuthorityError.repositoryOffline
    }

    func publish(configuration: BackupLocalConfiguration) throws -> Data? {
        try authority.publishStoredEnrollment(configuration)
    }
}

private actor LiveBackupRepositoryOpener: BackupRepositoryOpening {
    private(set) var openedURLs: [URL] = []
    let result: Bool

    init(result: Bool = true) {
        self.result = result
    }

    func open(_ url: URL) async -> Bool {
        openedURLs.append(url)
        return result
    }
}

@Test
func sqliteLogicalLiveBackupAndRestoreServicesDrainBeforeClosingDatabase() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("KinlogueSQLiteLiveBackup-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let selected = base.appendingPathComponent("selected", isDirectory: true)
    try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: base.path)
    let root = base.appendingPathComponent("Vault")
    let owner = try SQLiteLibraryOwner(rootURL: root)
    let database = try SQLiteLibraryStore(owner: owner)
    defer { try? database.close() }
    let repository = SQLiteReportRepository(store: database)
    let member = try FamilyMember(displayName: "Synthetic captured service member")
    try await repository.saveMember(member, replacing: nil)
    let bookmarks = LiveBackupMutableBookmarks(resolvedURL: selected)
    let configuration = BackupLocalConfigurationStore(rootURL: base.appendingPathComponent("BackupIdentity"))
    let backup = LiveBackupService(store: database, configurationStore: configuration,
        requiresSelectedDirectoryScope: true, destinationAuthority: BackupDestinationAuthority(bookmarks: bookmarks), selectedDirectoryScope: bookmarks)
    let recoveryCode = try await backup.beginSetup(selectedParent: selected)
    try await backup.completeSetup(recoveryCodeReentry: recoveryCode, independentlySaved: true)
    _ = try await backup.backUpNow()
    let destination = selected.appendingPathComponent(BackupDestinationAuthority.repositoryDirectoryName)
    let checkpoint = try #require(FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil).first { $0.pathExtension == "kinloguebackup" })
    let later: FamilyMember = { var value = member; value.displayName = "Synthetic later service member"; return value }()
    try await repository.saveMember(later, replacing: member)
    let lifecycle = LibraryLifecycleCoordinator()
    let transaction = try BackupRestoreTransaction(owner: owner)
    let restore = BackupRestoreService(verifier: try BackupRestoreVerifier(owner: owner), transaction: transaction,
        configurationStore: configuration, operationCoordinator: await backup.operationCoordinator, lifecycle: lifecycle, database: database)
    let prepared = try await restore.prepare(checkpointURL: checkpoint, recoveryCode: recoveryCode)
    let (entered, enteredContinuation) = AsyncStream<Void>.makeStream()
    let (release, releaseContinuation) = AsyncStream<Void>.makeStream()
    let (revoked, revokedContinuation) = AsyncStream<Void>.makeStream()
    try await lifecycle.register(id: UUID()) {
        #expect((try? database.state()) != nil)
        revokedContinuation.yield(())
    }
    let active = Task {
        try await lifecycle.withActiveOperation { () async throws -> Void in
            enteredContinuation.yield(())
            for await _ in release { break }
            #expect(try await repository.member(member.id) == later)
        }
    }
    for await _ in entered { break }
    let activation = Task { try await restore.activateAfterConfirmation(prepared) }
    for await _ in revoked { break }
    #expect((try? database.state()) != nil)
    releaseContinuation.yield(())
    try await active.value
    #expect(try await activation.value.requiresApplicationRestart)
    #expect((try? database.state()) == nil)
    #expect(try await configuration.load() == nil)
    #expect(throws: SQLiteLibraryError.occupied) { _ = try SQLiteLibraryStore(rootURL: root) }
    #expect(try await transaction.reconcile() == .committed)
    let reopened = try SQLiteLibraryStore(owner: owner)
    defer { try? reopened.close() }
    #expect(try await SQLiteReportRepository(store: reopened).member(member.id) == member)
    #expect(bookmarks.startCount == bookmarks.stopCount)
}
