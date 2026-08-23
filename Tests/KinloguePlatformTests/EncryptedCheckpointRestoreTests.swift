import CryptoKit
import Darwin
import Foundation
import KinlogueCore
import Testing
@_spi(Testing) @testable import KinloguePlatform

@Suite("Encrypted checkpoint restore", .serialized)
struct EncryptedCheckpointRestoreTests {
    @Test
    func cleanProfileRestoresWithoutBookmarkOrDeviceIdentityAndLeavesSourceUnchanged() async throws {
        try await withRestoreFixture { fixture in
            let before = try Data(contentsOf: fixture.checkpointURL)
            let destinationParent = fixture.base.appendingPathComponent("destination", isDirectory: true)
            try makePrivateDirectory(destinationParent)
            let activeRoot = destinationParent.appendingPathComponent("Vault", isDirectory: true)
            let verifier = try BackupRestoreVerifier(
                stableParentURL: destinationParent,
                activeRootURL: activeRoot
            )

            let prepared = try await verifier.prepare(
                checkpointURL: fixture.checkpointURL,
                recoveryCode: fixture.recoveryCode
            )
            #expect(!FileManager.default.fileExists(atPath: activeRoot.path))
            #expect(prepared.summary.memberCount == 0)
            #expect(prepared.summary.recordCount == 0)
            #expect(prepared.summary.inboxItemCount == 0)
            #expect(prepared.summary.revisionPair == fixture.revisionPair)

            let result = try await BackupRestoreTransaction(activeRootURL: activeRoot)
                .activate(prepared: prepared, resetWriter: {})
            #expect(result.requiresApplicationRestart)
            #expect(try Data(contentsOf: fixture.checkpointURL) == before)
            #expect(try await PlaintextVault(rootURL: activeRoot).loadCatalog().vaultID
                == fixture.sourceVaultID)
            #expect(try await PlaintextLANInboxStore(rootURL: activeRoot).loadSnapshot().vaultID
                == fixture.sourceVaultID)
        }
    }

    @Test
    func existingLibraryIsReplacedAsOneRootAndOldRootSurvivesUntilRestartReconcile() async throws {
        try await withRestoreFixture { fixture in
            let destinationParent = fixture.base.appendingPathComponent("replacement", isDirectory: true)
            try makePrivateDirectory(destinationParent)
            let activeRoot = destinationParent.appendingPathComponent("Vault", isDirectory: true)
            let oldVault = try PlaintextVault(rootURL: activeRoot)
            let oldCatalog = try await oldVault.initialize()
            _ = try await PlaintextLANInboxStore(rootURL: activeRoot).initialize()

            let verifier = try BackupRestoreVerifier(
                stableParentURL: destinationParent,
                activeRootURL: activeRoot
            )
            let prepared = try await verifier.prepare(
                checkpointURL: fixture.checkpointURL,
                recoveryCode: fixture.recoveryCode
            )
            #expect(try await oldVault.loadCatalog().vaultID == oldCatalog.vaultID)

            let transaction = try BackupRestoreTransaction(activeRootURL: activeRoot)
            _ = try await transaction.activate(prepared: prepared, resetWriter: {})
            #expect(try await PlaintextVault(rootURL: activeRoot).loadCatalog().vaultID
                == fixture.sourceVaultID)
            #expect(try transaction.rollbackIdentityForTesting() != nil)

            #expect(try await transaction.reconcile() == .committed)
            #expect(try transaction.rollbackIdentityForTesting() == nil)
        }
    }

    @Test
    func wrongCodeCapacityFailureAndMissingGraphLeaveCurrentAndCheckpointBytesUnchanged() async throws {
        try await withRestoreFixture(includeVaultObjectInContainer: false) { fixture in
            let destinationParent = fixture.base.appendingPathComponent("unchanged", isDirectory: true)
            try makePrivateDirectory(destinationParent)
            let activeRoot = destinationParent.appendingPathComponent("Vault", isDirectory: true)
            let activeVault = try PlaintextVault(rootURL: activeRoot)
            let activeCatalog = try await activeVault.initialize()
            _ = try await PlaintextLANInboxStore(rootURL: activeRoot).initialize()
            let activeManifestBefore = try Data(contentsOf: activeRoot.appendingPathComponent("library.json"))
            let checkpointBefore = try Data(contentsOf: fixture.checkpointURL)
            let verifier = try BackupRestoreVerifier(
                stableParentURL: destinationParent,
                activeRootURL: activeRoot
            )

            await #expect(throws: BackupRestoreError.authenticationFailed) {
                _ = try await verifier.prepare(
                    checkpointURL: fixture.checkpointURL,
                    recoveryCode: try BackupRecoveryCode.encode(seed: Data(repeating: 0xEE, count: 32))
                )
            }
            await #expect(throws: BackupRestoreError.graphInvalid) {
                _ = try await verifier.prepare(
                    checkpointURL: fixture.checkpointURL,
                    recoveryCode: fixture.recoveryCode
                )
            }

            let capacityVerifier = try BackupRestoreVerifier(
                stableParentURL: destinationParent,
                activeRootURL: activeRoot,
                availableCapacity: { 0 }
            )
            await #expect(throws: BackupRestoreError.capacityInsufficient) {
                _ = try await capacityVerifier.prepare(
                    checkpointURL: fixture.validCheckpointURL,
                    recoveryCode: fixture.recoveryCode
                )
            }

            let symlink = fixture.base.appendingPathComponent("alias.kinloguebackup")
            try FileManager.default.createSymbolicLink(
                at: symlink,
                withDestinationURL: fixture.validCheckpointURL
            )
            await #expect(throws: BackupRestoreError.invalidSource) {
                _ = try await verifier.prepare(
                    checkpointURL: symlink,
                    recoveryCode: fixture.recoveryCode
                )
            }
            let hardlink = fixture.base.appendingPathComponent("hardlink.kinloguebackup")
            #expect(link(fixture.validCheckpointURL.path, hardlink.path) == 0)
            await #expect(throws: BackupRestoreError.invalidSource) {
                _ = try await verifier.prepare(
                    checkpointURL: hardlink,
                    recoveryCode: fixture.recoveryCode
                )
            }
            #expect(unlink(hardlink.path) == 0)

            let tampered = fixture.base.appendingPathComponent("tampered.kinloguebackup")
            try FileManager.default.copyItem(at: fixture.validCheckpointURL, to: tampered)
            let tamperedDescriptor = Darwin.open(tampered.path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
            #expect(tamperedDescriptor >= 0)
            var byte: UInt8 = 0xFF
            #expect(pwrite(tamperedDescriptor, &byte, 1, 64) == 1)
            Darwin.close(tamperedDescriptor)
            await #expect(throws: BackupRestoreError.self) {
                _ = try await verifier.prepare(
                    checkpointURL: tampered,
                    recoveryCode: fixture.recoveryCode
                )
            }
            #expect(try await activeVault.loadCatalog().vaultID == activeCatalog.vaultID)
            #expect(try Data(contentsOf: activeRoot.appendingPathComponent("library.json"))
                == activeManifestBefore)
            #expect(try Data(contentsOf: fixture.checkpointURL) == checkpointBefore)
            #expect(try restoreArtifacts(in: destinationParent).isEmpty)
        }
    }

    @Test
    func restoresDerivedArtifactsRejectsLeafTamperingAndReconcilesPreprocessing() async throws {
        try await withRestoreFixture(includeLANRecoveryEvidence: true) { fixture in
            let evidence = try #require(fixture.lanEvidence)
            let destinationParent = fixture.base.appendingPathComponent(
                "lan-derived-destination",
                isDirectory: true
            )
            try makePrivateDirectory(destinationParent)
            let activeRoot = destinationParent.appendingPathComponent("Vault", isDirectory: true)
            let verifier = try BackupRestoreVerifier(
                stableParentURL: destinationParent,
                activeRootURL: activeRoot
            )
            let prepared = try await verifier.prepare(
                checkpointURL: fixture.checkpointURL,
                recoveryCode: fixture.recoveryCode
            )

            #expect(prepared.summary.inboxItemCount == 2)
            let stagingLayout = try LANInboxLayout(rootURL: prepared.stagingURL)
            #expect(try Data(contentsOf: stagingLayout.derivedURL(evidence.artifactID))
                == evidence.artifactBytes)
            #expect(!FileManager.default.fileExists(
                atPath: stagingLayout.partialURL(evidence.preprocessingAttemptID).path
            ))
            _ = try await PlaintextLANInboxStore(rootURL: prepared.stagingURL)
                .strictRestoreValidation()

            let transaction = try BackupRestoreTransaction(activeRootURL: activeRoot)
            _ = try await transaction.activate(prepared: prepared, resetWriter: {})
            #expect(try await transaction.reconcile() == .committed)
            let activatedStore = try PlaintextLANInboxStore(rootURL: activeRoot)
            _ = try await activatedStore.strictRestoreValidation()
            let initialized = try await activatedStore.initialize()
            let restoredReviewable = try #require(
                initialized.item(id: evidence.reviewableItemID)
            )
            #expect(restoredReviewable.isReviewable)
            #expect(restoredReviewable.derivedArtifact?.id == evidence.artifactID)
            let restoredInterrupted = try #require(
                initialized.item(id: evidence.preprocessingItemID)
            )
            guard case .failed(_, .storageFailure) = restoredInterrupted.state else {
                Issue.record("Expected startup to make interrupted preprocessing retryable")
                return
            }
            #expect(restoredInterrupted.attemptID == nil)
            #expect(!FileManager.default.fileExists(
                atPath: try LANInboxLayout(rootURL: activeRoot)
                    .partialURL(evidence.preprocessingAttemptID).path
            ))

            let tamperParent = fixture.base.appendingPathComponent(
                "lan-derived-tamper",
                isDirectory: true
            )
            try makePrivateDirectory(tamperParent)
            let tamperRoot = tamperParent.appendingPathComponent("Vault", isDirectory: true)
            let tamperVerifier = try BackupRestoreVerifier(
                stableParentURL: tamperParent,
                activeRootURL: tamperRoot
            )
            let tamperPrepared = try await tamperVerifier.prepare(
                checkpointURL: fixture.checkpointURL,
                recoveryCode: fixture.recoveryCode
            )
            let tamperLayout = try LANInboxLayout(rootURL: tamperPrepared.stagingURL)
            let artifactURL = tamperLayout.derivedURL(evidence.artifactID)
            let descriptor = Darwin.open(
                artifactURL.path,
                O_WRONLY | O_NOFOLLOW | O_CLOEXEC
            )
            #expect(descriptor >= 0)
            var replacement: UInt8 = 0xFF
            #expect(pwrite(descriptor, &replacement, 1, 0) == 1)
            Darwin.close(descriptor)
            await #expect(throws: VaultError.integrityCheckFailed) {
                _ = try await PlaintextLANInboxStore(
                    rootURL: tamperPrepared.stagingURL
                ).strictRestoreValidation()
            }
            try tamperVerifier.cancel(tamperPrepared)
        }
    }

    @Test
    func crashAfterOldRootMoveReconcilesToCompleteOldRoot() async throws {
        try await withRestoreFixture { fixture in
            let destinationParent = fixture.base.appendingPathComponent("rollback", isDirectory: true)
            try makePrivateDirectory(destinationParent)
            let activeRoot = destinationParent.appendingPathComponent("Vault", isDirectory: true)
            let oldVault = try PlaintextVault(rootURL: activeRoot)
            let oldCatalog = try await oldVault.initialize()
            _ = try await PlaintextLANInboxStore(rootURL: activeRoot).initialize()
            let prepared = try await BackupRestoreVerifier(
                stableParentURL: destinationParent,
                activeRootURL: activeRoot
            ).prepare(
                checkpointURL: fixture.checkpointURL,
                recoveryCode: fixture.recoveryCode
            )
            let interrupted = try BackupRestoreTransaction(
                activeRootURL: activeRoot,
                failureInjector: { $0 == .afterOldRootMove }
            )
            await #expect(throws: BackupRestoreError.injectedFailure) {
                _ = try await interrupted.activate(prepared: prepared, resetWriter: {})
            }

            let restarted = try BackupRestoreTransaction(activeRootURL: activeRoot)
            #expect(try await restarted.reconcile() == .rolledBack)
            #expect(try await PlaintextVault(rootURL: activeRoot).loadCatalog().vaultID
                == oldCatalog.vaultID)
        }
    }

    @Test
    func corruptedPreparedStagingFailsActivationAndRestoresExactPriorRootOrAbsence() async throws {
        try await withRestoreFixture { fixture in
            for startsWithExistingRoot in [true, false] {
                let caseName = startsWithExistingRoot ? "existing" : "absent"
                let destinationParent = fixture.base.appendingPathComponent(
                    "post-prepare-corruption-\(caseName)",
                    isDirectory: true
                )
                try makePrivateDirectory(destinationParent)
                let activeRoot = destinationParent.appendingPathComponent(
                    "Vault",
                    isDirectory: true
                )
                let oldRootSnapshot: [String: RestoreTreeEntry]?
                if startsWithExistingRoot {
                    let oldVault = try PlaintextVault(rootURL: activeRoot)
                    _ = try await oldVault.initialize()
                    _ = try await PlaintextLANInboxStore(rootURL: activeRoot).initialize()
                    oldRootSnapshot = try restoreTreeSnapshot(at: activeRoot)
                } else {
                    oldRootSnapshot = nil
                }

                let verifier = try BackupRestoreVerifier(
                    stableParentURL: destinationParent,
                    activeRootURL: activeRoot
                )
                let prepared = try await verifier.prepare(
                    checkpointURL: fixture.checkpointURL,
                    recoveryCode: fixture.recoveryCode
                )
                try corruptPreparedVaultObject(prepared)

                let transaction = try BackupRestoreTransaction(activeRootURL: activeRoot)
                await #expect(throws: BackupRestoreError.graphInvalid) {
                    _ = try await transaction.activate(prepared: prepared, resetWriter: {})
                }

                if let oldRootSnapshot {
                    #expect(try restoreTreeSnapshot(at: activeRoot) == oldRootSnapshot)
                } else {
                    #expect(!FileManager.default.fileExists(atPath: activeRoot.path))
                }
                #expect(try restoreArtifacts(in: destinationParent).isEmpty)
            }
        }
    }

    @Test
    func startupReconciliationRemovesOnlyReceiptBoundAbandonedPlaintextStaging() async throws {
        try await withRestoreFixture { fixture in
            let destinationParent = fixture.base.appendingPathComponent(
                "abandoned-preflight",
                isDirectory: true
            )
            try makePrivateDirectory(destinationParent)
            let activeRoot = destinationParent.appendingPathComponent("Vault", isDirectory: true)
            let verifier = try BackupRestoreVerifier(
                stableParentURL: destinationParent,
                activeRootURL: activeRoot
            )
            _ = try await verifier.prepare(
                checkpointURL: fixture.checkpointURL,
                recoveryCode: fixture.recoveryCode
            )
            #expect(try !restoreArtifacts(in: destinationParent).isEmpty)

            try BackupRestoreVerifier(
                stableParentURL: destinationParent,
                activeRootURL: activeRoot
            ).reconcileAbandonedPreflights()

            #expect(try restoreArtifacts(in: destinationParent).isEmpty)
            #expect(!FileManager.default.fileExists(atPath: activeRoot.path))
        }
    }
}

