import Foundation
import Testing
@testable import KinlogueApp

struct MemberSidebarViewSourceTests {
    @Test
    func memberManagementMenusDoNotOfferOneWayArchive() throws {
        let source = try String(contentsOf: memberSidebarURL, encoding: .utf8)

        #expect(source.contains("Button(AppLocalization.string(\"编辑\"))"))
        #expect(source.contains("Button(AppLocalization.string(\"删除家庭成员\")"))
        #expect(!source.contains("AppLocalization.string(\"归档\")"))
        #expect(!source.contains("onArchive"))
    }

    @Test
    func memberDeletionGuidanceDoesNotRecommendUnavailableArchive() throws {
        let source = try String(contentsOf: appShellURL, encoding: .utf8)

        #expect(!source.contains("也可以选择归档来保留资料"))
    }

    @Test
    func sidebarNavigationUsesADedicatedSelectionDomain() throws {
        let source = try String(contentsOf: memberSidebarURL, encoding: .utf8)

        #expect(source.contains("List {"))
        #expect(!source.contains("List(selection: sidebarSelection)"))
        #expect(source.contains("selectSidebar(.allRecords)"))
        #expect(source.contains("selectSidebar(.imaging)"))
        #expect(source.contains("selectSidebar(.lanInbox)"))
        #expect(source.contains("let selection = MemberSidebarSelection.member(member.id)"))
        #expect(source.contains("selectSidebar(selection)"))
        #expect(source.contains("selectSidebar(.settings)"))
        #expect(source.contains(".accessibilityAddTraits("))
        #expect(source.contains("@FocusState private var focusedSidebarSelection"))
        #expect(source.contains("sidebarRowFocusOverlay(for:"))
        #expect(source.contains(".onMoveCommand"))
        #expect(source.contains("case settings"))
        #expect(source.contains("systemImage: \"gearshape\""))
        #expect(!source.contains("List(selection: $selectedMemberID)"))
        #expect(!source.contains("private var sidebarSelection: Binding"))
    }

    @Test
    func sidebarActionRowsUseFullWidthButtonsOutsideTheSelectionDomain() throws {
        let source = try String(contentsOf: memberSidebarURL, encoding: .utf8)

        #expect(source.contains("private struct SidebarActionButton<Label: View>: View"))
        #expect(source.components(separatedBy: "SidebarActionButton").count - 1 == 4)
        #expect(source.contains("label\n                .sidebarRowHitTarget()"))
        #expect(source.contains(".contentShape(Rectangle())"))
        #expect(source.components(separatedBy: ".selectionDisabled()").count - 1 == 2)
    }

    @Test
    func sidebarRowsUseAConsistentFullWidthMinimumHitTarget() throws {
        let source = try String(contentsOf: memberSidebarURL, encoding: .utf8)

        #expect(source.contains("private extension View"))
        #expect(source.contains("func sidebarRowHitTarget()"))
        #expect(source.contains("minHeight: 44"))
        #expect(source.components(separatedBy: ".sidebarRowHitTarget()").count - 1 == 6)
    }

