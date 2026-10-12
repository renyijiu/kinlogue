import Darwin
import Foundation
import GRDB
import KinlogueCore
import KinlogueSQLiteConfiguration

package enum SQLiteLogicalCapturePhase: Sendable { case directoryCreated, receiptDurable, copyStep, logicalValidation }

/// A disposable copy of our own database, never a recovery-point payload.
/// A durable receipt owns one exact private directory and database inode.
final class SQLiteLogicalCaptureDatabase {
    private struct Receipt: Codable, Equatable {
        let version: Int
        let operationID: UUID
        let rootDigest: Data
        let directoryIdentity: BackupRestoreDirectoryIdentity
        let databaseDevice: Int64
        let databaseInode: Int64
    }
    let queue: DatabaseQueue
    private let parent: URL
    private let parentIdentity: SQLiteFileIdentity
    private let directoryName: String
    private let receiptName: String
    private let receipt: Receipt
    private let receiptIdentity: SQLiteFileIdentity
    private var closed = false

    init(rootURL: URL, operationID: UUID = UUID(), observation: (@Sendable (SQLiteLogicalCapturePhase) throws -> Void)? = nil) throws {
        parent = rootURL.deletingLastPathComponent()
        parentIdentity = try SQLiteFileIdentity.directory(at: parent, privateMode: false)
        let descriptor = try Self.openParent(parent, expected: parentIdentity)
        defer { Darwin.close(descriptor) }
        let prefix = Self.prefix(rootURL)
        directoryName = prefix + operationID.uuidString.lowercased() + ".staging"
        receiptName = prefix + operationID.uuidString.lowercased() + ".receipt.json"
        guard mkdirat(descriptor, directoryName, 0o700) == 0 else { throw SQLiteLibraryError.ioFailure(errno) }
        let identity = try BackupRestoreFilesystem.directoryIdentity(named: directoryName, parentDescriptor: descriptor)
        // No payload is written before the receipt is durable. A crash here leaves an
        // unknown empty artifact, which startup preserves without blocking the library.
        try observation?(.directoryCreated)
        let directoryURL = parent.appendingPathComponent(directoryName)
        let directory = try BackupRestoreFilesystem.openStrictDirectory(directoryURL)
        defer { Darwin.close(directory) }
        try BackupRestoreFilesystem.writeExclusiveFile(Data(), named: "snapshot.sqlite", parentDescriptor: directory)
        let fileURL = directoryURL.appendingPathComponent("snapshot.sqlite")
        let fileIdentity = try SQLiteFileIdentity.regular(at: fileURL)
        let value = Receipt(version: 1, operationID: operationID, rootDigest: Self.rootDigest(rootURL), directoryIdentity: identity,
            databaseDevice: fileIdentity.device, databaseInode: fileIdentity.inode)
        receipt = value
        let cleanupDirectory = directoryName, cleanupReceipt = receiptName
        var ownedReceipt: SQLiteFileIdentity?, completed = false
        defer {
            if !completed {
                try? Self.removeDirectory(cleanupDirectory, receipt: value, parent: descriptor)
                if let ownedReceipt { try? Self.removeOwnedFile(cleanupReceipt, identity: ownedReceipt, parent: descriptor) }
            }
        }
        receiptIdentity = try Self.writeReceipt(CanonicalVaultJSON.encode(value), name: receiptName, parent: descriptor)
        ownedReceipt = receiptIdentity
        try observation?(.receiptDurable)
        var configuration = Configuration()
        configuration.busyMode = .immediateError
        configuration.prepareDatabase { db in
            guard kinlogue_sqlite_configure(db.sqliteConnection) == SQLITE_OK else { throw SQLiteLibraryError.unsupportedConfiguration }
            try db.execute(sql: "PRAGMA trusted_schema=OFF")
            try db.execute(sql: "PRAGMA journal_mode=DELETE")
            // Only the ownership receipt needs durability; this database is disposable.
            try db.execute(sql: "PRAGMA synchronous=OFF")
            try db.execute(sql: "PRAGMA cache_size=-4096")
            // Some system SQLite builds default to a 20,000-page dirty spill
            // threshold even with a smaller cache. Both thresholds must be met.
            // An explicit low numeric threshold keeps the effective spill bound
            // within the cache budget at every supported page size.
            try db.execute(sql: "PRAGMA cache_spill=2")
            try Self.validateCacheBudget(db)
            try db.execute(sql: "PRAGMA mmap_size=0")
        }
        let opened = try DatabaseQueue(path: fileURL.path, configuration: configuration)
        do {
            guard try SQLiteFileIdentity.regular(at: fileURL) == fileIdentity,
                  try SQLiteFileIdentity.directory(at: parent, privateMode: false) == parentIdentity else { throw SQLiteLibraryError.staleRoot }
        } catch { try? opened.close(); throw error }
        queue = opened
        completed = true
    }

