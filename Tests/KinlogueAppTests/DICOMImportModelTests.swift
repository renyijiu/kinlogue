import Foundation
import Testing
@testable import KinlogueApp
@testable import KinlogueCore

@MainActor
struct DICOMImportModelTests {
    @Test
    func successfulImportReportsAggregateCountsAndRoutesToReview() async throws {
        let studyID = UUID()
        let service = DICOMAppServiceSpy()
        await service.setImportOutcome(dicomImportOutcome(
            studyID: studyID,
            destination: .review
        ))
        let model = DICOMImportModel(service: service)
        let selected = URL(fileURLWithPath: "/synthetic/generated-dicom", isDirectory: true)

        model.beginSelection()
        await model.handleImporterResult(.success([selected]))

        #expect(model.phase == .succeeded)
        #expect(model.result?.studyID == studyID)
        #expect(model.result?.viewableInstanceCount == 3)
        #expect(model.result?.inertObjectCount == 1)
        #expect(model.result?.ignoredNonDICOMCount == 2)
        #expect(model.result?.ignoredDuplicateCount == 1)
        #expect(model.takeResult()?.destination == .review)
        #expect(await service.importedURLs == [selected])
    }

    @Test
    func exactReimportRoutesToTheExistingConfirmedLibraryStudy() async {
        let studyID = UUID()
        let service = DICOMAppServiceSpy()
        await service.setImportOutcome(dicomImportOutcome(
            studyID: studyID,
            destination: .library,
            wasExisting: true
        ))
        let model = DICOMImportModel(service: service)

        await model.handleImporterResult(.success([
            URL(fileURLWithPath: "/synthetic/existing", isDirectory: true),
        ]))

        #expect(model.result?.wasExisting == true)
        #expect(model.takeResult()?.destination == .library)
        #expect(model.takeResult() == nil)
    }

    @Test
    func cancellationRequestsWorkflowCleanupAndDoesNotCreateADestination() async {
        let service = DelayedDICOMImportService(outcome: dicomImportOutcome(
            studyID: UUID(),
            destination: .review
        ))
        let model = DICOMImportModel(service: service)
        let importTask = Task {
            await model.handleImporterResult(.success([
                URL(fileURLWithPath: "/synthetic/cancelled", isDirectory: true),
            ]))
        }
        await service.waitUntilStarted()

        await model.cancel()
        await importTask.value

        #expect(await service.cancelCallCount == 1)
        #expect(model.phase == .cancelled)
        #expect(model.takeResult() == nil)
    }

    @Test
    func cancellationPublishesACommitThatAlreadyCrossedItsIrreversiblePoint() async {
        let committed = dicomImportOutcome(
            studyID: UUID(),
            destination: .review
        )
        let service = DelayedDICOMImportService(
            outcome: committed,
            cancelOutcome: committed
        )
        let model = DICOMImportModel(service: service)
        let importTask = Task {
            await model.handleImporterResult(.success([
                URL(fileURLWithPath: "/synthetic/committed", isDirectory: true),
            ]))
        }
        await service.waitUntilStarted()

        await model.cancel()
        await importTask.value

        #expect(model.phase == .succeeded)
        #expect(model.result == committed)
        #expect(await service.cancelCallCount == 1)
    }

    @Test
    func selectionCancellationLeavesTheModelRetryable() async {
        let model = DICOMImportModel(service: DICOMAppServiceSpy())
        model.beginSelection()

        await model.handleImporterResult(.failure(CocoaError(.userCancelled)))

        #expect(model.phase == .idle)
        #expect(model.userErrorMessage == nil)
        model.beginSelection()
        #expect(model.phase == .selecting)
    }

    @Test
    func cancellingFolderSelectionDoesNotConsumeAPriorServiceTerminal() async {
        let service = DICOMAppServiceSpy()
        let model = DICOMImportModel(service: service)
        model.beginSelection()

        await model.cancel()

        #expect(model.phase == .cancelled)
        #expect(await service.cancelCallCount == 0)
    }

    @Test
    func invalidPart10IsReportedAsUnreadableDICOMInsteadOfAnEmptyFolder() async {
        let service = DICOMAppServiceSpy()
        await service.setImportError(.invalidPart10)
        let model = DICOMImportModel(service: service)

        await model.handleImporterResult(.success([
            URL(fileURLWithPath: "/synthetic/invalid-part-10", isDirectory: true),
        ]))

        #expect(model.phase == .failed)
        #expect(
            model.userErrorMessage
                == AppLocalization.string("文件夹中包含无法读取或暂不支持的 DICOM 文件")
        )
    }

    @Test
    func lifecycleClearFencesALateSuccessfulImportResult() async throws {
        let studyID = UUID()
        let service = DelayedDICOMImportService(outcome: dicomImportOutcome(
            studyID: studyID,
            destination: .review
        ))
        let model = DICOMImportModel(service: service)
        let task = Task {
            await model.handleImporterResult(.success([
                URL(fileURLWithPath: "/synthetic/late", isDirectory: true),
            ]))
        }
        await service.waitUntilStarted()

        model.clear()
        await service.finish()
        await task.value

        #expect(model.phase == .idle)
        #expect(model.result == nil)
        #expect(model.takeResult() == nil)
    }
}

private actor DelayedDICOMImportService: DICOMAppServicing {
    let outcome: DICOMAppImportOutcome
    let cancelOutcome: DICOMAppImportOutcome?
    private var started = false
    private(set) var cancelCallCount = 0
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var continuation: CheckedContinuation<Void, Never>?

    init(
        outcome: DICOMAppImportOutcome,
        cancelOutcome: DICOMAppImportOutcome? = nil
    ) {
        self.outcome = outcome
        self.cancelOutcome = cancelOutcome
    }

    func importDICOMDirectory(at url: URL) async throws -> DICOMAppImportOutcome {
        started = true
        startedContinuation?.resume()
        startedContinuation = nil
        await withCheckedContinuation { self.continuation = $0 }
        return outcome
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }

    func finish() {
        continuation?.resume()
        continuation = nil
    }

    func cancelDICOMImport() async throws -> DICOMAppImportOutcome? {
        cancelCallCount += 1
        continuation?.resume()
        continuation = nil
        return cancelOutcome
    }
    func loadDICOMStudyReview(studyID: DICOMStudy.ID) async throws -> DICOMStudyReviewContent {
        throw AppServiceError.dicomStudyUnavailable
    }
    func saveDICOMStudy(_ command: SaveDICOMStudyCommand) async throws -> AppSnapshot {
        throw AppServiceError.dicomStudyUnavailable
    }
    func deleteDICOMStudy(id: DICOMStudy.ID) async throws -> AppSnapshot {
        throw AppServiceError.dicomStudyUnavailable
    }
}
