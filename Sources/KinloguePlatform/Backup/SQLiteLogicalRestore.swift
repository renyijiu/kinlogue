import Darwin
import Foundation
import GRDB
import KinlogueCore

package struct SQLiteLogicalValidation: Sendable {
    let header: BackupLogicalHeaderV1
    package let digest: Data
    package let memberCount: Int
    package let recordCount: Int
    package let inboxItemCount: Int
}

/// Only called for an empty App-created database in receipt-owned staging, never an input database.
enum SQLiteLogicalRestore {
    /// Space for the current App schema, independent of the logical wire version.
    /// Each B-tree entry gets a full 4 KiB page of cell/header/slack allowance;
    /// doubling payload + pages covers splits, internal pages and overflow slack.
    /// Variable data is at most four copies for reports (detail/search/summary/source),
    /// two for normalized DICOM/archive rows, and one for other domains. No index
    /// stores an unbounded string: indexed keys are IDs, hashes, ordinals and dates.
    static func databaseBudget(spool: SQLiteLogicalSpool, check: () throws -> Void) throws -> UInt64 {
        var payloadBytes: UInt64 = 0, treeEntries: UInt64 = 0
        func add(_ target: inout UInt64, _ value: UInt64) throws {
            let next = target.addingReportingOverflow(value)
            guard !next.overflow else { throw SQLiteLogicalBackupError.resourceLimit }; target = next.partialValue
        }
        _ = try SQLiteLogicalStream.read(byteCount: spool.byteCount, read: spool.read) { record in
            try check()
            let copies: UInt64, entries: UInt64
            switch record.kind {
            case .member: copies = 1; entries = 2
            case .original: copies = 1; entries = 3
            case .reportDocument, .lanDocument: copies = 1; entries = 2
            case .report:
                let value: HealthRecord = try canonical(record)
                guard value.sources.count <= 20_000 else { throw SQLiteLogicalBackupError.resourceLimit }
                copies = 4; entries = 10 + 7 * UInt64(value.sources.count)
            case .draft:
                let value: ImportDraft = try canonical(record)
                guard value.sources.count <= 20_000 else { throw SQLiteLogicalBackupError.resourceLimit }
                copies = 1; entries = 5 + 7 * UInt64(value.sources.count)
            case .inbox: copies = 1; entries = 7
            case .terminal: copies = 1; entries = 3
            case .receipt: copies = 1; entries = 4
            case .archiveReceipt: copies = 2; entries = 2
            case .dicom:
                let value: BackupLogicalDICOMV1 = try canonical(record)
                copies = 2
                entries = 5 + 3 * UInt64(value.index.retainedObjects.count)
                    + 4 * UInt64(value.index.series.count)
                    + 6 * UInt64(value.index.instances.count)
            }
            try add(&payloadBytes, UInt64(record.payload.count) * copies)
            try add(&treeEntries, entries)
        }
        let pages = treeEntries.multipliedReportingOverflow(by: 4_096)
        guard !pages.overflow else { throw SQLiteLogicalBackupError.resourceLimit }
        try add(&payloadBytes, pages.partialValue)
        let doubled = payloadBytes.multipliedReportingOverflow(by: 2)
        guard !doubled.overflow else { throw SQLiteLogicalBackupError.resourceLimit }
        // Empty App schema and its DELETE journal: insertion uses one transaction;
        // pages newly appended by that transaction do not need rollback images.
        var result = doubled.partialValue; try add(&result, 1_024 * 1_024)
        return result
    }

    /// What the container that carried a logical stream says about one original.
    struct ExpectedOriginal: Equatable, Sendable {
        let byteCount: UInt64
        let sha256: Data
        let contentType: String
    }

