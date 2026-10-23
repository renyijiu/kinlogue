import CryptoKit
import Darwin
import Foundation
import Testing
import ZIPFoundation
@testable import KinlogueCore
@testable import KinloguePlatform

@Suite("Backup archive restore")
struct BackupArchiveRestoreTests {
    @Test
    func extraEntriesAreIgnoredAndARecompressedFolderIsAccepted() async throws {
        let fixture = try await BackupArchiveRestoreFixture.make()
        defer { fixture.remove() }
        let extra = try fixture.rewrite("extra.zip") { entries in
            entries + [
                ("Notes from me.txt", Data("my own note".utf8), .deflate),
                ("__MACOSX/._kinlogue-backup.json", Data([0, 1, 2]), .none),
                ("../outside.txt", Data("never extracted".utf8), .none),
            ]
        }
        #expect(try await fixture.prepare(extra).summary.recordCount == 1)

        // Finder's Compress puts everything under one folder and deflates every entry.
        let folder = try fixture.rewrite("folder.zip") { entries in
            entries.map { ("Kinlogue Backup/" + $0.path, $0.data, CompressionMethod.deflate) }
        }
        let summary = try await fixture.prepare(folder).summary
        #expect(summary.memberCount == 1 && summary.originalCount == 1)
        #expect(fixture.leftovers().isEmpty)
    }

    @Test
    func filesThatAreNotBackupsAreNamedAsSuch() async throws {
        let fixture = try await BackupArchiveRestoreFixture.make()
        defer { fixture.remove() }
        let text = fixture.container.appendingPathComponent("text.zip")
        try Data("not a zip at all".utf8).write(to: text)
        await #expect(throws: BackupRestoreError.notABackup) { _ = try await fixture.prepare(text) }

        let noIndex = try fixture.rewrite("no-index.zip") { $0.filter { $0.path != BackupArchiveIndex.fileName } }
        await #expect(throws: BackupRestoreError.notABackup) { _ = try await fixture.prepare(noIndex) }

        let twoIndexes = try fixture.rewrite("two-indexes.zip") { entries in
            entries + entries.filter { $0.path == BackupArchiveIndex.fileName }.map { ("Copy/" + $0.path, $0.data, $0.method) }
        }
        await #expect(throws: BackupRestoreError.graphInvalid) { _ = try await fixture.prepare(twoIndexes) }
        #expect(fixture.leftovers().isEmpty)
    }

    @Test
    func changedContentIsRejectedAndNothingStays() async throws {
        let fixture = try await BackupArchiveRestoreFixture.make()
        defer { fixture.remove() }
        let original = try #require(fixture.index.originals.first).entry.path
        let flipped = try fixture.rewrite("flipped.zip") { entries in
            entries.map { entry in
                guard entry.path == original else { return entry }
                var data = entry.data
                data[data.startIndex] ^= 0xff
                return (entry.path, data, entry.method)
            }
        }
        await #expect(throws: BackupRestoreError.graphInvalid) { _ = try await fixture.prepare(flipped) }

        let missing = try fixture.rewrite("missing.zip") { $0.filter { $0.path != original } }
        await #expect(throws: BackupRestoreError.graphInvalid) { _ = try await fixture.prepare(missing) }

        let duplicate = try fixture.rewrite("duplicate.zip") { entries in
            entries + entries.filter { $0.path == original }.map { ($0.path, Data(count: $0.data.count), $0.method) }
        }
        await #expect(throws: BackupRestoreError.graphInvalid) { _ = try await fixture.prepare(duplicate) }

        let logical = try fixture.rewrite("logical.zip") { entries in
            entries.map { entry in
                guard entry.path == BackupArchiveIndex.dataPath else { return entry }
                var data = entry.data
                data[data.index(data.startIndex, offsetBy: 20)] ^= 0x01
                return (entry.path, data, entry.method)
            }
        }
        await #expect(throws: BackupRestoreError.graphInvalid) { _ = try await fixture.prepare(logical) }
        #expect(fixture.leftovers().isEmpty)
    }

