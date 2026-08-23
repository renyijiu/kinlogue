import Foundation
import Testing
@testable import KinlogueCore

@Test
func originalArchivePlanIncludesConfirmedOriginalsInDeterministicDateOrder() throws {
    let active = try member(1, "Alex")
    let archived = try member(2, "Alex", archived: true)
    let datedAttachment = try attachment(11, bytes: 11)
    let undatedAttachment = try attachment(12, bytes: 12)
    let archivedAttachment = try attachment(13, bytes: 13)
    let dicomAttachment = try attachment(14, bytes: 14, type: "application/dicom")
    let dated = try record(
        21,
        memberID: active.id,
        attachment: datedAttachment,
        name: "blood/result.exe",
        date: utcDate(2025, 1, 2),
        state: .confirmed
    )
    let undated = try record(
        22,
        memberID: active.id,
        attachment: undatedAttachment,
        name: nil,
        date: nil,
        state: .confirmed
    )
    let archivedRecord = try record(
        23,
        memberID: archived.id,
        attachment: archivedAttachment,
        name: "report.pdf",
        date: utcDate(2024, 12, 31),
        state: .confirmed
    )
    let study = try confirmedStudy(31, memberID: active.id, attachments: [dicomAttachment], date: utcDate(2025, 1, 3))
    let catalog = try VaultCatalog(
        vaultID: id(99),
        generation: 1,
        members: [archived, active],
        records: [undated, archivedRecord, dated],
        attachments: [dicomAttachment, archivedAttachment, undatedAttachment, datedAttachment],
        dicomStudies: [study]
    )

    let plan = try OriginalArchivePlan.make(
        catalog: catalog,
        preferredExtensions: [
            datedAttachment.id: "png",
            undatedAttachment.id: "pdf",
            archivedAttachment.id: "pdf",
            dicomAttachment.id: "dcm",
        ],
        undatedToken: "Undated"
    )

    #expect(plan.entries.map(\.archivePath) == [
        "Alex/2025-01-02 - Report 0001 - Source 0001 - blood_result.png",
        "Alex/2025-01-03 - DICOM 0001/0001.dcm",
        "Alex/Undated - Report 0002 - Source 0001 - Report.pdf",
        "Alex (2)/2024-12-31 - Report 0001 - Source 0001 - report.pdf",
    ])
    #expect(plan.entries.map(\.attachmentID) == [
        datedAttachment.id, dicomAttachment.id, undatedAttachment.id, archivedAttachment.id,
    ])
    #expect(plan.totalByteCount == 50)
    #expect(plan.entries.allSatisfy { !$0.archivePath.lowercased().contains("00000000-") })
}

@Test
func originalArchivePlanKeepsEveryOrderedSourceRowEvenWhenAttachmentRepeats() throws {
    let owner = try member(1, "Member")
    let original = try attachment(11, bytes: 7)
    let first = try ReportSource(id: id(41), attachmentID: original.id, displayName: "same.pdf", pageCount: 2)
    let second = try ReportSource(id: id(42), attachmentID: original.id, displayName: "SAME.PDF", pageCount: 2)
    let report = try HealthRecord(
        id: id(21),
        memberID: owner.id,
        sources: ReportSources([first, second]),
        importState: .confirmed
    )
    let catalog = try VaultCatalog(
        vaultID: id(99), generation: 1, members: [owner], records: [report], attachments: [original]
    )

    let plan = try OriginalArchivePlan.make(
        catalog: catalog,
        preferredExtensions: [original.id: "pdf"],
        undatedToken: "Undated"
    )

    #expect(plan.entries.map(\.archivePath) == [
        "Member/Undated - Report 0001 - Source 0001 - same.pdf",
        "Member/Undated - Report 0001 - Source 0002 - SAME.pdf",
    ])
    #expect(plan.entries.map(\.attachmentID) == [original.id, original.id])
    #expect(plan.totalByteCount == 14)
}

@Test
func originalArchivePlanExcludesUnconfirmedRecordsStudiesAndEmptyMembers() throws {
    let includedMember = try member(1, "Included")
    let emptyMember = try member(2, "Empty")
    let confirmedAttachment = try attachment(11, bytes: 3)
    let reviewAttachment = try attachment(12, bytes: 4)
    let dicomAttachment = try attachment(13, bytes: 5, type: "application/dicom")
    let confirmed = try record(21, memberID: includedMember.id, attachment: confirmedAttachment, state: .confirmed)
    let review = try record(22, memberID: includedMember.id, attachment: reviewAttachment, state: .needsReview)
    let reviewStudy = try needsReviewStudy(31, attachments: [dicomAttachment])
    let catalog = try VaultCatalog(
        vaultID: id(99),
        generation: 1,
        members: [emptyMember, includedMember],
        records: [review, confirmed],
        attachments: [reviewAttachment, dicomAttachment, confirmedAttachment],
        dicomStudies: [reviewStudy]
    )

    let plan = try OriginalArchivePlan.make(
        catalog: catalog,
        preferredExtensions: [confirmedAttachment.id: "pdf"],
        undatedToken: "Undated"
    )

    #expect(plan.entries.map(\.archivePath) == [
        "Included/Undated - Report 0001 - Source 0001 - Report.pdf",
    ])
}

