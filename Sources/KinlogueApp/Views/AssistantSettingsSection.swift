import KinlogueCore
import KinloguePlatform
import SwiftUI

/// Settings → AI chat (experimental): the switch, the local Codex it uses and its status. Shown
/// only in builds that embed the bridge.
struct AssistantSettingsSection: View {
    @ObservedObject var settings: AssistantSettingsModel
    let controlColumnWidth: CGFloat
    @State private var isDeleteAllPresented = false

    var body: some View {
        if settings.isAvailable {
            VStack(alignment: .leading, spacing: 12) {
                Label(AppLocalization.string("AI 对话（实验）"), systemImage: "bubble.left.and.text.bubble.right")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(KinlogueTheme.primary)

                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 24) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(AppLocalization.string("用 Codex 询问成员的报告"))
                                .font(.headline)
                                .foregroundStyle(KinlogueTheme.onSurface)
                            Text(AppLocalization.string("使用你在本机安装并登录的 Codex，就某位家庭成员已确认的报告提问。回答由模型生成，可能有误，不是诊断。"))
                                .foregroundStyle(KinlogueTheme.onVariant)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(AppLocalization.string("目前只支持 Codex 自己登录的 OpenAI 账号，不支持第三方中转服务。"))
                                .foregroundStyle(KinlogueTheme.onVariant)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 24)
                        Toggle(
                            AppLocalization.string("开启 AI 对话"),
                            isOn: Binding(
                                get: { settings.settings.isEnabled },
                                set: { enabled in Task { await settings.setEnabled(enabled) } }
                            )
                        )
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .fixedSize()
                        .frame(width: controlColumnWidth, alignment: .trailing)
                        .accessibilityIdentifier("assistant-settings-enabled")
                    }

                    if settings.settings.isEnabled {
                        Divider()
                        status
                        Divider()
                        fields
                    }
                    Divider()
                    savedConversations

