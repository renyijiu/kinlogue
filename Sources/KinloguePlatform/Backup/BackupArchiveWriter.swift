import CryptoKit
import Darwin
import Foundation
import KinlogueCore
import UniformTypeIdentifiers
import ZIPFoundation

public enum BackupArchiveWriteError: Error, Equatable, Sendable {
    case capacityInsufficient
    case resourceLimit
    /// The library changed under the capture or an original no longer matched its record;
    /// a later attempt can succeed.
    case sourceChanged
    /// The library itself could not be read consistently; retrying will not help.
    case libraryUnreadable
    case invalidDestination
    case destinationAccessDenied
    case archiveIntegrityFailure
    case publicationIndeterminate
    case ioFailure(Int32)
    case injectedFailure
}

public enum BackupArchiveWritePhase: Equatable, Sendable {
    case preparing
    case writing
    case verifying
    case committing
}

public struct BackupArchiveWriteProgress: Equatable, Sendable {
    public let phase: BackupArchiveWritePhase
    public let completedByteCount: UInt64
    public let totalByteCount: UInt64
    public let completedEntryCount: Int
    public let totalEntryCount: Int
    public let isCancellable: Bool
}

/// What the App supplies for people reading the archive: folder names, the read-me and the
/// version that wrote it. None of it is needed to restore.
public struct BackupArchiveContent: Sendable {
    public let labels: BackupArchiveLabels
    public let creator: BackupArchiveIndex.Creator
    public let readmeFileName: String
    public let readmeText: String

    public init(labels: BackupArchiveLabels, creator: BackupArchiveIndex.Creator, readmeFileName: String, readmeText: String) {
        self.labels = labels
        self.creator = creator
        self.readmeFileName = readmeFileName
        self.readmeText = readmeText
    }
}

public enum BackupArchiveDestination: Sendable {
    /// A folder the caller holds access to. The archive gets a name of its own there
    /// (`<stem>.zip`, then `<stem> (2).zip` …) and never replaces an existing file.
    case folder(URL, fileNameStem: String)
    /// A file location the person chose in a save panel; a file already there is replaced.
    case file(URL)
}

public struct BackupArchiveWriteResult: Equatable, Sendable {
    public let url: URL
    public let fileName: String
    public let backupID: UUID
    public let createdAt: Date
    public let library: BackupLibraryRevision
    public let counts: BackupArchiveIndex.Counts
    /// The library data and every original, before ZIP framing.
    public let contentByteCount: UInt64
    /// The published archive file as it was right after publication.
    public let inode: UInt64
    public let byteCount: UInt64
    public let modifiedSeconds: Int64
    public let modifiedNanoseconds: Int64
}

enum BackupArchiveWriterFault: Equatable, Sendable {
    case shortSourceRead
    case beforeVerification
    case corruptWorkArchiveBeforeVerification
    case beforeFinalRevisionCheck
    case beforeCommit
    case afterDestinationParentBinding
}

struct BackupArchiveDestinationAccess: Sendable {
    enum StartResult: Sendable { case notRequired, granted, denied }
    let start: @Sendable (URL) -> StartResult
    let stop: @Sendable (URL) -> Void

    static let live = Self(
        start: { $0.startAccessingSecurityScopedResource() ? .granted : .notRequired },
        stop: { $0.stopAccessingSecurityScopedResource() }
    )
}

