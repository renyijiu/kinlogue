import KinlogueCore
import SwiftUI

enum AppSidebarSection: Hashable {
    case records
    case lanInbox
    case settings
}

enum MemberSidebarSelection: Hashable {
    case allRecords
    case member(FamilyMember.ID)
    case lanInbox
    case settings

    init(
        memberID: FamilyMember.ID?,
        section: AppSidebarSection = .records
    ) {
        switch section {
        case .settings:
            self = .settings
        case .lanInbox:
            self = .lanInbox
        case .records:
            self = memberID.map(Self.member) ?? .allRecords
        }
    }

    var memberID: FamilyMember.ID? {
        guard case .member(let id) = self else { return nil }
        return id
    }

    var section: AppSidebarSection {
        switch self {
        case .allRecords, .member:
            .records
        case .lanInbox:
            .lanInbox
        case .settings:
            .settings
        }
    }

    func moving(
        _ step: SidebarNavigationStep,
        memberIDs: [FamilyMember.ID]
    ) -> Self? {
        let order: [Self] = [.allRecords, .lanInbox]
            + memberIDs.map(Self.member)
            + [.settings]
        guard let index = order.firstIndex(of: self) else { return nil }
        let nextIndex = switch step {
        case .previous: index - 1
        case .next: index + 1
        }
        guard order.indices.contains(nextIndex) else { return nil }
        return order[nextIndex]
    }
}

enum SidebarNavigationStep {
    case previous
    case next
}

struct MemberSidebarView: View {
    let members: [FamilyMember]
    @Binding var selectedMemberID: FamilyMember.ID?
    @Binding var selectedSection: AppSidebarSection
    let lanInboxItemCount: Int
    let isLANReceiverActive: Bool
    let dicomReviewStudies: [DICOMStudySummary]
    let reviewQueue: [DraftSummary]
    let backgroundDrafts: [DraftSummary]
    let busyDraftIDs: Set<ImportDraft.ID>
    let reportRecognitionActivity: ReportRecognitionActivity?
    let isReportRecognitionSlow: Bool
    let onAdd: () -> Void
    let onOpenDraft: (ImportDraft.ID) -> Void
    let onRetryDraft: (ImportDraft.ID) -> Void
    let onDiscardDraft: (ImportDraft.ID) -> Void
    let onOpenDICOMStudy: (DICOMStudy.ID) -> Void
    let onEdit: (FamilyMember) -> Void
    let onDelete: (FamilyMember) -> Void
    @State private var rowInteraction = KinlogueRowInteraction<MemberSidebarSelection>()
    @FocusState private var focusedSidebarSelection: MemberSidebarSelection?

