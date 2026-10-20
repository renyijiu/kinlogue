import Foundation

/// What the current extraction rules read differently from a confirmed record, when they are run
/// again on the OCR blocks retained with it. Nothing is recognized again and nothing changes until
/// the user takes a field; each field the user takes replaces the record's field with the new
/// candidate, recognized text and source references included. Member, dates and notes are never
/// offered: the user chose them.
public struct RecordRuleUpdate: Equatable, Identifiable, Sendable {
    public enum Field: CaseIterable, Hashable, Sendable {
        case title, organization, department, reportType, reportedResults, conclusion, abnormalItems
    }

    public struct Change: Hashable, Sendable {
        public let field: Field
        /// The record's field now and the new candidate, as lists: one or no item, or the
        /// abnormal items in order.
        public let current: [SourceField]
        public let proposed: [SourceField]
        /// The user changed what recognition read in the current field, or typed it in by hand,
        /// so taking the new candidate replaces the user's own text.
        public let replacesUserText: Bool
    }

    public var id: UUID { recordID }
    public let recordID: UUID
    public let recordRevision: UInt64
    /// The rules the candidates come from.
    public let extractionVersion: Int
    public let changes: [Change]
    /// The candidates the current rules read, to be retained with the record once the user decides.
    public let candidates: ReportCandidates

    /// The fields `candidates` read differently from `record`, or nil when there are none. Two
    /// readings differ when their recognized text differs; a correction the user made to the same
    /// recognized text is not a difference.
    public static func proposal(for record: HealthRecord, candidates: ReportCandidates, extractionVersion: Int) -> Self? {
        let changes = Field.allCases.compactMap { field -> Change? in
            let current = record.values(of: field), proposed = candidates.values(of: field)
            guard current.map(\.originalTranscription) != proposed.map(\.originalTranscription) else { return nil }
            return Change(field: field, current: current, proposed: proposed,
                          replacesUserText: current.contains { $0.correctedTranscription != nil || $0.entryMethod == .manual })
        }
        guard !changes.isEmpty else { return nil }
        return Self(recordID: record.id, recordRevision: record.revision, extractionVersion: extractionVersion,
                    changes: changes, candidates: candidates)
    }

    /// `record` at its next revision with the fields in `accepted` taken from the new candidates and
    /// every other field as it was. Accepting none still makes a new revision, which records that
    /// the user has seen these rules.
    public func applying(_ accepted: Set<Field>, to record: HealthRecord) throws -> HealthRecord {
        guard record.id == recordID, record.revision == recordRevision else { throw RecordRuleUpdateError.recordChanged }
        let next = record.revision.addingReportingOverflow(1)
        guard !next.overflow else { throw RecordRuleUpdateError.recordChanged }
        func value(_ field: Field) -> [SourceField] {
            accepted.contains(field) && changes.contains(where: { $0.field == field })
                ? candidates.values(of: field) : record.values(of: field)
        }
        return try HealthRecord(
            id: record.id, memberID: record.memberID, sources: record.sources,
            ocrDocumentObjectID: record.ocrDocumentObjectID, importState: record.importState,
            revision: next.partialValue,
            title: value(.title).first, organization: value(.organization).first,
            department: value(.department).first, reportType: value(.reportType).first,
            dateCandidates: record.dateCandidates, timelineDateCandidateID: record.timelineDateCandidateID,
            reportedResults: value(.reportedResults).first, conclusion: value(.conclusion).first,
            abnormalItems: value(.abnormalItems), notes: record.notes
        )
    }
}

public enum RecordRuleUpdateError: Error, Equatable, Sendable {
    case recordChanged
}

private extension HealthRecord {
    func values(of field: RecordRuleUpdate.Field) -> [SourceField] {
        switch field {
        case .title: [title].compactMap { $0 }
        case .organization: [organization].compactMap { $0 }
        case .department: [department].compactMap { $0 }
        case .reportType: [reportType].compactMap { $0 }
        case .reportedResults: [reportedResults].compactMap { $0 }
        case .conclusion: [conclusion].compactMap { $0 }
        case .abnormalItems: abnormalItems
        }
    }
}

private extension ReportCandidates {
    func values(of field: RecordRuleUpdate.Field) -> [SourceField] {
        switch field {
        case .title: [title].compactMap { $0 }
        case .organization: [organization].compactMap { $0 }
        case .department: [department].compactMap { $0 }
        case .reportType: [reportType].compactMap { $0 }
        case .reportedResults: [reportedResults].compactMap { $0 }
        case .conclusion: [conclusion].compactMap { $0 }
        case .abnormalItems: abnormalItems
        }
    }
}
