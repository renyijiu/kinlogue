import Foundation
import GRDB
import KinlogueCore

struct SQLiteLANArchiveCommand: Codable, Equatable, Sendable {
    let itemIDs: [UUID]
    let memberID: UUID
    let date: Date
    var data: Data { get throws { try CanonicalVaultJSON.encode(self) } }
    var hash: Data { get throws { SQLiteContentHash.hash(domain: "inbox_archive_command:1", values: [.blob(try data)]) } }
}

enum SQLiteLANRows {
    static let itemColumns = ["id", "originating_session_id", "sequence", "revision", "state", "original_id", "content_sha256", "content_byte_count", "derived_document_id", "derived_sha256", "derived_byte_count", "attempt_id", "display_name", "received_at", "failure_code"]
    static let receiptColumns = ["id", "display_name", "declared_byte_count", "media_type", "attempt_revision", "completed_at", "content_sha256", "content_byte_count", "session_id", "remote_file_id", "outcome", "item_id", "terminal_sha256", "terminal_byte_count"]
    static let terminalColumns = ["id", "created_at", "session_id", "sha256", "byte_count", "kind", "revision", "admission_generation_cutoff"]
    static let archiveColumns = ["command_hash", "command", "intent", "outcome", "generation"]

    static func item(_ id: UUID, _ db: Database) throws -> LANInboxItem {
        guard let row = try SQLiteRows.fetchOne(db, sql: "SELECT * FROM inbox_items WHERE id = ?", arguments: [id.sqliteBytes]) else { throw LANInboxError.fileNotFound }
        let original = try SQLiteOriginal.read(SQLiteReportRows.uuid(row, "original_id"), from: db)
        let documentID = try SQLiteReportRows.optionalUUID(row, "derived_document_id")
        let metadata = try documentID.flatMap { id in
            try SQLiteRows.fetchOne(db, sql: "SELECT kind,sha256,length(payload) AS byte_count FROM ocr_documents WHERE id = ?", arguments: [id.sqliteBytes])
        }
        if let documentID { try SQLiteReportRows.requireExclusiveDocument(documentID, reportID: nil, draftID: nil, inboxID: id, db) }
        return try item(row, original: original, metadata: metadata)
    }

    static func item(_ row: Row, original: SQLiteOriginal, metadata: Row?) throws -> LANInboxItem {
        try SQLiteReportRows.verify(row, table: "inbox_items", columns: itemColumns)
        let id = try SQLiteReportRows.uuid(row, "id")
        let originalID = try SQLiteReportRows.uuid(row, "original_id")
        guard original.id == originalID, original.lifecycle == "live", original.sha256 == row["content_sha256"] as Data,
              original.byteCount == row["content_byte_count"] as Int else { throw LANInboxError.integrityCheckFailed }
        let documentID = try SQLiteReportRows.optionalUUID(row, "derived_document_id")
        let derived: LANInboxDerivedArtifact?
        if let documentID {
            if let metadata { try SQLiteRows.validateText(metadata, table: "ocr_documents") }
            guard let metadata, metadata["kind"] as String == "lanSource",
                  metadata["sha256"] as Data == row["derived_sha256"] as Data?,
                  metadata["byte_count"] as Int == row["derived_byte_count"] as Int? else { throw LANInboxError.integrityCheckFailed }
            derived = try LANInboxDerivedArtifact(id: documentID, sha256Digest: row["derived_sha256"], byteCount: row["derived_byte_count"])
        } else { derived = nil }
        let attempt = try SQLiteReportRows.optionalUUID(row, "attempt_id")
        let issueRaw: String? = row["failure_code"]
        let issue = issueRaw.flatMap(LANInboxFileIssue.init(rawValue:))
        let state: LANInboxItemState
        switch row["state"] as String {
        case "stored": state = .stored(blobID: originalID)
        case "preprocessing": guard let attempt else { throw LANInboxError.invalidState }; state = .preprocessing(blobID: originalID, attemptID: attempt)
        case "reviewable": guard let derived else { throw LANInboxError.invalidState }; state = .reviewable(blobID: originalID, derived: derived)
        case "unsupported": guard let issue else { throw LANInboxError.invalidState }; state = .unsupported(blobID: originalID, issue: issue)
        case "failed": guard let issue else { throw LANInboxError.invalidState }; state = .failed(blobID: originalID, issue: issue)
        case "integrityFailed": guard let issue else { throw LANInboxError.invalidState }; state = .integrityFailed(blobID: originalID, issue: issue)
        default: throw LANInboxError.invalidState
        }
        let value = try LANInboxItem(id: id, originatingSessionID: SQLiteReportRows.uuid(row, "originating_session_id"),
            displayName: LANInboxDisplayName(rawValue: row["display_name"]), receivedAt: Date(timeIntervalSince1970: row["received_at"]),
            sequence: UInt64(row["sequence"] as Int64), revision: UInt64(row["revision"] as Int64),
            contentIdentity: LANInboxContentIdentity(sha256Digest: original.sha256, byteCount: original.byteCount), state: state)
        guard value.attemptID == attempt, value.issue?.rawValue == issueRaw, value.derivedArtifact == derived,
              value.displayName.rawValue == row["display_name"] as String,
              (derived == nil) == (row["derived_sha256"] as Data? == nil),
              (derived == nil) == (row["derived_byte_count"] as Int? == nil) else { throw LANInboxError.invalidModel }
        return value
    }

