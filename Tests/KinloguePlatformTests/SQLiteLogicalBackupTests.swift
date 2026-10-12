import Darwin
import Foundation
import GRDB
import Testing
import KinlogueDICOMTestSupport
import ZIPFoundation
@testable import KinlogueCore
@testable import KinloguePlatform

@Test
func sqliteLogicalSnapshotKeepsCapturedMembersAcrossLaterCommits() async throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let store = try SQLiteLibraryStore(rootURL: root)
    defer { try? store.close() }
    let reports = SQLiteReportRepository(store: store)
    let member = try FamilyMember(displayName: "Synthetic snapshot member")
    try await reports.saveMember(member, replacing: nil)
    let source = SQLiteLogicalBackupSource(store: store)
    let snapshot = try await source.prepare()
    defer { snapshot.release() }
    var changed = member; changed.displayName = "Later synthetic member"
    try await reports.saveMember(changed, replacing: member)
    try snapshot.validate()
    #expect(snapshot.revisionPair != (try source.currentRevision()))
    let records = try snapshot.logicalRecordsForTesting()
    #expect(records.contains { $0.kind == .member && (try? $0.decode(FamilyMember.self)) == member })
}

@Test
func sqliteLogicalStrictOpenCannotRepairAStagedOriginal() throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let store = try SQLiteLibraryStore(rootURL: root)
    let source = root.deletingLastPathComponent().appendingPathComponent("synthetic-source")
    try Data("synthetic".utf8).write(to: source)
    let fd = open(source.path, O_RDONLY | O_CLOEXEC); defer { close(fd) }
    _ = try store.stageOriginal(copyingFrom: fd, byteCount: 9, sha256: ContentDigest.sha256(Data("synthetic".utf8)), contentType: "public.data", operationID: UUID())
    try store.close()
    let before = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("originals").path)
    let owner = try SQLiteLibraryOwner(rootURL: root)
    let strict = try SQLiteLibraryStore(owner: owner, mode: .strictExisting)
    defer { try? strict.close() }
    #expect(throws: (any Error).self) { _ = try SQLiteLogicalBackupSource(store: strict).validateStrict() }
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("originals").path) == before)
}

