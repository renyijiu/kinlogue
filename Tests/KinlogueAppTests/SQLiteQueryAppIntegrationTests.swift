import Foundation
import GRDB
import Testing
@testable import KinlogueApp
@testable import KinlogueCore
@testable import KinloguePlatform

@Suite(.serialized)
@MainActor
struct SQLiteQueryAppIntegrationTests {
    @Test
    func reviewOutsideTheFirstDraftPageOpensByID() async throws {
        let fixture = try SQLiteAppQueryFixture()
        defer { fixture.destroy() }
        var ids: [UUID] = []
        for index in 0..<101 {
            let bytes = Data("synthetic off-page review \(index)".utf8)
            let file = try ValidatedImportedFile(data: bytes, kind: .image, contentTypeIdentifier: "public.png", sha256Digest: ContentDigest.sha256(bytes))
            guard case .created(let id) = try await fixture.reports.stage(file) else { throw LibraryReportError.invalidDocument }
            let lease = try await fixture.reports.beginProcessing(draftID: id, attemptID: UUID())
            try await fixture.reports.completeProcessing(lease: lease, document: ImportDraftDocument(blocks: [], candidates: ReportCandidates()))
            ids.append(id)
        }
        let model = AppModel(service: fixture.service())
        await model.start()
        #expect(model.reviewQueue.count == 100)
        let target = try #require(ids.first { id in !model.reviewQueue.contains { $0.id == id } })
        await model.presentReviewDraft(target)
        #expect(model.reviewDraftID == target)
        let review = model.makeReviewModel(draftID: target)
        await review.load()
        #expect(!review.loadFailed && review.originalDocument != nil)
        await model.beginDestructiveVaultLifecycle()
        review.closeReview()
    }

    @Test
    func coldItemDamageStaysLocalButTargetDatabaseFailureLocksEvenWithReadableHeader() async throws {
        let fixture = try SQLiteAppQueryFixture()
        defer { fixture.destroy() }
        let member = try FamilyMember(displayName: "Synthetic error classification")
        try await fixture.reports.saveMember(member, replacing: nil)
        let damaged = try await fixture.confirmed(member: member, seed: "damaged target")
        let good = try await fixture.confirmed(member: member, seed: "good target")
        let model = AppModel(service: fixture.service())
        await model.start()
        try fixture.store.write { db in
            try db.execute(sql: "UPDATE report_details SET payload=? WHERE record_id=?", arguments: [Data("broken".utf8), damaged.id.sqliteBytes])
        }
        await model.selectRecord(damaged.id)
        #expect(model.phase == .ready)
        await model.selectRecord(good.id)
        #expect(model.selectedRecord?.id == good.id)
        try fixture.store.write { db in try db.execute(sql: "DROP TABLE report_details") }
        #expect(try await fixture.reports.header().reportCount == 2)
        await model.selectRecord(good.id)
        #expect(model.phase == .locked)
        #expect(model.members.isEmpty && model.timelineSections.isEmpty && model.selectedRecord == nil)
    }

    @Test
    func damagedDraftAndPendingStudyRemainVisibleAsDamageWithoutLockingTheLibrary() async throws {
        let fixture = try SQLiteAppQueryFixture()
        defer { fixture.destroy() }
        let bytes = Data("synthetic damaged draft".utf8)
        guard case .created(let id) = try await fixture.reports.stage(ValidatedImportedFile(data: bytes,
            kind: .image, contentTypeIdentifier: "public.png", sha256Digest: ContentDigest.sha256(bytes))) else {
            Issue.record("Expected synthetic draft"); return
        }
        let studyID = UUID()
        try fixture.store.write { db in
            try db.execute(sql: "UPDATE import_drafts SET content_hash=zeroblob(32) WHERE draft_id=?", arguments: [id.sqliteBytes])
            try db.execute(sql: """
                INSERT INTO dicom_studies VALUES (?, 'needsReview', NULL, NULL, ?, zeroblob(32), 1,
                zeroblob(32), 'synthetic', 1, 0, 1, 2, 0, 1, 0, 0, zeroblob(32), zeroblob(32), zeroblob(32))
                """, arguments: [studyID.sqliteBytes, UUID().sqliteBytes])
        }
        let model = AppModel(service: fixture.service())
        await model.start()
        #expect(model.phase == .ready)
        #expect(model.damagedItemIDs.contains(id))
        #expect(model.damagedItemIDs.contains(studyID))
        #expect(model.reviewQueue.isEmpty && model.dicomLibraryModel.studies.isEmpty)
    }

