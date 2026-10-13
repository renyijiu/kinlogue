import Foundation
import GRDB
import KinlogueCore

struct SQLiteDICOMImportSession: Sendable {
    let operationID: UUID
    let libraryID: UUID
    let epoch: UUID
    let ownership: DICOMStagingOwnership
}

package final class SQLiteDICOMRepository: Sendable, DICOMImportStoring {
    let store: SQLiteLibraryStore
    let epoch: UUID

    package init(store: SQLiteLibraryStore) throws {
        self.store = store
        epoch = try store.readWithEpoch { _ in () }.1
        try recoverImports()
    }

    @concurrent
    package func summaries() async throws -> LibraryDICOMStudyListing {
        try await LibraryStorageExecutor.run {
            try store.read(epoch: epoch) { db in
                let state = try SQLiteLibraryState.read(from: db)
                let rows = try SQLiteRows.fetchAll(db, sql: "SELECT \(SQLiteDICOMRows.studyProjection) FROM dicom_studies ORDER BY id LIMIT 257")
                guard rows.count <= 256 else { throw DICOMImportError.resourceLimit }
                var items: [LibraryDICOMStudySummary] = [], damagedIDs: [UUID] = []
                for row in rows {
                    let id = try SQLiteReportRows.uuid(row, "id")
                    do { try store.requireUnquarantined(.study, id); items.append(try SQLiteDICOMRows.summary(row)) }
                    catch DICOMSliceServiceError.integrityFailure { damagedIDs.append(id) }
                    catch SQLiteLibraryError.damaged { damagedIDs.append(id) }
                }
                return LibraryDICOMStudyListing(revision: LibraryRevision(libraryID: state.libraryID, openEpoch: epoch,
                    generation: UInt64(state.generation), commitID: state.commitID), items: items, damagedIDs: damagedIDs)
            }
        }
    }

    @concurrent
    package func details(_ id: UUID) async throws -> LibraryDICOMStudyDetails {
        try await LibraryStorageExecutor.run {
            try store.read(epoch: epoch) { db in
                try store.requireUnquarantined(.study, id)
                let row = try SQLiteDICOMRows.studyRow(id, db), summary = try SQLiteDICOMRows.summary(row)
                let rows = try SQLiteRows.fetchAll(db, sql: "SELECT * FROM dicom_series WHERE study_id = ? ORDER BY ordinal LIMIT 4097", arguments: [id.sqliteBytes])
                guard rows.count == summary.seriesCount,
                      SQLiteDICOMRows.collectionHash("dicom-study-series", rows.map { $0["content_hash"] }) == row["series_hash"] as Data else { throw DICOMSliceServiceError.integrityFailure }
                try SQLiteDICOMRows.validateSeriesOrdinals(rows.map { $0["ordinal"] })
                return LibraryDICOMStudyDetails(study: summary, series: try rows.map(SQLiteDICOMRows.seriesSummary))
            }
        }
    }

    @concurrent
    package func confirm(_ id: UUID, expectedRevision: UInt64, memberID: UUID, effectiveDate: Date) async throws -> LibraryDICOMStudySummary {
        try await LibraryStorageExecutor.run {
            guard effectiveDate.timeIntervalSince1970.isFinite, expectedRevision < UInt64(Int64.max) else { throw DICOMImportError.integrityFailure }
            return try store.write { db in
                guard store.openEpoch == epoch else { throw SQLiteLibraryError.staleRoot }
                try store.requireUnquarantined(.study, id)
                let row = try SQLiteDICOMRows.studyRow(id, db)
                guard row["content_revision"] as Int64 == Int64(expectedRevision) else { throw DICOMImportError.publicationConflict }
                _ = try SQLiteDICOMRows.strictStudy(id, db)
                try SQLiteReportRows.requireMember(memberID, in: db)
                var values: [DatabaseValue] = SQLiteDICOMRows.studyColumns.map { row[$0] }
                values[1] = "confirmed".databaseValue; values[2] = memberID.sqliteBytes.databaseValue
                values[3] = effectiveDate.timeIntervalSince1970.databaseValue; values[10] = Int64(expectedRevision + 1).databaseValue
                let hash = try SQLiteDICOMRows.hash("dicom_studies", values)
                try db.execute(sql: "UPDATE dicom_studies SET state='confirmed', member_id=?, effective_date=?, content_revision=?, content_hash=? WHERE id=?",
                               arguments: [memberID.sqliteBytes, effectiveDate.timeIntervalSince1970, Int64(expectedRevision + 1), hash, id.sqliteBytes])
                try SQLiteLibraryState.advance(in: db)
                return try SQLiteDICOMRows.summary(SQLiteDICOMRows.studyRow(id, db))
            }
        }
    }

    @concurrent
    package func delete(_ id: UUID, expectedRevision: UInt64) async throws {
        try await LibraryStorageExecutor.run {
            let originalIDs = try store.write { db in
                guard store.openEpoch == epoch else { throw SQLiteLibraryError.staleRoot }
                try store.requireUnquarantined(.study, id)
                let graph = try SQLiteDICOMRows.strictStudy(id, db)
                guard graph.0.contentRevision == expectedRevision else { throw DICOMImportError.publicationConflict }
                for table in ["dicom_instances", "dicom_series", "dicom_objects"] {
                    try db.execute(sql: "DELETE FROM \(table) WHERE study_id = ?", arguments: [id.sqliteBytes])
                }
                try db.execute(sql: "DELETE FROM dicom_studies WHERE id = ?", arguments: [id.sqliteBytes])
                try store.markUnreferencedOriginalsDeleting(Set(graph.0.attachmentIDs), in: db)
                try SQLiteLibraryState.advance(in: db)
                return graph.0.attachmentIDs
            }
            for id in originalIDs { try store.reclaimDeletingOriginal(id) }
        }
    }

    @concurrent
    func beginImport(operationID: UUID, staging: DICOMStudyStaging) async throws -> DICOMImportSession {
        try await LibraryStorageExecutor.run {
            try store.admission.withLock {
                try Task.checkCancellation()
                try store.validateRoot()
                guard store.openEpoch == epoch, let queue else { throw SQLiteLibraryError.staleRoot }
                let state = try queue.read(SQLiteLibraryState.read)
                try recoverImportsLocked(libraryID: state.libraryID)
                store.activeDICOMImports.insert(operationID)
                let journal = try DICOMImportJournal(rootURL: store.rootURL)
                do {
                    try journal.begin(operationID: operationID, vaultID: state.libraryID)
                    let ownership = try staging.prepare(operationID: operationID)
                    try journal.bindStagingOwnership(ownership, operationID: operationID)
                    return SQLiteDICOMImportSession(operationID: operationID, libraryID: state.libraryID, epoch: epoch, ownership: ownership)
                } catch {
                    store.activeDICOMImports.remove(operationID)
                    try recoverImportsLocked(libraryID: state.libraryID)
                    throw error
                }
            }
        }
    }

    private var queue: DatabaseQueue? { store.queue }

    @concurrent
    func commitImport(_ proposal: DICOMIndexedStudyProposal, session: DICOMImportSession,
                      staging: DICOMStudyStaging, metrics: DICOMImportMetricsRecorder?) async throws -> DICOMImportCommit {
        try await LibraryStorageExecutor.run {
            do { return try await commitNewImport(proposal, session: session, staging: staging, metrics: metrics) }
            catch DICOMImportError.publicationConflict {
                guard let existing = try await verifiedDuplicate(proposal.study.fingerprint) else { throw DICOMImportError.publicationConflict }
                try await abortImport(session)
                return .duplicateExisting(existing)
            }
        }
    }

    @concurrent
    private func commitNewImport(_ proposal: DICOMIndexedStudyProposal, session: DICOMImportSession,
                                 staging: DICOMStudyStaging, metrics: DICOMImportMetricsRecorder?) async throws -> DICOMImportCommit {
        try await LibraryStorageExecutor.run {
            let session = try require(session)
            if let existing = try await verifiedDuplicate(proposal.study.fingerprint) {
                try await abortImport(session)
                return .duplicateExisting(existing)
            }
            guard proposal.study.state == .needsReview, proposal.study.contentRevision == 0,
                  proposal.objects.allSatisfy({ $0.staged.ownership == session.ownership }),
                  Set(proposal.objects.map(\.attachment.id)) == Set(proposal.study.attachmentIDs) else { throw DICOMImportError.integrityFailure }
            try proposal.index.validate(studyID: proposal.study.id, attachmentIDs: Set(proposal.study.attachmentIDs))
            try DICOMSeriesGeometry.validatePersistedGeometryOrder(proposal.index)
            guard try CanonicalVaultJSON.encode(proposal.index).count <= 16 * 1_024 * 1_024 else { throw DICOMImportError.resourceLimit }
            let bytes = try proposal.objects.reduce(0) { count, object in
                let sum = count.addingReportingOverflow(object.attachment.byteCount)
                guard !sum.overflow else { throw DICOMImportError.resourceLimit }; return sum.partialValue
            }
            try staging.validateCapacity(uniqueStagedBytes: bytes)
            try store.read(epoch: epoch) { db in try validateAdmission(proposal, db) }
            let journal = try DICOMImportJournal(rootURL: store.rootURL)
            try journal.verifyOwnership(operationID: session.operationID, vaultID: session.libraryID, ownership: session.ownership)
            for object in proposal.objects {
                try Task.checkCancellation()
                await metrics?.recordStagingDescriptorsOpened(3)
                do { try store.adoptDICOMOriginal(object, session: session, staging: staging) }
                catch { await metrics?.recordStagingDescriptorsClosed(3); throw error }
                await metrics?.recordStagingDescriptorsClosed(3)
                await metrics?.recordAttachmentAdoption(byteCount: object.attachment.byteCount)
            }
            await metrics?.recordStagingDescriptorsOpened(3)
            do {
                try store.publishDICOMOriginals(proposal.study.attachmentIDs, operationID: session.operationID, epoch: epoch) { db in
                    try validateAdmission(proposal, db)
                    try SQLiteDICOMRows.insertStudy(proposal.study, index: proposal.index, operationID: session.operationID, db)
                    try SQLiteLibraryState.advance(in: db)
                }
            } catch { await metrics?.recordStagingDescriptorsClosed(3); throw error }
            await metrics?.recordStagingDescriptorsClosed(3)
            for object in proposal.objects {
                await metrics?.recordPublicationValidation(digest: object.attachment.sha256Digest, byteCount: object.attachment.byteCount)
            }
            try await abortImport(session)
            return .accepted(proposal.study.id)
        }
    }

    private func validateAdmission(_ proposal: DICOMIndexedStudyProposal, _ db: Database) throws {
        guard try Int.fetchOne(db, sql: "SELECT count(*) FROM dicom_studies")! < 256,
              try Int.fetchOne(db, sql: "SELECT count(*) FROM dicom_series")! + proposal.index.series.count <= 4_096,
              try Int.fetchOne(db, sql: "SELECT count(DISTINCT original_id) FROM dicom_objects")! + proposal.objects.count <= 10_000,
              try Int.fetchOne(db, sql: "SELECT count(*) FROM (SELECT original_id FROM report_sources UNION SELECT original_id FROM dicom_objects)")! + proposal.objects.count <= 20_000 else { throw DICOMImportError.resourceLimit }
        guard try Int.fetchOne(db, sql: "SELECT count(*) FROM dicom_studies WHERE study_uid_digest = ?", arguments: [proposal.index.studyUIDDigest.digest]) == 0 else { throw DICOMImportError.publicationConflict }
    }

    @concurrent
    func abortImport(_ session: DICOMImportSession) async throws {
        try await LibraryStorageExecutor.run {
            let session = try require(session)
            try store.admission.withLock {
                store.activeDICOMImports.remove(session.operationID)
                try store.validateRoot()
                guard store.openEpoch == session.epoch else { throw SQLiteLibraryError.staleRoot }
                guard try store.recoverOriginalsLocked(operationID: session.operationID).isEmpty else {
                    throw DICOMImportError.integrityFailure
                }
                try recoverImportsLocked(libraryID: session.libraryID)
            }
        }
    }

    @concurrent
    func committedImport(_ proposal: DICOMIndexedStudyProposal, session: DICOMImportSession) async throws -> DICOMImportCommit? {
        try await LibraryStorageExecutor.run {
            let session = try require(session)
            return try store.read(epoch: session.epoch) { db in
                guard let row = try SQLiteRows.fetchOne(db, sql: "SELECT \(SQLiteDICOMRows.studyProjection) FROM dicom_studies WHERE id = ?", arguments: [proposal.study.id.sqliteBytes]) else { return nil }
                guard try SQLiteReportRows.uuid(row, "operation_id") == session.operationID else { throw DICOMImportError.integrityFailure }
                let (header, index) = try SQLiteDICOMRows.strictStudy(proposal.study.id, db)
                guard header.fingerprint == proposal.study.fingerprint, header.attachmentIDs == proposal.study.attachmentIDs,
                      Set(index.instances) == Set(proposal.index.instances), Set(index.series) == Set(proposal.index.series),
                      Set(index.retainedObjects) == Set(proposal.index.retainedObjects) else { throw DICOMImportError.integrityFailure }
                return .accepted(header.id)
            }
        }
    }

    private func require(_ session: DICOMImportSession) throws -> SQLiteDICOMImportSession {
        guard session.epoch == epoch else { throw DICOMImportError.publicationConflict }
        return session
    }
    private func recoverImports() throws {
        try store.admission.withLock {
            try store.validateRoot()
            guard store.openEpoch == epoch, let queue else { throw SQLiteLibraryError.staleRoot }
            try recoverImportsLocked(libraryID: queue.read(SQLiteLibraryState.read).libraryID)
        }
    }
    private func recoverImportsLocked(libraryID: UUID) throws {
        let result = try DICOMImportJournal(rootURL: store.rootURL).reconcile(vaultID: libraryID, retaining: [],
            excluding: store.activeDICOMImports, allowsPromotions: false)
        guard result.retryOperationCount == 0 else { throw DICOMImportError.integrityFailure }
    }
    @concurrent
    private func verifiedDuplicate(_ fingerprint: DICOMStudyFingerprint) async throws -> UUID? {
        try await LibraryStorageExecutor.run {
            let candidate = try store.read(epoch: epoch) { db -> DICOMStudyHeader? in
                guard let bytes = try Data.fetchOne(db, sql: "SELECT id FROM dicom_studies WHERE fingerprint_version = ? AND fingerprint = ? ORDER BY id LIMIT 1",
                    arguments: [fingerprint.version, ContentDigest.sha256(fingerprint.canonicalIdentityBytes)]) else { return nil }
                guard let id = UUID(sqliteBytes: bytes) else { throw DICOMImportError.integrityFailure }
                let header = try SQLiteDICOMRows.strictStudy(id, db).0
                guard header.fingerprint == fingerprint else { throw DICOMImportError.integrityFailure }
                return header
            }
            guard let candidate else { return nil }
            for id in candidate.attachmentIDs {
                let pin = try store.pinOriginal(id)
                defer { pin.release() }
                try pin.withVerifiedDescriptor { _ in () }
            }
            return try store.read(epoch: epoch) { db in
                let current = try SQLiteDICOMRows.strictStudy(candidate.id, db).0
                guard current.fingerprint == candidate.fingerprint, current.attachmentIDs == candidate.attachmentIDs else { throw DICOMImportError.publicationConflict }
                return candidate.id
            }
        }
    }
}
