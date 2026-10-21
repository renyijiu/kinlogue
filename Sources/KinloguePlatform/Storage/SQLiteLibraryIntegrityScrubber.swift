import Foundation
import GRDB
import KinlogueCore

package struct SQLiteIntegrityTarget: Hashable, Sendable {
    package enum Kind: String, CaseIterable, Sendable {
        case member, report, draft, document, original, inbox, terminal, receipt, archiveReceipt, study, upload, conversation
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
            case .conversation: "assistant_conversations"
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
///
/// A pass that is interrupted without a commit continues where it stopped, and a pass that
/// already completed for the current revision is reported again without rereading anything; see
/// `SQLiteIntegrityProgress` for what is carried over and why.
package struct SQLiteLibraryIntegrityScrubber: Sendable {
    let store: SQLiteLibraryStore
    package init(store: SQLiteLibraryStore) { self.store = store }

    @concurrent package func run(
        progress: @escaping @Sendable (Int) async throws -> Void = { _ in }
    ) async throws -> SQLiteIntegrityReport {
        try await LibraryStorageExecutor.run {
            let cancellation = SQLiteLogicalCancellation()
            return try await withTaskCancellationHandler {
                try await inspect(cancellation: cancellation, progress: progress)
            } onCancel: { cancellation.cancel() }
        }
    }

    /// Changes when any other connection commits, which the library state alone would not show.
    private static func dataVersion(_ db: Database) throws -> Int64 {
        guard let version = try Int64.fetchOne(db, sql: "PRAGMA data_version") else { throw SQLiteLibraryError.damaged }
        return version
    }

    private enum Step { case checked, damaged, stale }

    /// The revision one pass is bound to, and the checks that hold only while it is current.
    private struct Pass {
        let scrubber: SQLiteLibraryIntegrityScrubber
        let epoch: UUID
        let initial: SQLiteLibraryState
        let dataVersion: Int64
        let cancellation: SQLiteLogicalCancellation
        var store: SQLiteLibraryStore { scrubber.store }

        func unchanged(_ db: Database) throws -> Bool {
            try SQLiteLibraryState.read(from: db) == initial && SQLiteLibraryIntegrityScrubber.dataVersion(db) == dataVersion
        }

        /// The next keys of one kind, or nil when the revision is no longer the one inspected.
        func keys(_ kind: SQLiteIntegrityTarget.Kind, after: Data) throws -> [Data]? {
            try store.read(epoch: epoch) { db in
                guard try unchanged(db) else { return nil }
                return try Data.fetchAll(db, sql: "SELECT \(kind.key) FROM \(kind.table) WHERE \(kind.key)>? ORDER BY \(kind.key) LIMIT 16", arguments: [after])
            }
        }

        /// Checks one target. `rows` is false when its rows were already checked at this revision
        /// and only the file of an original is looked at again.
        func check(_ target: SQLiteIntegrityTarget, rows: Bool) throws -> Step {
            do {
                return try verify(target, rows: rows) ? .checked : .stale
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A revision change during a file read is incomplete coverage, not damage.
                guard try store.read(epoch: epoch, unchanged) else { return .stale }
                if let failure = error as? SQLiteLibraryError,
                   [.closed, .staleRoot, .databaseUnavailable, .unsupportedFormat, .unsupportedConfiguration].contains(failure) {
                    throw failure
                }
                try cancellation.check()
                guard try store.rememberIntegrityFailure(target, state: initial, epoch: epoch) else { return .stale }
                return .damaged
            }
        }

        /// False when the revision changed before the target could be checked.
        private func verify(_ target: SQLiteIntegrityTarget, rows: Bool) throws -> Bool {
            if rows {
                let current = try store.read(epoch: epoch) { db in
                    guard try unchanged(db) else { return false }
                    try SQLiteReadProgress.withGuard(db, check: cancellation.check) { try scrubber.validate(target, db) }
                    return true
                }
                guard current else { return false }
            }
            guard target.kind == .original, let id = target.id else { return true }
            let live: Bool? = try store.read(epoch: epoch) { db in
                try unchanged(db) ? try SQLiteOriginal.read(id, from: db).lifecycle == "live" : nil
            }
            guard let live else { return false }
            guard live else { return true }
            let pin = try store.pinOriginalForInspection(id)
            defer { pin.release() }
            try pin.verifyForInspection()
            try cancellation.check()
            return true
        }
    }

    private func inspect(cancellation: SQLiteLogicalCancellation,
                         progress: @escaping @Sendable (Int) async throws -> Void) async throws -> SQLiteIntegrityReport {
        let record = store.integrityProgress
        let (opened, epoch) = try store.readWithEpoch { db in
            try SQLiteReadProgress.withGuard(db, check: cancellation.check) {
                let state = try SQLiteLibraryState.read(from: db)
                var position = record.position(state: state, dataVersion: try Self.dataVersion(db))
                if !position.structureChecked {
                    try SQLiteLibrarySchema.validate(in: db)
                    guard try Int.fetchOne(db, sql: "SELECT count(*) FROM ocr_documents")! <= 45_000,
                          try Int.fetchOne(db, sql: "SELECT count(*) FROM inbox_archive_receipts")! <= 5_000 else { throw SQLiteLibraryError.damaged }
                    guard try String.fetchAll(db, sql: "PRAGMA integrity_check") == ["ok"],
                          try Row.fetchOne(db, sql: "PRAGMA foreign_key_check") == nil else { throw SQLiteLibraryError.damaged }
                    position.structureChecked = true
                }
                return position
            }
        }
        var position = opened
        record.save(position)
        let pass = Pass(scrubber: self, epoch: epoch, initial: position.state, dataVersion: position.dataVersion, cancellation: cancellation)
        let revision = LibraryRevision(libraryID: pass.initial.libraryID, openEpoch: epoch,
            generation: UInt64(pass.initial.generation), commitID: pass.initial.commitID)
        func result(completed: Bool) -> SQLiteIntegrityReport {
            SQLiteIntegrityReport(revision: revision, completed: completed, checkedCount: position.checked,
                checkedAt: position.completedAt ?? Date(), damagedTargets: position.damaged)
        }
        try await progress(position.checked)
        if position.completedAt != nil {
            // The rows are the ones already checked. Files can change without a commit, so every
            // original is looked at again; only one whose identity changed is read.
            var after = Data()
            while true {
                try cancellation.check()
                guard let batch = try pass.keys(.original, after: after) else { return result(completed: false) }
                guard let last = batch.last else { break }
                for key in batch {
                    let target = SQLiteIntegrityTarget(kind: .original, key: key)
                    switch try pass.check(target, rows: false) {
                    case .stale: return result(completed: false)
                    case .damaged: if !position.damaged.contains(target) { position.damaged.append(target); record.save(position) }
                    case .checked: break
                    }
                    try cancellation.check()
                    await Task.yield()
                }
                after = last
            }
            return result(completed: true)
        }
        let kinds = SQLiteIntegrityTarget.Kind.allCases
        while position.kindIndex < kinds.count {
            let kind = kinds[position.kindIndex]
            while true {
                try cancellation.check()
                guard let batch = try pass.keys(kind, after: position.after) else { return result(completed: false) }
                guard !batch.isEmpty else { break }
                for key in batch {
                    let target = SQLiteIntegrityTarget(kind: kind, key: key)
                    switch try pass.check(target, rows: true) {
                    case .stale: return result(completed: false)
                    case .damaged: position.damaged.append(target)
                    case .checked: break
                    }
                    position.checked += 1
                    position.after = key
                    record.save(position)
                    try await progress(position.checked)
                    try cancellation.check()
                    await Task.yield()
                }
            }
            position.kindIndex += 1
            position.after = Data()
            record.save(position)
        }
        let present: Set<UUID>? = try store.read(epoch: epoch) { db in
            guard try pass.unchanged(db) else { return nil }
            return Set(try Data.fetchAll(db, sql: "SELECT id FROM originals").compactMap { UUID(sqliteBytes: $0) })
        }
        guard let present else { return result(completed: false) }
        record.retainOriginals(present)
        position.completedAt = Date()
        record.save(position)
        return result(completed: true)
    }

    fileprivate func validate(_ target: SQLiteIntegrityTarget, _ db: Database) throws {
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
        case .conversation: guard try SQLiteAssistantRows.conversation(id, db) != nil else { throw SQLiteLibraryError.damaged }
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
