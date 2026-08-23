import Foundation
import Testing
@testable import KinlogueCore
@testable import KinloguePlatform

@Test
func plaintextVaultInitializesAndReopensWithoutAKeyStore() async throws {
    let root = plaintextVaultTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let vault = try PlaintextVault(rootURL: root)
    #expect(await vault.inspect() == .absent)
    let initial = try await vault.initialize()

    let reopened = try PlaintextVault(rootURL: root)
    #expect(await reopened.inspect().isReady)
    #expect(try await reopened.loadCatalog() == initial)
}

@Test
func plaintextVaultReopensAHistoricalRecordWithoutARevisionKey() async throws {
    let root = plaintextVaultTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let vault = try PlaintextVault(rootURL: root)
    let initial = try await vault.initialize()
    let member = try FamilyMember(displayName: "Synthetic member")
    let bytes = Data("historical-record-original".utf8)
    let attachment = try Attachment(
        contentTypeIdentifier: "public.data",
        byteCount: bytes.count,
        sha256Digest: ContentDigest.sha256(bytes)
    )
    let record = try HealthRecord(
        memberID: member.id,
        attachmentID: attachment.id,
        importState: .confirmed
    )
    let catalog = try VaultCatalog(
        vaultID: initial.vaultID,
        generation: try VaultGeneration.successor(of: initial.generation),
        members: [member],
        records: [record],
        attachments: [attachment]
    )
    _ = try await vault.commit(try VaultCommitRequest(
        expectedGeneration: initial.generation,
        catalog: catalog,
        writes: [VaultObjectWrite(
            reference: .init(id: attachment.id, kind: .attachment),
            plaintext: bytes
        )]
    ))

    let manifestData = try Data(contentsOf: root.appendingPathComponent("library.json"))
    let manifest = try #require(
        JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
    )
    let encodedCatalog = try #require(manifest["catalog"] as? [String: Any])
    let records = try #require(encodedCatalog["records"] as? [[String: Any]])
    #expect(try #require(records.first)["revision"] == nil)

    let reopened = try PlaintextVault(rootURL: root)
    #expect(await reopened.inspect().isReady)
    let reopenedRecord = try #require(try await reopened.loadCatalog().records.first)
    #expect(reopenedRecord.id == record.id)
    #expect(reopenedRecord.revision == 0)
}

@Test
func interruptedPlaintextInitializationBeforeTheManifestCanBeRetried() async throws {
    let root = plaintextVaultTestRoot()
    let transaction = try PlaintextVaultInitializationTransaction(rootURL: root)
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: transaction.receiptURL)
    }
    let interrupted = try PlaintextVault(
        rootURL: root,
        transactionFailureInjector: { $0 == .afterInitializationReceipt }
    )

    await #expect(throws: VaultError.injectedFailure) {
        _ = try await interrupted.initialize()
    }
    #expect(FileManager.default.fileExists(atPath: transaction.receiptURL.path))

    // Model a process exit after AtomicFileStore has durably written, but not
    // yet renamed, the first manifest temporary file.
    let temporary = root.appendingPathComponent(
        ".kinlogue-\(UUID().uuidString).tmp"
    )
    try Data("partial-initial-manifest".utf8).write(to: temporary)

    let reopened = try PlaintextVault(rootURL: root)
    #expect(await reopened.inspect() == .absent)
    #expect(!FileManager.default.fileExists(atPath: temporary.path))
    #expect(!FileManager.default.fileExists(atPath: transaction.receiptURL.path))

    let initial = try await reopened.initialize()
    #expect(initial.generation == 1)
    #expect(await reopened.inspect().isReady)
}

@Test
func interruptedPlaintextInitializationAfterTheManifestReopensReady() async throws {
    let root = plaintextVaultTestRoot()
    let transaction = try PlaintextVaultInitializationTransaction(rootURL: root)
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: transaction.receiptURL)
    }
    let interrupted = try PlaintextVault(
        rootURL: root,
        transactionFailureInjector: { $0 == .afterInitializationManifestCommit }
    )

    await #expect(throws: VaultError.injectedFailure) {
        _ = try await interrupted.initialize()
    }
    #expect(FileManager.default.fileExists(atPath: transaction.receiptURL.path))

    let reopened = try PlaintextVault(rootURL: root)
    #expect(await reopened.inspect().isReady)
    #expect(try await reopened.loadCatalog().generation == 1)
    #expect(!FileManager.default.fileExists(atPath: transaction.receiptURL.path))
}

