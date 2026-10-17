import AppKit
import KinlogueCore
import KinloguePlatform
import SwiftUI

/// The toolbar button that switches the detail column between the report and the member chat.
/// It appears only in builds that embed the bridge and only while the feature is on.
struct AssistantToolbarItem: View {
    @ObservedObject var settings: AssistantSettingsModel
    @Binding var isShown: Bool
    let hasMember: Bool

    var body: some View {
        if settings.isAvailable && settings.settings.isEnabled {
            Button {
                isShown.toggle()
            } label: {
                Label(
                    isShown ? AppLocalization.string("报告详情") : AppLocalization.string("对话"),
                    systemImage: isShown ? "doc.text" : "bubble.left.and.text.bubble.right"
                )
            }
            .help(help)
            .disabled(!hasMember)
            .accessibilityIdentifier("assistant-toolbar-toggle")
        }
    }

    private var help: String {
        if !hasMember { return AppLocalization.string("先在侧边栏选择一位家庭成员") }
        return isShown ? AppLocalization.string("返回报告详情") : AppLocalization.string("就这位成员已确认的报告提问")
    }
}

/// One member's chat in the detail column: what is sent and to whom, the turns so far, and the
/// question editor. Nothing is sent before the confirmation sheet has been accepted.
struct AssistantPanelView: View {
    @ObservedObject var model: AssistantConversationModel
    let memberLabel: String?
    let onShowRecord: (UUID) -> Void
    let onOpenSettings: () -> Void
    let onClose: () -> Void
    /// Turns the receiver line into a menu of the models Codex lists; nil shows it as text.
    var modelSettings: AssistantSettingsModel? = nil
    @State private var draft = ""
    @State private var isConsentPresented = false
    @State private var pendingDeletion: UUID?
    @State private var isComposing = false

