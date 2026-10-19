import Foundation
import Testing
@testable import KinlogueCore

@Suite("Backup archive index")
struct BackupArchiveIndexTests {
    @Test
    func indexRoundTripsAsReadableJSON() throws {
        let index = try sampleIndex()
        let data = try index.encoded()
        let text = try #require(String(data: data, encoding: .utf8))

        #expect(try BackupArchiveIndex.decode(data) == index)
        #expect(text.contains("\"encryption\" : \"none\""))
        #expect(text.contains("\"format\" : \"kinlogue-backup\""))
        #expect(text.contains("\"path\" : \"files/Alex/2025-01-02 - Report 0001 - Source 0001 - blood.pdf\""))
        #expect(text.contains(String(repeating: "ab", count: 32)))
        #expect(text.contains("\"backupID\" : \"abcdef01-2345-6789-abcd-ef0123456789\""))
    }

    @Test
    func newerWritersAreReadWhileTheirMinimumReaderIsMet() throws {
        var object = try jsonObject(sampleIndex())
        object["formatVersion"] = 3
        object["somethingNew"] = ["nested": true]
        let index = try BackupArchiveIndex.decode(JSONSerialization.data(withJSONObject: object))
        #expect(index.formatVersion == 3)
        #expect(index.minimumReaderVersion == 1)
    }

    @Test
    func indexRejectsNewerReadersEncryptionAndOtherFormats() throws {
        func decode(_ change: (inout [String: Any]) -> Void) throws -> BackupArchiveIndex {
            var object = try jsonObject(sampleIndex())
            change(&object)
            return try BackupArchiveIndex.decode(JSONSerialization.data(withJSONObject: object))
        }
        #expect(throws: BackupArchiveError.unsupportedFormat) {
            _ = try decode { $0["minimumReaderVersion"] = 2; $0["formatVersion"] = 2 }
        }
        #expect(throws: BackupArchiveError.unsupportedFormat) { _ = try decode { $0["encryption"] = "aes-256" } }
        #expect(throws: BackupArchiveError.invalidArchive) { _ = try decode { $0["format"] = "something-else" } }
        #expect(throws: BackupArchiveError.invalidArchive) { _ = try decode { $0.removeValue(forKey: "library") } }
        #expect(throws: BackupArchiveError.invalidArchive) { _ = try BackupArchiveIndex.decode(Data("not json".utf8)) }
    }

    @Test(arguments: [
        "../files/a.pdf", "/files/a.pdf", "files/../a.pdf", "files//a.pdf", "files/./a.pdf",
        "files\\a.pdf", "files/a\u{0}.pdf", "files/a\n.pdf", "files/", "other/a.pdf",
    ])
    func indexRejectsOriginalPathsOutsideTheFilesFolder(path: String) throws {
        var object = try jsonObject(sampleIndex())
        var originals = try #require(object["originals"] as? [[String: Any]])
        originals[0]["path"] = path
        object["originals"] = originals
        #expect(throws: BackupArchiveError.invalidArchive) {
            _ = try BackupArchiveIndex.decode(JSONSerialization.data(withJSONObject: object))
        }
    }

    @Test
    func indexRejectsDuplicatesMismatchedCountsAndMalformedValues() throws {
        func decode(_ change: (inout [String: Any], inout [[String: Any]]) -> Void) throws {
            var object = try jsonObject(sampleIndex())
            var originals = object["originals"] as! [[String: Any]]
            change(&object, &originals)
            object["originals"] = originals
            _ = try BackupArchiveIndex.decode(JSONSerialization.data(withJSONObject: object))
        }
        #expect(throws: BackupArchiveError.invalidArchive) {
            try decode { _, originals in originals[1]["path"] = originals[0]["path"]! }
        }
        #expect(throws: BackupArchiveError.invalidArchive) {
            try decode { _, originals in originals[1]["id"] = originals[0]["id"]! }
        }
        #expect(throws: BackupArchiveError.invalidArchive) {
            try decode { _, originals in originals[0]["path"] = BackupArchiveIndex.fileName }
        }
        #expect(throws: BackupArchiveError.invalidArchive) {
            try decode { object, _ in
                var counts = object["counts"] as! [String: Any]
                counts["originals"] = 3
                object["counts"] = counts
            }
        }
        #expect(throws: BackupArchiveError.invalidArchive) {
            try decode { _, originals in originals[0]["sha256"] = String(repeating: "AB", count: 32) }
        }
        #expect(throws: BackupArchiveError.invalidArchive) {
            try decode { _, originals in originals[0]["contentType"] = "" }
        }
        #expect(throws: BackupArchiveError.invalidArchive) {
            try decode { object, _ in
                var data = object["data"] as! [String: Any]
                data["path"] = "data/other.klog"
                object["data"] = data
            }
        }
        #expect(throws: BackupArchiveError.invalidArchive) {
            try decode { object, _ in object["createdAt"] = "yesterday" }
        }
    }

    @Test
    func indexBoundsSizeAndTotalBytes() throws {
        #expect(throws: BackupArchiveError.resourceLimit) {
            _ = try BackupArchiveIndex.decode(Data(count: BackupArchiveLimits.maximumIndexByteCount + 1))
        }
        let huge = try BackupArchiveIndex.Entry(
            path: "files/a.pdf", byteCount: BackupArchiveLimits.maximumPlaintextByteCount, sha256: Data(repeating: 1, count: 32)
        )
        #expect(throws: BackupArchiveError.resourceLimit) {
            _ = try BackupArchiveIndex(
                backupID: archiveID(1), createdAt: Date(timeIntervalSince1970: 0), creator: creator(),
                library: library(), counts: counts(originals: 1),
                data: .init(path: BackupArchiveIndex.dataPath, byteCount: 1, sha256: Data(repeating: 2, count: 32)),
                originals: [.init(id: archiveID(2), entry: huge, contentType: "com.adobe.pdf")]
            )
        }
    }
}