private struct RestoreFixture {
    let base: URL
    let checkpointURL: URL
    let validCheckpointURL: URL
    let recoveryCode: String
    let sourceVaultID: UUID
    let revisionPair: BackupRevisionPair
    let lanEvidence: RestoreLANEvidence?
}

private struct RestoreLANEvidence {
    let reviewableItemID: LANInboxItem.ID
    let preprocessingItemID: LANInboxItem.ID
    let preprocessingAttemptID: UUID
    let artifactID: LANInboxDerivedArtifact.ID
    let artifactBytes: Data
}

private func withRestoreFixture(
    includeVaultObjectInContainer: Bool = true,
    includeLANRecoveryEvidence: Bool = false,
    _ body: (RestoreFixture) async throws -> Void
) async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(
        "KinlogueRestore-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: base) }
    try makePrivateDirectory(base)
    let sourceRoot = base.appendingPathComponent("SourceVault", isDirectory: true)
    let vault = try PlaintextVault(rootURL: sourceRoot)
    let initial = try await vault.initialize()
    let payload = Data("synthetic restore object".utf8)
    let attachment = try Attachment(
        contentTypeIdentifier: "public.data",
        byteCount: payload.count,
        sha256Digest: Data(SHA256.hash(data: payload))
    )
    _ = try await vault.commit(try VaultCommitRequest(
        expectedGeneration: initial.generation,
        catalog: VaultCatalog(
            vaultID: initial.vaultID,
            generation: try VaultGeneration.successor(of: initial.generation),
            attachments: [attachment]
        ),
        writes: [.init(
            reference: .init(id: attachment.id, kind: .attachment),
            plaintext: payload
        )]
    ))
    let inbox = try PlaintextLANInboxStore(rootURL: sourceRoot)
    _ = try await inbox.initialize()
    let seeded: (evidence: RestoreLANEvidence, preprocessingSink: LANDerivedArtifactSink)?
    if includeLANRecoveryEvidence {
        seeded = try await seedRestoreLANEvidence(in: inbox)
    } else {
        seeded = nil
    }
    let source = try PlaintextLibraryBackupSource(vault: vault, inboxStore: inbox)
    let plan = try await source.prepare()
    let enrollment = try BackupKeyHierarchy.makeEnrollment()
    let seed = try BackupRecoveryCode.decode(enrollment.recoveryCode)
    let signer = try BackupDeviceSigner(
        descriptor: enrollment.descriptor,
        authorization: enrollment.authorization,
        deviceSigningSeed: enrollment.deviceSigningSeed
    )

    func makeCheckpoint(
        at url: URL,
        includeVaultObject: Bool
    ) async throws {
        let bytes = RestoreLockedBytes()
        let entries = await source.containerSources(for: plan).filter {
            includeVaultObject || $0.kind != .vaultObject
        }
        _ = try await EncryptedBackupContainerWriter().write(
            entries: entries,
            revisionPair: plan.revisionPair,
            sequence: 1,
            signer: signer,
            sink: .init(write: bytes.append, readBackSource: bytes.source)
        )
        try bytes.data.write(to: url, options: .withoutOverwriting)
        #expect(chmod(url.path, 0o600) == 0)
    }

    let checkpointURL = base.appendingPathComponent("selected.kinloguebackup")
    try await makeCheckpoint(at: checkpointURL, includeVaultObject: includeVaultObjectInContainer)
    let validCheckpointURL = base.appendingPathComponent("valid.kinloguebackup")
    try await makeCheckpoint(at: validCheckpointURL, includeVaultObject: true)
    _ = seed
    let fixture = RestoreFixture(
        base: base,
        checkpointURL: checkpointURL,
        validCheckpointURL: validCheckpointURL,
        recoveryCode: enrollment.recoveryCode,
        sourceVaultID: initial.vaultID,
        revisionPair: plan.revisionPair,
        lanEvidence: seeded?.evidence
    )
    do {
        try await body(fixture)
    } catch {
        if let seeded { await seeded.preprocessingSink.abort() }
        throw error
    }
    if let seeded { await seeded.preprocessingSink.abort() }
}