    static func saveItem(_ value: LANInboxItem, _ db: Database) throws {
        guard value.sequence <= Int64.max, value.revision <= Int64.max else { throw LANInboxError.invalidRevision }
        let state: String
        switch value.state { case .stored: state = "stored"; case .preprocessing: state = "preprocessing"; case .reviewable: state = "reviewable"; case .unsupported: state = "unsupported"; case .failed: state = "failed"; case .integrityFailed: state = "integrityFailed" }
        try SQLiteReportRows.put(db, table: "inbox_items", columns: itemColumns, values: [
            value.id.sqliteBytes.databaseValue, value.originatingSessionID.sqliteBytes.databaseValue,
            Int64(value.sequence).databaseValue, Int64(value.revision).databaseValue, state.databaseValue, value.blobID.sqliteBytes.databaseValue,
            value.contentIdentity.sha256Digest.databaseValue, value.contentIdentity.byteCount.databaseValue,
            value.derivedArtifact?.id.sqliteBytes.databaseValue ?? .null, value.derivedArtifact?.sha256Digest.databaseValue ?? .null,
            value.derivedArtifact?.byteCount.databaseValue ?? .null, value.attemptID?.sqliteBytes.databaseValue ?? .null,
            value.displayName.rawValue.databaseValue, value.receivedAt.timeIntervalSince1970.databaseValue, value.issue?.rawValue.databaseValue ?? .null])
    }

    static func receipt(_ transport: LANInboxTransportIdentity, _ db: Database) throws -> LANInboxTransportReceipt? {
        guard let row = try SQLiteRows.fetchOne(db, sql: "SELECT * FROM inbox_transport_receipts WHERE session_id = ? AND remote_file_id = ?", arguments: [transport.sessionID.sqliteBytes, transport.remoteFileID.sqliteBytes]) else { return nil }
        return try receipt(row, item: { try item($0, db) }, terminal: { try terminal(session: $0, content: $1, db) })
    }

