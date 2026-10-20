import Foundation
import Testing
@testable import KinlogueCore

@Test
func ruleUpdateOffersOnlyFieldsTheNewRulesReadDifferently() throws {
    let date = ReportDateCandidate(date: Date(timeIntervalSince1970: 1_786_000_000), kind: .report,
                                   source: try SourceField(originalTranscription: "合成日期"))
    let record = try HealthRecord(
        memberID: UUID(), attachmentID: UUID(), importState: .confirmed, revision: 3,
        // Recognized the same way; the user's correction is not a difference.
        title: try SourceField(originalTranscription: "合成旧标题", correctedTranscription: "合成标题"),
        // A sentence the older rules took for the hospital.
        organization: try SourceField(originalTranscription: "以合成医院纸质报告为准"),
        department: try SourceField.manualEntry("合成科室"),
        dateCandidates: [date], timelineDateCandidateID: date.id,
        conclusion: try SourceField(originalTranscription: "合成结论"),
        abnormalItems: [try SourceField(originalTranscription: "6.85↑")],
        notes: [try UserNote(text: "合成备注")]
    )
    let candidates = ReportCandidates(
        title: try SourceField(originalTranscription: "合成旧标题"),
        reportedResults: try SourceField(originalTranscription: "合成葡萄糖\t6.85↑\t3.89-6.11"),
        conclusion: try SourceField(originalTranscription: "合成结论"),
        abnormalItems: [try SourceField(originalTranscription: "合成葡萄糖 6.85↑ 3.89-6.11")]
    )

    let update = try #require(RecordRuleUpdate.proposal(for: record, candidates: candidates, extractionVersion: 7))

    #expect(update.changes.map(\.field) == [.organization, .department, .reportedResults, .abnormalItems])
    #expect(update.changes.map(\.replacesUserText) == [false, true, false, false])
    #expect(update.changes[0].proposed.isEmpty && update.changes[2].current.isEmpty)
    #expect(update.recordID == record.id && update.recordRevision == 3 && update.extractionVersion == 7)

    // Taken fields come from the candidates; every other field, the dates and notes stay.
    let updated = try update.applying([.organization, .reportedResults], to: record)
    #expect(updated.revision == 4)
    #expect(updated.organization == nil)
    #expect(updated.reportedResults == candidates.reportedResults)
    #expect(updated.title == record.title && updated.department == record.department)
    #expect(updated.abnormalItems == record.abnormalItems && updated.conclusion == record.conclusion)
    #expect(updated.dateCandidates == record.dateCandidates && updated.timelineDateCandidateID == date.id)
    #expect(updated.notes == record.notes && updated.memberID == record.memberID && updated.sources == record.sources)
    // A field the rules read the same way is never replaced, even when asked.
    #expect(try update.applying([.title, .conclusion], to: record).title == record.title)
    // Keeping everything is a new revision with the same fields.
    let kept = try update.applying([], to: record)
    #expect(kept.revision == 4 && kept.organization == record.organization && kept.abnormalItems == record.abnormalItems)
    // A record that moved on since the proposal is refused.
    #expect(throws: RecordRuleUpdateError.recordChanged) { _ = try update.applying([.organization], to: updated) }

    // Nothing to offer once the record reads as the rules do.
    #expect(RecordRuleUpdate.proposal(for: updated, candidates: ReportCandidates(
        department: record.department, title: record.title,
        reportedResults: candidates.reportedResults, conclusion: record.conclusion,
        abnormalItems: record.abnormalItems
    ), extractionVersion: 7) == nil)
}
