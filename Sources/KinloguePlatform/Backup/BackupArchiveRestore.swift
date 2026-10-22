import Darwin
import Foundation
import KinlogueCore

public enum BackupRestoreError: Error, Equatable, Sendable {
    case invalidSource
    /// The file is not a Kinlogue backup archive.
    case notABackup
    case sourceChanged
    case unsupportedFormat
    case graphInvalid
    case capacityInsufficient
    case stagingConflict
    case receiptInvalid
    case activationConflict
    case ioFailure(Int32)
    case injectedFailure
}

/// What the person confirms before a restore: when the backup was made and how much it holds,
/// never any health content.
public struct BackupRestoreSummary: Equatable, Sendable {
    public let backupID: UUID
    public let revisionPair: BackupRevisionPair
    public let createdAt: Date
    public let creatorVersion: String
    public let memberCount: Int
    public let recordCount: Int
    public let inboxItemCount: Int
    public let originalCount: Int
    public let plaintextByteCount: UInt64
    /// The digest of the logical stream this summary was validated against.
    package let logicalDigest: Data

    public init(
        backupID: UUID,
        revisionPair: BackupRevisionPair,
        createdAt: Date,
        creatorVersion: String,
        memberCount: Int,
        recordCount: Int,
        inboxItemCount: Int,
        originalCount: Int,
        plaintextByteCount: UInt64,
        logicalDigest: Data
    ) {
        self.backupID = backupID
        self.revisionPair = revisionPair
        self.createdAt = createdAt
        self.creatorVersion = creatorVersion
        self.memberCount = memberCount
        self.recordCount = recordCount
        self.inboxItemCount = inboxItemCount
        self.originalCount = originalCount
        self.plaintextByteCount = plaintextByteCount
        self.logicalDigest = logicalDigest
    }
}

public struct BackupPreparedRestore: Sendable {
    public let summary: BackupRestoreSummary
    let operationID: UUID
    let stagingURL: URL
    let stagingIdentity: BackupRestoreDirectoryIdentity
    let preflightReceiptURL: URL
    let activeRootName: String
}

/// A directory beside the library, as a restore or capture receipt recorded it.
///
/// Receipts are read again by the launch after an interrupted operation, and macOS can give the
/// volume another device number in between. The device number is therefore kept but not
/// compared: the directories a receipt names are found by a fixed name under the library's
/// pinned parent, so the inode is what tells the recorded directory from a replacement.
struct BackupRestoreDirectoryIdentity: Codable, Equatable, Sendable {
    let device: UInt64
    let inode: UInt64

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.inode == rhs.inode }

    init(_ metadata: stat) throws {
        guard (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == geteuid(),
              (metadata.st_mode & 0o777) == S_IRWXU,
              let device = UInt64(exactly: metadata.st_dev),
              let inode = UInt64(exactly: metadata.st_ino),
              device > 0,
              inode > 0 else {
            throw BackupRestoreError.stagingConflict
        }
        self.device = device
        self.inode = inode
    }

    func matches(_ metadata: stat) -> Bool {
        inode == UInt64(metadata.st_ino)
            && (metadata.st_mode & S_IFMT) == S_IFDIR
            && metadata.st_uid == geteuid()
            && (metadata.st_mode & 0o777) == S_IRWXU
    }
}

struct BackupRestorePreflightReceipt: Codable, Equatable {
    static let magic = "KLGRESTOREPREFLIGHT1"
    let magic: String
    let version: Int
    let operationID: UUID
    let activeRootNameDigest: Data
    /// The backup's identifier; the field keeps the name receipts were first written with.
    let checkpointID: Data
    let stagingName: String
    let stagingIdentity: BackupRestoreDirectoryIdentity
}

/// Verifies a backup archive and reconstructs one complete library root beneath the trusted
/// Application Support parent. It does not depend on a bookmark or on the backup settings.
// SAFETY: The verifier stores only immutable URLs and a Sendable capacity
// closure; each prepare call owns all descriptors and staging state it creates.
public final class BackupRestoreVerifier: @unchecked Sendable {
    public typealias AvailableCapacity = @Sendable () throws -> UInt64

    private let stableParentURL: URL
    private let activeRootURL: URL
    private let availableCapacity: AvailableCapacity
    private let owner: SQLiteLibraryOwner

