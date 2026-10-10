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
    "检查结果", "检查结果描述", "检查表现", "影像所见", "影像学表现", "放射学表现",
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

// The two layouts below copy the geometry of the Go preview's regression
// fixtures, which in turn keep only the coordinates of two recognitions; every
// text is synthetic wording.

@Test
func candidateExtractorReadsAPhoneScreenshotLayout() throws {
    let blocks = try [
        block("18:27", page: 1, x: 0.123, y: 0.949, width: 0.120, height: 0.025, confidence: 1),
        block("：！今85", page: 1, x: 0.700, y: 0.948, width: 0.221, height: 0.026, confidence: 0.3),
        block("检查报告", page: 1, x: 0.407, y: 0.897, width: 0.180, height: 0.023, confidence: 0.5),
        block("●••", page: 1, x: 0.792, y: 0.904, width: 0.057, height: 0.013, confidence: 0.3),
        block("医疗名称", page: 1, x: 0.041, y: 0.839, width: 0.152, height: 0.021, confidence: 0.5),
        block("合成部位CTA", page: 1, x: 0.038, y: 0.799, width: 0.259, height: 0.027, confidence: 1),
        block("姓名：合成成员", page: 1, x: 0.038, y: 0.732, width: 0.243, height: 0.021, confidence: 0.5),
        block("送检医生：合成医生", page: 1, x: 0.498, y: 0.732, width: 0.303, height: 0.020, confidence: 0.5),
        block("检查日期：2026-07-31 08:46:43", page: 1, x: 0.041, y: 0.622, width: 0.562, height: 0.020, confidence: 1),
        block("具体报告信息请以医院纸质报告为准。", page: 1, x: 0.041, y: 0.576, width: 0.496, height: 0.018, confidence: 1),
        block("检查结果", page: 1, x: 0.041, y: 0.491, width: 0.170, height: 0.019, confidence: 0.5),
        block("合成检查结果一句。", page: 1, x: 0.040, y: 0.450, width: 0.474, height: 0.025, confidence: 1),
        block("检查结果描述", page: 1, x: 0.041, y: 0.366, width: 0.256, height: 0.021, confidence: 0.5),
        block("合成描述第一行，", page: 1, x: 0.041, y: 0.325, width: 0.896, height: 0.023, confidence: 0.5),
        block("合成描述第二行。", page: 1, x: 0.041, y: 0.299, width: 0.884, height: 0.028, confidence: 1),
        block("查看影像", page: 1, x: 0.413, y: 0.107, width: 0.171, height: 0.021, confidence: 0.5),
        block("下载影像", page: 1, x: 0.413, y: 0.036, width: 0.170, height: 0.022, confidence: 1),
    ]

    let candidates = ReportCandidateExtractor().extract(from: blocks)

    #expect(candidates.title?.transcription == "合成部位CTA")
    #expect(candidates.title?.references.map(\.blockID) == [blocks[5].id])
    #expect(candidates.memberName?.transcription == "合成成员")
    #expect(candidates.organization == nil)
    #expect(candidates.department == nil)
    #expect(candidates.reportType == nil)
    #expect(candidates.reportedResults?.transcription == "合成检查结果一句。\n合成描述第一行，\n合成描述第二行。")
    #expect(candidates.reportedResults?.references.map(\.blockID) == [
        blocks[11].id, blocks[13].id, blocks[14].id,
    ])
    #expect(candidates.conclusion == nil)
    #expect(candidates.dateCandidates.map(\.kind) == [.examination])
    #expect(candidates.dateCandidates.first?.source.transcription == "2026-07-31 08:46:43")
    #expect(candidates.abnormalItems.isEmpty)
}

