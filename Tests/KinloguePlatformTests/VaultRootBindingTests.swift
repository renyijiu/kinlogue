import Darwin
import Foundation
import Testing
@testable import KinlogueCore
@testable import KinloguePlatform

@Test
func vaultRootBindingConstructionAndProbeNeverCreateAMissingRoot() throws {
    let fixture = try vaultRootBindingFixture()
    defer { try? FileManager.default.removeItem(at: fixture.parent) }

    let binding = try VaultRootBinding(rootURL: fixture.root)
    #expect(!FileManager.default.fileExists(atPath: fixture.root.path))
    #expect(throws: VaultError.vaultMissing) {
        _ = try binding.probe()
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.root.path))
}

@Test
func vaultRootBindingProbesAReadyVaultAndReprobesForMatches() async throws {
    let fixture = try vaultRootBindingFixture()
    defer { try? FileManager.default.removeItem(at: fixture.parent) }
    let vault = try PlaintextVault(rootURL: fixture.root)
    let catalog = try await vault.initialize()

    let binding = try VaultRootBinding(rootURL: fixture.root)
    let generation = try binding.probe()

    #expect(generation.parentDevice > 0)
    #expect(generation.parentInode > 0)
    #expect(generation.rootDevice > 0)
    #expect(generation.rootInode > 0)
    #expect(generation.vaultID == catalog.vaultID)
    #expect(binding.matches(generation))
    #expect(VaultRootBinding.matches(generation, rootURL: fixture.root))
}

@Test
func vaultRootBindingRejectsUnsafeParentRootAndManifestModes() async throws {
    let fixture = try vaultRootBindingFixture()
    defer { try? FileManager.default.removeItem(at: fixture.parent) }
    let vault = try PlaintextVault(rootURL: fixture.root)
    _ = try await vault.initialize()
    let binding = try VaultRootBinding(rootURL: fixture.root)
    let manifestURL = fixture.root.appendingPathComponent("library.json")

    let parentMode = try permissions(at: fixture.parent)
    let rootMode = try permissions(at: fixture.root)
    let manifestMode = try permissions(at: manifestURL)
    defer {
        try? setPermissions(parentMode, at: fixture.parent)
        try? setPermissions(rootMode, at: fixture.root)
        try? setPermissions(manifestMode, at: manifestURL)
    }

    try setPermissions(parentMode | mode_t(0o020), at: fixture.parent)
    #expect(throws: VaultError.invalidPath) {
        _ = try binding.probe()
    }
    try setPermissions(parentMode, at: fixture.parent)

    try setPermissions(mode_t(0o750), at: fixture.root)
    #expect(throws: VaultError.invalidPath) {
        _ = try binding.probe()
    }
    try setPermissions(rootMode, at: fixture.root)

    for unsafeMode in [mode_t(0o640), mode_t(0o400)] {
        try setPermissions(unsafeMode, at: manifestURL)
        #expect(throws: VaultError.invalidPath) {
            _ = try binding.probe()
        }
    }
    try setPermissions(manifestMode, at: manifestURL)
    _ = try binding.probe()
}

@Test
func rootBindingsAndLayoutsRetainTheResolvedPhysicalRootAfterAliasRetarget() async throws {
    let container = FileManager.default.temporaryDirectory.appendingPathComponent(
        "kinlogue-root-alias-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: container) }
    let physicalA = container.appendingPathComponent("physical-a", isDirectory: true)
    let physicalB = container.appendingPathComponent("physical-b", isDirectory: true)
    let holderA = physicalA.appendingPathComponent("holder", isDirectory: true)
    let holderB = physicalB.appendingPathComponent("holder", isDirectory: true)
    let alias = container.appendingPathComponent("alias", isDirectory: true)
    try FileManager.default.createDirectory(
        at: holderA,
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: holderB,
        withIntermediateDirectories: true
    )
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: physicalA)

    let aliasedRoot = alias
        .appendingPathComponent("holder", isDirectory: true)
        .appendingPathComponent("Vault", isDirectory: true)
    let physicalARoot = holderA.appendingPathComponent("Vault", isDirectory: true)
    let physicalBRoot = holderB.appendingPathComponent("Vault", isDirectory: true)
    let catalogA = try await PlaintextVault(rootURL: aliasedRoot).initialize()
    let catalogB = try await PlaintextVault(rootURL: physicalBRoot).initialize()

    let layout = try LANInboxLayout(rootURL: aliasedRoot)
    let binding = try VaultRootBinding(rootURL: aliasedRoot)
    let generationA = try binding.probe()
    let physicalPathA = try physicalPath(of: physicalARoot)
    #expect(layout.rootURL.path == physicalPathA)
    #expect(generationA.vaultID == catalogA.vaultID)

    try FileManager.default.removeItem(at: alias)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: physicalB)

    #expect(try binding.probe() == generationA)
    #expect(layout.rootURL.path == physicalPathA)
    #expect(try VaultRootBinding.probe(rootURL: aliasedRoot).vaultID == catalogB.vaultID)
}

