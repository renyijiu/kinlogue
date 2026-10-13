import Darwin
import Foundation
import KinlogueCore

public enum VaultMutationLockNaming {
    public static func filename(forCanonicalRootPath path: String) -> String {
        let digest = ContentDigest.sha256(Data(path.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return ".kinlogue-mutation-\(digest).lock"
    }
}

struct VaultProcessLockLocation: Hashable, Sendable {
    let parentURL: URL
    let namingKey: String
}

/// The lock files that sit beside a library root, one per name the root may be reached by.
/// The files are intentionally never unlinked while in use: removing one that another process
/// has open could create two lock inodes. Names are deduplicated and kept in one global path
/// order so that overlapping lock sets cannot deadlock.
struct VaultProcessLock: Sendable {
    let lockURLs: [URL]

    init(locations: [VaultProcessLockLocation]) {
        precondition(!locations.isEmpty)
        lockURLs = Array(Set(locations.map { location in
            location.parentURL.standardizedFileURL.appendingPathComponent(
                VaultMutationLockNaming.filename(
                    forCanonicalRootPath: location.namingKey
                ),
                isDirectory: false
            )
        })).sorted { lhs, rhs in
            lhs.path.utf8.lexicographicallyPrecedes(rhs.path.utf8)
        }
    }

    /// Opens (creating if needed) one lock file without following links, and refuses anything
    /// that is not a private regular file owned by this user.
    func openValidatedDescriptor(at lockURL: URL) throws -> Int32 {
        let parentURL = lockURL.deletingLastPathComponent()
        let parentDescriptor = Darwin.open(
            parentURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard parentDescriptor >= 0 else { throw VaultError.ioFailure(errno) }
        defer { Darwin.close(parentDescriptor) }

        var parentMetadata = stat()
        guard fstat(parentDescriptor, &parentMetadata) == 0,
              (parentMetadata.st_mode & S_IFMT) == S_IFDIR,
              parentMetadata.st_uid == geteuid() else {
            throw VaultError.invalidPath
        }

        let descriptor = openat(
            parentDescriptor,
            lockURL.lastPathComponent,
            O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            if errno == ELOOP || errno == ENOTDIR { throw VaultError.invalidPath }
            throw VaultError.ioFailure(errno)
        }
        do {
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0,
                  (metadata.st_mode & S_IFMT) == S_IFREG,
                  metadata.st_uid == geteuid(),
                  metadata.st_nlink == 1 else {
                throw VaultError.invalidPath
            }
            guard fchmod(descriptor, mode_t(0o600)) == 0 else {
                throw VaultError.ioFailure(errno)
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }
}
