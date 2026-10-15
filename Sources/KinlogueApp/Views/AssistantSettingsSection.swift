import KinlogueCore
import KinloguePlatform
import SwiftUI

/// Settings → AI chat (experimental): the switch, the local Codex it uses and its status. Shown
/// only in builds that embed the bridge.
struct AssistantSettingsSection: View {
    @ObservedObject var settings: AssistantSettingsModel
    let controlColumnWidth: CGFloat

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

                    Text(AppLocalization.string("每次对话发送前都会列出将要发送的内容并请你确认。对话只保存在内存中，退出续页后清除。"))
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

    private var status: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 8) {
                row(AppLocalization.string("Codex 位置"), settings.status?.executablePath ?? "—")
                row(AppLocalization.string("版本"), settings.status?.cliVersion ?? "—")
                row(AppLocalization.string("登录"), loginText)
                row(AppLocalization.string("模型"), settings.status?.model ?? "—")
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
                field(
                    AppLocalization.string("模型"), text: $settings.draft.model,
                    prompt: AppLocalization.string("留空则使用 Codex 的默认模型"),
                    identifier: "assistant-settings-model"
                )
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
