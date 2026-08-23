import Foundation
import KinlogueDICOMIPC
import KinlogueDICOMTestSupport
import Testing
@testable import KinlogueApp
@testable import KinlogueCore
@testable import KinloguePlatform

@MainActor
struct LiveDICOMAppServiceIntegrationTests {
    @Test
    func cancellationAfterManifestCommitWaitsForProjectionAndReportsSuccess() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kinlogue-app-dicom-cancel-after-commit-\(UUID().uuidString)",
            isDirectory: true
        )
        let root = base.appendingPathComponent("Vault", isDirectory: true)
        let source = base.appendingPathComponent("GeneratedSource", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: base) }
        try GeneratedDICOMFixture.explicitVRLittleEndianMR().write(
            to: source.appendingPathComponent("generated-object.dcm"),
            options: .atomic
        )
        let vault = try PlaintextVault(rootURL: root)
        _ = try await vault.initialize()
        let catalogLoadGate = AsyncOperationGate()
        let gatedVault = CatalogLoadGatedVault(underlying: vault, gate: catalogLoadGate)
        let draftStore = VaultImportDraftStore(vault: vault)
        let dicomWorkflow = try DICOMImportWorkflow(
            rootURL: root,
            vault: vault,
            decoder: GeneratedAppDICOMDecoder()
        )
        let service = LiveAppService(
            vault: gatedVault,
            draftStore: draftStore,
            workflow: ImportWorkflow(
                store: draftStore,
                textExtractor: GeneratedAppTextExtractor()
            ),
            startupCompleted: true,
            dicomRuntime: DICOMAppRuntime(
                workflow: dicomWorkflow,
                securityScope: .notRequiredForTesting
            )
        )
        let model = DICOMImportModel(service: service)

        let importTask = Task {
            await model.handleImporterResult(.success([source]))
        }
        #expect(await catalogLoadGate.waitUntilStarted())
        let committedCatalog = try await vault.loadCatalog()
        #expect(committedCatalog.dicomStudies.count == 1)

        let cancelTask = Task { await model.cancel() }
        for _ in 0..<100 where model.phase != .cancelling {
            await Task.yield()
        }
        #expect(model.phase == .cancelling)
        await catalogLoadGate.open()
        await cancelTask.value
        await importTask.value

        #expect(model.phase == .succeeded)
        #expect(model.result?.studyID == committedCatalog.dicomStudies.first?.id)
        #expect(model.result?.destination == .review)
        #expect(try await gatedVault.loadCatalog().dicomStudies.count == 1)
    }

    @Test
    func generatedFolderImportsReviewsConfirmsReimportsAndDeletesThroughTheLiveService() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kinlogue-app-dicom-\(UUID().uuidString)",
            isDirectory: true
        )
        let root = base.appendingPathComponent("Vault", isDirectory: true)
        let source = base.appendingPathComponent("GeneratedSource", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: base) }

        let objectData = GeneratedDICOMFixture.explicitVRLittleEndianMR()
        try objectData.write(
            to: source.appendingPathComponent("generated-object.dcm"),
            options: .atomic
        )
        let vault = try PlaintextVault(rootURL: root)
        _ = try await vault.initialize()
        let draftStore = VaultImportDraftStore(vault: vault)
        let dicomWorkflow = try DICOMImportWorkflow(
            rootURL: root,
            vault: vault,
            decoder: GeneratedAppDICOMDecoder()
        )
        let lifecycle = LibraryLifecycleCoordinator()
        let service = LiveAppService(
            vault: vault,
            draftStore: draftStore,
            workflow: ImportWorkflow(
                store: draftStore,
                textExtractor: GeneratedAppTextExtractor()
            ),
            startupCompleted: true,
            dicomRuntime: DICOMAppRuntime(
                workflow: dicomWorkflow,
                lifecycle: lifecycle,
                securityScope: .notRequiredForTesting
            )
        )
        let memberSnapshot = try await service.createMember(
            displayName: "Synthetic imaging integration member",
            disambiguationLabel: nil
        )
        let member = try #require(memberSnapshot.members.first)

        let imported = try await service.importDICOMDirectory(at: source)

        #expect(imported.destination == .review)
        #expect(!imported.wasExisting)
        #expect(imported.viewableInstanceCount == 1)
        #expect(imported.inertObjectCount == 0)
        let pending = try await service.refresh()
        #expect(pending.records.isEmpty)
        #expect(pending.drafts.isEmpty)
        #expect(pending.dicomStudies.map(\.state) == [.needsReview])

        let review = try await service.loadDICOMStudyReview(studyID: imported.studyID)
        #expect(review.viewableInstanceCount == 1)
        #expect(review.seriesCount == 1)
        #expect(review.selectableMembers.map(\.id) == [member.id])
        let viewer = try await service.loadDICOMStudyViewer(studyID: imported.studyID)
        #expect(viewer.study == review.study)
        #expect(viewer.series == review.viewerContent.series)
        #expect(viewer.confirmedMemberLabel == nil)

        let confirmation = SaveDICOMStudyCommand(
            studyID: imported.studyID,
            memberID: member.id,
            effectiveDate: Date(timeIntervalSince1970: 1_785_566_400)
        )
        let confirmed = try await service.saveDICOMStudy(confirmation)
        #expect(confirmed.dicomStudies.map(\.state) == [.confirmed])
        #expect(confirmed.records.isEmpty)
        #expect(confirmed.drafts.isEmpty)
        let repeatedConfirmation = try await service.saveDICOMStudy(confirmation)
        #expect(repeatedConfirmation.generation == confirmed.generation)

        let renamedMember = try FamilyMember(
            id: member.id,
            displayName: "Synthetic renamed imaging member"
        )
        let afterOrdinaryMemberEdit = try await service.updateMember(renamedMember)
        #expect(afterOrdinaryMemberEdit.members == [renamedMember])
        #expect(afterOrdinaryMemberEdit.dicomStudies.map(\.id) == [imported.studyID])

        let reportBytes = Data("synthetic-report-after-dicom-confirmation".utf8)
        let reportFile = try ValidatedImportedFile(
            data: reportBytes,
            kind: .image,
            contentTypeIdentifier: "public.png",
            sha256Digest: ContentDigest.sha256(reportBytes)
        )
        guard case .created(let reportDraftID) = try await draftStore.stage(reportFile) else {
            Issue.record("Expected a report draft after confirming the DICOM study")
            return
        }
        let afterReportStage = try await service.refresh()
        try #require(afterReportStage.dicomStudies.map(\.id) == [imported.studyID])
        let reportDraft = try #require(
            try await vault.loadCatalog().importDrafts.first { $0.id == reportDraftID }
        )
        let afterReportDiscard = try await draftStore.discard(
            draftID: reportDraftID,
            expectedRevision: reportDraft.revision
        )
        #expect(afterReportDiscard.dicomStudies.map(\.id) == [imported.studyID])
        #expect(try await service.loadDICOMStudyViewer(studyID: imported.studyID).study.id == imported.studyID)

        let duplicate = try await service.importDICOMDirectory(at: source)
        #expect(duplicate.studyID == imported.studyID)
        #expect(duplicate.wasExisting)
        #expect(duplicate.destination == .library)

        await #expect(throws: AppServiceError.memberStillReferencedByDICOMStudy(studyCount: 1)) {
            try await service.deleteMember(id: member.id)
        }
        let afterStudyDeletion = try await service.deleteDICOMStudy(id: imported.studyID)
        #expect(afterStudyDeletion.dicomStudies.isEmpty)
        let afterMemberDeletion = try await service.deleteMember(id: member.id)
        #expect(afterMemberDeletion.members.isEmpty)
        #expect(afterMemberDeletion.records.isEmpty)
        #expect(afterMemberDeletion.drafts.isEmpty)

        await lifecycle.revoke()
        await #expect(throws: LibraryLifecycleCoordinatorError.revoked) {
            try await service.importDICOMDirectory(at: source)
        }
        await #expect(throws: LibraryLifecycleCoordinatorError.revoked) {
            try await service.loadDICOMStudyReview(studyID: imported.studyID)
        }
        await #expect(throws: LibraryLifecycleCoordinatorError.revoked) {
            try await service.saveDICOMStudy(SaveDICOMStudyCommand(
                studyID: imported.studyID,
                memberID: member.id,
                effectiveDate: Date(timeIntervalSince1970: 1_785_566_400)
            ))
        }
        await #expect(throws: LibraryLifecycleCoordinatorError.revoked) {
            try await service.deleteDICOMStudy(id: imported.studyID)
        }
    }

    @Test
    func cancellationDuringCatalogProjectionReturnsTheSameCommittedOutcome() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kinlogue-app-dicom-cancel-projection-\(UUID().uuidString)",
            isDirectory: true
        )
        let root = base.appendingPathComponent("Vault", isDirectory: true)
        let source = base.appendingPathComponent("GeneratedSource", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: base) }

        try GeneratedDICOMFixture.explicitVRLittleEndianMR().write(
            to: source.appendingPathComponent("generated-object.dcm"),
            options: .atomic
        )
        let vault = try PlaintextVault(rootURL: root)
        _ = try await vault.initialize()
        let projectedVault = DICOMOutcomeProjectionVault(underlying: vault)
        let draftStore = VaultImportDraftStore(vault: vault)
        let workflow = try DICOMImportWorkflow(
            rootURL: root,
            vault: vault,
            decoder: GeneratedAppDICOMDecoder()
        )
        let service = LiveAppService(
            vault: projectedVault,
            draftStore: draftStore,
            workflow: ImportWorkflow(
                store: draftStore,
                textExtractor: GeneratedAppTextExtractor()
            ),
            startupCompleted: true,
            dicomRuntime: DICOMAppRuntime(
                workflow: workflow,
                lifecycle: nil,
                securityScope: .notRequiredForTesting
            )
        )
        let gate = DICOMOutcomeProjectionGate()
        await projectedVault.gateNextCatalogLoad(with: gate)

        let importing = Task { try await service.importDICOMDirectory(at: source) }
        await gate.waitUntilStarted()
        let cancelling = Task { try await service.cancelDICOMImport() }
        #expect(await service.waitUntilCurrentDICOMImportCancellationClaimedForTesting())
        await gate.open()

        let imported = try await importing.value
        let cancelled = try #require(try await cancelling.value)
        #expect(cancelled == imported)
        #expect(imported.destination == .review)
    }

    @Test
    func cancellationAfterImportCallReturnsStillObservesTheCommittedOutcome() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kinlogue-app-dicom-late-cancel-\(UUID().uuidString)",
            isDirectory: true
        )
        let root = base.appendingPathComponent("Vault", isDirectory: true)
        let source = base.appendingPathComponent("GeneratedSource", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: base) }

        try GeneratedDICOMFixture.explicitVRLittleEndianMR().write(
            to: source.appendingPathComponent("generated-object.dcm"),
            options: .atomic
        )
        let vault = try PlaintextVault(rootURL: root)
        _ = try await vault.initialize()
        let draftStore = VaultImportDraftStore(vault: vault)
        let workflow = try DICOMImportWorkflow(
            rootURL: root,
            vault: vault,
            decoder: GeneratedAppDICOMDecoder()
        )
        let service = LiveAppService(
            vault: vault,
            draftStore: draftStore,
            workflow: ImportWorkflow(
                store: draftStore,
                textExtractor: GeneratedAppTextExtractor()
            ),
            startupCompleted: true,
            dicomRuntime: DICOMAppRuntime(
                workflow: workflow,
                lifecycle: nil,
                securityScope: .notRequiredForTesting
            )
        )

        let imported = try await service.importDICOMDirectory(at: source)
        let cancelled = try #require(try await service.cancelDICOMImport())

        #expect(cancelled == imported)
        #expect(imported.destination == .review)
        #expect(try await service.cancelDICOMImport() == nil)
    }
}

