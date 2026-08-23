import Darwin
import Foundation
import KinloguePlatform

struct AcceptanceOwnershipReceipt: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 3

    let schemaVersion: Int
    let operationID: UUID
    let runRootDevice: UInt64
    let runRootInode: UInt64
}

enum AcceptanceRunOwnershipFileSystemError: Error, Equatable, Sendable {
    case runDirectoryAbsent
}

/// Filesystem-only ownership for synthetic acceptance data.
///
/// This protects cleanup from path mistakes, symlink traversal, and a replaced
/// run directory. It is intentionally not a security boundary against another
/// malicious process running as the same logged-in user.
struct AcceptanceRunOwnership: Sendable {
    static let receiptName = ".kinlogue-acceptance-owner-v3"
    private static let maximumReceiptByteCount = 4 * 1024

    let runRoot: URL
    let receipt: AcceptanceOwnershipReceipt

    static func claim(
        applicationSupportURL: URL,
        runID: String,
        operationID: UUID = UUID()
    ) throws -> Self {
        let locations = try locations(
            applicationSupportURL: applicationSupportURL,
            runID: runID
        )
        try ensureTrustedDirectory(locations.applicationSupport)
        try ensureDirectory(locations.kinlogue)
        try ensureDirectory(locations.acceptance)

        guard Darwin.mkdir(locations.runRoot.path, S_IRWXU) == 0 else {
            throw SyntheticAcceptanceError.unsafeCleanupTarget
        }
        var shouldRollback = true
        defer {
            if shouldRollback {
                _ = Darwin.unlink(locations.receipt.path)
                _ = Darwin.rmdir(locations.runRoot.path)
            }
        }

        let identity = try directoryIdentity(locations.runRoot)
        let receipt = AcceptanceOwnershipReceipt(
            schemaVersion: AcceptanceOwnershipReceipt.currentSchemaVersion,
            operationID: operationID,
            runRootDevice: identity.device,
            runRootInode: identity.inode
        )
        try writeExclusive(
            try canonicalData(receipt),
            to: locations.receipt
        )
        try syncDirectory(locations.runRoot)
        shouldRollback = false
        return Self(runRoot: locations.runRoot, receipt: receipt)
    }

    static func load(
        applicationSupportURL: URL,
        runID: String
    ) throws -> Self {
        let locations = try locations(
            applicationSupportURL: applicationSupportURL,
            runID: runID
        )
        try validateExistingParents(locations)
        guard fileType(at: locations.runRoot) != nil else {
            throw AcceptanceRunOwnershipFileSystemError.runDirectoryAbsent
        }
        let identity = try directoryIdentity(locations.runRoot)
        let data = try readRegularFile(
            locations.receipt,
            maximumByteCount: Self.maximumReceiptByteCount
        )
        let receipt: AcceptanceOwnershipReceipt
        do {
            receipt = try JSONDecoder().decode(AcceptanceOwnershipReceipt.self, from: data)
        } catch {
            throw SyntheticAcceptanceError.unsafeCleanupTarget
        }
        guard receipt.schemaVersion == AcceptanceOwnershipReceipt.currentSchemaVersion,
              try canonicalData(receipt) == data,
              receipt.runRootDevice == identity.device,
              receipt.runRootInode == identity.inode else {
            throw SyntheticAcceptanceError.unsafeCleanupTarget
        }
        return Self(runRoot: locations.runRoot, receipt: receipt)
    }

