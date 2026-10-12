import Darwin
import Foundation
import GRDB
import Testing
@testable import KinlogueCore
@testable import KinloguePlatform

@Test
func sqliteEntityMemberRejectsOversizeCreateAndReplacementAtomically() async throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let store = try SQLiteLibraryStore(rootURL: root)
    defer { try? store.close() }
    let repository = SQLiteReportRepository(store: store)
    let member = try FamilyMember(displayName: "Synthetic")
    try await repository.saveMember(member, replacing: nil)
    let before = try store.state()
    var oversized = member
    // Raw bytes fit; JSON's six-byte escape of U+0001 exceeds the entity budget.
    oversized.displayName = String(repeating: "\u{1}", count: 3 * 1_024 * 1_024)
    await #expect(throws: LibraryReportError.resourceLimit) { try await repository.saveMember(oversized, replacing: member) }
    #expect(try await repository.member(member.id) == member)
    let another = try FamilyMember(displayName: oversized.displayName)
    await #expect(throws: LibraryReportError.resourceLimit) { try await repository.saveMember(another, replacing: nil) }
    #expect(try store.state() == before)
}

@Test
func sqliteEntityDraftRejectsWholeOwnerEscapedSourceBudget() async throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let store = try SQLiteLibraryStore(rootURL: root)
    defer { try? store.close() }
    let repository = SQLiteReportRepository(store: store)
    guard case let .created(id) = try await repository.stage(entityBoundsFile()) else { Issue.record("Missing draft"); return }
    let initial = try await repository.draft(id)
    let name = String(repeating: "\u{1}", count: 1_500_000)
    let sources = try ReportSources((0..<2).map { _ in try ReportSource(attachmentID: initial.sources.first.attachmentID, displayName: name, pageCount: 1) })
    let invalid = ImportDraft(sources: sources)
    let before = try store.state()
    #expect(throws: LibraryReportError.resourceLimit) {
        try store.write { db in
            try SQLiteReportRows.saveDraft(invalid, documentHash: nil, db, replaceSources: true)
            try SQLiteLibraryState.advance(in: db)
        }
    }
    #expect(try store.state() == before)
    #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM import_drafts") } == 1)
    #expect(try await repository.draft(id) == initial)
}

@Test
func sqliteEntityRejectedPublicationReclaimsOnlyItsOwnedOriginal() async throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let store = try SQLiteLibraryStore(rootURL: root)
    defer { try? store.close() }
    let repository = SQLiteReportRepository(store: store)
    guard case let .created(id) = try await repository.stage(entityBoundsFile()) else { Issue.record("Missing draft"); return }
    let initial = try await repository.draft(id)
    try store.write { db in
        let current = try SQLiteLibraryState.read(from: db)
        let exhausted = SQLiteLibraryState(libraryID: current.libraryID, generation: Int64.max, commitID: current.commitID)
        try db.execute(sql: "UPDATE library_state SET generation=?,content_hash=?", arguments: [exhausted.generation, exhausted.contentHash])
    }
    let unrelated = try sqliteStage(Data("another operation's synthetic staging".utf8), in: store, operationID: UUID())
    let before = try store.state()
    await #expect(throws: CatalogDeletionError.generationExhausted) { _ = try await repository.stage(entityBoundsFile("another synthetic source")) }
    #expect(try store.state() == before)
    #expect(try await repository.draft(id) == initial)
    #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM originals") } == 2)
    #expect(try store.read { try SQLiteOriginal.read(unrelated, from: $0).lifecycle } == "staged")
    #expect(try FileManager.default.contentsOfDirectory(atPath: store.originalsURL.path).count == 2)
}