private actor DICOMOutcomeProjectionVault: VaultStore {
    private let underlying: PlaintextVault
    private var nextLoadGate: DICOMOutcomeProjectionGate?

    init(underlying: PlaintextVault) {
        self.underlying = underlying
    }

    func gateNextCatalogLoad(with gate: DICOMOutcomeProjectionGate) {
        nextLoadGate = gate
    }

    func inspect() async -> VaultAccessState { await underlying.inspect() }
    func loadValidatedCatalog() async throws -> VaultCatalog {
        try await underlying.loadValidatedCatalog()
    }
    func initialize() async throws -> VaultCatalog { try await underlying.initialize() }

    func loadCatalog() async throws -> VaultCatalog {
        if let gate = nextLoadGate {
            nextLoadGate = nil
            await gate.wait()
        }
        return try await underlying.loadCatalog()
    }

    func readObject(_ reference: VaultObjectReference) async throws -> Data {
        try await underlying.readObject(reference)
    }

    func readSnapshot(
        selecting references: @Sendable (VaultCatalog) throws -> [VaultObjectReference]
    ) async throws -> VaultReadSnapshot {
        try await underlying.readSnapshot(selecting: references)
    }

    func commit(_ request: VaultCommitRequest) async throws -> VaultCatalog {
        try await underlying.commit(request)
    }

    func destroy() async throws { try await underlying.destroy() }
}

