import AppKit
import KinlogueCore
import SwiftUI

struct RecordEditState {
    private(set) var record: HealthRecord
    var memberID: FamilyMember.ID
    var dateSelectionMode: TimelineDateSelectionMode
    var manualTimelineDate: Date
    var title: String
    var organization: String
    var department: String
    var reportType: String
    var reportedResults: String
    var conclusion: String
    var abnormalItems: [String]
    var userNote: String

    init(record: HealthRecord, now: Date = Date()) {
        self.record = record
        memberID = record.memberID
        if let selected = record.timelineDateCandidate {
            if selected.source.entryMethod == .manual {
                dateSelectionMode = .manual
                manualTimelineDate = ReportDateSemantics.pickerDate(from: selected.date) ?? now
            } else {
                dateSelectionMode = .detected(selected.id)
                manualTimelineDate = now
            }
        } else {
            dateSelectionMode = .unknown
            manualTimelineDate = now
        }
        title = record.title?.transcription ?? ""
        organization = record.organization?.transcription ?? ""
        department = record.department?.transcription ?? ""
        reportType = record.reportType?.transcription ?? ""
        reportedResults = record.reportedResults?.transcription ?? ""
        conclusion = record.conclusion?.transcription ?? ""
        abnormalItems = record.abnormalItems.map(\.transcription)
        userNote = record.notes.first?.text ?? ""
    }

    mutating func load(_ latest: HealthRecord, now: Date = Date()) {
        self = RecordEditState(record: latest, now: now)
    }

    func command() -> UpdateRecordCommand {
        UpdateRecordCommand(
            recordID: record.id,
            expectedRevision: record.revision,
            memberID: memberID,
            timelineDateSelection: dateSelectionMode.selection(manualDate: manualTimelineDate),
            title: title,
            organization: organization,
            department: department,
            reportType: reportType,
            reportedResults: reportedResults,
            conclusion: conclusion,
            abnormalItems: abnormalItems,
            userNote: userNote
        )
    }
}

struct RecordEditView: View {
    @Environment(\.dismiss) private var dismiss
    let record: HealthRecord
    let members: [FamilyMember]
    let original: OriginalDocumentPayload?
    let isOriginalLoading: Bool
    let selectedOriginalSourceID: ReportSource.ID?
    let onSelectOriginalSource: (ReportSource.ID) -> Void
    let onSave: (UpdateRecordCommand) async -> UpdateRecordResult

    @State private var editor: RecordEditState
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var latestConflictingRecord: HealthRecord?
    @State private var hasRecordConflict = false

    init(
        record: HealthRecord,
        members: [FamilyMember],
        original: OriginalDocumentPayload?,
        isOriginalLoading: Bool,
        selectedOriginalSourceID: ReportSource.ID?,
        onSelectOriginalSource: @escaping (ReportSource.ID) -> Void,
        onSave: @escaping (UpdateRecordCommand) async -> UpdateRecordResult
    ) {
        self.record = record
        self.members = members
        self.original = original
        self.isOriginalLoading = isOriginalLoading
        self.selectedOriginalSourceID = selectedOriginalSourceID
        self.onSelectOriginalSource = onSelectOriginalSource
        self.onSave = onSave
        _editor = State(initialValue: RecordEditState(record: record))
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(AppLocalization.string("编辑已确认记录"))
                    .font(.title2.weight(.semibold))
                Text(AppLocalization.string("这里只校正原文转录或重新分配成员，原件不会改变。"))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 26)
            .padding(.vertical, 20)

            Divider()

            HSplitView {
                OrderedOriginalDocumentView(
                    sources: editor.record.sources,
                    selectedSourceID: selectedOriginalSourceID,
                    payload: original,
                    isLoading: isOriginalLoading,
                    onSelectSource: onSelectOriginalSource,
                    presentation: .inline(onOpenOriginal: nil)
                )
                .frame(minWidth: 420)
                .disabled(isSaving)
                .accessibilityIdentifier("record-edit-original-pane")

                editorForm
                    .frame(minWidth: 390)
                    .background(KinlogueTheme.surface)
            }

            Divider()

