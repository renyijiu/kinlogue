import Foundation
import Testing
@testable import KinlogueCore
@testable import KinloguePlatform

@Suite("Canonical LAN pending-item store", .serialized)
struct LANPendingItemStoreTests {
    @Test
    func equalBodiesWithDifferentNamesPublishOneStableItemAndTwoReceipts() async throws {
        let fixture = try await LANInboxStoreTestFixture.make()
        defer { fixture.destroy() }
        let sessionID = UUID()
        let bytes = Data("synthetic canonical source".utf8)

        try await upload(
            bytes,
            store: fixture.store,
            sessionID: sessionID,
            remoteFileID: UUID(),
            displayName: "first.pdf"
        )
        try await upload(
            bytes,
            store: fixture.store,
            sessionID: sessionID,
            remoteFileID: UUID(),
            displayName: "later-name.pdf"
        )

        let snapshot = try await fixture.store.loadSnapshot()
        #expect(snapshot.items.count == 1)
        #expect(snapshot.blobs.count == 1)
        #expect(snapshot.transportReceipts.count == 2)
        #expect(snapshot.items.first?.displayName.rawValue == "first.pdf")
        #expect(snapshot.items.first?.sequence == 0)
        let outcomes = snapshot.transportReceipts.map(\.outcome)
        #expect(outcomes.contains { if case .published = $0 { true } else { false } })
        #expect(outcomes.contains { if case .merged = $0 { true } else { false } })
    }

    @Test
    func equalMetadataWithDifferentBodiesPublishesTwoItems() async throws {
        let fixture = try await LANInboxStoreTestFixture.make()
        defer { fixture.destroy() }
        let sessionID = UUID()

        try await upload(
            Data("synthetic source one".utf8),
            store: fixture.store,
            sessionID: sessionID,
            remoteFileID: UUID(),
            displayName: "same-name.bin"
        )
        try await upload(
            Data("synthetic source two".utf8),
            store: fixture.store,
            sessionID: sessionID,
            remoteFileID: UUID(),
            displayName: "same-name.bin"
        )

        let snapshot = try await fixture.store.loadSnapshot()
        #expect(snapshot.items.count == 2)
        #expect(snapshot.blobs.count == 2)
        #expect(snapshot.items.map(\.sequence) == [0, 1])
    }

