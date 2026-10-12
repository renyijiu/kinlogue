import Foundation
import GRDB
import KinlogueCore

// SAFETY: the lock protects one content-free cumulative byte counter.
package final class SQLiteOriginalReadMetrics: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: UInt64 = 0
    package var verifiedReadByteCount: UInt64 { lock.withLock { bytes } }
    func add(_ count: Int) { lock.withLock { bytes += UInt64(count) } }
}

extension SQLiteLibraryStore {
    func noteOriginalIntegrityFailure(_ original: SQLiteOriginal, epoch: UUID) {
        guard !Task.isCancelled else { return }
        _ = try? read(epoch: epoch) { db in try noteOriginalIntegrityFailureLocked(original, db) }
    }

    /// Caller holds admission; unrelated commits do not discard verified physical damage.
    func noteOriginalIntegrityFailureLocked(_ original: SQLiteOriginal, _ db: Database) throws {
        guard try SQLiteOriginal.read(original.id, from: db).contentHash == original.contentHash else { return }
        try rememberIntegrityFailureLocked(SQLiteIntegrityTarget(kind: .original, key: original.id.sqliteBytes), db)
    }

    /// Caller holds database admission. This is transient evidence for the current open epoch.
    func quarantinedIDs(_ kind: SQLiteIntegrityTarget.Kind) -> Set<UUID> {
        Set(quarantinedTargets.filter { $0.kind == kind }.compactMap(\.id))
    }

    func requireUnquarantined(_ kind: SQLiteIntegrityTarget.Kind, _ id: UUID) throws {
        guard !quarantinedTargets.contains(SQLiteIntegrityTarget(kind: kind, key: id.sqliteBytes)) else { throw SQLiteLibraryError.damaged }
    }

    func rememberIntegrityFailure(_ target: SQLiteIntegrityTarget, state: SQLiteLibraryState, epoch: UUID) throws -> Bool {
        try read(epoch: epoch) { db in
            guard try SQLiteLibraryState.read(from: db) == state else { return false }
            try rememberIntegrityFailureLocked(target, db)
            return true
        }
    }

    private func rememberIntegrityFailureLocked(_ target: SQLiteIntegrityTarget, _ db: Database) throws {
        var targets: Set<SQLiteIntegrityTarget> = [target]
        func append(_ kind: SQLiteIntegrityTarget.Kind, sql: String) throws {
            for key in try Data.fetchAll(db, sql: sql, arguments: [target.key]) {
                targets.insert(SQLiteIntegrityTarget(kind: kind, key: key))
            }
        }
        if target.kind == .original {
            try append(.report, sql: "SELECT report_id FROM report_sources WHERE original_id=? AND report_id IS NOT NULL")
            try append(.draft, sql: "SELECT draft_id FROM report_sources WHERE original_id=? AND draft_id IS NOT NULL")
            try append(.inbox, sql: "SELECT id FROM inbox_items WHERE original_id=?")
            try append(.study, sql: "SELECT DISTINCT study_id FROM dicom_objects WHERE original_id=?")
        } else if target.kind == .document {
            try append(.report, sql: "SELECT record_id FROM reports WHERE document_id=?")
            try append(.draft, sql: "SELECT draft_id FROM import_drafts WHERE document_id=?")
            try append(.inbox, sql: "SELECT id FROM inbox_items WHERE derived_document_id=?")
        }
        quarantinedTargets.formUnion(targets)
    }

}

extension SQLiteReportRepository {
    nonisolated func usableMember(_ id: UUID, _ db: Database) throws -> FamilyMember {
        try store.requireUnquarantined(.member, id)
        return try SQLiteReportRows.member(id, db)
    }
    nonisolated func usableRecord(_ id: UUID, _ db: Database) throws -> HealthRecord {
        try store.requireUnquarantined(.report, id)
        return try SQLiteReportRows.record(id, db)
    }
    nonisolated func usableDraft(_ id: UUID, _ db: Database) throws -> ImportDraft {
        try store.requireUnquarantined(.draft, id)
        return try SQLiteReportRows.draft(id, db)
    }
}

extension SQLiteLANInboxStore {
    func usableItem(_ id: UUID, _ db: Database) throws -> LANInboxItem {
        try store.requireUnquarantined(.inbox, id)
        return try SQLiteLANRows.item(id, db)
    }
}
