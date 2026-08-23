import Foundation
import KinlogueCore
import KinlogueDICOMIPC
import KinlogueDICOMTestSupport
import Testing
@testable import KinloguePlatform

struct DICOMSliceVaultIntegrationTests {
    @Test
    func verifiedVaultDescriptorDecodesOnDemandAfterSourceRemoval() async throws {
        let fixture = try await SliceVaultFixture()
        defer { fixture.cleanup() }
        let imported = try await fixture.importStudy()
        try FileManager.default.removeItem(at: fixture.source)
        let index = try await fixture.index(for: imported.studyID)
        let seriesID = try #require(index.series.first?.id)
        let service = fixture.makeService()

        let session = try await service.openSeries(
            studyID: imported.studyID,
            seriesID: seriesID
        )
        let instance = try #require(session.instances.first)
        let image = try await service.render(session: session, instanceID: instance.id)

        #expect(try image.withGrayscaleBytes { Data($0) }
            == Data([0, 64, 128, 255]))
        #expect(await fixture.decoder.callCount == 2) // import + on-demand view
        _ = try await service.render(
            session: session,
            instanceID: instance.id,
            windowCenter: 64,
            windowWidth: 128
        )
        #expect(await fixture.decoder.callCount == 2)
    }

    @Test
    func tamperedManagedObjectFailsBeforeDecoderAndExposesOnlyStableError() async throws {
        let fixture = try await SliceVaultFixture()
        defer { fixture.cleanup() }
        let imported = try await fixture.importStudy()
        let index = try await fixture.index(for: imported.studyID)
        let seriesID = try #require(index.series.first?.id)
        let service = fixture.makeService()
        let session = try await service.openSeries(
            studyID: imported.studyID,
            seriesID: seriesID
        )
        let instance = try #require(session.instances.first)
        let layout = try PlaintextVaultLayout(rootURL: fixture.vaultRoot)
        let objectURL = fixture.vaultRoot.appendingPathComponent(layout.objectPath(
            VaultObjectReference(id: instance.attachmentID, kind: .attachment)
        ))
        let handle = try FileHandle(forWritingTo: objectURL)
        try handle.seek(toOffset: UInt64(instance.objectByteCount - 1))
        try handle.write(contentsOf: Data([0xff]))
        try handle.close()

        do {
            _ = try await service.render(session: session, instanceID: instance.id)
            Issue.record("Expected integrity failure")
        } catch let error as DICOMSliceServiceError {
            #expect(error == .integrityFailure)
            #expect(String(describing: error) == "integrityFailure")
        }
        #expect(await fixture.decoder.callCount == 1)
    }

    @Test
    func catalogGenerationChangeInvalidatesOpenSeriesBeforeDecode() async throws {
        let fixture = try await SliceVaultFixture()
        defer { fixture.cleanup() }
        let imported = try await fixture.importStudy()
        let index = try await fixture.index(for: imported.studyID)
        let seriesID = try #require(index.series.first?.id)
        let service = fixture.makeService()
        let session = try await service.openSeries(
            studyID: imported.studyID,
            seriesID: seriesID
        )
        let current = try await fixture.vault.loadCatalog()
        let next = try VaultCatalog(
            vaultID: current.vaultID,
            generation: current.generation + 1,
            members: current.members + [try FamilyMember(displayName: "Synthetic Member")],
            records: current.records,
            attachments: current.attachments,
            importDrafts: current.importDrafts,
            dicomStudies: current.dicomStudies
        )
        _ = try await fixture.vault.commit(try VaultCommitRequest(
            expectedGeneration: current.generation,
            catalog: next,
            writes: []
        ))

        await #expect(throws: DICOMSliceServiceError.staleSession) {
            _ = try await service.render(
                session: session,
                instanceID: session.instances[0].id
            )
        }
        #expect(await fixture.decoder.callCount == 1)
    }

    @Test
    func catalogReplacementInvalidatesACachedLifecycleTicketWithoutAnotherDecode() async throws {
        let fixture = try await SliceVaultFixture()
        defer { fixture.cleanup() }
        let imported = try await fixture.importStudy()
        let index = try await fixture.index(for: imported.studyID)
        let seriesID = try #require(index.series.first?.id)
        let service = fixture.makeService()
        let session = try await service.openSeries(
            studyID: imported.studyID,
            seriesID: seriesID
        )
        _ = try await service.render(
            session: session,
            instanceID: session.instances[0].id
        )
        let decodeCount = await fixture.decoder.callCount

        let current = try await fixture.vault.loadCatalog()
        let next = try VaultCatalog(
            vaultID: current.vaultID,
            generation: current.generation + 1,
            members: current.members + [try FamilyMember(displayName: "Synthetic Member")],
            records: current.records,
            attachments: current.attachments,
            importDrafts: current.importDrafts,
            dicomStudies: current.dicomStudies
        )
        _ = try await fixture.vault.commit(try VaultCommitRequest(
            expectedGeneration: current.generation,
            catalog: next,
            writes: []
        ))

        await #expect(throws: DICOMSliceServiceError.staleSession) {
            _ = try await service.render(
                session: session,
                instanceID: session.instances[0].id,
                windowCenter: 64,
                windowWidth: 128
            )
        }
        #expect(await fixture.decoder.callCount == decodeCount)
    }

    @Test
    func destroyWaitsForVerifiedDescriptorDecodeAndCloseFencesItsResult() async throws {
        let fixture = try await SliceVaultFixture()
        defer { fixture.cleanup() }
        let imported = try await fixture.importStudy()
        let index = try await fixture.index(for: imported.studyID)
        let seriesID = try #require(index.series.first?.id)
        let decoder = BlockingSliceFrameDecoder()
        let service = DICOMSliceService(
            source: PlaintextVaultDICOMSliceSource(vault: fixture.vault, decoder: decoder),
            runtime: DICOMSliceRuntime()
        )
        let session = try await service.openSeries(
            studyID: imported.studyID,
            seriesID: seriesID
        )
        let render = Task {
            try await service.render(
                session: session,
                instanceID: session.instances[0].id
            )
        }
        while await decoder.callCount == 0 {
            try await Task.sleep(for: .milliseconds(2))
        }

        let coordinator = VaultMutationCoordinator.shared(for: fixture.vaultRoot)
        let destroy = Task { try await fixture.vault.destroy() }
        for _ in 0..<10_000 where coordinator.waitingCountForTesting == 0 {
            await Task.yield()
        }
        #expect(coordinator.waitingCountForTesting == 1)

        await service.close()
        #expect(coordinator.waitingCountForTesting == 1)
        await decoder.release()
        await #expect(throws: DICOMSliceServiceError.cancelled) {
            _ = try await render.value
        }
        try await destroy.value
        #expect(coordinator.waitingCountForTesting == 0)
    }

    @Test
    func destroyGenerationFencesFinalPublishAfterTheShortDecodeLeaseEnds() async throws {
        let fixture = try await SliceVaultFixture()
        defer { fixture.cleanup() }
        let imported = try await fixture.importStudy()
        let index = try await fixture.index(for: imported.studyID)
        let seriesID = try #require(index.series.first?.id)
        let decoder = BlockingSliceFrameDecoder()
        let service = DICOMSliceService(
            source: PlaintextVaultDICOMSliceSource(vault: fixture.vault, decoder: decoder),
            runtime: DICOMSliceRuntime()
        )
        let session = try await service.openSeries(
            studyID: imported.studyID,
            seriesID: seriesID
        )
        let render = Task {
            try await service.render(
                session: session,
                instanceID: session.instances[0].id
            )
        }
        while await decoder.callCount == 0 {
            try await Task.sleep(for: .milliseconds(2))
        }

        let coordinator = VaultMutationCoordinator.shared(for: fixture.vaultRoot)
        let destroy = Task { try await fixture.vault.destroy() }
        for _ in 0..<10_000 where coordinator.waitingCountForTesting == 0 {
            await Task.yield()
        }
        #expect(coordinator.waitingCountForTesting == 1)
        await decoder.release()

        await #expect(throws: DICOMSliceServiceError.staleSession) {
            _ = try await render.value
        }
        try await destroy.value
        let cache = await service.cacheSnapshotForTesting()
        let budget = await service.budgetSnapshotForTesting()
        #expect(cache.count == 0)
        #expect(budget.activeBytes == 0)
        #expect(budget.cacheBytes == 0)
        #expect(budget.renderBytes == 0)
    }
}

