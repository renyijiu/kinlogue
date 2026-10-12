import CoreGraphics
import Darwin
import Foundation
import GRDB
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import KinlogueCore
@testable import KinloguePlatform

@Test
func sqliteLANUploadPreprocessArchiveReopenKeepsOriginalAndReview() async throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let kernel = try SQLiteLibraryStore(rootURL: root)
    let reports = SQLiteReportRepository(store: kernel)
    let member = try FamilyMember(displayName: "Synthetic LAN member")
    try await reports.saveMember(member, replacing: nil)
    let inbox = try SQLiteLANInboxStore(store: kernel)
    let initial = try await inbox.initialize()
    #expect(initial.generation == UInt64(try kernel.state().generation) + 1)
    let data = try sqliteLANImage(red: 100)
    let session = UUID()
    try await sqliteLANUpload(data, session: session, inbox: inbox)
    let item = try #require(try await inbox.loadSnapshot().items.first)
    let inode = try SQLiteFileIdentity.regular(at: root.appendingPathComponent("originals/\(item.blobID.uuidString.lowercased()).data"))
    let preprocessor = LANItemPreprocessor(inbox: inbox, textExtractor: SQLiteLANTextExtractor())
    let coordinator = LANReportArchiveCoordinator(inbox: inbox, preprocessor: preprocessor)
    let date = Date(timeIntervalSince1970: 1_786_000_000.0056)
    guard case let .accepted(id) = try await coordinator.archive(itemIDs: [item.id], memberID: member.id,
        canonicalReportDate: date, activeSessionID: session) else { Issue.record("Expected a draft"); return }
    let draft = try await reports.draft(id)
    #expect(draft.sources.attachmentIDs == [item.blobID])
    #expect(try await reports.loadDocument(draftID: id).reviewState?.timelineDateSelection == .manual(CanonicalVaultJSON.persistenceStableDate(date)))
    #expect(try await inbox.loadSnapshot().items.isEmpty)
    #expect(try SQLiteFileIdentity.regular(at: root.appendingPathComponent("originals/\(item.blobID.uuidString.lowercased()).data")) == inode)
    #expect(try await coordinator.archive(itemIDs: [item.id], memberID: member.id, canonicalReportDate: date) == .accepted(draftID: id))
    #expect(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)) == ["library.sqlite", "originals"])
    try kernel.close()
    let reopened = try SQLiteLibraryStore(rootURL: root)
    defer { try? reopened.close() }
    let next = SQLiteReportRepository(store: reopened)
    #expect(try await next.draft(id) == draft)
    #expect(try await next.loadDocument(draftID: id).reviewState?.title == "Synthetic report")
}

@Test
func sqliteDraftPagesNameAWaitingDraftAfterItsFirstOriginal() async throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let kernel = try SQLiteLibraryStore(rootURL: root)
    defer { try? kernel.close() }
    let reports = SQLiteReportRepository(store: kernel)
    let member = try FamilyMember(displayName: "Synthetic LAN member")
    try await reports.saveMember(member, replacing: nil)
    let inbox = try SQLiteLANInboxStore(store: kernel)
    _ = try await inbox.initialize()
    let session = UUID()
    try await sqliteLANUpload(try sqliteLANImage(red: 120), session: session, inbox: inbox)
    let item = try #require(try await inbox.loadSnapshot().items.first)
    let coordinator = LANReportArchiveCoordinator(inbox: inbox,
        preprocessor: LANItemPreprocessor(inbox: inbox, textExtractor: SQLiteLANTextExtractor()))
    guard case let .accepted(named) = try await coordinator.archive(itemIDs: [item.id], memberID: member.id,
        canonicalReportDate: Date(timeIntervalSince1970: 1_786_000_000), activeSessionID: session) else {
        Issue.record("Expected a draft"); return
    }
    // A file staged from this Mac carries no name.
    let bytes = Data("synthetic unnamed draft".utf8)
    guard case .created(let unnamed) = try await reports.stage(ValidatedImportedFile(data: bytes, kind: .image,
        contentTypeIdentifier: "public.png", sha256Digest: ContentDigest.sha256(bytes))) else {
        Issue.record("Expected a staged draft"); return
    }
    let states = [ImportState.needsReview, .staging]

    let page = try await reports.draftPage(states: states, limit: 100, cursor: nil)
    #expect(page.damagedIDs.isEmpty)
    #expect(page.items.first { $0.id == named }?.displayName == "synthetic.png")
    #expect(page.items.contains { $0.id == unnamed && $0.displayName == nil })
    #expect(try await reports.drafts().items.first { $0.id == named }?.displayName == "synthetic.png")

    // A valid name too long for a list row is left out; the draft stays listed.
    try kernel.write { db in
        let row = try #require(try SQLiteRows.fetchOne(db,
            sql: "SELECT * FROM report_sources WHERE draft_id = ? AND position = 0", arguments: [named.sqliteBytes]))
        try SQLiteReportRows.put(db, table: "report_sources", columns: SQLiteReportRows.sourceColumns,
            values: SQLiteReportRows.sourceColumns.map { column in
                column == "display_name" ? String(repeating: "n", count: 1_025).databaseValue : row[column] as DatabaseValue
            })
    }
    let long = try await reports.draftPage(states: states, limit: 100, cursor: nil)
    #expect(long.damagedIDs.isEmpty)
    #expect(long.items.contains { $0.id == named && $0.displayName == nil })

    // A source row that no longer matches its hash marks only its own draft as damaged.
    try kernel.write { db in
        try db.execute(sql: "UPDATE report_sources SET display_name = 'tampered.png' WHERE draft_id = ?", arguments: [named.sqliteBytes])
    }
    let tampered = try await reports.draftPage(states: states, limit: 100, cursor: nil)
    #expect(tampered.damagedIDs == [named])
    #expect(tampered.items.map(\.id) == [unnamed])
}