    static func validateCacheBudget(_ db: Database) throws {
        guard let pageSize = try Int.fetchOne(db, sql: "PRAGMA page_size"), pageSize > 0,
              let spill = try Int.fetchOne(db, sql: "PRAGMA cache_spill"), spill > 0,
              spill <= (4 * 1_024 * 1_024) / pageSize,
              try Int.fetchOne(db, sql: "PRAGMA cache_size") == -4_096 else {
            throw SQLiteLibraryError.unsupportedConfiguration
        }
    }

    func close() throws {
        if closed { return }
        try queue.close()
        let descriptor = try Self.openParent(parent, expected: parentIdentity)
        defer { Darwin.close(descriptor) }
        guard try Self.readReceipt(receiptName, descriptor) == receipt else { throw SQLiteLogicalBackupError.sourceChanged }
        try Self.requireOwnedFile(receiptName, identity: receiptIdentity, parent: descriptor)
        try Self.removeDirectory(directoryName, receipt: receipt, parent: descriptor)
        try Self.removeOwnedFile(receiptName, identity: receiptIdentity, parent: descriptor)
        try BackupRestoreFilesystem.sync(descriptor)
        closed = true
    }

    /// After lifetime ownership, before opening any connection. This excludes another
    /// live prepare in the same process. Unknown unreceipted artifacts are left alone.
    static func reconcile(owner: SQLiteLibraryOwner) throws {
        try owner.validate(); try owner.requireClosedDatabase()
        let parent = owner.rootURL.deletingLastPathComponent()
        let identity = try SQLiteFileIdentity.directory(at: parent, privateMode: false)
        let descriptor = try openParent(parent, expected: identity)
        defer { Darwin.close(descriptor) }
        let prefix = prefix(owner.rootURL)
        let receipts = try BackupRestoreFilesystem.directChildNames(parentDescriptor: descriptor, prefix: prefix, suffix: ".receipt.json", maximumMatchCount: 64)
        var validated: [(String, String, Receipt, SQLiteFileIdentity)] = []
        for name in receipts {
            let identity = try SQLiteFileIdentity.regular(at: parent.appendingPathComponent(name))
            let receipt = try readReceipt(name, descriptor)
            let stem = prefix + receipt.operationID.uuidString.lowercased()
            guard receipt.version == 1, name == stem + ".receipt.json", receipt.rootDigest == rootDigest(owner.rootURL),
                  receipt.databaseDevice > 0, receipt.databaseInode > 0 else { throw SQLiteLogicalBackupError.invalidStream }
            try validateDirectory(stem + ".staging", receipt: receipt, parent: descriptor)
            try requireOwnedFile(name, identity: identity, parent: descriptor)
            validated.append((name, stem + ".staging", receipt, identity))
        }
        for (name, directory, receipt, identity) in validated {
            try owner.validate()
            try requireOwnedFile(name, identity: identity, parent: descriptor)
            try removeDirectory(directory, receipt: receipt, parent: descriptor)
            try removeOwnedFile(name, identity: identity, parent: descriptor)
        }
        try BackupRestoreFilesystem.sync(descriptor)
    }