@Test
func plaintextVaultStoresOriginalObjectBytesWithoutEncryption() async throws {
    let root = plaintextVaultTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let vault = try PlaintextVault(rootURL: root)
    let initial = try await vault.initialize()
    let bytes = Data("plain-local-medical-report".utf8)
    let attachment = try Attachment(
        contentTypeIdentifier: "public.data",
        byteCount: bytes.count,
        sha256Digest: ContentDigest.sha256(bytes)
    )
    let reference = VaultObjectReference(id: attachment.id, kind: .attachment)
    let next = try VaultCatalog(
        vaultID: initial.vaultID,
        generation: initial.generation + 1,
        attachments: [attachment]
    )

    _ = try await vault.commit(try VaultCommitRequest(
        expectedGeneration: initial.generation,
        catalog: next,
        writes: [VaultObjectWrite(reference: reference, plaintext: bytes)]
    ))

    let layout = try PlaintextVaultLayout(rootURL: root)
    #expect(try Data(contentsOf: root.appendingPathComponent(layout.objectPath(reference))) == bytes)
    #expect(try await vault.readObject(reference) == bytes)
}

@Test
func dicomStudyCommitRequiresAClosedIndexBeforeWritingAndReopenReadsIt() async throws {
    let root = plaintextVaultTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let vault = try PlaintextVault(rootURL: root)
    let initial = try await vault.initialize()
    let imageBytes = Data("generated-dicom-image".utf8)
    let inertBytes = Data("generated-dicom-inert".utf8)
    let image = try KinlogueCore.Attachment(
        contentTypeIdentifier: "application/dicom",
        byteCount: imageBytes.count,
        sha256Digest: ContentDigest.sha256(imageBytes)
    )
    let inert = try KinlogueCore.Attachment(
        contentTypeIdentifier: "application/dicom",
        byteCount: inertBytes.count,
        sha256Digest: ContentDigest.sha256(inertBytes)
    )
    let fingerprint = try DICOMStudyFingerprint(objects: [
        .init(sha256Digest: image.sha256Digest, byteCount: image.byteCount),
        .init(sha256Digest: inert.sha256Digest, byteCount: inert.byteCount),
    ])
    let study = try DICOMStudy(
        state: .needsReview,
        fingerprint: fingerprint,
        indexObjectID: UUID(),
        attachmentIDs: [image.id, inert.id]
    )
    let seriesID = UUID()
    let attributes = try DICOMStudyIndex.ImageAttributes(
        rows: 2, columns: 2, samplesPerPixel: 1, bitsAllocated: 16, bitsStored: 12, highBit: 11,
        pixelRepresentation: .unsigned, photometricInterpretation: .monochrome2,
        imagePositionPatient: try .init(x: 0, y: 0, z: 0),
        imageOrientationPatientRow: try .init(x: 1, y: 0, z: 0),
        imageOrientationPatientColumn: try .init(x: 0, y: 1, z: 0),
        rescaleSlope: 1, rescaleIntercept: 0, windowCenter: nil, windowWidth: nil
    )
    let instance = try DICOMStudyIndex.Instance(
        id: UUID(), attachmentID: image.id, seriesID: seriesID,
        sopInstanceUIDDigest: .init(scope: .sopInstance, digest: Data(repeating: 3, count: 32)),
        canonicalOrder: 0, sopClass: .mrImageStorage, transferSyntax: .explicitVRLittleEndian,
        modality: .mr, attributes: attributes
    )
    let incompleteIndex = try DICOMStudyIndex(
        studyID: study.id,
        studyUIDDigest: .init(scope: .study, digest: Data(repeating: 1, count: 32)),
        retainedObjects: [.init(attachmentID: image.id, kind: .viewableImage)],
        instances: [instance],
        series: [try .init(id: instance.seriesID, ordinal: 1, instanceIDs: [instance.id], seriesUIDDigest: .init(scope: .series, digest: Data(repeating: 2, count: 32)), orderingProvenance: .geometryProjection)]
    )
    let next = try VaultCatalog(
        vaultID: initial.vaultID,
        generation: initial.generation + 1,
        attachments: [image, inert],
        dicomStudies: [study]
    )
    let writes = [
        VaultObjectWrite(
            reference: .init(id: image.id, kind: .attachment),
            plaintext: imageBytes
        ),
        VaultObjectWrite(
            reference: .init(id: inert.id, kind: .attachment),
            plaintext: inertBytes
        ),
        VaultObjectWrite(
            reference: .init(id: study.indexObjectID, kind: .record),
            plaintext: try CanonicalVaultJSON.encode(incompleteIndex)
        ),
    ]

    await #expect(throws: VaultError.invalidCatalog) {
        _ = try await vault.commit(try VaultCommitRequest(
            expectedGeneration: initial.generation,
            catalog: next,
            writes: writes
        ))
    }
    #expect(try await vault.loadCatalog() == initial)

    let completeIndex = try DICOMStudyIndex(
        studyID: study.id,
        studyUIDDigest: .init(scope: .study, digest: Data(repeating: 1, count: 32)),
        retainedObjects: [
            .init(attachmentID: image.id, kind: .viewableImage),
            .init(attachmentID: inert.id, kind: .inertAttachment),
        ],
        instances: [instance],
        series: [try .init(id: instance.seriesID, ordinal: 1, instanceIDs: [instance.id], seriesUIDDigest: .init(scope: .series, digest: Data(repeating: 2, count: 32)), orderingProvenance: .geometryProjection)]
    )
    let completeWrites = Array(writes.dropLast()) + [VaultObjectWrite(
        reference: .init(id: study.indexObjectID, kind: .record),
        plaintext: try CanonicalVaultJSON.encode(completeIndex)
    )]
    _ = try await vault.commit(try VaultCommitRequest(
        expectedGeneration: initial.generation,
        catalog: next,
        writes: completeWrites
    ))

    let reopened = try PlaintextVault(rootURL: root)
    #expect(try await reopened.loadCatalog() == next)
}