private func sqliteLANUpload(_ data: Data, session: UUID = UUID(), remoteID: UUID = UUID(), inbox: SQLiteLANInboxStore) async throws {
    let metadata = try LANInboxTransportMetadata(displayName: LANInboxDisplayName(rawValue: "synthetic.png"), declaredByteCount: data.count)
    guard case let .sink(sink) = try await inbox.startItemUpload(transport: LANInboxTransportIdentity(sessionID: session, remoteFileID: remoteID), metadata: metadata, attemptRevision: 0) else { return }
    try await sink.write(data).value
    _ = try await sink.finish()
}

private func sqliteLANImage(red: UInt8) throws -> Data {
    let bytes = Data([red, 100, 50, 255])
    let provider = try #require(CGDataProvider(data: bytes as CFData))
    let image = try #require(CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
        decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

private struct SQLiteLANTextExtractor: TextExtractionService {
    func extractText(from file: ValidatedImportedFile) async throws -> [OCRBlock] {
        [try OCRBlock(pageNumber: 1, text: "标题：Synthetic report", boundingBox: try NormalizedRect(x: 0, y: 0, width: 1, height: 1), confidence: 1, method: .vision, engineVersion: "synthetic")]
    }
}

@Test
func sqliteLANCanonicalReceiptsAndDeleteFenceAllowFreshUpload() async throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let kernel = try SQLiteLibraryStore(rootURL: root)
    defer { try? kernel.close() }
    let inbox = try SQLiteLANInboxStore(store: kernel)
    let session = UUID(), remote = UUID(), data = Data("synthetic upload".utf8)
    let admission = try await inbox.itemAdmissionGeneration()
    let metadata = try LANInboxTransportMetadata(displayName: LANInboxDisplayName(rawValue: "synthetic.bin"), declaredByteCount: data.count)
    let late = try await sqliteLANStart(inbox, session: session, metadata: metadata, admission: admission)
    try await sqliteLANUpload(data, session: session, remoteID: remote, inbox: inbox)
    let first = try #require(try await inbox.loadSnapshot().items.first)
    _ = try await inbox.deleteItem(itemID: first.id, expectedRevision: first.revision, activeSessionID: session)
    try await late.write(data).value
    _ = try await late.finish()
    #expect(try await inbox.loadSnapshot().items.isEmpty)
    try await sqliteLANUpload(data, session: session, inbox: inbox)
    try await sqliteLANUpload(data, session: session, inbox: inbox)
    let after = try await inbox.loadSnapshot()
    #expect(after.items.count == 1)
    #expect(after.transportReceipts.contains { if case .merged = $0.outcome { true } else { false } })
    let changed = try LANInboxTransportMetadata(displayName: LANInboxDisplayName(rawValue: "changed.bin"), declaredByteCount: data.count)
    await #expect(throws: LANInboxError.receiptConflict) {
        _ = try await inbox.startItemUpload(transport: LANInboxTransportIdentity(sessionID: session, remoteFileID: remote), metadata: changed, attemptRevision: 0)
    }
    try await inbox.endItemSession(sessionID: session)
    #expect(try await inbox.loadSnapshot().transportReceipts.isEmpty)
    #expect(try await inbox.loadSnapshot().items.count == 1)
}

