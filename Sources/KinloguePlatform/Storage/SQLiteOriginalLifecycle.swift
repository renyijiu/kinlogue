import CryptoKit
import Darwin
import Foundation
import KinlogueCore
import GRDB

package enum SQLiteOriginalFaultPoint: Sendable {
    case afterRegistration, afterIdentityCommit, afterFileSync, afterRename, afterLiveCommit
    case afterDeletingCommit, afterUnlink
}

struct SQLiteOriginal: Sendable {
    let id: UUID
    let byteCount: Int
    let sha256: Data
    let contentType: String
    var lifecycle: String
    let operationID: UUID
    var identity: SQLiteFileIdentity?

    var contentHash: Data {
        SQLiteContentHash.hash(domain: "originals:1", values: [
            .blob(id.sqliteBytes), .integer(Int64(byteCount)), .blob(sha256), .text(contentType),
            .text(lifecycle), .blob(operationID.sqliteBytes),
            identity.map { .integer($0.device) } ?? .null,
            identity.map { .integer($0.inode) } ?? .null
        ])
    }

    static func read(_ id: UUID, from db: Database) throws -> Self {
        guard let row = try SQLiteRows.fetchOne(db, sql: "SELECT * FROM originals WHERE id = ?", arguments: [id.sqliteBytes]) else { throw SQLiteLibraryError.invalidOriginal }
        return try decode(row)
    }

    static func decode(_ row: Row) throws -> Self {
        try SQLiteRows.validateText(row, table: "originals")
        guard let id = UUID(sqliteBytes: row["id"]), let operationID = UUID(sqliteBytes: row["operation_id"]) else { throw SQLiteLibraryError.invalidOriginal }
        let device: Int64? = row["file_device"]
        let inode: Int64? = row["file_inode"]
        let identity: SQLiteFileIdentity?
        if let device, let inode { identity = SQLiteFileIdentity(device: device, inode: inode) }
        else { identity = nil }
        let original = Self(id: id, byteCount: row["byte_count"], sha256: row["sha256"], contentType: row["content_type"],
                            lifecycle: row["lifecycle"], operationID: operationID, identity: identity)
        guard original.contentHash == row["content_hash"] as Data else { throw SQLiteLibraryError.invalidOriginal }
        return original
    }

    func save(in db: Database) throws {
        try db.execute(sql: """
            INSERT INTO originals(id,byte_count,sha256,content_type,lifecycle,operation_id,file_device,file_inode,content_hash)
            VALUES (?, ?, ?, CAST(? AS TEXT), ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET lifecycle=excluded.lifecycle, file_device=excluded.file_device,
                file_inode=excluded.file_inode, content_hash=excluded.content_hash
            """, arguments: [id.sqliteBytes, byteCount, sha256, Data(contentType.utf8), lifecycle, operationID.sqliteBytes,
                             identity?.device, identity?.inode, contentHash])
    }
}