@Test
func oversizedDICOMIndexIsRejectedBeforeAnyObjectWriteOrCatalogMutation() async throws {
    let root = plaintextVaultTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let vault = try PlaintextVault(rootURL: root)
    let initial = try await vault.initialize()
    let before = try plaintextVaultRegularFileSnapshot(root: root)
    let bytes = Data("generated-dicom-object".utf8)
    let attachment = try KinlogueCore.Attachment(
        contentTypeIdentifier: "application/dicom",
        byteCount: bytes.count,
        sha256Digest: ContentDigest.sha256(bytes)
    )
    let fingerprint = try DICOMStudyFingerprint(objects: [
        .init(sha256Digest: attachment.sha256Digest, byteCount: attachment.byteCount),
    ])
    let study = try DICOMStudy(
        state: .needsReview,
        fingerprint: fingerprint,
        indexObjectID: UUID(),
        attachmentIDs: [attachment.id]
    )
    let proposed = try VaultCatalog(
        vaultID: initial.vaultID,
        generation: initial.generation + 1,
        attachments: [attachment],
        dicomStudies: [study]
    )
    let oversizedIndex = Data(
        repeating: 0x41,
        count: PlaintextVaultResourcePolicy.maximumByteCount(for: .record) + 1
    )

    await #expect(throws: VaultError.resourceLimitExceeded) {
        _ = try await vault.commit(try VaultCommitRequest(
            expectedGeneration: initial.generation,
            catalog: proposed,
            writes: [
                VaultObjectWrite(
                    reference: .init(id: attachment.id, kind: .attachment),
                    plaintext: bytes
                ),
                VaultObjectWrite(
                    reference: .init(id: study.indexObjectID, kind: .record),
                    plaintext: oversizedIndex
                ),
            ]
        ))
    }

    #expect(try await vault.loadCatalog() == initial)
    #expect(try plaintextVaultRegularFileSnapshot(root: root) == before)
}

@Test
func platformDICOMAggregateCapacityUsesCoreBoundsAtTheExactEdges() throws {
    #expect(PlaintextVaultResourcePolicy.maximumDICOMObjectCount
        == VaultCatalog.maximumRetainedDICOMObjectCount)
    #expect(PlaintextVaultResourcePolicy.maximumDICOMSeriesCount
        == DICOMStudyIndex.maximumSeriesCount)
    try PlaintextVaultResourcePolicy.validateDICOMRetainedObjectCount(10_000)
    #expect(throws: VaultError.resourceLimitExceeded) {
        try PlaintextVaultResourcePolicy.validateDICOMRetainedObjectCount(10_001)
    }
    #expect(try PlaintextVaultResourcePolicy.addingDICOMSeriesCount(4_095, adding: 1) == 4_096)
    #expect(throws: VaultError.resourceLimitExceeded) {
        _ = try PlaintextVaultResourcePolicy.addingDICOMSeriesCount(4_096, adding: 1)
    }
    try PlaintextVaultResourcePolicy.validateManifestByteCount(64 * 1_024 * 1_024)
    #expect(throws: VaultError.resourceLimitExceeded) {
        try PlaintextVaultResourcePolicy.validateManifestByteCount(64 * 1_024 * 1_024 + 1)
    }
}