                    Text(AppLocalization.string("每次对话发送前都会列出将要发送的内容并请你确认。"))
                        .font(.caption)
                        .foregroundStyle(KinlogueTheme.onVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(22)
                .kinloguePanel(.card)
            }
            .task { await settings.checkIfNeeded() }
        }
    }

    private var savedConversations: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(AppLocalization.string("已保存的对话"))
                        .font(.headline)
                        .foregroundStyle(KinlogueTheme.onSurface)
                    Text(AppLocalization.string("对话和报告一样以明文保存在本机资料库中，并随加密恢复点备份；删除成员时一并删除。关闭 AI 对话不会删除它们。"))
                        .foregroundStyle(KinlogueTheme.onVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 24)
                Button(AppLocalization.string("删除全部对话…"), role: .destructive) {
                    isDeleteAllPresented = true
                }
                .buttonStyle(.kinlogueDestructive)
                .disabled(settings.isDeletingConversations)
                .fixedSize()
                .frame(width: controlColumnWidth, alignment: .trailing)
                .accessibilityIdentifier("assistant-settings-delete-all")
            }
            if let issue = settings.deletionIssue {
                KinlogueStatusLabel(issue.message(), tone: .danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .confirmationDialog(AppLocalization.string("删除全部已保存的对话？"), isPresented: $isDeleteAllPresented) {
            Button(AppLocalization.string("删除全部对话"), role: .destructive) {
                Task { await settings.deleteAllConversations() }
            }
            Button(AppLocalization.string("保留"), role: .cancel) {}
        } message: {
            Text(AppLocalization.string("所有成员保存的对话都会从本机资料库中删除；已写入的恢复点仍包含它们，已发送给 Codex 服务的内容也不受影响。"))
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 8) {
                row(AppLocalization.string("Codex 位置"), settings.status?.executablePath ?? "—")
                row(AppLocalization.string("版本"), settings.status?.cliVersion ?? "—")
                row(AppLocalization.string("登录"), loginText)
                row(AppLocalization.string("模型"), settings.status.flatMap { status in
                    status.model.map { AssistantModelMenu.name(of: $0, in: status.models) }
                } ?? "—")
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                checkResult
                Spacer()
                Button(AppLocalization.string("重新检查")) { Task { await settings.check() } }
                    .buttonStyle(.kinlogueSecondary)
                    .disabled(settings.isChecking)
                    .accessibilityIdentifier("assistant-settings-check")
            }
        }
        .foregroundStyle(KinlogueTheme.onSurface)
    }

    private var loginText: String {
        guard let status = settings.status, status.cliVersion != nil else { return "—" }
        return status.isLoggedIn ? AppLocalization.string("已登录") : AppLocalization.string("未登录")
    }

    @ViewBuilder
    private var checkResult: some View {
        if settings.isChecking {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(AppLocalization.string("正在检查 Codex…"))
                    .foregroundStyle(KinlogueTheme.onVariant)
            }
        } else if let failure = settings.status?.failure {
            KinlogueStatusLabel(AssistantIssue.cli(failure).message(), tone: .danger)
                .fixedSize(horizontal: false, vertical: true)
        } else if let issue = settings.checkIssue {
            KinlogueStatusLabel(issue.message(), tone: .danger)
                .fixedSize(horizontal: false, vertical: true)
        } else if let status = settings.status {
            VStack(alignment: .leading, spacing: 4) {
                KinlogueStatusLabel(AppLocalization.string("发送前检查已通过，可以使用"), tone: .success)
                if !status.isVerifiedVersion {
                    Text(AppLocalization.string("续页尚未验证这个 Codex 版本；每次发送前仍会重新检查。"))
                        .font(.caption)
                        .foregroundStyle(KinlogueTheme.onVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 10) {
                field(
                    AppLocalization.string("Codex 路径"), text: $settings.draft.executablePath,
                    prompt: AppLocalization.string("留空则在 /opt/homebrew 和 /usr/local 中查找"),
                    identifier: "assistant-settings-path"
                )
                modelRow
                field(
                    AppLocalization.string("代理"), text: $settings.draft.proxy,
                    prompt: AppLocalization.string("例如 http://127.0.0.1:7890，留空则不使用"),
                    identifier: "assistant-settings-proxy"
                )
            }
            if let issue = settings.draftIssue {
                KinlogueStatusLabel(issue.message(), tone: .danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("assistant-settings-error")
            }
            HStack(spacing: 12) {
                Spacer()
                Button(AppLocalization.string("还原")) { settings.revertDraft() }
                    .buttonStyle(.kinlogueSecondary)
                    .disabled(!settings.hasUnsavedChanges)
                Button(AppLocalization.string("保存")) { Task { await settings.save() } }
                    .buttonStyle(.kinloguePrimary)
                    .disabled(!settings.hasUnsavedChanges)
                    .accessibilityIdentifier("assistant-settings-save")
            }
        }
    }

    /// A menu of the models the checked Codex lists; a text field when there is no list to offer.
    @ViewBuilder
    private var modelRow: some View {
        if let status = settings.status, !status.models.isEmpty {
            GridRow {
                Text(AppLocalization.string("模型"))
                    .foregroundStyle(KinlogueTheme.onVariant)
                    .gridColumnAlignment(.trailing)
                Picker(AppLocalization.string("模型"), selection: $settings.draft.model) {
                    ForEach(AssistantModelMenu.items(options: status.models, defaultModel: status.defaultModel, selected: settings.draft.model)) {
                        Text($0.title).tag($0.id)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("assistant-settings-model")
            }
        } else {
            field(
                AppLocalization.string("模型"), text: $settings.draft.model,
                prompt: AppLocalization.string("留空则使用 Codex 的默认模型"),
                identifier: "assistant-settings-model"
            )
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(KinlogueTheme.onVariant)
                .gridColumnAlignment(.trailing)
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private func field(_ title: String, text: Binding<String>, prompt: String, identifier: String) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(KinlogueTheme.onVariant)
                .gridColumnAlignment(.trailing)
            TextField(title, text: text, prompt: Text(prompt))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .autocorrectionDisabled()
                .frame(maxWidth: 420)
                .accessibilityIdentifier(identifier)
        }
    }
}