@Test
func sqliteLogicalEncryptedRestoreReopensAndEditsActualRepositories() async throws {
    let root = try sqliteTestRoot()
    let base = root.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: base) }
    let store = try SQLiteLibraryStore(rootURL: root)
    defer { try? store.close() }
    let member = try FamilyMember(displayName: "Synthetic\0logical e\u{301} member", disambiguationLabel: "Label\0尾部")
    try await SQLiteReportRepository(store: store).saveMember(member, replacing: nil)
    let inbox = try SQLiteLANInboxStore(store: store)
    let bytes = Data("Synthetic immutable original".utf8)
    let transport = LANInboxTransportIdentity(sessionID: UUID(), remoteFileID: UUID())
    let metadata = try LANInboxTransportMetadata(displayName: LANInboxDisplayName(rawValue: "Synthetic.bin"), declaredByteCount: bytes.count)
    guard case let .sink(sink) = try await inbox.startItemUpload(transport: transport, metadata: metadata, attemptRevision: 0) else { Issue.record("Missing upload"); return }
    try await sink.write(bytes).value
    _ = try await sink.finish()
    let item = try #require(try await inbox.loadSnapshot().items.first)
    let lanSource = try ReportSource(attachmentID: item.blobID, displayName: item.displayName.rawValue, pageCount: 1)
    let lanDocument = try LANPreprocessedSourceDocument(source: lanSource, contentTypeIdentifier: "public.data", blocks: [])
    _ = try await inbox.savePreprocessedDocument(itemID: item.id, expectedRevision: item.revision, document: lanDocument)
    let before = try await inbox.loadSnapshot()
    let (record, reportDocument) = try await sqliteLogicalConfirmedReport(store, member: member)
    let dicomDirectory = base.appendingPathComponent("synthetic-dicom")
    try FileManager.default.createDirectory(at: dicomDirectory, withIntermediateDirectories: false)
    try GeneratedDICOMFixture.explicitVRLittleEndianMR().write(to: dicomDirectory.appendingPathComponent("mr.dcm"))
    try GeneratedDICOMFixture.explicitVRLittleEndianInertObject().write(to: dicomDirectory.appendingPathComponent("inert.dcm"))
    let dicomRepository = try SQLiteDICOMRepository(store: store)
    let imported = try await DICOMImportWorkflow(repository: dicomRepository, decoder: SQLiteDICOMDecoder()).importDirectory(dicomDirectory, securityScope: .notRequiredForTesting)
    let details = try await dicomRepository.details(imported.studyID)
    _ = try await dicomRepository.confirm(imported.studyID, expectedRevision: details.study.contentRevision, memberID: member.id, effectiveDate: Date(timeIntervalSince1970: 1786000000))
    let snapshot = try await SQLiteLogicalBackupSource(store: store).prepare()
    defer { snapshot.release() }
    // The captured namespace survives a later legal deletion and delayed original GC.
    try await SQLiteReportRepository(store: store).deleteRecord(record.id, expectedRevision: record.revision)
    let enrollment = try BackupKeyHierarchy.makeEnrollment()
    let signer = try BackupDeviceSigner(descriptor: enrollment.descriptor, authorization: enrollment.authorization, deviceSigningSeed: enrollment.deviceSigningSeed)
    let output = SQLiteLogicalTestBytes()
    _ = try await EncryptedBackupContainerWriter().write(entries: snapshot.sources(), revisionPair: snapshot.revisionPair,
        sequence: 1, signer: signer, sink: .init(write: output.append, readBackSource: output.source))
    let checkpoint = base.appendingPathComponent("synthetic.kinloguebackup")
    try output.data.write(to: checkpoint); #expect(chmod(checkpoint.path, 0o600) == 0)
    for late in [false, true] {
        let lowRoot = base.appendingPathComponent(late ? "late-capacity" : "early-capacity")
        let lowOwner = try SQLiteLibraryOwner(rootURL: lowRoot)
        let capacity = SQLiteLogicalCapacitySequence(late: late)
        let lowVerifier = try BackupRestoreVerifier(owner: lowOwner, availableCapacity: capacity.available)
        await #expect(throws: BackupRestoreError.capacityInsufficient) {
            _ = try await lowVerifier.prepare(checkpointURL: checkpoint, recoveryCode: enrollment.recoveryCode)
        }
        #expect(!FileManager.default.fileExists(atPath: lowRoot.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: base.path).allSatisfy { !$0.hasSuffix(".staging") && !$0.hasSuffix(".preflight.json") })
    }
    let destination = base.appendingPathComponent("restored")
    let owner = try SQLiteLibraryOwner(rootURL: destination)
    let verifier = try BackupRestoreVerifier(owner: owner)
    let prepared = try await verifier.prepare(checkpointURL: checkpoint, recoveryCode: enrollment.recoveryCode)
    #expect(prepared.summary.logicalDigest?.count == 32)
    #expect(prepared.summary.memberCount == 1 && prepared.summary.inboxItemCount == 1)
    let transaction = try BackupRestoreTransaction(owner: owner)
    _ = try await transaction.activate(prepared: prepared, resetWriter: {})
    #expect(try await transaction.reconcile() == .committed)
    let restored = try SQLiteLibraryStore(owner: owner)
    defer { try? restored.close() }
    let repository = SQLiteReportRepository(store: restored)
    #expect(try await repository.member(member.id) == member)
    let restoredInbox = try SQLiteLANInboxStore(store: restored)
    let after = try await restoredInbox.loadSnapshot()
    #expect(after.items == before.items && after.transportReceipts == before.transportReceipts)
    let restoredItem = try #require(after.items.first)
    #expect(try await restoredInbox.loadPreprocessedDocument(itemID: restoredItem.id, expectedRevision: restoredItem.revision) == lanDocument)
    #expect(try await repository.record(record.id) == record)
    let restoredDocument = try restored.read { db in try SQLiteReportRows.document(record.ocrDocumentObjectID!, sources: record.sources,
        expectedHash: Data.fetchOne(db, sql: "SELECT document_hash FROM reports WHERE record_id=?", arguments: [record.id.sqliteBytes]), db) }
    #expect(restoredDocument == reportDocument)
    let restoredDICOM = try SQLiteDICOMRepository(store: restored)
    #expect(try await restoredDICOM.details(imported.studyID).study.retainedObjectCount == 2)
    #expect(try await restoredDICOM.details(imported.studyID).series.count == 1)
    let archive = PlaintextOriginalArchiveExporter(store: restored)
    let preparation = try await archive.prepare(undatedToken: "Undated")
    #expect(preparation.entryCount == 4)
    try await repository.deleteRecord(record.id, expectedRevision: record.revision)
    let zipURL = base.appendingPathComponent("originals.zip")
    #expect(try await archive.export(preparation, to: zipURL).entryCount == 4)
    let zip = try Archive(url: zipURL, accessMode: .read)
    #expect(Array(zip).count == 4)
    var changed = member; changed.displayName = "Restored edited member"
    try await repository.saveMember(changed, replacing: member)
    #expect(try await repository.member(member.id) == changed)
}