@Test
func plaintextVaultInspectionDoesNotReconcileDICOMJournalBeforeRejectingCorruptedObject() async throws {
    let root = plaintextVaultTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let vault = try PlaintextVault(rootURL: root)
    let initial = try await vault.initialize()
    let bytes = Data(repeating: 0x42, count: 64)
    let attachment = try Attachment(
        contentTypeIdentifier: "public.data",
        byteCount: bytes.count,
        sha256Digest: ContentDigest.sha256(bytes)
    )
    let reference = VaultObjectReference(id: attachment.id, kind: .attachment)
    let next = try VaultCatalog(
        vaultID: initial.vaultID,
        generation: initial.generation + 1,
        attachments: [attachment]
    )
    _ = try await vault.commit(try VaultCommitRequest(
        expectedGeneration: initial.generation,
        catalog: next,
        writes: [VaultObjectWrite(reference: reference, plaintext: bytes)]
    ))

    let pending = try installPendingDICOMPromotion(root: root, vaultID: initial.vaultID)
    let files = try AtomicFileStore(rootURL: root)
    let path = try PlaintextVaultLayout(rootURL: root).objectPath(reference)
    try files.replaceAtomically(Data(repeating: 0x43, count: bytes.count), relativePath: path)
    let before = try plaintextVaultRegularFileSnapshot(root: root)

    let reopened = try PlaintextVault(rootURL: root)
    #expect(await reopened.inspect() == .damaged)
    #expect(try plaintextVaultRegularFileSnapshot(root: root) == before)
    #expect(try pending.journal.pendingOperationCount() == 1)
    #expect(files.exists(relativePath: pending.objectPath))
}

@Test
func plaintextVaultInspectionReconcilesDICOMJournalAfterValidatingHealthyVault() async throws {
    let root = plaintextVaultTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let vault = try PlaintextVault(rootURL: root)
    let initial = try await vault.initialize()
    let pending = try installPendingDICOMPromotion(root: root, vaultID: initial.vaultID)
    let files = try AtomicFileStore(rootURL: root)

    #expect(try pending.journal.pendingOperationCount() == 1)
    #expect(files.exists(relativePath: pending.objectPath))
    #expect(await vault.inspect().isReady)
    #expect(try pending.journal.pendingOperationCount() == 0)
    #expect(!files.exists(relativePath: pending.objectPath))
}

@Test
func plaintextVaultDetectsObjectTampering() async throws {
    let root = plaintextVaultTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let vault = try PlaintextVault(rootURL: root)
    let initial = try await vault.initialize()
    let bytes = Data(repeating: 0x42, count: 64)
    let attachment = try Attachment(
        contentTypeIdentifier: "public.data",
        byteCount: bytes.count,
        sha256Digest: ContentDigest.sha256(bytes)
    )
    let reference = VaultObjectReference(id: attachment.id, kind: .attachment)
    let next = try VaultCatalog(
        vaultID: initial.vaultID,
        generation: initial.generation + 1,
        attachments: [attachment]
    )
    _ = try await vault.commit(try VaultCommitRequest(
        expectedGeneration: initial.generation,
        catalog: next,
        writes: [VaultObjectWrite(reference: reference, plaintext: bytes)]
    ))

    let files = try AtomicFileStore(rootURL: root)
    let path = try PlaintextVaultLayout(rootURL: root).objectPath(reference)
    try files.replaceAtomically(Data(repeating: 0x43, count: bytes.count), relativePath: path)

    let reopened = try PlaintextVault(rootURL: root)
    #expect(await reopened.inspect() == .damaged)
}

@Test
func plaintextVaultRejectsAMissingObjectBeforeReturningTheCatalog() async throws {
    let root = plaintextVaultTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let vault = try PlaintextVault(rootURL: root)
    let initial = try await vault.initialize()
    let bytes = Data("required-original".utf8)
    let attachment = try Attachment(
        contentTypeIdentifier: "public.data",
        byteCount: bytes.count,
        sha256Digest: ContentDigest.sha256(bytes)
    )
    let reference = VaultObjectReference(id: attachment.id, kind: .attachment)
    let next = try VaultCatalog(
        vaultID: initial.vaultID,
        generation: initial.generation + 1,
        attachments: [attachment]
    )
    _ = try await vault.commit(try VaultCommitRequest(
        expectedGeneration: initial.generation,
        catalog: next,
        writes: [VaultObjectWrite(reference: reference, plaintext: bytes)]
    ))
    let files = try AtomicFileStore(rootURL: root)
    try files.remove(
        relativePath: try PlaintextVaultLayout(rootURL: root).objectPath(reference)
    )

    await #expect(throws: VaultError.objectMissing) {
        _ = try await vault.loadCatalog()
    }
    #expect(await vault.inspect() == .damaged)
}

@Test
func plaintextVaultNeverOverwritesALegacyEncryptedVault() async throws {
    let root = plaintextVaultTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try AtomicFileStore(rootURL: root)
    let marker = Data("legacy-encrypted-marker".utf8)
    try files.replaceAtomically(marker, relativePath: "vault.marker")
    let vault = try PlaintextVault(rootURL: root)

    #expect(await vault.inspect() == .legacyEncrypted)
    await #expect(throws: VaultError.legacyEncryptedVault) {
        _ = try await vault.initialize()
    }
    await #expect(throws: VaultError.legacyEncryptedVault) {
        try await vault.destroy()
    }
    #expect(try files.read(relativePath: "vault.marker", maximumByteCount: 1024) == marker)
    #expect(FileManager.default.fileExists(atPath: root.path))
    #expect(!files.exists(relativePath: "library.json"))
}