private func seedRestoreLANEvidence(
    in inbox: PlaintextLANInboxStore
) async throws -> (evidence: RestoreLANEvidence, preprocessingSink: LANDerivedArtifactSink) {
    let reviewable = try await uploadRestoreLANBlob(
        Data("synthetic restore reviewable blob".utf8),
        name: "restore-reviewable.bin",
        to: inbox
    )
    let artifactBytes = Data("synthetic restore derived artifact".utf8)
    let artifactSink = try await inbox.beginItemDerivedArtifact(
        itemID: reviewable.id,
        expectedRevision: reviewable.revision
    )
    try await artifactSink.write(artifactBytes).value
    _ = try await artifactSink.finish()

    let preprocessing = try await uploadRestoreLANBlob(
        Data("synthetic restore preprocessing blob".utf8),
        name: "restore-preprocessing.bin",
        to: inbox
    )
    let preprocessingSink = try await inbox.beginItemDerivedArtifact(
        itemID: preprocessing.id,
        expectedRevision: preprocessing.revision
    )
    try await preprocessingSink.write(Data("excluded restore partial".utf8)).value

    let snapshot = try await inbox.loadSnapshot()
    let storedReviewable = try #require(snapshot.item(id: reviewable.id))
    let artifact = try #require(storedReviewable.derivedArtifact)
    let storedPreprocessing = try #require(snapshot.item(id: preprocessing.id))
    let attemptID = try #require(storedPreprocessing.attemptID)
    return (
        RestoreLANEvidence(
            reviewableItemID: reviewable.id,
            preprocessingItemID: preprocessing.id,
            preprocessingAttemptID: attemptID,
            artifactID: artifact.id,
            artifactBytes: artifactBytes
        ),
        preprocessingSink
    )
}

