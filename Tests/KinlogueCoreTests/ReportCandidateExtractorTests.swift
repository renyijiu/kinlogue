import Foundation
import Testing
@testable import KinlogueCore

@Test
func candidateExtractorKeepsExplicitSourceTextAndPrintedMarkers() throws {
    let blocks = try [
        block("合成市测试医院", page: 1, y: 0.90),
        block("姓名：测试成员", page: 1, y: 0.84),
        block("检查日期：2026-01-02", page: 1, y: 0.78),
        block("报告名称：合成随访报告", page: 1, y: 0.72),
        block("检查结论", page: 1, y: 0.60),
        block("合成观察文字。", page: 1, y: 0.54),
        block("备注", page: 1, y: 0.48),
        block("检验项目甲 12 ↑", page: 2, y: 0.80),
        block("检验项目乙 9 3~10", page: 2, y: 0.74),
    ]

    let candidates = ReportCandidateExtractor().extract(from: blocks)

    #expect(candidates.memberName?.transcription == "测试成员")
    #expect(candidates.organization?.transcription == "合成市测试医院")
    #expect(candidates.title?.transcription == "合成随访报告")
    #expect(candidates.dateCandidates.count == 1)
    #expect(candidates.dateCandidates.first?.kind == .examination)
    #expect(candidates.conclusion?.transcription == "合成观察文字。")
    #expect(candidates.abnormalItems.map(\.transcription) == ["检验项目甲 12 ↑"])
    #expect(candidates.abnormalItems.first?.references.first?.pageNumber == 2)
}

@Test
func candidateExtractorStopsAConclusionBeforeViewerActions() throws {
    let blocks = try [
        block("CT", page: 1, y: 0.9),
        block("检查结论", page: 1, y: 0.7),
        block("合成结论正文。", page: 1, y: 0.6),
        block("查看原始影像", page: 1, y: 0.4),
        block("查看报告", page: 1, y: 0.3),
    ]

    let candidates = ReportCandidateExtractor().extract(from: blocks)

    #expect(candidates.reportType?.transcription == "CT")
    #expect(candidates.conclusion?.transcription == "合成结论正文。")
}

@Test
func candidateExtractorDoesNotInferAbnormalityFromReferenceRanges() throws {
    let blocks = try [
        block("项目甲 99 参考值 1~10", page: 1, y: 0.8),
        block("项目乙 0.1 参考值 2~5", page: 1, y: 0.7),
    ]

    let candidates = ReportCandidateExtractor().extract(from: blocks)

    #expect(candidates.abnormalItems.isEmpty)
}

@Test
func candidateExtractorIsStableAcrossInputOrdering() throws {
    let top = try block("报告日期：2026年02月03日", page: 1, x: 0.1, y: 0.8)
    let bottom = try block("检查结论：合成结论", page: 1, x: 0.1, y: 0.4)

    let first = ReportCandidateExtractor().extract(from: [bottom, top])
    let second = ReportCandidateExtractor().extract(from: [top, bottom])

    #expect(first == second)
    #expect(first.dateCandidates.first?.kind == .report)
    #expect(first.conclusion?.transcription == "合成结论")
}

@Test(arguments: ["丨检查结论", "*检查结论", "＊检查结论"])
func candidateExtractorAcceptsDecoratedConclusionHeading(_ heading: String) throws {
    let blocks = try [
        block(heading, page: 1, y: 0.7),
        block("合成结论正文。", page: 1, y: 0.6),
        block("查看原始影像", page: 1, y: 0.4),
    ]

    let candidates = ReportCandidateExtractor().extract(from: blocks)

    #expect(candidates.conclusion?.transcription == "合成结论正文。")
}

@Test
func candidateExtractorRecognizesCommonReportMetadataLabels() throws {
    let blocks = try [
        block("患者姓名：合成成员", page: 1, y: 0.95),
        block("机构名称：合成健康中心", page: 1, y: 0.90),
        block("开单科室：合成门诊", page: 1, y: 0.85),
        block("报告类别：影像报告", page: 1, y: 0.80),
        block("检查名称：合成增强检查", page: 1, y: 0.75),
    ]

    let candidates = ReportCandidateExtractor().extract(from: blocks)

    #expect(candidates.memberName?.transcription == "合成成员")
    #expect(candidates.organization?.transcription == "合成健康中心")
    #expect(candidates.department?.transcription == "合成门诊")
    #expect(candidates.reportType?.transcription == "影像报告")
    #expect(candidates.title?.transcription == "合成增强检查")
}

