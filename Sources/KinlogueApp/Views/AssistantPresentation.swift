import Foundation
import KinlogueCore
import KinloguePlatform

/// Fixed words of the member chat. Functions take the language so both can be checked in tests.
enum AssistantText {
    static func answerLabel(language: AppLanguage = AppLocalization.selectedLanguage()) -> String {
        AppLocalization.string("模型生成 · 可能有误 · 不是诊断", language: language)
    }

    static func receiver(cliVersion: String, model: String, language: AppLanguage = AppLocalization.selectedLanguage()) -> String {
        AppLocalization.string("Codex \(cliVersion) · 模型 \(model)", language: language)
    }

    static func waiting(seconds: Int, language: AppLanguage = AppLocalization.selectedLanguage()) -> String {
        AppLocalization.string("正在等待 Codex 回答 · \(seconds) 秒", language: language)
    }

    /// One saved conversation in the history list: when it was last updated and how it began.
    static func historyTitle(_ summary: AssistantConversationSummary, language: AppLanguage = AppLocalization.selectedLanguage()) -> String {
        let date = summary.updatedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened,
                                                                 locale: AppLocalization.locale(for: language)))
        let question = summary.firstQuestion.map { $0.count > 24 ? String($0.prefix(24)) + "…" : $0 }
            ?? AppLocalization.string("尚无问题", language: language)
        return AppLocalization.string("\(date) · \(question) · \(summary.turnCount) 轮", language: language)
    }

    static func otherReceiver(_ provider: AssistantProviderDescriptor, language: AppLanguage = AppLocalization.selectedLanguage()) -> String {
        AppLocalization.string("这段对话由 \(receiver(cliVersion: provider.cliVersion, model: provider.model, language: language)) 生成；继续提问将开始一段新的对话。",
                               language: language)
    }

    /// Questions that ask for a description of the reports, never for a judgement.
    static func exampleQuestions(language: AppLanguage = AppLocalization.selectedLanguage()) -> [String] {
        [
            AppLocalization.string("按时间列出最近几次检查的主要结果", language: language),
            AppLocalization.string("这些报告里提到过哪些复查建议？", language: language),
            AppLocalization.string("解释一下报告里出现的专业术语", language: language),
        ]
    }
}

extension AssistantIssue {
    /// A stopped answer and an expired consent are expected turns of a conversation, not failures.
    var tone: KinlogueStatusTone {
        switch self {
        case .cli(.cancelled), .consentRequired: .warning
        default: .danger
        }
    }

    func message(language: AppLanguage = AppLocalization.selectedLanguage()) -> String {
        switch self {
        case .disabled:
            AppLocalization.string("AI 对话已关闭，可以在设置中开启。", language: language)
        case .invalidSettings:
            AppLocalization.string("AI 对话设置无效，请在设置中检查 Codex 路径、模型和代理。", language: language)
        case .noConfirmedRecords:
            AppLocalization.string("这位成员还没有已确认的报告，暂时没有可以对话的内容。", language: language)
        case .memberArchived:
            AppLocalization.string("这位成员已归档，不能开始对话。", language: language)
        case .selection:
            AppLocalization.string("所选报告无法全部发送，请重新打开对话。", language: language)
        case .libraryUnavailable:
            AppLocalization.string("资料库正在变更，对话已停止。", language: language)
        case .consentRequired:
            AppLocalization.string("要发送的内容或接收方已变化，请重新确认后再提问。", language: language)
        case .conversationFull:
            AppLocalization.string("这次对话已达到轮数上限，请开始新对话。", language: language)
        case .tooManyConversations:
            AppLocalization.string("这位成员保存的对话已达上限，请先在“历史对话”中删除一些。", language: language)
        case .invalidQuestion:
            AppLocalization.string("请输入不超过 \(AssistantLimits.maxQuestionCharacters) 个字符的问题。", language: language)
        case .storage:
            AppLocalization.string("无法读取本机资料库中的报告，请稍后重试。", language: language)
        case let .cli(failure):
            Self.message(for: failure, language: language)
        }
    }

    private static func message(for failure: AssistantFailure, language: AppLanguage) -> String {
        switch failure {
        case .cliNotFound:
            AppLocalization.string("没有找到 Codex。请先安装 Codex，或在设置中填写它的路径。", language: language)
        case .unsupportedLocation:
            AppLocalization.string("续页无法访问这个位置的 Codex。目前只支持安装在 /opt/homebrew 或 /usr/local 下的 Codex。", language: language)
        case .notLoggedIn:
            AppLocalization.string("Codex 尚未登录。请在终端运行 codex login，然后重新检查。", language: language)
        case .unsupportedCLI:
            AppLocalization.string("这个版本的 Codex 没有通过续页的发送前检查，暂时不能使用。", language: language)
        case .toolUseDetected:
            AppLocalization.string("Codex 试图调用工具，续页拒绝了这次回答。", language: language)
        case .busy:
            AppLocalization.string("上一个请求还没有结束，请稍后再试。", language: language)
        case .bridgeUnavailable:
            AppLocalization.string("对话组件不可用，请重新启动续页后再试。", language: language)
        case .rateLimited:
            AppLocalization.string("Codex 账号的用量已达上限，请稍后再试。", language: language)
        case .networkUnavailable:
            AppLocalization.string("Codex 无法连接到它的服务，请检查网络或代理设置。", language: language)
        case .timedOut:
            AppLocalization.string("等待回答超时，请重试。", language: language)
        case .outputTooLarge:
            AppLocalization.string("回答过长，已被丢弃。请换一个更具体的问题。", language: language)
        case .cancelled:
            AppLocalization.string("已停止这次回答。", language: language)
        case .failed:
            AppLocalization.string("Codex 没有给出回答，请重试。", language: language)
        }
    }
}

