import Darwin
import Foundation
import Testing
@testable import KinlogueCore
@testable import KinloguePlatform

@Test
func canonicalVaultAliasesShareOneMutationCoordinator() throws {
    let parent = FileManager.default.temporaryDirectory
        .appendingPathComponent("kinlogue-mutation-alias-\(UUID().uuidString)", isDirectory: true)
    let alias = parent.appendingPathComponent("alias", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: parent) }
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
        at: alias,
        withDestinationURL: parent
    )

    let canonicalRoot = parent.appendingPathComponent("vault", isDirectory: true)
    let aliasedRoot = alias.appendingPathComponent("vault", isDirectory: true)

    #expect(
        VaultMutationCoordinator.shared(for: canonicalRoot)
            === VaultMutationCoordinator.shared(for: aliasedRoot)
    )
}

@Test(.enabled(
    if: mutationTestVolumeIsCaseInsensitive,
    "Requires a case-insensitive filesystem"
))
func differentlyCasedVaultAliasesShareStableAndLegacyLockIdentity() throws {
    let parent = FileManager.default.temporaryDirectory
        .resolvingSymlinksInPath()
        .appendingPathComponent(
            "kinlogue-mutation-case-alias-\(UUID().uuidString)",
            isDirectory: true
        )
    defer { try? FileManager.default.removeItem(at: parent) }
    try FileManager.default.createDirectory(
        at: parent,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )

    let canonicalRoot = parent.appendingPathComponent("Kinlogue", isDirectory: true)
    let casedAlias = parent.appendingPathComponent("kinlogue", isDirectory: true)
    try FileManager.default.createDirectory(
        at: canonicalRoot,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )

    let canonicalCoordinator = VaultMutationCoordinator.shared(for: canonicalRoot)
    let aliasCoordinator = VaultMutationCoordinator.shared(for: casedAlias)
    #expect(canonicalCoordinator === aliasCoordinator)

    let legacyCanonicalName = VaultMutationLockNaming.filename(
        forCanonicalRootPath: canonicalRoot.resolvingSymlinksInPath()
            .standardizedFileURL.path.precomposedStringWithCanonicalMapping
    )
    #expect(canonicalCoordinator.processLockURLsForTesting.contains(where: {
        $0.lastPathComponent == legacyCanonicalName
    }))

    let missingCanonical = parent.appendingPathComponent("SourceVault", isDirectory: true)
    let missingAlias = parent.appendingPathComponent("sourcevault", isDirectory: true)
    let missingCanonicalCoordinator = VaultMutationCoordinator.shared(for: missingCanonical)
    let missingAliasCoordinator = VaultMutationCoordinator.shared(for: missingAlias)
    #expect(missingCanonicalCoordinator === missingAliasCoordinator)
}

@Test
func legacyCorrectlyCasedProcessLockStillBlocksUpgradedCoordinator() async throws {
    let parent = FileManager.default.temporaryDirectory
        .resolvingSymlinksInPath()
        .appendingPathComponent(
            "kinlogue-mutation-legacy-lock-\(UUID().uuidString)",
            isDirectory: true
        )
    defer { try? FileManager.default.removeItem(at: parent) }
    try FileManager.default.createDirectory(
        at: parent,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    let root = parent.appendingPathComponent("SourceVault", isDirectory: true)
    let legacyKey = root.standardizedFileURL.path
        .precomposedStringWithCanonicalMapping
    let legacyLockURL = parent.appendingPathComponent(
        VaultMutationLockNaming.filename(forCanonicalRootPath: legacyKey)
    )
    let coordinator = VaultMutationCoordinator.shared(for: root)
    #expect(coordinator.processLockURLsForTesting.contains(legacyLockURL))
    let holder = ExternalVaultLockHolder(
        lockURL: legacyLockURL,
        workingDirectory: parent
    )
    defer { holder.terminate() }
    try await holder.startAndWaitUntilLocked()

    let waiting = Task { try await coordinator.acquire() }
    defer { waiting.cancel() }
    try await waitUntil { coordinator.processLockWaiterCountForTesting == 1 }
    try await Task.sleep(for: .milliseconds(50))
    #expect(coordinator.processLockWaiterCountForTesting == 1)

    try await holder.releaseAndWait()
    let lease = try await waiting.value
    lease.release()
}

@Test
func cancelledMutationWaiterIsRemovedBeforeItCanEnterTheLease() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("kinlogue-mutation-cancel-\(UUID().uuidString)")
    let coordinator = VaultMutationCoordinator.shared(for: root)
    let firstLease = try await coordinator.acquire()
    defer { firstLease.release() }
    let probe = VaultMutationEntryProbe()

    let cancelled = Task {
        let lease = try await coordinator.acquire()
        defer { lease.release() }
        probe.markEntered()
    }
    for _ in 0..<10_000 where coordinator.waitingCountForTesting == 0 {
        await Task.yield()
    }
    #expect(coordinator.waitingCountForTesting == 1)

    cancelled.cancel()
    for _ in 0..<10_000 where coordinator.waitingCountForTesting != 0 {
        await Task.yield()
    }

    await #expect(throws: CancellationError.self) {
        try await cancelled.value
    }
    #expect(coordinator.waitingCountForTesting == 0)
    #expect(!probe.entered)
}