@Suite("Backup archive paths")
struct BackupArchivePlanTests {
    @Test
    func confirmedReportsAndStudiesAreFiledByPersonAndDate() throws {
        var catalog = BackupArchiveCatalog()
        let active = try FamilyMember(id: archiveID(1), displayName: "Alex")
        let archived = try FamilyMember(id: archiveID(2), displayName: "Alex", isArchived: true)
        catalog.add(member: archived)
        catalog.add(member: active)
        catalog.originals = [original(11), original(12), original(13), original(14, type: "application/dicom")]
        catalog.reports = [
            .init(record: try record(21, member: active.id, attachment: 12, name: nil, date: nil)),
            .init(record: try record(22, member: archived.id, attachment: 13, name: "report.pdf", date: utcDate(2024, 12, 31))),
            .init(record: try record(23, member: active.id, attachment: 11, name: "blood/result.exe", date: utcDate(2025, 1, 2))),
        ]
        catalog.studies = [.init(id: archiveID(31), state: .confirmed, memberID: active.id, date: utcDate(2025, 1, 3), attachmentIDs: [archiveID(14)])]

        let plan = try makePlan(catalog, extensions: [11: "png", 12: "pdf", 13: "pdf", 14: "dcm"])

        #expect(plan.files.map(\.path) == [
            "files/Alex/2025-01-02 - Report 0001 - Source 0001 - blood_result.png",
            "files/Alex/2025-01-03 - DICOM 0001/0001.dcm",
            "files/Alex/Undated - Report 0002 - Source 0001 - Report.pdf",
            "files/Alex (2)/2024-12-31 - Report 0001 - Source 0001 - report.pdf",
        ])
        #expect(plan.files.map(\.original.id) == [archiveID(11), archiveID(14), archiveID(12), archiveID(13)])
        #expect(plan.totalByteCount == 11 + 14 + 12 + 13)
        #expect(plan.files.allSatisfy { !$0.path.lowercased().contains("00000000-") })
    }

    @Test
    func everyOriginalIsWrittenOnceEvenWhenSourcesShareIt() throws {
        var catalog = BackupArchiveCatalog()
        let owner = try FamilyMember(id: archiveID(1), displayName: "Member")
        catalog.add(member: owner)
        catalog.originals = [original(11)]
        let first = try ReportSource(id: archiveID(41), attachmentID: archiveID(11), displayName: "same.pdf", pageCount: 1)
        let second = try ReportSource(id: archiveID(42), attachmentID: archiveID(11), displayName: "SAME.PDF", pageCount: 1)
        catalog.reports = [.init(record: try HealthRecord(
            id: archiveID(21), memberID: owner.id, sources: ReportSources([first, second]), importState: .confirmed
        ))]
        catalog.drafts = [.init(draft: ImportDraft(id: archiveID(51), attachmentID: archiveID(11)))]

        let plan = try makePlan(catalog, extensions: [11: "pdf"])
        #expect(plan.files.map(\.path) == ["files/Member/Undated - Report 0001 - Source 0001 - same.pdf"])
    }

    @Test
    func pendingItemsPhoneUploadsAndLooseOriginalsComeAfterThePeople() throws {
        var catalog = BackupArchiveCatalog()
        let owner = try FamilyMember(id: archiveID(1), displayName: "Zoe")
        catalog.add(member: owner)
        catalog.originals = (11...17).map { original($0, type: $0 == 14 ? "application/dicom" : "com.adobe.pdf") }
        catalog.reports = [
            .init(record: try record(21, member: owner.id, attachment: 11, name: "lab.pdf", date: utcDate(2025, 2, 1))),
            .init(record: try record(22, member: owner.id, attachment: 12, name: "draft-ish.pdf", date: nil, state: .needsReview)),
        ]
        catalog.drafts = [.init(draft: ImportDraft(
            id: archiveID(51),
            sources: try ReportSources([try ReportSource(id: archiveID(61), attachmentID: archiveID(13), displayName: "scan.jpg", pageCount: 1)]),
            state: .needsReview
        ))]
        catalog.studies = [.init(id: archiveID(31), state: .needsReview, memberID: nil, date: nil, attachmentIDs: [archiveID(14)])]
        catalog.inbox = [
            .init(item: try inboxItem(71, blob: 16, name: "IMG_2.heic", sequence: 9)),
            .init(item: try inboxItem(72, blob: 15, name: "IMG_1.jpg", sequence: 3)),
        ]

        let labels = BackupArchiveLabels(undated: "未注明日期", pendingFolder: "待确认", phoneFolder: "手机待整理", otherFolder: "其他")
        let plan = try BackupArchivePlan.make(catalog: catalog, preferredExtensions: extensions(
            [11: "pdf", 12: "pdf", 13: "jpg", 14: "dcm", 15: "jpeg", 16: "heic", 17: "bin"]
        ), labels: labels)

        #expect(plan.files.map(\.path) == [
            "files/Zoe/2025-02-01 - Report 0001 - Source 0001 - lab.pdf",
            "files/_待确认/Report 0001 - Source 0001 - draft-ish.pdf",
            "files/_待确认/Draft 0001 - Source 0001 - scan.jpg",
            "files/_待确认/DICOM 0001/0001.dcm",
            "files/_手机待整理/0001 - IMG_1.jpeg",
            "files/_手机待整理/0002 - IMG_2.heic",
            "files/_其他/0001.bin",
        ])
        #expect(Set(plan.files.map(\.original.id)) == Set(catalog.originals.map(\.id)))
    }

    @Test
    func folderNamesNeverCollideWithAPersonCalledLikeAFolder() throws {
        var catalog = BackupArchiveCatalog()
        let owner = try FamilyMember(id: archiveID(1), displayName: "_Pending")
        catalog.add(member: owner)
        catalog.originals = [original(11), original(12)]
        catalog.reports = [.init(record: try record(21, member: owner.id, attachment: 11, name: "a.pdf", date: nil))]
        catalog.drafts = [.init(draft: ImportDraft(id: archiveID(51), attachmentID: archiveID(12)))]

        let plan = try makePlan(catalog, extensions: [11: "pdf", 12: "pdf"])
        #expect(plan.files.map(\.path) == [
            "files/_Pending/Undated - Report 0001 - Source 0001 - a.pdf",
            "files/_Pending (2)/Draft 0001 - Source 0001 - Report.pdf",
        ])
    }

    @Test
    func namesAreSanitizedAndBounded() throws {
        var catalog = BackupArchiveCatalog()
        let first = try FamilyMember(id: archiveID(1), displayName: "CON")
        let second = try FamilyMember(id: archiveID(2), displayName: "con")
        let long = try FamilyMember(id: archiveID(3), displayName: String(repeating: "家", count: 200))
        [second, first, long].forEach { catalog.add(member: $0) }
        catalog.originals = [original(11), original(12), original(13)]
        catalog.reports = [
            .init(record: try record(21, member: first.id, attachment: 11, name: "../e\u{301}vil.PDF.exe", date: nil)),
            .init(record: try record(22, member: second.id, attachment: 12, name: "ÉVIL.pdf", date: nil)),
            .init(record: try record(23, member: long.id, attachment: 13, name: String(repeating: "检", count: 300) + ".pdf", date: nil)),
        ]

        let plan = try makePlan(catalog, extensions: [11: "png", 12: "png", 13: "pdf"])
        let paths = plan.files.map(\.path)
        #expect(paths.contains { $0.hasPrefix("files/_CON/") })
        #expect(paths.contains { $0.hasPrefix("files/_con (2)/") })
        #expect(paths.allSatisfy { !$0.contains("\\") && !$0.contains("..") && !$0.lowercased().hasSuffix(".exe") })
        #expect(paths.contains { $0.precomposedStringWithCanonicalMapping.contains("évil") })
        #expect(paths.allSatisfy { $0.utf8.count <= 512 && $0.split(separator: "/").allSatisfy { $0.utf8.count <= 120 } })
        #expect(paths.allSatisfy(BackupArchiveIndex.isSafePath))
    }

    @Test
    func planFailsClosedForUnknownReferencesAndMissingExtensions() throws {
        var catalog = BackupArchiveCatalog()
        let owner = try FamilyMember(id: archiveID(1), displayName: "Member")
        catalog.add(member: owner)
        catalog.originals = [original(11)]
        catalog.reports = [.init(record: try record(21, member: owner.id, attachment: 12, name: nil, date: nil))]
        #expect(throws: BackupArchiveError.invalidArchive) { _ = try makePlan(catalog, extensions: [11: "pdf", 12: "pdf"]) }

        catalog.reports = [.init(record: try record(21, member: owner.id, attachment: 11, name: nil, date: nil))]
        #expect(throws: BackupArchiveError.invalidArchive) { _ = try makePlan(catalog, extensions: [:]) }
        #expect(throws: BackupArchiveError.invalidArchive) { _ = try makePlan(catalog, extensions: [11: "../exe"]) }

        catalog.reports = [.init(record: try record(21, member: archiveID(9), attachment: 11, name: nil, date: nil))]
        #expect(throws: BackupArchiveError.invalidArchive) { _ = try makePlan(catalog, extensions: [11: "pdf"]) }
    }

    @Test
    func emptyLibraryHasNoFiles() throws {
        #expect(try makePlan(BackupArchiveCatalog(), extensions: [:]).files.isEmpty)
    }
}

