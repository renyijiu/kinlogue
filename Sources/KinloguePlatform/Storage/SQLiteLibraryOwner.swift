import Darwin
import Foundation

/// An owner survives whole-root replacement; its parent and lock inodes must not.
// SAFETY: databaseLock protects the only mutable field; lifetime filesystem authority is immutable.
package final class SQLiteLibraryOwner: @unchecked Sendable {
    package let rootURL: URL
    private let databaseLock = NSLock()
    private var databaseClaim: UUID?
    private let parentIdentity: SQLiteFileIdentity
    private let locks: [(url: URL, descriptor: Int32)]

    package init(rootURL: URL) throws {
        self.rootURL = try VaultCanonicalRootPath.rootURL(for: rootURL, allowMissing: true)
        parentIdentity = try SQLiteFileIdentity.directory(at: self.rootURL.deletingLastPathComponent(), privateMode: false)
        // Ownership lasts as long as these descriptors: the kernel drops the flock when the process dies.
        let lock = Self.processLock(rootURL: self.rootURL)
        var acquired: [(url: URL, descriptor: Int32)] = []
        do {
            for url in lock.lockURLs {
                let descriptor = try lock.openValidatedDescriptor(at: url)
                guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                    let code = errno
                    Darwin.close(descriptor)
                    if code == EWOULDBLOCK || code == EAGAIN { throw SQLiteLibraryError.occupied }
                    throw SQLiteLibraryError.ioFailure(code)
                }
                acquired.append((url, descriptor))
            }
        } catch {
            for item in acquired.reversed() { Darwin.close(item.descriptor) }
            throw error
        }
        // After ownership transfers to self, a throwing init is cleaned up by deinit.
        locks = acquired
        try validate()
    }

    package static func lockFilenames(rootURL: URL) -> Set<String> {
        Set(processLock(rootURL: rootURL).lockURLs.map(\.lastPathComponent))
    }

    private static func processLock(rootURL: URL) -> VaultProcessLock {
        let identity = VaultCanonicalRootPath.coordinatorIdentity(for: rootURL)
        return VaultProcessLock(locations: identity.lockLocations.map {
            VaultProcessLockLocation(parentURL: $0.parentURL, namingKey: "sqlite-owner:" + $0.namingKey)
        })
    }

    package func reconcilePendingDeletion() throws {
        try validate()
        try requireClosedDatabase()
        _ = try PlaintextVaultDeletionTransaction(rootURL: rootURL, strictReceipt: true).reconcile()
    }

    func claimDatabase() throws -> UUID {
        try databaseLock.withLock {
            guard databaseClaim == nil else { throw SQLiteLibraryError.occupied }
            let claim = UUID(); databaseClaim = claim; return claim
        }
    }
    func releaseDatabase(_ claim: UUID) { databaseLock.withLock { if databaseClaim == claim { databaseClaim = nil } } }
    func requireClosedDatabase() throws {
        try databaseLock.withLock { guard databaseClaim == nil else { throw SQLiteLibraryError.occupied } }
    }

    package func validate() throws {
        guard try SQLiteFileIdentity.directory(at: rootURL.deletingLastPathComponent(), privateMode: false) == parentIdentity else {
            throw SQLiteLibraryError.staleRoot
        }
        for item in locks {
            guard try SQLiteFileIdentity.regular(descriptor: item.descriptor)
                == SQLiteFileIdentity.regular(at: item.url) else { throw SQLiteLibraryError.staleRoot }
        }
    }

    deinit {
        for item in locks.reversed() { Darwin.close(item.descriptor) }
    }
}

struct SQLiteFileIdentity: Equatable, Sendable {
    let device: Int64
    let inode: Int64

    static func directory(at url: URL, privateMode: Bool = true) throws -> Self {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw SQLiteLibraryError.invalidPath }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == geteuid(),
              privateMode ? (metadata.st_mode & 0o7777 == 0o700) : (metadata.st_mode & 0o022 == 0) else {
            throw SQLiteLibraryError.invalidPath
        }
        return try identity(metadata)
    }

    static func regular(at url: URL) throws -> Self {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw SQLiteLibraryError.invalidPath }
        defer { Darwin.close(descriptor) }
        return try regular(descriptor: descriptor)
    }

    static func regular(descriptor: Int32) throws -> Self {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(), metadata.st_nlink == 1,
              metadata.st_mode & 0o7777 == 0o600 else { throw SQLiteLibraryError.invalidPath }
        return try identity(metadata)
    }

    private static func identity(_ metadata: stat) throws -> Self {
        guard let device = Int64(exactly: metadata.st_dev), device > 0,
              let inode = Int64(exactly: metadata.st_ino), inode > 0 else { throw SQLiteLibraryError.invalidPath }
        return Self(device: device, inode: inode)
    }
}
