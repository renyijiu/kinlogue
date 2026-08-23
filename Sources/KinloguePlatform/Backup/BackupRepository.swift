import CryptoKit
import Darwin
import Foundation
import KinlogueCore

public enum BackupRepositoryError: Error, Equatable, Sendable {
    case offline
    case identityChanged
    case resourceLimit
    case historyFork
    case verificationFailed
    case ioFailure(Int32)
    case synchronizationFailed
}

public struct BackupRepositoryEntry: Sendable {
    public let leafName: String
    public let verification: BackupPublicVerification
    public let fileIdentity: BackupPublishedFileIdentity?
    public let repositoryIdentityDigest: Data?

    public var retentionCandidate: BackupRetentionCandidate {
        .init(
            origin: .manual,
            verification: verification,
            repositoryIdentityDigest: repositoryIdentityDigest
        )
    }
}

public struct BackupRepositoryScan: Sendable {
    public let entries: [BackupRepositoryEntry]
    public let history: BackupRepositoryHistory
    public let maximumSequence: UInt64?
    let directoryFence: BackupRepositoryDirectoryFence

    public var retentionCandidates: [BackupRetentionCandidate] {
        entries.map(\.retentionCandidate)
    }
}

public struct BackupRepositoryLeaseAuthority: Hashable, Sendable {
    public let namespaceURL: URL
    public let namespaceIdentity: BackupFilesystemIdentity
    public let repositoryIdentity: BackupFilesystemIdentity
    public let setID: BackupSetID
    public let authorizationID: BackupAuthorizationID
    public let writerEpoch: BackupWriterEpoch

    public init(
        configurationRootURL: URL,
        configuration: BackupLocalConfiguration
    ) {
        namespaceURL = configurationRootURL.standardizedFileURL
        namespaceIdentity = configuration.configurationRootIdentity
        repositoryIdentity = configuration.repositoryDirectoryIdentity
        setID = configuration.descriptor.setID
        authorizationID = configuration.authorization.authorizationID
        writerEpoch = configuration.writerEpoch
    }

    init(
        namespaceURL: URL,
        namespaceIdentity: BackupFilesystemIdentity,
        repositoryIdentity: BackupFilesystemIdentity,
        setID: BackupSetID,
        authorizationID: BackupAuthorizationID,
        writerEpoch: BackupWriterEpoch
    ) {
        self.namespaceURL = namespaceURL.standardizedFileURL
        self.namespaceIdentity = namespaceIdentity
        self.repositoryIdentity = repositoryIdentity
        self.setID = setID
        self.authorizationID = authorizationID
        self.writerEpoch = writerEpoch
    }
}

struct BackupRepositoryDirectoryFence: Equatable, Sendable {
    let identity: BackupFilesystemIdentity
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let changeSeconds: Int64
    let changeNanoseconds: Int64
}

// SAFETY: stateLock protects descriptor ownership, the retention directory
// fence, and idempotent release. The lease is repository-instance-bound and
// never exposes its descriptors outside this file.
final class BackupRepositoryMutationLease: @unchecked Sendable {
    let ownerID: UUID
    let authority: BackupRepositoryLeaseAuthority
    private let stateLock = NSLock()
    private var repositoryDescriptor: Int32?
    private var lockDescriptor: Int32?
    private var directoryFence: BackupRepositoryDirectoryFence?

    init(
        ownerID: UUID,
        authority: BackupRepositoryLeaseAuthority,
        repositoryDescriptor: Int32,
        lockDescriptor: Int32
    ) {
        self.ownerID = ownerID
        self.authority = authority
        self.repositoryDescriptor = repositoryDescriptor
        self.lockDescriptor = lockDescriptor
    }

    var isHeld: Bool {
        stateLock.withLock { repositoryDescriptor != nil && lockDescriptor != nil }
    }

    func withDescriptors<T>(
        _ body: (Int32, Int32) throws -> T
    ) throws -> T {
        try stateLock.withLock {
            guard let repositoryDescriptor, let lockDescriptor else {
                throw BackupRepositoryError.identityChanged
            }
            return try body(repositoryDescriptor, lockDescriptor)
        }
    }

    func release() {
        let descriptors = stateLock.withLock { () -> (Int32?, Int32?) in
            defer {
                repositoryDescriptor = nil
                lockDescriptor = nil
                directoryFence = nil
            }
            return (repositoryDescriptor, lockDescriptor)
        }
        if let lockDescriptor = descriptors.1 {
            _ = flock(lockDescriptor, LOCK_UN)
            Darwin.close(lockDescriptor)
        }
        if let repositoryDescriptor = descriptors.0 {
            Darwin.close(repositoryDescriptor)
        }
    }

