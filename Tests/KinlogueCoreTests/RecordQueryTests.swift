import Foundation
import Testing
@testable import KinlogueCore

@Test
func normalQueriesExposeOnlyConfirmedRecords() throws {
    let member = try FamilyMember(displayName: "Member")
    let confirmed = try queryRecord(memberID: member.id, state: .confirmed, conclusion: "Searchable source")
    let review = try queryRecord(memberID: member.id, state: .needsReview, conclusion: "Searchable source")
    let failed = try queryRecord(memberID: member.id, state: .failed, conclusion: "Searchable source")

    let timeline = RecordQuery.timeline(records: [review, failed, confirmed], memberID: member.id)
    let search = RecordQuery.search("Searchable", records: [review, failed, confirmed], members: [member])

    #expect(timeline.flatMap(\.records).map(\.id) == [confirmed.id])
    #expect(search.map(\.id) == [confirmed.id])
}

@Test
func searchIncludesReportedResults() throws {
    let member = try FamilyMember(displayName: "Member")
    let record = try HealthRecord(
        memberID: member.id,
        attachmentID: UUID(),
        importState: .confirmed,
        reportedResults: try SourceField.manualEntry("Synthetic platelet result")
    )

    let matches = RecordQuery.search(
        "platelet",
        records: [record],
        members: [member]
    )

    #expect(matches.map(\.id) == [record.id])
}

@Test
func searchCanBeScopedToOneFamilyMember() throws {
    let firstMember = try FamilyMember(displayName: "First synthetic member")
    let secondMember = try FamilyMember(displayName: "Second synthetic member")
    let firstRecord = try queryRecord(
        memberID: firstMember.id,
        state: .confirmed,
        conclusion: "Shared synthetic conclusion"
    )
    let secondRecord = try queryRecord(
        memberID: secondMember.id,
        state: .confirmed,
        conclusion: "Shared synthetic conclusion"
    )

    let allMatches = RecordQuery.search(
        "Shared",
        records: [firstRecord, secondRecord],
        members: [firstMember, secondMember]
    )
    let selectedMemberMatches = RecordQuery.search(
        "Shared",
        records: [firstRecord, secondRecord],
        members: [firstMember, secondMember],
        memberID: firstMember.id
    )

    #expect(Set(allMatches.map(\.id)) == Set([firstRecord.id, secondRecord.id]))
    #expect(selectedMemberMatches.map(\.id) == [firstRecord.id])
}

@Test
func timelineSortsUnknownDatesIntoDedicatedFinalGroup() throws {
    let memberID = UUID()
    let dated = try queryRecord(
        memberID: memberID,
        state: .confirmed,
        selectedDate: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let unknown = try queryRecord(memberID: memberID, state: .confirmed)

    let sections = RecordQuery.timeline(records: [unknown, dated], memberID: memberID)

    #expect(sections.count == 2)
    #expect(sections[0].group == .dated(dated.timelineDate!))
    #expect(sections[1].group == .unknown)
    #expect(sections[1].records.map(\.id) == [unknown.id])
}

@Test
func comparisonDoesNotInventMissingConclusion() throws {
    let marked = try SourceField(
        originalTranscription: "Printed marker",
        references: [try SourceReference(pageNumber: 1)]
    )
    let record = try queryRecord(
        memberID: UUID(),
        state: .confirmed,
        abnormalItems: [marked]
    )

    let presentation = record.comparisonPresentation

    #expect(presentation?.conclusion == .notProvided)
    #expect(presentation?.sourceMarkedAbnormalItems == ["Printed marker"])
}

@Test
func duplicateNamesAndArchivedMembersRemainControllable() throws {
    let first = try FamilyMember(displayName: "Member")
    let second = try FamilyMember(displayName: "Member", disambiguationLabel: "Household B")
    let archived = try FamilyMember(displayName: "Archived member", isArchived: true)

    let normal = RecordQuery.selectableMembers(from: [archived, second, first])
    let all = RecordQuery.selectableMembers(from: [archived, second, first], includeArchived: true)
    let labels = RecordQuery.selectionLabels(for: [first, second])

    #expect(normal.map(\.id).contains(archived.id) == false)
    #expect(all.map(\.id).contains(archived.id))
    #expect(labels[first.id] != labels[second.id])
    #expect(labels[first.id]?.contains(first.stableShortID) == true)
    #expect(labels[second.id]?.contains("Household B") == true)
}

@Test
func duplicateMemberNamesRemainDistinctInSearchAndSelectionLabels() throws {
    let first = try FamilyMember(displayName: "Member")
    let second = try FamilyMember(displayName: "Member", disambiguationLabel: "Household B")
    let firstRecord = try queryRecord(memberID: first.id, state: .confirmed)
    let secondRecord = try queryRecord(memberID: second.id, state: .confirmed)

    let records = RecordQuery.search(
        "Member",
        records: [firstRecord, secondRecord],
        members: [first, second]
    )
    let labels = RecordQuery.selectionLabels(for: [first, second])

    #expect(records.count == 2)
    #expect(Set(records.compactMap { labels[$0.memberID] }).count == 2)
    #expect(labels[first.id]?.contains(first.stableShortID) == true)
    #expect(labels[second.id]?.contains("Household B") == true)
}

@Test
func unconfirmedRecordHasNoComparisonPresentation() throws {
    let record = try queryRecord(memberID: UUID(), state: .needsReview, conclusion: "Draft source")

    #expect(record.comparisonPresentation == nil)
}

private func queryRecord(
    memberID: UUID,
    state: ImportState,
    conclusion: String? = nil,
    abnormalItems: [SourceField] = [],
    selectedDate: Date? = nil
) throws -> HealthRecord {
    let candidate = try selectedDate.map {
        ReportDateCandidate(
            date: $0,
            kind: .report,
            source: try SourceField(originalTranscription: "Synthetic date source")
        )
    }
    return try HealthRecord(
        memberID: memberID,
        attachmentID: UUID(),
        importState: state,
        organization: try SourceField(originalTranscription: "Synthetic facility"),
        reportType: try SourceField(originalTranscription: "Synthetic report"),
        dateCandidates: candidate.map { [$0] } ?? [],
        timelineDateCandidateID: candidate?.id,
        conclusion: try conclusion.map { try SourceField(originalTranscription: $0) },
        abnormalItems: abnormalItems
    )
}
