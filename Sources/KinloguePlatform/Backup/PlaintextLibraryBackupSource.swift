import CryptoKit
import Darwin
import Foundation
import KinlogueCore

public enum PlaintextLibraryBackupSourceError: Error, Equatable, Sendable {
    case sourceChanged
    case resourceLimit
    case integrityFailure
    case invalidRoot
    case ioFailure(Int32)
}

public struct BackupPublishedFileIdentity: Hashable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let byteCount: UInt64

    public init(device: UInt64, inode: UInt64, byteCount: UInt64) {
        self.device = device
        self.inode = inode
        self.byteCount = byteCount
    }
}

struct PlaintextLibraryBackupFile: Sendable {
    let kind: BackupManifestEntry.Kind
    let relativePath: String
    let byteCount: UInt64
    let digest: Data
}

struct PlaintextVaultBackupSnapshot: Sendable {
    let root: VaultRootGeneration
    let manifestIdentity: PlaintextVaultManifestIdentity
    let revision: VaultRevision
    let files: [PlaintextLibraryBackupFile]
}

struct PlaintextLANInboxBackupSnapshot: Sendable {
    let root: VaultRootGeneration
    let manifestIdentity: BackupPublishedFileIdentity
    let revision: LANInboxRevision
    let files: [PlaintextLibraryBackupFile]
}

private enum PlaintextLibraryBackupPlanEntry: Sendable {
    case inline(kind: BackupManifestEntry.Kind, path: String, bytes: Data)
    case file(
        kind: BackupManifestEntry.Kind,
        path: String,
        byteCount: UInt64,
        digest: Data,
        identity: BackupPublishedFileIdentity
    )

    var kind: BackupManifestEntry.Kind {
        switch self {
        case let .inline(kind, _, _), let .file(kind, _, _, _, _): kind
        }
    }

    var path: String {
        switch self {
        case let .inline(_, path, _), let .file(_, path, _, _, _): path
        }
    }

    var byteCount: UInt64 {
        switch self {
        case let .inline(_, _, bytes): UInt64(bytes.count)
        case let .file(_, _, byteCount, _, _): byteCount
        }
    }

    var digest: Data {
        switch self {
        case let .inline(_, _, bytes): Data(SHA256.hash(data: bytes))
        case let .file(_, _, _, digest, _): digest
        }
    }
}

public struct PlaintextLibraryBackupPlan: Sendable {
    public let revisionPair: BackupRevisionPair
    public let entryCount: Int
    public let totalPlaintextByteCount: UInt64

    fileprivate let root: VaultRootGeneration
    fileprivate let vaultSnapshot: PlaintextVaultBackupSnapshot
    fileprivate let inboxSnapshot: PlaintextLANInboxBackupSnapshot
    fileprivate let entries: [PlaintextLibraryBackupPlanEntry]
}

// SAFETY: lock protects both current and maximum descriptor counters and all
// callers observe only copied integer snapshots.
private final class SourceDescriptorMetrics: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private var maximum = 0

    func didOpen() {
        lock.withLock {
            current += 1
            maximum = max(maximum, current)
        }
    }

    func didClose() {
        lock.withLock { current = max(0, current - 1) }
    }

    var maximumValue: Int { lock.withLock { maximum } }
}

