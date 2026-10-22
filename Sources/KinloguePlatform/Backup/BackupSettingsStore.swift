import Darwin
import Foundation
import KinlogueCore

public enum BackupSettingsStoreError: Error, Equatable, Sendable {
    case invalidRoot
    case invalidRecord
    case recordTooLarge
    case ioFailure
}

/// A directory as a record identifies it. Only the inode is compared: macOS can give a volume
/// another device number after a restart or an update, and a directory is always reached
/// through its bookmark or a fixed parent, so the inode is what tells a replacement apart.
public struct BackupFolderIdentity: Codable, Hashable, Sendable {
    public let device: UInt64
    public let inode: UInt64

    public init(device: UInt64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.inode == rhs.inode }
    public func hash(into hasher: inout Hasher) { hasher.combine(inode) }
}

public struct BackupFolderSelection: Codable, Hashable, Sendable {
    public static let maximumBookmarkByteCount = 128 * 1_024

    public let bookmarkData: Data
    public let identity: BackupFolderIdentity

    public init(bookmarkData: Data, identity: BackupFolderIdentity) throws {
        guard !bookmarkData.isEmpty, bookmarkData.count <= Self.maximumBookmarkByteCount else {
            throw BackupSettingsStoreError.invalidRecord
        }
        self.bookmarkData = bookmarkData
        self.identity = identity
    }
}

/// When the next automatic backup is due and why the last one did not finish.
public struct BackupSchedulerState: Codable, Hashable, Sendable {
    public var firstObservedRevision: BackupLibraryRevision?
    public var firstObservedAt: Date?
    public var dueAt: Date?
    public var lastCoveredRevision: BackupLibraryRevision?
    public var lastBackupAt: Date?
    public var lastBackupFileName: String?
    public var lastFailure: BackupFailure?
    public var retryAttempt: Int
    public var retryDueAt: Date?

    public init() {
        retryAttempt = 0
    }
}

/// Everything about backups that stays on this Mac: the chosen folder, the automation
/// preferences, scheduler timing and the ledger of backups written into the folder.
public struct BackupSettings: Hashable, Sendable {
    public static let maximumLedgerCount = 256

    public var folder: BackupFolderSelection?
    public var isAutomaticBackupEnabled: Bool
    public var retentionCount: BackupRetentionCount
    public var scheduler: BackupSchedulerState
    public var nextSequence: UInt64
    public var ledger: [BackupLedgerEntry]

    public init() {
        folder = nil
        isAutomaticBackupEnabled = false
        retentionCount = .default
        scheduler = BackupSchedulerState()
        nextSequence = 1
        ledger = []
    }
}

/// App-private, owner-only storage for `BackupSettings`. Every change is one
/// read-modify-write under an exclusive lock and lands through an atomic rename.
// SAFETY: processLock serializes every file transaction across instances in this process and
// flock serializes them across processes; the instance itself holds no mutable state.
public final class BackupSettingsStore: @unchecked Sendable {
    private static let recordName = "settings.json"
    private static let lockName = ".settings.lock"
    private static let magic = "KLG-BACKUP-SETTINGS-1"
    private static let maximumRecordByteCount = 512 * 1_024
    private static let processLock = NSLock()

    public let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    /// The stored settings, or the defaults when nothing has been stored yet.
    public func load() throws -> BackupSettings {
        let stored = try withExclusiveAccess(create: false) { root in try Self.read(at: root) }
        return (stored ?? nil) ?? BackupSettings()
    }

    @discardableResult
    public func update<Result>(_ body: (inout BackupSettings) throws -> Result) throws -> Result {
        let result = try withExclusiveAccess(create: true) { root in
            var settings = try Self.read(at: root) ?? BackupSettings()
            let result = try body(&settings)
            try Self.write(settings, at: root)
            return result
        }
        guard let result else { throw BackupSettingsStoreError.invalidRoot }
        return result
    }

    /// Removes the stored settings when the library is deleted. A record that no longer reads
    /// must not block that, so only the file's kind and owner are checked.
    public func remove() throws {
        _ = try withExclusiveAccess(create: false) { root -> Void in
            try Self.removeRecord(at: root)
        }
    }

    /// Run inside a restore, after the old library is gone: keeps the folder and the ledger
    /// but turns automatic backups off, so they cannot rotate out backups made before the
    /// restore until the person turns them on again. An unreadable record is removed instead.
    public func disableAutomaticBackupForRestore() throws {
        _ = try withExclusiveAccess(create: false) { root -> Void in
            let settings: BackupSettings?
            do { settings = try Self.read(at: root) } catch { try Self.removeRecord(at: root); return }
            guard var settings else { return }
            settings.isAutomaticBackupEnabled = false
            settings.scheduler = BackupSchedulerState()
            try Self.write(settings, at: root)
        }
    }

    // MARK: Files

    private func withExclusiveAccess<T>(create: Bool, _ body: (Int32) throws -> T) throws -> T? {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        guard let root = try openRoot(create: create) else { return nil }
        defer { Darwin.close(root) }
        let identity = try Self.directoryIdentity(root)
        let lock = openat(root, Self.lockName, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw BackupSettingsStoreError.ioFailure }
        defer { Darwin.close(lock) }
        guard Self.isOwnerPrivateFile(lock), flock(lock, LOCK_EX) == 0 else { throw BackupSettingsStoreError.ioFailure }
        defer { _ = flock(lock, LOCK_UN) }
        guard try Self.directoryIdentity(root) == identity else { throw BackupSettingsStoreError.invalidRoot }
        return try body(root)
    }

