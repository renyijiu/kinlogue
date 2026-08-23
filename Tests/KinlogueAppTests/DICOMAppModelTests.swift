import Foundation
import Testing
@testable import KinlogueApp
@testable import KinlogueCore
@testable import KinloguePlatform

@MainActor
struct DICOMAppModelTests {
    @Test
    func snapshotProjectsConfirmedStudiesOntoTheMemberTimelineWithoutSearchingThem() async throws {
        let member = try FamilyMember(displayName: "Synthetic App imaging member")
        let pending = dicomSummary(state: .needsReview)
        let confirmed = dicomSummary(
            state: .confirmed,
            memberID: member.id,
            effectiveDate: Date(timeIntervalSinceReferenceDate: 100)
        )
        let snapshot = AppSnapshot(
            generation: 3,
            members: [member],
            records: [],
            drafts: [],
            dicomStudies: [pending, confirmed]
        )
        let model = AppModel(
            service: AppServiceSpy(snapshot: snapshot),
            dicomService: DICOMAppServiceSpy()
        )

        await model.start()

        #expect(model.dicomLibraryModel.reviewStudies.map(\.id) == [pending.id])
        #expect(model.dicomLibraryModel.confirmedStudies(memberID: member.id).map(\.id) == [confirmed.id])
        #expect(model.timelineSections.count == 1)
        #expect(model.timelineSections.first?.group == .dated(confirmed.effectiveDate!))
        #expect(model.timelineSections.flatMap(\.dicomStudies).map(\.id) == [confirmed.id])
        #expect(model.timelineSections.flatMap(\.records).isEmpty)
        #expect(model.searchResults.isEmpty)
    }

    @Test
    func DICOMFolderSelectionSharesTheRootModalBoundaryAndLifecycleClearsImagingState() async throws {
        let pending = dicomSummary(state: .needsReview)
        let snapshot = AppSnapshot(
            generation: 1,
            members: [],
            records: [],
            drafts: [],
            dicomStudies: [pending]
        )
        let model = AppModel(
            service: AppServiceSpy(snapshot: snapshot),
            dicomService: DICOMAppServiceSpy()
        )
        await model.start()

        model.presentDICOMImport()
        #expect(model.isDICOMFolderPickerPresented)
        #expect(!model.isDICOMImportPresented)
        #expect(model.dicomImportModel.phase == .selecting)
        model.presentDICOMReview(pending.id)
        #expect(model.reviewingDICOMStudy == nil)

        await model.handleDICOMImporterResult(.failure(CocoaError(.userCancelled)))
        #expect(!model.isDICOMFolderPickerPresented)
        #expect(!model.isDICOMImportPresented)
        #expect(model.dicomImportModel.phase == .idle)
        model.presentDICOMReview(pending.id)
        #expect(model.reviewingDICOMStudy?.id == pending.id)
        #expect(model.dicomViewerStudyID(for: pending.id) == pending.id)
        model.presentImporter()
        #expect(!model.isImporterPresented)

        await model.beginDestructiveVaultLifecycle()
        #expect(model.reviewingDICOMStudy == nil)
        #expect(model.dicomLibraryModel.studies.isEmpty)
        #expect(model.dicomImportModel.phase == .idle)
    }

    @Test
    func selectedDICOMFolderOpensTheProgressSheetAndStartsImport() async throws {
        let studyID = UUID()
        let service = DICOMAppServiceSpy()
        await service.setImportOutcome(dicomImportOutcome(
            studyID: studyID,
            destination: .review
        ))
        let model = AppModel(
            service: AppServiceSpy(snapshot: .empty),
            dicomService: service
        )
        await model.start()
        let selected = URL(fileURLWithPath: "/synthetic/generated-dicom", isDirectory: true)

        model.presentDICOMImport()
        await model.handleDICOMImporterResult(.success([selected]))

        #expect(!model.isDICOMFolderPickerPresented)
        #expect(model.isDICOMImportPresented)
        #expect(model.dicomImportModel.phase == .succeeded)
        #expect(model.dicomImportModel.result?.studyID == studyID)
        #expect(await service.importedURLs == [selected])
    }

