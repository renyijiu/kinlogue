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
func duplicateDetectorPrefersExistingRecordThenDraft() throws {
    let digest = Data(repeating: 0x5A, count: 32)
    let attachment = try Attachment(
        contentTypeIdentifier: "public.png",
        byteCount: 10,
        sha256Digest: digest
    )
    let member = try FamilyMember(displayName: "Synthetic Member")
    let record = try HealthRecord(
        memberID: member.id,
        attachmentID: attachment.id,
        importState: .confirmed
    )
    let draft = ImportDraft(
        attachmentID: attachment.id,
        state: .needsReview,
        documentObjectID: UUID()
    )
    let fingerprint = try ReportFingerprint(sources: [
        .init(sha256Digest: digest, byteCount: attachment.byteCount),
    ])

    #expect(
        DuplicateDetector.find(
            fingerprint: fingerprint,
            attachments: [attachment],
            records: [record],
            drafts: [draft]
        ) == .record(record.id)
    )
    #expect(
        DuplicateDetector.find(
            fingerprint: fingerprint,
            attachments: [attachment],
            records: [],
            drafts: [draft]
        ) == .draft(draft.id)
    )
    let staging = ImportDraft(attachmentID: attachment.id)
    #expect(DuplicateDetector.find(
        fingerprint: fingerprint,
        attachments: [attachment],
        records: [],
        drafts: [staging]
    ) == nil)
}

@Test
func duplicateDetectorUsesTheCompleteMultisetAndStableClassTieBreaks() throws {
    let member = try FamilyMember(displayName: "Synthetic")
    let first = try Attachment(
        id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
        contentTypeIdentifier: "public.png",
        byteCount: 10,
        sha256Digest: Data(repeating: 0x11, count: 32)
    )
    let second = try Attachment(
        id: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
        contentTypeIdentifier: "public.png",
        byteCount: 20,
        sha256Digest: Data(repeating: 0x22, count: 32)
    )
    let sourceA = try ReportSource(attachmentID: first.id, displayName: "a.png", pageCount: 1)
    let sourceB = try ReportSource(attachmentID: second.id, displayName: "b.png", pageCount: 1)
    let lowerID = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
    let higherID = UUID(uuidString: "30000000-0000-0000-0000-000000000002")!
    let higher = try HealthRecord(
        id: higherID,
        memberID: member.id,
        sources: ReportSources([sourceA, sourceB]),
        importState: .confirmed
    )
    let lower = try HealthRecord(
        id: lowerID,
        memberID: member.id,
        sources: ReportSources([sourceB, sourceA]),
        importState: .confirmed
    )
    let fingerprint = try ReportFingerprint(
        sources: higher.sources,
        attachments: [first, second]
    )

    #expect(DuplicateDetector.find(
        fingerprint: fingerprint,
        attachments: [first, second],
        records: [higher, lower],
        drafts: []
    ) == .record(lowerID))

    let repeated = try ReportSources([sourceA, try ReportSource(
        attachmentID: first.id,
        displayName: "a-copy.png",
        pageCount: 1
    ), sourceB])
    #expect(try ReportFingerprint(sources: repeated, attachments: [first, second]) != fingerprint)
}

@Test
func catalogAcceptsAnUnassignedImportDraftWithAnAttachment() throws {
    let attachment = try Attachment(
        contentTypeIdentifier: "public.png",
        byteCount: 4,
        sha256Digest: Data(repeating: 1, count: 32)
    )
    let draft = ImportDraft(attachmentID: attachment.id)

    let catalog = try VaultCatalog(
        vaultID: UUID(),
        generation: 2,
        attachments: [attachment],
        importDrafts: [draft]
    )

    #expect(catalog.importDrafts == [draft])
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
