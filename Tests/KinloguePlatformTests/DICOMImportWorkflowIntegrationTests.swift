import Foundation
import KinlogueCore
import KinlogueDICOMIPC
import KinlogueDICOMTestSupport
import Testing
@testable import KinloguePlatform

struct DICOMImportWorkflowIntegrationTests {
    @Test
    func genericCatalogCommitCannotSilentlyRemoveAnImportedStudy() async throws {
        let fixture = try await WorkflowFixture()
        defer { fixture.cleanup() }
        try GeneratedDICOMFixture.explicitVRLittleEndianMR().write(
            to: fixture.source.appendingPathComponent("generated.bin")
        )
        let workflow = try DICOMImportWorkflow(
            rootURL: fixture.vaultRoot,
            vault: fixture.vault,
            decoder: RepeatingFrameDecoder(frame: fixture.frame())
        )
        let imported = try await workflow.importDirectory(
            fixture.source,
            securityScope: .notRequiredForTesting
        )
        let current = try await fixture.vault.loadCatalog()
        let accidentallyOmitted = try VaultCatalog(
            formatVersion: current.formatVersion,
            vaultID: current.vaultID,
            generation: current.generation + 1,
            members: current.members,
            records: current.records,
            attachments: current.attachments,
            importDrafts: current.importDrafts
        )

        await #expect(throws: VaultError.invalidCatalog) {
            _ = try await fixture.vault.commit(try VaultCommitRequest(
                expectedGeneration: current.generation,
                catalog: accidentallyOmitted,
                writes: []
            ))
        }
        #expect((try await fixture.vault.loadCatalog()).dicomStudies.map(\.id) == [imported.studyID])

