import Darwin
import Foundation
import GRDB
import KinlogueCore

extension SQLiteLibraryStore {
    func adoptDICOMOriginal(_ object: DICOMIndexedObject, session: SQLiteDICOMImportSession,
                            staging: VaultDICOMStudyStaging) throws {
        try staging.withOwnedStagedDescriptor(object.staged) { sourceDirectory, source, name in
            try admission.withLock {
                try Task.checkCancellation()
                try validateRoot()
                guard openEpoch == session.epoch, activeDICOMImports.contains(session.operationID), let queue,
                      object.staged.ownership == session.ownership,
                      object.staged.byteCount == object.attachment.byteCount,
                      object.staged.sha256Digest == object.attachment.sha256Digest else { throw DICOMImportError.integrityFailure }
                var sourceMetadata = stat()
                guard fstat(source, &sourceMetadata) == 0, sourceMetadata.st_uid == geteuid(),
                      sourceMetadata.st_mode & 0o7777 == 0o400, fchmod(source, 0o600) == 0,
                      fcntl(source, F_FULLFSYNC) == 0 || fsync(source) == 0 else { throw SQLiteLibraryError.invalidOriginal }
                let original = SQLiteOriginal(id: object.attachment.id, byteCount: object.attachment.byteCount,
                    sha256: object.attachment.sha256Digest, contentType: object.attachment.contentTypeIdentifier,
                    lifecycle: "staged", operationID: session.operationID,
                    identity: try SQLiteFileIdentity.regular(descriptor: source))
                let directory = try originalDirectoryDescriptor()
                defer { Darwin.close(directory) }
                try queue.write { db in
                    guard try Int.fetchOne(db, sql: "SELECT (SELECT count(*) FROM originals WHERE id = ?) + (SELECT count(*) FROM inbox_uploads WHERE id = ?)",
                        arguments: [original.id.sqliteBytes, original.id.sqliteBytes]) == 0 else { throw SQLiteLibraryError.invalidOriginal }
                    try original.save(in: db)
                }
                try failOriginal(.afterRegistration)
                var named = stat()
                guard fstatat(sourceDirectory, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                      Int64(named.st_dev) == original.identity?.device, Int64(named.st_ino) == original.identity?.inode,
                      named.st_mode & S_IFMT == S_IFREG, named.st_nlink == 1 else { throw SQLiteLibraryError.invalidOriginal }
                guard renameatx_np(sourceDirectory, name, directory, originalFilename(original.id, staged: true), UInt32(RENAME_EXCL)) == 0 else { throw SQLiteLibraryError.ioFailure(errno) }
                try syncOriginalDirectory(sourceDirectory)
                try syncOriginalDirectory(directory)
                try failOriginal(.afterIdentityCommit)
            }
        }
    }

    /// All bytes are durable before one transaction publishes the complete graph.
    func publishDICOMOriginals<T: Sendable>(_ ids: [UUID], operationID: UUID, epoch: UUID,
                                           _ publish: (Database) throws -> T) throws -> T {
        var committed: LibraryRevision?
        defer { notifications.publish(committed) }
        let originals = try admission.withLock {
            try validateRoot()
            guard openEpoch == epoch, activeDICOMImports.contains(operationID), let queue,
                  Set(ids).count == ids.count, !ids.isEmpty, ids.count <= 2_000,
                  ids.allSatisfy({ !activeOriginals.contains($0) }) else { throw DICOMImportError.publicationConflict }
            let originals = try queue.read { db in
                try ids.map { id in
                    let original = try SQLiteOriginal.read(id, from: db)
                    guard original.lifecycle == "staged", original.operationID == operationID else { throw SQLiteLibraryError.invalidOriginal }
                    return original
                }
            }
            activeOriginals.formUnion(ids)
            return originals
        }
        defer { for id in ids { finishOriginalOperation(id) } }
        var snapshots: [UUID: SQLiteOriginalSnapshot] = [:]
        for original in originals {
            try Task.checkCancellation()
            let directory = try admission.withLock { try originalDirectoryDescriptor() }
            defer { Darwin.close(directory) }
            let fd = openat(directory, originalFilename(original.id, staged: true), O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw SQLiteLibraryError.invalidOriginal }
            defer { Darwin.close(fd) }
            let before = try validateOriginalDescriptor(fd, original: original, hashBytes: true)
            snapshots[original.id] = try admission.withLock {
                try Task.checkCancellation()
                guard openEpoch == epoch, activeDICOMImports.contains(operationID) else { throw SQLiteLibraryError.staleRoot }
                try validateActiveOriginal(original)
                try validateOriginalPath(directory: directory, original: original, staged: true)
                guard try SQLiteOriginalSnapshot(fd) == before else { throw SQLiteLibraryError.invalidOriginal }
                guard renameatx_np(directory, originalFilename(original.id, staged: true), directory,
                    originalFilename(original.id), UInt32(RENAME_EXCL)) == 0 else { throw SQLiteLibraryError.ioFailure(errno) }
                try syncOriginalDirectory(directory)
                let published = try SQLiteOriginalSnapshot(fd)
                guard published.sameContent(as: before) else { throw SQLiteLibraryError.invalidOriginal }
                return published
            }
            try failOriginal(.afterRename)
        }
        let result = try admission.withLock {
            try Task.checkCancellation()
            try validateRoot()
            guard openEpoch == epoch, activeDICOMImports.contains(operationID), let queue else { throw SQLiteLibraryError.staleRoot }
            let directory = try originalDirectoryDescriptor()
            defer { Darwin.close(directory) }
            for original in originals {
                try validateActiveOriginal(original)
                let fd = openat(directory, originalFilename(original.id), O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { throw SQLiteLibraryError.invalidOriginal }
                defer { Darwin.close(fd) }
                guard try validateOriginalDescriptor(fd, original: original, hashBytes: false) == snapshots[original.id] else { throw SQLiteLibraryError.invalidOriginal }
            }
            return try commitTransaction(queue, capture: &committed) { db in
                for var original in originals { original.lifecycle = "live"; try original.save(in: db) }
                let value = try publish(db)
                try validateRoot()
                return value
            }
        }
        try failOriginal(.afterLiveCommit)
        return result
    }
}
