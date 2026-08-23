import Foundation
import Testing
@testable import KinlogueCore

@Test
func domainModelsRoundTripWithoutLosingProvenance() throws {
    let member = try FamilyMember(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        displayName: "Member",
        disambiguationLabel: "Household A"
    )
    let attachment = try Attachment(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        contentTypeIdentifier: "public.png",
        byteCount: 64,
        sha256Digest: Data(repeating: 0x2A, count: 32)
    )
    let bounds = try NormalizedRect(x: 0.1, y: 0.2, width: 0.7, height: 0.1)
    let block = try OCRBlock(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
        pageNumber: 1,
        text: "Synthetic source text",
        boundingBox: bounds,
        confidence: 0.9,
        method: .vision,
        engineVersion: "test-engine"
    )
    let source = try SourceField(
        originalTranscription: "Original source",
        correctedTranscription: "Corrected source",
        references: [try SourceReference(pageNumber: 1, boundingBox: bounds, blockID: block.id)]
    )
    let candidate = ReportDateCandidate(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
        date: Date(timeIntervalSince1970: 1_700_000_000),
        kind: .report,
        source: source
    )
    let record = try HealthRecord(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
        memberID: member.id,
        attachmentID: attachment.id,
        importState: .confirmed,
        revision: 7,
        title: source,
        dateCandidates: [candidate],
        timelineDateCandidateID: candidate.id,
        conclusion: source,
        notes: [try UserNote(text: "Separate user note")]
    )
    let catalog = try VaultCatalog(
        vaultID: UUID(uuidString: "00000000-0000-0000-0000-000000000006")!,
        generation: 7,
        members: [member],
        records: [record],
        attachments: [attachment]
    )

    let encoded = try JSONEncoder().encode(catalog)
    let decoded = try JSONDecoder().decode(VaultCatalog.self, from: encoded)

    #expect(decoded == catalog)
    #expect(decoded.records[0].revision == 7)
    #expect(decoded.records[0].timelineDate == candidate.date)
    #expect(decoded.records[0].conclusion?.transcription == "Corrected source")
    #expect(block.referencesSource(pageNumber: 1, boundingBox: bounds))
}

@Test
func healthRecordDecodingDefaultsARevisionMissingFromAnExistingCatalog() throws {
    let member = try FamilyMember(displayName: "Synthetic member")
    let attachment = try Attachment(
        contentTypeIdentifier: "public.png",
        byteCount: 4,
        sha256Digest: Data(repeating: 0x2B, count: 32)
    )
    let record = try HealthRecord(
        memberID: member.id,
        attachmentID: attachment.id,
        importState: .confirmed,
        revision: 9
    )
    let encoded = try JSONEncoder().encode(record)
    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(object.removeValue(forKey: "revision") != nil)

    let legacyData = try JSONSerialization.data(withJSONObject: object)
    let decoded = try JSONDecoder().decode(HealthRecord.self, from: legacyData)

    #expect(decoded.revision == 0)
}