    private static func stagingName(for operationID: UUID) -> String {
        ".kinlogue-restore-\(operationID.uuidString.lowercased()).staging"
    }

    private static func preflightReceiptName(for operationID: UUID) -> String {
        ".kinlogue-restore-\(operationID.uuidString.lowercased()).preflight.json"
    }

    package convenience init(owner: SQLiteLibraryOwner) throws {
        let parent = owner.rootURL.standardizedFileURL.deletingLastPathComponent()
        try self.init(owner: owner, availableCapacity: {
            var information = statfs()
            guard statfs(parent.path, &information) == 0,
                  information.f_bavail >= 0,
                  information.f_bsize > 0 else {
                throw BackupRestoreError.ioFailure(errno)
            }
            let blocks = UInt64(information.f_bavail)
            let size = UInt64(information.f_bsize)
            let bytes = blocks.multipliedReportingOverflow(by: size)
            guard !bytes.overflow else { return UInt64.max }
            return bytes.partialValue
        })
    }

    init(owner: SQLiteLibraryOwner, availableCapacity: @escaping AvailableCapacity) throws {
        let root = owner.rootURL.standardizedFileURL
        let parent = root.deletingLastPathComponent()
        guard parent.isFileURL,
              root.isFileURL,
              !root.lastPathComponent.isEmpty,
              !root.lastPathComponent.hasPrefix(".") else {
            throw BackupRestoreError.stagingConflict
        }
        let parentDescriptor = try BackupRestoreFilesystem.openStrictDirectory(parent)
        Darwin.close(parentDescriptor)
        self.stableParentURL = parent
        self.activeRootURL = root
        self.availableCapacity = availableCapacity
        self.owner = owner
        try owner.validate()
    }

    @concurrent public func prepare(archiveURL: URL) async throws -> BackupPreparedRestore {
        try await LibraryStorageExecutor.run {
            let cancellation = SQLiteLogicalCancellation()
            return try await withTaskCancellationHandler {
                try prepareArchive(archiveURL, cancellation: cancellation)
            } onCancel: { cancellation.cancel() }
        }
    }

