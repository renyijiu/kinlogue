import Foundation
import GRDB
import KinlogueCore

private struct SQLiteLANVerifiedDestination: Sendable {
    let destination: LANReportDuplicateDestination
    let revision: UInt64
    let sources: ReportSources
    let documentID: UUID?
    let documentHash: Data?

    static func read(_ destination: LANReportDuplicateDestination, _ db: Database) throws -> Self {
        let sources: ReportSources, revision: UInt64, documentID: UUID?, documentHash: Data?
        switch destination.kind {
        case .healthRecord:
            let record = try SQLiteReportRows.record(destination.id, db)
            sources = record.sources; revision = record.revision; documentID = record.ocrDocumentObjectID
            documentHash = try Data.fetchOne(db, sql: "SELECT document_hash FROM reports WHERE record_id = ?", arguments: [destination.id.sqliteBytes])
        case .importDraft:
            let draft = try SQLiteReportRows.draft(destination.id, db)
            guard draft.state == .needsReview else { throw LANInboxError.staleRevision }
            sources = draft.sources; revision = draft.revision; documentID = draft.documentObjectID
            documentHash = try SQLiteReportRows.draftRow(destination.id, db)["document_hash"]
        }
        if let documentID { _ = try SQLiteReportRows.document(documentID, sources: sources, expectedHash: documentHash, db) }
        return Self(destination: destination, revision: revision, sources: sources, documentID: documentID, documentHash: documentHash)
    }

    func validate(_ db: Database, fingerprint: Data) throws {
        let current = try Self.read(destination, db)
        guard current.revision == revision, current.sources == sources, current.documentID == documentID, current.documentHash == documentHash,
              try SQLiteReportRows.fingerprint(sources, db) == fingerprint else { throw LANInboxError.staleRevision }
    }
}

extension SQLiteLANInboxStore {
    @concurrent
    package func completedArchive(itemIDs: [UUID], memberID: UUID, canonicalReportDate: Date) async throws -> LANArchiveOutcome? {
        try store.read(epoch: epoch) { try SQLiteLANRows.archiveOutcome(Self.command(itemIDs, memberID, canonicalReportDate), $0) }
    }