    func installDirectoryFence(_ fence: BackupRepositoryDirectoryFence) throws {
        try stateLock.withLock {
            guard repositoryDescriptor != nil, lockDescriptor != nil else {
                throw BackupRepositoryError.identityChanged
            }
            directoryFence = fence
        }
    }

    func expectedDirectoryFence() throws -> BackupRepositoryDirectoryFence {
        try stateLock.withLock {
            guard repositoryDescriptor != nil,
                  lockDescriptor != nil,
                  let directoryFence else {
                throw BackupRepositoryError.identityChanged
            }
            return directoryFence
        }
    }

    func advanceDirectoryFence(
        from expected: BackupRepositoryDirectoryFence,
        to updated: BackupRepositoryDirectoryFence
    ) throws {
        try stateLock.withLock {
            guard repositoryDescriptor != nil,
                  lockDescriptor != nil,
                  directoryFence == expected else {
                throw BackupRepositoryError.identityChanged
            }
            directoryFence = updated
        }
    }

    deinit { release() }
}

/// Descriptor-rooted, direct-child-only view of the Kinlogue-owned namespace.
/// File names, mtimes, extensions, and provider metadata are never trust roots.
// SAFETY: Repository authority fields are immutable; historyLock protects the
// only mutable cross-scan high-water and checkpoint commitment state.
public final class BackupRepository: @unchecked Sendable {
    private static let finalSuffix = ".kinloguebackup"
    private static let legacyMutationLockName = ".kinlogue-publication.lock"
    private static let maximumCheckpointByteCount =
        BackupFormatLimits.maximumPlaintextByteCount
        + BackupFormatLimits.targetFormatAllowanceByteCount
        + 1 * 1_024 * 1_024

    public let repositoryURL: URL
    public let expectedIdentity: BackupFilesystemIdentity
    public let trustedDescriptor: BackupSetDescriptor
    public let expectedAuthorizationID: BackupAuthorizationID?
    public let leaseAuthority: BackupRepositoryLeaseAuthority
    private let directorySynchronizer: @Sendable (Int32) throws -> Void
    private let scanObserver: @Sendable () -> Void

    private let historyLock = NSLock()
    private let mutationLeaseOwnerID = UUID()
    private var previouslySeen: [BackupCheckpointID: (sequence: UInt64, commitment: Data)] = [:]
    private var previousMaximumSequence: UInt64?

    public init(
        repositoryURL: URL,
        expectedIdentity: BackupFilesystemIdentity,
        trustedDescriptor: BackupSetDescriptor,
        expectedAuthorizationID: BackupAuthorizationID? = nil,
        leaseAuthority: BackupRepositoryLeaseAuthority
    ) {
        self.repositoryURL = repositoryURL.standardizedFileURL
        self.expectedIdentity = expectedIdentity
        self.trustedDescriptor = trustedDescriptor
        self.expectedAuthorizationID = expectedAuthorizationID
        self.leaseAuthority = leaseAuthority
        directorySynchronizer = Self.synchronize
        scanObserver = {}
    }

    init(
        repositoryURL: URL,
        expectedIdentity: BackupFilesystemIdentity,
        trustedDescriptor: BackupSetDescriptor,
        expectedAuthorizationID: BackupAuthorizationID? = nil,
        leaseAuthority: BackupRepositoryLeaseAuthority,
        directorySynchronizer: @escaping @Sendable (Int32) throws -> Void
    ) {
        self.repositoryURL = repositoryURL.standardizedFileURL
        self.expectedIdentity = expectedIdentity
        self.trustedDescriptor = trustedDescriptor
        self.expectedAuthorizationID = expectedAuthorizationID
        self.leaseAuthority = leaseAuthority
        self.directorySynchronizer = directorySynchronizer
        scanObserver = {}
    }

    init(
        repositoryURL: URL,
        expectedIdentity: BackupFilesystemIdentity,
        trustedDescriptor: BackupSetDescriptor,
        expectedAuthorizationID: BackupAuthorizationID? = nil,
        leaseAuthority: BackupRepositoryLeaseAuthority,
        scanObserver: @escaping @Sendable () -> Void
    ) {
        self.repositoryURL = repositoryURL.standardizedFileURL
        self.expectedIdentity = expectedIdentity
        self.trustedDescriptor = trustedDescriptor
        self.expectedAuthorizationID = expectedAuthorizationID
        self.leaseAuthority = leaseAuthority
        directorySynchronizer = Self.synchronize
        self.scanObserver = scanObserver
    }