    /// Reads the archive's index, stages its data stream and originals, and rebuilds and
    /// strictly validates a complete library in private staging. The active library is not
    /// touched; the returned summary is what the person confirms.
    private func prepareArchive(_ archiveURL: URL, cancellation: SQLiteLogicalCancellation) throws -> BackupPreparedRestore {
        try Task.checkCancellation()
        try owner.validate()
        let reader: BackupArchiveReader
        do { reader = try BackupArchiveReader(url: archiveURL) } catch is CancellationError {
            throw CancellationError()
        } catch { throw Self.map(error) }
        defer { reader.close() }
        let index = reader.index
        let logicalBytes = index.data.byteCount
        // The staged originals and data stream, the strict-validation spool and headroom;
        // the database itself is budgeted from the actual records below.
        let required = index.totalByteCount.addingReportingOverflow(
            BackupArchiveLimits.capacityHeadroomByteCount + logicalBytes + (logicalBytes > 0 ? 1_024 * 1_024 : 0)
        )
        guard !required.overflow, try availableCapacity() >= required.partialValue else {
            throw BackupRestoreError.capacityInsufficient
        }
        guard logicalBytes <= UInt64(Int.max) else { throw BackupRestoreError.capacityInsufficient }
        let revisionPair: BackupRevisionPair
        do {
            revisionPair = try SQLiteLogicalBackupSource.revision(BackupLogicalHeaderV1(
                libraryID: index.library.libraryID, generation: index.library.generation, commitID: index.library.commitID
            ))
        } catch { throw BackupRestoreError.graphInvalid }

        let operationID = UUID()
        let stagingName = Self.stagingName(for: operationID)
        let receiptName = Self.preflightReceiptName(for: operationID)
        let stagingURL = stableParentURL.appendingPathComponent(stagingName, isDirectory: true)
        let receiptURL = stableParentURL.appendingPathComponent(receiptName, isDirectory: false)
        let parentDescriptor = try BackupRestoreFilesystem.openStrictDirectory(stableParentURL)
        defer { Darwin.close(parentDescriptor) }
        guard mkdirat(parentDescriptor, stagingName, 0o700) == 0 else { throw BackupRestoreError.stagingConflict }
        let stagingIdentity = try BackupRestoreFilesystem.directoryIdentity(named: stagingName, parentDescriptor: parentDescriptor)
        let receipt = BackupRestorePreflightReceipt(
            magic: BackupRestorePreflightReceipt.magic,
            version: 1,
            operationID: operationID,
            activeRootNameDigest: ContentDigest.sha256(Data(activeRootURL.lastPathComponent.utf8)),
            checkpointID: index.backupID.sqliteBytes,
            stagingName: stagingName,
            stagingIdentity: stagingIdentity
        )
        do {
            try BackupRestoreFilesystem.writeExclusiveFile(try CanonicalVaultJSON.encode(receipt), named: receiptName,
                                                           parentDescriptor: parentDescriptor)
            try BackupRestoreFilesystem.sync(parentDescriptor)
        } catch {
            try? BackupRestoreFilesystem.removeDirectoryTree(named: stagingName, expectedIdentity: stagingIdentity,
                                                             parentDescriptor: parentDescriptor)
            throw Self.map(error)
        }

        do {
            try owner.validate()
            let logicalSpool = try SQLiteLogicalSpool(parent: stableParentURL, maximumByteCount: Int(logicalBytes))
            defer { logicalSpool.release() }
            let stagingStore = try SQLiteLibraryStore(rootURL: stagingURL)
            defer { try? stagingStore.close() }
            let staging = try BackupRestoreOutput(parentDescriptor: parentDescriptor, stagingName: stagingName,
                                                  expectedIdentity: stagingIdentity, logicalSpool: logicalSpool)
            try reader.extract(index.data) { try logicalSpool.append($0) }
            for original in index.originals {
                try cancellation.check()
                let writer = try staging.originalWriter(id: original.id, byteCount: original.entry.byteCount)
                do {
                    try reader.extract(original.entry) { try writer.append($0) }
                    try writer.finish()
                } catch { writer.close(); throw error }
            }
            try staging.finish()
            try reader.checkUnchanged()
            let databaseBytes = try SQLiteLogicalRestore.databaseBudget(spool: logicalSpool, check: cancellation.check)
            let remaining = databaseBytes.addingReportingOverflow(logicalBytes + BackupArchiveLimits.capacityHeadroomByteCount)
            guard !remaining.overflow, try availableCapacity() >= remaining.partialValue else {
                throw BackupRestoreError.capacityInsufficient
            }
            let expected = Dictionary(uniqueKeysWithValues: index.originals.map {
                ($0.id, SQLiteLogicalRestore.ExpectedOriginal(byteCount: $0.entry.byteCount, sha256: $0.entry.sha256, contentType: $0.contentType))
            })
            let validation = try SQLiteLogicalRestore.restore(spool: logicalSpool, originals: expected, revisionPair: revisionPair,
                                                              store: stagingStore, check: cancellation.check)
            guard validation.memberCount == index.counts.members, validation.recordCount == index.counts.records,
                  validation.inboxItemCount == index.counts.inboxItems else { throw BackupRestoreError.graphInvalid }
            try stagingStore.close()
            try owner.validate()
            try BackupRestoreFilesystem.sync(parentDescriptor)
            return BackupPreparedRestore(
                summary: .init(
                    backupID: index.backupID,
                    revisionPair: revisionPair,
                    createdAt: index.createdAt,
                    creatorVersion: index.creator.version,
                    memberCount: validation.memberCount,
                    recordCount: validation.recordCount,
                    inboxItemCount: validation.inboxItemCount,
                    originalCount: index.originals.count,
                    plaintextByteCount: index.totalByteCount,
                    logicalDigest: validation.digest
                ),
                operationID: operationID,
                stagingURL: stagingURL,
                stagingIdentity: stagingIdentity,
                preflightReceiptURL: receiptURL,
                activeRootName: activeRootURL.lastPathComponent
            )
        } catch {
            try? BackupRestoreFilesystem.removeDirectoryTree(named: stagingName, expectedIdentity: stagingIdentity,
                                                             parentDescriptor: parentDescriptor)
            try? BackupRestoreFilesystem.removeRegularFile(named: receiptName, parentDescriptor: parentDescriptor)
            try? BackupRestoreFilesystem.sync(parentDescriptor)
            if error is CancellationError { throw CancellationError() }
            throw Self.map(error)
        }
    }