@Test
func authorizedPendingDeletionCompletesBeforeLegacyMarkerIsClassified() async throws {
    let root = plaintextVaultTestRoot()
    let transaction = try PlaintextVaultDeletionTransaction(rootURL: root)
    defer { removeDeletionArtifacts(root: root, transaction: transaction) }
    let interrupted = try PlaintextVault(
        rootURL: root,
        transactionFailureInjector: { $0 == .afterDeletionReceipt }
    )
    _ = try await interrupted.initialize()

    await #expect(throws: VaultError.injectedFailure) {
        try await interrupted.destroy()
    }
    #expect(FileManager.default.fileExists(atPath: transaction.receiptURL.path))
    let files = try AtomicFileStore(rootURL: root)
    try files.replaceAtomically(
        Data("legacy-encrypted-marker".utf8),
        relativePath: "vault.marker"
    )

    let reopened = try PlaintextVault(rootURL: root)
    #expect(await reopened.inspect() == .absent)
    #expect(!FileManager.default.fileExists(atPath: root.path))
    #expect(!FileManager.default.fileExists(atPath: transaction.receiptURL.path))
    #expect(!FileManager.default.fileExists(atPath: transaction.quarantineURL.path))
}

@Test
func malformedDeletionReceiptDoesNotAuthorizeDeletingALegacyVault() async throws {
    let root = plaintextVaultTestRoot()
    let transaction = try PlaintextVaultDeletionTransaction(rootURL: root)
    defer { removeDeletionArtifacts(root: root, transaction: transaction) }
    let marker = Data("legacy-encrypted-marker".utf8)
    let files = try AtomicFileStore(rootURL: root)
    try files.replaceAtomically(marker, relativePath: "vault.marker")
    try Data("malformed-deletion-receipt".utf8).write(
        to: transaction.receiptURL,
        options: .withoutOverwriting
    )

    let vault = try PlaintextVault(rootURL: root)
    #expect(await vault.inspect() == .legacyEncrypted)
    #expect(try files.read(relativePath: "vault.marker", maximumByteCount: 1024) == marker)
    #expect(FileManager.default.fileExists(atPath: root.path))
    #expect(!FileManager.default.fileExists(atPath: transaction.receiptURL.path))
    #expect(!FileManager.default.fileExists(atPath: transaction.quarantineURL.path))
}

@Test(arguments: [
    PlaintextVaultTransactionFault.afterObjects,
    .afterManifestCommit,
])
func interruptedPlaintextCommitReopensAtACompleteGeneration(
    fault: PlaintextVaultTransactionFault
) async throws {
    let root = plaintextVaultTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let vault = try PlaintextVault(
        rootURL: root,
        transactionFailureInjector: { $0 == fault }
    )
    let initial = try await vault.initialize()
    let bytes = Data("interrupted-commit-original".utf8)
    let attachment = try Attachment(
        contentTypeIdentifier: "public.data",
        byteCount: bytes.count,
        sha256Digest: ContentDigest.sha256(bytes)
    )
    let reference = VaultObjectReference(id: attachment.id, kind: .attachment)
    let next = try VaultCatalog(
        vaultID: initial.vaultID,
        generation: initial.generation + 1,
        attachments: [attachment]
    )

    await #expect(throws: VaultError.injectedFailure) {
        _ = try await vault.commit(try VaultCommitRequest(
            expectedGeneration: initial.generation,
            catalog: next,
            writes: [VaultObjectWrite(reference: reference, plaintext: bytes)]
        ))
    }

    let reopened = try PlaintextVault(rootURL: root)
    let catalog = try await reopened.loadCatalog()
    let objectURL = root.appendingPathComponent(
        try PlaintextVaultLayout(rootURL: root).objectPath(reference)
    )
    switch fault {
    case .afterObjects:
        #expect(catalog == initial)
        #expect(!FileManager.default.fileExists(atPath: objectURL.path))
    case .afterManifestCommit:
        #expect(catalog == next)
        #expect(try await reopened.readObject(reference) == bytes)
    case .afterInitializationReceipt, .afterInitializationManifestCommit,
         .afterDeletionReceipt, .afterDeletionRename, .afterDeletionQuarantineRemoval,
         .afterDICOMJournalRecord, .afterDICOMAttachmentPromotion,
         .afterDICOMIndexPromotion:
        Issue.record("Unexpected deletion fault in commit test")
    }
    #expect(await reopened.inspect().isReady)
}

