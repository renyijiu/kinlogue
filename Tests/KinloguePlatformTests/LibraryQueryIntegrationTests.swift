import Darwin
import Foundation
import GRDB
import Testing
@testable import KinlogueCore
@testable import KinloguePlatform

@Test
func sqliteReportWorkflowPersistsReviewAndConfirmedDetailsWithoutOCRFiles() async throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let kernel = try SQLiteLibraryStore(rootURL: root)
    let repository = SQLiteReportRepository(store: kernel)
    let member = try FamilyMember(displayName: "Synthetic member")
    try await repository.saveMember(member, replacing: nil)
    let file = try sqliteReportFile("synthetic source")
    guard case let .created(id) = try await repository.stage(file) else {
        Issue.record("Expected a new draft"); return
    }
    let lease = try await repository.beginProcessing(draftID: id, attemptID: UUID())
    try await repository.completeProcessing(lease: lease, document: ImportDraftDocument(
        blocks: [], candidates: ReportCandidates(), candidateExtractionVersion: nil
    ))
    let before = try await repository.draft(id)
    #expect(try await repository.loadDocument(draftID: id).candidateExtractionVersion == nil)
    let reviewed = ImportDraftDocument(blocks: [], candidates: ReportCandidates(), reviewState: ImportDraftReviewState(
        timelineDateSelection: .unknown, title: "Synthetic title", organization: "", department: "", reportType: "",
        reportedResults: "", conclusion: "", abnormalItems: [], userNote: "Synthetic private note"
    ))
    try await repository.saveReview(draftID: id, expectedRevision: before.revision, memberID: member.id, document: reviewed)
    let after = try await repository.draft(id)
    #expect(before.documentObjectID == after.documentObjectID)
    #expect(try await repository.loadDocument(draftID: id) == reviewed)
    #expect(try await repository.reportPage().items.isEmpty)
    let record = try HealthRecord(memberID: member.id, sources: after.sources, ocrDocumentObjectID: after.documentObjectID,
                                  importState: .confirmed, title: SourceField.manualEntry("Synthetic title"))
    try await repository.confirm(draftID: id, expectedRevision: after.revision, record: record)
    #expect(try await repository.record(record.id) == record)
    #expect(try await repository.reportPage().items.map(\.id) == [record.id])
    #expect(try await repository.stage(file) == .existingRecord(record.id))
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("originals").path).count == 1)
    try kernel.close()
    let reopened = try SQLiteLibraryStore(rootURL: root)
    defer { try? reopened.close() }
    let next = SQLiteReportRepository(store: reopened)
    #expect(try await next.record(record.id) == record)
    let restoredDocument = try reopened.read { db in
        try SQLiteReportRows.document(after.documentObjectID!, sources: after.sources,
            expectedHash: Data.fetchOne(db, sql: "SELECT document_hash FROM reports WHERE record_id = ?",
                                       arguments: [record.id.sqliteBytes]), db)
    }
    #expect(restoredDocument == reviewed)
    try await next.deleteRecord(record.id, expectedRevision: record.revision)
    try await next.deleteMember(member.id)
    #expect(try await next.members().isEmpty)
    let page = try await next.reportPage()
    #expect(page.nextCursor == nil)
    #expect(page.revision.generation == UInt64(try reopened.state().generation))
    #expect(page.revision.openEpoch == reopened.openEpoch)
}

@Test
func sqliteReportAttemptsAndFailedTransactionsPreserveDraft() async throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let kernel = try SQLiteLibraryStore(rootURL: root)
    defer { try? kernel.close() }
    let repository = SQLiteReportRepository(store: kernel)
    guard case let .created(id) = try await repository.stage(sqliteReportFile("attempt source")) else {
        Issue.record("Expected a draft"); return
    }
    let old = try await repository.beginProcessing(draftID: id, attemptID: UUID())
    let current = try await repository.beginProcessing(draftID: id, attemptID: UUID())
    await #expect(throws: ImportDraftError.staleAttempt) {
        try await repository.completeProcessing(lease: old, document: ImportDraftDocument(blocks: [], candidates: ReportCandidates()))
    }
    #expect(try await repository.draft(id).revision == current.revision)
    #expect(try kernel.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM ocr_documents") } == 0)
}

private func sqliteReportFile(_ text: String) throws -> ValidatedImportedFile {
    let data = Data(text.utf8)
    return try ValidatedImportedFile(data: data, kind: .image, contentTypeIdentifier: "public.png", sha256Digest: ContentDigest.sha256(data))
}