    private func openRoot(create: Bool) throws -> Int32? {
        let parent = Darwin.open(rootURL.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else {
            if errno == ENOENT, !create { return nil }
            throw BackupSettingsStoreError.invalidRoot
        }
        defer { Darwin.close(parent) }
        let name = rootURL.lastPathComponent
        guard !name.isEmpty, name != ".", name != ".." else { throw BackupSettingsStoreError.invalidRoot }
        if create, mkdirat(parent, name, 0o700) != 0, errno != EEXIST { throw BackupSettingsStoreError.invalidRoot }
        let root = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else {
            if errno == ENOENT, !create { return nil }
            throw BackupSettingsStoreError.invalidRoot
        }
        return root
    }

    private static func directoryIdentity(_ descriptor: Int32) throws -> BackupFolderIdentity {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == geteuid(), metadata.st_mode & 0o777 == 0o700 else {
            throw BackupSettingsStoreError.invalidRoot
        }
        return .init(device: UInt64(metadata.st_dev), inode: UInt64(metadata.st_ino))
    }

    private static func isOwnerPrivateFile(_ descriptor: Int32) -> Bool {
        var metadata = stat()
        return fstat(descriptor, &metadata) == 0 && (metadata.st_mode & S_IFMT) == S_IFREG
            && metadata.st_uid == geteuid() && metadata.st_nlink == 1 && metadata.st_mode & 0o777 == 0o600
    }

    private static func read(at root: Int32) throws -> BackupSettings? {
        let descriptor = openat(root, recordName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw BackupSettingsStoreError.invalidRecord
        }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard isOwnerPrivateFile(descriptor), fstat(descriptor, &metadata) == 0 else {
            throw BackupSettingsStoreError.invalidRecord
        }
        guard metadata.st_size <= maximumRecordByteCount else { throw BackupSettingsStoreError.recordTooLarge }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw BackupSettingsStoreError.ioFailure }
            if count == 0 { break }
            guard data.count + count <= maximumRecordByteCount else { throw BackupSettingsStoreError.recordTooLarge }
            data.append(contentsOf: buffer[..<count])
        }
        let wire: Wire
        do { wire = try CanonicalVaultJSON.decode(Wire.self, from: data) } catch {
            throw BackupSettingsStoreError.invalidRecord
        }
        return try wire.settings()
    }

    private static func write(_ settings: BackupSettings, at root: Int32) throws {
        let bytes: Data
        do { bytes = try CanonicalVaultJSON.encode(try Wire(settings)) } catch {
            throw BackupSettingsStoreError.invalidRecord
        }
        guard bytes.count <= maximumRecordByteCount else { throw BackupSettingsStoreError.recordTooLarge }
        let workName = ".settings.\(UUID().uuidString.lowercased()).work"
        let descriptor = openat(root, workName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw BackupSettingsStoreError.ioFailure }
        var published = false
        defer {
            Darwin.close(descriptor)
            if !published { _ = unlinkat(root, workName, 0) }
        }
        guard fchmod(descriptor, 0o600) == 0 else { throw BackupSettingsStoreError.ioFailure }
        try bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw BackupSettingsStoreError.ioFailure }
                offset += count
            }
        }
        try synchronize(descriptor)
        guard renameat(root, workName, root, recordName) == 0 else { throw BackupSettingsStoreError.ioFailure }
        published = true
        try synchronize(root)
    }

    private static func removeRecord(at root: Int32) throws {
        var metadata = stat()
        guard fstatat(root, recordName, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return }
            throw BackupSettingsStoreError.ioFailure
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG, metadata.st_uid == geteuid(), metadata.st_nlink == 1,
              unlinkat(root, recordName, 0) == 0 else {
            throw BackupSettingsStoreError.invalidRecord
        }
        try synchronize(root)
    }

    private static func synchronize(_ descriptor: Int32) throws {
        if fcntl(descriptor, F_FULLFSYNC) == 0 { return }
        guard fsync(descriptor) == 0 else { throw BackupSettingsStoreError.ioFailure }
    }

    private struct Wire: Codable {
        let magic: String
        let version: Int
        let folder: BackupFolderSelection?
        let automaticEnabled: Bool
        let retentionCount: Int
        let scheduler: BackupSchedulerState
        let nextSequence: UInt64
        let ledger: [BackupLedgerEntry]

        init(_ settings: BackupSettings) throws {
            magic = BackupSettingsStore.magic
            version = 1
            folder = settings.folder
            automaticEnabled = settings.isAutomaticBackupEnabled
            retentionCount = settings.retentionCount.value
            scheduler = settings.scheduler
            nextSequence = settings.nextSequence
            ledger = settings.ledger
            guard ledger.count <= BackupSettings.maximumLedgerCount else { throw BackupSettingsStoreError.recordTooLarge }
        }

        func settings() throws -> BackupSettings {
            guard magic == BackupSettingsStore.magic, version == 1, nextSequence > 0,
                  ledger.count <= BackupSettings.maximumLedgerCount,
                  ledger.allSatisfy({ $0.sequence < nextSequence && BackupArchiveWriter.isSinglePathComponent($0.fileName) }),
                  Set(ledger.map(\.sequence)).count == ledger.count,
                  scheduler.retryAttempt >= 0 else {
                throw BackupSettingsStoreError.invalidRecord
            }
            if let folder {
                _ = try BackupFolderSelection(bookmarkData: folder.bookmarkData, identity: folder.identity)
            }
            var settings = BackupSettings()
            settings.folder = folder
            settings.isAutomaticBackupEnabled = automaticEnabled
            do { settings.retentionCount = try BackupRetentionCount(retentionCount) } catch {
                throw BackupSettingsStoreError.invalidRecord
            }
            settings.scheduler = scheduler
            settings.nextSequence = nextSequence
            settings.ledger = ledger
            return settings
        }
    }
}
