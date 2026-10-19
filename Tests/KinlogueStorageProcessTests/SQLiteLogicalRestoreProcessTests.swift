import Darwin
import Foundation
import KinlogueCore
import Testing
@testable import KinloguePlatform

// Existing phases 1...6; absent phases except old-root rename; two damaged activations.
@Test(arguments: [1, 2, 3, 4, 5, 6, 7, 8, 10, 11, 12, 13, 14])
func sqliteLogicalRestoreSurvivesRealRootPhaseCrashesAndRollsBackDamage(scenario: Int) async throws {
    let existing = scenario <= 6 || scenario == 13
    let phase = scenario >= 13 ? 4 : (scenario - 1) % 6 + 1
    try await withOwnedVaultFixture { fixture in
        let parent = fixture.rootURL.deletingLastPathComponent()
        let sourceRoot = parent.appendingPathComponent("LogicalSource")
        let source = try SQLiteLibraryStore(rootURL: sourceRoot)
        let member = try FamilyMember(displayName: "Synthetic restored logical member")
        try await SQLiteReportRepository(store: source).saveMember(member, replacing: nil)
        let inbox = try SQLiteLANInboxStore(store: source)
        let original = Data("Synthetic logical original".utf8)
        let transport = LANInboxTransportIdentity(sessionID: UUID(), remoteFileID: UUID())
        let metadata = try LANInboxTransportMetadata(displayName: LANInboxDisplayName(rawValue: "Synthetic.bin"), declaredByteCount: original.count)
        guard case let .sink(sink) = try await inbox.startItemUpload(transport: transport, metadata: metadata, attemptRevision: 1) else { throw SQLiteLibraryError.damaged }
        try await sink.write(original).value; _ = try await sink.finish()
        let captured = try SQLiteLogicalBackupSource(store: source).currentRevision()
        _ = try await BackupArchiveWriter(store: source).write(
            to: .file(parent.appendingPathComponent("logical.zip")),
            content: BackupArchiveContent(
                labels: BackupArchiveLabels(undated: "Undated", pendingFolder: "Pending", phoneFolder: "Phone", otherFolder: "Other"),
                creator: try BackupArchiveIndex.Creator(app: "Kinlogue", version: "test", build: "test"),
                readmeFileName: "README.txt",
                readmeText: "Synthetic process restore backup"
            )
        )
        try source.close()
        var oldFiles: [String: Data] = [:]
        if existing {
            let old = try SQLiteLibraryStore(rootURL: fixture.rootURL)
            try await SQLiteReportRepository(store: old).saveMember(FamilyMember(displayName: "Synthetic old member"), replacing: nil)
            let oldInbox = try SQLiteLANInboxStore(store: old)
            let oldOriginal = Data("Synthetic previous root original".utf8)
            guard case let .sink(oldSink) = try await oldInbox.startItemUpload(
                transport: LANInboxTransportIdentity(sessionID: UUID(), remoteFileID: UUID()),
                metadata: LANInboxTransportMetadata(displayName: LANInboxDisplayName(rawValue: "Old.bin"), declaredByteCount: oldOriginal.count),
                attemptRevision: 1) else { throw SQLiteLibraryError.damaged }
            try await oldSink.write(oldOriginal).value; _ = try await oldSink.finish()
            try old.close()
            oldFiles = try sqliteLogicalRootFiles(fixture.rootURL)
        }
        try await withStorageProcessFixture(processCount: 1) { processes in
            let process = processes[0]
            try process.send(.init(operation: "holdSQLiteLogicalRestore", rootURL: fixture.rootURL, variant: phase))
            #expect(try await process.nextResponse().event == "leaseHeld")
            #expect(throws: SQLiteLibraryError.occupied) { _ = try SQLiteLibraryStore(rootURL: fixture.rootURL) }
            try await process.crash()
        }
        if scenario >= 13 {
            let originals = fixture.rootURL.appendingPathComponent("originals")
            let file = try #require(FileManager.default.contentsOfDirectory(at: originals, includingPropertiesForKeys: nil).first)
            let fd = Darwin.open(file.path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
            #expect(fd >= 0); #expect(pwrite(fd, [UInt8(0)], 1, 0) == 1); close(fd)
        }
        let owner = try SQLiteLibraryOwner(rootURL: fixture.rootURL)
        let transaction = try BackupRestoreTransaction(owner: owner)
        let outcome = try await transaction.reconcile()
        try BackupRestoreVerifier(owner: owner).reconcileAbandonedPreflights()
        let expectNew = phase >= 4 && scenario < 13
        if expectNew {
            #expect(outcome == .committed)
            let restored = try SQLiteLibraryStore(owner: owner, mode: .strictExisting)
            defer { try? restored.close() }
            #expect(try SQLiteLogicalBackupSource(store: restored).currentRevision() == captured)
            #expect(try await SQLiteReportRepository(store: restored).member(member.id) == member)
            let restoredInbox = try SQLiteLANInboxStore(store: restored)
            let state = try await restoredInbox.loadSnapshot()
            #expect(state.items.count == 1 && state.transportReceipts.count == 1)
            _ = try SQLiteLogicalBackupSource(store: restored).validateStrict()
        } else if existing {
            #expect(try sqliteLogicalRootFiles(fixture.rootURL) == oldFiles)
        } else {
            #expect(!FileManager.default.fileExists(atPath: fixture.rootURL.path))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path).allSatisfy { !$0.hasSuffix(".staging") && !$0.hasSuffix(".preflight.json") && !$0.hasPrefix(".kinlogue-restore-rollback-") && !$0.hasPrefix(".kinlogue-restore-transaction-") })
    }
}

private func sqliteLogicalRootFiles(_ root: URL) throws -> [String: Data] {
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { throw SQLiteLibraryError.invalidPath }
    var result: [String: Data] = [:]
    for case let url as URL in enumerator {
        if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            result[String(url.path.dropFirst(root.path.count + 1))] = try Data(contentsOf: url)
        }
    }
    return result
}

@Test(arguments: [1, 2, 3, 4, 5, 6])
func sqliteLogicalCaptureTemporaryDatabaseSurvivesRealProcessDeath(scenario: Int) async throws {
    try await withOwnedVaultFixture { fixture in
        let root = fixture.rootURL, parent = root.deletingLastPathComponent()
        let store = try SQLiteLibraryStore(rootURL: root)
        try await SQLiteReportRepository(store: store).saveMember(FamilyMember(displayName: "Synthetic capture crash member"), replacing: nil)
        let inbox = try SQLiteLANInboxStore(store: store)
        let original = Data("Synthetic capture crash original".utf8)
        guard case let .sink(sink) = try await inbox.startItemUpload(
            transport: LANInboxTransportIdentity(sessionID: UUID(), remoteFileID: UUID()),
            metadata: LANInboxTransportMetadata(displayName: LANInboxDisplayName(rawValue: "Synthetic.bin"), declaredByteCount: original.count),
            attemptRevision: 1) else { throw SQLiteLibraryError.damaged }
        try await sink.write(original).value; _ = try await sink.finish()
        try store.close()
        let before = try sqliteLogicalRootFiles(root)
        try await withStorageProcessFixture(processCount: 1) { processes in
            let process = processes[0]
            try process.send(.init(operation: "holdSQLiteLogicalCapture", rootURL: root, variant: min(scenario, 4)))
            #expect(try await process.nextResponse().event == "leaseHeld")
            #expect(throws: SQLiteLibraryError.occupied) { _ = try SQLiteLibraryOwner(rootURL: root) }
            try await process.crash()
        }
        let artifacts = try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".kinlogue-sqlite-capture-") }
        let directory = try #require(artifacts.first { $0.lastPathComponent.hasSuffix(".staging") })
        var protectedFile: URL?
        let marker = Data("Synthetic unknown capture file".utf8)
        if scenario >= 5 {
            let path = directory.appendingPathComponent(scenario == 5 ? "unknown.data" : "snapshot.sqlite")
            if scenario == 6 { try FileManager.default.moveItem(at: path, to: parent.appendingPathComponent("held.sqlite")) }
            try marker.write(to: path); #expect(chmod(path.path, 0o600) == 0)
            protectedFile = path
        }
        let owner = try SQLiteLibraryOwner(rootURL: root)
        if let protectedFile {
            #expect(throws: (any Error).self) { try SQLiteLogicalBackupSource.reconcileTemporaryCaptures(owner: owner) }
            #expect(try Data(contentsOf: protectedFile) == marker)
            #expect(try sqliteLogicalRootFiles(root) == before)
            return
        }
        try SQLiteLogicalBackupSource.reconcileTemporaryCaptures(owner: owner)
        #expect(try sqliteLogicalRootFiles(root) == before)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: parent.path).filter { $0.hasPrefix(".kinlogue-sqlite-capture-") }
        #expect(scenario == 1 ? remaining == [directory.lastPathComponent] : remaining.isEmpty)
        let reopened = try SQLiteLibraryStore(owner: owner)
        defer { try? reopened.close() }
        _ = try SQLiteLogicalBackupSource(store: reopened).validateStrict()
    }
}