@Test(arguments: [SQLiteOriginalFaultPoint.afterRegistration, .afterIdentityCommit, .afterFileSync, .afterRename, .afterLiveCommit])
func sqliteEntityStageFaultCleansUnreturnedIDsAndReconcilesLiveCommit(point: SQLiteOriginalFaultPoint) async throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let store = try SQLiteLibraryStore(rootURL: root, originalFault: { $0 == point })
    defer { try? store.close() }
    let repository = SQLiteReportRepository(store: store)
    if point == .afterLiveCommit {
        guard case let .created(id) = try await repository.stage(entityBoundsFile()) else { Issue.record("Missing reconciled draft"); return }
        #expect(try await repository.draft(id).state == .staging)
        #expect(try store.state().generation == 1)
    } else {
        await #expect(throws: SQLiteLibraryError.injectedFailure) { _ = try await repository.stage(entityBoundsFile()) }
        #expect(try store.state().generation == 0)
        #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM originals") } == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.originalsURL.path).isEmpty)
    }
}

private func entityBoundsFile(_ text: String = "synthetic bounds source") throws -> ValidatedImportedFile {
    let data = Data(text.utf8)
    return try ValidatedImportedFile(data: data, kind: .image, contentTypeIdentifier: "public.png", sha256Digest: ContentDigest.sha256(data))
}

@Test(arguments: 0..<5)
func sqliteEntityEscapedTextBudgetMatchesCanonicalEncoder(index: Int) throws {
    let cases = ["quoted\"name", "back\\slash", "path/slash", "\u{0}\u{1}\u{8}\u{9}\u{a}\u{c}\u{d}\u{1f}", "合成😀e\u{301}\u{2028}\u{2029}"]
    let text = cases[index]
    let encoded = try CanonicalVaultJSON.encode(text)
    var remaining = encoded.count - 2
    try SQLiteEntityBudget.consumeText(text, remaining: &remaining)
    #expect(remaining == 0)
    var insufficient = encoded.count - 3
    #expect(throws: LibraryReportError.resourceLimit) { try SQLiteEntityBudget.consumeText(text, remaining: &insufficient) }
}

@Test
func sqliteEntityMemberExactCanonicalBoundarySurvivesLogicalCapture() async throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let store = try SQLiteLibraryStore(rootURL: root)
    defer { try? store.close() }
    let repository = SQLiteReportRepository(store: store)
    var member = try FamilyMember(displayName: "x", disambiguationLabel: "Synthetic")
    let overhead = try CanonicalVaultJSON.encode(member).count - 1
    member.displayName = String(repeating: "/", count: LibraryStorageLimits.maximumEntityJSONBytes - overhead)
    #expect(try CanonicalVaultJSON.encode(member).count == LibraryStorageLimits.maximumEntityJSONBytes)
    try await repository.saveMember(member, replacing: nil)
    #expect(try await repository.member(member.id) == member)
    let before = try store.state()
    var oversized = member; oversized.displayName += "x"
    await #expect(throws: LibraryReportError.resourceLimit) { try await repository.saveMember(oversized, replacing: member) }
    #expect(try store.state() == before)
    let snapshot = try await SQLiteLogicalBackupSource(store: store).prepare()
    defer { snapshot.release() }
    try snapshot.validate()
    let records = try snapshot.logicalRecordsForTesting()
    #expect(try records.first { $0.kind == .member }?.decode(FamilyMember.self) == member)
    let restored = try SQLiteLibraryStore(rootURL: root.deletingLastPathComponent().appendingPathComponent("Restored"))
    defer { try? restored.close() }
    _ = try SQLiteLogicalRestore.restore(spool: snapshot.spool, manifest: snapshot.manifest(), store: restored)
    #expect(try await SQLiteReportRepository(store: restored).member(member.id) == member)
}