@Test
func plaintextVaultRejectsACorruptedManifestDigest() async throws {
    let root = plaintextVaultTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let vault = try PlaintextVault(rootURL: root)
    _ = try await vault.initialize()

    let manifestURL = root.appendingPathComponent("library.json")
    let manifestData = try Data(contentsOf: manifestURL)
    var manifest = try #require(
        JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
    )
    manifest["catalogSHA256"] = Data(repeating: 0, count: 32).base64EncodedString()
    let corrupted = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
    let files = try AtomicFileStore(rootURL: root)
    try files.replaceAtomically(corrupted, relativePath: "library.json")

    let reopened = try PlaintextVault(rootURL: root)
    #expect(await reopened.inspect() == .damaged)
    await #expect(throws: VaultError.invalidDigest) {
        _ = try await reopened.loadCatalog()
    }
}

@Test
func targetedReadDoesNotOpenUnrelatedDamagedObjects() async throws {
    let root = plaintextVaultTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let vault = try PlaintextVault(rootURL: root)
    let initial = try await vault.initialize()
    let firstBytes = Data("first-original".utf8)
    let secondBytes = Data("second-original".utf8)
    let first = try Attachment(
        contentTypeIdentifier: "public.data",
        byteCount: firstBytes.count,
        sha256Digest: ContentDigest.sha256(firstBytes)
    )
    let second = try Attachment(
        contentTypeIdentifier: "public.data",
        byteCount: secondBytes.count,
        sha256Digest: ContentDigest.sha256(secondBytes)
    )
    let firstReference = VaultObjectReference(id: first.id, kind: .attachment)
    let secondReference = VaultObjectReference(id: second.id, kind: .attachment)
    let next = try VaultCatalog(
        vaultID: initial.vaultID,
        generation: initial.generation + 1,
        attachments: [first, second]
    )
    _ = try await vault.commit(try VaultCommitRequest(
        expectedGeneration: initial.generation,
        catalog: next,
        writes: [
            VaultObjectWrite(reference: firstReference, plaintext: firstBytes),
            VaultObjectWrite(reference: secondReference, plaintext: secondBytes),
        ]
    ))

    let files = try AtomicFileStore(rootURL: root)
    let secondPath = try PlaintextVaultLayout(rootURL: root).objectPath(secondReference)
    try files.replaceAtomically(
        Data(repeating: 0x7F, count: secondBytes.count),
        relativePath: secondPath
    )

    #expect(try await vault.loadCatalog() == next)
    #expect(try await vault.readObject(firstReference) == firstBytes)
    await #expect(throws: VaultError.invalidDigest) {
        _ = try await vault.readObject(secondReference)
    }
    #expect(await vault.inspect() == .damaged)
}

@Test
func postCommitOrphanCleanupFailureDoesNotInvalidateTheCommittedCatalog() async throws {
    let root = plaintextVaultTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let initialVault = try PlaintextVault(rootURL: root)
    let initial = try await initialVault.initialize()
    let firstBytes = Data("retained".utf8)
    let orphanBytes = Data("orphaned".utf8)
    let first = try Attachment(
        contentTypeIdentifier: "public.data",
        byteCount: firstBytes.count,
        sha256Digest: ContentDigest.sha256(firstBytes)
    )
    let orphan = try Attachment(
        contentTypeIdentifier: "public.data",
        byteCount: orphanBytes.count,
        sha256Digest: ContentDigest.sha256(orphanBytes)
    )
    let firstReference = VaultObjectReference(id: first.id, kind: .attachment)
    let orphanReference = VaultObjectReference(id: orphan.id, kind: .attachment)
    let populated = try VaultCatalog(
        vaultID: initial.vaultID,
        generation: initial.generation + 1,
        attachments: [first, orphan]
    )
    _ = try await initialVault.commit(try VaultCommitRequest(
        expectedGeneration: initial.generation,
        catalog: populated,
        writes: [
            VaultObjectWrite(reference: firstReference, plaintext: firstBytes),
            VaultObjectWrite(reference: orphanReference, plaintext: orphanBytes),
        ]
    ))

    let vault = try PlaintextVault(
        rootURL: root,
        fileFailureInjector: { $0 == .beforeRemove }
    )
    let pruned = try VaultCatalog(
        vaultID: populated.vaultID,
        generation: populated.generation + 1,
        attachments: [first]
    )
    #expect(try await vault.commit(try VaultCommitRequest(
        expectedGeneration: populated.generation,
        catalog: pruned,
        writes: []
    )) == pruned)

    let orphanURL = root.appendingPathComponent(
        try PlaintextVaultLayout(rootURL: root).objectPath(orphanReference)
    )
    #expect(FileManager.default.fileExists(atPath: orphanURL.path))

    let reopened = try PlaintextVault(rootURL: root)
    #expect(try await reopened.loadCatalog() == pruned)
    #expect(!FileManager.default.fileExists(atPath: orphanURL.path))
}

