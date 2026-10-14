import KinlogueCore
import SwiftUI

struct LANInboxView: View {
    private struct MemberPickerOption: Identifiable {
        let id: FamilyMember.ID
        let label: String
    }

    @ObservedObject var model: LANInboxModel
    let members: [LibraryMemberSummary]
    let onOpenDuplicate: (LANReportDuplicateDestination) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.isLoading && model.items.isEmpty {
                ProgressView(AppLocalization.string("正在加载待确认队列…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.items.isEmpty && !model.hasMore && model.storage?.itemCount == 0 {
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
                    // Opaque so the system selection highlight can never show through.
                    .listRowBackground(
                        KinlogueTheme.surface.overlay(
                            model.selectedItemIDs.contains(item.id)
                                ? KinlogueTheme.selection
                                : Color.clear
                        )
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
                if model.hasMore {
                    Button(AppLocalization.string("加载更多待确认项")) { Task { await model.loadMore() } }
                        .disabled(model.isLoadingMore)
                        .padding(8)
                    if model.isLoadingMore { ProgressView() }
                }
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
                        Text(model.usesContentByteTotals
                            ? AppLocalization.string("\(storage.itemCount) 个唯一原件 · 原件内容 \(ByteCountFormatter.string(fromByteCount: Int64(storage.sourceByteCount), countStyle: .file))")
                            : AppLocalization.string("\(storage.itemCount) 个唯一原件 · 实际占用 \(ByteCountFormatter.string(fromByteCount: Int64(storage.totalPhysicalByteCount), countStyle: .file))"))
                            .font(.caption)
                            .foregroundStyle(KinlogueTheme.onVariant)
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
            if model.hasDamagedItems {
                Label(AppLocalization.string("部分资料无法读取"), systemImage: "exclamationmark.triangle")
                    .font(.caption)
            }
            if let error = model.userErrorMessage {
                KinlogueStatusLabel(error, tone: .danger)
                    .font(.caption)
                if model.canRetryQueueLoad {
                    Button(AppLocalization.string("重试载入")) {
                        Task { await model.retryQueueLoad() }
                    }
                    .buttonStyle(.kinlogueSecondary)
                    .disabled(model.isLoading || model.isLoadingMore)
                }
            }
        }
        .padding(16)
    }

    private var archiveActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text(AppLocalization.string("已选 \(model.archiveOrder.count) 个原件，作为 1 份报告"))
                    .foregroundStyle(KinlogueTheme.onVariant)
                Spacer(minLength: 0)
                Button(AppLocalization.string("删除所选…"), role: .destructive) {
                    model.requestDelete(model.selectedItemIDs)
                }
                .buttonStyle(.kinlogueDestructive)
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
        // Centered: the icon-only close button has no text baseline to align to.
        HStack(spacing: 8) {
            Image(systemName: KinlogueStatusTone.success.systemImage)
                .foregroundStyle(KinlogueTheme.success)
            if notice.draftID != nil {
                Text(AppLocalization.string("已作为 1 份报告加入待确认。"))
            } else {
                Text(AppLocalization.string("原件与已有报告相同，未重复创建。"))
            }
            if let destination = notice.duplicateDestination {
                Button(AppLocalization.string("查看已有资料")) {
                    onOpenDuplicate(destination)
                }
                .buttonStyle(.kinlogueGhost)
            }
            Spacer()
            Button {
                model.archiveNotice = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.kinlogueGhost(.neutral))
            .accessibilityLabel(AppLocalization.string("关闭归档结果"))
        }
        .font(.callout)
        .foregroundStyle(KinlogueTheme.onSurface)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .kinloguePanel(.container, cornerRadius: KinlogueTheme.Radius.control)
    }

    private var memberPickerOptions: [MemberPickerOption] {
        let labels = LibraryMemberSummary.labels( members)
        return LibraryMemberSummary.selectable( members).map { member in
            MemberPickerOption(
                id: member.id,
                label: labels[member.id] ?? member.displayName
            )
        }
    }

    private var activeMemberIDs: Set<FamilyMember.ID> {
        Set(LibraryMemberSummary.selectable( members).map(\.id))
    }

    private func clearArchivedMemberSelection(activeIDs: Set<FamilyMember.ID>) {
        if let selected = model.selectedMemberID, !activeIDs.contains(selected) {
            model.selectedMemberID = nil
        }
    }
}