    /// Rebuilds the library in `store` from the logical stream. The originals must already be
    /// staged under their identifiers, and must be exactly those `originals` describes.
    static func restore(spool: SQLiteLogicalSpool, originals originalEntries: [UUID: ExpectedOriginal], revisionPair: BackupRevisionPair,
                        store: SQLiteLibraryStore,
                        check: () throws -> Void = { try Task.checkCancellation() }) throws -> SQLiteLogicalValidation {
        var restored: Set<UUID> = []
        try store.write { db in
            guard try Int.fetchOne(db, sql: "SELECT count(*) FROM members") == 0,
                  try Int.fetchOne(db, sql: "SELECT count(*) FROM originals") == 0 else { throw SQLiteLogicalBackupError.invalidStream }
            let header = try SQLiteLogicalStream.read(byteCount: spool.byteCount, read: spool.read, receiveHeader: { header in
                let state = SQLiteLibraryState(libraryID: header.libraryID, generation: header.generation, commitID: header.commitID)
                guard try SQLiteLogicalBackupSource.revision(header) == revisionPair else { throw SQLiteLogicalBackupError.invalidStream }
                try db.execute(sql: "UPDATE library_state SET library_id=?,generation=?,commit_id=?,content_hash=? WHERE singleton=1",
                    arguments: [state.libraryID.sqliteBytes, state.generation, state.commitID.sqliteBytes, state.contentHash])
            }) { record in
                try check()
                switch record.kind {
                case .member:
                    let value: FamilyMember = try canonical(record)
                    guard value.id == (try record.id) else { throw SQLiteLogicalBackupError.invalidStream }
                    try SQLiteReportRows.saveMember(value, revision: 0, db)
                case .original:
                    let value: BackupLogicalOriginalV1 = try canonical(record)
                    guard value.id == (try record.id), let entry = originalEntries[value.id],
                          value.byteCount >= 0, UInt64(value.byteCount) == entry.byteCount, value.sha256 == entry.sha256,
                          entry.contentType == value.contentType else { throw SQLiteLogicalBackupError.invalidStream }
                    _ = try BackupLogicalOriginalV1(id: value.id, byteCount: value.byteCount, sha256: value.sha256, contentType: value.contentType)
                    let url = store.originalsURL.appendingPathComponent(value.id.uuidString.lowercased() + ".data")
                    let identity = try SQLiteFileIdentity.regular(at: url)
                    let original = SQLiteOriginal(id: value.id, byteCount: value.byteCount, sha256: value.sha256,
                        contentType: value.contentType, lifecycle: "live", operationID: UUID(), identity: identity)
                    try original.save(in: db); restored.insert(value.id)
                case .reportDocument:
                    let value: BackupLogicalReportDocumentV1 = try canonical(record)
                    try insertDocument(id: record.id, kind: "report", revision: value.revision,
                        extraction: value.document.candidateExtractionVersion, bytes: CanonicalVaultJSON.encode(value.document), db)
                case .lanDocument:
                    let value: BackupLogicalLANDocumentV1 = try canonical(record)
                    let document = try LANPreprocessedSourceDocument(source: value.source, contentTypeIdentifier: value.contentType, blocks: value.blocks)
                    try insertDocument(id: record.id, kind: "lanSource", revision: value.revision, extraction: nil, bytes: CanonicalVaultJSON.encode(document), db)
                case .report:
                    let value: HealthRecord = try canonical(record)
                    guard value.id == (try record.id) else { throw SQLiteLogicalBackupError.invalidStream }
                    let digest = try documentHash(value.ocrDocumentObjectID, db)
                    try SQLiteReportRows.saveRecord(value, documentHash: digest, db)
                case .draft:
                    let value: ImportDraft = try canonical(record)
                    guard value.id == (try record.id), value.state != .processing, value.state != .staging else { throw SQLiteLogicalBackupError.invalidStream }
                    try SQLiteReportRows.saveDraft(value, documentHash: documentHash(value.documentObjectID, db), db, replaceSources: true)
                case .inbox:
                    let value: LANInboxItem = try canonical(record)
                    guard value.id == (try record.id), value.attemptID == nil else { throw SQLiteLogicalBackupError.invalidStream }
                    try SQLiteLANRows.saveItem(value, db)
                case .terminal:
                    let value: LANInboxContentTerminal = try canonical(record)
                    guard value.id == (try record.id) else { throw SQLiteLogicalBackupError.invalidStream }
                    try SQLiteLANRows.saveTerminal(value, db)
                case .receipt:
                    let value: LANInboxTransportReceipt = try canonical(record)
                    guard value.id == (try record.id) else { throw SQLiteLogicalBackupError.invalidStream }
                    try SQLiteLANRows.saveReceipt(value, db)
                case .archiveReceipt:
                    let value: BackupLogicalArchiveReceiptV1 = try canonical(record)
                    let command = SQLiteLANArchiveCommand(itemIDs: value.itemIDs, memberID: value.memberID, date: value.date)
                    guard try command.hash == record.key, value.generation >= 0,
                          value.generation <= (try SQLiteLibraryState.read(from: db).generation) else { throw SQLiteLogicalBackupError.invalidStream }
                    try SQLiteReportRows.put(db, table: "inbox_archive_receipts", columns: SQLiteLANRows.archiveColumns,
                        values: [record.key.databaseValue, try command.data.databaseValue, try CanonicalVaultJSON.encode(value.intent).databaseValue,
                                 try CanonicalVaultJSON.encode(value.outcome).databaseValue, value.generation.databaseValue])
                    _ = try SQLiteLANRows.archiveOutcome(command, db)
                case .dicom:
                    let value: BackupLogicalDICOMV1 = try canonical(record)
                    guard value.index.studyID == (try record.id) else { throw SQLiteLogicalBackupError.invalidStream }
                    try SQLiteDICOMRows.insertStudy(value.header(), index: value.index, operationID: UUID(), db)
                }
            }
            guard restored == Set(originalEntries.keys), try SQLiteLogicalBackupSource.revision(header) == revisionPair else { throw SQLiteLogicalBackupError.invalidStream }
            try SQLiteLogicalRows.bounds(db)
        }
        let result = try SQLiteLogicalBackupSource(store: store).validateStrict(check: check)
        guard result.digest == (try spool.read(offset: spool.byteCount - 32, count: 32)) else { throw SQLiteLogicalBackupError.invalidStream }
        return result
    }
    private static func canonical<T: Codable>(_ record: SQLiteLogicalRecord) throws -> T {
        let value = try record.decode(T.self)
        guard try CanonicalVaultJSON.encode(value) == record.payload else { throw SQLiteLogicalBackupError.invalidStream }
        return value
    }
    private static func documentHash(_ id: UUID?, _ db: Database) throws -> Data? {
        guard let id else { return nil }
        guard let hash = try Data.fetchOne(db, sql: "SELECT sha256 FROM ocr_documents WHERE id=?", arguments: [id.sqliteBytes]) else { throw SQLiteLogicalBackupError.invalidStream }
        return hash
    }
    private static func insertDocument(id: UUID, kind: String, revision: UInt64, extraction: Int?, bytes: Data, _ db: Database) throws {
        guard revision <= Int64.max, bytes.count <= (kind == "report" ? 16 : 32) * 1_024 * 1_024 else { throw SQLiteLogicalBackupError.resourceLimit }
        try SQLiteReportRows.put(db, table: "ocr_documents", columns: SQLiteReportRows.documentColumns,
            values: [id.sqliteBytes.databaseValue, kind.databaseValue, 1.databaseValue, extraction.databaseValue, Int64(revision).databaseValue,
                     bytes.databaseValue, ContentDigest.sha256(bytes).databaseValue])
    }
}
