import Foundation
import GRDB
import KinlogueCore

/// Business codecs shared by report commands and the LAN archive transaction.
enum SQLiteReportRows {
    static let memberColumns = ["id", "display_name", "disambiguation", "archived", "revision", "summary_name", "summary_label", "summary_hash"]
    static let memberSummaryColumns = ["id", "archived", "revision", "summary_name", "summary_label"]
    static let sourceColumns = ["row_id", "source_id", "report_id", "draft_id", "position", "original_id", "page_count", "display_name"]
    static let documentColumns = ["id", "kind", "document_version", "extraction_version", "revision", "payload", "sha256"]
    static let draftColumns = ["draft_id", "member_id", "state", "revision", "attempt_id", "failure_code", "document_id", "sources_hash", "source_count", "document_hash", "fingerprint", "fingerprint_version"]
    static let reportColumns = ["record_id", "member_id", "document_id", "revision", "timeline_date", "date_kind", "title", "report_type", "organization", "conclusion", "search_hash", "detail_hash", "sources_hash", "source_count", "document_hash", "fingerprint", "fingerprint_version"]

    static func hash(table: String, values: [DatabaseValue]) throws -> Data {
        let fields: [SQLiteContentHash.Value] = try values.map { value in
            switch value.storage {
            case .null: return .null
            case .int64(let value): return .integer(value)
            case .double(let value):
                guard value.isFinite else { throw SQLiteLibraryError.damaged }
                var bits = value.bitPattern.bigEndian
                return withUnsafeBytes(of: &bits) { .blob(Data($0)) }
            case .string(let value): return .text(value)
            case .blob(let value): return .blob(value)
            }
        }
        return SQLiteContentHash.hash(domain: table + ":1", values: fields)
    }

    static func verify(_ row: Row, table: String, columns: [String]) throws {
        try SQLiteRows.validateText(row, table: table)
        guard try hash(table: table, values: columns.map { row[$0] as DatabaseValue }) == row["content_hash"] as Data else {
            throw SQLiteLibraryError.damaged
        }
    }

    static func put(_ db: Database, table: String, columns: [String], values: [DatabaseValue]) throws {
        let digest = try hash(table: table, values: values)
        let names = columns + ["content_hash"]
        let storedValues = values + [digest.databaseValue]
        try db.execute(sql: "INSERT INTO \(table)(\(names.joined(separator: ","))) VALUES (\(SQLiteRows.placeholders(storedValues))) ON CONFLICT(\(columns[0])) DO UPDATE SET \(names.dropFirst().map { "\($0)=excluded.\($0)" }.joined(separator: ","))",
                       arguments: SQLiteRows.arguments(storedValues))
    }

    static func uuid(_ row: Row, _ column: String) throws -> UUID {
        guard let result = UUID(sqliteBytes: row[column]) else { throw SQLiteLibraryError.damaged }
        return result
    }

    static func optionalUUID(_ row: Row, _ column: String) throws -> UUID? {
        let bytes: Data? = row[column]
        guard let bytes else { return nil }
        guard let value = UUID(sqliteBytes: bytes) else { throw SQLiteLibraryError.damaged }
        return value
    }

    static let memberTextBytesSQL = "octet_length(display_name) + coalesce(octet_length(disambiguation),0)"

    static func member(_ row: Row) throws -> FamilyMember {
        try verify(row, table: "members", columns: memberColumns)
        let result = try FamilyMember(id: uuid(row, "id"), displayName: row["display_name"],
                                     disambiguationLabel: row["disambiguation"], isArchived: row["archived"] as Int == 1)
        guard result.displayName == row["display_name"] as String,
              result.disambiguationLabel == row["disambiguation"] as String? else { throw SQLiteLibraryError.damaged }
        _ = try SQLiteEntityBudget.memberData(result)
        guard try memberSummary(row) == LibraryMemberSummary(result) else { throw SQLiteLibraryError.damaged }
        return result
    }

    static func saveMember(_ member: FamilyMember, revision: Int64, _ db: Database) throws {
        _ = try SQLiteEntityBudget.memberData(member)
        guard revision >= 0 else { throw LibraryReportError.invalidDocument }
        let summary = LibraryMemberSummary(member)
        let summaryValues: [DatabaseValue] = [member.id.sqliteBytes.databaseValue, member.isArchived.databaseValue,
            revision.databaseValue, summary.displayName.databaseValue, summary.disambiguationLabel.databaseValue]
        try put(db, table: "members", columns: memberColumns, values: [
            member.id.sqliteBytes.databaseValue, member.displayName.databaseValue, member.disambiguationLabel.databaseValue,
            member.isArchived.databaseValue, revision.databaseValue, summary.displayName.databaseValue,
            summary.disambiguationLabel.databaseValue, try hash(table: "member_summary", values: summaryValues).databaseValue
        ])
    }

