import Foundation
import Testing
@testable import KinlogueCore

@Test
func needsReviewStudyCannotPersistConfirmationFields() throws {
    let attachment = try syntheticAttachment()
    let fingerprint = try DICOMStudyFingerprint(objects: [
        .init(sha256Digest: attachment.sha256Digest, byteCount: attachment.byteCount),
    ])

    #expect(throws: DomainValidationError.invalidStateTransition) {
        _ = try DICOMStudyHeader(
            id: UUID(),
            state: .needsReview,
            fingerprint: fingerprint,
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
        _ = try DICOMStudyHeader(
            id: UUID(),
            state: .confirmed,
            fingerprint: fingerprint,
            attachmentIDs: [attachment.id],
            confirmedMemberID: UUID(),
            effectiveDate: nil
        )
    }
}

@Test
func studyHeaderRequiresOneDistinctAttachmentPerFingerprintObject() throws {
    let attachment = try syntheticAttachment()
    let fingerprint = try DICOMStudyFingerprint(objects: [
        .init(sha256Digest: attachment.sha256Digest, byteCount: attachment.byteCount),
    ])
    let memberID = UUID()
    let date = Date(timeIntervalSince1970: 0)

    let confirmed = try DICOMStudyHeader(
        id: UUID(), state: .confirmed, fingerprint: fingerprint, attachmentIDs: [attachment.id],
        confirmedMemberID: memberID, effectiveDate: date
    )
    #expect(confirmed.confirmedMemberID == memberID)
    #expect(confirmed.effectiveDate == date)
    for attachmentIDs in [[], [attachment.id, attachment.id], [attachment.id, UUID()]] {
        #expect(throws: DomainValidationError.invalidCatalogReference) {
            _ = try DICOMStudyHeader(id: UUID(), state: .needsReview, fingerprint: fingerprint, attachmentIDs: attachmentIDs)
        }
    }
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

private func syntheticAttachment() throws -> KinlogueCore.Attachment {
    try KinlogueCore.Attachment(
        contentTypeIdentifier: "application/dicom",
        byteCount: 12,
        sha256Digest: Data(repeating: 0xA1, count: 32)
    )
}


private func syntheticDigest(_ ordinal: Int) -> Data {
    var digest = Data(repeating: 0, count: 32)
    var value = UInt64(ordinal).bigEndian
    withUnsafeBytes(of: &value) { digest.replaceSubrange(24..<32, with: $0) }
    return digest
}