private final class SQLiteLogicalTestBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    func append(_ bytes: Data) { lock.withLock { storage.append(bytes) } }
    var data: Data { lock.withLock { storage } }
    func source() -> BackupContainerByteSource {
        let snapshot = data
        return .init(byteCount: UInt64(snapshot.count)) { offset, count in
            let start = Int(offset)
            return Data(snapshot[start..<min(snapshot.count, start + count)])
        }
    }
}

struct SQLiteLogicalFrozenFixture: Codable { let stream: Data; let originals: [SQLiteLogicalFrozenOriginal] }
struct SQLiteLogicalFrozenOriginal: Codable { let id: UUID; let bytes: Data }

private func sqliteLogicalConfirmedReport(_ store: SQLiteLibraryStore, member: FamilyMember) async throws -> (HealthRecord, ImportDraftDocument) {
    let repository = SQLiteReportRepository(store: store)
    let data = Data("Synthetic report original".utf8)
    let file = try ValidatedImportedFile(data: data, kind: .image, contentTypeIdentifier: "public.png", sha256Digest: ContentDigest.sha256(data))
    guard case let .created(id) = try await repository.stage(file) else { throw LibraryReportError.invalidDocument }
    let first = try await repository.draft(id)
    let firstSource = first.sources.elements[0]
    let sources = try ReportSources([firstSource, ReportSource(attachmentID: firstSource.attachmentID, displayName: "../Synthetic\0duplicate.source.png", pageCount: 1)])
    try store.write { db in
        let draft = ImportDraft(id: first.id, sources: sources, state: first.state, revision: first.revision,
            attemptID: first.attemptID, documentObjectID: first.documentObjectID, failureCode: first.failureCode, memberID: first.memberID)
        try SQLiteReportRows.saveDraft(draft, documentHash: nil, db, replaceSources: true)
    }
    let lease = try await repository.beginProcessing(draftID: id, attemptID: UUID())
    let document = ImportDraftDocument(blocks: [], candidates: ReportCandidates(), reviewState: ImportDraftReviewState(
        timelineDateSelection: .manual(Date(timeIntervalSince1970: 1786000000)), title: "Synthetic\0reviewed title", organization: "Synthetic\0facility", department: "",
        reportType: "Synthetic type", reportedResults: "Synthetic result", conclusion: "Synthetic conclusion", abnormalItems: ["Synthetic flag"], userNote: "Synthetic review note"))
    try await repository.completeProcessing(lease: lease, document: document)
    let draft = try await repository.draft(id)
    let record = try HealthRecord(memberID: member.id, sources: draft.sources, ocrDocumentObjectID: draft.documentObjectID,
        importState: .confirmed, title: SourceField.manualEntry("Synthetic\0confirmed title"))
    try await repository.confirm(draftID: id, expectedRevision: draft.revision, record: record)
    return (record, document)
}

@Test
func sqliteLogicalSnapshotExcludesHandoffStagingAndRejectsStrictTransientState() async throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let store = try SQLiteLibraryStore(rootURL: root)
    defer { try? store.close() }
    let input = root.deletingLastPathComponent().appendingPathComponent("synthetic-stage")
    try Data([1]).write(to: input)
    let fd = open(input.path, O_RDONLY | O_CLOEXEC); defer { close(fd) }
    let operation = UUID()
    let id = try store.stageOriginal(copyingFrom: fd, byteCount: 1, sha256: ContentDigest.sha256(Data([1])), contentType: "public.data", operationID: operation)
    #expect(!store.activeOriginals.contains(id))
    let snapshot = try await SQLiteLogicalBackupSource(store: store).prepare()
    #expect(try snapshot.logicalRecordsForTesting().isEmpty)
    snapshot.release()
    #expect(throws: (any Error).self) { _ = try SQLiteLogicalBackupSource(store: store).validateStrict() }
    _ = try store.recoverOriginals()
}

@Test
func sqliteLogicalOwnerCannotOpenASecondConnectionEvenWithSharedAuthority() throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let owner = try SQLiteLibraryOwner(rootURL: root)
    let store = try SQLiteLibraryStore(owner: owner)
    #expect(throws: SQLiteLibraryError.occupied) { _ = try SQLiteLibraryStore(owner: owner) }
    try store.closeDatabaseForReplacement()
    let next = try SQLiteLibraryStore(owner: owner, mode: .strictExisting)
    try next.close()
    try store.close()
}

