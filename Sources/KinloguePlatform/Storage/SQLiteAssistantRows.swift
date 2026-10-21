import Foundation
import GRDB
import KinlogueCore

/// Saved member chats: a conversation row, its turns, and each turn's send manifest. Every row
/// carries a content hash; a conversation reads back only whole and only when every hash matches.
enum SQLiteAssistantRows {
    static let conversationColumns = [
        "id", "member_id", "created_at", "updated_at", "provider_kind", "cli_version", "model", "prompt_version",
        "turn_count", "first_question",
    ]
    static let turnColumns = ["id", "conversation_id", "ordinal", "question", "answer", "completed_at"]
    static let sourceColumns = ["turn_id", "position", "label", "record_id", "record_revision", "projection_digest"]

    /// Replaces the conversation's rows. Its member must exist, and a member keeps at most
    /// `AssistantLimits.maxConversationsPerMember` conversations.
    static func save(_ conversation: AssistantConversation, _ db: Database) throws {
        let member = conversation.memberID.sqliteBytes
        guard try Row.fetchOne(db, sql: "SELECT 1 FROM members WHERE id = ?", arguments: [member]) != nil else {
            throw LibraryReportError.memberNotFound
        }
        if let owner = try Data.fetchOne(db, sql: "SELECT member_id FROM assistant_conversations WHERE id = ?",
                                         arguments: [conversation.id.sqliteBytes]) {
            guard owner == member else { throw LibraryReportError.invalidDocument }
        } else {
            guard try Int.fetchOne(db, sql: "SELECT count(*) FROM assistant_conversations WHERE member_id = ?",
                                   arguments: [member])! < AssistantLimits.maxConversationsPerMember else {
                throw LibraryReportError.resourceLimit
            }
        }
        let firstQuestion = conversation.turns.first.map { String($0.question.prefix(AssistantConversationSummary.firstQuestionCharacters)) }
        try SQLiteReportRows.put(db, table: "assistant_conversations", columns: conversationColumns, values: [
            conversation.id.sqliteBytes.databaseValue, member.databaseValue,
            conversation.createdAt.timeIntervalSince1970.databaseValue, conversation.updatedAt.timeIntervalSince1970.databaseValue,
            conversation.provider.kind.rawValue.databaseValue, conversation.provider.cliVersion.databaseValue,
            conversation.provider.model.databaseValue, Int64(conversation.promptVersion).databaseValue,
            Int64(conversation.turns.count).databaseValue, firstQuestion.databaseValue,
        ])
        try deleteTurns(of: conversation.id, db)
        for turn in conversation.turns {
            try insert(db, table: "assistant_turns", columns: turnColumns, values: [
                turn.id.sqliteBytes.databaseValue, conversation.id.sqliteBytes.databaseValue, Int64(turn.ordinal).databaseValue,
                turn.question.databaseValue, turn.answer.databaseValue, turn.completedAt.timeIntervalSince1970.databaseValue,
            ])
            for (position, source) in turn.sources.enumerated() {
                guard source.recordRevision <= UInt64(Int64.max) else { throw LibraryReportError.resourceLimit }
                try insert(db, table: "assistant_turn_sources", columns: sourceColumns, values: [
                    turn.id.sqliteBytes.databaseValue, Int64(position).databaseValue, source.label.databaseValue,
                    source.recordID.sqliteBytes.databaseValue, Int64(source.recordRevision).databaseValue,
                    source.projectionDigest.databaseValue,
                ])
            }
        }
    }

