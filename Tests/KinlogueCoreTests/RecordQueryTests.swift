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
func searchTermEndingInNULMatchesOnlyTextThatContainsIt() {
    // Foundation reads past the end of the text for such a term: without the guard the first two
    // lines report a match and the third traps.
    for locale in [Locale(identifier: "en_US"), Locale(identifier: "zh_Hans_CN"), Locale(identifier: "tr_TR")] {
        #expect(!RecordQuery.localizedContains("A\u{0}", in: "ungla", locale: locale))
        #expect(!RecordQuery.localizedContains("a\u{0}\u{0}", in: "ungla", locale: locale))
        #expect(!RecordQuery.localizedContains("成\u{0}", in: "合成", locale: locale))
        #expect(RecordQuery.localizedContains("A\u{0}", in: "xa\u{0}y", locale: locale))
        #expect(RecordQuery.localizedContains("成\u{0}", in: "合成\u{0}", locale: locale))
        #expect(RecordQuery.localizedContains("\u{0}", in: "a\u{0}", locale: locale))
        #expect(!RecordQuery.localizedContains("\u{0}", in: "a", locale: locale))
    }
    #expect(!RecordQuery.matchesSearchTerm("成\u{0}", fields: ["合成", "Synthetic"]))
    #expect(RecordQuery.matchesSearchTerm("syn", fields: ["合成", "Synthetic"]))
    #expect(!RecordQuery.matchesSearchTerm("", fields: ["合成"]))
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

@Test
func resultLinesKeepTheTableCellsOfExtractedResultsVerbatim() throws {
    // The exact transcription the table extraction writes for two lab rows.
    let transcription = "合成项目甲\t12.2 ↑\t3.0~10.0%\n合成项目乙\t5.9\t3.5~9.5"

    #expect(ReportedResultLine.lines(in: transcription).map(\.cells) == [
        ["合成项目甲", "12.2 ↑", "3.0~10.0%"],
        ["合成项目乙", "5.9", "3.5~9.5"],
    ])
    #expect(ReportedResultLine.lines(matching: "项目乙", in: transcription).map(\.cells) == [["合成项目乙", "5.9", "3.5~9.5"]])
    #expect(ReportedResultLine.lines(matching: "12.2", in: transcription).map(\.cells) == [["合成项目甲", "12.2 ↑", "3.0~10.0%"]])
    #expect(ReportedResultLine.lines(matching: "合成项目", in: transcription).count == 2)
    #expect(ReportedResultLine.lines(matching: "", in: transcription).isEmpty)
    #expect(ReportedResultLine.lines(matching: "absent", in: transcription).isEmpty)
}

@Test
func resultLinesNeedTwoCellsAndIgnoreNarrativeText() {
    #expect(ReportedResultLine.lines(in: "合成检查所见正文。\n合成项目 12 3~4").isEmpty)
    #expect(ReportedResultLine.lines(matching: "合成", in: "合成检查所见正文。").isEmpty)
    // A user edit can leave a single cell, blank cells or Windows line endings behind.
    let edited = "合成项目甲\t\n\t\t\n 合成项目乙 \t\t 5.9 \r\n合成说明一句\n合成项目丙\t7\t5~8\t附注"
    #expect(ReportedResultLine.lines(in: edited).map(\.cells) == [
        ["合成项目乙", "5.9"],
        ["合成项目丙", "7", "5~8", "附注"],
    ])
    // The term is searched in the stored line, so it never spans a tab.
    #expect(ReportedResultLine.lines(matching: "项目乙 5.9", in: edited).isEmpty)
}