@Test
func sqliteLANScopesShareAdmissionAndKeepOwnerUntilDescriptorClose() async throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let kernel = try SQLiteLibraryStore(rootURL: root)
    defer { try? kernel.close() }
    let inbox = try SQLiteLANInboxStore(store: kernel)
    let a = try await inbox.publicationGuard(), b = try await inbox.publicationGuard()
    let metadata = try LANInboxTransportMetadata(displayName: LANInboxDisplayName(rawValue: "scope.bin"), declaredByteCount: 1)
    let first = try await sqliteLANStart(inbox, metadata: metadata, scope: a)
    let second = try await sqliteLANStart(inbox, metadata: metadata, scope: b)
    #expect(throws: SQLiteLibraryError.originalBusy) { try kernel.closeDatabaseForReplacement() }
    await #expect(throws: LANInboxError.resourceLimitExceeded) { _ = try await sqliteLANStart(inbox, metadata: metadata, scope: b) }
    #expect(try await inbox.initialize().items.isEmpty)
    try await inbox.revokePublications(guardedBy: a)
    try await first.write(Data([1])).value
    await #expect(throws: LANInboxError.vaultUnavailable) { _ = try await first.finish() }
    await first.cancel()
    try await second.write(Data([2])).value
    _ = try await second.finish()
    await second.cancel()
    #expect(inbox.admissionPolicy.currentUsage.activeUploadCount == 0)
    #expect(try await inbox.loadSnapshot().items.count == 1)
    try kernel.closeDatabaseForReplacement()
    try kernel.reopenAfterReplacement()
    await #expect(throws: SQLiteLibraryError.staleRoot) { _ = try await inbox.loadSnapshot() }
}

@Test(arguments: [SQLiteOriginalFaultPoint.afterRename, .afterLiveCommit])
func sqliteLANUploadPublicationFaultKeepsOnlyOwnedDurableResult(point: SQLiteOriginalFaultPoint) async throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let kernel = try SQLiteLibraryStore(rootURL: root, originalFault: { $0 == point })
    let inbox = try SQLiteLANInboxStore(store: kernel)
    let bytes = Data("synthetic commit recovery".utf8)
    if point == .afterRename {
        await #expect(throws: SQLiteLibraryError.injectedFailure) { try await sqliteLANUpload(bytes, inbox: inbox) }
        #expect(try await inbox.loadSnapshot().items.isEmpty)
    } else {
        try await sqliteLANUpload(bytes, inbox: inbox)
        #expect(try await inbox.loadSnapshot().items.count == 1)
    }
    #expect(try kernel.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM inbox_uploads") } == 0)
    try kernel.close()
    let reopened = try SQLiteLibraryStore(rootURL: root)
    defer { try? reopened.close() }
    let next = try SQLiteLANInboxStore(store: reopened)
    #expect(try await next.initialize().items.count == (point == .afterRename ? 0 : 1))
}

@Test
func sqliteLANMissingReceiptOrderedArchiveAndBadDuplicatePreserveGoodSources() async throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let kernel = try SQLiteLibraryStore(rootURL: root)
    defer { try? kernel.close() }
    let reports = SQLiteReportRepository(store: kernel)
    let member = try FamilyMember(displayName: "Synthetic member")
    try await reports.saveMember(member, replacing: nil)
    let inbox = try SQLiteLANInboxStore(store: kernel)
    let session = UUID()
    let firstBytes = try sqliteLANImage(red: 10), secondBytes = try sqliteLANImage(red: 20)
    try await sqliteLANUpload(firstBytes, session: session, inbox: inbox)
    try await sqliteLANUpload(secondBytes, session: session, inbox: inbox)
    let originalItems = try await inbox.loadSnapshot().items
    let preprocessor = LANItemPreprocessor(inbox: inbox, textExtractor: SQLiteLANTextExtractor())
    _ = try await preprocessor.preprocess(itemIDs: originalItems.map(\.id))
    try await inbox.endItemSession(sessionID: session)
    let coordinator = LANReportArchiveCoordinator(inbox: inbox, preprocessor: preprocessor)
    let date = Date(timeIntervalSince1970: 1_786_000_000.0056)
    guard case let .accepted(id) = try await coordinator.archive(itemIDs: originalItems.reversed().map(\.id), memberID: member.id, canonicalReportDate: date) else { Issue.record("Expected draft"); return }
    let draft = try await reports.draft(id)
    #expect(draft.sources.attachmentIDs == originalItems.reversed().map(\.blobID))
    try await sqliteLANUpload(firstBytes, inbox: inbox)
    try await sqliteLANUpload(secondBytes, inbox: inbox)
    let good = try await inbox.loadSnapshot().items
    let oldPath = root.appendingPathComponent("originals/\(draft.sources.attachmentIDs[0].uuidString.lowercased()).data")
    let fd = Darwin.open(oldPath.path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
    #expect(fd >= 0)
    _ = Darwin.pwrite(fd, [UInt8(0)], 1, 0)
    Darwin.close(fd)
    await #expect(throws: SQLiteLibraryError.invalidOriginal) {
        _ = try await coordinator.archive(itemIDs: good.map(\.id), memberID: member.id, canonicalReportDate: date)
    }
    #expect(Set(try await inbox.loadSnapshot().items.map(\.id)) == Set(good.map(\.id)))
    for item in good { #expect(try await inbox.withVerifiedItemSourceContent(itemID: item.id) { fd in fcntl(fd, F_GETFD) >= 0 }) }
}

