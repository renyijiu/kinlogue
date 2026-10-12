import Foundation
import GRDB
import KinlogueCore

extension SQLiteReportRepository: LibraryReportStoring {
    @concurrent package nonisolated func initializeLibrary() async throws -> LibraryHeader { try await LibraryStorageExecutor.run { try await header() } }
    @concurrent package nonisolated func header() async throws -> LibraryHeader {
        try await LibraryStorageExecutor.run {
            try store.read { db in
                let revision = try self.libraryRevision(db)
                var members = try SQLiteReportRows.memberSummaries(db)
                let knownMembers = store.quarantinedIDs(.member)
                members.items.removeAll { knownMembers.contains($0.id) }
                members.damagedIDs += knownMembers
                let rows = try SQLiteRows.fetchAll(db, sql: "SELECT \(SQLiteDICOMRows.studyProjection) FROM dicom_studies ORDER BY id LIMIT 257")
                guard rows.count <= 256 else { throw LibraryReportError.resourceLimit }
                var studies: [LibraryDICOMStudySummary] = [], damaged: [UUID] = []
                for row in rows {
                    let id = try SQLiteReportRows.uuid(row, "id")
                    do { try store.requireUnquarantined(.study, id); studies.append(try SQLiteDICOMRows.summary(row)) } catch { damaged.append(id) }
                }
                return LibraryHeader(revision: revision, members: members.items, studies: studies,
                    reportCount: try Int.fetchOne(db, sql: "SELECT count(*) FROM reports")!,
                    draftCount: try Int.fetchOne(db, sql: "SELECT count(*) FROM import_drafts")!,
                    damagedMemberIDs: members.damagedIDs, damagedStudyIDs: damaged)
            }
        }
    }

    nonisolated func libraryRevision(_ db: Database) throws -> LibraryRevision {
        let state = try SQLiteLibraryState.read(from: db)
        return LibraryRevision(libraryID: state.libraryID, openEpoch: store.openEpoch,
            generation: UInt64(state.generation), commitID: state.commitID)
    }

