import Foundation
import Testing
@testable import KinlogueCore

@Test
func deletingRecordRemovesItsUnsharedAttachmentAndAdvancesGeneration() throws {
    let fixture = try DeletionFixture()
    let ocrObjectID = UUID()
    let record = try fixture.record(
        attachmentID: fixture.firstAttachment.id,
        ocrDocumentObjectID: ocrObjectID
    )
    let catalog = try fixture.catalog(
        records: [record],
        attachments: [fixture.firstAttachment]
    )

    let deleted = try catalog.deletingRecord(id: record.id)

    #expect(deleted.generation == catalog.generation + 1)
    #expect(deleted.records.isEmpty)
    #expect(deleted.attachments.isEmpty)
    #expect(deleted.members == catalog.members)
    #expect(!deleted.reachableObjectReferences.contains {
        $0.id == ocrObjectID && $0.kind == VaultObjectKind.ocr
    })
}

@Test
func deletingRecordKeepsAnAttachmentSharedByAnotherRecord() throws {
    let fixture = try DeletionFixture()
    let deletedRecord = try fixture.record(attachmentID: fixture.firstAttachment.id)
    let retainedRecord = try fixture.record(attachmentID: fixture.firstAttachment.id)
    let catalog = try fixture.catalog(
        records: [deletedRecord, retainedRecord],
        attachments: [fixture.firstAttachment]
    )

    let deleted = try catalog.deletingRecord(id: deletedRecord.id)

    #expect(deleted.records == [retainedRecord])
    #expect(deleted.attachments == [fixture.firstAttachment])
}

@Test
func deletingRecordKeepsAnAttachmentReferencedByADraft() throws {
    let fixture = try DeletionFixture()
    let record = try fixture.record(attachmentID: fixture.firstAttachment.id)
    let draft = ImportDraft(
        attachmentID: fixture.firstAttachment.id,
        memberID: fixture.firstMember.id
    )
    let catalog = try fixture.catalog(
        records: [record],
        attachments: [fixture.firstAttachment],
        drafts: [draft]
    )

    let deleted = try catalog.deletingRecord(id: record.id)

    #expect(deleted.records.isEmpty)
    #expect(deleted.attachments == [fixture.firstAttachment])
    #expect(deleted.importDrafts == [draft])
}

@Test
func deletingAMultiSourceRecordReclaimsOnlyItsFinalAttachmentEdges() throws {
    let fixture = try DeletionFixture()
    let deletedRecord = try HealthRecord(
        memberID: fixture.firstMember.id,
        sources: ReportSources([
            try ReportSource(
                attachmentID: fixture.firstAttachment.id,
                displayName: "unique.png",
                pageCount: 1
            ),
            try ReportSource(
                attachmentID: fixture.secondAttachment.id,
                displayName: "shared.png",
                pageCount: 1
            ),
        ]),
        importState: .confirmed
    )
    let retainedRecord = try HealthRecord(
        memberID: fixture.firstMember.id,
        sources: ReportSources([try ReportSource(
            attachmentID: fixture.secondAttachment.id,
            displayName: "same-object-other-owner.png",
            pageCount: 1
        )]),
        importState: .confirmed
    )
    let catalog = try fixture.catalog(
        records: [deletedRecord, retainedRecord],
        attachments: [fixture.firstAttachment, fixture.secondAttachment]
    )

    let deleted = try catalog.deletingRecord(id: deletedRecord.id)

    #expect(deleted.records == [retainedRecord])
    #expect(deleted.attachments == [fixture.secondAttachment])
}

@Test
func deletingMemberReportsOnlyReferenceCountsAndDoesNotMutateCatalog() throws {
    let fixture = try DeletionFixture()
    let record = try fixture.record(attachmentID: fixture.firstAttachment.id)
    let draft = ImportDraft(
        attachmentID: fixture.secondAttachment.id,
        memberID: fixture.firstMember.id
    )
    let catalog = try fixture.catalog(
        records: [record],
        attachments: [fixture.firstAttachment, fixture.secondAttachment],
        drafts: [draft]
    )

    #expect(throws: CatalogDeletionError.memberStillReferenced(
        recordCount: 1,
        draftCount: 1
    )) {
        _ = try catalog.deletingMember(id: fixture.firstMember.id)
    }
    #expect(catalog.members == [fixture.firstMember])
    #expect(catalog.generation == 7)
}

@Test
func deletingMissingRecordOrMemberReturnsContentFreeErrors() throws {
    let fixture = try DeletionFixture()
    let catalog = try fixture.catalog()

    #expect(throws: CatalogDeletionError.recordNotFound) {
        _ = try catalog.deletingRecord(id: UUID())
    }
    #expect(throws: CatalogDeletionError.memberNotFound) {
        _ = try catalog.deletingMember(id: UUID())
    }
}

@Test
func deletingTheLastUnreferencedMemberProducesAValidEmptyCatalog() throws {
    let fixture = try DeletionFixture()
    let catalog = try fixture.catalog()

    let deleted = try catalog.deletingMember(id: fixture.firstMember.id)

    #expect(deleted.members.isEmpty)
    #expect(deleted.records.isEmpty)
    #expect(deleted.importDrafts.isEmpty)
    #expect(deleted.generation == 8)
    try deleted.validate()
}