    @Test
    func anIndexThatDisagreesWithTheArchiveIsRejected() async throws {
        let fixture = try await BackupArchiveRestoreFixture.make()
        defer { fixture.remove() }
        func withIndex(_ name: String, _ change: (inout [String: Any]) -> Void) throws -> URL {
            try fixture.rewrite(name) { entries in
                entries.map { entry in
                    guard entry.path == BackupArchiveIndex.fileName else { return entry }
                    var object = try! JSONSerialization.jsonObject(with: entry.data) as! [String: Any]
                    change(&object)
                    return (entry.path, try! JSONSerialization.data(withJSONObject: object), entry.method)
                }
            }
        }
        let shorter = try withIndex("shorter.zip") { object in
            var originals = object["originals"] as! [[String: Any]]
            originals[0]["byteCount"] = (originals[0]["byteCount"] as! Int) - 1
            object["originals"] = originals
        }
        await #expect(throws: BackupRestoreError.graphInvalid) { _ = try await fixture.prepare(shorter) }

        let counts = try withIndex("counts.zip") { object in
            var counts = object["counts"] as! [String: Any]
            counts["records"] = 7
            object["counts"] = counts
        }
        await #expect(throws: BackupRestoreError.graphInvalid) { _ = try await fixture.prepare(counts) }

        let library = try withIndex("library.zip") { object in
            var library = object["library"] as! [String: Any]
            library["generation"] = (library["generation"] as! Int) + 1
            object["library"] = library
        }
        await #expect(throws: BackupRestoreError.graphInvalid) { _ = try await fixture.prepare(library) }

        let newer = try withIndex("newer.zip") { object in
            object["formatVersion"] = 2
            object["minimumReaderVersion"] = 2
        }
        await #expect(throws: BackupRestoreError.unsupportedFormat) { _ = try await fixture.prepare(newer) }

        let encrypted = try withIndex("encrypted.zip") { $0["encryption"] = "aes-256-gcm" }
        await #expect(throws: BackupRestoreError.unsupportedFormat) { _ = try await fixture.prepare(encrypted) }
        #expect(fixture.leftovers().isEmpty)
    }

    @Test
    func anEntryThatInflatesPastItsDeclaredSizeIsStopped() async throws {
        let fixture = try await BackupArchiveRestoreFixture.make()
        defer { fixture.remove() }
        // The data entry really inflates to a megabyte more than the index and the ZIP
        // headers claim; reading must stop at the declared size instead of following it.
        let declared = try #require(UInt32(exactly: fixture.index.data.byteCount))
        let bomb = try fixture.rewrite("bomb.zip") { entries in
            entries.map { $0.path == BackupArchiveIndex.dataPath ? ($0.path, $0.data + Data(count: 1_000_000), .deflate) : $0 }
        }
        try patchUncompressedSize(of: BackupArchiveIndex.dataPath, in: bomb, to: declared)
        await #expect(throws: BackupRestoreError.graphInvalid) { _ = try await fixture.prepare(bomb) }

        let larger = try fixture.rewrite("larger.zip") { entries in
            entries.map { $0.path == BackupArchiveIndex.dataPath ? ($0.path, $0.data + Data(count: 16), $0.method) : $0 }
        }
        await #expect(throws: BackupRestoreError.graphInvalid) { _ = try await fixture.prepare(larger) }
        #expect(fixture.leftovers().isEmpty)
    }
}

/// Rewrites the uncompressed-size fields of one entry's local and central headers.
private func patchUncompressedSize(of path: String, in url: URL, to size: UInt32) throws {
    var bytes = [UInt8](try Data(contentsOf: url))
    let name = Array(path.utf8)
    func little(_ offset: Int, _ count: Int) -> Int {
        (0..<count).reduce(0) { $0 | Int(bytes[offset + $1]) << (8 * $1) }
    }
    var patched = 0
    for offset in 0..<(bytes.count - 46) where bytes[offset] == 0x50 && bytes[offset + 1] == 0x4b {
        let (sizeField, nameLength, nameStart): (Int, Int, Int)
        if bytes[offset + 2] == 0x03 && bytes[offset + 3] == 0x04 {
            (sizeField, nameLength, nameStart) = (offset + 22, little(offset + 26, 2), offset + 30)
        } else if bytes[offset + 2] == 0x01 && bytes[offset + 3] == 0x02 {
            (sizeField, nameLength, nameStart) = (offset + 24, little(offset + 28, 2), offset + 46)
        } else { continue }
        guard nameLength == name.count, nameStart + nameLength <= bytes.count,
              Array(bytes[nameStart..<(nameStart + nameLength)]) == name else { continue }
        for index in 0..<4 { bytes[sizeField + index] = UInt8(truncatingIfNeeded: size >> (8 * UInt32(index))) }
        patched += 1
    }
    guard patched == 2 else { throw CocoaError(.fileReadCorruptFile) }
    try Data(bytes).write(to: url)
}

