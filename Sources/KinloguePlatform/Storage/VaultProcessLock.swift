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

    /// Includes the filesystem-stable name and every legacy path-keyed name
    /// this process may leave beside the vault. Cleanup code must accept only
    /// this exact set, while tolerating that an older release created just one
    /// compatibility member.
    public static func filenames(forRootURL rootURL: URL) -> Set<String> {
        Set(
            VaultCanonicalRootPath.coordinatorIdentity(for: rootURL)
                .lockLocations.map {
                    filename(forCanonicalRootPath: $0.namingKey)
                }
        )
    }
}

struct VaultProcessLockLocation: Hashable, Sendable {
    let parentURL: URL
    let namingKey: String
}

/// A kernel-managed advisory write lock shared by every process opening the
/// same canonical vault root. The sibling lock file is intentionally stable:
/// unlinking it while another process has it open could create two lock inodes.
/// Stable and legacy compatibility locks are deduplicated and acquired in one
/// global path order so overlapping upgraded-process lock sets cannot deadlock.
// SAFETY: Lock URLs are immutable and `stateLock` protects process-local waiter
// accounting; kernel descriptors move into lock-protected leases.
final class VaultProcessLock: @unchecked Sendable {
    let lockURLs: [URL]

    var lockURL: URL { lockURLs[0] }

    private let stateLock = NSLock()
    private var waiterCount = 0

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

    var waiterCountForTesting: Int {
        stateLock.withLock { waiterCount }
    }

    func acquire() async throws -> VaultProcessLease {
        stateLock.withLock { waiterCount += 1 }
        defer { stateLock.withLock { waiterCount -= 1 } }

        var descriptors: [Int32] = []
        do {
            for lockURL in lockURLs {
                let descriptor = try openValidatedDescriptor(at: lockURL)
                do {
                    try await acquireWriteLock(on: descriptor)
                    descriptors.append(descriptor)
                } catch {
                    Darwin.close(descriptor)
                    throw error
                }
            }
            try Task.checkCancellation()
            return VaultProcessLease(descriptors: descriptors)
        } catch {
            for descriptor in descriptors.reversed() {
                Darwin.close(descriptor)
            }
            throw error
        }
    }

    private func acquireWriteLock(on descriptor: Int32) async throws {
        while true {
            try Task.checkCancellation()
            var request = Darwin.flock()
            request.l_type = Int16(F_WRLCK)
            request.l_whence = Int16(SEEK_SET)
            request.l_start = 0
            request.l_len = 0
            if fcntl(descriptor, F_SETLK, &request) == 0 {
                try Task.checkCancellation()
                return
            }
            switch errno {
            case EINTR:
                continue
            case EACCES, EAGAIN:
                try await Task.sleep(for: .milliseconds(10))
            default:
                throw VaultError.ioFailure(errno)
            }
        }
    }

    private func openValidatedDescriptor(at lockURL: URL) throws -> Int32 {
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

// SAFETY: `lock` protects descriptor ownership and makes release idempotent.
final class VaultProcessLease: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptors: [Int32]

    init(descriptors: [Int32]) {
        self.descriptors = descriptors
    }

    func release() {
        let descriptors = lock.withLock { () -> [Int32] in
            defer { self.descriptors.removeAll(keepingCapacity: false) }
            return self.descriptors
        }
        for descriptor in descriptors.reversed() {
            var request = Darwin.flock()
            request.l_type = Int16(F_UNLCK)
            request.l_whence = Int16(SEEK_SET)
            request.l_start = 0
            request.l_len = 0
            _ = fcntl(descriptor, F_SETLK, &request)
            Darwin.close(descriptor)
        }
    }

    deinit {
        release()
    }
}