    @Test
    func terminalTransportIdentityReplaysAndChangedMetadataConflictsBeforeBody() async throws {
        let fixture = try await LANInboxStoreTestFixture.make()
        defer { fixture.destroy() }
        let transport = LANInboxTransportIdentity(
            sessionID: UUID(),
            remoteFileID: UUID()
        )
        let bytes = Data("synthetic replay source".utf8)
        let metadata = try LANInboxTransportMetadata(
            displayName: LANInboxDisplayName(rawValue: "replay.bin"),
            declaredByteCount: bytes.count
        )
        let generation = try await fixture.store.itemAdmissionGeneration()
        let started = try await fixture.store.startItemUpload(
            transport: transport,
            metadata: metadata,
            attemptRevision: 0,
            admissionGeneration: generation
        )
        let sink = try requireSink(started)
        try await sink.write(bytes).value
        _ = try await sink.finish()

        let replay = try await fixture.store.startItemUpload(
            transport: transport,
            metadata: metadata,
            attemptRevision: 9,
            admissionGeneration: generation
        )
        guard case .terminal = replay else {
            Issue.record("Expected terminal replay without a second body")
            return
        }

        let changed = try LANInboxTransportMetadata(
            displayName: LANInboxDisplayName(rawValue: "changed.bin"),
            declaredByteCount: bytes.count
        )
        await #expect(throws: LANInboxError.receiptConflict) {
            _ = try await fixture.store.startItemUpload(
                transport: transport,
                metadata: changed,
                attemptRevision: 10,
                admissionGeneration: generation
            )
        }
    }

    @Test
    func deleteTerminalFencesAdmittedBodyButAllowsFreshIdentity() async throws {
        let fixture = try await LANInboxStoreTestFixture.make()
        defer { fixture.destroy() }
        let sessionID = UUID()
        let bytes = Data("synthetic late body".utf8)
        let admission = try await fixture.store.itemAdmissionGeneration()

        let first = try await start(
            store: fixture.store,
            sessionID: sessionID,
            remoteFileID: UUID(),
            displayName: "winner.bin",
            byteCount: bytes.count,
            admissionGeneration: admission
        )
        let late = try await start(
            store: fixture.store,
            sessionID: sessionID,
            remoteFileID: UUID(),
            displayName: "late.bin",
            byteCount: bytes.count,
            admissionGeneration: admission
        )
        try await first.write(bytes).value
        _ = try await first.finish()

        let beforeDelete = try await fixture.store.loadSnapshot()
        let item = try #require(beforeDelete.items.first)
        _ = try await fixture.store.deleteItem(
            itemID: item.id,
            expectedRevision: item.revision,
            activeSessionID: sessionID,
            admissionGenerationCutoff: beforeDelete.generation
        )
        try await late.write(bytes).value
        _ = try await late.finish()
        #expect(try await fixture.store.loadSnapshot().items.isEmpty)

        let freshAdmission = try await fixture.store.itemAdmissionGeneration()
        let fresh = try await start(
            store: fixture.store,
            sessionID: sessionID,
            remoteFileID: UUID(),
            displayName: "fresh.bin",
            byteCount: bytes.count,
            admissionGeneration: freshAdmission
        )
        try await fresh.write(bytes).value
        _ = try await fresh.finish()
        let final = try await fixture.store.loadSnapshot()
        #expect(final.items.count == 1)
        #expect(final.items.first?.displayName.rawValue == "fresh.bin")
    }

    @Test
    func recoveredItemCanBeDeletedAfterItsUploadingSessionDisappears() async throws {
        let fixture = try await LANInboxStoreTestFixture.make()
        defer { fixture.destroy() }
        try await upload(
            Data("synthetic recovered source".utf8),
            store: fixture.store,
            sessionID: UUID(),
            remoteFileID: UUID(),
            displayName: "recovered.bin"
        )

        try fixture.kernel.close()
        let reopened = try SQLiteLibraryStore(rootURL: fixture.rootURL)
        defer { try? reopened.close() }
        let recoveredStore = try SQLiteLANInboxStore(store: reopened)
        let recovered = try await recoveredStore.initialize()
        let item = try #require(recovered.items.first)
        let deleted = try await recoveredStore.deleteItem(
            itemID: item.id,
            expectedRevision: item.revision,
            activeSessionID: nil
        )

        #expect(deleted.items.isEmpty)
        #expect(deleted.transportReceipts.isEmpty)
        #expect(deleted.blobs.isEmpty)
    }

    private func upload(
        _ bytes: Data,
        store: SQLiteLANInboxStore,
        sessionID: UUID,
        remoteFileID: UUID,
        displayName: String
    ) async throws {
        let admission = try await store.itemAdmissionGeneration()
        let sink = try await start(
            store: store,
            sessionID: sessionID,
            remoteFileID: remoteFileID,
            displayName: displayName,
            byteCount: bytes.count,
            admissionGeneration: admission
        )
        try await sink.write(bytes).value
        _ = try await sink.finish()
    }

    private func start(
        store: SQLiteLANInboxStore,
        sessionID: UUID,
        remoteFileID: UUID,
        displayName: String,
        byteCount: Int,
        admissionGeneration: UInt64
    ) async throws -> LANUploadSink {
        let metadata = try LANInboxTransportMetadata(
            displayName: LANInboxDisplayName(rawValue: displayName),
            declaredByteCount: byteCount
        )
        return try requireSink(try await store.startItemUpload(
            transport: LANInboxTransportIdentity(
                sessionID: sessionID,
                remoteFileID: remoteFileID
            ),
            metadata: metadata,
            attemptRevision: 0,
            admissionGeneration: admissionGeneration
        ))
    }

    private func requireSink(_ outcome: LANItemUploadStartOutcome) throws -> LANUploadSink {
        guard case let .sink(sink) = outcome else {
            throw LANInboxError.invalidState
        }
        return sink
    }

}
