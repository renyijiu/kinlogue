import KinlogueCore
import SwiftUI

struct ImportReviewContainer: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject var model: ImportReviewModel

    var body: some View {
        ImportReviewView(model: model)
            .task { await model.load() }
            .onChange(of: model.isPresented) {
                if !model.isPresented { dismiss() }
            }
            .onDisappear {
                model.closeReview()
            }
            // A successfully loaded review must choose an explicit persistence
            // semantic. If loading never succeeded, there is nothing to save and
            // the user must be able to leave the otherwise unusable sheet.
            .interactiveDismissDisabled(!model.loadFailed)
    }
}

struct ImportReviewView: View {
    @ObservedObject var model: ImportReviewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(AppLocalization.string("确认报告信息"))
                        .font(.title2.weight(.semibold))
                    Text(AppLocalization.string("识别结果只是转录建议，请对照左侧原件确认。"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await model.recognizeAgain() }
                } label: {
                    if model.isRecognitionInFlight {
                        Label(AppLocalization.string("正在重新识别"), systemImage: "viewfinder")
                    } else {
                        Label(AppLocalization.string("重新识别并覆盖"), systemImage: "viewfinder")
                    }
                }
                .frame(minWidth: 142)
                .disabled(model.isLoading || model.isTerminalActionInFlight || model.isRecognitionInFlight)
                .help(AppLocalization.string("使用新的本机识别结果覆盖当前字段"))
                .accessibilityIdentifier("import-review-recognize-again")
                Text(model.sourceMethodDescription)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .kinlogueChip()
            }
            .padding(22)
            Divider()

            if model.isLoading && model.originalDocument == nil {
                ProgressView(AppLocalization.string("正在读取本机草稿…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    Group {
                        if let sources = model.originalSources {
                            OrderedOriginalDocumentView(
                                sources: sources,
                                selectedSourceID: model.selectedOriginalSourceID,
                                payload: model.originalDocument,
                                isLoading: model.isOriginalLoading,
                                onSelectSource: { sourceID in
                                    Task { await model.selectOriginalSource(sourceID) }
                                },
                                presentation: .inline(onOpenOriginal: nil)
                            )
                        } else {
                            ContentUnavailableView(AppLocalization.string("原件不可用"), systemImage: "doc.questionmark")
                        }
                    }
                    .frame(minWidth: 420)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            Picker(AppLocalization.string("家庭成员"), selection: $model.selectedMemberID) {
                                Text(AppLocalization.string("请选择")).tag(Optional<FamilyMember.ID>.none)
                                ForEach(model.members) { member in
                                    Text(model.memberSelectionLabels[member.id] ?? member.displayName)
                                        .tag(Optional(member.id))
                                }
                            }
                            .accessibilityHint(AppLocalization.string("必须由你确认，识别结果不会自动归档"))

                            Picker(AppLocalization.string("时间线日期"), selection: $model.dateSelectionMode) {
                                Text(AppLocalization.string("日期未知")).tag(TimelineDateSelectionMode.unknown)
                                ForEach(model.dateCandidates) { candidate in
                                    Text(dateLabel(candidate))
                                        .tag(TimelineDateSelectionMode.detected(candidate.id))
                                }
                                Text(AppLocalization.string("手动选择日期…")).tag(TimelineDateSelectionMode.manual)
                            }
                            .accessibilityHint(AppLocalization.string("不选择时记录会进入日期未知分组"))
                            switch model.dateSelectionMode {
                            case .unknown:
                                if !model.dateCandidates.isEmpty {
                                    Text(AppLocalization.string("已识别到 \(model.dateCandidates.count) 个日期，请展开选择；也可以手动选择。"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            case .detected(let selectedID):
                                SourceCaption(model.dateSourceDescriptions[selectedID])
                            case .manual:
                                LocalizedDatePicker(
                                    AppLocalization.string("手动日期"),
                                    selection: $model.manualTimelineDate
                                )
                                Text(AppLocalization.string("此日期由你手动选择，会明确标记为人工录入。"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            ReviewTextField(
                                AppLocalization.string("标题"),
                                text: $model.title,
                                source: model.fieldSourceDescriptions[.title]
                            )
                            ReviewTextField(
                                AppLocalization.string("医院"),
                                text: $model.organization,
                                source: model.fieldSourceDescriptions[.organization]
                            )
                            ReviewTextField(
                                AppLocalization.string("科室"),
                                text: $model.department,
                                source: model.fieldSourceDescriptions[.department]
                            )
                            ReviewTextField(
                                AppLocalization.string("报告类型"),
                                text: $model.reportType,
                                source: model.fieldSourceDescriptions[.reportType]
                            )

                            ReviewTextEditor(
                                AppLocalization.string("检查结果（逐字）"),
                                text: $model.reportedResults,
                                source: model.fieldSourceDescriptions[.reportedResults],
                                minimumHeight: 150
                            )

                            ReviewTextEditor(
                                AppLocalization.string("检查结论（逐字）"),
                                text: $model.conclusion,
                                source: model.fieldSourceDescriptions[.conclusion],
                                minimumHeight: 110
                            )

                            if !model.abnormalItems.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(AppLocalization.string("报告自带标记")).font(.headline)
                                    ForEach(model.abnormalItems.indices, id: \.self) { index in
                                        VStack(alignment: .leading, spacing: 4) {
                                            TextField(AppLocalization.string("原报告标记"), text: $model.abnormalItems[index])
                                                .accessibilityHint(
                                                    model.abnormalSourceDescriptions.indices.contains(index)
                                                        ? model.abnormalSourceDescriptions[index]
                                                        : AppLocalization.string("请对照原件人工核对")
                                                )
                                            if model.abnormalSourceDescriptions.indices.contains(index) {
                                                SourceCaption(model.abnormalSourceDescriptions[index])
                                            }
                                        }
                                    }
                                    Text(AppLocalization.string("只保留原报告印出的高低或箭头标记，不会按数值推断。"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            VStack(alignment: .leading, spacing: 7) {
                                Text(AppLocalization.string("我的备注（可选）")).font(.headline)
                                TextEditor(text: $model.userNote)
                                    .frame(minHeight: 90)
                                    .padding(8)
                                    .background(KinlogueTheme.card, in: RoundedRectangle(cornerRadius: 10))
                                Text(AppLocalization.string("备注与原文转录分开保存，不进入比较。"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(22)
                    }
                    .frame(minWidth: 390)
                    .background(KinlogueTheme.surface)
                }
            }

            Divider()
            HStack {
                if model.loadFailed {
                    if let error = model.errorMessage {
                        Text(error).foregroundStyle(.red).accessibilityLabel(AppLocalization.string("错误：\(error)"))
                    }
                    Spacer()
                    Button(AppLocalization.string("关闭")) { model.closeReview() }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("import-review-close")
                } else {
                    Button(AppLocalization.string("放弃导入…"), role: .destructive) { model.requestDiscard() }
                        .disabled(model.isLoading || model.isTerminalActionInFlight || model.isRecognitionInFlight)
                        .accessibilityIdentifier("import-review-discard")
                    Spacer()
                    if let error = model.errorMessage {
                        Text(error).foregroundStyle(.red).accessibilityLabel(AppLocalization.string("错误：\(error)"))
                    }
                    Button(AppLocalization.string("稍后处理")) { Task { await model.deferReview() } }
                        .buttonStyle(.kinlogueSecondary)
                        .disabled(model.isLoading || model.isTerminalActionInFlight || model.isRecognitionInFlight)
                        .accessibilityIdentifier("import-review-defer")
                    Button(AppLocalization.string("确认并加入时间线")) { Task { await model.confirm() } }
                        .buttonStyle(.kinloguePrimary)
                        .disabled(model.isLoading || model.isTerminalActionInFlight || model.isRecognitionInFlight)
                        .accessibilityIdentifier("import-review-confirm")
                }
            }
            .padding(18)
        }
        .frame(minWidth: 960, minHeight: 680)
        .confirmationDialog(
            AppLocalization.string("放弃这份导入？"),
            isPresented: $model.isDiscardConfirmationPresented
        ) {
            Button(AppLocalization.string("放弃并删除本机草稿"), role: .destructive) {
                Task { await model.confirmDiscard() }
            }
            Button(AppLocalization.string("继续确认"), role: .cancel) {}
        } message: {
            Text(AppLocalization.string("源文件不会被删除；续页中的本机草稿会被移除。"))
        }
    }

    private func dateLabel(_ candidate: ReportDateCandidate) -> String {
        "\(ReportDateSemantics.formatted(candidate.date, style: .long)) · \(dateKind(candidate.kind))"
    }

    private func dateKind(_ kind: ReportDateKind) -> String {
        switch kind {
        case .report: AppLocalization.string("报告日期")
        case .examination: AppLocalization.string("检查日期")
        case .collection: AppLocalization.string("采样日期")
        case .admission: AppLocalization.string("入院日期")
        case .discharge: AppLocalization.string("出院日期")
        case .other: AppLocalization.string("其他日期")
        }
    }
}

private struct ReviewTextField: View {
    let label: String
    @Binding var text: String
    let source: String?

    init(_ label: String, text: Binding<String>, source: String?) {
        self.label = label
        _text = text
        self.source = source
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(label, text: $text)
                .accessibilityLabel(label)
                .accessibilityHint(source ?? AppLocalization.string("请对照原件人工核对"))
            SourceCaption(source)
        }
    }
}

private struct ReviewTextEditor: View {
    let label: String
    @Binding var text: String
    let source: String?
    let minimumHeight: CGFloat

    init(_ label: String, text: Binding<String>, source: String?, minimumHeight: CGFloat) {
        self.label = label
        _text = text
        self.source = source
        self.minimumHeight = minimumHeight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label).font(.headline)
            TextEditor(text: $text)
                .scrollContentBackground(.hidden)
                .frame(minHeight: minimumHeight)
                .padding(8)
                .background(KinlogueTheme.card, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(KinlogueTheme.outline))
                .accessibilityLabel(label)
                .accessibilityHint(source ?? AppLocalization.string("请对照原件人工核对，可手动填写"))
            SourceCaption(source)
        }
    }
}

private struct SourceCaption: View {
    let value: String?
    init(_ value: String?) { self.value = value }

    var body: some View {
        Text(value ?? AppLocalization.string("原报告未提供或未识别；可对照原件手动填写，保存后会标记为人工录入"))
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