@Test
func sqliteEntityDraftHeaderBudgetCoversEveryLegalLifecycleState() throws {
    let id = UUID()
    let small = try ReportSources([ReportSource(attachmentID: id, displayName: "x", pageCount: Int.max)])
    let header = try SQLiteEntityBudget.maximumDraftHeaderBytes.get()
    let nameCount = LibraryStorageLimits.maximumEntityJSONBytes - header - (try CanonicalVaultJSON.encode(small).count - 1)
    let sources = try ReportSources([ReportSource(id: small.first.id, attachmentID: id, displayName: String(repeating: "x", count: nameCount), pageCount: Int.max)])
    let states: [(ImportState, UUID?, UUID?, ImportFailureCode?)] = [
        (.staging, nil, nil, nil), (.processing, id, nil, nil), (.needsReview, nil, id, nil)
    ] + ImportFailureCode.allCases.map { (.failed, nil, nil, $0) }
    var maximum = 0
    for (state, attempt, document, failure) in states {
        let draft = ImportDraft(id: id, sources: sources, state: state, revision: UInt64(Int64.max), attemptID: attempt, documentObjectID: document, failureCode: failure, memberID: id)
        #expect(draft.isStructurallyValid)
        maximum = max(maximum, try SQLiteEntityBudget.draftData(draft).count)
    }
    #expect(maximum == LibraryStorageLimits.maximumEntityJSONBytes)
    let over = try ReportSources([ReportSource(attachmentID: id, displayName: sources.first.displayName! + "x", pageCount: Int.max)])
    #expect(throws: LibraryReportError.resourceLimit) { _ = try SQLiteEntityBudget.draftData(ImportDraft(sources: over)) }
}

@Test
func sqliteEntityReadPreflightRejectsOversizedRowsBeforeHashingTheirContents() async throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let store = try SQLiteLibraryStore(rootURL: root)
    defer { try? store.close() }
    let repository = SQLiteReportRepository(store: store)
    let member = try FamilyMember(displayName: "Synthetic")
    try await repository.saveMember(member, replacing: nil)
    guard case let .created(id) = try await repository.stage(entityBoundsFile()) else { Issue.record("Missing draft"); return }
    let original = try await repository.draft(id).sources.first.attachmentID
    try store.write { db in
        // A damaged row exceeds the raw-byte bound. A full row/hash read would return damaged.
        try db.execute(sql: "UPDATE members SET display_name=CAST(zeroblob(?) AS TEXT) WHERE id=?", arguments: [LibraryStorageLimits.maximumEntityJSONBytes + 1, member.id.sqliteBytes])
        try db.execute(sql: "UPDATE report_sources SET display_name=CAST(zeroblob(?) AS TEXT) WHERE original_id=?", arguments: [9 * 1_024 * 1_024, original.sqliteBytes])
        try db.execute(sql: "INSERT INTO report_sources SELECT ?,?,report_id,draft_id,1,original_id,page_count,display_name,content_hash FROM report_sources WHERE original_id=?", arguments: [UUID().sqliteBytes, UUID().sqliteBytes, original.sqliteBytes])
    }
    await #expect(throws: LibraryReportError.resourceLimit) { _ = try await repository.member(member.id) }
    await #expect(throws: LibraryReportError.resourceLimit) { _ = try await repository.draft(id) }
    // The empty hot query does not need either unrelated damaged entity.
    #expect(try await repository.reportPage().items.isEmpty)
}

@Test(arguments: [SQLiteOriginalFaultPoint.afterFileSync, .afterRename])
func sqliteEntityFailedStagePreservesReplacementInode(point: SQLiteOriginalFaultPoint) async throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let suffix = point == .afterFileSync ? "staged" : "data"
    let store = try SQLiteLibraryStore(rootURL: root, originalFault: { current in
        guard current == point else { return false }
        do { try sqliteMutateOriginal(root: root, extension: suffix, mutation: "replace") }
        catch { Issue.record(error) }
        return false
    })
    defer { try? store.close() }
    await #expect(throws: SQLiteLibraryError.invalidOriginal) { _ = try await SQLiteReportRepository(store: store).stage(entityBoundsFile()) }
    let replacement = try #require(try FileManager.default.contentsOfDirectory(at: store.originalsURL, includingPropertiesForKeys: nil).first)
    #expect(try Data(contentsOf: replacement) == Data("unowned replacement".utf8))
    #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM originals") } == 1)
    #expect(try store.state().generation == 0)
}

