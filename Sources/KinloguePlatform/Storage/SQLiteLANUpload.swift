import Darwin
import Foundation
import GRDB
import KinlogueCore

struct SQLiteLANUpload: Sendable {
    static let columns = ["id", "scope_id", "session_id", "remote_file_id", "display_name", "declared_byte_count", "media_type", "attempt_revision", "admission_generation", "file_device", "file_inode"]
    let id: UUID
    let scopeID: UUID
    let transport: LANInboxTransportIdentity
    let metadata: LANInboxTransportMetadata
    let attemptRevision: UInt64
    let admissionGeneration: UInt64
    var identity: SQLiteFileIdentity?

    var values: [DatabaseValue] { [id.sqliteBytes.databaseValue, scopeID.sqliteBytes.databaseValue,
        transport.sessionID.sqliteBytes.databaseValue, transport.remoteFileID.sqliteBytes.databaseValue,
        metadata.displayName.rawValue.databaseValue, metadata.declaredByteCount.databaseValue, metadata.mediaType.databaseValue,
        Int64(attemptRevision).databaseValue, Int64(admissionGeneration - 1).databaseValue,
        identity?.device.databaseValue ?? .null, identity?.inode.databaseValue ?? .null] }
    var contentHash: Data { get throws { try SQLiteReportRows.hash(table: "inbox_uploads", values: values) } }
    func save(_ db: Database) throws { try SQLiteReportRows.put(db, table: "inbox_uploads", columns: Self.columns, values: values) }
    static func read(_ id: UUID, _ db: Database) throws -> Self {
        guard let row = try SQLiteRows.fetchOne(db, sql: "SELECT * FROM inbox_uploads WHERE id = ?", arguments: [id.sqliteBytes]) else { throw LANInboxError.fileNotFound }
        return try decode(row)
    }
    static func decode(_ row: Row) throws -> Self {
        let id = try SQLiteReportRows.uuid(row, "id")
        try SQLiteReportRows.verify(row, table: "inbox_uploads", columns: columns)
        let device: Int64? = row["file_device"], inode: Int64? = row["file_inode"]
        let result = try Self(id: id, scopeID: SQLiteReportRows.uuid(row, "scope_id"),
            transport: LANInboxTransportIdentity(sessionID: SQLiteReportRows.uuid(row, "session_id"), remoteFileID: SQLiteReportRows.uuid(row, "remote_file_id")),
            metadata: LANInboxTransportMetadata(displayName: LANInboxDisplayName(rawValue: row["display_name"]), declaredByteCount: row["declared_byte_count"], mediaType: row["media_type"]),
            attemptRevision: UInt64(row["attempt_revision"] as Int64), admissionGeneration: UInt64(row["admission_generation"] as Int64) + 1,
            identity: device.flatMap { device in inode.map { SQLiteFileIdentity(device: device, inode: $0) } })
        guard try result.contentHash == row["content_hash"] as Data else { throw SQLiteLibraryError.damaged }
        return result
    }
}

extension SQLiteLibraryStore {
    func beginLANUpload(_ requested: SQLiteLANUpload, epoch: UUID, validate: () throws -> Void) throws -> (SQLiteLANUpload, Int32) {
        try admission.withLock {
            try validateRoot()
            guard let queue, openEpoch == epoch else { throw SQLiteLibraryError.closed }
            try validate()
            try queue.write { db in
                guard try Int.fetchOne(db, sql: "SELECT count(*) FROM inbox_uploads")! < LANInboxSnapshot.maximumTransportReceiptCount else { throw LANInboxError.resourceLimitExceeded }
                let total = try Int.fetchOne(db, sql: "SELECT (SELECT count(*) FROM inbox_transport_receipts) + (SELECT count(*) FROM inbox_uploads)")!
                let sessionCount = try Int.fetchOne(db, sql: "SELECT (SELECT count(*) FROM inbox_transport_receipts WHERE session_id = ?) + (SELECT count(*) FROM inbox_uploads WHERE session_id = ?)", arguments: [requested.transport.sessionID.sqliteBytes, requested.transport.sessionID.sqliteBytes])!
                guard total < 5_000, sessionCount < 1_000 else { throw LANInboxError.resourceLimitExceeded }
                guard try SQLiteLANRows.receipt(requested.transport, db) == nil else { throw LANInboxError.mutationConflict }
                try requested.save(db)
            }
            try failOriginal(.afterRegistration)
            let directory = try originalDirectoryDescriptor()
            defer { Darwin.close(directory) }
            let fd = openat(directory, lanUploadFilename(requested.id), O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw SQLiteLibraryError.ioFailure(errno) }
            do {
                var upload = requested
                upload.identity = try SQLiteFileIdentity.regular(descriptor: fd)
                try queue.write { try upload.save($0) }
                try syncOriginalDirectory(directory)
                try failOriginal(.afterIdentityCommit)
                activeOriginals.insert(upload.id)
                return (upload, fd)
            } catch { Darwin.close(fd); throw error }
        }
    }