    public func cancel(_ prepared: BackupPreparedRestore) throws {
        try owner.validate()
        guard prepared.activeRootName == activeRootURL.lastPathComponent,
              prepared.stagingURL.deletingLastPathComponent() == stableParentURL,
              prepared.preflightReceiptURL.deletingLastPathComponent() == stableParentURL else {
            throw BackupRestoreError.receiptInvalid
        }
        let parentDescriptor = try BackupRestoreFilesystem.openStrictDirectory(stableParentURL)
        defer { Darwin.close(parentDescriptor) }
        try BackupRestoreFilesystem.removeDirectoryTree(
            named: prepared.stagingURL.lastPathComponent,
            expectedIdentity: prepared.stagingIdentity,
            parentDescriptor: parentDescriptor
        )
        try BackupRestoreFilesystem.removeRegularFile(
            named: prepared.preflightReceiptURL.lastPathComponent,
            parentDescriptor: parentDescriptor
        )
        try BackupRestoreFilesystem.sync(parentDescriptor)
    }

    /// Removes plaintext staging left by a process that exited after writing
    /// its durable preflight receipt but before confirmation. This runs only
    /// during startup, before storage-backed services are exposed. An invalid
    /// or identity-mismatched receipt fails closed and never authorizes a
    /// recursive removal.
    public func reconcileAbandonedPreflights() throws {
        try owner.validate()
        try SQLiteLogicalBackupSource.reconcileTemporaryCaptures(owner: owner)
        let parentDescriptor = try BackupRestoreFilesystem.openStrictDirectory(stableParentURL)
        defer { Darwin.close(parentDescriptor) }
        let candidates = try BackupRestoreFilesystem.directChildNames(
            parentDescriptor: parentDescriptor,
            prefix: ".kinlogue-restore-",
            suffix: ".preflight.json",
            maximumMatchCount: 64
        )
        for receiptName in candidates.sorted() {
            let receipt = try Self.readPreflightReceipt(
                named: receiptName,
                parentDescriptor: parentDescriptor
            )
            guard receipt.magic == BackupRestorePreflightReceipt.magic,
                  receipt.version == 1,
                  receiptName == Self.preflightReceiptName(for: receipt.operationID),
                  receipt.stagingName == Self.stagingName(for: receipt.operationID),
                  receipt.activeRootNameDigest
                    == ContentDigest.sha256(Data(activeRootURL.lastPathComponent.utf8)),
                  receipt.checkpointID.count == 16 else {
                throw BackupRestoreError.receiptInvalid
            }
            if let current = try BackupRestoreFilesystem.directoryIdentityIfPresent(
                named: receipt.stagingName,
                parentDescriptor: parentDescriptor
            ) {
                guard current == receipt.stagingIdentity else {
                    throw BackupRestoreError.receiptInvalid
                }
                try BackupRestoreFilesystem.removeDirectoryTree(
                    named: receipt.stagingName,
                    expectedIdentity: receipt.stagingIdentity,
                    parentDescriptor: parentDescriptor
                )
            }
            try BackupRestoreFilesystem.removeRegularFile(
                named: receiptName,
                parentDescriptor: parentDescriptor
            )
            try BackupRestoreFilesystem.sync(parentDescriptor)
        }
    }

    private static func readPreflightReceipt(
        named name: String,
        parentDescriptor: Int32
    ) throws -> BackupRestorePreflightReceipt {
        let descriptor = name.withCString {
            openat(parentDescriptor, $0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw BackupRestoreError.receiptInvalid }
        defer { Darwin.close(descriptor) }
        var initial = stat()
        guard fstat(descriptor, &initial) == 0,
              (initial.st_mode & S_IFMT) == S_IFREG,
              initial.st_uid == geteuid(),
              initial.st_nlink == 1,
              (initial.st_mode & 0o777) == (S_IRUSR | S_IWUSR),
              initial.st_size >= 0,
              initial.st_size <= 16 * 1_024 else {
            throw BackupRestoreError.receiptInvalid
        }
        var data = Data()
        data.reserveCapacity(Int(initial.st_size))
        var buffer = [UInt8](repeating: 0, count: 4 * 1_024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw BackupRestoreError.ioFailure(errno) }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= 16 * 1_024 else {
                throw BackupRestoreError.receiptInvalid
            }
        }
        var final = stat()
        guard fstat(descriptor, &final) == 0,
              final.st_dev == initial.st_dev,
              final.st_ino == initial.st_ino,
              final.st_size == initial.st_size else {
            throw BackupRestoreError.receiptInvalid
        }
        do {
            let receipt = try CanonicalVaultJSON.decode(
                BackupRestorePreflightReceipt.self,
                from: data
            )
            guard try CanonicalVaultJSON.encode(receipt) == data else {
                throw BackupRestoreError.receiptInvalid
            }
            return receipt
        } catch {
            throw BackupRestoreError.receiptInvalid
        }
    }

