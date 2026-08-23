import Foundation
import Testing
@testable import KinlogueCore

@Test
func reportSourcesRequireAUniqueNonemptyOrderedIdentity() throws {
    let attachmentID = UUID()
    let first = try ReportSource(
        id: UUID(),
        attachmentID: attachmentID,
        displayName: "page-a.png",
        pageCount: 1
    )
    let second = try ReportSource(
        id: UUID(),
        attachmentID: UUID(),
        displayName: "page-a-copy.png",
        pageCount: 2
    )

    let sources = try ReportSources([first, second])

    #expect(sources.elements == [first, second])
    #expect(sources.logicalPage(forSourceID: second.id, filePage: 2) == 3)
    #expect(sources.logicalPage(forSourceID: second.id, filePage: 3) == nil)
    #expect(throws: DomainValidationError.emptyReportSources) {
        _ = try ReportSources([])
    }
    #expect(throws: DomainValidationError.duplicateReportSourceIdentifier) {
        _ = try ReportSources([first, first])
    }

    let inconsistentRepeat = try ReportSource(
        attachmentID: attachmentID,
        displayName: "same-object.png",
        pageCount: 2
    )
    #expect(throws: DomainValidationError.invalidReportSourcePageCount) {
        _ = try ReportSources([first, inconsistentRepeat])
    }
}

@Test
func exactReportFingerprintIsOrderIndependentButPreservesMultiplicityAndLength() throws {
    let digestA = Data(repeating: 0x11, count: 32)
    let digestB = Data(repeating: 0x22, count: 32)
    let a = try ReportFingerprint.SourceDigest(sha256Digest: digestA, byteCount: 10)
    let b = try ReportFingerprint.SourceDigest(sha256Digest: digestB, byteCount: 20)

    #expect(try ReportFingerprint(sources: [a, b]) == ReportFingerprint(sources: [b, a]))
    #expect(try ReportFingerprint(sources: [a, a, b]) != ReportFingerprint(sources: [a, b]))
    #expect(try ReportFingerprint(sources: [a]) != ReportFingerprint(sources: [
        .init(sha256Digest: digestA, byteCount: 11),
    ]))
}

@Test
func oneFileCompatibilityUsesTheOwnerIDAsStableSourceIdentity() throws {
    let recordID = UUID()
    let draftID = UUID()
    let attachmentID = UUID()

    let firstRecord = try HealthRecord(
        id: recordID,
        memberID: UUID(),
        attachmentID: attachmentID,
        importState: .confirmed
    )
    let reopenedRecord = try HealthRecord(
        id: recordID,
        memberID: firstRecord.memberID,
        attachmentID: attachmentID,
        importState: .confirmed
    )
    let draft = ImportDraft(id: draftID, attachmentID: attachmentID)

    #expect(firstRecord.sources == reopenedRecord.sources)
    #expect(firstRecord.sources.first.id == recordID)
    #expect(draft.sources.first.id == draftID)
    #expect(firstRecord.sources.first.displayName == nil)
}

@Test
func persistedProvenanceRequiresSourceIdentityAndProjectsFromCurrentOrder() throws {
    let first = try ReportSource(attachmentID: UUID(), pageCount: 1)
    let second = try ReportSource(attachmentID: UUID(), pageCount: 2)
    let forward = try ReportSources([first, second])
    let reversed = try ReportSources([second, first])
    let bounds = try NormalizedRect(x: 0, y: 0, width: 1, height: 1)
    let block = try OCRBlock(
        sourceID: second.id,
        attachmentID: second.attachmentID,
        filePageNumber: 1,
        text: "Synthetic",
        boundingBox: bounds,
        confidence: nil,
        method: .vision,
        engineVersion: "synthetic"
    )

    #expect(try block.projected(for: forward).pageNumber == 2)
    #expect(try block.projected(for: reversed).pageNumber == 1)
    #expect(try block.projected(for: forward).filePageNumber == 1)
    let reference = try SourceReference(
        sourceID: second.id,
        attachmentID: second.attachmentID,
        filePageNumber: 1
    )
    #expect(reference.logicalPage(in: forward) == 2)
    #expect(reference.logicalPage(in: reversed) == 1)
    #expect(throws: EncodingError.self) {
        _ = try JSONEncoder().encode(block.projected(for: forward))
    }
    #expect(throws: EncodingError.self) {
        _ = try JSONEncoder().encode(SourceReference(pageNumber: 1))
    }
    #expect(throws: EncodingError.self) {
        _ = try JSONEncoder().encode(OCRBlock(
            pageNumber: 1,
            text: "Transient",
            boundingBox: bounds,
            confidence: nil,
            method: .vision,
            engineVersion: "synthetic"
        ))
    }
}

