import Foundation
import Testing
@testable import KinlogueCore

@Test
func legacyImportDraftDocumentDecodesWithoutAnExtractionVersion() throws {
    let data = Data(#"{"blocks":[],"candidates":{"dateCandidates":[],"abnormalItems":[]}}"#.utf8)

    let document = try JSONDecoder().decode(ImportDraftDocument.self, from: data)

    #expect(document.candidateExtractionVersion == nil)
    #expect(document.reviewState == nil)
}

@Test
func importDraftDocumentReviewStateSurvivesACodableRoundTrip() throws {
    let manualDate = Date(timeIntervalSince1970: 1_784_419_200)
    let state = ImportDraftReviewState(
        timelineDateSelection: .manual(manualDate),
        title: "Synthetic title",
        organization: "Synthetic organization",
        department: "Synthetic department",
        reportType: "Synthetic type",
        reportedResults: "Synthetic results",
        conclusion: "Synthetic conclusion",
        abnormalItems: ["Synthetic abnormal item"],
        userNote: "Synthetic note"
    )
    let document = ImportDraftDocument(
        blocks: [],
        candidates: ReportCandidates(),
        reviewState: state
    )

    let reopened = try JSONDecoder().decode(
        ImportDraftDocument.self,
        from: JSONEncoder().encode(document)
    )

    #expect(reopened.reviewState == state)
}

@Test
func newImportDraftDocumentRecordsTheCurrentExtractionVersion() {
    let document = ImportDraftDocument(blocks: [], candidates: ReportCandidates())

    #expect(document.candidateExtractionVersion == ReportCandidateExtractor.extractionVersion)
}

@Test
func importDraftUsesAttemptAndRevisionToRejectStaleResults() throws {
    let attachmentID = UUID()
    let draft = ImportDraft(attachmentID: attachmentID)
    let attemptID = UUID()

    let lease = try draft.startingProcessing(attemptID: attemptID)

    #expect(lease.state == .processing)
    #expect(lease.revision == 1)
    #expect(lease.attemptID == attemptID)
    #expect(throws: ImportDraftError.staleAttempt) {
        _ = try lease.completingProcessing(
            expectedRevision: 0,
            attemptID: attemptID,
            documentObjectID: UUID()
        )
    }

    let documentObjectID = UUID()
    let completed = try lease.completingProcessing(
        expectedRevision: lease.revision,
        attemptID: attemptID,
        documentObjectID: documentObjectID
    )
    #expect(completed.state == .needsReview)
    #expect(completed.revision == 2)
    #expect(completed.attemptID == nil)
    #expect(completed.documentObjectID == documentObjectID)
}

@Test
func failedDraftCanRetryWithoutInventingAMember() throws {
    let initial = ImportDraft(attachmentID: UUID())
    let firstAttempt = try initial.startingProcessing(attemptID: UUID())
    let failed = try firstAttempt.failingProcessing(
        expectedRevision: firstAttempt.revision,
        attemptID: try #require(firstAttempt.attemptID),
        failureCode: .textExtractionFailed
    )

    #expect(failed.state == .failed)
    #expect(failed.memberID == nil)

    let retry = try failed.startingProcessing(attemptID: UUID())
    #expect(retry.state == .processing)
    #expect(retry.revision == failed.revision + 1)
    #expect(retry.memberID == nil)
}

@Test
func importDraftDocumentRejectsDuplicateBlockIdentifiers() throws {
    let source = try ReportSource(attachmentID: UUID(), pageCount: 1)
    let sources = try ReportSources([source])
    let blockID = UUID()
    let first = try attributedBlock(id: blockID, source: source)
    let second = try attributedBlock(id: blockID, source: source, text: "Second")

    #expect(throws: DomainValidationError.duplicateIdentifier) {
        _ = try ImportDraftDocument(
            blocks: [first, second],
            candidates: ReportCandidates()
        ).attributedAndValidated(for: sources)
    }
}

@Test
func importDraftDocumentRejectsDuplicateDateCandidateIdentifiersBeforePresentation() throws {
    let source = try ReportSource(attachmentID: UUID(), pageCount: 1)
    let sources = try ReportSources([source])
    let candidateID = UUID(uuidString: "00000000-0000-0000-0000-0000000000D2")!
    let field = try SourceField(originalTranscription: "Synthetic date")
    let first = ReportDateCandidate(
        id: candidateID,
        date: Date(timeIntervalSince1970: 1_700_000_000),
        kind: .examination,
        source: field
    )
    let duplicate = ReportDateCandidate(
        id: candidateID,
        date: Date(timeIntervalSince1970: 1_700_086_400),
        kind: .report,
        source: field
    )
    let document = ImportDraftDocument(
        blocks: [],
        candidates: ReportCandidates(dateCandidates: [first, duplicate])
    )

    #expect(throws: DomainValidationError.duplicateIdentifier) {
        _ = try document.attributedAndValidated(for: sources)
    }
}

@Test
func importDraftDocumentValidatesEveryBlockReferenceAgainstItsProvenanceAndBounds() throws {
    let source = try ReportSource(attachmentID: UUID(), pageCount: 1)
    let foreign = try ReportSource(attachmentID: UUID(), pageCount: 1)
    let sources = try ReportSources([source, foreign])
    let block = try attributedBlock(source: source)

    func document(reference: SourceReference) throws -> ImportDraftDocument {
        ImportDraftDocument(
            blocks: [block],
            candidates: ReportCandidates(conclusion: try SourceField(
                originalTranscription: "Synthetic",
                references: [reference]
            ))
        )
    }

    let validReference = try SourceReference(
        sourceID: source.id,
        attachmentID: source.attachmentID,
        filePageNumber: 1,
        boundingBox: block.boundingBox,
        blockID: block.id
    )
    _ = try document(reference: validReference).attributedAndValidated(for: sources)

    let missingBlock = try SourceReference(
        sourceID: source.id,
        attachmentID: source.attachmentID,
        filePageNumber: 1,
        boundingBox: block.boundingBox,
        blockID: UUID()
    )
    #expect(throws: DomainValidationError.invalidCatalogReference) {
        _ = try document(reference: missingBlock).attributedAndValidated(for: sources)
    }

    let foreignSource = try SourceReference(
        sourceID: foreign.id,
        attachmentID: foreign.attachmentID,
        filePageNumber: 1,
        boundingBox: block.boundingBox,
        blockID: block.id
    )
    #expect(throws: DomainValidationError.invalidCatalogReference) {
        _ = try document(reference: foreignSource).attributedAndValidated(for: sources)
    }

    let wrongBounds = try SourceReference(
        sourceID: source.id,
        attachmentID: source.attachmentID,
        filePageNumber: 1,
        boundingBox: NormalizedRect(x: 0, y: 0, width: 0.1, height: 0.1),
        blockID: block.id
    )
    #expect(throws: DomainValidationError.invalidCatalogReference) {
        _ = try document(reference: wrongBounds).attributedAndValidated(for: sources)
    }
}

private func attributedBlock(
    id: UUID = UUID(),
    source: ReportSource,
    text: String = "Synthetic"
) throws -> OCRBlock {
    try OCRBlock(
        id: id,
        sourceID: source.id,
        attachmentID: source.attachmentID,
        filePageNumber: 1,
        text: text,
        boundingBox: NormalizedRect(x: 0.1, y: 0.7, width: 0.4, height: 0.1),
        confidence: 1,
        method: .vision,
        engineVersion: "synthetic"
    )
}
