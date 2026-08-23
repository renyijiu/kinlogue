import CryptoKit
import Darwin
import Foundation
import KinlogueCore
import ZIPFoundation

public enum PlaintextOriginalArchiveExportError: Error, Equatable, Sendable {
    case emptyArchive
    case invalidDestination
    case insufficientSpace
    case destinationAccessDenied
    case vaultChanged
    case sourceIntegrityFailure
    case archiveIntegrityFailure
    case publicationIndeterminate
    case ioFailure(Int32)
    case injectedFailure
}

public enum OriginalArchiveExportPhase: Equatable, Sendable {
    case preparing
    case writing
    case verifying
    case committing
}

public struct OriginalArchiveExportProgress: Equatable, Sendable {
    public let phase: OriginalArchiveExportPhase
    public let completedByteCount: Int
    public let totalByteCount: Int
    public let completedEntryCount: Int
    public let totalEntryCount: Int
    public let isCancellable: Bool

    init(
        phase: OriginalArchiveExportPhase,
        completedByteCount: Int,
        totalByteCount: Int,
        completedEntryCount: Int,
        totalEntryCount: Int,
        isCancellable: Bool
    ) {
        self.phase = phase
        self.completedByteCount = completedByteCount
        self.totalByteCount = totalByteCount
        self.completedEntryCount = completedEntryCount
        self.totalEntryCount = totalEntryCount
        self.isCancellable = isCancellable
    }
}

public struct PlaintextOriginalArchivePreparation: Sendable {
    public var entryCount: Int { snapshot.plan.entries.count }
    public var totalByteCount: Int { snapshot.plan.totalByteCount }
    let snapshot: PlaintextOriginalArchiveSnapshot
}

public struct PlaintextOriginalArchiveExportResult: Equatable, Sendable {
    public let destinationURL: URL
    public let entryCount: Int
    public let totalByteCount: Int
}

enum PlaintextOriginalArchiveExporterFault: Equatable, Sendable {
    case shortSourceRead
    case beforeVerification
    case corruptWorkArchiveBeforeVerification
    case beforeFinalRevisionCheck
    case beforeCommit
    case afterDestinationParentBinding
}

struct PlaintextOriginalArchiveSnapshot: Sendable {
    let plan: OriginalArchivePlan
    let revision: VaultRevision
    let manifestIdentity: PlaintextVaultManifestIdentity
    let metadataByAttachmentID: [Attachment.ID: PlaintextVaultObjectMetadata]
    let vaultRootURL: URL
}

// SAFETY: `lock` serializes the only mutable state and makes descriptor close
// idempotent. Reads occur only before the actor calls `close()`.
final class PlaintextOriginalArchiveSource: @unchecked Sendable {
    let descriptor: Int32
    let byteCount: Int
    let sha256Digest: Data
    private let lock = NSLock()
    private var isClosed = false

    init(descriptor: Int32, byteCount: Int, sha256Digest: Data) {
        self.descriptor = descriptor
        self.byteCount = byteCount
        self.sha256Digest = sha256Digest
    }

    func close() {
        lock.withLock {
            guard !isClosed else { return }
            isClosed = true
            Darwin.close(descriptor)
        }
    }

    deinit { close() }
}

struct PlaintextOriginalArchiveDestinationAccess: Sendable {
    enum StartResult: Sendable { case notRequired, granted, denied }
    let start: @Sendable (URL) -> StartResult
    let stop: @Sendable (URL) -> Void

    static let live = Self(
        start: { $0.startAccessingSecurityScopedResource() ? .granted : .notRequired },
        stop: { $0.stopAccessingSecurityScopedResource() }
    )
}

