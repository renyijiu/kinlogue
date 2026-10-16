import Foundation
import GRDB
import KinlogueCore

/// A pack as loaded from the library, with the reports that could not be read.
package struct AssistantPackLoad: Sendable {
    package let pack: AssistantContextPack
    /// Confirmed reports of the member that failed verification and were left out.
    package let damagedRecordIDs: [UUID]
}

extension SQLiteReportRepository {
    /// One member's confirmed reports for an assistant pack, read in one transaction: the newest
    /// reports a pack can hold, or exactly the selected ones, and the member's total. Digests use
    /// the Platform's SHA-256.
    @concurrent
    package nonisolated func assistantPack(
        memberID: UUID,
        selection: AssistantPackSelection = .automatic,
        includeOrganization: Bool = false
    ) async throws -> AssistantPackLoad {
        try await LibraryStorageExecutor.run {
            if case let .explicit(ids) = selection, ids.count > AssistantLimits.maxPackRecords {
                throw AssistantPackError.selectionTooLarge
            }
            let (member, records, damaged, total) = try store.read { db in
                let member = try usableMember(memberID, db)
                let total = try Int.fetchOne(
                    db, sql: "SELECT count(*) FROM reports WHERE member_id = ?", arguments: [memberID.sqliteBytes]
                ) ?? 0
                let ids: [UUID]
                switch selection {
                case .automatic:
                    ids = try SQLiteRows.fetchAll(
                        db, sql: "SELECT record_id FROM reports WHERE member_id = ? ORDER BY timeline_date DESC, record_id LIMIT ?",
                        arguments: [memberID.sqliteBytes, AssistantLimits.maxPackRecords]
                    ).map { try SQLiteReportRows.uuid($0, "record_id") }
                case let .explicit(selected):
                    ids = selected
                }
                var records: [HealthRecord] = [], damaged: [UUID] = []
                for id in ids {
                    do {
                        records.append(try usableRecord(id, db))
                    } catch {
                        // A selected report that cannot be read is simply unavailable to the builder.
                        if selection == .automatic { damaged.append(id) }
                    }
                }
                return (member, records, damaged, total)
            }
            let pack = try AssistantContextPackBuilder.build(
                member: member, records: records, selection: selection, includeOrganization: includeOrganization,
                confirmedRecordCount: total, digest: ContentDigest.sha256
            )
            return AssistantPackLoad(pack: pack, damagedRecordIDs: damaged)
        }
    }

    /// What each record says now, for the citation status of earlier answers. A report that is
    /// gone or cannot be read is absent.
    @concurrent
    package nonisolated func assistantRecordStates(_ ids: [UUID]) async throws -> [UUID: AssistantRecordState] {
        try await LibraryStorageExecutor.run {
            let unique = Array(Set(ids))
            guard unique.count <= AssistantLimits.maxPackRecords * AssistantLimits.maxTurnsPerConversation else {
                throw LibraryReportError.resourceLimit
            }
            let records = try store.read { db in unique.compactMap { try? usableRecord($0, db) } }
            var states: [UUID: AssistantRecordState] = [:]
            for record in records {
                states[record.id] = AssistantRecordState(
                    revision: record.revision,
                    projectionDigest: try AssistantContextPackBuilder.projectionDigest(of: record, digest: ContentDigest.sha256)
                )
            }
            return states
        }
    }
}

extension SQLiteReportRepository {
    /// A saved conversation, or nil when there is none.
    @concurrent
    package nonisolated func assistantConversation(_ id: UUID) async throws -> AssistantConversation? {
        try await LibraryStorageExecutor.run {
            try store.read { db in
                try store.requireUnquarantined(.conversation, id)
                return try SQLiteAssistantRows.conversation(id, db)
            }
        }
    }

    /// One member's saved conversations, newest first, without their turns.
    @concurrent
    package nonisolated func assistantConversationSummaries(memberID: UUID) async throws -> [AssistantConversationSummary] {
        try await LibraryStorageExecutor.run {
            try store.read { db in
                let quarantined = store.quarantinedIDs(.conversation)
                return try SQLiteAssistantRows.summaries(memberID: memberID, db).filter { !quarantined.contains($0.id) }
            }
        }
    }

    /// Saves the whole conversation, replacing what was saved for it before.
    @concurrent
    package nonisolated func saveAssistantConversation(_ conversation: AssistantConversation) async throws {
        try await LibraryStorageExecutor.run {
            try store.write { db in
                try SQLiteAssistantRows.save(conversation, db)
                try SQLiteLibraryState.advance(in: db)
            }
        }
    }

    @concurrent
    package nonisolated func deleteAssistantConversation(_ id: UUID) async throws {
        try await LibraryStorageExecutor.run {
            try store.write { db in
                try SQLiteAssistantRows.delete(id, db)
                try SQLiteLibraryState.advance(in: db)
            }
        }
    }

    @concurrent
    package nonisolated func deleteAssistantConversations(memberID: UUID) async throws {
        try await LibraryStorageExecutor.run {
            try store.write { db in
                try SQLiteAssistantRows.deleteAll(memberID: memberID, db)
                try SQLiteLibraryState.advance(in: db)
            }
        }
    }

    @concurrent
    package nonisolated func deleteAllAssistantConversations() async throws {
        try await LibraryStorageExecutor.run {
            try store.write { db in
                try SQLiteAssistantRows.deleteAll(db)
                try SQLiteLibraryState.advance(in: db)
            }
        }
    }
}