extension SQLiteLibraryStore {
    /// Register ownership before copying bounded bytes. No display name is accepted as a path.
    package func stageOriginal(
        copyingFrom source: Int32, byteCount: Int, sha256: Data,
        contentType: String, operationID: UUID
    ) throws -> UUID {
        let (original, directory, descriptor) = try admission.withLock {
            try Task.checkCancellation()
            try validateRoot()
            guard let queue, byteCount >= 0,
                  sha256.count == 32, !contentType.isEmpty, contentType.utf8.count <= 256 else {
                throw SQLiteLibraryError.invalidOriginal
            }
            var original = SQLiteOriginal(id: UUID(), byteCount: byteCount, sha256: sha256,
                contentType: contentType, lifecycle: "staged", operationID: operationID)
            try queue.write { db in try original.save(in: db) }
            try failOriginal(.afterRegistration)
            let directory = try originalDirectoryDescriptor()
            let descriptor = openat(directory, originalFilename(original.id, staged: true),
                O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else {
                let code = errno
                Darwin.close(directory)
                throw SQLiteLibraryError.ioFailure(code)
            }
            do {
                original.identity = try SQLiteFileIdentity.regular(descriptor: descriptor)
                try queue.write { db in try original.save(in: db) }
                try syncOriginalDirectory(directory)
                activeOriginals.insert(original.id)
                return (original, directory, descriptor)
            } catch {
                Darwin.close(descriptor)
                Darwin.close(directory)
                throw error
            }
        }
        defer {
            Darwin.close(descriptor)
            Darwin.close(directory)
            finishOriginalOperation(original.id)
        }
        try failOriginal(.afterIdentityCommit)
        try Task.checkCancellation()
        var sourceMetadata = stat()
        guard fstat(source, &sourceMetadata) == 0, sourceMetadata.st_mode & S_IFMT == S_IFREG,
              sourceMetadata.st_size == byteCount else { throw SQLiteLibraryError.invalidOriginal }
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        var offset = 0
        var hasher = SHA256()
        while offset < byteCount {
            try Task.checkCancellation()
            let count = pread(source, &buffer, min(buffer.count, byteCount - offset), off_t(offset))
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw SQLiteLibraryError.invalidOriginal }
            try buffer.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { throw SQLiteLibraryError.invalidOriginal }
                var written = 0
                while written < count {
                    let amount = Darwin.write(descriptor, base.advanced(by: written), count - written)
                    if amount < 0, errno == EINTR { continue }
                    guard amount > 0 else { throw SQLiteLibraryError.ioFailure(errno) }
                    written += amount
                }
                hasher.update(bufferPointer: UnsafeRawBufferPointer(start: base, count: count))
            }
            offset += count
        }
        guard Data(hasher.finalize()) == sha256 else { throw SQLiteLibraryError.invalidOriginal }
        if fcntl(descriptor, F_FULLFSYNC) != 0, fsync(descriptor) != 0 { throw SQLiteLibraryError.ioFailure(errno) }
        let verified = try validateOriginalDescriptor(descriptor, original: original, hashBytes: true)
        try failOriginal(.afterFileSync)
        try admission.withLock {
            try Task.checkCancellation()
            try validateActiveOriginal(original)
            guard try validateOriginalPath(directory: directory, original: original, staged: true) == verified else {
                throw SQLiteLibraryError.invalidOriginal
            }
        }
        return original.id
    }

    /// The caller adds domain references in this same transaction; live bytes precede the commit.
    func publishOriginal<T: Sendable>(_ id: UUID, operationID: UUID, _ publish: (Database) throws -> T) throws -> T {
        var committed: LibraryRevision?
        defer { notifications.publish(committed) }
        do {
            let (staged, directory, descriptor) = try admission.withLock {
                try Task.checkCancellation()
                try validateRoot()
                guard !activeOriginals.contains(id) else { throw SQLiteLibraryError.originalBusy }
                guard let queue else { throw SQLiteLibraryError.closed }
                let original = try queue.read { try SQLiteOriginal.read(id, from: $0) }
                guard original.lifecycle == "staged", original.operationID == operationID else { throw SQLiteLibraryError.invalidOriginal }
                let directory = try originalDirectoryDescriptor()
                let descriptor = openat(directory, originalFilename(id, staged: true), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard descriptor >= 0 else {
                    Darwin.close(directory)
                    throw SQLiteLibraryError.invalidOriginal
                }
                do { try validateOriginalDescriptor(descriptor, original: original, hashBytes: false) }
                catch {
                    Darwin.close(descriptor)
                    Darwin.close(directory)
                    throw error
                }
                activeOriginals.insert(id)
                return (original, directory, descriptor)
            }
            defer {
                Darwin.close(descriptor)
                Darwin.close(directory)
                finishOriginalOperation(id)
            }
            let verified = try validateOriginalDescriptor(descriptor, original: staged, hashBytes: true)
            let renamed = try admission.withLock {
                try Task.checkCancellation()
                try validateActiveOriginal(staged)
                guard try validateOriginalPath(directory: directory, original: staged, staged: true) == verified else {
                    throw SQLiteLibraryError.invalidOriginal
                }
                // RENAME_EXCL never overwrites an unexpected file at the opaque destination.
                guard renameatx_np(directory, originalFilename(id, staged: true), directory, originalFilename(id), UInt32(RENAME_EXCL)) == 0 else {
                    throw SQLiteLibraryError.ioFailure(errno)
                }
                try syncOriginalDirectory(directory)
                let renamed = try SQLiteOriginalSnapshot(descriptor)
                guard renamed.sameContent(as: verified) else { throw SQLiteLibraryError.invalidOriginal }
                return renamed
            }
            try failOriginal(.afterRename)
            let result = try admission.withLock {
                try Task.checkCancellation()
                try validateActiveOriginal(staged)
                guard try validateOriginalPath(directory: directory, original: staged, staged: false) == renamed else {
                    throw SQLiteLibraryError.invalidOriginal
                }
                guard let queue else { throw SQLiteLibraryError.closed }
                var original = staged
                original.lifecycle = "live"
                return try commitTransaction(queue, capture: &committed) { db in
                    try original.save(in: db)
                    let result = try publish(db)
                    try validateRoot()
                    return result
                }
            }
            try failOriginal(.afterLiveCommit)
            return result
        } catch { throw Self.sanitized(error) }
    }

    func validateActiveOriginal(_ original: SQLiteOriginal) throws {
        try validateRoot()
        guard activeOriginals.contains(original.id), let queue,
              try queue.read({ try SQLiteOriginal.read(original.id, from: $0).contentHash }) == original.contentHash else {
            throw SQLiteLibraryError.invalidOriginal
        }
    }

    @discardableResult
    func validateOriginalPath(directory: Int32, original: SQLiteOriginal, staged: Bool) throws -> SQLiteOriginalSnapshot {
        let descriptor = openat(directory, originalFilename(original.id, staged: staged), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw SQLiteLibraryError.invalidOriginal }
        defer { Darwin.close(descriptor) }
        return try validateOriginalDescriptor(descriptor, original: original, hashBytes: false)
    }

    package func publishOriginal(_ id: UUID, operationID: UUID) throws {
        try publishOriginal(id, operationID: operationID) { _ in () }
    }

    /// Call after domain references are removed; a pinned snapshot keeps its bytes until release.
    package func deleteOriginal(_ id: UUID) throws {
        try admission.withLock {
            try validateRoot()
            guard pins[id, default: 0] == 0 else { throw SQLiteLibraryError.originalPinned }
            guard !activeOriginals.contains(id) else { throw SQLiteLibraryError.originalBusy }
            guard let queue else { throw SQLiteLibraryError.closed }
            var original = try queue.read { try SQLiteOriginal.read(id, from: $0) }
            guard original.lifecycle == "live" else { throw SQLiteLibraryError.invalidOriginal }
            try queue.write { db in
                guard try !originalIsReferenced(id, in: db) else { throw SQLiteLibraryError.invalidOriginal }
                original.lifecycle = "deleting"
                try original.save(in: db)
            }
            try failOriginal(.afterDeletingCommit)
            try reclaim(original)
        }
    }

    /// Called inside the domain deletion transaction, while admission is held.
    func markUnreferencedOriginalsDeleting(_ ids: Set<UUID>, in db: Database) throws {
        for id in ids where try !originalIsReferenced(id, in: db) {
            var original = try SQLiteOriginal.read(id, from: db)
            guard original.lifecycle == "live" else { throw SQLiteLibraryError.invalidOriginal }
            original.lifecycle = "deleting"
            try original.save(in: db)
        }
    }

    func reclaimDeletingOriginal(_ id: UUID) throws {
        try admission.withLock { try reclaimDeletingOriginalLocked(id) }
    }

    private func reclaimDeletingOriginalLocked(_ id: UUID) throws {
        try validateRoot()
        guard pins[id, default: 0] == 0, !activeOriginals.contains(id), let queue else { return }
        guard let original = try queue.read({ db -> SQLiteOriginal? in
            guard try Int.fetchOne(db, sql: "SELECT count(*) FROM originals WHERE id = ? AND lifecycle = 'deleting'", arguments: [id.sqliteBytes]) == 1 else { return nil }
            return try SQLiteOriginal.read(id, from: db)
        }) else { return }
        try reclaim(original)
    }

    func finishOriginalOperation(_ id: UUID) {
        admission.withLock {
            activeOriginals.remove(id)
            try? reclaimDeletingOriginalLocked(id)
        }
    }

    /// Returns ambiguous/corrupted item IDs without deleting their bytes or blocking good items.
    package func recoverOriginals() throws -> [UUID] {
        try admission.withLock { try recoverOriginalsLocked() }
    }

    /// Runtime cleanup is scoped to the completed operation; startup may recover the whole library.
    func reclaimOriginals(operationID: UUID) throws -> [UUID] {
        try admission.withLock { try recoverOriginalsLocked(operationID: operationID) }
    }

    func recoverOriginalsLocked(operationID: UUID? = nil) throws -> [UUID] {
        try validateRoot()
        guard let queue else { throw SQLiteLibraryError.closed }
        var after = Data()
        var retained: [UUID] = []
        while true {
            let batch = try queue.read { db in
                if let operationID {
                    return try Data.fetchAll(db, sql: "SELECT id FROM originals WHERE lifecycle != 'live' AND operation_id = ? AND id > ? ORDER BY id LIMIT 32", arguments: [operationID.sqliteBytes, after])
                }
                return try Data.fetchAll(db, sql: "SELECT id FROM originals WHERE lifecycle != 'live' AND id > ? ORDER BY id LIMIT 32", arguments: [after])
            }
            guard let last = batch.last else { return retained }
            for bytes in batch {
                guard let id = UUID(sqliteBytes: bytes) else { throw SQLiteLibraryError.damaged }
                if activeOriginals.contains(id) {
                    if operationID != nil { retained.append(id) }
                    continue
                }
                do {
                    let original = try queue.read { try SQLiteOriginal.read(id, from: $0) }
                    if activeDICOMImports.contains(original.operationID) {
                        if operationID != nil { retained.append(id) }
                        continue
                    }
                    try reclaim(original)
                } catch { retained.append(id) }
            }
            after = last
        }
    }

    package func pinOriginal(_ id: UUID) throws -> SQLiteOriginalPin {
        try pinOriginal(id, recordsDamage: true)
    }

    // Inspection owns its initial-revision fence and records only still-current failures.
    func pinOriginalForInspection(_ id: UUID) throws -> SQLiteOriginalPin {
        try pinOriginal(id, recordsDamage: false)
    }

    private func pinOriginal(_ id: UUID, recordsDamage: Bool) throws -> SQLiteOriginalPin {
        try admission.withLock {
            try validateRoot()
            guard let queue else { throw SQLiteLibraryError.closed }
            try requireUnquarantined(.original, id)
            let original = try queue.read { try SQLiteOriginal.read(id, from: $0) }
            guard original.lifecycle == "live" else { throw SQLiteLibraryError.invalidOriginal }
            do {
                let directory = try originalDirectoryDescriptor()
                defer { Darwin.close(directory) }
                let descriptor = openat(directory, originalFilename(id), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard descriptor >= 0 else { throw SQLiteLibraryError.invalidOriginal }
                do { try validateOriginalDescriptor(descriptor, original: original, hashBytes: false) }
                catch { Darwin.close(descriptor); throw error }
                pins[id, default: 0] += 1
                return SQLiteOriginalPin(store: self, original: original, descriptor: descriptor, recordsDamage: recordsDamage)
            } catch SQLiteLibraryError.invalidOriginal {
                if recordsDamage && !Task.isCancelled { try queue.read { try noteOriginalIntegrityFailureLocked(original, $0) } }
                throw SQLiteLibraryError.invalidOriginal
            }
        }
    }

    // Snapshot pins are released in one admission and one metadata query, not N root checks/transactions.
    func releasePins(_ ids: Set<UUID>) {
        admission.withLock {
            var unpinned: Set<UUID> = []
            for id in ids {
                let remaining = pins[id, default: 0] - 1
                if remaining > 0 { pins[id] = remaining } else { pins.removeValue(forKey: id); unpinned.insert(id) }
            }
            guard let queue, let deleting = try? queue.read({ db in
                try Data.fetchAll(db, sql: "SELECT id FROM originals WHERE lifecycle='deleting'")
            }) else { return }
            for data in deleting {
                guard let id = UUID(sqliteBytes: data), unpinned.contains(id) else { continue }
                try? reclaimDeletingOriginalLocked(id)
            }
        }
    }

    func releasePin(_ id: UUID) {
        admission.withLock {
            let remaining = pins[id, default: 0] - 1
            if remaining > 0 { pins[id] = remaining } else {
                pins.removeValue(forKey: id)
                try? reclaimDeletingOriginalLocked(id)
            }
        }
    }

    @discardableResult
    func validateOriginalDescriptor(_ descriptor: Int32, original: SQLiteOriginal, hashBytes: Bool) throws -> SQLiteOriginalSnapshot {
        let identity: SQLiteFileIdentity
        do { identity = try SQLiteFileIdentity.regular(descriptor: descriptor) }
        catch SQLiteLibraryError.invalidPath { throw SQLiteLibraryError.invalidOriginal }
        guard identity == original.identity else { throw SQLiteLibraryError.invalidOriginal }
        let before = try SQLiteOriginalSnapshot(descriptor)
        guard before.size == original.byteCount else { throw SQLiteLibraryError.invalidOriginal }
        guard hashBytes else { return before }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        var offset = 0
        while offset < original.byteCount {
            try Task.checkCancellation()
            let count = pread(descriptor, &buffer, min(buffer.count, original.byteCount - offset), off_t(offset))
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw SQLiteLibraryError.invalidOriginal }
            originalReadMetrics.add(count)
            buffer.withUnsafeBytes {
                hasher.update(bufferPointer: UnsafeRawBufferPointer(start: $0.baseAddress, count: count))
            }
            offset += count
        }
        guard Data(hasher.finalize()) == original.sha256,
              try SQLiteOriginalSnapshot(descriptor) == before,
              try SQLiteFileIdentity.regular(descriptor: descriptor) == original.identity else {
            throw SQLiteLibraryError.invalidOriginal
        }
        return before
    }

    private func reclaim(_ original: SQLiteOriginal) throws {
        guard !activeOriginals.contains(original.id) else { throw SQLiteLibraryError.originalBusy }
        guard let queue, pins[original.id, default: 0] == 0 else { throw SQLiteLibraryError.originalPinned }
        guard try queue.read({ try !originalIsReferenced(original.id, in: $0) }) else { throw SQLiteLibraryError.invalidOriginal }
        let directory = try originalDirectoryDescriptor()
        defer { Darwin.close(directory) }
        for name in [originalFilename(original.id, staged: true), originalFilename(original.id)] {
            var metadata = stat()
            if fstatat(directory, name, &metadata, AT_SYMLINK_NOFOLLOW) != 0 {
                if errno == ENOENT { continue }
                throw SQLiteLibraryError.ioFailure(errno)
            }
            guard let identity = original.identity,
                  metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == geteuid(), metadata.st_nlink == 1,
                  Int64(exactly: metadata.st_dev) == identity.device,
                  Int64(exactly: metadata.st_ino) == identity.inode else { throw SQLiteLibraryError.invalidOriginal }
            try validateRoot()
            guard unlinkat(directory, name, 0) == 0 else { throw SQLiteLibraryError.ioFailure(errno) }
            try syncOriginalDirectory(directory)
            try failOriginal(.afterUnlink)
        }
        try queue.write { db in
            guard try !originalIsReferenced(original.id, in: db) else { throw SQLiteLibraryError.invalidOriginal }
            try db.execute(sql: "DELETE FROM originals WHERE id = ? AND lifecycle != 'live'", arguments: [original.id.sqliteBytes])
        }
    }

    private func originalIsReferenced(_ id: UUID, in db: Database) throws -> Bool {
        try Int.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM report_sources WHERE original_id = ?
                UNION ALL SELECT 1 FROM inbox_items WHERE original_id = ?
                UNION ALL SELECT 1 FROM dicom_objects WHERE original_id = ?)
            """, arguments: [id.sqliteBytes, id.sqliteBytes, id.sqliteBytes]) == 1
    }

    func originalDirectoryDescriptor() throws -> Int32 {
        try validateRoot()
        let descriptor = Darwin.open(originalsURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw SQLiteLibraryError.invalidPath }
        return descriptor
    }

    func originalFilename(_ id: UUID, staged: Bool = false) -> String {
        id.uuidString.lowercased() + (staged ? ".staged" : ".data")
    }

    func syncOriginalDirectory(_ descriptor: Int32) throws {
        if fsync(descriptor) != 0, errno != EINVAL, errno != ENOTSUP { throw SQLiteLibraryError.ioFailure(errno) }
    }

    func failOriginal(_ point: SQLiteOriginalFaultPoint) throws {
        if originalFault?(point) == true { throw SQLiteLibraryError.injectedFailure }
    }
}

/// A snapshot pin owns the verified descriptor and retains the database owner until released.
// SAFETY: lock serializes descriptor use and release; store admission protects the shared pin counts.
package final class SQLiteOriginalPin: @unchecked Sendable {
    private let lock = NSLock()
    private var store: SQLiteLibraryStore?
    private let original: SQLiteOriginal
    private let epoch: UUID
    private let recordsDamage: Bool
    private var descriptor: Int32

    fileprivate init(store: SQLiteLibraryStore, original: SQLiteOriginal, descriptor: Int32, recordsDamage: Bool) {
        self.recordsDamage = recordsDamage
        self.store = store
        self.original = original
        epoch = store.openEpoch
        self.descriptor = descriptor
    }

    package func withVerifiedDescriptor<T>(_ body: (Int32) throws -> T) throws -> T {
        try lock.withLock {
            guard let store, descriptor >= 0 else { throw SQLiteLibraryError.closed }
            try store.admission.withLock { try store.validateRoot() }
            let before = try verifiedSnapshot(store)
            let result = try body(descriptor)
            guard try verifiedSnapshot(store) == before else {
                if recordsDamage { store.noteOriginalIntegrityFailure(original, epoch: epoch) }
                throw SQLiteLibraryError.invalidOriginal
            }
            try store.admission.withLock { try store.validateRoot() }
            return result
        }
    }

    private func verifiedSnapshot(_ store: SQLiteLibraryStore) throws -> SQLiteOriginalSnapshot {
        do { return try store.validateOriginalDescriptor(descriptor, original: original, hashBytes: true) }
        catch SQLiteLibraryError.invalidOriginal {
            if recordsDamage { store.noteOriginalIntegrityFailure(original, epoch: epoch) }
            throw SQLiteLibraryError.invalidOriginal
        }
    }

    package func release() {
        lock.withLock {
            guard let store else { return }
            Darwin.close(descriptor)
            descriptor = -1
            store.releasePin(original.id)
            self.store = nil
        }
    }

    deinit { release() }
}

/// A bounded stat fence carries the result of the one full publication hash
/// through publication or consumption. Rename may change ctime, never content mtime.
struct SQLiteOriginalSnapshot: Equatable, Sendable {
    let device: Int64
    let inode: Int64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64

    init(_ descriptor: Int32) throws {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else { throw SQLiteLibraryError.invalidOriginal }
        device = Int64(value.st_dev); inode = Int64(value.st_ino); size = value.st_size
        modifiedSeconds = Int64(value.st_mtimespec.tv_sec); modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
        changedSeconds = Int64(value.st_ctimespec.tv_sec); changedNanoseconds = Int64(value.st_ctimespec.tv_nsec)
    }
    func sameContent(as other: Self) -> Bool {
        device == other.device && inode == other.inode && size == other.size
            && modifiedSeconds == other.modifiedSeconds && modifiedNanoseconds == other.modifiedNanoseconds
    }
}
