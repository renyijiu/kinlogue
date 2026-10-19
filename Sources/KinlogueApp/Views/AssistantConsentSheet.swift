import KinlogueCore
import KinloguePlatform
import SwiftUI

/// What one conversation sends and to whom, with the full text, shown before anything leaves the
/// Mac. Consent is given only here, and only for the pack and receiver shown.
struct AssistantConsentSheet: View {
    @ObservedObject var model: AssistantConversationModel
    let memberLabel: String?
    let onClose: () -> Void
    @State private var showsFullText = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(AppLocalization.string("发送给 Codex 前请确认"))
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(KinlogueTheme.onSurface)
                        if let memberLabel {
                            // Shown here only; the member's name is not part of what is sent.
                            Text(memberLabel)
                                .foregroundStyle(KinlogueTheme.onVariant)
                        }
                    }
                    receiver
                    sent
                    organization
                    KinlogueWarningNotice(AppLocalization.string("这不是匿名化：报告转录里可能印有姓名、病历号等信息，会原样发送。内容发送后无法撤回；对方保存多久取决于你的 Codex 账号设置。"))
                    fullText
                }
                .padding(24)
            }
            Divider()
            HStack(spacing: 12) {
                if model.phase == .loading {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button(model.phase == .needsConsent ? AppLocalization.string("取消") : AppLocalization.string("完成"), action: onClose)
                    .buttonStyle(.kinlogueSecondary)
                    .keyboardShortcut(.cancelAction)
                if !model.hasConsent {
                    Button(AppLocalization.string("确认并开始对话")) {
                        model.confirm()
                        if model.hasConsent { onClose() }
                    }
                    .buttonStyle(.kinloguePrimary)
                    .disabled(model.phase != .needsConsent || model.isCheckingCLI)
                    .accessibilityIdentifier("assistant-consent-confirm")
                }
            }
            .padding(16)
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 520, idealHeight: 660)
        .kinlogueSheetCanvas()
    }

    private var summary: AssistantPackSummary? {
        model.pack.map { AssistantPackSummary(pack: $0, damagedCount: model.damagedRecordIDs.count) }
    }

    private var receiver: some View {
        section(AppLocalization.string("接收方")) {
            Text(AppLocalization.string("发送到你在 Codex 中配置的服务，通常是 OpenAI。续页无法控制对方如何保存或使用这些内容。"))
                .foregroundStyle(KinlogueTheme.onSurface)
            if let status = model.cliStatus, status.failure == nil, let version = status.cliVersion, let name = status.model {
                Text(AssistantText.receiver(cliVersion: version, model: name))
                    .foregroundStyle(KinlogueTheme.onVariant)
            } else {
                KinlogueStatusLabel(AppLocalization.string("Codex 当前不可用，暂时不能发送。"), tone: .warning)
            }
        }
    }

    private var sent: some View {
        section(AppLocalization.string("会发送")) {
            if let summary {
                // Each layer of the pack, as the plan's section 7.1 lists them.
                ForEach([summary.index(), summary.conclusions(), summary.results(), summary.fullTexts()].compactMap { $0 }, id: \.self) {
                    bullet($0)
                }
                if model.includeOrganization {
                    bullet(AppLocalization.string("这些报告的检查机构名称"))
                }
                bullet(AppLocalization.string("你的问题，以及这次对话中之前的问答"))
                bullet(AppLocalization.string("续页的固定说明：只依据这些报告回答、标注来源、不做诊断或治疗建议"))
                ForEach([summary.omitted(), summary.omittedConclusions(), summary.omittedResultRows(), summary.omittedResultItems(),
                         summary.truncated(), summary.damaged()].compactMap { $0 }, id: \.self) { note in
                    Text(note)
                        .foregroundStyle(KinlogueTheme.onVariant)
                }
            }
            Text(AppLocalization.string("不会发送：成员姓名、备注、原件文件和图片、文件名，以及其他成员的资料。"))
                .foregroundStyle(KinlogueTheme.onVariant)
        }
    }

    private var organization: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(AppLocalization.string("包含检查机构名称"))
                    .foregroundStyle(KinlogueTheme.onSurface)
                Text(AppLocalization.string("默认不发送。更改后需要重新确认。"))
                    .font(.caption)
                    .foregroundStyle(KinlogueTheme.onVariant)
            }
            Spacer(minLength: 16)
            Toggle(
                AppLocalization.string("包含检查机构名称"),
                isOn: Binding(
                    get: { model.includeOrganization },
                    set: { include in Task { await model.setIncludeOrganization(include) } }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .disabled(model.phase == .sending || model.phase == .loading || model.pack == nil)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .kinloguePanel(.card)
        .accessibilityIdentifier("assistant-consent-organization")
    }

    private var fullText: some View {
        DisclosureGroup(isExpanded: $showsFullText) {
            ScrollView {
                Text(model.pack?.renderedRecords() ?? "")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(KinlogueTheme.onSurface)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(minHeight: 160, maxHeight: 300)
            .kinloguePanel(.container)
            .padding(.top, 8)
        } label: {
            // On macOS only the disclosure arrow takes clicks; the words open the full text too.
            Button(AppLocalization.string("查看将发送的全部内容")) { showsFullText.toggle() }
                .buttonStyle(.kinlogueGhost)
        }
        .accessibilityIdentifier("assistant-consent-full-text")
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(KinlogueTheme.onSurface)
            content()
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func bullet(_ text: String) -> some View {
        Label {
            Text(text)
                .foregroundStyle(KinlogueTheme.onSurface)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "arrow.up.right")
                .foregroundStyle(KinlogueTheme.onVariant)
                .accessibilityHidden(true)
        }
    }
}
