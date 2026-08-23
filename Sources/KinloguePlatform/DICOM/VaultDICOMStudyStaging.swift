import CryptoKit
import Darwin
import Foundation
import KinlogueCore

public struct VaultDICOMStagingOwnership: Codable, Equatable, Sendable {
    public let operationID: UUID
    let device: UInt64
    let inode: UInt64

    fileprivate init(operationID: UUID, metadata: stat) {
        self.operationID = operationID
        device = UInt64(metadata.st_dev)
        inode = UInt64(metadata.st_ino)
    }

    fileprivate func matches(_ metadata: stat) -> Bool {
        device == UInt64(metadata.st_dev) && inode == UInt64(metadata.st_ino)
            && (metadata.st_mode & S_IFMT) == S_IFDIR
            && metadata.st_uid == geteuid()
    }
}

public struct VaultDICOMStagedObject: Equatable, Sendable {
    public let ownership: VaultDICOMStagingOwnership
    public let stagingID: UUID
    public let relativePath: String
    public let byteCount: Int
    public let sha256Digest: Data

    public init(
        ownership: VaultDICOMStagingOwnership,
        stagingID: UUID,
        relativePath: String,
        byteCount: Int,
        sha256Digest: Data
    ) throws {
        guard byteCount > 0, sha256Digest.count == 32,
              relativePath == Self.path(
                operationID: ownership.operationID,
                stagingID: stagingID
              ) else {
            throw DICOMImportError.integrityFailure
        }
        self.ownership = ownership
        self.stagingID = stagingID
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.sha256Digest = sha256Digest
    }

    public var operationID: UUID { ownership.operationID }

    public static func path(operationID: UUID, stagingID: UUID) -> String {
        "\(PlaintextVaultLayout.dicomImportStagingDirectoryPath(operationID: operationID))/"
            + "\(stagingID.uuidString.lowercased()).data"
    }
}

// SAFETY: The scanner is the only close owner. Its structured child tasks may
// concurrently read rawValue for POSIX operations, but never mutate or close
// the lease; withThrowingTaskGroup joins before the scanner calls close().
final class VaultDICOMOperationDescriptorLease: @unchecked Sendable {
    let ownership: VaultDICOMStagingOwnership
    private(set) var rawValue: Int32

    init(ownership: VaultDICOMStagingOwnership, rawValue: Int32) {
        self.ownership = ownership
        self.rawValue = rawValue
    }

    func close() {
        guard rawValue >= 0 else { return }
        Darwin.close(rawValue)
        rawValue = -1
    }

    deinit { close() }
}

/// Same-volume, opaque, immutable staging owned by the Vault root. Source
/// display names never participate in managed paths.
public struct VaultDICOMStudyStaging: Sendable {
    typealias AvailableCapacityProvider = @Sendable (URL) throws -> Int64

    private let rootURL: URL
    private let layout: PlaintextVaultLayout
    private let policy: DICOMImportPolicy
    private let availableCapacityProvider: AvailableCapacityProvider

    public init(rootURL: URL, policy: DICOMImportPolicy = .default) throws {
        try self.init(
            rootURL: rootURL,
            policy: policy,
            availableCapacityProvider: Self.systemAvailableCapacity
        )
    }

    init(
        rootURL: URL,
        policy: DICOMImportPolicy = .default,
        availableCapacityProvider: @escaping AvailableCapacityProvider
    ) throws {
        let layout = try PlaintextVaultLayout(rootURL: rootURL)
        self.layout = layout
        self.rootURL = layout.rootURL
        self.policy = policy
        self.availableCapacityProvider = availableCapacityProvider
    }

