import Foundation
@testable import KinlogueApp
@testable import KinlogueCore
@testable import KinloguePlatform

actor DICOMAppServiceSpy: DICOMAppServicing {
    var importOutcome: DICOMAppImportOutcome?
    var importError: DICOMImportError?
    var reviewContent: DICOMStudyReviewContent?
    var savedSnapshot: AppSnapshot = .empty
    var deletedSnapshot: AppSnapshot = .empty
    var cancelOutcome: DICOMAppImportOutcome?
    var cancelError: DICOMImportError?
    private(set) var importedURLs: [URL] = []
    private(set) var cancelCallCount = 0
    private(set) var saveCommands: [SaveDICOMStudyCommand] = []
    private(set) var deletedStudyIDs: [DICOMStudy.ID] = []

    func setImportOutcome(_ outcome: DICOMAppImportOutcome) {
        importOutcome = outcome
    }

    func setImportError(_ error: DICOMImportError) {
        importError = error
    }

    func setCancelOutcome(_ outcome: DICOMAppImportOutcome?) {
        cancelOutcome = outcome
    }

    func setCancelError(_ error: DICOMImportError?) {
        cancelError = error
    }

    func setReviewContent(_ content: DICOMStudyReviewContent) {
        reviewContent = content
    }

    func setSavedSnapshot(_ snapshot: AppSnapshot) {
        savedSnapshot = snapshot
    }

    func setDeletedSnapshot(_ snapshot: AppSnapshot) {
        deletedSnapshot = snapshot
    }

    func importDICOMDirectory(at url: URL) async throws -> DICOMAppImportOutcome {
        importedURLs.append(url)
        if let importError { throw importError }
        guard let importOutcome else { throw DICOMImportError.integrityFailure }
        return importOutcome
    }

    func cancelDICOMImport() async throws -> DICOMAppImportOutcome? {
        cancelCallCount += 1
        if let cancelError { throw cancelError }
        return cancelOutcome
    }

    func loadDICOMStudyReview(studyID: DICOMStudy.ID) async throws -> DICOMStudyReviewContent {
        guard let reviewContent, reviewContent.study.id == studyID else {
            throw AppServiceError.dicomStudyUnavailable
        }
        return reviewContent
    }

    func saveDICOMStudy(_ command: SaveDICOMStudyCommand) async throws -> AppSnapshot {
        saveCommands.append(command)
        return savedSnapshot
    }

    func deleteDICOMStudy(id: DICOMStudy.ID) async throws -> AppSnapshot {
        deletedStudyIDs.append(id)
        return deletedSnapshot
    }
}

func dicomSummary(
    id: UUID = UUID(),
    state: DICOMStudyState,
    memberID: FamilyMember.ID? = nil,
    effectiveDate: Date? = nil,
    objectCount: Int = 2
) -> DICOMStudySummary {
    DICOMStudySummary(
        id: id,
        state: state,
        retainedObjectCount: objectCount,
        confirmedMemberID: memberID,
        effectiveDate: effectiveDate
    )
}

func dicomImportOutcome(
    studyID: UUID,
    destination: DICOMStudyDestination,
    wasExisting: Bool = false
) -> DICOMAppImportOutcome {
    DICOMAppImportOutcome(
        studyID: studyID,
        destination: destination,
        wasExisting: wasExisting,
        viewableInstanceCount: 3,
        inertObjectCount: 1,
        ignoredNonDICOMCount: 2,
        ignoredDuplicateCount: 1
    )
}

func dicomSeriesSummaries(count: Int) -> [DICOMSeriesSummary] {
    (0..<count).map { index in
        DICOMSeriesSummary(
            id: UUID(),
            ordinal: index + 1,
            sliceCount: 2,
            rows: 2,
            columns: 2,
            orderingProvenance: .geometryProjection
        )
    }
}

func dicomReviewContent(
    study: DICOMStudySummary,
    selectableMembers: [FamilyMember],
    viewableInstanceCount: Int,
    inertObjectCount: Int,
    series: [DICOMSeriesSummary]
) -> DICOMStudyReviewContent {
    let labels = RecordQuery.selectionLabels(for: selectableMembers)
    return DICOMStudyReviewContent(
        viewerContent: DICOMStudyViewerContent(
            study: study,
            confirmedMemberLabel: study.confirmedMemberID.flatMap { labels[$0] },
            viewableInstanceCount: viewableInstanceCount,
            inertObjectCount: inertObjectCount,
            series: series
        ),
        selectableMembers: selectableMembers
    )
}