@Test
func sqliteReportSearchMatchesFoundationFieldsAndKeepsPreviewsBounded() async throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let kernel = try SQLiteLibraryStore(rootURL: root)
    defer { try? kernel.close() }
    let repository = SQLiteReportRepository(store: kernel)
    let member = try FamilyMember(displayName: "合成成员", disambiguationLabel: "Household Café")
    try await repository.saveMember(member, replacing: nil)
    let long = "印象:" + String(repeating: "e\u{301}", count: 2_000) + "尾部关键词"
    let record = try await sqliteConfirmedRecord(repository, member: member, seed: "search", conclusion: long)
    let terms = ["", " 成员 ", "HOUSEHOLD", "café", "图像", "Synthetic facility", "科室", "检查", "platelet", "印象", "尾部关键词", "flag", "2026", "private", "rawOCR", "图像Synthetic"]
    for term in terms {
        let actual = try await repository.reportPage(query: term)
        #expect(actual.items.map(\.id) == RecordQuery.search(term, records: [record], members: [member]).map(\.id))
        #expect(actual.damagedIDs.isEmpty)
    }
    let summary = try #require(try await repository.reportPage().items.first)
    #expect(summary.conclusion!.unicodeScalars.count == 512)
    #expect(summary.conclusion!.utf8.count <= 2_048)
    #expect(try await repository.record(record.id).timelineDate == record.timelineDate)
    var renamed = member
    renamed.displayName = "Renamed synthetic member"
    try await repository.saveMember(renamed, replacing: member)
    #expect(try await repository.reportPage(query: "合成成员").items.isEmpty)
    #expect(try await repository.reportPage(query: "Renamed").items.map(\.id) == [record.id])
}

@Test
func sqliteReportPagingReportsDamageAndRejectsStaleCursors() async throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let kernel = try SQLiteLibraryStore(rootURL: root)
    defer { try? kernel.close() }
    let repository = SQLiteReportRepository(store: kernel)
    let member = try FamilyMember(displayName: "Synthetic member")
    try await repository.saveMember(member, replacing: nil)
    var records: [HealthRecord] = []
    for index in 0..<3 { records.append(try await sqliteConfirmedRecord(repository, member: member, seed: "page-\(index)")) }
    records.sort { $0.id.uuidString < $1.id.uuidString }
    try kernel.write { db in try db.execute(sql: "UPDATE reports SET title = 'damaged projection' WHERE record_id = ?", arguments: [records[0].id.sqliteBytes]) }
    let first = try await repository.reportPage(limit: 1)
    #expect(first.items.isEmpty)
    #expect(first.damagedIDs == [records[0].id])
    let cursor = try #require(first.nextCursor)
    let second = try await repository.reportPage(limit: 1, cursor: cursor)
    #expect(second.items.map(\.id) == [records[1].id])
    await #expect(throws: LibraryReportError.staleCursor) { _ = try await repository.reportPage(query: "different", cursor: cursor) }
    var renamed = member; renamed.displayName = "New synthetic member"
    try await repository.saveMember(renamed, replacing: member)
    await #expect(throws: LibraryReportError.staleCursor) { _ = try await repository.reportPage(cursor: cursor) }
    let foreign = LibraryQueryCursor(libraryID: UUID(), commitID: try kernel.state().commitID, openEpoch: kernel.openEpoch, scope: "reports:", memberID: nil, lastID: records[0].id, lastDate: records[0].timelineDate)
    await #expect(throws: LibraryReportError.staleCursor) { _ = try await repository.reportPage(cursor: foreign) }
}

@Test
func sqliteReportColdCorruptionIsIsolatedAndCannotDiscardANewOriginal() async throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let kernel = try SQLiteLibraryStore(rootURL: root)
    defer { try? kernel.close() }
    let repository = SQLiteReportRepository(store: kernel)
    let member = try FamilyMember(displayName: "Synthetic member")
    try await repository.saveMember(member, replacing: nil)
    let damaged = try await sqliteConfirmedRecord(repository, member: member, seed: "damaged")
    let good = try await sqliteConfirmedRecord(repository, member: member, seed: "good")
    try kernel.write { db in
        try db.execute(sql: "UPDATE report_details SET payload = ? WHERE record_id = ?", arguments: [Data("broken".utf8), damaged.id.sqliteBytes])
        try db.execute(sql: "UPDATE ocr_documents SET payload = ? WHERE id = ?", arguments: [Data("broken".utf8), damaged.ocrDocumentObjectID!.sqliteBytes])
    }
    #expect(try await repository.reportPage().items.count == 2)
    #expect(try await repository.reportPage(query: "图像").items.count == 2)
    #expect(try await repository.record(good.id) == good)
    await #expect(throws: SQLiteLibraryError.damaged) { _ = try await repository.record(damaged.id) }
    guard case .created = try await repository.stage(sqliteReportFile("damaged")) else {
        Issue.record("A damaged duplicate must not discard a good newly selected source"); return
    }
    try kernel.write { db in try db.execute(sql: "UPDATE report_search SET fields = ? WHERE record_id = ?", arguments: [Data("[]".utf8), good.id.sqliteBytes]) }
    let page = try await repository.reportPage(query: "unmatched-term")
    #expect(page.items.isEmpty)
    #expect(page.damagedIDs == [good.id])
}

