import Foundation
import GRDB
import Testing
@testable import KinlogueCore
@testable import KinloguePlatform

/// Saved member chats in the SQLite library: rows, limits, deletion, integrity and restore points.
@Suite(.serialized)
struct AssistantConversationStoreTests {
    @Test
    func aSavedConversationReadsBackWhole() async throws {
        let library = try AssistantTestLibrary()
        defer { library.close() }
        let member = try await library.member("Synthetic member")
        _ = try await library.confirmed(member, day: 1, results: "Glucose\t5.1")
        let pack = try await library.repository.assistantPack(memberID: member.id).pack
        let first = try conversation(member: member.id, pack: pack, questions: ["First question", "Second question"], at: 100)
        let second = try conversation(member: member.id, pack: pack, questions: ["Newer question"], at: 200)

        try await library.repository.saveAssistantConversation(first)
        try await library.repository.saveAssistantConversation(second)

        #expect(try await library.repository.assistantConversation(first.id) == first)
        let summaries = try await library.repository.assistantConversationSummaries(memberID: member.id)
        #expect(summaries.map(\.id) == [second.id, first.id], "newest first")
        #expect(summaries.last?.turnCount == 2)
        #expect(summaries.last?.firstQuestion == "First question")
        #expect(summaries.last?.provider == first.provider)
        #expect(try await library.repository.assistantConversation(UUID()) == nil)
    }

    @Test
    func savingAgainReplacesTheTurns() async throws {
        let library = try AssistantTestLibrary()
        defer { library.close() }
        let member = try await library.member("Synthetic member")
        _ = try await library.confirmed(member, day: 1, results: "Glucose\t5.1")
        let pack = try await library.repository.assistantPack(memberID: member.id).pack
        let one = try conversation(member: member.id, pack: pack, questions: ["One"], at: 100)
        try await library.repository.saveAssistantConversation(one)
        let two = try one.appending(AssistantTurn(ordinal: 1, question: "Two", answer: "Answer [R1]",
                                                  completedAt: Date(timeIntervalSince1970: 300), sources: pack.manifest))
        try await library.repository.saveAssistantConversation(two)

        #expect(try await library.repository.assistantConversation(one.id)?.turns.map(\.question) == ["One", "Two"])
        let counts = try library.store.read { db in
            (try Int.fetchOne(db, sql: "SELECT count(*) FROM assistant_turns")!,
             try Int.fetchOne(db, sql: "SELECT count(*) FROM assistant_turn_sources")!)
        }
        #expect(counts.0 == 2 && counts.1 == 2)
    }

