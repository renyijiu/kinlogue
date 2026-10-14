import Darwin
import Foundation
import GRDB
import KinlogueCore

/// Strict entity codecs remain usable independently by background integrity inspection.
enum SQLiteLogicalRows {
    /// Conservative wire budget from bounded SQL lengths; no payload is materialized here.
    static func estimatedSpoolBytes(_ db: Database) throws -> UInt64 {
        var total: UInt64 = 1_024 * 1_024 // framing, header/footer and fixed entity fields
        let entityBytes = LibraryStorageLimits.maximumEntityJSONBytes
        let draftHeader = try SQLiteEntityBudget.maximumDraftHeaderBytes.get()
        let queries: [(String, UInt64)] = [
            ("SELECT coalesce(sum(length(payload)),0) FROM report_details", 1),
            ("SELECT coalesce(sum(length(payload)+256),0) FROM ocr_documents", 1),
            // Escaping is at most six bytes per UTF-8 byte, bounded again by entity admission.
            ("SELECT coalesce(sum(min(\(entityBytes),6*(\(SQLiteReportRows.memberTextBytesSQL))+256)+64),0) FROM members", 1),
            ("SELECT coalesce(sum(min(\(entityBytes),6*coalesce(s.bytes,0)+256*coalesce(s.n,0)+\(draftHeader))+64),0) FROM import_drafts d LEFT JOIN (SELECT draft_id,count(*) AS n,sum(coalesce(length(CAST(display_name AS BLOB)),0)) AS bytes FROM report_sources WHERE draft_id IS NOT NULL GROUP BY draft_id) s ON s.draft_id=d.draft_id", 1),
            ("SELECT count(*) FROM reports", 64),
            ("SELECT count(*) FROM originals", 2_048),
            ("SELECT count(*) FROM inbox_items", 8_192),
            ("SELECT count(*) FROM inbox_content_terminals", 8_192),
            ("SELECT count(*) FROM inbox_transport_receipts", 8_192),
            ("SELECT coalesce(sum(length(command)+length(intent)+length(outcome)+256),0) FROM inbox_archive_receipts", 2),
            ("SELECT coalesce(sum(logical_byte_count+object_count*128+1024),0) FROM dicom_studies", 1)
        ]
        for (sql, multiplier) in queries {
            guard let value = try Int64.fetchOne(db, sql: sql), value >= 0 else { throw SQLiteLogicalBackupError.resourceLimit }
            let addition = UInt64(value).multipliedReportingOverflow(by: multiplier)
            let next = total.addingReportingOverflow(addition.partialValue)
            guard !addition.overflow, !next.overflow, next.partialValue <= BackupFormatLimits.maximumPlaintextByteCount else { throw SQLiteLogicalBackupError.resourceLimit }
            total = next.partialValue
        }
        return total
    }