    private static func map(_ error: Error) -> BackupRestoreError {
        if case BackupRestoreError.ioFailure(ENOSPC) = error { return .capacityInsufficient }
        if let error = error as? BackupArchiveError {
            switch error {
            case .unsupportedFormat: return .unsupportedFormat
            case .resourceLimit: return .capacityInsufficient
            case .invalidArchive: return .graphInvalid
            }
        }
        if case SQLiteLibraryError.ioFailure(ENOSPC) = error { return .capacityInsufficient }
        if let error = error as? BackupRestoreError { return error }
        if let error = error as? SQLiteLogicalBackupError {
            switch error {
            case .unsupportedVersion: return .unsupportedFormat
            case .resourceLimit, .capacityInsufficient: return .capacityInsufficient
            default: return .graphInvalid
            }
        }
        if error is SQLiteLibraryError || error is LibraryReportError || error is DICOMImportError || error is DICOMSliceServiceError { return .graphInvalid }
        if error is VaultError || error is LANInboxError { return .graphInvalid }
        return .ioFailure(EIO)
    }
}

// SAFETY: rootDescriptor is owned for the lifetime of one preparation; lock guards `finished`.
/// The staging root a restore writes originals into. Paths are built from identifiers only.
final class BackupRestoreOutput: @unchecked Sendable {
    private let rootDescriptor: Int32
    private let lock = NSLock()
    private var finished = false
    private let logicalSpool: SQLiteLogicalSpool

    init(
        parentDescriptor: Int32,
        stagingName: String,
        expectedIdentity: BackupRestoreDirectoryIdentity, logicalSpool: SQLiteLogicalSpool
    ) throws {
        self.logicalSpool = logicalSpool
        let descriptor = stagingName.withCString {
            openat(parentDescriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw BackupRestoreError.stagingConflict }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              expectedIdentity.matches(metadata) else {
            Darwin.close(descriptor)
            throw BackupRestoreError.stagingConflict
        }
        rootDescriptor = descriptor
    }

    /// A writer for one original at `originals/<id>.data` in staging.
    func originalWriter(id: UUID, byteCount: UInt64) throws -> RestoreFileWriter {
        try lock.withLock { guard !finished else { throw BackupRestoreError.stagingConflict } }
        return try RestoreFileWriter(rootDescriptor: rootDescriptor, path: "originals/\(id.uuidString.lowercased()).data",
                                     byteCount: byteCount)
    }

    func finish() throws {
        let shouldSync = lock.withLock { () -> Bool in
            guard !finished else { return false }
            finished = true
            return true
        }
        if shouldSync { try logicalSpool.seal(); try BackupRestoreFilesystem.sync(rootDescriptor) }
    }

    deinit { Darwin.close(rootDescriptor) }
}

// SAFETY: lock serializes byteCount, writes, sync, and the idempotent close of
// both exclusively owned descriptors; no operation uses them after close.
final class RestoreFileWriter: @unchecked Sendable {
    private let descriptor: Int32
    private let parentDescriptor: Int32
    private let expectedByteCount: UInt64
    private let lock = NSLock()
    private var byteCount: UInt64 = 0
    private var closed = false