@Test
func sqliteReportReviewAndRecordEditsAreAtomicAndRevisionBound() async throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let kernel = try SQLiteLibraryStore(rootURL: root)
    defer { try? kernel.close() }
    let repository = SQLiteReportRepository(store: kernel)
    let member = try FamilyMember(displayName: "Synthetic member")
    try await repository.saveMember(member, replacing: nil)
    let record = try await sqliteConfirmedRecord(repository, member: member, seed: "edit")
    let updated = try HealthRecord(id: record.id, memberID: record.memberID, sources: record.sources,
        ocrDocumentObjectID: record.ocrDocumentObjectID, importState: .confirmed, revision: record.revision + 1,
        title: SourceField.manualEntry("Updated synthetic title"))
    try await repository.updateRecord(updated, expectedRevision: record.revision)
    let state = try kernel.state()
    await #expect(throws: LibraryReportError.staleRevision) { try await repository.updateRecord(updated, expectedRevision: record.revision) }
    #expect(try kernel.state() == state)
    #expect(try await repository.record(record.id) == updated)
    let result = try await repository.original(recordID: updated.id, expectedRevision: updated.revision, sourceID: updated.sources.first.id)
    #expect(result.1 == Data("edit".utf8))
    await #expect(throws: LibraryReportError.staleRevision) { _ = try await repository.original(recordID: updated.id, expectedRevision: record.revision, sourceID: updated.sources.first.id) }
    await #expect(throws: CatalogDeletionError.memberStillReferenced(recordCount: 1, draftCount: 0)) { try await repository.deleteMember(member.id) }
    let bad = try ValidatedImportedFile(data: Data("different".utf8), kind: .image, contentTypeIdentifier: "public.png", sha256Digest: ContentDigest.sha256(Data("edit".utf8)))
    await #expect(throws: SQLiteLibraryError.invalidOriginal) { _ = try await repository.stage(bad) }
}

@Test
func sqliteReportSharedSourcesKeepMultiplicityAndRejectPageCountMismatch() async throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let kernel = try SQLiteLibraryStore(rootURL: root)
    defer { try? kernel.close() }
    let repository = SQLiteReportRepository(store: kernel)
    let file = try sqliteReportFile("shared synthetic source")
    guard case let .created(id) = try await repository.stage(file) else { Issue.record("Expected draft"); return }
    let first = try await repository.draft(id)
    let sources = try ReportSources([ReportSource(attachmentID: first.sources.first.attachmentID, pageCount: 1), ReportSource(attachmentID: first.sources.first.attachmentID, pageCount: 1)])
    let shared = ImportDraft(sources: sources, state: .needsReview, documentObjectID: UUID())
    try kernel.write { db in
        let digest = try SQLiteReportRows.saveDocument(ImportDraftDocument(blocks: [], candidates: ReportCandidates()),
            id: shared.documentObjectID!, revision: shared.revision, sources: sources, db)
        try SQLiteReportRows.saveDraft(shared, documentHash: digest, db, replaceSources: true)
        try SQLiteLibraryState.advance(in: db)
    }
    try await repository.discard(draftID: first.id, expectedRevision: first.revision)
    #expect(try await repository.draft(shared.id).sources.count == 2)
    guard case .created = try await repository.stage(file) else { Issue.record("Two repeated sources must not deduplicate a one-source import"); return }
    let invalid = ImportDraft(sources: try ReportSources([ReportSource(attachmentID: sources.first.attachmentID, pageCount: 2)]))
    #expect(throws: LibraryReportError.invalidDocument) {
        try kernel.write { db in try SQLiteReportRows.saveDraft(invalid, documentHash: nil, db, replaceSources: true) }
    }
    #expect(try await repository.draft(shared.id).sources == sources)
}

