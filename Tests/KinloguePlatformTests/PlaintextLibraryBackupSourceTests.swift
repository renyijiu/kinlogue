import CryptoKit
import Foundation
import KinlogueCore
import Testing
@testable import KinloguePlatform

@Suite("Whole-library backup source", .serialized)
struct PlaintextLibraryBackupSourceTests {
    @Test
    func freezesOneVaultAndInboxPairAndStreamsEveryCanonicalEntry() async throws {
        try await withLibraryBackupFixture { fixture in
            let source = try PlaintextLibraryBackupSource(
                vault: fixture.vault,
                inboxStore: fixture.inbox
            )
            let plan = try await source.prepare()
            let output = SourceTestLockedBytes()

            let sources = await source.containerSources(for: plan)
            #expect(sources.contains {
                $0.kind == .lanInboxDerivedArtifact
                    && $0.path == fixture.inboxDerivedArtifactPath
            })
            #expect(!sources.contains {
                $0.path == fixture.inboxPreprocessingPartialPath
            })

            let result = try await EncryptedBackupContainerWriter().write(
                entries: sources,
                revisionPair: plan.revisionPair,
                sequence: 1,
                signer: fixture.signer,
                sink: .init(write: output.append, readBackSource: output.source)
            )

            #expect(result.manifest.revisionPair == plan.revisionPair)
            #expect(result.manifest.entryCount == plan.entryCount)
            #expect(result.maximumBufferedPlaintextByteCount
                <= BackupFormatLimits.maximumFramePlaintextByteCount)
            #expect(await source.maximumSimultaneousOpenFileCount == 1)

            let restored = SourceTestLockedEntries()
            let read = try BackupContainerReader().read(
                source: output.source(),
                recoverySeed: fixture.recoverySeed,
                sink: restored.sink
            )
            #expect(read.manifest.revisionPair == plan.revisionPair)
            #expect(restored.value(for: "library.json") == fixture.vaultManifestBytes)
            #expect(restored.value(for: fixture.vaultObjectPath) == fixture.vaultObjectBytes)
            #expect(restored.value(for: "lan-inbox/inbox.json") == fixture.inboxManifestBytes)
            #expect(restored.value(for: fixture.inboxBlobPath) == fixture.inboxBlobBytes)
            #expect(restored.value(for: fixture.inboxDerivedArtifactPath)
                == fixture.inboxDerivedArtifactBytes)
            #expect(restored.value(for: fixture.inboxPreprocessingPartialPath) == nil)
        }
    }

    @Test
    func refusesAnEntryAfterEitherDurableHeadChanges() async throws {
        try await withLibraryBackupFixture { fixture in
            let source = try PlaintextLibraryBackupSource(
                vault: fixture.vault,
                inboxStore: fixture.inbox
            )
            let plan = try await source.prepare()
            let current = try await fixture.vault.loadCatalog()
            let member = try FamilyMember(displayName: "Concurrent synthetic member")
            _ = try await fixture.vault.commit(try VaultCommitRequest(
                expectedGeneration: current.generation,
                catalog: VaultCatalog(
                    vaultID: current.vaultID,
                    generation: try VaultGeneration.successor(of: current.generation),
                    members: current.members + [member],
                    records: current.records,
                    attachments: current.attachments,
                    importDrafts: current.importDrafts,
                    dicomStudies: current.dicomStudies
                ),
                writes: []
            ))

            await #expect(throws: PlaintextLibraryBackupSourceError.sourceChanged) {
                try await source.validateCurrentPair(for: plan)
            }
        }
    }
}

private struct LibraryBackupFixture {
    let base: URL
    let root: URL
    let vault: PlaintextVault
    let inbox: PlaintextLANInboxStore
    let recoverySeed: Data
    let signer: BackupDeviceSigner
    let vaultManifestBytes: Data
    let vaultObjectPath: String
    let vaultObjectBytes: Data
    let inboxManifestBytes: Data
    let inboxBlobPath: String
    let inboxBlobBytes: Data
    let inboxDerivedArtifactPath: String
    let inboxDerivedArtifactBytes: Data
    let inboxPreprocessingPartialPath: String
}