    static func memberSummary(_ row: Row) throws -> LibraryMemberSummary {
        try SQLiteRows.validateText(row, table: "members")
        guard try hash(table: "member_summary", values: memberSummaryColumns.map { row[$0] }) == row["summary_hash"] as Data else { throw SQLiteLibraryError.damaged }
        let name: String = row["summary_name"]
        let label: String? = row["summary_label"]
        guard name.unicodeScalars.count <= 160, label.map({ $0.unicodeScalars.count <= 160 }) != false else { throw SQLiteLibraryError.damaged }
        return LibraryMemberSummary(id: try uuid(row, "id"), displayName: name, disambiguationLabel: label, isArchived: row["archived"] as Int == 1)
    }

    static func memberSummaries(_ db: Database) throws -> (items: [LibraryMemberSummary], damagedIDs: [UUID]) {
        let rows = try SQLiteRows.fetchAll(db, sql: "SELECT \(SQLiteHotProjection.sql(memberSummaryColumns + ["summary_hash"], bounds: ["summary_name": 640, "summary_label": 640])) FROM members ORDER BY id LIMIT 257")
        guard rows.count <= 256 else { throw LibraryReportError.resourceLimit }
        var items: [LibraryMemberSummary] = [], damagedIDs: [UUID] = []
        for row in rows {
            let id = try uuid(row, "id")
            do {
                guard !(row["oversized"] as Bool) else { throw SQLiteLibraryError.damaged }
                items.append(try memberSummary(row))
            } catch { damagedIDs.append(id) }
        }
        return (items, damagedIDs)
    }

    static func visitMembers(_ db: Database, _ consume: (FamilyMember) throws -> Void) throws {
        let bounds = try SQLiteRows.fetchOne(db, sql: "SELECT count(*) AS n, coalesce(max(\(memberTextBytesSQL)),0) AS bytes FROM members")!
        guard (bounds["n"] as Int) <= 256, (bounds["bytes"] as Int) <= LibraryStorageLimits.maximumEntityJSONBytes else { throw LibraryReportError.resourceLimit }
        let rows = try SQLiteRows.fetchCursor(db, sql: "SELECT * FROM members ORDER BY id")
        while let row = try rows.next() { try consume(member(row)) }
    }

    static func members(_ db: Database) throws -> [FamilyMember] {
        let rawBytes = try Int.fetchOne(db, sql: "SELECT coalesce(sum(\(memberTextBytesSQL)),0) FROM members")!
        guard rawBytes <= VaultReadSnapshotPolicy.maximumRetainedByteCount else { throw LibraryReportError.resourceLimit }
        var result: [FamilyMember] = []
        var remaining = VaultReadSnapshotPolicy.maximumRetainedByteCount
        try visitMembers(db) { member in
            let count = try SQLiteEntityBudget.memberData(member).count
            guard count <= remaining else { throw LibraryReportError.resourceLimit }
            remaining -= count
            result.append(member)
        }
        return result
    }

    static func member(_ id: UUID, _ db: Database) throws -> FamilyMember {
        guard let bytes = try Int.fetchOne(db, sql: "SELECT \(memberTextBytesSQL) FROM members WHERE id = ?", arguments: [id.sqliteBytes]) else {
            throw LibraryReportError.memberNotFound
        }
        guard bytes <= LibraryStorageLimits.maximumEntityJSONBytes else { throw LibraryReportError.resourceLimit }
        guard let row = try SQLiteRows.fetchOne(db, sql: "SELECT * FROM members WHERE id = ?", arguments: [id.sqliteBytes]) else {
            throw LibraryReportError.memberNotFound
        }
        return try member(row)
    }

    static func requireMember(_ id: UUID?, allowArchived: Bool = false, in db: Database) throws {
        guard let id else { return }
        let value = try member(id, db)
        guard allowArchived || !value.isArchived else { throw LibraryReportError.invalidDocument }
    }