    static func receipt(_ row: Row, item: (UUID) throws -> LANInboxItem,
                        terminal: (UUID, LANInboxContentIdentity) throws -> LANInboxContentTerminal?) throws -> LANInboxTransportReceipt {
        let transport = try LANInboxTransportIdentity(sessionID: SQLiteReportRows.uuid(row, "session_id"), remoteFileID: SQLiteReportRows.uuid(row, "remote_file_id"))
        try SQLiteReportRows.verify(row, table: "inbox_transport_receipts", columns: receiptColumns)
        let digest: Data? = row["content_sha256"], count: Int? = row["content_byte_count"]
        let content = try digest.flatMap { digest in try count.map { try LANInboxContentIdentity(sha256Digest: digest, byteCount: $0) } }
        let outcome: LANInboxTransportOutcome
        switch row["outcome"] as String {
        case "published", "merged":
            let itemID = try SQLiteReportRows.uuid(row, "item_id")
            guard try item(itemID).contentIdentity == content else { throw LANInboxError.invalidReference }
            outcome = row["outcome"] as String == "published" ? .published(itemID: itemID) : .merged(itemID: itemID)
        case "archived", "deleted":
            guard let content, let terminal = try terminal(transport.sessionID, content),
                  row["terminal_sha256"] as Data? == content.sha256Digest, row["terminal_byte_count"] as Int? == content.byteCount else { throw LANInboxError.invalidReference }
            switch (row["outcome"] as String, terminal.kind) {
            case ("archived", .archived): outcome = .archived
            case ("deleted", .deleted): outcome = .deleted
            default: throw LANInboxError.invalidReference
            }
        case "cancelled": outcome = .cancelled
        default: throw LANInboxError.invalidState
        }
        return try LANInboxTransportReceipt(id: SQLiteReportRows.uuid(row, "id"), transport: transport,
            metadata: LANInboxTransportMetadata(displayName: LANInboxDisplayName(rawValue: row["display_name"]), declaredByteCount: row["declared_byte_count"], mediaType: row["media_type"]),
            attemptRevision: UInt64(row["attempt_revision"] as Int64), contentIdentity: content,
            completedAt: Date(timeIntervalSince1970: row["completed_at"]), outcome: outcome)
    }

    static func saveReceipt(_ value: LANInboxTransportReceipt, _ db: Database) throws {
        guard value.attemptRevision <= Int64.max else { throw LANInboxError.invalidRevision }
        let outcome: String, itemID: UUID?, terminal: LANInboxContentIdentity?
        switch value.outcome {
        case let .published(id): outcome = "published"; itemID = id; terminal = nil
        case let .merged(id): outcome = "merged"; itemID = id; terminal = nil
        case .archived: outcome = "archived"; itemID = nil; terminal = value.contentIdentity
        case .deleted: outcome = "deleted"; itemID = nil; terminal = value.contentIdentity
        case .cancelled: outcome = "cancelled"; itemID = nil; terminal = nil
        }
        try SQLiteReportRows.put(db, table: "inbox_transport_receipts", columns: receiptColumns, values: [value.id.sqliteBytes.databaseValue,
            value.metadata.displayName.rawValue.databaseValue, value.metadata.declaredByteCount.databaseValue, value.metadata.mediaType.databaseValue,
            Int64(value.attemptRevision).databaseValue, value.completedAt.timeIntervalSince1970.databaseValue,
            value.contentIdentity?.sha256Digest.databaseValue ?? .null, value.contentIdentity?.byteCount.databaseValue ?? .null,
            value.transport.sessionID.sqliteBytes.databaseValue, value.transport.remoteFileID.sqliteBytes.databaseValue, outcome.databaseValue,
            itemID?.sqliteBytes.databaseValue ?? .null, terminal?.sha256Digest.databaseValue ?? .null, terminal?.byteCount.databaseValue ?? .null])
    }

    static func terminal(session: UUID, content: LANInboxContentIdentity, _ db: Database) throws -> LANInboxContentTerminal? {
        guard let row = try SQLiteRows.fetchOne(db, sql: "SELECT * FROM inbox_content_terminals WHERE session_id = ? AND sha256 = ? AND byte_count = ?", arguments: [session.sqliteBytes, content.sha256Digest, content.byteCount]) else { return nil }
        return try terminal(row)
    }