private func sqliteConfirmedRecord(_ repository: SQLiteReportRepository, member: FamilyMember, seed: String, conclusion: String = "Synthetic impression") async throws -> HealthRecord {
    let file = try sqliteReportFile(seed)
    guard case let .created(id) = try await repository.stage(file) else { throw LibraryReportError.invalidDocument }
    let lease = try await repository.beginProcessing(draftID: id, attemptID: UUID())
    let document = ImportDraftDocument(blocks: [], candidates: ReportCandidates())
    try await repository.completeProcessing(lease: lease, document: document)
    let draft = try await repository.draft(id)
    let date = ReportDateCandidate(date: CanonicalVaultJSON.persistenceStableDate(Date(timeIntervalSince1970: 1_786_000_000.0056)), kind: .report, source: try SourceField.manualEntry("Synthetic date"))
    let record = try HealthRecord(memberID: member.id, sources: draft.sources, ocrDocumentObjectID: draft.documentObjectID,
        importState: .confirmed, title: SourceField.manualEntry("图像"), organization: SourceField.manualEntry("Synthetic facility"),
        department: SourceField.manualEntry("科室"), reportType: SourceField.manualEntry("检查"), dateCandidates: [date], timelineDateCandidateID: date.id,
        reportedResults: SourceField.manualEntry("Synthetic platelet result"), conclusion: SourceField.manualEntry(conclusion),
        abnormalItems: [SourceField.manualEntry("flag")], notes: [UserNote(text: "private rawOCR")])
    try await repository.confirm(draftID: id, expectedRevision: draft.revision, record: record)
    return record
}

@Test
func sqliteReportDeletionDefersPinnedOriginalReclamation() async throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let kernel = try SQLiteLibraryStore(rootURL: root)
    let repository = SQLiteReportRepository(store: kernel)
    let member = try FamilyMember(displayName: "Synthetic member")
    try await repository.saveMember(member, replacing: nil)
    let record = try await sqliteConfirmedRecord(repository, member: member, seed: "pinned deletion")
    let id = record.sources.first.attachmentID
    let pin = try kernel.pinOriginal(id)
    try await repository.deleteRecord(record.id, expectedRevision: record.revision)
    #expect(try kernel.read { try SQLiteOriginal.read(id, from: $0).lifecycle } == "deleting")
    #expect(throws: SQLiteLibraryError.invalidOriginal) { _ = try kernel.pinOriginal(id) }
    try pin.withVerifiedDescriptor { descriptor in
        var buffer = [UInt8](repeating: 0, count: 15)
        #expect(pread(descriptor, &buffer, 15, 0) == 15)
        #expect(Data(buffer) == Data("pinned deletion".utf8))
    }
    pin.release()
    try kernel.close()
    let reopened = try SQLiteLibraryStore(rootURL: root)
    defer { try? reopened.close() }
    #expect(try reopened.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM originals WHERE id = ?", arguments: [id.sqliteBytes]) } == 0)
}

@Test
func sqliteReportStageDoesNotBlockUnrelatedRepositoryReadsOrWrites() async throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let gate = SQLiteReportStageGate()
    let kernel = try SQLiteLibraryStore(rootURL: root, originalFault: { point in
        if point == .afterIdentityCommit { gate.pause() }
        return false
    })
    defer { try? kernel.close() }
    let repository = SQLiteReportRepository(store: kernel)
    let file = try sqliteReportFile("paused original")
    let stage = Task { try await repository.stage(file) }
    await gate.waitForEntry()
    let timeout = Thread { gate.releaseAfterDeadline() }
    timeout.start()
    let member = try FamilyMember(displayName: "Concurrent synthetic member")
    try await repository.saveMember(member, replacing: nil)
    #expect(try await repository.members() == [member])
    #expect(gate.isPaused)
    gate.release()
    _ = try await stage.value
}

// SAFETY: condition owns pause state; the dedicated timeout thread cannot occupy a cooperative executor.
private final class SQLiteReportStageGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var released = false
    private var entry: CheckedContinuation<Void, Never>?
    var isPaused: Bool {
        condition.lock(); defer { condition.unlock() }
        return entered && !released
    }
    func waitForEntry() async {
        await withCheckedContinuation { continuation in
            condition.lock()
            if entered { condition.unlock(); continuation.resume() }
            else { entry = continuation; condition.unlock() }
        }
    }
    func pause() {
        condition.lock()
        entered = true
        let continuation = entry; entry = nil
        continuation?.resume()
        while !released { condition.wait() }
        condition.unlock()
    }
    func releaseAfterDeadline() {
        condition.lock()
        let deadline = Date().addingTimeInterval(3)
        while !released, condition.wait(until: deadline) {}
        released = true; condition.broadcast(); condition.unlock()
    }
    func release() {
        condition.lock(); released = true; condition.broadcast(); condition.unlock()
    }
}