private actor DICOMOutcomeProjectionGate {
    private var started = false
    private var isOpen = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !isOpen else { return }
        await withCheckedContinuation { openWaiters.append($0) }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func open() {
        isOpen = true
        let waiters = openWaiters
        openWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor CatalogLoadGatedVault: VaultStore {
    let underlying: PlaintextVault
    let gate: AsyncOperationGate

    init(underlying: PlaintextVault, gate: AsyncOperationGate) {
        self.underlying = underlying
        self.gate = gate
    }

    func inspect() async -> VaultAccessState {
        await underlying.inspect()
    }

    func loadValidatedCatalog() async throws -> VaultCatalog {
        try await underlying.loadValidatedCatalog()
    }

    func initialize() async throws -> VaultCatalog {
        try await underlying.initialize()
    }

    func loadCatalog() async throws -> VaultCatalog {
        await gate.wait()
        return try await underlying.loadCatalog()
    }

    func readObject(_ reference: VaultObjectReference) async throws -> Data {
        try await underlying.readObject(reference)
    }

    func readSnapshot(
        selecting references: @Sendable (VaultCatalog) throws -> [VaultObjectReference]
    ) async throws -> VaultReadSnapshot {
        try await underlying.readSnapshot(selecting: references)
    }

    func commit(_ request: VaultCommitRequest) async throws -> VaultCatalog {
        try await underlying.commit(request)
    }

    func destroy() async throws {
        try await underlying.destroy()
    }
}

private actor GeneratedAppDICOMDecoder: DICOMFrameDecoding {
    func decode(
        descriptor: FileHandle,
        declaredByteCount: Int
    ) async throws -> KinlogueDICOMDecodedFrame {
        let data = try descriptor.readToEnd() ?? Data()
        guard data.count == declaredByteCount else {
            throw DICOMDecoderAdapterError.invalidResponse
        }
        return KinlogueDICOMDecodedFrame(
            transferSyntaxUID: KinlogueDICOMSupportedObject.explicitVRLittleEndian,
            sopClassUID: KinlogueDICOMSupportedObject.mrImageStorage,
            studyInstanceUID: "2.25.8822",
            seriesInstanceUID: "2.25.8823",
            sopInstanceUID: "2.25.8824",
            modality: KinlogueDICOMSupportedObject.modality,
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
}

private actor GeneratedAppTextExtractor: TextExtractionService {
    func extractText(from file: ValidatedImportedFile) async throws -> [OCRBlock] {
        throw AppServiceError.importFailed
    }
}