    static func terminal(_ row: Row) throws -> LANInboxContentTerminal {
        let session = try SQLiteReportRows.uuid(row, "session_id")
        let content = try LANInboxContentIdentity(sha256Digest: row["sha256"], byteCount: row["byte_count"])
        try SQLiteReportRows.verify(row, table: "inbox_content_terminals", columns: terminalColumns)
        let kind: LANInboxContentTerminalKind
        if row["kind"] as String == "archived" {
            guard row["admission_generation_cutoff"] as Int64? == nil else { throw LANInboxError.invalidModel }
            kind = .archived
        } else {
            guard let cutoff: Int64 = row["admission_generation_cutoff"] else { throw LANInboxError.invalidModel }
            kind = .deleted(admissionGenerationCutoff: UInt64(cutoff) + 1)
        }
        return try LANInboxContentTerminal(id: SQLiteReportRows.uuid(row, "id"), sessionID: session, contentIdentity: content,
            createdAt: Date(timeIntervalSince1970: row["created_at"]), kind: kind)
    }

    static func saveTerminal(_ value: LANInboxContentTerminal, _ db: Database) throws {
        let kind: String, cutoff: Int64?
        switch value.kind {
        case .archived: kind = "archived"; cutoff = nil
        case let .deleted(generation): guard generation > 0, generation - 1 <= Int64.max else { throw LANInboxError.invalidGeneration }; kind = "deleted"; cutoff = Int64(generation - 1)
        }
        try SQLiteReportRows.put(db, table: "inbox_content_terminals", columns: terminalColumns, values: [value.id.sqliteBytes.databaseValue,
            value.createdAt.timeIntervalSince1970.databaseValue, value.sessionID.sqliteBytes.databaseValue, value.contentIdentity.sha256Digest.databaseValue,
            value.contentIdentity.byteCount.databaseValue, kind.databaseValue, 0.databaseValue, cutoff.databaseValue])
    }

    static func canonicalItem(_ content: LANInboxContentIdentity, _ db: Database) throws -> LANInboxItem? {
        guard let bytes = try Data.fetchOne(db, sql: "SELECT id FROM inbox_items WHERE content_sha256 = ? AND content_byte_count = ?", arguments: [content.sha256Digest, content.byteCount]), let id = UUID(sqliteBytes: bytes) else { return nil }
        return try item(id, db)
    }

    static func snapshot(_ db: Database, epoch: UUID) throws -> LANInboxSnapshot {
        let state = try SQLiteLibraryState.read(from: db)
        let items = try Data.fetchAll(db, sql: "SELECT id FROM inbox_items ORDER BY sequence LIMIT 5001").map { bytes -> LANInboxItem in
            guard let id = UUID(sqliteBytes: bytes) else { throw LANInboxError.invalidModel }; return try item(id, db)
        }
        let receipts = try SQLiteRows.fetchAll(db, sql: "SELECT session_id,remote_file_id FROM inbox_transport_receipts LIMIT 5001").map { row -> LANInboxTransportReceipt in
            let transport = try LANInboxTransportIdentity(sessionID: SQLiteReportRows.uuid(row, "session_id"), remoteFileID: SQLiteReportRows.uuid(row, "remote_file_id"))
            guard let value = try receipt(transport, db) else { throw LANInboxError.invalidReference }; return value
        }
        let terminals = try SQLiteRows.fetchAll(db, sql: "SELECT session_id,sha256,byte_count FROM inbox_content_terminals LIMIT 5001").map { row -> LANInboxContentTerminal in
            guard let value = try terminal(session: SQLiteReportRows.uuid(row, "session_id"), content: LANInboxContentIdentity(sha256Digest: row["sha256"], byteCount: row["byte_count"]), db) else { throw LANInboxError.invalidReference }; return value
        }
        return try LANInboxSnapshot(vaultID: state.libraryID, generation: UInt64(state.generation) + 1, commitID: state.commitID,
            lastWriterRuntimeGeneration: epoch, items: items, transportReceipts: receipts, contentTerminals: terminals,
            blobs: items.map { try LANInboxBlob(id: $0.blobID, sha256Digest: $0.contentIdentity.sha256Digest, byteCount: $0.contentIdentity.byteCount) })
    }

