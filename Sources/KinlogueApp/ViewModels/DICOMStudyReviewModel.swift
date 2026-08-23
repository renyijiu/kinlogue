import Foundation
import KinlogueCore

enum DICOMStudyReviewPhase: Equatable {
    case idle
    case loading
    case ready
    case saving
    case deleting
    case failed
}

@MainActor
final class DICOMStudyReviewModel: ObservableObject {
    let studyID: DICOMStudy.ID
    private let service: any DICOMAppServicing
    private let onSnapshotChanged: @MainActor @Sendable (AppSnapshot) async -> Void
    private let onStudyMetadataChanged: @MainActor @Sendable (DICOMStudy.ID) async -> Void
    private let onStudyDeletionBegan: @MainActor @Sendable (DICOMStudy.ID) async -> Void
    private var requestGeneration: UInt64 = 0

    @Published private(set) var phase: DICOMStudyReviewPhase = .idle
    @Published private(set) var content: DICOMStudyReviewContent?
    @Published var selectedMemberID: FamilyMember.ID?
    @Published var effectiveDate = Date()
    @Published private(set) var hasValidationError = false
    @Published private(set) var operationFailed = false

    init(
        studyID: DICOMStudy.ID,
        service: any DICOMAppServicing,
        onSnapshotChanged: @escaping @MainActor @Sendable (AppSnapshot) async -> Void = { _ in },
        onStudyMetadataChanged: @escaping @MainActor @Sendable (DICOMStudy.ID) async -> Void = { _ in },
        onStudyDeletionBegan: @escaping @MainActor @Sendable (DICOMStudy.ID) async -> Void = { _ in }
    ) {
        self.studyID = studyID
        self.service = service
        self.onSnapshotChanged = onSnapshotChanged
        self.onStudyMetadataChanged = onStudyMetadataChanged
        self.onStudyDeletionBegan = onStudyDeletionBegan
    }

    var allowsDismissal: Bool {
        switch phase {
        case .idle, .loading, .saving, .deleting:
            return false
        case .ready, .failed:
            return content?.study.state != .needsReview
        }
    }

    func load() async {
        guard phase == .idle else { return }
        let generation = beginRequest()
        phase = .loading
        operationFailed = false
        do {
            let content = try await service.loadDICOMStudyReview(studyID: studyID)
            guard isCurrent(generation) else { return }
            self.content = content
            selectedMemberID = content.study.confirmedMemberID
            effectiveDate = content.study.effectiveDate.flatMap {
                ReportDateSemantics.pickerDate(from: $0)
            } ?? Date()
            phase = .ready
        } catch {
            guard isCurrent(generation) else { return }
            content = nil
            operationFailed = true
            phase = .failed
        }
    }

    func save() async -> Bool {
        guard phase == .ready,
              let content,
              let selectedMemberID,
              content.selectableMembers.contains(where: { $0.id == selectedMemberID }),
              effectiveDate.timeIntervalSinceReferenceDate.isFinite else {
            hasValidationError = true
            return false
        }
        hasValidationError = false
        operationFailed = false
        phase = .saving
        let generation = beginRequest()
        do {
            let snapshot = try await service.saveDICOMStudy(SaveDICOMStudyCommand(
                studyID: studyID,
                memberID: selectedMemberID,
                effectiveDate: effectiveDate
            ))
            guard isCurrent(generation) else { return false }
            guard let updated = snapshot.dicomStudies.first(where: { $0.id == studyID }) else {
                throw AppServiceError.dicomStudyUnavailable
            }
            let metadataChanged = content.study.confirmedMemberID != updated.confirmedMemberID
                || content.study.effectiveDate != updated.effectiveDate
            if metadataChanged {
                await onStudyMetadataChanged(studyID)
                guard isCurrent(generation) else { return false }
            }
            let selectableMembers = RecordQuery.selectableMembers(
                from: snapshot.members.filter {
                    !$0.isArchived || $0.id == updated.confirmedMemberID
                },
                includeArchived: true
            )
            let memberLabels = RecordQuery.selectionLabels(for: selectableMembers)
            self.content = DICOMStudyReviewContent(
                viewerContent: DICOMStudyViewerContent(
                    study: updated,
                    confirmedMemberLabel: updated.confirmedMemberID.flatMap {
                        memberLabels[$0]
                    },
                    viewableInstanceCount: content.viewableInstanceCount,
                    inertObjectCount: content.inertObjectCount,
                    series: content.viewerContent.series
                ),
                selectableMembers: selectableMembers
            )
            await onSnapshotChanged(snapshot)
            guard isCurrent(generation) else { return false }
            phase = .ready
            return true
        } catch {
            guard isCurrent(generation) else { return false }
            operationFailed = true
            phase = .ready
            return false
        }
    }

    func deleteStudy() async -> Bool {
        guard phase == .ready, content != nil else { return false }
        operationFailed = false
        phase = .deleting
        let generation = beginRequest()
        await onStudyDeletionBegan(studyID)
        guard isCurrent(generation) else { return false }
        do {
            let snapshot = try await service.deleteDICOMStudy(id: studyID)
            guard isCurrent(generation) else { return false }
            content = nil
            await onSnapshotChanged(snapshot)
            guard isCurrent(generation) else { return false }
            phase = .idle
            return true
        } catch {
            guard isCurrent(generation) else { return false }
            operationFailed = true
            phase = .ready
            return false
        }
    }

    func clear() {
        requestGeneration &+= 1
        content = nil
        selectedMemberID = nil
        hasValidationError = false
        operationFailed = false
        phase = .idle
    }

    private func beginRequest() -> UInt64 {
        requestGeneration &+= 1
        return requestGeneration
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        requestGeneration == generation
    }
}