private struct SliceVaultFixture {
    let base: URL
    let source: URL
    let vaultRoot: URL
    let vault: PlaintextVault
    let decoder = RepeatingSliceFrameDecoder()

    init() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        source = base.appendingPathComponent("source", isDirectory: true)
        vaultRoot = base.appendingPathComponent("vault", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try GeneratedDICOMFixture.explicitVRLittleEndianMR().write(
            to: source.appendingPathComponent("generated.data")
        )
        vault = try PlaintextVault(rootURL: vaultRoot)
        _ = try await vault.initialize()
    }

    func importStudy() async throws -> DICOMImportResult {
        try await DICOMImportWorkflow(
            rootURL: vaultRoot,
            vault: vault,
            decoder: decoder
        ).importDirectory(source, securityScope: .notRequiredForTesting)
    }

    func index(for studyID: UUID) async throws -> DICOMStudyIndex {
        let catalog = try await vault.loadCatalog()
        let study = try #require(catalog.dicomStudies.first(where: { $0.id == studyID }))
        let data = try await vault.readObject(.init(id: study.indexObjectID, kind: .record))
        return try CanonicalVaultJSON.decode(DICOMStudyIndex.self, from: data)
    }

    func makeService() -> DICOMSliceService {
        DICOMSliceService(
            source: PlaintextVaultDICOMSliceSource(vault: vault, decoder: decoder),
            runtime: DICOMSliceRuntime()
        )
    }