@Test(arguments: [
    "检查结果", "检查表现", "影像所见", "影像学表现", "放射学表现",
    "超声所见", "内镜所见", "病理所见", "检验结果",
])
func candidateExtractorRecognizesCommonNarrativeResultHeadings(_ heading: String) throws {
    let blocks = try [
        block(heading, page: 1, y: 0.70),
        block("合成检查结果正文。", page: 1, y: 0.60),
        block("报告时间：2026-08-10", page: 1, y: 0.40),
    ]

    let candidates = ReportCandidateExtractor().extract(from: blocks)

    #expect(candidates.reportedResults?.transcription == "合成检查结果正文。")
}

@Test(arguments: [
    "检查诊断", "诊断结论", "报告结论", "诊断提示", "诊断印象",
    "影像诊断", "放射学诊断", "超声诊断", "内镜诊断", "病理诊断",
])
func candidateExtractorRecognizesCommonConclusionHeadings(_ heading: String) throws {
    let blocks = try [
        block(heading, page: 1, y: 0.70),
        block("合成结论正文。", page: 1, y: 0.60),
        block("审核时间：2026-08-10", page: 1, y: 0.40),
    ]

    let candidates = ReportCandidateExtractor().extract(from: blocks)

    #expect(candidates.conclusion?.transcription == "合成结论正文。")
}

@Test
func candidateExtractorRecognizesCommonDateLabelsAndKinds() throws {
    let blocks = try [
        block("出报告时间：2026-01-01 10:30", page: 1, y: 0.95),
        block("检查时间：2026-01-02 09:15", page: 1, y: 0.90),
        block("检验日期：2026-01-03", page: 1, y: 0.85),
        block("收样时间：2026-01-04 08:00", page: 1, y: 0.80),
        block("送检日期：2026-01-05", page: 1, y: 0.75),
        block("入院时间：2026-01-06 12:00", page: 1, y: 0.70),
        block("出院时间：2026-01-07 12:00", page: 1, y: 0.65),
        block("就诊日期：2026-01-08", page: 1, y: 0.60),
    ]

    let candidates = ReportCandidateExtractor().extract(from: blocks)

    #expect(candidates.dateCandidates.map(\.kind) == [
        .report, .examination, .examination, .collection,
        .collection, .admission, .discharge, .other,
    ])
    #expect(candidates.dateCandidates.map(\.source.transcription) == [
        "2026-01-01 10:30", "2026-01-02 09:15", "2026-01-03", "2026-01-04 08:00",
        "2026-01-05", "2026-01-06 12:00", "2026-01-07 12:00", "2026-01-08",
    ])
}

@Test(arguments: [
    "2025-02-29",
    "2026-02-30",
    "2026-00-10",
    "2026-13-10",
])
func candidateExtractorRejectsImpossibleCalendarDates(_ value: String) throws {
    let candidates = ReportCandidateExtractor().extract(from: [
        try block("检查日期：\(value)", page: 1, y: 0.8),
    ])

    #expect(candidates.dateCandidates.isEmpty)
}

@Test
func candidateExtractorKeepsAValidLeapDay() throws {
    let candidates = ReportCandidateExtractor().extract(from: [
        try block("报告日期：2024-02-29", page: 1, y: 0.8),
    ])

    let candidate = try #require(candidates.dateCandidates.first)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let components = calendar.dateComponents([.year, .month, .day], from: candidate.date)
    #expect(components.year == 2024)
    #expect(components.month == 2)
    #expect(components.day == 29)
}

@Test
func candidateExtractorSeparatesRadiologyFindingsFromDiagnosis() throws {
    let findings = try block("合成放射学表现正文。", page: 1, y: 0.70)
    let diagnosis = try block("合成放射学诊断正文。", page: 1, y: 0.50)
    let blocks = try [
        block("放射学表现", page: 1, y: 0.80),
        findings,
        block("放射学诊断", page: 1, y: 0.60),
        diagnosis,
        block("审核医师：合成审核者", page: 1, y: 0.30),
    ]

    let candidates = ReportCandidateExtractor().extract(from: blocks)

    #expect(candidates.reportedResults?.transcription == "合成放射学表现正文。")
    #expect(candidates.reportedResults?.references.map(\.blockID) == [findings.id])
    #expect(candidates.conclusion?.transcription == "合成放射学诊断正文。")
    #expect(candidates.conclusion?.references.map(\.blockID) == [diagnosis.id])
}

