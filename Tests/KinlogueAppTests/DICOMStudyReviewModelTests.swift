import Foundation
import Testing
@testable import KinlogueApp
@testable import KinlogueCore

@MainActor
struct DICOMStudyReviewModelTests {
    @Test
    func confirmationRequiresAVisibleActiveMemberAndFiniteDate() async throws {
        let member = try FamilyMember(displayName: "Synthetic imaging member")
        let archived = try FamilyMember(
            displayName: "Synthetic archived member",
            isArchived: true
        )
        let study = dicomSummary(state: .needsReview)
        let service = DICOMAppServiceSpy()
        await service.setReviewContent(dicomReviewContent(
            study: study,
            selectableMembers: [member],
            viewableInstanceCount: 4,
            inertObjectCount: 1,
            series: dicomSeriesSummaries(count: 2)
        ))
        let model = DICOMStudyReviewModel(studyID: study.id, service: service)

        await model.load()
        #expect(model.content?.viewableInstanceCount == 4)
        #expect(model.content?.inertObjectCount == 1)
        #expect(model.content?.seriesCount == 2)
        #expect(!(await model.save()))

        model.selectedMemberID = archived.id
        #expect(!(await model.save()))

        model.selectedMemberID = member.id
        model.effectiveDate = Date(timeIntervalSinceReferenceDate: .infinity)
        #expect(!(await model.save()))
        #expect(await service.saveCommands.isEmpty)
    }

    @Test
    func confirmationPublishesOnceAndAppliesTheReturnedSnapshot() async throws {
        let member = try FamilyMember(displayName: "Synthetic confirmed member")
        let date = Date(timeIntervalSinceReferenceDate: 123_456)
        let pending = dicomSummary(state: .needsReview)
        let confirmed = dicomSummary(
            id: pending.id,
            state: .confirmed,
            memberID: member.id,
            effectiveDate: date
        )
        let snapshot = AppSnapshot(
            generation: 9,
            members: [member],
            records: [],
            drafts: [],
            dicomStudies: [confirmed]
        )
        let service = DICOMAppServiceSpy()
        await service.setReviewContent(dicomReviewContent(
            study: pending,
            selectableMembers: [member],
            viewableInstanceCount: 3,
            inertObjectCount: 0,
            series: dicomSeriesSummaries(count: 1)
        ))
        await service.setSavedSnapshot(snapshot)
        let applied = DICOMSnapshotRecorder()
        let model = DICOMStudyReviewModel(
            studyID: pending.id,
            service: service,
            onSnapshotChanged: { snapshot in await applied.record(snapshot) }
        )
        await model.load()
        model.selectedMemberID = member.id
        model.effectiveDate = date

        #expect(await model.save())

        #expect(model.content?.study == confirmed)
        #expect(await service.saveCommands == [SaveDICOMStudyCommand(
            studyID: pending.id,
            memberID: member.id,
            effectiveDate: date
        )])
        #expect(await applied.snapshots == [snapshot])
    }

    @Test
    func deletionAppliesTheReturnedSnapshotAndClearsLoadedContent() async throws {
        let pending = dicomSummary(state: .needsReview)
        let service = DICOMAppServiceSpy()
        await service.setReviewContent(dicomReviewContent(
            study: pending,
            selectableMembers: [],
            viewableInstanceCount: 1,
            inertObjectCount: 1,
            series: dicomSeriesSummaries(count: 1)
        ))
        await service.setDeletedSnapshot(.empty)
        let model = DICOMStudyReviewModel(studyID: pending.id, service: service)
        await model.load()

        #expect(await model.deleteStudy())

        #expect(model.content == nil)
        #expect(await service.deletedStudyIDs == [pending.id])
    }

    @Test
    func loadingSavingAndDeletingBlockDismissalWithoutTrappingAStableReview() async throws {
        let member = try FamilyMember(displayName: "Synthetic review lifecycle member")
        let study = dicomSummary(
            state: .confirmed,
            memberID: member.id,
            effectiveDate: Date(timeIntervalSinceReferenceDate: 900)
        )
        let content = dicomReviewContent(
            study: study,
            selectableMembers: [member],
            viewableInstanceCount: 1,
            inertObjectCount: 0,
            series: dicomSeriesSummaries(count: 1)
        )
        let loadGate = AsyncOperationGate()
        let saveGate = AsyncOperationGate()
        let deleteGate = AsyncOperationGate()
        let events = DICOMReviewEventRecorder()
        let service = GatedDICOMReviewService(
            content: content,
            savedSnapshot: AppSnapshot(
                generation: 2,
                members: [member],
                records: [],
                drafts: [],
                dicomStudies: [study]
            ),
            loadGate: loadGate,
            saveGate: saveGate,
            deleteGate: deleteGate,
            events: events
        )
        let model = DICOMStudyReviewModel(
            studyID: study.id,
            service: service,
            onStudyDeletionBegan: { _ in await events.record("revoke") }
        )

        #expect(!model.allowsDismissal)
        let load = Task { await model.load() }
        #expect(await loadGate.waitUntilStarted())
        #expect(model.phase == .loading)
        #expect(!model.allowsDismissal)
        await loadGate.open()
        await load.value
        #expect(model.phase == .ready)
        #expect(model.allowsDismissal)

        model.selectedMemberID = member.id
        let save = Task { await model.save() }
        #expect(await saveGate.waitUntilStarted())
        #expect(model.phase == .saving)
        #expect(!model.allowsDismissal)
        await saveGate.open()
        #expect(await save.value)
        #expect(model.phase == .ready)
        #expect(model.allowsDismissal)

        let deletion = Task { await model.deleteStudy() }
        #expect(await deleteGate.waitUntilStarted())
        #expect(model.phase == .deleting)
        #expect(!model.allowsDismissal)
        #expect(await events.values == ["revoke", "delete"])
        await deleteGate.open()
        #expect(await deletion.value)
        #expect(model.content == nil)
    }

    @Test
    func failedInitialLoadRestoresAnExplicitClosePath() async {
        let model = DICOMStudyReviewModel(
            studyID: UUID(),
            service: DICOMAppServiceSpy()
        )

        await model.load()

        #expect(model.phase == .failed)
        #expect(model.content == nil)
        #expect(model.allowsDismissal)
    }
}