    static func attachment(_ id: UUID, _ db: Database) throws -> Attachment {
        let original = try SQLiteOriginal.read(id, from: db)
        guard original.lifecycle == "live", original.byteCount <= 100 * 1_024 * 1_024 else { throw SQLiteLibraryError.invalidOriginal }
        return try Attachment(id: original.id, contentTypeIdentifier: original.contentType,
                              byteCount: original.byteCount, sha256Digest: original.sha256)
    }

    static func sources(_ ownerID: UUID, report: Bool, _ db: Database) throws -> ReportSources {
        let ownerColumn = report ? "report_id" : "draft_id"
        let bounds = try SQLiteRows.fetchOne(db, sql: "SELECT count(*) AS n, coalesce(sum(coalesce(octet_length(display_name),0)),0) AS bytes FROM report_sources WHERE \(ownerColumn) = ?", arguments: [ownerID.sqliteBytes])!
        guard (bounds["n"] as Int) <= 20_000, (bounds["bytes"] as Int) <= LibraryStorageLimits.maximumEntityJSONBytes else { throw LibraryReportError.resourceLimit }
        let rows = try SQLiteRows.fetchCursor(db, sql: "SELECT * FROM report_sources WHERE \(ownerColumn) = ? ORDER BY position", arguments: [ownerID.sqliteBytes])
        var result: [ReportSource] = []
        var remaining = LibraryStorageLimits.maximumEntityJSONBytes
        while let row = try rows.next() {
            try verify(row, table: "report_sources", columns: sourceColumns)
            try SQLiteEntityBudget.consumeText(row["display_name"] as String?, remaining: &remaining)
            guard row["position"] as Int == result.count else { throw SQLiteLibraryError.damaged }
            let id = try uuid(row, "original_id")
            _ = try attachment(id, db)
            guard try SQLiteRows.fetchOne(db, sql: "SELECT row_id FROM report_sources WHERE original_id = ? AND page_count != ? LIMIT 1", arguments: [id.sqliteBytes, row["page_count"] as Int]) == nil else { throw SQLiteLibraryError.damaged }
            let source = try ReportSource(id: uuid(row, "source_id"), attachmentID: id,
                                          displayName: row["display_name"], pageCount: row["page_count"])
            guard source.displayName == row["display_name"] as String? else { throw SQLiteLibraryError.damaged }
            result.append(source)
        }
        let value = try ReportSources(result)
        _ = try SQLiteEntityBudget.sourcesData(value)
        return value
    }

    /// The file name of a draft's first source, for a list row. The source row's own hash is
    /// verified; a name too long for a list row is left out instead of being copied.
    static func firstSourceName(draftID: UUID, _ db: Database) throws -> String? {
        guard let row = try SQLiteRows.fetchOne(db, sql: "SELECT \(SQLiteHotProjection.sql(sourceColumns, bounds: ["display_name": 1_024])) FROM report_sources WHERE draft_id = ? AND position = 0", arguments: [draftID.sqliteBytes]) else { throw SQLiteLibraryError.damaged }
        guard !(row["oversized"] as Bool) else { return nil }
        try verify(row, table: "report_sources", columns: sourceColumns)
        return row["display_name"]
    }

    static func sourcesHash(_ sources: ReportSources) throws -> Data {
        ContentDigest.sha256(try SQLiteEntityBudget.sourcesData(sources))
    }

    static func saveSources(_ sources: ReportSources, ownerID: UUID, report: Bool, _ db: Database) throws {
        _ = try SQLiteEntityBudget.sourcesData(sources)
        try db.execute(sql: "DELETE FROM report_sources WHERE \(report ? "report_id" : "draft_id") = ?", arguments: [ownerID.sqliteBytes])
        for (position, source) in sources.elements.enumerated() {
            _ = try attachment(source.attachmentID, db)
            guard try SQLiteRows.fetchOne(db, sql: "SELECT row_id FROM report_sources WHERE original_id = ? AND page_count != ? LIMIT 1", arguments: [source.attachmentID.sqliteBytes, source.pageCount]) == nil else { throw LibraryReportError.invalidDocument }
            try put(db, table: "report_sources", columns: sourceColumns, values: [
                UUID().sqliteBytes.databaseValue, source.id.sqliteBytes.databaseValue,
                (report ? ownerID.sqliteBytes : nil).databaseValue, (report ? nil : ownerID.sqliteBytes).databaseValue,
                position.databaseValue, source.attachmentID.sqliteBytes.databaseValue,
                source.pageCount.databaseValue, source.displayName.databaseValue
            ])
        }
    }