@Test
func sqliteLANTypedOCRIsAtomicAndCorruptionDoesNotEnterDraft() async throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let kernel = try SQLiteLibraryStore(rootURL: root)
    defer { try? kernel.close() }
    let inbox = try SQLiteLANInboxStore(store: kernel)
    try await sqliteLANUpload(sqliteLANImage(red: 42), inbox: inbox)
    let initial = try #require(try await inbox.loadSnapshot().items.first)
    let source = try ReportSource(attachmentID: initial.blobID, displayName: initial.displayName.rawValue, pageCount: 1)
    let value = try LANPreprocessedSourceDocument(source: source, contentTypeIdentifier: "public.png", blocks: [])
    let saved = try await inbox.savePreprocessedDocument(itemID: initial.id, expectedRevision: initial.revision, document: value)
    #expect(saved.revision == initial.revision + 2)
    #expect(try await inbox.loadPreprocessedDocument(itemID: saved.id, expectedRevision: saved.revision) == value)
    await #expect(throws: LANInboxError.staleRevision) { _ = try await inbox.savePreprocessedDocument(itemID: initial.id, expectedRevision: initial.revision, document: value) }
    let sameLengthDamage = Data(repeating: 0, count: try CanonicalVaultJSON.encode(value).count)
    try kernel.write { db in try db.execute(sql: "UPDATE ocr_documents SET payload = ? WHERE id = ?", arguments: [sameLengthDamage, saved.derivedArtifact!.id.sqliteBytes]) }
    #expect(try await inbox.queueScreen().page.items == [saved])
    await #expect(throws: (any Error).self) { _ = try await inbox.loadPreprocessedDocument(itemID: saved.id, expectedRevision: saved.revision) }
    try kernel.write { db in try db.execute(sql: "UPDATE ocr_documents SET payload = ? WHERE id = ?", arguments: [Data("invalid".utf8), saved.derivedArtifact!.id.sqliteBytes]) }
    #expect(try await inbox.queueScreen().page.damagedItemIDs == [saved.id])
    await #expect(throws: (any Error).self) { _ = try await inbox.loadPreprocessedDocument(itemID: saved.id, expectedRevision: saved.revision) }
    #expect(try kernel.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM import_drafts") } == 0)
}

@Test
func sqliteLANAbandonedAndReplacedPartialsRecoverWithoutGuessingOwnership() async throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let kernel = try SQLiteLibraryStore(rootURL: root)
    let inbox = try SQLiteLANInboxStore(store: kernel)
    try await sqliteLANUpload(Data("Good synthetic completed upload".utf8), inbox: inbox)
    let metadata = try LANInboxTransportMetadata(displayName: LANInboxDisplayName(rawValue: "partial.bin"), declaredByteCount: 10)
    var sink: LANUploadSink? = try await sqliteLANStart(inbox, metadata: metadata)
    try await sink!.write(Data([1, 2, 3])).value
    let bytes = try #require(try kernel.read { try Data.fetchOne($0, sql: "SELECT id FROM inbox_uploads") })
    let id = try #require(UUID(sqliteBytes: bytes))
    let path = root.appendingPathComponent("originals/\(id.uuidString.lowercased()).upload")
    let old = path.appendingPathExtension("retained")
    try FileManager.default.moveItem(at: path, to: old)
    try Data([9]).write(to: path)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    let screen = try await inbox.queueScreen()
    #expect(screen.page.items.count == 1)
    #expect(screen.damagedUploadIDs == [id])
    #expect(screen.storage.partialObjectCount == 0)
    sink = nil
    for _ in 0..<200 where inbox.admissionPolicy.currentUsage.activeUploadCount > 0 { try await Task.sleep(for: .milliseconds(5)) }
    #expect(inbox.admissionPolicy.currentUsage.activeUploadCount == 0)
    #expect(try kernel.recoverLANUploads() == [id])
    #expect(try Data(contentsOf: path) == Data([9]))
    #expect(try Data(contentsOf: old) == Data([1, 2, 3]))
    try kernel.close()
    let reopened = try SQLiteLibraryStore(rootURL: root)
    defer { try? reopened.close() }
    #expect(try reopened.recoverLANUploads() == [id])
    #expect(try Data(contentsOf: path) == Data([9]))
}

