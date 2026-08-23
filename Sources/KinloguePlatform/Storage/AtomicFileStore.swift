import Darwin
import CryptoKit
import Foundation
import KinlogueCore

public enum AtomicFileStoreFaultPoint: Equatable, Sendable {
    case afterDirectoryCreateBeforeSync
    case afterDirectorySyncBeforeParentSync
    case afterDirectoryParentSync
    case beforeDirectoryDurabilityRepair
    case afterDirectoryDurabilityRepair
    case beforeWrite
    case afterWriteBeforeSync
    case afterSyncBeforeCommit
    case afterCommitBeforeDirectorySync
    case beforeRemove
    case afterRemoveBeforeDirectorySync
}

enum AtomicFileStoreRootState: Equatable {
    case absent
    case empty
    case nonempty
}

public struct AtomicFileStore: Sendable {
    public let rootURL: URL
    private let failureInjector: (@Sendable (AtomicFileStoreFaultPoint) -> Bool)?
    private let directoryDurability = AtomicFileStoreDirectoryDurability()

    public init(
        rootURL: URL,
        failureInjector: (@Sendable (AtomicFileStoreFaultPoint) -> Bool)? = nil
    ) throws {
        self.rootURL = try PlaintextVaultLayout(rootURL: rootURL).rootURL
        self.failureInjector = failureInjector
    }

    public func writeImmutable(_ data: Data, relativePath: String) throws {
        let target = try resolved(relativePath)
        try ensureParentDirectory(of: target)
        if exists(relativePath: relativePath) { throw VaultError.objectAlreadyExists }
        let temporary = target.deletingLastPathComponent()
            .appendingPathComponent(".kinlogue-\(UUID().uuidString).tmp")
        try writeTemporary(data, to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try failIfRequested(.afterSyncBeforeCommit)
        guard Darwin.link(temporary.path, target.path) == 0 else {
            if errno == EEXIST { throw VaultError.objectAlreadyExists }
            throw VaultError.ioFailure(errno)
        }
        try failIfRequested(.afterCommitBeforeDirectorySync)
        try syncDirectory(target.deletingLastPathComponent())
    }

    /// Streams an already-open regular source into an immutable managed
    /// object. The source descriptor never becomes a catalog or Core-layer
    /// path, and both length and digest are checked before publication.
    func writeImmutable(
        copyingFrom sourceDescriptor: Int32,
        expectedByteCount: Int,
        expectedSHA256: Data,
        relativePath: String
    ) throws {
        guard expectedByteCount >= 0, expectedSHA256.count == SHA256.byteCount else {
            throw VaultError.resourceLimitExceeded
        }
        var sourceMetadata = stat()
        guard fstat(sourceDescriptor, &sourceMetadata) == 0,
              (sourceMetadata.st_mode & S_IFMT) == S_IFREG,
              sourceMetadata.st_size == expectedByteCount else {
            throw VaultError.invalidDigest
        }
        let target = try resolved(relativePath)
        try ensureParentDirectory(of: target)
        if exists(relativePath: relativePath) {
            let existing = try openRegularFile(at: target)
            defer { Darwin.close(existing) }
            let measured = try hashDescriptor(existing, expectedByteCount: expectedByteCount)
            guard measured == expectedSHA256 else { throw VaultError.objectAlreadyExists }
            return
        }

        let temporary = target.deletingLastPathComponent()
            .appendingPathComponent(".kinlogue-\(UUID().uuidString).tmp")
        try failIfRequested(.beforeWrite)
        let destination = Darwin.open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard destination >= 0 else { throw VaultError.ioFailure(errno) }
        var destinationIsOpen = true
        defer {
            if destinationIsOpen { Darwin.close(destination) }
            try? FileManager.default.removeItem(at: temporary)
        }

        var hasher = SHA256()
        var offset: off_t = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while offset < sourceMetadata.st_size {
            let amount = min(buffer.count, Int(sourceMetadata.st_size - offset))
            let readCount = buffer.withUnsafeMutableBytes { bytes in
                Darwin.pread(sourceDescriptor, bytes.baseAddress, amount, offset)
            }
            if readCount < 0 {
                if errno == EINTR { continue }
                throw VaultError.ioFailure(errno)
            }
            guard readCount > 0 else { throw VaultError.invalidDigest }
            try buffer.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var written = 0
                while written < readCount {
                    let count = Darwin.write(
                        destination,
                        base.advanced(by: written),
                        readCount - written
                    )
                    if count < 0 {
                        if errno == EINTR { continue }
                        throw VaultError.ioFailure(errno)
                    }
                    written += count
                }
                hasher.update(bufferPointer: UnsafeRawBufferPointer(
                    start: base,
                    count: readCount
                ))
            }
            offset += off_t(readCount)
        }
        guard offset == sourceMetadata.st_size,
              Data(hasher.finalize()) == expectedSHA256 else {
            throw VaultError.invalidDigest
        }
        try failIfRequested(.afterWriteBeforeSync)
        if fcntl(destination, F_FULLFSYNC) != 0, fsync(destination) != 0 {
            throw VaultError.ioFailure(errno)
        }
        guard Darwin.close(destination) == 0 else { throw VaultError.ioFailure(errno) }
        destinationIsOpen = false
        try failIfRequested(.afterSyncBeforeCommit)
        guard Darwin.link(temporary.path, target.path) == 0 else {
            if errno == EEXIST {
                let existing = try openRegularFile(at: target)
                defer { Darwin.close(existing) }
                guard try hashDescriptor(
                    existing,
                    expectedByteCount: expectedByteCount
                ) == expectedSHA256 else {
                    throw VaultError.objectAlreadyExists
                }
                return
            }
            throw VaultError.ioFailure(errno)
        }
        try failIfRequested(.afterCommitBeforeDirectorySync)
        try syncDirectory(target.deletingLastPathComponent())
    }