    struct Screen {
        let snapshot: LANInboxSnapshot
        let damagedItemIDs: [UUID]
        let damagedReceiptIDs: [UUID]
        let damagedTerminalIDs: [UUID]
    }
    private struct TerminalKey: Hashable {
        let session: UUID
        let content: LANInboxContentIdentity
    }

    /// Hot UI projection. Strict snapshot/backup and per-target source reads stay strict.
    static func screen(_ db: Database, epoch: UUID, quarantinedItemIDs: Set<UUID> = []) throws -> Screen {
        let state = try SQLiteLibraryState.read(from: db)
        let itemRows = try SQLiteRows.fetchAll(db, sql: "SELECT \(SQLiteHotProjection.sql(itemColumns, bounds: ["display_name": 1_024, "failure_code": 128])) FROM inbox_items ORDER BY sequence LIMIT 5001")
        let originalRows = try SQLiteRows.fetchAll(db, sql: "SELECT \(SQLiteHotProjection.sql(["id","byte_count","sha256","content_type","lifecycle","operation_id","file_device","file_inode"], bounds: ["content_type": 256], qualifier: "o")) FROM originals o JOIN inbox_items i ON i.original_id=o.id LIMIT 5001")
        let documentRows = try SQLiteRows.fetchAll(db, sql: """
            SELECT d.id,d.kind,d.sha256,length(d.payload) AS byte_count,
              (SELECT count(*) FROM reports WHERE document_id=d.id) +
              (SELECT count(*) FROM import_drafts WHERE document_id=d.id) +
              (SELECT count(*) FROM inbox_items WHERE derived_document_id=d.id) AS owner_count
            FROM ocr_documents d JOIN inbox_items i ON i.derived_document_id=d.id LIMIT 5001
            """)
        let receiptRows = try SQLiteRows.fetchAll(db, sql: "SELECT \(SQLiteHotProjection.sql(receiptColumns, bounds: ["display_name": 1_024, "media_type": 256])) FROM inbox_transport_receipts LIMIT 5001")
        let terminalRows = try SQLiteRows.fetchAll(db, sql: "SELECT * FROM inbox_content_terminals LIMIT 5001")
        guard [itemRows.count, originalRows.count, documentRows.count, receiptRows.count, terminalRows.count].allSatisfy({ $0 <= 5_000 }) else { throw LANInboxError.resourceLimitExceeded }
        var originals: [UUID: SQLiteOriginal] = [:], metadata: [UUID: Row] = [:]
        for row in originalRows where !(row["oversized"] as Bool) { if let value = try? SQLiteOriginal.decode(row) { originals[value.id] = value } }
        for row in documentRows where row["owner_count"] as Int == 1 { metadata[try SQLiteReportRows.uuid(row, "id")] = row }
        var items: [LANInboxItem] = [], damagedItems: [UUID] = []
        for row in itemRows {
            let id = try SQLiteReportRows.uuid(row, "id")
            do {
                guard !quarantinedItemIDs.contains(id), !(row["oversized"] as Bool), let original = originals[try SQLiteReportRows.uuid(row, "original_id")] else { throw LANInboxError.integrityCheckFailed }
                let document = try SQLiteReportRows.optionalUUID(row, "derived_document_id").flatMap { metadata[$0] }
                items.append(try item(row, original: original, metadata: document))
            } catch { damagedItems.append(id) }
        }
        var terminals: [LANInboxContentTerminal] = [], damagedTerminals: [UUID] = []
        for row in terminalRows {
            do { terminals.append(try terminal(row)) }
            catch { damagedTerminals.append(try SQLiteReportRows.uuid(row, "id")) }
        }
        let itemMap = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let terminalMap = Dictionary(uniqueKeysWithValues: terminals.map { (TerminalKey(session: $0.sessionID, content: $0.contentIdentity), $0) })
        var receipts: [LANInboxTransportReceipt] = [], damagedReceipts: [UUID] = []
        for row in receiptRows {
            do {
                guard !(row["oversized"] as Bool) else { throw LANInboxError.resourceLimitExceeded }
                receipts.append(try receipt(row, item: { id in
                    guard let value = itemMap[id] else { throw LANInboxError.invalidReference }; return value
                }, terminal: { terminalMap[TerminalKey(session: $0, content: $1)] }))
            } catch { damagedReceipts.append(try SQLiteReportRows.uuid(row, "id")) }
        }
        return Screen(snapshot: try LANInboxSnapshot(vaultID: state.libraryID, generation: UInt64(state.generation) + 1,
            commitID: state.commitID, lastWriterRuntimeGeneration: epoch, items: items, transportReceipts: receipts,
            contentTerminals: terminals, blobs: items.map { try LANInboxBlob(id: $0.blobID,
                sha256Digest: $0.contentIdentity.sha256Digest, byteCount: $0.contentIdentity.byteCount) }),
            damagedItemIDs: damagedItems, damagedReceiptIDs: damagedReceipts, damagedTerminalIDs: damagedTerminals)
    }