    @Test
    func eachMemberKeepsAtMostTheLimitAndUnknownMembersAreRefused() async throws {
        let library = try AssistantTestLibrary()
        defer { library.close() }
        let member = try await library.member("Synthetic member")
        let provider = try AssistantProviderDescriptor(kind: .codex, cliVersion: "0.162.0", model: "gpt-synthetic")
        for index in 0..<AssistantLimits.maxConversationsPerMember {
            try await library.repository.saveAssistantConversation(
                AssistantConversation(memberID: member.id, createdAt: Date(timeIntervalSince1970: Double(index)), provider: provider, promptVersion: 1)
            )
        }
        await #expect(throws: LibraryReportError.resourceLimit) {
            try await library.repository.saveAssistantConversation(
                AssistantConversation(memberID: member.id, createdAt: Date(), provider: provider, promptVersion: 1)
            )
        }
        await #expect(throws: LibraryReportError.memberNotFound) {
            try await library.repository.saveAssistantConversation(
                AssistantConversation(memberID: UUID(), createdAt: Date(), provider: provider, promptVersion: 1)
            )
        }
    }

    @Test
    func conversationsAreDeletedOneByOneByMemberAndWithTheMember() async throws {
        let library = try AssistantTestLibrary()
        defer { library.close() }
        let member = try await library.member("Synthetic member")
        let other = try await library.member("Other synthetic member")
        let record = try await library.confirmed(member, day: 1, results: "Glucose\t5.1")
        let pack = try await library.repository.assistantPack(memberID: member.id).pack
        let kept = try conversation(member: member.id, pack: pack, questions: ["Kept"], at: 100)
        let removed = try conversation(member: member.id, pack: pack, questions: ["Removed"], at: 200)
        let others = try AssistantConversation(memberID: other.id, createdAt: Date(), provider: kept.provider, promptVersion: 1)
        for value in [kept, removed, others] { try await library.repository.saveAssistantConversation(value) }

        try await library.repository.deleteAssistantConversation(removed.id)
        #expect(try await library.repository.assistantConversationSummaries(memberID: member.id).map(\.id) == [kept.id])

        // A cited report can be deleted; the conversation still reads and the citation reads as deleted.
        try await library.repository.deleteRecord(record.id, expectedRevision: record.revision)
        let reread = try #require(try await library.repository.assistantConversation(kept.id))
        let states = try await library.repository.assistantRecordStates([record.id])
        #expect(reread.turns[0].sources[0].status(current: states[record.id]) == .deleted)

        // Deleting the member removes its conversations in the same transaction.
        try await library.repository.deleteMember(member.id)
        #expect(try await library.repository.assistantConversation(kept.id) == nil)
        #expect(try await library.repository.assistantConversationSummaries(memberID: other.id).count == 1)

        try await library.repository.deleteAllAssistantConversations()
        #expect(try await library.repository.assistantConversationSummaries(memberID: other.id).isEmpty)
    }

    @Test
    func aTamperedTurnIsDamageFoundByInspectionAndRefusedOnRead() async throws {
        let library = try AssistantTestLibrary()
        defer { library.close() }
        let member = try await library.member("Synthetic member")
        _ = try await library.confirmed(member, day: 1, results: "Glucose\t5.1")
        let pack = try await library.repository.assistantPack(memberID: member.id).pack
        let value = try conversation(member: member.id, pack: pack, questions: ["Question"], at: 100)
        try await library.repository.saveAssistantConversation(value)

        try library.store.write { db in
            try db.execute(sql: "UPDATE assistant_turns SET answer = 'Edited outside the App'")
        }
        let report = try await SQLiteLibraryIntegrityScrubber(store: library.store).run()
        #expect(report.damagedTargets.map(\.kind) == [.conversation])
        #expect(report.damagedTargets.first?.id == value.id)
        await #expect(throws: SQLiteLibraryError.damaged) { _ = try await library.repository.assistantConversation(value.id) }
    }

    @Test
    func restorePointsCarryConversations() async throws {
        let library = try AssistantTestLibrary()
        defer { library.close() }
        let member = try await library.member("Synthetic member")
        _ = try await library.confirmed(member, day: 1, results: "Glucose\t5.1")
        let pack = try await library.repository.assistantPack(memberID: member.id).pack
        let value = try conversation(member: member.id, pack: pack, questions: ["Question one", "Question two"], at: 100)
        try await library.repository.saveAssistantConversation(value)

        let snapshot = try await SQLiteLogicalBackupSource(store: library.store).prepare()
        defer { snapshot.release() }
        #expect(snapshot.header.version == 2)
        let records = try snapshot.logicalRecordsForTesting()
        let saved = try #require(records.first { $0.kind == .assistantConversation })
        #expect(try saved.decode(AssistantConversation.self) == value)
        #expect(records.last?.kind == .assistantConversation, "conversations come after every other record")

        let restoredRoot = try sqliteTestRoot()
        defer { try? FileManager.default.removeItem(at: restoredRoot.deletingLastPathComponent()) }
        let restoredStore = try SQLiteLibraryStore(rootURL: restoredRoot)
        defer { try? restoredStore.close() }
        _ = try restoreSnapshot(snapshot, into: restoredStore)
        let restored = SQLiteReportRepository(store: restoredStore)
        #expect(try await restored.assistantConversation(value.id) == value)
    }

    @Test
    func aVersionOneStreamCannotCarryConversations() throws {
        let header = try BackupLogicalHeaderV1(version: 1, libraryID: UUID(), generation: 1, commitID: UUID())
        var bytes = Data()
        let writer = try SQLiteLogicalStream.Writer(header: header) { bytes.append($0) }
        let record = SQLiteLogicalRecord(kind: .assistantConversation, id: UUID(), payload: Data("{}".utf8))
        #expect(throws: SQLiteLogicalBackupError.invalidStream) { try writer.append(record) }
    }
}

private func conversation(member: UUID, pack: AssistantContextPack, questions: [String], at seconds: Double) throws -> AssistantConversation {
    let provider = try AssistantProviderDescriptor(kind: .codex, cliVersion: "0.162.0", model: "gpt-synthetic")
    var value = try AssistantConversation(memberID: member, createdAt: Date(timeIntervalSince1970: seconds), provider: provider, promptVersion: 1)
    for (index, question) in questions.enumerated() {
        value = try value.appending(AssistantTurn(
            ordinal: index, question: question, answer: "Synthetic answer \(index) [R1]",
            completedAt: Date(timeIntervalSince1970: seconds + Double(index + 1)), sources: pack.manifest
        ))
    }
    return value
}

/// Restores a captured snapshot into an empty store the way an encrypted restore point would.
private func restoreSnapshot(_ snapshot: SQLiteLogicalBackupSnapshot, into store: SQLiteLibraryStore) throws -> SQLiteLogicalValidation {
    let stream = try snapshot.spool.read(offset: 0, count: snapshot.spool.byteCount)
    let spool = try SQLiteLogicalSpool(parent: store.rootURL.deletingLastPathComponent())
    defer { spool.release() }
    try spool.append(stream); try spool.seal()
    var entries: [BackupManifestEntry] = []
    var frame: UInt64 = 0
    func entry(_ kind: BackupManifestEntry.Kind, _ path: String, _ data: Data) throws {
        let count = try BackupManifestEntry.requiredFrameCount(for: UInt64(data.count))
        entries.append(try BackupManifestEntry(kind: kind, path: path, plaintextByteCount: UInt64(data.count),
            plaintextDigest: ContentDigest.sha256(data), firstFrameIndex: frame, frameCount: count))
        frame += UInt64(count)
    }
    try entry(.logicalSegment, "logical/00000000.data", stream)
    for original in snapshot.pins.originals.values.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
        let reader = try snapshot.pins.open(original.id)
        let bytes = try reader.read(offset: 0, maximumByteCount: original.byteCount)
        reader.close()
        let path = "originals/\(original.id.uuidString.lowercased()).data"
        let url = store.rootURL.appendingPathComponent(path)
        try bytes.write(to: url, options: .withoutOverwriting)
        #expect(chmod(url.path, 0o600) == 0)
        try entry(.original, path, bytes)
    }
    return try SQLiteLogicalRestore.restore(spool: spool,
        manifest: BackupManifest(revisionPair: SQLiteLogicalBackupSource.revision(snapshot.header), entries: entries), store: store)
}