    /// The sink retains the descriptor and active ownership until its actual close callback.
    func commitLANUpload<T: Sendable>(_ upload: SQLiteLANUpload, completed: LANUploadSink.CompletedUpload, descriptor: Int32,
                                     epoch: UUID, _ body: (Database, SQLiteOriginal) throws -> T) throws -> T {
        var committed: LibraryRevision?
        defer { notifications.publish(committed) }
        let original = SQLiteOriginal(id: upload.id, byteCount: completed.byteCount, sha256: completed.sha256Digest,
            contentType: "public.data", lifecycle: "live", operationID: upload.id, identity: upload.identity)
        let verified = try validateOriginalDescriptor(descriptor, original: original, hashBytes: true)
        return try admission.withLock {
            try Task.checkCancellation()
            try validateRoot()
            guard openEpoch == epoch, activeOriginals.contains(upload.id), let queue,
                  completed.attemptID == upload.id, completed.byteCount == upload.metadata.declaredByteCount,
                  try queue.read({ try SQLiteLANUpload.read(upload.id, $0).contentHash }) == upload.contentHash else { throw LANInboxError.staleRevision }
            let directory = try originalDirectoryDescriptor()
            defer { Darwin.close(directory) }
            try validateLANUploadPath(upload, directory: directory, name: lanUploadFilename(upload.id))
            guard try SQLiteOriginalSnapshot(descriptor) == verified else { throw SQLiteLibraryError.invalidOriginal }
            guard renameatx_np(directory, lanUploadFilename(upload.id), directory, originalFilename(upload.id), UInt32(RENAME_EXCL)) == 0 else { throw SQLiteLibraryError.ioFailure(errno) }
            try syncOriginalDirectory(directory)
            let renamed = try SQLiteOriginalSnapshot(descriptor)
            guard renamed.sameContent(as: verified) else { throw SQLiteLibraryError.invalidOriginal }
            try failOriginal(.afterRename)
            guard try validateOriginalPath(directory: directory, original: original, staged: false) == renamed else {
                throw SQLiteLibraryError.invalidOriginal
            }
            let result = try commitTransaction(queue, capture: &committed) { db in
                try original.save(in: db)
                let value = try body(db, original)
                try markUnreferencedOriginalsDeleting([original.id], in: db)
                try db.execute(sql: "DELETE FROM inbox_uploads WHERE id = ?", arguments: [upload.id.sqliteBytes])
                try validateRoot()
                return value
            }
            try failOriginal(.afterLiveCommit)
            return result
        }
    }

    func cancelLANUpload(_ upload: SQLiteLANUpload, descriptor: Int32?) throws {
        try admission.withLock {
            try validateRoot()
            guard let queue else { throw SQLiteLibraryError.closed }
            // A lost publication response cannot authorize deleting the live original.
            guard try queue.read({ try Int.fetchOne($0, sql: "SELECT count(*) FROM inbox_uploads WHERE id = ?", arguments: [upload.id.sqliteBytes]) }) == 1 else { return }
            guard try queue.read({ try SQLiteLANUpload.read(upload.id, $0).contentHash }) == upload.contentHash else { throw SQLiteLibraryError.damaged }
            if let descriptor { guard try SQLiteFileIdentity.regular(descriptor: descriptor).isFile(recordedAs: upload.identity) else { throw SQLiteLibraryError.invalidOriginal } }
            guard try queue.read({ try Int.fetchOne($0, sql: "SELECT count(*) FROM originals WHERE id = ?", arguments: [upload.id.sqliteBytes]) }) == 0 else { throw SQLiteLibraryError.invalidOriginal }
            let directory = try originalDirectoryDescriptor()
            defer { Darwin.close(directory) }
            for name in [lanUploadFilename(upload.id), originalFilename(upload.id)] {
                var metadata = stat()
                if fstatat(directory, name, &metadata, AT_SYMLINK_NOFOLLOW) != 0 {
                    if errno == ENOENT { continue }; throw SQLiteLibraryError.ioFailure(errno)
                }
                try validateLANUploadPath(upload, directory: directory, name: name)
                guard unlinkat(directory, name, 0) == 0 else { throw SQLiteLibraryError.ioFailure(errno) }
                try syncOriginalDirectory(directory)
            }
            try queue.write { try $0.execute(sql: "DELETE FROM inbox_uploads WHERE id = ?", arguments: [upload.id.sqliteBytes]) }
        }
    }

    func recoverLANUploads() throws -> [UUID] {
        let ids = try read { try Data.fetchAll($0, sql: "SELECT id FROM inbox_uploads ORDER BY id LIMIT 5001") }
        guard ids.count <= 5_000 else { throw LANInboxError.resourceLimitExceeded }
        var retained: [UUID] = []
        for bytes in ids {
            guard let id = UUID(sqliteBytes: bytes) else { throw SQLiteLibraryError.damaged }
            if admission.withLock({ activeOriginals.contains(id) }) { continue }
            do { try cancelLANUpload(read { try SQLiteLANUpload.read(id, $0) }, descriptor: nil) }
            catch { retained.append(id) }
        }
        return retained
    }

    private func lanUploadFilename(_ id: UUID) -> String { id.uuidString.lowercased() + ".upload" }
    private func validateLANUploadPath(_ upload: SQLiteLANUpload, directory: Int32, name: String) throws {
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw SQLiteLibraryError.invalidOriginal }
        defer { Darwin.close(fd) }
        guard try SQLiteFileIdentity.regular(descriptor: fd).isFile(recordedAs: upload.identity) else { throw SQLiteLibraryError.invalidOriginal }
    }
}
