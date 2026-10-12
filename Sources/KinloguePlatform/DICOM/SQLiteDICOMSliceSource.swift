import Darwin
import Foundation
import GRDB
import KinlogueCore

struct SQLiteDICOMSliceSource: DICOMVerifiedSliceSource {
    let repository: SQLiteDICOMRepository
    let decoder: any DICOMFrameDecoding

    @concurrent
    func openSeries(studyID: UUID, seriesID: UUID) async throws -> DICOMSliceSeriesSession {
        try await LibraryStorageExecutor.run {
            try repository.store.read(epoch: repository.epoch) { db in
                let state = try SQLiteLibraryState.read(from: db)
                try repository.store.requireUnquarantined(.study, studyID)
                let study = try SQLiteDICOMRows.summary(SQLiteDICOMRows.studyRow(studyID, db))
                let (index, originals) = try SQLiteDICOMRows.targetSeries(studyID, seriesID, db)
                guard let seriesHash = try Data.fetchOne(db, sql: "SELECT content_hash FROM dicom_series WHERE study_id = ? AND series_id = ?",
                    arguments: [studyID.sqliteBytes, seriesID.sqliteBytes]) else { throw DICOMSliceServiceError.seriesUnavailable }
                let token = DICOMVaultSessionToken(libraryID: state.libraryID, epoch: repository.epoch,
                    studyID: studyID, contentRevision: study.contentRevision, seriesID: seriesID, seriesHash: seriesHash)
                let instances = try zip(index.instances, originals).map { instance, original in
                    try DICOMSliceInstanceDescriptor(id: instance.id, attachmentID: original.id,
                        contentDigest: original.sha256, objectByteCount: original.byteCount, attributes: instance.attributes)
                }
                return try DICOMSliceSeriesSession(token: token, studyID: studyID, seriesID: seriesID,
                    orderingProvenance: index.series[0].orderingProvenance, instances: instances)
            }
        }
    }

    @concurrent
    func decode(_ requested: DICOMSliceInstanceDescriptor, in session: DICOMSliceSeriesSession) async throws -> DICOMVerifiedDecodedFrame {
        try await LibraryStorageExecutor.run {
            let original = try validateTarget(requested, session)
            do {
                let pin = try repository.store.pinOriginal(original.id)
                defer { pin.release() }
                let handle = try pin.withVerifiedDescriptor { fd in
                    let duplicate = fcntl(fd, F_DUPFD_CLOEXEC, 0)
                    guard duplicate >= 0 else { throw SQLiteLibraryError.ioFailure(errno) }
                    return FileHandle(fileDescriptor: duplicate, closeOnDealloc: true)
                }
                defer { try? handle.close() }
                let descriptor = handle.fileDescriptor
                let before = try Snapshot(descriptor: descriptor)
                let frame = try await decoder.decode(descriptor: handle, declaredByteCount: original.byteCount)
                try pin.withVerifiedDescriptor { _ in () }
                guard try Snapshot(descriptor: descriptor) == before,
                      try validateTarget(requested, session).contentHash == original.contentHash else { throw DICOMSliceServiceError.integrityFailure }
                try frame.validate()
                guard try DICOMImageAttributesMapper.attributes(for: frame) == requested.attributes else { throw DICOMSliceServiceError.integrityFailure }
                let ticket = DICOMSliceLifecycleTicket {
                    let current = try validateTarget(requested, session)
                    guard current.contentHash == original.contentHash else { throw DICOMSliceServiceError.staleSession }
                    let directory = try repository.store.admission.withLock { try repository.store.originalDirectoryDescriptor() }
                    defer { Darwin.close(directory) }
                    let fd = openat(directory, repository.store.originalFilename(original.id), O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
                    guard fd >= 0 else { throw DICOMSliceServiceError.integrityFailure }
                    defer { Darwin.close(fd) }
                    guard try Snapshot(descriptor: fd) == before else { throw DICOMSliceServiceError.integrityFailure }
                }
                try ticket.validate()
                return DICOMVerifiedDecodedFrame(frame: frame, lifecycle: ticket)
            } catch SQLiteLibraryError.invalidOriginal { throw DICOMSliceServiceError.integrityFailure }
        }
    }

    private func validateTarget(_ requested: DICOMSliceInstanceDescriptor, _ session: DICOMSliceSeriesSession) throws -> SQLiteOriginal {
        try repository.store.read(epoch: repository.epoch) { db in
            guard case let .sqlite(libraryID, epoch, studyID, revision, seriesID, seriesHash) = session.token.identity,
                  epoch == repository.epoch, studyID == session.studyID, seriesID == session.seriesID,
                  try SQLiteLibraryState.read(from: db).libraryID == libraryID else { throw DICOMSliceServiceError.staleSession }
            try repository.store.requireUnquarantined(.study, studyID)
            let study = try SQLiteDICOMRows.summary(SQLiteDICOMRows.studyRow(studyID, db))
            guard study.contentRevision == revision else { throw DICOMSliceServiceError.staleSession }
            guard let seriesRow = try Row.fetchOne(db, sql: "SELECT * FROM dicom_series WHERE study_id = ? AND series_id = ?",
                arguments: [studyID.sqliteBytes, session.seriesID.sqliteBytes]) else { throw DICOMSliceServiceError.staleSession }
            let series = try SQLiteDICOMRows.seriesSummary(seriesRow)
            guard seriesRow["content_hash"] as Data == seriesHash, series.orderingProvenance == session.orderingProvenance, series.sliceCount == session.instances.count,
                  series.rows == requested.attributes.rows, series.columns == requested.attributes.columns else { throw DICOMSliceServiceError.staleSession }
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM dicom_instances WHERE study_id = ? AND series_id = ? AND instance_id = ?",
                arguments: [studyID.sqliteBytes, session.seriesID.sqliteBytes, requested.id.sqliteBytes]) else { throw DICOMSliceServiceError.staleSession }
            let instance = try SQLiteDICOMRows.instance(row)
            guard instance.attachmentID == requested.attachmentID, instance.attributes == requested.attributes,
                  let objectRow = try Row.fetchOne(db, sql: "SELECT * FROM dicom_objects WHERE study_id = ? AND original_id = ?", arguments: [studyID.sqliteBytes, requested.attachmentID.sqliteBytes]) else { throw DICOMSliceServiceError.integrityFailure }
            let (_, original) = try SQLiteDICOMRows.object(objectRow, db)
            guard original.sha256 == requested.contentDigest, original.byteCount == requested.objectByteCount else { throw DICOMSliceServiceError.integrityFailure }
            return original
        }
    }

    private struct Snapshot: Equatable, Sendable {
        let identity: SQLiteFileIdentity
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        init(descriptor: Int32) throws {
            do { identity = try SQLiteFileIdentity.regular(descriptor: descriptor) }
            catch SQLiteLibraryError.invalidPath { throw DICOMSliceServiceError.integrityFailure }
            var value = stat()
            guard fstat(descriptor, &value) == 0 else { throw DICOMSliceServiceError.integrityFailure }
            size = value.st_size; modifiedSeconds = Int64(value.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
        }
    }
}