@Test
func normalizedRectDecodingPreservesWireKeysAndRejectsInvalidBounds() throws {
    let valid = try NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
    let encoded = try JSONEncoder().encode(valid)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

    #expect(Set(object.keys) == ["x", "y", "width", "height"])
    #expect(try JSONDecoder().decode(NormalizedRect.self, from: encoded) == valid)

    let invalid = Data(#"{"x":0.9,"y":0.2,"width":0.2,"height":0.4}"#.utf8)
    do {
        _ = try JSONDecoder().decode(NormalizedRect.self, from: invalid)
        Issue.record("Out-of-range normalized bounds decoded successfully")
    } catch DecodingError.dataCorrupted {
        // Expected: decoded values must pass the same invariant as direct construction.
    } catch {
        Issue.record("Invalid bounds produced the wrong decoding error: \(error)")
    }
}

@Test
func catalogDecodingRejectsInvalidGenerationReferencesAndSelection() throws {
    let member = try FamilyMember(displayName: "Member")
    let attachment = try Attachment(
        contentTypeIdentifier: "public.png",
        byteCount: 4,
        sha256Digest: Data(repeating: 0x1A, count: 32)
    )
    let candidate = ReportDateCandidate(
        date: Date(timeIntervalSince1970: 1_700_000_000),
        kind: .report,
        source: try SourceField(originalTranscription: "Synthetic date")
    )
    let record = try HealthRecord(
        memberID: member.id,
        attachmentID: attachment.id,
        importState: .confirmed,
        dateCandidates: [candidate],
        timelineDateCandidateID: candidate.id
    )
    let catalog = try VaultCatalog(
        vaultID: UUID(),
        generation: 1,
        members: [member],
        records: [record],
        attachments: [attachment]
    )
    let encoded = try JSONEncoder().encode(catalog)
    let validObject = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

    var invalidGeneration = validObject
    invalidGeneration["generation"] = 0

    var invalidReference = validObject
    var records = try #require(invalidReference["records"] as? [[String: Any]])
    records[0]["memberID"] = UUID().uuidString
    invalidReference["records"] = records

    var invalidSelection = validObject
    records = try #require(invalidSelection["records"] as? [[String: Any]])
    records[0]["timelineDateCandidateID"] = UUID().uuidString
    invalidSelection["records"] = records

    var duplicateIdentifier = validObject
    var members = try #require(duplicateIdentifier["members"] as? [[String: Any]])
    members.append(members[0])
    duplicateIdentifier["members"] = members

    for invalidObject in [invalidGeneration, invalidReference, invalidSelection, duplicateIdentifier] {
        let invalidData = try JSONSerialization.data(withJSONObject: invalidObject)
        do {
            _ = try JSONDecoder().decode(VaultCatalog.self, from: invalidData)
            Issue.record("Invalid catalog decoded successfully")
        } catch {
            // Expected: decoding must route through catalog validation.
        }
    }

    var mutatedCatalog = catalog
    mutatedCatalog.records[0].timelineDateCandidateID = UUID()
    do {
        _ = try JSONEncoder().encode(mutatedCatalog)
        Issue.record("Invalid catalog encoded successfully")
    } catch {
        // Expected: persistence must validate even after in-memory mutation.
    }
}

@Test
func healthRecordRejectsDuplicateDateCandidateIdentifiersAtEveryPersistenceBoundary() throws {
    let candidateID = UUID(uuidString: "00000000-0000-0000-0000-0000000000D1")!
    let first = ReportDateCandidate(
        id: candidateID,
        date: Date(timeIntervalSince1970: 1_700_000_000),
        kind: .examination,
        source: try SourceField(originalTranscription: "Synthetic examination date")
    )
    let duplicate = ReportDateCandidate(
        id: candidateID,
        date: Date(timeIntervalSince1970: 1_700_086_400),
        kind: .report,
        source: try SourceField(originalTranscription: "Synthetic report date")
    )

    #expect(throws: DomainValidationError.duplicateIdentifier) {
        _ = try makeRecord(
            importState: .confirmed,
            dateCandidates: [first, duplicate]
        )
    }

    var mutated = try makeRecord(
        importState: .confirmed,
        dateCandidates: [first]
    )
    let validData = try JSONEncoder().encode(mutated)
    var object = try #require(JSONSerialization.jsonObject(with: validData) as? [String: Any])
    var encodedCandidates = try #require(object["dateCandidates"] as? [[String: Any]])
    encodedCandidates.append(encodedCandidates[0])
    object["dateCandidates"] = encodedCandidates
    let duplicateData = try JSONSerialization.data(withJSONObject: object)

    #expect(throws: DecodingError.self) {
        _ = try JSONDecoder().decode(HealthRecord.self, from: duplicateData)
    }

    let member = try FamilyMember(
        id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
        displayName: "Synthetic Member"
    )
    let attachment = try Attachment(
        id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
        contentTypeIdentifier: "public.png",
        byteCount: 4,
        sha256Digest: Data(repeating: 0xD1, count: 32)
    )
    var mutatedCatalog = try VaultCatalog(
        vaultID: UUID(),
        generation: 1,
        members: [member],
        records: [mutated],
        attachments: [attachment]
    )
    mutatedCatalog.records[0].dateCandidates.append(first)
    #expect(throws: DomainValidationError.duplicateIdentifier) {
        try mutatedCatalog.validate()
    }
    #expect(throws: EncodingError.self) {
        _ = try JSONEncoder().encode(mutatedCatalog)
    }

    mutated.dateCandidates.append(first)
    #expect(throws: EncodingError.self) {
        _ = try JSONEncoder().encode(mutated)
    }
}

