import Foundation
import Testing
@testable import KinlogueApp
@testable import KinlogueCore
@testable import KinloguePlatform

@Suite("LAN inbox observation optimization measurement", .serialized)
@MainActor
struct LANInboxObservationOptimizationMeasurementTests {
    @Test
    func measuresUnchangedFullRefreshesAcrossFiveLivenessTicks() async throws {
        let service = try LANObservationMeasurementService()
        let model = LANInboxModel(service: service)
        await model.start()
        await model.prepareReceiving()
        model.hasAcknowledgedPrivateNetwork = true
        await model.startReceiving()
        #expect(model.receiverPhase == .active)

        for _ in 0..<5 { await model.pollReceiverOnce() }

        let refreshes = await service.refreshCallCount
        print("LAN_OBSERVATION_OPTIMIZATION_METRICS idle_full_refreshes=\(refreshes) partial_refreshes=0")
        #expect(refreshes == 0)
        #expect(model.receiverPhase == .active)
    }
}

private actor LANObservationMeasurementService: LANInboxServicing {
    private let screen: LANInboxScreenSnapshot
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