@Test
func sqliteReportSearchCancellationStopsTheScanWithoutPoisoningLaterQueries() async throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let kernel = try SQLiteLibraryStore(rootURL: root)
    defer { try? kernel.close() }
    let repository = SQLiteReportRepository(store: kernel)
    let member = try FamilyMember(displayName: "Synthetic member")
    try await repository.saveMember(member, replacing: nil)
    let record = try await sqliteConfirmedRecord(repository, member: member, seed: "cancel search")
    let gate = SQLiteReportStageGate()
    try kernel.write { db in
        db.trace { event in
            if case let .statement(statement) = event, statement.sql.hasPrefix("SELECT r.record_id, r.member_id, r.timeline_date, r.search_hash") { gate.pause() }
        }
    }
    let search = Task { try await repository.reportPage(query: "图像") }
    await gate.waitForEntry()
    search.cancel()
    gate.release()
    await #expect(throws: CancellationError.self) { _ = try await search.value }
    try kernel.write { db in db.trace(nil) }
    #expect(try await repository.reportPage(query: "图像").items.map(\.id) == [record.id])
}

@Test
func sqliteReportOpenEpochRejectsSameLibraryAndRevisionAfterReopening() async throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let kernel = try SQLiteLibraryStore(rootURL: root)
    defer { try? kernel.close() }
    let repository = SQLiteReportRepository(store: kernel)
    let member = try FamilyMember(displayName: "Synthetic member")
    try await repository.saveMember(member, replacing: nil)
    let first = try await sqliteConfirmedRecord(repository, member: member, seed: "epoch one")
    _ = try await sqliteConfirmedRecord(repository, member: member, seed: "epoch two")
    let cursor = try #require(try await repository.reportPage(limit: 1).nextCursor)
    let (record, epoch) = try kernel.readWithEpoch { try SQLiteReportRows.record(first.id, $0) }
    let state = try kernel.state()
    try kernel.closeDatabaseForReplacement()
    try kernel.reopenAfterReplacement()
    #expect(try kernel.state() == state)
    #expect(try await repository.record(first.id) == record)
    #expect(throws: SQLiteLibraryError.staleRoot) {
        try kernel.read(epoch: epoch) { _ in Issue.record("Old read consumed the reopened library") }
    }
    await #expect(throws: LibraryReportError.staleCursor) { _ = try await repository.reportPage(cursor: cursor) }
}

@Test
func sqliteReportConfirmationFailureRollsBackRemovedDraftAndItsSources() async throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let kernel = try SQLiteLibraryStore(rootURL: root)
    defer { try? kernel.close() }
    let repository = SQLiteReportRepository(store: kernel)
    let member = try FamilyMember(displayName: "Synthetic member")
    try await repository.saveMember(member, replacing: nil)
    guard case let .created(id) = try await repository.stage(sqliteReportFile("rollback")) else { Issue.record("Expected draft"); return }
    let lease = try await repository.beginProcessing(draftID: id, attemptID: UUID())
    try await repository.completeProcessing(lease: lease, document: ImportDraftDocument(blocks: [], candidates: ReportCandidates()))
    let draft = try await repository.draft(id)
    let document = try await repository.loadDocument(draftID: id)
    let state = try kernel.state()
    var invalid = try HealthRecord(memberID: member.id, sources: draft.sources, ocrDocumentObjectID: draft.documentObjectID, importState: .confirmed)
    invalid.title = try SourceField(originalTranscription: "Invalid attribution", references: [SourceReference(sourceID: UUID(), attachmentID: UUID(), filePageNumber: 1)])
    await #expect(throws: SQLiteLibraryError.damaged) { try await repository.confirm(draftID: id, expectedRevision: draft.revision, record: invalid) }
    #expect(try kernel.state() == state)
    #expect(try await repository.draft(id) == draft)
    #expect(try await repository.loadDocument(draftID: id) == document)
    #expect(try await repository.reportPage().items.isEmpty)
}