/// Writes one backup archive: the index, a read-me, the library's logical stream and every
/// original, captured from one commit. The archive is built in a private work file on the
/// destination volume, read back in full, and only then published.
public actor BackupArchiveWriter {
    public typealias ProgressHandler = @Sendable (BackupArchiveWriteProgress) -> Void
    static let bufferSize = 64 * 1_024
    static let stableModificationDate = Date(timeIntervalSince1970: 315_532_800)

    private let store: SQLiteLibraryStore
    private let fileManager: FileManager
    private let destinationAccess: BackupArchiveDestinationAccess
    private let parentDirectorySync: @Sendable (URL) throws -> Void
    private let failureInjector: (@Sendable (BackupArchiveWriterFault) -> Bool)?
    private let clock: @Sendable () -> Date
    private let captureObservation: (@Sendable (UInt8, Int, TimeInterval) -> Void)?

    /// `captureObservation` reports capture phases to the storage probe; the App passes nothing.
    package init(
        store: SQLiteLibraryStore,
        clock: @escaping @Sendable () -> Date = { Date() },
        captureObservation: (@Sendable (UInt8, Int, TimeInterval) -> Void)? = nil
    ) {
        self.init(store: store, fileManager: .default, clock: clock, captureObservation: captureObservation)
    }

    init(
        store: SQLiteLibraryStore,
        fileManager: FileManager,
        destinationAccess: BackupArchiveDestinationAccess = .live,
        parentDirectorySync: @escaping @Sendable (URL) throws -> Void = BackupArchiveWriter.syncDirectory,
        failureInjector: (@Sendable (BackupArchiveWriterFault) -> Bool)? = nil,
        clock: @escaping @Sendable () -> Date = { Date() },
        captureObservation: (@Sendable (UInt8, Int, TimeInterval) -> Void)? = nil
    ) {
        self.store = store
        self.fileManager = fileManager
        self.destinationAccess = destinationAccess
        self.parentDirectorySync = parentDirectorySync
        self.failureInjector = failureInjector
        self.clock = clock
        self.captureObservation = captureObservation
    }

    public func write(
        to destination: BackupArchiveDestination,
        content: BackupArchiveContent,
        progress: @escaping ProgressHandler = { _ in }
    ) async throws -> BackupArchiveWriteResult {
        try Task.checkCancellation()
        let snapshot: SQLiteLogicalBackupSnapshot
        do {
            snapshot = try await SQLiteLogicalBackupSource(store: store, captureObservation: captureObservation).prepare()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.map(error)
        }
        defer { snapshot.release() }
        let prepared: Prepared
        do {
            prepared = try Self.prepare(snapshot, content: content, createdAt: clock(), vaultRootURL: store.rootURL)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as BackupArchiveWriteError {
            throw error
        } catch {
            throw Self.map(error)
        }
        progress(prepared.progress(.preparing))

        switch destination {
        case .file(let url):
            return try await writeFile(prepared, snapshot: snapshot, to: url, progress: progress)
        case .folder(let folder, let stem):
            return try await writeIntoFolder(prepared, snapshot: snapshot, folder: folder, stem: stem, progress: progress)
        }
    }
}

// MARK: - Planning

extension BackupArchiveWriter {
    /// One archive's entries in writing order, with the index that describes them.
    struct Prepared: Sendable {
        enum Source: Sendable {
            case bytes(Data)
            case logical
            case original(UUID)
        }
        enum Compression: Sendable {
            case stored, deflate
            var method: CompressionMethod { self == .stored ? .none : .deflate }
        }
        struct Entry: Sendable {
            let path: String
            let byteCount: UInt64
            let sha256: Data
            let compression: Compression
            let source: Source
        }
        let index: BackupArchiveIndex
        let entries: [Entry]
        let vaultRootURL: URL

        var contentByteCount: UInt64 { index.totalByteCount }

        func progress(
            _ phase: BackupArchiveWritePhase, bytes: UInt64 = 0, entries completed: Int = 0, cancellable: Bool = true
        ) -> BackupArchiveWriteProgress {
            .init(phase: phase, completedByteCount: bytes, totalByteCount: contentByteCount,
                  completedEntryCount: completed, totalEntryCount: entries.count, isCancellable: cancellable)
        }
    }

    static func prepare(
        _ snapshot: SQLiteLogicalBackupSnapshot, content: BackupArchiveContent, createdAt: Date, vaultRootURL: URL
    ) throws -> Prepared {
        let readmeName = content.readmeFileName
        guard readmeName.utf8.count <= 120, !readmeName.contains("/"), BackupArchiveIndex.isSafePath(readmeName),
              ![BackupArchiveIndex.fileName, "data", BackupArchiveIndex.originalsDirectory]
                .contains(where: { $0.caseInsensitiveCompare(readmeName) == .orderedSame }) else {
            throw BackupArchiveWriteError.archiveIntegrityFailure
        }

        let spool = snapshot.spool
        var catalog = BackupArchiveCatalog()
        var members = 0, records = 0, drafts = 0, inbox = 0, studies = 0
        var dicomIDs: Set<UUID> = []
        _ = try SQLiteLogicalStream.read(byteCount: spool.byteCount, read: spool.read) { record in
            try Task.checkCancellation()
            switch record.kind {
            case .member:
                catalog.add(member: try record.decode(FamilyMember.self)); members += 1
            case .original:
                let value = try record.decode(BackupLogicalOriginalV1.self)
                catalog.originals.append(.init(id: value.id, byteCount: value.byteCount, sha256: value.sha256, contentType: value.contentType))
            case .report:
                catalog.reports.append(.init(record: try record.decode(HealthRecord.self))); records += 1
            case .draft:
                catalog.drafts.append(.init(draft: try record.decode(ImportDraft.self))); drafts += 1
            case .inbox:
                catalog.inbox.append(.init(item: try record.decode(LANInboxItem.self))); inbox += 1
            case .dicom:
                let value = try record.decode(BackupLogicalDICOMV1.self)
                let ids = value.index.retainedObjects.map(\.attachmentID)
                dicomIDs.formUnion(ids)
                catalog.studies.append(.init(id: value.index.studyID, state: value.state, memberID: value.memberID,
                                             date: value.date, attachmentIDs: ids))
                studies += 1
            case .reportDocument, .lanDocument, .terminal, .receipt, .archiveReceipt, .assistantConversation:
                break
            }
        }
        guard catalog.originals.count == snapshot.pins.originals.count,
              catalog.originals.allSatisfy({ original in
                  snapshot.pins.originals[original.id].map { $0.byteCount == original.byteCount && $0.sha256 == original.sha256 } ?? false
              }) else { throw BackupArchiveWriteError.sourceChanged }

        let extensions = Dictionary(uniqueKeysWithValues: catalog.originals.map { original in
            (original.id, dicomIDs.contains(original.id) ? "dcm" : Self.fileExtension(forContentType: original.contentType))
        })
        let plan = try BackupArchivePlan.make(catalog: catalog, preferredExtensions: extensions, labels: content.labels)

        var hasher = SHA256()
        var offset = 0
        while offset < spool.byteCount {
            try Task.checkCancellation()
            let chunk = try spool.read(offset: offset, count: min(1_024 * 1_024, spool.byteCount - offset))
            hasher.update(data: chunk)
            offset += chunk.count
        }
        let header = snapshot.header
        let index = try BackupArchiveIndex(
            backupID: UUID(),
            createdAt: createdAt,
            creator: content.creator,
            library: .init(libraryID: header.libraryID, generation: header.generation, commitID: header.commitID),
            counts: .init(members: members, records: records, drafts: drafts, inboxItems: inbox,
                          dicomStudies: studies, originals: plan.files.count),
            data: .init(path: BackupArchiveIndex.dataPath, byteCount: UInt64(spool.byteCount), sha256: Data(hasher.finalize())),
            originals: plan.files.map { file in
                try .init(
                    id: file.original.id,
                    entry: .init(path: file.path, byteCount: UInt64(file.original.byteCount), sha256: file.original.sha256),
                    contentType: file.original.contentType
                )
            }
        )
        let indexBytes = try index.encoded()
        let readmeBytes = Data(content.readmeText.utf8)
        var entries: [Prepared.Entry] = [
            .init(path: BackupArchiveIndex.fileName, byteCount: UInt64(indexBytes.count),
                  sha256: Data(SHA256.hash(data: indexBytes)), compression: .deflate, source: .bytes(indexBytes)),
            .init(path: readmeName, byteCount: UInt64(readmeBytes.count),
                  sha256: Data(SHA256.hash(data: readmeBytes)), compression: .deflate, source: .bytes(readmeBytes)),
            .init(path: index.data.path, byteCount: index.data.byteCount, sha256: index.data.sha256,
                  compression: .deflate, source: .logical),
        ]
        // Originals are mostly PDFs and images, compressed already; storing keeps writes fast
        // and the space needed exact.
        entries += index.originals.map {
            .init(path: $0.entry.path, byteCount: $0.entry.byteCount, sha256: $0.entry.sha256, compression: .stored, source: .original($0.id))
        }
        return Prepared(index: index, entries: entries, vaultRootURL: vaultRootURL)
    }

    static func fileExtension(forContentType identifier: String) -> String {
        let value = UTType(identifier)?.preferredFilenameExtension?.lowercased() ?? ""
        let isSafe = !value.isEmpty && value.utf8.count <= 16 && value.utf8.allSatisfy { byte in
            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
        }
        return isSafe ? value : "bin"
    }

    static func map(_ error: Error) -> BackupArchiveWriteError {
        if let error = error as? BackupArchiveWriteError { return error }
        if case SQLiteLibraryError.ioFailure(ENOSPC) = error { return .capacityInsufficient }
        if let error = error as? SQLiteLogicalBackupError {
            switch error {
            case .capacityInsufficient: return .capacityInsufficient
            case .resourceLimit: return .resourceLimit
            case .sourceChanged, .captureTimedOut, .released: return .sourceChanged
            case .invalidStream, .unsupportedVersion: return .libraryUnreadable
            }
        }
        if let error = error as? BackupArchiveError {
            return error == .resourceLimit ? .resourceLimit : .libraryUnreadable
        }
        if error is SQLiteLibraryError { return .libraryUnreadable }
        return .libraryUnreadable
    }
}

// MARK: - Destinations

private extension BackupArchiveWriter {
    func writeFile(
        _ prepared: Prepared, snapshot: SQLiteLogicalBackupSnapshot, to selected: URL, progress: @escaping ProgressHandler
    ) async throws -> BackupArchiveWriteResult {
        let candidate = try Self.normalizedFileDestination(selected, vaultRootURL: prepared.vaultRootURL)
        let access = destinationAccess.start(candidate)
        guard access != .denied else { throw BackupArchiveWriteError.destinationAccessDenied }
        defer { if access == .granted { destinationAccess.stop(candidate) } }
        let destination = try Self.validatedFileDestination(candidate, vaultRootURL: prepared.vaultRootURL)
        var initial = stat()
        let existed = lstat(destination.path, &initial) == 0

        let replacementDirectory = try makeReplacementDirectory(for: destination)
        defer { try? fileManager.removeItem(at: replacementDirectory) }
        try removeReplacementPlaceholderIfCreated(at: destination, destinationInitiallyExisted: existed)
        let workURL = replacementDirectory.appendingPathComponent(UUID().uuidString)
        try buildAndVerify(prepared, snapshot: snapshot, workURL: workURL, capacityDirectory: replacementDirectory, progress: progress)
        do {
            try publishReplacing(workURL, to: destination, vaultRootURL: prepared.vaultRootURL,
                                 coordinateAccess: access == .granted, destinationInitiallyExisted: existed)
            try syncParentAfterPublication(of: destination)
        } catch let error as BackupArchiveWriteError {
            throw error
        } catch {
            throw BackupArchiveWriteError.publicationIndeterminate
        }
        var published = stat()
        let found = lstat(destination.path, &published) == 0
        return result(prepared, url: destination, metadata: found ? published : nil)
    }

    func writeIntoFolder(
        _ prepared: Prepared, snapshot: SQLiteLogicalBackupSnapshot, folder: URL, stem: String,
        progress: @escaping ProgressHandler
    ) async throws -> BackupArchiveWriteResult {
        guard Self.isSinglePathComponent(stem), stem.utf8.count <= 200, !stem.hasPrefix(".") else {
            throw BackupArchiveWriteError.invalidDestination
        }
        let folder = try Self.validatedFolder(folder, vaultRootURL: prepared.vaultRootURL)
        let replacementDirectory = try makeReplacementDirectory(for: folder.appendingPathComponent(stem + ".zip"))
        defer { try? fileManager.removeItem(at: replacementDirectory) }
        let workURL = replacementDirectory.appendingPathComponent(UUID().uuidString)
        try buildAndVerify(prepared, snapshot: snapshot, workURL: workURL, capacityDirectory: replacementDirectory, progress: progress)
        let published: (name: String, metadata: stat)
        do {
            published = try Self.publishExclusive(workURL, into: folder, stem: stem, failureInjector: failureInjector)
            try syncParentAfterPublication(of: folder.appendingPathComponent(published.name))
        } catch let error as BackupArchiveWriteError {
            throw error
        } catch {
            throw BackupArchiveWriteError.publicationIndeterminate
        }
        return result(prepared, url: folder.appendingPathComponent(published.name), metadata: published.metadata)
    }

    func buildAndVerify(
        _ prepared: Prepared, snapshot: SQLiteLogicalBackupSnapshot, workURL: URL, capacityDirectory: URL,
        progress: @escaping ProgressHandler
    ) throws {
        try checkCapacity(prepared, at: capacityDirectory)
        do {
            try writeArchive(prepared, snapshot: snapshot, to: workURL, progress: progress)
            try fullSyncFile(at: workURL)
            try failIfRequested(.beforeVerification)
            if failureInjector?(.corruptWorkArchiveBeforeVerification) == true { try corruptFirstPayload(in: workURL) }
            progress(prepared.progress(.verifying, bytes: prepared.contentByteCount, entries: prepared.entries.count))
            try Self.verify(workURL, against: prepared.entries)
            try failIfRequested(.beforeFinalRevisionCheck)
            try snapshot.validate()
            try Task.checkCancellation()
            try failIfRequested(.beforeCommit)
        } catch let error as BackupArchiveWriteError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SQLiteLogicalBackupError {
            throw Self.map(error)
        } catch {
            throw BackupArchiveWriteError.archiveIntegrityFailure
        }
        progress(prepared.progress(.committing, bytes: prepared.contentByteCount, entries: prepared.entries.count, cancellable: false))
    }

    func result(_ prepared: Prepared, url: URL, metadata: stat?) -> BackupArchiveWriteResult {
        let index = prepared.index
        return BackupArchiveWriteResult(
            url: url,
            fileName: url.lastPathComponent,
            backupID: index.backupID,
            createdAt: index.createdAt,
            library: index.library,
            counts: index.counts,
            contentByteCount: prepared.contentByteCount,
            inode: metadata.map { UInt64($0.st_ino) } ?? 0,
            byteCount: metadata.map { UInt64(max(0, $0.st_size)) } ?? 0,
            modifiedSeconds: metadata.map { Int64($0.st_mtimespec.tv_sec) } ?? 0,
            modifiedNanoseconds: metadata.map { Int64($0.st_mtimespec.tv_nsec) } ?? 0
        )
    }

    func syncParentAfterPublication(of destination: URL) throws {
        do {
            try parentDirectorySync(destination.deletingLastPathComponent())
        } catch {
            guard Self.isUnavailableDirectorySync(error) else { throw BackupArchiveWriteError.publicationIndeterminate }
        }
    }
}

// MARK: - Writing and reading back

private extension BackupArchiveWriter {
    /// Runs off the actor: ZIPFoundation pulls each chunk through a synchronous provider.
    nonisolated func writeArchive(
        _ prepared: Prepared, snapshot: SQLiteLogicalBackupSnapshot, to url: URL, progress: @escaping ProgressHandler
    ) throws {
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .create, pathEncoding: nil)
        } catch {
            throw BackupArchiveWriteError.ioFailure(EIO)
        }
        try setPermissions(0o600, at: url)
        var completedBytes: UInt64 = 0
        for (offset, entry) in prepared.entries.enumerated() {
            try Task.checkCancellation()
            let reader: @Sendable (UInt64, Int) throws -> Data
            var close: () -> Void = {}
            var onMismatch: () -> Void = {}
            switch entry.source {
            case .bytes(let data):
                reader = { position, count in data.subdata(in: Int(position)..<(Int(position) + count)) }
            case .logical:
                let spool = snapshot.spool
                reader = { position, count in try spool.read(offset: Int(position), count: count) }
            case .original(let id):
                let opened = try snapshot.pins.open(id)
                reader = { position, count in try opened.read(offset: position, maximumByteCount: count) }
                close = { opened.close() }
                onMismatch = { opened.reportDigestMismatch() }
            }
            defer { close() }
            var expected: UInt64 = 0
            var hasher = SHA256()
            try archive.addEntry(
                with: entry.path,
                type: .file,
                uncompressedSize: Int64(entry.byteCount),
                modificationDate: Self.stableModificationDate,
                permissions: 0o600,
                compressionMethod: entry.compression.method,
                bufferSize: Self.bufferSize
            ) { position, requested in
                try Task.checkCancellation()
                guard position == Int64(expected), requested > 0, UInt64(requested) <= entry.byteCount - expected else {
                    throw BackupArchiveWriteError.sourceChanged
                }
                if self.failureInjector?(.shortSourceRead) == true { throw BackupArchiveWriteError.sourceChanged }
                let data = try reader(expected, requested)
                guard data.count == requested else { throw BackupArchiveWriteError.sourceChanged }
                hasher.update(data: data)
                expected += UInt64(data.count)
                if case .bytes = entry.source {} else {
                    completedBytes += UInt64(data.count)
                    progress(prepared.progress(.writing, bytes: completedBytes, entries: offset))
                }
                return data
            }
            guard expected == entry.byteCount else { throw BackupArchiveWriteError.sourceChanged }
            guard Data(hasher.finalize()) == entry.sha256 else {
                onMismatch()
                throw BackupArchiveWriteError.sourceChanged
            }
            progress(prepared.progress(.writing, bytes: completedBytes, entries: offset + 1))
        }
    }

    /// Reopens the finished file and checks every entry, in order, against the plan.
    static func verify(_ url: URL, against planned: [Prepared.Entry]) throws {
        try Task.checkCancellation()
        let archive = try Archive(url: url, accessMode: .read)
        let stored = archive.makeIterator()
        for expected in planned {
            try Task.checkCancellation()
            guard let entry = stored.next(), entry.type == .file, entry.path == expected.path,
                  entry.uncompressedSize == expected.byteCount else {
                throw BackupArchiveWriteError.archiveIntegrityFailure
            }
            var count: UInt64 = 0
            var hasher = SHA256()
            let crc = try archive.extract(entry, bufferSize: bufferSize) { data in
                try Task.checkCancellation()
                count += UInt64(data.count)
                guard count <= expected.byteCount else { throw BackupArchiveWriteError.archiveIntegrityFailure }
                hasher.update(data: data)
            }
            guard count == expected.byteCount, crc == entry.checksum, Data(hasher.finalize()) == expected.sha256 else {
                throw BackupArchiveWriteError.archiveIntegrityFailure
            }
        }
        guard stored.next() == nil else { throw BackupArchiveWriteError.archiveIntegrityFailure }
    }

    func checkCapacity(_ prepared: Prepared, at directory: URL) throws {
        let overhead = UInt64(max(1_024 * 1_024, prepared.entries.count * 1_024))
        let required = prepared.contentByteCount.addingReportingOverflow(overhead + BackupArchiveLimits.capacityHeadroomByteCount)
        guard !required.overflow else { throw BackupArchiveWriteError.capacityInsufficient }
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = values?.volumeAvailableCapacityForImportantUsage, available > 0,
           UInt64(available) < required.partialValue {
            throw BackupArchiveWriteError.capacityInsufficient
        }
    }

    func makeReplacementDirectory(for destination: URL) throws -> URL {
        let directory: URL
        do {
            directory = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true)
        } catch {
            throw BackupArchiveWriteError.invalidDestination
        }
        try setPermissions(0o700, at: directory)
        return directory
    }

    func removeReplacementPlaceholderIfCreated(at destination: URL, destinationInitiallyExisted: Bool) throws {
        guard !destinationInitiallyExisted else { return }
        var metadata = stat()
        if lstat(destination.path, &metadata) == 0 {
            guard (metadata.st_mode & S_IFMT) == S_IFREG, metadata.st_size == 0 else {
                throw BackupArchiveWriteError.invalidDestination
            }
            try fileManager.removeItem(at: destination)
        } else if errno != ENOENT {
            throw BackupArchiveWriteError.ioFailure(errno)
        }
    }

    nonisolated func setPermissions(_ permissions: mode_t, at url: URL) throws {
        if chmod(url.path, permissions) != 0, errno != ENOTSUP, errno != EOPNOTSUPP {
            throw BackupArchiveWriteError.ioFailure(errno)
        }
    }

    func fullSyncFile(at url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw BackupArchiveWriteError.ioFailure(errno) }
        defer { Darwin.close(descriptor) }
        if fcntl(descriptor, F_FULLFSYNC) != 0, fsync(descriptor) != 0 {
            throw BackupArchiveWriteError.ioFailure(errno)
        }
    }

    func corruptFirstPayload(in url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw BackupArchiveWriteError.ioFailure(errno) }
        defer { Darwin.close(descriptor) }
        var header = [UInt8](repeating: 0, count: 30)
        guard pread(descriptor, &header, header.count, 0) == header.count,
              header[0...3].elementsEqual([0x50, 0x4b, 0x03, 0x04]) else { throw BackupArchiveWriteError.ioFailure(EIO) }
        let offset = 30 + (Int(header[26]) | Int(header[27]) << 8) + (Int(header[28]) | Int(header[29]) << 8)
        var byte: UInt8 = 0
        guard pread(descriptor, &byte, 1, off_t(offset)) == 1 else { throw BackupArchiveWriteError.ioFailure(EIO) }
        byte ^= 0xff
        guard pwrite(descriptor, &byte, 1, off_t(offset)) == 1 else { throw BackupArchiveWriteError.ioFailure(EIO) }
        try fullSyncFile(at: url)
    }

    func failIfRequested(_ fault: BackupArchiveWriterFault) throws {
        if failureInjector?(fault) == true { throw BackupArchiveWriteError.injectedFailure }
    }
}