extension AssistantSettingsIssue {
    func message(language: AppLanguage = AppLocalization.selectedLanguage()) -> String {
        switch self {
        case .invalidPath:
            AppLocalization.string("请填写 Codex 可执行文件的完整路径，以 / 开头。", language: language)
        case .invalidModel:
            AppLocalization.string("模型名称只能包含英文字母、数字和 . - _ :，并以字母或数字开头。", language: language)
        case .invalidProxy:
            AppLocalization.string("代理需要是 http、https 或 socks5 地址，例如 http://127.0.0.1:7890。", language: language)
        case .proxyCredentials:
            AppLocalization.string("代理地址不能包含用户名或密码，因为续页以明文保存设置。", language: language)
        }
    }
}

/// What a pack holds, in the terms the scope bar and the confirmation sheet use.
struct AssistantPackSummary: Equatable {
    let reportCount: Int
    /// `yyyy-MM-dd` per report, nil for a report without a timeline date.
    let dates: [String?]
    let byteCount: Int
    let omittedCount: Int
    let truncatedCount: Int
    let damagedCount: Int

    init(reportCount: Int, dates: [String?], byteCount: Int, omittedCount: Int, truncatedCount: Int, damagedCount: Int) {
        self.reportCount = reportCount
        self.dates = dates
        self.byteCount = byteCount
        self.omittedCount = omittedCount
        self.truncatedCount = truncatedCount
        self.damagedCount = damagedCount
    }

    init(pack: AssistantContextPack, damagedCount: Int) {
        self.init(
            reportCount: pack.entries.count, dates: pack.entries.map(\.date), byteCount: pack.byteCount,
            omittedCount: pack.omittedRecordCount, truncatedCount: pack.entries.filter(\.isTruncated).count,
            damagedCount: damagedCount
        )
    }

    func reports(language: AppLanguage = AppLocalization.selectedLanguage()) -> String {
        AppLocalization.string("\(reportCount) 份报告", language: language)
    }

    /// Year and month of the oldest and newest dated report.
    func dateRange(language: AppLanguage = AppLocalization.selectedLanguage()) -> String? {
        let months = dates.compactMap { $0.map { String($0.prefix(7)) } }.sorted()
        guard let first = months.first, let last = months.last else { return nil }
        return first == last ? first : AppLocalization.string("\(first) 至 \(last)", language: language)
    }

    func size() -> String {
        ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }

    func omitted(language: AppLanguage = AppLocalization.selectedLanguage()) -> String? {
        omittedCount > 0 ? AppLocalization.string("另有 \(omittedCount) 份较早的报告不会发送", language: language) : nil
    }

    func truncated(language: AppLanguage = AppLocalization.selectedLanguage()) -> String? {
        truncatedCount > 0 ? AppLocalization.string("\(truncatedCount) 份报告过长，只发送开头部分", language: language) : nil
    }

    func damaged(language: AppLanguage = AppLocalization.selectedLanguage()) -> String? {
        damagedCount > 0 ? AppLocalization.string("\(damagedCount) 份报告无法读取，没有包含在内", language: language) : nil
    }
}

/// Answers are shown with their inline emphasis but never as links: a link in a model answer
/// would send the user somewhere the reports did not name.
enum AssistantAnswerFormatting {
    static func attributed(_ answer: String) -> AttributedString {
        var text = (try? AttributedString(
            markdown: answer,
            options: .init(allowsExtendedAttributes: false, interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        )) ?? AttributedString(answer)
        for run in text.runs where run.link != nil || run.imageURL != nil {
            text[run.range].link = nil
            text[run.range].imageURL = nil
        }
        return text
    }
}

/// One `[R#]` an answer cites, resolved through the manifest of the turn that produced it.
struct AssistantCitationChip: Identifiable, Equatable {
    enum State: Equatable {
        case current
        /// The report was edited after the answer; it opens in its current form.
        case changed
        case deleted
        /// The answer cites a label that was not sent in this turn.
        case notSent
    }

    let label: String
    /// The report to open, nil when there is none.
    let recordID: UUID?
    let state: State

    var id: String { label }

    static func chips(
        for turn: AssistantTurn,
        status: (AssistantTurnSource) -> AssistantCitationStatus
    ) -> [AssistantCitationChip] {
        AssistantCitationParser.resolve(answer: turn.answer, manifest: turn.sources).map { citation in
            guard let source = citation.source else {
                return AssistantCitationChip(label: citation.label, recordID: nil, state: .notSent)
            }
            switch status(source) {
            case .current: return AssistantCitationChip(label: citation.label, recordID: source.recordID, state: .current)
            case .changed: return AssistantCitationChip(label: citation.label, recordID: source.recordID, state: .changed)
            case .deleted: return AssistantCitationChip(label: citation.label, recordID: nil, state: .deleted)
            }
        }
    }

    func title(language: AppLanguage = AppLocalization.selectedLanguage()) -> String {
        switch state {
        case .current: label
        case .changed: AppLocalization.string("\(label) · 已更新", language: language)
        case .deleted: AppLocalization.string("\(label) · 已删除", language: language)
        case .notSent: AppLocalization.string("\(label) · 未发送", language: language)
        }
    }

    func accessibilityLabel(language: AppLanguage = AppLocalization.selectedLanguage()) -> String {
        switch state {
        case .current: AppLocalization.string("来源 \(label)，打开报告", language: language)
        case .changed: AppLocalization.string("来源 \(label)，报告之后已修改，打开报告", language: language)
        case .deleted: AppLocalization.string("来源 \(label)，报告已删除", language: language)
        case .notSent: AppLocalization.string("\(label) 不在发送的报告中", language: language)
        }
    }
}