@Test
func originalArchivePlanUsesVisibleMemberDisambiguationAndStableStudyOrdinals() throws {
    let owner = try FamilyMember(
        id: id(1),
        displayName: "Alex",
        disambiguationLabel: "Parent"
    )
    let firstAttachment = try attachment(11, bytes: 1, type: "application/dicom")
    let secondAttachment = try attachment(12, bytes: 1, type: "application/dicom")
    let first = try confirmedStudy(
        31,
        memberID: owner.id,
        attachments: [firstAttachment],
        date: utcDate(2025, 1, 2)
    )
    let second = try confirmedStudy(
        32,
        memberID: owner.id,
        attachments: [secondAttachment],
        date: utcDate(2025, 1, 2)
    )
    let catalog = try VaultCatalog(
        vaultID: id(99),
        generation: 1,
        members: [owner],
        attachments: [firstAttachment, secondAttachment],
        dicomStudies: [second, first]
    )

    let plan = try OriginalArchivePlan.make(
        catalog: catalog,
        preferredExtensions: [firstAttachment.id: "dcm", secondAttachment.id: "dcm"],
        undatedToken: "Undated"
    )

    #expect(plan.entries.map(\.archivePath) == [
        "Alex - Parent/2025-01-02 - DICOM 0001/0001.dcm",
        "Alex - Parent/2025-01-02 - DICOM 0002/0001.dcm",
    ])
}

@Test
func originalArchivePlanSanitizesTraversalUnicodeCaseReservedNamesAndSpoofedExtensions() throws {
    let firstMember = try member(1, "CON")
    let secondMember = try member(2, "con")
    let firstAttachment = try attachment(11, bytes: 1)
    let secondAttachment = try attachment(12, bytes: 1)
    let decomposed = "../e\u{301}vil.PDF.exe"
    let first = try record(21, memberID: firstMember.id, attachment: firstAttachment, name: decomposed, state: .confirmed)
    let second = try record(22, memberID: secondMember.id, attachment: secondAttachment, name: "ÉVIL.pdf", state: .confirmed)
    let catalog = try VaultCatalog(
        vaultID: id(99),
        generation: 1,
        members: [secondMember, firstMember],
        records: [second, first],
        attachments: [secondAttachment, firstAttachment]
    )

    let plan = try OriginalArchivePlan.make(
        catalog: catalog,
        preferredExtensions: [firstAttachment.id: "png", secondAttachment.id: "png"],
        undatedToken: "Undated"
    )

    let paths = plan.entries.map(\.archivePath)
    #expect(paths.count == 2)
    #expect(Set(paths.map { $0.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")) }).count == 2)
    #expect(paths.allSatisfy { !$0.contains("/") || $0.split(separator: "/").count == 2 })
    #expect(paths.allSatisfy { !$0.contains("\\") && !$0.contains("..") && $0.hasSuffix(".png") })
    #expect(paths.allSatisfy { !$0.lowercased().hasSuffix(".exe") })
    #expect(paths.contains { $0.hasPrefix("_CON/") })
    #expect(paths.contains { $0.hasPrefix("_con (2)/") })
    #expect(paths.contains { $0.precomposedStringWithCanonicalMapping.contains("évil") })
}

@Test
func originalArchivePlanBoundsEveryComponentAndCompletePath() throws {
    let owner = try member(1, String(repeating: "家", count: 200))
    let original = try attachment(11, bytes: 1)
    let report = try record(
        21,
        memberID: owner.id,
        attachment: original,
        name: String(repeating: "检", count: 300) + ".pdf",
        state: .confirmed
    )
    let catalog = try VaultCatalog(
        vaultID: id(99), generation: 1, members: [owner], records: [report], attachments: [original]
    )

    let plan = try OriginalArchivePlan.make(
        catalog: catalog,
        preferredExtensions: [original.id: "pdf"],
        undatedToken: String(repeating: "未", count: 200)
    )

    let path = try #require(plan.entries.first?.archivePath)
    #expect(path.utf8.count <= 512)
    #expect(path.split(separator: "/").allSatisfy { $0.utf8.count <= 120 })
}

@Test
func originalArchivePlanFailsClosedForMissingOrUnsafeExtensionAndByteOverflow() throws {
    let owner = try member(1, "Member")
    let firstAttachment = try attachment(11, bytes: Int.max, digestByte: 0x11)
    let secondAttachment = try attachment(12, bytes: 1, digestByte: 0x12)
    let first = try record(21, memberID: owner.id, attachment: firstAttachment, state: .confirmed)
    let second = try record(22, memberID: owner.id, attachment: secondAttachment, state: .confirmed)
    let singleCatalog = try VaultCatalog(
        vaultID: id(98), generation: 1, members: [owner], records: [first], attachments: [firstAttachment]
    )
    let overflowCatalog = try VaultCatalog(
        vaultID: id(99),
        generation: 1,
        members: [owner],
        records: [first, second],
        attachments: [firstAttachment, secondAttachment]
    )

    #expect(throws: OriginalArchivePlanError.missingPreferredExtension) {
        _ = try OriginalArchivePlan.make(catalog: singleCatalog, preferredExtensions: [:], undatedToken: "Undated")
    }
    #expect(throws: OriginalArchivePlanError.invalidPreferredExtension) {
        _ = try OriginalArchivePlan.make(
            catalog: singleCatalog,
            preferredExtensions: [firstAttachment.id: "../exe"],
            undatedToken: "Undated"
        )
    }
    #expect(throws: OriginalArchivePlanError.totalByteCountOverflow) {
        _ = try OriginalArchivePlan.make(
            catalog: overflowCatalog,
            preferredExtensions: [firstAttachment.id: "pdf", secondAttachment.id: "pdf"],
            undatedToken: "Undated"
        )
    }
}