@Test
func reconciliationRejectsWrongAndReleasedMutationLeases() async throws {
    let first = try vaultRootBindingFixture()
    let second = try vaultRootBindingFixture()
    defer {
        try? FileManager.default.removeItem(at: first.parent)
        try? FileManager.default.removeItem(at: second.parent)
    }
    let firstCatalog = try await PlaintextVault(rootURL: first.root).initialize()
    _ = try await PlaintextVault(rootURL: second.root).initialize()
    let binding = try VaultRootBinding(rootURL: first.root)

    let wrongLease = try await VaultMutationCoordinator.shared(for: second.root).acquire()
    #expect(throws: VaultError.mutationConflict) {
        _ = try binding.probe(reconcilingTransactionsWith: wrongLease)
    }
    wrongLease.release()

    let correctLease = try await VaultMutationCoordinator.shared(for: first.root).acquire()
    #expect(
        try binding.probe(reconcilingTransactionsWith: correctLease).vaultID
            == firstCatalog.vaultID
    )
    correctLease.release()
    #expect(throws: VaultError.mutationConflict) {
        _ = try binding.probe(reconcilingTransactionsWith: correctLease)
    }
}

@Test
func vaultRootBindingRejectsSymlinkAndNonDirectoryRoots() throws {
    let symlinkFixture = try vaultRootBindingFixture()
    defer { try? FileManager.default.removeItem(at: symlinkFixture.parent) }
    let target = symlinkFixture.parent.appendingPathComponent("target", isDirectory: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(
        at: symlinkFixture.root,
        withDestinationURL: target
    )

    #expect(throws: VaultError.invalidPath) {
        _ = try VaultRootBinding.probe(rootURL: symlinkFixture.root)
    }

    let fileFixture = try vaultRootBindingFixture()
    defer { try? FileManager.default.removeItem(at: fileFixture.parent) }
    try Data("synthetic-non-directory".utf8).write(to: fileFixture.root)

    #expect(throws: VaultError.invalidPath) {
        _ = try VaultRootBinding.probe(rootURL: fileFixture.root)
    }
}

@Test
func vaultRootBindingRejectsASymlinkManifest() async throws {
    let fixture = try vaultRootBindingFixture()
    defer { try? FileManager.default.removeItem(at: fixture.parent) }
    let vault = try PlaintextVault(rootURL: fixture.root)
    _ = try await vault.initialize()

    let manifestURL = fixture.root.appendingPathComponent("library.json")
    let displacedManifest = fixture.parent.appendingPathComponent("displaced-library.json")
    try FileManager.default.moveItem(at: manifestURL, to: displacedManifest)
    try FileManager.default.createSymbolicLink(
        at: manifestURL,
        withDestinationURL: displacedManifest
    )

    #expect(throws: VaultError.invalidPath) {
        _ = try VaultRootBinding.probe(rootURL: fixture.root)
    }
}

@Test
func vaultRootBindingRejectsCatalogDigestDamage() async throws {
    let fixture = try vaultRootBindingFixture()
    defer { try? FileManager.default.removeItem(at: fixture.parent) }
    let vault = try PlaintextVault(rootURL: fixture.root)
    _ = try await vault.initialize()

    let manifestURL = fixture.root.appendingPathComponent("library.json")
    var json = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL))
            as? [String: Any]
    )
    json["catalogSHA256"] = Data(repeating: 0, count: 32).base64EncodedString()
    let damaged = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    try AtomicFileStore(rootURL: fixture.root).replaceAtomically(
        damaged,
        relativePath: "library.json"
    )

    #expect(throws: VaultError.invalidDigest) {
        _ = try VaultRootBinding.probe(rootURL: fixture.root)
    }
}

@Test
func staleVaultRootBindingDoesNotRecreateADestroyedRoot() async throws {
    let fixture = try vaultRootBindingFixture()
    defer { try? FileManager.default.removeItem(at: fixture.parent) }
    let vault = try PlaintextVault(rootURL: fixture.root)
    _ = try await vault.initialize()
    let binding = try VaultRootBinding(rootURL: fixture.root)
    let generation = try binding.probe()

    try await vault.destroy()

    #expect(!binding.matches(generation))
    #expect(throws: VaultError.vaultMissing) {
        _ = try binding.probe()
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.root.path))
}