    static func fingerprint(_ sources: ReportSources, _ db: Database) throws -> Data {
        let parts = try sources.elements.map { source in
            let original = try attachment(source.attachmentID, db)
            return try ReportFingerprint.SourceDigest(sha256Digest: original.sha256Digest, byteCount: original.byteCount)
        }
        return ContentDigest.sha256(try CanonicalVaultJSON.encode(ReportFingerprint(sources: parts)))
    }

    static func documentData(_ id: UUID, kind: String, _ db: Database) throws -> Data {
        guard let row = try SQLiteRows.fetchOne(db, sql: "SELECT * FROM ocr_documents WHERE id = ?", arguments: [id.sqliteBytes]) else {
            throw LibraryReportError.invalidDocument
        }
        try verify(row, table: "ocr_documents", columns: documentColumns)
        let data: Data = row["payload"]
        guard row["kind"] as String == kind, row["document_version"] as Int == 1,
              ContentDigest.sha256(data) == row["sha256"] as Data else { throw SQLiteLibraryError.damaged }
        return data
    }

    static func document(_ id: UUID, sources: ReportSources, expectedHash: Data?, _ db: Database) throws -> ImportDraftDocument {
        let data = try documentData(id, kind: "report", db)
        guard ContentDigest.sha256(data) == expectedHash else { throw SQLiteLibraryError.damaged }
        let value = try CanonicalVaultJSON.decode(ImportDraftDocument.self, from: data)
        let validated = try value.attributedAndValidated(for: sources)
        guard validated == value,
              try Int.fetchOne(db, sql: "SELECT extraction_version FROM ocr_documents WHERE id = ?", arguments: [id.sqliteBytes]) == value.candidateExtractionVersion else {
            throw SQLiteLibraryError.damaged
        }
        return value
    }

    static func saveDocument(_ document: ImportDraftDocument, id: UUID, revision: UInt64, sources: ReportSources, _ db: Database) throws -> Data {
        let value = try document.attributedAndValidated(for: sources)
        let data = try CanonicalVaultJSON.encode(value)
        guard data.count <= SQLiteLibrarySchema.maximumPayloadBytes,
              revision <= Int64.max, value.candidateExtractionVersion == nil || value.candidateExtractionVersion! > 0 else {
            throw LibraryReportError.resourceLimit
        }
        let digest = ContentDigest.sha256(data)
        try put(db, table: "ocr_documents", columns: documentColumns, values: [
            id.sqliteBytes.databaseValue, "report".databaseValue, 1.databaseValue,
            value.candidateExtractionVersion.databaseValue, Int64(revision).databaseValue,
            data.databaseValue, digest.databaseValue
        ])
        return digest
    }

    static func draftRow(_ id: UUID, _ db: Database) throws -> Row {
        guard let row = try SQLiteRows.fetchOne(db, sql: "SELECT * FROM import_drafts WHERE draft_id = ?", arguments: [id.sqliteBytes]) else {
            throw LibraryReportError.draftNotFound
        }
        try verify(row, table: "import_drafts", columns: draftColumns)
        return row
    }

    static func draft(_ id: UUID, _ db: Database) throws -> ImportDraft {
        let row = try draftRow(id, db)
        let sourceRows = try sources(id, report: false, db)
        guard let state = ImportState(rawValue: row["state"]),
              sourceRows.count == row["source_count"] as Int,
              try sourcesHash(sourceRows) == row["sources_hash"] as Data,
              try fingerprint(sourceRows, db) == row["fingerprint"] as Data?,
              row["fingerprint_version"] as Int? == ReportFingerprint.currentVersion else { throw SQLiteLibraryError.damaged }
        let failure: String? = row["failure_code"]
        let value = ImportDraft(id: id, sources: sourceRows, state: state, revision: UInt64(row["revision"] as Int64),
            attemptID: try optionalUUID(row, "attempt_id"), documentObjectID: try optionalUUID(row, "document_id"),
            failureCode: failure.flatMap(ImportFailureCode.init(rawValue:)), memberID: try optionalUUID(row, "member_id"))
        guard value.isStructurallyValid, value.failureCode?.rawValue == failure,
              (value.documentObjectID == nil) == (row["document_hash"] as Data? == nil) else { throw SQLiteLibraryError.damaged }
        _ = try SQLiteEntityBudget.draftData(value)
        if let memberID = value.memberID { _ = try member(memberID, db) }
        if let id = value.documentObjectID { try requireExclusiveDocument(id, reportID: nil, draftID: value.id, db) }
        return value
    }

