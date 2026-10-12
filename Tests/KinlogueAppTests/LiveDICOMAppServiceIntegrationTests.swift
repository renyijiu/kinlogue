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
    func sqliteViewerSurvivesUnrelatedReportCommitAndRevokesForItsStudyAndClosedLibrary() async throws {
        let fixture = try SQLiteAppQueryFixture()
        defer { fixture.destroy() }
        let source = fixture.base.appendingPathComponent("GeneratedSource")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try GeneratedDICOMFixture.explicitVRLittleEndianMR().write(to: source.appendingPathComponent("synthetic.dcm"))
        let workflow = try DICOMImportWorkflow(repository: fixture.studies, decoder: GeneratedAppDICOMDecoder())
        let service = LiveAppService(reports: fixture.reports, studies: fixture.studies, draftStore: fixture.reports,
            workflow: ImportWorkflow(store: fixture.reports, textExtractor: GeneratedAppTextExtractor()),
            dicomRuntime: DICOMAppRuntime(workflow: workflow, securityScope: .notRequiredForTesting))
        _ = try await service.bootstrap()
        let imported = try await service.importDICOMDirectory(at: source)
        let model = AppModel(service: service, dicomService: service,
            dicomSliceServiceFactory: { DICOMSliceService(repository: fixture.studies, decoder: GeneratedAppDICOMDecoder()) })
        await model.start()
        let viewer = model.makeDICOMStudyViewerModel(studyID: imported.studyID)
        viewer.activateWindow(onDismiss: {})
        await viewer.load()
        #expect(viewer.phase == .ready && viewer.image != nil)
        let member = try FamilyMember(displayName: "Synthetic viewer member")
        try await fixture.reports.saveMember(member, replacing: nil)
        _ = try await fixture.confirmed(member: member, seed: "unrelated report")
        await model.refresh()
        #expect(viewer.phase == .ready && viewer.image != nil)
        _ = try await service.saveDICOMStudy(SaveDICOMStudyCommand(studyID: imported.studyID,
            expectedRevision: 0, memberID: member.id, effectiveDate: Date(timeIntervalSince1970: 100)))
        await model.refresh()
        #expect(viewer.phase == .closed && viewer.image == nil)
        let reopened = model.makeDICOMStudyViewerModel(studyID: imported.studyID)
        reopened.activateWindow(onDismiss: {})
        await reopened.load()
        #expect(reopened.phase == .ready)
        try fixture.store.close()
        await reopened.selectSeries(try #require(reopened.selectedSeriesID))
        for _ in 0..<200 {
            if model.phase == .locked, reopened.phase == .closed { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(model.phase == .locked)
        #expect(reopened.phase == .closed && reopened.image == nil)
    }

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
        let memberID = try #require(memberSnapshot.members.first?.id)
        let member = try await service.loadMember(id: memberID)

        let imported = try await service.importDICOMDirectory(at: source)

        #expect(imported.destination == .review)
        #expect(!imported.wasExisting)
        #expect(imported.viewableInstanceCount == 1)
        #expect(imported.inertObjectCount == 0)
        let pending = try await service.refresh()
        #expect(pending.reportCount == 0)
        #expect(pending.draftCount == 0)
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
            expectedRevision: review.study.contentRevision,
            memberID: member.id,
            effectiveDate: Date(timeIntervalSince1970: 1_785_566_400)
        )
        let confirmed = try await service.saveDICOMStudy(confirmation)
        #expect(confirmed.dicomStudies.map(\.state) == [.confirmed])
        #expect(confirmed.reportCount == 0)
        #expect(confirmed.draftCount == 0)
        let repeatedConfirmation = try await service.saveDICOMStudy(confirmation)
        #expect(repeatedConfirmation.generation == confirmed.generation)

        let renamedMember = try FamilyMember(
            id: member.id,
            displayName: "Synthetic renamed imaging member"
        )
        let afterOrdinaryMemberEdit = try await service.updateMember(renamedMember, replacing: member)
        #expect(afterOrdinaryMemberEdit.members == [LibraryMemberSummary(renamedMember)])
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
        try await draftStore.discard(
            draftID: reportDraftID,
            expectedRevision: reportDraft.revision
        )
        let afterReportDiscard = try await vault.loadCatalog()
        #expect(afterReportDiscard.dicomStudies.map(\.id) == [imported.studyID])
        #expect(try await service.loadDICOMStudyViewer(studyID: imported.studyID).study.id == imported.studyID)

        let duplicate = try await service.importDICOMDirectory(at: source)
        #expect(duplicate.studyID == imported.studyID)
        #expect(duplicate.wasExisting)
        #expect(duplicate.destination == .timeline)

        await #expect(throws: AppServiceError.memberStillReferencedByDICOMStudy(studyCount: 1)) {
            try await service.deleteMember(id: member.id)
        }
        let afterStudyDeletion = try await service.deleteDICOMStudy(id: imported.studyID)
        #expect(afterStudyDeletion.dicomStudies.isEmpty)
        let afterMemberDeletion = try await service.deleteMember(id: member.id)
        #expect(afterMemberDeletion.members.isEmpty)
        #expect(afterMemberDeletion.reportCount == 0)
        #expect(afterMemberDeletion.draftCount == 0)

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
                expectedRevision: review.study.contentRevision,
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
        _ = try await loadCatalog()
        return try await underlying.readSnapshot(selecting: references)
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
        _ = try await loadCatalog()
        return try await underlying.readSnapshot(selecting: references)
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