@Suite("Backup settings store")
struct BackupSettingsStoreTests {
    @Test
    func settingsPersistPrivatelyAndDefaultWhenMissing() throws {
        let parent = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = BackupSettingsStore(rootURL: parent.appendingPathComponent("Backup", isDirectory: true))
        #expect(try store.load() == BackupSettings())
        #expect(!FileManager.default.fileExists(atPath: store.rootURL.path))

        let selection = try BackupFolderSelection(bookmarkData: Data([1, 2, 3]), identity: .init(device: 9, inode: 42))
        let entry = try ledgerEntry(1)
        try store.update { settings in
            settings.folder = selection
            settings.isAutomaticBackupEnabled = true
            settings.retentionCount = try BackupRetentionCount(3)
            settings.ledger = [entry]
            settings.nextSequence = 2
            settings.scheduler.lastFailure = .folderUnavailable
        }
        let loaded = try BackupSettingsStore(rootURL: store.rootURL).load()
        #expect(loaded.folder == selection && loaded.isAutomaticBackupEnabled && loaded.retentionCount.value == 3)
        #expect(loaded.ledger == [entry] && loaded.nextSequence == 2 && loaded.scheduler.lastFailure == .folderUnavailable)
        #expect(try mode(store.rootURL) == 0o700)
        #expect(try mode(store.rootURL.appendingPathComponent("settings.json")) == 0o600)
        // A volume renumbered after a restart still names the same folder.
        #expect(BackupFolderIdentity(device: 1, inode: 42) == selection.identity)
    }

    @Test
    func restoreTurnsAutomaticBackupOffButKeepsTheFolderAndLedger() throws {
        let parent = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = BackupSettingsStore(rootURL: parent.appendingPathComponent("Backup", isDirectory: true))
        try store.disableAutomaticBackupForRestore()
        let selection = try BackupFolderSelection(bookmarkData: Data([1]), identity: .init(device: 1, inode: 2))
        try store.update { settings in
            settings.folder = selection
            settings.isAutomaticBackupEnabled = true
            settings.ledger = [try ledgerEntry(1)]
            settings.nextSequence = 2
            settings.scheduler.dueAt = Date(timeIntervalSince1970: 100)
        }
        try store.disableAutomaticBackupForRestore()
        let loaded = try store.load()
        #expect(!loaded.isAutomaticBackupEnabled && loaded.folder == selection && loaded.ledger.count == 1)
        #expect(loaded.scheduler == BackupSchedulerState())
    }

    @Test
    func anUnreadableRecordFailsClosedButCanStillBeRemoved() throws {
        let parent = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = BackupSettingsStore(rootURL: parent.appendingPathComponent("Backup", isDirectory: true))
        try store.update { $0.isAutomaticBackupEnabled = true }
        let record = store.rootURL.appendingPathComponent("settings.json")
        try Data("{\"magic\":\"other\"}".utf8).write(to: record)
        #expect(chmod(record.path, 0o600) == 0)
        #expect(throws: BackupSettingsStoreError.invalidRecord) { _ = try store.load() }
        try store.disableAutomaticBackupForRestore()
        #expect(try store.load() == BackupSettings())

        try store.update { $0.isAutomaticBackupEnabled = true }
        try store.remove()
        #expect(try store.load() == BackupSettings())
    }

}

@Suite("Backup folder retention")
struct BackupFolderRetentionTests {
    @Test
    func keepsTheNewestOwnBackupsAndNeverTouchesFilesThatChanged() throws {
        let folder = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ledger = try (1...5).map { sequence in try writeBackup(folder, sequence: sequence) }
        // The person renamed one, rewrote another and put an unrelated file next to them.
        try FileManager.default.moveItem(at: folder.appendingPathComponent("Backup 2.zip"), to: folder.appendingPathComponent("Kept by me.zip"))
        try Data("changed".utf8).write(to: folder.appendingPathComponent("Backup 3.zip"))
        try Data("mine".utf8).write(to: folder.appendingPathComponent("Backup 0.zip"))

        let outcome = BackupFolderRetention.apply(folder: folder, ledger: ledger, count: try BackupRetentionCount(2), newest: 5)

        #expect(!outcome.deferred && outcome.deletedCount == 1)
        #expect(outcome.ledger.map(\.sequence) == [4, 5])
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == [
            "Backup 0.zip", "Backup 3.zip", "Backup 4.zip", "Backup 5.zip", "Kept by me.zip",
        ])
    }

    @Test
    func nothingIsDeletedWhenTheNewBackupIsNotThere() throws {
        let folder = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ledger = try (1...3).map { sequence in try writeBackup(folder, sequence: sequence) }
        try FileManager.default.removeItem(at: folder.appendingPathComponent("Backup 3.zip"))

        let outcome = BackupFolderRetention.apply(folder: folder, ledger: ledger, count: try BackupRetentionCount(1), newest: 3)
        #expect(outcome.deletedCount == 0 && outcome.ledger.map(\.sequence) == [1, 2])
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["Backup 1.zip", "Backup 2.zip"])

        let offline = BackupFolderRetention.apply(folder: folder.appendingPathComponent("gone"), ledger: ledger,
                                                  count: try BackupRetentionCount(1), newest: 3)
        #expect(offline.deferred && offline.ledger == ledger)
    }
}