    static func saveDraft(_ draft: ImportDraft, documentHash: Data?, _ db: Database, replaceSources: Bool = false) throws {
        guard draft.isStructurallyValid, draft.revision <= Int64.max, draft.sources.count <= 20_000,
              (draft.documentObjectID == nil) == (documentHash == nil) else { throw LibraryReportError.invalidDocument }
        _ = try SQLiteEntityBudget.draftData(draft)
        if let id = draft.documentObjectID { try requireExclusiveDocument(id, reportID: nil, draftID: draft.id, db) }
        try put(db, table: "import_drafts", columns: draftColumns, values: [
            draft.id.sqliteBytes.databaseValue, draft.memberID?.sqliteBytes.databaseValue ?? .null,
            draft.state.rawValue.databaseValue, Int64(draft.revision).databaseValue, draft.attemptID?.sqliteBytes.databaseValue ?? .null,
            draft.failureCode?.rawValue.databaseValue ?? .null, draft.documentObjectID?.sqliteBytes.databaseValue ?? .null,
            try sourcesHash(draft.sources).databaseValue, draft.sources.count.databaseValue, documentHash.databaseValue,
            try fingerprint(draft.sources, db).databaseValue, ReportFingerprint.currentVersion.databaseValue
        ])
        if replaceSources { try saveSources(draft.sources, ownerID: draft.id, report: false, db) }
    }

    static var summaryProjection: String {
        SQLiteHotProjection.sql(reportColumns, bounds: ["title": 640, "report_type": 512, "organization": 512, "conclusion": 2_048])
    }

    static func summary(_ row: Row) throws -> LibraryReportSummary {
        try verify(row, table: "reports", columns: reportColumns)
        let date: Double? = row["timeline_date"]
        let kind: String? = row["date_kind"]
        guard (date == nil) == (kind == nil), date?.isFinite != false,
              kind == nil || ReportDateKind(rawValue: kind!) != nil else { throw SQLiteLibraryError.damaged }
        return LibraryReportSummary(id: try uuid(row, "record_id"), memberID: try uuid(row, "member_id"),
            revision: UInt64(row["revision"] as Int64), timelineDate: date.map(Date.init(timeIntervalSince1970:)),
            dateKind: kind.flatMap(ReportDateKind.init(rawValue:)), title: row["title"], reportType: row["report_type"],
            organization: row["organization"], conclusion: row["conclusion"])
    }

    static func record(_ id: UUID, _ db: Database) throws -> HealthRecord {
        guard let row = try SQLiteRows.fetchOne(db, sql: "SELECT * FROM reports WHERE record_id = ?", arguments: [id.sqliteBytes]),
              let detail = try SQLiteRows.fetchOne(db, sql: "SELECT * FROM report_details WHERE record_id = ?", arguments: [id.sqliteBytes]) else {
            throw LibraryReportError.recordNotFound
        }
        let projection = try summary(row)
        try verify(detail, table: "report_details", columns: ["record_id", "payload"])
        let data: Data = detail["payload"]
        guard ContentDigest.sha256(data) == row["detail_hash"] as Data else { throw SQLiteLibraryError.damaged }
        let record = try CanonicalVaultJSON.decode(HealthRecord.self, from: data)
        let sourceRows = try sources(id, report: true, db)
        guard let search = try SQLiteRows.fetchOne(db, sql: "SELECT * FROM report_search WHERE record_id = ?", arguments: [id.sqliteBytes]) else { throw SQLiteLibraryError.damaged }
        try verify(search, table: "report_search", columns: ["record_id", "fields"])
        guard ContentDigest.sha256(search["fields"] as Data) == row["search_hash"] as Data else { throw SQLiteLibraryError.damaged }
        guard record.id == id, record.importState == .confirmed, record.sources == sourceRows,
              record.ocrDocumentObjectID == (try optionalUUID(row, "document_id")),
              LibraryReportSummary(record: record) == projection,
              try CanonicalVaultJSON.encode(RecordQuery.searchableFields(record: record)) == search["fields"] as Data,
              try sourcesHash(sourceRows) == row["sources_hash"] as Data, sourceRows.count == row["source_count"] as Int,
              try fingerprint(sourceRows, db) == row["fingerprint"] as Data?, row["fingerprint_version"] as Int? == ReportFingerprint.currentVersion,
              (record.ocrDocumentObjectID == nil) == (row["document_hash"] as Data? == nil) else { throw SQLiteLibraryError.damaged }
        _ = try member(record.memberID, db)
        if let id = record.ocrDocumentObjectID { try requireExclusiveDocument(id, reportID: record.id, draftID: nil, db) }
        return record
    }

