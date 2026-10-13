import CryptoKit
import Darwin
import Foundation
import KinlogueCore
import Testing
@_spi(Testing) @testable import KinloguePlatform

// Restore preparation and whole-root activation against the SQLite library. A restore that
// reopens and edits every repository is in `SQLiteLogicalBackupTests`; real process deaths at
// each activation phase are in `SQLiteLogicalRestoreProcessTests`.

@Suite("Encrypted checkpoint restore", .serialized)
struct EncryptedCheckpointRestoreTests {
    @Test
    func readerRejectsTheFileTreeFormatBeforeStagingWithoutCallingItDamaged() async throws {
        try await withRestoreFixture { fixture in
            let root = try fixture.destinationRoot("file-tree-format")
            let parent = root.deletingLastPathComponent()
            let owner = try SQLiteLibraryOwner(rootURL: root)
            let store = try SQLiteLibraryStore(owner: owner)
            defer { try? store.close() }
            let member = try FamilyMember(displayName: "Synthetic preserved member")
            try await SQLiteReportRepository(store: store).saveMember(member, replacing: nil)
            let before = try restoreTreeSnapshot(at: root)
            let names = try FileManager.default.contentsOfDirectory(atPath: parent.path).sorted()
            let checkpointBytes = try Data(contentsOf: fixture.fileTreeCheckpointURL)

            let verifier = try BackupRestoreVerifier(owner: owner)
            await #expect(throws: BackupRestoreError.unsupportedFormat) {
                _ = try await verifier.prepare(
                    checkpointURL: fixture.fileTreeCheckpointURL,
                    recoveryCode: fixture.recoveryCode
                )
            }

            #expect(try restoreTreeSnapshot(at: root) == before)
            #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path).sorted() == names)
            #expect(try Data(contentsOf: fixture.fileTreeCheckpointURL) == checkpointBytes)
            #expect(try await SQLiteReportRepository(store: store).member(member.id) == member)
        }
    }

    @Test
    func wrongRecoveryCodeLeavesTheLibraryAndTheCheckpointUnchanged() async throws {
        try await withRestoreFixture { fixture in
            let root = try fixture.destinationRoot("wrong-code")
            let owner = try SQLiteLibraryOwner(rootURL: root)
            let store = try SQLiteLibraryStore(owner: owner)
            defer { try? store.close() }
            let member = try FamilyMember(displayName: "Synthetic preserved member")
            try await SQLiteReportRepository(store: store).saveMember(member, replacing: nil)
            let before = try restoreTreeSnapshot(at: root)
            let checkpointBytes = try Data(contentsOf: fixture.checkpointURL)

            let verifier = try BackupRestoreVerifier(owner: owner)
            await #expect(throws: BackupRestoreError.authenticationFailed) {
                _ = try await verifier.prepare(
                    checkpointURL: fixture.checkpointURL,
                    recoveryCode: try BackupRecoveryCode.encode(seed: Data(repeating: 0xEE, count: 32))
                )
            }

            #expect(try restoreTreeSnapshot(at: root) == before)
            #expect(try restoreArtifacts(in: root.deletingLastPathComponent()).isEmpty)
            #expect(try Data(contentsOf: fixture.checkpointURL) == checkpointBytes)
            #expect(try await SQLiteReportRepository(store: store).member(member.id) == member)
        }
    }

    @Test
    func existingLibraryIsReplacedAsOneRootAndTheOldRootSurvivesUntilReconcile() async throws {
        try await withRestoreFixture { fixture in
            let root = try fixture.destinationRoot("replacement")
            let owner = try SQLiteLibraryOwner(rootURL: root)
            let old = try SQLiteLibraryStore(owner: owner)
            let oldMember = try FamilyMember(displayName: "Synthetic previous member")
            try await SQLiteReportRepository(store: old).saveMember(oldMember, replacing: nil)

            let prepared = try await BackupRestoreVerifier(owner: owner).prepare(
                checkpointURL: fixture.checkpointURL,
                recoveryCode: fixture.recoveryCode
            )
            // Preparing touches nothing in the library that is still open.
            #expect(try await SQLiteReportRepository(store: old).member(oldMember.id) == oldMember)

            let transaction = try BackupRestoreTransaction(owner: owner)
            // The root cannot be swapped under an open database.
            await #expect(throws: SQLiteLibraryError.occupied) {
                _ = try await transaction.activate(prepared: prepared, resetWriter: {})
            }
            try old.close()

            _ = try await transaction.activate(prepared: prepared, resetWriter: {})
            #expect(try transaction.rollbackIdentityForTesting() != nil)

            #expect(try await transaction.reconcile() == .committed)
            #expect(try transaction.rollbackIdentityForTesting() == nil)
            #expect(try restoreArtifacts(in: root.deletingLastPathComponent()).isEmpty)
            let restored = try SQLiteLibraryStore(owner: owner, mode: .strictExisting)
            defer { try? restored.close() }
            #expect(try await SQLiteReportRepository(store: restored).members() == [fixture.sourceMember])
            #expect(try SQLiteLogicalBackupSource(store: restored).currentRevision() == fixture.revisionPair)
        }
    }

    /// The second case rewrites the device numbers the receipts recorded before the next launch
    /// reads them, which is what a restart that renumbers the volume leaves behind.
    @Test(arguments: [false, true])
    func interruptionAfterTheOldRootMoveReconcilesToTheCompleteOldRoot(afterTheVolumeWasRenumbered: Bool) async throws {
        try await withRestoreFixture { fixture in
            let root = try fixture.destinationRoot("rollback")
            let owner = try SQLiteLibraryOwner(rootURL: root)
            let oldMember = try await seedClosedLibrary(owner: owner)
            let before = try restoreTreeSnapshot(at: root)
            let prepared = try await BackupRestoreVerifier(owner: owner).prepare(
                checkpointURL: fixture.checkpointURL,
                recoveryCode: fixture.recoveryCode
            )

            let interrupted = try BackupRestoreTransaction(
                owner: owner,
                failureInjector: { $0 == .afterOldRootMove }
            )
            await #expect(throws: BackupRestoreError.injectedFailure) {
                _ = try await interrupted.activate(prepared: prepared, resetWriter: {})
            }
            if afterTheVolumeWasRenumbered { try renumberRecordedDevices(inReceiptsOf: root) }

            #expect(try await BackupRestoreTransaction(owner: owner).reconcile() == .rolledBack)
            #expect(try restoreArtifacts(in: root.deletingLastPathComponent()).isEmpty)
            #expect(try restoreTreeSnapshot(at: root) == before)
            let reopened = try SQLiteLibraryStore(owner: owner, mode: .strictExisting)
            defer { try? reopened.close() }
            #expect(try await SQLiteReportRepository(store: reopened).members() == [oldMember])
        }
    }

    @Test
    func aRestoreInterruptedAfterActivationCommitsOnceTheVolumeHasBeenRenumbered() async throws {
        try await withRestoreFixture { fixture in
            let root = try fixture.destinationRoot("renumbered-forward")
            let owner = try SQLiteLibraryOwner(rootURL: root)
            _ = try await seedClosedLibrary(owner: owner)
            let prepared = try await BackupRestoreVerifier(owner: owner).prepare(
                checkpointURL: fixture.checkpointURL,
                recoveryCode: fixture.recoveryCode
            )
            let interrupted = try BackupRestoreTransaction(
                owner: owner,
                failureInjector: { $0 == .afterNewRootActivation }
            )
            await #expect(throws: BackupRestoreError.injectedFailure) {
                _ = try await interrupted.activate(prepared: prepared, resetWriter: {})
            }
            try renumberRecordedDevices(inReceiptsOf: root)

            // The new root is in place and the old one set aside; the receipt has to recognize
            // both by inode to finish the restore instead of refusing to converge.
            #expect(try await BackupRestoreTransaction(owner: owner).reconcile() == .committed)
            #expect(try restoreArtifacts(in: root.deletingLastPathComponent()).isEmpty)
            let restored = try SQLiteLibraryStore(owner: owner, mode: .strictExisting)
            defer { try? restored.close() }
            #expect(try await SQLiteReportRepository(store: restored).members() == [fixture.sourceMember])
        }
    }

    @Test
    func truncatedActivationReceiptFailsClosedAndLeavesTheOldRoot() async throws {
        try await withRestoreFixture { fixture in
            let root = try fixture.destinationRoot("truncated-receipt")
            let parent = root.deletingLastPathComponent()
            let owner = try SQLiteLibraryOwner(rootURL: root)
            _ = try await seedClosedLibrary(owner: owner)
            let before = try restoreTreeSnapshot(at: root)
            let prepared = try await BackupRestoreVerifier(owner: owner).prepare(
                checkpointURL: fixture.checkpointURL,
                recoveryCode: fixture.recoveryCode
            )
            let interrupted = try BackupRestoreTransaction(
                owner: owner,
                failureInjector: { $0 == .afterIntent }
            )
            await #expect(throws: BackupRestoreError.injectedFailure) {
                _ = try await interrupted.activate(prepared: prepared, resetWriter: {})
            }
            let receipts = try restoreArtifacts(in: parent).filter {
                $0.hasPrefix(".kinlogue-restore-transaction-") && $0.hasSuffix(".json")
            }
            let receipt = parent.appendingPathComponent(try #require(receipts.first))
            #expect(receipts.count == 1)
            try Data(#"{"magic":"truncated""#.utf8).write(to: receipt)
            #expect(chmod(receipt.path, 0o600) == 0)

            await #expect(throws: BackupRestoreError.receiptInvalid) {
                _ = try await BackupRestoreTransaction(owner: owner).reconcile()
            }
            // Nothing is guessed from a receipt that cannot be read: the old root stays in place.
            #expect(try restoreTreeSnapshot(at: root) == before)
        }
    }

    @Test(arguments: [false, true])
    func abandonedPreflightReconciliationRemovesOnlyReceiptBoundStaging(afterTheVolumeWasRenumbered: Bool) async throws {
        try await withRestoreFixture { fixture in
            let root = try fixture.destinationRoot("abandoned-preflight")
            let parent = root.deletingLastPathComponent()
            let owner = try SQLiteLibraryOwner(rootURL: root)
            _ = try await BackupRestoreVerifier(owner: owner).prepare(
                checkpointURL: fixture.checkpointURL,
                recoveryCode: fixture.recoveryCode
            )
            #expect(try !restoreArtifacts(in: parent).isEmpty)
            // A directory that only looks like staging has no receipt, so it is not ours to remove.
            let unowned = parent.appendingPathComponent(
                ".kinlogue-restore-\(UUID().uuidString.lowercased()).staging",
                isDirectory: true
            )
            try makePrivateDirectory(unowned)
            try Data("synthetic unowned file".utf8).write(to: unowned.appendingPathComponent("kept.bin"))
            if afterTheVolumeWasRenumbered { try renumberRecordedDevices(inReceiptsOf: root) }

            try BackupRestoreVerifier(owner: owner).reconcileAbandonedPreflights()

            #expect(try restoreArtifacts(in: parent) == [unowned.lastPathComponent])
            #expect(FileManager.default.fileExists(atPath: unowned.appendingPathComponent("kept.bin").path))
            #expect(!FileManager.default.fileExists(atPath: root.path))
        }
    }
}

