import CryptoKit
import Darwin
import Foundation
import KinlogueCore

public enum EncryptedCheckpointWriterError: Error, Equatable, Sendable {
    case sourceChanged
    case repositoryIdentityChanged
    case finalAlreadyExists
    case capacityInsufficient
    case verificationFailed
    case publicationIndeterminate
    case invalidConfiguration
    case resourceLimit
    case ioFailure(Int32)
}

enum EncryptedCheckpointWritePhase: Equatable, Sendable {
    case encryptedPayload
}

enum EncryptedCheckpointWriterEvent: Equatable, Sendable {
    case beforeFinalSourceValidation
    case afterPublication(URL)
}

public struct EncryptedCheckpointWriteResult: Sendable {
    public let finalLeafName: String
    public let fileIdentity: BackupPublishedFileIdentity
    public let revisionPair: BackupRevisionPair
    public let witness: BackupDurableFullReaderWitness
    public let maximumBufferedPlaintextByteCount: Int
    public let maximumSimultaneousSourceFileCount: Int
}

// SAFETY: lock protects the complete optional failure-code state.
private final class CheckpointWriteFailureState: @unchecked Sendable {
    private let lock = NSLock()
    private var code: Int32?

    func record(_ value: Int32) { lock.withLock { code = value } }
    var value: Int32? { lock.withLock { code } }
}

// SAFETY: lock protects the complete optional publication result state.
private final class CheckpointPublicationState: @unchecked Sendable {
    typealias Value = (leafName: String, identity: BackupPublishedFileIdentity)
    private let lock = NSLock()
    private var storage: Value?

    func set(_ value: Value) { lock.withLock { storage = value } }
    var value: Value? { lock.withLock { storage } }
}

// SAFETY: lock serializes append/publication/close state and descriptor close;
// returned read closures have a structured lifetime that finishes before close.
private final class CheckpointWorkFile: @unchecked Sendable {
    let repositoryURL: URL
    let repositoryDescriptor: Int32
    let repositoryIdentity: BackupFilesystemIdentity
    let workName: String
    let descriptor: Int32
    let workIdentity: BackupPublishedFileIdentity

    private let lock = NSLock()
    private var byteCount: UInt64 = 0
    private var publishedName: String?
    private var isClosed = false

