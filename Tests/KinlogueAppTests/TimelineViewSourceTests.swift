import Foundation
import SwiftUI
import Testing
@testable import KinlogueApp

struct TimelineViewSourceTests {
    @Test
    func memberChipsAppearOnlyWhereSeveralMembersShareTheTimeline() throws {
        let timeline = try source(named: "TimelineView.swift")
        let shell = try source(named: "AppShellView.swift")

        #expect(shell.contains("showsMemberLabels: model.selectedMemberID == nil"))
        // Both the report card and the imaging card guard their chip, and the
        // search results use the same card as the dated sections.
        #expect(timeline.components(separatedBy: "showsMemberLabel: showsMemberLabels").count - 1 == 3)
        #expect(timeline.components(
            separatedBy: "if showsMemberLabel {\n                            Text(memberLabel)"
        ).count - 1 == 2)
        #expect(timeline.components(separatedBy: "Text(memberLabel)").count - 1 == 2)
        // VoiceOver keeps the member on every card whether or not the chip shows.
        #expect(timeline.contains("AppLocalization.string(\"\\(memberLabel)，\\(recordType)\")"))
        #expect(timeline.contains(".accessibilityValue(memberLabel)"))
    }

    @Test
    func enteringTheTimelineOpensItsNewestRecord() throws {
        let shell = try source(named: "AppShellView.swift")
        let timelineStart = try #require(shell.range(of: "TimelineView("))
        let titleStart = try #require(shell.range(
            of: ".navigationTitle(model.selectedMemberID.flatMap",
            range: timelineStart.lowerBound..<shell.endIndex
        ))
        let timelineColumn = shell[timelineStart.lowerBound..<titleStart.lowerBound]

        #expect(timelineColumn.contains(
            ".task(id: model.selectedMemberID) {\n                        await model.openNewestRecordIfNothingIsOpen()"
        ))
        #expect(shell.components(separatedBy: "openNewestRecordIfNothingIsOpen()").count - 1 == 1)
    }

    @Test
    func searchCardsNameTheirDateAndShowMatchedResultLinesWithoutJudgingThem() throws {
        let timeline = try source(named: "TimelineView.swift")

        // Only search results lack the date sections, so only they name the date on the card.
        #expect(timeline.components(separatedBy: "searchTerm: searchTerm,").count - 1 == 1)
        #expect(timeline.components(separatedBy: "searchTerm: \"\",").count - 1 == 1)
        #expect(timeline.contains("private var isSearchResult: Bool { !searchTerm.isEmpty }"))
        #expect(timeline.contains("if !record.matchedResultLines.isEmpty {"))
        #expect(timeline.contains("AppLocalization.string(\"\\(memberLabel)，\\(recordType)，\\(dateText)，匹配的结果行：\\(lines)\")"))
        // The lines are printed cells. No status tone may suggest the value is normal or not.
        let view = try #require(timeline.range(of: "private struct MatchedResultLinesView"))
        let body = timeline[view.lowerBound...].lowercased()
        for tone in ["danger", "warning", "accent", "success", "kinloguestatus", ".red", ".green", ".orange"] {
            #expect(!body.contains(tone))
        }
    }

    @Test
    func searchCardsHighlightTheTermAndShowAnExcerptWhenNoLineMatched() throws {
        let timeline = try source(named: "TimelineView.swift")
        let shell = try source(named: "AppShellView.swift")

        #expect(shell.contains("searchTerm: model.searchText.trimmingCharacters(in: .whitespacesAndNewlines),"))
        #expect(timeline.components(separatedBy: "term: searchTerm").count - 1 == 5)
        // Lines come first, then the sentences, then the excerpt, and only then the conclusion.
        let lines = try #require(timeline.range(of: "if !record.matchedResultLines.isEmpty {"))
        let passages = try #require(timeline.range(of: "} else if !record.matchedPassages.isEmpty {"))
        let excerpt = try #require(timeline.range(of: "} else if let excerpt = record.matchedExcerpt {"))
        let conclusion = try #require(timeline.range(of: "AppLocalization.string(\"原报告未提供结论\")"))
        #expect(lines.lowerBound < passages.lowerBound && passages.lowerBound < excerpt.lowerBound)
        #expect(excerpt.lowerBound < conclusion.lowerBound)
        #expect(timeline.contains("AppLocalization.string(\"\\(memberLabel)，\\(recordType)，\\(dateText)，匹配的句子：\\(sentences)\")"))
        // Each sentence names its field; VoiceOver reads the sentence without the drawn ellipses.
        #expect(timeline.contains("case .reportedResults: AppLocalization.string(\"检查结果\")"))
        #expect(timeline.contains("case .conclusion: AppLocalization.string(\"检查结论\")"))
        #expect(timeline.contains("AppLocalization.string(\"\\(fieldName($0.field))：\\($0.excerpt.text)\")"))
        #expect(timeline.contains("AppLocalization.string(\"\\(memberLabel)，\\(recordType)，\\(dateText)，匹配内容：\\(excerpt)\")"))
        // VoiceOver reads the excerpt without the drawn ellipses.
        #expect(timeline.contains("if let excerpt = record.matchedExcerpt?.text {"))
    }

    @Test
    func searchHighlightMarksEveryPlaceTheTermIsFound() {
        let highlighted = SearchHighlight.text("LDL 与 ldl-C，合成LDL", term: "ldl", locale: Locale(identifier: "zh_Hans_CN"))
        let marked = highlighted.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }
            .map { String(highlighted[$0.range].characters) }
        #expect(marked == ["LDL", "ldl", "LDL"])
        #expect(String(highlighted.characters) == "LDL 与 ldl-C，合成LDL")
        for term in ["", "absent", "l\u{0}"] {
            #expect(SearchHighlight.text("LDL", term: term).runs.allSatisfy { $0.inlinePresentationIntent == nil })
        }
    }

    private func source(named filename: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/KinlogueApp/Views")
                .appendingPathComponent(filename),
            encoding: .utf8
        )
    }
}