    public func scan() throws -> BackupRepositoryScan {
        let root = try openRepository()
        defer { Darwin.close(root) }
        return try scan(root: root)
    }

    private func scan(root: Int32) throws -> BackupRepositoryScan {
        scanObserver()
        let startingFence = try directoryFence(root)
        let names = try directChildNames(root)
        guard names.count <= BackupFormatLimits.maximumCandidateFileCount else {
            throw BackupRepositoryError.resourceLimit
        }
        var entries: [BackupRepositoryEntry] = []
        entries.reserveCapacity(names.count)
        for name in names.sorted() {
            try Task.checkCancellation()
            entries.append(try inspect(name, at: root))
        }
        let endingFence = try directoryFence(root)
        guard endingFence == startingFence else {
            throw BackupRepositoryError.identityChanged
        }
        let verified = entries.compactMap { entry -> BackupPublicCheckpoint? in
            guard case let .verified(point) = entry.verification else { return nil }
            return point
        }
        let currentHistory = history(for: verified)
        let maximum = verified.map(\.sequence).max()
        let historical = historyLock.withLock {
            var result = currentHistory
            if let previousMaximumSequence,
               let maximum,
               maximum < previousMaximumSequence {
                result = .fork(.sequenceRegression)
            }
            for point in verified {
                if previouslySeen[point.checkpointID] == nil,
                   let previousMaximumSequence,
                   point.sequence <= previousMaximumSequence {
                    result = .fork(.hiddenHistoryRevealed)
                }
                previouslySeen[point.checkpointID] = (
                    point.sequence,
                    point.commitment.digest
                )
            }
            if let maximum {
                previousMaximumSequence = max(previousMaximumSequence ?? maximum, maximum)
            }
            return result
        }
        return .init(
            entries: entries,
            history: historical,
            maximumSequence: maximum,
            directoryFence: endingFence
        )
    }

    func acquireMutationLease() async throws -> BackupRepositoryMutationLease {
        guard leaseAuthority.repositoryIdentity == expectedIdentity,
              leaseAuthority.setID == trustedDescriptor.setID,
              leaseAuthority.authorizationID == expectedAuthorizationID else {
            throw BackupRepositoryError.identityChanged
        }
        let root = try openRepository()
        var lockDescriptor: Int32 = -1
        do {
            lockDescriptor = Darwin.open(
                leaseAuthority.namespaceURL.path,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
            )
            guard lockDescriptor >= 0 else {
                throw BackupRepositoryError.identityChanged
            }
            guard try Self.directoryIdentity(lockDescriptor)
                == leaseAuthority.namespaceIdentity else {
                throw BackupRepositoryError.identityChanged
            }

            while true {
                try Task.checkCancellation()
                if flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 { break }
                switch errno {
                case EINTR:
                    continue
                case EWOULDBLOCK:
                    try await Task.sleep(for: .milliseconds(10))
                default:
                    throw BackupRepositoryError.ioFailure(errno)
                }
            }
            try Task.checkCancellation()
            guard try Self.directoryIdentity(root) == expectedIdentity,
                  try Self.directoryIdentity(lockDescriptor)
                    == leaseAuthority.namespaceIdentity else {
                throw BackupRepositoryError.identityChanged
            }
            let visible = try openRepository()
            Darwin.close(visible)
            let visibleNamespace = try openLeaseNamespace()
            Darwin.close(visibleNamespace)
            return BackupRepositoryMutationLease(
                ownerID: mutationLeaseOwnerID,
                authority: leaseAuthority,
                repositoryDescriptor: root,
                lockDescriptor: lockDescriptor
            )
        } catch {
            if lockDescriptor >= 0 {
                _ = flock(lockDescriptor, LOCK_UN)
                Darwin.close(lockDescriptor)
            }
            Darwin.close(root)
            throw error
        }
    }

    func scan(holding lease: BackupRepositoryMutationLease) throws -> BackupRepositoryScan {
        try validateMutationLease(lease)
        let authoritativeScan: BackupRepositoryScan = try lease.withDescriptors { root, _ in
            try self.scan(root: root)
        }
        try lease.installDirectoryFence(authoritativeScan.directoryFence)
        return authoritativeScan
    }