    init(rootDescriptor: Int32, path: String, byteCount: UInt64) throws {
        let components = path.split(separator: "/").map(String.init)
        guard let leaf = components.last, !leaf.isEmpty else {
            throw BackupRestoreError.graphInvalid
        }
        var parent = dup(rootDescriptor)
        guard parent >= 0 else { throw BackupRestoreError.ioFailure(errno) }
        do {
            for component in components.dropLast() {
                let child = try BackupRestoreFilesystem.openOrCreatePrivateDirectory(
                    named: component,
                    parentDescriptor: parent
                )
                Darwin.close(parent)
                parent = child
            }
            let descriptor = leaf.withCString {
                openat(parent, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            }
            guard descriptor >= 0 else { throw BackupRestoreError.ioFailure(errno) }
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0,
                  (metadata.st_mode & S_IFMT) == S_IFREG,
                  metadata.st_uid == geteuid(),
                  metadata.st_nlink == 1,
                  (metadata.st_mode & 0o777) == (S_IRUSR | S_IWUSR) else {
                Darwin.close(descriptor)
                throw BackupRestoreError.stagingConflict
            }
            self.descriptor = descriptor
            parentDescriptor = parent
            expectedByteCount = byteCount
        } catch {
            Darwin.close(parent)
            throw error
        }
    }

    func append(_ data: Data) throws {
        try lock.withLock {
            guard !closed else { throw BackupRestoreError.ioFailure(EBADF) }
            let next = byteCount.addingReportingOverflow(UInt64(data.count))
            guard !next.overflow, next.partialValue <= expectedByteCount else {
                throw BackupRestoreError.graphInvalid
            }
            try data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = Darwin.write(
                        descriptor,
                        raw.baseAddress!.advanced(by: offset),
                        raw.count - offset
                    )
                    if written < 0, errno == EINTR { continue }
                    guard written > 0 else { throw BackupRestoreError.ioFailure(errno) }
                    offset += written
                }
            }
            byteCount = next.partialValue
        }
    }

    func finish() throws {
        try lock.withLock {
            guard !closed, byteCount == expectedByteCount else {
                throw BackupRestoreError.graphInvalid
            }
            try BackupRestoreFilesystem.sync(descriptor)
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0,
                  metadata.st_nlink == 1,
                  metadata.st_size == off_t(expectedByteCount) else {
                throw BackupRestoreError.stagingConflict
            }
            try BackupRestoreFilesystem.sync(parentDescriptor)
            Darwin.close(descriptor)
            Darwin.close(parentDescriptor)
            closed = true
        }
    }

    func close() {
        lock.withLock {
            guard !closed else { return }
            Darwin.close(descriptor)
            Darwin.close(parentDescriptor)
            closed = true
        }
    }

    deinit { close() }
}

