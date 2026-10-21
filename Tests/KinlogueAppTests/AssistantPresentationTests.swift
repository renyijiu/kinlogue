import Foundation
import Testing
@testable import KinlogueApp
@testable import KinlogueCore
@testable import KinloguePlatform

/// The words and derived values the member chat shows, in both languages, without rendering.
struct AssistantPresentationTests {
    static let issues: [AssistantIssue] = [
        .disabled, .invalidSettings, .noConfirmedRecords, .memberArchived, .selection, .libraryUnavailable,
        .consentRequired, .conversationFull, .tooManyConversations, .invalidQuestion, .storage,
        .cli(.cliNotFound), .cli(.unsupportedLocation), .cli(.notLoggedIn), .cli(.unsupportedCLI),
        .cli(.toolUseDetected), .cli(.busy), .cli(.bridgeUnavailable), .cli(.rateLimited),
        .cli(.networkUnavailable), .cli(.timedOut), .cli(.outputTooLarge), .cli(.cancelled), .cli(.failed(exitCode: 1)),
    ]

    @Test
    func everyIssueReadsInBothLanguagesWithItsOwnWords() {
        var english = Set<String>()
        var chinese = Set<String>()
        for issue in Self.issues {
            let en = issue.message(language: .english)
            let zh = issue.message(language: .simplifiedChinese)
            #expect(!en.isEmpty && !zh.isEmpty)
            #expect(!containsHan(en), "missing English for \(issue)")
            #expect(containsHan(zh), "missing Chinese for \(issue)")
            english.insert(en)
            chinese.insert(zh)
        }
        #expect(english.count == Self.issues.count)
        #expect(chinese.count == Self.issues.count)
        #expect(AssistantIssue.cli(.failed(exitCode: nil)).message(language: .english)
            == AssistantIssue.cli(.failed(exitCode: 1)).message(language: .english), "an exit code is not shown")
        #expect(AssistantIssue.invalidQuestion.message(language: .english) == "Enter a question of at most 2,000 characters.")
        #expect(AssistantIssue.invalidQuestion.message(language: .simplifiedChinese) == "请输入不超过 2,000 个字符的问题。")
    }

    @Test
    func onlyAStoppedAnswerOrAnExpiredConsentIsAWarning() {
        for issue in Self.issues {
            let expected: KinlogueStatusTone = issue == .cli(.cancelled) || issue == .consentRequired ? .warning : .danger
            #expect(issue.tone == expected, "\(issue)")
        }
    }

    @Test
    func settingsIssuesReadInBothLanguages() {
        let issues: [AssistantSettingsIssue] = [.invalidPath, .invalidModel, .invalidProxy, .proxyCredentials]
        let english = issues.map { $0.message(language: .english) }
        #expect(Set(english).count == issues.count)
        for issue in issues {
            #expect(!containsHan(issue.message(language: .english)))
            #expect(containsHan(issue.message(language: .simplifiedChinese)))
        }
    }

    @Test
    func packSummaryCountsReportsWithPluralsAndAMonthRange() {
        let one = AssistantPackSummary(reportCount: 1, dates: ["2024-05-01"], byteCount: 900, omittedCount: 1, truncatedCount: 1, damagedCount: 1)
        #expect(one.reports(language: .english) == "1 report")
        #expect(one.reports(language: .simplifiedChinese) == "1 份报告")
        #expect(one.dateRange(language: .english) == "2024-05")
        #expect(one.omitted(language: .english) == "1 older report will not be sent")
        #expect(one.truncated(language: .english) == "1 report is too long; only its beginning is sent")
        #expect(one.damaged(language: .english) == "1 report could not be read and is left out")

        let many = AssistantPackSummary(
            reportCount: 12, dates: [nil, "2023-01-09", "2026-09-30"], byteCount: 41_000, omittedCount: 3, truncatedCount: 2, damagedCount: 4
        )
        #expect(many.reports(language: .english) == "12 reports")
        #expect(many.reports(language: .simplifiedChinese) == "12 份报告")
        #expect(many.dateRange(language: .english) == "2023-01 to 2026-09")
        #expect(many.dateRange(language: .simplifiedChinese) == "2023-01 至 2026-09")
        #expect(many.omitted(language: .english) == "3 older reports will not be sent")
        #expect(many.omitted(language: .simplifiedChinese) == "另有 3 份较早的报告不会发送")
        #expect(many.truncated(language: .english) == "2 reports are too long; only their beginnings are sent")
        #expect(many.truncated(language: .simplifiedChinese) == "2 份报告过长，只发送开头部分")
        #expect(many.damaged(language: .english) == "4 reports could not be read and are left out")
        #expect(many.damaged(language: .simplifiedChinese) == "4 份报告无法读取，没有包含在内")

        let undated = AssistantPackSummary(reportCount: 2, dates: [nil, nil], byteCount: 10, omittedCount: 0, truncatedCount: 0, damagedCount: 0)
        #expect(undated.dateRange(language: .english) == nil)
        #expect(undated.omitted(language: .english) == nil)
        #expect(undated.truncated(language: .english) == nil)
        #expect(undated.damaged(language: .english) == nil)
    }

    @Test
    func receiverAndAnswerLabelsReadInBothLanguages() {
        #expect(AssistantText.receiver(cliVersion: "0.162.0", model: "gpt-synthetic", language: .english)
            == "Codex 0.162.0 · model gpt-synthetic")
        #expect(AssistantText.receiver(cliVersion: "0.162.0", model: "gpt-synthetic", language: .simplifiedChinese)
            == "Codex 0.162.0 · 模型 gpt-synthetic")
        #expect(AssistantText.answerLabel(language: .english) == "Model-generated · May be wrong · Not a diagnosis")
        #expect(AssistantText.answerLabel(language: .simplifiedChinese) == "模型生成 · 可能有误 · 不是诊断")
        let examples = AssistantText.exampleQuestions(language: .english)
        #expect(examples.count == 3)
        #expect(examples.allSatisfy { !containsHan($0) })
        #expect(AssistantText.exampleQuestions(language: .simplifiedChinese).allSatisfy(containsHan))
        #expect(AssistantText.waiting(seconds: 1, language: .english) == "Waiting for Codex to answer · 1 second")
        #expect(AssistantText.waiting(seconds: 12, language: .english) == "Waiting for Codex to answer · 12 seconds")
        #expect(AssistantText.waiting(seconds: 12, language: .simplifiedChinese) == "正在等待 Codex 回答 · 12 秒")
        #expect(AssistantText.olderVersion(language: .simplifiedChinese) == "这段对话来自较早版本的续页；继续提问将开始一段新的对话。")
        #expect(AssistantText.olderVersion(language: .english)
            == "This conversation comes from an earlier version of Kinlogue; asking another question starts a new conversation.")
    }

    @Test
    func modelMenuOffersCodexDefaultTheListedModelsAndASavedUnlistedOne() {
        let options = [AssistantModelOption(slug: "gpt-a", displayName: "GPT A"), .init(slug: "gpt-b", displayName: "GPT B")]

        let chinese = AssistantModelMenu.items(options: options, defaultModel: "gpt-b", selected: nil, language: .simplifiedChinese)
        #expect(chinese.map(\.id) == ["", "gpt-a", "gpt-b"])
        #expect(chinese.map(\.title) == ["Codex 默认（GPT B）", "GPT A", "GPT B"])

        let english = AssistantModelMenu.items(options: options, defaultModel: "gpt-b", selected: "gpt-old", language: .english)
        #expect(english.map(\.id) == ["", "gpt-a", "gpt-b", "gpt-old"])
        #expect(english.first?.title == "Codex default (GPT B)")
        #expect(english.last?.title == "gpt-old (not in Codex's list)")
        #expect(AssistantModelMenu.items(options: options, defaultModel: "gpt-a", selected: "gpt-a", language: .english).count == 3)

        #expect(AssistantModelMenu.items(options: [], defaultModel: nil, selected: nil, language: .english).map(\.title) == ["Codex default"])
        #expect(AssistantModelMenu.items(options: [], defaultModel: "gpt-x", selected: nil, language: .simplifiedChinese).map(\.title)
            == ["Codex 默认（gpt-x）"])
        #expect(AssistantModelMenu.name(of: "gpt-a", in: options) == "GPT A")
        #expect(AssistantModelMenu.name(of: "gpt-x", in: options) == "gpt-x")
    }

    @Test
    func answersKeepEmphasisAndLineBreaksButNoLinks() {
        let text = AssistantAnswerFormatting.attributed(
            "**Glucose** 5.1 [R1]\nSee [the site](https://example.com) and <https://example.org>\n\n- item"
        )
        #expect(text.runs.allSatisfy { $0.link == nil })
        #expect(String(text.characters) == "Glucose 5.1 [R1]\nSee the site and https://example.org\n\n- item")
        #expect(text.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })

        let unparsable = AssistantAnswerFormatting.attributed("plain [R2]")
        #expect(String(unparsable.characters) == "plain [R2]")
    }

    @Test
    func citationChipsFollowTheStateOfTheCitedRecord() throws {
        let ids = (0..<3).map { _ in UUID() }
        let sources = try ids.enumerated().map { index, id in
            try AssistantTurnSource(label: "R\(index + 1)", recordID: id, recordRevision: 1, projectionDigest: Data(repeating: 1, count: 32))
        }
        let turn = try AssistantTurn(
            ordinal: 0, question: "Q", answer: "A [R1] B [R2]【R3】 and [R9] again [R1]", completedAt: Date(), sources: sources
        )
        let states: [UUID: AssistantCitationStatus] = [ids[0]: .current, ids[1]: .changed, ids[2]: .deleted]
        let chips = AssistantCitationChip.chips(for: turn) { states[$0.recordID] ?? .current }

        #expect(chips.map(\.label) == ["R1", "R2", "R3", "R9"])
        #expect(chips.map(\.state) == [.current, .changed, .deleted, .notSent])
        #expect(chips.map(\.recordID) == [ids[0], ids[1], nil, nil], "only a record that still exists can be opened")
        #expect(chips.map { $0.title(language: .english) } == ["R1", "R2 · Updated", "R3 · Deleted", "R9 · Not sent"])
        #expect(chips.map { $0.title(language: .simplifiedChinese) } == ["R1", "R2 · 已更新", "R3 · 已删除", "R9 · 未发送"])
        #expect(chips[0].accessibilityLabel(language: .english) == "Source R1, open the report")
        #expect(chips[1].accessibilityLabel(language: .english) == "Source R2, the report has changed since, open it")
        #expect(chips[2].accessibilityLabel(language: .english) == "Source R3, the report was deleted")
        #expect(chips[3].accessibilityLabel(language: .english) == "R9 was not among the reports sent")
    }

    @Test @MainActor
    func summaryOfALoadedPackCountsItsEntries() async throws {
        let fixture = try await AssistantServiceFixture()
        defer { fixture.close() }
        let load = try await fixture.service.pack(memberID: fixture.member.id)
        let summary = AssistantPackSummary(pack: load.pack, damagedCount: load.damagedRecordIDs.count)

        #expect(summary.reportCount == 2)
        #expect(summary.dateRange(language: .english) == "2001-06 to 2002-06")
        #expect(summary.byteCount == load.pack.byteCount)
        #expect(summary.omitted(language: .english) == nil)
        // Both synthetic reports have one "Glucose" row and fit in full.
        #expect(summary.resultItemCount == 1 && summary.resultRowCount == 2)
        #expect(summary.fullTextCount == 2)
        #expect(summary.conclusionCount == 0)
    }

    @Test
    func layeredSummaryReadsEachLayerInBothLanguages() {
        let summary = AssistantPackSummary(
            reportCount: 86, dates: ["2019-04-02", "2024-03-01"], byteCount: 98_000, omittedCount: 0, truncatedCount: 1, damagedCount: 0,
            conclusionCount: 40, omittedConclusionCount: 46, resultItemCount: 31, resultRowCount: 312,
            omittedResultRowCount: 1, omittedResultItemCount: 2, fullTextCount: 9
        )
        #expect(summary.index(language: .simplifiedChinese) == "报告目录：86 份报告，每份一行日期和标题")
        #expect(summary.index(language: .english) == "Index: 86 reports, one line each with date and title")
        #expect(summary.conclusions(language: .simplifiedChinese) == "结论与标记项：40 份报告")
        #expect(summary.conclusions(language: .english) == "Conclusions and flagged items: 40 reports")
        #expect(summary.results(language: .simplifiedChinese) == "检验汇总：31 个项目、312 行")
        #expect(summary.results(language: .english) == "Lab results by item: 31 items, 312 rows")
        #expect(summary.fullTexts(language: .simplifiedChinese) == "完整检查结果：最新的 9 份报告")
        #expect(summary.fullTexts(language: .english) == "Full results: the newest 9 reports")
        #expect(summary.omittedConclusions(language: .simplifiedChinese) == "另有 46 份较早报告的结论没有列入")
        #expect(summary.omittedConclusions(language: .english) == "46 older reports' conclusions are not listed")
        #expect(summary.omittedResultRows(language: .simplifiedChinese) == "另有 1 条较早的检验结果没有列入")
        #expect(summary.omittedResultRows(language: .english) == "1 older result row is not listed")
        #expect(summary.omittedResultItems(language: .simplifiedChinese) == "另有 2 个检验项目没有列入")
        #expect(summary.omittedResultItems(language: .english) == "2 more items are not listed")
        #expect(summary.scopeLine(language: .simplifiedChinese).hasPrefix("86 份报告 · 全文 9 份 · 2019-04 至 2024-03 · "))
        #expect(summary.scopeLine(language: .english).hasPrefix("86 reports · 9 in full · 2019-04 to 2024-03 · "))

        let single = AssistantPackSummary(
            reportCount: 1, dates: [nil], byteCount: 10, omittedCount: 0, truncatedCount: 0, damagedCount: 0,
            conclusionCount: 1, omittedConclusionCount: 1, resultItemCount: 1, resultRowCount: 1,
            omittedResultRowCount: 2, omittedResultItemCount: 1, fullTextCount: 1
        )
        #expect(single.results(language: .english) == "Lab results by item: 1 item, 1 row")
        #expect(single.omittedConclusions(language: .english) == "1 older report's conclusion is not listed")
        #expect(single.omittedResultRows(language: .english) == "2 older result rows are not listed")
        #expect(single.omittedResultItems(language: .english) == "1 more item is not listed")

        let bare = AssistantPackSummary(reportCount: 1, dates: [nil], byteCount: 10, omittedCount: 0, truncatedCount: 0, damagedCount: 0)
        #expect(bare.conclusions(language: .english) == nil)
        #expect(bare.results(language: .english) == nil)
        #expect(bare.fullTexts(language: .english) == nil)
        #expect(bare.omittedConclusions(language: .english) == nil)
        #expect(bare.omittedResultRows(language: .english) == nil)
        #expect(bare.omittedResultItems(language: .english) == nil)
    }

    private func containsHan(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    }
}