@Test
func sqliteLogicalFrozenV1RestoresIntoAppSchemaAndRemainsByteExact() async throws {
    let fixture = try JSONDecoder().decode(SQLiteLogicalFrozenFixture.self, from: Data(sqliteLogicalV1FrozenJSON.utf8))
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let store = try SQLiteLibraryStore(rootURL: root)
    defer { try? store.close() }
    let result = try sqliteRestoreFrozen(fixture, store: store)
    #expect(result.memberCount == 1 && result.recordCount == 1 && result.inboxItemCount == 1)
    let after = try await SQLiteLogicalBackupSource(store: store).prepare()
    defer { after.release() }
    #expect(try after.spool.read(offset: 0, count: after.spool.byteCount) == fixture.stream)
    let records = try after.logicalRecordsForTesting()
    let reportDocument = try #require(records.first { $0.kind == .reportDocument }).decode(BackupLogicalReportDocumentV1.self)
    #expect(reportDocument.document.reviewState?.userNote == "Synthetic review note")
    let study = try #require(records.first { $0.kind == .dicom }).decode(BackupLogicalDICOMV1.self)
    #expect(study.index.retainedObjects.count == 2 && study.index.instances.count == 1)
    #expect(BackupLogicalKind.reportDocument.maximumCount == 40_000)
    // 4 TiB uses at most 4096 streaming ranges, fitting alongside every legal original.
    #expect(4_096 + BackupLogicalKind.original.maximumCount < BackupFormatLimits.maximumEntryCount)
}

private func sqliteRestoreFrozen(_ fixture: SQLiteLogicalFrozenFixture, store: SQLiteLibraryStore) throws -> SQLiteLogicalValidation {
    let spool = try SQLiteLogicalSpool(parent: store.rootURL.deletingLastPathComponent())
    defer { spool.release() }
    try spool.append(fixture.stream); try spool.seal()
    let header = try SQLiteLogicalStream.read(byteCount: fixture.stream.count, read: spool.read) { _ in }
    var entries: [BackupManifestEntry] = []
    var frame: UInt64 = 0
    func entry(_ kind: BackupManifestEntry.Kind, _ path: String, _ data: Data) throws {
        let count = try BackupManifestEntry.requiredFrameCount(for: UInt64(data.count))
        entries.append(try BackupManifestEntry(kind: kind, path: path, plaintextByteCount: UInt64(data.count), plaintextDigest: ContentDigest.sha256(data), firstFrameIndex: frame, frameCount: count))
        frame += UInt64(count)
    }
    try entry(.logicalSegment, "logical/00000000.data", fixture.stream)
    for original in fixture.originals.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
        let path = "originals/\(original.id.uuidString.lowercased()).data"
        let url = store.rootURL.appendingPathComponent(path)
        try original.bytes.write(to: url, options: .withoutOverwriting)
        #expect(chmod(url.path, 0o600) == 0)
        try entry(.original, path, original.bytes)
    }
    return try SQLiteLogicalRestore.restore(spool: spool, manifest: BackupManifest(revisionPair: SQLiteLogicalBackupSource.revision(header), entries: entries), store: store)
}

@Test(arguments: ["unknown-version", "length", "footer-count", "footer-digest", "trailing", "truncated", "unknown-kind"])
func sqliteLogicalFrozenV1RejectsMalformedFraming(kind: String) throws {
    let fixture = try JSONDecoder().decode(SQLiteLogicalFrozenFixture.self, from: Data(sqliteLogicalV1FrozenJSON.utf8))
    var bytes = fixture.stream
    let headerLength = Int(SQLiteLogicalStream.number(bytes.subdata(in: 8..<12), UInt32.self))
    switch kind {
    case "unknown-version":
        let target = try #require(bytes.range(of: Data("\"version\":1".utf8)))
        bytes[target.upperBound - 1] = Character("2").asciiValue!
    case "length": bytes.replaceSubrange(8..<12, with: [255,255,255,255])
    case "footer-count": bytes[bytes.count - 84] ^= 1
    case "footer-digest": bytes[bytes.count - 1] ^= 1
    case "trailing": bytes.append(0)
    case "truncated": bytes.removeLast()
    default: bytes[12 + headerLength] = 99
    }
    #expect(throws: (any Error).self) {
        _ = try SQLiteLogicalStream.read(byteCount: bytes.count, read: { offset, count in bytes.subdata(in: offset..<(offset + count)) }) { _ in }
    }
}

