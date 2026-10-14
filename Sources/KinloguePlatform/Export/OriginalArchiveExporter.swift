import CryptoKit
import Darwin
import Foundation
import KinlogueCore
import ZIPFoundation

public enum OriginalArchiveExportError: Error, Equatable, Sendable {
    case emptyArchive
    case invalidDestination
    case insufficientSpace
    case destinationAccessDenied
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

public struct OriginalArchivePreparation: Sendable {
    public var entryCount: Int { snapshot.plan.entries.count }
    public var totalByteCount: Int { snapshot.plan.totalByteCount }
    let snapshot: OriginalArchiveSnapshot
}

public struct OriginalArchiveExportResult: Equatable, Sendable {
    public let destinationURL: URL
    public let entryCount: Int
    public let totalByteCount: Int
}

enum OriginalArchiveExporterFault: Equatable, Sendable {
    case shortSourceRead
    case beforeVerification
    case corruptWorkArchiveBeforeVerification
    case beforeFinalRevisionCheck
    case beforeCommit
    case afterDestinationParentBinding
}

/// The plan of one export and the pins that keep its originals readable until it ends.
struct OriginalArchiveSnapshot: Sendable {
    let plan: OriginalArchivePlan
    let pins: SQLiteLogicalOriginalPins
    let vaultRootURL: URL

    init(plan: OriginalArchivePlan, pins: SQLiteLogicalOriginalPins, rootURL: URL) {
        self.plan = plan
        self.pins = pins
        vaultRootURL = rootURL
    }
}

// SAFETY: `lock` serializes the only mutable state and makes closing the reader
// idempotent. Reads occur only before the actor calls `close()`.
final class OriginalArchiveSource: @unchecked Sendable {
    let byteCount: Int
    let sha256Digest: Data
    private let lock = NSLock()
    private var isClosed = false
    private let reader: SQLiteLogicalOriginalReader

    init(reader: SQLiteLogicalOriginalReader, byteCount: Int, sha256Digest: Data) {
        self.reader = reader
        self.byteCount = byteCount
        self.sha256Digest = sha256Digest
    }

    func read(offset: Int, count: Int) throws -> Data {
        try lock.withLock {
            guard !isClosed else { throw OriginalArchiveExportError.sourceIntegrityFailure }
            return try reader.read(offset: UInt64(offset), maximumByteCount: count)
        }
    }

    func reportDigestMismatch() { reader.reportDigestMismatch() }

    func close() {
        lock.withLock {
            guard !isClosed else { return }
            isClosed = true
            reader.close()
        }
    }

    deinit { close() }
}

struct OriginalArchiveDestinationAccess: Sendable {
    enum StartResult: Sendable { case notRequired, granted, denied }
    let start: @Sendable (URL) -> StartResult
    let stop: @Sendable (URL) -> Void