private func uploadRestoreLANBlob(
    _ bytes: Data,
    name: String,
    to inbox: PlaintextLANInboxStore
) async throws -> LANInboxItem {
    let outcome = try await inbox.startItemUpload(
        transport: .init(sessionID: UUID(), remoteFileID: UUID()),
        metadata: try .init(
            displayName: .init(rawValue: name),
            declaredByteCount: bytes.count
        ),
        attemptRevision: 0,
        admissionGeneration: try await inbox.itemAdmissionGeneration()
    )
    guard case let .sink(sink) = outcome else { throw LANInboxError.invalidState }
    try await sink.write(bytes).value
    _ = try await sink.finish()
    return try #require(try await inbox.loadSnapshot().items.first(where: {
        $0.displayName.rawValue == name
    }))
}

private final class RestoreLockedBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    func append(_ bytes: Data) { lock.withLock { storage.append(bytes) } }
    var data: Data { lock.withLock { storage } }
    func source() -> BackupContainerByteSource {
        let snapshot = data
        return .init(byteCount: UInt64(snapshot.count)) { offset, count in
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

private func corruptPreparedVaultObject(_ prepared: BackupPreparedRestore) throws {
    let objectRoot = prepared.stagingURL.appendingPathComponent("objects", isDirectory: true)
    let enumerator = try #require(FileManager.default.enumerator(
        at: objectRoot,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [],
        errorHandler: { _, _ in false }
    ))
    let objectURL = try #require(enumerator.compactMap { element -> URL? in
        guard let url = element as? URL,
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            return nil
        }
        return url
    }.first)
    let descriptor = Darwin.open(objectURL.path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
    defer { Darwin.close(descriptor) }
    var replacement: UInt8 = 0xFF
    guard pwrite(descriptor, &replacement, 1, 0) == 1,
          fsync(descriptor) == 0 else {
        throw CocoaError(.fileWriteUnknown)
    }
}

private func makePrivateDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    guard chmod(url.path, 0o700) == 0 else { throw CocoaError(.fileWriteUnknown) }
}

private func restoreArtifacts(in parent: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: parent.path).filter {
        $0.hasPrefix(".kinlogue-restore-")
    }
}
