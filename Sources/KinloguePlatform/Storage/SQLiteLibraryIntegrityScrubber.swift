import Foundation
import GRDB
import KinlogueCore

package struct SQLiteIntegrityTarget: Hashable, Sendable {
    package enum Kind: String, CaseIterable, Sendable {
        case member, report, draft, document, original, inbox, terminal, receipt, archiveReceipt, study, upload
        var table: String {
            switch self {
            case .member: "members"
            case .report: "reports"
            case .draft: "import_drafts"
            case .document: "ocr_documents"
            case .original: "originals"
            case .inbox: "inbox_items"
            case .terminal: "inbox_content_terminals"
            case .receipt: "inbox_transport_receipts"
            case .archiveReceipt: "inbox_archive_receipts"
            case .study: "dicom_studies"
            case .upload: "inbox_uploads"
            }
        }
        var key: String {
            switch self { case .report: "record_id"; case .draft: "draft_id"; case .archiveReceipt: "command_hash"; default: "id" }
        }
    }
    package let kind: Kind
    let key: Data
    package var id: UUID? { UUID(sqliteBytes: key) }
}

package struct SQLiteIntegrityReport: Sendable {
    package let revision: LibraryRevision
    package let completed: Bool
    package let checkedCount: Int
    package let checkedAt: Date
    package let damagedTargets: [SQLiteIntegrityTarget]
}