    static let live = Self(
        start: { $0.startAccessingSecurityScopedResource() ? .granted : .notRequired },
        stop: { $0.stopAccessingSecurityScopedResource() }
    )
}

/// Creates one plaintext, stored ZIP from the originals a preparation pinned. ZIPFoundation
/// is confined to this actor and each source is read through the pin that fixed its identity.
public actor OriginalArchiveExporter {
    public typealias ProgressHandler = @Sendable (OriginalArchiveExportProgress) -> Void
    private static let bufferSize = 64 * 1_024
    private static let stableModificationDate = Date(timeIntervalSince1970: 315_532_800)

    private let store: SQLiteLibraryStore
    private let fileManager: FileManager
    private let destinationAccess: OriginalArchiveDestinationAccess
    private let parentDirectorySync: @Sendable (URL) throws -> Void
    private let failureInjector: (@Sendable (OriginalArchiveExporterFault) -> Bool)?

    package init(store: SQLiteLibraryStore) {
        self.init(store: store, fileManager: .default)
    }

    init(
        store: SQLiteLibraryStore,
        fileManager: FileManager,
        destinationAccess: OriginalArchiveDestinationAccess = .live,
        parentDirectorySync: @escaping @Sendable (URL) throws -> Void =
            OriginalArchiveExporter.syncParentDirectory,
        failureInjector: (@Sendable (OriginalArchiveExporterFault) -> Bool)? = nil
    ) {
        self.store = store
        self.fileManager = fileManager
        self.destinationAccess = destinationAccess
        self.parentDirectorySync = parentDirectorySync
        self.failureInjector = failureInjector
    }

    /// Pins the originals one export will read. The export that receives the preparation releases
    /// them when it ends, whatever the outcome, so each export needs a preparation of its own.
    public func prepare(undatedToken: String) async throws -> OriginalArchivePreparation {
        let snapshot: OriginalArchiveSnapshot
        snapshot = try await SQLiteOriginalArchiveSource(store: store).prepare(undatedToken: undatedToken)
        guard !snapshot.plan.entries.isEmpty else {
            throw OriginalArchiveExportError.emptyArchive
        }
        return OriginalArchivePreparation(snapshot: snapshot)
    }

    public func export(
        _ preparation: OriginalArchivePreparation,
        to selectedDestinationURL: URL,
        progress: @escaping ProgressHandler = { _ in }
    ) async throws -> OriginalArchiveExportResult {
        let snapshot = preparation.snapshot
        defer { snapshot.pins.release() }
        try Task.checkCancellation()
        progress(Self.progress(.preparing, snapshot: snapshot))
        let destinationCandidate = try normalizedDestination(
            selectedDestinationURL,
            vaultRootURL: snapshot.vaultRootURL
        )
        let accessResult = destinationAccess.start(destinationCandidate)
        guard accessResult != .denied else {
            throw OriginalArchiveExportError.destinationAccessDenied
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
            try snapshot.pins.validate()
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
                    throw OriginalArchiveExportError.publicationIndeterminate
                }
            }
        } catch let error as OriginalArchiveExportError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw OriginalArchiveExportError.archiveIntegrityFailure
        }
        return OriginalArchiveExportResult(
            destinationURL: destination,
            entryCount: snapshot.plan.entries.count,
            totalByteCount: snapshot.plan.totalByteCount
        )
    }
}

private extension OriginalArchiveExporter {
    static func progress(
        _ phase: OriginalArchiveExportPhase,
        snapshot: OriginalArchiveSnapshot,
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
        snapshot: OriginalArchiveSnapshot,
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
            let source = OriginalArchiveSource(reader: try snapshot.pins.open(entry.attachmentID),
                                                        byteCount: entry.byteCount, sha256Digest: entry.sha256Digest)
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
        from source: OriginalArchiveSource,
        to archive: Archive,
        completedBytes: inout Int,
        completedEntries: Int,
        snapshot: OriginalArchiveSnapshot,
        progress: ProgressHandler
    ) throws {
        guard source.byteCount == entry.byteCount,
              source.sha256Digest == entry.sha256Digest else {
            throw OriginalArchiveExportError.sourceIntegrityFailure
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
                throw OriginalArchiveExportError.sourceIntegrityFailure
            }
            if failureInjector?(.shortSourceRead) == true { throw OriginalArchiveExportError.sourceIntegrityFailure }
            let data = try source.read(offset: expectedPosition, count: requestedSize)
            let readCount = data.count
            guard readCount == requestedSize else { throw OriginalArchiveExportError.sourceIntegrityFailure }
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
        guard expectedPosition == entry.byteCount else { throw OriginalArchiveExportError.sourceIntegrityFailure }
        guard Data(hasher.finalize()) == entry.sha256Digest else {
            source.reportDigestMismatch()
            throw OriginalArchiveExportError.sourceIntegrityFailure
        }
    }

    func verify(_ archiveURL: URL, against plan: OriginalArchivePlan) throws {
        try Task.checkCancellation()
        let archive = try Archive(url: archiveURL, accessMode: .read)
        let storedEntries = archive.makeIterator()
        for plannedEntry in plan.entries {
            try Task.checkCancellation()
            guard let storedEntry = storedEntries.next() else {
                throw OriginalArchiveExportError.archiveIntegrityFailure
            }
            guard storedEntry.type == .file,
                  storedEntry.path == plannedEntry.archivePath,
                  storedEntry.uncompressedSize == UInt64(plannedEntry.byteCount) else {
                throw OriginalArchiveExportError.archiveIntegrityFailure
            }
            var count = 0
            var hasher = SHA256()
            _ = try archive.extract(storedEntry, bufferSize: Self.bufferSize) { data in
                try Task.checkCancellation()
                let next = count.addingReportingOverflow(data.count)
                guard !next.overflow, next.partialValue <= plannedEntry.byteCount else {
                    throw OriginalArchiveExportError.archiveIntegrityFailure
                }
                count = next.partialValue
                hasher.update(data: data)
            }
            guard count == plannedEntry.byteCount,
                  Data(hasher.finalize()) == plannedEntry.sha256Digest else {
                throw OriginalArchiveExportError.archiveIntegrityFailure
            }
        }
        guard storedEntries.next() == nil else {
            throw OriginalArchiveExportError.archiveIntegrityFailure
        }
    }

