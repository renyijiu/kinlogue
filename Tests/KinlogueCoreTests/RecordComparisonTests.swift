import Foundation
import Testing
@testable import KinlogueCore

@Test
func comparisonRequiresExactlyTwoDistinctConfirmedRecords() throws {
    let first = try comparisonRecord(state: .confirmed)
    let second = try comparisonRecord(state: .confirmed)
    let draft = try comparisonRecord(state: .needsReview)

    #expect(throws: RecordComparisonError.requiresExactlyTwoRecords) {
        _ = try RecordComparison(records: [first])
    }
    #expect(throws: RecordComparisonError.duplicateRecord) {
        _ = try RecordComparison(records: [first, first])
    }
    #expect(throws: RecordComparisonError.unconfirmedRecord) {
        _ = try RecordComparison(records: [first, draft])
    }
    #expect(try RecordComparison(records: [first, second]).left.recordID == first.id)
}

@Test
func comparisonKeepsSelectionOrderAndNeverIncludesNotesOrDerivedMarkers() throws {
    let sourced = try SourceField(
        originalTranscription: "Printed up marker",
        references: [try SourceReference(pageNumber: 1)]
    )
    let unsourced = try SourceField(originalTranscription: "Unsourced value")
    let left = try comparisonRecord(
        state: .confirmed,
        reportedResults: try SourceField(originalTranscription: "Verbatim result"),
        conclusion: try SourceField(originalTranscription: "Verbatim left"),
        abnormalItems: [sourced, unsourced],
        notes: [try UserNote(text: "Must never enter comparison")]
    )
    let right = try comparisonRecord(state: .confirmed)

    let comparison = try RecordComparison(records: [right, left])

    #expect(comparison.left.recordID == right.id)
    #expect(comparison.left.conclusion == .notProvided)
    #expect(comparison.right.recordID == left.id)
    #expect(comparison.right.reportedResults == .verbatim("Verbatim result"))
    #expect(comparison.right.conclusion == .verbatim("Verbatim left"))
    #expect(comparison.right.sourceMarkedAbnormalItems == ["Printed up marker"])
    #expect(String(describing: comparison).contains("Must never enter comparison") == false)
}

@Test
func correctionCanReturnToTheOriginalTranscription() throws {
    let original = try SourceField(
        originalTranscription: "A",
        references: [try SourceReference(pageNumber: 1)]
    )
    let corrected = try original.correctingTranscription(to: "B")
    let reverted = try corrected.correctingTranscription(to: "A")

    #expect(corrected.transcription == "B")
    #expect(reverted.transcription == "A")
    #expect(reverted.correctedTranscription == nil)
    #expect(reverted.references == original.references)
}

@Test
func comparisonCarriesEveryOrderedOriginalWithoutCollapsingRepeatedAttachments() throws {
    let attachmentID = UUID()
    let first = try ReportSource(
        attachmentID: attachmentID,
        displayName: "first.png",
        pageCount: 1
    )
    let second = try ReportSource(
        attachmentID: attachmentID,
        displayName: "second.png",
        pageCount: 1
    )
    let record = try HealthRecord(
        memberID: UUID(),
        sources: ReportSources([first, second]),
        importState: .confirmed
    )

    let pane = try RecordComparisonPane(record: record)

    #expect(pane.sources.elements == [first, second])
    #expect(pane.sources.attachmentIDs == [attachmentID, attachmentID])
    #expect(record.soleAttachmentID == nil)
}

private func comparisonRecord(
    state: ImportState,
    reportedResults: SourceField? = nil,
    conclusion: SourceField? = nil,
    abnormalItems: [SourceField] = [],
    notes: [UserNote] = []
) throws -> HealthRecord {
    try HealthRecord(
        memberID: UUID(),
        attachmentID: UUID(),
        importState: state,
        reportedResults: reportedResults,
        conclusion: conclusion,
        abnormalItems: abnormalItems,
        notes: notes
    )
}