@Test
func candidateExtractorReadsAPhotographedPaperReportLayout() throws {
    let blocks = try [
        block("合成市第一附属医院", page: 1, x: 0.282, y: 0.906, width: 0.375, height: 0.058, confidence: 1),
        block("MRI检査报告单", page: 1, x: 0.360, y: 0.822, width: 0.206, height: 0.060, confidence: 0.5),
        block("检查号：SYNTHETIC0001", page: 1, x: 0.579, y: 0.739, width: 0.254, height: 0.045, confidence: 0.5),
        block("扫码查看报告及影像", page: 1, x: 0.078, y: 0.632, width: 0.177, height: 0.037, confidence: 1),
        block("姓名：合成成员", page: 1, x: 0.071, y: 0.551, width: 0.115, height: 0.040, confidence: 0.5),
        block("登记号：", page: 1, x: 0.641, y: 0.551, width: 0.078, height: 0.039, confidence: 0.5),
        block("0000000001", page: 1, x: 0.751, y: 0.554, width: 0.108, height: 0.032, confidence: 1),
        block("8/6/2026 3:36:47", page: 1, x: 0.724, y: 0.506, width: 0.124, height: 0.034, confidence: 1),
        block("科室：合成内科门诊", page: 1, x: 0.070, y: 0.473, width: 0.249, height: 0.063, confidence: 0.3),
        block("检查日期：PM", page: 1, x: 0.637, y: 0.477, width: 0.125, height: 0.053, confidence: 0.3),
        block("合成成像，合成平扫", page: 1, x: 0.276, y: 0.337, width: 0.353, height: 0.057, confidence: 0.5),
        block("检査所见：", page: 1, x: 0.073, y: 0.252, width: 0.112, height: 0.049, confidence: 0.5),
        block("合成所见第一行，", page: 1, x: 0.133, y: 0.179, width: 0.696, height: 0.052, confidence: 0.5),
        block("合成所见第二行。", page: 1, x: 0.096, y: 0.127, width: 0.575, height: 0.053, confidence: 1),
    ]

    let candidates = ReportCandidateExtractor().extract(from: blocks)

    #expect(candidates.organization?.transcription == "合成市第一附属医院")
    #expect(candidates.department?.transcription == "合成内科门诊")
    #expect(candidates.reportType?.transcription == "MRI检查报告单")
    #expect(candidates.reportType?.originalTranscription == "MRI检査报告单")
    #expect(candidates.reportType?.references.map(\.blockID) == [blocks[1].id])
    #expect(candidates.title == nil)
    #expect(candidates.memberName?.transcription == "合成成员")
    #expect(candidates.reportedResults?.transcription == "合成所见第一行，\n合成所见第二行。")
    #expect(candidates.conclusion == nil)
    #expect(candidates.dateCandidates.isEmpty)
}

@Test(arguments: [
    "具体报告信息请以医院纸质报告为准。",
    "本报告仅供本院医师参考",
    "如有疑问请到医院咨询",
    "医院地址：合成路 1 号",
    "扫码关注医院公众号",
    String(repeating: "合成", count: 20) + "医院",
])
func candidateExtractorDoesNotReadASentenceMentioningAHospitalAsItsName(_ text: String) throws {
    let candidates = ReportCandidateExtractor().extract(from: [
        try block(text, page: 1, y: 0.9),
    ])

    #expect(candidates.organization == nil)
}

@Test(arguments: ["合成市测试医院", "合成大学附属医院东院区", "合成市测试医院检验报告单"])
func candidateExtractorStillReadsAShortLetterheadAsTheOrganization(_ text: String) throws {
    let candidates = ReportCandidateExtractor().extract(from: [
        try block(text, page: 1, y: 0.9),
    ])

    #expect(candidates.organization?.transcription == text)
}

@Test
func candidateExtractorReadsAFormNameEndingInReportSheetAsTheReportType() throws {
    let extractor = ReportCandidateExtractor()

    #expect(extractor.extract(from: [
        try block("合成超声检查报告单", page: 1, y: 0.9),
    ]).reportType?.transcription == "合成超声检查报告单")
    // A labelled line is some other field that happens to end the same way.
    #expect(extractor.extract(from: [
        try block("备注：详见合成报告单", page: 1, y: 0.9),
    ]).reportType == nil)
    #expect(extractor.extract(from: [
        try block(String(repeating: "合", count: 22) + "报告单", page: 1, y: 0.9),
    ]).reportType == nil)
    // An explicit label earlier on the page still wins.
    #expect(extractor.extract(from: [
        try block("报告类型：合成类型", page: 1, y: 0.9),
        try block("合成超声检查报告单", page: 1, y: 0.8),
    ]).reportType?.transcription == "合成类型")
}