/// A cold inspection uses the same per-entity codecs as strict logical backup.
/// It releases database admission between targets and never captures a full-library spool.
package struct SQLiteLibraryIntegrityScrubber: Sendable {
    let store: SQLiteLibraryStore
    package init(store: SQLiteLibraryStore) { self.store = store }

    @concurrent package func run(
        progress: @escaping @Sendable (Int) async throws -> Void = { _ in }
    ) async throws -> SQLiteIntegrityReport {
        let cancellation = SQLiteLogicalCancellation()
        return try await withTaskCancellationHandler {
            try await inspect(cancellation: cancellation, progress: progress)
        } onCancel: { cancellation.cancel() }
    }

    private func inspect(cancellation: SQLiteLogicalCancellation,
                         progress: @escaping @Sendable (Int) async throws -> Void) async throws -> SQLiteIntegrityReport {
        let (initial, epoch) = try store.readWithEpoch { db in
            try SQLiteReadProgress.withGuard(db, check: cancellation.check) {
                try SQLiteLibrarySchema.validate(in: db)
                guard try Int.fetchOne(db, sql: "SELECT count(*) FROM ocr_documents")! <= 45_000,
                      try Int.fetchOne(db, sql: "SELECT count(*) FROM inbox_archive_receipts")! <= 5_000 else { throw SQLiteLibraryError.damaged }
                guard try String.fetchAll(db, sql: "PRAGMA integrity_check") == ["ok"],
                      try Row.fetchOne(db, sql: "PRAGMA foreign_key_check") == nil else { throw SQLiteLibraryError.damaged }
                return try SQLiteLibraryState.read(from: db)
            }
        }
        let revision = LibraryRevision(libraryID: initial.libraryID, openEpoch: epoch,
            generation: UInt64(initial.generation), commitID: initial.commitID)
        var checked = 0
        var damaged: [SQLiteIntegrityTarget] = []
        func result(completed: Bool) -> SQLiteIntegrityReport {
            SQLiteIntegrityReport(revision: revision, completed: completed, checkedCount: checked,
                checkedAt: Date(), damagedTargets: damaged)
        }
        try await progress(checked)
        for kind in SQLiteIntegrityTarget.Kind.allCases {
            var after = Data()
            while true {
                try cancellation.check()
                let keys: [Data]? = try store.read(epoch: epoch) { db in
                    guard try SQLiteLibraryState.read(from: db) == initial else { return nil }
                    return try Data.fetchAll(db, sql: "SELECT \(kind.key) FROM \(kind.table) WHERE \(kind.key)>? ORDER BY \(kind.key) LIMIT 16", arguments: [after])
                }
                guard let keys else { return result(completed: false) }
                guard !keys.isEmpty else { break }
                for key in keys {
                    let target = SQLiteIntegrityTarget(kind: kind, key: key)
                    do {
                        let current = try store.read(epoch: epoch) { db in
                            guard try SQLiteLibraryState.read(from: db) == initial else { return false }
                            try SQLiteReadProgress.withGuard(db, check: cancellation.check) { try validate(target, db) }
                            return true
                        }
                        guard current else { return result(completed: false) }
                        if kind == .original, let id = target.id {
                            let live = try store.read(epoch: epoch) { try SQLiteOriginal.read(id, from: $0).lifecycle == "live" }
                            if live {
                                let pin = try store.pinOriginalForInspection(id)
                                defer { pin.release() }
                                try pin.withVerifiedDescriptor { _ in try cancellation.check() }
                            }
                        }
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        // A revision change during a file read is incomplete coverage, not damage.
                        guard try store.read(epoch: epoch, { try SQLiteLibraryState.read(from: $0) }) == initial else {
                            return result(completed: false)
                        }
                        if let failure = error as? SQLiteLibraryError,
                           [.closed, .staleRoot, .databaseUnavailable, .unsupportedFormat, .unsupportedConfiguration].contains(failure) {
                            throw failure
                        }
                        try cancellation.check()
                        guard try store.rememberIntegrityFailure(target, state: initial, epoch: epoch) else { return result(completed: false) }
                        damaged.append(target)
                    }
                    checked += 1
                    try await progress(checked)
                    try cancellation.check()
                    await Task.yield()
                }
                after = keys[keys.count - 1]
            }
        }
        let unchanged = try store.read(epoch: epoch) { try SQLiteLibraryState.read(from: $0) == initial }
        return result(completed: unchanged)
    }

    private func validate(_ target: SQLiteIntegrityTarget, _ db: Database) throws {
        // Unlike strict backup's whole-library bounds, an oversized entity is local damage.
        let boundedExpression: String?
        switch target.kind {
        case .member: boundedExpression = "\(SQLiteReportRows.memberTextBytesSQL)"
        case .document: boundedExpression = "length(payload)"
        case .archiveReceipt: boundedExpression = "length(command)+length(intent)+length(outcome)"
        default: boundedExpression = nil
        }
        if let boundedExpression {
            let maximum = target.kind == .document ? 32 * 1_024 * 1_024 : LibraryStorageLimits.maximumEntityJSONBytes
            guard let length = try Int.fetchOne(db, sql: "SELECT \(boundedExpression) FROM \(target.kind.table) WHERE \(target.kind.key)=?", arguments: [target.key]), length <= maximum else { throw SQLiteLibraryError.damaged }
        }

        if target.kind == .archiveReceipt {
            guard let row = try SQLiteRows.fetchOne(db, sql: "SELECT * FROM inbox_archive_receipts WHERE command_hash=?", arguments: [target.key]) else { throw SQLiteLibraryError.damaged }
            let command = try CanonicalVaultJSON.decode(SQLiteLANArchiveCommand.self, from: row["command"])
            guard try SQLiteLANRows.archiveOutcome(command, db) != nil else { throw SQLiteLibraryError.damaged }
            return
        }
        guard let id = target.id else { throw SQLiteLibraryError.damaged }
        switch target.kind {
        case .member: _ = try SQLiteReportRows.member(id, db)
        case .report: _ = try SQLiteReportRows.record(id, db)
        case .draft: _ = try SQLiteReportRows.draft(id, db)
        case .document: try validateDocument(id, db)
        case .original:
            let value = try SQLiteOriginal.read(id, from: db)
            let references = try Int.fetchOne(db, sql: "SELECT (SELECT count(*) FROM report_sources WHERE original_id=?)+(SELECT count(*) FROM inbox_items WHERE original_id=?)+(SELECT count(*) FROM dicom_objects WHERE original_id=?)", arguments: [id.sqliteBytes, id.sqliteBytes, id.sqliteBytes])!
            guard (value.lifecycle == "live") == (references > 0) else { throw SQLiteLibraryError.damaged }
        case .inbox:
            let item = try SQLiteLANRows.item(id, db)
            if item.derivedArtifact != nil { _ = try SQLiteLANInboxStore.document(for: item, revision: item.revision, db) }
        case .terminal:
            guard let row = try SQLiteRows.fetchOne(db, sql: "SELECT * FROM inbox_content_terminals WHERE id=?", arguments: [target.key]) else { throw SQLiteLibraryError.damaged }
            _ = try SQLiteLANRows.terminal(row)
        case .receipt:
            guard let row = try SQLiteRows.fetchOne(db, sql: "SELECT * FROM inbox_transport_receipts WHERE id=?", arguments: [target.key]) else { throw SQLiteLibraryError.damaged }
            _ = try SQLiteLANRows.receipt(row, item: { try SQLiteLANRows.item($0, db) }, terminal: { try SQLiteLANRows.terminal(session: $0, content: $1, db) })
        case .study: _ = try SQLiteDICOMRows.strictStudy(id, db)
        case .upload: _ = try SQLiteLANUpload.read(id, db)
        case .archiveReceipt: break
        }
    }

    private func validateDocument(_ id: UUID, _ db: Database) throws {
        guard let kind = try String.fetchOne(db, sql: "SELECT kind FROM ocr_documents WHERE id=?", arguments: [id.sqliteBytes]) else { throw SQLiteLibraryError.damaged }
        let owners = try Int.fetchOne(db, sql: "SELECT (SELECT count(*) FROM reports WHERE document_id=?)+(SELECT count(*) FROM import_drafts WHERE document_id=?)+(SELECT count(*) FROM inbox_items WHERE derived_document_id=?)", arguments: [id.sqliteBytes, id.sqliteBytes, id.sqliteBytes])
        guard owners == 1 else { throw SQLiteLibraryError.damaged }
        if kind == "report" {
            guard let row = try Row.fetchOne(db, sql: "SELECT record_id AS owner_id,1 AS is_report,document_hash FROM reports WHERE document_id=? UNION ALL SELECT draft_id,0,document_hash FROM import_drafts WHERE document_id=?", arguments: [id.sqliteBytes, id.sqliteBytes]) else { throw SQLiteLibraryError.damaged }
            let sources = try SQLiteReportRows.sources(SQLiteReportRows.uuid(row, "owner_id"), report: row["is_report"] as Int == 1, db)
            _ = try SQLiteReportRows.document(id, sources: sources, expectedHash: row["document_hash"], db)
        } else {
            guard let owner = try Data.fetchOne(db, sql: "SELECT id FROM inbox_items WHERE derived_document_id=?", arguments: [id.sqliteBytes]), let itemID = UUID(sqliteBytes: owner) else { throw SQLiteLibraryError.damaged }
            let item = try SQLiteLANRows.item(itemID, db)
            _ = try SQLiteLANInboxStore.document(for: item, revision: item.revision, db)
        }
    }
}
