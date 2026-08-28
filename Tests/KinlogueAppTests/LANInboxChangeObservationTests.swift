import Foundation
import Testing
@testable import KinlogueApp
@testable import KinlogueCore
@testable import KinloguePlatform

@Suite("LAN inbox change observation")
@MainActor
struct LANInboxChangeObservationTests {
    @Test
    func pollingRefreshesOnlyForChangesAndReceiverStop() async throws {
        let service = try LANInboxChangeObservationService()
        let changes = DurableInboxChanges()
        let model = LANInboxModel(
            service: service,
            onDurableStateChanged: { await changes.record() }
        )
        await model.start()
        await model.prepareReceiving()
        model.hasAcknowledgedPrivateNetwork = true
        await model.startReceiving()

        await model.pollReceiverOnce()
        #expect(await service.refreshCallCount == 0)

        await service.recordChange()
        await model.pollReceiverOnce()
        #expect(await service.refreshCallCount == 1)
        #expect(await changes.count == 1)

        await model.pollReceiverOnce()
        #expect(await service.refreshCallCount == 1)
        #expect(await changes.count == 1)

        await service.endReceivingExternally()
        await model.pollReceiverOnce()
        #expect(await service.refreshCallCount == 2)
        #expect(model.receiverPhase == .inactive)
    }
}

private actor DurableInboxChanges {
    private(set) var count = 0
    func record() { count += 1 }
}

private actor LANInboxChangeObservationService: LANInboxServicing {
    private let screen: LANInboxScreenSnapshot
    private var generation: UInt64 = 0
    private var receiving = false
    private(set) var refreshCallCount = 0

    init() throws {
        screen = LANInboxScreenSnapshot(
            snapshot: try LANInboxSnapshot(
                vaultID: UUID(),
                generation: 1,
                commitID: UUID(),
                lastWriterRuntimeGeneration: UUID()
            ),
            storage: try LANInboxStorageSummary(
                itemCount: 0,
                uniqueBlobCount: 0,
                sourceByteCount: 0,
                derivedArtifactCount: 0,
                derivedByteCount: 0,
                pendingUploadCount: 0,
                pendingByteCount: 0,
                metadataByteCount: 0
            )
        )
    }

    func recordChange() { generation &+= 1 }
    func endReceivingExternally() { receiving = false }
    func initialize() async throws -> LANInboxScreenSnapshot { screen }
    func refresh() async throws -> LANInboxScreenSnapshot {
        refreshCallCount += 1
        return screen
    }
    func resolveAddresses() async throws -> LANNetworkInterfaceResolution {
        .automatic(LANNetworkAddress(
            interfaceName: "en0",
            host: "192.0.2.1",
            networkPrefixLength: 24
        ))
    }
    func startReceiving(at address: LANNetworkAddress) async throws -> LANReceiverDetails {
        receiving = true
        return LANReceiverDetails(
            url: URL(string: "http://192.0.2.1")!,
            pairingCode: "123456",
            pairingExpiresInSeconds: 300
        )
    }
    func stopReceiving() async { receiving = false }
    func isReceiving() async -> Bool { receiving }
    func changeGeneration() async -> UInt64 { generation }
    func preprocess(itemID: LANInboxItem.ID) async throws {}
    func delete(itemID: LANInboxItem.ID, expectedRevision: UInt64) async throws {}
    func archive(
        itemIDs: [LANInboxItem.ID],
        memberID: FamilyMember.ID,
        canonicalReportDate: Date
    ) async throws -> LANReportArchiveResult {
        throw LANInboxError.invalidState
    }
    func loadPreview(itemID: LANInboxItem.ID) async throws -> LANInboxPreviewPayload {
        throw LANInboxError.invalidState
    }
}
