import KinlogueCore
import SwiftUI

/// The fields the current extraction rules read differently from a confirmed record, the record's
/// text beside the new reading. Every field keeps the record's text unless the user ticks it, and
/// a field the user wrote or corrected says that taking the new reading replaces that text.
struct RecordRuleUpdateView: View {
    @Environment(\.dismiss) private var dismiss
    let update: RecordRuleUpdate
    let onSave: (Set<RecordRuleUpdate.Field>) async -> UpdateRecordResult

    @State private var accepted: Set<RecordRuleUpdate.Field> = []
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(AppLocalization.string("按新规则重新整理"))
                    .font(.title2.weight(.semibold))
                Text(AppLocalization.string("下面的字段由当前的识别规则从这份报告保存的识别结果重新整理，没有重新识别原件。勾选的字段换成新规则的结果，没有勾选的保持不变。"))
                    .foregroundStyle(KinlogueTheme.onVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 26)
            .padding(.vertical, 20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(update.changes, id: \.field) { change in
                        changeCard(change)
                    }
                }
                .padding(.horizontal, 26)
                .padding(.vertical, 18)
            }
            .background(KinlogueTheme.surface)

            Divider()

            HStack {
                if let errorMessage {
                    KinlogueStatusLabel(errorMessage, tone: .danger)
                        .font(.caption)
                        .accessibilityLabel(AppLocalization.string("错误：\(errorMessage)"))
                } else {
                    Text(AppLocalization.string("保存后这份报告不再提示，之后仍可以随时编辑。"))
                        .font(.caption)
                        .foregroundStyle(KinlogueTheme.onVariant)
                }
                Spacer()
                Button(AppLocalization.string("取消")) { dismiss() }
                    .buttonStyle(.kinlogueSecondary)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                Button(accepted.isEmpty ? AppLocalization.string("全部保留") : AppLocalization.string("保存")) {
                    isSaving = true
                    errorMessage = nil
                    Task {
                        switch await onSave(accepted) {
                        case .saved:
                            dismiss()
                        case .recordChanged:
                            errorMessage = AppLocalization.string("这份报告已在其他窗口中发生变化，请关闭后重新打开再整理。")
                        case .failed:
                            errorMessage = AppLocalization.string("无法保存这条记录，请稍后再试。")
                        }
                        isSaving = false
                    }
                }
                .buttonStyle(.kinloguePrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving)
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 18)
        }
        .frame(minWidth: 760, idealWidth: 900, minHeight: 520, idealHeight: 640)
        .kinlogueSheetCanvas()
        .interactiveDismissDisabled(isSaving)
    }

    private func changeCard(_ change: RecordRuleUpdate.Change) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(
                get: { accepted.contains(change.field) },
                set: { if $0 { accepted.insert(change.field) } else { accepted.remove(change.field) } }
            )) {
                Text(AppLocalization.string("使用新规则的\(Self.fieldName(change.field))"))
                    .font(.headline)
            }
            .disabled(isSaving)
            if change.replacesUserText {
                Label(AppLocalization.string("你改过这一项，使用新规则会替换你的修改。"), systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(KinlogueTheme.onVariant)
            }
            HStack(alignment: .top, spacing: 14) {
                reading(AppLocalization.string("当前"), change.current)
                reading(AppLocalization.string("新规则"), change.proposed)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .kinloguePanel(.card, cornerRadius: KinlogueTheme.Radius.control)
    }

    private func reading(_ title: String, _ fields: [SourceField]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(KinlogueTheme.onVariant)
            Text(fields.isEmpty ? AppLocalization.string("（无）") : fields.map(\.transcription).joined(separator: "\n"))
                .font(.callout)
                .foregroundStyle(fields.isEmpty ? KinlogueTheme.onVariant : KinlogueTheme.onSurface)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .kinloguePanel(.container, cornerRadius: KinlogueTheme.Radius.control)
        .accessibilityElement(children: .combine)
    }

    static func fieldName(_ field: RecordRuleUpdate.Field) -> String {
        switch field {
        case .title: AppLocalization.string("标题")
        case .organization: AppLocalization.string("医院")
        case .department: AppLocalization.string("科室")
        case .reportType: AppLocalization.string("报告类型")
        case .reportedResults: AppLocalization.string("检查结果")
        case .conclusion: AppLocalization.string("检查结论")
        case .abnormalItems: AppLocalization.string("报告自带标记")
        }
    }
}

/// The notice on a record the current rules read differently, naming the fields.
struct RecordRuleUpdateNotice: View {
    let update: RecordRuleUpdate
    let onReview: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .foregroundStyle(KinlogueTheme.primary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(AppLocalization.string("识别规则已更新"))
                    .font(.subheadline.weight(.semibold))
                Text(AppLocalization.string("按新规则，这份报告的\(fieldNames)可以重新整理。不会重新识别原件，也不会自动修改。"))
                    .font(.caption)
                    .foregroundStyle(KinlogueTheme.onVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(AppLocalization.string("查看"), action: onReview)
                .buttonStyle(.kinlogueSecondary)
                .accessibilityHint(AppLocalization.string("逐项对照当前内容和新规则的结果"))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .kinloguePanel(.container, cornerRadius: KinlogueTheme.Radius.control)
        .accessibilityElement(children: .contain)
    }

    private var fieldNames: String {
        update.changes.map { RecordRuleUpdateView.fieldName($0.field) }.joined(separator: AppLocalization.string("、"))
    }
}