@Test
func reportSummaryBoundsTheResultLinesItLists() throws {
    let member = try FamilyMember(displayName: "Synthetic member")
    let record = try queryRecord(memberID: member.id, state: .confirmed, conclusion: "Synthetic impression")
    let summary = LibraryReportSummary(record: record)
    #expect(summary.matchedResultLines.isEmpty)
    #expect(summary.matchedResultLineCount == 0)

    let long = String(repeating: "合", count: 200)
    let lines = (0..<10).compactMap { ReportedResultLine("\(long)\($0)\t\($0)") }
    let listed = summary.listing(LibraryReportSearchMatch(resultLines: lines, excerpt: nil))
    #expect(listed.matchedResultLineCount == 10)
    #expect(listed.matchedResultLines.count == LibraryReportSummary.maximumMatchedResultLines)
    #expect(listed.matchedResultLines.allSatisfy { $0.cells[0].unicodeScalars.count == LibraryReportSummary.maximumResultCellScalars })
    #expect(listed.matchedResultLines.map { $0.cells[1] } == (0..<8).map(String.init))
    #expect(listed.id == summary.id && listed.conclusion == summary.conclusion && listed.timelineDate == summary.timelineDate)
}

@Test
func searchExcerptKeepsAWindowAroundTheFirstMatch() throws {
    let before = String(repeating: "甲", count: 50), after = String(repeating: "乙", count: 200)
    let excerpt = try #require(SearchExcerpt(term: "肝脏", in: before + "\n肝脏\t形态正常。" + after))
    #expect(excerpt.text.hasPrefix(String(repeating: "甲", count: 29) + " 肝脏 形态正常。"))
    #expect(excerpt.text.count == SearchExcerpt.maximumCharacters)
    #expect(excerpt.isTruncatedAtStart && excerpt.isTruncatedAtEnd)
    #expect(excerpt.displayText == "…" + excerpt.text + "…")

    // A short field is kept whole, matched without regard to case, with its whitespace folded.
    let whole = try #require(SearchExcerpt(term: "ldl", in: "  Synthetic\tLDL-C\n 2.1  "))
    #expect(whole.text == "Synthetic LDL-C 2.1")
    #expect(!whole.isTruncatedAtStart && !whole.isTruncatedAtEnd)
    #expect(whole.displayText == whole.text)

    #expect(SearchExcerpt(term: "absent", in: "Synthetic") == nil)
    #expect(SearchExcerpt(term: "", in: "Synthetic") == nil)
    #expect(SearchExcerpt(term: "成\u{0}", in: "合成\u{0}") == nil)
}

@Test
func searchMatchPrefersResultLinesAndSkipsFieldsTheRowShows() throws {
    let line = try #require(ReportedResultLine("合成葡萄糖\t5.4"))
    let excerpt = try #require(SearchExcerpt(term: "葡萄糖", in: "合成葡萄糖偏高"))
    #expect(LibraryReportSearchMatch(resultLines: [line], excerpt: excerpt).excerpt == nil)
    #expect(LibraryReportSearchMatch.none.isEmpty)

    let fields = ["合成标题", "合成医院", "合成内分泌科", "合成结论提到内分泌", "2026-10-09T00:00:00Z"]
    let visible: Set = ["合成标题", "合成医院", "2026-10-09T00:00:00Z"]
    #expect(LibraryReportSearchMatch.excerpt(term: "内分泌", fields: fields, hiding: visible)?.text == "合成内分泌科")
    #expect(LibraryReportSearchMatch.excerpt(term: "标题", fields: fields, hiding: visible) == nil)
    #expect(LibraryReportSearchMatch.excerpt(term: "2026", fields: fields, hiding: visible) == nil)

    let member = try FamilyMember(displayName: "Synthetic member")
    let summary = LibraryReportSummary(record: try queryRecord(memberID: member.id, state: .confirmed, conclusion: "Synthetic"))
    #expect(summary.matchedExcerpt == nil)
    #expect(summary.visibleSearchText == ["Synthetic report", "Synthetic facility"])
    // 101 characters, but each of the last 100 carries ten combining marks.
    let marked = String(repeating: "a" + String(repeating: "\u{301}", count: 10), count: 100)
    let long = try #require(SearchExcerpt(term: "x", in: "x" + marked))
    #expect(!long.isTruncatedAtEnd)
    let listed = summary.listing(LibraryReportSearchMatch(resultLines: [], excerpt: long))
    #expect(listed.matchedExcerpt?.text.unicodeScalars.count == LibraryReportSummary.maximumExcerptScalars)
    #expect(listed.matchedExcerpt?.isTruncatedAtEnd == true)
    #expect(listed.matchedResultLines.isEmpty)
}