    public func deleteExact(_ entry: BackupRepositoryEntry) throws {
        guard isOpaqueFinalName(entry.leafName),
              case let .verified(expectedPoint) = entry.verification,
              let expectedFileIdentity = entry.fileIdentity,
              let expectedDigest = entry.repositoryIdentityDigest else {
            throw BackupRepositoryError.verificationFailed
        }
        let root = try openRepository()
        defer { Darwin.close(root) }
        let reopened = try inspectFinal(entry.leafName, at: root)
        guard case let .verified(point) = reopened.verification,
              point == expectedPoint,
              reopened.fileIdentity == expectedFileIdentity,
              reopened.repositoryIdentityDigest == expectedDigest else {
            throw BackupRepositoryError.identityChanged
        }
        guard unlinkat(root, entry.leafName, 0) == 0 else {
            throw BackupRepositoryError.ioFailure(errno)
        }
        do {
            try directorySynchronizer(root)
        } catch {
            throw BackupRepositoryError.synchronizationFailed
        }
    }

    func deleteExact(
        _ entry: BackupRepositoryEntry,
        preserving protectedEntries: [BackupRepositoryEntry],
        holding lease: BackupRepositoryMutationLease
    ) throws {
        try validateMutationLease(lease)
        let expectedFence = try lease.expectedDirectoryFence()
        let updatedFence = try lease.withDescriptors { root, _ in
            guard try directoryFence(root) == expectedFence else {
                throw BackupRepositoryError.identityChanged
            }
            try requireExact(entry, at: root)
            for protectedEntry in protectedEntries {
                guard protectedEntry.leafName != entry.leafName else {
                    throw BackupRepositoryError.verificationFailed
                }
                try requireExact(protectedEntry, at: root)
            }
            guard unlinkat(root, entry.leafName, 0) == 0 else {
                throw BackupRepositoryError.ioFailure(errno)
            }
            do {
                try directorySynchronizer(root)
            } catch {
                throw BackupRepositoryError.synchronizationFailed
            }
            return try directoryFence(root)
        }
        try lease.advanceDirectoryFence(from: expectedFence, to: updatedFence)
    }

    func validateMutationLease(_ lease: BackupRepositoryMutationLease) throws {
        guard lease.ownerID == mutationLeaseOwnerID,
              lease.authority == leaseAuthority,
              lease.isHeld else {
            throw BackupRepositoryError.identityChanged
        }
        try lease.withDescriptors { repositoryDescriptor, lockDescriptor in
            guard try Self.directoryIdentity(repositoryDescriptor) == expectedIdentity,
                  try Self.directoryIdentity(lockDescriptor)
                    == leaseAuthority.namespaceIdentity else {
                throw BackupRepositoryError.identityChanged
            }
        }
        let visible = try openRepository()
        Darwin.close(visible)
        let visibleNamespace = try openLeaseNamespace()
        Darwin.close(visibleNamespace)
    }

