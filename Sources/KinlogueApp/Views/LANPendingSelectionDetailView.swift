import KinlogueCore
import SwiftUI

struct LANPendingSelectionDetailView: View {
    @ObservedObject var model: LANInboxModel
    @State private var previewItemID: LANInboxItem.ID?
    @State private var loadedPreview: LoadedPreview?
    @State private var isPreviewLoading = false
    @State private var previewFailed = false

    var body: some View {
        Group {
            if model.orderedSelectedItems.isEmpty {
                ContentUnavailableView {
                    Label(AppLocalization.string("选择待确认资料"), systemImage: "checklist")
                } description: {
                    Text(AppLocalization.string("可单选一个原件，或多选后在这里确认报告页序。"))
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(AppLocalization.string("作为 1 份报告"))
                                .font(.title2.bold())
                            Text(AppLocalization.string("共 \(model.orderedSelectedItems.count) 个原件；顺序只影响这次报告。"))
                                .foregroundStyle(.secondary)
                        }
                        Divider()
                        Text(AppLocalization.string("报告页序"))
                            .font(.headline)
                        ForEach(Array(model.orderedSelectedItems.enumerated()), id: \.element.id) {
                            index, item in
                            HStack(spacing: 12) {
                                Text("\(index + 1)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24)
                                Button {
                                    previewItemID = item.id
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.displayName.rawValue)
                                            .foregroundStyle(KinlogueTheme.onSurface)
                                        Text(ByteCountFormatter.string(
                                            fromByteCount: Int64(item.contentIdentity.byteCount),
                                            countStyle: .file
                                        ))
                                        .font(.caption)
                                        .foregroundStyle(KinlogueTheme.onVariant)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(AppLocalization.string("查看第 \(index + 1) 个原件"))
                                .accessibilityAddTraits(
                                    previewItemID == item.id ? .isSelected : []
                                )
                                Button {
                                    Task { await model.openPreview(itemID: item.id) }
                                } label: {
                                    Image(systemName: "eye")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(AppLocalization.string("查看第 \(index + 1) 个原件"))
                                Button {
                                    model.moveArchiveItem(itemID: item.id, offset: -1)
                                } label: {
                                    Image(systemName: "arrow.up")
                                }
                                .buttonStyle(.borderless)
                                .disabled(index == 0 || model.busyItemIDs.contains(item.id))
                                .accessibilityLabel(AppLocalization.string("将 \(item.displayName.rawValue) 向前移动"))
                                Button {
                                    model.moveArchiveItem(itemID: item.id, offset: 1)
                                } label: {
                                    Image(systemName: "arrow.down")
                                }
                                .buttonStyle(.borderless)
                                .disabled(
                                    index == model.orderedSelectedItems.count - 1
                                        || model.busyItemIDs.contains(item.id)
                                )
                                .accessibilityLabel(AppLocalization.string("将 \(item.displayName.rawValue) 向后移动"))
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 8)
                            .background(
                                previewItemID == item.id
                                    ? KinlogueTheme.selection
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                            if index < model.orderedSelectedItems.count - 1 { Divider() }
                        }
                        Divider()
                        inlinePreview
                        Divider()
                        Text(AppLocalization.string("归档后会生成一份待确认报告；在报告中确认前不会进入时间线。"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(24)
                }
            }
        }
        .background(KinlogueTheme.surface)
        .navigationTitle(AppLocalization.string("报告顺序"))
        .onAppear { reconcilePreviewSelection() }
        .onChange(of: model.archiveOrder) { reconcilePreviewSelection() }
        .task(id: previewItem?.id) { await loadPreview() }
    }

    @ViewBuilder
    private var inlinePreview: some View {
        if let item = previewItem {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(AppLocalization.string("完整预览"))
                        .font(.headline)
                    Spacer(minLength: 8)
                    if let index = model.orderedSelectedItems.firstIndex(where: { $0.id == item.id }) {
                        Text(AppLocalization.string("第 \(index + 1) 个，共 \(model.orderedSelectedItems.count) 个"))
                        .font(.caption)
                        .foregroundStyle(KinlogueTheme.onVariant)
                    }
                }

                if isPreviewLoading {
                    ProgressView(AppLocalization.string("正在准备原件…"))
                        .frame(maxWidth: .infinity, minHeight: 260)
                } else if let loadedPreview, loadedPreview.itemID == item.id {
                    OriginalDocumentFitPreview(
                        payload: loadedPreview.payload,
                        onOpenOriginal: {
                            model.presentPreview(
                                itemID: item.id,
                                payload: loadedPreview.payload
                            )
                        }
                    )
                    .id(item.id)
                    .frame(minHeight: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(KinlogueTheme.outline)
                    }
                    .accessibilityIdentifier("lan-inline-original-preview")
                } else {
                    ContentUnavailableView(
                        previewFailed
                            ? AppLocalization.string("原件无法显示")
                            : AppLocalization.string("正在准备原件…"),
                        systemImage: previewFailed ? "doc.questionmark" : "doc.richtext"
                    )
                    .frame(maxWidth: .infinity, minHeight: 260)
                }
            }
        }
    }

    private var previewItem: LANInboxItem? {
        let selected = model.orderedSelectedItems
        if let previewItemID,
           let selectedItem = selected.first(where: { $0.id == previewItemID }) {
            return selectedItem
        }
        return selected.first
    }

    private func reconcilePreviewSelection() {
        let selectedIDs = model.orderedSelectedItems.map(\.id)
        if let previewItemID, selectedIDs.contains(previewItemID) { return }
        previewItemID = selectedIDs.first
    }

    @MainActor
    private func loadPreview() async {
        guard let item = previewItem else {
            loadedPreview = nil
            isPreviewLoading = false
            previewFailed = false
            return
        }
        loadedPreview = nil
        isPreviewLoading = true
        previewFailed = false
        do {
            let payload = try await model.loadPreviewPayload(itemID: item.id)
            guard !Task.isCancelled else { return }
            loadedPreview = LoadedPreview(itemID: item.id, payload: payload)
            isPreviewLoading = false
        } catch {
            guard !Task.isCancelled else { return }
            isPreviewLoading = false
            previewFailed = true
        }
    }

    private struct LoadedPreview {
        let itemID: LANInboxItem.ID
        let payload: OriginalDocumentPayload
    }
}