@Test
func sqliteReportOriginalCorruptionRejectsOnlyItsConsumerAndDuplicateClaim() async throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let kernel = try SQLiteLibraryStore(rootURL: root)
    defer { try? kernel.close() }
    let repository = SQLiteReportRepository(store: kernel)
    let member = try FamilyMember(displayName: "Synthetic member")
    try await repository.saveMember(member, replacing: nil)
    let record = try await sqliteConfirmedRecord(repository, member: member, seed: "original bytes")
    let originalID = record.sources.first.attachmentID
    let path = root.appendingPathComponent("originals/\(originalID.uuidString.lowercased()).data")
    let descriptor = Darwin.open(path.path, O_WRONLY | O_NOFOLLOW)
    try #require(descriptor >= 0)
    let replacement = [UInt8](repeating: 42, count: 14)
    #expect(Darwin.write(descriptor, replacement, replacement.count) == replacement.count)
    Darwin.close(descriptor)
    #expect(try await repository.reportPage().items.map(\.id) == [record.id])
    await #expect(throws: SQLiteLibraryError.invalidOriginal) {
        _ = try await repository.original(recordID: record.id, expectedRevision: record.revision, sourceID: record.sources.first.id)
    }
    guard case .created = try await repository.stage(sqliteReportFile("original bytes")) else { Issue.record("A damaged original must not discard a new intact copy"); return }
}

@Test
func sqliteReportStageRejectsBytesChangedAfterPublicationHash() async throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let store = try SQLiteLibraryStore(rootURL: root, originalFault: { point in
        guard point == .afterRename else { return false }
        do { try sqliteMutateOriginal(root: root, extension: "data", mutation: "overwrite") }
        catch { Issue.record(error) }
        return false
    })
    defer { try? store.close() }
    let repository = SQLiteReportRepository(store: store)
    await #expect(throws: SQLiteLibraryError.invalidOriginal) {
        _ = try await repository.stage(sqliteReportFile("synthetic report publication fence"))
    }
    #expect(try store.state().generation == 0)
    #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM import_drafts") } == 0)
    #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM report_sources") } == 0)
}

@Test
func sqliteApplicationQueriesIsolateDamagedMemberFromUnrelatedSearch() async throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let store = try SQLiteLibraryStore(rootURL: root)
    defer { try? store.close() }
    let repository = SQLiteReportRepository(store: store)
    let damaged = try FamilyMember(displayName: "Damaged synthetic member")
    let good = try FamilyMember(displayName: "Good synthetic member")
    try await repository.saveMember(damaged, replacing: nil)
    try await repository.saveMember(good, replacing: nil)
    let record = try await sqliteConfirmedRecord(repository, member: good, seed: "isolated member")
    try store.write { db in
        try db.execute(sql: "UPDATE members SET display_name='Damaged payload', summary_name='Damaged preview' WHERE id=?", arguments: [damaged.id.sqliteBytes])
    }
    let header = try await repository.header()
    #expect(header.members.map(\.id) == [good.id])
    #expect(header.damagedMemberIDs == [damaged.id])
    #expect(try await repository.reportPage(query: "图像").items.map(\.id) == [record.id])
    #expect(try await repository.reportPage(query: "图像").damagedMemberIDs == [damaged.id])
    await #expect(throws: SQLiteLibraryError.damaged) { _ = try await repository.member(damaged.id) }
}

@Test
func sqliteApplicationHeaderKeepsMemberTextColdAndPreservesFullEdits() async throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let store = try SQLiteLibraryStore(rootURL: root)
    defer { try? store.close() }
    let repository = SQLiteReportRepository(store: store)
    let member = try FamilyMember(displayName: String(repeating: "e\u{301}", count: 600_000) + "Full-name-tail")
    try await repository.saveMember(member, replacing: nil)
    let header = try await repository.header()
    #expect(header.members.first?.displayName.unicodeScalars.count == 160)
    #expect(try await repository.member(member.id) == member)
    var changed = try await repository.member(member.id)
    changed.disambiguationLabel = "Synthetic label"
    try await repository.saveMember(changed, replacing: member)
    #expect(try await repository.member(member.id).displayName == member.displayName)
    // Cold corruption is discovered by a consumer of full text, without materializing it at startup.
    try store.write { db in try db.execute(sql: "UPDATE members SET display_name='Broken cold member' WHERE id=?", arguments: [member.id.sqliteBytes]) }
    #expect(try await repository.header().damagedMemberIDs.isEmpty)
    let search = try await repository.reportPage(query: "Full-name-tail")
    #expect(search.damagedMemberIDs == [member.id])
    await #expect(throws: SQLiteLibraryError.damaged) { _ = try await repository.member(member.id) }
}

