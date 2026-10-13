import Darwin
import Foundation
import GRDB
import Testing
@testable import KinlogueCore
@testable import KinloguePlatform

@Test
func sqliteLogicalCaptureAllowsCommitsDuringFrozenValidationAndPinsDeletedOriginal() async throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let store = try SQLiteLibraryStore(rootURL: root)
    defer { try? store.close() }
    let reports = SQLiteReportRepository(store: store)
    let member = try FamilyMember(displayName: "Synthetic capture member")
    try await reports.saveMember(member, replacing: nil)
    let bytes = Data("Synthetic captured original".utf8)
    let outcome = try await reports.stage(ValidatedImportedFile(data: bytes, kind: .image, contentTypeIdentifier: "public.png", sha256Digest: ContentDigest.sha256(bytes)))
    guard case let .created(draftID) = outcome else { Issue.record("Missing synthetic draft"); return }
    let draft = try await reports.draft(draftID)
    let (entered, signal) = AsyncStream<Void>.makeStream()
    let gate = DispatchSemaphore(value: 0)
    let source = SQLiteLogicalBackupSource(store: store, captureHook: { phase in
        if phase == .logicalValidation { signal.yield(()); gate.wait() }
    })
    let task = Task { try await source.prepare() }
    for await _ in entered { break }
    var changed = member; changed.displayName = "Synthetic committed during capture"
    do {
        try await reports.saveMember(changed, replacing: member)
        try await reports.discard(draftID: draft.id, expectedRevision: draft.revision)
    } catch { gate.signal(); _ = try? await task.value; throw error }
    gate.signal()
    let snapshot = try await task.value
    defer { snapshot.release() }
    let records = try snapshot.logicalRecordsForTesting()
    #expect(records.contains { $0.kind == .member && (try? $0.decode(FamilyMember.self)) == member })
    #expect(records.contains { $0.kind == .draft && (try? $0.id) == draft.id })
    #expect(snapshot.revisionPair != (try source.currentRevision()))
    for id in snapshot.pins.originals.keys {
        let reader = try snapshot.pins.open(id); defer { reader.close() }
        #expect(try reader.read(offset: 0, maximumByteCount: 64 * 1_024) == bytes)
    }
    snapshot.release()
    #expect(store.pins.isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("originals").path).isEmpty)
}

@Test
func sqliteLogicalCaptureReadsOriginalsAfterTheVolumeIsRenumbered() async throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let store = try SQLiteLibraryStore(rootURL: root)
    let bytes = Data("Synthetic original on a renumbered volume".utf8)
    let outcome = try await SQLiteReportRepository(store: store).stage(ValidatedImportedFile(
        data: bytes, kind: .image, contentTypeIdentifier: "public.png", sha256Digest: ContentDigest.sha256(bytes)))
    guard case let .created(draftID) = outcome else { Issue.record("Missing synthetic draft"); return }
    // Every row keeps the device number the volume had before a restart gave it another one.
    try store.write { db in
        for row in try SQLiteRows.fetchAll(db, sql: "SELECT * FROM originals") {
            var original = try SQLiteOriginal.decode(row)
            let recorded = try #require(original.identity)
            original.identity = SQLiteFileIdentity(device: recorded.device + 3, inode: recorded.inode)
            try original.save(in: db)
        }
    }
    try store.close()

    let reopened = try SQLiteLibraryStore(rootURL: root)
    defer { try? reopened.close() }
    let snapshot = try await SQLiteLogicalBackupSource(store: reopened).prepare()
    #expect(snapshot.pins.originals.count == 1)
    for id in snapshot.pins.originals.keys {
        let reader = try snapshot.pins.open(id); defer { reader.close() }
        #expect(try reader.read(offset: 0, maximumByteCount: 64 * 1_024) == bytes)
    }
    snapshot.release()

    let reports = SQLiteReportRepository(store: reopened)
    try await reports.discard(draftID: draftID, expectedRevision: try await reports.draft(draftID).revision)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("originals").path).isEmpty)
}

@Test
func sqliteLogicalNativeCopyCancellationUninstallsResources() async throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let store = try SQLiteLibraryStore(rootURL: root)
    defer { try? store.close() }
    let before = try FileManager.default.contentsOfDirectory(atPath: root.deletingLastPathComponent().path).sorted()
    let (entered, signal) = AsyncStream<Void>.makeStream()
    let gate = DispatchSemaphore(value: 0)
    let source = SQLiteLogicalBackupSource(store: store, captureHook: { phase in
        if phase == .copyStep { signal.yield(()); gate.wait() }
    })
    let task = Task { try await source.prepare() }
    for await _ in entered { break }
    task.cancel(); gate.signal()
    await #expect(throws: CancellationError.self) { _ = try await task.value }
    #expect(store.pins.isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.deletingLastPathComponent().path).sorted() == before)
    try await SQLiteReportRepository(store: store).saveMember(FamilyMember(displayName: "Synthetic after copy cancel"), replacing: nil)
}