    @Test
    func nonCancelledDICOMFolderPickerErrorOpensTheRetrySheet() async {
        let model = AppModel(
            service: AppServiceSpy(snapshot: .empty),
            dicomService: DICOMAppServiceSpy()
        )
        await model.start()

        model.presentDICOMImport()
        await model.handleDICOMImporterResult(.failure(CocoaError(.fileNoSuchFile)))

        #expect(!model.isDICOMFolderPickerPresented)
        #expect(model.isDICOMImportPresented)
        #expect(model.dicomImportModel.phase == .failed)
        #expect(
            model.dicomImportModel.userErrorMessage
                == AppLocalization.string("无法读取所选文件夹")
        )
    }

    @Test
    func lateDICOMFolderPickerResultCannotReviveAClosedVaultLifecycle() async {
        let service = DICOMAppServiceSpy()
        let model = AppModel(
            service: AppServiceSpy(snapshot: .empty),
            dicomService: service
        )
        await model.start()
        model.presentDICOMImport()

        await model.beginDestructiveVaultLifecycle()
        await model.handleDICOMImporterResult(.success([
            URL(fileURLWithPath: "/synthetic/stale-dicom", isDirectory: true),
        ]))

        #expect(model.phase == .changingVault)
        #expect(!model.isDICOMFolderPickerPresented)
        #expect(!model.isDICOMImportPresented)
        #expect(model.dicomImportModel.phase == .idle)
        #expect(await service.importedURLs.isEmpty)
    }

    @Test
    func retryDismissesTheImportSheetBeforeReopeningTheFolderPicker() async {
        let service = DICOMAppServiceSpy()
        await service.setImportError(.invalidPart10)
        let model = AppModel(
            service: AppServiceSpy(snapshot: .empty),
            dicomService: service
        )
        await model.start()

        model.presentDICOMImport()
        await model.handleDICOMImporterResult(.success([
            URL(fileURLWithPath: "/synthetic/invalid-dicom", isDirectory: true),
        ]))
        #expect(model.isDICOMImportPresented)
        #expect(model.dicomImportModel.phase == .failed)

        model.retryDICOMImportSelection()
        #expect(!model.isDICOMImportPresented)
        #expect(!model.isDICOMFolderPickerPresented)
        #expect(model.dicomImportModel.phase == .failed)

        model.dicomImportPresentationDidEnd()
        #expect(!model.isDICOMImportPresented)
        #expect(model.isDICOMFolderPickerPresented)
        #expect(model.dicomImportModel.phase == .selecting)
    }

    @Test
    func refreshDismissesAReviewWhoseStudyWasDeletedByAnotherMutation() async {
        let pending = dicomSummary(state: .needsReview)
        let model = AppModel(
            service: AppServiceSpy(
                snapshot: AppSnapshot(
                    generation: 1,
                    members: [],
                    records: [],
                    drafts: [],
                    dicomStudies: [pending]
                ),
                refreshedSnapshot: AppSnapshot(
                    generation: 2,
                    members: [],
                    records: [],
                    drafts: [],
                    dicomStudies: []
                )
            ),
            dicomService: DICOMAppServiceSpy()
        )
        await model.start()
        model.presentDICOMReview(pending.id)
        #expect(model.reviewingDICOMStudy?.id == pending.id)

        await model.refresh()

        #expect(model.reviewingDICOMStudy == nil)
        #expect(model.dicomLibraryModel.studies.isEmpty)
    }

    @Test
    func refreshInvalidatesAViewerRequestWhoseStudyWasDeletedByAnotherMutation() async {
        let confirmed = dicomSummary(state: .confirmed)
        let registry = DICOMViewerRegistry()
        let model = AppModel(
            service: AppServiceSpy(
                snapshot: AppSnapshot(
                    generation: 1,
                    members: [],
                    records: [],
                    drafts: [],
                    dicomStudies: [confirmed]
                ),
                refreshedSnapshot: AppSnapshot(
                    generation: 2,
                    members: [],
                    records: [],
                    drafts: [],
                    dicomStudies: []
                )
            ),
            dicomService: DICOMAppServiceSpy(),
            dicomViewerRegistry: registry
        )
        let dismissal = DICOMWindowDismissalRecorder()
        await model.start()
        #expect(model.dicomViewerStudyID(for: confirmed.id) == confirmed.id)
        let viewer = model.makeDICOMStudyViewerModel(studyID: confirmed.id)
        viewer.activateWindow { dismissal.record() }

        await model.refresh()

        #expect(model.dicomViewerStudyID(for: confirmed.id) == nil)
        #expect(model.dicomLibraryModel.studies.isEmpty)
        #expect(viewer.phase == .closed)
        #expect(dismissal.count == 1)
    }

    @Test
    func wholeVaultLifecycleRevokesRegisteredViewerWindowsBeforeReturning() async {
        let study = dicomSummary(state: .confirmed)
        let registry = DICOMViewerRegistry()
        let model = AppModel(
            service: AppServiceSpy(snapshot: AppSnapshot(
                members: [],
                records: [],
                drafts: [],
                dicomStudies: [study]
            )),
            dicomService: DICOMAppServiceSpy(),
            dicomViewerRegistry: registry
        )
        let dismissal = DICOMWindowDismissalRecorder()
        await model.start()
        let viewer = model.makeDICOMStudyViewerModel(studyID: study.id)
        viewer.activateWindow { dismissal.record() }

        await model.beginDestructiveVaultLifecycle()

        #expect(viewer.phase == .closed)
        #expect(viewer.image == nil)
        #expect(dismissal.count == 1)
    }

    @Test
    func refreshFailureClearsViewerPixelsAndAwaitsSessionCloseBeforeLocking() async throws {
        let study = dicomSummary(state: .confirmed)
        let session = try appModelViewerSession(studyID: study.id)
        let content = appModelViewerContent(study: study, session: session)
        let slices = GatedAppModelDICOMSliceService(session: session)
        let registry = DICOMViewerRegistry()
        let model = AppModel(
            service: AppServiceSpy(
                snapshot: AppSnapshot(
                    generation: 1,
                    members: [],
                    records: [],
                    drafts: [],
                    dicomStudies: [study]
                ),
                refreshError: .vaultUnavailable
            ),
            dicomService: DICOMAppServiceSpy(),
            dicomSliceServiceFactory: { slices },
            dicomViewerRegistry: registry
        )
        let dismissal = DICOMWindowDismissalRecorder()
        await model.start()
        let viewer = model.makeDICOMStudyViewerModel(
            studyID: study.id,
            initialContent: content
        )
        viewer.activateWindow { dismissal.record() }
        await viewer.load()
        #expect(viewer.image != nil)
        await slices.delayCloseUntilReleased()

        let refresh = Task { await model.refresh() }
        await slices.waitUntilCloseStarts()

        #expect(viewer.image == nil)
        #expect(model.phase == .locked)
        #expect(dismissal.count == 0)

        await slices.releaseClose()
        await refresh.value

        #expect(viewer.phase == .closed)
        #expect(dismissal.count == 1)
        #expect(model.phase == .locked)
        #expect(model.dicomLibraryModel.studies.isEmpty)
    }

    @Test
    func refreshRevokesViewerWhenTheSameStudyMetadataChanges() async {
        let member = UUID()
        let original = dicomSummary(
            state: .confirmed,
            memberID: member,
            effectiveDate: Date(timeIntervalSinceReferenceDate: 100)
        )
        let updated = dicomSummary(
            id: original.id,
            state: .confirmed,
            memberID: member,
            effectiveDate: Date(timeIntervalSinceReferenceDate: 200)
        )
        let model = AppModel(
            service: AppServiceSpy(
                snapshot: AppSnapshot(
                    generation: 1,
                    members: [],
                    records: [],
                    drafts: [],
                    dicomStudies: [original]
                ),
                refreshedSnapshot: AppSnapshot(
                    generation: 2,
                    members: [],
                    records: [],
                    drafts: [],
                    dicomStudies: [updated]
                )
            ),
            dicomService: DICOMAppServiceSpy()
        )
        let dismissal = DICOMWindowDismissalRecorder()
        await model.start()
        let viewer = model.makeDICOMStudyViewerModel(studyID: original.id)
        viewer.activateWindow { dismissal.record() }

        await model.refresh()

        #expect(viewer.phase == .closed)
        #expect(dismissal.count == 1)
        #expect(model.dicomLibraryModel.studies == [updated])
    }

    @Test
    func refreshRevokesViewerForAnUnrelatedCatalogGenerationChange() async {
        let study = dicomSummary(state: .confirmed)
        let model = AppModel(
            service: AppServiceSpy(
                snapshot: AppSnapshot(
                    generation: 1,
                    members: [],
                    records: [],
                    drafts: [],
                    dicomStudies: [study]
                ),
                refreshedSnapshot: AppSnapshot(
                    generation: 2,
                    members: [],
                    records: [],
                    drafts: [],
                    dicomStudies: [study]
                )
            ),
            dicomService: DICOMAppServiceSpy()
        )
        let dismissal = DICOMWindowDismissalRecorder()
        await model.start()
        let viewer = model.makeDICOMStudyViewerModel(studyID: study.id)
        viewer.activateWindow { dismissal.record() }

        await model.refresh()

        #expect(viewer.phase == .closed)
        #expect(dismissal.count == 1)
        #expect(model.dicomLibraryModel.studies == [study])
    }

    @Test
    func savingChangedStudyMetadataRevokesTheOpenViewerBeforePublishingSnapshot() async throws {
        let originalMember = try FamilyMember(displayName: "Synthetic original imaging member")
        let updatedMember = try FamilyMember(displayName: "Synthetic updated imaging member")
        let originalDate = Date(timeIntervalSinceReferenceDate: 100)
        let updatedDate = Date(timeIntervalSinceReferenceDate: 200)
        let originalStudy = dicomSummary(
            state: .confirmed,
            memberID: originalMember.id,
            effectiveDate: originalDate
        )
        let updatedStudy = dicomSummary(
            id: originalStudy.id,
            state: .confirmed,
            memberID: updatedMember.id,
            effectiveDate: updatedDate
        )
        let initialSnapshot = AppSnapshot(
            generation: 1,
            members: [originalMember, updatedMember],
            records: [],
            drafts: [],
            dicomStudies: [originalStudy]
        )
        let updatedSnapshot = AppSnapshot(
            generation: 2,
            members: [originalMember, updatedMember],
            records: [],
            drafts: [],
            dicomStudies: [updatedStudy]
        )
        let session = try appModelViewerSession(studyID: originalStudy.id)
        let viewerContent = appModelViewerContent(study: originalStudy, session: session)
        let dicomService = DICOMAppServiceSpy()
        await dicomService.setReviewContent(DICOMStudyReviewContent(
            viewerContent: viewerContent,
            selectableMembers: [originalMember, updatedMember]
        ))
        await dicomService.setSavedSnapshot(updatedSnapshot)
        let slices = GatedAppModelDICOMSliceService(session: session)
        let model = AppModel(
            service: AppServiceSpy(snapshot: initialSnapshot),
            dicomService: dicomService,
            dicomSliceServiceFactory: { slices },
            dicomViewerRegistry: DICOMViewerRegistry()
        )
        let dismissal = DICOMWindowDismissalRecorder()
        await model.start()
        let viewer = model.makeDICOMStudyViewerModel(
            studyID: originalStudy.id,
            initialContent: viewerContent
        )
        viewer.activateWindow { dismissal.record() }
        await viewer.load()
        let review = model.makeDICOMStudyReviewModel(studyID: originalStudy.id)
        await review.load()
        review.selectedMemberID = updatedMember.id
        review.effectiveDate = updatedDate
        await slices.delayCloseUntilReleased()

        let save = Task { await review.save() }
        await slices.waitUntilCloseStarts()

        #expect(viewer.image == nil)
        #expect(dismissal.count == 0)
        #expect(review.content?.study == originalStudy)
        #expect(model.dicomLibraryModel.studies == [originalStudy])

        await slices.releaseClose()
        #expect(await save.value)

        #expect(viewer.phase == .closed)
        #expect(dismissal.count == 1)
        #expect(review.content?.study == updatedStudy)
        #expect(model.dicomLibraryModel.studies == [updatedStudy])
    }

    @Test
    func reviewCannotEscapeBeforeItsModelAllowsDismissal() async {
        let study = dicomSummary(state: .confirmed)
        let model = AppModel(
            service: AppServiceSpy(snapshot: AppSnapshot(
                members: [],
                records: [],
                drafts: [],
                dicomStudies: [study]
            )),
            dicomService: DICOMAppServiceSpy()
        )
        await model.start()
        model.presentDICOMReview(study.id)

        model.dismissDICOMReviewIfAllowed()
        #expect(model.reviewingDICOMStudy?.id == study.id)
        let review = model.makeDICOMStudyReviewModel(studyID: study.id)
        model.dismissDICOMReviewIfAllowed()
        #expect(model.reviewingDICOMStudy?.id == study.id)

        await review.load()
        #expect(review.phase == .failed)
        #expect(review.allowsDismissal)
        model.dismissDICOMReviewIfAllowed()
        #expect(model.reviewingDICOMStudy == nil)
    }
}