@Test
func reinitializedVaultAtTheSamePathHasADifferentRootGeneration() async throws {
    let fixture = try vaultRootBindingFixture()
    defer { try? FileManager.default.removeItem(at: fixture.parent) }
    let firstVault = try PlaintextVault(rootURL: fixture.root)
    _ = try await firstVault.initialize()
    let binding = try VaultRootBinding(rootURL: fixture.root)
    let first = try binding.probe()

    try await firstVault.destroy()
    let replacementVault = try PlaintextVault(rootURL: fixture.root)
    _ = try await replacementVault.initialize()
    let replacement = try binding.probe()

    #expect(replacement.vaultID != first.vaultID)
    #expect(replacement != first)
    #expect(!VaultRootBinding.matches(first, rootURL: fixture.root))
    #expect(VaultRootBinding.matches(replacement, rootURL: fixture.root))
}

@Test
func vaultRootBindingExplicitlyReconcilesAnExistingInitializationReceipt() async throws {
    let fixture = try vaultRootBindingFixture()
    let transaction = try PlaintextVaultInitializationTransaction(rootURL: fixture.root)
    defer {
        try? FileManager.default.removeItem(at: fixture.parent)
        try? FileManager.default.removeItem(at: transaction.receiptURL)
    }
    let interrupted = try PlaintextVault(
        rootURL: fixture.root,
        transactionFailureInjector: { $0 == .afterInitializationManifestCommit }
    )
    let catalog: VaultCatalog
    do {
        _ = try await interrupted.initialize()
        Issue.record("Expected the synthetic initialization interruption")
        return
    } catch VaultError.injectedFailure {
        let manifest = try CanonicalVaultJSON.decode(
            PlaintextVaultManifest.self,
            from: Data(contentsOf: fixture.root.appendingPathComponent("library.json"))
        )
        catalog = manifest.catalog
    }
    #expect(FileManager.default.fileExists(atPath: transaction.receiptURL.path))

    let binding = try VaultRootBinding(rootURL: fixture.root)
    let ordinaryGeneration = try binding.probe()
    #expect(ordinaryGeneration.vaultID == catalog.vaultID)
    #expect(FileManager.default.fileExists(atPath: transaction.receiptURL.path))

    let coordinator = VaultMutationCoordinator.shared(for: fixture.root)
    let lease = try await coordinator.acquire()
    defer { lease.release() }
    let generation = try binding.probe(
        reconcilingTransactionsWith: lease
    )

    #expect(generation.vaultID == catalog.vaultID)
    #expect(!FileManager.default.fileExists(atPath: transaction.receiptURL.path))
}

@Test
func vaultRootBindingDeletionReconciliationNeverRecreatesTheRoot() async throws {
    let fixture = try vaultRootBindingFixture()
    let transaction = try PlaintextVaultDeletionTransaction(rootURL: fixture.root)
    defer {
        try? FileManager.default.removeItem(at: fixture.parent)
        try? FileManager.default.removeItem(at: transaction.receiptURL)
        try? FileManager.default.removeItem(at: transaction.quarantineURL)
    }
    let interrupted = try PlaintextVault(
        rootURL: fixture.root,
        transactionFailureInjector: { $0 == .afterDeletionRename }
    )
    _ = try await interrupted.initialize()
    let binding = try VaultRootBinding(rootURL: fixture.root)
    await #expect(throws: VaultError.injectedFailure) {
        try await interrupted.destroy()
    }

    #expect(throws: VaultError.vaultMissing) {
        _ = try binding.probe()
    }
    #expect(FileManager.default.fileExists(atPath: transaction.receiptURL.path))
    #expect(FileManager.default.fileExists(atPath: transaction.quarantineURL.path))

    let coordinator = VaultMutationCoordinator.shared(for: fixture.root)
    let lease = try await coordinator.acquire()
    defer { lease.release() }
    #expect(throws: VaultError.vaultMissing) {
        _ = try binding.probe(
            reconcilingTransactionsWith: lease
        )
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.root.path))
    #expect(!FileManager.default.fileExists(atPath: transaction.receiptURL.path))
    #expect(!FileManager.default.fileExists(atPath: transaction.quarantineURL.path))
}

private func vaultRootBindingFixture() throws -> (parent: URL, root: URL) {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
        "kinlogue-root-binding-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    return (
        parent,
        parent.appendingPathComponent("Vault", isDirectory: true)
    )
}

private func permissions(at url: URL) throws -> mode_t {
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0 else {
        throw VaultError.ioFailure(errno)
    }
    return metadata.st_mode & mode_t(0o7777)
}

private func setPermissions(_ mode: mode_t, at url: URL) throws {
    guard chmod(url.path, mode) == 0 else {
        throw VaultError.ioFailure(errno)
    }
}

private func physicalPath(of url: URL) throws -> String {
    errno = 0
    let pointer = url.path.withCString { path in realpath(path, nil) }
    guard let pointer else { throw VaultError.ioFailure(errno) }
    defer { free(pointer) }
    return URL(
        fileURLWithPath: String(cString: pointer),
        isDirectory: true
    ).standardizedFileURL.path
}