@Test
func sqliteApplicationSelectionAndOriginalAreCoherentAcrossEpochs() async throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let store = try SQLiteLibraryStore(rootURL: root)
    defer { try? store.close() }
    let repository = SQLiteReportRepository(store: store)
    let member = try FamilyMember(displayName: "Synthetic selection member")
    try await repository.saveMember(member, replacing: nil)
    let first = try await sqliteConfirmedRecord(repository, member: member, seed: "first original")
    let second = try await sqliteConfirmedRecord(repository, member: member, seed: "second original")
    let selection = try await repository.recordSelection([second.id, first.id])
    #expect(selection.records == [second, first])
    #expect(selection.revision.commitID == (try store.state()).commitID)
    let before = try await repository.original(recordID: first.id, expectedRevision: first.revision,
        sourceID: first.sources.first.id, expectedLibrary: selection.revision)
    #expect(before.1 == Data("first original".utf8))
    try store.closeDatabaseForReplacement()
    try store.reopenAfterReplacement()
    #expect(try await repository.recordSelection([first.id]).revision.openEpoch != selection.revision.openEpoch)
    await #expect(throws: SQLiteLibraryError.staleRoot) {
        _ = try await repository.original(recordID: first.id, expectedRevision: first.revision,
            sourceID: first.sources.first.id, expectedLibrary: selection.revision)
    }
}

@Test
func sqliteCommitHintsPublishOnlyCommittedBusinessChangesAndEndWhenClosed() async throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let store = try SQLiteLibraryStore(rootURL: root)
    let repository = SQLiteReportRepository(store: store)
    let changes = store.changes()
    var iterator = changes.makeAsyncIterator()
    try store.write { _ in () }
    #expect(throws: SQLiteLibraryError.injectedFailure) {
        try store.write { db in
            try SQLiteLibraryState.advance(in: db)
            throw SQLiteLibraryError.injectedFailure
        }
    }
    // Metadata staging and rollback must not produce a business revision.
    _ = try sqliteStage(Data("staged synthetic original".utf8), in: store, operationID: UUID())
    #expect(try store.state().generation == 0)
    try store.closeDatabaseForReplacement()
    #expect(await iterator.next() == nil)
    try store.reopenAfterReplacement()
    let live = store.changes()
    var events = live.makeAsyncIterator()
    try await repository.saveMember(FamilyMember(displayName: "Synthetic observed member"), replacing: nil)
    let memberEvent = try #require(await events.next())
    #expect(memberEvent.generation == 1)
    #expect(memberEvent.commitID == (try store.state()).commitID)
    _ = try await repository.stage(sqliteReportFile("published synthetic report"))
    let importEvent = try #require(await events.next())
    #expect(importEvent.generation == 2)
    #expect(importEvent.openEpoch == store.openEpoch)
    try store.close()
    #expect(await events.next() == nil)
}

@Test
func sqliteSearchPrefilterPreservesFoundationLocaleUnicodeAndFieldBoundaries() {
    let fields = ["cafe\u{301}", "CAFÉ", "Iİıi", "Σσς", "ß SS", "a\u{0}b", "Å A\u{30a}", "合成中文", "👩‍👩‍👧‍👦", "a\u{ad}b", "e\u{34f}\u{301}"]
    let queries = fields + ["a", "i", "e\u{301}", "a b", "bCAF", "合", "SS", "\u{0}", "\u{301}"]
    for identifier in ["en_US", "zh_Hans_CN", "tr_TR", "az_AZ", "lt_LT", "el_GR", "ja_JP", "de_DE", "fr_FR"] {
        let locale = Locale(identifier: identifier)
        for query in queries {
            let predicate = SQLiteReportSearch.Predicate(query, locale: locale)
            for start in fields.indices {
                let values = Array(fields.dropFirst(start).prefix(3))
                let expected = values.contains { $0.range(of: query, options: .caseInsensitive, locale: locale) != nil }
                #expect(predicate.matches(values, prefilter: true) == expected)
            }
        }
    }
}

@Test
func sqliteSearchSkipsOversizedColdBlobBeforeMaterializingAndKeepsTheNextQueryUsable() async throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let store = try SQLiteLibraryStore(rootURL: root)
    defer { try? store.close() }
    let reports = SQLiteReportRepository(store: store)
    let member = try FamilyMember(displayName: "Synthetic oversize search")
    try await reports.saveMember(member, replacing: nil)
    let bad = try await sqliteConfirmedRecord(reports, member: member, seed: "bad search blob")
    let good = try await sqliteConfirmedRecord(reports, member: member, seed: "good search blob")
    try store.write { db in
        try db.execute(sql: "PRAGMA ignore_check_constraints=ON")
        defer { try? db.execute(sql: "PRAGMA ignore_check_constraints=OFF") }
        try db.execute(sql: "UPDATE report_search SET fields=zeroblob(?) WHERE record_id=?",
            arguments: [LibraryStorageLimits.maximumEntityJSONBytes + 1, bad.id.sqliteBytes])
    }
    let page = try await reports.reportPage(query: "图像")
    #expect(page.items.map(\.id) == [good.id])
    #expect(page.damagedIDs == [bad.id])
    let scan = try await reports.measureReportSearch("图像")
    #expect(scan.peakBatchBytes < SQLiteReportSearch.batchByteLimit)
    #expect(scan.ids == [good.id])
    #expect(try await reports.reportPage().items.count == 2)
}

