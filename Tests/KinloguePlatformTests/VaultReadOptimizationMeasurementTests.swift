import Foundation
import Testing
@testable import KinlogueCore
@testable import KinloguePlatform

@Suite("Vault read optimization measurement", .serialized)
struct VaultReadOptimizationMeasurementTests {
    @Test
    func validatedStartupReturnsItsCatalogFromOneManifestResolution() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kinlogue-vault-startup-measurement-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let resolutions = LockedMeasurementCounter()
        let vault = try PlaintextVault(
            rootURL: root,
            manifestResolutionObserver: { resolutions.increment() }
        )
        let initialized = try await vault.initialize()

        resolutions.reset()
        let validated = try await vault.loadValidatedCatalog()

        #expect(validated == initialized)
        #expect(resolutions.value == 1)
    }

    @Test
    func measuresManifestResolutionsAcrossDocumentAndDuplicateReads() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kinlogue-vault-read-measurement-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let resolutions = LockedMeasurementCounter()
        let vault = try PlaintextVault(
            rootURL: root,
            manifestResolutionObserver: { resolutions.increment() }
        )
        _ = try await vault.initialize()
        let store = VaultImportDraftStore(vault: vault)
        let bytes = Data("SYNTHETIC-VAULT-READ-MEASUREMENT".utf8)
        let file = try ValidatedImportedFile(
            data: bytes,
            kind: .image,
            contentTypeIdentifier: "public.png",
            sha256Digest: ContentDigest.sha256(bytes)
        )
        guard case .created(let draftID) = try await store.stage(file) else {
            Issue.record("Expected a synthetic draft")
            return
        }
        let lease = try await store.beginProcessing(draftID: draftID, attemptID: UUID())
        try await store.completeProcessing(
            lease: lease,
            document: ImportDraftDocument(blocks: [], candidates: ReportCandidates())
        )

        resolutions.reset()
        let review = try await store.loadReviewSnapshot(draftID: draftID)
        #expect(review.draft.id == draftID)
        #expect(review.originalData == bytes)
        #expect(resolutions.value == 1)

        resolutions.reset()
        _ = try await store.loadDocument(draftID: draftID)
        #expect(try await store.stage(file) == .existingDraft(draftID))
        let measured = resolutions.value

        print("VAULT_READ_OPTIMIZATION_METRICS manifest_resolutions=\(measured)")
        #expect(measured == 3)
    }

    @Test
    func boundedSnapshotReturnsValidatedObjectsAndRejectsOversizedSelections() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kinlogue-vault-snapshot-measurement-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = try PlaintextVault(rootURL: root)
        let initial = try await vault.initialize()
        let bytes = Data("SYNTHETIC-BOUNDED-SNAPSHOT".utf8)
        let attachment = try Attachment(
            contentTypeIdentifier: "public.png",
            byteCount: bytes.count,
            sha256Digest: ContentDigest.sha256(bytes)
        )
        let reference = VaultObjectReference(id: attachment.id, kind: .attachment)
        let catalog = try VaultCatalog(
            vaultID: initial.vaultID,
            generation: initial.generation + 1,
            attachments: [attachment]
        )
        _ = try await vault.commit(try VaultCommitRequest(
            expectedGeneration: initial.generation,
            catalog: catalog,
            writes: [VaultObjectWrite(reference: reference, plaintext: bytes)]
        ))

        let snapshot = try await vault.readSnapshot { _ in [reference] }
        #expect(try snapshot.data(for: reference) == bytes)
        #expect(snapshot.retainedByteCount == bytes.count)
        #expect(snapshot.retainedByteCount <= VaultReadSnapshotPolicy.maximumRetainedByteCount)
        print("VAULT_READ_SNAPSHOT_METRICS snapshot_peak_bytes=\(snapshot.retainedByteCount)")
        await #expect(throws: VaultError.resourceLimitExceeded) {
            _ = try await vault.readSnapshot { _ in
                (0...VaultReadSnapshotPolicy.maximumObjectCount).map { index in
                    VaultObjectReference(id: Self.uuid(index), kind: .attachment)
                }
            }
        }
    }

    private static func uuid(_ value: Int) -> UUID {
        let byte = UInt8(truncatingIfNeeded: value)
        return UUID(uuid: (
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, byte
        ))
    }
}

private final class LockedMeasurementCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    func reset() {
        lock.lock()
        count = 0
        lock.unlock()
    }
}