@Test
func plaintextVaultReclaimsRecognizedAtomicCrashLeftovers() async throws {
    let root = plaintextVaultTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let vault = try PlaintextVault(rootURL: root)
    _ = try await vault.initialize()

    let rootTemporary = root.appendingPathComponent(
        ".kinlogue-\(UUID().uuidString).tmp"
    )
    try Data("partial-manifest".utf8).write(to: rootTemporary)

    let objectDirectory = root
        .appendingPathComponent("objects", isDirectory: true)
        .appendingPathComponent("attachment", isDirectory: true)
    try FileManager.default.createDirectory(
        at: objectDirectory,
        withIntermediateDirectories: true
    )
    let objectTemporary = objectDirectory.appendingPathComponent(
        ".kinlogue-\(UUID().uuidString).tmp"
    )
    try Data("partial-object".utf8).write(to: objectTemporary)

    _ = try await vault.loadCatalog()
    #expect(!FileManager.default.fileExists(atPath: rootTemporary.path))
    #expect(!FileManager.default.fileExists(atPath: objectTemporary.path))
}

@Test
func plaintextVaultNeverReclaimsTemporaryLookingFilesFromAnUnknownLayout() async throws {
    let root = plaintextVaultTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    let unknown = root.appendingPathComponent(
        ".kinlogue-\(UUID().uuidString).tmp"
    )
    let sentinel = Data("unowned-temporary-looking-file".utf8)
    try sentinel.write(to: unknown)

    let vault = try PlaintextVault(rootURL: root)
    #expect(await vault.inspect() == .damaged)
    await #expect(throws: VaultError.partialInitialization) {
        _ = try await vault.initialize()
    }
    await #expect(throws: VaultError.partialInitialization) {
        try await vault.destroy()
    }
    #expect(try Data(contentsOf: unknown) == sentinel)
}

@Test(arguments: [
    PlaintextVaultTransactionFault.afterDeletionReceipt,
    .afterDeletionRename,
    .afterDeletionQuarantineRemoval,
])
func interruptedPlaintextDeletionFinishesOnTheNextInspection(
    fault: PlaintextVaultTransactionFault
) async throws {
    let root = plaintextVaultTestRoot()
    let transaction = try PlaintextVaultDeletionTransaction(rootURL: root)
    defer { removeDeletionArtifacts(root: root, transaction: transaction) }
    let vault = try PlaintextVault(
        rootURL: root,
        transactionFailureInjector: { $0 == fault }
    )
    _ = try await vault.initialize()

    await #expect(throws: VaultError.injectedFailure) {
        try await vault.destroy()
    }

    let reopened = try PlaintextVault(rootURL: root)
    #expect(await reopened.inspect() == .absent)
    #expect(!FileManager.default.fileExists(atPath: root.path))
    #expect(!FileManager.default.fileExists(atPath: transaction.receiptURL.path))
    #expect(!FileManager.default.fileExists(atPath: transaction.quarantineURL.path))
}

@Test
func plaintextDeletionDoesNotRecursivelyDeleteAReplacementQuarantine() async throws {
    let root = plaintextVaultTestRoot()
    let probe = try PlaintextVaultDeletionTransaction(rootURL: root)
    let originalQuarantine = probe.quarantineURL.appendingPathExtension("original")
    let replacement = probe.quarantineURL.appendingPathExtension("replacement")
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: probe.receiptURL)
        try? FileManager.default.removeItem(at: probe.quarantineURL)
        try? FileManager.default.removeItem(at: originalQuarantine)
        try? FileManager.default.removeItem(at: replacement)
    }
    let vault = try PlaintextVault(rootURL: root)
    _ = try await vault.initialize()
    try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: false)
    let sentinel = replacement.appendingPathComponent("must-survive.txt")
    let sentinelBytes = Data("replacement quarantine sentinel".utf8)
    try sentinelBytes.write(to: sentinel)

    let swap = DeletionQuarantineSwap(
        quarantine: probe.quarantineURL,
        originalQuarantine: originalQuarantine,
        replacement: replacement
    )
    let transaction = try PlaintextVaultDeletionTransaction(
        rootURL: root,
        failureInjector: { point in
            if point == .afterDeletionRename { swap.perform() }
            return false
        }
    )

    #expect(throws: VaultError.invalidPath) {
        try transaction.begin()
    }
    #expect(swap.succeeded)
    #expect(try Data(contentsOf: probe.quarantineURL.appendingPathComponent(
        sentinel.lastPathComponent
    )) == sentinelBytes)
    #expect(FileManager.default.fileExists(atPath: originalQuarantine.path))
}