@Test
func candidateExtractorKeepsNarrativeFindingsAndStopsConclusionBeforeReportTime() throws {
    let findingBody = try block("合成检查所见正文。", page: 1, y: 0.75)
    let findingContinuation = try block("合成检查所见续行。", page: 1, y: 0.70)
    let conclusionBody = try block("合成检查结论正文。", page: 1, y: 0.55)
    let blocks = try [
        block("*检查所见", page: 1, y: 0.80),
        findingBody,
        findingContinuation,
        block("＊检查结论", page: 1, y: 0.60),
        conclusionBody,
        block("报告时间：2026-07-22 15:30:00", page: 1, y: 0.40),
        block("审核者：合成审核者", page: 1, y: 0.35),
    ]

    let candidates = ReportCandidateExtractor().extract(from: blocks)

    #expect(candidates.reportedResults?.transcription == "合成检查所见正文。\n合成检查所见续行。")
    #expect(candidates.reportedResults?.references.map(\.blockID) == [
        findingBody.id,
        findingContinuation.id,
    ])
    #expect(candidates.conclusion?.transcription == "合成检查结论正文。")
    #expect(candidates.conclusion?.references.map(\.blockID) == [conclusionBody.id])
    #expect(candidates.dateCandidates.count == 1)
    #expect(candidates.dateCandidates.first?.kind == .report)
    #expect(candidates.dateCandidates.first?.source.transcription == "2026-07-22 15:30:00")
}

@Test
func candidateExtractorJoinsASameLineSplitDateLabelAndValue() throws {
    let blocks = try [
        block("采样日期：", page: 1, x: 0.05, y: 0.8, width: 0.18),
        block("2026-07-18", page: 1, x: 0.25, y: 0.801, width: 0.2),
        block("无关同行字段", page: 1, x: 0.55, y: 0.801, width: 0.2),
    ]

    let candidates = ReportCandidateExtractor().extract(from: blocks)

    #expect(candidates.dateCandidates.count == 1)
    #expect(candidates.dateCandidates.first?.kind == .collection)
    #expect(candidates.dateCandidates.first?.source.references.count == 2)
}

@Test
func candidateExtractorKeepsReportedLabRowsAsVerbatimResults() throws {
    let blocks = try [
        block("收样时间：2026-07-18 09:30", page: 1, x: 0.05, y: 0.45, width: 0.35),
        block("参考值", page: 1, x: 0.65, y: 0.9, width: 0.2),
        block("合成项目乙", page: 1, x: 0.05, y: 0.7, width: 0.25),
        block("5.9", page: 1, x: 0.4, y: 0.701, width: 0.12),
        block("3.5~9.5", page: 1, x: 0.65, y: 0.699, width: 0.2),
        block("项目", page: 1, x: 0.05, y: 0.9, width: 0.2),
        block("12.2", page: 1, x: 0.4, y: 0.801, width: 0.1),
        block("↑", page: 1, x: 0.52, y: 0.799, width: 0.05),
        block("3.0~10.0%", page: 1, x: 0.65, y: 0.8, width: 0.25),
        block("合成项目甲", page: 1, x: 0.05, y: 0.8, width: 0.25),
        block("结果", page: 1, x: 0.4, y: 0.9, width: 0.2),
        block("页脚伪项目", page: 1, x: 0.05, y: 0.35, width: 0.25),
        block("99", page: 1, x: 0.4, y: 0.351, width: 0.1),
        block("1~2", page: 1, x: 0.65, y: 0.349, width: 0.2),
    ]

    let candidates = ReportCandidateExtractor().extract(from: blocks)

    #expect(candidates.reportedResults?.transcription == "合成项目甲\t12.2 ↑\t3.0~10.0%\n合成项目乙\t5.9\t3.5~9.5")
    #expect(candidates.reportedResults?.references.count == 7)
    #expect(candidates.conclusion == nil)
    #expect(candidates.abnormalItems.isEmpty)
    #expect(candidates.dateCandidates.first?.kind == .collection)
}

