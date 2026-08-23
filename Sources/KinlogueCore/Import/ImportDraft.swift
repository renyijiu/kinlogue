import Foundation

public enum ImportFailureCode: String, Codable, CaseIterable, Hashable, Sendable {
    case textExtractionFailed
    case cancelled
}

public enum ImportDraftError: Error, Equatable, Sendable {
    case invalidState
    case staleAttempt
}

public enum ImportDraftTimelineDateSelection: Codable, Hashable, Sendable {
    case unknown
    case detected(ReportDateCandidate.ID)
    case manual(Date)
}

public struct ImportDraftReviewState: Codable, Hashable, Sendable {
    public let timelineDateSelection: ImportDraftTimelineDateSelection
    public let title: String
    public let organization: String
    public let department: String
    public let reportType: String
    public let reportedResults: String
    public let conclusion: String
    public let abnormalItems: [String]
    public let userNote: String

    public init(
        timelineDateSelection: ImportDraftTimelineDateSelection,
        title: String,
        organization: String,
        department: String,
        reportType: String,
        reportedResults: String,
        conclusion: String,
        abnormalItems: [String],
        userNote: String
    ) {
        self.timelineDateSelection = timelineDateSelection
        self.title = title
        self.organization = organization
        self.department = department
        self.reportType = reportType
        self.reportedResults = reportedResults
        self.conclusion = conclusion
        self.abnormalItems = abnormalItems
        self.userNote = userNote
    }
}

public struct ImportDraft: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let sources: ReportSources
    public var state: ImportState
    public var revision: UInt64
    public var attemptID: UUID?
    public var documentObjectID: UUID?
    public var failureCode: ImportFailureCode?
    public var memberID: FamilyMember.ID?

    public init(
        id: UUID = UUID(),
        sources: ReportSources,
        state: ImportState = .staging,
        revision: UInt64 = 0,
        attemptID: UUID? = nil,
        documentObjectID: UUID? = nil,
        failureCode: ImportFailureCode? = nil,
        memberID: FamilyMember.ID? = nil
    ) {
        self.id = id
        self.sources = sources
        self.state = state
        self.revision = revision
        self.attemptID = attemptID
        self.documentObjectID = documentObjectID
        self.failureCode = failureCode
        self.memberID = memberID
    }

    /// Compatibility initializer for the existing one-file import path.
    public init(
        id: UUID = UUID(),
        attachmentID: Attachment.ID,
        state: ImportState = .staging,
        revision: UInt64 = 0,
        attemptID: UUID? = nil,
        documentObjectID: UUID? = nil,
        failureCode: ImportFailureCode? = nil,
        memberID: FamilyMember.ID? = nil
    ) {
        self.id = id
        sources = .unnamedSinglePage(ownerID: id, attachmentID: attachmentID)
        self.state = state
        self.revision = revision
        self.attemptID = attemptID
        self.documentObjectID = documentObjectID
        self.failureCode = failureCode
        self.memberID = memberID
    }

    public var soleAttachmentID: Attachment.ID? {
        sources.soleSource?.attachmentID
    }

    public var isResumableAfterInterruption: Bool {
        state == .staging || state == .processing
    }

    public func startingProcessing(attemptID: UUID) throws -> Self {
        guard state == .staging || state == .failed || state == .processing else {
            throw ImportDraftError.invalidState
        }
        guard revision < UInt64.max else { throw ImportDraftError.invalidState }
        var copy = self
        copy.state = .processing
        copy.revision += 1
        copy.attemptID = attemptID
        copy.failureCode = nil
        return copy
    }

    public var isStructurallyValid: Bool {
        switch state {
        case .staging:
            return attemptID == nil && documentObjectID == nil && failureCode == nil
        case .processing:
            return attemptID != nil && documentObjectID == nil && failureCode == nil
        case .needsReview:
            return attemptID == nil && documentObjectID != nil && failureCode == nil
        case .failed:
            return attemptID == nil && documentObjectID == nil && failureCode != nil
        case .confirmed, .discarded:
            return false
        }
    }

    public func completingProcessing(
        expectedRevision: UInt64,
        attemptID: UUID,
        documentObjectID: UUID
    ) throws -> Self {
        try validateLease(expectedRevision: expectedRevision, attemptID: attemptID)
        guard revision < UInt64.max else { throw ImportDraftError.invalidState }
        var copy = self
        copy.state = .needsReview
        copy.revision += 1
        copy.attemptID = nil
        copy.documentObjectID = documentObjectID
        copy.failureCode = nil
        return copy
    }

    public func failingProcessing(
        expectedRevision: UInt64,
        attemptID: UUID,
        failureCode: ImportFailureCode
    ) throws -> Self {
        try validateLease(expectedRevision: expectedRevision, attemptID: attemptID)
        guard revision < UInt64.max else { throw ImportDraftError.invalidState }
        var copy = self
        copy.state = .failed
        copy.revision += 1
        copy.attemptID = nil
        copy.failureCode = failureCode
        return copy
    }

    public func savingReview(
        expectedRevision: UInt64,
        memberID: FamilyMember.ID?,
        documentObjectID: UUID
    ) throws -> Self {
        guard state == .needsReview, revision < UInt64.max else {
            throw ImportDraftError.invalidState
        }
        guard revision == expectedRevision else { throw ImportDraftError.staleAttempt }
        var copy = self
        copy.revision += 1
        copy.memberID = memberID
        copy.documentObjectID = documentObjectID
        return copy
    }

    private func validateLease(expectedRevision: UInt64, attemptID: UUID) throws {
        guard state == .processing else { throw ImportDraftError.invalidState }
        guard revision == expectedRevision, self.attemptID == attemptID else {
            throw ImportDraftError.staleAttempt
        }
    }
}