@Test
func deletionRejectsGenerationOverflowWithoutTrapping() throws {
    let fixture = try DeletionFixture()
    let catalog = try fixture.catalog(generation: UInt64.max)

    #expect(throws: CatalogDeletionError.generationExhausted) {
        _ = try catalog.deletingMember(id: fixture.firstMember.id)
    }
}

@Test
func dicomStudyOwnsItsIndexAndAttachmentsAndBlocksConfirmedMemberDeletion() throws {
    let fixture = try DeletionFixture()
    let fingerprint = try DICOMStudyFingerprint(objects: [
        .init(
            sha256Digest: fixture.firstAttachment.sha256Digest,
            byteCount: fixture.firstAttachment.byteCount
        ),
    ])
    let indexID = UUID()
    let study = try DICOMStudy(
        state: .confirmed,
        fingerprint: fingerprint,
        indexObjectID: indexID,
        attachmentIDs: [fixture.firstAttachment.id],
        confirmedMemberID: fixture.firstMember.id,
        effectiveDate: Date(timeIntervalSince1970: 0)
    )
    let catalog = try fixture.catalog(
        attachments: [fixture.firstAttachment],
        dicomStudies: [study]
    )

    #expect(catalog.reachableObjectReferences.contains(
        VaultObjectReference(id: indexID, kind: .record)
    ))
    #expect(throws: CatalogDeletionError.memberStillReferencedByDICOMStudy(studyCount: 1)) {
        _ = try catalog.deletingMember(id: fixture.firstMember.id)
    }

    let deleted = try catalog.deletingDICOMStudy(id: study.id)
    #expect(deleted.dicomStudies.isEmpty)
    #expect(deleted.attachments.isEmpty)
    #expect(!deleted.reachableObjectReferences.contains(
        VaultObjectReference(id: indexID, kind: .record)
    ))
}

@Test
func sharedDICOMAttachmentIsRemovedOnlyAfterItsLastOwnerDisappears() throws {
    let fixture = try DeletionFixture()
    let record = try fixture.record(attachmentID: fixture.firstAttachment.id)
    let fingerprint = try DICOMStudyFingerprint(objects: [
        .init(
            sha256Digest: fixture.firstAttachment.sha256Digest,
            byteCount: fixture.firstAttachment.byteCount
        ),
    ])
    let study = try DICOMStudy(
        state: .needsReview,
        fingerprint: fingerprint,
        indexObjectID: UUID(),
        attachmentIDs: [fixture.firstAttachment.id]
    )
    let catalog = try fixture.catalog(
        records: [record],
        attachments: [fixture.firstAttachment],
        dicomStudies: [study]
    )

    let recordDeleted = try catalog.deletingRecord(id: record.id)
    #expect(recordDeleted.attachments == [fixture.firstAttachment])
    let studyDeleted = try recordDeleted.deletingDICOMStudy(id: study.id)
    #expect(studyDeleted.attachments.isEmpty)
}

@Test
func deletingDICOMStudyLeavesUnrelatedOrdinaryCatalogAttachmentsUntouched() throws {
    let fixture = try DeletionFixture()
    let fingerprint = try DICOMStudyFingerprint(objects: [
        .init(
            sha256Digest: fixture.firstAttachment.sha256Digest,
            byteCount: fixture.firstAttachment.byteCount
        ),
    ])
    let study = try DICOMStudy(
        state: .needsReview,
        fingerprint: fingerprint,
        indexObjectID: UUID(),
        attachmentIDs: [fixture.firstAttachment.id]
    )
    let catalog = try fixture.catalog(
        attachments: [fixture.firstAttachment, fixture.secondAttachment],
        dicomStudies: [study]
    )

    let deleted = try catalog.deletingDICOMStudy(id: study.id)

    #expect(deleted.dicomStudies.isEmpty)
    #expect(deleted.attachments == [fixture.secondAttachment])
}

private struct DeletionFixture {
    let firstMember: FamilyMember
    let firstAttachment: KinlogueCore.Attachment
    let secondAttachment: KinlogueCore.Attachment
    let vaultID = UUID()

    init() throws {
        firstMember = try FamilyMember(displayName: "Synthetic member")
        firstAttachment = try KinlogueCore.Attachment(
            contentTypeIdentifier: "public.jpeg",
            byteCount: 11,
            sha256Digest: Data(repeating: 0x11, count: 32)
        )
        secondAttachment = try KinlogueCore.Attachment(
            contentTypeIdentifier: "public.png",
            byteCount: 13,
            sha256Digest: Data(repeating: 0x22, count: 32)
        )
    }

    func record(
        attachmentID: KinlogueCore.Attachment.ID,
        ocrDocumentObjectID: UUID? = nil
    ) throws -> HealthRecord {
        try HealthRecord(
            memberID: firstMember.id,
            attachmentID: attachmentID,
            ocrDocumentObjectID: ocrDocumentObjectID,
            importState: .confirmed
        )
    }

    func catalog(
        generation: UInt64 = 7,
        records: [HealthRecord] = [],
        attachments: [KinlogueCore.Attachment] = [],
        drafts: [ImportDraft] = [],
        dicomStudies: [DICOMStudy] = []
    ) throws -> VaultCatalog {
        try VaultCatalog(
            vaultID: vaultID,
            generation: generation,
            members: [firstMember],
            records: records,
            attachments: attachments,
            importDrafts: drafts,
            dicomStudies: dicomStudies
        )
    }
}