    func normalizedDestination(_ url: URL, vaultRootURL: URL) throws -> URL {
        let destination = url.standardizedFileURL
        guard destination.isFileURL,
              destination.pathExtension.lowercased() == "zip",
              !destination.lastPathComponent.isEmpty,
              !destination.path.utf8.contains(0) else {
            throw OriginalArchiveExportError.invalidDestination
        }
        let standardizedVault = vaultRootURL.standardizedFileURL.path
        guard destination.path != standardizedVault,
              !destination.path.hasPrefix(standardizedVault + "/") else {
            throw OriginalArchiveExportError.invalidDestination
        }
        return destination
    }

    static func validatedDestination(_ destination: URL, vaultRootURL: URL) throws -> URL {
        let parent = destination.deletingLastPathComponent()
        var parentMetadata = stat()
        guard stat(parent.path, &parentMetadata) == 0,
              (parentMetadata.st_mode & S_IFMT) == S_IFDIR else {
            throw OriginalArchiveExportError.invalidDestination
        }
        let resolvedParent = parent.resolvingSymlinksInPath().standardizedFileURL
        let resolvedDestination = resolvedParent.appendingPathComponent(destination.lastPathComponent)
        let canonicalVault = vaultRootURL.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedDestination.path != canonicalVault,
              !resolvedDestination.path.hasPrefix(canonicalVault + "/") else {
            throw OriginalArchiveExportError.invalidDestination
        }
        var targetMetadata = stat()
        if lstat(destination.path, &targetMetadata) == 0 {
            guard (targetMetadata.st_mode & S_IFMT) == S_IFREG else {
                throw OriginalArchiveExportError.invalidDestination
            }
        } else if errno != ENOENT {
            throw OriginalArchiveExportError.ioFailure(errno)
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
                throw OriginalArchiveExportError.invalidDestination
            }
            try fileManager.removeItem(at: destination)
        } else if errno != ENOENT {
            throw OriginalArchiveExportError.ioFailure(errno)
        }
    }

    func checkCapacity(for snapshot: OriginalArchiveSnapshot, at directory: URL) throws {
        let overhead = max(1 * 1_024 * 1_024, snapshot.plan.entries.count * 1_024)
        let required = snapshot.plan.totalByteCount.addingReportingOverflow(overhead)
        guard !required.overflow else {
            throw OriginalArchiveExportError.insufficientSpace
        }
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = values?.volumeAvailableCapacityForImportantUsage,
           available > 0,
           available < Int64(required.partialValue) {
            throw OriginalArchiveExportError.insufficientSpace
        }
    }

    func setPermissions(_ permissions: mode_t, at url: URL) throws {
        if chmod(url.path, permissions) != 0,
           errno != ENOTSUP,
           errno != EOPNOTSUPP {
            throw OriginalArchiveExportError.ioFailure(errno)
        }
    }

    func fullSyncFile(at url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw OriginalArchiveExportError.ioFailure(errno)
        }
        defer { Darwin.close(descriptor) }
        if fcntl(descriptor, F_FULLFSYNC) != 0, fsync(descriptor) != 0 {
            throw OriginalArchiveExportError.ioFailure(errno)
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
            throw OriginalArchiveExportError.ioFailure(
                Int32(clamping: coordinationError.code)
            )
        }
        guard let publicationResult else {
            throw OriginalArchiveExportError.ioFailure(EIO)
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
                throw OriginalArchiveExportError.invalidDestination
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
            throw OriginalArchiveExportError.ioFailure(errno)
        }
    }

    static func publishBound(
        _ workURL: URL,
        to destination: URL,
        vaultRootURL: URL,
        destinationInitiallyExisted: Bool,
        failureInjector: (@Sendable (OriginalArchiveExporterFault) -> Bool)?
    ) throws {
        let destinationParent = destination.deletingLastPathComponent()
        let resolvedParent = destinationParent.resolvingSymlinksInPath().standardizedFileURL
        let destinationName = destination.lastPathComponent
        guard isSinglePathComponent(destinationName) else {
            throw OriginalArchiveExportError.invalidDestination
        }
        let resolvedDestination = resolvedParent.appendingPathComponent(destinationName)
        let canonicalVault = vaultRootURL.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedDestination.path != canonicalVault,
              !resolvedDestination.path.hasPrefix(canonicalVault + "/") else {
            throw OriginalArchiveExportError.invalidDestination
        }

        let destinationParentDescriptor = Darwin.open(
            resolvedParent.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard destinationParentDescriptor >= 0 else {
            if errno == EACCES || errno == EPERM {
                throw OriginalArchiveExportError.destinationAccessDenied
            }
            throw OriginalArchiveExportError.ioFailure(errno)
        }
        defer { Darwin.close(destinationParentDescriptor) }
        var boundParentMetadata = stat()
        guard fstat(destinationParentDescriptor, &boundParentMetadata) == 0,
              (boundParentMetadata.st_mode & S_IFMT) == S_IFDIR else {
            throw OriginalArchiveExportError.invalidDestination
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
                throw OriginalArchiveExportError.invalidDestination
            }
        } else if errno != ENOENT {
            throw OriginalArchiveExportError.ioFailure(errno)
        }

        let workParent = workURL.deletingLastPathComponent().resolvingSymlinksInPath()
        let workName = workURL.lastPathComponent
        guard isSinglePathComponent(workName) else {
            throw OriginalArchiveExportError.archiveIntegrityFailure
        }
        let workParentDescriptor = Darwin.open(
            workParent.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard workParentDescriptor >= 0 else {
            throw OriginalArchiveExportError.ioFailure(errno)
        }
        defer { Darwin.close(workParentDescriptor) }
        var workMetadata = stat()
        guard workName.withCString({
            fstatat(workParentDescriptor, $0, &workMetadata, AT_SYMLINK_NOFOLLOW)
        }) == 0,
              (workMetadata.st_mode & S_IFMT) == S_IFREG else {
            throw OriginalArchiveExportError.archiveIntegrityFailure
        }
        let workDirectoryName: String? = {
            let parent = workParent.deletingLastPathComponent().standardizedFileURL
            guard parent == resolvedParent,
                  isSinglePathComponent(workParent.lastPathComponent) else { return nil }
            return workParent.lastPathComponent
        }()

        if failureInjector?(.afterDestinationParentBinding) == true {
            throw OriginalArchiveExportError.injectedFailure
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
                throw OriginalArchiveExportError.publicationIndeterminate
            }
            throw OriginalArchiveExportError.invalidDestination
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
                throw OriginalArchiveExportError.invalidDestination
            }
            throw OriginalArchiveExportError.ioFailure(errno)
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
            throw OriginalArchiveExportError.publicationIndeterminate
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
            throw OriginalArchiveExportError.ioFailure(errno)
        }
        defer { Darwin.close(descriptor) }
        if fsync(descriptor) != 0, errno != EINVAL, errno != ENOTSUP {
            throw OriginalArchiveExportError.ioFailure(errno)
        }
    }

    static func isUnavailableParentDirectorySync(_ error: Error) -> Bool {
        guard case let OriginalArchiveExportError.ioFailure(errorCode) = error else {
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
            throw OriginalArchiveExportError.ioFailure(errno)
        }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        var header = [UInt8](repeating: 0, count: 30)
        guard fstat(descriptor, &metadata) == 0, metadata.st_size > 30,
              pread(descriptor, &header, header.count, 0) == header.count,
              header[0...3].elementsEqual([0x50, 0x4b, 0x03, 0x04]) else {
            throw OriginalArchiveExportError.ioFailure(EIO)
        }
        let filenameLength = Int(header[26]) | (Int(header[27]) << 8)
        let extraLength = Int(header[28]) | (Int(header[29]) << 8)
        let payloadOffset = 30 + filenameLength + extraLength
        guard payloadOffset < metadata.st_size else {
            throw OriginalArchiveExportError.ioFailure(EIO)
        }
        var byte: UInt8 = 0
        guard pread(descriptor, &byte, 1, off_t(payloadOffset)) == 1 else {
            throw OriginalArchiveExportError.ioFailure(EIO)
        }
        byte ^= 0xff
        guard pwrite(descriptor, &byte, 1, off_t(payloadOffset)) == 1 else {
            throw OriginalArchiveExportError.ioFailure(EIO)
        }
        try fullSyncFile(at: url)
    }

    func failIfRequested(_ fault: OriginalArchiveExporterFault) throws {
        if failureInjector?(fault) == true {
            throw OriginalArchiveExportError.injectedFailure
        }
    }
}