    /// The whole conversation, or nil when there is none; damage throws.
    static func conversation(_ id: UUID, _ db: Database) throws -> AssistantConversation? {
        guard let row = try SQLiteRows.fetchOne(db, sql: "SELECT * FROM assistant_conversations WHERE id = ?",
                                                arguments: [id.sqliteBytes]) else { return nil }
        try SQLiteReportRows.verify(row, table: "assistant_conversations", columns: conversationColumns)
        let turnRows = try SQLiteRows.fetchAll(db, sql: "SELECT * FROM assistant_turns WHERE conversation_id = ? ORDER BY ordinal",
                                               arguments: [id.sqliteBytes])
        guard turnRows.count == row["turn_count"] as Int else { throw SQLiteLibraryError.damaged }
        var turns: [AssistantTurn] = []
        for turnRow in turnRows {
            try SQLiteReportRows.verify(turnRow, table: "assistant_turns", columns: turnColumns)
            let turnID = try SQLiteReportRows.uuid(turnRow, "id")
            let sourceRows = try SQLiteRows.fetchAll(db, sql: "SELECT * FROM assistant_turn_sources WHERE turn_id = ? ORDER BY position",
                                                     arguments: [turnID.sqliteBytes])
            let sources = try sourceRows.enumerated().map { position, source -> AssistantTurnSource in
                try SQLiteReportRows.verify(source, table: "assistant_turn_sources", columns: sourceColumns)
                let revision: Int64 = source["record_revision"]
                guard source["position"] as Int == position, revision >= 0 else { throw SQLiteLibraryError.damaged }
                return try AssistantTurnSource(label: source["label"], recordID: SQLiteReportRows.uuid(source, "record_id"),
                                               recordRevision: UInt64(revision), projectionDigest: source["projection_digest"])
            }
            turns.append(try AssistantTurn(id: turnID, ordinal: turnRow["ordinal"], question: turnRow["question"],
                                           answer: turnRow["answer"], completedAt: Date(timeIntervalSince1970: turnRow["completed_at"]),
                                           sources: sources))
        }
        guard let kind = AssistantProviderKind(rawValue: row["provider_kind"]) else { throw SQLiteLibraryError.damaged }
        let value = try AssistantConversation(
            id: SQLiteReportRows.uuid(row, "id"), memberID: SQLiteReportRows.uuid(row, "member_id"),
            createdAt: Date(timeIntervalSince1970: row["created_at"]), updatedAt: Date(timeIntervalSince1970: row["updated_at"]),
            provider: AssistantProviderDescriptor(kind: kind, cliVersion: row["cli_version"], model: row["model"]),
            promptVersion: row["prompt_version"], turns: turns
        )
        guard row["first_question"] as String? == turns.first.map({ String($0.question.prefix(AssistantConversationSummary.firstQuestionCharacters)) }) else {
            throw SQLiteLibraryError.damaged
        }
        return value
    }

    /// One member's conversations, newest first, from the conversation rows alone.
    static func summaries(memberID: UUID, _ db: Database) throws -> [AssistantConversationSummary] {
        let rows = try SQLiteRows.fetchAll(db, sql: """
            SELECT * FROM assistant_conversations WHERE member_id = ? ORDER BY updated_at DESC, id DESC LIMIT ?
            """, arguments: [memberID.sqliteBytes, AssistantLimits.maxConversationsPerMember])
        return try rows.map { row in
            try SQLiteReportRows.verify(row, table: "assistant_conversations", columns: conversationColumns)
            guard let kind = AssistantProviderKind(rawValue: row["provider_kind"]) else { throw SQLiteLibraryError.damaged }
            return AssistantConversationSummary(
                id: try SQLiteReportRows.uuid(row, "id"), memberID: memberID,
                createdAt: Date(timeIntervalSince1970: row["created_at"]), updatedAt: Date(timeIntervalSince1970: row["updated_at"]),
                provider: try AssistantProviderDescriptor(kind: kind, cliVersion: row["cli_version"], model: row["model"]),
                turnCount: row["turn_count"], firstQuestion: row["first_question"]
            )
        }
    }

    static func delete(_ id: UUID, _ db: Database) throws {
        try deleteTurns(of: id, db)
        try db.execute(sql: "DELETE FROM assistant_conversations WHERE id = ?", arguments: [id.sqliteBytes])
    }

    static func deleteAll(memberID: UUID, _ db: Database) throws {
        let ids = try Data.fetchAll(db, sql: "SELECT id FROM assistant_conversations WHERE member_id = ?", arguments: [memberID.sqliteBytes])
        for data in ids {
            guard let id = UUID(sqliteBytes: data) else { throw SQLiteLibraryError.damaged }
            try delete(id, db)
        }
    }

    static func deleteAll(_ db: Database) throws {
        try db.execute(sql: "DELETE FROM assistant_turn_sources")
        try db.execute(sql: "DELETE FROM assistant_turns")
        try db.execute(sql: "DELETE FROM assistant_conversations")
    }

    private static func deleteTurns(of conversation: UUID, _ db: Database) throws {
        try db.execute(sql: "DELETE FROM assistant_turn_sources WHERE turn_id IN (SELECT id FROM assistant_turns WHERE conversation_id = ?)",
                       arguments: [conversation.sqliteBytes])
        try db.execute(sql: "DELETE FROM assistant_turns WHERE conversation_id = ?", arguments: [conversation.sqliteBytes])
    }

    private static func insert(_ db: Database, table: String, columns: [String], values: [DatabaseValue]) throws {
        let stored = values + [try SQLiteReportRows.hash(table: table, values: values).databaseValue]
        try db.execute(sql: "INSERT INTO \(table)(\((columns + ["content_hash"]).joined(separator: ","))) VALUES (\(SQLiteRows.placeholders(stored)))",
                       arguments: SQLiteRows.arguments(stored))
    }
}
