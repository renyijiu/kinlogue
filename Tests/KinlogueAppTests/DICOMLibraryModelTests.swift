import Foundation
import Testing
@testable import KinlogueApp
@testable import KinlogueCore

@MainActor
struct DICOMLibraryModelTests {
    @Test
    func librarySeparatesReviewFromConfirmedAndFiltersByMember() throws {
        let firstMember = try FamilyMember(displayName: "Synthetic first imaging member")
        let secondMember = try FamilyMember(displayName: "Synthetic second imaging member")
        let first = dicomSummary(
            state: .confirmed,
            memberID: firstMember.id,
            effectiveDate: Date(timeIntervalSinceReferenceDate: 10)
        )
        let second = dicomSummary(
            state: .confirmed,
            memberID: secondMember.id,
            effectiveDate: Date(timeIntervalSinceReferenceDate: 20)
        )
        let pending = dicomSummary(state: .needsReview)
        let model = DICOMLibraryModel()

        model.update(studies: [pending, first, second], members: [firstMember, secondMember])

        #expect(model.reviewStudies.map(\.id) == [pending.id])
        #expect(Set(model.confirmedStudies(memberID: nil).map(\.id)) == Set([first.id, second.id]))
        #expect(model.confirmedStudies(memberID: firstMember.id).map(\.id) == [first.id])
    }

    @Test
    func refreshClearsAStaleSelectionAndDestructiveLifecycleClearsAllState() throws {
        let member = try FamilyMember(displayName: "Synthetic imaging lifecycle member")
        let study = dicomSummary(
            state: .confirmed,
            memberID: member.id,
            effectiveDate: Date(timeIntervalSinceReferenceDate: 30)
        )
        let model = DICOMLibraryModel()
        model.update(studies: [study], members: [member])
        model.select(study.id)
        #expect(model.selectedStudyID == study.id)

        model.update(studies: [], members: [member])
        #expect(model.selectedStudyID == nil)

        model.update(studies: [study], members: [member])
        model.select(study.id)
        model.clear()
        #expect(model.studies.isEmpty)
        #expect(model.members.isEmpty)
        #expect(model.selectedStudyID == nil)
    }
}

struct DICOMLibrarySelectionNavigationTests {
    @Test
    func destinationUsesVisibleOrderAndStopsAtBoundaries() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let visibleStudyIDs = [third, first, second]

        #expect(DICOMLibrarySelectionNavigation.destination(
            from: first,
            step: .previous,
            studyIDs: visibleStudyIDs
        ) == third)
        #expect(DICOMLibrarySelectionNavigation.destination(
            from: first,
            step: .next,
            studyIDs: visibleStudyIDs
        ) == second)
        #expect(DICOMLibrarySelectionNavigation.destination(
            from: third,
            step: .previous,
            studyIDs: visibleStudyIDs
        ) == nil)
        #expect(DICOMLibrarySelectionNavigation.destination(
            from: second,
            step: .next,
            studyIDs: visibleStudyIDs
        ) == nil)
        #expect(DICOMLibrarySelectionNavigation.destination(
            from: UUID(),
            step: .next,
            studyIDs: visibleStudyIDs
        ) == nil)
    }
}