// Legal domain strings must round-trip exactly; embedded NUL is not a storage delimiter.
@Test
func sqliteTextFidelityMemberPreservesEmbeddedNUL() async throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let kernel = try SQLiteLibraryStore(rootURL: root)
    defer { try? kernel.close() }
    let repository = SQLiteReportRepository(store: kernel)
    let member = try FamilyMember(displayName: "Synthetic\0member e\u{301}", disambiguationLabel: "Label\0尾部")
    try await repository.saveMember(member, replacing: nil)
    #expect(try await repository.member(member.id) == member)
    let header = try await repository.header()
    #expect(header.members.first?.displayName == member.displayName)
    #expect(header.damagedMemberIDs.isEmpty)
    var edited = member
    edited.displayName += "\0edited"
    try await repository.saveMember(edited, replacing: member)
    try kernel.close()
    let reopened = try SQLiteLibraryStore(rootURL: root)
    defer { try? reopened.close() }
    #expect(try await SQLiteReportRepository(store: reopened).member(member.id) == edited)
}

@Test
func sqliteTextFidelityReportSummaryPreservesEmbeddedNUL() async throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let kernel = try SQLiteLibraryStore(rootURL: root)
    defer { try? kernel.close() }
    let repository = SQLiteReportRepository(store: kernel)
    let member = try FamilyMember(displayName: "Synthetic member")
    try await repository.saveMember(member, replacing: nil)
    let record = try await sqliteConfirmedRecord(repository, member: member, seed: "text fidelity", conclusion: "Synthetic\0tail")
    #expect(try await repository.record(record.id) == record)
    let page = try await repository.reportPage()
    #expect(page.items.first?.conclusion == "Synthetic\0tail")
    #expect(page.damagedIDs.isEmpty)
    #expect(try await repository.reportPage(query: "tail").items.map(\.id) == [record.id])
    let edited = try HealthRecord(id: record.id, memberID: record.memberID, sources: record.sources,
        ocrDocumentObjectID: record.ocrDocumentObjectID, importState: .confirmed, revision: record.revision + 1,
        title: SourceField.manualEntry("Title\0尾部"), organization: SourceField.manualEntry("Org\0e\u{301}"),
        reportType: SourceField.manualEntry("Type\0updated"), conclusion: SourceField.manualEntry("New\0conclusion"))
    try await repository.updateRecord(edited, expectedRevision: record.revision)
    #expect(try await repository.record(edited.id) == edited)
    for query in ["尾部", "updated", "conclusion", "tail"] {
        #expect(try await repository.reportPage(query: query).items.map(\.id) == RecordQuery.search(query, records: [edited], members: [member]).map(\.id))
    }
}

@Test
func sqliteTextFidelityRejectsInvalidUTF8WithoutHidingGoodRows() async throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let kernel = try SQLiteLibraryStore(rootURL: root)
    defer { try? kernel.close() }
    let repository = SQLiteReportRepository(store: kernel)
    let member = try FamilyMember(displayName: "Synthetic malformed text")
    try await repository.saveMember(member, replacing: nil)
    let good = try await sqliteConfirmedRecord(repository, member: member, seed: "good UTF-8")
    let bad = try await sqliteConfirmedRecord(repository, member: member, seed: "bad UTF-8")
    try kernel.write { db in
        try db.execute(sql: "UPDATE reports SET title=CAST(X'ff' AS TEXT) WHERE record_id=?", arguments: [bad.id.sqliteBytes])
        try db.execute(sql: "UPDATE members SET summary_name=CAST(X'ff' AS TEXT) WHERE id=?", arguments: [member.id.sqliteBytes])
    }
    let page = try await repository.reportPage()
    #expect(page.items.map(\.id) == [good.id])
    #expect(page.damagedIDs == [bad.id])
    #expect(try await repository.header().damagedMemberIDs == [member.id])
    await #expect(throws: SQLiteLibraryError.damaged) { _ = try await repository.record(bad.id) }
    await #expect(throws: (any Error).self) { _ = try await SQLiteLogicalBackupSource(store: kernel).prepare() }
}
