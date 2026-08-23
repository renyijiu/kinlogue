import Foundation
import KinlogueCore

@MainActor
final class DICOMLibraryModel: ObservableObject {
    private var confirmedStudiesByDate: [DICOMStudySummary] = []
    private var memberLabelsByID: [FamilyMember.ID: String] = [:]

    @Published private(set) var studies: [DICOMStudySummary] = []
    @Published private(set) var members: [FamilyMember] = []
    @Published private(set) var selectedStudyID: DICOMStudy.ID?

    var reviewStudies: [DICOMStudySummary] {
        studies.filter { $0.state == .needsReview }
    }

    var selectedStudy: DICOMStudySummary? {
        guard let selectedStudyID else { return nil }
        return studies.first { $0.id == selectedStudyID }
    }

    func confirmedStudies(memberID: FamilyMember.ID?) -> [DICOMStudySummary] {
        guard let memberID else { return confirmedStudiesByDate }
        return confirmedStudiesByDate.filter { $0.confirmedMemberID == memberID }
    }

    func update(studies: [DICOMStudySummary], members: [FamilyMember]) {
        self.studies = studies
        self.members = members
        confirmedStudiesByDate = studies.filter { $0.state == .confirmed }
            .sorted(by: Self.precedes)
        memberLabelsByID = RecordQuery.selectionLabels(for: members)
        if let selectedStudyID,
           !studies.contains(where: {
               $0.id == selectedStudyID && $0.state == .confirmed
           }) {
            self.selectedStudyID = nil
        }
    }

    func select(_ id: DICOMStudy.ID?) {
        guard let id else {
            selectedStudyID = nil
            return
        }
        guard studies.contains(where: { $0.id == id && $0.state == .confirmed }) else {
            return
        }
        selectedStudyID = id
    }

    func clear() {
        studies = []
        members = []
        confirmedStudiesByDate = []
        memberLabelsByID = [:]
        selectedStudyID = nil
    }

    func memberLabel(for study: DICOMStudySummary) -> String {
        guard let memberID = study.confirmedMemberID else {
            return AppLocalization.string("未分配家庭成员")
        }
        return memberLabelsByID[memberID]
            ?? AppLocalization.string("家庭成员")
    }

    private static func precedes(_ lhs: DICOMStudySummary, _ rhs: DICOMStudySummary) -> Bool {
        switch (lhs.effectiveDate, rhs.effectiveDate) {
        case let (left?, right?) where left != right:
            return left > right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}