    @discardableResult
    public func prepare(operationID: UUID) throws
        -> VaultDICOMStagingOwnership {
        let operationDescriptor = try openOrCreateOperationDirectory(operationID: operationID)
        defer { Darwin.close(operationDescriptor) }
        var metadata = stat()
        guard fstat(operationDescriptor, &metadata) == 0 else {
            throw DICOMImportError.integrityFailure
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        let root = rootURL.appendingPathComponent(
            layout.dicomImportStagingDirectoryPath,
            isDirectory: true
        )
        var mutableRoot = root
        try? mutableRoot.setResourceValues(values)
        return VaultDICOMStagingOwnership(operationID: operationID, metadata: metadata)
    }

    public func stage(
        sourceDescriptor: Int32,
        declaredByteCount: Int,
        ownership: VaultDICOMStagingOwnership,
        stagedByteCountBeforeCopy: Int
    ) throws -> VaultDICOMStagedObject {
        try stage(
            sourceDescriptor: sourceDescriptor,
            declaredByteCount: declaredByteCount,
            ownership: ownership,
            stagedByteCountBeforeCopy: stagedByteCountBeforeCopy,
            permitsTemporaryDeduplicationCandidate: false
        )
    }

    func stageDeduplicationCandidate(
        sourceDescriptor: Int32,
        declaredByteCount: Int,
        ownership: VaultDICOMStagingOwnership,
        stagedByteCountBeforeCopy: Int,
        operationLease: VaultDICOMOperationDescriptorLease
    ) throws -> VaultDICOMStagedObject {
        try stage(
            sourceDescriptor: sourceDescriptor,
            declaredByteCount: declaredByteCount,
            ownership: ownership,
            stagedByteCountBeforeCopy: stagedByteCountBeforeCopy,
            permitsTemporaryDeduplicationCandidate: true,
            operationLease: operationLease
        )
    }

    private func stage(
        sourceDescriptor: Int32,
        declaredByteCount: Int,
        ownership: VaultDICOMStagingOwnership,
        stagedByteCountBeforeCopy: Int,
        permitsTemporaryDeduplicationCandidate: Bool,
        operationLease: VaultDICOMOperationDescriptorLease? = nil
    ) throws -> VaultDICOMStagedObject {
        guard declaredByteCount > 0, declaredByteCount <= policy.maximumObjectBytes else {
            throw DICOMImportError.resourceLimit
        }
        let operationID = ownership.operationID
        guard stagedByteCountBeforeCopy >= 0,
              stagedByteCountBeforeCopy <= policy.maximumUniqueSourceBytes else {
            throw DICOMImportError.resourceLimit
        }
        let prospective = stagedByteCountBeforeCopy.addingReportingOverflow(declaredByteCount)
        let temporaryLimit = policy.maximumUniqueSourceBytes.addingReportingOverflow(
            permitsTemporaryDeduplicationCandidate ? policy.maximumObjectBytes : 0
        )
        guard !prospective.overflow, !temporaryLimit.overflow,
              prospective.partialValue <= temporaryLimit.partialValue else {
            throw DICOMImportError.resourceLimit
        }
        try requireCapacity(
            uniqueStagedBytes: min(prospective.partialValue, policy.maximumUniqueSourceBytes),
            alreadyStagedBytes: stagedByteCountBeforeCopy
        )

        var before = stat()
        guard fstat(sourceDescriptor, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFREG,
              before.st_size == declaredByteCount else {
            throw DICOMImportError.sourceChanged
        }

        let stagingID = UUID()
        let relativePath = VaultDICOMStagedObject.path(
            operationID: operationID,
            stagingID: stagingID
        )
        let operationDescriptor: Int32
        let ownsOperationDescriptor: Bool
        if let operationLease {
            guard operationLease.ownership == ownership, operationLease.rawValue >= 0 else {
                throw DICOMImportError.integrityFailure
            }
            operationDescriptor = operationLease.rawValue
            ownsOperationDescriptor = false
        } else {
            operationDescriptor = try openOperationDirectory(ownership: ownership)
            ownsOperationDescriptor = true
        }
        defer { if ownsOperationDescriptor { Darwin.close(operationDescriptor) } }
        let filename = "\(stagingID.uuidString.lowercased()).data"
        let descriptor = filename.withCString {
            openat(
                operationDescriptor,
                $0,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else { throw DICOMImportError.integrityFailure }
        var targetOpen = true
        var succeeded = false
        defer {
            if targetOpen { Darwin.close(descriptor) }
            if !succeeded { filename.withCString { _ = unlinkat(operationDescriptor, $0, 0) } }
        }

        var hasher = SHA256()
        var offset: off_t = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while offset < before.st_size {
            if Task.isCancelled { throw DICOMImportError.cancelled }
            let amount = min(buffer.count, Int(before.st_size - offset))
            let readCount = buffer.withUnsafeMutableBytes { bytes in
                Darwin.pread(sourceDescriptor, bytes.baseAddress, amount, offset)
            }
            guard readCount > 0 else { throw DICOMImportError.sourceChanged }
            try buffer.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var written = 0
                while written < readCount {
                    let count = Darwin.write(descriptor, base.advanced(by: written), readCount - written)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw DICOMImportError.integrityFailure }
                    written += count
                }
                hasher.update(bufferPointer: .init(start: base, count: readCount))
            }
            offset += off_t(readCount)
        }
        var after = stat()
        guard fstat(sourceDescriptor, &after) == 0,
              sameSnapshot(before, after), offset == before.st_size else {
            throw DICOMImportError.sourceChanged
        }
        guard fchmod(descriptor, S_IRUSR) == 0,
              fcntl(descriptor, F_FULLFSYNC) == 0 || fsync(descriptor) == 0,
              Darwin.close(descriptor) == 0 else {
            throw DICOMImportError.integrityFailure
        }
        targetOpen = false
        try syncDescriptor(operationDescriptor)
        succeeded = true
        return try VaultDICOMStagedObject(
            ownership: ownership,
            stagingID: stagingID,
            relativePath: relativePath,
            byteCount: declaredByteCount,
            sha256Digest: Data(hasher.finalize())
        )
    }

    /// Removes one exact staged object without resolving its relative path as
    /// a filesystem path. Both the opened inode and its content identity must
    /// still match the scanner-owned object before unlink.
    func remove(
        _ object: VaultDICOMStagedObject,
        operationLease: VaultDICOMOperationDescriptorLease
    ) throws {
        guard operationLease.ownership == object.ownership,
              operationLease.rawValue >= 0 else {
            throw DICOMImportError.integrityFailure
        }
        let operationDescriptor = operationLease.rawValue
        let filename = "\(object.stagingID.uuidString.lowercased()).data"
        guard object.relativePath == VaultDICOMStagedObject.path(
            operationID: object.operationID,
            stagingID: object.stagingID
        ) else { throw DICOMImportError.integrityFailure }

        var before = stat()
        guard filename.withCString({
            fstatat(operationDescriptor, $0, &before, AT_SYMLINK_NOFOLLOW)
        }) == 0, (before.st_mode & S_IFMT) == S_IFREG,
              before.st_size == object.byteCount else {
            throw DICOMImportError.integrityFailure
        }
        let descriptor = filename.withCString {
            openat(operationDescriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw DICOMImportError.integrityFailure }
        defer { Darwin.close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              sameFileIdentity(before, opened),
              try digestDescriptor(descriptor, expectedByteCount: object.byteCount)
                == object.sha256Digest else {
            throw DICOMImportError.integrityFailure
        }
        var after = stat(), finalName = stat()
        guard fstat(descriptor, &after) == 0,
              sameSnapshot(opened, after),
              filename.withCString({
                  fstatat(operationDescriptor, $0, &finalName, AT_SYMLINK_NOFOLLOW)
              }) == 0,
              sameFileIdentity(opened, finalName),
              filename.withCString({ unlinkat(operationDescriptor, $0, 0) }) == 0 else {
            throw DICOMImportError.integrityFailure
        }
        try syncDescriptor(operationDescriptor)
    }

    public func withDescriptor<T>(
        _ object: VaultDICOMStagedObject,
        _ body: (FileHandle) async throws -> T
    ) async throws -> T {
        let operationDescriptor = try openOperationDirectory(ownership: object.ownership)
        defer { Darwin.close(operationDescriptor) }
        let descriptor = try openStagedFile(object, operationDescriptor: operationDescriptor)
        guard descriptor >= 0 else { throw DICOMImportError.integrityFailure }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_size == object.byteCount else {
            throw DICOMImportError.integrityFailure
        }
        return try await body(handle)
    }

    func withRawDescriptor<T>(
        _ object: VaultDICOMStagedObject,
        _ body: (Int32) throws -> T
    ) throws -> T {
        let operationDescriptor = try openOperationDirectory(ownership: object.ownership)
        defer { Darwin.close(operationDescriptor) }
        let descriptor = try openStagedFile(object, operationDescriptor: operationDescriptor)
        guard descriptor >= 0 else { throw DICOMImportError.integrityFailure }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_size == object.byteCount else {
            throw DICOMImportError.integrityFailure
        }
        return try body(descriptor)
    }

    func validateCapacity(uniqueStagedBytes: Int) throws {
        try requireCapacity(
            uniqueStagedBytes: uniqueStagedBytes,
            alreadyStagedBytes: uniqueStagedBytes
        )
    }

    func openOperationDescriptorLease(
        ownership: VaultDICOMStagingOwnership
    ) throws -> VaultDICOMOperationDescriptorLease {
        .init(
            ownership: ownership,
            rawValue: try openOperationDirectory(ownership: ownership)
        )
    }

    public func read(_ object: VaultDICOMStagedObject) throws -> Data {
        try withRawDescriptor(object) {
            try readDescriptor($0, expectedByteCount: object.byteCount)
        }
    }

    public func list(ownership: VaultDICOMStagingOwnership) throws
        -> [VaultDICOMStagedObject] {
        let operationID = ownership.operationID
        let operationURL = rootURL.appendingPathComponent(
            layout.dicomImportStagingDirectoryPath(operationID: operationID),
            isDirectory: true
        )
        guard FileManager.default.fileExists(atPath: operationURL.path) else { return [] }
        let operationDescriptor = try openOperationDirectory(ownership: ownership)
        defer { Darwin.close(operationDescriptor) }
        let names = try entryNames(directoryDescriptor: operationDescriptor)
        return try names.sorted().compactMap { name in
            guard name.hasSuffix(".data"),
                  let stagingID = UUID(uuidString: String(name.dropLast(5))) else { return nil }
            let relativePath = VaultDICOMStagedObject.path(
                operationID: operationID,
                stagingID: stagingID
            )
            let descriptor = name.withCString {
                openat(operationDescriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard descriptor >= 0 else { throw DICOMImportError.integrityFailure }
            defer { Darwin.close(descriptor) }
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0,
                  (metadata.st_mode & S_IFMT) == S_IFREG,
                  metadata.st_size > 0,
                  metadata.st_size <= policy.maximumObjectBytes else {
                throw DICOMImportError.integrityFailure
            }
            return try VaultDICOMStagedObject(
                ownership: ownership,
                stagingID: stagingID,
                relativePath: relativePath,
                byteCount: Int(metadata.st_size),
                sha256Digest: digestDescriptor(
                    descriptor,
                    expectedByteCount: Int(metadata.st_size)
                )
            )
        }
    }

    public func cleanup(ownership: VaultDICOMStagingOwnership) throws {
        try removeOwnedOperation(ownership: ownership, allowMissing: true)
    }

    func removeOwnedOperation(
        ownership: VaultDICOMStagingOwnership,
        allowMissing: Bool
    ) throws {
        let hierarchy: (root: Int32, staging: Int32)
        do {
            hierarchy = try openStagingHierarchy()
        } catch where allowMissing && errno == ENOENT {
            return
        }
        defer {
            Darwin.close(hierarchy.staging)
            Darwin.close(hierarchy.root)
        }
        let operationName = ownership.operationID.uuidString.lowercased()
        let operationDescriptor = operationName.withCString {
            openat(hierarchy.staging, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        if operationDescriptor < 0, allowMissing && errno == ENOENT { return }
        guard operationDescriptor >= 0 else { throw DICOMImportError.integrityFailure }
        defer { Darwin.close(operationDescriptor) }
        var operationMetadata = stat()
        guard fstat(operationDescriptor, &operationMetadata) == 0,
              ownership.matches(operationMetadata) else {
            throw DICOMImportError.integrityFailure
        }

        for name in try entryNames(directoryDescriptor: operationDescriptor).sorted() {
            guard name.hasSuffix(".data"),
                  UUID(uuidString: String(name.dropLast(5))) != nil else {
                throw DICOMImportError.integrityFailure
            }
            var before = stat()
            guard name.withCString({
                fstatat(operationDescriptor, $0, &before, AT_SYMLINK_NOFOLLOW)
            }) == 0, (before.st_mode & S_IFMT) == S_IFREG else {
                throw DICOMImportError.integrityFailure
            }
            let fileDescriptor = name.withCString {
                openat(operationDescriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard fileDescriptor >= 0 else { throw DICOMImportError.integrityFailure }
            var opened = stat(), finalName = stat()
            let openedStatus = fstat(fileDescriptor, &opened)
            Darwin.close(fileDescriptor)
            guard openedStatus == 0,
                  opened.st_dev == before.st_dev, opened.st_ino == before.st_ino,
                  name.withCString({
                    fstatat(operationDescriptor, $0, &finalName, AT_SYMLINK_NOFOLLOW)
                  }) == 0,
                  finalName.st_dev == opened.st_dev, finalName.st_ino == opened.st_ino,
                  (finalName.st_mode & S_IFMT) == S_IFREG,
                  name.withCString({ unlinkat(operationDescriptor, $0, 0) }) == 0 else {
                throw DICOMImportError.integrityFailure
            }
        }
        try syncDescriptor(operationDescriptor)
        guard operationName.withCString({
            unlinkat(hierarchy.staging, $0, AT_REMOVEDIR)
        }) == 0 || errno == ENOENT else {
            throw DICOMImportError.integrityFailure
        }
        try syncDescriptor(hierarchy.staging)
        if layout.dicomImportStagingDirectoryPath.withCString({
            unlinkat(hierarchy.root, $0, AT_REMOVEDIR)
        }) == 0 {
            try syncDescriptor(hierarchy.root)
        } else if errno != ENOTEMPTY && errno != EEXIST && errno != ENOENT {
            throw DICOMImportError.integrityFailure
        }
    }

    func removeUnboundEmptyOperation(operationID: UUID) throws {
        let hierarchy: (root: Int32, staging: Int32)
        do { hierarchy = try openStagingHierarchy() }
        catch where errno == ENOENT { return }
        defer {
            Darwin.close(hierarchy.staging)
            Darwin.close(hierarchy.root)
        }
        let operationName = operationID.uuidString.lowercased()
        let operationDescriptor = operationName.withCString {
            openat(hierarchy.staging, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        if operationDescriptor < 0, errno == ENOENT { return }
        guard operationDescriptor >= 0 else { throw DICOMImportError.integrityFailure }
        let names: [String]
        do {
            defer { Darwin.close(operationDescriptor) }
            names = try entryNames(directoryDescriptor: operationDescriptor)
        }
        guard names.isEmpty,
              operationName.withCString({
                unlinkat(hierarchy.staging, $0, AT_REMOVEDIR)
              }) == 0 || errno == ENOENT else {
            throw DICOMImportError.integrityFailure
        }
        try syncDescriptor(hierarchy.staging)
    }

    private func requireCapacity(
        uniqueStagedBytes: Int,
        alreadyStagedBytes: Int
    ) throws {
        let required = try policy.requiredAdditionalFreeBytes(
            forUniqueStagedBytes: uniqueStagedBytes,
            alreadyStagedBytes: alreadyStagedBytes
        )
        let available = try availableCapacityProvider(rootURL)
        guard available >= Int64(required) else {
            throw DICOMImportError.insufficientCapacity
        }
    }

    static func systemAvailableCapacity(rootURL: URL) throws -> Int64 {
        var info = statfs()
        guard statfs(rootURL.path, &info) == 0 else { throw DICOMImportError.insufficientCapacity }
        let available = Int64(info.f_bavail).multipliedReportingOverflow(by: Int64(info.f_bsize))
        guard !available.overflow else {
            throw DICOMImportError.insufficientCapacity
        }
        return available.partialValue
    }

    private func readDescriptor(_ descriptor: Int32, expectedByteCount: Int) throws -> Data {
        var result = Data()
        result.reserveCapacity(expectedByteCount)
        var offset: off_t = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while offset < expectedByteCount {
            let requested = min(buffer.count, expectedByteCount - Int(offset))
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.pread(descriptor, bytes.baseAddress, requested, offset)
            }
            guard count > 0 else { throw DICOMImportError.integrityFailure }
            result.append(contentsOf: buffer.prefix(count))
            offset += off_t(count)
        }
        return result
    }

    private func openOrCreateOperationDirectory(operationID: UUID) throws -> Int32 {
        if mkdir(rootURL.path, S_IRWXU) != 0, errno != EEXIST {
            throw DICOMImportError.integrityFailure
        }
        let rootDescriptor = Darwin.open(
            rootURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard rootDescriptor >= 0 else { throw DICOMImportError.integrityFailure }
        defer { Darwin.close(rootDescriptor) }
        let stagingName = layout.dicomImportStagingDirectoryPath
        let createdStaging = stagingName.withCString {
            mkdirat(rootDescriptor, $0, S_IRWXU)
        } == 0
        guard createdStaging || errno == EEXIST else {
            throw DICOMImportError.integrityFailure
        }
        if createdStaging { try syncDescriptor(rootDescriptor) }
        let stagingDescriptor = stagingName.withCString {
            openat(rootDescriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard stagingDescriptor >= 0 else { throw DICOMImportError.integrityFailure }
        defer { Darwin.close(stagingDescriptor) }
        guard fchmod(stagingDescriptor, S_IRWXU) == 0 else {
            throw DICOMImportError.integrityFailure
        }
        let indexMarker = ".metadata_never_index"
        let markerDescriptor = indexMarker.withCString {
            openat(
                stagingDescriptor,
                $0,
                O_RDONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR
            )
        }
        guard markerDescriptor >= 0 else { throw DICOMImportError.integrityFailure }
        let markerSynchronized = fcntl(markerDescriptor, F_FULLFSYNC) == 0
            || fsync(markerDescriptor) == 0
        Darwin.close(markerDescriptor)
        guard markerSynchronized else { throw DICOMImportError.integrityFailure }
        try syncDescriptor(stagingDescriptor)
        let operationName = operationID.uuidString.lowercased()
        let createdOperation = operationName.withCString {
            mkdirat(stagingDescriptor, $0, S_IRWXU)
        } == 0
        guard createdOperation || errno == EEXIST else {
            throw DICOMImportError.integrityFailure
        }
        if createdOperation { try syncDescriptor(stagingDescriptor) }
        let operationDescriptor = operationName.withCString {
            openat(stagingDescriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard operationDescriptor >= 0, fchmod(operationDescriptor, S_IRWXU) == 0 else {
            if operationDescriptor >= 0 { Darwin.close(operationDescriptor) }
            throw DICOMImportError.integrityFailure
        }
        return operationDescriptor
    }

    private func openStagingHierarchy() throws -> (root: Int32, staging: Int32) {
        let rootDescriptor = Darwin.open(
            rootURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard rootDescriptor >= 0 else { throw DICOMImportError.integrityFailure }
        let stagingDescriptor = layout.dicomImportStagingDirectoryPath.withCString {
            openat(rootDescriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard stagingDescriptor >= 0 else {
            Darwin.close(rootDescriptor)
            throw DICOMImportError.integrityFailure
        }
        return (rootDescriptor, stagingDescriptor)
    }

    private func openOperationDirectory(ownership: VaultDICOMStagingOwnership) throws -> Int32 {
        let hierarchy = try openStagingHierarchy()
        defer {
            Darwin.close(hierarchy.staging)
            Darwin.close(hierarchy.root)
        }
        let descriptor = ownership.operationID.uuidString.lowercased().withCString {
            openat(hierarchy.staging, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw DICOMImportError.integrityFailure }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, ownership.matches(metadata) else {
            Darwin.close(descriptor)
            throw DICOMImportError.integrityFailure
        }
        return descriptor
    }

    private func openStagedFile(
        _ object: VaultDICOMStagedObject,
        operationDescriptor: Int32
    ) throws -> Int32 {
        let filename = "\(object.stagingID.uuidString.lowercased()).data"
        guard object.relativePath == VaultDICOMStagedObject.path(
            operationID: object.operationID,
            stagingID: object.stagingID
        ) else { throw DICOMImportError.integrityFailure }
        return filename.withCString {
            openat(operationDescriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
    }

    private func entryNames(directoryDescriptor: Int32) throws -> [String] {
        let duplicate = dup(directoryDescriptor)
        guard duplicate >= 0, let directory = fdopendir(duplicate) else {
            if duplicate >= 0 { Darwin.close(duplicate) }
            throw DICOMImportError.integrityFailure
        }
        defer { closedir(directory) }
        var names: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }

    private func sameSnapshot(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private func sameFileIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
            && lhs.st_size == rhs.st_size
            && (rhs.st_mode & S_IFMT) == S_IFREG
    }

    private func digestDescriptor(_ descriptor: Int32, expectedByteCount: Int) throws -> Data {
        var hasher = SHA256()
        var offset = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while offset < expectedByteCount {
            if Task.isCancelled { throw DICOMImportError.cancelled }
            let amount = min(buffer.count, expectedByteCount - offset)
            let count = buffer.withUnsafeMutableBytes {
                Darwin.pread(descriptor, $0.baseAddress, amount, off_t(offset))
            }
            guard count > 0 else { throw DICOMImportError.integrityFailure }
            buffer.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                hasher.update(bufferPointer: .init(start: base, count: count))
            }
            offset += count
        }
        var extra: UInt8 = 0
        guard Darwin.pread(descriptor, &extra, 1, off_t(offset)) == 0 else {
            throw DICOMImportError.integrityFailure
        }
        return Data(hasher.finalize())
    }

    private func syncDescriptor(_ descriptor: Int32) throws {
        guard fsync(descriptor) == 0 || errno == EINVAL || errno == ENOTSUP else {
            throw DICOMImportError.integrityFailure
        }
    }
}