@Suite("Backup retention")
struct BackupRetentionTests {
    @Test
    func retentionCountAllowsOneThroughThirty() throws {
        #expect(BackupRetentionCount.default.value == 5)
        #expect(try BackupRetentionCount(1).value == 1)
        #expect(try BackupRetentionCount(30).value == 30)
        #expect(throws: BackupArchiveError.self) { _ = try BackupRetentionCount(0) }
        #expect(throws: BackupArchiveError.self) { _ = try BackupRetentionCount(31) }
    }

    @Test
    func keepsTheNewestIntactBackupsAndForgetsChangedOnes() throws {
        let entries = try (1...6).map { try ledgerEntry($0) }
        let plan = BackupRetention.plan(
            entries: entries.shuffled(),
            observations: [1: .intact, 2: .changed, 3: .intact, 4: .intact, 5: .changed, 6: .intact],
            count: try BackupRetentionCount(2),
            newest: 6
        )
        #expect(plan.keep.map(\.sequence) == [6, 4])
        #expect(plan.delete.map(\.sequence) == [3, 1])
        #expect(plan.forget.map(\.sequence) == [5, 2])
    }

    @Test
    func deletesNothingWhenTheNewBackupIsNotIntact() throws {
        let entries = try (1...4).map { try ledgerEntry($0) }
        let plan = BackupRetention.plan(
            entries: entries,
            observations: [1: .intact, 2: .intact, 3: .intact],
            count: try BackupRetentionCount(1),
            newest: 4
        )
        #expect(plan.delete.isEmpty)
        #expect(plan.keep.map(\.sequence) == [3, 2, 1])
        #expect(plan.forget.map(\.sequence) == [4])
    }
}