@MainActor
private final class DICOMWindowDismissalRecorder {
    private(set) var count = 0
    func record() { count += 1 }
}

private actor GatedAppModelDICOMSliceService: DICOMSliceViewing {
    private let session: DICOMSliceSeriesSession
    private var shouldDelayClose = false
    private var closeStarted = false
    private var closeStartedContinuation: CheckedContinuation<Void, Never>?
    private var closeContinuation: CheckedContinuation<Void, Never>?

    init(session: DICOMSliceSeriesSession) { self.session = session }

    func openSeries(
        studyID: DICOMStudy.ID,
        seriesID: DICOMStudyIndex.Series.ID
    ) async throws -> DICOMSliceSeriesSession {
        guard studyID == session.studyID, seriesID == session.seriesID else {
            throw DICOMSliceServiceError.seriesUnavailable
        }
        return session
    }

    func render(
        session: DICOMSliceSeriesSession,
        instanceID: DICOMStudyIndex.Instance.ID,
        windowCenter: Double?,
        windowWidth: Double?
    ) async throws -> DICOMSliceImage {
        let instance = try #require(session.instances.first { $0.id == instanceID })
        return DICOMSliceImage(
            instanceID: instanceID,
            rows: instance.attributes.rows,
            columns: instance.attributes.columns,
            windowCenter: windowCenter ?? 128,
            windowWidth: windowWidth ?? 256,
            pixels: DICOMSlicePixelBuffer(bytes: Data([0, 64, 128, 255]))
        )
    }

    func prefetch(
        session: DICOMSliceSeriesSession,
        instanceID: DICOMStudyIndex.Instance.ID
    ) async -> Bool { true }

    func handleMemoryPressure() async {}

    func close() async {
        guard shouldDelayClose else { return }
        shouldDelayClose = false
        closeStarted = true
        closeStartedContinuation?.resume()
        closeStartedContinuation = nil
        await withCheckedContinuation { closeContinuation = $0 }
    }

    func delayCloseUntilReleased() {
        shouldDelayClose = true
        closeStarted = false
    }

    func waitUntilCloseStarts() async {
        guard !closeStarted else { return }
        await withCheckedContinuation { closeStartedContinuation = $0 }
    }

    func releaseClose() {
        closeContinuation?.resume()
        closeContinuation = nil
    }
}