@Test
func logicalPageProjectionFailsSafelyOnIntegerOverflow() throws {
    let first = try ReportSource(attachmentID: UUID(), pageCount: Int.max)
    let second = try ReportSource(attachmentID: UUID(), pageCount: 1)
    let sources = try ReportSources([first, second])

    #expect(sources.logicalPage(forSourceID: second.id, filePage: 1) == nil)
}

@Test
func fingerprintRejectsDuplicateAttachmentMetadataIdentifiers() throws {
    let attachmentID = UUID()
    let source = try ReportSource(attachmentID: attachmentID, pageCount: 1)
    let first = try Attachment(
        id: attachmentID,
        contentTypeIdentifier: "public.png",
        byteCount: 1,
        sha256Digest: Data(repeating: 0x11, count: 32)
    )
    let second = try Attachment(
        id: attachmentID,
        contentTypeIdentifier: "public.png",
        byteCount: 2,
        sha256Digest: Data(repeating: 0x22, count: 32)
    )

    #expect(throws: DomainValidationError.invalidCatalogReference) {
        _ = try ReportFingerprint(
            sources: ReportSources([source]),
            attachments: [first, second]
        )
    }
}

@Test
func catalogRejectsConflictingPageCountsForTheSameAttachmentAcrossOwners() throws {
    let member = try FamilyMember(displayName: "Synthetic")
    let attachment = try Attachment(
        contentTypeIdentifier: "public.png",
        byteCount: 1,
        sha256Digest: Data(repeating: 0x33, count: 32)
    )
    let record = try HealthRecord(
        memberID: member.id,
        sources: ReportSources([try ReportSource(
            attachmentID: attachment.id,
            pageCount: 1
        )]),
        importState: .confirmed
    )
    let draft = ImportDraft(
        sources: try ReportSources([try ReportSource(
            attachmentID: attachment.id,
            pageCount: 2
        )])
    )

    #expect(throws: DomainValidationError.invalidReportSourcePageCount) {
        _ = try VaultCatalog(
            vaultID: UUID(),
            generation: 1,
            members: [member],
            records: [record],
            attachments: [attachment],
            importDrafts: [draft]
        )
    }
}

@Test
func orderedSourceAndFingerprintDecodingRejectsInvalidWireValues() throws {
    let sourceID = UUID().uuidString
    let attachmentID = UUID().uuidString
    let invalidSource = Data(
        "{\"attachmentID\":\"\(attachmentID)\",\"displayName\":\"   \",\"id\":\"\(sourceID)\",\"pageCount\":0}".utf8
    )
    #expect(throws: DecodingError.self) {
        _ = try JSONDecoder().decode(ReportSource.self, from: invalidSource)
    }

    let first = try ReportFingerprint.SourceDigest(
        sha256Digest: Data(repeating: 0x22, count: 32),
        byteCount: 2
    )
    let second = try ReportFingerprint.SourceDigest(
        sha256Digest: Data(repeating: 0x11, count: 32),
        byteCount: 1
    )
    let unsorted = try JSONEncoder().encode(UncheckedFingerprintWire(
        version: ReportFingerprint.currentVersion,
        sources: [first, second]
    ))
    #expect(throws: DecodingError.self) {
        _ = try JSONDecoder().decode(ReportFingerprint.self, from: unsorted)
    }
}

private struct UncheckedFingerprintWire: Encodable {
    let version: Int
    let sources: [ReportFingerprint.SourceDigest]
}