@Test
func sqliteLANDocumentOwnershipLookupsUseIndexes() throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let kernel = try SQLiteLibraryStore(rootURL: root)
    defer { try? kernel.close() }
    try kernel.read { db in
        for (table, column, index) in [("reports", "document_id", "report_document"), ("import_drafts", "document_id", "draft_document"), ("inbox_items", "derived_document_id", "inbox_document")] {
            let rows = try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN SELECT * FROM \(table) WHERE \(column) = ?", arguments: [UUID().sqliteBytes])
            let details = rows.map { $0["detail"] as String }.joined(separator: " ")
            #expect(details.contains(index))
            #expect(!details.contains("SCAN"))
        }
    }
}

private func sqliteLANStart(_ inbox: SQLiteLANInboxStore, session: UUID = UUID(), metadata: LANInboxTransportMetadata,
                           admission: UInt64? = nil, scope: LANInboxPublicationGuard? = nil) async throws -> LANUploadSink {
    guard case let .sink(sink) = try await inbox.startItemUpload(transport: LANInboxTransportIdentity(sessionID: session, remoteFileID: UUID()), metadata: metadata,
        attemptRevision: 0, admissionGeneration: admission, publicationGuard: scope) else { throw LANInboxError.invalidState }
    return sink
}

@Test(arguments: [false, true])
func sqliteLANInvalidSourceBecomesIntegrityFailedWithoutAutoHealing(hardlink: Bool) async throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let kernel = try SQLiteLibraryStore(rootURL: root)
    defer { try? kernel.close() }
    let inbox = try SQLiteLANInboxStore(store: kernel)
    try await sqliteLANUpload(Data("synthetic missing original".utf8), inbox: inbox)
    let item = try #require(try await inbox.loadSnapshot().items.first)
    let url = root.appendingPathComponent("originals/\(item.blobID.uuidString.lowercased()).data")
    let saved = url.appendingPathExtension("held")
    if hardlink { try FileManager.default.linkItem(at: url, to: saved) }
    else { try FileManager.default.moveItem(at: url, to: saved) }
    await #expect(throws: LANInboxError.integrityCheckFailed) { _ = try await inbox.withVerifiedItemSourceContent(itemID: item.id) { _ in true } }
    guard case .integrityFailed = try await inbox.loadSnapshot().items.first?.state else { Issue.record("Invalid original must quarantine the item"); return }
    if hardlink { try FileManager.default.removeItem(at: saved) }
    else { try FileManager.default.moveItem(at: saved, to: url) }
    try kernel.close()
    let reopened = try SQLiteLibraryStore(rootURL: root)
    defer { try? reopened.close() }
    let reopenedInbox = try SQLiteLANInboxStore(store: reopened)
    guard case .integrityFailed = try await reopenedInbox.initialize().items.first?.state else { Issue.record("Restart must not silently heal integrity failures"); return }
}

@Test
func sqliteLANArchiveKeepsTerminalsScopedAndReplaysDuplicateOutcome() async throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let kernel = try SQLiteLibraryStore(rootURL: root)
    defer { try? kernel.close() }
    let reports = SQLiteReportRepository(store: kernel)
    let member = try FamilyMember(displayName: "Synthetic member")
    try await reports.saveMember(member, replacing: nil)
    let inbox = try SQLiteLANInboxStore(store: kernel)
    let data = [try sqliteLANImage(red: 17), try sqliteLANImage(red: 19)]
    let sessions = [UUID(), UUID()]
    for index in 0..<2 { try await sqliteLANUpload(data[index], session: sessions[index], inbox: inbox) }
    let items = try await inbox.loadSnapshot().items
    let coordinator = LANReportArchiveCoordinator(inbox: inbox, preprocessor: LANItemPreprocessor(inbox: inbox, textExtractor: SQLiteLANTextExtractor()))
    let date = Date(timeIntervalSince1970: 1_786_000_000.0056)
    guard case let .accepted(id) = try await coordinator.archive(itemIDs: items.map(\.id), memberID: member.id, canonicalReportDate: date) else { Issue.record("Expected draft"); return }
    let archived = try await inbox.loadSnapshot()
    #expect(archived.contentTerminals.count == 2)
    for index in 0..<2 { try await sqliteLANUpload(data[index], session: sessions[index], inbox: inbox) }
    #expect(try await inbox.loadSnapshot().items.isEmpty)
    for bytes in data { try await sqliteLANUpload(bytes, inbox: inbox) }
    let duplicateItems = try await inbox.loadSnapshot().items
    let outcome = try await coordinator.archive(itemIDs: duplicateItems.map(\.id), memberID: member.id, canonicalReportDate: date)
    #expect(outcome == .duplicateSkipped(.init(kind: .importDraft, id: id)))
    #expect(try await coordinator.archive(itemIDs: duplicateItems.map(\.id), memberID: member.id, canonicalReportDate: date) == outcome)
    #expect(try await inbox.loadSnapshot().items.isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("originals").path).count == 2)
}