@Test
func candidateExtractorTakesTheValueBesideOrUnderALabelThatStandsAlone() throws {
    func label(_ text: String) throws -> OCRBlock {
        try block(text, page: 1, x: 0.05, y: 0.8, width: 0.15)
    }
    let cases: [(name: String, blocks: [OCRBlock], expected: String?)] = try [
        ("under", [label("检查名称"), block("合成检查", page: 1, x: 0.05, y: 0.76, width: 0.3)], "合成检查"),
        ("under, spaced", [label("检 查 名 称："), block("合成检查", page: 1, x: 0.06, y: 0.76, width: 0.3)], "合成检查"),
        ("beside", [label("检查名称："), block("合成检查", page: 1, x: 0.25, y: 0.801, width: 0.3)], "合成检查"),
        ("beside wins", [
            label("检查名称"),
            block("合成旁边", page: 1, x: 0.25, y: 0.8, width: 0.3),
            block("合成下方", page: 1, x: 0.05, y: 0.76, width: 0.3),
        ], "合成旁边"),
        ("nearest under", [
            label("检查名称"),
            block("合成较远", page: 1, x: 0.05, y: 0.73, width: 0.3),
            block("合成较近", page: 1, x: 0.05, y: 0.77, width: 0.3),
        ], "合成较近"),
        ("too far under", [label("检查名称"), block("合成检查", page: 1, x: 0.05, y: 0.6, width: 0.3)], nil),
        ("another column", [label("检查名称"), block("合成检查", page: 1, x: 0.5, y: 0.76, width: 0.3)], nil),
        ("another page", [label("检查名称"), block("合成检查", page: 2, x: 0.05, y: 0.76, width: 0.3)], nil),
        ("another label", [label("检查名称"), block("姓名：合成成员", page: 1, x: 0.05, y: 0.76, width: 0.3)], nil),
        ("a heading", [label("检查名称"), block("检查所见", page: 1, x: 0.05, y: 0.76, width: 0.3)], nil),
        ("a button", [label("检查名称"), block("下载报告", page: 1, x: 0.05, y: 0.76, width: 0.3)], nil),
        ("not only a label", [label("检查名称及说明"), block("合成检查", page: 1, x: 0.05, y: 0.76, width: 0.3)], nil),
    ]

    for testCase in cases {
        let candidates = ReportCandidateExtractor().extract(from: testCase.blocks)
        #expect(
            candidates.title?.transcription == testCase.expected,
            "\(testCase.name)"
        )
        if testCase.expected != nil {
            // The proposal points at the block that holds the value, not the label.
            let valueBlock = try #require(testCase.blocks.first(where: { $0.text == testCase.expected }))
            #expect(candidates.title?.references.map(\.blockID) == [valueBlock.id], "\(testCase.name)")
        }
    }
}

@Test(arguments: ["检验项目", "项目名称", "检查项目"])
func candidateExtractorDoesNotReadAResultsTableColumnHeaderAsATitleLabel(_ header: String) throws {
    let blocks = try [
        block(header, page: 1, x: 0.05, y: 0.9, width: 0.2),
        block("结果", page: 1, x: 0.3, y: 0.9, width: 0.1),
        block("参考值", page: 1, x: 0.65, y: 0.9, width: 0.2),
        block("合成项目甲", page: 1, x: 0.05, y: 0.86, width: 0.25),
        block("1", page: 1, x: 0.3, y: 0.86, width: 0.1),
        block("0~2", page: 1, x: 0.65, y: 0.86, width: 0.2),
    ]

    let candidates = ReportCandidateExtractor().extract(from: blocks)

    #expect(candidates.title == nil)
}

@Test
func candidateExtractorNeedsASeparatorBetweenALabelAndItsValue() throws {
    let longerWords = ReportCandidateExtractor().extract(from: [
        try block("科室主任：合成主任", page: 1, y: 0.9),
        try block("报告类型说明", page: 1, y: 0.8),
        try block("标题栏", page: 1, y: 0.7),
        try block("姓名性别年龄", page: 1, y: 0.6),
    ])
    #expect(longerWords == ReportCandidates())

    let separated = ReportCandidateExtractor().extract(from: [
        try block("科室 合成科室", page: 1, y: 0.9),
        try block("报告类型:合成类型", page: 1, y: 0.8),
        try block("姓名 合成成员", page: 1, y: 0.7),
        try block("检查名称\u{3000}合成检查", page: 1, y: 0.6),
    ])
    #expect(separated.department?.transcription == "合成科室")
    #expect(separated.reportType?.transcription == "合成类型")
    #expect(separated.memberName?.transcription == "合成成员")
    #expect(separated.title?.transcription == "合成检查")
}

@Test
func candidateExtractorKeepsTheSourceTextOfADateWhoseLabelHasNoSeparator() throws {
    let candidates = ReportCandidateExtractor().extract(from: [
        try block("检查日期2026-01-02", page: 1, y: 0.8),
    ])

    #expect(candidates.dateCandidates.map(\.kind) == [.examination])
    #expect(candidates.dateCandidates.first?.source.transcription == "2026-01-02")
}

@Test
func candidateExtractorStopsFindingsAtConclusionsAndViewerButtons() throws {
    let blocks = try [
        block("检查所见：合成所见同行。", page: 1, y: 0.9),
        block("合成所见续行。", page: 1, y: 0.85),
        block("诊断意见", page: 1, y: 0.8),
        block("合成诊断。", page: 1, y: 0.75),
        block("检查结果描述：合成描述。", page: 1, y: 0.7),
        block("下载报告", page: 1, y: 0.65),
        block("合成按钮之后的文字", page: 1, y: 0.6),
    ]

    let candidates = ReportCandidateExtractor().extract(from: blocks)

    #expect(candidates.reportedResults?.transcription == "合成所见同行。\n合成所见续行。\n合成描述。")
    #expect(candidates.conclusion?.transcription == "合成诊断。")
}