        let explicitlyDeleted = try current.deletingDICOMStudy(id: imported.studyID)
        let committed = try await fixture.vault.commit(try VaultCommitRequest(
            expectedGeneration: current.generation,
            catalog: explicitlyDeleted,
            writes: [],
            removedDICOMStudyIDs: [imported.studyID]
        ))
        #expect(committed.dicomStudies.isEmpty)
    }

    @Test
    func wholeStudyPublishesOnceReopensWithoutSourceAndExactReimportIsIdempotent() async throws {
        let fixture = try await WorkflowFixture()
        defer { fixture.cleanup() }
        try GeneratedDICOMFixture.explicitVRLittleEndianMR().write(
            to: fixture.source.appendingPathComponent("generated.bin")
        )
        let decoder = RepeatingFrameDecoder(frame: fixture.frame())
        let workflow = try DICOMImportWorkflow(
            rootURL: fixture.vaultRoot,
            vault: fixture.vault,
            decoder: decoder
        )

        let first = try await workflow.importDirectory(
            fixture.source,
            securityScope: .notRequiredForTesting
        )
        let firstStudyID = first.studyID
        try FileManager.default.removeItem(at: fixture.source)
        let reopened = try await PlaintextVault(rootURL: fixture.vaultRoot).loadCatalog()
        #expect(reopened.dicomStudies.map(\.id) == [firstStudyID])
        #expect(reopened.dicomStudies.first?.state == .needsReview)

        try FileManager.default.createDirectory(at: fixture.source, withIntermediateDirectories: true)
        try GeneratedDICOMFixture.explicitVRLittleEndianMR().write(
            to: fixture.source.appendingPathComponent("renamed.bin")
        )
        let second = try await workflow.importDirectory(
            fixture.source,
            securityScope: .notRequiredForTesting
        )
        #expect(second.studyID == firstStudyID)
        #expect(second.wasExisting)
        #expect((try await fixture.vault.loadCatalog()).dicomStudies.count == 1)
    }

    @Test
    func journalFaultLeavesNoVisibleStudyAndNextReopenReclaimsOwnedOrphans() async throws {
        let fixture = try await WorkflowFixture(transactionFault: .afterDICOMJournalRecord)
        defer { fixture.cleanup() }
        try GeneratedDICOMFixture.explicitVRLittleEndianMR().write(
            to: fixture.source.appendingPathComponent("generated.bin")
        )
        let workflow = try DICOMImportWorkflow(
            rootURL: fixture.vaultRoot,
            vault: fixture.vault,
            decoder: RepeatingFrameDecoder(frame: fixture.frame())
        )

        await #expect(throws: VaultError.injectedFailure) {
            try await workflow.importDirectory(
                fixture.source,
                securityScope: .notRequiredForTesting
            )
        }
        let reopened = try PlaintextVault(rootURL: fixture.vaultRoot)
        #expect((try await reopened.loadCatalog()).dicomStudies.isEmpty)
        #expect(try VaultDICOMImportJournal(rootURL: fixture.vaultRoot).pendingOperationCount() == 0)
    }

    @Test(arguments: [
        PlaintextVaultTransactionFault.afterDICOMAttachmentPromotion,
        .afterDICOMIndexPromotion,
        .afterObjects,
        .afterManifestCommit,
    ])
    func everyDICOMPromotionBoundaryReopensAsOneOldOrNewCatalog(
        fault: PlaintextVaultTransactionFault
    ) async throws {
        let fixture = try await WorkflowFixture(transactionFault: fault)
        defer { fixture.cleanup() }
        try GeneratedDICOMFixture.explicitVRLittleEndianMR().write(
            to: fixture.source.appendingPathComponent("generated.bin")
        )
        let workflow = try DICOMImportWorkflow(
            rootURL: fixture.vaultRoot,
            vault: fixture.vault,
            decoder: RepeatingFrameDecoder(frame: fixture.frame())
        )
        if fault == .afterManifestCommit {
            let result = try await workflow.importDirectory(
                fixture.source,
                securityScope: .notRequiredForTesting
            )
            #expect(!result.wasExisting)
        } else {
            await #expect(throws: VaultError.injectedFailure) {
                _ = try await workflow.importDirectory(
                    fixture.source,
                    securityScope: .notRequiredForTesting
                )
            }
        }

        let reopened = try PlaintextVault(rootURL: fixture.vaultRoot)
        let catalog = try await reopened.loadCatalog()
        #expect(catalog.dicomStudies.count == (fault == .afterManifestCommit ? 1 : 0))
        #expect(try VaultDICOMImportJournal(rootURL: fixture.vaultRoot).pendingOperationCount() == 0)
        #expect(await reopened.inspect().isReady)
    }

    @Test
    func concurrentExactImportsConvergeOnOneStudy() async throws {
        let fixture = try await WorkflowFixture()
        defer { fixture.cleanup() }
        try GeneratedDICOMFixture.explicitVRLittleEndianMR().write(
            to: fixture.source.appendingPathComponent("generated.bin")
        )
        let first = try DICOMImportWorkflow(
            rootURL: fixture.vaultRoot,
            vault: fixture.vault,
            decoder: RepeatingFrameDecoder(frame: fixture.frame())
        )
        let secondVault = try PlaintextVault(rootURL: fixture.vaultRoot)
        let second = try DICOMImportWorkflow(
            rootURL: fixture.vaultRoot,
            vault: secondVault,
            decoder: RepeatingFrameDecoder(frame: fixture.frame())
        )

        async let firstResult = first.importDirectory(
            fixture.source, securityScope: .notRequiredForTesting
        )
        async let secondResult = second.importDirectory(
            fixture.source, securityScope: .notRequiredForTesting
        )
        let results = try await [firstResult, secondResult]
        #expect(Set(results.map(\.studyID)).count == 1)
        #expect(results.filter(\.wasExisting).count == 1)
        #expect((try await fixture.vault.loadCatalog()).dicomStudies.count == 1)
    }

    @Test
    func cancellationDuringDecoderWorkPublishesNothingAndRemovesStaging() async throws {
        let fixture = try await WorkflowFixture()
        defer { fixture.cleanup() }
        try GeneratedDICOMFixture.explicitVRLittleEndianMR().write(
            to: fixture.source.appendingPathComponent("generated.bin")
        )
        let decoder = SuspendingFrameDecoder(frame: fixture.frame())
        let workflow = try DICOMImportWorkflow(
            rootURL: fixture.vaultRoot,
            vault: fixture.vault,
            decoder: decoder
        )
        let task = Task {
            try await workflow.importDirectory(
                fixture.source, securityScope: .notRequiredForTesting
            )
        }
        while await decoder.callCount == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await workflow.state == .indexing)
        #expect(try await workflow.cancelCurrentImport() == nil)
        await #expect(throws: DICOMImportError.cancelled) { _ = try await task.value }
        #expect(await workflow.state == .cancelled)
        #expect((try await fixture.vault.loadCatalog()).dicomStudies.isEmpty)
        let stagingRoot = fixture.vaultRoot.appendingPathComponent("dicom-import-staging")
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: stagingRoot.path)) ?? []
        #expect(entries.compactMap(UUID.init(uuidString:)).isEmpty)
    }

    @Test
    func abandonedPrecommitStagingIsReconciledOnReopen() async throws {
        let fixture = try await WorkflowFixture()
        defer { fixture.cleanup() }
        try GeneratedDICOMFixture.explicitVRLittleEndianMR().write(
            to: fixture.source.appendingPathComponent("generated.bin")
        )

        let stagedPath = try await abandonImportAfterStaging(fixture: fixture)
        #expect(FileManager.default.fileExists(
            atPath: fixture.vaultRoot.appendingPathComponent(stagedPath).path
        ))
        #expect(try VaultDICOMImportJournal(rootURL: fixture.vaultRoot).pendingOperationCount() == 1)

        let reopened = try PlaintextVault(rootURL: fixture.vaultRoot)
        #expect((try await reopened.loadCatalog()).dicomStudies.isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.vaultRoot.appendingPathComponent(stagedPath).path
        ))
        #expect(try VaultDICOMImportJournal(rootURL: fixture.vaultRoot).pendingOperationCount() == 0)
    }

    @Test
    func reconciliationRefusesAReplacedStagingEntryWithoutTouchingItsTarget() async throws {
        let fixture = try await WorkflowFixture()
        defer { fixture.cleanup() }
        let canary = fixture.base.appendingPathComponent("outside-canary.data")
        let canaryBytes = Data("identity-free-canary".utf8)
        try canaryBytes.write(to: canary)

        let link = try await abandonImportWithSymlink(fixture: fixture, target: canary)
        let reopened = try PlaintextVault(rootURL: fixture.vaultRoot)
        #expect((try await reopened.loadCatalog()).dicomStudies.isEmpty)
        #expect(try Data(contentsOf: canary) == canaryBytes)
        #expect(FileManager.default.fileExists(atPath: link.path))
        #expect(try VaultDICOMImportJournal(rootURL: fixture.vaultRoot).pendingOperationCount() == 1)
    }

    @Test
    func unresolvedReconciliationBlocksAnotherImportWithoutAccumulatingReceipts() async throws {
        let fixture = try await WorkflowFixture()
        defer { fixture.cleanup() }
        let canary = fixture.base.appendingPathComponent("outside-canary.data")
        try Data("identity-free-canary".utf8).write(to: canary)
        _ = try await abandonImportWithSymlink(fixture: fixture, target: canary)
        try GeneratedDICOMFixture.explicitVRLittleEndianMR().write(
            to: fixture.source.appendingPathComponent("generated.bin")
        )
        let workflow = try DICOMImportWorkflow(
            rootURL: fixture.vaultRoot,
            vault: fixture.vault,
            decoder: RepeatingFrameDecoder(frame: fixture.frame())
        )

        await #expect(throws: DICOMImportError.integrityFailure) {
            _ = try await workflow.importDirectory(
                fixture.source,
                securityScope: .notRequiredForTesting
            )
        }
        #expect((try await fixture.vault.loadCatalog()).dicomStudies.isEmpty)
        #expect(try VaultDICOMImportJournal(rootURL: fixture.vaultRoot).pendingOperationCount() == 1)
    }

    @Test
    func insufficientCapacityFailsBeforePublicationAndLeavesNoOwnedStaging() async throws {
        let fixture = try await WorkflowFixture()
        defer { fixture.cleanup() }
        try GeneratedDICOMFixture.explicitVRLittleEndianMR().write(
            to: fixture.source.appendingPathComponent("generated.bin")
        )
        let policy = try DICOMImportPolicy(
            maximumTraversalDepth: 16,
            maximumDirectoryEntries: 10_000,
            maximumDICOMObjectCount: 2_000,
            maximumUniqueSourceBytes: 2 * 1_024 * 1_024 * 1_024,
            maximumObjectBytes: 100 * 1_024 * 1_024,
            maximumRows: 8_192,
            maximumColumns: 8_192,
            maximumDecodedSampleBytes: 128 * 1_024 * 1_024,
            maximumWorkers: 2,
            maximumSourceAndStagingDescriptors: 8,
            requiredFreeSpaceHeadroom: Int.max / 2
        )
        let workflow = try DICOMImportWorkflow(
            rootURL: fixture.vaultRoot,
            vault: fixture.vault,
            decoder: RepeatingFrameDecoder(frame: fixture.frame()),
            policy: policy
        )

        await #expect(throws: DICOMImportError.insufficientCapacity) {
            _ = try await workflow.importDirectory(
                fixture.source,
                securityScope: .notRequiredForTesting
            )
        }
        #expect((try await fixture.vault.loadCatalog()).dicomStudies.isEmpty)
        #expect(try VaultDICOMImportJournal(rootURL: fixture.vaultRoot).pendingOperationCount() == 0)
    }

    @Test
    func stagedBytesAreCreditedAgainstTheFinalCapacityReservation() async throws {
        let fixture = try await WorkflowFixture()
        defer { fixture.cleanup() }
        let sourceData = GeneratedDICOMFixture.explicitVRLittleEndianMR()
        try sourceData.write(to: fixture.source.appendingPathComponent("generated.bin"))
        let headroom = 4_096
        let policy = try DICOMImportPolicy(
            maximumTraversalDepth: 16,
            maximumDirectoryEntries: 10_000,
            maximumDICOMObjectCount: 2_000,
            maximumUniqueSourceBytes: 2 * 1_024 * 1_024 * 1_024,
            maximumObjectBytes: 100 * 1_024 * 1_024,
            maximumRows: 8_192,
            maximumColumns: 8_192,
            maximumDecodedSampleBytes: 128 * 1_024 * 1_024,
            maximumWorkers: 2,
            maximumSourceAndStagingDescriptors: 8,
            requiredFreeSpaceHeadroom: headroom
        )
        let capacity = CapacitySequence(values: [
            Int64(2 * sourceData.count + headroom),
            Int64(sourceData.count + headroom),
        ])
        let workflow = try DICOMImportWorkflow(
            rootURL: fixture.vaultRoot,
            vault: fixture.vault,
            decoder: RepeatingFrameDecoder(frame: fixture.frame()),
            policy: policy,
            metrics: nil,
            scannerControl: nil,
            availableCapacityProvider: { _ in try capacity.next() }
        )

        let result = try await workflow.importDirectory(
            fixture.source,
            securityScope: .notRequiredForTesting
        )

        #expect(result.viewableInstanceCount == 1)
        #expect(capacity.callCount == 2)
        #expect((try await fixture.vault.loadCatalog()).dicomStudies.map(\.id) == [result.studyID])
    }

    @Test
    func cancellationWaitsForAnIrreversibleManifestCommitAndReturnsTheStudy() async throws {
        let gate = SynchronousTransactionGate(point: .afterManifestCommit)
        let fixture = try await WorkflowFixture(
            transactionFailureInjector: { point in gate.handle(point) }
        )
        defer {
            gate.release()
            fixture.cleanup()
        }
        try GeneratedDICOMFixture.explicitVRLittleEndianMR().write(
            to: fixture.source.appendingPathComponent("generated.bin")
        )
        let workflow = try DICOMImportWorkflow(
            rootURL: fixture.vaultRoot,
            vault: fixture.vault,
            decoder: RepeatingFrameDecoder(frame: fixture.frame())
        )
        let importTask = Task {
            try await workflow.importDirectory(
                fixture.source,
                securityScope: .notRequiredForTesting
            )
        }
        try await gate.waitUntilEntered()

        let cancellation = Task { try await workflow.cancelCurrentImport() }
        while await workflow.state != .cancelling { await Task.yield() }
        #expect(await workflow.state == .cancelling)

        gate.release()
        let cancelledResult = try #require(try await cancellation.value)
        let importedResult = try await importTask.value

        #expect(cancelledResult == importedResult)
        #expect(await workflow.state == .completed)
        #expect((try await fixture.vault.loadCatalog()).dicomStudies.map(\.id) == [importedResult.studyID])
    }

    @Test
    func cancellationRecoversSuccessWhenIrreversibleManifestCommitThrows() async throws {
        let gate = SynchronousTransactionGate(
            point: .afterManifestCommit,
            shouldFail: true
        )
        let fixture = try await WorkflowFixture(
            transactionFailureInjector: { point in gate.handle(point) }
        )
        defer {
            gate.release()
            fixture.cleanup()
        }
        try GeneratedDICOMFixture.explicitVRLittleEndianMR().write(
            to: fixture.source.appendingPathComponent("generated.bin")
        )
        let workflow = try DICOMImportWorkflow(
            rootURL: fixture.vaultRoot,
            vault: fixture.vault,
            decoder: RepeatingFrameDecoder(frame: fixture.frame())
        )
        let importTask = Task {
            try await workflow.importDirectory(
                fixture.source,
                securityScope: .notRequiredForTesting
            )
        }
        try await gate.waitUntilEntered()

        let cancellation = Task { try await workflow.cancelCurrentImport() }
        while await workflow.state != .cancelling { await Task.yield() }
        let stagingOperationDirectory = try #require(
            try FileManager.default.contentsOfDirectory(
                at: fixture.vaultRoot.appendingPathComponent("dicom-import-staging"),
                includingPropertiesForKeys: nil
            ).first(where: { UUID(uuidString: $0.lastPathComponent) != nil })
        )
        let unexpectedEntry = stagingOperationDirectory.appendingPathComponent("unexpected-entry")
        try Data("synthetic-reconciliation-failure".utf8).write(to: unexpectedEntry)
        gate.release()

        let cancelledResult = try #require(try await cancellation.value)
        let importedResult = try await importTask.value

        #expect(cancelledResult == importedResult)
        #expect(await workflow.state == .completed)
        #expect((try await fixture.vault.loadCatalog()).dicomStudies.map(\.id) == [importedResult.studyID])
        #expect(try VaultDICOMImportJournal(rootURL: fixture.vaultRoot).pendingOperationCount() == 1)

        try FileManager.default.removeItem(at: unexpectedEntry)
        _ = try await fixture.vault.loadCatalog()
        #expect(try VaultDICOMImportJournal(rootURL: fixture.vaultRoot).pendingOperationCount() == 0)
    }

    @Test
    func transactionGateTimesOutWhenTheFaultPointIsNeverReached() async {
        let gate = SynchronousTransactionGate(
            point: .afterManifestCommit,
            waitTimeout: .milliseconds(20)
        )
        defer { gate.release() }

        await #expect(throws: SynchronousTransactionGateError.self) {
            try await gate.waitUntilEntered()
        }
    }

    @Test
    func committedGraphRecoveryAllowsConfirmationButRejectsDifferentObjects() throws {
        let studyID = UUID()
        let indexObjectID = UUID()
        let attachmentID = UUID()
        let fingerprint = try DICOMStudyFingerprint(objects: [
            DICOMStudyFingerprint.ObjectDigest(
                sha256Digest: Data(repeating: 0x41, count: 32),
                byteCount: 128
            ),
        ])
        let proposal = try DICOMStudy(
            id: studyID,
            state: .needsReview,
            fingerprint: fingerprint,
            indexObjectID: indexObjectID,
            attachmentIDs: [attachmentID]
        )
        let confirmed = try DICOMStudy(
            id: studyID,
            state: .confirmed,
            fingerprint: fingerprint,
            indexObjectID: indexObjectID,
            attachmentIDs: [attachmentID],
            confirmedMemberID: UUID(),
            effectiveDate: Date(timeIntervalSince1970: 1_785_566_400)
        )
        let differentGraph = try DICOMStudy(
            id: studyID,
            state: .needsReview,
            fingerprint: fingerprint,
            indexObjectID: UUID(),
            attachmentIDs: [attachmentID]
        )

        #expect(DICOMImportWorkflow.matchesCommittedGraph(confirmed, proposal: proposal))
        #expect(!DICOMImportWorkflow.matchesCommittedGraph(differentGraph, proposal: proposal))
    }

    @Test
    func multiHundredFileImportStaysInsideFrozenExecutionAndIOBudgets() async throws {
        let fixture = try await WorkflowFixture()
        defer { fixture.cleanup() }
        let objectCount = 220
        var uniqueBytes = 0
        for ordinal in 0..<objectCount {
            let data = GeneratedDICOMFixture.explicitVRLittleEndianMR(
                sopInstanceUID: "2.25.88\(10_000 + ordinal)"
            )
            uniqueBytes += data.count
            try data.write(to: fixture.source.appendingPathComponent("generated-\(ordinal).bin"))
        }
        let metrics = DICOMImportMetricsRecorder()
        let control = TwoWorkerBarrierControl()
        let workflow = try DICOMImportWorkflow(
            rootURL: fixture.vaultRoot,
            vault: fixture.vault,
            decoder: EchoingFrameDecoder(),
            metrics: metrics,
            scannerControl: control
        )

        let result = try await workflow.importDirectory(
            fixture.source,
            securityScope: .notRequiredForTesting
        )
        let snapshot = await metrics.snapshot()

        #expect(result.viewableInstanceCount == objectCount)
        #expect(snapshot.uniqueObjectCount == objectCount)
        #expect(snapshot.maximumConcurrentWorkers == 2)
        #expect(snapshot.maximumQueueDepth == 2)
        #expect(snapshot.maximumLiveSourceDescriptors <= 8)
        #expect(snapshot.maximumLiveSourceAndStagingDescriptors <= 8)
        #expect(snapshot.liveSourceAndStagingDescriptorCount == 0)
        #expect(snapshot.liveWorkerCount == 0)
        #expect(snapshot.sourceBytesRead == uniqueBytes)
        #expect(snapshot.stagingBytesWritten == uniqueBytes)
        #expect(snapshot.maximumManagedFullReadsPerObject <= 3)
        #expect(snapshot.maximumWritesPerObject <= 2)
        #expect(snapshot.managedFullReadBytes <= uniqueBytes * 3)
        #expect(snapshot.promotedAttachmentBytes == uniqueBytes)
        #expect(snapshot.peakAddedDiskBytes <= uniqueBytes * 2 + 256 * 1_024 * 1_024)
    }

    @Test
    func cancellingAQueuedMultiHundredFileImportStopsWithinOneSecond() async throws {
        let fixture = try await WorkflowFixture()
        defer { fixture.cleanup() }
        for ordinal in 0..<220 {
            try GeneratedDICOMFixture.explicitVRLittleEndianMR(
                sopInstanceUID: "2.25.99\(10_000 + ordinal)"
            ).write(to: fixture.source.appendingPathComponent("generated-\(ordinal).bin"))
        }
        let control = BlockingWorkerControl()
        let workflow = try DICOMImportWorkflow(
            rootURL: fixture.vaultRoot,
            vault: fixture.vault,
            decoder: EchoingFrameDecoder(),
            metrics: DICOMImportMetricsRecorder(),
            scannerControl: control
        )
        let task = Task {
            try await workflow.importDirectory(
                fixture.source,
                securityScope: .notRequiredForTesting
            )
        }
        while !(await control.hasStarted) { try await Task.sleep(for: .milliseconds(2)) }
        #expect(await workflow.state == .staging)

        let clock = ContinuousClock()
        let start = clock.now
        #expect(try await workflow.cancelCurrentImport() == nil)
        await #expect(throws: DICOMImportError.cancelled) { _ = try await task.value }
        let elapsed = start.duration(to: clock.now)

        #expect(elapsed < .seconds(1))
        #expect(await workflow.state == .cancelled)
        #expect((try await fixture.vault.loadCatalog()).dicomStudies.isEmpty)
    }
}