    var body: some View {
        let selectionLabels = RecordQuery.selectionLabels(for: members)

        VStack(spacing: 0) {
            List {
                Section(AppLocalization.string("浏览")) {
                    Button {
                        selectSidebar(.allRecords)
                    } label: {
                        SidebarRowLabel(
                            AppLocalization.string("全部记录"),
                            systemImage: "clock.arrow.circlepath",
                            color: sidebarRowForeground(for: .allRecords)
                        )
                            .sidebarRowHitTarget()
                            .foregroundStyle(sidebarRowForeground(for: .allRecords))
                    }
                    .buttonStyle(.kinlogueRow { rowInteraction.setPressed($0, for: .allRecords) })
                    .focusEffectDisabled()
                    .focused($focusedSidebarSelection, equals: .allRecords)
                    .background(sidebarRowBackground(for: .allRecords))
                    .overlay(sidebarRowFocusOverlay(for: .allRecords))
                    .listRowBackground(Color.clear)
                    .accessibilityAddTraits(
                        currentSidebarSelection == .allRecords ? .isSelected : []
                    )
                    .onHover { isHovering in
                        rowInteraction.setHovering(isHovering, for: .allRecords)
                    }
                    .onMoveCommand { direction in
                        moveSidebarSelection(from: .allRecords, direction: direction)
                    }
                    Button {
                        selectSidebar(.lanInbox)
                    } label: {
                        HStack {
                            SidebarRowLabel(
                                isLANReceiverActive ? AppLocalization.string("手机上传（接收中）") : AppLocalization.string("手机上传"),
                                systemImage: isLANReceiverActive
                                    ? "dot.radiowaves.left.and.right"
                                    : "iphone.and.arrow.forward.inward",
                                color: sidebarRowForeground(for: .lanInbox)
                            )
                            Spacer()
                            if lanInboxItemCount > 0 {
                                Text("\(lanInboxItemCount)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(sidebarSupplementaryForeground(for: .lanInbox))
                            }
                        }
                        .sidebarRowHitTarget()
                        .foregroundStyle(sidebarRowForeground(for: .lanInbox))
                    }
                    .buttonStyle(.kinlogueRow { rowInteraction.setPressed($0, for: .lanInbox) })
                    .focusEffectDisabled()
                    .focused($focusedSidebarSelection, equals: .lanInbox)
                    .background(sidebarRowBackground(for: .lanInbox))
                    .overlay(sidebarRowFocusOverlay(for: .lanInbox))
                    .accessibilityLabel(
                        isLANReceiverActive
                            ? AppLocalization.string("手机上传，正在接收，\(lanInboxItemCount) 个待确认项")
                            : AppLocalization.string("手机上传，\(lanInboxItemCount) 个待确认项")
                    )
                    .accessibilityAddTraits(
                        currentSidebarSelection == .lanInbox ? .isSelected : []
                    )
                    .listRowBackground(Color.clear)
                    .onHover { isHovering in
                        rowInteraction.setHovering(isHovering, for: .lanInbox)
                    }
                    .onMoveCommand { direction in
                        moveSidebarSelection(from: .lanInbox, direction: direction)
                    }
                }

                Section(AppLocalization.string("家人")) {
                    ForEach(RecordQuery.selectableMembers(from: members)) { member in
                        let selectionLabel = selectionLabels[member.id] ?? member.displayName
                        let selection = MemberSidebarSelection.member(member.id)
                        HStack {
                            Button {
                                selectSidebar(selection)
                            } label: {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(selectionLabel)
                                        if let label = member.disambiguationLabel,
                                           selectionLabel == member.displayName {
                                            Text(label)
                                                .font(.caption)
                                                .foregroundStyle(sidebarSupplementaryForeground(for: selection))
                                        }
                                    }
                                } icon: {
                                    Image(systemName: "person.crop.circle.fill")
                                        .foregroundStyle(sidebarRowForeground(for: selection))
                                }
                                .sidebarRowHitTarget()
                            }
                            .buttonStyle(.kinlogueRow { rowInteraction.setPressed($0, for: selection) })
                            .focusEffectDisabled()
                            .focused($focusedSidebarSelection, equals: selection)
                            .onMoveCommand { direction in
                                moveSidebarSelection(from: selection, direction: direction)
                            }
                            .accessibilityAddTraits(
                                currentSidebarSelection == selection ? .isSelected : []
                            )
                            Menu {
                                Button(AppLocalization.string("编辑")) { onEdit(member) }
                                Divider()
                                Button(AppLocalization.string("删除家庭成员"), role: .destructive) { onDelete(member) }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .foregroundStyle(sidebarRowForeground(for: selection))
                                    .accessibilityLabel(AppLocalization.string("管理 \(selectionLabel)"))
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                        }
                        .foregroundStyle(sidebarRowForeground(for: selection))
                        .background(sidebarRowBackground(for: selection))
                        .overlay(sidebarRowFocusOverlay(for: selection))
                        .listRowBackground(Color.clear)
                        .onHover { isHovering in
                            rowInteraction.setHovering(isHovering, for: selection)
                        }
                        .contextMenu {
                            Button(AppLocalization.string("编辑")) { onEdit(member) }
                            Divider()
                            Button(AppLocalization.string("删除家庭成员"), role: .destructive) { onDelete(member) }
                        }
                    }
                    SidebarActionButton(action: onAdd) {
                        SidebarRowLabel(
                            AppLocalization.string("添加家庭成员"),
                            systemImage: "person.badge.plus",
                            color: KinlogueTheme.onVariant
                        )
                    }
                }

                if !reviewQueue.isEmpty {
                    Section(AppLocalization.string("待确认（\(reviewQueue.count)）")) {
                        ForEach(reviewQueue) { draft in
                            SidebarActionButton {
                                onOpenDraft(draft.id)
                            } label: {
                                HStack {
                                    // The file name is the user's own; it is shown as it is.
                                    SidebarRowLabel(
                                        draft.displayName ?? draftLabel(draft),
                                        systemImage: "doc.badge.clock",
                                        color: KinlogueTheme.onVariant
                                    )
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(KinlogueTheme.onVariantSubtle)
                                }
                            }
                            .help(draft.displayName ?? "")
                            .accessibilityLabel(
                                draft.displayName.map { AppLocalization.string("等待确认：\($0)") }
                                    ?? draftLabel(draft)
                            )
                            .accessibilityHint(AppLocalization.string("打开原件并确认识别字段"))
                        }
                    }
                }

                if !dicomReviewStudies.isEmpty {
                    Section(AppLocalization.string("待确认影像")) {
                        ForEach(dicomReviewStudies) { study in
                            SidebarActionButton {
                                onOpenDICOMStudy(study.id)
                            } label: {
                                HStack {
                                    SidebarRowLabel(
                                        AppLocalization.string("医学影像检查"),
                                        systemImage: "waveform.path.ecg.rectangle",
                                        color: KinlogueTheme.onVariant
                                    )
                                    Spacer()
                                    Text("\(study.retainedObjectCount)")
                                        .font(.caption.monospacedDigit())
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(KinlogueTheme.onVariantSubtle)
                                }
                            }
                            .accessibilityHint(AppLocalization.string("确认家庭成员与检查日期"))
                        }
                    }
                }

                if !backgroundDrafts.isEmpty {
                    Section(AppLocalization.string("导入状态")) {
                        ForEach(backgroundDrafts) { draft in
                            if draft.state == .failed {
                                HStack {
                                    SidebarActionButton {
                                        onRetryDraft(draft.id)
                                    } label: {
                                        SidebarRowLabel(
                                            AppLocalization.string("识别失败，点按重试"),
                                            systemImage: "arrow.clockwise",
                                            color: KinlogueTheme.onVariant
                                        )
                                    }
                                    .disabled(busyDraftIDs.contains(draft.id))
                                    Button(role: .destructive) { onDiscardDraft(draft.id) } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.kinlogueGhost(.danger))
                                    .accessibilityLabel(AppLocalization.string("放弃这份失败的导入"))
                                    .disabled(busyDraftIDs.contains(draft.id))
                                }
                                .selectionDisabled()
                            } else {
                                SidebarRowLabel(
                                    draftLabel(draft),
                                    systemImage: "hourglass",
                                    color: KinlogueTheme.onVariant
                                )
                                    .foregroundStyle(KinlogueTheme.onVariant)
                                    .selectionDisabled()
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            if let reportRecognitionActivity {
                Divider()
                ReportRecognitionStatusView(
                    activity: reportRecognitionActivity,
                    isSlow: isReportRecognitionSlow
                )
            }

            Divider()

            Button {
                selectSidebar(.settings)
            } label: {
                HStack {
                    SidebarRowLabel(
                        AppLocalization.string("设置"),
                        systemImage: "gearshape",
                        color: sidebarRowForeground(for: .settings)
                    )
                    Spacer()
                }
                .padding(.horizontal, 12)
                .sidebarRowHitTarget()
                .foregroundStyle(sidebarRowForeground(for: .settings))
            }
            .buttonStyle(.kinlogueRow { rowInteraction.setPressed($0, for: .settings) })
            .focusEffectDisabled()
            .focused($focusedSidebarSelection, equals: .settings)
            .background(sidebarRowBackground(for: .settings))
            .overlay(sidebarRowFocusOverlay(for: .settings))
            .padding(10)
            .accessibilityAddTraits(selectedSection == .settings ? .isSelected : [])
            .onHover { isHovering in
                rowInteraction.setHovering(isHovering, for: .settings)
            }
            .onMoveCommand { direction in
                moveSidebarSelection(from: .settings, direction: direction)
            }
        }
        .background(KinlogueTheme.surface)
        .navigationTitle(AppLocalization.string("续页"))
        .accessibilityLabel(AppLocalization.string("家庭成员与待确认资料"))
    }

    private func selectSidebar(_ selection: MemberSidebarSelection) {
        selectedSection = selection.section
        if selection.section == .records {
            selectedMemberID = selection.memberID
        }
        focusedSidebarSelection = selection
    }

    private var currentSidebarSelection: MemberSidebarSelection {
        MemberSidebarSelection(memberID: selectedMemberID, section: selectedSection)
    }

    private func sidebarRowBackground(
        for selection: MemberSidebarSelection
    ) -> some View {
        RoundedRectangle(cornerRadius: KinlogueTheme.Radius.control)
            .fill(rowInteraction.fill(
                for: selection,
                isSelected: currentSidebarSelection == selection
            ))
    }

    private func sidebarRowForeground(for selection: MemberSidebarSelection) -> Color {
        currentSidebarSelection == selection
            ? KinlogueTheme.selectionForeground
            : KinlogueTheme.onVariant
    }

    private func sidebarSupplementaryForeground(for selection: MemberSidebarSelection) -> Color {
        sidebarRowForeground(for: selection)
    }

    private func sidebarRowFocusOverlay(
        for selection: MemberSidebarSelection
    ) -> some View {
        RoundedRectangle(cornerRadius: KinlogueTheme.Radius.control)
            .stroke(
                focusedSidebarSelection == selection
                    ? KinlogueTheme.primary
                    : .clear,
                lineWidth: 2
            )
    }

    private func moveSidebarSelection(
        from selection: MemberSidebarSelection,
        direction: MoveCommandDirection
    ) {
        let step: SidebarNavigationStep
        switch direction {
        case .up: step = .previous
        case .down: step = .next
        default: return
        }
        let memberIDs = RecordQuery.selectableMembers(from: members).map(\.id)
        guard let next = selection.moving(step, memberIDs: memberIDs) else { return }
        selectSidebar(next)
    }

    private func draftLabel(_ draft: DraftSummary) -> String {
        switch draft.state {
        case .needsReview: AppLocalization.string("等待确认")
        case .processing: AppLocalization.string("正在识别")
        case .failed: AppLocalization.string("需要重试")
        case .staging: AppLocalization.string("准备处理")
        case .confirmed, .discarded: AppLocalization.string("已处理")
        }
    }
}

private extension View {
    func sidebarRowHitTarget() -> some View {
        frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
    }
}

/// A sidebar-style list tints a bare `Label` icon with the accent color and
/// grays it while the window is inactive, ignoring the row's foreground. Only
/// a style on the symbol itself keeps icon and title on the same row color.
private struct SidebarRowLabel: View {
    let title: String
    let systemImage: String
    let color: Color

    init(_ title: String, systemImage: String, color: Color) {
        self.title = title
        self.systemImage = systemImage
        self.color = color
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(color)
        }
    }
}

private struct SidebarActionButton<Label: View>: View {
    let action: () -> Void
    let label: Label
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false
    @State private var isPressed = false
    @FocusState private var isFocused: Bool

    init(
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) {
        self.action = action
        self.label = label()
    }

    var body: some View {
        Button(action: action) {
            label
                .sidebarRowHitTarget()
        }
        .buttonStyle(.kinlogueRow { isPressed = $0 })
        .focusEffectDisabled()
        .focused($isFocused)
        .foregroundStyle(KinlogueTheme.onVariant)
        .background(
            RoundedRectangle(cornerRadius: KinlogueTheme.Radius.control)
                .fill(KinlogueTheme.rowFill(
                    isSelected: false,
                    isHovering: isHovering && isEnabled,
                    isPressed: isPressed
                ))
        )
        .overlay(
            RoundedRectangle(cornerRadius: KinlogueTheme.Radius.control)
                .stroke(isFocused ? KinlogueTheme.primary : .clear, lineWidth: 2)
        )
        .onHover { isHovering = $0 }
    }
}

struct MemberEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let existing: FamilyMember?
    @State private var name: String
    @State private var label: String
    @State private var isSaving = false
    @State private var errorMessage: String?
    let onSave: (String, String?) async -> Bool

    init(existing: FamilyMember?, onSave: @escaping (String, String?) async -> Bool) {
        self.existing = existing
        _name = State(initialValue: existing?.displayName ?? "")
        _label = State(initialValue: existing?.disambiguationLabel ?? "")
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(existing == nil ? AppLocalization.string("添加家庭成员") : AppLocalization.string("编辑家庭成员"))
                .font(.title2.weight(.semibold))
            TextField(AppLocalization.string("显示名"), text: $name)
                .disabled(isSaving)
            TextField(AppLocalization.string("称谓或区分标签（可选）"), text: $label)
                .disabled(isSaving)
            Text(AppLocalization.string("同名时会自动显示区分标签或本地短标识。"))
                .font(.caption)
                .foregroundStyle(KinlogueTheme.onVariant)
            if let errorMessage {
                KinlogueStatusLabel(errorMessage, tone: .danger)
                    .font(.caption)
                    .accessibilityLabel(AppLocalization.string("错误：\(errorMessage)"))
            }
            HStack {
                Spacer()
                Button(AppLocalization.string("取消")) { dismiss() }
                    .buttonStyle(.kinlogueSecondary)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                    .accessibilityIdentifier("member-edit-cancel")
                Button(existing == nil ? AppLocalization.string("添加") : AppLocalization.string("保存")) {
                    isSaving = true
                    errorMessage = nil
                    Task {
                        if await onSave(name, label.isEmpty ? nil : label) {
                            dismiss()
                        } else {
                            errorMessage = existing == nil ? AppLocalization.string("无法添加家庭成员，请稍后再试。") : AppLocalization.string("无法保存家庭成员，请稍后再试。")
                        }
                        isSaving = false
                    }
                }
                .buttonStyle(.kinloguePrimary)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                .accessibilityIdentifier("member-edit-save")
            }
        }
        .padding(28)
        .frame(width: 430)
        .kinlogueSheetCanvas()
        .interactiveDismissDisabled(isSaving)
    }
}