private func appModelViewerContent(
    study: DICOMStudySummary,
    session: DICOMSliceSeriesSession
) -> DICOMStudyViewerContent {
    DICOMStudyViewerContent(
        study: study,
        confirmedMemberLabel: nil,
        viewableInstanceCount: session.instances.count,
        inertObjectCount: 0,
        series: [DICOMSeriesSummary(
            id: session.seriesID,
            ordinal: 1,
            sliceCount: session.instances.count,
            rows: session.instances[0].attributes.rows,
            columns: session.instances[0].attributes.columns,
            orderingProvenance: session.orderingProvenance
        )]
    )
}

private func appModelViewerSession(studyID: DICOMStudy.ID) throws -> DICOMSliceSeriesSession {
    let attributes = try DICOMStudyIndex.ImageAttributes(
        rows: 2,
        columns: 2,
        samplesPerPixel: 1,
        bitsAllocated: 16,
        bitsStored: 12,
        highBit: 11,
        pixelRepresentation: .unsigned,
        photometricInterpretation: .monochrome2,
        imagePositionPatient: try .init(x: 0, y: 0, z: 0),
        imageOrientationPatientRow: try .init(x: 1, y: 0, z: 0),
        imageOrientationPatientColumn: try .init(x: 0, y: 1, z: 0),
        rescaleSlope: 1,
        rescaleIntercept: 0,
        windowCenter: 128,
        windowWidth: 256
    )
    let revision = try VaultRevision(
        generation: 1,
        commitID: UUID(),
        catalogDigest: Data(repeating: 0x42, count: 32)
    )
    return try DICOMSliceSeriesSession(
        token: DICOMVaultSessionToken(vaultID: UUID(), revision: revision),
        studyID: studyID,
        seriesID: UUID(),
        orderingProvenance: .geometryProjection,
        instances: [try DICOMSliceInstanceDescriptor(
            id: UUID(),
            attachmentID: UUID(),
            contentDigest: Data(repeating: 0x21, count: 32),
            objectByteCount: 512,
            attributes: attributes
        )]
    )
}
