import KinlogueCore
import SwiftUI

struct LANInboxView: View {
    private struct MemberPickerOption: Identifiable {
        let id: FamilyMember.ID
        let label: String
    }

    @ObservedObject var model: LANInboxModel
    let members: [FamilyMember]
    let onOpenDuplicate: (LANReportDuplicateDestination) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.items.isEmpty {
                ContentUnavailableView {
                    Label(AppLocalization.string("没有待确认项"), systemImage: "tray")
                } description: {
                    Text(AppLocalization.string("手机上传的唯一原件会出现在这里；处理完后队列会恢复为空。"))
                } actions: {
                    Button(AppLocalization.string("从手机接收")) {
                        Task { await model.prepareReceiving() }
                    }
                    .buttonStyle(.kinloguePrimary)
                    .disabled(model.isLoading)
                }
            } else {
                List(model.items, selection: $model.selectedItemIDs) { item in
                    LANInboxItemRow(
                        item: item,
                        isBusy: model.busyItemIDs.contains(item.id),
                        onPreview: {
                            Task { await model.openPreview(itemID: item.id) }
                        },
                        onRetry: {
                            Task { await model.retry(itemID: item.id) }
                        },
                        onDelete: {
                            model.requestDelete([item.id])
                        }
                    )
                    .listRowBackground(
                        model.selectedItemIDs.contains(item.id)
                            ? KinlogueTheme.container
                            : KinlogueTheme.surface
                    )
                    .tag(item.id)
                    .selectionDisabled(!item.isReviewable)
                    .accessibilityHint(
                        item.isReviewable
                            ? AppLocalization.string("选择后可与其他原件组成一份报告")
                            : AppLocalization.string("可单独重试或删除，不影响其他资料")
                    )
                }
                .scrollContentBackground(.hidden)
                .background(KinlogueTheme.surface)
                archiveActions
            }
        }
        .background(KinlogueTheme.surface)
        .navigationTitle(AppLocalization.string("手机上传"))
        .sheet(item: $model.previewPresentation, onDismiss: {
            model.dismissPreview()
        }) { presentation in
            OriginalDocumentViewer(payload: presentation.payload)
        }
        .confirmationDialog(
            AppLocalization.string("删除所选待确认项？"),
            isPresented: Binding(
                get: { model.pendingDeleteCommand != nil },
                set: { if !$0 { model.cancelDeleteRequest() } }
            )
        ) {
            if let command = model.pendingDeleteCommand {
                Button(AppLocalization.string("删除本机接收副本"), role: .destructive) {
                    Task {
                        await model.confirmDeleteItems(command)
                    }
                }
            }
            Button(AppLocalization.string("取消"), role: .cancel) {}
        } message: {
            Text(AppLocalization.string("只删除待确认队列中的所选原件；已经归档到报告的原件不受影响。"))
        }
        .onChange(of: model.selectedItemIDs) {
            model.reconcileSelectionOrder()
        }
        .onChange(of: activeMemberIDs) { _, activeIDs in
            clearArchivedMemberSelection(activeIDs: activeIDs)
        }
        .onAppear {
            clearArchivedMemberSelection(activeIDs: activeMemberIDs)
            model.reconcileSelectionOrder()
        }
        .onDisappear {
            model.dismissPreview()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(AppLocalization.string("待确认队列"))
                        .font(.title2.bold())
                    if let storage = model.storage {
                        Text(AppLocalization.string("\(model.items.count) 个唯一原件 · 实际占用 \(ByteCountFormatter.string(fromByteCount: Int64(storage.totalPhysicalByteCount), countStyle: .file))"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button {
                    if model.receiverPhase == .active {
                        model.isReceiverSheetPresented = true
                    } else {
                        Task { await model.prepareReceiving() }
                    }
                } label: {
                    Label(
                        model.receiverPhase == .active
                            ? AppLocalization.string("接收中")
                            : AppLocalization.string("从手机接收"),
                        systemImage: model.receiverPhase == .active
                            ? "dot.radiowaves.left.and.right"
                            : "iphone.and.arrow.forward.inward"
                    )
                }
                .buttonStyle(.kinloguePrimary)
                .disabled(
                    model.isLoading
                        || model.receiverPhase == .starting
                        || model.receiverPhase == .stopping
                )
            }
            if let notice = model.archiveNotice { archiveNotice(notice) }
            if let error = model.userErrorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(16)
    }

    private var archiveActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text(AppLocalization.string("已选 \(model.archiveOrder.count) 个原件，作为 1 份报告"))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button(AppLocalization.string("删除所选…"), role: .destructive) {
                    model.requestDelete(model.selectedItemIDs)
                }
                .disabled(
                    model.selectedItemIDs.isEmpty
                        || model.selectedItemIDs.contains(where: model.busyItemIDs.contains)
                )
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    memberPicker.frame(width: 210)
                    LocalizedDatePicker(
                        AppLocalization.string("报告日期"),
                        selection: $model.canonicalReportDate
                    )
                    .fixedSize()
                    Spacer(minLength: 0)
                    archiveButton
                }
                VStack(alignment: .leading, spacing: 8) {
                    memberPicker
                    LocalizedDatePicker(
                        AppLocalization.string("报告日期"),
                        selection: $model.canonicalReportDate
                    )
                    HStack { Spacer(); archiveButton }
                }
            }
        }
        .padding(12)
        .background(KinlogueTheme.container)
        .overlay(alignment: .top) { Divider() }
    }

    private var memberPicker: some View {
        Picker(AppLocalization.string("归档给"), selection: $model.selectedMemberID) {
            Text(AppLocalization.string("选择家庭成员…")).tag(nil as FamilyMember.ID?)
            ForEach(memberPickerOptions) { option in
                Text(option.label).tag(Optional(option.id))
            }
        }
    }

    private var archiveButton: some View {
        Button(AppLocalization.string("作为 1 份报告加入待确认")) {
            Task { await model.archiveSelectedItems() }
        }
        .buttonStyle(.kinloguePrimary)
        .fixedSize(horizontal: true, vertical: false)
        .disabled(!model.canArchiveSelection)
        .accessibilityHint(
            model.selectedMemberID == nil
                ? AppLocalization.string("请先选择家庭成员和报告日期")
                : AppLocalization.string("按右侧显示的顺序创建一份待确认报告")
        )
    }

    private func archiveNotice(_ notice: LANInboxArchiveNotice) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "checkmark.circle")
            if notice.draftID != nil {
                Text(AppLocalization.string("已作为 1 份报告加入待确认。"))
            } else {
                Text(AppLocalization.string("原件与已有报告相同，未重复创建。"))
            }
            if let destination = notice.duplicateDestination {
                Button(AppLocalization.string("查看已有资料")) {
                    onOpenDuplicate(destination)
                }
            }
            Spacer()
            Button {
                model.archiveNotice = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(AppLocalization.string("关闭归档结果"))
        }
        .font(.callout)
        .padding(10)
        .background(KinlogueTheme.container, in: RoundedRectangle(cornerRadius: 9))
    }

    private var memberPickerOptions: [MemberPickerOption] {
        let labels = RecordQuery.selectionLabels(for: members)
        return RecordQuery.selectableMembers(from: members).map { member in
            MemberPickerOption(
                id: member.id,
                label: labels[member.id] ?? member.displayName
            )
        }
    }

    private var activeMemberIDs: Set<FamilyMember.ID> {
        Set(RecordQuery.selectableMembers(from: members).map(\.id))
    }

    private func clearArchivedMemberSelection(activeIDs: Set<FamilyMember.ID>) {
        if let selected = model.selectedMemberID, !activeIDs.contains(selected) {
            model.selectedMemberID = nil
        }
    }
}
