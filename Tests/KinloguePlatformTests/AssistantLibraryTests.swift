import Foundation
import GRDB
import Testing
@testable import KinlogueCore
@testable import KinloguePlatform

/// The assistant's view of the SQLite library: one member's confirmed reports, read in one
/// transaction and digested with the Platform's SHA-256.
struct AssistantLibraryTests {
    @Test
    func packsIndexEveryConfirmedReportOfOneMember() async throws {
        let library = try AssistantTestLibrary()
        defer { library.close() }
        let member = try await library.member("Synthetic member")
        let other = try await library.member("Other synthetic member")
        var records: [HealthRecord] = []
        for day in 1...23 {
            records.append(try await library.confirmed(member, day: day, results: "Glucose\t5.\(day % 10)"))
        }
        let foreign = try await library.confirmed(other, day: 30, results: "Foreign result")

        let load = try await library.repository.assistantPack(memberID: member.id)

        #expect(load.pack.entries.map(\.recordID) == records.map(\.id))
        #expect(load.pack.omittedRecordCount == 0)
        #expect(load.pack.resultItemCount == 1, "every report's Glucose row is in one group")
        #expect(load.damagedRecordIDs.isEmpty)
        #expect(!load.pack.renderedRecords().contains("Foreign result"))
        #expect(!load.pack.entries.contains { $0.recordID == foreign.id })
        let expected = try AssistantContextPackBuilder.projectionDigest(of: records[22], digest: ContentDigest.sha256)
        #expect(load.pack.entries.last?.projectionDigest == expected)
    }

    /// The query reads the newest reports up to the index cap and counts the rest.
    @Test
    func packsStopAtTheIndexCapAndCountTheRest() async throws {
        let library = try AssistantTestLibrary()
        defer { library.close() }
        let member = try await library.member("Synthetic member")
        var records: [HealthRecord] = []
        for day in 1...(AssistantLimits.maxPackRecords + 2) {
            records.append(try await library.confirmed(member, day: day, results: "V\(day)"))
        }

        let load = try await library.repository.assistantPack(memberID: member.id)

        #expect(load.pack.entries.count == AssistantLimits.maxPackRecords)
        #expect(load.pack.entries.first?.recordID == records[2].id)
        #expect(load.pack.omittedRecordCount == 2)
        #expect(load.pack.byteCount <= AssistantLimits.maxPackBytes)
    }

    @Test
    func damagedReportsAreLeftOutAndNamed() async throws {
        let library = try AssistantTestLibrary()
        defer { library.close() }
        let member = try await library.member("Synthetic member")
        let kept = try await library.confirmed(member, day: 1, results: "Kept")
        let broken = try await library.confirmed(member, day: 2, results: "Broken")
        try library.store.write { db in
            try db.execute(sql: "UPDATE report_details SET payload = ? WHERE record_id = ?",
                           arguments: [Data("broken".utf8), broken.id.sqliteBytes])
        }

        let load = try await library.repository.assistantPack(memberID: member.id)

        #expect(load.pack.entries.map(\.recordID) == [kept.id])
        #expect(load.damagedRecordIDs == [broken.id])
    }

