import CryptoKit
import Darwin
import Foundation
import Testing
import ZIPFoundation
@testable import KinlogueCore
@testable import KinloguePlatform

@Suite("Backup archive writer")
struct BackupArchiveWriterTests {
    @Test
    func archiveHoldsIndexReadmeDataAndEveryOriginalAndRestores() async throws {
        let fixture = try await BackupArchiveFixture.make()
        defer { fixture.remove() }
        let destination = fixture.container.appendingPathComponent("backup.zip")
        let result = try await BackupArchiveWriter(store: fixture.store).write(to: .file(destination), content: .synthetic)

        #expect(result.url == destination && result.fileName == "backup.zip")
        #expect(result.counts.members == 1 && result.counts.records == 1 && result.counts.originals == 1)
        let archive = try Archive(url: destination, accessMode: .read)
        let entries = Array(archive)
        #expect(entries.map(\.path) == [
            "kinlogue-backup.json", "README.txt", "data/library.klog",
            "files/Synthetic Member/Undated - Report 0001 - Source 0001 - Report.pdf",
        ])
        #expect(entries[0].isCompressed && entries[2].isCompressed && !entries[3].isCompressed)
        let index = try BackupArchiveIndex.decode(try extract(entries[0], from: archive))
        #expect(index.backupID == result.backupID && index.library == result.library)
        #expect(index.creator.version == "9.9" && index.counts == result.counts)
        #expect(try extract(entries[1], from: archive) == Data("Synthetic read-me".utf8))
        let data = try extract(entries[2], from: archive)
        #expect(UInt64(data.count) == index.data.byteCount && Data(SHA256.hash(data: data)) == index.data.sha256)
        #expect(try extract(entries[3], from: archive) == fixture.bytes)
        #expect(index.originals.map(\.id) == [fixture.record.sources.first.attachmentID])
        var metadata = stat()
        #expect(lstat(destination.path, &metadata) == 0)
        #expect(result.inode == UInt64(metadata.st_ino) && result.byteCount == UInt64(metadata.st_size))
        #expect(metadata.st_mode & 0o777 == 0o600)

        let restoredRoot = fixture.container.appendingPathComponent("Restored", isDirectory: true)
        let owner = try SQLiteLibraryOwner(rootURL: restoredRoot)
        let prepared = try await BackupRestoreVerifier(owner: owner).prepare(archiveURL: destination)
        #expect(prepared.summary.memberCount == 1 && prepared.summary.recordCount == 1)
        #expect(prepared.summary.originalCount == 1 && prepared.summary.backupID == result.backupID)
        #expect(prepared.summary.createdAt == result.createdAt && prepared.summary.creatorVersion == "9.9")
        let transaction = try BackupRestoreTransaction(owner: owner)
        _ = try await transaction.activate(prepared: prepared, resetWriter: {})
        #expect(try await transaction.reconcile() == .committed)
        let restored = try SQLiteLibraryStore(owner: owner)
        defer { try? restored.close() }
        #expect(try await SQLiteReportRepository(store: restored).record(fixture.record.id) == fixture.record)
    }

    @Test
    func folderBackupsNeverReplaceAFileAndTakeTheNextFreeName() async throws {
        let fixture = try await BackupArchiveFixture.make()
        defer { fixture.remove() }
        let folder = fixture.container.appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let existing = Data("someone else's file".utf8)
        try existing.write(to: folder.appendingPathComponent("Kinlogue Backup.zip"))
        let writer = BackupArchiveWriter(store: fixture.store)

        let first = try await writer.write(to: .folder(folder, fileNameStem: "Kinlogue Backup"), content: .synthetic)
        let second = try await writer.write(to: .folder(folder, fileNameStem: "Kinlogue Backup"), content: .synthetic)

        #expect(first.fileName == "Kinlogue Backup (2).zip" && second.fileName == "Kinlogue Backup (3).zip")
        #expect(first.backupID != second.backupID)
        #expect(try Data(contentsOf: folder.appendingPathComponent("Kinlogue Backup.zip")) == existing)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == [
            "Kinlogue Backup (2).zip", "Kinlogue Backup (3).zip", "Kinlogue Backup.zip",
        ])
        var metadata = stat()
        #expect(lstat(second.url.path, &metadata) == 0)
        #expect(second.inode == UInt64(metadata.st_ino) && second.byteCount == UInt64(metadata.st_size))
        #expect(second.modifiedSeconds == Int64(metadata.st_mtimespec.tv_sec)
            && second.modifiedNanoseconds == Int64(metadata.st_mtimespec.tv_nsec))
        await #expect(throws: BackupArchiveWriteError.invalidDestination) {
            _ = try await writer.write(to: .folder(folder, fileNameStem: "../escape"), content: .synthetic)
        }
        await #expect(throws: BackupArchiveWriteError.invalidDestination) {
            _ = try await writer.write(to: .folder(fixture.vaultRoot, fileNameStem: "inside"), content: .synthetic)
        }
    }

    @Test
    func failedBackupKeepsTheExistingFileAndLeavesNothingBehind() async throws {
        let fixture = try await BackupArchiveFixture.make()
        defer { fixture.remove() }
        let destination = fixture.container.appendingPathComponent("backup.zip")
        let prior = Data("prior archive bytes".utf8)
        try prior.write(to: destination)
        let writer = BackupArchiveWriter(store: fixture.store, fileManager: .default, failureInjector: { $0 == .beforeVerification })

        await #expect(throws: BackupArchiveWriteError.injectedFailure) {
            _ = try await writer.write(to: .file(destination), content: .synthetic)
        }
        #expect(try Data(contentsOf: destination) == prior)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.container.path).filter { $0.hasSuffix(".zip") } == ["backup.zip"])
    }

    @Test
    func originalThatNoLongerMatchesItsDigestStopsTheBackup() async throws {
        let fixture = try await BackupArchiveFixture.make()
        defer { fixture.remove() }
        let destination = fixture.container.appendingPathComponent("backup.zip")
        try Data(repeating: 0x44, count: fixture.bytes.count).write(to: fixture.originalURL)

        await #expect(throws: BackupArchiveWriteError.sourceChanged) {
            _ = try await BackupArchiveWriter(store: fixture.store).write(to: .file(destination), content: .synthetic)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test
    func backupKeepsTheCommitItCapturedWhenTheLibraryChangesBeforePublication() async throws {
        let fixture = try await BackupArchiveFixture.make(byteCount: 2 * 1_024 * 1_024)
        defer { fixture.remove() }
        let destination = fixture.container.appendingPathComponent("backup.zip")
        let gate = BackupWriteGate()
        let writer = BackupArchiveWriter(store: fixture.store, fileManager: .default, failureInjector: { fault in
            guard fault == .beforeFinalRevisionCheck else { return false }
            gate.reachAndWait()
            return false
        })
        let task = Task { try await writer.write(to: .file(destination), content: .synthetic) }
        await gate.waitUntilReached()
        defer { gate.release() }
        try await fixture.reports.deleteRecord(fixture.record.id, expectedRevision: fixture.record.revision)
        #expect(FileManager.default.fileExists(atPath: fixture.originalURL.path))
        gate.release()

        let result = try await task.value
        #expect(result.counts.records == 1)
        let archive = try Archive(url: destination, accessMode: .read)
        #expect(try extract(try #require(Array(archive).last), from: archive) == fixture.bytes)
        #expect(!FileManager.default.fileExists(atPath: fixture.originalURL.path))
    }

    @Test
    func fileDestinationsMustBeZIPFilesOutsideTheLibrary() async throws {
        let fixture = try await BackupArchiveFixture.make()
        defer { fixture.remove() }
        let writer = BackupArchiveWriter(store: fixture.store)
        for destination in [fixture.container.appendingPathComponent("not-a-zip.txt"), fixture.vaultRoot.appendingPathComponent("leak.zip")] {
            await #expect(throws: BackupArchiveWriteError.invalidDestination) {
                _ = try await writer.write(to: .file(destination), content: .synthetic)
            }
        }
        let symlink = fixture.container.appendingPathComponent("link.zip")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: fixture.container.appendingPathComponent("target"))
        await #expect(throws: BackupArchiveWriteError.invalidDestination) {
            _ = try await writer.write(to: .file(symlink), content: .synthetic)
        }
    }

    @Test(arguments: [BackupArchiveWriterFault.beforeCommit, .afterDestinationParentBinding])
    func publicationStaysBoundToTheValidatedParent(fault: BackupArchiveWriterFault) async throws {
        let fixture = try await BackupArchiveFixture.make()
        defer { fixture.remove() }
        let parent = fixture.container.appendingPathComponent("Export", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        let destination = parent.appendingPathComponent("backup.zip")
        let prior = Data("prior archive bytes".utf8)
        try prior.write(to: destination)
        let replacement = fixture.container.appendingPathComponent("MovedExport", isDirectory: true)
        let swap = BackupParentSwap(parent: parent, replacement: replacement, symlinkTarget: fixture.vaultRoot)
        let writer = BackupArchiveWriter(
            store: fixture.store, fileManager: .default,
            destinationAccess: .init(start: { _ in .notRequired }, stop: { _ in }),
            failureInjector: { if $0 == fault { swap.perform() }; return false }
        )

        await #expect(throws: BackupArchiveWriteError.invalidDestination) {
            _ = try await writer.write(to: .file(destination), content: .synthetic)
        }
        #expect(swap.succeeded)
        #expect(!FileManager.default.fileExists(atPath: fixture.vaultRoot.appendingPathComponent("backup.zip").path))
        #expect(try Data(contentsOf: replacement.appendingPathComponent("backup.zip")) == prior)
    }

    @Test(arguments: [BackupArchiveWriterFault.corruptWorkArchiveBeforeVerification, .shortSourceRead])
    func damagedWorkArchiveIsNeverPublished(fault: BackupArchiveWriterFault) async throws {
        let fixture = try await BackupArchiveFixture.make()
        defer { fixture.remove() }
        let destination = fixture.container.appendingPathComponent("backup.zip")
        let writer = BackupArchiveWriter(store: fixture.store, fileManager: .default, failureInjector: { $0 == fault })
        await #expect(throws: (any Error).self) {
            _ = try await writer.write(to: .file(destination), content: .synthetic)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test
    func cancellationBeforeCommitPublishesNothing() async throws {
        let fixture = try await BackupArchiveFixture.make(byteCount: 2 * 1_024 * 1_024)
        defer { fixture.remove() }
        let destination = fixture.container.appendingPathComponent("backup.zip")
        let writer = BackupArchiveWriter(store: fixture.store)
        let box = BackupWriteTaskBox()
        let task = Task {
            try await writer.write(to: .file(destination), content: .synthetic) { progress in
                if progress.phase == .writing, progress.completedByteCount > 0 { box.cancel() }
            }
        }
        box.set(task)
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test
    func grantedDestinationAccessIsBalancedAndDeniedAccessWritesNothing() async throws {
        let fixture = try await BackupArchiveFixture.make()
        defer { fixture.remove() }
        let destination = fixture.container.appendingPathComponent("backup.zip")
        let granted = AccessCounter()
        let failing = BackupArchiveWriter(
            store: fixture.store, fileManager: .default,
            destinationAccess: .init(start: { _ in granted.started(); return .granted }, stop: { _ in granted.stopped() }),
            failureInjector: { $0 == .beforeVerification }
        )
        await #expect(throws: BackupArchiveWriteError.injectedFailure) {
            _ = try await failing.write(to: .file(destination), content: .synthetic)
        }
        #expect(granted.counts == (1, 1))

        let denied = AccessCounter()
        let refused = BackupArchiveWriter(
            store: fixture.store, fileManager: .default,
            destinationAccess: .init(start: { _ in denied.started(); return .denied }, stop: { _ in denied.stopped() })
        )
        await #expect(throws: BackupArchiveWriteError.destinationAccessDenied) {
            _ = try await refused.write(to: .file(destination), content: .synthetic)
        }
        #expect(denied.counts == (1, 0))
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test
    func failedFolderSyncAfterPublicationIsReportedAsIndeterminate() async throws {
        let fixture = try await BackupArchiveFixture.make()
        defer { fixture.remove() }
        let destination = fixture.container.appendingPathComponent("backup.zip")
        let writer = BackupArchiveWriter(store: fixture.store, fileManager: .default,
                                         parentDirectorySync: { _ in throw BackupArchiveWriteError.ioFailure(EIO) })
        await #expect(throws: BackupArchiveWriteError.publicationIndeterminate) {
            _ = try await writer.write(to: .file(destination), content: .synthetic)
        }
        #expect(Array(try Archive(url: destination, accessMode: .read)).count == 4)
    }

    @Test(arguments: [EACCES, EPERM, EINVAL, ENOTSUP, EOPNOTSUPP])
    func folderSyncThatTheVolumeCannotDoIsAccepted(errorCode: Int32) async throws {
        let fixture = try await BackupArchiveFixture.make()
        defer { fixture.remove() }
        let destination = fixture.container.appendingPathComponent("backup.zip")
        let writer = BackupArchiveWriter(store: fixture.store, fileManager: .default,
                                         parentDirectorySync: { _ in throw BackupArchiveWriteError.ioFailure(errorCode) })
        #expect(try await writer.write(to: .file(destination), content: .synthetic).url == destination)
    }

    @Test
    func emptyLibraryStillMakesARestorableBackup() async throws {
        let container = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: container) }
        let store = try SQLiteLibraryStore(rootURL: container.appendingPathComponent("Vault", isDirectory: true))
        let destination = container.appendingPathComponent("empty.zip")
        let result = try await BackupArchiveWriter(store: store).write(to: .file(destination), content: .synthetic)
        try store.close()
        #expect(result.counts.originals == 0)
        #expect(Array(try Archive(url: destination, accessMode: .read)).map(\.path) == ["kinlogue-backup.json", "README.txt", "data/library.klog"])
        let owner = try SQLiteLibraryOwner(rootURL: container.appendingPathComponent("Restored", isDirectory: true))
        #expect(try await BackupRestoreVerifier(owner: owner).prepare(archiveURL: destination).summary.memberCount == 0)
    }
}