@Test(arguments: [false, true])
func sqliteLogicalCaptureChecksLocalSpoolCapacityBeforeWritingAndReleasesAdmission(late: Bool) async throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let store = try SQLiteLibraryStore(rootURL: root)
    defer { try? store.close() }
    let before = try FileManager.default.contentsOfDirectory(atPath: root.deletingLastPathComponent().path).sorted()
    let capacity = SQLiteLogicalCapacitySequence(late: late)
    let source = SQLiteLogicalBackupSource(store: store, availableCapacity: capacity.available)
    await #expect(throws: SQLiteLogicalBackupError.capacityInsufficient) { _ = try await source.prepare() }
    #expect(store.pins.isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.deletingLastPathComponent().path).sorted() == before)
    try await SQLiteReportRepository(store: store).saveMember(FamilyMember(displayName: "Synthetic after capacity failure"), replacing: nil)
}

@Test
func sqliteLogicalCaptureCancellationReleasesAdmissionAndDoesNotRetainFiles() async throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let store = try SQLiteLibraryStore(rootURL: root)
    defer { try? store.close() }
    let (entered, continuation) = AsyncStream<Void>.makeStream()
    let gate = DispatchSemaphore(value: 0)
    let source = SQLiteLogicalBackupSource(store: store, availableCapacity: {
        continuation.yield(()); gate.wait(); return UInt64.max
    })
    let task = Task { try await source.prepare() }
    for await _ in entered { break }
    task.cancel(); gate.signal()
    await #expect(throws: CancellationError.self) { _ = try await task.value }
    #expect(store.pins.isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.deletingLastPathComponent().path).allSatisfy { !$0.hasSuffix(".spool") })
    try await SQLiteReportRepository(store: store).saveMember(FamilyMember(displayName: "Synthetic after cancellation"), replacing: nil)
}

@Test
func sqliteLogicalMetadataPinsDoNotHoldOneDescriptorPerOriginal() async throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let store = try SQLiteLibraryStore(rootURL: root)
    defer { try? store.close() }
    let repository = SQLiteReportRepository(store: store)
    for ordinal in 0..<128 {
        let bytes = Data("Synthetic descriptor fixture \(ordinal)".utf8)
        _ = try await repository.stage(ValidatedImportedFile(data: bytes, kind: .image, contentTypeIdentifier: "public.png", sha256Digest: ContentDigest.sha256(bytes)))
    }
    func descriptors() throws -> Int {
        try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").compactMap(Int32.init).filter { fcntl($0, F_GETFD) != -1 }.count
    }
    let before = try descriptors()
    let snapshot = try await SQLiteLogicalBackupSource(store: store).prepare()
    #expect(snapshot.pins.originals.count == 128 && store.pins.count == 128)
    #expect(try descriptors() - before <= 2)
    for id in snapshot.pins.originals.keys {
        let reader = try snapshot.pins.open(id)
        _ = try reader.read(offset: 0, maximumByteCount: 64 * 1_024)
        reader.close()
    }
    #expect(snapshot.pins.maximumSimultaneousOpenFileCount == 1)
    snapshot.release()
    #expect(store.pins.isEmpty)
    #expect(try descriptors() <= before)
}

@Test
func sqliteLogicalDatabaseBudgetCoversLargeDocumentsAndManySmallSourceRows() throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let spool = try SQLiteLogicalSpool(parent: root.deletingLastPathComponent())
    defer { spool.release() }
    let header = try BackupLogicalHeaderV1(libraryID: UUID(), generation: 0, commitID: UUID())
    let writer = try SQLiteLogicalStream.Writer(header: header, write: spool.append)
    let document = ImportDraftDocument(blocks: [], candidates: ReportCandidates(), reviewState: ImportDraftReviewState(
        timelineDateSelection: .unknown, title: String(repeating: "Synthetic", count: 1_000_000), organization: "", department: "",
        reportType: "", reportedResults: "", conclusion: "", abnormalItems: [], userNote: ""))
    let documentBytes = try CanonicalVaultJSON.encode(BackupLogicalReportDocumentV1(revision: 0, document: document))
    try writer.append(SQLiteLogicalRecord(kind: .reportDocument, id: UUID(), payload: documentBytes))
    let original = UUID()
    let sources = try ReportSources((0..<20_000).map { _ in try ReportSource(attachmentID: original, displayName: "S", pageCount: 1) })
    let record = try HealthRecord(memberID: UUID(), sources: sources, importState: .confirmed, title: SourceField.manualEntry("Synthetic"))
    try writer.append(SQLiteLogicalRecord(kind: .report, id: record.id, payload: CanonicalVaultJSON.encode(record)))
    try writer.finish(); try spool.seal()
    let budget = try SQLiteLogicalRestore.databaseBudget(spool: spool, check: {})
    #expect(budget >= UInt64(documentBytes.count) * 2 + 20_000 * 7 * 8_192)
    #expect(budget < 2 * 1_024 * 1_024 * 1_024)
}