private func abandonImportAfterStaging(fixture: WorkflowFixture) async throws -> String {
    let operationID = UUID()
    let staging = try VaultDICOMStudyStaging(rootURL: fixture.vaultRoot)
    let session = try await fixture.vault.beginDICOMImport(
        operationID: operationID,
        staging: staging
    )
    let scan = try await DICOMFolderScanner().scan(
        directoryURL: fixture.source,
        operationID: operationID,
        securityScope: .notRequiredForTesting,
        staging: staging,
        ownership: session.stagingOwnership
    )
    _ = session.vaultID
    return try #require(scan.stagedObjects.first).relativePath
}

private func abandonImportWithSymlink(
    fixture: WorkflowFixture,
    target: URL
) async throws -> URL {
    let operationID = UUID()
    let staging = try VaultDICOMStudyStaging(rootURL: fixture.vaultRoot)
    let session = try await fixture.vault.beginDICOMImport(
        operationID: operationID,
        staging: staging
    )
    let link = fixture.vaultRoot.appendingPathComponent(
        "dicom-import-staging/\(operationID.uuidString.lowercased())/\(UUID().uuidString.lowercased()).data"
    )
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    _ = session.vaultID
    return link
}

private struct WorkflowFixture {
    let base: URL
    let source: URL
    let vaultRoot: URL
    let vault: PlaintextVault

