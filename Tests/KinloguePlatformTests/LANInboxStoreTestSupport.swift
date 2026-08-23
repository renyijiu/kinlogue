import Foundation
@testable import KinloguePlatform

struct LANInboxStoreTestFixture {
    let parentURL: URL
    let rootURL: URL
    let vaultID: UUID
    let store: PlaintextLANInboxStore

    static func make(
        failureInjector: PlaintextLANInboxStore.FailureInjector? = nil,
        partialActivityProbeFailureInjector:
            PlaintextLANInboxStore.PartialActivityProbeFailureInjector? = nil,
        screenProjectionWillRebuild:
            PlaintextLANInboxStore.ScreenProjectionWillRebuild? = nil
    ) async throws -> Self {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kinlogue-lan-item-store-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: false
        )
        let root = parent.appendingPathComponent("Vault", isDirectory: true)
        let catalog = try await PlaintextVault(rootURL: root).initialize()
        let store = try PlaintextLANInboxStore(
            rootURL: root,
            failureInjector: failureInjector,
            partialActivityProbeFailureInjector:
                partialActivityProbeFailureInjector,
            screenProjectionWillRebuild: screenProjectionWillRebuild
        )
        _ = try await store.initialize()
        return Self(
            parentURL: parent,
            rootURL: root,
            vaultID: catalog.vaultID,
            store: store
        )
    }

    func destroy() {
        try? FileManager.default.removeItem(at: parentURL)
    }
}