    @Test
    func waitingDraftsAreCountedAndNamedAfterTheirFirstOriginal() throws {
        let source = try String(contentsOf: memberSidebarURL, encoding: .utf8)

        #expect(source.contains("Section(AppLocalization.string(\"待确认（\\(reviewQueue.count)）\"))"))
        #expect(source.contains("draft.displayName ?? draftLabel(draft)"))
        #expect(source.contains(".truncationMode(.middle)"))
        #expect(source.contains(
            "draft.displayName.map { AppLocalization.string(\"等待确认：\\($0)\") }"
        ))
        #expect(source.contains(".accessibilityHint(AppLocalization.string(\"打开原件并确认识别字段\"))"))
    }

    @Test
    func recognitionStatusStaysVisibleOutsideTheScrollingList() throws {
        let sidebar = try String(contentsOf: memberSidebarURL, encoding: .utf8)
        let shell = try String(contentsOf: appShellURL, encoding: .utf8)
        let status = try String(
            contentsOf: repositoryURL.appendingPathComponent(
                "Sources/KinlogueApp/Views/ReportRecognitionStatusView.swift"
            ),
            encoding: .utf8
        )

        let listEnd = try #require(sidebar.range(of: ".listStyle(.sidebar)"))
        let statusStart = try #require(sidebar.range(of: "if let reportRecognitionActivity {"))
        let settings = try #require(sidebar.range(of: "selectSidebar(.settings)\n            } label:"))
        #expect(listEnd.upperBound < statusStart.lowerBound)
        #expect(statusStart.upperBound < settings.lowerBound)
        #expect(shell.contains("reportRecognitionActivity: model.reportRecognitionActivity"))
        #expect(shell.contains("isReportRecognitionSlow: model.isReportRecognitionSlow"))
        #expect(status.contains("ProgressView()"))
        #expect(status.contains("if isSlow {\n                SlowRecognitionNotice()"))
        #expect(status.contains("activity.total > 1"))
        #expect(status.contains(".accessibilityElement(children: .combine)"))
    }

    @Test
    func imagingNavigationDoesNotShowAConfirmedStudyCount() throws {
        let sidebar = try String(contentsOf: memberSidebarURL, encoding: .utf8)
        let shell = try String(contentsOf: appShellURL, encoding: .utf8)

        #expect(!sidebar.contains("confirmedDICOMStudyCount"))
        #expect(!shell.contains("confirmedDICOMStudyCount:"))
    }

    @Test
    func allRecordsAndMemberSelectionsRoundTripWithoutSharingDraftIDs() {
        let memberID = UUID()

        #expect(MemberSidebarSelection(memberID: nil) == .allRecords)
        #expect(MemberSidebarSelection(memberID: memberID) == .member(memberID))
        #expect(MemberSidebarSelection.allRecords.memberID == nil)
        #expect(MemberSidebarSelection.member(memberID).memberID == memberID)
        #expect(MemberSidebarSelection(memberID: nil, section: .lanInbox) == .lanInbox)
        #expect(MemberSidebarSelection.lanInbox.section == .lanInbox)
        #expect(MemberSidebarSelection(memberID: nil, section: .imaging) == .imaging)
        #expect(MemberSidebarSelection.imaging.section == .imaging)
        #expect(MemberSidebarSelection(memberID: nil, section: .settings) == .settings)
        #expect(MemberSidebarSelection.settings.section == .settings)
    }

    @Test
    func keyboardNavigationTraversesEveryPrimaryDestinationInVisualOrder() {
        let firstMemberID = UUID()
        let secondMemberID = UUID()
        let memberIDs = [firstMemberID, secondMemberID]

        #expect(MemberSidebarSelection.allRecords.moving(.previous, memberIDs: memberIDs) == nil)
        #expect(MemberSidebarSelection.allRecords.moving(.next, memberIDs: memberIDs) == .imaging)
        #expect(MemberSidebarSelection.imaging.moving(.next, memberIDs: memberIDs) == .lanInbox)
        #expect(MemberSidebarSelection.lanInbox.moving(.next, memberIDs: memberIDs) == .member(firstMemberID))
        #expect(MemberSidebarSelection.member(firstMemberID).moving(.next, memberIDs: memberIDs) == .member(secondMemberID))
        #expect(MemberSidebarSelection.member(secondMemberID).moving(.next, memberIDs: memberIDs) == .settings)
        #expect(MemberSidebarSelection.settings.moving(.next, memberIDs: memberIDs) == nil)
        #expect(MemberSidebarSelection.settings.moving(.previous, memberIDs: memberIDs) == .member(secondMemberID))
    }

    private var repositoryURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var memberSidebarURL: URL {
        repositoryURL.appendingPathComponent("Sources/KinlogueApp/Views/MemberSidebarView.swift")
    }

    private var appShellURL: URL {
        repositoryURL.appendingPathComponent("Sources/KinlogueApp/Views/AppShellView.swift")
    }
}