    init(
        transactionFault: PlaintextVaultTransactionFault? = nil,
        transactionFailureInjector: (@Sendable (PlaintextVaultTransactionFault) -> Bool)? = nil
    ) async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        source = base.appendingPathComponent("source", isDirectory: true)
        vaultRoot = base.appendingPathComponent("vault", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let failureInjector: (@Sendable (PlaintextVaultTransactionFault) -> Bool)?
        if let transactionFailureInjector {
            failureInjector = transactionFailureInjector
        } else if let transactionFault {
            failureInjector = { $0 == transactionFault }
        } else {
            failureInjector = nil
        }
        vault = try PlaintextVault(
            rootURL: vaultRoot,
            transactionFailureInjector: failureInjector
        )
        _ = try await vault.initialize()
    }

    func frame() -> KinlogueDICOMDecodedFrame {
        KinlogueDICOMDecodedFrame(
            transferSyntaxUID: KinlogueDICOMSupportedObject.explicitVRLittleEndian,
            sopClassUID: KinlogueDICOMSupportedObject.mrImageStorage,
            studyInstanceUID: "2.25.8822", seriesInstanceUID: "2.25.8823",
            sopInstanceUID: "2.25.8824", modality: "MR", instanceNumber: 1,
            rows: 2, columns: 2, samplesPerPixel: 1, bitsAllocated: 16,
            bitsStored: 12, highBit: 11, pixelRepresentation: 0,
            photometricInterpretation: "MONOCHROME2", numberOfFrames: 1,
            imagePositionPatient: [0, 0, 0], imageOrientationPatient: [1, 0, 0, 0, 1, 0],
            windowCenter: 128, windowWidth: 256, rescaleIntercept: 0,
            rescaleSlope: 1, sampleBytes: Data([0, 0, 64, 0, 128, 0, 255, 0])
        )
    }