    func cleanup() { try? FileManager.default.removeItem(at: base) }
}

private actor RepeatingSliceFrameDecoder: DICOMFrameDecoding {
    private(set) var callCount = 0

    func decode(
        descriptor: FileHandle,
        declaredByteCount: Int
    ) async throws -> KinlogueDICOMDecodedFrame {
        callCount += 1
        return syntheticSliceFrame()
    }
}

private actor BlockingSliceFrameDecoder: DICOMFrameDecoding {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var callCount = 0

    func decode(
        descriptor: FileHandle,
        declaredByteCount: Int
    ) async throws -> KinlogueDICOMDecodedFrame {
        callCount += 1
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        return syntheticSliceFrame()
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private func syntheticSliceFrame() -> KinlogueDICOMDecodedFrame {
    KinlogueDICOMDecodedFrame(
        transferSyntaxUID: KinlogueDICOMSupportedObject.explicitVRLittleEndian,
        sopClassUID: KinlogueDICOMSupportedObject.mrImageStorage,
        studyInstanceUID: "2.25.8822",
        seriesInstanceUID: "2.25.8823",
        sopInstanceUID: "2.25.8824",
        modality: "MR",
        instanceNumber: 1,
        rows: 2,
        columns: 2,
        samplesPerPixel: 1,
        bitsAllocated: 16,
        bitsStored: 12,
        highBit: 11,
        pixelRepresentation: 0,
        photometricInterpretation: "MONOCHROME2",
        numberOfFrames: 1,
        imagePositionPatient: [0, 0, 0],
        imageOrientationPatient: [1, 0, 0, 0, 1, 0],
        windowCenter: 128,
        windowWidth: 256,
        rescaleIntercept: 0,
        rescaleSlope: 1,
        sampleBytes: Data([0, 0, 64, 0, 128, 0, 255, 0])
    )
}
