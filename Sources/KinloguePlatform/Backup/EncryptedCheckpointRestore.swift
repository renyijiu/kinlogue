import Darwin
import Foundation
import KinlogueCore

public enum BackupRestoreError: Error, Equatable, Sendable {
    case invalidSource
    case sourceChanged
    case authenticationFailed
    case unsupportedFormat
    case graphInvalid
    case capacityInsufficient
    case stagingConflict
    case receiptInvalid
    case activationConflict
    case ioFailure(Int32)
    case injectedFailure
}

public struct BackupRestoreSummary: Equatable, Sendable {
    public let checkpointID: BackupCheckpointID
    public let revisionPair: BackupRevisionPair
    public let sequence: UInt64
    public let memberCount: Int
    public let recordCount: Int
    public let inboxItemCount: Int
    public let plaintextByteCount: UInt64
    public let formatVersion: BackupFormatVersion
    package let logicalDigest: Data?

    public init(
        checkpointID: BackupCheckpointID,
        revisionPair: BackupRevisionPair,
        sequence: UInt64,
        memberCount: Int,
        recordCount: Int,
        inboxItemCount: Int,
        plaintextByteCount: UInt64,
        formatVersion: BackupFormatVersion,
        logicalDigest: Data? = nil
    ) {
        self.checkpointID = checkpointID
        self.revisionPair = revisionPair
        self.sequence = sequence
        self.memberCount = memberCount
        self.recordCount = recordCount
        self.inboxItemCount = inboxItemCount
        self.plaintextByteCount = plaintextByteCount
        self.formatVersion = formatVersion
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

struct BackupRestoreDirectoryIdentity: Codable, Equatable, Sendable {
    let device: UInt64
    let inode: UInt64

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
        device == UInt64(metadata.st_dev)
            && inode == UInt64(metadata.st_ino)
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
    let checkpointID: Data
    let stagingName: String
    let stagingIdentity: BackupRestoreDirectoryIdentity
}

/// Performs seed-only checkpoint verification and reconstructs one complete
/// plaintext root beneath the trusted Application Support parent. It has no
/// dependency on a bookmark, local backup configuration, or device signer.
// SAFETY: The verifier stores only immutable URLs and a Sendable capacity
// closure; each prepare call owns all descriptors and staging state it creates.
public final class BackupRestoreVerifier: @unchecked Sendable {
    public typealias AvailableCapacity = @Sendable () throws -> UInt64

    fileprivate static let maximumContainerByteCount =
        BackupFormatLimits.maximumContainerByteCount(for: .current)
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

    @concurrent public func prepare(checkpointURL: URL, recoveryCode: String) async throws -> BackupPreparedRestore {
        try await LibraryStorageExecutor.run {
            let cancellation = SQLiteLogicalCancellation()
            return try await withTaskCancellationHandler {
                try await prepare(checkpointURL: checkpointURL, recoveryCode: recoveryCode, cancellation: cancellation)
            } onCancel: { cancellation.cancel() }
        }
    }

    private func prepare(
        checkpointURL: URL,
        recoveryCode: String,
        cancellation: SQLiteLogicalCancellation
    ) async throws -> BackupPreparedRestore {
        try Task.checkCancellation()
        try owner.validate()
        let source = try BackupRestoreSource(url: checkpointURL)
        defer { source.close() }
        let sourceIdentity = try source.identity()
        let recoverySeed: Data
        do { recoverySeed = try BackupRecoveryCode.decode(recoveryCode) }
        catch { throw BackupRestoreError.authenticationFailed }

        let reader = BackupContainerReader()
        let firstPass: BackupContainerReadResult
        do {
            firstPass = try reader.read(
                source: source.byteSource,
                recoverySeed: recoverySeed,
                sink: .init { _ in { _ in } },
                // A file-tree checkpoint cannot be restored; say so before decrypting all of it.
                acceptManifest: { guard $0.isLogical else { throw BackupRestoreError.unsupportedFormat } }
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.map(error)
        }
        let capacity = try availableCapacity()
        let logicalBytes = firstPass.manifest.entries.filter { $0.kind == .logicalSegment }.reduce(UInt64(0)) { $0 + $1.plaintextByteCount }
        // First reserve streamed originals, the input logical spool and the later
        // strict-validation spool. The App-schema budget is checked from authenticated
        // per-domain records below, before inserting any rows.
        let required = firstPass.manifest.totalPlaintextByteCount.addingReportingOverflow(
            BackupFormatLimits.capacityHeadroomByteCount + logicalBytes + (logicalBytes > 0 ? 1_024 * 1_024 : 0)
        )
        guard !required.overflow, capacity >= required.partialValue else {
            throw BackupRestoreError.capacityInsufficient
        }
        guard try source.identity() == sourceIdentity else {
            throw BackupRestoreError.sourceChanged
        }

        let operationID = UUID()
        let stagingName = Self.stagingName(for: operationID)
        let receiptName = Self.preflightReceiptName(for: operationID)
        let stagingURL = stableParentURL.appendingPathComponent(stagingName, isDirectory: true)
        let receiptURL = stableParentURL.appendingPathComponent(receiptName, isDirectory: false)
        let parentDescriptor = try BackupRestoreFilesystem.openStrictDirectory(stableParentURL)
        defer { Darwin.close(parentDescriptor) }
        guard mkdirat(parentDescriptor, stagingName, 0o700) == 0 else {
            throw BackupRestoreError.stagingConflict
        }
        let stagingIdentity = try BackupRestoreFilesystem.directoryIdentity(
            named: stagingName,
            parentDescriptor: parentDescriptor
        )
        let receipt = BackupRestorePreflightReceipt(
            magic: BackupRestorePreflightReceipt.magic,
            version: 1,
            operationID: operationID,
            activeRootNameDigest: ContentDigest.sha256(Data(activeRootURL.lastPathComponent.utf8)),
            checkpointID: firstPass.publicVerification.checkpoint.checkpointID.bytes,
            stagingName: stagingName,
            stagingIdentity: stagingIdentity
        )
        do {
            try BackupRestoreFilesystem.writeExclusiveFile(
                try CanonicalVaultJSON.encode(receipt),
                named: receiptName,
                parentDescriptor: parentDescriptor
            )
            try BackupRestoreFilesystem.sync(parentDescriptor)
        } catch {
            try? BackupRestoreFilesystem.removeDirectoryTree(
                named: stagingName,
                expectedIdentity: stagingIdentity,
                parentDescriptor: parentDescriptor
            )
            throw Self.map(error)
        }

        do {
            try owner.validate()
            let logicalSpool = try SQLiteLogicalSpool(parent: stableParentURL, maximumByteCount: Int(logicalBytes))
            defer { logicalSpool.release() }
            let stagingStore = try SQLiteLibraryStore(rootURL: stagingURL)
            defer { try? stagingStore.close() }
            let output = try BackupRestoreOutput(
                parentDescriptor: parentDescriptor,
                stagingName: stagingName,
                expectedIdentity: stagingIdentity, logicalSpool: logicalSpool
            )
            let secondPass = try reader.read(
                source: source.byteSource,
                recoverySeed: recoverySeed,
                sink: output.sink
            )
            try output.finish()
            guard secondPass.manifest == firstPass.manifest,
                  secondPass.publicVerification.checkpoint
                    == firstPass.publicVerification.checkpoint,
                  try source.identity() == sourceIdentity else {
                throw BackupRestoreError.sourceChanged
            }
            let databaseBytes = try SQLiteLogicalRestore.databaseBudget(spool: logicalSpool, check: cancellation.check)
            let remaining = databaseBytes.addingReportingOverflow(logicalBytes + BackupFormatLimits.capacityHeadroomByteCount)
            guard !remaining.overflow, try availableCapacity() >= remaining.partialValue else { throw BackupRestoreError.capacityInsufficient }
            let validation = try SQLiteLogicalRestore.restore(spool: logicalSpool, manifest: secondPass.manifest,
                store: stagingStore, check: cancellation.check)
            try stagingStore.close()
            try owner.validate()
            try BackupRestoreFilesystem.sync(parentDescriptor)
            return BackupPreparedRestore(
                summary: .init(
                    checkpointID: secondPass.publicVerification.checkpoint.checkpointID,
                    revisionPair: secondPass.manifest.revisionPair,
                    sequence: secondPass.publicVerification.checkpoint.sequence,
                    memberCount: validation.memberCount,
                    recordCount: validation.recordCount,
                    inboxItemCount: validation.inboxItemCount,
                    plaintextByteCount: secondPass.manifest.totalPlaintextByteCount,
                    formatVersion: secondPass.manifest.formatVersion, logicalDigest: validation.digest
                ),
                operationID: operationID,
                stagingURL: stagingURL,
                stagingIdentity: stagingIdentity,
                preflightReceiptURL: receiptURL,
                activeRootName: activeRootURL.lastPathComponent
            )
        } catch {
            try? BackupRestoreFilesystem.removeDirectoryTree(
                named: stagingName,
                expectedIdentity: stagingIdentity,
                parentDescriptor: parentDescriptor
            )
            try? BackupRestoreFilesystem.removeRegularFile(
                named: receiptName,
                parentDescriptor: parentDescriptor
            )
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
        guard let error = error as? BackupContainerError else {
            if error is VaultError || error is LANInboxError { return .graphInvalid }
            return .ioFailure(EIO)
        }
        switch error {
        case .authenticationFailed, .trustFailure:
            return .authenticationFailed
        case .unsupportedVersion, .unsupportedSuite:
            return .unsupportedFormat
        case .resourceLimit, .arithmeticOverflow:
            return .capacityInsufficient
        case .graphInvalid, .invalidFormat, .sourceIntegrityFailure, .trailingBytes:
            return .graphInvalid
        case .outputFailure, .counterOverflow:
            return .ioFailure(EIO)
        }
    }
}

// SAFETY: lock makes close idempotent; the byteSource closure is consumed only
// within the structured verifier read and joins before that defer closes the FD.
private final class BackupRestoreSource: @unchecked Sendable {
    struct Identity: Equatable {
        let device: UInt64
        let inode: UInt64
        let byteCount: UInt64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
    }

    private let descriptor: Int32
    let byteSource: BackupContainerByteSource
    private let lock = NSLock()
    private var closed = false

    init(url: URL) throws {
        guard url.isFileURL, url.pathExtension == "kinloguebackup" else {
            throw BackupRestoreError.invalidSource
        }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw BackupRestoreError.invalidSource }
        self.descriptor = descriptor
        do {
            let identity = try Self.identity(of: descriptor)
            guard identity.byteCount > 0,
                  identity.byteCount <= BackupRestoreVerifier.maximumContainerByteCount else {
                throw BackupRestoreError.invalidSource
            }
            byteSource = BackupContainerByteSource(byteCount: identity.byteCount) {
                offset, maximumByteCount in
                var bytes = [UInt8](repeating: 0, count: maximumByteCount)
                let count = pread(descriptor, &bytes, maximumByteCount, off_t(offset))
                guard count >= 0 else { throw BackupRestoreError.ioFailure(errno) }
                return Data(bytes.prefix(count))
            }
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    func identity() throws -> Identity { try Self.identity(of: descriptor) }

    func close() {
        let shouldClose = lock.withLock { () -> Bool in
            guard !closed else { return false }
            closed = true
            return true
        }
        if shouldClose { Darwin.close(descriptor) }
    }

    deinit { close() }

    private static func identity(of descriptor: Int32) throws -> Identity {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_nlink == 1,
              metadata.st_size >= 0 else {
            throw BackupRestoreError.invalidSource
        }
        return Identity(
            device: UInt64(metadata.st_dev),
            inode: UInt64(metadata.st_ino),
            byteCount: UInt64(metadata.st_size),
            modifiedSeconds: Int64(metadata.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(metadata.st_mtimespec.tv_nsec)
        )
    }
}

// SAFETY: rootDescriptor is owned for one structured reader lifetime and lock
// serializes the single active entry writer plus finish/close transitions.
private final class BackupRestoreOutput: @unchecked Sendable {
    private let rootDescriptor: Int32
    private let lock = NSLock()
    private var activeWriter: (path: String, writer: RestoreFileWriter)?
    private var finished = false
    private let logicalSpool: SQLiteLogicalSpool
    private var activeLogical: (path: String, remaining: UInt64)?

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

    lazy var sink = BackupContainerEntrySink({ [weak self] entry in
        guard let self else { throw BackupRestoreError.ioFailure(EIO) }
        if entry.kind == .logicalSegment {
            try lock.withLock {
                guard !finished, activeWriter == nil, activeLogical == nil else { throw BackupRestoreError.stagingConflict }
                activeLogical = (entry.path, entry.plaintextByteCount)
            }
            return { bytes in
                try self.lock.withLock {
                    guard let active = self.activeLogical, active.path == entry.path, UInt64(bytes.count) <= active.remaining else { throw BackupRestoreError.graphInvalid }
                    try self.logicalSpool.append(bytes)
                    self.activeLogical = (active.path, active.remaining - UInt64(bytes.count))
                }
            }
        }
        guard entry.kind == .original else { throw BackupRestoreError.graphInvalid }
        let writer = try RestoreFileWriter(rootDescriptor: rootDescriptor, entry: entry)
        do {
            try lock.withLock {
                guard !finished, activeWriter == nil else {
                    throw BackupRestoreError.stagingConflict
                }
                activeWriter = (entry.path, writer)
            }
        } catch {
            writer.close()
            throw error
        }
        return { bytes in try writer.append(bytes) }
    }, finish: { [weak self] entry in
        guard let self else { throw BackupRestoreError.ioFailure(EIO) }
        if entry.kind == .logicalSegment {
            try lock.withLock {
                guard let activeLogical, activeLogical.path == entry.path, activeLogical.remaining == 0 else { throw BackupRestoreError.graphInvalid }
                self.activeLogical = nil
            }
            return
        }
        let writer = try lock.withLock { () throws -> RestoreFileWriter in
            guard !finished,
                  let activeWriter,
                  activeWriter.path == entry.path else {
                throw BackupRestoreError.stagingConflict
            }
            self.activeWriter = nil
            return activeWriter.writer
        }
        try writer.finish()
    })

    func finish() throws {
        let shouldSync = try lock.withLock { () throws -> Bool in
            guard !finished else { return false }
            guard activeWriter == nil, activeLogical == nil else { throw BackupRestoreError.graphInvalid }
            finished = true
            return true
        }
        if shouldSync { try logicalSpool.seal(); try BackupRestoreFilesystem.sync(rootDescriptor) }
    }

    deinit {
        let current = lock.withLock { activeWriter?.writer }
        current?.close()
        Darwin.close(rootDescriptor)
    }
}

// SAFETY: lock serializes byteCount, writes, sync, and the idempotent close of
// both exclusively owned descriptors; no operation uses them after close.
private final class RestoreFileWriter: @unchecked Sendable {
    private let descriptor: Int32
    private let parentDescriptor: Int32
    private let expectedByteCount: UInt64
    private let lock = NSLock()
    private var byteCount: UInt64 = 0
    private var closed = false

    init(rootDescriptor: Int32, entry: BackupManifestEntry) throws {
        let components = entry.path.split(separator: "/").map(String.init)
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
            expectedByteCount = entry.plaintextByteCount
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