// MARK: - Publication

extension BackupArchiveWriter {
    static func normalizedFileDestination(_ url: URL, vaultRootURL: URL) throws -> URL {
        let destination = url.standardizedFileURL
        guard destination.isFileURL, destination.pathExtension.lowercased() == "zip",
              isSinglePathComponent(destination.lastPathComponent) else {
            throw BackupArchiveWriteError.invalidDestination
        }
        try requireOutsideVault(destination, vaultRootURL: vaultRootURL)
        return destination
    }

    static func validatedFileDestination(_ destination: URL, vaultRootURL: URL) throws -> URL {
        var parent = stat()
        guard stat(destination.deletingLastPathComponent().path, &parent) == 0, (parent.st_mode & S_IFMT) == S_IFDIR else {
            throw BackupArchiveWriteError.invalidDestination
        }
        let resolved = destination.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
            .appendingPathComponent(destination.lastPathComponent)
        try requireOutsideVault(resolved, vaultRootURL: vaultRootURL)
        var target = stat()
        if lstat(destination.path, &target) == 0 {
            guard (target.st_mode & S_IFMT) == S_IFREG else { throw BackupArchiveWriteError.invalidDestination }
        } else if errno != ENOENT {
            throw BackupArchiveWriteError.ioFailure(errno)
        }
        return destination
    }

