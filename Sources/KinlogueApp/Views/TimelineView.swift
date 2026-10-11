import KinlogueCore
import SwiftUI

struct TimelineFilterBar: View {
    @Binding var filter: AppTimelineFilter

    var body: some View {
        HStack(spacing: 8) {
            ForEach(AppTimelineFilter.allCases, id: \.self) { option in
                let isSelected = filter == option
                Button {
                    filter = option
                } label: {
                    HStack(spacing: 4) {
                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.caption2.weight(.bold))
                                .accessibilityHidden(true)
                        }
                        Text(title(for: option))
                    }
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .kinlogueChip(isSelected ? .selected : .neutral)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AppLocalization.string("时间线内容"))
    }

    private func title(for option: AppTimelineFilter) -> String {
        switch option {
        case .all: AppLocalization.string("全部")
        case .reports: AppLocalization.string("报告")
        case .imaging: AppLocalization.string("影像")
        }
    }
}

struct TimelineDetailContainer<RecordDetail: View>: View {
    @ObservedObject var dicomLibraryModel: DICOMLibraryModel
    let onReviewDICOM: (DICOMStudy.ID) -> Void
    let onViewDICOMImages: (DICOMStudy.ID) -> Void
    @ViewBuilder let recordDetail: () -> RecordDetail

    var body: some View {
        if let study = dicomLibraryModel.selectedStudy {
            DICOMStudyDetailView(
                study: study,
                memberLabel: dicomLibraryModel.memberLabel(for: study),
                onReview: onReviewDICOM,
                onViewImages: onViewDICOMImages
            )
        } else {
            recordDetail()
        }
    }
}

struct TimelineView: View {
    @ObservedObject var comparisonModel: ComparisonModel
    @ObservedObject var dicomLibraryModel: DICOMLibraryModel
    let sections: [AppTimelineSection]
    let searchResults: [HealthRecord]
    let isSearching: Bool
    let filter: AppTimelineFilter
    let selectedRecordID: HealthRecord.ID?
    let memberLabel: (HealthRecord) -> String
    let onSelect: (HealthRecord.ID) -> Void
    let onSelectDICOM: (DICOMStudy.ID) -> Void
    let onImport: () -> Void

    var body: some View {
        if displayedEntriesAreEmpty {
            ContentUnavailableView {
                Label(emptyTitle, systemImage: emptySystemImage)
            } description: {
                Text(emptyDescription)
            } actions: {
                if !isSearching, filter != .imaging {
                    Button(AppLocalization.string("导入第一份报告…"), action: onImport)
                        .buttonStyle(.kinloguePrimary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
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
                                        memberLabel: dicomLibraryModel.memberLabel(for: study),
                                        isSelected: study.id == dicomLibraryModel.selectedStudyID,
                                        isSelectingComparison: comparisonModel.isSelecting,
                                        onSelect: onSelectDICOM
                                    )
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
        }
    }

    private var displayedEntriesAreEmpty: Bool {
        isSearching ? searchResults.isEmpty : sections.allSatisfy(\.entries.isEmpty)
    }

    private var emptyTitle: String {
        if isSearching { return AppLocalization.string("没有匹配记录") }
        return filter == .imaging
            ? AppLocalization.string("还没有已确认的医学影像")
            : AppLocalization.string("还没有健康记录")
    }

    private var emptySystemImage: String {
        !isSearching && filter == .imaging
            ? "waveform.path.ecg.rectangle"
            : "doc.text.magnifyingglass"
    }

    private var emptyDescription: String {
        switch (isSearching, filter == .imaging) {
        case (true, true):
            AppLocalization.string("医学影像不进入搜索。切换到“全部”或“报告”后再搜索。")
        case (true, false):
            AppLocalization.string("搜索只会查看已经确认的字段。")
        case (false, true):
            AppLocalization.string("导入 DICOM 文件夹并确认家庭成员与检查日期后，会显示在这里。")
        case (false, false):
            AppLocalization.string("导入 PDF 或图片，确认后会出现在时间线。")
        }
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
    let isSelected: Bool
    let isSelectingComparison: Bool
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
            .buttonStyle(.kinlogueCard(isHighlighted: isSelected))
            .disabled(isSelectingComparison)
            .accessibilityLabel(AppLocalization.string("医学影像检查"))
            .accessibilityValue(memberLabel)
            .accessibilityHint(AppLocalization.string("选择后可查看检查摘要"))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }
}

private struct TimelineCard: View {
    let record: HealthRecord
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
                        Text(record.title?.transcription ?? record.reportType?.transcription ?? AppLocalization.string("健康记录"))
                            .font(.headline)
                        Spacer()
                        Text(memberLabel)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .kinlogueChip()
                    }
                    if let organization = record.organization?.transcription {
                        Label(organization, systemImage: "building.2")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(record.conclusion?.transcription ?? AppLocalization.string("原报告未提供结论"))
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
        let recordType = record.reportType?.transcription
            ?? AppLocalization.string("健康记录")
        return AppLocalization.string("\(memberLabel)，\(recordType)")
    }
}
