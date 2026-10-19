import Foundation
import KinlogueCore
@testable import KinloguePlatform
import Testing
import ZIPFoundation
@testable import KinlogueApp

@Suite("Live backup service", .serialized)
struct LiveBackupServiceTests {
    @Test
    func choosingAFolderNeedsItsScopeAndRefusesTheLibraryItself() async throws {
        let fixture = try await LiveBackupFixture.make()
        defer { fixture.remove() }
        let service = fixture.service(requiresScope: true)

        await #expect(throws: BackupFolderError.forbiddenVaultRelationship) {
            try await service.chooseFolder(fixture.vaultURL)
        }
        try await service.chooseFolder(fixture.selected)
        let settings = try fixture.settings.load()
        #expect(settings.folder?.bookmarkData == Data("bookmark".utf8))
        #expect(settings.isAutomaticBackupEnabled == false)
        #expect(try await service.loadStatus().folderName == "selected")
        #expect(fixture.bookmarks.startCount == fixture.bookmarks.stopCount)
    }

    @Test
    func statusNeverReadsTheLibraryAndOnlyEnablingDoes() async throws {
        let fixture = try await LiveBackupFixture.make()
        defer { fixture.remove() }
        let service = fixture.service()
        try await service.chooseFolder(fixture.selected)

        _ = try await service.loadStatus()
        #expect(await service.sourceRevisionReadCountForTesting() == 0)
        _ = try await service.setAutomaticBackupEnabled(true)
        #expect(await service.sourceRevisionReadCountForTesting() == 1)
        _ = try await service.setAutomaticBackupEnabled(false)
        #expect(await service.sourceRevisionReadCountForTesting() == 1)
    }

    @Test
    func backupsLandInTheFolderAndRetentionDeletesOnlyThisMacsUnchangedOnes() async throws {
        let fixture = try await LiveBackupFixture.make()
        defer { fixture.remove() }
        let service = fixture.service()
        try await service.chooseFolder(fixture.selected)
        try await service.setRetentionCount(2)

        let first = try await service.backUpNow()
        fixture.clock.advance(1)
        let second = try await service.backUpNow()
        // The person renames the second backup; it is theirs from now on.
        try FileManager.default.moveItem(at: fixture.selected.appendingPathComponent(second.fileName),
                                         to: fixture.selected.appendingPathComponent("Mine.zip"))
        try Data("unrelated".utf8).write(to: fixture.selected.appendingPathComponent("notes.txt"))
        fixture.clock.advance(1)
        let third = try await service.backUpNow()
        fixture.clock.advance(1)
        let fourth = try await service.backUpNow()

        #expect(!fourth.cleanupDeferred)
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.selected.path).sorted()
        #expect(names == [third.fileName, fourth.fileName, "Mine.zip", "notes.txt"].sorted())
        #expect(!names.contains(first.fileName))
        let status = try await service.loadStatus()
        #expect(status.managedBackupCount == 2 && status.lastBackupFileName == fourth.fileName)
        #expect(status.lastBackupAt == fourth.completedAt && status.lastFailure == nil)
        let archive = try Archive(url: fixture.selected.appendingPathComponent(fourth.fileName), accessMode: .read)
        #expect(archive[BackupArchiveIndex.fileName] != nil)
        #expect(fourth.fileName.hasPrefix(BackupArchiveText.fileNameStem(fixture.clock.start.addingTimeInterval(3))))
        #expect(fixture.bookmarks.startCount == fixture.bookmarks.stopCount)
    }

    @Test
    func aStaleBookmarkIsRefreshedAndSurvivesARelaunch() async throws {
        let fixture = try await LiveBackupFixture.make()
        defer { fixture.remove() }
        let service = fixture.service()
        try await service.chooseFolder(fixture.selected)
        fixture.bookmarks.stale = true
        fixture.bookmarks.createdBookmark = Data("refreshed-bookmark".utf8)

        _ = try await service.loadStatus()

        #expect(try BackupSettingsStore(rootURL: fixture.settings.rootURL).load().folder?.bookmarkData
            == Data("refreshed-bookmark".utf8))
        #expect(fixture.bookmarks.startCount == fixture.bookmarks.stopCount)
    }

    @Test
    func showingTheFolderOpensItWithBalancedScope() async throws {
        let fixture = try await LiveBackupFixture.make()
        defer { fixture.remove() }
        let opener = LiveBackupFolderOpener()
        let service = fixture.service(opener: opener)
        try await service.chooseFolder(fixture.selected)

        try await service.showFolder()
        #expect(await opener.openedURLs == [fixture.selected])

        await opener.setResult(false)
        await #expect(throws: BackupFailure.folderUnavailable) { try await service.showFolder() }
        #expect(fixture.bookmarks.startCount == fixture.bookmarks.stopCount)
    }

    @Test
    func aFolderThatIsGoneBeforeTheSchedulerRunsGetsADurableRetry() async throws {
        let fixture = try await LiveBackupFixture.make()
        defer { fixture.remove() }
        let service = fixture.service()
        try await service.chooseFolder(fixture.selected)
        let due = fixture.clock.start.addingTimeInterval(BackupScheduler.quietPeriod)
        #expect(try await service.setAutomaticBackupEnabled(true) == .scheduled(due))

        let parked = fixture.base.appendingPathComponent("parked", isDirectory: true)
        try FileManager.default.moveItem(at: fixture.selected, to: parked)
        let outcome = try await service.handleSchedulerEvent(.activation)
        #expect(outcome == .retryScheduled(due))
        let persisted = try fixture.settings.load()
        #expect(persisted.scheduler.lastFailure == .folderUnavailable && persisted.scheduler.retryAttempt == 1)
        #expect(try await service.loadStatus().lastFailure == .folderUnavailable)

        fixture.clock.set(fixture.clock.start.addingTimeInterval(60))
        let relaunched = fixture.service()
        #expect(try await relaunched.handleSchedulerEvent(.startup) == .retryScheduled(due))

        try FileManager.default.moveItem(at: parked, to: fixture.selected)
        fixture.clock.set(due)
        #expect(try await relaunched.handleSchedulerEvent(.wake) == .completed)
        let completed = try fixture.settings.load()
        #expect(completed.scheduler.lastFailure == nil && completed.scheduler.retryAttempt == 0)
        #expect(completed.scheduler.lastCoveredRevision != nil && completed.ledger.count == 1)
        #expect(fixture.bookmarks.startCount == fixture.bookmarks.stopCount)
    }

    @Test
    func aReplacedFolderNeedsToBeChosenAgain() async throws {
        let fixture = try await LiveBackupFixture.make()
        defer { fixture.remove() }
        let service = fixture.service()
        try await service.chooseFolder(fixture.selected)
        try FileManager.default.moveItem(at: fixture.selected, to: fixture.base.appendingPathComponent("moved"))
        try FileManager.default.createDirectory(at: fixture.selected, withIntermediateDirectories: false)

        #expect(try await service.loadStatus().lastFailure == .folderNeedsReselection)
        await #expect(throws: BackupFailure.folderNeedsReselection) { _ = try await service.backUpNow() }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.selected.path).isEmpty)
    }

    @Test
    func aRenumberedVolumeStillNamesTheSameFolder() async throws {
        let fixture = try await LiveBackupFixture.make()
        defer { fixture.remove() }
        try await fixture.service().chooseFolder(fixture.selected)
        // macOS may give a volume another device number after a restart or an update.
        try fixture.settings.update { settings in
            guard let folder = settings.folder else { throw BackupFailure.notConfigured }
            settings.folder = try BackupFolderSelection(
                bookmarkData: folder.bookmarkData,
                identity: .init(device: folder.identity.device + 3, inode: folder.identity.inode)
            )
        }
        let relaunched = fixture.service()
        #expect(try await relaunched.loadStatus().lastFailure == nil)
        _ = try await relaunched.backUpNow()
        #expect(try fixture.settings.load().ledger.count == 1)
    }
}