    func releaseAfterVaultRemoval() throws {
        let identity = try Self.directoryIdentity(runRoot)
        guard identity.device == receipt.runRootDevice,
              identity.inode == receipt.runRootInode else {
            throw SyntheticAcceptanceError.unsafeCleanupTarget
        }
        let receiptURL = runRoot.appendingPathComponent(Self.receiptName)
        let receiptData = try Self.readRegularFile(
            receiptURL,
            maximumByteCount: Self.maximumReceiptByteCount
        )
        guard receiptData == (try Self.canonicalData(receipt)) else {
            throw SyntheticAcceptanceError.unsafeCleanupTarget
        }
        let lockNames = Self.expectedVaultLockNames(runRoot: runRoot)
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: runRoot.path))
        let permittedNames = lockNames.union([Self.receiptName])
        guard names.contains(Self.receiptName),
              names.isSubset(of: permittedNames) else {
            throw SyntheticAcceptanceError.unsafeCleanupTarget
        }
        try Self.removeIdleVaultLocks(
            names.intersection(lockNames).sorted().map {
                runRoot.appendingPathComponent($0)
            }
        )

        guard Darwin.unlink(receiptURL.path) == 0 else {
            throw SyntheticAcceptanceError.unsafeCleanupTarget
        }
        try Self.syncDirectory(runRoot)
        guard Darwin.rmdir(runRoot.path) == 0 else {
            throw SyntheticAcceptanceError.unsafeCleanupTarget
        }
        try Self.syncDirectory(runRoot.deletingLastPathComponent())
    }

    private struct Locations {
        let applicationSupport: URL
        let kinlogue: URL
        let acceptance: URL
        let runRoot: URL
        let receipt: URL
    }

    private struct DirectoryIdentity {
        let device: UInt64
        let inode: UInt64
    }

    private static func locations(
        applicationSupportURL: URL,
        runID: String
    ) throws -> Locations {
        guard AppRuntimeIdentity.validRunID(runID) else {
            throw SyntheticAcceptanceError.unsafeCleanupTarget
        }
        let applicationSupport = applicationSupportURL.standardizedFileURL
        guard applicationSupport.isFileURL,
              applicationSupport.path != "/",
              !applicationSupport.lastPathComponent.isEmpty else {
            throw SyntheticAcceptanceError.unsafeCleanupTarget
        }
        let kinlogue = applicationSupport.appendingPathComponent("Kinlogue", isDirectory: true)
        let acceptance = kinlogue.appendingPathComponent("Acceptance", isDirectory: true)
        let runRoot = acceptance.appendingPathComponent(runID, isDirectory: true)
        return Locations(
            applicationSupport: applicationSupport,
            kinlogue: kinlogue,
            acceptance: acceptance,
            runRoot: runRoot,
            receipt: runRoot.appendingPathComponent(Self.receiptName)
        )
    }

    private static func validateExistingParents(_ locations: Locations) throws {
        try ensureTrustedDirectory(locations.applicationSupport)
        try requireDirectory(locations.kinlogue)
        try requireDirectory(locations.acceptance)
        try requireDirectory(locations.runRoot)
    }

    private static func ensureTrustedDirectory(_ url: URL) throws {
        try requireDirectory(url)
    }

    private static func ensureDirectory(_ url: URL) throws {
        if fileType(at: url) == nil {
            guard Darwin.mkdir(url.path, S_IRWXU) == 0 else {
                throw SyntheticAcceptanceError.unsafeCleanupTarget
            }
            try syncDirectory(url.deletingLastPathComponent())
        }
        try requireDirectory(url)
    }

    private static func requireDirectory(_ url: URL) throws {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR else {
            throw SyntheticAcceptanceError.unsafeCleanupTarget
        }
    }

    private static func fileType(at url: URL) -> mode_t? {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else { return nil }
        return metadata.st_mode & S_IFMT
    }

    private static func directoryIdentity(_ url: URL) throws -> DirectoryIdentity {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR,
              let device = UInt64(exactly: metadata.st_dev),
              let inode = UInt64(exactly: metadata.st_ino),
              device > 0,
              inode > 0 else {
            throw SyntheticAcceptanceError.unsafeCleanupTarget
        }
        return DirectoryIdentity(device: device, inode: inode)
    }

    private static func canonicalData(_ receipt: AcceptanceOwnershipReceipt) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(receipt)
    }

    private static func writeExclusive(_ data: Data, to url: URL) throws {
        let descriptor = Darwin.open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw SyntheticAcceptanceError.unsafeCleanupTarget
        }
        var closeNeeded = true
        defer { if closeNeeded { Darwin.close(descriptor) } }
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    buffer.count - offset
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    throw SyntheticAcceptanceError.unsafeCleanupTarget
                }
                offset += count
            }
        }
        guard fsync(descriptor) == 0,
              Darwin.close(descriptor) == 0 else {
            throw SyntheticAcceptanceError.unsafeCleanupTarget
        }
        closeNeeded = false
    }

    private static func readRegularFile(
        _ url: URL,
        maximumByteCount: Int
    ) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw SyntheticAcceptanceError.unsafeCleanupTarget
        }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_size >= 0,
              metadata.st_size <= maximumByteCount else {
            throw SyntheticAcceptanceError.unsafeCleanupTarget
        }
        var data = Data(count: Int(metadata.st_size))
        try data.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.read(
                    descriptor,
                    base.advanced(by: offset),
                    buffer.count - offset
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    throw SyntheticAcceptanceError.unsafeCleanupTarget
                }
                guard count > 0 else {
                    throw SyntheticAcceptanceError.unsafeCleanupTarget
                }
                offset += count
            }
        }
        var extra: UInt8 = 0
        guard Darwin.read(descriptor, &extra, 1) == 0 else {
            throw SyntheticAcceptanceError.unsafeCleanupTarget
        }
        return data
    }

    private static func syncDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw SyntheticAcceptanceError.unsafeCleanupTarget
        }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 || errno == EINVAL || errno == ENOTSUP else {
            throw SyntheticAcceptanceError.unsafeCleanupTarget
        }
    }

    private static func expectedVaultLockNames(runRoot: URL) -> Set<String> {
        let sourceVault = runRoot.resolvingSymlinksInPath()
            .appendingPathComponent("SourceVault", isDirectory: true)
            .standardizedFileURL
        return VaultMutationLockNaming.filenames(forRootURL: sourceVault)
    }

    private static func removeIdleVaultLocks(_ urls: [URL]) throws {
        var descriptors: [(url: URL, descriptor: Int32)] = []
        defer {
            for entry in descriptors.reversed() {
                Darwin.close(entry.descriptor)
            }
        }
        for url in urls {
            let descriptor = Darwin.open(url.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else {
                throw SyntheticAcceptanceError.unsafeCleanupTarget
            }
            descriptors.append((url, descriptor))
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0,
                  (metadata.st_mode & S_IFMT) == S_IFREG,
                  metadata.st_uid == geteuid(),
                  metadata.st_nlink == 1 else {
                throw SyntheticAcceptanceError.unsafeCleanupTarget
            }
            var request = Darwin.flock()
            request.l_type = Int16(F_WRLCK)
            request.l_whence = Int16(SEEK_SET)
            request.l_start = 0
            request.l_len = 0
            guard fcntl(descriptor, F_SETLK, &request) == 0 else {
                throw SyntheticAcceptanceError.unsafeCleanupTarget
            }
        }
        for entry in descriptors {
            guard Darwin.unlink(entry.url.path) == 0 else {
                throw SyntheticAcceptanceError.unsafeCleanupTarget
            }
        }
    }
}
