import Foundation
import Testing

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
