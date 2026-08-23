import Darwin
import Foundation
import KinlogueCore

/// A filesystem-only destruction transaction. The sibling receipt survives a
/// partial recursive removal, so a later process can finish deleting the exact
/// inode that was validated before the active vault was quarantined.
struct PlaintextVaultDeletionTransaction: Sendable {
    private struct Receipt: Codable, Equatable {
        let magic: String
        let formatVersion: Int
        let rootPathSHA256: Data
        let device: UInt64
        let inode: UInt64
    }

    private struct DirectoryIdentity: Equatable {
        let device: UInt64
        let inode: UInt64

        func matches(_ metadata: stat) -> Bool {
            device == UInt64(metadata.st_dev)
                && inode == UInt64(metadata.st_ino)
                && (metadata.st_mode & S_IFMT) == S_IFDIR
                && metadata.st_uid == geteuid()
        }
    }

    private static let receiptMagic = "KLGDELETE1"
    private static let formatVersion = 1
    private static let maximumReceiptByteCount = 4 * 1024

    let rootURL: URL
    let receiptURL: URL
    let quarantineURL: URL

    private let failureInjector: (@Sendable (PlaintextVaultTransactionFault) -> Bool)?
    private let canonicalRootPath: String

    init(
        rootURL: URL,
        failureInjector: (@Sendable (PlaintextVaultTransactionFault) -> Bool)? = nil
    ) throws {
        let root = try PlaintextVaultLayout(rootURL: rootURL).rootURL
        let canonicalPath = root.resolvingSymlinksInPath().standardizedFileURL
            .path.precomposedStringWithCanonicalMapping
        let suffix = ContentDigest.sha256(Data(canonicalPath.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let parent = root.deletingLastPathComponent()

        self.rootURL = root
        receiptURL = parent.appendingPathComponent(
            ".kinlogue-vault-deletion-\(suffix).json",
            isDirectory: false
        )
        quarantineURL = parent.appendingPathComponent(
            ".kinlogue-vault-deletion-\(suffix).quarantine",
            isDirectory: true
        )
        self.failureInjector = failureInjector
        canonicalRootPath = canonicalPath
    }

    func begin() throws {
        guard try !receiptExists(),
              try directoryIdentityIfPresent(quarantineURL) == nil,
              let activeIdentity = try directoryIdentityIfPresent(rootURL) else {
            throw VaultError.partialInitialization
        }
        let receipt = Receipt(
            magic: Self.receiptMagic,
            formatVersion: Self.formatVersion,
            rootPathSHA256: ContentDigest.sha256(Data(canonicalRootPath.utf8)),
            device: activeIdentity.device,
            inode: activeIdentity.inode
        )
        try writeReceipt(try CanonicalVaultJSON.encode(receipt))
        try failIfRequested(.afterDeletionReceipt)
        _ = try reconcile()
    }

    /// Returns true when a durable deletion receipt was consumed.
    @discardableResult
    func reconcile() throws -> Bool {
        let activeIdentity = try directoryIdentityIfPresent(rootURL)
        var quarantineIdentity = try directoryIdentityIfPresent(quarantineURL)

        guard try receiptExists() else {
            guard quarantineIdentity == nil else {
                throw VaultError.partialInitialization
            }
            return false
        }

        let receipt: Receipt
        do {
            let data = try readReceipt()
            receipt = try CanonicalVaultJSON.decode(Receipt.self, from: data)
            guard try CanonicalVaultJSON.encode(receipt) == data else {
                throw VaultError.invalidCatalog
            }
        } catch {
            // An interrupted receipt write cannot have renamed the active root.
            // When no quarantine exists, discard only this deterministic,
            // app-owned receipt and leave the active vault untouched.
            guard quarantineIdentity == nil else { throw VaultError.invalidCatalog }
            try removeReceipt()
            return activeIdentity == nil
        }

        guard receipt.magic == Self.receiptMagic,
              receipt.formatVersion == Self.formatVersion,
              receipt.rootPathSHA256.count == 32,
              receipt.rootPathSHA256
                == ContentDigest.sha256(Data(canonicalRootPath.utf8)) else {
            throw VaultError.invalidCatalog
        }
        let expectedIdentity = DirectoryIdentity(
            device: receipt.device,
            inode: receipt.inode
        )
        guard activeIdentity == nil || quarantineIdentity == nil else {
            throw VaultError.partialInitialization
        }

        var didRenameActiveRoot = false
        if let activeIdentity {
            guard activeIdentity == expectedIdentity,
                  quarantineIdentity == nil else {
                throw VaultError.invalidPath
            }
            guard Darwin.rename(rootURL.path, quarantineURL.path) == 0 else {
                throw VaultError.ioFailure(errno)
            }
            try syncParentDirectory()
            quarantineIdentity = try directoryIdentityIfPresent(quarantineURL)
            guard quarantineIdentity == expectedIdentity else {
                throw VaultError.invalidPath
            }
            didRenameActiveRoot = true
        } else if let quarantineIdentity {
            guard quarantineIdentity == expectedIdentity else {
                throw VaultError.invalidPath
            }
        } else {
            try removeReceipt()
            return true
        }

        try removeValidatedQuarantine(expectedIdentity: expectedIdentity) {
            if didRenameActiveRoot {
                try failIfRequested(.afterDeletionRename)
            }
        }
        guard try directoryIdentityIfPresent(quarantineURL) == nil else {
            throw VaultError.ioFailure(EIO)
        }
        try syncParentDirectory()
        try failIfRequested(.afterDeletionQuarantineRemoval)
        try removeReceipt()
        return true
    }

    private func removeValidatedQuarantine(
        expectedIdentity: DirectoryIdentity,
        afterOpen: () throws -> Void
    ) throws {
        let parentDescriptor = try openParentDirectory()
        defer { Darwin.close(parentDescriptor) }
        let quarantineName = quarantineURL.lastPathComponent
        let quarantineDescriptor = quarantineName.withCString {
            openat(
                parentDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard quarantineDescriptor >= 0 else { throw VaultError.invalidPath }
        defer { Darwin.close(quarantineDescriptor) }
        var openedMetadata = stat()
        guard fstat(quarantineDescriptor, &openedMetadata) == 0,
              expectedIdentity.matches(openedMetadata) else {
            throw VaultError.invalidPath
        }

        try afterOpen()
        try removeDirectoryContents(quarantineDescriptor, depth: 0)
        try syncDescriptor(quarantineDescriptor)

        var finalMetadata = stat()
        guard quarantineName.withCString({
            fstatat(parentDescriptor, $0, &finalMetadata, AT_SYMLINK_NOFOLLOW)
        }) == 0,
              expectedIdentity.matches(finalMetadata),
              quarantineName.withCString({
                  unlinkat(parentDescriptor, $0, AT_REMOVEDIR)
              }) == 0 else {
            throw VaultError.invalidPath
        }
        try syncDescriptor(parentDescriptor)
    }

    private func removeDirectoryContents(_ descriptor: Int32, depth: Int) throws {
        guard depth <= 64 else { throw VaultError.resourceLimitExceeded }
        for name in try entryNames(directoryDescriptor: descriptor) {
            var metadata = stat()
            guard name.withCString({
                fstatat(descriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
            }) == 0 else {
                throw VaultError.ioFailure(errno)
            }
            if (metadata.st_mode & S_IFMT) == S_IFDIR {
                let child = name.withCString {
                    openat(
                        descriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                guard child >= 0 else { throw VaultError.invalidPath }
                defer { Darwin.close(child) }
                var opened = stat()
                guard fstat(child, &opened) == 0,
                      sameIdentity(metadata, opened) else {
                    throw VaultError.invalidPath
                }
                try removeDirectoryContents(child, depth: depth + 1)
                try syncDescriptor(child)
                var finalMetadata = stat()
                guard name.withCString({
                    fstatat(descriptor, $0, &finalMetadata, AT_SYMLINK_NOFOLLOW)
                }) == 0,
                      sameIdentity(opened, finalMetadata),
                      name.withCString({ unlinkat(descriptor, $0, AT_REMOVEDIR) }) == 0 else {
                    throw VaultError.invalidPath
                }
            } else {
                try removeNonDirectoryEntry(
                    name,
                    expectedMetadata: metadata,
                    parentDescriptor: descriptor
                )
            }
        }
        try syncDescriptor(descriptor)
    }

    private func removeNonDirectoryEntry(
        _ name: String,
        expectedMetadata: stat,
        parentDescriptor: Int32
    ) throws {
        if (expectedMetadata.st_mode & S_IFMT) == S_IFREG {
            let opened = name.withCString {
                openat(parentDescriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard opened >= 0 else { throw VaultError.invalidPath }
            defer { Darwin.close(opened) }
            var openedMetadata = stat()
            guard fstat(opened, &openedMetadata) == 0,
                  sameIdentity(expectedMetadata, openedMetadata) else {
                throw VaultError.invalidPath
            }
        }
        var finalMetadata = stat()
        guard name.withCString({
            fstatat(parentDescriptor, $0, &finalMetadata, AT_SYMLINK_NOFOLLOW)
        }) == 0,
              sameIdentity(expectedMetadata, finalMetadata),
              name.withCString({ unlinkat(parentDescriptor, $0, 0) }) == 0 else {
            throw VaultError.invalidPath
        }
    }

    private func entryNames(directoryDescriptor: Int32) throws -> [String] {
        let duplicate = dup(directoryDescriptor)
        guard duplicate >= 0, let directory = fdopendir(duplicate) else {
            if duplicate >= 0 { Darwin.close(duplicate) }
            throw VaultError.ioFailure(errno)
        }
        defer { closedir(directory) }
        var names: [String] = []
        errno = 0
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name != ".", name != ".." { names.append(name) }
            errno = 0
        }
        guard errno == 0 else { throw VaultError.ioFailure(errno) }
        return names.sorted()
    }

    private func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
            && (lhs.st_mode & S_IFMT) == (rhs.st_mode & S_IFMT)
    }

    private func receiptExists() throws -> Bool {
        var metadata = stat()
        guard lstat(receiptURL.path, &metadata) == 0 else {
            if errno == ENOENT { return false }
            throw VaultError.ioFailure(errno)
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_nlink == 1 else {
            throw VaultError.invalidPath
        }
        return true
    }

    private func directoryIdentityIfPresent(_ url: URL) throws -> DirectoryIdentity? {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            if errno == ENOENT { return nil }
            throw VaultError.ioFailure(errno)
        }
        guard (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == geteuid(),
              let device = UInt64(exactly: metadata.st_dev),
              let inode = UInt64(exactly: metadata.st_ino),
              device > 0,
              inode > 0 else {
            throw VaultError.invalidPath
        }
        return DirectoryIdentity(device: device, inode: inode)
    }

    private func writeReceipt(_ data: Data) throws {
        guard data.count <= Self.maximumReceiptByteCount else {
            throw VaultError.resourceLimitExceeded
        }
        let parentDescriptor = try openParentDirectory()
        defer { Darwin.close(parentDescriptor) }
        let descriptor = openat(
            parentDescriptor,
            receiptURL.lastPathComponent,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else { throw VaultError.ioFailure(errno) }
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
                    throw VaultError.ioFailure(errno)
                }
                offset += count
            }
        }
        if fcntl(descriptor, F_FULLFSYNC) != 0, fsync(descriptor) != 0 {
            throw VaultError.ioFailure(errno)
        }
        guard Darwin.close(descriptor) == 0 else {
            throw VaultError.ioFailure(errno)
        }
        closeNeeded = false
        try syncDescriptor(parentDescriptor)
    }

    private func readReceipt() throws -> Data {
        let descriptor = Darwin.open(receiptURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw VaultError.ioFailure(errno) }
        defer { Darwin.close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_nlink == 1,
              metadata.st_size >= 0,
              metadata.st_size <= Self.maximumReceiptByteCount else {
            throw VaultError.invalidPath
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw VaultError.ioFailure(errno)
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= Self.maximumReceiptByteCount else {
                throw VaultError.resourceLimitExceeded
            }
        }
        return data
    }

    private func removeReceipt() throws {
        let parentDescriptor = try openParentDirectory()
        defer { Darwin.close(parentDescriptor) }
        if unlinkat(parentDescriptor, receiptURL.lastPathComponent, 0) != 0,
           errno != ENOENT {
            throw VaultError.ioFailure(errno)
        }
        try syncDescriptor(parentDescriptor)
    }

    private func openParentDirectory() throws -> Int32 {
        let parent = rootURL.deletingLastPathComponent()
        let descriptor = Darwin.open(
            parent.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw VaultError.ioFailure(errno) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == geteuid() else {
            Darwin.close(descriptor)
            throw VaultError.invalidPath
        }
        return descriptor
    }

    private func syncParentDirectory() throws {
        let descriptor = try openParentDirectory()
        defer { Darwin.close(descriptor) }
        try syncDescriptor(descriptor)
    }

    private func syncDescriptor(_ descriptor: Int32) throws {
        guard fsync(descriptor) == 0 || errno == EINVAL || errno == ENOTSUP else {
            throw VaultError.ioFailure(errno)
        }
    }

    private func failIfRequested(_ point: PlaintextVaultTransactionFault) throws {
        if failureInjector?(point) == true { throw VaultError.injectedFailure }
    }
}