private struct RestoreFixture {
    let base: URL
    /// A checkpoint of the source library in the logical format the App writes.
    let checkpointURL: URL
    /// A correctly signed and encrypted checkpoint in the earlier file-tree layout.
    let fileTreeCheckpointURL: URL
    let recoveryCode: String
    let sourceMember: FamilyMember
    let revisionPair: BackupRevisionPair

    /// The root path of a library inside its own private parent directory. Nothing is created
    /// at the root itself.
    func destinationRoot(_ name: String) throws -> URL {
        let parent = base.appendingPathComponent(name, isDirectory: true)
        try makePrivateDirectory(parent)
        return parent.appendingPathComponent("Vault", isDirectory: true)
    }
}

private func withRestoreFixture(_ body: (RestoreFixture) async throws -> Void) async throws {
    let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(
        "KinlogueRestore-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: base) }
    try makePrivateDirectory(base)
    let sourceParent = base.appendingPathComponent("source", isDirectory: true)
    try makePrivateDirectory(sourceParent)
    let source = try SQLiteLibraryStore(rootURL: sourceParent.appendingPathComponent("Vault", isDirectory: true))
    let member = try FamilyMember(displayName: "Synthetic restored member")
    try await SQLiteReportRepository(store: source).saveMember(member, replacing: nil)
    let original = Data("synthetic restore original".utf8)
    let upload = try await SQLiteLANInboxStore(store: source).startItemUpload(
        transport: .init(sessionID: UUID(), remoteFileID: UUID()),
        metadata: try .init(displayName: .init(rawValue: "restore.bin"), declaredByteCount: original.count),
        attemptRevision: 0
    )
    guard case let .sink(sink) = upload else { throw LANInboxError.invalidState }
    try await sink.write(original).value
    _ = try await sink.finish()

    let enrollment = try BackupKeyHierarchy.makeEnrollment()
    let signer = try BackupDeviceSigner(
        descriptor: enrollment.descriptor,
        authorization: enrollment.authorization,
        deviceSigningSeed: enrollment.deviceSigningSeed
    )
    func writeCheckpoint(
        named name: String,
        entries: [BackupContainerEntrySource],
        revisionPair: BackupRevisionPair
    ) async throws -> URL {
        let bytes = RestoreLockedBytes()
        _ = try await EncryptedBackupContainerWriter().write(
            entries: entries,
            revisionPair: revisionPair,
            sequence: 1,
            signer: signer,
            sink: .init(write: bytes.append, readBackSource: bytes.source)
        )
        let url = base.appendingPathComponent(name)
        try bytes.data.write(to: url, options: .withoutOverwriting)
        #expect(chmod(url.path, 0o600) == 0)
        return url
    }

    let snapshot = try await SQLiteLogicalBackupSource(store: source).prepare()
    let revisionPair = snapshot.revisionPair
    let checkpointURL: URL
    do {
        defer { snapshot.release() }
        checkpointURL = try await writeCheckpoint(
            named: "logical.kinloguebackup",
            entries: snapshot.sources(),
            revisionPair: revisionPair
        )
    }
    try source.close()
    let fileTreeCheckpointURL = try await writeCheckpoint(
        named: "file-tree.kinloguebackup",
        entries: [
            fileTreeEntry(.vaultCatalog, path: "library.json", bytes: Data("{}".utf8)),
            fileTreeEntry(.lanInboxManifest, path: "lan-inbox/inbox.json", bytes: Data("{}".utf8)),
            fileTreeEntry(.vaultObject, path: "objects/payload.bin", bytes: Data("synthetic file-tree object".utf8)),
        ],
        revisionPair: revisionPair
    )

    try await body(RestoreFixture(
        base: base,
        checkpointURL: checkpointURL,
        fileTreeCheckpointURL: fileTreeCheckpointURL,
        recoveryCode: enrollment.recoveryCode,
        sourceMember: member,
        revisionPair: revisionPair
    ))
}

private func fileTreeEntry(
    _ kind: BackupManifestEntry.Kind,
    path: String,
    bytes: Data
) -> BackupContainerEntrySource {
    BackupContainerEntrySource(
        kind: kind,
        path: path,
        plaintextByteCount: UInt64(bytes.count),
        plaintextDigest: Data(SHA256.hash(data: bytes))
    ) { offset, maximum in
        guard offset <= UInt64(bytes.count) else { return Data() }
        let start = Int(offset)
        return Data(bytes[start..<min(bytes.count, start + maximum)])
    }
}

/// Creates a library with one member under `owner` and leaves its database closed.
private func seedClosedLibrary(owner: SQLiteLibraryOwner) async throws -> FamilyMember {
    let store = try SQLiteLibraryStore(owner: owner)
    let member = try FamilyMember(displayName: "Synthetic previous member")
    do {
        try await SQLiteReportRepository(store: store).saveMember(member, replacing: nil)
    } catch {
        try? store.close()
        throw error
    }
    try store.close()
    return member
}

private final class RestoreLockedBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    func append(_ bytes: Data) { lock.withLock { storage.append(bytes) } }
    var data: Data { lock.withLock { storage } }
    func source() -> BackupContainerByteSource {
        let snapshot = data
        return .init(byteCount: UInt64(snapshot.count)) { offset, count in
            guard offset <= UInt64(snapshot.count) else { return Data() }
            let start = Int(offset)
            return Data(snapshot[start..<min(snapshot.count, start + count)])
        }
    }
}