/// Creates one plaintext, stored ZIP from a pinned vault revision. ZIPFoundation
/// is confined to this actor and each source is read through a descriptor whose
/// identity was fixed under the vault mutation lease.
public actor PlaintextOriginalArchiveExporter {
    public typealias ProgressHandler = @Sendable (OriginalArchiveExportProgress) -> Void
    private static let bufferSize = 64 * 1_024
    private static let stableModificationDate = Date(timeIntervalSince1970: 315_532_800)

    private let vault: PlaintextVault
    private let fileManager: FileManager
    private let destinationAccess: PlaintextOriginalArchiveDestinationAccess
    private let parentDirectorySync: @Sendable (URL) throws -> Void
    private let failureInjector: (@Sendable (PlaintextOriginalArchiveExporterFault) -> Bool)?

    public init(vault: PlaintextVault) {
        self.vault = vault
        fileManager = .default
        destinationAccess = .live
        parentDirectorySync = Self.syncParentDirectory
        failureInjector = nil
    }

    init(
        vault: PlaintextVault,
        fileManager: FileManager = .default,
        destinationAccess: PlaintextOriginalArchiveDestinationAccess = .live,
        parentDirectorySync: @escaping @Sendable (URL) throws -> Void =
            PlaintextOriginalArchiveExporter.syncParentDirectory,
        failureInjector: (@Sendable (PlaintextOriginalArchiveExporterFault) -> Bool)? = nil
    ) {
        self.vault = vault
        self.fileManager = fileManager
        self.destinationAccess = destinationAccess
        self.parentDirectorySync = parentDirectorySync
        self.failureInjector = failureInjector
    }

    public func prepare(undatedToken: String) async throws -> PlaintextOriginalArchivePreparation {
        let snapshot = try await vault.prepareOriginalArchiveExport(undatedToken: undatedToken)
        guard !snapshot.plan.entries.isEmpty else {
            throw PlaintextOriginalArchiveExportError.emptyArchive
        }
        return PlaintextOriginalArchivePreparation(snapshot: snapshot)
    }

    public func export(
        _ preparation: PlaintextOriginalArchivePreparation,
        to selectedDestinationURL: URL,
        progress: @escaping ProgressHandler = { _ in }
    ) async throws -> PlaintextOriginalArchiveExportResult {
        let snapshot = preparation.snapshot
        try Task.checkCancellation()
        progress(Self.progress(.preparing, snapshot: snapshot))
        let destinationCandidate = try normalizedDestination(
            selectedDestinationURL,
            vaultRootURL: snapshot.vaultRootURL
        )
        let accessResult = destinationAccess.start(destinationCandidate)
        guard accessResult != .denied else {
            throw PlaintextOriginalArchiveExportError.destinationAccessDenied
        }
        defer {
            if accessResult == .granted { destinationAccess.stop(destinationCandidate) }
        }
        let destination = try Self.validatedDestination(
            destinationCandidate,
            vaultRootURL: snapshot.vaultRootURL
        )
        var initialDestinationMetadata = stat()
        let destinationInitiallyExisted = lstat(
            destination.path,
            &initialDestinationMetadata
        ) == 0

        let replacementDirectory = try makeReplacementDirectory(for: destination)
        defer { try? fileManager.removeItem(at: replacementDirectory) }
        try removeReplacementPlaceholderIfCreated(
            at: destination,
            destinationInitiallyExisted: destinationInitiallyExisted
        )
        let workURL = replacementDirectory.appendingPathComponent(UUID().uuidString)
        try checkCapacity(for: snapshot, at: replacementDirectory)
        do {
            try await writeArchive(to: workURL, snapshot: snapshot, progress: progress)
            try fullSyncFile(at: workURL)
            try failIfRequested(.beforeVerification)
            if failureInjector?(.corruptWorkArchiveBeforeVerification) == true {
                try corruptPayload(in: workURL)
            }
            progress(Self.progress(
                .verifying,
                snapshot: snapshot,
                completedBytes: snapshot.plan.totalByteCount,
                completedEntries: snapshot.plan.entries.count
            ))
            try verify(workURL, against: snapshot.plan)
            try failIfRequested(.beforeFinalRevisionCheck)
            try await vault.validateOriginalArchiveRevision(snapshot)
            try Task.checkCancellation()
            try failIfRequested(.beforeCommit)
            progress(Self.progress(
                .committing,
                snapshot: snapshot,
                completedBytes: snapshot.plan.totalByteCount,
                completedEntries: snapshot.plan.entries.count,
                isCancellable: false
            ))
            try publishAtomically(
                workURL,
                to: destination,
                vaultRootURL: snapshot.vaultRootURL,
                coordinateAccess: accessResult == .granted,
                destinationInitiallyExisted: destinationInitiallyExisted
            )
            do {
                try parentDirectorySync(destination)
            } catch {
                guard Self.isUnavailableParentDirectorySync(error) else {
                    throw PlaintextOriginalArchiveExportError.publicationIndeterminate
                }
            }
        } catch let error as PlaintextOriginalArchiveExportError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PlaintextOriginalArchiveExportError.archiveIntegrityFailure
        }
        return PlaintextOriginalArchiveExportResult(
            destinationURL: destination,
            entryCount: snapshot.plan.entries.count,
            totalByteCount: snapshot.plan.totalByteCount
        )
    }
}