@Test
func missingAndUnselectedDatesRemainUnknown() throws {
    let record = try makeRecord(importState: .confirmed)
    let candidate = ReportDateCandidate(
        date: Date(timeIntervalSince1970: 1_700_000_000),
        kind: .collection,
        source: try SourceField(originalTranscription: "Source date")
    )
    let unselected = try makeRecord(importState: .confirmed, dateCandidates: [candidate])

    #expect(record.timelineDate == nil)
    #expect(unselected.timelineDate == nil)
    #expect(unselected.timelineDateCandidate == nil)
}

@Test
func selectedDatePreservesItsTypeAndSource() throws {
    let first = ReportDateCandidate(
        date: Date(timeIntervalSince1970: 1_600_000_000),
        kind: .collection,
        source: try SourceField(originalTranscription: "First source")
    )
    let selected = ReportDateCandidate(
        date: Date(timeIntervalSince1970: 1_700_000_000),
        kind: .report,
        source: try SourceField(originalTranscription: "Selected source")
    )
    let record = try makeRecord(
        importState: .confirmed,
        dateCandidates: [first, selected],
        timelineDateCandidateID: selected.id
    )

    #expect(record.timelineDateCandidate == selected)
    #expect(record.timelineDateCandidate?.kind == .report)
    #expect(record.timelineDateCandidate?.source.transcription == "Selected source")
}

@Test
func sourceCorrectionAndUserNoteRemainSeparate() throws {
    let original = try SourceField(originalTranscription: "Source")
    let field = try original
        .correctingTranscription(to: "Corrected source")
    let note = try UserNote(text: "User-authored note")
    let record = try makeRecord(importState: .confirmed, conclusion: field, notes: [note])

    #expect(record.conclusion?.originalTranscription == "Source")
    #expect(record.conclusion?.transcription == "Corrected source")
    #expect(record.notes.map(\.text) == ["User-authored note"])
    #expect(record.comparisonPresentation?.conclusion == .verbatim("Corrected source"))

    let restored = try field.correctingTranscription(to: " Source ")
    #expect(restored.originalTranscription == original.originalTranscription)
    #expect(restored.correctedTranscription == nil)
    #expect(restored.references == original.references)
}

@Test
func manuallyEnteredSourceFieldRoundTripsWithoutPretendingToBeOCR() throws {
    let original = try SourceField.manualEntry("Manually transcribed result")
    let corrected = try original.correctingTranscription(to: "Corrected manual result")

    let encoded = try JSONEncoder().encode(corrected)
    let decoded = try JSONDecoder().decode(SourceField.self, from: encoded)

    #expect(decoded.entryMethod == .manual)
    #expect(decoded.references.isEmpty)
    #expect(decoded.originalTranscription == "Manually transcribed result")
    #expect(decoded.transcription == "Corrected manual result")
}

@Test
func legacySourceFieldJSONDecodesAsRecognizedContent() throws {
    let data = Data(#"{"originalTranscription":"Legacy OCR","references":[]}"#.utf8)

    let decoded = try JSONDecoder().decode(SourceField.self, from: data)

    #expect(decoded.entryMethod == nil)
    #expect(decoded.transcription == "Legacy OCR")
}

@Test
func importStateAllowsOnlyDocumentedTransitions() {
    #expect(ImportState.staging.canTransition(to: .processing))
    #expect(ImportState.processing.canTransition(to: .needsReview))
    #expect(ImportState.needsReview.canTransition(to: .confirmed))
    #expect(ImportState.failed.canTransition(to: .processing))
    #expect(!ImportState.confirmed.canTransition(to: .processing))
    #expect(!ImportState.discarded.canTransition(to: .needsReview))
}

@Test
func reassignmentPreservesRecordAndAttachmentIdentity() throws {
    let record = try makeRecord(importState: .confirmed)
    let newMemberID = UUID()

    let reassigned = record.reassigned(to: newMemberID)

    #expect(reassigned.id == record.id)
    #expect(reassigned.sources == record.sources)
    #expect(reassigned.memberID == newMemberID)
}

private func makeRecord(
    importState: ImportState,
    dateCandidates: [ReportDateCandidate] = [],
    timelineDateCandidateID: ReportDateCandidate.ID? = nil,
    conclusion: SourceField? = nil,
    abnormalItems: [SourceField] = [],
    notes: [UserNote] = []
) throws -> HealthRecord {
    try HealthRecord(
        memberID: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
        attachmentID: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
        importState: importState,
        dateCandidates: dateCandidates,
        timelineDateCandidateID: timelineDateCandidateID,
        conclusion: conclusion,
        abnormalItems: abnormalItems,
        notes: notes
    )
}