            VStack(spacing: 8) {
                HStack {
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .accessibilityLabel(AppLocalization.string("错误：\(errorMessage)"))
                    }
                    Spacer()
                    Button(AppLocalization.string("取消")) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(isSaving)
                        .accessibilityIdentifier("record-edit-cancel")
                    Button(AppLocalization.string("保存")) {
                        isSaving = true
                        errorMessage = nil
                        Task {
                            let command = editor.command()
                            switch await onSave(command) {
                            case .saved:
                                dismiss()
                            case .recordChanged(let latest):
                                latestConflictingRecord = latest
                                hasRecordConflict = true
                                errorMessage = latest == nil
                                    ? AppLocalization.string("这条记录已在其他窗口中发生变化，当前修改无法保存。请关闭编辑页。")
                                    : AppLocalization.string("这条记录已在其他窗口中更新。重新载入最新版本会替换此页未保存的修改。")
                            case .failed:
                                errorMessage = AppLocalization.string("无法保存这条记录，请稍后再试。")
                            }
                            isSaving = false
                        }
                    }
                    .buttonStyle(.kinloguePrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving || isOriginalLoading || hasRecordConflict)
                    .accessibilityIdentifier("record-edit-save")
                }
                if let latestConflictingRecord, hasRecordConflict {
                    HStack {
                        Spacer()
                        Button(AppLocalization.string("重新载入最新版本")) {
                            editor.load(latestConflictingRecord)
                            self.latestConflictingRecord = nil
                            hasRecordConflict = false
                            errorMessage = nil
                        }
                        .disabled(isSaving)
                        .accessibilityIdentifier("record-edit-reload-latest")
                    }
                }
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 18)
        }
        .frame(minWidth: 960, idealWidth: 1_180, minHeight: 680, idealHeight: 760)
        .interactiveDismissDisabled(isSaving)
    }

    private var editorForm: some View {
        ScrollView {
            Form {
                Picker(AppLocalization.string("家庭成员"), selection: $editor.memberID) {
                    let labels = RecordQuery.selectionLabels(for: members)
                    ForEach(editableMemberChoices) { member in
                        Text(labels[member.id] ?? member.displayName).tag(member.id)
                    }
                }
                Picker(AppLocalization.string("时间线日期"), selection: $editor.dateSelectionMode) {
                    Text(AppLocalization.string("日期未知")).tag(TimelineDateSelectionMode.unknown)
                    ForEach(detectedDateCandidates) { candidate in
                        Text(ReportDateSemantics.formatted(
                            candidate.date,
                            style: .long
                        ))
                            .tag(TimelineDateSelectionMode.detected(candidate.id))
                    }
                    Text(AppLocalization.string("手动选择日期…")).tag(TimelineDateSelectionMode.manual)
                }
                if editor.dateSelectionMode == .manual {
                    LocalizedDatePicker(
                        AppLocalization.string("手动日期"),
                        selection: $editor.manualTimelineDate
                    )
                }
                sourceField(AppLocalization.string("标题"), text: $editor.title, source: editor.record.title)
                sourceField(AppLocalization.string("医院"), text: $editor.organization, source: editor.record.organization)
                sourceField(AppLocalization.string("科室"), text: $editor.department, source: editor.record.department)
                sourceField(AppLocalization.string("报告类型"), text: $editor.reportType, source: editor.record.reportType)
                sourceTextEditor(AppLocalization.string("检查结果（逐字）"), text: $editor.reportedResults, source: editor.record.reportedResults)
                sourceTextEditor(AppLocalization.string("检查结论（逐字）"), text: $editor.conclusion, source: editor.record.conclusion)
                if !editor.abnormalItems.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(AppLocalization.string("报告自带标记"))
                        ForEach(editor.abnormalItems.indices, id: \.self) { index in
                            VStack(alignment: .leading, spacing: 4) {
                                TextField(AppLocalization.string("原报告标记"), text: $editor.abnormalItems[index])
                                    .accessibilityHint(
                                        editor.record.abnormalItems.indices.contains(index)
                                            ? editor.record.abnormalItems[index]
                                                .sourceDescription(for: editor.record.sources)
                                            : AppLocalization.string("请对照原件人工核对")
                                    )
                                if editor.record.abnormalItems.indices.contains(index) {
                                    sourceHint(editor.record.abnormalItems[index])
                                }
                            }
                        }
                        Text(AppLocalization.string("只校正原报告印出的高低或箭头标记，不会按数值推断。"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading) {
                    Text(AppLocalization.string("我的备注"))
                    multilineEditor(
                        text: $editor.userNote,
                        minimumHeight: 70,
                        accessibilityLabel: AppLocalization.string("我的备注"),
                        accessibilityHelp: AppLocalization.string("填写仅供自己查看的备注，不会作为原报告内容")
                    )
                        .accessibilityLabel(AppLocalization.string("我的备注"))
                        .accessibilityHint(AppLocalization.string("填写仅供自己查看的备注，不会作为原报告内容"))
                    Text(AppLocalization.string("备注不会进入搜索比较中的原文结论。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(26)
        }
        .disabled(isSaving)
    }

    private var editableMemberChoices: [FamilyMember] {
        RecordQuery.selectableMembers(
            from: members.filter { !$0.isArchived || $0.id == editor.record.memberID },
            includeArchived: true
        )
    }

    private var detectedDateCandidates: [ReportDateCandidate] {
        editor.record.dateCandidates.filter { $0.source.entryMethod != .manual }
    }

    @ViewBuilder
    private func sourceField(_ label: String, text: Binding<String>, source: SourceField?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(label, text: text)
            sourceHint(source)
        }
    }

    @ViewBuilder
    private func sourceTextEditor(_ label: String, text: Binding<String>, source: SourceField?) -> some View {
        let accessibilityHelp = source?.sourceDescription(for: editor.record.sources)
            ?? AppLocalization.string("请对照原件人工核对，可手动填写")

        VStack(alignment: .leading) {
            Text(label)
            multilineEditor(
                text: text,
                minimumHeight: 100,
                accessibilityLabel: label,
                accessibilityHelp: accessibilityHelp
            )
                .accessibilityLabel(label)
                .accessibilityHint(accessibilityHelp)
            sourceHint(source)
        }
    }

    private func multilineEditor(
        text: Binding<String>,
        minimumHeight: CGFloat,
        accessibilityLabel: String,
        accessibilityHelp: String
    ) -> some View {
        InsetTextEditor(
            text: text,
            accessibilityLabel: accessibilityLabel,
            accessibilityHelp: accessibilityHelp
        )
            .frame(minHeight: minimumHeight)
            .background(KinlogueTheme.card, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(KinlogueTheme.outline))
    }

    private func sourceHint(_ source: SourceField?) -> some View {
        Text(
            source?.sourceDescription(for: editor.record.sources)
                ?? AppLocalization.string("原报告未提供或未识别；可对照原件手动填写")
        )
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

struct InsetTextEditor: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    @Binding var text: String
    let accessibilityLabel: String
    let accessibilityHelp: String

    private static let contentInset = NSSize(width: 8, height: 8)

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }

        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textColor = .labelColor
        textView.textContainerInset = Self.contentInset
        textView.string = text
        textView.setAccessibilityLabel(accessibilityLabel)
        textView.setAccessibilityHelp(accessibilityHelp)
        textView.delegate = context.coordinator
        textView.isEditable = isEnabled
        textView.isSelectable = isEnabled
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        scrollView.drawsBackground = false
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let textView = scrollView.documentView as? NSTextView else { return }

        if textView.isEditable != isEnabled {
            textView.isEditable = isEnabled
        }
        if textView.isSelectable != isEnabled {
            textView.isSelectable = isEnabled
        }
        if textView.accessibilityLabel() != accessibilityLabel {
            textView.setAccessibilityLabel(accessibilityLabel)
        }
        if textView.accessibilityHelp() != accessibilityHelp {
            textView.setAccessibilityHelp(accessibilityHelp)
        }
        if textView.textContainerInset != Self.contentInset {
            textView.textContainerInset = Self.contentInset
        }
        if textView.string != text {
            textView.string = text
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            guard text.wrappedValue != textView.string else { return }
            text.wrappedValue = textView.string
        }
    }
}
