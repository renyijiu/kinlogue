import AppKit
import KinlogueCore
import SwiftUI

struct ComparisonSelectionBar: View {
    @ObservedObject var model: ComparisonModel
    let onCompare: () -> Void

    var body: some View {
        if model.isSelecting {
            HStack(spacing: 12) {
                Label(AppLocalization.string("比较选择 \(model.selectionCountText)"), systemImage: "rectangle.split.2x1")
                    .font(.headline)
                    .foregroundStyle(KinlogueTheme.primary)
                    .accessibilityLabel(AppLocalization.string("比较选择，已选择 \(model.selectionCountText)"))
                if let error = model.errorMessage {
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }
                Spacer()
                Button(AppLocalization.string("清空")) { model.clearSelection() }
                    .disabled(model.selectedRecordIDs.isEmpty)
                Button(AppLocalization.string("取消")) { model.cancelSelection() }
                Button(AppLocalization.string("比较"), action: onCompare)
                    .buttonStyle(.kinloguePrimary)
                    .disabled(!model.canCompare)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(KinlogueTheme.primary.opacity(0.09))
            .onChange(of: model.announcement) {
                guard !model.announcement.isEmpty else { return }
                announce(model.announcement)
            }
            .onAppear {
                announce(model.announcement.isEmpty
                    ? AppLocalization.string("比较选择模式，已选择 \(model.selectionCountText)")
                    : model.announcement)
            }
        }
    }

    private func announce(_ message: String) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }
}

struct ComparisonToolbarItem: View {
    @ObservedObject var model: ComparisonModel
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            Label(
                model.isSelecting ? AppLocalization.string("取消比较") : AppLocalization.string("比较两条记录"),
                systemImage: "rectangle.split.2x1"
            )
        }
        .help(model.isSelecting ? AppLocalization.string("退出比较选择") : AppLocalization.string("选择两条已确认记录进行比较"))
    }
}

struct ComparisonView: View {
    @ObservedObject var model: ComparisonModel
    let memberLabels: [FamilyMember.ID: String]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(AppLocalization.string("并排查看历史原件"))
                        .font(.title2.weight(.semibold))
                    Text(AppLocalization.string("仅展示确认过的原文，不生成趋势、判断或建议。"))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(AppLocalization.string("关闭")) { model.closeComparison() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)
            Divider()

            if let comparison = model.comparison {
                HSplitView {
                    ComparisonColumn(
                        sideName: AppLocalization.string("左侧"),
                        pane: comparison.left,
                        memberLabel: memberLabels[comparison.left.memberID] ?? AppLocalization.string("家庭成员"),
                        original: model.leftOriginal,
                        loadState: model.leftLoadState,
                        selectedSourceID: model.leftSelectedSourceID,
                        onSelectSource: { sourceID in
                            Task { await model.selectOriginalSource(sourceID, side: .left) }
                        }
                    )
                    ComparisonColumn(
                        sideName: AppLocalization.string("右侧"),
                        pane: comparison.right,
                        memberLabel: memberLabels[comparison.right.memberID] ?? AppLocalization.string("家庭成员"),
                        original: model.rightOriginal,
                        loadState: model.rightLoadState,
                        selectedSourceID: model.rightSelectedSourceID,
                        onSelectSource: { sourceID in
                            Task { await model.selectOriginalSource(sourceID, side: .right) }
                        }
                    )
                }
            } else {
                ProgressView(AppLocalization.string("正在准备比较…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 1080, minHeight: 720)
        .background(KinlogueTheme.surface)
        .onDisappear {
            if model.isPresented { model.closeComparison() }
        }
    }
}

private struct ComparisonColumn: View {
    let sideName: String
    let pane: RecordComparisonPane
    let memberLabel: String
    let original: OriginalDocumentPayload?
    let loadState: ComparisonOriginalLoadState
    let selectedSourceID: ReportSource.ID?
    let onSelectSource: (ReportSource.ID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(sideName)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .kinlogueChip()
                        Text(memberLabel).font(.headline)
                        Spacer()
                        Text(pane.timelineDate.map {
                            ReportDateSemantics.formatted($0, style: .medium)
                        } ?? AppLocalization.string("日期未知"))
                            .foregroundStyle(.secondary)
                    }
                    Text(pane.title ?? AppLocalization.string("健康记录"))
                        .font(.title3.weight(.semibold))
                    if case .verbatim(let value) = pane.reportedResults {
                        Text(AppLocalization.string("检查结果"))
                            .font(.headline)
                            .foregroundStyle(KinlogueTheme.primary)
                        Text(value)
                            .textSelection(.disabled)
                    }
                    Text(AppLocalization.string("检查结论"))
                        .font(.headline)
                        .foregroundStyle(KinlogueTheme.primary)
                    conclusionText
                        .textSelection(.disabled)
                    if !pane.sourceMarkedAbnormalItems.isEmpty {
                        Text(AppLocalization.string("报告自带标记"))
                            .font(.subheadline.weight(.semibold))
                        ForEach(pane.sourceMarkedAbnormalItems, id: \.self) { item in
                            Text(item).font(.subheadline).textSelection(.disabled)
                        }
                    }
                }
                .padding(18)
            }
            .frame(minHeight: 150, idealHeight: 220, maxHeight: 280)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(AppLocalization.string("\(sideName)记录，\(memberLabel)"))

            Divider()
            ComparisonOriginalPane(
                sideName: sideName,
                sources: pane.sources,
                selectedSourceID: selectedSourceID,
                payload: original,
                loadState: loadState,
                onSelectSource: onSelectSource
            )
            .frame(minHeight: 340)
        }
        .frame(minWidth: 500)
        .background(KinlogueTheme.container)
    }

    @ViewBuilder
    private var conclusionText: some View {
        switch pane.conclusion {
        case .verbatim(let value): Text(value)
        case .notProvided: Text(AppLocalization.string("原报告未提供结论")).foregroundStyle(.secondary)
        }
    }
}