/// Freezes the two authoritative plaintext heads under the vault-wide mutation
/// lease, then exposes one-at-a-time descriptor-backed readers. Large objects
/// are never retained in an in-memory snapshot.
public actor PlaintextLibraryBackupSource {
    private let vault: PlaintextVault
    private var inboxStore: PlaintextLANInboxStore?
    private let rootURL: URL
    private let mutationCoordinator: VaultMutationCoordinator
    private let metrics = SourceDescriptorMetrics()

    public init(vault: PlaintextVault, inboxStore: PlaintextLANInboxStore) throws {
        let vaultRoot = vault.backupRootURL
        let inboxRoot = inboxStore.backupRootURL
        guard vaultRoot == inboxRoot else {
            throw PlaintextLibraryBackupSourceError.invalidRoot
        }
        self.vault = vault
        self.inboxStore = inboxStore
        rootURL = vaultRoot
        mutationCoordinator = VaultMutationCoordinator.shared(for: vaultRoot)
    }

    /// Defers constructing the inbox store until the first backup operation.
    /// Composition uses this on a clean first launch so restore reconciliation
    /// still observes an absent active root before normal Vault bootstrap.
    public init(vault: PlaintextVault, deferredInboxRootURL: URL) throws {
        let vaultRoot = vault.backupRootURL
        guard vaultRoot == deferredInboxRootURL.standardizedFileURL else {
            throw PlaintextLibraryBackupSourceError.invalidRoot
        }
        self.vault = vault
        inboxStore = nil
        rootURL = vaultRoot
        mutationCoordinator = VaultMutationCoordinator.shared(for: vaultRoot)
    }

    public var maximumSimultaneousOpenFileCount: Int { metrics.maximumValue }

    public func prepare() async throws -> PlaintextLibraryBackupPlan {
        do {
            try Task.checkCancellation()
            let inboxStore = try resolvedInboxStore()
            let lease = try await mutationCoordinator.acquire()
            defer { lease.release() }

            let vaultSnapshot = try await vault.backupSnapshot(using: lease)
            let inboxSnapshot = try await inboxStore.backupSnapshot(using: lease)
            guard vaultSnapshot.root == inboxSnapshot.root else {
                throw PlaintextLibraryBackupSourceError.sourceChanged
            }

            var entries: [PlaintextLibraryBackupPlanEntry] = []
            for file in vaultSnapshot.files + inboxSnapshot.files {
                let identity = try Self.inspectFile(
                    relativePath: file.relativePath,
                    root: vaultSnapshot.root,
                    rootURL: rootURL
                )
                guard identity.byteCount == file.byteCount else {
                    throw PlaintextLibraryBackupSourceError.integrityFailure
                }
                entries.append(.file(
                    kind: file.kind,
                    path: file.relativePath,
                    byteCount: file.byteCount,
                    digest: file.digest,
                    identity: identity
                ))
            }
            entries.sort { $0.path < $1.path }
            guard entries.count <= BackupFormatLimits.maximumEntryCount,
                  Set(entries.map(\.path)).count == entries.count else {
                throw PlaintextLibraryBackupSourceError.resourceLimit
            }
            var total: UInt64 = 0
            for entry in entries {
                let next = total.addingReportingOverflow(entry.byteCount)
                guard !next.overflow,
                      next.partialValue <= BackupFormatLimits.maximumPlaintextByteCount else {
                    throw PlaintextLibraryBackupSourceError.resourceLimit
                }
                total = next.partialValue
            }
            return PlaintextLibraryBackupPlan(
                revisionPair: try BackupRevisionPair(
                    vault: vaultSnapshot.revision,
                    lanInbox: inboxSnapshot.revision
                ),
                entryCount: entries.count,
                totalPlaintextByteCount: total,
                root: vaultSnapshot.root,
                vaultSnapshot: vaultSnapshot,
                inboxSnapshot: inboxSnapshot,
                entries: entries
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as PlaintextLibraryBackupSourceError {
            throw error
        } catch VaultError.resourceLimitExceeded {
            throw PlaintextLibraryBackupSourceError.resourceLimit
        } catch VaultError.ioFailure(let code) {
            throw PlaintextLibraryBackupSourceError.ioFailure(code)
        } catch {
            throw PlaintextLibraryBackupSourceError.integrityFailure
        }
    }

    public func containerSources(
        for plan: PlaintextLibraryBackupPlan
    ) -> [BackupContainerEntrySource] {
        plan.entries.map { entry in
            BackupContainerEntrySource(
                kind: entry.kind,
                path: entry.path,
                plaintextByteCount: entry.byteCount,
                plaintextDigest: entry.digest,
                open: { [self] in try await open(entry: entry, plan: plan) }
            )
        }
    }

    public func validateCurrentPair(for plan: PlaintextLibraryBackupPlan) async throws {
        do {
            let lease = try await mutationCoordinator.acquire()
            defer { lease.release() }
            try await validate(plan, using: lease)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as PlaintextLibraryBackupSourceError {
            throw error
        } catch {
            throw PlaintextLibraryBackupSourceError.sourceChanged
        }
    }

    /// Retains the short source lease through a synchronous publication step.
    /// No file payload is read while this lease is held.
    func withValidatedCurrentPair<T: Sendable>(
        for plan: PlaintextLibraryBackupPlan,
        _ body: () throws -> T
    ) async throws -> T {
        let lease = try await mutationCoordinator.acquire()
        defer { lease.release() }
        do {
            try await validate(plan, using: lease)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as PlaintextLibraryBackupSourceError {
            throw error
        } catch {
            throw PlaintextLibraryBackupSourceError.sourceChanged
        }
        return try body()
    }

    private func validate(
        _ plan: PlaintextLibraryBackupPlan,
        using lease: VaultMutationLease
    ) async throws {
        guard plan.root == plan.vaultSnapshot.root,
              plan.root == plan.inboxSnapshot.root else {
            throw PlaintextLibraryBackupSourceError.sourceChanged
        }
        try await vault.validateBackupSnapshot(plan.vaultSnapshot, using: lease)
        let inboxStore = try resolvedInboxStore()
        try await inboxStore.validateBackupSnapshot(plan.inboxSnapshot, using: lease)
    }

    private func resolvedInboxStore() throws -> PlaintextLANInboxStore {
        if let inboxStore { return inboxStore }
        let created = try PlaintextLANInboxStore(rootURL: rootURL)
        inboxStore = created
        return created
    }

    private func open(
        entry: PlaintextLibraryBackupPlanEntry,
        plan: PlaintextLibraryBackupPlan
    ) async throws -> BackupContainerOpenedEntrySource {
        let lease = try await mutationCoordinator.acquire()
        do {
            try await validate(plan, using: lease)
            switch entry {
            case let .inline(_, _, bytes):
                lease.release()
                return BackupContainerOpenedEntrySource { offset, count in
                    guard offset <= UInt64(bytes.count),
                          let start = Int(exactly: offset) else { return Data() }
                    return Data(bytes[start..<min(bytes.count, start + count)])
                }
            case let .file(_, path, _, _, expectedIdentity):
                let descriptor = try Self.openFile(
                    relativePath: path,
                    root: plan.root,
                    rootURL: rootURL,
                    expectedIdentity: expectedIdentity
                )
                metrics.didOpen()
                lease.release()
                let metrics = metrics
                return BackupContainerOpenedEntrySource(
                    read: { offset, count in
                        try Self.read(descriptor: descriptor, offset: offset, count: count)
                    },
                    close: {
                        Darwin.close(descriptor)
                        metrics.didClose()
                    }
                )
            }
        } catch {
            lease.release()
            throw error
        }
    }

    private static func inspectFile(
        relativePath: String,
        root: VaultRootGeneration,
        rootURL: URL
    ) throws -> BackupPublishedFileIdentity {
        let descriptor = try openFile(
            relativePath: relativePath,
            root: root,
            rootURL: rootURL,
            expectedIdentity: nil
        )
        defer { Darwin.close(descriptor) }
        return try strictIdentity(descriptor)
    }

    private static func openFile(
        relativePath: String,
        root: VaultRootGeneration,
        rootURL: URL,
        expectedIdentity: BackupPublishedFileIdentity?
    ) throws -> Int32 {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw PlaintextLibraryBackupSourceError.integrityFailure
        }
        var directory = Darwin.open(rootURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else {
            throw PlaintextLibraryBackupSourceError.ioFailure(errno)
        }
        do {
            let rootIdentity = try strictDirectoryIdentity(directory)
            guard rootIdentity.device == root.rootDevice,
                  rootIdentity.inode == root.rootInode else {
                throw PlaintextLibraryBackupSourceError.sourceChanged
            }
            for component in components.dropLast() {
                let next = openat(
                    directory,
                    String(component),
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
                guard next >= 0 else {
                    throw PlaintextLibraryBackupSourceError.ioFailure(errno)
                }
                Darwin.close(directory)
                directory = next
                _ = try strictDirectoryIdentity(directory)
            }
            let descriptor = openat(
                directory,
                String(components.last!),
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
            guard descriptor >= 0 else {
                throw PlaintextLibraryBackupSourceError.ioFailure(errno)
            }
            do {
                let actual = try strictIdentity(descriptor)
                if let expectedIdentity, actual != expectedIdentity {
                    throw PlaintextLibraryBackupSourceError.sourceChanged
                }
                Darwin.close(directory)
                return descriptor
            } catch {
                Darwin.close(descriptor)
                throw error
            }
        } catch {
            Darwin.close(directory)
            throw error
        }
    }

    private static func strictDirectoryIdentity(
        _ descriptor: Int32
    ) throws -> BackupFilesystemIdentity {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw PlaintextLibraryBackupSourceError.ioFailure(errno)
        }
        guard (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == geteuid(),
              metadata.st_nlink >= 2 else {
            throw PlaintextLibraryBackupSourceError.invalidRoot
        }
        return .init(device: UInt64(metadata.st_dev), inode: UInt64(metadata.st_ino))
    }

    private static func strictIdentity(
        _ descriptor: Int32
    ) throws -> BackupPublishedFileIdentity {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw PlaintextLibraryBackupSourceError.ioFailure(errno)
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_nlink == 1,
              metadata.st_size >= 0 else {
            throw PlaintextLibraryBackupSourceError.integrityFailure
        }
        return .init(
            device: UInt64(metadata.st_dev),
            inode: UInt64(metadata.st_ino),
            byteCount: UInt64(metadata.st_size)
        )
    }

    private static func read(descriptor: Int32, offset: UInt64, count: Int) throws -> Data {
        guard count >= 0, let fileOffset = off_t(exactly: offset) else {
            throw PlaintextLibraryBackupSourceError.integrityFailure
        }
        if count == 0 { return Data() }
        var bytes = Data(count: count)
        let readCount = bytes.withUnsafeMutableBytes { raw in
            pread(descriptor, raw.baseAddress, count, fileOffset)
        }
        guard readCount >= 0 else {
            throw PlaintextLibraryBackupSourceError.ioFailure(errno)
        }
        bytes.count = readCount
        return bytes
    }
}