    static func saveRecord(_ record: HealthRecord, documentHash: Data?, _ db: Database) throws {
        guard record.importState == .confirmed, record.revision <= Int64.max,
              record.sources.count <= 20_000, (record.ocrDocumentObjectID == nil) == (documentHash == nil) else { throw LibraryReportError.invalidDocument }
        _ = try SQLiteEntityBudget.sourcesData(record.sources)
        let data = try SQLiteEntityBudget.encode(record)
        let validated = try CanonicalVaultJSON.decode(HealthRecord.self, from: data)
        let summary = LibraryReportSummary(record: validated)
        let search = try CanonicalVaultJSON.encode(RecordQuery.searchableFields(record: validated))
        guard data.count <= SQLiteLibrarySchema.maximumPayloadBytes, search.count <= SQLiteLibrarySchema.maximumPayloadBytes,
              validated.hasValidTimelineDateSelection, validated.hasValidSourceReferences else { throw LibraryReportError.resourceLimit }
        if let id = record.ocrDocumentObjectID { try requireExclusiveDocument(id, reportID: record.id, draftID: nil, db) }
        try put(db, table: "reports", columns: reportColumns, values: [
            record.id.sqliteBytes.databaseValue, record.memberID.sqliteBytes.databaseValue,
            record.ocrDocumentObjectID?.sqliteBytes.databaseValue ?? .null, Int64(record.revision).databaseValue,
            summary.timelineDate?.timeIntervalSince1970.databaseValue ?? .null, summary.dateKind?.rawValue.databaseValue ?? .null,
            summary.title.databaseValue, summary.reportType.databaseValue, summary.organization.databaseValue, summary.conclusion.databaseValue,
            ContentDigest.sha256(search).databaseValue, ContentDigest.sha256(data).databaseValue,
            try sourcesHash(record.sources).databaseValue, record.sources.count.databaseValue, documentHash.databaseValue,
            try fingerprint(record.sources, db).databaseValue, ReportFingerprint.currentVersion.databaseValue
        ])
        try put(db, table: "report_search", columns: ["record_id", "fields"], values: [record.id.sqliteBytes.databaseValue, search.databaseValue])
        try put(db, table: "report_details", columns: ["record_id", "payload"], values: [record.id.sqliteBytes.databaseValue, data.databaseValue])
        try saveSources(record.sources, ownerID: record.id, report: true, db)
    }

    static func requireExclusiveDocument(_ id: UUID, reportID: UUID?, draftID: UUID?, inboxID: UUID? = nil, _ db: Database) throws {
        let records = try Data.fetchAll(db, sql: "SELECT record_id FROM reports WHERE document_id = ? LIMIT 2", arguments: [id.sqliteBytes])
        let drafts = try Data.fetchAll(db, sql: "SELECT draft_id FROM import_drafts WHERE document_id = ? LIMIT 2", arguments: [id.sqliteBytes])
        guard records.allSatisfy({ $0 == reportID?.sqliteBytes }), drafts.allSatisfy({ $0 == draftID?.sqliteBytes }),
              try Data.fetchAll(db, sql: "SELECT id FROM inbox_items WHERE derived_document_id = ? LIMIT 2", arguments: [id.sqliteBytes]).allSatisfy({ $0 == inboxID?.sqliteBytes }) else { throw LibraryReportError.invalidDocument }
    }

    static func deleteDocumentIfUnreferenced(_ id: UUID?, _ db: Database) throws {
        guard let id else { return }
        try db.execute(sql: "DELETE FROM ocr_documents WHERE id = ? AND NOT EXISTS(SELECT 1 FROM reports WHERE document_id = ?) AND NOT EXISTS(SELECT 1 FROM import_drafts WHERE document_id = ?) AND NOT EXISTS(SELECT 1 FROM inbox_items WHERE derived_document_id = ?)", arguments: StatementArguments(Array(repeating: id.sqliteBytes, count: 4)))
    }
}