    private func openRepository() throws -> Int32 {
        let descriptor = Darwin.open(
            repositoryURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw BackupRepositoryError.offline }
        do {
            guard try Self.directoryIdentity(descriptor) == expectedIdentity else {
                throw BackupRepositoryError.identityChanged
            }
            let visible = Darwin.open(
                repositoryURL.path,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard visible >= 0 else { throw BackupRepositoryError.identityChanged }
            defer { Darwin.close(visible) }
            guard try Self.directoryIdentity(visible) == expectedIdentity else {
                throw BackupRepositoryError.identityChanged
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private func openLeaseNamespace() throws -> Int32 {
        let descriptor = Darwin.open(
            leaseAuthority.namespaceURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw BackupRepositoryError.identityChanged }
        do {
            guard try Self.directoryIdentity(descriptor)
                == leaseAuthority.namespaceIdentity else {
                throw BackupRepositoryError.identityChanged
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private func directChildNames(_ root: Int32) throws -> [String] {
        let duplicate = dup(root)
        guard duplicate >= 0, let directory = fdopendir(duplicate) else {
            if duplicate >= 0 { Darwin.close(duplicate) }
            throw BackupRepositoryError.ioFailure(errno)
        }
        defer { closedir(directory) }
        var result: [String] = []
        errno = 0
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != "..", name != Self.legacyMutationLockName else {
                continue
            }
            result.append(name)
            guard result.count <= BackupFormatLimits.maximumCandidateFileCount else {
                throw BackupRepositoryError.resourceLimit
            }
        }
        guard errno == 0 else { throw BackupRepositoryError.ioFailure(errno) }
        return result
    }

    private func requireExact(
        _ expected: BackupRepositoryEntry,
        at root: Int32
    ) throws {
        guard isOpaqueFinalName(expected.leafName),
              case let .verified(expectedPoint) = expected.verification,
              let expectedFileIdentity = expected.fileIdentity,
              let expectedDigest = expected.repositoryIdentityDigest else {
            throw BackupRepositoryError.verificationFailed
        }
        let reopened = try inspectFinal(expected.leafName, at: root)
        guard case let .verified(point) = reopened.verification,
              point == expectedPoint,
              reopened.fileIdentity == expectedFileIdentity,
              reopened.repositoryIdentityDigest == expectedDigest else {
            throw BackupRepositoryError.identityChanged
        }
    }

    private func inspect(_ name: String, at root: Int32) throws -> BackupRepositoryEntry {
        if isOpaqueFinalName(name) {
            return try inspectFinal(name, at: root)
        }
        return .init(
            leafName: name,
            verification: .indeterminate(name.hasSuffix(".work") ? .workFile : .unknownFile),
            fileIdentity: nil,
            repositoryIdentityDigest: nil
        )
    }

    private func inspectFinal(
        _ name: String,
        at root: Int32
    ) throws -> BackupRepositoryEntry {
        var namedMetadata = stat()
        let statResult = name.withCString {
            fstatat(root, $0, &namedMetadata, AT_SYMLINK_NOFOLLOW)
        }
        guard statResult == 0 else {
            return indeterminate(name, .identityChanged)
        }
        guard (namedMetadata.st_mode & S_IFMT) == S_IFREG,
              namedMetadata.st_uid == geteuid(),
              namedMetadata.st_nlink == 1,
              namedMetadata.st_mode & 0o777 == 0o600,
              namedMetadata.st_size > 0 else {
            return indeterminate(name, .identityChanged)
        }
        guard UInt64(namedMetadata.st_size) <= Self.maximumCheckpointByteCount else {
            return rejected(name, .corruptRecord)
        }
        let descriptor = openat(root, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return indeterminate(name, .materializationFailed) }
        defer { Darwin.close(descriptor) }
        let identity: BackupPublishedFileIdentity
        do {
            identity = try Self.fileIdentity(descriptor)
        } catch {
            return indeterminate(name, .identityChanged)
        }
        let namedIdentity = BackupPublishedFileIdentity(
            device: UInt64(namedMetadata.st_dev),
            inode: UInt64(namedMetadata.st_ino),
            byteCount: UInt64(namedMetadata.st_size)
        )
        guard identity == namedIdentity else { return indeterminate(name, .identityChanged) }
        let source = BackupContainerByteSource(byteCount: identity.byteCount) { offset, count in
            try Self.read(descriptor, offset: offset, count: count)
        }
        do {
            let verified = try BackupTrustVerifier().verify(
                source: source,
                trustedDescriptor: trustedDescriptor
            )
            guard name == verified.checkpoint.checkpointID.bytes.hex + Self.finalSuffix else {
                return rejected(name, .corruptRecord)
            }
            var finalMetadata = stat()
            guard name.withCString({
                fstatat(root, $0, &finalMetadata, AT_SYMLINK_NOFOLLOW)
            }) == 0,
            BackupPublishedFileIdentity(
                device: UInt64(finalMetadata.st_dev),
                inode: UInt64(finalMetadata.st_ino),
                byteCount: UInt64(finalMetadata.st_size)
            ) == identity else {
                return indeterminate(name, .identityChanged)
            }
            return .init(
                leafName: name,
                verification: .verified(verified.checkpoint),
                fileIdentity: identity,
                repositoryIdentityDigest: Self.identityDigest(
                    repository: expectedIdentity,
                    file: identity
                )
            )
        } catch let error as BackupContainerError {
            return rejected(name, Self.rejection(for: error))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return indeterminate(name, .materializationFailed)
        }
    }

    private func history(for points: [BackupPublicCheckpoint]) -> BackupRepositoryHistory {
        let checkpointGroups = Dictionary(grouping: points, by: \.checkpointID)
        if checkpointGroups.values.contains(where: { $0.count > 1 }) {
            return .fork(.duplicateCheckpointIdentity)
        }
        let sequenceGroups = Dictionary(grouping: points, by: \.sequence)
        if sequenceGroups.values.contains(where: { group in
            Set(group.map(\.commitment)).count > 1
        }) {
            return .fork(.sameSequenceDifferentCommitment)
        }
        let authorizations = Set(points.map(\.authorizationID))
        if authorizations.count > 1 { return .fork(.overlappingAuthorization) }
        if let expectedAuthorizationID,
           authorizations.contains(where: { $0 != expectedAuthorizationID }) {
            return .fork(.unknownAuthorization)
        }
        return .linear
    }

    private func isOpaqueFinalName(_ name: String) -> Bool {
        guard name.hasSuffix(Self.finalSuffix) else { return false }
        let stem = name.dropLast(Self.finalSuffix.count)
        return stem.count == 32 && stem.allSatisfy { $0.isNumber || ("a"..."f").contains(String($0)) }
    }

    private func rejected(
        _ name: String,
        _ reason: BackupPublicVerificationRejection
    ) -> BackupRepositoryEntry {
        .init(
            leafName: name,
            verification: .rejected(reason),
            fileIdentity: nil,
            repositoryIdentityDigest: nil
        )
    }

    private func indeterminate(
        _ name: String,
        _ reason: BackupPublicVerificationIndeterminate
    ) -> BackupRepositoryEntry {
        .init(
            leafName: name,
            verification: .indeterminate(reason),
            fileIdentity: nil,
            repositoryIdentityDigest: nil
        )
    }

    private static func rejection(
        for error: BackupContainerError
    ) -> BackupPublicVerificationRejection {
        switch error {
        case .unsupportedVersion: .unsupportedVersion
        case .unsupportedSuite: .unsupportedSuite
        case .trustFailure: .signatureInvalid
        case .authenticationFailed: .authorizationInvalid
        case .trailingBytes: .footerInvalid
        case .invalidFormat, .resourceLimit, .arithmeticOverflow, .counterOverflow,
             .sourceIntegrityFailure, .outputFailure, .graphInvalid:
            .corruptRecord
        }
    }

    private static func directoryIdentity(_ descriptor: Int32) throws -> BackupFilesystemIdentity {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == geteuid(),
              metadata.st_nlink >= 2,
              metadata.st_mode & 0o777 == 0o700 else {
            throw BackupRepositoryError.identityChanged
        }
        return .init(device: UInt64(metadata.st_dev), inode: UInt64(metadata.st_ino))
    }

    private static func fileIdentity(_ descriptor: Int32) throws -> BackupPublishedFileIdentity {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_nlink == 1,
              metadata.st_mode & 0o777 == 0o600,
              metadata.st_size > 0 else {
            throw BackupRepositoryError.identityChanged
        }
        return .init(
            device: UInt64(metadata.st_dev),
            inode: UInt64(metadata.st_ino),
            byteCount: UInt64(metadata.st_size)
        )
    }

    private func directoryFence(_ descriptor: Int32) throws -> BackupRepositoryDirectoryFence {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == geteuid(),
              metadata.st_nlink >= 2,
              metadata.st_mode & 0o777 == 0o700 else {
            throw BackupRepositoryError.identityChanged
        }
        let identity = BackupFilesystemIdentity(
            device: UInt64(metadata.st_dev),
            inode: UInt64(metadata.st_ino)
        )
        guard identity == expectedIdentity else {
            throw BackupRepositoryError.identityChanged
        }
        return .init(
            identity: identity,
            modificationSeconds: Int64(metadata.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(metadata.st_mtimespec.tv_nsec),
            changeSeconds: Int64(metadata.st_ctimespec.tv_sec),
            changeNanoseconds: Int64(metadata.st_ctimespec.tv_nsec)
        )
    }

    private static func synchronize(_ descriptor: Int32) throws {
        if fcntl(descriptor, F_FULLFSYNC) == 0 { return }
        guard fsync(descriptor) == 0 else {
            throw BackupRepositoryError.synchronizationFailed
        }
    }

    private static func read(_ descriptor: Int32, offset: UInt64, count: Int) throws -> Data {
        guard count >= 0, let fileOffset = off_t(exactly: offset) else {
            throw BackupRepositoryError.verificationFailed
        }
        var bytes = Data(count: count)
        let readCount = bytes.withUnsafeMutableBytes {
            pread(descriptor, $0.baseAddress, count, fileOffset)
        }
        guard readCount >= 0 else { throw BackupRepositoryError.ioFailure(errno) }
        bytes.count = readCount
        return bytes
    }

    private static func identityDigest(
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

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