private final class SQLiteLogicalCapacitySequence: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let late: Bool
    init(late: Bool) { self.late = late }
    func available() -> UInt64 { lock.withLock { calls += 1; return late && calls == 1 ? UInt64.max : 1 } }
}

@Test
func sqliteLogicalNormalizesWorkAndKeepsHistoricalArchiveWithoutOwningDeletedTargets() async throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let store = try SQLiteLibraryStore(rootURL: root)
    defer { try? store.close() }
    let fixture = try JSONDecoder().decode(SQLiteLogicalFrozenFixture.self, from: Data(sqliteLogicalV1FrozenJSON.utf8))
    _ = try sqliteRestoreFrozen(fixture, store: store)
    let reports = SQLiteReportRepository(store: store)
    let member = try #require(try store.read { try SQLiteReportRows.members($0).first })
    let inbox = try SQLiteLANInboxStore(store: store)
    // Keep a non-empty attributed OCR block and all user review text in the frozen stream.
    try store.write { db in
        let recordID = try #require(Data.fetchOne(db, sql: "SELECT record_id FROM reports").flatMap(UUID.init(sqliteBytes:)))
        let record = try SQLiteReportRows.record(recordID, db)
        let documentID = try #require(record.ocrDocumentObjectID)
        let prior = try SQLiteReportRows.document(documentID, sources: record.sources,
            expectedHash: Data.fetchOne(db, sql: "SELECT document_hash FROM reports WHERE record_id=?", arguments: [recordID.sqliteBytes]), db)
        let source = record.sources.elements[0]
        let block = try OCRBlock(sourceID: source.id, attachmentID: source.attachmentID, filePageNumber: 1,
            text: "Synthetic source transcription", boundingBox: NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.1), confidence: 0.9,
            method: .vision, engineVersion: "synthetic-frozen-v1")
        let document = ImportDraftDocument(blocks: [block], candidates: prior.candidates, reviewState: prior.reviewState)
        let hash = try SQLiteReportRows.saveDocument(document, id: documentID, revision: 1, sources: record.sources, db)
        try SQLiteReportRows.saveRecord(record, documentHash: hash, db)
    }
    let originalItem = try #require(try await inbox.loadSnapshot().items.first)
    let originalDocument = try await inbox.loadPreprocessedDocument(itemID: originalItem.id, expectedRevision: originalItem.revision)
    let prepared = try LANPreparedItemSelection(items: [originalItem], sourceDocuments: [originalDocument], sources: ReportSources([originalDocument.source]),
        document: ImportDraftDocument(blocks: originalDocument.blocks, candidates: ReportCandidates()))
    let date = Date(timeIntervalSince1970: 1786000000)
    let outcome = try await inbox.archive(prepared, memberID: member.id, canonicalReportDate: date, activeSessionID: nil)
    guard case let .accepted(archivedID) = outcome else { Issue.record("Expected archived draft"); return }
    let archived = try await reports.draft(archivedID)
    try await reports.discard(draftID: archivedID, expectedRevision: archived.revision)
    let bytes = Data("Synthetic processing draft".utf8)
    guard case let .created(draftID) = try await reports.stage(ValidatedImportedFile(data: bytes, kind: .image,
        contentTypeIdentifier: "public.png", sha256Digest: ContentDigest.sha256(bytes))) else { Issue.record("Expected draft"); return }
    _ = try await reports.beginProcessing(draftID: draftID, attemptID: UUID())
    let processingDraft = try await reports.draft(draftID)
    let lanBytes = Data("Synthetic preprocessing inbox".utf8)
    guard case let .sink(sink) = try await inbox.startItemUpload(transport: LANInboxTransportIdentity(sessionID: UUID(), remoteFileID: UUID()),
        metadata: LANInboxTransportMetadata(displayName: LANInboxDisplayName(rawValue: "Processing.bin"), declaredByteCount: lanBytes.count), attemptRevision: 7) else { Issue.record("Expected sink"); return }
    try await sink.write(lanBytes).value; _ = try await sink.finish()
    let uploaded = try #require(try await inbox.loadSnapshot().items.first)
    let processingItem = try uploaded.transitioning(to: .preprocessing(blobID: uploaded.blobID, attemptID: UUID()), expectedRevision: uploaded.revision)
    try store.write { try SQLiteLANRows.saveItem(processingItem, $0) }
    let snapshot = try await SQLiteLogicalBackupSource(store: store).prepare()
    defer { snapshot.release() }
    let records = try snapshot.logicalRecordsForTesting()
    let normalizedDraft = try #require(records.first { $0.kind == .draft && $0.key == draftID.sqliteBytes }).decode(ImportDraft.self)
    #expect(normalizedDraft.state == .failed && normalizedDraft.failureCode == .cancelled && normalizedDraft.attemptID == nil)
    #expect(normalizedDraft.revision == processingDraft.revision)
    let normalizedItem = try #require(records.first { $0.kind == .inbox }).decode(LANInboxItem.self)
    #expect(normalizedItem.state == .failed(blobID: processingItem.blobID, issue: .storageFailure))
    #expect(normalizedItem.revision == processingItem.revision && normalizedItem.attemptID == nil)
    #expect(records.filter { $0.kind == .archiveReceipt }.count == 1)
    #expect(records.filter { $0.kind == .terminal }.count == 1)
    let capturedFixture = SQLiteLogicalFrozenFixture(stream: try snapshot.spool.read(offset: 0, count: snapshot.spool.byteCount),
        originals: try snapshot.pins.originals.values.map { original in
            let reader = try snapshot.pins.open(original.id); defer { reader.close() }
            return SQLiteLogicalFrozenOriginal(id: original.id, bytes: try reader.read(offset: 0, maximumByteCount: 64 * 1_024))
        })
    let destination = root.deletingLastPathComponent().appendingPathComponent("Normalized")
    let restored = try SQLiteLibraryStore(rootURL: destination)
    defer { try? restored.close() }
    _ = try sqliteRestoreFrozen(capturedFixture, store: restored)
    let restoredInbox = try SQLiteLANInboxStore(store: restored)
    #expect(try await restoredInbox.completedArchive(itemIDs: [originalItem.id], memberID: member.id, canonicalReportDate: date) == outcome)
    #expect(try await SQLiteReportRepository(store: restored).draft(draftID) == normalizedDraft)
    #expect(try await restoredInbox.loadSnapshot().items == [normalizedItem])
}

