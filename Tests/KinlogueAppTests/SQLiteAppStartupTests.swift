import Foundation
import Testing
import KinlogueCore
@testable import KinlogueApp
@_spi(Testing) @testable import KinloguePlatform

@Suite(.serialized)
@MainActor
struct SQLiteAppStartupTests {
    @Test
    func disclosurePrecedesIOAndConcurrentOpeningSharesTheOwner() async throws {
        let fixture = try SQLStartupFixture()
        defer { fixture.remove() }
        let startup = LibraryLaunchCoordinator(identity: fixture.identity)
        #expect(!FileManager.default.fileExists(atPath: fixture.identity.sourceVault.rootURL.deletingLastPathComponent().path))
        await #expect(throws: AppStartupError.disclosureRequired) { try await startup.openEnvironment() }
        #expect(!FileManager.default.fileExists(atPath: fixture.identity.sourceVault.rootURL.deletingLastPathComponent().path))
        startup.acknowledgeStorageDisclosure()
        async let first = startup.openEnvironment()
        async let second = startup.openEnvironment()
        let (left, right) = try await (first, second)
        #expect(left.dataService === right.dataService)
        #expect(try await left.dataService.bootstrap().reportCount == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.identity.sourceVault.rootURL.appendingPathComponent("library.json").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.identity.backupIdentity.settingsRootURL.path))
        // Re-opening does not run restore reconciliation against its already-open database.
        #expect(try await startup.openEnvironment().dataService === left.dataService)
        let other = LibraryLaunchCoordinator(identity: fixture.identity)
        other.acknowledgeStorageDisclosure()
        await #expect(throws: SQLiteLibraryError.occupied) { try await other.openEnvironment() }
        #expect(other.seedRestoreService == nil)
        await startup.shutdown()
        await #expect(throws: LibraryLifecycleCoordinatorError.revoked) { try await startup.openEnvironment() }
        let recovered = try await other.openEnvironment()
        #expect(try await recovered.dataService.bootstrap().reportCount == 0)
        await other.shutdown()
    }