@Test
func candidateExtractorCombinesResultTablesAcrossPages() throws {
    let blocks = try [
        block("项目", page: 1, x: 0.05, y: 0.9, width: 0.2),
        block("结果", page: 1, x: 0.4, y: 0.9, width: 0.2),
        block("参考值", page: 1, x: 0.65, y: 0.9, width: 0.2),
        block("第一页项目", page: 1, x: 0.05, y: 0.8, width: 0.25),
        block("1", page: 1, x: 0.4, y: 0.8, width: 0.1),
        block("0~2", page: 1, x: 0.65, y: 0.8, width: 0.2),
        block("项目", page: 2, x: 0.05, y: 0.9, width: 0.2),
        block("结果", page: 2, x: 0.4, y: 0.9, width: 0.2),
        block("参考值", page: 2, x: 0.65, y: 0.9, width: 0.2),
        block("第二页项目", page: 2, x: 0.05, y: 0.8, width: 0.25),
        block("2", page: 2, x: 0.4, y: 0.8, width: 0.1),
        block("1~3", page: 2, x: 0.65, y: 0.8, width: 0.2),
    ]

    let candidates = ReportCandidateExtractor().extract(from: blocks)

    #expect(candidates.reportedResults?.transcription == "第一页项目\t1\t0~2\n第二页项目\t2\t1~3")
    #expect(candidates.reportedResults?.references.map(\.pageNumber) == [1, 1, 1, 2, 2, 2])
}

@Test
func candidateExtractorSkipsTimestampWatermarksBeforeAConclusion() throws {
    let blocks = try [
        block("丨检查结论", page: 1, y: 0.8),
        block("08:28", page: 1, x: 0.238, y: 0.466, width: 0.122, height: 0.026, confidence: 0.5),
        block("8A8", page: 1, x: 0.643, y: 0.464, width: 0.044, height: 0.010, confidence: 0.3),
        block("08:28", page: 1, x: 0.694, y: 0.468, width: 0.125, height: 0.025, confidence: 0.3),
        block("1. 合成结论正文。", page: 1, y: 0.436, confidence: 0.5),
        block("合成结论续行。", page: 1, y: 0.409),
        block("查看原始图像", page: 1, y: 0.3),
    ]
    #expect(Set(blocks.map(\.id)).count == blocks.count)

    let candidates = ReportCandidateExtractor().extract(from: blocks)

    #expect(candidates.conclusion?.transcription == "1. 合成结论正文。\n合成结论续行。")
}

@Test
func candidateExtractorKeepsAnIsolatedLowConfidenceNumericConclusionLine() throws {
    let blocks = try [
        block("丨检查结论", page: 1, y: 0.8),
        block("12.0", page: 1, y: 0.7, confidence: 0.4),
        block("查看原始图像", page: 1, y: 0.3),
    ]

    let candidates = ReportCandidateExtractor().extract(from: blocks)

    #expect(candidates.conclusion?.transcription == "12.0")
}

@Test
func inlineConclusionOnTheSecondOriginalKeepsStableProvenanceAfterReopen() throws {
    let first = try ReportSource(attachmentID: UUID(), displayName: "first.pdf", pageCount: 2)
    let second = try ReportSource(attachmentID: UUID(), displayName: "second.png", pageCount: 1)
    let sources = try ReportSources([first, second])
    let block = try OCRBlock(
        sourceID: second.id,
        attachmentID: second.attachmentID,
        filePageNumber: 1,
        text: "检查结论：合成第二原件结论",
        boundingBox: NormalizedRect(x: 0.05, y: 0.8, width: 0.8, height: 0.04),
        confidence: 0.99,
        method: .vision,
        engineVersion: "synthetic"
    )

    let candidates = try ReportCandidateExtractor().extract(from: [block], sources: sources)
    let reference = try #require(candidates.conclusion?.references.first)
    #expect(candidates.conclusion?.transcription == "合成第二原件结论")
    #expect(reference.sourceID == second.id)
    #expect(reference.attachmentID == second.attachmentID)
    #expect(reference.filePageNumber == 1)
    #expect(reference.logicalPage(in: sources) == 3)

    let persisted = try ImportDraftDocument(
        blocks: [block],
        candidates: candidates
    ).attributedAndValidated(for: sources)
    let reopened = try JSONDecoder().decode(
        ImportDraftDocument.self,
        from: JSONEncoder().encode(persisted)
    ).attributedAndValidated(for: sources)
    #expect(reopened.candidates.conclusion?.references.first == reference)
    #expect(reopened.candidates.conclusion?.references.first?.logicalPage(in: sources) == 3)
}

private func block(
    _ text: String,
    page: Int,
    x: Double = 0.05,
    y: Double,
    width: Double = 0.8,
    height: Double = 0.04,
    confidence: Double = 0.99,
    id: UUID = UUID()
) throws -> OCRBlock {
    try OCRBlock(
        id: id,
        pageNumber: page,
        text: text,
        boundingBox: NormalizedRect(x: x, y: y, width: width, height: height),
        confidence: confidence,
        method: .vision,
        engineVersion: "synthetic"
    )
}