enum BackupRestoreFilesystem {
    static func openStrictDirectory(_ url: URL) throws -> Int32 {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw BackupRestoreError.ioFailure(errno) }
        do {
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0,
                  (metadata.st_mode & S_IFMT) == S_IFDIR,
                  metadata.st_uid == geteuid(),
                  (metadata.st_mode & 0o777) == S_IRWXU else {
                throw BackupRestoreError.stagingConflict
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    static func directoryIdentity(
        named name: String,
        parentDescriptor: Int32
    ) throws -> BackupRestoreDirectoryIdentity {
        var metadata = stat()
        guard name.withCString({
            fstatat(parentDescriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
        }) == 0 else { throw BackupRestoreError.ioFailure(errno) }
        return try BackupRestoreDirectoryIdentity(metadata)
    }

    static func directoryIdentityIfPresent(
        named name: String,
        parentDescriptor: Int32
    ) throws -> BackupRestoreDirectoryIdentity? {
        var metadata = stat()
        guard name.withCString({
            fstatat(parentDescriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
        }) == 0 else {
            if errno == ENOENT { return nil }
            throw BackupRestoreError.ioFailure(errno)
        }
        return try BackupRestoreDirectoryIdentity(metadata)
    }

    static func directChildNames(
        parentDescriptor: Int32,
        prefix: String,
        suffix: String,
        maximumMatchCount: Int
    ) throws -> [String] {
        let duplicate = dup(parentDescriptor)
        guard duplicate >= 0, let directory = fdopendir(duplicate) else {
            if duplicate >= 0 { Darwin.close(duplicate) }
            throw BackupRestoreError.ioFailure(errno)
        }
        defer { closedir(directory) }
        var matches: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { continue }
            matches.append(name)
            guard matches.count <= maximumMatchCount else {
                throw BackupRestoreError.receiptInvalid
            }
        }
        return matches
    }

    static func openOrCreatePrivateDirectory(
        named name: String,
        parentDescriptor: Int32
    ) throws -> Int32 {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw BackupRestoreError.graphInvalid
        }
        if mkdirat(parentDescriptor, name, 0o700) != 0, errno != EEXIST {
            throw BackupRestoreError.ioFailure(errno)
        }
        let child = name.withCString {
            openat(parentDescriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard child >= 0 else { throw BackupRestoreError.stagingConflict }
        var metadata = stat()
        guard fstat(child, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == geteuid(),
              (metadata.st_mode & 0o777) == S_IRWXU else {
            Darwin.close(child)
            throw BackupRestoreError.stagingConflict
        }
        return child
    }

    static func writeExclusiveFile(
        _ data: Data,
        named name: String,
        parentDescriptor: Int32
    ) throws {
        let descriptor = name.withCString {
            openat(parentDescriptor, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        }
        guard descriptor >= 0 else { throw BackupRestoreError.receiptInvalid }
        defer { Darwin.close(descriptor) }
        var offset = 0
        try data.withUnsafeBytes { raw in
            while offset < raw.count {
                let written = Darwin.write(
                    descriptor,
                    raw.baseAddress!.advanced(by: offset),
                    raw.count - offset
                )
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw BackupRestoreError.ioFailure(errno) }
                offset += written
            }
        }
        try sync(descriptor)
    }

    static func removeRegularFile(named name: String, parentDescriptor: Int32) throws {
        var metadata = stat()
        guard name.withCString({
            fstatat(parentDescriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
        }) == 0 else {
            if errno == ENOENT { return }
            throw BackupRestoreError.ioFailure(errno)
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_nlink == 1,
              name.withCString({ unlinkat(parentDescriptor, $0, 0) }) == 0 else {
            throw BackupRestoreError.receiptInvalid
        }
    }

    static func removeDirectoryTree(
        named name: String,
        expectedIdentity: BackupRestoreDirectoryIdentity,
        parentDescriptor: Int32
    ) throws {
        let descriptor = name.withCString {
            openat(parentDescriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { return }
            throw BackupRestoreError.stagingConflict
        }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              expectedIdentity.matches(metadata) else {
            throw BackupRestoreError.stagingConflict
        }
        try removeContents(descriptor: descriptor, depth: 0)
        try sync(descriptor)
        guard try directoryIdentity(named: name, parentDescriptor: parentDescriptor)
                == expectedIdentity,
              name.withCString({ unlinkat(parentDescriptor, $0, AT_REMOVEDIR) }) == 0 else {
            throw BackupRestoreError.stagingConflict
        }
        try sync(parentDescriptor)
    }

    private static func removeContents(descriptor: Int32, depth: Int) throws {
        guard depth <= 8 else { throw BackupRestoreError.graphInvalid }
        let duplicate = dup(descriptor)
        guard duplicate >= 0, let directory = fdopendir(duplicate) else {
            if duplicate >= 0 { Darwin.close(duplicate) }
            throw BackupRestoreError.ioFailure(errno)
        }
        defer { closedir(directory) }
        var names: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name != ".", name != ".." { names.append(name) }
        }
        for name in names {
            var metadata = stat()
            guard name.withCString({
                fstatat(descriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
            }) == 0 else { throw BackupRestoreError.ioFailure(errno) }
            if (metadata.st_mode & S_IFMT) == S_IFDIR {
                let child = name.withCString {
                    openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard child >= 0 else { throw BackupRestoreError.stagingConflict }
                defer { Darwin.close(child) }
                try removeContents(descriptor: child, depth: depth + 1)
                guard name.withCString({ unlinkat(descriptor, $0, AT_REMOVEDIR) }) == 0 else {
                    throw BackupRestoreError.stagingConflict
                }
            } else {
                guard (metadata.st_mode & S_IFMT) == S_IFREG,
                      metadata.st_uid == geteuid(),
                      metadata.st_nlink == 1,
                      name.withCString({ unlinkat(descriptor, $0, 0) }) == 0 else {
                    throw BackupRestoreError.stagingConflict
                }
            }
        }
        try sync(descriptor)
    }

    static func sync(_ descriptor: Int32) throws {
        if fcntl(descriptor, F_FULLFSYNC) == 0 { return }
        guard fsync(descriptor) == 0 else { throw BackupRestoreError.ioFailure(errno) }
    }
}