    @Test
    func launchCreatesASQLiteLibraryThatTheNextLaunchReopens() async throws {
        let fixture = try SQLStartupFixture()
        defer { fixture.remove() }
        let root = fixture.identity.sourceVault.rootURL
        let first = LibraryLaunchCoordinator(identity: fixture.identity)
        first.acknowledgeStorageDisclosure()
        #expect(await first.start())
        let model = try #require(first.composition?.appModel)
        #expect(model.phase == .ready)
        #expect(await model.createMember(displayName: "Synthetic launch member", disambiguationLabel: nil))
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)) == ["library.sqlite", "originals"])
        // A first launch is an ordinary start: nothing to restore, a private parent directory,
        // and no backup settings until the person chooses a folder.
        #expect(first.composition?.restoreModel.phase == .idle && first.failure == nil)
        let parent = try FileManager.default.attributesOfItem(atPath: root.deletingLastPathComponent().path)
        #expect((parent[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect(!FileManager.default.fileExists(atPath: fixture.identity.backupIdentity.settingsRootURL.path))
        await first.shutdown()

        let second = LibraryLaunchCoordinator(identity: fixture.identity)
        second.acknowledgeStorageDisclosure()
        #expect(await second.start())
        #expect(second.composition?.appModel.members.map(\.displayName) == ["Synthetic launch member"])
        await second.shutdown()
    }

    @Test
    func launchWithoutARuntimeIdentityReportsTheLibraryAsUnavailable() async {
        let startup = LibraryLaunchCoordinator(identity: nil)
        // Nothing is attempted before the storage disclosure is accepted.
        #expect(!(await startup.start()))
        #expect(startup.failure == nil && startup.composition == nil)

        startup.acknowledgeStorageDisclosure()
        #expect(!(await startup.start()))
        #expect(startup.failure == .unavailable)
        #expect(startup.composition != nil && startup.composition?.appModel.phase != .ready)
        #expect(startup.seedRestoreService == nil && startup.database == nil)
        await startup.shutdown()
    }

    @Test
    func coldReadyReadsNoOriginalBytesAndInspectionAccountsForLaterReads() async throws {
        let fixture = try SQLStartupFixture()
        defer { fixture.remove() }
        let root = fixture.identity.sourceVault.rootURL
        try LibraryParentDirectoryPreparation.ensureParentDirectory(for: root)
        let initial = try SQLiteLibraryStore(rootURL: root)
        let reports = SQLiteReportRepository(store: initial)
        let member = try FamilyMember(displayName: "Synthetic cold launch")
        try await reports.saveMember(member, replacing: nil)
        let bytes = Data("synthetic cold original".utf8)
        let file = try ValidatedImportedFile(data: bytes, kind: .image, contentTypeIdentifier: "public.png", sha256Digest: ContentDigest.sha256(bytes))
        guard case .created(let id) = try await reports.stage(file) else { throw LibraryReportError.invalidDocument }
        let lease = try await reports.beginProcessing(draftID: id, attemptID: UUID())
        try await reports.completeProcessing(lease: lease, document: ImportDraftDocument(blocks: [], candidates: ReportCandidates()))
        let draft = try await reports.draft(id)
        let record = try HealthRecord(id: id, memberID: member.id, sources: draft.sources, ocrDocumentObjectID: draft.documentObjectID,
            importState: .confirmed, conclusion: SourceField.manualEntry("Synthetic source"))
        try await reports.confirm(draftID: id, expectedRevision: draft.revision, record: record)
        try initial.close()
        let startup = LibraryLaunchCoordinator(identity: fixture.identity)
        startup.acknowledgeStorageDisclosure()
        #expect(await startup.start())
        #expect(startup.composition?.appModel.phase == .ready)
        let opened = try #require(startup.database)
        #expect(opened.originalReadMetrics.verifiedReadByteCount == 0)
        await startup.composition?.integrityCoordinator?.pause()
        let inspected = try await SQLiteLibraryIntegrityScrubber(store: opened).run()
        #expect(inspected.completed && inspected.damagedTargets.isEmpty)
        #expect(opened.originalReadMetrics.verifiedReadByteCount >= bytes.count)
        await startup.shutdown()
    }

    @Test
    func pendingDeletionReceiptMustBeValidBeforeDatabaseCreation() async throws {
        let fixture = try SQLStartupFixture()
        defer { fixture.remove() }
        let root = fixture.identity.sourceVault.rootURL
        try LibraryParentDirectoryPreparation.ensureParentDirectory(for: root)
        let transaction = try LibraryDeletionTransaction(rootURL: root, strictReceipt: true)
        let bytes = Data("synthetic unknown deletion receipt".utf8)
        try bytes.write(to: transaction.receiptURL)
        let startup = LibraryLaunchCoordinator(identity: fixture.identity)
        startup.acknowledgeStorageDisclosure()
        await #expect(throws: (any Error).self) { try await startup.openEnvironment() }
        #expect(try Data(contentsOf: transaction.receiptURL) == bytes)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(startup.seedRestoreService == nil)
        await startup.shutdown()
    }

    /// The deletion is interrupted either right after its receipt was written or after the library
    /// was moved aside, and in the renumbered cases the launch that finishes it finds the volume
    /// under another device number than the receipt recorded.
    @Test(arguments: [LibraryDeletionFault.afterDeletionReceipt, .afterDeletionRename], [false, true])
    func ownedDeletionReceiptConvergesBeforeAnEmptyLibraryIsOpened(
        interruptedAt fault: LibraryDeletionFault, afterTheVolumeWasRenumbered: Bool
    ) async throws {
        let fixture = try SQLStartupFixture()
        defer { fixture.remove() }
        let root = fixture.identity.sourceVault.rootURL
        try LibraryParentDirectoryPreparation.ensureParentDirectory(for: root)
        let store = try SQLiteLibraryStore(rootURL: root)
        try await SQLiteReportRepository(store: store).saveMember(try FamilyMember(displayName: "Synthetic member to delete"), replacing: nil)
        try store.close()
        let transaction = try LibraryDeletionTransaction(rootURL: root, failureInjector: { $0 == fault }, strictReceipt: true)
        #expect(throws: (any Error).self) { try transaction.begin() }
        if afterTheVolumeWasRenumbered {
            let text = try String(contentsOf: transaction.receiptURL, encoding: .utf8)
            let pattern = try NSRegularExpression(pattern: #""device":(\d+)"#)
            let match = try #require(pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)))
            let digits = try #require(Range(match.range(at: 1), in: text))
            let handle = try FileHandle(forWritingTo: transaction.receiptURL)
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: Data(text.replacingCharacters(in: digits, with: String(try #require(Int(text[digits])) + 3)).utf8))
            try handle.close()
        }
        let startup = LibraryLaunchCoordinator(identity: fixture.identity)
        startup.acknowledgeStorageDisclosure()
        let snapshot = try await startup.openEnvironment().dataService.bootstrap()
        #expect(snapshot.members.isEmpty && snapshot.reportCount == 0)
        #expect(!FileManager.default.fileExists(atPath: transaction.receiptURL.path))
        await startup.shutdown()
    }

    @Test
    func startRetriesAnOccupiedRootByReplacingTheUnavailableComposition() async throws {
        let fixture = try SQLStartupFixture()
        defer { fixture.remove() }
        let first = LibraryLaunchCoordinator(identity: fixture.identity)
        first.acknowledgeStorageDisclosure()
        _ = try await first.openEnvironment()
        let other = LibraryLaunchCoordinator(identity: fixture.identity)
        other.acknowledgeStorageDisclosure()
        #expect(!(await other.start()))
        #expect(other.failure == .occupied && other.failure?.canRetry == true)
        #expect(other.seedRestoreService == nil)
        await first.shutdown()
        #expect(await other.start())
        #expect(other.composition?.appModel.phase == .ready)
        #expect(other.failure == nil)
        await other.shutdown()
    }

    @Test
    func unreadableSQLitePageRetainsSameOwnerSeedRecovery() async throws {
        let fixture = try SQLStartupFixture()
        defer { fixture.remove() }
        let root = fixture.identity.sourceVault.rootURL
        try LibraryParentDirectoryPreparation.ensureParentDirectory(for: root)
        let store = try SQLiteLibraryStore(rootURL: root)
        try store.close()
        let url = root.appendingPathComponent(SQLiteLibraryStore.databaseFilename)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seek(toOffset: 100)
        try handle.write(contentsOf: Data([0xff]))
        try handle.close()
        let before = try Data(contentsOf: url)
        let startup = LibraryLaunchCoordinator(identity: fixture.identity)
        startup.acknowledgeStorageDisclosure()
        await #expect(throws: SQLiteLibraryError.databaseUnavailable) { try await startup.openEnvironment() }
        #expect(startup.seedRestoreService != nil)
        #expect(try Data(contentsOf: url) == before)
        await startup.shutdown()
    }

    @Test
    func oldJSONIsPreservedAndOnlyItsExistingOwnerMayOfferSeedRestore() async throws {
        let fixture = try SQLStartupFixture()
        defer { fixture.remove() }
        let root = fixture.identity.sourceVault.rootURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let bytes = Data("synthetic old JSON bytes must survive".utf8)
        let file = root.appendingPathComponent("library.json")
        try bytes.write(to: file)
        let startup = LibraryLaunchCoordinator(identity: fixture.identity)
        startup.acknowledgeStorageDisclosure()
        await #expect(throws: SQLiteLibraryError.unsupportedFormat) { try await startup.openEnvironment() }
        #expect(try Data(contentsOf: file) == bytes)
        #expect(startup.seedRestoreService != nil)
        #expect(throws: SQLiteLibraryError.occupied) { try SQLiteLibraryOwner(rootURL: root) }
        #expect(!(await startup.start()))
        #expect(startup.failure == .unrecognized && startup.failure?.canRetry == false)
        await startup.shutdown()
    }

    enum OldLibraryCircumstance: Sendable {
        case nothingElse
        /// The backup settings can no longer be read. The restore has to clear them instead of
        /// stopping on them.
        case anUnreadableBackupSettings
        /// An earlier restore over the same library stopped right after recording its intent.
        /// The launch has to undo it and leave the old library in place for another attempt.
        case anInterruptedEarlierRestore
    }

    @Test(arguments: [OldLibraryCircumstance.nothingElse, .anUnreadableBackupSettings, .anInterruptedEarlierRestore])
    func restoringOverAnOldFormatLibraryReplacesItAndTheNextLaunchOpensTheRestoredOne(
        with circumstance: OldLibraryCircumstance
    ) async throws {
        let fixture = try SQLStartupFixture()
        defer { fixture.remove() }
        let donorParent = fixture.base.appendingPathComponent("donor", isDirectory: true)
        try FileManager.default.createDirectory(at: donorParent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let donor = try SQLiteLibraryStore(rootURL: donorParent.appendingPathComponent("Vault", isDirectory: true))
        let member = try FamilyMember(displayName: "Synthetic restored member")
        try await SQLiteReportRepository(store: donor).saveMember(member, replacing: nil)
        let restorePoint = fixture.base.appendingPathComponent("synthetic.zip")
        _ = try await BackupArchiveWriter(store: donor).write(to: .file(restorePoint), content: BackupArchiveText.content())
        try donor.close()

        let root = fixture.identity.sourceVault.rootURL
        try FileManager.default.createDirectory(at: root.appendingPathComponent("objects", isDirectory: true),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let oldManifest = Data("synthetic old JSON bytes".utf8)
        try oldManifest.write(to: root.appendingPathComponent("library.json"))
        try Data("synthetic old object".utf8).write(to: root.appendingPathComponent("objects/synthetic.bin"))
        let settingsRoot = fixture.identity.backupIdentity.settingsRootURL
        let profileRecord = settingsRoot.appendingPathComponent("settings.json")
        if circumstance == .anUnreadableBackupSettings {
            try FileManager.default.createDirectory(at: settingsRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data("{\"magic\":\"truncated".utf8).write(to: profileRecord)
            #expect(chmod(profileRecord.path, 0o600) == 0)
            #expect(throws: BackupSettingsStoreError.invalidRecord) { _ = try BackupSettingsStore(rootURL: settingsRoot).load() }
        }
        func restoreLeftovers() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: root.deletingLastPathComponent().path)
                .filter { $0.hasPrefix(".kinlogue-restore-") }
        }
        if circumstance == .anInterruptedEarlierRestore {
            // Scoped, so the owner is released before the launch takes it.
            let owner = try SQLiteLibraryOwner(rootURL: root)
            let prepared = try await BackupRestoreVerifier(owner: owner).prepare(archiveURL: restorePoint)
            let interrupted = try BackupRestoreTransaction(owner: owner, failureInjector: { $0 == .afterIntent })
            await #expect(throws: BackupRestoreError.injectedFailure) {
                _ = try await interrupted.activate(prepared: prepared, resetWriter: {})
            }
            #expect(try !restoreLeftovers().isEmpty)
        }

        let startup = LibraryLaunchCoordinator(identity: fixture.identity)
        startup.acknowledgeStorageDisclosure()
        await #expect(throws: SQLiteLibraryError.unsupportedFormat) { try await startup.openEnvironment() }
        #expect(try Data(contentsOf: root.appendingPathComponent("library.json")) == oldManifest)
        #expect(try restoreLeftovers().isEmpty)
        do {
            // Scoped: the service keeps the library's owner, which the next launch has to take.
            let restore = try #require(startup.seedRestoreService)
            #expect(try await restore.prepare(archiveURL: restorePoint).memberCount == 1)
            // Checking the backup replaces nothing; only the confirmed activation does.
            #expect(try Data(contentsOf: root.appendingPathComponent("library.json")) == oldManifest)
            #expect(try await restore.activatePreparedRestore().requiresApplicationRestart)
        }
        await startup.shutdown()

        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("library.json").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("objects").path))
        #expect(!FileManager.default.fileExists(atPath: profileRecord.path))
        func setAsideDirectories() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: root.deletingLastPathComponent().path)
                .filter { $0.hasPrefix(".kinlogue-restore-rollback-") }
        }
        // The replaced directory stays beside the library until the next launch settles the restore.
        #expect(try setAsideDirectories().count == 1)
        let next = LibraryLaunchCoordinator(identity: fixture.identity)
        next.acknowledgeStorageDisclosure()
        #expect(try await next.openEnvironment().dataService.bootstrap().members.map(\.id) == [member.id])
        #expect(try setAsideDirectories().isEmpty)
        await next.shutdown()
    }
}

struct SQLStartupFixture {
    let base: URL
    let identity: AppRuntimeIdentity
    init() throws {
        base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("kinlogue-sql-startup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        identity = try AppRuntimeIdentity.resolve(bundleInfo: ["CFBundleIdentifier": AppRuntimeIdentity.productionBundleIdentifier],
            arguments: ["Kinlogue"], trustedApplicationSupportDirectory: base)
    }
    func remove() { try? FileManager.default.removeItem(at: base) }
}