@Test
func sqliteLogicalFrozenRecoveryStatesAndReplayHistoryRemainPortable() async throws {
    let fixture = try JSONDecoder().decode(SQLiteLogicalFrozenFixture.self, from: Data(sqliteLogicalV1StatesFrozenJSON.utf8))
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let store = try SQLiteLibraryStore(rootURL: root)
    defer { try? store.close() }
    _ = try sqliteRestoreFrozen(fixture, store: store)
    let snapshot = try await SQLiteLogicalBackupSource(store: store).prepare()
    defer { snapshot.release() }
    #expect(try snapshot.spool.read(offset: 0, count: snapshot.spool.byteCount) == fixture.stream)
    let records = try snapshot.logicalRecordsForTesting()
    let document = try #require(records.first { $0.kind == .reportDocument }).decode(BackupLogicalReportDocumentV1.self)
    #expect(document.document.blocks.count == 1)
    #expect(document.document.reviewState?.userNote == "Synthetic review note")
    let draft = try #require(records.first { $0.kind == .draft }).decode(ImportDraft.self)
    #expect(draft.state == .failed && draft.failureCode == .cancelled && draft.attemptID == nil)
    let inbox = try #require(records.first { $0.kind == .inbox }).decode(LANInboxItem.self)
    #expect(inbox.state == .failed(blobID: inbox.blobID, issue: .storageFailure) && inbox.attemptID == nil)
    let historical = try #require(records.first { $0.kind == .archiveReceipt }).decode(BackupLogicalArchiveReceiptV1.self)
    let restoredInbox = try SQLiteLANInboxStore(store: store)
    #expect(try await restoredInbox.completedArchive(itemIDs: historical.itemIDs, memberID: historical.memberID, canonicalReportDate: historical.date) == historical.outcome)
    if case let .accepted(id) = historical.outcome {
        await #expect(throws: LibraryReportError.draftNotFound) { _ = try await SQLiteReportRepository(store: store).draft(id) }
    }
}