@Test
func sqliteEntityLostStageResponseAcceptsAlreadyAdvancedDraft() async throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let store = try SQLiteLibraryStore(rootURL: root, originalFault: { point in
        guard point == .afterLiveCommit else { return false }
        do {
            // Same real persisted command as beginProcessing, while the stage response is pending.
            let queue = try DatabaseQueue(path: root.appendingPathComponent(SQLiteLibraryStore.databaseFilename).path)
            try queue.write { db in
                let bytes = try #require(try Data.fetchOne(db, sql: "SELECT draft_id FROM import_drafts"))
                let id = try #require(UUID(sqliteBytes: bytes))
                let draft = try SQLiteReportRows.draft(id, db).startingProcessing(attemptID: UUID())
                try SQLiteReportRows.saveDraft(draft, documentHash: nil, db)
                try SQLiteLibraryState.advance(in: db)
            }
            try queue.close()
        } catch { Issue.record(error) }
        return true
    })
    defer { try? store.close() }
    let repository = SQLiteReportRepository(store: store)
    guard case let .created(id) = try await repository.stage(entityBoundsFile()) else { Issue.record("Missing successful stage"); return }
    #expect(try await repository.draft(id).state == .processing)
    #expect(try store.state().generation == 2)
    #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM originals WHERE lifecycle='live'") } == 1)
}

@Test
func sqliteEntityLargeMemberLibraryUsesBoundedQueriesAndLogicalEnumeration() async throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let store = try SQLiteLibraryStore(rootURL: root)
    defer { try? store.close() }
    let repository = SQLiteReportRepository(store: store)
    let text = String(repeating: "x", count: 15 * 1_024 * 1_024)
    var ids: [UUID] = []
    for _ in 0..<9 {
        let member = try FamilyMember(displayName: text)
        try await repository.saveMember(member, replacing: nil)
        ids.append(member.id)
    }
    await #expect(throws: LibraryReportError.resourceLimit) { _ = try await repository.members() }
    #expect(try await repository.member(ids[0]).displayName == text)
    #expect(try await repository.reportPage(query: "unmatched").items.isEmpty)
    let snapshot = try await SQLiteLogicalBackupSource(store: store).prepare()
    defer { snapshot.release() }
    try snapshot.validate()
    var count = 0
    _ = try SQLiteLogicalStream.read(byteCount: snapshot.spool.byteCount, read: snapshot.spool.read) { record in
        if record.kind == .member {
            count += 1
            let member = try record.decode(FamilyMember.self)
            #expect(member.displayName == text)
        }
    }
    #expect(count == 9)
    #expect(UInt64(snapshot.logicalByteCount) <= (try store.read(SQLiteLogicalRows.estimatedSpoolBytes)))
}

@Test(arguments: [false, true])
func sqliteEntityLostStageResponseDoesNotAcceptMissingOrReplacedSources(remove: Bool) async throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let store = try SQLiteLibraryStore(rootURL: root, originalFault: { point in
        guard point == .afterLiveCommit else { return false }
        do {
            let queue = try DatabaseQueue(path: root.appendingPathComponent(SQLiteLibraryStore.databaseFilename).path)
            try queue.write { db in
                let bytes = try #require(try Data.fetchOne(db, sql: "SELECT draft_id FROM import_drafts"))
                let id = try #require(UUID(sqliteBytes: bytes))
                let old = try SQLiteReportRows.draft(id, db)
                if remove {
                    try db.execute(sql: "DELETE FROM report_sources WHERE draft_id=?", arguments: [bytes])
                    try db.execute(sql: "DELETE FROM import_drafts WHERE draft_id=?", arguments: [bytes])
                    var original = try SQLiteOriginal.read(old.sources.first.attachmentID, from: db)
                    original.lifecycle = "deleting"
                    try original.save(in: db)
                } else {
                    let source = try ReportSource(attachmentID: old.sources.first.attachmentID, pageCount: 1)
                    let changed = ImportDraft(id: id, sources: try ReportSources([source]), revision: old.revision + 1)
                    try SQLiteReportRows.saveDraft(changed, documentHash: nil, db, replaceSources: true)
                }
                try SQLiteLibraryState.advance(in: db)
            }
            try queue.close()
        } catch { Issue.record(error) }
        return true
    })
    defer { try? store.close() }
    await #expect(throws: SQLiteLibraryError.injectedFailure) { _ = try await SQLiteReportRepository(store: store).stage(entityBoundsFile()) }
    #expect(try store.state().generation == 2)
    #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM originals") } == (remove ? 0 : 1))
}