@Test
func sqliteLANKeepsSeparateTransportAndOCRAndReportSizeBudgets() async throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let kernel = try SQLiteLibraryStore(rootURL: root)
    defer { try? kernel.close() }
    let inbox = try SQLiteLANInboxStore(store: kernel)
    let largeTransport = try LANInboxTransportMetadata(displayName: LANInboxDisplayName(rawValue: "large.bin"), declaredByteCount: 101 * 1_024 * 1_024)
    let sink = try await sqliteLANStart(inbox, metadata: largeTransport)
    await sink.cancel()
    #expect(inbox.admissionPolicy.currentUsage.activeUploadCount == 0)
    try await sqliteLANUpload(sqliteLANImage(red: 12), inbox: inbox)
    let item = try #require(try await inbox.loadSnapshot().items.first)
    let source = try ReportSource(attachmentID: item.blobID, displayName: item.displayName.rawValue, pageCount: 1)
    let block = try OCRBlock(sourceID: source.id, attachmentID: item.blobID, filePageNumber: 1,
        text: String(repeating: "x", count: 17 * 1_024 * 1_024), boundingBox: NormalizedRect(x: 0, y: 0, width: 1, height: 1),
        confidence: 1, method: .vision, engineVersion: "synthetic")
    let sourceDocument = try LANPreprocessedSourceDocument(source: source, contentTypeIdentifier: "public.png", blocks: [block])
    let next = try await inbox.savePreprocessedDocument(itemID: item.id, expectedRevision: item.revision, document: sourceDocument)
    #expect(try await inbox.loadPreprocessedDocument(itemID: next.id, expectedRevision: next.revision) == sourceDocument)
    let prepared = try LANPreparedItemSelection(items: [next], sourceDocuments: [sourceDocument], sources: ReportSources([source]),
        document: ImportDraftDocument(blocks: [block], candidates: ReportCandidates()))
    await #expect(throws: LANInboxError.resourceLimitExceeded) {
        _ = try await inbox.archive(prepared, memberID: UUID(), canonicalReportDate: Date(timeIntervalSince1970: 1_786_000_000.0056), activeSessionID: nil)
    }
    #expect(try await inbox.loadSnapshot().items == [next])
    #expect(try kernel.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM import_drafts") } == 0)
}

@Test
func sqliteLANScopeRevocationWaitsForPublicationCommitWithoutRevokingOtherScopes() async throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let kernel = try SQLiteLibraryStore(rootURL: root)
    defer { try? kernel.close() }
    let inbox = try SQLiteLANInboxStore(store: kernel)
    let scope = try await inbox.publicationGuard(), otherScope = try await inbox.publicationGuard()
    let metadata = try LANInboxTransportMetadata(displayName: LANInboxDisplayName(rawValue: "scope.bin"), declaredByteCount: 1)
    let sink = try await sqliteLANStart(inbox, metadata: metadata, scope: scope)
    try await sink.write(Data([1])).value
    let before = try kernel.state().generation
    let gate = SQLiteLANCommitGate()
    defer { gate.release() }
    try kernel.write { db in
        db.trace { event in
            if case let .statement(statement) = event, statement.sql.hasPrefix("INSERT INTO inbox_transport_receipts(") {
                gate.pauseBeforeReceiptInsert()
            }
        }
    }
    let finishing = Task { try await sink.finish() }
    try await gate.waitUntil { $0.paused }
    let revoking = Task {
        gate.markRevocationRequested()
        try await inbox.revokePublications(guardedBy: scope)
        gate.markRevocationReturned()
    }
    try await gate.waitUntil { $0.revocationRequested }
    // A bounded observation interval proves that revocation cannot acknowledge
    // while the already-validated publication is still inside its SQL transaction.
    try await Task.sleep(for: .milliseconds(50))
    let duringCommit = gate.observation
    #expect(!duringCommit.revocationReturned)
    gate.release()
    _ = try await finishing.value
    try await revoking.value
    try kernel.write { db in db.trace(nil) }
    #expect(!gate.observation.timedOut)
    #expect(try await inbox.loadSnapshot().items.count == 1)
    #expect(try kernel.state().generation == before + 1)
    await #expect(throws: LANInboxError.vaultUnavailable) {
        _ = try await sqliteLANStart(inbox, metadata: metadata, scope: scope)
    }
    let allowed = try await sqliteLANStart(inbox, metadata: metadata, scope: otherScope)
    try await allowed.write(Data([2])).value
    _ = try await allowed.finish()
    #expect(try await inbox.loadSnapshot().items.count == 2)
    try kernel.closeDatabaseForReplacement()
    try kernel.reopenAfterReplacement()
    await #expect(throws: SQLiteLibraryError.staleRoot) { _ = try await inbox.publicationGuard() }
    await #expect(throws: SQLiteLibraryError.staleRoot) { try await inbox.revokePublications(guardedBy: otherScope) }
}