// MARK: - Fixtures

private struct BackupArchiveRestoreFixture {
    let base: BackupArchiveFixture
    let archiveURL: URL
    let index: BackupArchiveIndex
    var container: URL { base.container }

    static func make() async throws -> Self {
        let base = try await BackupArchiveFixture.make(byteCount: 64 * 1_024)
        let url = base.container.appendingPathComponent("source.zip")
        _ = try await BackupArchiveWriter(store: base.store).write(to: .file(url), content: .synthetic)
        let archive = try Archive(url: url, accessMode: .read)
        let index = try BackupArchiveIndex.decode(try extract(try #require(archive[BackupArchiveIndex.fileName]), from: archive))
        return Self(base: base, archiveURL: url, index: index)
    }

    func remove() { base.remove() }

    func entries() throws -> [(path: String, data: Data, method: CompressionMethod)] {
        let archive = try Archive(url: archiveURL, accessMode: .read)
        return try archive.map { entry in (entry.path, try extract(entry, from: archive), entry.isCompressed ? .deflate : .none) }
    }

    func rewrite(
        _ name: String,
        _ transform: ([(path: String, data: Data, method: CompressionMethod)]) throws -> [(path: String, data: Data, method: CompressionMethod)]
    ) throws -> URL {
        let url = container.appendingPathComponent(name)
        let archive = try Archive(url: url, accessMode: .create)
        for entry in try transform(entries()) {
            try archive.addEntry(with: entry.path, type: .file, uncompressedSize: Int64(entry.data.count),
                                 compressionMethod: entry.method) { position, size in
                entry.data.subdata(in: Int(position)..<(Int(position) + size))
            }
        }
        return url
    }

    func prepare(_ url: URL) async throws -> BackupPreparedRestore {
        let root = container.appendingPathComponent("Restored-\(UUID().uuidString)", isDirectory: true)
        let owner = try SQLiteLibraryOwner(rootURL: root)
        let verifier = try BackupRestoreVerifier(owner: owner)
        let prepared = try await verifier.prepare(archiveURL: url)
        try verifier.cancel(prepared)
        return prepared
    }

    /// Restore staging and receipts left beside the library roots.
    func leftovers() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: container.path)) ?? [])
            .filter { $0.hasSuffix(".staging") || $0.hasSuffix(".preflight.json") || $0.hasSuffix(".spool") }
    }
}

private func privateDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return url
}

private func mode(_ url: URL) throws -> mode_t {
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0 else { throw CocoaError(.fileNoSuchFile) }
    return metadata.st_mode & 0o777
}

private func ledgerEntry(_ sequence: UInt64) throws -> BackupLedgerEntry {
    BackupLedgerEntry(
        sequence: sequence, fileName: "Backup \(sequence).zip", inode: 100 + sequence, byteCount: 10,
        modifiedSeconds: 1, modifiedNanoseconds: 2, backupID: UUID(),
        createdAt: Date(timeIntervalSince1970: TimeInterval(sequence)),
        library: try BackupLibraryRevision(libraryID: UUID(), generation: 1, commitID: UUID())
    )
}

private func writeBackup(_ folder: URL, sequence: UInt64) throws -> BackupLedgerEntry {
    let url = folder.appendingPathComponent("Backup \(sequence).zip")
    try Data("backup \(sequence)".utf8).write(to: url)
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0 else { throw CocoaError(.fileNoSuchFile) }
    return BackupLedgerEntry(
        sequence: sequence, fileName: url.lastPathComponent, inode: UInt64(metadata.st_ino), byteCount: UInt64(metadata.st_size),
        modifiedSeconds: Int64(metadata.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(metadata.st_mtimespec.tv_nsec),
        backupID: UUID(), createdAt: Date(timeIntervalSince1970: TimeInterval(sequence)),
        library: try BackupLibraryRevision(libraryID: UUID(), generation: 1, commitID: UUID())
    )
}
