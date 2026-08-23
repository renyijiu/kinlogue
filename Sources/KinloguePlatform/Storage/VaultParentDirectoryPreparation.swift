import Darwin
import Foundation
import KinlogueCore

/// Creates only the app-owned parent of an active vault root. Every existing
/// component is required to resolve without symlinks; the active root itself
/// is deliberately left absent for first-run state detection.
public enum VaultParentDirectoryPreparation {
    @discardableResult
    public static func ensureParentDirectory(for activeVaultURL: URL) throws -> URL {
        let active = activeVaultURL.standardizedFileURL
        let parent = active.deletingLastPathComponent().standardizedFileURL
        let ancestor = parent.deletingLastPathComponent().standardizedFileURL
        let parentName = parent.lastPathComponent
        guard active.isFileURL,
              active.path != "/",
              parent.path != "/",
              isSingleComponent(parentName),
              ancestor.resolvingSymlinksInPath().standardizedFileURL.path
                == ancestor.path else {
            throw VaultError.invalidPath
        }

        let ancestorDescriptor = Darwin.open(
            ancestor.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard ancestorDescriptor >= 0 else {
            throw VaultError.invalidPath
        }
        defer { Darwin.close(ancestorDescriptor) }

        var created = false
        if mkdirat(ancestorDescriptor, parentName, 0o700) == 0 {
            created = true
        } else if errno != EEXIST {
            throw VaultError.ioFailure(errno)
        }
        let parentDescriptor = openat(
            ancestorDescriptor,
            parentName,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard parentDescriptor >= 0 else {
            throw VaultError.invalidPath
        }
        defer { Darwin.close(parentDescriptor) }

        var metadata = stat()
        guard fstat(parentDescriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == geteuid(),
              parent.resolvingSymlinksInPath().standardizedFileURL.path
                == parent.path else {
            throw VaultError.invalidPath
        }
        guard fchmod(parentDescriptor, 0o700) == 0 else {
            throw VaultError.ioFailure(errno)
        }
        if fsync(parentDescriptor) != 0, errno != EINVAL, errno != ENOTSUP {
            throw VaultError.ioFailure(errno)
        }
        if created, fsync(ancestorDescriptor) != 0,
           errno != EINVAL, errno != ENOTSUP {
            throw VaultError.ioFailure(errno)
        }
        return parent
    }

    private static func isSingleComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/")
    }
}