@Test
func plaintextVaultRejectsTooManyReachableObjectsBeforePublishing() async throws {
    let root = plaintextVaultTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let vault = try PlaintextVault(rootURL: root)
    let initial = try await vault.initialize()
    let emptyDigest = ContentDigest.sha256(Data())
    var attachments: [KinlogueCore.Attachment] = []
    attachments.reserveCapacity(20_000)
    for _ in 0..<20_000 {
        attachments.append(try Attachment(
            contentTypeIdentifier: "public.data",
            byteCount: 0,
            sha256Digest: emptyDigest
        ))
    }
    let ownedAttachment = try #require(attachments.first)
    let fingerprint = try DICOMStudyFingerprint(objects: [
        .init(
            sha256Digest: ownedAttachment.sha256Digest,
            byteCount: ownedAttachment.byteCount
        ),
    ])
    let study = try DICOMStudy(
        state: .needsReview,
        fingerprint: fingerprint,
        indexObjectID: UUID(),
        attachmentIDs: [ownedAttachment.id]
    )
    let oversized = try VaultCatalog(
        vaultID: initial.vaultID,
        generation: initial.generation + 1,
        attachments: attachments,
        dicomStudies: [study]
    )

    await #expect(throws: VaultError.resourceLimitExceeded) {
        _ = try await vault.commit(try VaultCommitRequest(
            expectedGeneration: initial.generation,
            catalog: oversized,
            writes: []
        ))
    }
    #expect(try await vault.loadCatalog() == initial)
}

@Test
func nonDirectoryVaultRootFailsClosedDuringInspectionAndDeletion() async throws {
    let root = plaintextVaultTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sentinel = Data("not-a-vault-directory".utf8)
    try sentinel.write(to: root)
    let vault = try PlaintextVault(rootURL: root)

    #expect(await vault.inspect() == .damaged)
    await #expect(throws: VaultError.invalidPath) {
        try await vault.destroy()
    }
    #expect(try Data(contentsOf: root) == sentinel)
}

@Test
func plaintextVaultRejectsAStaleGenerationAcrossInstances() async throws {
    let root = plaintextVaultTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try PlaintextVault(rootURL: root)
    let second = try PlaintextVault(rootURL: root)
    let initial = try await first.initialize()
    let generationTwo = try VaultCatalog(
        vaultID: initial.vaultID,
        generation: initial.generation + 1
    )
    _ = try await first.commit(try VaultCommitRequest(
        expectedGeneration: initial.generation,
        catalog: generationTwo,
        writes: []
    ))

    await #expect(throws: VaultError.mutationConflict) {
        _ = try await second.commit(try VaultCommitRequest(
            expectedGeneration: initial.generation,
            catalog: generationTwo,
            writes: []
        ))
    }
    #expect(try await second.loadCatalog() == generationTwo)
}

func plaintextVaultTestRoot() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("kinlogue-plaintext-vault-\(UUID().uuidString)", isDirectory: true)
}

private func removeDeletionArtifacts(
    root: URL,
    transaction: PlaintextVaultDeletionTransaction
) {
    try? FileManager.default.removeItem(at: root)
    try? FileManager.default.removeItem(at: transaction.receiptURL)
    try? FileManager.default.removeItem(at: transaction.quarantineURL)
}

private final class DeletionQuarantineSwap: @unchecked Sendable {
    private let lock = NSLock()
    private let quarantine: URL
    private let originalQuarantine: URL
    private let replacement: URL
    private var didRun = false
    private var failure: Error?

    init(quarantine: URL, originalQuarantine: URL, replacement: URL) {
        self.quarantine = quarantine
        self.originalQuarantine = originalQuarantine
        self.replacement = replacement
    }

    var succeeded: Bool { lock.withLock { didRun && failure == nil } }

    func perform() {
        lock.withLock {
            guard !didRun else { return }
            didRun = true
            do {
                try FileManager.default.moveItem(at: quarantine, to: originalQuarantine)
                try FileManager.default.moveItem(at: replacement, to: quarantine)
            } catch {
                failure = error
            }
        }
    }
}

private func installPendingDICOMPromotion(
    root: URL,
    vaultID: UUID
) throws -> (journal: VaultDICOMImportJournal, objectPath: String) {
    let operationID = UUID()
    let reference = VaultObjectReference(id: UUID(), kind: .attachment)
    let journal = try VaultDICOMImportJournal(rootURL: root)
    let files = try AtomicFileStore(rootURL: root)
    let objectPath = try PlaintextVaultLayout(rootURL: root).objectPath(reference)

    try journal.begin(operationID: operationID, vaultID: vaultID)
    try files.replaceAtomically(
        Data("abandoned-dicom-object".utf8),
        relativePath: objectPath
    )
    try journal.recordPromotions([reference], operationID: operationID)
    return (journal, objectPath)
}

func plaintextVaultRegularFileSnapshot(root: URL) throws -> [String: Data] {
    guard let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: []
    ) else { return [:] }
    var snapshot: [String: Data] = [:]
    for case let url as URL in enumerator {
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            continue
        }
        snapshot[String(url.path.dropFirst(root.path.count + 1))] = try Data(contentsOf: url)
    }
    return snapshot
}
