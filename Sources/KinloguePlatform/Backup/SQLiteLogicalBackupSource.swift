import CryptoKit
import Darwin
import Foundation
import GRDB
import KinlogueCore

package enum SQLiteLogicalBackupError: Error, Equatable, Sendable {
    case invalidStream, unsupportedVersion, resourceLimit, capacityInsufficient, captureTimedOut, sourceChanged, released
}

struct SQLiteLogicalRecord: Sendable {
    let kind: BackupLogicalKind
    let key: Data
    let payload: Data
    var id: UUID { get throws { guard let id = UUID(sqliteBytes: key) else { throw SQLiteLogicalBackupError.invalidStream }; return id } }
    init(kind: BackupLogicalKind, id: UUID, payload: Data) { self.kind = kind; key = id.sqliteBytes; self.payload = payload }
    init(kind: BackupLogicalKind, key: Data, payload: Data) { self.kind = kind; self.key = key; self.payload = payload }
    func decode<T: Decodable>(_ type: T.Type) throws -> T { try CanonicalVaultJSON.decode(type, from: payload) }
}

// SAFETY: its lock protects the descriptor, length and sealing state; reads use pread.
final class SQLiteLogicalSpool: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32
    private(set) var byteCount = 0
    private var sealed = false
    private let maximumByteCount: Int
    init(parent: URL, maximumByteCount: Int = Int(BackupFormatLimits.maximumPlaintextByteCount)) throws {
        self.maximumByteCount = maximumByteCount
        let identity = try SQLiteFileIdentity.directory(at: parent, privateMode: false)
        let directory = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw SQLiteLibraryError.invalidPath }
        defer { close(directory) }
        let name = ".kinlogue-logical-\(UUID().uuidString.lowercased()).spool"
        let fd = openat(directory, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SQLiteLibraryError.ioFailure(errno) }
        var created = stat()
        guard fstat(fd, &created) == 0 else { let error = errno; close(fd); throw SQLiteLibraryError.ioFailure(error) }
        func removeOwnedName() throws {
            var named = stat()
            guard fstatat(directory, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  named.st_dev == created.st_dev, named.st_ino == created.st_ino else { throw SQLiteLibraryError.invalidPath }
            guard unlinkat(directory, name, 0) == 0 else { throw SQLiteLibraryError.ioFailure(errno) }
        }
        do {
            var parentFD = stat()
            guard fstat(directory, &parentFD) == 0,
                  UInt64(parentFD.st_dev) == identity.device, UInt64(parentFD.st_ino) == identity.inode else { throw SQLiteLibraryError.invalidPath }
            _ = try SQLiteFileIdentity.regular(descriptor: fd)
            guard try SQLiteFileIdentity.directory(at: parent, privateMode: false) == identity else { throw SQLiteLibraryError.invalidPath }
            try removeOwnedName()
        } catch { try? removeOwnedName(); close(fd); throw error }
        descriptor = fd
    }
    func append(_ data: Data) throws {
        try lock.withLock {
            guard data.count <= maximumByteCount - byteCount else { throw SQLiteLogicalBackupError.resourceLimit }
            guard descriptor >= 0, !sealed, data.count <= Int.max - byteCount else { throw SQLiteLogicalBackupError.released }
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    try Task.checkCancellation()
                    let count = pwrite(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, off_t(byteCount + offset))
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw SQLiteLibraryError.ioFailure(errno) }; offset += count
                }
            }
            byteCount += data.count
        }
    }
    func seal() throws {
        try lock.withLock {
            guard descriptor >= 0, !sealed else { throw SQLiteLogicalBackupError.sourceChanged }
            sealed = true
        }
    }
    func read(offset: Int, count: Int) throws -> Data {
        try lock.withLock {
            guard descriptor >= 0, offset >= 0, count >= 0, count <= 32 * 1_024 * 1_024 + 2_048,
                  offset <= byteCount, count <= byteCount - offset else { throw SQLiteLogicalBackupError.invalidStream }
            var data = Data(count: count)
            try data.withUnsafeMutableBytes { bytes in
                var done = 0
                while done < count {
                    try Task.checkCancellation()
                    let result = pread(descriptor, bytes.baseAddress!.advanced(by: done), count - done, off_t(offset + done))
                    if result < 0, errno == EINTR { continue }
                    guard result > 0 else { throw SQLiteLogicalBackupError.sourceChanged }; done += result
                }
            }
            return data
        }
    }
    func validate() throws {
        try lock.withLock {
            var value = stat()
            guard descriptor >= 0, sealed, fstat(descriptor, &value) == 0,
                  value.st_mode & S_IFMT == S_IFREG, value.st_uid == geteuid(), value.st_nlink == 0,
                  value.st_mode & 0o7777 == 0o600, value.st_size == byteCount else { throw SQLiteLogicalBackupError.sourceChanged }
        }
    }
    func release() { lock.withLock { if descriptor >= 0 { close(descriptor); descriptor = -1 } } }
    deinit { release() }
}