@Test
func liveBackupAndRestoreDrainBeforeClosingTheDatabase() async throws {
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
    let settings = BackupSettingsStore(rootURL: base.appendingPathComponent("Backup"))
    let lifecycle = LibraryLifecycleCoordinator()
    let backup = LiveBackupService(store: database, settingsStore: settings, lifecycle: lifecycle,
        requiresSelectedDirectoryScope: true, authority: BackupFolderAuthority(bookmarks: bookmarks), selectedDirectoryScope: bookmarks)
    try await backup.chooseFolder(selected)
    _ = try await backup.setAutomaticBackupEnabled(true)
    let written = try await backup.backUpNow()
    let archiveURL = selected.appendingPathComponent(written.fileName)
    let later: FamilyMember = { var value = member; value.displayName = "Synthetic later service member"; return value }()
    try await repository.saveMember(later, replacing: member)
    let transaction = try BackupRestoreTransaction(owner: owner)
    let restore = BackupRestoreService(verifier: try BackupRestoreVerifier(owner: owner), transaction: transaction,
        settingsStore: settings, operationCoordinator: await backup.operationCoordinator, lifecycle: lifecycle, database: database)
    let prepared = try await restore.prepare(archiveURL: archiveURL)
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
    // The folder and its ledger stay; automatic backup waits for the person.
    let after = try settings.load()
    #expect(after.folder != nil && after.ledger.count == 1 && !after.isAutomaticBackupEnabled)
    #expect(throws: SQLiteLibraryError.occupied) { _ = try SQLiteLibraryStore(rootURL: root) }
    #expect(try await transaction.reconcile() == .committed)
    let reopened = try SQLiteLibraryStore(owner: owner)
    defer { try? reopened.close() }
    #expect(try await SQLiteReportRepository(store: reopened).member(member.id) == member)
    #expect(bookmarks.startCount == bookmarks.stopCount)
}