    public func replaceAtomically(_ data: Data, relativePath: String) throws {
        let target = try resolved(relativePath)
        try ensureParentDirectory(of: target)
        let temporary = target.deletingLastPathComponent()
            .appendingPathComponent(".kinlogue-\(UUID().uuidString).tmp")
        try writeTemporary(data, to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try failIfRequested(.afterSyncBeforeCommit)
        guard Darwin.rename(temporary.path, target.path) == 0 else {
            throw VaultError.ioFailure(errno)
        }
        try failIfRequested(.afterCommitBeforeDirectorySync)
        try syncDirectory(target.deletingLastPathComponent())
    }

    public func read(relativePath: String, maximumByteCount: Int) throws -> Data {
        guard maximumByteCount >= 0 else { throw VaultError.resourceLimitExceeded }
        let url = try resolved(relativePath)
        let metadata = try regularFileMetadata(url)
        guard metadata.st_size <= maximumByteCount else {
            throw VaultError.resourceLimitExceeded
        }
        do {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard data.count <= maximumByteCount else {
                throw VaultError.resourceLimitExceeded
            }
            return data
        } catch let error as VaultError {
            throw error
        } catch {
            throw VaultError.ioFailure(EIO)
        }
    }

    func withRegularFileDescriptor<Result>(
        relativePath: String,
        _ body: (Int32) throws -> Result
    ) throws -> Result {
        let descriptor = try openRegularFile(at: resolved(relativePath))
        defer { Darwin.close(descriptor) }
        return try body(descriptor)
    }

    func withRegularFileDescriptor<Result: Sendable>(
        relativePath: String,
        _ body: (Int32) async throws -> Result
    ) async throws -> Result {
        let descriptor = try openRegularFile(at: resolved(relativePath))
        defer { Darwin.close(descriptor) }
        return try await body(descriptor)
    }

    func validateRegularFile(relativePath: String, expectedByteCount: Int) throws {
        guard expectedByteCount >= 0 else { throw VaultError.resourceLimitExceeded }
        let metadata = try regularFileMetadata(try resolved(relativePath))
        guard metadata.st_size == expectedByteCount else {
            throw VaultError.invalidDigest
        }
    }

    public func exists(relativePath: String) -> Bool {
        guard let url = try? resolved(relativePath) else { return false }
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else { return false }
        return (metadata.st_mode & S_IFMT) == S_IFREG
    }

    func rootState() throws -> AtomicFileStoreRootState {
        var metadata = stat()
        guard lstat(rootURL.path, &metadata) == 0 else {
            if errno == ENOENT { return .absent }
            throw VaultError.ioFailure(errno)
        }
        guard (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == geteuid() else {
            throw VaultError.invalidPath
        }
        do {
            let entries = try FileManager.default.contentsOfDirectory(atPath: rootURL.path)
            return entries.isEmpty ? .empty : .nonempty
        } catch {
            throw VaultError.ioFailure(EIO)
        }
    }

    public func listRegularFiles(relativeDirectory: String) throws -> [String] {
        let directory = try resolved(relativeDirectory)
        try validateNoSymlink(to: directory)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { throw VaultError.ioFailure(EIO) }

        let canonicalRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL
        let prefix = canonicalRoot.path + "/"
        var results: [String] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { throw VaultError.invalidPath }
            if values.isRegularFile == true {
                let canonical = url.resolvingSymlinksInPath().standardizedFileURL
                guard canonical.path.hasPrefix(prefix) else { throw VaultError.invalidPath }
                results.append(String(canonical.path.dropFirst(prefix.count)))
            }
        }
        return results
    }

    public func remove(relativePath: String) throws {
        let url = try resolved(relativePath)
        var metadata = stat()
        if lstat(url.path, &metadata) != 0 {
            if errno == ENOENT { return }
            throw VaultError.ioFailure(errno)
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG else {
            throw VaultError.invalidPath
        }
        try failIfRequested(.beforeRemove)
        guard Darwin.unlink(url.path) == 0 else { throw VaultError.ioFailure(errno) }
        try failIfRequested(.afterRemoveBeforeDirectorySync)
        try syncDirectory(url.deletingLastPathComponent())
    }

    func removeEmptyDirectory(relativePath: String) throws {
        let url = try resolved(relativePath)
        var metadata = stat()
        if lstat(url.path, &metadata) != 0 {
            if errno == ENOENT { return }
            throw VaultError.ioFailure(errno)
        }
        guard (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == geteuid() else {
            throw VaultError.invalidPath
        }
        guard Darwin.rmdir(url.path) == 0 else {
            if errno == ENOENT { return }
            throw VaultError.ioFailure(errno)
        }
        try syncDirectory(url.deletingLastPathComponent())
    }

    func removeRecognizedTemporaryFiles(relativeDirectory: String) throws {
        let directory = try resolved(relativeDirectory, allowEmpty: true)
        try validateNoSymlink(to: directory)

        var directoryMetadata = stat()
        guard lstat(directory.path, &directoryMetadata) == 0 else {
            if errno == ENOENT { return }
            throw VaultError.ioFailure(errno)
        }
        guard (directoryMetadata.st_mode & S_IFMT) == S_IFDIR else {
            throw VaultError.invalidPath
        }

        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        } catch {
            throw VaultError.ioFailure(EIO)
        }
        for name in names where PlaintextVaultLayout.isAtomicTemporaryFilename(name) {
            let relativePath = relativeDirectory.isEmpty
                ? name
                : "\(relativeDirectory)/\(name)"
            try remove(relativePath: relativePath)
        }
    }

    private func writeTemporary(_ data: Data, to url: URL) throws {
        try failIfRequested(.beforeWrite)
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw VaultError.ioFailure(errno) }
        var closeNeeded = true
        defer {
            if closeNeeded { Darwin.close(descriptor) }
        }
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: written),
                    rawBuffer.count - written
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    throw VaultError.ioFailure(errno)
                }
                written += count
            }
        }
        try failIfRequested(.afterWriteBeforeSync)
        if fcntl(descriptor, F_FULLFSYNC) != 0, fsync(descriptor) != 0 {
            throw VaultError.ioFailure(errno)
        }
        guard Darwin.close(descriptor) == 0 else { throw VaultError.ioFailure(errno) }
        closeNeeded = false
    }

    private func openRegularFile(at url: URL) throws -> Int32 {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw VaultError.ioFailure(errno) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG else {
            Darwin.close(descriptor)
            throw VaultError.invalidPath
        }
        return descriptor
    }

    private func hashDescriptor(
        _ descriptor: Int32,
        expectedByteCount: Int
    ) throws -> Data {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_size == expectedByteCount else {
            throw VaultError.invalidDigest
        }
        var hasher = SHA256()
        var offset: off_t = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while offset < metadata.st_size {
            let amount = min(buffer.count, Int(metadata.st_size - offset))
            let readCount = buffer.withUnsafeMutableBytes { bytes in
                Darwin.pread(descriptor, bytes.baseAddress, amount, offset)
            }
            if readCount < 0 {
                if errno == EINTR { continue }
                throw VaultError.ioFailure(errno)
            }
            guard readCount > 0 else { throw VaultError.invalidDigest }
            buffer.withUnsafeBytes { bytes in
                hasher.update(bufferPointer: UnsafeRawBufferPointer(
                    start: bytes.baseAddress,
                    count: readCount
                ))
            }
            offset += off_t(readCount)
        }
        return Data(hasher.finalize())
    }

    private func ensureParentDirectory(of url: URL) throws {
        let parent = url.deletingLastPathComponent()
        _ = try resolved(String(parent.path.dropFirst(rootURL.path.count + 1)), allowEmpty: true)

        var missingDirectories: [URL] = []
        var existingAncestor = parent
        while true {
            var metadata = stat()
            if lstat(existingAncestor.path, &metadata) == 0 {
                guard (metadata.st_mode & S_IFMT) == S_IFDIR else {
                    throw VaultError.invalidPath
                }
                if isInsideRoot(existingAncestor), metadata.st_uid != geteuid() {
                    throw VaultError.invalidPath
                }
                break
            }
            guard errno == ENOENT,
                  existingAncestor.path != "/" else {
                if errno == ENOENT { throw VaultError.invalidPath }
                throw VaultError.ioFailure(errno)
            }
            missingDirectories.append(existingAncestor)
            existingAncestor.deleteLastPathComponent()
        }

        if isInsideRoot(existingAncestor) {
            try repairManagedDirectoryChain(through: existingAncestor)
        }

        for directory in missingDirectories.reversed() {
            try validateDirectory(existingAncestor, requireOwnership: isInsideRoot(existingAncestor))
            guard Darwin.mkdir(directory.path, S_IRWXU) == 0 else {
                if errno == EEXIST {
                    try validateDirectory(directory, requireOwnership: true)
                    existingAncestor = directory
                    continue
                }
                throw VaultError.ioFailure(errno)
            }
            try validateDirectory(directory, requireOwnership: true)
            try failIfRequested(.afterDirectoryCreateBeforeSync)
            try syncDirectory(directory)
            try failIfRequested(.afterDirectorySyncBeforeParentSync)
            try syncDirectory(existingAncestor)
            directoryDurability.markDurable(directory.path)
            try failIfRequested(.afterDirectoryParentSync)
            existingAncestor = directory
        }
        try repairManagedDirectoryChain(through: parent)
        try validateNoSymlink(to: parent)
    }

    private func resolved(_ relativePath: String, allowEmpty: Bool = false) throws -> URL {
        if allowEmpty, relativePath.isEmpty { return rootURL }
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/", omittingEmptySubsequences: false)
                .contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }) else {
            throw VaultError.invalidPath
        }
        let url = rootURL.appendingPathComponent(relativePath).standardizedFileURL
        guard url.path.hasPrefix(rootURL.path + "/") else { throw VaultError.invalidPath }
        try validateNoSymlink(to: url.deletingLastPathComponent())
        return url
    }

    private func validateNoSymlink(to destination: URL) throws {
        var cursor = rootURL
        var rootMetadata = stat()
        if lstat(rootURL.path, &rootMetadata) == 0,
           (rootMetadata.st_mode & S_IFMT) == S_IFLNK {
            throw VaultError.invalidPath
        }
        let relative = destination.path.dropFirst(rootURL.path.count)
        for component in relative.split(separator: "/") {
            cursor.appendPathComponent(String(component))
            var metadata = stat()
            if lstat(cursor.path, &metadata) == 0,
               (metadata.st_mode & S_IFMT) == S_IFLNK {
                throw VaultError.invalidPath
            }
        }
    }

    private func regularFileMetadata(_ url: URL) throws -> stat {
        try validateNoSymlink(to: url.deletingLastPathComponent())
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            if errno == ENOENT { throw VaultError.objectMissing }
            throw VaultError.ioFailure(errno)
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG else {
            throw VaultError.invalidPath
        }
        return metadata
    }

    private func validateDirectory(_ directory: URL, requireOwnership: Bool) throws {
        var metadata = stat()
        guard lstat(directory.path, &metadata) == 0 else {
            if errno == ENOENT { throw VaultError.invalidPath }
            throw VaultError.ioFailure(errno)
        }
        guard (metadata.st_mode & S_IFMT) == S_IFDIR,
              !requireOwnership || metadata.st_uid == geteuid() else {
            throw VaultError.invalidPath
        }
    }

    private func isInsideRoot(_ url: URL) -> Bool {
        url.path == rootURL.path || url.path.hasPrefix(rootURL.path + "/")
    }

    private func repairManagedDirectoryChain(through destination: URL) throws {
        guard isInsideRoot(destination) else { throw VaultError.invalidPath }
        let relative = destination.path.dropFirst(rootURL.path.count)
        var directory = rootURL
        var directories = [directory]
        for component in relative.split(separator: "/") {
            directory.appendPathComponent(String(component), isDirectory: true)
            directories.append(directory)
        }

        for managedDirectory in directories {
            try validateDirectory(managedDirectory, requireOwnership: true)
            guard !directoryDurability.isDurable(managedDirectory.path) else { continue }
            try failIfRequested(.beforeDirectoryDurabilityRepair)
            try syncDirectory(managedDirectory)
            try syncDirectory(managedDirectory.deletingLastPathComponent())
            directoryDurability.markDurable(managedDirectory.path)
            try failIfRequested(.afterDirectoryDurabilityRepair)
        }
    }

    private func syncDirectory(_ directory: URL) throws {
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ELOOP || errno == ENOTDIR { throw VaultError.invalidPath }
            throw VaultError.ioFailure(errno)
        }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw VaultError.ioFailure(errno)
        }
        guard (metadata.st_mode & S_IFMT) == S_IFDIR else {
            throw VaultError.invalidPath
        }
        guard fsync(descriptor) == 0 || errno == EINVAL || errno == ENOTSUP else {
            throw VaultError.ioFailure(errno)
        }
    }

    private func failIfRequested(_ point: AtomicFileStoreFaultPoint) throws {
        if failureInjector?(point) == true { throw VaultError.injectedFailure }
    }

}

// SAFETY: `lock` protects the complete set of durability-confirmed paths.
private final class AtomicFileStoreDirectoryDurability: @unchecked Sendable {
    private let lock = NSLock()
    private var durablePaths: Set<String> = []

    func isDurable(_ path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return durablePaths.contains(path)
    }

    func markDurable(_ path: String) {
        lock.lock()
        durablePaths.insert(path)
        lock.unlock()
    }
}
