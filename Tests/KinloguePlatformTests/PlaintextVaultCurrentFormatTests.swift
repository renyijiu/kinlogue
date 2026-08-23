import Foundation
import Testing
@testable import KinlogueCore
@testable import KinloguePlatform

@Test
func catalogV2ManifestFailsClosedWithoutChangingVaultContents() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "kinlogue-current-catalog-only-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }

    let vault = try PlaintextVault(rootURL: root)
    _ = try await vault.initialize()
    try writeCatalogVersion(2, inManifestAt: root.appendingPathComponent("library.json"))
    let before = try plaintextVaultRegularFileSnapshot(root: root)

    #expect(await vault.inspect() == .unsupportedVersion)
    await #expect(throws: VaultError.unsupportedVersion(2)) {
        _ = try await vault.loadCatalog()
    }
    #expect(try plaintextVaultRegularFileSnapshot(root: root) == before)
}

@Test
func authorizedPendingDeletionCompletesBeforeCatalogV2IsRejected() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "kinlogue-current-catalog-deletion-\(UUID().uuidString)",
        isDirectory: true
    )
    let transaction = try PlaintextVaultDeletionTransaction(
        rootURL: root,
        failureInjector: { $0 == .afterDeletionReceipt }
    )
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: transaction.receiptURL)
        try? FileManager.default.removeItem(at: transaction.quarantineURL)
    }

    let vault = try PlaintextVault(rootURL: root)
    _ = try await vault.initialize()
    try writeCatalogVersion(2, inManifestAt: root.appendingPathComponent("library.json"))
    #expect(throws: VaultError.injectedFailure) {
        try transaction.begin()
    }
    #expect(FileManager.default.fileExists(atPath: transaction.receiptURL.path))
    #expect(FileManager.default.fileExists(atPath: root.path))

    let reopened = try PlaintextVault(rootURL: root)
    #expect(await reopened.inspect() == .absent)
    #expect(!FileManager.default.fileExists(atPath: root.path))
    #expect(!FileManager.default.fileExists(atPath: transaction.receiptURL.path))
}

private func writeCatalogVersion(_ version: Int, inManifestAt manifestURL: URL) throws {
    var manifest = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL))
            as? [String: Any]
    )
    var catalog = try #require(manifest["catalog"] as? [String: Any])
    catalog["formatVersion"] = version
    let catalogData = try JSONSerialization.data(withJSONObject: catalog, options: [.sortedKeys])
    manifest["catalog"] = catalog
    manifest["catalogSHA256"] = ContentDigest.sha256(catalogData).base64EncodedString()
    try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        .write(to: manifestURL, options: .atomic)
}