    @concurrent
    package func archive(_ prepared: LANPreparedItemSelection, memberID: UUID, canonicalReportDate: Date,
                         activeSessionID: UUID?) async throws -> LANArchiveOutcome {
        let command = try Self.command(prepared.items.map(\.id), memberID, canonicalReportDate)
        guard prepared.items.count == prepared.sourceDocuments.count,
              prepared.sources.elements == prepared.sourceDocuments.map(\.source),
              try prepared.document.attributedAndValidated(for: prepared.sources) == prepared.document,
              try CanonicalVaultJSON.encode(prepared.document).count <= SQLiteLibrarySchema.maximumPayloadBytes else { throw LANInboxError.resourceLimitExceeded }
        if let completed = try store.read(epoch: epoch, { try SQLiteLANRows.archiveOutcome(command, $0) }) { return completed }
        let intent = try store.read(epoch: epoch) { db in
            try SQLiteReportRows.requireMember(memberID, in: db)
            let sources = try zip(prepared.items, prepared.sourceDocuments).map { item, document -> LANArchiveSource in
                guard try usableItem(item.id, db) == item,
                      try Self.document(for: item, revision: item.revision, db) == document else { throw LANInboxError.staleRevision }
                return try LANArchiveSource(itemID: item.id, itemRevision: item.revision, contentIdentity: item.contentIdentity,
                    reportSourceID: document.source.id, attachmentID: document.source.attachmentID)
            }
            return try LANArchiveIntent(vaultID: SQLiteLibraryState.read(from: db).libraryID, orderedSources: sources,
                memberID: memberID, canonicalReportDate: command.date, draftID: UUID(), documentObjectID: UUID())
        }
        let fingerprint = ContentDigest.sha256(try CanonicalVaultJSON.encode(intent.fingerprint))
        let duplicate = try store.read(epoch: epoch) { db -> SQLiteLANVerifiedDestination? in
            let destination: LANReportDuplicateDestination?
            if let bytes = try Data.fetchOne(db, sql: "SELECT record_id FROM reports WHERE fingerprint_version = ? AND fingerprint = ? ORDER BY record_id LIMIT 1", arguments: [ReportFingerprint.currentVersion, fingerprint]), let id = UUID(sqliteBytes: bytes) {
                destination = LANReportDuplicateDestination(kind: .healthRecord, id: id)
            } else if let bytes = try Data.fetchOne(db, sql: "SELECT draft_id FROM import_drafts WHERE state = 'needsReview' AND fingerprint_version = ? AND fingerprint = ? ORDER BY draft_id LIMIT 1", arguments: [ReportFingerprint.currentVersion, fingerprint]), let id = UUID(sqliteBytes: bytes) {
                destination = LANReportDuplicateDestination(kind: .importDraft, id: id)
            } else { destination = nil }
            return try destination.map { try SQLiteLANVerifiedDestination.read($0, db) }
        }
        var pins: [SQLiteOriginalPin] = []
        defer { for pin in pins { pin.release() } }
        let originalIDs = Set(prepared.items.map(\.blobID)).union(duplicate?.sources.attachmentIDs ?? [])
        guard originalIDs.count <= 40 else { throw LANInboxError.resourceLimitExceeded }
        for id in originalIDs {
            try Task.checkCancellation()
            let pin = try store.pinOriginal(id)
            pins.append(pin)
            try pin.withVerifiedDescriptor { _ in () }
        }
        try Task.checkCancellation()
        let outcome = try write { db in
            if let completed = try SQLiteLANRows.archiveOutcome(command, db) { return completed }
            try SQLiteReportRows.requireMember(memberID, in: db)
            for (item, source) in zip(prepared.items, prepared.sourceDocuments) {
                guard try usableItem(item.id, db) == item,
                      try Self.document(for: item, revision: item.revision, db) == source else { throw LANInboxError.staleRevision }
            }
            let outcome: LANArchiveOutcome
            if let duplicate {
                try duplicate.validate(db, fingerprint: fingerprint)
                outcome = .duplicateSkipped(duplicate.destination)
            } else {
                guard try Int.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM reports WHERE fingerprint_version = ? AND fingerprint = ? UNION ALL SELECT 1 FROM import_drafts WHERE state = 'needsReview' AND fingerprint_version = ? AND fingerprint = ?)", arguments: [ReportFingerprint.currentVersion, fingerprint, ReportFingerprint.currentVersion, fingerprint]) == 0 else { throw LANInboxError.mutationConflict }
                try SQLiteReportRepository.checkNewDraftCapacity(originalIDs: Set(prepared.items.map(\.blobID)), db)
                let documentHash = try SQLiteReportRows.saveDocument(prepared.document, id: intent.documentObjectID, revision: 0, sources: prepared.sources, db)
                let draft = ImportDraft(id: intent.draftID, sources: prepared.sources, state: .needsReview, documentObjectID: intent.documentObjectID, memberID: memberID)
                try SQLiteReportRows.saveDraft(draft, documentHash: documentHash, db, replaceSources: true)
                outcome = .accepted(draftID: draft.id)
            }
            let contents = Set(prepared.items.map(\.contentIdentity))
            let receipts = try Self.receipts(contents: contents, db)
            var terminalContents: [UUID: Set<LANInboxContentIdentity>] = [:]
            for receipt in receipts {
                guard let content = receipt.contentIdentity else { throw LANInboxError.invalidReference }
                terminalContents[receipt.transport.sessionID, default: []].insert(content)
            }
            if let activeSessionID { terminalContents[activeSessionID, default: []].formUnion(contents) }
            for (session, values) in terminalContents {
                for content in values { try Self.putTerminal(session: session, content: content, kind: .archived, db) }
            }
            for receipt in receipts { try SQLiteLANRows.saveReceipt(Self.receipt(receipt, outcome: .archived), db) }
            for item in prepared.items {
                try db.execute(sql: "DELETE FROM inbox_items WHERE id = ?", arguments: [item.id.sqliteBytes])
                try SQLiteReportRows.deleteDocumentIfUnreferenced(item.derivedArtifact?.id, db)
            }
            try store.markUnreferencedOriginalsDeleting(Set(prepared.items.map(\.blobID)), in: db)
            let state = try SQLiteLibraryState.advance(in: db)
            // The bounded replay window retains the newest completed commands without owning original bytes.
            try db.execute(sql: "DELETE FROM inbox_archive_receipts WHERE command_hash IN (SELECT command_hash FROM inbox_archive_receipts ORDER BY generation DESC LIMIT -1 OFFSET 4999)")
            try SQLiteReportRows.put(db, table: "inbox_archive_receipts", columns: SQLiteLANRows.archiveColumns, values: [
                try command.hash.databaseValue, try command.data.databaseValue, try CanonicalVaultJSON.encode(intent).databaseValue,
                try CanonicalVaultJSON.encode(outcome).databaseValue, state.generation.databaseValue])
            return outcome
        }
        for id in Set(prepared.items.map(\.blobID)) { try store.reclaimDeletingOriginal(id) }
        return outcome
    }

    private static func command(_ itemIDs: [UUID], _ memberID: UUID, _ date: Date) throws -> SQLiteLANArchiveCommand {
        guard !itemIDs.isEmpty, itemIDs.count <= LANArchiveIntent.maximumSourceCount, Set(itemIDs).count == itemIDs.count,
              date.timeIntervalSinceReferenceDate.isFinite else { throw LANInboxError.invalidModel }
        return SQLiteLANArchiveCommand(itemIDs: itemIDs, memberID: memberID, date: CanonicalVaultJSON.persistenceStableDate(date))
    }
}