// MARK: - Shared fixtures

extension BackupArchiveContent {
    static let synthetic = BackupArchiveContent(
        labels: BackupArchiveLabels(undated: "Undated", pendingFolder: "Pending", phoneFolder: "Phone", otherFolder: "Other"),
        creator: try! BackupArchiveIndex.Creator(app: "Kinlogue", version: "9.9", build: "99"),
        readmeFileName: "README.txt",
        readmeText: "Synthetic read-me"
    )
}

func extract(_ entry: Entry, from archive: Archive) throws -> Data {
    var data = Data()
    _ = try archive.extract(entry, bufferSize: 64 * 1_024) { data.append($0) }
    return data
}

struct BackupArchiveFixture {
    let container: URL
    let vaultRoot: URL
    let store: SQLiteLibraryStore
    let reports: SQLiteReportRepository
    let record: HealthRecord
    let bytes: Data

    var originalURL: URL {
        store.originalsURL.appendingPathComponent(record.sources.first.attachmentID.uuidString.lowercased() + ".data")
    }

    static func make(byteCount: Int = 128 * 1_024) async throws -> Self {
        let container = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        let root = container.appendingPathComponent("Vault", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let store = try SQLiteLibraryStore(rootURL: root)
        let reports = SQLiteReportRepository(store: store)
        let member = try FamilyMember(displayName: "Synthetic Member")
        try await reports.saveMember(member, replacing: nil)
        let bytes = Data((0..<byteCount).map { UInt8(truncatingIfNeeded: $0) })
        let file = try ValidatedImportedFile(data: bytes, kind: .pdf, contentTypeIdentifier: "com.adobe.pdf",
                                             sha256Digest: Data(SHA256.hash(data: bytes)), pageCount: 1)
        guard case .created(let draftID) = try await reports.stage(file) else { throw LibraryReportError.invalidDocument }
        let lease = try await reports.beginProcessing(draftID: draftID, attemptID: UUID())
        try await reports.completeProcessing(lease: lease, document: ImportDraftDocument(blocks: [], candidates: ReportCandidates()))
        let draft = try await reports.draft(draftID)
        let record = try HealthRecord(id: draftID, memberID: member.id, sources: draft.sources,
                                      ocrDocumentObjectID: draft.documentObjectID, importState: .confirmed)
        try await reports.confirm(draftID: draftID, expectedRevision: draft.revision, record: record)
        return Self(container: container, vaultRoot: root, store: store, reports: reports, record: record, bytes: bytes)
    }

    func remove() {
        try? store.close()
        try? FileManager.default.removeItem(at: container)
    }
}

private final class BackupWriteTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<BackupArchiveWriteResult, Error>?
    private var pending = false