private actor DICOMSnapshotRecorder {
    private(set) var snapshots: [AppSnapshot] = []
    func record(_ snapshot: AppSnapshot) { snapshots.append(snapshot) }
}

private actor DICOMReviewEventRecorder {
    private(set) var values: [String] = []
    func record(_ value: String) { values.append(value) }
}

private actor GatedDICOMReviewService: DICOMAppServicing {
    let content: DICOMStudyReviewContent
    let savedSnapshot: AppSnapshot
    let loadGate: AsyncOperationGate
    let saveGate: AsyncOperationGate
    let deleteGate: AsyncOperationGate
    let events: DICOMReviewEventRecorder

    init(
        content: DICOMStudyReviewContent,
        savedSnapshot: AppSnapshot,
        loadGate: AsyncOperationGate,
        saveGate: AsyncOperationGate,
        deleteGate: AsyncOperationGate,
        events: DICOMReviewEventRecorder
    ) {
        self.content = content
        self.savedSnapshot = savedSnapshot
        self.loadGate = loadGate
        self.saveGate = saveGate
        self.deleteGate = deleteGate
        self.events = events
    }

    func importDICOMDirectory(at url: URL) async throws -> DICOMAppImportOutcome {
        throw AppServiceError.importFailed
    }

    func cancelDICOMImport() async throws -> DICOMAppImportOutcome? { nil }

    func loadDICOMStudyReview(studyID: DICOMStudy.ID) async throws -> DICOMStudyReviewContent {
        await loadGate.wait()
        guard content.study.id == studyID else { throw AppServiceError.dicomStudyUnavailable }
        return content
    }

    func saveDICOMStudy(_ command: SaveDICOMStudyCommand) async throws -> AppSnapshot {
        await saveGate.wait()
        return savedSnapshot
    }

    func deleteDICOMStudy(id: DICOMStudy.ID) async throws -> AppSnapshot {
        await events.record("delete")
        await deleteGate.wait()
        return .empty
    }
}
