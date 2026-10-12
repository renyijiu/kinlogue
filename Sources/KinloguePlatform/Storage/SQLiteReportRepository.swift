import Darwin
import Foundation
import GRDB
import KinlogueCore

package actor SQLiteReportRepository: ImportDraftStore {
    let store: SQLiteLibraryStore

    package init(store: SQLiteLibraryStore) { self.store = store }

    @concurrent
    package nonisolated func members() async throws -> [FamilyMember] { try store.read(SQLiteReportRows.members) }
    @concurrent
    package nonisolated func member(_ id: UUID) async throws -> FamilyMember { try store.read { try usableMember(id, $0) } }

    @concurrent
    package nonisolated func saveMember(_ member: FamilyMember, replacing expected: FamilyMember?) async throws {
        _ = try SQLiteEntityBudget.memberData(member)
        try store.write { db in
            let row = try SQLiteRows.fetchOne(db, sql: "SELECT revision FROM members WHERE id = ?", arguments: [member.id.sqliteBytes])
            let revision: Int64
            if let expected {
                guard let row else { throw LibraryReportError.memberNotFound }
                guard try usableMember(member.id, db) == expected, expected.id == member.id else { throw LibraryReportError.staleRevision }
                let previous: Int64 = row["revision"]
                guard previous < Int64.max else { throw LibraryReportError.resourceLimit }
                revision = previous + 1
            } else {
                guard row == nil else { throw LibraryReportError.staleRevision }
                guard try Int.fetchOne(db, sql: "SELECT count(*) FROM members")! < 256 else { throw LibraryReportError.resourceLimit }
                revision = 0
            }
            if member.isArchived,
               try Int.fetchOne(db, sql: "SELECT count(*) FROM dicom_studies WHERE state = 'confirmed' AND member_id = ?", arguments: [member.id.sqliteBytes])! > 0 {
                throw LibraryReportError.invalidDocument
            }
            try SQLiteReportRows.saveMember(member, revision: revision, db)
            try SQLiteLibraryState.advance(in: db)
        }
    }

    @concurrent
    package nonisolated func deleteMember(_ id: UUID) async throws {
        try store.write { db in
            _ = try usableMember(id, db)
            let records = try Int.fetchOne(db, sql: "SELECT count(*) FROM reports WHERE member_id = ?", arguments: [id.sqliteBytes])!
            let drafts = try Int.fetchOne(db, sql: "SELECT count(*) FROM import_drafts WHERE member_id = ?", arguments: [id.sqliteBytes])!
            guard records == 0, drafts == 0 else {
                throw CatalogDeletionError.memberStillReferenced(recordCount: records, draftCount: drafts)
            }
            let studies = try Int.fetchOne(db, sql: "SELECT count(*) FROM dicom_studies WHERE member_id = ?", arguments: [id.sqliteBytes])!
            guard studies == 0 else { throw CatalogDeletionError.memberStillReferencedByDICOMStudy(studyCount: studies) }
            try db.execute(sql: "DELETE FROM members WHERE id = ?", arguments: [id.sqliteBytes])
            try SQLiteLibraryState.advance(in: db)
        }
    }

    @concurrent
    package nonisolated func draft(_ id: UUID) async throws -> ImportDraft { try readDraft(id) }
    private nonisolated func readDraft(_ id: UUID) throws -> ImportDraft { try store.read { try usableDraft(id, $0) } }
    @concurrent
    package nonisolated func record(_ id: UUID) async throws -> HealthRecord { try readRecord(id) }
    private nonisolated func readRecord(_ id: UUID) throws -> HealthRecord { try store.read { try usableRecord(id, $0) } }

    @concurrent
    package nonisolated func records(_ ids: [UUID]) async throws -> [HealthRecord] {
        guard ids.count <= VaultReadSnapshotPolicy.maximumObjectCount, Set(ids).count == ids.count else { throw LibraryReportError.resourceLimit }
        return try store.read { db in
            var count = 0
            return try ids.map { id in
                let size = try Int.fetchOne(db, sql: "SELECT length(payload) FROM report_details WHERE record_id = ?", arguments: [id.sqliteBytes]) ?? 0
                count += size
                guard count <= VaultReadSnapshotPolicy.maximumRetainedByteCount else { throw LibraryReportError.resourceLimit }
                return try usableRecord(id, db)
            }
        }
    }

    @concurrent
    package nonisolated func reportPage(query: String = "", memberID: UUID? = nil, limit: Int = 100,
                            cursor: LibraryQueryCursor? = nil) async throws -> LibraryReportPage {
        guard (1...100).contains(limit) else { throw LibraryReportError.resourceLimit }
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let cancellation = SQLiteReportQueryCancellation()
        return try await withTaskCancellationHandler {
            do {
                try cancellation.check()
                return try store.read { db in
                    let state = try SQLiteLibraryState.read(from: db)
                    let epoch = store.openEpoch
                    try Self.validate(cursor, state: state, epoch: epoch, scope: "reports:" + term, memberID: memberID)
                    let revision = LibraryRevision(libraryID: state.libraryID, openEpoch: epoch,
                        generation: UInt64(state.generation), commitID: state.commitID)
                    if !term.isEmpty {
                        let scan = try SQLiteReportSearch.scan(db, term: term, memberID: memberID, cursor: cursor,
                            maximumMatches: limit + 1, cancellation: cancellation)
                        var items: [LibraryReportSummary] = [], damaged: [UUID] = []
                        for match in scan.matches.prefix(limit) {
                            try cancellation.check()
                            if match.damaged { damaged.append(match.id); continue }
                            guard let row = try SQLiteRows.fetchOne(db, sql: "SELECT \(SQLiteReportRows.summaryProjection) FROM reports WHERE record_id=?", arguments: [match.id.sqliteBytes]) else { throw SQLiteLibraryError.damaged }
                            do {
                                guard !(row["oversized"] as Bool) else { throw SQLiteLibraryError.damaged }
                                try store.requireUnquarantined(.report, SQLiteReportRows.uuid(row, "record_id"))
                            items.append(try SQLiteReportRows.summary(row))
                            } catch { damaged.append(match.id) }
                        }
                        let next = scan.matches.count > limit ? scan.matches.prefix(limit).last.map {
                            LibraryQueryCursor(libraryID: state.libraryID, commitID: state.commitID, openEpoch: epoch,
                                scope: "reports:" + term, memberID: memberID, lastID: $0.id, lastDate: $0.date)
                        } : nil
                        return LibraryReportPage(revision: revision, items: items, nextCursor: next,
                            damagedIDs: damaged, damagedMemberIDs: scan.damagedMemberIDs)
                    }
                    var predicates: [String] = [], arguments: [DatabaseValue] = []
                    if let memberID { predicates.append("member_id = ?"); arguments.append(memberID.sqliteBytes.databaseValue) }
                    if let cursor {
                        if let date = cursor.lastDate {
                            predicates.append("(timeline_date < ? OR timeline_date IS NULL OR (timeline_date = ? AND record_id > ?))")
                            arguments += [date.timeIntervalSince1970.databaseValue, date.timeIntervalSince1970.databaseValue, cursor.lastID.sqliteBytes.databaseValue]
                        } else { predicates.append("timeline_date IS NULL AND record_id > ?"); arguments.append(cursor.lastID.sqliteBytes.databaseValue) }
                    }
                    arguments.append((limit + 1).databaseValue)
                    let condition = predicates.isEmpty ? "" : " WHERE " + predicates.joined(separator: " AND ")
                    let rows = try SQLiteRows.fetchAll(db, sql: "SELECT \(SQLiteReportRows.summaryProjection) FROM reports\(condition) ORDER BY timeline_date DESC, record_id LIMIT ?", arguments: StatementArguments(arguments))
                    try cancellation.check()
                    var items: [LibraryReportSummary] = [], damaged: [UUID] = []
                    for row in rows.prefix(limit) {
                        do {
                            guard !(row["oversized"] as Bool) else { throw SQLiteLibraryError.damaged }
                            try store.requireUnquarantined(.report, SQLiteReportRows.uuid(row, "record_id"))
                            items.append(try SQLiteReportRows.summary(row))
                        } catch { damaged.append(try SQLiteReportRows.uuid(row, "record_id")) }
                    }
                    let next = try rows.count > limit ? rows.prefix(limit).last.map { row in
                        LibraryQueryCursor(libraryID: state.libraryID, commitID: state.commitID, openEpoch: epoch, scope: "reports:", memberID: memberID,
                            lastID: try SQLiteReportRows.uuid(row, "record_id"), lastDate: (row["timeline_date"] as Double?).map(Date.init(timeIntervalSince1970:)))
                    } : nil
                    return LibraryReportPage(revision: revision, items: items, nextCursor: next, damagedIDs: damaged)
                }
            } catch { try cancellation.check(); throw error }
        } onCancel: { cancellation.cancel() }
    }

    @concurrent
    package nonisolated func drafts(limit: Int = 100, cursor: LibraryQueryCursor? = nil) async throws -> LibraryDraftPage {
        guard (1...100).contains(limit) else { throw LibraryReportError.resourceLimit }
        return try store.read { db in
            let state = try SQLiteLibraryState.read(from: db)
            try Self.validate(cursor, state: state, epoch: store.openEpoch, scope: "drafts", memberID: nil)
            let rows = try SQLiteRows.fetchAll(db, sql: "SELECT * FROM import_drafts\(cursor == nil ? "" : " WHERE draft_id > ?") ORDER BY draft_id LIMIT ?",
                arguments: StatementArguments((cursor.map { [$0.lastID.sqliteBytes.databaseValue] } ?? []) + [(limit + 1).databaseValue]))
            var items: [LibraryDraftSummary] = []
            var damaged: [UUID] = []
            for row in rows.prefix(limit) {
                let id = try SQLiteReportRows.uuid(row, "draft_id")
                do {
                    try store.requireUnquarantined(.draft, id)
                    try SQLiteReportRows.verify(row, table: "import_drafts", columns: SQLiteReportRows.draftColumns)
                    guard let status = ImportState(rawValue: row["state"]) else { throw SQLiteLibraryError.damaged }
                    let failure: String? = row["failure_code"]
                    items.append(LibraryDraftSummary(id: id, state: status, revision: UInt64(row["revision"] as Int64),
                        memberID: try SQLiteReportRows.optionalUUID(row, "member_id"), failureCode: failure.flatMap(ImportFailureCode.init(rawValue:)), sourceCount: row["source_count"]))
                } catch { damaged.append(id) }
            }
            let next = try rows.count > limit ? rows.prefix(limit).last.map { row in
                LibraryQueryCursor(libraryID: state.libraryID, commitID: state.commitID, openEpoch: store.openEpoch, scope: "drafts", memberID: nil,
                                   lastID: try SQLiteReportRows.uuid(row, "draft_id"), lastDate: nil)
            } : nil
            return LibraryDraftPage(revision: LibraryRevision(libraryID: state.libraryID, openEpoch: store.openEpoch, generation: UInt64(state.generation), commitID: state.commitID), items: items, nextCursor: next, damagedIDs: damaged)
        }
    }

    private static func validate(_ cursor: LibraryQueryCursor?, state: SQLiteLibraryState, epoch: UUID, scope: String, memberID: UUID?) throws {
        guard let cursor else { return }
        guard cursor.libraryID == state.libraryID, cursor.commitID == state.commitID, cursor.openEpoch == epoch,
              cursor.scope == scope, cursor.memberID == memberID else { throw LibraryReportError.staleCursor }
    }

    package func stage(_ file: ValidatedImportedFile) throws -> ImportStageOutcome {
        try Task.checkCancellation()
        guard !file.data.isEmpty, file.data.count <= 100 * 1_024 * 1_024, file.pageCount <= 200 else { throw LibraryReportError.resourceLimit }
        guard ContentDigest.sha256(file.data) == file.sha256Digest else { throw SQLiteLibraryError.invalidOriginal }
        let fingerprint = ContentDigest.sha256(try CanonicalVaultJSON.encode(ReportFingerprint(sources: [
            .init(sha256Digest: file.sha256Digest, byteCount: file.data.count)
        ])))
        if let duplicate = try verifiedDuplicate(fingerprint: fingerprint) { return duplicate }
        guard let temporary = tmpfile() else { throw SQLiteLibraryError.ioFailure(errno) }
        defer { fclose(temporary) }
        let descriptor = fileno(temporary)
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else { throw SQLiteLibraryError.ioFailure(errno) }
        try file.data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                let written = pwrite(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, off_t(offset))
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw SQLiteLibraryError.ioFailure(errno) }
                offset += written
            }
        }
        let operation = UUID()
        var proposed: ImportDraft?
        do {
            let id = try store.stageOriginal(copyingFrom: descriptor, byteCount: file.data.count, sha256: file.sha256Digest,
                                             contentType: file.contentTypeIdentifier, operationID: operation)
            let draft = ImportDraft(sources: try ReportSources([ReportSource(attachmentID: id, pageCount: file.pageCount)]))
            proposed = draft
            try store.publishOriginal(id, operationID: operation) { db in
                try Self.checkNewDraftCapacity(originalIDs: [id], db)
                try SQLiteReportRows.saveDraft(draft, documentHash: nil, db, replaceSources: true)
                try SQLiteLibraryState.advance(in: db)
            }
            return .created(draft.id)
        } catch {
            // A committed live original belongs to the draft, even when the response was lost.
            if let proposed, (try? store.read({ db in
                let original = try SQLiteOriginal.read(proposed.sources.first.attachmentID, from: db)
                let current = try usableDraft(proposed.id, db)
                return original.operationID == operation && original.lifecycle == "live" && current.sources == proposed.sources
            })) == true { return .created(proposed.id) }
            let failure = SQLiteLibraryStore.sanitized(error)
            // The operation is known even if staging threw before returning an original ID.
            guard try store.reclaimOriginals(operationID: operation).isEmpty else { throw SQLiteLibraryError.invalidOriginal }
            throw failure
        }
    }

    static func checkNewDraftCapacity(originalIDs: Set<UUID>, _ db: Database) throws {
        let retained = try Int.fetchOne(db, sql: "SELECT count(*) FROM (SELECT original_id FROM report_sources UNION SELECT original_id FROM dicom_objects)")!
        var added = 0
        for id in originalIDs {
            if try Int.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM report_sources WHERE original_id = ? UNION ALL SELECT 1 FROM dicom_objects WHERE original_id = ?)", arguments: [id.sqliteBytes, id.sqliteBytes]) == 0 { added += 1 }
        }
        guard try Int.fetchOne(db, sql: "SELECT count(*) FROM import_drafts")! < 20_000,
              retained + added <= 20_000 else { throw LibraryReportError.resourceLimit }
    }

    @concurrent
    package nonisolated func beginProcessing(draftID: UUID, attemptID: UUID) async throws -> ImportProcessingLease {
        try Task.checkCancellation()
        return try store.write { db in
            let next = try usableDraft(draftID, db).startingProcessing(attemptID: attemptID)
            try SQLiteReportRows.saveDraft(next, documentHash: nil, db)
            try SQLiteLibraryState.advance(in: db)
            return ImportProcessingLease(draftID: draftID, revision: next.revision, attemptID: attemptID)
        }
    }

    @concurrent
    package nonisolated func loadSource(draftID: UUID) async throws -> ValidatedImportedFile {
        let (captured, epoch) = try store.readWithEpoch { try usableDraft(draftID, $0) }
        guard let source = captured.sources.soleSource else { throw LibraryReportError.invalidDocument }
        let (attachment, bytes) = try original(source.attachmentID)
        guard try store.read(epoch: epoch, { db in try usableDraft(draftID, db) == captured }) else { throw ImportDraftError.staleAttempt }
        return try ValidatedImportedFile(data: bytes, kind: attachment.contentTypeIdentifier == "com.adobe.pdf" ? .pdf : .image,
            contentTypeIdentifier: attachment.contentTypeIdentifier, sha256Digest: attachment.sha256Digest, pageCount: source.pageCount)
    }

    @concurrent
    package nonisolated func completeProcessing(lease: ImportProcessingLease, document: ImportDraftDocument) async throws {
        try Task.checkCancellation()
        try store.write { db in
            let next = try usableDraft(lease.draftID, db).completingProcessing(
                expectedRevision: lease.revision, attemptID: lease.attemptID, documentObjectID: UUID())
            let hash = try SQLiteReportRows.saveDocument(document, id: next.documentObjectID!, revision: next.revision, sources: next.sources, db)
            try SQLiteReportRows.saveDraft(next, documentHash: hash, db)
            try SQLiteLibraryState.advance(in: db)
        }
    }

    @concurrent
    package nonisolated func failProcessing(lease: ImportProcessingLease, failureCode: ImportFailureCode) async throws {
        try store.write { db in
            let next = try usableDraft(lease.draftID, db).failingProcessing(
                expectedRevision: lease.revision, attemptID: lease.attemptID, failureCode: failureCode)
            try SQLiteReportRows.saveDraft(next, documentHash: nil, db)
            try SQLiteLibraryState.advance(in: db)
        }
    }

    @concurrent
    package nonisolated func resumableDraftIDs() async throws -> [UUID] {
        try store.read { db in
            let rows = try SQLiteRows.fetchAll(db, sql: "SELECT * FROM import_drafts WHERE state IN ('staging','processing') ORDER BY draft_id LIMIT 20001")
            guard rows.count <= 20_000 else { throw SQLiteLibraryError.damaged }
            // A corrupt target stays visible as damaged in draftPage; it must not prevent healthy
            // targets or the library header from opening. This loop performs no fallible SQL reads.
            return rows.compactMap { row in
                guard (try? SQLiteReportRows.verify(row, table: "import_drafts", columns: SQLiteReportRows.draftColumns)) != nil else { return nil }
                return try? SQLiteReportRows.uuid(row, "draft_id")
            }
        }
    }

    @concurrent
    package nonisolated func loadDocument(draftID: UUID) async throws -> ImportDraftDocument {
        try store.read { db in
            let draft = try usableDraft(draftID, db)
            guard let id = draft.documentObjectID else { throw LibraryReportError.invalidDocument }
            return try SQLiteReportRows.document(id, sources: draft.sources, expectedHash: SQLiteReportRows.draftRow(draftID, db)["document_hash"], db)
        }
    }

    @concurrent
    package nonisolated func loadReviewSnapshot(draftID: UUID) async throws -> ImportDraftReviewSnapshot {
        let ((draft, document, members, attachment), epoch) = try store.readWithEpoch { db in
            let draft = try usableDraft(draftID, db)
            guard draft.state == .needsReview, let id = draft.documentObjectID else { throw LibraryReportError.invalidDocument }
            return (draft, try SQLiteReportRows.document(id, sources: draft.sources,
                expectedHash: SQLiteReportRows.draftRow(draftID, db)["document_hash"], db),
                try SQLiteReportRows.members(db), try SQLiteReportRows.attachment(draft.sources.first.attachmentID, db))
        }
        let (actual, bytes) = try original(attachment.id)
        guard actual == attachment, try store.read(epoch: epoch, { db in try usableDraft(draftID, db) == draft }) else { throw ImportDraftError.staleAttempt }
        return ImportDraftReviewSnapshot(draft: draft, document: document, members: members, attachment: attachment, originalData: bytes)
    }

    @concurrent
    package nonisolated func saveReview(draftID: UUID, expectedRevision: UInt64, memberID: UUID?, document: ImportDraftDocument) async throws {
        try Task.checkCancellation()
        guard document.reviewState != nil else { throw LibraryReportError.invalidDocument }
        try store.write { db in
            let original = try usableDraft(draftID, db)
            guard let id = original.documentObjectID else { throw LibraryReportError.invalidDocument }
            _ = try SQLiteReportRows.document(id, sources: original.sources,
                expectedHash: SQLiteReportRows.draftRow(draftID, db)["document_hash"], db)
            try SQLiteReportRows.requireMember(memberID, in: db)
            let next = try original.savingReview(expectedRevision: expectedRevision, memberID: memberID, documentObjectID: id)
            let digest = try SQLiteReportRows.saveDocument(document, id: id, revision: next.revision, sources: next.sources, db)
            try SQLiteReportRows.saveDraft(next, documentHash: digest, db)
            try SQLiteLibraryState.advance(in: db)
        }
    }

    @concurrent
    package nonisolated func confirm(draftID: UUID, expectedRevision: UInt64, record: HealthRecord) async throws {
        try Task.checkCancellation()
        try store.write { db in
            let draft = try usableDraft(draftID, db)
            guard draft.revision == expectedRevision else { throw ImportDraftError.staleAttempt }
            guard draft.state == .needsReview, record.importState == .confirmed, record.sources == draft.sources,
                  record.ocrDocumentObjectID == draft.documentObjectID,
                  try Int.fetchOne(db, sql: "SELECT count(*) FROM reports WHERE record_id = ?", arguments: [record.id.sqliteBytes]) == 0 else { throw LibraryReportError.invalidDocument }
            guard try Int.fetchOne(db, sql: "SELECT count(*) FROM reports")! < 20_000 else { throw LibraryReportError.resourceLimit }
            try SQLiteReportRows.requireMember(record.memberID, in: db)
            let hash: Data? = try SQLiteReportRows.draftRow(draftID, db)["document_hash"]
            _ = try SQLiteReportRows.document(draft.documentObjectID!, sources: draft.sources, expectedHash: hash, db)
            try db.execute(sql: "DELETE FROM report_sources WHERE draft_id = ?", arguments: [draftID.sqliteBytes])
            try db.execute(sql: "DELETE FROM import_drafts WHERE draft_id = ?", arguments: [draftID.sqliteBytes])
            try SQLiteReportRows.saveRecord(record, documentHash: hash, db)
            try SQLiteLibraryState.advance(in: db)
        }
    }

    @concurrent
    package nonisolated func updateRecord(_ record: HealthRecord, expectedRevision: UInt64) async throws {
        try Task.checkCancellation()
        try store.write { db in
            let current = try usableRecord(record.id, db)
            guard current.revision == expectedRevision else { throw LibraryReportError.staleRevision }
            guard expectedRevision < Int64.max, record.revision == expectedRevision + 1,
                  record.sources == current.sources, record.ocrDocumentObjectID == current.ocrDocumentObjectID else { throw LibraryReportError.invalidDocument }
            try SQLiteReportRows.requireMember(record.memberID, allowArchived: current.memberID == record.memberID, in: db)
            let hash = try Data.fetchOne(db, sql: "SELECT document_hash FROM reports WHERE record_id = ?", arguments: [record.id.sqliteBytes])
            try SQLiteReportRows.saveRecord(record, documentHash: hash, db)
            try SQLiteLibraryState.advance(in: db)
        }
    }

    @concurrent
    package nonisolated func deleteRecord(_ id: UUID, expectedRevision: UInt64) async throws {
        let originals = try store.write { db in
            let current = try usableRecord(id, db)
            guard current.revision == expectedRevision else { throw LibraryReportError.staleRevision }
            try db.execute(sql: "DELETE FROM report_sources WHERE report_id = ?", arguments: [id.sqliteBytes])
            try db.execute(sql: "DELETE FROM report_details WHERE record_id = ?", arguments: [id.sqliteBytes])
            try db.execute(sql: "DELETE FROM report_search WHERE record_id = ?", arguments: [id.sqliteBytes])
            try db.execute(sql: "DELETE FROM reports WHERE record_id = ?", arguments: [id.sqliteBytes])
            try SQLiteReportRows.deleteDocumentIfUnreferenced(current.ocrDocumentObjectID, db)
            try store.markUnreferencedOriginalsDeleting(Set(current.sources.attachmentIDs), in: db)
            try SQLiteLibraryState.advance(in: db)
            return Set(current.sources.attachmentIDs)
        }
        for id in originals { try? store.reclaimDeletingOriginal(id) }
    }

    @concurrent
    package nonisolated func discard(draftID: UUID, expectedRevision: UInt64) async throws {
        let originals = try store.write { db in
            let current = try usableDraft(draftID, db)
            guard current.revision == expectedRevision else { throw ImportDraftError.staleAttempt }
            try db.execute(sql: "DELETE FROM report_sources WHERE draft_id = ?", arguments: [draftID.sqliteBytes])
            try db.execute(sql: "DELETE FROM import_drafts WHERE draft_id = ?", arguments: [draftID.sqliteBytes])
            try SQLiteReportRows.deleteDocumentIfUnreferenced(current.documentObjectID, db)
            try store.markUnreferencedOriginalsDeleting(Set(current.sources.attachmentIDs), in: db)
            try SQLiteLibraryState.advance(in: db)
            return Set(current.sources.attachmentIDs)
        }
        for id in originals { try? store.reclaimDeletingOriginal(id) }
    }

    @concurrent
    package nonisolated func original(recordID: UUID, expectedRevision: UInt64, sourceID: UUID) async throws -> (Attachment, Data) {
        let (captured, epoch) = try store.readWithEpoch { try usableRecord(recordID, $0) }
        guard captured.revision == expectedRevision else { throw LibraryReportError.staleRevision }
        guard let source = captured.sources.elements.first(where: { $0.id == sourceID }) else { throw LibraryReportError.invalidDocument }
        let result = try original(source.attachmentID)
        guard try store.read(epoch: epoch, { db in try usableRecord(recordID, db) == captured }) else { throw LibraryReportError.staleRevision }
        return result
    }

    @concurrent
    package nonisolated func original(draftID: UUID, expectedRevision: UInt64, sourceID: UUID) async throws -> (Attachment, Data) {
        let (captured, epoch) = try store.readWithEpoch { try usableDraft(draftID, $0) }
        guard captured.revision == expectedRevision else { throw ImportDraftError.staleAttempt }
        guard let source = captured.sources.elements.first(where: { $0.id == sourceID }) else { throw LibraryReportError.invalidDocument }
        let result = try original(source.attachmentID)
        guard try store.read(epoch: epoch, { db in try usableDraft(draftID, db) == captured }) else { throw ImportDraftError.staleAttempt }
        return result
    }

    private nonisolated func original(_ id: UUID) throws -> (Attachment, Data) {
        let attachment = try store.read { try SQLiteReportRows.attachment(id, $0) }
        let pin = try store.pinOriginal(id)
        defer { pin.release() }
        let bytes = try pin.withVerifiedDescriptor { descriptor in
            var data = Data(count: attachment.byteCount)
            try data.withUnsafeMutableBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    try Task.checkCancellation()
                    let count = pread(descriptor, buffer.baseAddress!.advanced(by: offset), min(1_024 * 1_024, buffer.count - offset), off_t(offset))
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw SQLiteLibraryError.invalidOriginal }
                    offset += count
                }
            }
            guard ContentDigest.sha256(data) == attachment.sha256Digest else { throw SQLiteLibraryError.invalidOriginal }
            return data
        }
        return (attachment, bytes)
    }

    private nonisolated func verifiedDuplicate(fingerprint: Data) throws -> ImportStageOutcome? {
        let candidates: [(Bool, UUID)] = try store.read { db in
            let records = try Data.fetchAll(db, sql: "SELECT record_id FROM reports WHERE fingerprint_version = ? AND fingerprint = ? ORDER BY record_id", arguments: [ReportFingerprint.currentVersion, fingerprint])
            let drafts = try Data.fetchAll(db, sql: "SELECT draft_id FROM import_drafts WHERE state = 'needsReview' AND fingerprint_version = ? AND fingerprint = ? ORDER BY draft_id", arguments: [ReportFingerprint.currentVersion, fingerprint])
            return try records.map { bytes in
                guard let id = UUID(sqliteBytes: bytes) else { throw SQLiteLibraryError.damaged }; return (true, id)
            } + drafts.map { bytes in
                guard let id = UUID(sqliteBytes: bytes) else { throw SQLiteLibraryError.damaged }; return (false, id)
            }
        }
        for (isRecord, id) in candidates {
            try Task.checkCancellation()
            do {
                let (captured, epoch): ((ReportSources, UInt64, Data?), UUID) = try store.readWithEpoch { db in
                    let sources: ReportSources
                    let revision: UInt64
                    let documentID: UUID?
                    let documentHash: Data?
                    if isRecord {
                        let value = try usableRecord(id, db)
                        sources = value.sources; revision = value.revision; documentID = value.ocrDocumentObjectID
                        documentHash = try Data.fetchOne(db, sql: "SELECT document_hash FROM reports WHERE record_id = ?", arguments: [id.sqliteBytes])
                    } else {
                        let value = try usableDraft(id, db)
                        guard value.state == .needsReview else { throw LibraryReportError.staleRevision }
                        sources = value.sources; revision = value.revision; documentID = value.documentObjectID
                        documentHash = try SQLiteReportRows.draftRow(id, db)["document_hash"]
                    }
                    guard try SQLiteReportRows.fingerprint(sources, db) == fingerprint else { throw SQLiteLibraryError.damaged }
                    if let documentID { _ = try SQLiteReportRows.document(documentID, sources: sources, expectedHash: documentHash, db) }
                    return (sources, revision, documentHash)
                }
                for originalID in Set(captured.0.attachmentIDs) {
                    let pin = try store.pinOriginal(originalID)
                    defer { pin.release() }
                    try pin.withVerifiedDescriptor { _ in }
                }
                let unchanged = try store.read(epoch: epoch) { db in
                    if isRecord {
                        let current = try usableRecord(id, db)
                        return try current.revision == captured.1 && current.sources == captured.0
                            && (try Data.fetchOne(db, sql: "SELECT document_hash FROM reports WHERE record_id = ?", arguments: [id.sqliteBytes])) == captured.2
                    }
                    let current = try usableDraft(id, db)
                    return try current.state == .needsReview && current.revision == captured.1 && current.sources == captured.0
                        && (try SQLiteReportRows.draftRow(id, db)["document_hash"] as Data?) == captured.2
                }
                if unchanged { return isRecord ? .existingRecord(id) : .existingDraft(id) }
            } catch is CancellationError { throw CancellationError() }
            catch let error as SQLiteLibraryError where [.closed, .staleRoot, .occupied, .unsupportedFormat].contains(error) { throw error }
            catch { continue }
        }
        return nil
    }
}

// SAFETY: SQLite executes on GRDB's queue, so cancellation crosses that boundary through this locked flag.
final class SQLiteReportQueryCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.withLock { cancelled = true } }
    func check() throws { if lock.withLock({ cancelled }) { throw CancellationError() } }
}