// SAFETY: the condition serializes trace-thread pause state and task observations.
private final class SQLiteLANCommitGate: @unchecked Sendable {
    struct Observation: Sendable {
        var paused = false
        var revocationRequested = false
        var revocationReturned = false
        var timedOut = false
    }
    private let condition = NSCondition()
    private var state = Observation()
    private var released = false
    var observation: Observation { condition.lock(); defer { condition.unlock() }; return state }
    func pauseBeforeReceiptInsert() {
        condition.lock()
        state.paused = true
        let deadline = Date().addingTimeInterval(3)
        while !released {
            if !condition.wait(until: deadline) { state.timedOut = true; break }
        }
        condition.unlock()
    }
    func markRevocationRequested() { condition.lock(); state.revocationRequested = true; condition.unlock() }
    func markRevocationReturned() { condition.lock(); state.revocationReturned = true; condition.unlock() }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
    func waitUntil(_ predicate: (Observation) -> Bool) async throws {
        for _ in 0..<400 {
            if predicate(observation) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw SQLiteLibraryError.injectedFailure
    }
}

@Test(arguments: ["overwrite", "append", "replace"])
func sqliteLANUploadRejectsOriginalChangedAfterPublicationHash(mutation: String) async throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let store = try SQLiteLibraryStore(rootURL: root, originalFault: { point in
        guard point == .afterRename else { return false }
        do { try sqliteMutateOriginal(root: root, extension: "data", mutation: mutation) }
        catch { Issue.record(error) }
        return false
    })
    defer { try? store.close() }
    let inbox = try SQLiteLANInboxStore(store: store)
    await #expect(throws: SQLiteLibraryError.invalidOriginal) {
        try await sqliteLANUpload(Data("synthetic LAN publication fence".utf8), inbox: inbox)
    }
    let snapshot = try await inbox.loadSnapshot()
    #expect(snapshot.items.isEmpty)
    #expect(snapshot.transportReceipts.isEmpty)
    #expect(try store.state().generation == 0)
}

@Test(arguments: [false, true])
func sqliteLANScreenAndTargetProcessingSurviveAnotherDamagedItem(oversized: Bool) async throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let kernel = try SQLiteLibraryStore(rootURL: root)
    defer { try? kernel.close() }
    let inbox = try SQLiteLANInboxStore(store: kernel)
    try await sqliteLANUpload(sqliteLANImage(red: 110), inbox: inbox)
    try await sqliteLANUpload(sqliteLANImage(red: 111), inbox: inbox)
    let all = try await inbox.loadSnapshot().items
    let damaged = all[0], good = all[1]
    try kernel.write { db in
        try db.execute(sql: "UPDATE inbox_items SET display_name=? WHERE id=?", arguments: [oversized ? String(repeating: "x", count: 2_000_000) : "damaged synthetic name", damaged.id.sqliteBytes])
    }
    let screen = try await inbox.snapshotAndStorageSummary()
    #expect(screen.snapshot.items.map(\.id) == [good.id])
    #expect(screen.damagedItemIDs == [damaged.id])
    #expect(screen.damagedReceiptIDs.count == 1)
    let preprocessor = LANItemPreprocessor(inbox: inbox, textExtractor: SQLiteLANTextExtractor())
    let processed = try await preprocessor.preprocess(itemID: good.id)
    #expect(processed.isReviewable)
    try await inbox.prepare()
    let workflow = LANPendingQueueWorkflow(inbox: inbox, preprocessor: preprocessor,
        archiveCoordinator: LANReportArchiveCoordinator(inbox: inbox, preprocessor: preprocessor))
    #expect(try await workflow.loadPreview(itemID: good.id).data == sqliteLANImage(red: 111))
    try await inbox.removeItem(itemID: good.id, expectedRevision: processed.revision, activeSessionID: nil)
    #expect(try await inbox.queueScreen().page.items.isEmpty)
    await #expect(throws: (any Error).self) { _ = try await inbox.loadSnapshot() }
}