    static func bounds(_ db: Database) throws {
        try SQLiteLibrarySchema.validate(in: db)
        for (table, limit) in [("ocr_documents", 45_000), ("inbox_archive_receipts", 5_000)] {
            guard try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)")! <= limit else { throw SQLiteLogicalBackupError.resourceLimit }
        }
        // Check lengths before GRDB materializes an untrusted TEXT/BLOB or a source collection.
        for (table, expression, maximum) in [
            ("members", "length(CAST(display_name AS BLOB)) + coalesce(length(CAST(disambiguation AS BLOB)),0)", LibraryStorageLimits.maximumEntityJSONBytes),
            ("report_details", "length(payload)", LibraryStorageLimits.maximumEntityJSONBytes),
            ("report_search", "length(fields)", LibraryStorageLimits.maximumEntityJSONBytes),
            ("ocr_documents", "length(payload)", 32 * 1_024 * 1_024),
            ("inbox_archive_receipts", "length(command) + length(intent) + length(outcome)", LibraryStorageLimits.maximumEntityJSONBytes)
        ] {
            guard try Row.fetchOne(db, sql: "SELECT 1 FROM \(table) WHERE \(expression) > ? LIMIT 1", arguments: [maximum]) == nil else { throw SQLiteLogicalBackupError.resourceLimit }
        }
        guard try Row.fetchOne(db, sql: "SELECT 1 FROM report_sources GROUP BY report_id,draft_id HAVING sum(coalesce(length(CAST(display_name AS BLOB)),0)) > \(LibraryStorageLimits.maximumEntityJSONBytes) OR count(*) > 20000 LIMIT 1") == nil,
              try Row.fetchOne(db, sql: "SELECT 1 FROM inbox_transport_receipts GROUP BY session_id HAVING count(*) > 1000 LIMIT 1") == nil,
              try Int.fetchOne(db, sql: "SELECT count(*) FROM report_details") == Int.fetchOne(db, sql: "SELECT count(*) FROM reports"),
              try Int.fetchOne(db, sql: "SELECT count(*) FROM report_search") == Int.fetchOne(db, sql: "SELECT count(*) FROM reports"),
              try Row.fetchOne(db, sql: "SELECT 1 FROM ocr_documents d WHERE (SELECT count(*) FROM reports WHERE document_id=d.id)+(SELECT count(*) FROM import_drafts WHERE document_id=d.id)+(SELECT count(*) FROM inbox_items WHERE derived_document_id=d.id) != 1 LIMIT 1") == nil else { throw SQLiteLogicalBackupError.invalidStream }
    }

    static func visit(_ db: Database, store: SQLiteLibraryStore, strict: Bool,
                      consume: (SQLiteLogicalRecord) throws -> Void) throws -> [UUID: SQLiteOriginal] {
        try bounds(db)
        func emit<T: Encodable>(_ kind: BackupLogicalKind, _ id: UUID, _ value: T) throws {
            try consume(SQLiteLogicalRecord(kind: kind, id: id, payload: CanonicalVaultJSON.encode(value)))
        }
        try SQLiteReportRows.visitMembers(db) { value in try emit(.member, value.id, value) }

        let originals = try reachableOriginals(db, strict: strict)
        for value in originals.values.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            try emit(.original, value.id, BackupLogicalOriginalV1(id: value.id, byteCount: value.byteCount, sha256: value.sha256, contentType: value.contentType))
        }
        for (kind, storedKind) in [(BackupLogicalKind.reportDocument, "report"), (.lanDocument, "lanSource")] {
            let rows = try Row.fetchCursor(db, sql: "SELECT id,revision FROM ocr_documents WHERE kind = ? ORDER BY id", arguments: [storedKind])
            while let row = try rows.next() {
                let id = try SQLiteReportRows.uuid(row, "id")
                let revision: Int64 = row["revision"]
                guard revision >= 0 else { throw SQLiteLogicalBackupError.invalidStream }
                if kind == .reportDocument {
                    guard let owner = try Row.fetchOne(db, sql: "SELECT record_id AS owner_id,1 AS is_report,document_hash FROM reports WHERE document_id=? UNION ALL SELECT draft_id,0,document_hash FROM import_drafts WHERE document_id=?", arguments: [id.sqliteBytes, id.sqliteBytes]) else { throw SQLiteLogicalBackupError.invalidStream }
                    let sources = try SQLiteReportRows.sources(SQLiteReportRows.uuid(owner, "owner_id"), report: owner["is_report"] as Int == 1, db)
                    let document = try SQLiteReportRows.document(id, sources: sources, expectedHash: owner["document_hash"], db)
                    try emit(kind, id, BackupLogicalReportDocumentV1(revision: UInt64(revision), document: document))
                } else {
                    let data = try SQLiteReportRows.documentData(id, kind: storedKind, db)
                    let document = try CanonicalVaultJSON.decode(LANPreprocessedSourceDocument.self, from: data)
                    try emit(kind, id, BackupLogicalLANDocumentV1(revision: UInt64(revision), source: document.source, contentType: document.contentTypeIdentifier, blocks: document.blocks))
                }
            }
        }
        let records = try Data.fetchCursor(db, sql: "SELECT record_id FROM reports ORDER BY record_id")
        while let data = try records.next() {
            guard let id = UUID(sqliteBytes: data) else { throw SQLiteLogicalBackupError.invalidStream }
            let value = try SQLiteReportRows.record(id, db)
            try emit(.report, id, value)
        }
        let drafts = try Data.fetchCursor(db, sql: "SELECT draft_id FROM import_drafts ORDER BY draft_id")
        while let data = try drafts.next() {
            guard let id = UUID(sqliteBytes: data) else { throw SQLiteLogicalBackupError.invalidStream }
            var value = try SQLiteReportRows.draft(id, db)
            if value.state == .processing || value.state == .staging {
                guard !strict else { throw SQLiteLogicalBackupError.invalidStream }
                value.state = .failed; value.attemptID = nil; value.failureCode = .cancelled
            }
            try emit(.draft, id, value)
        }
        let inbox = try SQLiteLANRows.snapshot(db, epoch: store.openEpoch)
        for item in inbox.items.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            if item.derivedArtifact != nil { _ = try SQLiteLANInboxStore.document(for: item, revision: item.revision, db) }
            let normalized: LANInboxItem
            if case .preprocessing = item.state {
                guard !strict else { throw SQLiteLogicalBackupError.invalidStream }
                normalized = try LANInboxItem(id: item.id, originatingSessionID: item.originatingSessionID,
                    displayName: item.displayName, receivedAt: item.receivedAt, sequence: item.sequence, revision: item.revision,
                    contentIdentity: item.contentIdentity, state: .failed(blobID: item.blobID, issue: .storageFailure))
            } else { normalized = item }
            try emit(.inbox, item.id, normalized)
        }
        for terminal in inbox.contentTerminals.sorted(by: { $0.id.uuidString < $1.id.uuidString }) { try emit(.terminal, terminal.id, terminal) }
        for receipt in inbox.transportReceipts.sorted(by: { $0.id.uuidString < $1.id.uuidString }) { try emit(.receipt, receipt.id, receipt) }
        let archives = try Row.fetchCursor(db, sql: "SELECT * FROM inbox_archive_receipts ORDER BY command_hash")
        while let row = try archives.next() {
            let command = try CanonicalVaultJSON.decode(SQLiteLANArchiveCommand.self, from: row["command"])
            guard let outcome = try SQLiteLANRows.archiveOutcome(command, db) else { throw SQLiteLogicalBackupError.invalidStream }
            let intent = try CanonicalVaultJSON.decode(LANArchiveIntent.self, from: row["intent"])
            let value = BackupLogicalArchiveReceiptV1(itemIDs: command.itemIDs, memberID: command.memberID, date: command.date,
                intent: intent, outcome: outcome, generation: row["generation"])
            try consume(SQLiteLogicalRecord(kind: .archiveReceipt, key: row["command_hash"], payload: CanonicalVaultJSON.encode(value)))
        }
        let studies = try Data.fetchCursor(db, sql: "SELECT id FROM dicom_studies ORDER BY id")
        while let data = try studies.next() {
            guard let id = UUID(sqliteBytes: data) else { throw SQLiteLogicalBackupError.invalidStream }
            let (header, index) = try SQLiteDICOMRows.strictStudy(id, db)
            try emit(.dicom, id, BackupLogicalDICOMV1(header: header, index: index))
        }
        if strict {
            let expected = Set(originals.keys.map { $0.uuidString.lowercased() + ".data" })
            guard try boundedNames(store.originalsURL, maximum: 25_000) == expected else { throw SQLiteLogicalBackupError.invalidStream }
            for name in ["dicom-import-journals", "dicom-import-staging"] {
                let url = store.rootURL.appendingPathComponent(name)
                var metadata = stat()
                if lstat(url.path, &metadata) != 0 {
                    guard errno == ENOENT else { throw SQLiteLogicalBackupError.invalidStream }; continue
                }
                let entries = try boundedNames(url, maximum: 1)
                guard entries.isSubset(of: [".metadata_never_index"]) else { throw SQLiteLogicalBackupError.invalidStream }
                if entries.contains(".metadata_never_index") { _ = try SQLiteFileIdentity.regular(at: url.appendingPathComponent(".metadata_never_index")) }
            }
        }
        return originals
    }
    static func reachableOriginals(_ db: Database, strict: Bool) throws -> [UUID: SQLiteOriginal] {
        var originals: [UUID: SQLiteOriginal] = [:]
        let reachable = try Data.fetchCursor(db, sql: "SELECT original_id FROM report_sources UNION SELECT original_id FROM inbox_items UNION SELECT original_id FROM dicom_objects ORDER BY original_id")
        while let data = try reachable.next() {
            guard let id = UUID(sqliteBytes: data), originals.count < 25_000 else { throw SQLiteLogicalBackupError.resourceLimit }
            let value = try SQLiteOriginal.read(id, from: db)
            guard value.lifecycle == "live", value.identity != nil else { throw SQLiteLogicalBackupError.invalidStream }
            originals[id] = value
        }
        let all = try Data.fetchCursor(db, sql: "SELECT id FROM originals ORDER BY id")
        while let data = try all.next() {
            guard let id = UUID(sqliteBytes: data) else { throw SQLiteLogicalBackupError.invalidStream }
            let value = try SQLiteOriginal.read(id, from: db)
            if originals[id] == nil {
                guard !strict, value.lifecycle != "live" else { throw SQLiteLogicalBackupError.invalidStream }
            }
        }
        let uploads = try Data.fetchCursor(db, sql: "SELECT id FROM inbox_uploads ORDER BY id")
        while let data = try uploads.next() {
            guard let id = UUID(sqliteBytes: data), !strict else { throw SQLiteLogicalBackupError.invalidStream }
            _ = try SQLiteLANUpload.read(id, db)
        }
        return originals
    }
    private static func boundedNames(_ url: URL, maximum: Int) throws -> Set<String> {
        _ = try SQLiteFileIdentity.directory(at: url)
        let fd = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw SQLiteLogicalBackupError.invalidStream }
        guard let directory = fdopendir(fd) else { Darwin.close(fd); throw SQLiteLogicalBackupError.invalidStream }
        defer { closedir(directory) }
        var result: Set<String> = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else { throw SQLiteLogicalBackupError.invalidStream }; break
            }
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            guard result.count < maximum, result.insert(name).inserted else { throw SQLiteLogicalBackupError.invalidStream }
        }
        return result
    }
}
