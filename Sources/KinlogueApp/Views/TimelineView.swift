import KinlogueCore
import SwiftUI

struct TimelineView: View {
    @ObservedObject var comparisonModel: ComparisonModel
    let sections: [AppTimelineSection]
    let searchResults: [LibraryReportSummary]
    let isSearching: Bool
    let selectedRecordID: HealthRecord.ID?
    let memberLabel: (LibraryReportSummary) -> String
    let dicomMemberLabel: (DICOMStudySummary) -> String
    let onSelect: (HealthRecord.ID) -> Void
    let onSelectDICOM: (DICOMStudy.ID) -> Void
    let onImport: () -> Void
    let pageState: AppPageState
    let hasMore: Bool
    let hasDamage: Bool
    let onLoadMore: () -> Void
    let onRetry: () -> Void

    var body: some View {
        if displayedEntriesAreEmpty && pageState == .loading {
            ProgressView(AppLocalization.string("正在载入记录…"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if displayedEntriesAreEmpty && (pageState == .failed || hasDamage || hasMore) {
            VStack(spacing: 12) {
                Text(pageState == .failed ? AppLocalization.string("无法载入记录") : AppLocalization.string("部分资料无法读取"))
                pageControls
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if displayedEntriesAreEmpty {
            ContentUnavailableView {
                Label(isSearching ? AppLocalization.string("没有匹配记录") : AppLocalization.string("还没有健康记录"), systemImage: "doc.text.magnifyingglass")
            } description: {
                Text(isSearching ? AppLocalization.string("搜索只会查看已经确认的字段。") : AppLocalization.string("导入 PDF 或图片，确认后会出现在时间线。"))
            } actions: {
                if !isSearching {
                    Button(AppLocalization.string("导入第一份报告…"), action: onImport)
                        .buttonStyle(.kinloguePrimary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if hasDamage { Text(AppLocalization.string("部分资料无法读取")).foregroundStyle(.secondary) }
                    if isSearching {
                        ForEach(searchResults) { record in
                            TimelineCard(
                                record: record,
                                memberLabel: memberLabel(record),
                                isSelected: record.id == selectedRecordID,
                                comparisonModel: comparisonModel,
                                onSelect: onSelect
                            )
                        }
                    } else {
                        ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                            Text(sectionTitle(section.group))
                                .font(.headline)
                                .foregroundStyle(KinlogueTheme.primary)
                                .padding(.top, 22)
                                .padding(.bottom, 10)
                            ForEach(section.entries) { entry in
                                switch entry {
                                case .record(let record):
                                    TimelineCard(
                                        record: record,
                                        memberLabel: memberLabel(record),
                                        isSelected: record.id == selectedRecordID,
                                        comparisonModel: comparisonModel,
                                        onSelect: onSelect
                                    )
                                case .dicomStudy(let study):
                                    DICOMTimelineCard(
                                        study: study,
                                        memberLabel: dicomMemberLabel(study),
                                        onSelect: onSelectDICOM
                                    )
                                }
                            }
                        }
                    }
                    pageControls.padding(.top, 16)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
        }
    }

    @ViewBuilder private var pageControls: some View {
        if pageState == .loading {
            ProgressView(AppLocalization.string("正在载入记录…"))
        } else if pageState == .failed {
            Button(AppLocalization.string("重试载入"), action: onRetry)
                .accessibilityHint(AppLocalization.string("重新载入当前查询"))
        } else if hasMore {
            Button(AppLocalization.string("载入更多记录"), action: onLoadMore)
                .accessibilityHint(AppLocalization.string("载入下一页记录"))
        }
    }

    private var displayedEntriesAreEmpty: Bool {
        isSearching ? searchResults.isEmpty : sections.allSatisfy(\.entries.isEmpty)
    }

    private func sectionTitle(_ group: TimelineDateGroup) -> String {
        switch group {
        case .dated(let date):
            ReportDateSemantics.formatted(date, style: .long)
        case .unknown: AppLocalization.string("日期未知")
        }
    }
}

private struct DICOMTimelineCard: View {
    let study: DICOMStudySummary
    let memberLabel: String
    let onSelect: (DICOMStudy.ID) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 0) {
                Circle()
                    .fill(KinlogueTheme.primary)
                    .frame(width: 12, height: 12)
                Rectangle()
                    .fill(KinlogueTheme.primary.opacity(0.25))
                    .frame(width: 2, height: 82)
            }
            Button {
                onSelect(study.id)
            } label: {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Label(
                            AppLocalization.string("医学影像检查"),
                            systemImage: "waveform.path.ecg.rectangle"
                        )
                        .font(.headline)
                        Spacer()
                        Text(memberLabel)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .kinlogueChip()
                    }
                    Text(AppLocalization.string("保留 \(study.retainedObjectCount) 个对象"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.kinlogueCard(isHighlighted: false))
            .accessibilityLabel(AppLocalization.string("医学影像检查"))
            .accessibilityValue(memberLabel)
            .accessibilityHint(AppLocalization.string("查看影像"))
        }
    }
}

private struct TimelineCard: View {
    let record: LibraryReportSummary
    let memberLabel: String
    let isSelected: Bool
    @ObservedObject var comparisonModel: ComparisonModel
    let onSelect: (HealthRecord.ID) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 0) {
                Circle()
                    .fill(KinlogueTheme.primary)
                    .frame(width: 12, height: 12)
                Rectangle()
                    .fill(KinlogueTheme.primary.opacity(0.25))
                    .frame(width: 2, height: 82)
            }
            Button {
                if comparisonModel.isSelecting {
                    comparisonModel.toggle(record)
                } else {
                    onSelect(record.id)
                }
            } label: {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        if comparisonModel.isSelecting {
                            Image(systemName: comparisonModel.isSelected(record.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(KinlogueTheme.primary)
                                .accessibilityHidden(true)
                        }
                        Text(record.title ?? record.reportType ?? AppLocalization.string("健康记录"))
                            .font(.headline)
                        Spacer()
                        Text(memberLabel)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .kinlogueChip()
                    }
                    if let organization = record.organization {
                        Label(organization, systemImage: "building.2")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(record.conclusion ?? AppLocalization.string("原报告未提供结论"))
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                }
            }
            .buttonStyle(.kinlogueCard(isHighlighted: isHighlighted))
            .accessibilityLabel(localizedAccessibilityLabel)
            .accessibilityValue(comparisonModel.isSelected(record.id) ? AppLocalization.string("已加入比较") : AppLocalization.string("未加入比较"))
            .accessibilityHint(comparisonModel.isSelecting ? AppLocalization.string("按下以切换比较选择") : AppLocalization.string("打开已确认字段和原件"))
        }
    }

    private var isHighlighted: Bool {
        comparisonModel.isSelecting ? comparisonModel.isSelected(record.id) : isSelected
    }

    private var localizedAccessibilityLabel: String {
        let recordType = record.reportType
            ?? AppLocalization.string("健康记录")
        return AppLocalization.string("\(memberLabel)，\(recordType)")
    }
}
