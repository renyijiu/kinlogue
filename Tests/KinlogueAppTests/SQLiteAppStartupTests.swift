import Foundation
import Testing
import KinlogueCore
@testable import KinlogueApp
@testable import KinloguePlatform

@Suite(.serialized)
@MainActor
struct SQLiteAppStartupTests {
    @Test
    func disclosurePrecedesIOAndConcurrentOpeningSharesTheOwner() async throws {
        let fixture = try SQLStartupFixture()
        defer { fixture.remove() }
        let startup = AppStartupCoordinator(identity: fixture.identity)
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
        #expect(!FileManager.default.fileExists(atPath: fixture.identity.backupIdentity.rootURL.path))
        // Re-opening does not run restore reconciliation against its already-open database.
        #expect(try await startup.openEnvironment().dataService === left.dataService)
        let other = AppStartupCoordinator(identity: fixture.identity)
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
    func coldReadyReadsNoOriginalBytesAndInspectionAccountsForLaterReads() async throws {
        let fixture = try SQLStartupFixture()
        defer { fixture.remove() }
        let root = fixture.identity.sourceVault.rootURL
        try VaultParentDirectoryPreparation.ensureParentDirectory(for: root)
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
        let startup = AppStartupCoordinator(identity: fixture.identity)
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
        try VaultParentDirectoryPreparation.ensureParentDirectory(for: root)
        let transaction = try PlaintextVaultDeletionTransaction(rootURL: root, strictReceipt: true)
        let bytes = Data("synthetic unknown deletion receipt".utf8)
        try bytes.write(to: transaction.receiptURL)
        let startup = AppStartupCoordinator(identity: fixture.identity)
        startup.acknowledgeStorageDisclosure()
        await #expect(throws: (any Error).self) { try await startup.openEnvironment() }
        #expect(try Data(contentsOf: transaction.receiptURL) == bytes)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(startup.seedRestoreService == nil)
        await startup.shutdown()
    }

    @Test
    func ownedDeletionReceiptConvergesBeforeAnEmptyLibraryIsOpened() async throws {
        let fixture = try SQLStartupFixture()
        defer { fixture.remove() }
        let root = fixture.identity.sourceVault.rootURL
        try VaultParentDirectoryPreparation.ensureParentDirectory(for: root)
        let store = try SQLiteLibraryStore(rootURL: root)
        try store.close()
        let transaction = try PlaintextVaultDeletionTransaction(rootURL: root, failureInjector: { $0 == .afterDeletionReceipt }, strictReceipt: true)
        #expect(throws: (any Error).self) { try transaction.begin() }
        let startup = AppStartupCoordinator(identity: fixture.identity)
        startup.acknowledgeStorageDisclosure()
        #expect(try await startup.openEnvironment().dataService.bootstrap().reportCount == 0)
        #expect(!FileManager.default.fileExists(atPath: transaction.receiptURL.path))
        await startup.shutdown()
    }

    @Test
    func startRetriesAnOccupiedRootByReplacingTheUnavailableComposition() async throws {
        let fixture = try SQLStartupFixture()
        defer { fixture.remove() }
        let first = AppStartupCoordinator(identity: fixture.identity)
        first.acknowledgeStorageDisclosure()
        _ = try await first.openEnvironment()
        let other = AppStartupCoordinator(identity: fixture.identity)
        other.acknowledgeStorageDisclosure()
        #expect(!(await other.start()))
        #expect(other.candidateFailure == .occupied && other.candidateFailure?.canRetry == true)
        #expect(other.seedRestoreService == nil)
        await first.shutdown()
        #expect(await other.start())
        #expect(other.composition?.appModel.phase == .ready)
        #expect(other.candidateFailure == nil)
        await other.shutdown()
    }

    @Test
    func unreadableSQLitePageRetainsSameOwnerSeedRecovery() async throws {
        let fixture = try SQLStartupFixture()
        defer { fixture.remove() }
        let root = fixture.identity.sourceVault.rootURL
        try VaultParentDirectoryPreparation.ensureParentDirectory(for: root)
        let store = try SQLiteLibraryStore(rootURL: root)
        try store.close()
        let url = root.appendingPathComponent(SQLiteLibraryStore.databaseFilename)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seek(toOffset: 100)
        try handle.write(contentsOf: Data([0xff]))
        try handle.close()
        let before = try Data(contentsOf: url)
        let startup = AppStartupCoordinator(identity: fixture.identity)
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
        let startup = AppStartupCoordinator(identity: fixture.identity)
        startup.acknowledgeStorageDisclosure()
        await #expect(throws: SQLiteLibraryError.unsupportedFormat) { try await startup.openEnvironment() }
        #expect(try Data(contentsOf: file) == bytes)
        #expect(startup.seedRestoreService != nil)
        #expect(throws: SQLiteLibraryError.occupied) { try SQLiteLibraryOwner(rootURL: root) }
        #expect(!(await startup.start()))
        #expect(startup.candidateFailure == .unrecognized && startup.candidateFailure?.canRetry == false)
        await startup.shutdown()
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