@Test
func externalWriterLeasePreventsOrphanSweepUntilItsPublicationWindowCloses() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("kinlogue-mutation-process-race-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let initialVault = try PlaintextVault(rootURL: root)
    let initial = try await initialVault.initialize()
    let coordinator = VaultMutationCoordinator.shared(for: root)
    let holder = ExternalVaultLockHolder(
        lockURL: coordinator.processLockURLForTesting,
        workingDirectory: root.deletingLastPathComponent()
    )
    defer { holder.terminate() }
    try await holder.startAndWaitUntilLocked()

    // This canonical object path models the external writer's durable object
    // after its object phase and before its catalog head is published.
    let orphan = VaultObjectReference(id: UUID(), kind: .ocr)
    let path = try PlaintextVaultLayout(rootURL: root).objectPath(orphan)
    let files = try AtomicFileStore(rootURL: root)
    try files.writeImmutable(Data(repeating: 0x5A, count: 24), relativePath: path)
    let restarted = try PlaintextVault(rootURL: root)
    let sweep = Task { try await restarted.loadCatalog() }
    defer { sweep.cancel() }

    try await waitUntil { coordinator.processLockWaiterCountForTesting == 1 }
    try await Task.sleep(for: .milliseconds(50))
    #expect(coordinator.processLockWaiterCountForTesting == 1)
    #expect(files.exists(relativePath: path))

    try await holder.releaseAndWait()
    #expect(try await sweep.value == initial)
    #expect(!files.exists(relativePath: path))
}

@Test
func crashedExternalProcessCannotPermanentlyDeadlockTheVaultLease() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("kinlogue-mutation-process-crash-\(UUID().uuidString)")
    let coordinator = VaultMutationCoordinator.shared(for: root)
    let holder = ExternalVaultLockHolder(
        lockURL: coordinator.processLockURLForTesting,
        workingDirectory: root.deletingLastPathComponent()
    )
    defer { holder.terminate() }
    try await holder.startAndWaitUntilLocked()

    let waiting = Task { try await coordinator.acquire() }
    defer { waiting.cancel() }
    try await waitUntil { coordinator.processLockWaiterCountForTesting == 1 }
    try await holder.terminateAndWait()

    let lease = try await waiting.value
    lease.release()
    let retry = try await coordinator.acquire()
    retry.release()
}

@Test
func processLockPathSubstitutionFailsClosed() async throws {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("kinlogue-mutation-process-path-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: base) }
    let coordinator = VaultMutationCoordinator.shared(
        for: base.appendingPathComponent("vault")
    )
    let outside = base.appendingPathComponent("outside")
    _ = FileManager.default.createFile(atPath: outside.path, contents: Data())
    try FileManager.default.createSymbolicLink(
        at: coordinator.processLockURLForTesting,
        withDestinationURL: outside
    )

    await #expect(throws: VaultError.invalidPath) {
        _ = try await coordinator.acquire()
    }
}

private final class VaultMutationEntryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var didEnter = false

    var entered: Bool {
        lock.withLock { didEnter }
    }

    func markEntered() {
        lock.withLock { didEnter = true }
    }
}

private enum VaultMutationProcessTestError: Error {
    case childFailed
    case timedOut
}

private final class ExternalVaultLockHolder: @unchecked Sendable {
    private let process = Process()
    private let readyURL: URL
    private let releaseURL: URL
    private var started = false

    init(lockURL: URL, workingDirectory: URL) {
        readyURL = workingDirectory.appendingPathComponent(
            ".kinlogue-lock-ready-\(UUID().uuidString)"
        )
        releaseURL = workingDirectory.appendingPathComponent(
            ".kinlogue-lock-release-\(UUID().uuidString)"
        )
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
        process.arguments = [
            "-k",
            lockURL.path,
            "/bin/zsh",
            "-c",
            "set -eu; : > \"$KINLOGUE_LOCK_READY\"; "
                + "while [[ ! -e \"$KINLOGUE_LOCK_RELEASE\" ]]; do /bin/sleep 0.01; done",
        ]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "KINLOGUE_LOCK_READY": readyURL.path,
            "KINLOGUE_LOCK_RELEASE": releaseURL.path,
        ]) { _, replacement in replacement }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
    }

    func startAndWaitUntilLocked() async throws {
        try process.run()
        started = true
        try await waitUntil {
            FileManager.default.fileExists(atPath: self.readyURL.path)
                || !self.process.isRunning
        }
        guard process.isRunning,
              FileManager.default.fileExists(atPath: readyURL.path) else {
            throw VaultMutationProcessTestError.childFailed
        }
    }

    func releaseAndWait() async throws {
        _ = FileManager.default.createFile(atPath: releaseURL.path, contents: Data())
        try await waitUntil { !self.process.isRunning }
        guard process.terminationStatus == 0 else {
            throw VaultMutationProcessTestError.childFailed
        }
        cleanupSignals()
    }

    func terminateAndWait() async throws {
        process.terminate()
        try await waitUntil { !self.process.isRunning }
        cleanupSignals()
    }

    func terminate() {
        if started, process.isRunning { process.terminate() }
        cleanupSignals()
    }

    private func cleanupSignals() {
        try? FileManager.default.removeItem(at: readyURL)
        try? FileManager.default.removeItem(at: releaseURL)
    }
}

private func waitUntil(
    _ condition: @escaping @Sendable () -> Bool
) async throws {
    for _ in 0..<500 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw VaultMutationProcessTestError.timedOut
}

private let mutationTestVolumeIsCaseInsensitive: Bool = {
    let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
    let descriptor = Darwin.open(
        directory.path,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard descriptor >= 0 else { return false }
    defer { Darwin.close(descriptor) }
    return fpathconf(descriptor, _PC_CASE_SENSITIVE) == 0
}()
