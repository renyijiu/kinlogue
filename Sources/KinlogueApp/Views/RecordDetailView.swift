import KinlogueCore
import SwiftUI

struct RecordDetailView: View {
    let record: HealthRecord?
    let memberLabel: String?
    let original: OriginalDocumentPayload?
    let isOriginalLoading: Bool
    let originalSources: ReportSources?
    let selectedOriginalSourceID: ReportSource.ID?
    let onSelectOriginalSource: (ReportSource.ID) -> Void
    let onOpenOriginal: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    init(
        record: HealthRecord?,
        memberLabel: String?,
        original: OriginalDocumentPayload?,
        isOriginalLoading: Bool,
        originalSources: ReportSources? = nil,
        selectedOriginalSourceID: ReportSource.ID? = nil,
        onSelectOriginalSource: @escaping (ReportSource.ID) -> Void = { _ in },
        onOpenOriginal: @escaping () -> Void,
        onEdit: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.record = record
        self.memberLabel = memberLabel
        self.original = original
        self.isOriginalLoading = isOriginalLoading
        self.originalSources = originalSources
        self.selectedOriginalSourceID = selectedOriginalSourceID
        self.onSelectOriginalSource = onSelectOriginalSource
        self.onOpenOriginal = onOpenOriginal
        self.onEdit = onEdit
        self.onDelete = onDelete
    }

    var body: some View {
        VSplitView {
            ScrollView {
                if let record {
                    recordSummary(record)
                } else {
                    ContentUnavailableView(
                        isOriginalLoading ? AppLocalization.string("正在读取记录与本机原件…") : AppLocalization.string("选择一条记录"),
                        systemImage: isOriginalLoading ? "hourglass" : "doc.richtext",
                        description: Text(isOriginalLoading
                            ? AppLocalization.string("原件读取完成后会一次显示完整详情。")
                            : AppLocalization.string("这里会显示已确认字段和原件。"))
                    )
                    .frame(maxWidth: .infinity, minHeight: 180)
                }
            }
            .frame(minHeight: 180, idealHeight: 280)

            VStack(alignment: .leading, spacing: 10) {
                Label(AppLocalization.string("原件"), systemImage: "doc.richtext")
                    .font(.headline)
                    .foregroundStyle(KinlogueTheme.primary)
                Divider()
                Group {
                    if record == nil {
                        ContentUnavailableView(
                            isOriginalLoading ? AppLocalization.string("正在读取本机原件…") : AppLocalization.string("选择记录后显示原件"),
                            systemImage: isOriginalLoading ? "hourglass" : "doc.richtext"
                        )
                        .frame(minHeight: 260)
                    } else if let originalSources {
                        OrderedOriginalDocumentView(
                            sources: originalSources,
                            selectedSourceID: selectedOriginalSourceID,
                            payload: original,
                            isLoading: isOriginalLoading,
                            onSelectSource: onSelectOriginalSource,
                            presentation: .inline(onOpenOriginal: onOpenOriginal)
                        )
                            .frame(minHeight: 300)
                    } else if let original {
                        OriginalDocumentFitPreview(
                            payload: original,
                            onOpenOriginal: onOpenOriginal
                        )
                            .frame(minHeight: 300)
                    } else {
                        ContentUnavailableView(AppLocalization.string("原件不可用"), systemImage: "doc.questionmark")
                            .frame(minHeight: 260)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(12)
            .background(KinlogueTheme.container, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(KinlogueTheme.outline))
            .accessibilityIdentifier("record-original-pane")
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .frame(minHeight: 300, idealHeight: 420)
        }
    }

    private func recordSummary(_ record: HealthRecord) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(record.title?.transcription ?? record.reportType?.transcription ?? AppLocalization.string("健康记录"))
                        .font(.title2.weight(.semibold))
                    Text(memberLabel ?? AppLocalization.string("家庭成员"))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(AppLocalization.string("编辑"), action: onEdit)
                Button(AppLocalization.string("删除记录"), role: .destructive, action: onDelete)
                Text(record.timelineDate.map {
                    ReportDateSemantics.formatted($0, style: .medium)
                } ?? AppLocalization.string("日期未知"))
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .kinlogueChip()
            }

            if let reportedResults = record.reportedResults {
                DetailCard(title: AppLocalization.string("检查结果"), systemImage: "list.bullet.rectangle") {
                    Text(reportedResults.transcription)
                        .textSelection(.disabled)
                    SourcePages(field: reportedResults, sources: record.sources)
                }
            }

            DetailCard(title: AppLocalization.string("检查结论"), systemImage: "text.quote") {
                if let conclusion = record.conclusion {
                    Text(conclusion.transcription)
                        .textSelection(.disabled)
                    SourcePages(field: conclusion, sources: record.sources)
                } else {
                    Text(AppLocalization.string("原报告未提供结论"))
                        .foregroundStyle(.secondary)
                }
            }

            if !record.abnormalItems.isEmpty {
                DetailCard(title: AppLocalization.string("报告自带标记"), systemImage: "arrow.up.arrow.down") {
                    ForEach(record.abnormalItems, id: \.self) { item in
                        Text(item.transcription)
                            .textSelection(.disabled)
                        SourcePages(field: item, sources: record.sources)
                    }
                }
            }

            DetailCard(title: AppLocalization.string("已确认信息"), systemImage: "checkmark.seal") {
                MetadataRow(label: AppLocalization.string("医院"), field: record.organization, sources: record.sources)
                MetadataRow(label: AppLocalization.string("科室"), field: record.department, sources: record.sources)
                MetadataRow(label: AppLocalization.string("报告类型"), field: record.reportType, sources: record.sources)
            }

            if !record.notes.isEmpty {
                DetailCard(title: AppLocalization.string("我的备注"), systemImage: "note.text") {
                    ForEach(record.notes) { note in Text(note.text) }
                }
            }
        }
        .padding(24)
    }
}

private struct DetailCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(KinlogueTheme.primary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(KinlogueTheme.container, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(KinlogueTheme.outline))
    }
}

private struct MetadataRow: View {
    let label: String
    let field: SourceField?
    let sources: ReportSources

    var body: some View {
        if let field, !field.transcription.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(label).foregroundStyle(.secondary).frame(width: 72, alignment: .leading)
                    Text(field.transcription)
                }
                SourcePages(field: field, sources: sources)
            }
        }
    }
}

private struct SourcePages: View {
    let field: SourceField
    let sources: ReportSources

    var body: some View {
        Text(field.sourceDescription(for: sources))
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityLabel(field.sourceAccessibilityLabel(for: sources))
    }
}

extension SourceField {
    func sourcePageNumbersDescription(for sources: ReportSources) -> String {
        Set(references.compactMap { $0.logicalPage(in: sources) })
            .sorted()
            .map(String.init)
            .joined(separator: AppLocalization.string("、"))
    }

    func sourceDescription(for sources: ReportSources) -> String {
        if entryMethod == .manual { return AppLocalization.string("来源：人工录入") }
        let pages = sourcePageNumbersDescription(for: sources)
        return pages.isEmpty ? AppLocalization.string("来源位置不可用") : AppLocalization.string("来源：原件第 \(pages) 页")
    }

    func sourceAccessibilityLabel(for sources: ReportSources) -> String {
        if entryMethod == .manual { return AppLocalization.string("来源人工录入") }
        let pages = sourcePageNumbersDescription(for: sources)
        return pages.isEmpty ? AppLocalization.string("来源位置不可用") : AppLocalization.string("来源原件第 \(pages) 页")
    }
}