@Test(arguments: ["查看影像", "查看图像", "下载影像", "下载图像", "下载报告"])
func candidateExtractorStopsASectionBeforeViewerAndDownloadButtons(_ button: String) throws {
    let candidates = ReportCandidateExtractor().extract(from: [
        try block("检查结论", page: 1, y: 0.7),
        try block("合成结论正文。", page: 1, y: 0.6),
        try block(button, page: 1, y: 0.4),
        try block("合成按钮之后的文字", page: 1, y: 0.3),
    ])

    #expect(candidates.conclusion?.transcription == "合成结论正文。")
}

@Test
func candidateExtractorMatchesVariantCharactersWithoutRewritingRecognition() throws {
    let label = try block("检査名称：合成复査项目", page: 1, y: 0.9)
    let heading = try block("检査结论", page: 1, y: 0.8)
    let body = try block("合成复査结论。", page: 1, y: 0.7)
    let date = try block("检査日期：2026-01-02", page: 1, y: 0.5)
    let blocks = [label, heading, body, date]

    let candidates = ReportCandidateExtractor().extract(from: blocks)

    // The proposal restores the character; what recognition read stays as the
    // original transcription, and the reference still names the same block.
    let conclusion = try #require(candidates.conclusion)
    #expect(conclusion.transcription == "合成复查结论。")
    #expect(conclusion.originalTranscription == "合成复査结论。")
    #expect(conclusion.correctedTranscription == "合成复查结论。")
    #expect(conclusion.entryMethod == nil)
    #expect(conclusion.references.map(\.blockID) == [body.id])
    let title = try #require(candidates.title)
    #expect(title.transcription == "合成复查项目")
    #expect(title.originalTranscription == "合成复査项目")
    #expect(title.references.map(\.blockID) == [label.id])
    #expect(candidates.dateCandidates.map(\.kind) == [.examination])
    #expect(candidates.dateCandidates.first?.source.originalTranscription == "2026-01-02")
    #expect(candidates.dateCandidates.first?.source.correctedTranscription == nil)
    #expect(blocks.map(\.text) == ["检査名称：合成复査项目", "检査结论", "合成复査结论。", "检査日期：2026-01-02"])

    // The saved recognition and its proposals survive a round trip unchanged.
    let source = try ReportSource(attachmentID: UUID(), displayName: "synthetic.png", pageCount: 1)
    let sources = try ReportSources([source])
    let attributed = try blocks.map { try $0.attributedAndValidated(for: sources) }
    let document = try ImportDraftDocument(
        blocks: attributed,
        candidates: ReportCandidateExtractor().extract(from: attributed, sources: sources)
    ).attributedAndValidated(for: sources)
    let reopened = try JSONDecoder().decode(
        ImportDraftDocument.self,
        from: JSONEncoder().encode(document)
    ).attributedAndValidated(for: sources)
    #expect(reopened.blocks.map(\.text) == blocks.map(\.text))
    #expect(reopened.candidates.conclusion?.originalTranscription == "合成复査结论。")
    #expect(reopened.candidates.conclusion?.transcription == "合成复查结论。")
}

@Test
func candidateExtractorLeavesTextWithoutVariantsUncorrected() throws {
    let candidates = ReportCandidateExtractor().extract(from: [
        try block("检查结论", page: 1, y: 0.8),
        try block("合成复查结论。", page: 1, y: 0.7),
    ])

    #expect(candidates.conclusion?.originalTranscription == "合成复查结论。")
    #expect(candidates.conclusion?.correctedTranscription == nil)
}

@Test
func candidateExtractorRebuildsATableWhoseFooterLabelUsesAVariantCharacter() throws {
    let blocks = try [
        block("项目", page: 1, x: 0.05, y: 0.9, width: 0.2),
        block("结果", page: 1, x: 0.4, y: 0.9, width: 0.2),
        block("参考值", page: 1, x: 0.65, y: 0.9, width: 0.2),
        block("合成项目甲", page: 1, x: 0.05, y: 0.8, width: 0.25),
        block("1", page: 1, x: 0.4, y: 0.8, width: 0.1),
        block("0~2", page: 1, x: 0.65, y: 0.8, width: 0.2),
        block("检査时间：2026-07-18 09:30", page: 1, x: 0.05, y: 0.45, width: 0.35),
        block("页脚伪项目", page: 1, x: 0.05, y: 0.35, width: 0.25),
        block("99", page: 1, x: 0.4, y: 0.351, width: 0.1),
        block("1~2", page: 1, x: 0.65, y: 0.349, width: 0.2),
    ]

    let candidates = ReportCandidateExtractor().extract(from: blocks)

    #expect(candidates.reportedResults?.transcription == "合成项目甲\t1\t0~2")
    #expect(candidates.dateCandidates.map(\.kind) == [.examination])
}