    @concurrent package nonisolated func draftDisposition(_ id: UUID) async throws -> LibraryDraftDisposition {
        try await LibraryStorageExecutor.run {
            try store.read { db in
                let hasDraft = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM import_drafts WHERE draft_id=?)", arguments: [id.sqliteBytes])!
                let hasRecord = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM reports WHERE record_id=?)", arguments: [id.sqliteBytes])!
                return LibraryDraftDisposition(draft: hasDraft ? try usableDraft(id, db) : nil,
                    record: hasRecord ? try usableRecord(id, db) : nil)
            }
        }
    }

    @concurrent package nonisolated func recordSelection(_ ids: [UUID]) async throws -> LibraryRecordSelection {
        try await LibraryStorageExecutor.run {
            guard ids.count <= 2, Set(ids).count == ids.count else { throw LibraryReportError.resourceLimit }
            return try store.read { db in
                LibraryRecordSelection(revision: try libraryRevision(db), records: try ids.map { try usableRecord($0, db) })
            }
        }
    }

    @concurrent package nonisolated func timelinePage(memberID: UUID?, limit: Int, cursor: LibraryQueryCursor?) async throws -> LibraryTimelinePage {
        try await LibraryStorageExecutor.run {
            guard (1...100).contains(limit) else { throw LibraryReportError.resourceLimit }
            return try store.read { db in
                let revision = try libraryRevision(db)
                try Self.validateQuery(cursor, revision: revision, scope: "timeline", memberID: memberID)
                var arguments: [DatabaseValue] = []
                let reportMember = memberID.map { id in arguments.append(id.sqliteBytes.databaseValue); return " WHERE member_id = ?" } ?? ""
                let studyMember = memberID.map { id in arguments.append(id.sqliteBytes.databaseValue); return " AND member_id = ?" } ?? ""
                var after = ""
                if let cursor {
                    let sameDate = "(kind > ? OR (kind = ? AND id > ?))"
                    if let date = cursor.lastDate {
                        after = " WHERE date < ? OR date IS NULL OR (date = ? AND \(sameDate))"
                        arguments += [date.timeIntervalSince1970.databaseValue, date.timeIntervalSince1970.databaseValue]
                    } else { after = " WHERE date IS NULL AND \(sameDate)" }
                    arguments += [cursor.lastKind.databaseValue, cursor.lastKind.databaseValue, cursor.lastID.sqliteBytes.databaseValue]
                }
                arguments.append((limit + 1).databaseValue)
                // One raw boundary covers both domains and damaged rows; no late insertion before the loaded page.
                let keys = try SQLiteRows.fetchAll(db, sql: """
                    SELECT * FROM (
                        SELECT record_id AS id, timeline_date AS date, 0 AS kind FROM reports\(reportMember)
                        UNION ALL SELECT id, effective_date AS date, 1 AS kind FROM dicom_studies WHERE state='confirmed'\(studyMember)
                    )\(after) ORDER BY date DESC, kind, id LIMIT ?
                    """, arguments: StatementArguments(arguments))
                var items: [LibraryTimelineItem] = [], damaged: [UUID] = []
                for key in keys.prefix(limit) {
                    let id = try SQLiteReportRows.uuid(key, "id")
                    do {
                        try store.requireUnquarantined(key["kind"] as Int == 0 ? .report : .study, id)
                        if key["kind"] as Int == 0 {
                            guard let row = try SQLiteRows.fetchOne(db, sql: "SELECT \(SQLiteReportRows.summaryProjection) FROM reports WHERE record_id=?", arguments: [id.sqliteBytes]) else { throw LibraryReportError.recordNotFound }
                            guard !(row["oversized"] as Bool) else { throw SQLiteLibraryError.damaged }
                            items.append(.report(try SQLiteReportRows.summary(row)))
                        } else { items.append(.study(try SQLiteDICOMRows.summary(SQLiteDICOMRows.studyRow(id, db)))) }
                    } catch let error as DatabaseError { throw error }
                    catch { damaged.append(id) }
                }
                let next = try keys.count > limit ? keys.prefix(limit).last.map { key in
                    LibraryQueryCursor(libraryID: revision.libraryID, commitID: revision.commitID, openEpoch: revision.openEpoch,
                        scope: "timeline", memberID: memberID, lastID: try SQLiteReportRows.uuid(key, "id"),
                        lastDate: (key["date"] as Double?).map(Date.init(timeIntervalSince1970:)), lastKind: key["kind"])
                } : nil
                return LibraryTimelinePage(revision: revision, items: items, nextCursor: next, damagedIDs: damaged)
            }
        }
    }

    @concurrent package nonisolated func draftPage(states: [ImportState], limit: Int, cursor: LibraryQueryCursor?) async throws -> LibraryDraftPage {
        try await LibraryStorageExecutor.run {
            guard (1...100).contains(limit), !states.isEmpty else { throw LibraryReportError.resourceLimit }
            let values = Set(states.map(\.rawValue)).sorted()
            let scope = "drafts:" + values.joined(separator: ",")
            return try store.read { db in
                let revision = try libraryRevision(db)
                try Self.validateQuery(cursor, revision: revision, scope: scope, memberID: nil)
                var arguments = values.map(\.databaseValue)
                if let cursor { arguments.append(cursor.lastID.sqliteBytes.databaseValue) }
                arguments.append((limit + 1).databaseValue)
                let rows = try SQLiteRows.fetchAll(db, sql: "SELECT \(SQLiteHotProjection.sql(SQLiteReportRows.draftColumns, bounds: ["state": 64, "failure_code": 128])) FROM import_drafts WHERE state IN (\(Array(repeating: "?", count: values.count).joined(separator: ",")))\(cursor == nil ? "" : " AND draft_id > ?") ORDER BY draft_id LIMIT ?", arguments: StatementArguments(arguments))
                var items: [LibraryDraftSummary] = [], damaged: [UUID] = []
                for row in rows.prefix(limit) {
                    let id = try SQLiteReportRows.uuid(row, "draft_id")
                    do {
                        guard !(row["oversized"] as Bool) else { throw SQLiteLibraryError.damaged }
                        try store.requireUnquarantined(.draft, id)
                        try SQLiteReportRows.verify(row, table: "import_drafts", columns: SQLiteReportRows.draftColumns)
                        guard let state = ImportState(rawValue: row["state"]) else { throw LibraryReportError.invalidDocument }
                        let failure: String? = row["failure_code"]
                        items.append(LibraryDraftSummary(id: id, state: state, revision: UInt64(row["revision"] as Int64), memberID: try SQLiteReportRows.optionalUUID(row, "member_id"), failureCode: failure.flatMap(ImportFailureCode.init(rawValue:)), sourceCount: row["source_count"],
                            displayName: try SQLiteReportRows.firstSourceName(draftID: id, db)))
                    } catch let error as DatabaseError { throw error }
                    catch { damaged.append(id) }
                }
                let next = try rows.count > limit ? rows.prefix(limit).last.map { row in
                    LibraryQueryCursor(libraryID: revision.libraryID, commitID: revision.commitID, openEpoch: revision.openEpoch,
                        scope: scope, memberID: nil, lastID: try SQLiteReportRows.uuid(row, "draft_id"), lastDate: nil)
                } : nil
                return LibraryDraftPage(revision: revision, items: items, nextCursor: next, damagedIDs: damaged)
            }
        }
    }

    @concurrent package nonisolated func reviewContent(draftID: UUID) async throws -> LibraryReviewSnapshot {
        try await LibraryStorageExecutor.run {
            let captured = try store.read { db in
                let draft = try usableDraft(draftID, db)
                guard draft.state == .needsReview, let id = draft.documentObjectID else { throw LibraryReportError.invalidDocument }
                return (try libraryRevision(db), draft, try SQLiteReportRows.document(id, sources: draft.sources,
                    expectedHash: SQLiteReportRows.draftRow(draftID, db)["document_hash"], db), try SQLiteReportRows.memberSummaries(db).items)
            }
            let original = try await original(draftID: draftID, expectedRevision: captured.1.revision, sourceID: captured.1.sources.first.id)
            try store.read(epoch: captured.0.openEpoch) { db in
                guard try usableDraft(draftID, db) == captured.1 else { throw ImportDraftError.staleAttempt }
            }
            return LibraryReviewSnapshot(revision: captured.0, draft: captured.1, document: captured.2, members: captured.3,
                attachment: original.0, originalData: original.1)
        }
    }

    @concurrent package nonisolated func original(recordID: UUID, expectedRevision: UInt64, sourceID: UUID, expectedLibrary: LibraryRevision) async throws -> (Attachment, Data) {
        try await LibraryStorageExecutor.run {
            try checkLibrary(expectedLibrary)
            let result = try await original(recordID: recordID, expectedRevision: expectedRevision, sourceID: sourceID)
            try checkLibrary(expectedLibrary)
            return result
        }
    }

    @concurrent package nonisolated func original(draftID: UUID, expectedRevision: UInt64, sourceID: UUID, expectedLibrary: LibraryRevision) async throws -> (Attachment, Data) {
        try await LibraryStorageExecutor.run {
            try checkLibrary(expectedLibrary)
            let result = try await original(draftID: draftID, expectedRevision: expectedRevision, sourceID: sourceID)
            try checkLibrary(expectedLibrary)
            return result
        }
    }

    private nonisolated func checkLibrary(_ expected: LibraryRevision) throws {
        try store.read(epoch: expected.openEpoch) { db in
            guard try SQLiteLibraryState.read(from: db).libraryID == expected.libraryID else { throw SQLiteLibraryError.staleRoot }
        }
    }

    private static func validateQuery(_ cursor: LibraryQueryCursor?, revision: LibraryRevision, scope: String, memberID: UUID?) throws {
        guard let cursor else { return }
        guard cursor.libraryID == revision.libraryID, cursor.openEpoch == revision.openEpoch, cursor.commitID == revision.commitID,
              cursor.scope == scope, cursor.memberID == memberID else { throw LibraryReportError.staleCursor }
    }
}

extension SQLiteDICOMRepository: LibraryDICOMStoring {}