// MARK: - Fixtures

private func archiveID(_ ordinal: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", ordinal))!
}

private func original(_ ordinal: Int, type: String = "com.adobe.pdf") -> BackupArchiveOriginal {
    BackupArchiveOriginal(id: archiveID(ordinal), byteCount: ordinal, sha256: Data(repeating: UInt8(ordinal), count: 32), contentType: type)
}

private func extensions(_ values: [Int: String]) -> [UUID: String] {
    Dictionary(uniqueKeysWithValues: values.map { (archiveID($0.key), $0.value) })
}

private func makePlan(_ catalog: BackupArchiveCatalog, extensions values: [Int: String]) throws -> BackupArchivePlan {
    try BackupArchivePlan.make(
        catalog: catalog,
        preferredExtensions: extensions(values),
        labels: BackupArchiveLabels(undated: "Undated", pendingFolder: "Pending", phoneFolder: "Phone", otherFolder: "Other")
    )
}

private func record(
    _ ordinal: Int, member: UUID, attachment: Int, name: String?, date: Date?, state: ImportState = .confirmed
) throws -> HealthRecord {
    let source = try ReportSource(id: archiveID(ordinal + 100), attachmentID: archiveID(attachment), displayName: name, pageCount: 1)
    let candidate = try date.map {
        ReportDateCandidate(id: archiveID(ordinal + 200), date: $0, kind: .report, source: try SourceField(originalTranscription: "Synthetic date"))
    }
    return try HealthRecord(
        id: archiveID(ordinal), memberID: member, sources: ReportSources([source]), importState: state,
        dateCandidates: candidate.map { [$0] } ?? [], timelineDateCandidateID: candidate?.id
    )
}