struct SQLiteLogicalFileToken: Equatable, Sendable {
    let identity: SQLiteFileIdentity
    let byteCount: Int64
    let modifiedSeconds: Int, modifiedNanos: Int, changedSeconds: Int, changedNanos: Int
    init(_ fd: Int32, original: SQLiteOriginal) throws {
        identity = try SQLiteFileIdentity.regular(descriptor: fd)
        var value = stat()
        guard fstat(fd, &value) == 0, identity == original.identity, value.st_size == original.byteCount else { throw SQLiteLogicalBackupError.sourceChanged }
        byteCount = value.st_size; modifiedSeconds = value.st_mtimespec.tv_sec; modifiedNanos = value.st_mtimespec.tv_nsec
        changedSeconds = value.st_ctimespec.tv_sec; changedNanos = value.st_ctimespec.tv_nsec
    }
}

// SAFETY: lock serializes pin lifetime and read tokens; the kernel owns admission and pin counters.
final class SQLiteLogicalOriginalPins: @unchecked Sendable {
    private let lock = NSLock()
    private var store: SQLiteLibraryStore?
    let epoch: UUID
    let originals: [UUID: SQLiteOriginal]
    private var tokens: [UUID: SQLiteLogicalFileToken] = [:]
    private var openReaders = 0
    private var maximumOpenReaders = 0
    var maximumSimultaneousOpenFileCount: Int { lock.withLock { maximumOpenReaders } }
    // Caller holds store.admission in the same transaction that selected this metadata.
    init(store: SQLiteLibraryStore, originals: [UUID: SQLiteOriginal]) {
        self.store = store; self.originals = originals; epoch = store.openEpoch
        for id in originals.keys { store.pins[id, default: 0] += 1 }
    }
    func open(_ id: UUID) throws -> SQLiteLogicalOriginalReader {
        try lock.withLock {
            guard let store, let original = originals[id] else { throw SQLiteLogicalBackupError.released }
            try store.admission.withLock {
                try store.validateRoot()
                guard store.openEpoch == epoch else { throw SQLiteLibraryError.staleRoot }
            }
            let fd = Darwin.open(store.originalsURL.appendingPathComponent(id.uuidString.lowercased() + ".data").path,
                O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else {
                store.noteOriginalIntegrityFailure(original, epoch: epoch)
                throw SQLiteLogicalBackupError.sourceChanged
            }
            do {
                let token = try SQLiteLogicalFileToken(fd, original: original)
                if let previous = tokens[id], previous != token { throw SQLiteLogicalBackupError.sourceChanged }
                tokens[id] = token
                openReaders += 1; maximumOpenReaders = max(maximumOpenReaders, openReaders)
                return SQLiteLogicalOriginalReader(descriptor: fd, original: original, token: token, store: store, epoch: epoch,
                    onClose: { [self] in lock.withLock { openReaders -= 1 } })
            } catch {
                Darwin.close(fd)
                if error as? SQLiteLogicalBackupError == .sourceChanged || error as? SQLiteLibraryError == .invalidPath {
                    store.noteOriginalIntegrityFailure(original, epoch: epoch)
                }
                throw error
            }
        }
    }
    func validate() throws {
        try lock.withLock {
            guard let store else { throw SQLiteLogicalBackupError.released }
            try store.admission.withLock {
                try store.validateRoot()
                guard store.openEpoch == epoch else { throw SQLiteLibraryError.staleRoot }
            }
            for (id, token) in tokens {
                try Task.checkCancellation()
                guard let original = originals[id] else { throw SQLiteLogicalBackupError.sourceChanged }
                let fd = Darwin.open(store.originalsURL.appendingPathComponent(id.uuidString.lowercased() + ".data").path,
                    O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard fd >= 0 else {
                    store.noteOriginalIntegrityFailure(original, epoch: epoch)
                    throw SQLiteLogicalBackupError.sourceChanged
                }
                defer { Darwin.close(fd) }
                do {
                    guard try SQLiteLogicalFileToken(fd, original: original) == token else { throw SQLiteLogicalBackupError.sourceChanged }
                } catch {
                    store.noteOriginalIntegrityFailure(original, epoch: epoch)
                    throw error
                }
            }
        }
    }
    func release() {
        let value = lock.withLock { () -> SQLiteLibraryStore? in let value = store; store = nil; return value }
        if let value { value.releasePins(Set(originals.keys)) }
    }
    deinit { release() }
}

// SAFETY: lock serializes descriptor reads and close; no caller receives the raw descriptor.
final class SQLiteLogicalOriginalReader: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32
    private let original: SQLiteOriginal, token: SQLiteLogicalFileToken, store: SQLiteLibraryStore, epoch: UUID
    private let onClose: @Sendable () -> Void
    init(descriptor: Int32, original: SQLiteOriginal, token: SQLiteLogicalFileToken, store: SQLiteLibraryStore, epoch: UUID, onClose: @escaping @Sendable () -> Void) {
        self.descriptor = descriptor; self.original = original; self.token = token; self.store = store; self.epoch = epoch; self.onClose = onClose
    }
    func read(offset: UInt64, maximumByteCount: Int) throws -> Data {
        try lock.withLock {
            try Task.checkCancellation()
            guard descriptor >= 0, offset <= UInt64(original.byteCount), maximumByteCount > 0,
                  maximumByteCount <= BackupFormatLimits.maximumFramePlaintextByteCount else { throw SQLiteLogicalBackupError.sourceChanged }
            try store.admission.withLock {
                try store.validateRoot()
                guard store.openEpoch == epoch else { throw SQLiteLibraryError.staleRoot }
            }
            do {
                guard try SQLiteLogicalFileToken(descriptor, original: original) == token else { throw SQLiteLogicalBackupError.sourceChanged }
                let count = min(maximumByteCount, original.byteCount - Int(offset))
                var data = Data(count: count)
                try data.withUnsafeMutableBytes { bytes in
                    var done = 0
                    while done < count {
                        try Task.checkCancellation()
                        let actual = pread(descriptor, bytes.baseAddress!.advanced(by: done), count - done, off_t(offset) + off_t(done))
                        if actual < 0, errno == EINTR { continue }
                        guard actual > 0 else { throw SQLiteLogicalBackupError.sourceChanged }
                        store.originalReadMetrics.add(actual)
                        done += actual
                    }
                }
                guard try SQLiteLogicalFileToken(descriptor, original: original) == token else { throw SQLiteLogicalBackupError.sourceChanged }
                return data
            } catch {
                if error as? SQLiteLogicalBackupError == .sourceChanged || error as? SQLiteLibraryError == .invalidPath {
                    store.noteOriginalIntegrityFailure(original, epoch: epoch)
                }
                throw error
            }
        }
    }
    func reportDigestMismatch() { store.noteOriginalIntegrityFailure(original, epoch: epoch) }
    func close() {
        let closed = lock.withLock { () -> Bool in
            guard descriptor >= 0 else { return false }; Darwin.close(descriptor); descriptor = -1; return true
        }
        if closed { onClose() }
    }
    deinit { close() }
}

package final class SQLiteLogicalBackupSnapshot: Sendable {
    package let revisionPair: BackupRevisionPair
    package let captureDuration: TimeInterval
    let spool: SQLiteLogicalSpool
    let pins: SQLiteLogicalOriginalPins
    let header: BackupLogicalHeaderV1
    let segments: [(offset: Int, count: Int, digest: Data)]
    package var logicalByteCount: Int { spool.byteCount }
    package var entryCount: Int { segments.count + pins.originals.count }
    package var totalPlaintextByteCount: UInt64 { UInt64(spool.byteCount) + pins.originals.values.reduce(0) { $0 + UInt64($1.byteCount) } }
    package var maximumContainerByteCount: UInt64 { get throws { try manifest().maximumContainerByteCount } }
    init(header: BackupLogicalHeaderV1, spool: SQLiteLogicalSpool, pins: SQLiteLogicalOriginalPins, captureDuration: TimeInterval) throws {
        self.header = header; self.spool = spool; self.pins = pins; self.captureDuration = captureDuration
        revisionPair = try SQLiteLogicalBackupSource.revision(header)
        var segments: [(Int, Int, Data)] = []
        var offset = 0
        while offset < spool.byteCount {
            let count = min(1_024 * 1_024 * 1_024, spool.byteCount - offset)
            var hasher = SHA256(); var position = 0
            while position < count { let chunk = try spool.read(offset: offset + position, count: min(64 * 1_024, count - position)); hasher.update(data: chunk); position += chunk.count }
            segments.append((offset, count, Data(hasher.finalize()))); offset += count
        }
        self.segments = segments
        _ = try manifest()
    }
    func manifest() throws -> BackupManifest {
        var next: UInt64 = 0
        let entries = try sources().sorted { $0.path < $1.path }.map { source in
            let frames = try BackupManifestEntry.requiredFrameCount(for: source.plaintextByteCount)
            defer { next += UInt64(frames) }
            return try BackupManifestEntry(kind: source.kind, path: source.path, plaintextByteCount: source.plaintextByteCount,
                plaintextDigest: source.plaintextDigest, firstFrameIndex: next, frameCount: frames)
        }
        return try BackupManifest(revisionPair: revisionPair, entries: entries)
    }
    package func sources() -> [BackupContainerEntrySource] {
        let logical = segments.enumerated().map { index, segment in
            BackupContainerEntrySource(kind: .logicalSegment, path: String(format: "logical/%08d.data", index), plaintextByteCount: UInt64(segment.count), plaintextDigest: segment.digest) { [spool] in
                try spool.validate()
                return BackupContainerOpenedEntrySource(read: { offset, count in
                    guard offset <= UInt64(segment.count), count > 0 else { throw SQLiteLogicalBackupError.invalidStream }
                    return try spool.read(offset: segment.offset + Int(offset), count: min(count, segment.count - Int(offset)))
                }, close: {})
            }
        }
        return logical + pins.originals.values.sorted { $0.id.uuidString < $1.id.uuidString }.map { original in
            BackupContainerEntrySource(kind: .original, path: "originals/\(original.id.uuidString.lowercased()).data", plaintextByteCount: UInt64(original.byteCount), plaintextDigest: original.sha256) { [pins] in
                let opened = try pins.open(original.id)
                return BackupContainerOpenedEntrySource(read: opened.read, close: opened.close, onDigestMismatch: opened.reportDigestMismatch)
            }
        }
    }
    package func validate() throws { try spool.validate(); try pins.validate() }
    package func release() { spool.release(); pins.release() }
    deinit { release() }
    func logicalRecordsForTesting() throws -> [SQLiteLogicalRecord] {
        var records: [SQLiteLogicalRecord] = []
        _ = try SQLiteLogicalStream.read(byteCount: spool.byteCount, read: spool.read) { records.append($0) }
        return records
    }
}

package struct SQLiteLogicalBackupSource: Sendable {
    let store: SQLiteLibraryStore
    private let availableCapacity: @Sendable () throws -> UInt64
    private let captureHook: (@Sendable (SQLiteLogicalCapturePhase) throws -> Void)?
    private let captureObservation: (@Sendable (UInt8, Int, TimeInterval) -> Void)?
    package init(store: SQLiteLibraryStore, captureObservation: (@Sendable (UInt8, Int, TimeInterval) -> Void)? = nil, captureHook: (@Sendable (SQLiteLogicalCapturePhase) throws -> Void)? = nil) {
        self.captureObservation = captureObservation; self.captureHook = captureHook
        self.store = store; availableCapacity = { try Self.availableBytes(at: store.rootURL.deletingLastPathComponent()) }
    }
    init(store: SQLiteLibraryStore, availableCapacity: @escaping @Sendable () throws -> UInt64) {
        self.store = store; self.availableCapacity = availableCapacity; captureObservation = nil; captureHook = nil
    }
    static func availableBytes(at parent: URL) throws -> UInt64 {
        var value = statfs()
        guard statfs(parent.path, &value) == 0, value.f_bavail >= 0, value.f_bsize > 0 else { throw SQLiteLibraryError.ioFailure(errno) }
        let bytes = UInt64(value.f_bavail).multipliedReportingOverflow(by: UInt64(value.f_bsize))
        return bytes.overflow ? UInt64.max : bytes.partialValue
    }
    package func currentRevision() throws -> BackupRevisionPair {
        let state = try store.state()
        return try Self.revision(BackupLogicalHeaderV1(libraryID: state.libraryID, generation: state.generation, commitID: state.commitID))
    }
    static func revision(_ header: BackupLogicalHeaderV1) throws -> BackupRevisionPair {
        guard header.version == 1, header.generation >= 0 else { throw SQLiteLogicalBackupError.unsupportedVersion }
        let digest = SQLiteContentHash.hash(domain: "logical-revision:1", values: [.blob(header.libraryID.sqliteBytes), .integer(header.generation), .blob(header.commitID.sqliteBytes)])
        let revision = try BackupRevision(generation: UInt64(header.generation) + 1, commitID: header.commitID, manifestDigest: digest)
        return try BackupRevisionPair(vault: revision, lanInbox: revision)
    }
    @concurrent package func prepare() async throws -> SQLiteLogicalBackupSnapshot {
        try await LibraryStorageExecutor.run {
            let cancellation = SQLiteLogicalCancellation()
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try captureFrozen(check: cancellation.check)
            } onCancel: { cancellation.cancel() }
        }
    }
    package func validateStrict(check: () throws -> Void = { try Task.checkCancellation() }) throws -> SQLiteLogicalValidation {
        let snapshot = try captureStrict(check: check)
        defer { snapshot.release() }
        for original in snapshot.pins.originals.values {
            let reader = try snapshot.pins.open(original.id); defer { reader.close() }
            var hash = SHA256(); var offset = 0
            while offset < original.byteCount { try check(); let bytes = try reader.read(offset: UInt64(offset), maximumByteCount: 64 * 1_024); hash.update(data: bytes); offset += bytes.count }
            guard Data(hash.finalize()) == original.sha256 else {
                reader.reportDigestMismatch()
                throw SQLiteLogicalBackupError.sourceChanged
            }
        }
        try snapshot.validate()
        let footer = try snapshot.spool.read(offset: snapshot.spool.byteCount - 85, count: 85)
        func count(_ kind: BackupLogicalKind) -> Int {
            let start = 1 + (Int(kind.rawValue) - 1) * 4
            return Int(SQLiteLogicalStream.number(footer.subdata(in: start..<(start + 4)), UInt32.self))
        }
        let counts = (count(.member), count(.report), count(.inbox))
        return SQLiteLogicalValidation(header: snapshot.header, digest: try snapshot.spool.read(offset: snapshot.spool.byteCount - 32, count: 32),
            memberCount: counts.0, recordCount: counts.1, inboxItemCount: counts.2)
    }
    private func captureFrozen(check: () throws -> Void) throws -> SQLiteLogicalBackupSnapshot {
        try check()
        let reserve: UInt64 = 256 * 1_024 * 1_024
        guard try availableCapacity() >= reserve + 1_024 * 1_024 else { throw SQLiteLogicalBackupError.capacityInsufficient }
        try store.admission.withLock { try store.validateRoot() }
        let captured = try SQLiteLogicalCaptureDatabase(rootURL: store.rootURL, observation: captureHook)
        defer { try? captured.close() }
        var pins: SQLiteLogicalOriginalPins?, spool: SQLiteLogicalSpool?
        do {
            var duration: TimeInterval = 0, estimate: UInt64 = 0
            let header = try captured.queue.writeWithoutTransaction { destination in
                let header = try store.read { db in
                    let start = ContinuousClock.now
                    func guardAdmission() throws {
                        try check()
                        guard start.duration(to: .now) < .seconds(5) else { throw SQLiteLogicalBackupError.captureTimedOut }
                    }
                    return try SQLiteReadProgress.withGuard(db, check: guardAdmission) {
                        try guardAdmission()
                        try SQLiteLogicalRows.bounds(db)
                        // Probe-only phases: bounds, size estimate, metadata, native copy.
                        captureObservation?(240, 0, 0)
                        estimate = try SQLiteLogicalRows.estimatedSpoolBytes(db)
                        guard let pageCount = try Int64.fetchOne(db, sql: "PRAGMA page_count"), pageCount >= 0,
                              let pageSize = try Int64.fetchOne(db, sql: "PRAGMA page_size"), pageSize > 0 else { throw SQLiteLogicalBackupError.invalidStream }
                        let databaseBytes = UInt64(pageCount).multipliedReportingOverflow(by: UInt64(pageSize))
                        let required = databaseBytes.partialValue.addingReportingOverflow(estimate + reserve + 1_024 * 1_024)
                        guard !databaseBytes.overflow, !required.overflow, try availableCapacity() >= required.partialValue else { throw SQLiteLogicalBackupError.capacityInsufficient }
                        let state = try SQLiteLibraryState.read(from: db)
                        let header = try BackupLogicalHeaderV1(libraryID: state.libraryID, generation: state.generation, commitID: state.commitID)
                        captureObservation?(241, 0, 0)
                        let originals = try SQLiteLogicalRows.reachableOriginals(db, strict: false)
                        captureObservation?(242, originals.count, 0)
                        try guardAdmission()
                        try withoutActuallyEscaping(guardAdmission) { guardCallback in
                            try db.backup(to: destination, pagesPerStep: 256) { _ in try captureHook?(.copyStep); try guardCallback() }
                        }
                        try SQLiteLogicalCaptureDatabase.validateCacheBudget(destination)
                        captureObservation?(243, 0, 0)
                        // GRDB ignores an error from the completed-step callback.
                        try guardAdmission()
                        pins = SQLiteLogicalOriginalPins(store: store, originals: originals)
                        let elapsed = start.duration(to: .now).components
                        duration = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                        guard duration <= 5 else { throw SQLiteLogicalBackupError.captureTimedOut }
                        captureObservation?(0, originals.count, duration)
                        return header
                    }
                }
                try destination.execute(sql: "PRAGMA query_only=ON")
                return header
            }
            try check()
            guard let pins else { throw SQLiteLogicalBackupError.invalidStream }
            let output = try SQLiteLogicalSpool(parent: store.rootURL.deletingLastPathComponent(), maximumByteCount: Int(estimate))
            spool = output
            try captureHook?(.logicalValidation)
            try captured.queue.read { db in
                let frozen = try SQLiteLibraryState.read(from: db)
                guard frozen.libraryID == header.libraryID, frozen.generation == header.generation, frozen.commitID == header.commitID else { throw SQLiteLogicalBackupError.sourceChanged }
                let writer = try SQLiteLogicalStream.Writer(header: header, write: output.append)
                var phase: UInt8 = 0, count = 0, phaseStart = ContinuousClock.now
                func reportPhase() {
                    if phase == 0 { return }
                    let elapsed = phaseStart.duration(to: .now).components
                    captureObservation?(phase, count, Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
                }
                defer { reportPhase() }
                let originals = try SQLiteLogicalRows.visit(db, store: store, strict: false) { record in
                    try check()
                    if phase != record.kind.rawValue { reportPhase(); phase = record.kind.rawValue; phaseStart = .now; count = 0 }
                    try writer.append(record); count += 1
                }
                guard originals.count == pins.originals.count,
                      originals.allSatisfy({ pins.originals[$0.key]?.contentHash == $0.value.contentHash }) else { throw SQLiteLogicalBackupError.sourceChanged }
                try check(); try writer.finish(); try output.seal()
            }
            try captured.close()
            try check()
            return try SQLiteLogicalBackupSnapshot(header: header, spool: output, pins: pins, captureDuration: duration)
        } catch { spool?.release(); pins?.release(); throw error }
    }

    private func captureStrict(check: () throws -> Void) throws -> SQLiteLogicalBackupSnapshot {
        var spool: SQLiteLogicalSpool?
        var pins: SQLiteLogicalOriginalPins?
        do {
            var duration: TimeInterval = 0
            let header = try store.read { db in
                let start = ContinuousClock.now
                var phaseStart = start, phase: UInt8 = 0, count = 0
                func reportPhase() {
                    let elapsed = phaseStart.duration(to: .now).components
                    captureObservation?(phase, count, Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
                }
                defer { reportPhase() }
                try check()
                let estimate = try SQLiteLogicalRows.estimatedSpoolBytes(db)
                try check()
                let free = try availableCapacity(), reserve: UInt64 = 256 * 1_024 * 1_024
                guard free >= reserve, estimate <= free - reserve else { throw SQLiteLogicalBackupError.capacityInsufficient }
                try check()
                let capturedSpool = try SQLiteLogicalSpool(parent: store.rootURL.deletingLastPathComponent(), maximumByteCount: Int(estimate))
                spool = capturedSpool
                let state = try SQLiteLibraryState.read(from: db)
                let header = try BackupLogicalHeaderV1(libraryID: state.libraryID, generation: state.generation, commitID: state.commitID)
                let writer = try SQLiteLogicalStream.Writer(header: header, write: capturedSpool.append)
                let originals = try SQLiteLogicalRows.visit(db, store: store, strict: true) { record in
                    try check()
                    if record.kind.rawValue != phase {
                        reportPhase(); phaseStart = .now; phase = record.kind.rawValue; count = 0
                    }
                    count += 1
                    try writer.append(record)
                }
                try check(); try writer.finish(); try capturedSpool.seal()
                let elapsed = start.duration(to: .now).components
                duration = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                pins = SQLiteLogicalOriginalPins(store: store, originals: originals)
                return header
            }
            guard let pins, let spool else { throw SQLiteLogicalBackupError.captureTimedOut }
            return try SQLiteLogicalBackupSnapshot(header: header, spool: spool, pins: pins, captureDuration: duration)
        } catch { spool?.release(); pins?.release(); throw error }
    }
}

// SAFETY: a locked flag carries cancellation across GRDB's synchronous queue boundary.
final class SQLiteLogicalCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.withLock { cancelled = true } }
    func check() throws { if lock.withLock({ cancelled }) { throw CancellationError() } }
}