private struct RestoreTreeEntry: Equatable {
    let isDirectory: Bool
    let bytes: Data
}

private func restoreTreeSnapshot(at root: URL) throws -> [String: RestoreTreeEntry] {
    let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]
    let enumerator = try #require(FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: resourceKeys,
        options: [],
        errorHandler: { _, _ in false }
    ))
    var snapshot: [String: RestoreTreeEntry] = [:]
    for case let url as URL in enumerator {
        let values = try url.resourceValues(forKeys: Set(resourceKeys))
        let relativePath = String(url.path.dropFirst(root.path.count + 1))
        if values.isDirectory == true {
            snapshot[relativePath] = RestoreTreeEntry(isDirectory: true, bytes: Data())
        } else {
            #expect(values.isRegularFile == true)
            snapshot[relativePath] = RestoreTreeEntry(
                isDirectory: false,
                bytes: try Data(contentsOf: url)
            )
        }
    }
    return snapshot
}

private func makePrivateDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    guard chmod(url.path, 0o700) == 0 else { throw CocoaError(.fileWriteUnknown) }
}

/// Adds three to every device number recorded in the restore receipts beside `root`, leaving the
/// inodes alone: the directories are the same ones, named by a number the volume no longer has.
private func renumberRecordedDevices(inReceiptsOf root: URL) throws {
    let parent = root.deletingLastPathComponent()
    let receipts = try restoreArtifacts(in: parent).filter { $0.hasSuffix(".json") }
    #expect(!receipts.isEmpty)
    let pattern = try NSRegularExpression(pattern: #""device":(\d+)"#)
    for name in receipts {
        let url = parent.appendingPathComponent(name)
        let text = try String(contentsOf: url, encoding: .utf8)
        var renumbered = text
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            let digits = try #require(Range(match.range(at: 1), in: renumbered))
            renumbered.replaceSubrange(digits, with: String(try #require(Int(renumbered[digits])) + 3))
        }
        #expect(renumbered != text)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(renumbered.utf8))
        try handle.close()
    }
}

private func restoreArtifacts(in parent: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: parent.path).filter {
        $0.hasPrefix(".kinlogue-restore-")
    }
}