private extension PlaintextOriginalArchiveExporter {
    static func progress(
        _ phase: OriginalArchiveExportPhase,
        snapshot: PlaintextOriginalArchiveSnapshot,
        completedBytes: Int = 0,
        completedEntries: Int = 0,
        isCancellable: Bool = true
    ) -> OriginalArchiveExportProgress {
        OriginalArchiveExportProgress(
            phase: phase,
            completedByteCount: completedBytes,
            totalByteCount: snapshot.plan.totalByteCount,
            completedEntryCount: completedEntries,
            totalEntryCount: snapshot.plan.entries.count,
            isCancellable: isCancellable
        )
    }

    func writeArchive(
        to archiveURL: URL,
        snapshot: PlaintextOriginalArchiveSnapshot,
        progress: ProgressHandler
    ) async throws {
        let archive = try Archive(
            url: archiveURL,
            accessMode: .create,
            pathEncoding: nil
        )
        try setPermissions(0o600, at: archiveURL)
        var completedBytes = 0
        var completedEntries = 0
        for entry in snapshot.plan.entries {
            try Task.checkCancellation()
            let source = try await vault.openOriginalArchiveSource(
                for: entry,
                snapshot: snapshot
            )
            defer { source.close() }
            try write(
                entry,
                from: source,
                to: archive,
                completedBytes: &completedBytes,
                completedEntries: completedEntries,
                snapshot: snapshot,
                progress: progress
            )
            completedEntries += 1
            progress(Self.progress(
                .writing,
                snapshot: snapshot,
                completedBytes: completedBytes,
                completedEntries: completedEntries
            ))
        }
        // The archive and its file handle are released when this helper returns,
        // before the caller syncs and reopens the completed file.
    }

    func write(
        _ entry: OriginalArchiveEntry,
        from source: PlaintextOriginalArchiveSource,
        to archive: Archive,
        completedBytes: inout Int,
        completedEntries: Int,
        snapshot: PlaintextOriginalArchiveSnapshot,
        progress: ProgressHandler
    ) throws {
        guard source.byteCount == entry.byteCount,
              source.sha256Digest == entry.sha256Digest else {
            throw PlaintextOriginalArchiveExportError.sourceIntegrityFailure
        }
        var expectedPosition = 0
        var hasher = SHA256()
        try archive.addEntry(
            with: entry.archivePath,
            type: .file,
            uncompressedSize: Int64(entry.byteCount),
            modificationDate: Self.stableModificationDate,
            permissions: 0o600,
            compressionMethod: .none,
            bufferSize: Self.bufferSize
        ) { position, requestedSize in
            try Task.checkCancellation()
            guard position == Int64(expectedPosition),
                  requestedSize > 0,
                  expectedPosition <= entry.byteCount,
                  requestedSize <= entry.byteCount - expectedPosition else {
                throw PlaintextOriginalArchiveExportError.sourceIntegrityFailure
            }
            var data = Data(count: requestedSize)
            if failureInjector?(.shortSourceRead) == true {
                throw PlaintextOriginalArchiveExportError.sourceIntegrityFailure
            }
            let readCount = data.withUnsafeMutableBytes { buffer -> Int in
                while true {
                    let result = pread(
                        source.descriptor,
                        buffer.baseAddress,
                        requestedSize,
                        off_t(expectedPosition)
                    )
                    if result < 0, errno == EINTR { continue }
                    return result
                }
            }
            guard readCount == requestedSize else {
                throw PlaintextOriginalArchiveExportError.sourceIntegrityFailure
            }
            hasher.update(data: data)
            expectedPosition += readCount
            completedBytes += readCount
            progress(Self.progress(
                .writing,
                snapshot: snapshot,
                completedBytes: completedBytes,
                completedEntries: completedEntries
            ))
            return data
        }
        guard expectedPosition == entry.byteCount,
              Data(hasher.finalize()) == entry.sha256Digest else {
            throw PlaintextOriginalArchiveExportError.sourceIntegrityFailure
        }
    }