private func withLibraryBackupFixture(
    _ body: (LibraryBackupFixture) async throws -> Void
) async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(
        "KinlogueLibraryBackup-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let root = base.appendingPathComponent("Vault", isDirectory: true)
    let vault = try PlaintextVault(rootURL: root)
    let initial = try await vault.initialize()
    let objectBytes = Data("synthetic-vault-object".utf8)
    let attachment = try Attachment(
        contentTypeIdentifier: "public.data",
        byteCount: objectBytes.count,
        sha256Digest: Data(SHA256.hash(data: objectBytes))
    )
    let objectReference = VaultObjectReference(id: attachment.id, kind: .attachment)
    _ = try await vault.commit(try VaultCommitRequest(
        expectedGeneration: initial.generation,
        catalog: VaultCatalog(
            vaultID: initial.vaultID,
            generation: try VaultGeneration.successor(of: initial.generation),
            attachments: [attachment]
        ),
        writes: [.init(reference: objectReference, plaintext: objectBytes)]
    ))

    let inbox = try PlaintextLANInboxStore(rootURL: root)
    _ = try await inbox.initialize()
    let inboxBytes = Data("synthetic-inbox-blob".utf8)
    let reviewableItem = try await uploadLibraryBackupBlob(
        inboxBytes,
        name: "synthetic-reviewable.bin",
        to: inbox
    )
    let derivedBytes = Data("synthetic-derived-artifact".utf8)
    let derivedSink = try await inbox.beginItemDerivedArtifact(
        itemID: reviewableItem.id,
        expectedRevision: reviewableItem.revision
    )
    try await derivedSink.write(derivedBytes).value
    _ = try await derivedSink.finish()

    let preprocessingItem = try await uploadLibraryBackupBlob(
        Data("synthetic-preprocessing-blob".utf8),
        name: "synthetic-preprocessing.bin",
        to: inbox
    )
    let preprocessingSink = try await inbox.beginItemDerivedArtifact(
        itemID: preprocessingItem.id,
        expectedRevision: preprocessingItem.revision
    )
    try await preprocessingSink.write(Data("transient-partial".utf8)).value

    let inboxSnapshot = try await inbox.loadSnapshot()
    let blob = try #require(inboxSnapshot.blobs.first(where: {
        $0.id == reviewableItem.blobID
    }))
    let reviewable = try #require(inboxSnapshot.item(id: reviewableItem.id))
    let artifact = try #require(reviewable.derivedArtifact)
    let preprocessing = try #require(inboxSnapshot.item(id: preprocessingItem.id))
    let attemptID = try #require(preprocessing.attemptID)

    let recoverySeed = Data((1...32).map(UInt8.init))
    let material = try BackupKeyHierarchy.makeEnrollment(
        recoverySeed: recoverySeed,
        setID: .init(bytes: Data((33...48).map(UInt8.init))),
        deviceSigningSeed: Data((65...96).map(UInt8.init)),
        deviceID: .init(bytes: Data((97...112).map(UInt8.init))),
        authorizationID: .init(bytes: Data((113...128).map(UInt8.init))),
        writerEpoch: .init(bytes: Data((129...144).map(UInt8.init)))
    )
    let signer = try BackupDeviceSigner(
        descriptor: material.descriptor,
        authorization: material.authorization,
        deviceSigningSeed: material.deviceSigningSeed
    )
    let layout = try PlaintextVaultLayout(rootURL: root)
    let fixture = LibraryBackupFixture(
        base: base,
        root: root,
        vault: vault,
        inbox: inbox,
        recoverySeed: recoverySeed,
        signer: signer,
        vaultManifestBytes: try Data(contentsOf: root.appendingPathComponent("library.json")),
        vaultObjectPath: layout.objectPath(objectReference),
        vaultObjectBytes: objectBytes,
        inboxManifestBytes: try Data(
            contentsOf: root.appendingPathComponent("lan-inbox/inbox.json")
        ),
        inboxBlobPath: "lan-inbox/blobs/\(blob.id.uuidString.lowercased()).blob",
        inboxBlobBytes: inboxBytes,
        inboxDerivedArtifactPath:
            "lan-inbox/derived/\(artifact.id.uuidString.lowercased()).data",
        inboxDerivedArtifactBytes: derivedBytes,
        inboxPreprocessingPartialPath:
            "lan-inbox/partials/\(attemptID.uuidString.lowercased()).partial"
    )
    do {
        try await body(fixture)
    } catch {
        await preprocessingSink.abort()
        throw error
    }
    await preprocessingSink.abort()
}

private func uploadLibraryBackupBlob(
    _ bytes: Data,
    name: String,
    to store: PlaintextLANInboxStore
) async throws -> LANInboxItem {
    let admission = try await store.itemAdmissionGeneration()
    let outcome = try await store.startItemUpload(
        transport: .init(sessionID: UUID(), remoteFileID: UUID()),
        metadata: try .init(
            displayName: .init(rawValue: name),
            declaredByteCount: bytes.count
        ),
        attemptRevision: 0,
        admissionGeneration: admission
    )
    guard case let .sink(sink) = outcome else { throw LANInboxError.invalidState }
    try await sink.write(bytes).value
    _ = try await sink.finish()
    return try #require(try await store.loadSnapshot().items.first {
        $0.displayName.rawValue == name
    })
}

private final class SourceTestLockedBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ bytes: Data) { lock.withLock { storage.append(bytes) } }

    func source() -> BackupContainerByteSource {
        let snapshot = lock.withLock { storage }
        return .init(byteCount: UInt64(snapshot.count)) { offset, count in
            guard offset <= UInt64(snapshot.count) else { return Data() }
            let start = Int(offset)
            return Data(snapshot[start..<min(snapshot.count, start + count)])
        }
    }
}

private final class SourceTestLockedEntries: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: Data] = [:]

    lazy var sink = BackupContainerEntrySink { [weak self] entry in
        { [weak self] bytes in
            self?.lock.withLock { self?.entries[entry.path, default: Data()].append(bytes) }
        }
    }

    func value(for path: String) -> Data? { lock.withLock { entries[path] } }
}
