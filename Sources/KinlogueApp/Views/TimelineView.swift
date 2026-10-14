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
                }
                .buttonStyle(.kinlogueChip(isSelected: isSelected))
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
    let searchResults: [LibraryReportSummary]
    /// The trimmed query the search results answer; empty on the timeline.
    let searchTerm: String
    let filter: AppTimelineFilter
    let selectedRecordID: HealthRecord.ID?
    /// False on one member's timeline, where every card would repeat the
    /// member the window title already names.
    let showsMemberLabels: Bool
    let memberLabel: (LibraryReportSummary) -> String
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
                    if hasDamage { Text(AppLocalization.string("部分资料无法读取")).foregroundStyle(KinlogueTheme.onVariant) }
                    if isSearching {
                        ForEach(searchResults) { record in
                            TimelineCard(
                                record: record,
                                memberLabel: memberLabel(record),
                                showsMemberLabel: showsMemberLabels,
                                showsDate: true,
                                highlightTerm: searchTerm,
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
                                        showsMemberLabel: showsMemberLabels,
                                        showsDate: false,
                                        highlightTerm: "",
                                        isSelected: record.id == selectedRecordID,
                                        comparisonModel: comparisonModel,
                                        onSelect: onSelect
                                    )
                                case .dicomStudy(let study):
                                    DICOMTimelineCard(
                                        study: study,
                                        memberLabel: dicomLibraryModel.memberLabel(for: study),
                                        showsMemberLabel: showsMemberLabels,
                                        isSelected: study.id == dicomLibraryModel.selectedStudyID,
                                        isSelectingComparison: comparisonModel.isSelecting,
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
                .buttonStyle(.kinlogueSecondary)
                .accessibilityHint(AppLocalization.string("重新载入当前查询"))
        } else if hasMore {
            Button(AppLocalization.string("载入更多记录"), action: onLoadMore)
                .buttonStyle(.kinlogueSecondary)
                .accessibilityHint(AppLocalization.string("载入下一页记录"))
        }
    }

    private var isSearching: Bool { !searchTerm.isEmpty }

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
    let showsMemberLabel: Bool
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
                        if showsMemberLabel {
                            Text(memberLabel)
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .kinlogueChip()
                        }
                    }
                    Text(AppLocalization.string("保留 \(study.retainedObjectCount) 个对象"))
                        .font(.subheadline)
                        .foregroundStyle(KinlogueTheme.onVariant)
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
    let record: LibraryReportSummary
    let memberLabel: String
    let showsMemberLabel: Bool
    /// Search results have no date sections above them, so each card names its own date.
    let showsDate: Bool
    /// The search term to set in bold wherever the card shows it; empty on the timeline.
    let highlightTerm: String
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
                        Text(SearchHighlight.text(
                            record.title ?? record.reportType ?? AppLocalization.string("健康记录"),
                            term: highlightTerm
                        ))
                            .font(.headline)
                        Spacer()
                        if showsMemberLabel {
                            Text(memberLabel)
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .kinlogueChip()
                        }
                    }
                    if showsDate {
                        Label(dateText, systemImage: "calendar")
                            .font(.subheadline)
                            .foregroundStyle(KinlogueTheme.onVariant)
                    }
                    if let organization = record.organization {
                        Label {
                            Text(SearchHighlight.text(organization, term: highlightTerm))
                        } icon: {
                            Image(systemName: "building.2")
                        }
                            .font(.subheadline)
                            .foregroundStyle(KinlogueTheme.onVariant)
                            .lineLimit(1)
                    }
                    if !record.matchedResultLines.isEmpty {
                        MatchedResultLinesView(
                            lines: record.matchedResultLines,
                            totalCount: record.matchedResultLineCount,
                            term: highlightTerm
                        )
                    } else if let excerpt = record.matchedExcerpt {
                        // Shows where the term was found when the heading does not.
                        Label {
                            Text(SearchHighlight.text(excerpt.displayText, term: highlightTerm))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                        } icon: {
                            Image(systemName: "text.magnifyingglass")
                                .foregroundStyle(KinlogueTheme.onVariant)
                        }
                            .font(.subheadline)
                    } else {
                        Text(record.conclusion ?? AppLocalization.string("原报告未提供结论"))
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                    }
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
        guard showsDate else { return AppLocalization.string("\(memberLabel)，\(recordType)") }
        guard !record.matchedResultLines.isEmpty else {
            if let excerpt = record.matchedExcerpt?.displayText {
                return AppLocalization.string("\(memberLabel)，\(recordType)，\(dateText)，匹配内容：\(excerpt)")
            }
            return AppLocalization.string("\(memberLabel)，\(recordType)，\(dateText)")
        }
        let lines = MatchedResultLinesView.spokenText(
            lines: record.matchedResultLines,
            totalCount: record.matchedResultLineCount
        )
        return AppLocalization.string("\(memberLabel)，\(recordType)，\(dateText)，匹配的结果行：\(lines)")
    }

    private var dateText: String {
        record.timelineDate.map { ReportDateSemantics.formatted($0, style: .medium) }
            ?? AppLocalization.string("日期未知")
    }
}

/// The confirmed result lines a search term was found in, cell by cell as the report printed
/// them. Nothing is parsed, compared or marked; a printed "↑" stays in its own cell.
private struct MatchedResultLinesView: View {
    let lines: [ReportedResultLine]
    let totalCount: Int
    let term: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 4) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    GridRow {
                        ForEach(Array(line.cells.enumerated()), id: \.offset) { index, cell in
                            Text(SearchHighlight.text(cell, term: term))
                                .font(index == 0 ? .subheadline : .subheadline.monospacedDigit())
                                .fontWeight(index == 1 ? .medium : .regular)
                                .foregroundStyle(index < 2 ? KinlogueTheme.onSurface : KinlogueTheme.onVariant)
                                .lineLimit(1)
                        }
                    }
                }
            }
            if totalCount > lines.count {
                Text(AppLocalization.string("还有 \(totalCount - lines.count) 行匹配"))
                    .font(.caption)
                    .foregroundStyle(KinlogueTheme.onVariant)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .kinloguePanel(.container, cornerRadius: KinlogueTheme.Radius.control)
    }

    static func spokenText(lines: [ReportedResultLine], totalCount: Int) -> String {
        var parts = lines.map { $0.cells.joined(separator: " ") }
        if totalCount > lines.count {
            parts.append(AppLocalization.string("还有 \(totalCount - lines.count) 行匹配"))
        }
        return parts.joined(separator: AppLocalization.string("；"))
    }
}

/// Text with every place the search term is found set in bold Primary. The places are found by
/// the localized, case-insensitive search that matched the report; bold keeps them visible
/// without relying on color.
enum SearchHighlight {
    static func text(_ value: String, term: String, locale: Locale = .current) -> AttributedString {
        var attributed = AttributedString(value)
        // A term with NUL takes a guarded path in the match predicate; it is not highlighted.
        guard !term.isEmpty, !term.unicodeScalars.contains(where: { $0.value == 0 }) else { return attributed }
        var searchStart = value.startIndex
        while let found = value.range(of: term, options: .caseInsensitive,
                                      range: searchStart..<value.endIndex, locale: locale),
              !found.isEmpty {
            if let range = Range(found, in: attributed) {
                attributed[range].inlinePresentationIntent = .stronglyEmphasized
                attributed[range].swiftUI.foregroundColor = KinlogueTheme.primary
            }
            searchStart = found.upperBound
        }
        return attributed
    }
}