@Test
func emptyCatalogProducesEmptyOriginalArchivePlanWithoutExtensionMappings() throws {
    let catalog = try VaultCatalog(vaultID: id(99), generation: 1)
    let plan = try OriginalArchivePlan.make(catalog: catalog, preferredExtensions: [:], undatedToken: "Undated")
    #expect(plan.entries.isEmpty)
    #expect(plan.totalByteCount == 0)
}

@Test
func originalArchivePlanRejectsMoreEntriesThanTheCharacterizedWriterLimit() throws {
    let owner = try member(1, "Member")
    let original = try attachment(11, bytes: 1)
    let sources = try (0...OriginalArchivePlan.maximumEntryCount).map { offset in
        try ReportSource(
            id: id(1_000_000 + offset),
            attachmentID: original.id,
            displayName: "report.pdf",
            pageCount: 1
        )
    }
    let record = try HealthRecord(
        id: id(21),
        memberID: owner.id,
        sources: ReportSources(sources),
        importState: .confirmed
    )
    let catalog = try VaultCatalog(
        vaultID: id(99),
        generation: 1,
        members: [owner],
        records: [record],
        attachments: [original]
    )

    #expect(throws: OriginalArchivePlanError.maximumEntryCountExceeded) {
        _ = try OriginalArchivePlan.make(
            catalog: catalog,
            preferredExtensions: [original.id: "pdf"],
            undatedToken: "Undated"
        )
    }
}

private func id(_ ordinal: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", ordinal))!
}

private func member(_ ordinal: Int, _ name: String, archived: Bool = false) throws -> FamilyMember {
    try FamilyMember(id: id(ordinal), displayName: name, isArchived: archived)
}

private func attachment(
    _ ordinal: Int,
    bytes: Int,
    digestByte: UInt8? = nil,
    type: String = "application/pdf"
) throws -> KinlogueCore.Attachment {
    try KinlogueCore.Attachment(
        id: id(ordinal),
        contentTypeIdentifier: type,
        byteCount: bytes,
        sha256Digest: Data(repeating: digestByte ?? UInt8(ordinal), count: 32)
    )
}

private func record(
    _ ordinal: Int,
    memberID: FamilyMember.ID,
    attachment: KinlogueCore.Attachment,
    name: String? = nil,
    date: Date? = nil,
    state: ImportState
) throws -> HealthRecord {
    let source = try ReportSource(id: id(ordinal + 100), attachmentID: attachment.id, displayName: name, pageCount: 1)
    let candidate: ReportDateCandidate?
    if let date {
        candidate = ReportDateCandidate(
            id: id(ordinal + 200),
            date: date,
            kind: .report,
            source: try SourceField(originalTranscription: "Synthetic date")
        )
    } else {
        candidate = nil
    }
    return try HealthRecord(
        id: id(ordinal),
        memberID: memberID,
        sources: ReportSources([source]),
        importState: state,
        dateCandidates: candidate.map { [$0] } ?? [],
        timelineDateCandidateID: candidate?.id
    )
}

private func confirmedStudy(
    _ ordinal: Int,
    memberID: FamilyMember.ID,
    attachments: [KinlogueCore.Attachment],
    date: Date
) throws -> DICOMStudy {
    try DICOMStudy(
        id: id(ordinal),
        state: .confirmed,
        fingerprint: fingerprint(attachments),
        indexObjectID: id(ordinal + 300),
        attachmentIDs: attachments.map(\.id),
        confirmedMemberID: memberID,
        effectiveDate: date
    )
}

private func needsReviewStudy(_ ordinal: Int, attachments: [KinlogueCore.Attachment]) throws -> DICOMStudy {
    try DICOMStudy(
        id: id(ordinal),
        state: .needsReview,
        fingerprint: fingerprint(attachments),
        indexObjectID: id(ordinal + 300),
        attachmentIDs: attachments.map(\.id)
    )
}

private func fingerprint(_ attachments: [KinlogueCore.Attachment]) throws -> DICOMStudyFingerprint {
    try DICOMStudyFingerprint(objects: attachments.map {
        try DICOMStudyFingerprint.ObjectDigest(sha256Digest: $0.sha256Digest, byteCount: $0.byteCount)
    })
}

private func utcDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar.date(from: DateComponents(year: year, month: month, day: day))!
}