    func set(_ task: Task<BackupArchiveWriteResult, Error>) {
        lock.withLock { self.task = task; if pending { task.cancel() } }
    }

    func cancel() {
        lock.withLock { pending = true; task?.cancel() }
    }
}

private final class AccessCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0, stops = 0
    var counts: (Int, Int) { lock.withLock { (starts, stops) } }
    func started() { lock.withLock { starts += 1 } }
    func stopped() { lock.withLock { stops += 1 } }
}

private final class BackupParentSwap: @unchecked Sendable {
    private let lock = NSLock()
    private let parent: URL, replacement: URL, symlinkTarget: URL
    private var failure: String?
    private var didRun = false

    init(parent: URL, replacement: URL, symlinkTarget: URL) {
        self.parent = parent; self.replacement = replacement; self.symlinkTarget = symlinkTarget
    }

    var succeeded: Bool { lock.withLock { didRun && failure == nil } }

    func perform() {
        lock.withLock {
            guard !didRun else { return }
            didRun = true
            do {
                try FileManager.default.moveItem(at: parent, to: replacement)
                try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: symlinkTarget)
            } catch {
                failure = String(describing: error)
            }
        }
    }
}

private final class BackupWriteGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var reached = false
    private var waiter: CheckedContinuation<Void, Never>?

    func reachAndWait() {
        let pending = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            reached = true
            defer { waiter = nil }
            return waiter
        }
        pending?.resume()
        semaphore.wait()
    }

    func waitUntilReached() async {
        if lock.withLock({ reached }) { return }
        await withCheckedContinuation { continuation in
            let resume = lock.withLock { () -> Bool in
                guard !reached else { return true }
                waiter = continuation
                return false
            }
            if resume { continuation.resume() }
        }
    }

    func release() { semaphore.signal() }
}