    func verify(_ archiveURL: URL, against plan: OriginalArchivePlan) throws {
        try Task.checkCancellation()
        let archive = try Archive(url: archiveURL, accessMode: .read)
        let storedEntries = archive.makeIterator()
        for plannedEntry in plan.entries {
            try Task.checkCancellation()
            guard let storedEntry = storedEntries.next() else {
                throw PlaintextOriginalArchiveExportError.archiveIntegrityFailure
            }
            guard storedEntry.type == .file,
                  storedEntry.path == plannedEntry.archivePath,
                  storedEntry.uncompressedSize == UInt64(plannedEntry.byteCount) else {
                throw PlaintextOriginalArchiveExportError.archiveIntegrityFailure
            }
            var count = 0
            var hasher = SHA256()
            _ = try archive.extract(storedEntry, bufferSize: Self.bufferSize) { data in
                try Task.checkCancellation()
                let next = count.addingReportingOverflow(data.count)
                guard !next.overflow, next.partialValue <= plannedEntry.byteCount else {
                    throw PlaintextOriginalArchiveExportError.archiveIntegrityFailure
                }
                count = next.partialValue
                hasher.update(data: data)
            }
            guard count == plannedEntry.byteCount,
                  Data(hasher.finalize()) == plannedEntry.sha256Digest else {
                throw PlaintextOriginalArchiveExportError.archiveIntegrityFailure
            }
        }
        guard storedEntries.next() == nil else {
            throw PlaintextOriginalArchiveExportError.archiveIntegrityFailure
        }
    }

    func normalizedDestination(_ url: URL, vaultRootURL: URL) throws -> URL {
        let destination = url.standardizedFileURL
        guard destination.isFileURL,
              destination.pathExtension.lowercased() == "zip",
              !destination.lastPathComponent.isEmpty,
              !destination.path.utf8.contains(0) else {
            throw PlaintextOriginalArchiveExportError.invalidDestination
        }
        let standardizedVault = vaultRootURL.standardizedFileURL.path
        guard destination.path != standardizedVault,
              !destination.path.hasPrefix(standardizedVault + "/") else {
            throw PlaintextOriginalArchiveExportError.invalidDestination
        }
        return destination
    }

    static func validatedDestination(_ destination: URL, vaultRootURL: URL) throws -> URL {
        let parent = destination.deletingLastPathComponent()
        var parentMetadata = stat()
        guard stat(parent.path, &parentMetadata) == 0,
              (parentMetadata.st_mode & S_IFMT) == S_IFDIR else {
            throw PlaintextOriginalArchiveExportError.invalidDestination
        }
        let resolvedParent = parent.resolvingSymlinksInPath().standardizedFileURL
        let resolvedDestination = resolvedParent.appendingPathComponent(destination.lastPathComponent)
        let canonicalVault = vaultRootURL.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedDestination.path != canonicalVault,
              !resolvedDestination.path.hasPrefix(canonicalVault + "/") else {
            throw PlaintextOriginalArchiveExportError.invalidDestination
        }
        var targetMetadata = stat()
        if lstat(destination.path, &targetMetadata) == 0 {
            guard (targetMetadata.st_mode & S_IFMT) == S_IFREG else {
                throw PlaintextOriginalArchiveExportError.invalidDestination
            }
        } else if errno != ENOENT {
            throw PlaintextOriginalArchiveExportError.ioFailure(errno)
        }
        return destination
    }