    @Test
    func explicitSelectionsMustNameThisMembersConfirmedReports() async throws {
        let library = try AssistantTestLibrary()
        defer { library.close() }
        let member = try await library.member("Synthetic member")
        let other = try await library.member("Other synthetic member")
        let first = try await library.confirmed(member, day: 1, results: "First")
        let second = try await library.confirmed(member, day: 2, results: "Second")
        _ = try await library.confirmed(member, day: 3, results: "Third")
        let foreign = try await library.confirmed(other, day: 4, results: "Foreign")

        let load = try await library.repository.assistantPack(memberID: member.id, selection: .explicit([second.id, first.id]))
        #expect(load.pack.entries.map(\.recordID) == [first.id, second.id])
        #expect(load.pack.omittedRecordCount == 1)

        for unavailable in [foreign.id, UUID()] {
            await #expect(throws: AssistantPackError.recordUnavailable) {
                _ = try await library.repository.assistantPack(memberID: member.id, selection: .explicit([first.id, unavailable]))
            }
        }
        await #expect(throws: AssistantPackError.selectionTooLarge) {
            _ = try await library.repository.assistantPack(
                memberID: member.id, selection: .explicit((0...AssistantLimits.maxPackRecords).map { _ in UUID() })
            )
        }
    }

    @Test
    func archivedMissingAndEmptyMembersGetNoPack() async throws {
        let library = try AssistantTestLibrary()
        defer { library.close() }
        let member = try await library.member("Synthetic member")
        await #expect(throws: AssistantPackError.noConfirmedRecords) {
            _ = try await library.repository.assistantPack(memberID: member.id)
        }
        _ = try await library.confirmed(member, day: 1, results: "Value")
        var archived = member
        archived.isArchived = true
        try await library.repository.saveMember(archived, replacing: member)
        await #expect(throws: AssistantPackError.memberArchived) {
            _ = try await library.repository.assistantPack(memberID: member.id)
        }
        await #expect(throws: (any Error).self) {
            _ = try await library.repository.assistantPack(memberID: UUID())
        }
    }

    @Test
    func recordStatesFollowEditsNotesAndDeletions() async throws {
        let library = try AssistantTestLibrary()
        defer { library.close() }
        let member = try await library.member("Synthetic member")
        let edited = try await library.confirmed(member, day: 1, results: "Original")
        let noted = try await library.confirmed(member, day: 2, results: "Noted")
        let deleted = try await library.confirmed(member, day: 3, results: "Deleted")
        let manifest = try await library.repository.assistantPack(memberID: member.id).pack.manifest

        try await library.repository.updateRecord(
            try nextRevision(of: edited, results: SourceField.manualEntry("Changed")), expectedRevision: edited.revision
        )
        try await library.repository.updateRecord(
            try nextRevision(of: noted, notes: [UserNote(text: "Synthetic note")]), expectedRevision: noted.revision
        )
        try await library.repository.deleteRecord(deleted.id, expectedRevision: deleted.revision)

        let states = try await library.repository.assistantRecordStates(manifest.map(\.recordID))

        #expect(states[deleted.id] == nil)
        #expect(states[edited.id]?.revision == edited.revision + 1)
        let statuses = Dictionary(uniqueKeysWithValues: manifest.map { ($0.recordID, $0.status(current: states[$0.recordID])) })
        #expect(statuses[edited.id] == .changed)
        #expect(statuses[noted.id] == .current)
        #expect(statuses[deleted.id] == .deleted)
    }
}

/// The record as the editor saves it: same identity and sources, the next revision.
private func nextRevision(of record: HealthRecord, results: SourceField? = nil, notes: [UserNote]? = nil) throws -> HealthRecord {
    try HealthRecord(
        id: record.id, memberID: record.memberID, sources: record.sources, ocrDocumentObjectID: record.ocrDocumentObjectID,
        importState: .confirmed, revision: record.revision + 1, title: record.title, dateCandidates: record.dateCandidates,
        timelineDateCandidateID: record.timelineDateCandidateID, reportedResults: results ?? record.reportedResults,
        conclusion: record.conclusion, abnormalItems: record.abnormalItems, notes: notes ?? record.notes
    )
}

/// A fresh SQLite library with confirmed reports added through the real import path.
struct AssistantTestLibrary {
    let root: URL
    let store: SQLiteLibraryStore
    let repository: SQLiteReportRepository

    init() throws {
        root = try sqliteTestRoot()
        store = try SQLiteLibraryStore(rootURL: root)
        repository = SQLiteReportRepository(store: store)
    }

    func close() {
        try? store.close()
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    func member(_ name: String) async throws -> FamilyMember {
        let member = try FamilyMember(displayName: name)
        try await repository.saveMember(member, replacing: nil)
        return member
    }

    func confirmed(_ member: FamilyMember, day: Int, results: String) async throws -> HealthRecord {
        let data = Data("assistant-\(member.id)-\(day)-\(results)".utf8)
        let file = try ValidatedImportedFile(
            data: data, kind: .image, contentTypeIdentifier: "public.png", sha256Digest: ContentDigest.sha256(data)
        )
        guard case let .created(id) = try await repository.stage(file) else { throw LibraryReportError.invalidDocument }
        let lease = try await repository.beginProcessing(draftID: id, attemptID: UUID())
        try await repository.completeProcessing(lease: lease, document: ImportDraftDocument(blocks: [], candidates: ReportCandidates()))
        let draft = try await repository.draft(id)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = try #require(calendar.date(from: DateComponents(year: 2000 + day, month: 6, day: 1, hour: 12)))
        let candidate = ReportDateCandidate(date: date, kind: .report, source: try SourceField.manualEntry("Synthetic date"))
        let record = try HealthRecord(
            memberID: member.id, sources: draft.sources, ocrDocumentObjectID: draft.documentObjectID, importState: .confirmed,
            title: SourceField.manualEntry("Synthetic panel"), dateCandidates: [candidate], timelineDateCandidateID: candidate.id,
            reportedResults: SourceField.manualEntry(results)
        )
        try await repository.confirm(draftID: id, expectedRevision: draft.revision, record: record)
        return record
    }
}
