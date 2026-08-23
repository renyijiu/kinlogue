import Foundation

public struct HealthRecord: Codable, Identifiable, Hashable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case id
        case memberID
        case sources
        case ocrDocumentObjectID
        case importState
        case revision
        case title
        case organization
        case department
        case reportType
        case dateCandidates
        case timelineDateCandidateID
        case reportedResults
        case conclusion
        case abnormalItems
        case notes
    }

    public let id: UUID
    public var memberID: FamilyMember.ID
    public let sources: ReportSources
    /// OCR document retained for provenance after a draft is confirmed.
    public let ocrDocumentObjectID: UUID?
    public var importState: ImportState
    public let revision: UInt64
    public var title: SourceField?
    public var organization: SourceField?
    public var department: SourceField?
    public var reportType: SourceField?
    public var dateCandidates: [ReportDateCandidate]
    public var timelineDateCandidateID: ReportDateCandidate.ID?
    public var reportedResults: SourceField?
    public var conclusion: SourceField?
    public var abnormalItems: [SourceField]
    public var notes: [UserNote]

    public init(
        id: UUID = UUID(),
        memberID: FamilyMember.ID,
        sources: ReportSources,
        ocrDocumentObjectID: UUID? = nil,
        importState: ImportState,
        revision: UInt64 = 0,
        title: SourceField? = nil,
        organization: SourceField? = nil,
        department: SourceField? = nil,
        reportType: SourceField? = nil,
        dateCandidates: [ReportDateCandidate] = [],
        timelineDateCandidateID: ReportDateCandidate.ID? = nil,
        reportedResults: SourceField? = nil,
        conclusion: SourceField? = nil,
        abnormalItems: [SourceField] = [],
        notes: [UserNote] = []
    ) throws {
        guard Set(dateCandidates.map(\.id)).count == dateCandidates.count else {
            throw DomainValidationError.duplicateIdentifier
        }
        if let timelineDateCandidateID,
           !dateCandidates.contains(where: { $0.id == timelineDateCandidateID }) {
            throw DomainValidationError.invalidTimelineDateSelection
        }

        self.id = id
        self.memberID = memberID
        self.sources = sources
        self.ocrDocumentObjectID = ocrDocumentObjectID
        self.importState = importState
        self.revision = revision
        self.title = try title?.attributedAndValidated(for: sources)
        self.organization = try organization?.attributedAndValidated(for: sources)
        self.department = try department?.attributedAndValidated(for: sources)
        self.reportType = try reportType?.attributedAndValidated(for: sources)
        self.dateCandidates = try dateCandidates.map {
            ReportDateCandidate(
                id: $0.id,
                date: $0.date,
                kind: $0.kind,
                source: try $0.source.attributedAndValidated(for: sources)
            )
        }
        self.timelineDateCandidateID = timelineDateCandidateID
        self.reportedResults = try reportedResults?.attributedAndValidated(for: sources)
        self.conclusion = try conclusion?.attributedAndValidated(for: sources)
        self.abnormalItems = try abnormalItems.map { try $0.attributedAndValidated(for: sources) }
        self.notes = notes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(UUID.self, forKey: .id),
                memberID: container.decode(FamilyMember.ID.self, forKey: .memberID),
                sources: container.decode(ReportSources.self, forKey: .sources),
                ocrDocumentObjectID: container.decodeIfPresent(
                    UUID.self,
                    forKey: .ocrDocumentObjectID
                ),
                importState: container.decode(ImportState.self, forKey: .importState),
                revision: container.decodeIfPresent(UInt64.self, forKey: .revision) ?? 0,
                title: container.decodeIfPresent(SourceField.self, forKey: .title),
                organization: container.decodeIfPresent(SourceField.self, forKey: .organization),
                department: container.decodeIfPresent(SourceField.self, forKey: .department),
                reportType: container.decodeIfPresent(SourceField.self, forKey: .reportType),
                dateCandidates: container.decode(
                    [ReportDateCandidate].self,
                    forKey: .dateCandidates
                ),
                timelineDateCandidateID: container.decodeIfPresent(
                    ReportDateCandidate.ID.self,
                    forKey: .timelineDateCandidateID
                ),
                reportedResults: container.decodeIfPresent(
                    SourceField.self,
                    forKey: .reportedResults
                ),
                conclusion: container.decodeIfPresent(SourceField.self, forKey: .conclusion),
                abnormalItems: container.decode([SourceField].self, forKey: .abnormalItems),
                notes: container.decode([UserNote].self, forKey: .notes)
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Health record failed structural validation"
                )
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        guard Set(dateCandidates.map(\.id)).count == dateCandidates.count else {
            throw EncodingError.invalidValue(
                self,
                .init(
                    codingPath: encoder.codingPath,
                    debugDescription: "Health record has duplicate date candidate identifiers"
                )
            )
        }

        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(memberID, forKey: .memberID)
        try container.encode(sources, forKey: .sources)
        try container.encodeIfPresent(ocrDocumentObjectID, forKey: .ocrDocumentObjectID)
        try container.encode(importState, forKey: .importState)
        // Revision zero is the historical wire representation where the key
        // was absent. Keeping it absent preserves existing catalog digests.
        if revision != 0 {
            try container.encode(revision, forKey: .revision)
        }
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(organization, forKey: .organization)
        try container.encodeIfPresent(department, forKey: .department)
        try container.encodeIfPresent(reportType, forKey: .reportType)
        try container.encode(dateCandidates, forKey: .dateCandidates)
        try container.encodeIfPresent(timelineDateCandidateID, forKey: .timelineDateCandidateID)
        try container.encodeIfPresent(reportedResults, forKey: .reportedResults)
        try container.encodeIfPresent(conclusion, forKey: .conclusion)
        try container.encode(abnormalItems, forKey: .abnormalItems)
        try container.encode(notes, forKey: .notes)
    }

    /// Compatibility initializer for the existing one-file import path.
    public init(
        id: UUID = UUID(),
        memberID: FamilyMember.ID,
        attachmentID: Attachment.ID,
        ocrDocumentObjectID: UUID? = nil,
        importState: ImportState,
        revision: UInt64 = 0,
        title: SourceField? = nil,
        organization: SourceField? = nil,
        department: SourceField? = nil,
        reportType: SourceField? = nil,
        dateCandidates: [ReportDateCandidate] = [],
        timelineDateCandidateID: ReportDateCandidate.ID? = nil,
        reportedResults: SourceField? = nil,
        conclusion: SourceField? = nil,
        abnormalItems: [SourceField] = [],
        notes: [UserNote] = []
    ) throws {
        try self.init(
            id: id,
            memberID: memberID,
            sources: .unnamedSinglePage(ownerID: id, attachmentID: attachmentID),
            ocrDocumentObjectID: ocrDocumentObjectID,
            importState: importState,
            revision: revision,
            title: title,
            organization: organization,
            department: department,
            reportType: reportType,
            dateCandidates: dateCandidates,
            timelineDateCandidateID: timelineDateCandidateID,
            reportedResults: reportedResults,
            conclusion: conclusion,
            abnormalItems: abnormalItems,
            notes: notes
        )
    }

    public var soleAttachmentID: Attachment.ID? {
        sources.soleSource?.attachmentID
    }

    public var timelineDateCandidate: ReportDateCandidate? {
        guard let timelineDateCandidateID else { return nil }
        return dateCandidates.first { $0.id == timelineDateCandidateID }
    }

    public var timelineDate: Date? {
        timelineDateCandidate?.date
    }

    public var hasValidTimelineDateSelection: Bool {
        guard let timelineDateCandidateID else { return true }
        return dateCandidates.contains { $0.id == timelineDateCandidateID }
    }

    public var hasUniqueDateCandidateIDs: Bool {
        Set(dateCandidates.map(\.id)).count == dateCandidates.count
    }

    public var hasValidSourceReferences: Bool {
        let sourceByID = Dictionary(uniqueKeysWithValues: sources.elements.map { ($0.id, $0) })
        let fields = [title, organization, department, reportType, reportedResults, conclusion]
            .compactMap { $0 } + abnormalItems + dateCandidates.map(\.source)
        return fields.flatMap(\.references).allSatisfy { reference in
            guard let sourceID = reference.sourceID,
                  let attachmentID = reference.attachmentID,
                  let source = sourceByID[sourceID] else { return false }
            return source.attachmentID == attachmentID
                && (1...source.pageCount).contains(reference.filePageNumber)
        }
    }

    public var comparisonPresentation: ComparisonRecordPresentation? {
        guard importState == .confirmed else { return nil }
        return ComparisonRecordPresentation(
            recordID: id,
            reportedResults: reportedResults.map { .verbatim($0.transcription) } ?? .notProvided,
            conclusion: conclusion.map { .verbatim($0.transcription) } ?? .notProvided,
            sourceMarkedAbnormalItems: abnormalItems
                .filter { !$0.references.isEmpty }
                .map(\.transcription)
        )
    }

    public func reassigned(to memberID: FamilyMember.ID) -> Self {
        var copy = self
        copy.memberID = memberID
        return copy
    }

    public func transitioning(to state: ImportState) throws -> Self {
        guard importState.canTransition(to: state) else {
            throw DomainValidationError.invalidStateTransition
        }
        var copy = self
        copy.importState = state
        return copy
    }
}

public enum ComparisonConclusion: Codable, Hashable, Sendable {
    case verbatim(String)
    case notProvided
}

public struct ComparisonRecordPresentation: Codable, Hashable, Sendable {
    public let recordID: HealthRecord.ID
    public let reportedResults: ComparisonConclusion
    public let conclusion: ComparisonConclusion
    public let sourceMarkedAbnormalItems: [String]

    public init(
        recordID: HealthRecord.ID,
        reportedResults: ComparisonConclusion,
        conclusion: ComparisonConclusion,
        sourceMarkedAbnormalItems: [String]
    ) {
        self.recordID = recordID
        self.reportedResults = reportedResults
        self.conclusion = conclusion
        self.sourceMarkedAbnormalItems = sourceMarkedAbnormalItems
    }
}