private func inboxItem(_ ordinal: Int, blob: Int, name: String, sequence: UInt64) throws -> LANInboxItem {
    try LANInboxItem(
        id: archiveID(ordinal), originatingSessionID: archiveID(99), displayName: LANInboxDisplayName(rawValue: name),
        receivedAt: Date(timeIntervalSince1970: 1_700_000_000), sequence: sequence,
        contentIdentity: LANInboxContentIdentity(sha256Digest: Data(repeating: UInt8(blob), count: 32), byteCount: blob),
        state: .stored(blobID: archiveID(blob))
    )
}

private func utcDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar.date(from: DateComponents(year: year, month: month, day: day))!
}

private func creator() throws -> BackupArchiveIndex.Creator {
    try .init(app: "Kinlogue", version: "1.0", build: "1")
}

private func library() throws -> BackupLibraryRevision {
    try .init(libraryID: archiveID(90), generation: 4, commitID: archiveID(91))
}

private func counts(originals: Int) throws -> BackupArchiveIndex.Counts {
    try .init(members: 1, records: 1, drafts: 0, inboxItems: 0, dicomStudies: 0, originals: originals)
}

private func sampleIndex() throws -> BackupArchiveIndex {
    try BackupArchiveIndex(
        backupID: UUID(uuidString: "ABCDEF01-2345-6789-ABCD-EF0123456789")!,
        createdAt: Date(timeIntervalSince1970: 1_760_000_000.25),
        creator: creator(),
        library: library(),
        counts: counts(originals: 2),
        data: .init(path: BackupArchiveIndex.dataPath, byteCount: 1_024, sha256: Data(repeating: 0xcd, count: 32)),
        originals: [
            .init(
                id: archiveID(11),
                entry: .init(path: "files/Alex/2025-01-02 - Report 0001 - Source 0001 - blood.pdf", byteCount: 11, sha256: Data(repeating: 0xab, count: 32)),
                contentType: "com.adobe.pdf"
            ),
            .init(
                id: archiveID(12),
                entry: .init(path: "files/_Phone/0001 - IMG.jpeg", byteCount: 12, sha256: Data(repeating: 0x12, count: 32)),
                contentType: "public.jpeg"
            ),
        ]
    )
}

private func jsonObject(_ index: BackupArchiveIndex) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: index.encoded()) as? [String: Any])
}

private func ledgerEntry(_ sequence: UInt64) throws -> BackupLedgerEntry {
    BackupLedgerEntry(
        sequence: sequence, fileName: "Backup \(sequence).zip", inode: sequence + 100, byteCount: 10,
        modifiedSeconds: 1, modifiedNanoseconds: 0, backupID: archiveID(Int(sequence)),
        createdAt: Date(timeIntervalSince1970: TimeInterval(sequence)), library: try library()
    )
}