@Test
func sqliteCaptureOwnershipSupportsParentModeAndPreservesUnknownReceipt() throws {
    let root = try sqliteTestRoot(), parent = root.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: parent) }
    #expect(chmod(parent.path, 0o755) == 0)
    let capture = try SQLiteLogicalCaptureDatabase(rootURL: root)
    try capture.queue.read { db in
        let pageSize = try #require(try Int.fetchOne(db, sql: "PRAGMA page_size"))
        let spill = try #require(try Int.fetchOne(db, sql: "PRAGMA cache_spill"))
        #expect(spill > 0 && spill <= (4 * 1_024 * 1_024) / pageSize)
    }
    try capture.close()
    #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty)
    let operation = UUID()
    let digest = ContentDigest.sha256(Data(root.lastPathComponent.utf8)).map { String(format: "%02x", $0) }.joined()
    let receipt = parent.appendingPathComponent(".kinlogue-sqlite-capture-\(digest)-\(operation.uuidString.lowercased()).receipt.json")
    let marker = Data("Synthetic unknown receipt".utf8)
    try marker.write(to: receipt); #expect(chmod(receipt.path, 0o600) == 0)
    #expect(throws: (any Error).self) { _ = try SQLiteLogicalCaptureDatabase(rootURL: root, operationID: operation) }
    #expect(try Data(contentsOf: receipt) == marker)
    #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path) == [receipt.lastPathComponent])
}

@Test(arguments: [false, true])
func sqliteCaptureCleanupPreservesUnknownChildOrReplacedDatabase(replace: Bool) throws {
    let root = try sqliteTestRoot(), parent = root.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: parent) }
    let capture = try SQLiteLogicalCaptureDatabase(rootURL: root)
    let directory = try #require(FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil).first { $0.pathExtension == "staging" })
    let marker = directory.appendingPathComponent(replace ? "snapshot.sqlite" : "unknown.data")
    if replace {
        try capture.queue.close()
        try FileManager.default.moveItem(at: marker, to: parent.appendingPathComponent("held.sqlite"))
    }
    let bytes = Data("Synthetic unowned child".utf8)
    try bytes.write(to: marker); #expect(chmod(marker.path, 0o600) == 0)
    #expect(throws: (any Error).self) { try capture.close() }
    #expect(try Data(contentsOf: marker) == bytes)
    let owner = try SQLiteLibraryOwner(rootURL: root)
    #expect(throws: (any Error).self) { try SQLiteLogicalBackupSource.reconcileTemporaryCaptures(owner: owner) }
    #expect(try Data(contentsOf: marker) == bytes)
}

/// A capture that never got to clean up after itself, as after a crash. In the second case the
/// launch that removes it finds the volume under another device number than its receipt recorded.
@Test(arguments: [false, true])
func sqliteCaptureLeftBehindIsRemovedAtTheNextLaunch(afterTheVolumeWasRenumbered: Bool) throws {
    let root = try sqliteTestRoot(), parent = root.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: parent) }
    let capture = try SQLiteLogicalCaptureDatabase(rootURL: root)
    try capture.queue.close()
    let left = try FileManager.default.contentsOfDirectory(atPath: parent.path)
    #expect(left.contains { $0.hasSuffix(".staging") } && left.contains { $0.hasSuffix(".receipt.json") })
    if afterTheVolumeWasRenumbered {
        let receipt = parent.appendingPathComponent(try #require(left.first { $0.hasSuffix(".receipt.json") }))
        let text = try String(contentsOf: receipt, encoding: .utf8)
        let pattern = try NSRegularExpression(pattern: #""(?:device|databaseDevice)":(\d+)"#)
        var renumbered = text
        let matches = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
        #expect(matches.count == 2)
        for match in matches.reversed() {
            let digits = try #require(Range(match.range(at: 1), in: renumbered))
            renumbered.replaceSubrange(digits, with: String(try #require(Int(renumbered[digits])) + 3))
        }
        let handle = try FileHandle(forWritingTo: receipt)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(renumbered.utf8))
        try handle.close()
    }

    let owner = try SQLiteLibraryOwner(rootURL: root)
    try SQLiteLogicalBackupSource.reconcileTemporaryCaptures(owner: owner)

    #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path)
        .allSatisfy { !$0.hasSuffix(".staging") && !$0.hasSuffix(".receipt.json") })
    withExtendedLifetime(capture) {}
}

@Test
func sqliteCaptureUnreceiptedEmptyDirectoryDoesNotBlockLibraryStartup() throws {
    let root = try sqliteTestRoot(), parent = root.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: parent) }
    #expect(throws: CancellationError.self) {
        _ = try SQLiteLogicalCaptureDatabase(rootURL: root, observation: { phase in
            if phase == .directoryCreated { throw CancellationError() }
        })
    }
    let before = try FileManager.default.contentsOfDirectory(atPath: parent.path)
    #expect(before.count == 1 && before[0].hasSuffix(".staging"))
    let owner = try SQLiteLibraryOwner(rootURL: root)
    try SQLiteLogicalBackupSource.reconcileTemporaryCaptures(owner: owner)
    #expect(FileManager.default.fileExists(atPath: parent.appendingPathComponent(before[0]).path))
    let store = try SQLiteLibraryStore(owner: owner)
    defer { try? store.close() }
    _ = try store.state()
}

@Test(arguments: [false, true])
func sqliteReadProgressRestoresSemanticErrorAndUninstallsHandler(deadline: Bool) throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let store = try SQLiteLibraryStore(rootURL: root)
    defer { try? store.close() }
    do {
        try store.read { db in
            var calls = 0
            try SQLiteReadProgress.withGuard(db, check: {
                calls += 1
                if calls >= 5 {
                    if deadline { throw SQLiteLogicalBackupError.captureTimedOut }
                    throw CancellationError()
                }
            }) {
                _ = try Int.fetchOne(db, sql: "WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<10000000) SELECT sum(x) FROM n")
            }
        }
        Issue.record("Long query was not interrupted")
    } catch {
        if deadline { #expect(error as? SQLiteLogicalBackupError == .captureTimedOut) }
        else { #expect(error is CancellationError) }
    }
    #expect(try store.read { try Int.fetchOne($0, sql: "SELECT 17") } == 17)
}