    /// Metadata aggregates do not certify unread rows or attribute shared SQLite pages.
    static func totals(_ db: Database) throws -> (items: Int, sourceBytes: Int, documents: Int, documentBytes: Int) {
        let row = try Row.fetchOne(db, sql: """
            SELECT count(*) AS items, coalesce(sum(content_byte_count),0) AS source_bytes,
              count(derived_document_id) AS documents, coalesce(sum(derived_byte_count),0) AS document_bytes,
              coalesce(min(content_byte_count),1) AS min_source, coalesce(min(derived_byte_count),0) AS min_document,
              coalesce(max(derived_byte_count),0) AS max_document,
              (SELECT count(*) FROM inbox_transport_receipts) AS receipts,
              (SELECT count(*) FROM inbox_content_terminals) AS terminals
            FROM inbox_items
            """)!
        let count: Int = row["items"], documents: Int = row["documents"]
        guard count <= 5_000, documents <= count, (row["receipts"] as Int) <= 5_000,
              (row["terminals"] as Int) <= 5_000, (row["min_source"] as Int) >= 0,
              (row["min_document"] as Int) >= 0,
              (row["max_document"] as Int) <= LANPreprocessedSourceDocument.maximumEncodedByteCount else { throw LANInboxError.resourceLimitExceeded }
        return (count, row["source_bytes"], documents, row["document_bytes"])
    }