public struct ImportDraftDocument: Codable, Equatable, Sendable {
    public let blocks: [OCRBlock]
    public let candidates: ReportCandidates
    public let candidateExtractionVersion: Int?
    public let reviewState: ImportDraftReviewState?

    public init(
        blocks: [OCRBlock],
        candidates: ReportCandidates,
        reviewState: ImportDraftReviewState? = nil
    ) {
        self.init(
            blocks: blocks,
            candidates: candidates,
            candidateExtractionVersion: ReportCandidateExtractor.extractionVersion,
            reviewState: reviewState
        )
    }

    public init(
        blocks: [OCRBlock],
        candidates: ReportCandidates,
        candidateExtractionVersion: Int?,
        reviewState: ImportDraftReviewState? = nil
    ) {
        self.blocks = blocks
        self.candidates = candidates
        self.candidateExtractionVersion = candidateExtractionVersion
        self.reviewState = reviewState
    }

    public func attributedAndValidated(for sources: ReportSources) throws -> Self {
        guard Set(blocks.map(\.id)).count == blocks.count else {
            throw DomainValidationError.duplicateIdentifier
        }
        let validatedBlocks = try blocks.map { try $0.attributedAndValidated(for: sources) }
        let validatedCandidates = try candidates.attributedAndValidated(for: sources)
        let blockByID = Dictionary(uniqueKeysWithValues: validatedBlocks.map { ($0.id, $0) })
        for reference in validatedCandidates.sourceFields.flatMap(\.references) {
            guard let blockID = reference.blockID else { continue }
            guard let block = blockByID[blockID],
                  reference.sourceID == block.sourceID,
                  reference.attachmentID == block.attachmentID,
                  reference.filePageNumber == block.filePageNumber,
                  reference.boundingBox == nil || reference.boundingBox == block.boundingBox else {
                throw DomainValidationError.invalidCatalogReference
            }
        }
        return Self(
            blocks: validatedBlocks,
            candidates: validatedCandidates,
            candidateExtractionVersion: candidateExtractionVersion,
            reviewState: reviewState
        )
    }
}

private extension ReportCandidates {
    var sourceFields: [SourceField] {
        [memberName, organization, department, reportType, title, reportedResults, conclusion]
            .compactMap { $0 }
            + dateCandidates.map(\.source)
            + abnormalItems
    }
}