    @Test
    func realServicePagesSummariesOpensOffPageIDsComparesTwoAndRetainsLongMemberEdits() async throws {
        let fixture = try SQLiteAppQueryFixture()
        defer { fixture.destroy() }
        let member = try FamilyMember(displayName: String(repeating: "合成成员", count: 60))
        try await fixture.reports.saveMember(member, replacing: nil)
        var records: [HealthRecord] = []
        for index in 0..<103 { records.append(try await fixture.confirmed(member: member, seed: "synthetic-\(index)")) }
        let service = fixture.service()
        let model = AppModel(service: service)
        await model.start()
        #expect(model.phase == .ready)
        #expect(model.members.first?.displayName.unicodeScalars.count == 160)
        #expect(model.timelineSections.flatMap(\.records).count == 100)
        #expect(model.hasMoreRecords)
        let expected = records.sorted { $0.id.uuidString < $1.id.uuidString }
        let offPage = expected[102]
        await model.selectRecord(offPage.id)
        #expect(model.selectedRecord == offPage)
        #expect(model.originalDocument?.data == Data("synthetic-\(records.firstIndex { $0.id == offPage.id }!)".utf8))
        await model.loadNextRecordsPage()
        #expect(model.timelineSections.flatMap(\.records).map(\.id) == expected.map(\.id))
        #expect(!model.hasMoreRecords)
        await model.presentMemberEditor(try #require(model.members.first))
        #expect(model.editingMember == member)
        model.isMemberEditorPresented = false; model.editingMember = nil
        model.comparisonModel.startSelection()
        model.comparisonModel.toggle(LibraryReportSummary(record: offPage))
        model.comparisonModel.toggle(LibraryReportSummary(record: expected[0]))
        await model.comparisonModel.openComparison()
        #expect(model.comparisonModel.comparison?.left.recordID == offPage.id)
        #expect(model.comparisonModel.comparison?.right.recordID == expected[0].id)
        #expect(model.comparisonModel.leftOriginal != nil && model.comparisonModel.rightOriginal != nil)
        model.comparisonModel.closeComparison()
        model.searchText = "does-not-exist"
        #expect(model.searchResults.isEmpty)
        #expect(model.pageState == .loading)
        await model.waitForCurrentPage()
        #expect(model.pageState == .loaded && model.searchResults.isEmpty)
        #expect(model.selectedRecord?.id == offPage.id)
        await model.beginDestructiveVaultLifecycle()
        #expect(model.selectedRecord == nil && model.members.isEmpty)
    }

    @Test
    func realSearchKeepsFoundationUnicodeAndConfirmedFieldsSemantics() async throws {
        let fixture = try SQLiteAppQueryFixture()
        defer { fixture.destroy() }
        let member = try FamilyMember(displayName: "Élodie 合成成员")
        try await fixture.reports.saveMember(member, replacing: nil)
        let first = try await fixture.confirmed(member: member, seed: "one", conclusion: "cafe\u{301} 中文检查")
        let second = try await fixture.confirmed(member: member, seed: "two", conclusion: "CAFE synthetic source")
        let service = fixture.service()
        _ = try await service.bootstrap()
        for query in ["CAFÉ", "cafe\u{301}", "中", "检查", "élodie", "合成", "cafe", "raw OCR hidden", "private note", first.id.uuidString] {
            let actual = try await service.reportPage(query: query, memberID: nil, cursor: nil)
            let expected = RecordQuery.search(query, records: [first, second], members: [member])
            #expect(actual.items.map(\.id) == expected.map(\.id))
        }
    }

    @Test
    func successfulSQLCommitHintsAndMissedHintsConvergeTheAppAndBackupSignal() async throws {
        let fixture = try SQLiteAppQueryFixture()
        defer { fixture.destroy() }
        let service = fixture.service()
        let model = AppModel(service: service)
        var notifications = 0
        let observer = AppLibraryObservationCoordinator(subscribe: { fixture.store.changes() }, reconcile: {
            guard model.phase == .ready else { return nil }
            await model.refresh()
            return model.currentLibraryRevision
        }, onDurableChange: { notifications += 1 })
        observer.install()
        await model.start()
        await observer.reconcile()
        let member = try FamilyMember(displayName: "Synthetic background member")
        try await fixture.reports.saveMember(member, replacing: nil)
        await observer.reconcile()
        #expect(model.members.map(\.id) == [member.id])
        #expect(notifications == 1)
        let record = try await fixture.confirmed(member: member, seed: "background report")
        await observer.reconcile()
        #expect(model.timelineSections.flatMap(\.records).map(\.id) == [record.id])
        let previous = notifications
        // Terminate this hint source, deliberately drop subsequent delivery, then reconcile on activation.
        fixture.store.notifications.finish()
        let changed = try FamilyMember(id: member.id, displayName: "Synthetic renamed member")
        try await fixture.reports.saveMember(changed, replacing: member)
        await observer.reconcile()
        #expect(model.members.first?.displayName == changed.displayName)
        #expect(notifications == previous + 1)
        let settled = notifications
        await observer.reconcile()
        #expect(notifications == settled)
        // A terminated source is reconstructed before the activation read. Later commits must
        // again arrive through the subscriber, without a manual refresh masking a dead task.
        for _ in 0..<30 { await Task.yield() }
        observer.install()
        let latest = try FamilyMember(id: member.id, displayName: "Synthetic reconstructed observer")
        try await fixture.reports.saveMember(latest, replacing: changed)
        for _ in 0..<200 {
            if model.members.first?.displayName == latest.displayName, notifications == settled + 1 { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(model.members.first?.displayName == latest.displayName)
        #expect(notifications == settled + 1)
        await observer.stop()
        await model.beginDestructiveVaultLifecycle()
    }
}

struct SQLiteAppQueryFixture: Sendable {
    let base: URL
    let store: SQLiteLibraryStore
    let reports: SQLiteReportRepository
    let studies: SQLiteDICOMRepository
    init() throws {
        base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("kinlogue-sqlite-app-query-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        store = try SQLiteLibraryStore(rootURL: base.appendingPathComponent("Library"))
        reports = SQLiteReportRepository(store: store)
        studies = try SQLiteDICOMRepository(store: store)
    }
    func service() -> LiveAppService {
        LiveAppService(reports: reports, studies: studies, draftStore: reports,
            workflow: ImportWorkflow(store: reports, textExtractor: SQLiteAppQueryExtractor()))
    }
    func confirmed(member: FamilyMember, seed: String, conclusion: String = "Synthetic confirmed source") async throws -> HealthRecord {
        let bytes = Data(seed.utf8)
        let file = try ValidatedImportedFile(data: bytes, kind: .image, contentTypeIdentifier: "public.png", sha256Digest: ContentDigest.sha256(bytes))
        guard case .created(let id) = try await reports.stage(file) else { throw LibraryReportError.invalidDocument }
        let lease = try await reports.beginProcessing(draftID: id, attemptID: UUID())
        try await reports.completeProcessing(lease: lease, document: ImportDraftDocument(blocks: [], candidates: ReportCandidates()))
        let draft = try await reports.draft(id)
        let record = try HealthRecord(id: id, memberID: member.id, sources: draft.sources, ocrDocumentObjectID: draft.documentObjectID,
            importState: .confirmed, conclusion: SourceField.manualEntry(conclusion), notes: [UserNote(text: "private note")])
        try await reports.confirm(draftID: id, expectedRevision: draft.revision, record: record)
        return record
    }
    func destroy() { try? store.close(); try? FileManager.default.removeItem(at: base) }
}

private struct SQLiteAppQueryExtractor: TextExtractionService {
    func extractText(from file: ValidatedImportedFile) async throws -> [OCRBlock] { [] }
}
