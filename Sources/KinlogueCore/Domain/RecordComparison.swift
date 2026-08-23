import Foundation

public enum RecordComparisonError: Error, Equatable, Sendable {
    case requiresExactlyTwoRecords
    case duplicateRecord
    case unconfirmedRecord
}

public struct RecordComparisonPane: Equatable, Sendable {
    public let recordID: HealthRecord.ID
    public let memberID: FamilyMember.ID
    public let sources: ReportSources
    public let title: String?
    public let timelineDate: Date?
    public let reportedResults: ComparisonConclusion
    public let conclusion: ComparisonConclusion
    public let sourceMarkedAbnormalItems: [String]

    public init(record: HealthRecord) throws {
        guard let presentation = record.comparisonPresentation else {
            throw RecordComparisonError.unconfirmedRecord
        }
        recordID = record.id
        memberID = record.memberID
        sources = record.sources
        title = record.title?.transcription ?? record.reportType?.transcription
        timelineDate = record.timelineDate
        reportedResults = presentation.reportedResults
        conclusion = presentation.conclusion
        sourceMarkedAbnormalItems = presentation.sourceMarkedAbnormalItems
    }
}

/// A faithful, presentation-only pairing. It intentionally has no user notes,
/// numeric interpretation, trend, derived abnormality or medical summary fields.
public struct RecordComparison: Equatable, Sendable {
    public let left: RecordComparisonPane
    public let right: RecordComparisonPane

    public init(records: [HealthRecord]) throws {
        guard records.count == 2 else {
            throw RecordComparisonError.requiresExactlyTwoRecords
        }
        guard records[0].id != records[1].id else {
            throw RecordComparisonError.duplicateRecord
        }
        left = try RecordComparisonPane(record: records[0])
        right = try RecordComparisonPane(record: records[1])
    }
}
