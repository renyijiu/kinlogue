import Darwin
import Foundation
import KinlogueCore

/// Makes the first manifest publication restartable without treating a
/// temporary-looking filename as ownership proof.
///
/// The durable sibling receipt is published before `AtomicFileStore` can
/// create a manifest temporary file. It binds recovery authority to the exact
/// root inode and expected initial manifest. Without that receipt this type
/// never mutates a nonempty root.
struct PlaintextVaultInitializationTransaction: Sendable {
    private struct Receipt: Codable, Equatable {
        let magic: String
        let formatVersion: Int
        let rootPathSHA256: Data
        let device: UInt64
        let inode: UInt64
        let manifestByteCount: Int
        let manifestSHA256: Data
    }

    private struct DirectoryIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
    }

    private static let receiptMagic = "KLGINIT1"
    private static let formatVersion = 1
    private static let maximumReceiptByteCount = 4 * 1024
    private static let maximumInitialManifestByteCount = 1024 * 1024

    let rootURL: URL
    let receiptURL: URL

    private let layout: PlaintextVaultLayout
    private let failureInjector: (@Sendable (PlaintextVaultTransactionFault) -> Bool)?

    init(
        rootURL: URL,
        failureInjector: (@Sendable (PlaintextVaultTransactionFault) -> Bool)? = nil
    ) throws {
        let layout = try PlaintextVaultLayout(rootURL: rootURL)
        self.layout = layout
        self.rootURL = layout.rootURL
        receiptURL = layout.initializationReceiptURL
        self.failureInjector = failureInjector
    }

    func begin(expectedManifestData: Data) throws {
        guard !expectedManifestData.isEmpty,
              expectedManifestData.count <= Self.maximumInitialManifestByteCount,
              try !receiptExists() else {
            throw VaultError.partialInitialization
        }
        let identity = try ensureEmptyRoot()
        let receipt = Receipt(
            magic: Self.receiptMagic,
            formatVersion: Self.formatVersion,
            rootPathSHA256: expectedRootPathDigest,
            device: identity.device,
            inode: identity.inode,
            manifestByteCount: expectedManifestData.count,
            manifestSHA256: ContentDigest.sha256(expectedManifestData)
        )
        try writeReceiptAtomically(try CanonicalVaultJSON.encode(receipt))
        try failIfRequested(.afterInitializationReceipt)
    }

    func finishAfterManifestCommit() throws {
        try failIfRequested(.afterInitializationManifestCommit)
        guard try reconcile() else { throw VaultError.partialInitialization }
    }

    /// Returns true when an initialization receipt was consumed.
    @discardableResult
    func reconcile() throws -> Bool {
        guard try receiptExists() else { return false }
        let receipt = try validatedReceipt()

        guard let identity = try directoryIdentityIfPresent(rootURL) else {
            try removeReceipt()
            return true
        }
        guard identity.device == receipt.device,
              identity.inode == receipt.inode else {
            throw VaultError.invalidPath
        }

        let names = try rootEntryNames(expectedIdentity: identity)
        guard !names.contains(layout.legacyEncryptedMarkerPath) else {
            throw VaultError.legacyEncryptedVault
        }

        if names.contains(layout.manifestPath) {
            let manifest = try readRegularFile(
                rootURL.appendingPathComponent(layout.manifestPath),
                maximumByteCount: Self.maximumInitialManifestByteCount
            )
            guard manifest.count == receipt.manifestByteCount,
                  ContentDigest.sha256(manifest) == receipt.manifestSHA256 else {
                throw VaultError.invalidDigest
            }
            try removeReceipt()
            return true
        }

        // Preflight every entry before deleting any. A valid receipt grants
        // authority only over AtomicFileStore's exact manifest temp grammar.
        guard names.allSatisfy(PlaintextVaultLayout.isAtomicTemporaryFilename) else {
            throw VaultError.partialInitialization
        }
        for name in names {
            try validateOwnedRegularFile(rootURL.appendingPathComponent(name))
        }
        for name in names {
            guard Darwin.unlink(rootURL.appendingPathComponent(name).path) == 0 else {
                throw VaultError.ioFailure(errno)
            }
        }
        if !names.isEmpty { try syncDirectory(rootURL) }
        try removeReceipt()
        return true
    }

    private var expectedRootPathDigest: Data {
        ContentDigest.sha256(Data(layout.transactionCanonicalRootPath.utf8))
    }

    private func validatedReceipt() throws -> Receipt {
        let data = try readRegularFile(
            receiptURL,
            maximumByteCount: Self.maximumReceiptByteCount
        )
        let receipt: Receipt
        do {
            receipt = try CanonicalVaultJSON.decode(Receipt.self, from: data)
            guard try CanonicalVaultJSON.encode(receipt) == data else {
                throw VaultError.invalidCatalog
            }
        } catch let error as VaultError {
            throw error
        } catch {
            throw VaultError.invalidCatalog
        }
        guard receipt.magic == Self.receiptMagic,
              receipt.formatVersion == Self.formatVersion,
              receipt.rootPathSHA256 == expectedRootPathDigest,
              receipt.rootPathSHA256.count == 32,
              receipt.device > 0,
              receipt.inode > 0,
              receipt.manifestByteCount > 0,
              receipt.manifestByteCount <= Self.maximumInitialManifestByteCount,
              receipt.manifestSHA256.count == 32 else {
            throw VaultError.invalidCatalog
        }
        return receipt
    }

    private func ensureEmptyRoot() throws -> DirectoryIdentity {
        let parentDescriptor = try openParentDirectory()
        defer { Darwin.close(parentDescriptor) }
        let rootName = rootURL.lastPathComponent
        guard isSinglePathComponent(rootName) else { throw VaultError.invalidPath }

        var created = false
        if mkdirat(parentDescriptor, rootName, 0o700) == 0 {
            created = true
        } else if errno != EEXIST {
            throw VaultError.ioFailure(errno)
        }
        let rootDescriptor = openat(
            parentDescriptor,
            rootName,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard rootDescriptor >= 0 else { throw VaultError.invalidPath }
        defer { Darwin.close(rootDescriptor) }

        let identity = try directoryIdentity(descriptor: rootDescriptor)
        guard try rootEntryNames(expectedIdentity: identity).isEmpty else {
            throw VaultError.partialInitialization
        }
        guard fchmod(rootDescriptor, 0o700) == 0 else {
            throw VaultError.ioFailure(errno)
        }
        try syncDescriptor(rootDescriptor)
        if created { try syncDescriptor(parentDescriptor) }
        return identity
    }

    private func rootEntryNames(expectedIdentity: DirectoryIdentity) throws -> [String] {
        guard try directoryIdentityIfPresent(rootURL) == expectedIdentity else {
            throw VaultError.invalidPath
        }
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: rootURL.path)
        } catch {
            throw VaultError.ioFailure(EIO)
        }
        guard try directoryIdentityIfPresent(rootURL) == expectedIdentity else {
            throw VaultError.invalidPath
        }
        return names.sorted()
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

    private func directoryIdentity(descriptor: Int32) throws -> DirectoryIdentity {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == geteuid(),
              let device = UInt64(exactly: metadata.st_dev),
              let inode = UInt64(exactly: metadata.st_ino),
              device > 0,
              inode > 0 else {
            throw VaultError.invalidPath
        }
        return DirectoryIdentity(device: device, inode: inode)
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

    private func writeReceiptAtomically(_ data: Data) throws {
        guard data.count <= Self.maximumReceiptByteCount else {
            throw VaultError.resourceLimitExceeded
        }
        let parentDescriptor = try openParentDirectory()
        defer { Darwin.close(parentDescriptor) }
        let temporaryName = receiptURL.lastPathComponent + ".\(UUID().uuidString).tmp"
        let descriptor = openat(
            parentDescriptor,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else { throw VaultError.ioFailure(errno) }
        var closeNeeded = true
        defer {
            if closeNeeded { Darwin.close(descriptor) }
            _ = unlinkat(parentDescriptor, temporaryName, 0)
        }
        try writeAll(data, descriptor: descriptor)
        if fcntl(descriptor, F_FULLFSYNC) != 0, fsync(descriptor) != 0 {
            throw VaultError.ioFailure(errno)
        }
        guard Darwin.close(descriptor) == 0 else { throw VaultError.ioFailure(errno) }
        closeNeeded = false
        guard renameatx_np(
            parentDescriptor,
            temporaryName,
            parentDescriptor,
            receiptURL.lastPathComponent,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            throw VaultError.ioFailure(errno)
        }
        try syncDescriptor(parentDescriptor)
    }

    private func readRegularFile(_ url: URL, maximumByteCount: Int) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { throw VaultError.objectMissing }
            throw VaultError.ioFailure(errno)
        }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_nlink == 1,
              metadata.st_size >= 0,
              metadata.st_size <= maximumByteCount else {
            throw VaultError.invalidPath
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw VaultError.ioFailure(errno)
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= maximumByteCount else {
                throw VaultError.resourceLimitExceeded
            }
        }
        return data
    }

    private func validateOwnedRegularFile(_ url: URL) throws {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_nlink == 1 else {
            throw VaultError.invalidPath
        }
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
        let descriptor = Darwin.open(
            rootURL.deletingLastPathComponent().path,
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

    private func writeAll(_ data: Data, descriptor: Int32) throws {
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
    }

    private func syncDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw VaultError.ioFailure(errno) }
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

    private func isSinglePathComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
    }
}