@Test(arguments: ["processing", "preprocessing", "missing-original", "extra-original", "dangling-member", "unknown-field"])
func sqliteLogicalFrozenV1RejectsBadSemanticGraphsWithoutRepair(kind: String) throws {
    let fixture = try JSONDecoder().decode(SQLiteLogicalFrozenFixture.self, from: Data(sqliteLogicalV1StatesFrozenJSON.utf8))
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let spool = try SQLiteLogicalSpool(parent: root.deletingLastPathComponent())
    defer { spool.release() }
    var records: [SQLiteLogicalRecord] = []
    let header = try SQLiteLogicalStream.read(byteCount: fixture.stream.count, read: { offset, count in fixture.stream.subdata(in: offset..<(offset + count)) }) { records.append($0) }
    var originals = fixture.originals
    switch kind {
    case "missing-original": originals.removeLast()
    case "extra-original": originals.append(SQLiteLogicalFrozenOriginal(id: UUID(), bytes: Data([1])))
    case "dangling-member": records.removeAll { $0.kind == .member }
    case "processing":
        let index = try #require(records.firstIndex { $0.kind == .draft })
        var value = try records[index].decode(ImportDraft.self)
        value.state = .processing; value.failureCode = nil; value.attemptID = UUID()
        records[index] = SQLiteLogicalRecord(kind: .draft, id: value.id, payload: try CanonicalVaultJSON.encode(value))
    case "preprocessing":
        let index = try #require(records.firstIndex { $0.kind == .inbox })
        let prior = try records[index].decode(LANInboxItem.self)
        let value = try LANInboxItem(id: prior.id, originatingSessionID: prior.originatingSessionID, displayName: prior.displayName,
            receivedAt: prior.receivedAt, sequence: prior.sequence, revision: prior.revision, contentIdentity: prior.contentIdentity,
            state: .preprocessing(blobID: prior.blobID, attemptID: UUID()))
        records[index] = SQLiteLogicalRecord(kind: .inbox, id: value.id, payload: try CanonicalVaultJSON.encode(value))
    default:
        let index = try #require(records.firstIndex { $0.kind == .member })
        var object = try #require(JSONSerialization.jsonObject(with: records[index].payload) as? [String: Any])
        object["futureUnversionedField"] = "Synthetic"
        records[index] = SQLiteLogicalRecord(kind: .member, key: records[index].key,
            payload: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
    }
    let writer = try SQLiteLogicalStream.Writer(header: header, write: spool.append)
    for record in records { try writer.append(record) }
    try writer.finish(); try spool.seal()
    let changed = SQLiteLogicalFrozenFixture(stream: try spool.read(offset: 0, count: spool.byteCount), originals: originals)
    let store = try SQLiteLibraryStore(rootURL: root)
    defer { try? store.close() }
    #expect(throws: (any Error).self) { _ = try sqliteRestoreFrozen(changed, store: store) }
}

@Test(arguments: [false, true])
func sqliteLogicalBackupDigestFailureQuarantinesWithoutReadingOriginalTwice(strictValidation: Bool) async throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let store = try SQLiteLibraryStore(rootURL: root)
    defer { try? store.close() }
    let repository = SQLiteReportRepository(store: store)
    let member = try FamilyMember(displayName: "Synthetic backup integrity")
    try await repository.saveMember(member, replacing: nil)
    let (record, _) = try await sqliteLogicalConfirmedReport(store, member: member)
    let original = try store.read { try SQLiteOriginal.read(record.sources.first.attachmentID, from: $0) }
    let file = store.originalsURL.appendingPathComponent(store.originalFilename(original.id))
    try Data(repeating: 0, count: original.byteCount).write(to: file)
    let before = store.originalReadMetrics.verifiedReadByteCount
    let source = SQLiteLogicalBackupSource(store: store)
    if strictValidation {
        #expect(throws: SQLiteLogicalBackupError.sourceChanged) { try source.validateStrict() }
    } else {
        let snapshot = try await source.prepare()
        defer { snapshot.release() }
        let enrollment = try BackupKeyHierarchy.makeEnrollment()
        let signer = try BackupDeviceSigner(descriptor: enrollment.descriptor, authorization: enrollment.authorization, deviceSigningSeed: enrollment.deviceSigningSeed)
        let output = SQLiteLogicalTestBytes()
        await #expect(throws: BackupContainerError.sourceIntegrityFailure) {
            try await EncryptedBackupContainerWriter().write(entries: snapshot.sources(), revisionPair: snapshot.revisionPair,
                sequence: 1, signer: signer, sink: .init(write: output.append, readBackSource: output.source))
        }
    }
    #expect(store.originalReadMetrics.verifiedReadByteCount - before == UInt64(original.byteCount))
    await #expect(throws: SQLiteLibraryError.damaged) { try await repository.record(record.id) }
}