    private static let bottomID = "assistant-bottom"

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        // The split view measures the detail column at its narrowest; without a floor every wrapping
        // line outside the transcript would break per character and push the composer off screen.
        .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        .background(KinlogueTheme.surface)
        .sheet(isPresented: $isConsentPresented) {
            AssistantConsentSheet(model: model, memberLabel: memberLabel) { isConsentPresented = false }
        }
        .onChange(of: model.memberID) {
            draft = ""
            isConsentPresented = false
            pendingDeletion = nil
        }
        .confirmationDialog(
            AppLocalization.string("删除这段对话？"),
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })
        ) {
            if let id = pendingDeletion {
                Button(AppLocalization.string("删除对话"), role: .destructive) {
                    Task { await model.deleteConversation(id) }
                }
            }
            Button(AppLocalization.string("保留"), role: .cancel) {}
        } message: {
            Text(AppLocalization.string("对话会从本机资料库中删除；已写入的恢复点仍包含它，已发送给 Codex 服务的内容也不受影响。"))
        }
        .accessibilityIdentifier("assistant-panel")
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(AppLocalization.string("对话"))
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(KinlogueTheme.onSurface)
                    if let memberLabel {
                        Text(memberLabel)
                            .foregroundStyle(KinlogueTheme.onVariant)
                            .lineLimit(1)
                    }
                }
                .layoutPriority(1)
                Spacer(minLength: 12)
                historyMenu
                Button(AppLocalization.string("新对话")) {
                    model.startNewConversation()
                    draft = ""
                }
                .buttonStyle(.kinlogueSecondary)
                .fixedSize()
                .disabled(model.conversation == nil || model.phase == .sending)
                .help(AppLocalization.string("清空当前对话，从新的问题开始"))
                Button(action: onClose) {
                    Label(AppLocalization.string("返回报告详情"), systemImage: "xmark")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.kinlogueGhost(.neutral))
                .help(AppLocalization.string("返回报告详情"))
            }
            if receiverLine != nil || packLine != nil {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        if let receiverLine {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                if let modelSettings, let status = model.cliStatus, !status.models.isEmpty {
                                    AssistantModelMenuButton(settings: modelSettings, status: status, title: receiverLine)
                                        .disabled(model.phase == .sending || model.phase == .loading || model.isCheckingCLI)
                                } else {
                                    scopeText(receiverLine)
                                }
                                if model.isCheckingCLI {
                                    ProgressView()
                                        .controlSize(.mini)
                                        .accessibilityLabel(AppLocalization.string("正在检查 Codex…"))
                                }
                            }
                        }
                        if let packLine {
                            scopeText(packLine)
                        }
                    }
                    Spacer(minLength: 8)
                    Button(AppLocalization.string("查看发送内容")) { isConsentPresented = true }
                        .buttonStyle(.kinlogueGhost)
                        .help(AppLocalization.string("查看会发送给 Codex 的全部内容"))
                        .accessibilityIdentifier("assistant-scope-review")
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var historyMenu: some View {
        Menu {
            ForEach(model.history) { summary in
                Button {
                    Task { await model.selectConversation(summary.id) }
                } label: {
                    if summary.id == model.conversation?.id {
                        Label(AssistantText.historyTitle(summary), systemImage: "checkmark")
                    } else {
                        Text(AssistantText.historyTitle(summary))
                    }
                }
            }
            if !model.history.isEmpty { Divider() }
            Button(AppLocalization.string("删除当前对话…"), role: .destructive) {
                pendingDeletion = model.conversation?.id
            }
            .disabled(model.conversation == nil)
        } label: {
            Label(AppLocalization.string("历史对话"), systemImage: "clock.arrow.circlepath")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(model.phase == .sending || model.phase == .loading || model.phase == .closed)
        .help(AppLocalization.string("查看或删除这位成员保存的对话"))
        .accessibilityIdentifier("assistant-history")
    }

    private var summary: AssistantPackSummary? {
        model.pack.map { AssistantPackSummary(pack: $0, damagedCount: model.damagedRecordIDs.count) }
    }

    /// Who receives the chat.
    private var receiverLine: String? {
        guard let status = model.cliStatus, status.failure == nil, let version = status.cliVersion, let name = status.model else {
            return nil
        }
        return AssistantText.receiver(cliVersion: version, model: name)
    }

    /// What the chat sends.
    private var packLine: String? {
        summary.map { [$0.reports(), $0.dateRange(), $0.size()].compactMap { $0 }.joined(separator: " · ") }
    }

    private func scopeText(_ line: String) -> some View {
        Text(line)
            .font(.callout)
            .foregroundStyle(KinlogueTheme.onVariant)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .closed, .loading:
            ProgressView(AppLocalization.string("正在准备对话…"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable:
            unavailable
        case .needsConsent, .ready, .sending:
            conversation
        }
    }

    private var unavailable: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let issue = model.issue {
                KinlogueStatusLabel(issue.message(), tone: issue.tone)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                if offersSettings {
                    Button(AppLocalization.string("打开设置"), action: onOpenSettings)
                        .buttonStyle(.kinlogueSecondary)
                }
                if offersRecheck {
                    Button(AppLocalization.string("重新检查")) { Task { await model.recheck() } }
                        .buttonStyle(.kinloguePrimary)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: 480, maxHeight: .infinity)
        .frame(maxWidth: .infinity)
    }

    private var offersSettings: Bool {
        switch model.issue {
        case .disabled, .invalidSettings, .cli(.cliNotFound), .cli(.unsupportedLocation), .cli(.networkUnavailable): true
        default: false
        }
    }

    private var offersRecheck: Bool {
        switch model.issue {
        case .cli, .storage, .selection: true
        default: false
        }
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if model.conversation?.turns.isEmpty ?? true, model.pendingQuestion == nil {
                            emptyState
                        }
                        ForEach(model.conversation?.turns ?? []) { turn in
                            AssistantTurnView(
                                turn: turn,
                                chips: AssistantCitationChip.chips(for: turn) { model.citationStatus(of: $0) },
                                onShowRecord: onShowRecord
                            )
                        }
                        if let question = model.pendingQuestion {
                            AssistantQuestionBubble(question: question)
                            waiting
                        }
                        Color.clear.frame(height: 1).id(Self.bottomID)
                    }
                    .padding(20)
                }
                .onChange(of: model.conversation?.turns.count) { scrollToBottom(proxy) }
                .onChange(of: model.pendingQuestion) { scrollToBottom(proxy) }
            }
            if let issue = model.issue {
                KinlogueStatusLabel(issue.message(), tone: issue.tone)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)
                    .accessibilityIdentifier("assistant-issue")
            }
            if let shown = model.conversation, !model.continuesShownConversation {
                Text(AssistantText.otherReceiver(shown.provider))
                    .font(.callout)
                    .foregroundStyle(KinlogueTheme.onVariant)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)
            }
            Divider()
            if model.phase == .needsConsent {
                consentPrompt
            } else {
                composer
            }
            Text(AppLocalization.string("对话保存在本机资料库中，可在“历史对话”里删除。"))
                .font(.caption)
                .foregroundStyle(KinlogueTheme.onVariant)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(AppLocalization.string("可以这样问"))
                .font(.headline)
                .foregroundStyle(KinlogueTheme.onSurface)
            ForEach(AssistantText.exampleQuestions(), id: \.self) { question in
                Button(question) { draft = question }
                    .buttonStyle(.kinlogueChip(isSelected: false))
                    .disabled(model.phase == .sending)
                    .help(AppLocalization.string("填入这个问题"))
            }
            Text(AppLocalization.string("回答只依据发送的报告转录，由模型生成，可能有误，不能代替医生的诊断。"))
                .foregroundStyle(KinlogueTheme.onVariant)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .kinloguePanel(.container)
    }

    @ViewBuilder
    private var waiting: some View {
        if let start = model.sendingStartedAt {
            SwiftUI.TimelineView(.periodic(from: start, by: 1)) { context in
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(AssistantText.waiting(seconds: max(0, Int(context.date.timeIntervalSince(start)))))
                        .foregroundStyle(KinlogueTheme.onVariant)
                }
            }
            .accessibilityIdentifier("assistant-waiting")
        }
    }

    private var consentPrompt: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(AppLocalization.string("发送前请确认"))
                .font(.headline)
                .foregroundStyle(KinlogueTheme.onSurface)
            Text(consentPromptText)
                .foregroundStyle(KinlogueTheme.onVariant)
                .fixedSize(horizontal: false, vertical: true)
            Button(AppLocalization.string("查看并确认…")) { isConsentPresented = true }
                .buttonStyle(.kinloguePrimary)
                .disabled(model.isCheckingCLI)
                .accessibilityIdentifier("assistant-review-consent")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .kinloguePanel(.card)
        .padding(16)
    }

    private var consentPromptText: String {
        let reports = summary?.reports() ?? ""
        return AppLocalization.string("确认后，续页会把这位成员 \(reports)的转录文本和你的问题发送给 Codex。确认前可以查看将要发送的全部内容。")
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            // SwiftUI's editor sets its first line against the clip bounds, which cuts off the top
            // of Chinese text while an input method composes it; this one keeps an 8pt inset.
            InsetTextEditor(
                text: $draft,
                accessibilityLabel: AppLocalization.string("问题"),
                accessibilityHelp: AppLocalization.string("按 Command-Return 发送"),
                isComposing: $isComposing
            )
                .frame(height: 88)
                .kinlogueInputFrame()
                .overlay(alignment: .topLeading) {
                    // An input method keeps its uncommitted text out of `draft` until it commits.
                    if draft.isEmpty && !isComposing {
                        Text(AppLocalization.string("就已确认的报告提问"))
                            .foregroundStyle(KinlogueTheme.onVariantSubtle)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .disabled(model.phase != .ready)
                .accessibilityIdentifier("assistant-question")
            HStack(spacing: 12) {
                if draft.count > AssistantLimits.maxQuestionCharacters * 9 / 10 {
                    Text(verbatim: "\(draft.count)/\(AssistantLimits.maxQuestionCharacters)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(KinlogueTheme.onVariant)
                }
                Spacer()
                if model.phase == .sending {
                    Button(AppLocalization.string("停止")) { model.stop() }
                        .buttonStyle(.kinlogueSecondary)
                        .help(AppLocalization.string("停止等待这次回答"))
                        .accessibilityIdentifier("assistant-stop")
                } else {
                    Button(AppLocalization.string("发送")) { send() }
                        .buttonStyle(.kinloguePrimary)
                        // Return adds a line in the question, so it is sent with Command-Return.
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!canSend)
                        .help(AppLocalization.string("发送问题（Command-Return）"))
                        .accessibilityIdentifier("assistant-send")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var canSend: Bool {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.phase == .ready && !model.isCheckingCLI && !question.isEmpty
            && question.count <= AssistantLimits.maxQuestionCharacters
    }

    private func send() {
        // A shortcut arrives before an input method commits its text; sending then would drop it.
        if NSApp.currentEvent?.type == .keyDown,
           TextInputComposition.isActive(in: NSApp.keyWindow?.firstResponder) {
            return
        }
        guard canSend else { return }
        let question = draft
        let memberID = model.memberID
        draft = ""
        Task {
            await model.send(question)
            // Give an unanswered question back, unless the chat moved to another member meanwhile.
            if model.issue != nil, model.memberID == memberID, draft.isEmpty {
                draft = question
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
    }
}

/// The receiver line as a menu of the models Codex lists. Choosing one saves the setting; the open
/// conversation then asks for consent again, because the receiver changed.
private struct AssistantModelMenuButton: View {
    @ObservedObject var settings: AssistantSettingsModel
    let status: AssistantCLIStatus
    let title: String

    var body: some View {
        Menu {
            ForEach(AssistantModelMenu.items(options: status.models, defaultModel: status.defaultModel, selected: settings.settings.model)) { item in
                Button {
                    Task { await settings.selectModel(item.id.isEmpty ? nil : item.id) }
                } label: {
                    if item.id == (settings.settings.model ?? "") {
                        Label(item.title, systemImage: "checkmark")
                    } else {
                        Text(item.title)
                    }
                }
            }
        } label: {
            Text(title)
                .font(.callout)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(AppLocalization.string("选择 Codex 使用的模型；更换后需要重新确认发送内容"))
        .accessibilityIdentifier("assistant-model-menu")
    }
}

private struct AssistantQuestionBubble: View {
    let question: String

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            Text(question)
                .foregroundStyle(KinlogueTheme.onSurface)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .kinloguePanel(.container)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(AppLocalization.string("你的问题：\(question)"))
    }
}

/// One question and its answer. The answer stays neutral: it carries the model label and the
/// reports it cites, never a colour that would read as a judgement.
private struct AssistantTurnView: View {
    let turn: AssistantTurn
    let chips: [AssistantCitationChip]
    let onShowRecord: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AssistantQuestionBubble(question: turn.question)
            VStack(alignment: .leading, spacing: 10) {
                Label(AssistantText.answerLabel(), systemImage: "text.bubble")
                    .font(.caption)
                    .foregroundStyle(KinlogueTheme.onVariant)
                Text(AssistantAnswerFormatting.attributed(turn.answer))
                    .foregroundStyle(KinlogueTheme.onSurface)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if !chips.isEmpty {
                    AssistantChipFlow(spacing: 6) {
                        ForEach(chips) { chip in
                            Button {
                                if let recordID = chip.recordID { onShowRecord(recordID) }
                            } label: {
                                Label(chip.title(), systemImage: Self.symbol(for: chip.state))
                            }
                            .buttonStyle(.kinlogueChip(isSelected: false))
                            .disabled(chip.recordID == nil)
                            .help(chip.accessibilityLabel())
                            .accessibilityLabel(chip.accessibilityLabel())
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .kinloguePanel(.card)
            .accessibilityElement(children: .contain)
        }
    }

    private static func symbol(for state: AssistantCitationChip.State) -> String {
        switch state {
        case .current: "doc.text"
        case .changed: "pencil"
        case .deleted: "trash"
        case .notSent: "questionmark"
        }
    }
}

/// Lays chips out in rows, wrapping to the next row when one is full.
private struct AssistantChipFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