    private static func openParent(_ url: URL, expected: SQLiteFileIdentity) throws -> Int32 {
        guard try SQLiteFileIdentity.directory(at: url, privateMode: false) == expected else { throw SQLiteLibraryError.staleRoot }
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw SQLiteLibraryError.ioFailure(errno) }
        var value = stat()
        guard fstat(fd, &value) == 0, Int64(value.st_dev) == expected.device, Int64(value.st_ino) == expected.inode,
              value.st_mode & S_IFMT == S_IFDIR, value.st_uid == geteuid(), value.st_mode & 0o022 == 0 else {
            Darwin.close(fd); throw SQLiteLibraryError.staleRoot
        }
        return fd
    }
    private static func requireOwnedFile(_ name: String, identity: SQLiteFileIdentity, parent: Int32) throws {
        var value = stat()
        guard fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) == 0,
              Int64(value.st_dev) == identity.device, Int64(value.st_ino) == identity.inode,
              value.st_mode & S_IFMT == S_IFREG, value.st_uid == geteuid(), value.st_nlink == 1,
              value.st_mode & 0o7777 == 0o600 else { throw SQLiteLogicalBackupError.sourceChanged }
    }
    private static func removeOwnedFile(_ name: String, identity: SQLiteFileIdentity, parent: Int32) throws {
        try requireOwnedFile(name, identity: identity, parent: parent)
        guard unlinkat(parent, name, 0) == 0 else { throw SQLiteLibraryError.ioFailure(errno) }
    }
    private static func writeReceipt(_ bytes: Data, name: String, parent: Int32) throws -> SQLiteFileIdentity {
        // Publish only a complete fsynced receipt. A torn preparation is not authority.
        let temporary = name + ".preparing-" + UUID().uuidString.lowercased()
        let fd = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SQLiteLibraryError.ioFailure(errno) }
        defer { Darwin.close(fd) }
        let identity = try SQLiteFileIdentity.regular(descriptor: fd)
        var published = false
        do {
            try bytes.withUnsafeBytes { buffer in
                var done = 0
                while done < buffer.count {
                    let count = write(fd, buffer.baseAddress!.advanced(by: done), buffer.count - done)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw SQLiteLibraryError.ioFailure(errno) }; done += count
                }
            }
            try BackupRestoreFilesystem.sync(fd)
            try requireOwnedFile(temporary, identity: identity, parent: parent)
            guard renameatx_np(parent, temporary, parent, name, UInt32(RENAME_EXCL)) == 0 else { throw SQLiteLibraryError.ioFailure(errno) }
            published = true
            try BackupRestoreFilesystem.sync(parent)
            return identity
        } catch {
            try? removeOwnedFile(published ? name : temporary, identity: identity, parent: parent)
            throw error
        }
    }
    private static func validateDirectory(_ name: String, receipt: Receipt, parent: Int32) throws {
        guard let actual = try BackupRestoreFilesystem.directoryIdentityIfPresent(named: name, parentDescriptor: parent) else { return }
        guard actual == receipt.directoryIdentity else { throw SQLiteLogicalBackupError.sourceChanged }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw SQLiteLogicalBackupError.sourceChanged }
        defer { Darwin.close(fd) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, receipt.directoryIdentity.matches(metadata) else { throw SQLiteLogicalBackupError.sourceChanged }
        let names = try BackupRestoreFilesystem.directChildNames(parentDescriptor: fd, prefix: "", suffix: "", maximumMatchCount: 5).filter { $0 != "." && $0 != ".." }
        // DELETE mode creates only its rollback journal. No directories or foreign files.
        guard Set(names).isSubset(of: ["snapshot.sqlite", "snapshot.sqlite-journal"]) else { throw SQLiteLogicalBackupError.sourceChanged }
        for child in names {
            if child == "snapshot.sqlite" {
                try requireOwnedFile(child, identity: SQLiteFileIdentity(device: receipt.databaseDevice, inode: receipt.databaseInode), parent: fd)
            } else {
                let childFD = openat(fd, child, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
                guard childFD >= 0 else { throw SQLiteLogicalBackupError.sourceChanged }
                defer { Darwin.close(childFD) }
                _ = try SQLiteFileIdentity.regular(descriptor: childFD)
            }
        }
    }
    private static func removeDirectory(_ name: String, receipt: Receipt, parent: Int32) throws {
        try validateDirectory(name, receipt: receipt, parent: parent)
        try BackupRestoreFilesystem.removeDirectoryTree(named: name, expectedIdentity: receipt.directoryIdentity, parentDescriptor: parent)
    }
    private static func readReceipt(_ name: String, _ parent: Int32) throws -> Receipt {
        let fd = openat(parent, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw SQLiteLogicalBackupError.invalidStream }
        defer { Darwin.close(fd) }
        _ = try SQLiteFileIdentity.regular(descriptor: fd)
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_size > 0, metadata.st_size <= 4096 else { throw SQLiteLogicalBackupError.invalidStream }
        var bytes = Data(count: Int(metadata.st_size))
        try bytes.withUnsafeMutableBytes { buffer in
            var done = 0
            while done < buffer.count {
                let count = pread(fd, buffer.baseAddress!.advanced(by: done), buffer.count - done, off_t(done))
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw SQLiteLogicalBackupError.invalidStream }; done += count
            }
        }
        var after = stat(), named = stat()
        guard fstat(fd, &after) == 0, fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              metadata.st_dev == named.st_dev, metadata.st_ino == named.st_ino,
              metadata.st_size == after.st_size, metadata.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, metadata.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              metadata.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, metadata.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw SQLiteLogicalBackupError.sourceChanged }
        let receipt = try CanonicalVaultJSON.decode(Receipt.self, from: bytes)
        guard try CanonicalVaultJSON.encode(receipt) == bytes else { throw SQLiteLogicalBackupError.invalidStream }
        return receipt
    }
    private static func rootDigest(_ root: URL) -> Data { ContentDigest.sha256(Data(root.lastPathComponent.utf8)) }
    private static func prefix(_ root: URL) -> String { ".kinlogue-sqlite-capture-" + rootDigest(root).map { String(format: "%02x", $0) }.joined() + "-" }
    deinit { try? close() }
}

extension SQLiteLogicalBackupSource {
    package static func reconcileTemporaryCaptures(owner: SQLiteLibraryOwner) throws {
        try SQLiteLogicalCaptureDatabase.reconcile(owner: owner)
    }
}