    static func validatedFolder(_ url: URL, vaultRootURL: URL) throws -> URL {
        let folder = url.standardizedFileURL
        var metadata = stat()
        guard folder.isFileURL, lstat(folder.path, &metadata) == 0 else {
            throw BackupArchiveWriteError.invalidDestination
        }
        guard (metadata.st_mode & S_IFMT) == S_IFDIR else { throw BackupArchiveWriteError.invalidDestination }
        let resolved = folder.resolvingSymlinksInPath().standardizedFileURL
        try requireOutsideVault(resolved, vaultRootURL: vaultRootURL)
        let vault = vaultRootURL.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard !vault.starts(with: resolved.pathComponents) else { throw BackupArchiveWriteError.invalidDestination }
        return folder
    }

    static func requireOutsideVault(_ url: URL, vaultRootURL: URL) throws {
        let vault = vaultRootURL.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let candidate = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard !candidate.starts(with: vault) else { throw BackupArchiveWriteError.invalidDestination }
    }

    /// Moves the finished work file into the folder under the first free name. `RENAME_EXCL`
    /// makes the name check and the move one step, so an existing file is never replaced.
    static func publishExclusive(
        _ workURL: URL, into folder: URL, stem: String,
        failureInjector: (@Sendable (BackupArchiveWriterFault) -> Bool)?
    ) throws -> (name: String, metadata: stat) {
        let folderDescriptor = Darwin.open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folderDescriptor >= 0 else {
            if errno == EACCES || errno == EPERM { throw BackupArchiveWriteError.destinationAccessDenied }
            throw BackupArchiveWriteError.ioFailure(errno)
        }
        defer { Darwin.close(folderDescriptor) }
        let workName = workURL.lastPathComponent
        let workParent = Darwin.open(workURL.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard workParent >= 0, isSinglePathComponent(workName) else {
            if workParent >= 0 { Darwin.close(workParent) }
            throw BackupArchiveWriteError.archiveIntegrityFailure
        }
        defer { Darwin.close(workParent) }
        var work = stat()
        guard fstatat(workParent, workName, &work, AT_SYMLINK_NOFOLLOW) == 0, (work.st_mode & S_IFMT) == S_IFREG else {
            throw BackupArchiveWriteError.archiveIntegrityFailure
        }
        if failureInjector?(.afterDestinationParentBinding) == true { throw BackupArchiveWriteError.injectedFailure }
        for ordinal in 1...999 {
            let name = ordinal == 1 ? "\(stem).zip" : "\(stem) (\(ordinal)).zip"
            if renameatx_np(workParent, workName, folderDescriptor, name, UInt32(RENAME_EXCL)) == 0 {
                var published = stat()
                guard fstatat(folderDescriptor, name, &published, AT_SYMLINK_NOFOLLOW) == 0, sameIdentity(work, published) else {
                    throw BackupArchiveWriteError.publicationIndeterminate
                }
                return (name, published)
            }
            guard errno == EEXIST else {
                if errno == EACCES || errno == EPERM { throw BackupArchiveWriteError.destinationAccessDenied }
                throw BackupArchiveWriteError.ioFailure(errno)
            }
        }
        throw BackupArchiveWriteError.invalidDestination
    }

    func publishReplacing(
        _ workURL: URL, to destination: URL, vaultRootURL: URL, coordinateAccess: Bool, destinationInitiallyExisted: Bool
    ) throws {
        // Unsandboxed tests do not own a Powerbox coordination purpose and NSFileCoordinator
        // rejects their temporary URLs; save-panel destinations use the coordinated URL.
        guard coordinateAccess else {
            try Self.publishBound(workURL, to: destination, vaultRootURL: vaultRootURL,
                                  destinationInitiallyExisted: destinationInitiallyExisted, failureInjector: failureInjector)
            return
        }
        let fileManager = fileManager
        var coordinationError: NSError?
        var outcome: Result<Void, Error>?
        NSFileCoordinator().coordinate(
            writingItemAt: workURL, options: .forMoving,
            writingItemAt: destination, options: .forReplacing,
            error: &coordinationError
        ) { coordinatedWork, coordinatedDestination in
            outcome = Result {
                _ = try Self.validatedFileDestination(coordinatedDestination, vaultRootURL: vaultRootURL)
                var metadata = stat()
                if lstat(coordinatedDestination.path, &metadata) == 0 {
                    guard (metadata.st_mode & S_IFMT) == S_IFREG else { throw BackupArchiveWriteError.invalidDestination }
                    _ = try fileManager.replaceItemAt(coordinatedDestination, withItemAt: coordinatedWork,
                                                      backupItemName: nil, options: [.usingNewMetadataOnly])
                } else if errno == ENOENT {
                    try fileManager.moveItem(at: coordinatedWork, to: coordinatedDestination)
                } else {
                    throw BackupArchiveWriteError.ioFailure(errno)
                }
            }
        }
        if let coordinationError { throw BackupArchiveWriteError.ioFailure(Int32(clamping: coordinationError.code)) }
        guard let outcome else { throw BackupArchiveWriteError.ioFailure(EIO) }
        try outcome.get()
    }

    static func publishBound(
        _ workURL: URL, to destination: URL, vaultRootURL: URL, destinationInitiallyExisted: Bool,
        failureInjector: (@Sendable (BackupArchiveWriterFault) -> Bool)?
    ) throws {
        let parent = destination.deletingLastPathComponent()
        let resolvedParent = parent.resolvingSymlinksInPath().standardizedFileURL
        let name = destination.lastPathComponent
        guard isSinglePathComponent(name) else { throw BackupArchiveWriteError.invalidDestination }
        try requireOutsideVault(resolvedParent.appendingPathComponent(name), vaultRootURL: vaultRootURL)
        let parentDescriptor = Darwin.open(resolvedParent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentDescriptor >= 0 else {
            if errno == EACCES || errno == EPERM { throw BackupArchiveWriteError.destinationAccessDenied }
            throw BackupArchiveWriteError.ioFailure(errno)
        }
        defer { Darwin.close(parentDescriptor) }
        var boundParent = stat()
        guard fstat(parentDescriptor, &boundParent) == 0, (boundParent.st_mode & S_IFMT) == S_IFDIR else {
            throw BackupArchiveWriteError.invalidDestination
        }
        var target = stat()
        let targetStatus = fstatat(parentDescriptor, name, &target, AT_SYMLINK_NOFOLLOW)
        if targetStatus == 0 {
            guard (target.st_mode & S_IFMT) == S_IFREG else { throw BackupArchiveWriteError.invalidDestination }
        } else if errno != ENOENT {
            throw BackupArchiveWriteError.ioFailure(errno)
        }
        let workParentURL = workURL.deletingLastPathComponent().resolvingSymlinksInPath()
        let workName = workURL.lastPathComponent
        guard isSinglePathComponent(workName) else { throw BackupArchiveWriteError.archiveIntegrityFailure }
        let workParent = Darwin.open(workParentURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard workParent >= 0 else { throw BackupArchiveWriteError.ioFailure(errno) }
        defer { Darwin.close(workParent) }
        var work = stat()
        guard fstatat(workParent, workName, &work, AT_SYMLINK_NOFOLLOW) == 0, (work.st_mode & S_IFMT) == S_IFREG else {
            throw BackupArchiveWriteError.archiveIntegrityFailure
        }
        if failureInjector?(.afterDestinationParentBinding) == true { throw BackupArchiveWriteError.injectedFailure }
        var currentParent = stat()
        if stat(parent.path, &currentParent) != 0 || !sameIdentity(boundParent, currentParent) {
            let removedWork = removeBoundRegularFile(descriptor: workParent, name: workName, expected: work)
            let removedPlaceholder = destinationInitiallyExisted || targetStatus != 0
                || removeBoundRegularFile(descriptor: parentDescriptor, name: name, expected: target)
            guard removedWork, removedPlaceholder else { throw BackupArchiveWriteError.publicationIndeterminate }
            throw BackupArchiveWriteError.invalidDestination
        }
        guard renameat(workParent, workName, parentDescriptor, name) == 0 else {
            if errno == EISDIR || errno == ENOTDIR || errno == ELOOP { throw BackupArchiveWriteError.invalidDestination }
            throw BackupArchiveWriteError.ioFailure(errno)
        }
        var published = stat()
        guard fstatat(parentDescriptor, name, &published, AT_SYMLINK_NOFOLLOW) == 0, sameIdentity(work, published) else {
            throw BackupArchiveWriteError.publicationIndeterminate
        }
    }

    static func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && (lhs.st_mode & S_IFMT) == (rhs.st_mode & S_IFMT)
    }

    static func removeBoundRegularFile(descriptor: Int32, name: String, expected: stat) -> Bool {
        var current = stat()
        guard fstatat(descriptor, name, &current, AT_SYMLINK_NOFOLLOW) == 0 else { return errno == ENOENT }
        guard (current.st_mode & S_IFMT) == S_IFREG, sameIdentity(current, expected) else { return false }
        return unlinkat(descriptor, name, 0) == 0 || errno == ENOENT
    }

    static func isSinglePathComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.utf8.contains(0)
    }

    static func syncDirectory(_ directory: URL) throws {
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw BackupArchiveWriteError.ioFailure(errno) }
        defer { Darwin.close(descriptor) }
        if fsync(descriptor) != 0, errno != EINVAL, errno != ENOTSUP {
            throw BackupArchiveWriteError.ioFailure(errno)
        }
    }

    /// A save panel grants the chosen file, not always its folder, and some volumes cannot sync
    /// a directory. The archive itself was synced, verified and published before this step.
    static func isUnavailableDirectorySync(_ error: Error) -> Bool {
        guard case let BackupArchiveWriteError.ioFailure(code) = error else { return false }
        return [EACCES, EPERM, EINVAL, ENOTSUP, EOPNOTSUPP].contains(code)
    }
}
