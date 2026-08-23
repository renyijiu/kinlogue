import Foundation
import Testing
@testable import KinlogueCore

@Test
func needsReviewStudyCannotPersistConfirmationFields() throws {
    let indexID = UUID()
    let attachment = try syntheticAttachment()
    let fingerprint = try DICOMStudyFingerprint(objects: [
        .init(sha256Digest: attachment.sha256Digest, byteCount: attachment.byteCount),
    ])

    #expect(throws: DomainValidationError.invalidStateTransition) {
        _ = try DICOMStudy(
            id: UUID(),
            state: .needsReview,
            fingerprint: fingerprint,
            indexObjectID: indexID,
            attachmentIDs: [attachment.id],
            confirmedMemberID: UUID(),
            effectiveDate: Date(timeIntervalSince1970: 0)
        )
    }
}

@Test
func confirmedStudyRequiresMemberAndEffectiveDateTogether() throws {
    let attachment = try syntheticAttachment()
    let fingerprint = try DICOMStudyFingerprint(objects: [
        .init(sha256Digest: attachment.sha256Digest, byteCount: attachment.byteCount),
    ])

    #expect(throws: DomainValidationError.invalidStateTransition) {
        _ = try DICOMStudy(
            state: .confirmed,
            fingerprint: fingerprint,
            indexObjectID: UUID(),
            attachmentIDs: [attachment.id],
            confirmedMemberID: UUID(),
            effectiveDate: nil
        )
    }
}

@Test
func reconfirmingPreservesStudyIdentityAndImmutableGraph() throws {
    let attachment = try syntheticAttachment()
    let fingerprint = try DICOMStudyFingerprint(objects: [
        .init(sha256Digest: attachment.sha256Digest, byteCount: attachment.byteCount),
    ])
    let study = try DICOMStudy(
        state: .needsReview,
        fingerprint: fingerprint,
        indexObjectID: UUID(),
        attachmentIDs: [attachment.id]
    )
    let memberID = UUID()
    let confirmed = try study.confirmed(memberID: memberID, effectiveDate: Date(timeIntervalSince1970: 0))

    #expect(confirmed.id == study.id)
    #expect(confirmed.fingerprint == study.fingerprint)
    #expect(confirmed.indexObjectID == study.indexObjectID)
    #expect(confirmed.attachmentIDs == study.attachmentIDs)
    #expect(confirmed.confirmedMemberID == memberID)
}

@Test
func fingerprintIsVersionedAndOrderIndependentButRejectsDuplicates() throws {
    let first = try DICOMStudyFingerprint.ObjectDigest(
        sha256Digest: Data(repeating: 0x01, count: 32),
        byteCount: 3
    )
    let second = try DICOMStudyFingerprint.ObjectDigest(
        sha256Digest: Data(repeating: 0x02, count: 32),
        byteCount: 5
    )

    let ordered = try DICOMStudyFingerprint(objects: [first, second])
    let reversed = try DICOMStudyFingerprint(objects: [second, first])
    #expect(ordered == reversed)
    #expect(ordered.domain == "kinlogue.dicom.study-fingerprint")
    #expect(ordered.uniqueObjectCount == 2)
    #expect(ordered.canonicalIdentityBytes == reversed.canonicalIdentityBytes)
    #expect(!ordered.canonicalIdentityBytes.isEmpty)
    #expect(throws: DomainValidationError.duplicateIdentifier) {
        _ = try DICOMStudyFingerprint(objects: [first, first])
    }
}

@Test
func catalogRejectsDuplicateDICOMStudyFingerprint() throws {
    let attachment = try syntheticAttachment()
    let fingerprint = try DICOMStudyFingerprint(objects: [
        .init(sha256Digest: attachment.sha256Digest, byteCount: attachment.byteCount),
    ])
    let first = try DICOMStudy(state: .needsReview, fingerprint: fingerprint, indexObjectID: UUID(), attachmentIDs: [attachment.id])
    let second = try DICOMStudy(state: .needsReview, fingerprint: fingerprint, indexObjectID: UUID(), attachmentIDs: [attachment.id])
    #expect(throws: DomainValidationError.duplicateIdentifier) {
        _ = try VaultCatalog(vaultID: UUID(), generation: 1, attachments: [attachment], dicomStudies: [first, second])
    }
}