    init(
        repositoryURL: URL,
        repositoryDescriptor: Int32,
        repositoryIdentity: BackupFilesystemIdentity
    ) throws {
        self.repositoryURL = repositoryURL
        self.repositoryDescriptor = repositoryDescriptor
        self.repositoryIdentity = repositoryIdentity
        workName = ".checkpoint-\(UUID().uuidString.lowercased()).work"
        descriptor = openat(
            repositoryDescriptor,
            workName,
            O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard descriptor >= 0 else {
            throw EncryptedCheckpointWriterError.ioFailure(errno)
        }
        do {
            guard fchmod(descriptor, 0o600) == 0 else {
                throw EncryptedCheckpointWriterError.ioFailure(errno)
            }
            workIdentity = try Self.strictFileIdentity(descriptor)
        } catch {
            Darwin.close(descriptor)
            _ = unlinkat(repositoryDescriptor, workName, 0)
            throw error
        }
    }

    func append(_ bytes: Data) throws {
        try lock.withLock {
            guard !isClosed, publishedName == nil else {
                throw EncryptedCheckpointWriterError.verificationFailed
            }
            let next = byteCount.addingReportingOverflow(UInt64(bytes.count))
            guard !next.overflow else {
                throw EncryptedCheckpointWriterError.resourceLimit
            }
            try bytes.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let count = Darwin.write(
                        descriptor,
                        raw.baseAddress!.advanced(by: offset),
                        raw.count - offset
                    )
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else {
                        throw EncryptedCheckpointWriterError.ioFailure(errno)
                    }
                    offset += count
                }
            }
            byteCount = next.partialValue
        }
    }

    func source() throws -> BackupContainerByteSource {
        try lock.withLock {
            guard !isClosed else { throw EncryptedCheckpointWriterError.verificationFailed }
            let identity = try Self.strictFileIdentity(descriptor)
            guard identity.device == workIdentity.device,
                  identity.inode == workIdentity.inode,
                  identity.byteCount == byteCount else {
                throw EncryptedCheckpointWriterError.verificationFailed
            }
            let descriptor = descriptor
            return BackupContainerByteSource(byteCount: identity.byteCount) { offset, count in
                try Self.read(descriptor: descriptor, offset: offset, count: count)
            }
        }
    }

    func synchronizeAndPublish(
        checkpointID: BackupCheckpointID
    ) throws -> (leafName: String, identity: BackupPublishedFileIdentity) {
        try lock.withLock {
            guard !isClosed, publishedName == nil else {
                throw EncryptedCheckpointWriterError.publicationIndeterminate
            }
            try Self.synchronize(descriptor)
            try validateRepositoryIdentity()
            let currentWork = try Self.namedIdentity(workName, at: repositoryDescriptor)
            let openWork = try Self.strictFileIdentity(descriptor)
            guard currentWork == openWork,
                  currentWork.device == workIdentity.device,
                  currentWork.inode == workIdentity.inode,
                  currentWork.byteCount == byteCount else {
                throw EncryptedCheckpointWriterError.repositoryIdentityChanged
            }
            let leafName = checkpointID.bytes.map { String(format: "%02x", $0) }.joined()
                + ".kinloguebackup"
            let renamed = renameatx_np(
                repositoryDescriptor,
                workName,
                repositoryDescriptor,
                leafName,
                UInt32(RENAME_EXCL)
            )
            guard renamed == 0 else {
                if errno == EEXIST { throw EncryptedCheckpointWriterError.finalAlreadyExists }
                throw EncryptedCheckpointWriterError.ioFailure(errno)
            }
            publishedName = leafName
            do {
                try Self.synchronizeDirectory(repositoryDescriptor)
                try validateRepositoryIdentity()
                let finalIdentity = try Self.namedIdentity(leafName, at: repositoryDescriptor)
                guard finalIdentity == openWork else {
                    throw EncryptedCheckpointWriterError.publicationIndeterminate
                }
                return (leafName, finalIdentity)
            } catch {
                throw EncryptedCheckpointWriterError.publicationIndeterminate
            }
        }
    }

    func validatePublishedIdentity(
        leafName: String,
        expected: BackupPublishedFileIdentity
    ) throws {
        try lock.withLock {
            guard publishedName == leafName,
                  try Self.strictFileIdentity(descriptor) == expected,
                  try Self.namedIdentity(leafName, at: repositoryDescriptor) == expected else {
                throw EncryptedCheckpointWriterError.publicationIndeterminate
            }
            try validateRepositoryIdentity()
        }
    }

    func close() {
        lock.withLock {
            guard !isClosed else { return }
            isClosed = true
            Darwin.close(descriptor)
            if publishedName == nil { _ = unlinkat(repositoryDescriptor, workName, 0) }
            Darwin.close(repositoryDescriptor)
        }
    }

    deinit { close() }

    private func validateRepositoryIdentity() throws {
        guard try Self.strictDirectoryIdentity(repositoryDescriptor) == repositoryIdentity else {
            throw EncryptedCheckpointWriterError.repositoryIdentityChanged
        }
        let visible = Darwin.open(
            repositoryURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard visible >= 0 else {
            throw EncryptedCheckpointWriterError.repositoryIdentityChanged
        }
        defer { Darwin.close(visible) }
        guard try Self.strictDirectoryIdentity(visible) == repositoryIdentity else {
            throw EncryptedCheckpointWriterError.repositoryIdentityChanged
        }
    }

    static func strictDirectoryIdentity(_ descriptor: Int32) throws -> BackupFilesystemIdentity {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw EncryptedCheckpointWriterError.ioFailure(errno)
        }
        guard (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == geteuid(),
              metadata.st_nlink >= 2,
              metadata.st_mode & 0o777 == 0o700 else {
            throw EncryptedCheckpointWriterError.repositoryIdentityChanged
        }
        return .init(device: UInt64(metadata.st_dev), inode: UInt64(metadata.st_ino))
    }

    static func strictFileIdentity(_ descriptor: Int32) throws -> BackupPublishedFileIdentity {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw EncryptedCheckpointWriterError.ioFailure(errno)
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_nlink == 1,
              metadata.st_mode & 0o777 == 0o600,
              metadata.st_size >= 0 else {
            throw EncryptedCheckpointWriterError.verificationFailed
        }
        return .init(
            device: UInt64(metadata.st_dev),
            inode: UInt64(metadata.st_ino),
            byteCount: UInt64(metadata.st_size)
        )
    }

    static func namedIdentity(
        _ name: String,
        at parent: Int32
    ) throws -> BackupPublishedFileIdentity {
        var metadata = stat()
        let result = name.withCString {
            fstatat(parent, $0, &metadata, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0 else {
            throw EncryptedCheckpointWriterError.ioFailure(errno)
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_nlink == 1,
              metadata.st_mode & 0o777 == 0o600,
              metadata.st_size >= 0 else {
            throw EncryptedCheckpointWriterError.verificationFailed
        }
        return .init(
            device: UInt64(metadata.st_dev),
            inode: UInt64(metadata.st_ino),
            byteCount: UInt64(metadata.st_size)
        )
    }

    static func read(descriptor: Int32, offset: UInt64, count: Int) throws -> Data {
        guard count >= 0, let fileOffset = off_t(exactly: offset) else {
            throw EncryptedCheckpointWriterError.verificationFailed
        }
        if count == 0 { return Data() }
        var bytes = Data(count: count)
        let readCount = bytes.withUnsafeMutableBytes {
            pread(descriptor, $0.baseAddress, count, fileOffset)
        }
        guard readCount >= 0 else {
            throw EncryptedCheckpointWriterError.ioFailure(errno)
        }
        bytes.count = readCount
        return bytes
    }

    static func synchronize(_ descriptor: Int32) throws {
        if fcntl(descriptor, F_FULLFSYNC) == 0 { return }
        guard fsync(descriptor) == 0 else {
            throw EncryptedCheckpointWriterError.ioFailure(errno)
        }
    }

    static func synchronizeDirectory(_ descriptor: Int32) throws {
        if fcntl(descriptor, F_FULLFSYNC) == 0 { return }
        guard fsync(descriptor) == 0 else {
            throw EncryptedCheckpointWriterError.ioFailure(errno)
        }
    }
}

/// Streams one coherent Vault+LAN generation into a private work inode, then
/// publishes it exclusively and records a durable final-reader witness.
// SAFETY: All collaborators and injected closures are immutable Sendable
// values; each write owns its work file and otherwise delegates to actors.
public final class EncryptedCheckpointWriter: @unchecked Sendable {
    private let source: PlaintextLibraryBackupSource
    private let configurationStore: BackupLocalConfigurationStore
    private let containerWriter: EncryptedBackupContainerWriter
    private let eventHandler: @Sendable (EncryptedCheckpointWriterEvent) async throws -> Void
    private let writeFailureInjector: @Sendable (EncryptedCheckpointWritePhase) -> Int32?

    public init(
        source: PlaintextLibraryBackupSource,
        configurationStore: BackupLocalConfigurationStore
    ) {
        self.source = source
        self.configurationStore = configurationStore
        containerWriter = .init()
        eventHandler = { _ in }
        writeFailureInjector = { _ in nil }
    }

    init(
        source: PlaintextLibraryBackupSource,
        configurationStore: BackupLocalConfigurationStore,
        containerWriter: EncryptedBackupContainerWriter,
        eventHandler: @escaping @Sendable (EncryptedCheckpointWriterEvent) async throws -> Void = { _ in },
        writeFailureInjector: @escaping @Sendable (EncryptedCheckpointWritePhase) -> Int32? = { _ in nil }
    ) {
        self.source = source
        self.configurationStore = configurationStore
        self.containerWriter = containerWriter
        self.eventHandler = eventHandler
        self.writeFailureInjector = writeFailureInjector
    }

    func write(
        repositoryURL: URL,
        configuration: BackupLocalConfiguration,
        sequence: UInt64,
        publicationFenceValidator: @escaping @Sendable () throws -> Void = {}
    ) async throws -> EncryptedCheckpointWriteResult {
        var work: CheckpointWorkFile?
        do {
            try Task.checkCancellation()
            do {
                try publicationFenceValidator()
            } catch {
                throw EncryptedCheckpointWriterError.repositoryIdentityChanged
            }
            try await validateConfiguration(configuration, sequence: sequence)
            let plan = try await source.prepare()
            let repositoryDescriptor = Darwin.open(
                repositoryURL.path,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard repositoryDescriptor >= 0 else {
                throw EncryptedCheckpointWriterError.repositoryIdentityChanged
            }
            let repositoryIdentity: BackupFilesystemIdentity
            do {
                repositoryIdentity = try CheckpointWorkFile.strictDirectoryIdentity(
                    repositoryDescriptor
                )
                guard repositoryIdentity == configuration.repositoryDirectoryIdentity else {
                    throw EncryptedCheckpointWriterError.repositoryIdentityChanged
                }
                try Self.validateEnrollment(
                    repositoryDescriptor: repositoryDescriptor,
                    configuration: configuration
                )
                try Self.validateCapacity(
                    repositoryDescriptor: repositoryDescriptor,
                    plaintextByteCount: plan.totalPlaintextByteCount
                )
                work = try CheckpointWorkFile(
                    repositoryURL: repositoryURL,
                    repositoryDescriptor: repositoryDescriptor,
                    repositoryIdentity: repositoryIdentity
                )
            } catch {
                Darwin.close(repositoryDescriptor)
                throw error
            }
            guard let work else { throw EncryptedCheckpointWriterError.verificationFailed }
            let signer = try BackupDeviceSigner(
                descriptor: configuration.descriptor,
                authorization: configuration.authorization,
                deviceSigningSeed: configuration.deviceSigningSeed
            )
            let failureState = CheckpointWriteFailureState()
            let publicationState = CheckpointPublicationState()
            let sink = BackupContainerWriteSink(
                write: { [writeFailureInjector] bytes in
                    if let code = writeFailureInjector(.encryptedPayload) {
                        failureState.record(code)
                        throw EncryptedCheckpointWriterError.ioFailure(code)
                    }
                    do {
                        try work.append(bytes)
                    } catch EncryptedCheckpointWriterError.ioFailure(let code) {
                        failureState.record(code)
                        throw EncryptedCheckpointWriterError.ioFailure(code)
                    }
                },
                readBackSource: work.source,
                finalizeAndReadBackSource: {
                    [source, configurationStore, eventHandler, publicationFenceValidator]
                    checkpointID in
                    try await eventHandler(.beforeFinalSourceValidation)
                    do {
                        try publicationFenceValidator()
                    } catch {
                        throw EncryptedCheckpointWriterError.repositoryIdentityChanged
                    }
                    guard let current = try await configurationStore.load(),
                          current.phase == .enabled,
                          current.writerIdentity == configuration.writerIdentity else {
                        throw EncryptedCheckpointWriterError.invalidConfiguration
                    }
                    let published = try await source.withValidatedCurrentPair(for: plan) {
                        try work.synchronizeAndPublish(checkpointID: checkpointID)
                    }
                    publicationState.set(published)
                    try await eventHandler(.afterPublication(
                        repositoryURL.appendingPathComponent(published.leafName)
                    ))
                    return try work.source()
                }
            )
            let containerResult: EncryptedBackupContainerWriteResult
            do {
                containerResult = try await containerWriter.write(
                    entries: await source.containerSources(for: plan),
                    revisionPair: plan.revisionPair,
                    sequence: sequence,
                    signer: signer,
                    sink: sink
                )
            } catch {
                if failureState.value == ENOSPC {
                    throw EncryptedCheckpointWriterError.capacityInsufficient
                }
                throw error
            }
            guard let publication = publicationState.value else {
                throw EncryptedCheckpointWriterError.publicationIndeterminate
            }
            do {
                try publicationFenceValidator()
            } catch {
                throw EncryptedCheckpointWriterError.publicationIndeterminate
            }
            try work.validatePublishedIdentity(
                leafName: publication.leafName,
                expected: publication.identity
            )
            let checkpoint = try BackupPublicCheckpoint(
                setID: configuration.descriptor.setID,
                checkpointID: containerResult.checkpointID,
                deviceID: configuration.authorization.deviceID,
                authorizationID: configuration.authorization.authorizationID,
                sequence: sequence,
                commitment: containerResult.commitment
            )
            let observedAt = Date(
                timeIntervalSince1970:
                    (Date().timeIntervalSince1970 * 1_000).rounded() / 1_000
            )
            let witness = try BackupDurableFullReaderWitness(
                checkpoint: checkpoint,
                writerEpoch: configuration.writerEpoch,
                repositoryIdentityDigest: Self.repositoryIdentityDigest(
                    repository: repositoryIdentity,
                    file: publication.identity
                ),
                continuousObservationStartedAt: observedAt,
                lastObservedAt: observedAt
            )
            do {
                _ = try await configurationStore.appendVerificationWitness(
                    witness,
                    expectedWriterIdentity: configuration.writerIdentity
                )
            } catch {
                // The final name is already durable and fully read back. If
                // its writer authority cannot be durably witnessed, ownership
                // is unknown; never delete the final as cleanup.
                throw EncryptedCheckpointWriterError.publicationIndeterminate
            }
            do {
                try publicationFenceValidator()
            } catch {
                throw EncryptedCheckpointWriterError.publicationIndeterminate
            }
            do {
                try work.validatePublishedIdentity(
                    leafName: publication.leafName,
                    expected: publication.identity
                )
            } catch {
                throw EncryptedCheckpointWriterError.publicationIndeterminate
            }
            let maximumOpen = await source.maximumSimultaneousOpenFileCount
            work.close()
            return EncryptedCheckpointWriteResult(
                finalLeafName: publication.leafName,
                fileIdentity: publication.identity,
                revisionPair: plan.revisionPair,
                witness: witness,
                maximumBufferedPlaintextByteCount: containerResult.maximumBufferedPlaintextByteCount,
                maximumSimultaneousSourceFileCount: maximumOpen
            )
        } catch is CancellationError {
            work?.close()
            throw CancellationError()
        } catch let error as EncryptedCheckpointWriterError {
            work?.close()
            throw error
        } catch PlaintextLibraryBackupSourceError.sourceChanged {
            work?.close()
            throw EncryptedCheckpointWriterError.sourceChanged
        } catch BackupContainerError.sourceIntegrityFailure {
            work?.close()
            throw EncryptedCheckpointWriterError.sourceChanged
        } catch is BackupContainerError {
            work?.close()
            throw EncryptedCheckpointWriterError.verificationFailed
        } catch BackupLocalConfigurationStoreError.compareAndSwapFailed {
            work?.close()
            throw EncryptedCheckpointWriterError.publicationIndeterminate
        } catch {
            work?.close()
            throw EncryptedCheckpointWriterError.verificationFailed
        }
    }

    private func validateConfiguration(
        _ configuration: BackupLocalConfiguration,
        sequence: UInt64
    ) async throws {
        guard configuration.phase == .enabled,
              configuration.writerEpoch == configuration.enrollmentEpoch,
              sequence >= configuration.authorization.sequenceFloor,
              let current = try await configurationStore.load(),
              current.phase == .enabled,
              current.writerIdentity == configuration.writerIdentity else {
            throw EncryptedCheckpointWriterError.invalidConfiguration
        }
        do {
            try BackupKeyHierarchy.validateEnrollment(
                descriptor: configuration.descriptor,
                authorization: configuration.authorization,
                deviceSigningSeed: configuration.deviceSigningSeed
            )
        } catch {
            throw EncryptedCheckpointWriterError.invalidConfiguration
        }
    }

    private static func validateEnrollment(
        repositoryDescriptor: Int32,
        configuration: BackupLocalConfiguration
    ) throws {
        guard try strictRead(
            "backup-set-descriptor.bin",
            at: repositoryDescriptor
        ) == configuration.descriptor.canonicalBytes,
        try strictRead(
            "writer-authorization.bin",
            at: repositoryDescriptor
        ) == configuration.authorization.canonicalBytes else {
            throw EncryptedCheckpointWriterError.invalidConfiguration
        }
    }

    private static func strictRead(_ name: String, at parent: Int32) throws -> Data {
        let descriptor = openat(parent, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw EncryptedCheckpointWriterError.invalidConfiguration
        }
        defer { Darwin.close(descriptor) }
        let identity = try CheckpointWorkFile.strictFileIdentity(descriptor)
        guard identity.byteCount <= 256 * 1_024 else {
            throw EncryptedCheckpointWriterError.invalidConfiguration
        }
        var result = Data()
        var offset: UInt64 = 0
        while offset < identity.byteCount {
            let bytes = try CheckpointWorkFile.read(
                descriptor: descriptor,
                offset: offset,
                count: Int(min(16 * 1_024, identity.byteCount - offset))
            )
            guard !bytes.isEmpty else {
                throw EncryptedCheckpointWriterError.invalidConfiguration
            }
            result.append(bytes)
            offset += UInt64(bytes.count)
        }
        return result
    }

    private static func validateCapacity(
        repositoryDescriptor: Int32,
        plaintextByteCount: UInt64
    ) throws {
        var filesystem = statfs()
        guard fstatfs(repositoryDescriptor, &filesystem) == 0 else {
            throw EncryptedCheckpointWriterError.ioFailure(errno)
        }
        let blocks = UInt64(filesystem.f_bavail)
        let blockSize = UInt64(filesystem.f_bsize)
        let available = blocks.multipliedReportingOverflow(by: blockSize)
        let withAllowance = plaintextByteCount.addingReportingOverflow(
            BackupFormatLimits.targetFormatAllowanceByteCount
        )
        let required = withAllowance.partialValue.addingReportingOverflow(
            BackupFormatLimits.capacityHeadroomByteCount
        )
        guard !available.overflow,
              !withAllowance.overflow,
              !required.overflow,
              available.partialValue >= required.partialValue else {
            throw EncryptedCheckpointWriterError.capacityInsufficient
        }
    }

    private static func repositoryIdentityDigest(
        repository: BackupFilesystemIdentity,
        file: BackupPublishedFileIdentity
    ) -> Data {
        var input = Data("com.kinlogue.backup/repository-leaf-identity/v1".utf8)
        for value in [repository.device, repository.inode, file.device, file.inode, file.byteCount] {
            var bigEndian = value.bigEndian
            withUnsafeBytes(of: &bigEndian) { input.append(contentsOf: $0) }
        }
        return Data(SHA256.hash(data: input))
    }
}
