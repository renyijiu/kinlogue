import Darwin
import Foundation
import KinlogueCore

/// The filesystem generation to which root-scoped state is bound.
///
/// Catalog commits intentionally do not change this value. Whole-vault
/// replacement does, through either the directory identity or `vaultID`.
struct VaultRootGeneration: Equatable, Sendable {
    let parentDevice: UInt64
    let parentInode: UInt64
    let rootDevice: UInt64
    let rootInode: UInt64
    let vaultID: UUID
}

/// Descriptor-based validation for stores that live beneath a plaintext vault
/// but have an independent manifest.
///
/// This type never acquires `VaultMutationCoordinator` itself. A pure probe is
/// available for diagnostics; reconciliation and any publication authorized by
/// a generation require the caller to retain that root's mutation lease.
struct VaultRootBinding: Sendable {
    private enum DirectoryRole {
        case parent
        case root
    }

    private struct DirectoryIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
    }

    private struct RegularFileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        let byteCount: Int
    }

    private let layout: PlaintextVaultLayout
    private let mutationCoordinator: VaultMutationCoordinator

    /// Construction resolves an existing non-symlink root to its physical path
    /// and never creates a missing root.
    init(rootURL: URL) throws {
        let canonicalRootURL = try VaultCanonicalRootPath.rootURL(
            for: rootURL,
            allowMissing: true
        )
        layout = try PlaintextVaultLayout(rootURL: canonicalRootURL)
        mutationCoordinator = VaultMutationCoordinator.shared(
            for: canonicalRootURL
        )
    }

    /// Re-probes the current parent, root and catalog without side effects.
    func probe() throws -> VaultRootGeneration {
        try probeCurrentGeneration()
    }

    /// Reconciles existing receipts only while the exact canonical root's
    /// process-shared mutation lease remains active. It never initializes a
    /// missing directory.
    func probe(
        reconcilingTransactionsWith lease: VaultMutationLease
    ) throws -> VaultRootGeneration {
        try mutationCoordinator.withValidatedLease(lease) {
            try validatePathShapeBeforeReconciliation()
            _ = try PlaintextVaultDeletionTransaction(rootURL: layout.rootURL).reconcile()
            _ = try PlaintextVaultInitializationTransaction(rootURL: layout.rootURL).reconcile()
            return try probeCurrentGeneration()
        }
    }

    /// Re-probes instead of trusting a cached path or descriptor identity.
    /// Any missing, replaced or damaged generation is a non-match.
    func matches(_ expected: VaultRootGeneration) -> Bool {
        guard let current = try? probe() else {
            return false
        }
        return current == expected
    }

    static func probe(rootURL: URL) throws -> VaultRootGeneration {
        try Self(rootURL: rootURL).probe()
    }

    static func matches(
        _ expected: VaultRootGeneration,
        rootURL: URL
    ) -> Bool {
        guard let binding = try? Self(rootURL: rootURL) else { return false }
        return binding.matches(expected)
    }

    private func probeCurrentGeneration() throws -> VaultRootGeneration {
        let parentDescriptor = try openParentDirectory()
        defer { Darwin.close(parentDescriptor) }
        let parentIdentity = try directoryIdentity(
            descriptor: parentDescriptor,
            role: .parent
        )

        let rootDescriptor = try openRootDirectory(relativeTo: parentDescriptor)
        defer { Darwin.close(rootDescriptor) }
        let rootIdentity = try directoryIdentity(
            descriptor: rootDescriptor,
            role: .root
        )

        let manifestData = try readManifest(relativeTo: rootDescriptor)
        let manifest: PlaintextVaultManifest
        do {
            manifest = try CanonicalVaultJSON.decode(
                PlaintextVaultManifest.self,
                from: manifestData
            )
        } catch {
            throw VaultError.invalidCatalog
        }
        let catalog = try PlaintextVault.validatedCatalog(in: manifest)

        // A descriptor remains valid after a rename. Reopen the named path at
        // the end so a root or parent replacement cannot authorize a publish
        // into a stale, unlinked generation.
        try validateCurrentPath(
            parentIdentity: parentIdentity,
            rootIdentity: rootIdentity
        )

        return VaultRootGeneration(
            parentDevice: parentIdentity.device,
            parentInode: parentIdentity.inode,
            rootDevice: rootIdentity.device,
            rootInode: rootIdentity.inode,
            vaultID: catalog.vaultID
        )
    }

    private func validatePathShapeBeforeReconciliation() throws {
        let parentDescriptor = try openParentDirectory()
        defer { Darwin.close(parentDescriptor) }
        _ = try directoryIdentity(descriptor: parentDescriptor, role: .parent)

        let descriptor = openat(
            parentDescriptor,
            layout.rootURL.lastPathComponent,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            if errno == ENOENT { return }
            throw pathOpenError(errno)
        }
        defer { Darwin.close(descriptor) }
        _ = try directoryIdentity(descriptor: descriptor, role: .root)
    }

    private func validateCurrentPath(
        parentIdentity expectedParent: DirectoryIdentity,
        rootIdentity expectedRoot: DirectoryIdentity
    ) throws {
        let currentParentDescriptor = try openParentDirectory()
        defer { Darwin.close(currentParentDescriptor) }
        guard try directoryIdentity(
            descriptor: currentParentDescriptor,
            role: .parent
        ) == expectedParent else {
            throw VaultError.invalidPath
        }

        let currentRootDescriptor = try openRootDirectory(
            relativeTo: currentParentDescriptor
        )
        defer { Darwin.close(currentRootDescriptor) }
        guard try directoryIdentity(
            descriptor: currentRootDescriptor,
            role: .root
        ) == expectedRoot else {
            throw VaultError.invalidPath
        }
    }

    private func openParentDirectory() throws -> Int32 {
        let descriptor = Darwin.open(
            layout.rootURL.deletingLastPathComponent().path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            if errno == ENOENT { throw VaultError.vaultMissing }
            throw pathOpenError(errno)
        }
        do {
            _ = try directoryIdentity(descriptor: descriptor, role: .parent)
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private func openRootDirectory(relativeTo parentDescriptor: Int32) throws -> Int32 {
        let descriptor = openat(
            parentDescriptor,
            layout.rootURL.lastPathComponent,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            if errno == ENOENT { throw VaultError.vaultMissing }
            throw pathOpenError(errno)
        }
        do {
            _ = try directoryIdentity(descriptor: descriptor, role: .root)
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private func readManifest(relativeTo rootDescriptor: Int32) throws -> Data {
        let descriptor = openat(
            rootDescriptor,
            layout.manifestPath,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            if errno == ENOENT { throw VaultError.vaultMissing }
            throw pathOpenError(errno)
        }
        defer { Darwin.close(descriptor) }

        let initialIdentity = try regularFileIdentity(descriptor: descriptor)
        guard initialIdentity.byteCount
                <= PlaintextVaultResourcePolicy.maximumManifestByteCount else {
            throw VaultError.resourceLimitExceeded
        }

        var data = Data()
        data.reserveCapacity(initialIdentity.byteCount)
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw VaultError.ioFailure(errno)
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= PlaintextVaultResourcePolicy.maximumManifestByteCount else {
                throw VaultError.resourceLimitExceeded
            }
        }

        guard data.count == initialIdentity.byteCount,
              try regularFileIdentity(descriptor: descriptor) == initialIdentity else {
            throw VaultError.invalidDigest
        }
        return data
    }

    private func directoryIdentity(
        descriptor: Int32,
        role: DirectoryRole
    ) throws -> DirectoryIdentity {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw VaultError.ioFailure(errno)
        }
        guard (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == geteuid(),
              validDirectoryMode(metadata.st_mode, role: role),
              let device = UInt64(exactly: metadata.st_dev),
              let inode = UInt64(exactly: metadata.st_ino),
              device > 0,
              inode > 0 else {
            throw VaultError.invalidPath
        }
        return DirectoryIdentity(device: device, inode: inode)
    }

    private func validDirectoryMode(
        _ mode: mode_t,
        role: DirectoryRole
    ) -> Bool {
        switch role {
        case .parent:
            mode & mode_t(0o022) == 0
        case .root:
            mode & mode_t(0o7777) == mode_t(0o700)
        }
    }

    private func regularFileIdentity(descriptor: Int32) throws -> RegularFileIdentity {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw VaultError.ioFailure(errno)
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_nlink == 1,
              metadata.st_mode & mode_t(0o7777) == mode_t(0o600),
              metadata.st_size >= 0,
              let device = UInt64(exactly: metadata.st_dev),
              let inode = UInt64(exactly: metadata.st_ino),
              let byteCount = Int(exactly: metadata.st_size),
              device > 0,
              inode > 0 else {
            throw VaultError.invalidPath
        }
        return RegularFileIdentity(
            device: device,
            inode: inode,
            byteCount: byteCount
        )
    }

    private func pathOpenError(_ code: Int32) -> VaultError {
        switch code {
        case ELOOP, ENOTDIR:
            .invalidPath
        default:
            .ioFailure(code)
        }
    }
}