@Test
func sqliteLANPartialBytesDoNotPublishCommitHintsButFinishedUploadDoes() async throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let kernel = try SQLiteLibraryStore(rootURL: root)
    let inbox = try SQLiteLANInboxStore(store: kernel)
    let data = Data("synthetic observed LAN original".utf8)
    let metadata = try LANInboxTransportMetadata(displayName: LANInboxDisplayName(rawValue: "synthetic.bin"), declaredByteCount: data.count)
    var partial = kernel.changes().makeAsyncIterator()
    let sink = try await sqliteLANStart(inbox, metadata: metadata)
    try await sink.write(Data(data.prefix(4))).value
    kernel.notifications.finish()
    #expect(await partial.next() == nil)
    #expect(try kernel.state().generation == 0)
    var committed = kernel.changes().makeAsyncIterator()
    try await sink.write(Data(data.dropFirst(4))).value
    _ = try await sink.finish()
    let event = try #require(await committed.next())
    let state = try kernel.state()
    #expect(event.generation == 1 && event.commitID == state.commitID)
    #expect(try await inbox.snapshotAndStorageSummary().snapshot.items.count == 1)
    try kernel.close()
    #expect(await committed.next() == nil)
}

@Test
func sqliteLANQueuePagesAdvanceAcrossDamageAndBindRevisionAndEpoch() async throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let kernel = try SQLiteLibraryStore(rootURL: root)
    let inbox = try SQLiteLANInboxStore(store: kernel)
    for index in 0..<201 { try await sqliteLANUpload(Data("synthetic page original \(index)".utf8), inbox: inbox) }
    let durable = try await inbox.loadSnapshot()
    let all = durable.items
    var cursor: LANInboxPageCursor?
    var ids: [UUID] = []
    var sizes: [Int] = []
    repeat {
        let screen = try await inbox.queueScreen(cursor: cursor)
        #expect(screen.storage.itemCount == 201)
        #expect(screen.storage.sourceByteCount == all.reduce(0) { $0 + $1.contentIdentity.byteCount })
        ids += screen.page.items.map(\.id); sizes.append(screen.page.items.count)
        cursor = screen.page.nextCursor
    } while cursor != nil
    #expect(sizes == [100, 100, 1])
    #expect(ids == all.map(\.id))
    try kernel.write { db in
        try db.execute(sql: "UPDATE inbox_items SET display_name=? WHERE id=?", arguments: ["damaged", all[99].id.sqliteBytes])
    }
    let first = try await inbox.queueScreen()
    #expect(first.page.items.count == 99)
    #expect(first.page.damagedItemIDs == [all[99].id])
    #expect(first.storage.itemCount == 201)
    let second = try await inbox.queueScreen(cursor: first.page.nextCursor)
    #expect(second.page.items.map(\.id) == Array(all[100..<200]).map(\.id))
    let knownReceipt = try #require(durable.transportReceipts.first).id
    #expect(try kernel.rememberIntegrityFailure(SQLiteIntegrityTarget(kind: .inbox, key: all[150].id.sqliteBytes), state: kernel.state(), epoch: inbox.epoch))
    #expect(try kernel.rememberIntegrityFailure(SQLiteIntegrityTarget(kind: .receipt, key: knownReceipt.sqliteBytes), state: kernel.state(), epoch: inbox.epoch))
    let known = try await inbox.queueScreen()
    #expect(Set(known.page.damagedItemIDs) == [all[99].id, all[150].id])
    #expect(known.damagedReceiptIDs == [knownReceipt])
    #expect(try await inbox.loadItems(ids: [all[200].id]) == [all[200]])
    let revised = try await inbox.markItemPreprocessingIssue(itemID: all[200].id, expectedRevision: all[200].revision, issue: .unsupportedContent)
    await #expect(throws: LANInboxError.staleRevision) {
        try await inbox.removeItem(itemID: revised.id, expectedRevision: all[200].revision, activeSessionID: nil)
    }
    await #expect(throws: LibraryReportError.staleCursor) { _ = try await inbox.queueScreen(cursor: first.page.nextCursor) }
    let processing = try await inbox.itemPage(processing: true)
    _ = try await inbox.markItemPreprocessingIssue(itemID: all[0].id, expectedRevision: all[0].revision, issue: .unsupportedContent)
    #expect(try await inbox.itemPage(cursor: processing.nextCursor, processing: true).items.count == 99)
    let latest = try await inbox.queueScreen()
    try kernel.close()
    let reopened = try SQLiteLibraryStore(rootURL: root)
    defer { try? reopened.close() }
    let next = try SQLiteLANInboxStore(store: reopened)
    await #expect(throws: LibraryReportError.staleCursor) { _ = try await next.queueScreen(cursor: latest.page.nextCursor) }
}