@Test
func studyObjectLimitAcceptsTwoThousandAndRejectsTheNextObject() throws {
    let digests = try (0..<DICOMStudy.maximumAttachmentCount).map {
        try DICOMStudyFingerprint.ObjectDigest(
            sha256Digest: syntheticDigest($0),
            byteCount: $0 + 1
        )
    }

    let boundary = try DICOMStudyFingerprint(objects: digests)
    #expect(boundary.uniqueObjectCount == 2_000)
    #expect(throws: DomainValidationError.invalidCatalogReference) {
        _ = try DICOMStudyFingerprint(objects: digests + [
            .init(sha256Digest: syntheticDigest(2_000), byteCount: 2_001),
        ])
    }
}

@Test
func catalogStudyLimitAcceptsTwoHundredFiftySixAndRejectsTheNextStudy() throws {
    let graph = try syntheticStudyGraph(studyCount: VaultCatalog.maximumDICOMStudyCount)
    let boundary = try VaultCatalog(
        vaultID: UUID(),
        generation: 1,
        attachments: graph.attachments,
        dicomStudies: graph.studies
    )
    #expect(boundary.dicomStudies.count == 256)

    let extra = try syntheticStudyGraph(
        studyCount: 1,
        startingOrdinal: VaultCatalog.maximumDICOMStudyCount
    )
    #expect(throws: DomainValidationError.invalidCatalogReference) {
        _ = try VaultCatalog(
            vaultID: UUID(),
            generation: 1,
            attachments: graph.attachments + extra.attachments,
            dicomStudies: graph.studies + extra.studies
        )
    }
}

@Test
func catalogRetainedDICOMObjectLimitAcceptsTenThousandAndRejectsTheNextObject() throws {
    let boundaryGraph = try syntheticStudyGraph(studyCount: 5, objectsPerStudy: 2_000)
    let boundary = try VaultCatalog(
        vaultID: UUID(),
        generation: 1,
        attachments: boundaryGraph.attachments,
        dicomStudies: boundaryGraph.studies
    )
    #expect(Set(boundary.dicomStudies.flatMap(\.attachmentIDs)).count == 10_000)

    let extra = try syntheticStudyGraph(studyCount: 1, startingOrdinal: 10_000)
    #expect(throws: DomainValidationError.invalidCatalogReference) {
        _ = try VaultCatalog(
            vaultID: UUID(),
            generation: 1,
            attachments: boundaryGraph.attachments + extra.attachments,
            dicomStudies: boundaryGraph.studies + extra.studies
        )
    }
}

private func syntheticAttachment() throws -> KinlogueCore.Attachment {
    try KinlogueCore.Attachment(
        contentTypeIdentifier: "application/dicom",
        byteCount: 12,
        sha256Digest: Data(repeating: 0xA1, count: 32)
    )
}

private func syntheticStudyGraph(
    studyCount: Int,
    objectsPerStudy: Int = 1,
    startingOrdinal: Int = 0
) throws -> (attachments: [KinlogueCore.Attachment], studies: [DICOMStudy]) {
    var attachments: [KinlogueCore.Attachment] = []
    var studies: [DICOMStudy] = []
    attachments.reserveCapacity(studyCount * objectsPerStudy)
    studies.reserveCapacity(studyCount)
    for studyOrdinal in 0..<studyCount {
        let firstObjectOrdinal = startingOrdinal + studyOrdinal * objectsPerStudy
        var owned: [KinlogueCore.Attachment] = []
        owned.reserveCapacity(objectsPerStudy)
        for offset in 0..<objectsPerStudy {
            let ordinal = firstObjectOrdinal + offset
            owned.append(try KinlogueCore.Attachment(
                contentTypeIdentifier: "application/dicom",
                byteCount: ordinal + 1,
                sha256Digest: syntheticDigest(ordinal)
            ))
        }
        let fingerprint = try DICOMStudyFingerprint(objects: owned.map {
            try DICOMStudyFingerprint.ObjectDigest(
                sha256Digest: $0.sha256Digest,
                byteCount: $0.byteCount
            )
        })
        studies.append(try DICOMStudy(
            state: .needsReview,
            fingerprint: fingerprint,
            indexObjectID: UUID(),
            attachmentIDs: owned.map(\.id)
        ))
        attachments.append(contentsOf: owned)
    }
    return (attachments, studies)
}

private func syntheticDigest(_ ordinal: Int) -> Data {
    var digest = Data(repeating: 0, count: 32)
    var value = UInt64(ordinal).bigEndian
    withUnsafeBytes(of: &value) { digest.replaceSubrange(24..<32, with: $0) }
    return digest
}