    static func page(_ db: Database, epoch: UUID, cursor: LANInboxPageCursor?, processing: Bool,
                     quarantinedItemIDs: Set<UUID>) throws -> LANInboxPage {
        let state = try SQLiteLibraryState.read(from: db)
        let revision = LibraryRevision(libraryID: state.libraryID, openEpoch: epoch,
            generation: UInt64(state.generation) + 1, commitID: state.commitID)
        if let cursor {
            // Processing walks stable keys while its own attempts advance the commit.
            guard cursor.processing == processing, cursor.revision.libraryID == revision.libraryID,
                  cursor.revision.openEpoch == epoch, processing || cursor.revision == revision,
                  cursor.sequence <= Int64.max else { throw LibraryReportError.staleCursor }
        }
        guard try Int.fetchOne(db, sql: "SELECT count(*) FROM inbox_items")! <= LANInboxSnapshot.maximumItemCount else { throw LANInboxError.resourceLimitExceeded }
        let predicate = cursor == nil ? "" : "WHERE (sequence,id) > (?,?)"
        let arguments: StatementArguments = cursor.map { [Int64($0.sequence), $0.id.sqliteBytes] } ?? []
        let rows = try SQLiteRows.fetchAll(db, sql: "SELECT \(SQLiteHotProjection.sql(itemColumns, bounds: ["display_name": 1_024, "failure_code": 128])) FROM inbox_items \(predicate) ORDER BY sequence,id LIMIT 101", arguments: arguments)
        let pageRows = Array(rows.prefix(100))
        var items: [LANInboxItem] = [], damaged = quarantinedItemIDs
        for row in pageRows {
            try Task.checkCancellation()
            let id = try SQLiteReportRows.uuid(row, "id")
            do {
                guard !quarantinedItemIDs.contains(id), !(row["oversized"] as Bool) else { throw LANInboxError.integrityCheckFailed }
                let originalID = try SQLiteReportRows.uuid(row, "original_id")
                guard let originalRow = try SQLiteRows.fetchOne(db, sql: "SELECT \(SQLiteHotProjection.sql(["id","byte_count","sha256","content_type","lifecycle","operation_id","file_device","file_inode"], bounds: ["content_type": 256])) FROM originals WHERE id=?", arguments: [originalID.sqliteBytes]),
                      !(originalRow["oversized"] as Bool) else { throw LANInboxError.integrityCheckFailed }
                let original = try SQLiteOriginal.decode(originalRow)
                let documentID = try SQLiteReportRows.optionalUUID(row, "derived_document_id")
                let metadata = try documentID.flatMap { documentID in
                    try SQLiteReportRows.requireExclusiveDocument(documentID, reportID: nil, draftID: nil, inboxID: id, db)
                    return try SQLiteRows.fetchOne(db, sql: "SELECT kind,sha256,length(payload) AS byte_count FROM ocr_documents WHERE id=?", arguments: [documentID.sqliteBytes])
                }
                items.append(try item(row, original: original, metadata: metadata))
            } catch let error as DatabaseError { throw error }
            catch is CancellationError { throw CancellationError() }
            catch { damaged.insert(id) }
        }
        let next: LANInboxPageCursor?
        if rows.count > 100, let last = pageRows.last {
            guard let sequence = UInt64(exactly: last["sequence"] as Int64) else { throw LANInboxError.invalidRevision }
            next = LANInboxPageCursor(revision: revision, sequence: sequence,
                id: try SQLiteReportRows.uuid(last, "id"), processing: processing)
        } else { next = nil }
        return LANInboxPage(revision: revision, items: items, nextCursor: next,
            damagedItemIDs: damaged.sorted { $0.uuidString < $1.uuidString })
    }

    static func archiveOutcome(_ command: SQLiteLANArchiveCommand, _ db: Database) throws -> LANArchiveOutcome? {
        guard let row = try SQLiteRows.fetchOne(db, sql: "SELECT * FROM inbox_archive_receipts WHERE command_hash = ?", arguments: [try command.hash]) else { return nil }
        try SQLiteReportRows.verify(row, table: "inbox_archive_receipts", columns: archiveColumns)
        let saved = try CanonicalVaultJSON.decode(SQLiteLANArchiveCommand.self, from: row["command"])
        let intent = try CanonicalVaultJSON.decode(LANArchiveIntent.self, from: row["intent"])
        let outcome = try CanonicalVaultJSON.decode(LANArchiveOutcome.self, from: row["outcome"])
        guard saved == command, try saved.hash == row["command_hash"] as Data,
              intent.orderedSources.map(\.itemID) == command.itemIDs, intent.memberID == command.memberID,
              intent.canonicalReportDate == command.date, intent.vaultID == (try SQLiteLibraryState.read(from: db)).libraryID else { throw LANInboxError.receiptConflict }
        if case let .accepted(id) = outcome, id != intent.draftID { throw LANInboxError.receiptConflict }
        return outcome
    }
}