    func cleanup() { try? FileManager.default.removeItem(at: base) }
}

private final class CapacitySequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int64]
    private var recordedCallCount = 0

    init(values: [Int64]) { self.values = values }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedCallCount
    }

    func next() throws -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        guard !values.isEmpty else { throw DICOMImportError.insufficientCapacity }
        recordedCallCount += 1
        return values.removeFirst()
    }
}

private final class SynchronousTransactionGate: @unchecked Sendable {
    private let condition = NSCondition()
    private let point: PlaintextVaultTransactionFault
    private let shouldFail: Bool
    private let waitTimeout: Duration
    private let entryEvents: AsyncStream<Void>
    private let entryContinuation: AsyncStream<Void>.Continuation
    private var entered = false
    private var isReleased = false

    init(
        point: PlaintextVaultTransactionFault,
        shouldFail: Bool = false,
        waitTimeout: Duration = .seconds(30)
    ) {
        let (entryEvents, entryContinuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.point = point
        self.shouldFail = shouldFail
        self.waitTimeout = waitTimeout
        self.entryEvents = entryEvents
        self.entryContinuation = entryContinuation
    }

    func handle(_ point: PlaintextVaultTransactionFault) -> Bool {
        guard point == self.point else { return false }
        condition.lock()
        entered = true
        condition.broadcast()
        condition.unlock()
        entryContinuation.yield(())

        condition.lock()
        while !isReleased { condition.wait() }
        condition.unlock()
        return shouldFail
    }

    func waitUntilEntered() async throws {
        guard !hasEntered else { return }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [entryEvents] in
                var iterator = entryEvents.makeAsyncIterator()
                guard await iterator.next() != nil else { throw CancellationError() }
            }
            group.addTask { [waitTimeout] in
                try await Task.sleep(for: waitTimeout)
                throw SynchronousTransactionGateError.timedOut
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    func release() {
        condition.lock()
        isReleased = true
        condition.broadcast()
        condition.unlock()
        entryContinuation.finish()
    }

    private var hasEntered: Bool {
        condition.lock()
        defer { condition.unlock() }
        return entered
    }
}

private enum SynchronousTransactionGateError: Error {
    case timedOut
}

private actor RepeatingFrameDecoder: DICOMFrameDecoding {
    let frame: KinlogueDICOMDecodedFrame
    init(frame: KinlogueDICOMDecodedFrame) { self.frame = frame }
    func decode(descriptor: FileHandle, declaredByteCount: Int) async throws -> KinlogueDICOMDecodedFrame { frame }
}

private actor SuspendingFrameDecoder: DICOMFrameDecoding {
    let frame: KinlogueDICOMDecodedFrame
    private(set) var callCount = 0
    init(frame: KinlogueDICOMDecodedFrame) { self.frame = frame }
    func decode(descriptor: FileHandle, declaredByteCount: Int) async throws -> KinlogueDICOMDecodedFrame {
        callCount += 1
        try await Task.sleep(for: .seconds(30))
        return frame
    }
}

private actor TwoWorkerBarrierControl: DICOMFolderScannerControl {
    private var started = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func sourceAdmitted(ordinal: Int) async throws {}

    func workerStarted() async throws {
        started += 1
        if started >= 2 {
            let pending = waiters
            waiters.removeAll()
            pending.forEach { $0.resume() }
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private actor BlockingWorkerControl: DICOMFolderScannerControl {
    private(set) var hasStarted = false
    func sourceAdmitted(ordinal: Int) async throws {}
    func workerStarted() async throws {
        hasStarted = true
        try await Task.sleep(for: .seconds(30))
    }
}

private actor EchoingFrameDecoder: DICOMFrameDecoding {
    func decode(
        descriptor: FileHandle,
        declaredByteCount: Int
    ) async throws -> KinlogueDICOMDecodedFrame {
        try descriptor.seek(toOffset: 0)
        let data = try descriptor.readToEnd() ?? Data()
        try descriptor.seek(toOffset: 0)
        guard data.count == declaredByteCount,
              let study = explicitVRString(data, group: 0x0020, element: 0x000d),
              let series = explicitVRString(data, group: 0x0020, element: 0x000e),
              let instance = explicitVRString(data, group: 0x0008, element: 0x0018) else {
            throw DICOMDecoderAdapterError.decoderFailed
        }
        return KinlogueDICOMDecodedFrame(
            transferSyntaxUID: KinlogueDICOMSupportedObject.explicitVRLittleEndian,
            sopClassUID: KinlogueDICOMSupportedObject.mrImageStorage,
            studyInstanceUID: study,
            seriesInstanceUID: series,
            sopInstanceUID: instance,
            modality: "MR",
            instanceNumber: nil,
            rows: 2,
            columns: 2,
            samplesPerPixel: 1,
            bitsAllocated: 16,
            bitsStored: 12,
            highBit: 11,
            pixelRepresentation: 0,
            photometricInterpretation: "MONOCHROME2",
            numberOfFrames: 1,
            imagePositionPatient: nil,
            imageOrientationPatient: nil,
            windowCenter: 128,
            windowWidth: 256,
            rescaleIntercept: 0,
            rescaleSlope: 1,
            sampleBytes: Data([0, 0, 64, 0, 128, 0, 255, 0])
        )
    }

    private func explicitVRString(_ data: Data, group: UInt16, element: UInt16) -> String? {
        let needle: [UInt8] = [
            UInt8(group & 0xff), UInt8(group >> 8),
            UInt8(element & 0xff), UInt8(element >> 8),
        ]
        guard data.count >= 8 else { return nil }
        for offset in 0...(data.count - 8) where data[offset..<(offset + 4)].elementsEqual(needle) {
            let length = Int(data[offset + 6]) | Int(data[offset + 7]) << 8
            guard length >= 0, offset + 8 <= data.count - length else { return nil }
            return String(decoding: data[(offset + 8)..<(offset + 8 + length)], as: UTF8.self)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0 "))
        }
        return nil
    }
}