// MARK: - Fixtures

private struct LiveBackupFixture {
    let base: URL
    let selected: URL
    let vaultURL: URL
    let library: SQLiteLibraryStore
    let settings: BackupSettingsStore
    let bookmarks: LiveBackupMutableBookmarks
    let clock: LiveBackupTestClock
    let lifecycle = LibraryLifecycleCoordinator()

    static func make() async throws -> Self {
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("KinlogueLiveBackup-\(UUID().uuidString)", isDirectory: true)
        let selected = base.appendingPathComponent("selected", isDirectory: true)
        let vaultURL = base.appendingPathComponent("support/Kinlogue/Vault", isDirectory: true)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: vaultURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let library = try SQLiteLibraryStore(rootURL: vaultURL)
        try await SQLiteReportRepository(store: library).saveMember(try FamilyMember(displayName: "Synthetic member"), replacing: nil)
        return Self(
            base: base, selected: selected, vaultURL: vaultURL, library: library,
            settings: BackupSettingsStore(rootURL: vaultURL.deletingLastPathComponent().appendingPathComponent("Backup", isDirectory: true)),
            bookmarks: LiveBackupMutableBookmarks(resolvedURL: selected),
            clock: LiveBackupTestClock(Date(timeIntervalSince1970: 1_800_000_000))
        )
    }

    func service(requiresScope: Bool = false, opener: any BackupFolderOpening = LiveBackupFolderOpener()) -> LiveBackupService {
        let clock = self.clock
        return LiveBackupService(
            store: library, settingsStore: BackupSettingsStore(rootURL: settings.rootURL), lifecycle: lifecycle,
            requiresSelectedDirectoryScope: requiresScope, authority: BackupFolderAuthority(bookmarks: bookmarks),
            selectedDirectoryScope: bookmarks, folderOpener: opener, clock: { clock.now() }
        )
    }

    func remove() {
        try? library.close()
        try? FileManager.default.removeItem(at: base)
    }
}

final class LiveBackupMutableBookmarks: BackupBookmarkAccessing, BackupSelectedDirectorySecurityScope, @unchecked Sendable {
    private let lock = NSLock()
    private var _resolvedURL: URL
    private var _stale = false
    private var _createdBookmark = Data("bookmark".utf8)
    private var starts = 0
    private var stops = 0

    init(resolvedURL: URL) { _resolvedURL = resolvedURL }

    var stale: Bool {
        get { lock.withLock { _stale } }
        set { lock.withLock { _stale = newValue } }
    }
    var createdBookmark: Data {
        get { lock.withLock { _createdBookmark } }
        set { lock.withLock { _createdBookmark = newValue } }
    }
    var startCount: Int { lock.withLock { starts } }
    var stopCount: Int { lock.withLock { stops } }

    func createBookmark(for url: URL) throws -> Data { createdBookmark }
    func resolveBookmark(_ data: Data) throws -> BackupResolvedBookmark {
        lock.withLock { .init(url: _resolvedURL, isStale: _stale) }
    }
    func startAccessing(_ url: URL) -> Bool { lock.withLock { starts += 1 }; return true }
    func stopAccessing(_ url: URL) { lock.withLock { stops += 1 } }
}

final class LiveBackupTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    let start: Date

    init(_ value: Date) {
        self.value = value
        start = value
    }

    func now() -> Date { lock.withLock { value } }
    func set(_ value: Date) { lock.withLock { self.value = value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}

private actor LiveBackupFolderOpener: BackupFolderOpening {
    private(set) var openedURLs: [URL] = []
    private var result = true

    func setResult(_ value: Bool) { result = value }

    func open(_ url: URL) async -> Bool {
        openedURLs.append(url)
        return result
    }
}