    func makeReplacementDirectory(for destination: URL) throws -> URL {
        let directory = try fileManager.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: destination,
            create: true
        )
        try setPermissions(0o700, at: directory)
        return directory
    }

    func removeReplacementPlaceholderIfCreated(
        at destination: URL,
        destinationInitiallyExisted: Bool
    ) throws {
        guard !destinationInitiallyExisted else { return }
        var metadata = stat()
        if lstat(destination.path, &metadata) == 0 {
            guard (metadata.st_mode & S_IFMT) == S_IFREG,
                  metadata.st_size == 0 else {
                throw PlaintextOriginalArchiveExportError.invalidDestination
            }
            try fileManager.removeItem(at: destination)
        } else if errno != ENOENT {
            throw PlaintextOriginalArchiveExportError.ioFailure(errno)
        }
    }

    func checkCapacity(for snapshot: PlaintextOriginalArchiveSnapshot, at directory: URL) throws {
        let overhead = max(1 * 1_024 * 1_024, snapshot.plan.entries.count * 1_024)
        let required = snapshot.plan.totalByteCount.addingReportingOverflow(overhead)
        guard !required.overflow else {
            throw PlaintextOriginalArchiveExportError.insufficientSpace
        }
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = values?.volumeAvailableCapacityForImportantUsage,
           available > 0,
           available < Int64(required.partialValue) {
            throw PlaintextOriginalArchiveExportError.insufficientSpace
        }
    }

    func setPermissions(_ permissions: mode_t, at url: URL) throws {
        if chmod(url.path, permissions) != 0,
           errno != ENOTSUP,
           errno != EOPNOTSUPP {
            throw PlaintextOriginalArchiveExportError.ioFailure(errno)
        }
    }

    func fullSyncFile(at url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw PlaintextOriginalArchiveExportError.ioFailure(errno)
        }
        defer { Darwin.close(descriptor) }
        if fcntl(descriptor, F_FULLFSYNC) != 0, fsync(descriptor) != 0 {
            throw PlaintextOriginalArchiveExportError.ioFailure(errno)
        }
    }

    func publishAtomically(
        _ workURL: URL,
        to destination: URL,
        vaultRootURL: URL,
        coordinateAccess: Bool,
        destinationInitiallyExisted: Bool
    ) throws {
        let fileManager = fileManager
        // Unsandboxed test and command-line processes do not own a Powerbox
        // coordination purpose and NSFileCoordinator rejects their /tmp URLs.
        // Installed save-panel exports use the coordinator-provided URL rather
        // than requiring directory access beyond the selected file authority.
        guard coordinateAccess else {
            try Self.publishBound(
                workURL,
                to: destination,
                vaultRootURL: vaultRootURL,
                destinationInitiallyExisted: destinationInitiallyExisted,
                failureInjector: failureInjector
            )
            return
        }
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var publicationResult: Result<Void, Error>?
        coordinator.coordinate(
            writingItemAt: workURL,
            options: .forMoving,
            writingItemAt: destination,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinatedWorkURL, coordinatedDestination in
            publicationResult = Result {
                _ = try Self.validatedDestination(
                    coordinatedDestination,
                    vaultRootURL: vaultRootURL
                )
                try Self.publishCoordinated(
                    coordinatedWorkURL,
                    to: coordinatedDestination,
                    fileManager: fileManager
                )
            }
        }
        if let coordinationError {
            throw PlaintextOriginalArchiveExportError.ioFailure(
                Int32(clamping: coordinationError.code)
            )
        }
        guard let publicationResult else {
            throw PlaintextOriginalArchiveExportError.ioFailure(EIO)
        }
        try publicationResult.get()
    }

    static func publishCoordinated(
        _ workURL: URL,
        to destination: URL,
        fileManager: FileManager
    ) throws {
        var metadata = stat()
        if lstat(destination.path, &metadata) == 0 {
            guard (metadata.st_mode & S_IFMT) == S_IFREG else {
                throw PlaintextOriginalArchiveExportError.invalidDestination
            }
            _ = try fileManager.replaceItemAt(
                destination,
                withItemAt: workURL,
                backupItemName: nil,
                options: [.usingNewMetadataOnly]
            )
        } else if errno == ENOENT {
            try fileManager.moveItem(at: workURL, to: destination)
        } else {
            throw PlaintextOriginalArchiveExportError.ioFailure(errno)
        }
    }

    static func publishBound(
        _ workURL: URL,
        to destination: URL,
        vaultRootURL: URL,
        destinationInitiallyExisted: Bool,
        failureInjector: (@Sendable (PlaintextOriginalArchiveExporterFault) -> Bool)?
    ) throws {
        let destinationParent = destination.deletingLastPathComponent()
        let resolvedParent = destinationParent.resolvingSymlinksInPath().standardizedFileURL
        let destinationName = destination.lastPathComponent
        guard isSinglePathComponent(destinationName) else {
            throw PlaintextOriginalArchiveExportError.invalidDestination
        }
        let resolvedDestination = resolvedParent.appendingPathComponent(destinationName)
        let canonicalVault = vaultRootURL.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedDestination.path != canonicalVault,
              !resolvedDestination.path.hasPrefix(canonicalVault + "/") else {
            throw PlaintextOriginalArchiveExportError.invalidDestination
        }

        let destinationParentDescriptor = Darwin.open(
            resolvedParent.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard destinationParentDescriptor >= 0 else {
            if errno == EACCES || errno == EPERM {
                throw PlaintextOriginalArchiveExportError.destinationAccessDenied
            }
            throw PlaintextOriginalArchiveExportError.ioFailure(errno)
        }
        defer { Darwin.close(destinationParentDescriptor) }
        var boundParentMetadata = stat()
        guard fstat(destinationParentDescriptor, &boundParentMetadata) == 0,
              (boundParentMetadata.st_mode & S_IFMT) == S_IFDIR else {
            throw PlaintextOriginalArchiveExportError.invalidDestination
        }

        var targetMetadata = stat()
        let targetStatus = destinationName.withCString {
            fstatat(
                destinationParentDescriptor,
                $0,
                &targetMetadata,
                AT_SYMLINK_NOFOLLOW
            )
        }
        if targetStatus == 0 {
            guard (targetMetadata.st_mode & S_IFMT) == S_IFREG else {
                throw PlaintextOriginalArchiveExportError.invalidDestination
            }
        } else if errno != ENOENT {
            throw PlaintextOriginalArchiveExportError.ioFailure(errno)
        }

        let workParent = workURL.deletingLastPathComponent().resolvingSymlinksInPath()
        let workName = workURL.lastPathComponent
        guard isSinglePathComponent(workName) else {
            throw PlaintextOriginalArchiveExportError.archiveIntegrityFailure
        }
        let workParentDescriptor = Darwin.open(
            workParent.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard workParentDescriptor >= 0 else {
            throw PlaintextOriginalArchiveExportError.ioFailure(errno)
        }
        defer { Darwin.close(workParentDescriptor) }
        var workMetadata = stat()
        guard workName.withCString({
            fstatat(workParentDescriptor, $0, &workMetadata, AT_SYMLINK_NOFOLLOW)
        }) == 0,
              (workMetadata.st_mode & S_IFMT) == S_IFREG else {
            throw PlaintextOriginalArchiveExportError.archiveIntegrityFailure
        }
        let workDirectoryName: String? = {
            let parent = workParent.deletingLastPathComponent().standardizedFileURL
            guard parent == resolvedParent,
                  isSinglePathComponent(workParent.lastPathComponent) else { return nil }
            return workParent.lastPathComponent
        }()

        if failureInjector?(.afterDestinationParentBinding) == true {
            throw PlaintextOriginalArchiveExportError.injectedFailure
        }
        var currentParentMetadata = stat()
        if stat(destinationParent.path, &currentParentMetadata) != 0
            || !sameIdentity(boundParentMetadata, currentParentMetadata) {
            let removedWork = removeBoundRegularFile(
                descriptor: workParentDescriptor,
                name: workName,
                expected: workMetadata
            )
            let removedPlaceholder: Bool
            if !destinationInitiallyExisted, targetStatus == 0 {
                removedPlaceholder = removeBoundRegularFile(
                    descriptor: destinationParentDescriptor,
                    name: destinationName,
                    expected: targetMetadata
                )
            } else {
                removedPlaceholder = true
            }
            if removedWork, let workDirectoryName {
                _ = workDirectoryName.withCString {
                    unlinkat(destinationParentDescriptor, $0, AT_REMOVEDIR)
                }
            }
            guard removedWork, removedPlaceholder else {
                throw PlaintextOriginalArchiveExportError.publicationIndeterminate
            }
            throw PlaintextOriginalArchiveExportError.invalidDestination
        }

        let renameStatus = workName.withCString { sourceName in
            destinationName.withCString { targetName in
                renameat(
                    workParentDescriptor,
                    sourceName,
                    destinationParentDescriptor,
                    targetName
                )
            }
        }
        guard renameStatus == 0 else {
            if errno == EISDIR || errno == ENOTDIR || errno == ELOOP {
                throw PlaintextOriginalArchiveExportError.invalidDestination
            }
            throw PlaintextOriginalArchiveExportError.ioFailure(errno)
        }
        var publishedMetadata = stat()
        guard destinationName.withCString({
            fstatat(
                destinationParentDescriptor,
                $0,
                &publishedMetadata,
                AT_SYMLINK_NOFOLLOW
            )
        }) == 0,
              sameIdentity(workMetadata, publishedMetadata) else {
            throw PlaintextOriginalArchiveExportError.publicationIndeterminate
        }
    }

    static func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
            && (lhs.st_mode & S_IFMT) == (rhs.st_mode & S_IFMT)
    }

    static func removeBoundRegularFile(
        descriptor: Int32,
        name: String,
        expected: stat
    ) -> Bool {
        var current = stat()
        let status = name.withCString {
            fstatat(descriptor, $0, &current, AT_SYMLINK_NOFOLLOW)
        }
        guard status == 0 else { return errno == ENOENT }
        guard (current.st_mode & S_IFMT) == S_IFREG,
              sameIdentity(current, expected) else { return false }
        return name.withCString { unlinkat(descriptor, $0, 0) } == 0 || errno == ENOENT
    }

    static func isSinglePathComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".."
            && !value.contains("/") && !value.utf8.contains(0)
    }

    static func syncParentDirectory(of destination: URL) throws {
        let descriptor = Darwin.open(
            destination.deletingLastPathComponent().path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw PlaintextOriginalArchiveExportError.ioFailure(errno)
        }
        defer { Darwin.close(descriptor) }
        if fsync(descriptor) != 0, errno != EINVAL, errno != ENOTSUP {
            throw PlaintextOriginalArchiveExportError.ioFailure(errno)
        }
    }

    static func isUnavailableParentDirectorySync(_ error: Error) -> Bool {
        guard case let PlaintextOriginalArchiveExportError.ioFailure(errorCode) = error else {
            return false
        }
        // NSSavePanel grants access to the selected file, not necessarily its
        // parent directory. The archive itself was already fully synced,
        // verified, and atomically published before this best-effort step.
        return [EACCES, EPERM, EINVAL, ENOTSUP, EOPNOTSUPP].contains(errorCode)
    }

    func corruptPayload(in url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw PlaintextOriginalArchiveExportError.ioFailure(errno)
        }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        var header = [UInt8](repeating: 0, count: 30)
        guard fstat(descriptor, &metadata) == 0, metadata.st_size > 30,
              pread(descriptor, &header, header.count, 0) == header.count,
              header[0...3].elementsEqual([0x50, 0x4b, 0x03, 0x04]) else {
            throw PlaintextOriginalArchiveExportError.ioFailure(EIO)
        }
        let filenameLength = Int(header[26]) | (Int(header[27]) << 8)
        let extraLength = Int(header[28]) | (Int(header[29]) << 8)
        let payloadOffset = 30 + filenameLength + extraLength
        guard payloadOffset < metadata.st_size else {
            throw PlaintextOriginalArchiveExportError.ioFailure(EIO)
        }
        var byte: UInt8 = 0
        guard pread(descriptor, &byte, 1, off_t(payloadOffset)) == 1 else {
            throw PlaintextOriginalArchiveExportError.ioFailure(EIO)
        }
        byte ^= 0xff
        guard pwrite(descriptor, &byte, 1, off_t(payloadOffset)) == 1 else {
            throw PlaintextOriginalArchiveExportError.ioFailure(EIO)
        }
        try fullSyncFile(at: url)
    }

    func failIfRequested(_ fault: PlaintextOriginalArchiveExporterFault) throws {
        if failureInjector?(fault) == true {
            throw PlaintextOriginalArchiveExportError.injectedFailure
        }
    }
}
