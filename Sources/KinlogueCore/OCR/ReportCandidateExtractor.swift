import Foundation

public struct ReportCandidates: Codable, Equatable, Sendable {
    public var memberName: SourceField?
    public var organization: SourceField?
    public var department: SourceField?
    public var reportType: SourceField?
    public var title: SourceField?
    public var dateCandidates: [ReportDateCandidate]
    public var reportedResults: SourceField?
    public var conclusion: SourceField?
    public var abnormalItems: [SourceField]

    public init(
        memberName: SourceField? = nil,
        organization: SourceField? = nil,
        department: SourceField? = nil,
        reportType: SourceField? = nil,
        title: SourceField? = nil,
        dateCandidates: [ReportDateCandidate] = [],
        reportedResults: SourceField? = nil,
        conclusion: SourceField? = nil,
        abnormalItems: [SourceField] = []
    ) {
        self.memberName = memberName
        self.organization = organization
        self.department = department
        self.reportType = reportType
        self.title = title
        self.dateCandidates = dateCandidates
        self.reportedResults = reportedResults
        self.conclusion = conclusion
        self.abnormalItems = abnormalItems
    }

    public func attributedAndValidated(for sources: ReportSources) throws -> Self {
        guard Set(dateCandidates.map(\.id)).count == dateCandidates.count else {
            throw DomainValidationError.duplicateIdentifier
        }
        return try Self(
            memberName: memberName?.attributedAndValidated(for: sources),
            organization: organization?.attributedAndValidated(for: sources),
            department: department?.attributedAndValidated(for: sources),
            reportType: reportType?.attributedAndValidated(for: sources),
            title: title?.attributedAndValidated(for: sources),
            dateCandidates: dateCandidates.map {
                ReportDateCandidate(
                    id: $0.id,
                    date: $0.date,
                    kind: $0.kind,
                    source: try $0.source.attributedAndValidated(for: sources)
                )
            },
            reportedResults: reportedResults?.attributedAndValidated(for: sources),
            conclusion: conclusion?.attributedAndValidated(for: sources),
            abnormalItems: abnormalItems.map {
                try $0.attributedAndValidated(for: sources)
            }
        )
    }
}

public struct ReportCandidateExtractor: Sendable {
    public static let extractionVersion = 4

    private static let memberNameLabels = ["受检者姓名", "患者姓名", "病人姓名", "姓名"]
    private static let organizationLabels = [
        "医疗机构名称", "医院名称", "机构名称", "医疗机构", "送检单位", "检查机构", "检验机构",
    ]
    private static let departmentLabels = [
        "申请科室", "开单科室", "送检科室", "就诊科室", "临床科室",
        "执行科室", "检查科室", "检验科室", "科室",
    ]
    private static let reportTypeLabels = [
        "报告类型", "报告类别", "报告种类", "检查类型", "检查类别", "检验类型",
    ]
    private static let titleLabels = [
        "报告标题", "报告名称", "检查名称", "检查项目", "检验名称", "检验项目", "项目名称", "标题",
    ]
    private static let conclusionHeadings = [
        "检查结论", "检查诊断", "诊断意见", "诊断结论", "报告结论", "诊断提示", "诊断印象",
        "影像学诊断", "影像诊断", "放射学诊断", "超声诊断", "内镜诊断", "病理诊断",
    ]
    private static let narrativeResultHeadings = [
        "检查所见", "检查结果", "检查表现", "影像所见", "影像学表现", "放射学表现",
        "超声所见", "内镜所见", "病理所见", "检验结果",
    ]
    private static let dateLabelMappings: [(String, ReportDateKind)] = [
        ("出报告时间", .report),
        ("报告日期时间", .report),
        ("报告时间", .report),
        ("报告日期", .report),
        ("检查时间", .examination),
        ("检查日期", .examination),
        ("检验时间", .examination),
        ("检验日期", .examination),
        ("采样时间", .collection),
        ("采样日期", .collection),
        ("采集时间", .collection),
        ("采集日期", .collection),
        ("收样时间", .collection),
        ("收样日期", .collection),
        ("送检时间", .collection),
        ("送检日期", .collection),
        ("入院时间", .admission),
        ("入院日期", .admission),
        ("出院时间", .discharge),
        ("出院日期", .discharge),
        ("就诊时间", .other),
        ("就诊日期", .other),
    ]
    private static let stopHeadings = narrativeResultHeadings
        + conclusionHeadings
        + dateLabelMappings.map { $0.0 }
        + [
        "备注", "审核时间", "审核日期", "报告医师", "审核医师", "审核者",
        "查看原始影像", "查看原始图像", "查看报告", "扫码", "扫一扫", "简体中文", "English",
    ]
    private static let resultTableFooterHeadings = dateLabelMappings.map { $0.0 } + [
        "检验：", "检验:", "核对：", "核对:",
        "备注", "注：", "注:", "**代表",
    ]
    private static let headingDecorations = CharacterSet(charactersIn: "|｜丨│┃¦·•●○■□▪-—_*＊ ")
    private static let standaloneReportTypes = [
        "CT", "CTA", "MR", "MRI", "MRA", "X线", "DR", "CR", "超声", "B超", "PET-CT", "PET/CT",
        "检验报告", "化验单", "病理报告", "内镜报告", "心电图报告", "体检报告",
    ]
    private static let printedMarkerPattern = #"(?:↑|↓|(?:^|[\s:：])(?:H|L|High|Low)(?:$|[\s:：])|偏高|偏低)"#
    private static let standalonePrintedMarkerPattern = #"^(?:↑|↓|H|L|High|Low|偏高|偏低)$"#
    private static let rowAlignmentTolerance = 0.008
    private static let headerAlignmentTolerance = 0.012
    private static let dateValueMaximumHorizontalGap = 0.1
    private static let dateValueMaximumBlockCount = 4

    public init() {}

    public func extract(from blocks: [OCRBlock], sources: ReportSources) throws -> ReportCandidates {
        extract(from: try blocks.map { try $0.projected(for: sources) })
    }

    public func extract(from blocks: [OCRBlock]) -> ReportCandidates {
        let ordered = blocks.sorted(by: readingOrder)
        let blocksByPage = Dictionary(grouping: ordered, by: \.pageNumber)
        let numericOverlayBlockIDs = likelyNumericOverlayBlockIDs(in: ordered)
        var result = ReportCandidates()

        for block in ordered {
            let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let reference = sourceReference(for: block)

            if result.memberName == nil,
               let value = labeledValue(in: text, labels: Self.memberNameLabels) {
                result.memberName = sourceField(value, reference: reference)
            }
            if result.organization == nil,
               let value = labeledValue(in: text, labels: Self.organizationLabels) {
                result.organization = sourceField(value, reference: reference)
            }
            if result.department == nil,
               let value = labeledValue(in: text, labels: Self.departmentLabels) {
                result.department = sourceField(value, reference: reference)
            }
            if result.reportType == nil,
               let value = labeledValue(in: text, labels: Self.reportTypeLabels) {
                result.reportType = sourceField(value, reference: reference)
            }
            if result.reportType == nil,
               Self.standaloneReportTypes.contains(where: {
                   text.compare($0, options: .caseInsensitive) == .orderedSame
               }) {
                result.reportType = sourceField(text, reference: reference)
            }
            if result.title == nil,
               let value = labeledValue(in: text, labels: Self.titleLabels) {
                result.title = sourceField(value, reference: reference)
            }
            if result.organization == nil,
               text.count <= 80,
               (text.contains("医院") || text.contains("院区")) {
                result.organization = sourceField(text, reference: reference)
            }

            if isPrintedMarker(text), !isStandalonePrintedMarker(text) {
                if let field = sourceField(text, reference: reference) {
                    result.abnormalItems.append(field)
                }
            }
        }

        result.conclusion = sectionField(
            in: ordered,
            headings: Self.conclusionHeadings,
            stopHeadings: Self.stopHeadings,
            excluding: numericOverlayBlockIDs
        )
        result.dateCandidates = dateCandidates(in: ordered, blocksByPage: blocksByPage)
        result.reportedResults = reportedResults(in: ordered, blocksByPage: blocksByPage)
            ?? sectionField(
                in: ordered,
                headings: Self.narrativeResultHeadings,
                stopHeadings: Self.stopHeadings,
                excluding: numericOverlayBlockIDs
            )
        return result
    }

    private func sectionField(
        in ordered: [OCRBlock],
        headings: [String],
        stopHeadings: [String],
        excluding excludedBlockIDs: Set<OCRBlock.ID>
    ) -> SourceField? {
        var collectedBlocks: [OCRBlock] = []
        var isCollecting = false

        for block in ordered {
            let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let headingText = textDroppingHeadingDecorations(text)
            if let heading = headings.first(where: { headingText.hasPrefix($0) }) {
                isCollecting = true
                let remainder = String(headingText.dropFirst(heading.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: " :："))
                if !remainder.isEmpty, !excludedBlockIDs.contains(block.id) {
                    collectedBlocks.append(blockReplacingText(block, text: remainder))
                }
            } else if isCollecting {
                if stopHeadings.contains(where: { headingText.hasPrefix($0) }) {
                    isCollecting = false
                } else if !excludedBlockIDs.contains(block.id) {
                    collectedBlocks.append(block)
                }
            }
        }

        guard !collectedBlocks.isEmpty else { return nil }
        return try? SourceField(
            originalTranscription: collectedBlocks.map(\.text).joined(separator: "\n"),
            references: collectedBlocks.compactMap(sourceReference(for:))
        )
    }

    private func dateCandidates(
        in ordered: [OCRBlock],
        blocksByPage: [Int: [OCRBlock]]
    ) -> [ReportDateCandidate] {
        var candidates: [ReportDateCandidate] = []
        var seen: Set<DateCandidateIdentity> = []

        for block in ordered {
            let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let reference = sourceReference(for: block)
            if let candidate = dateCandidate(
                in: text,
                references: reference.map { [$0] } ?? [],
                id: block.id
            ) {
                append(candidate, to: &candidates, seen: &seen)
                continue
            }

            guard dateLabel(in: text) != nil else { continue }
            let sameLine = blocksByPage[block.pageNumber, default: []].filter { candidate in
                candidate.boundingBox.x > block.boundingBox.x
                    && abs(candidate.boundingBox.y - block.boundingBox.y) <= Self.rowAlignmentTolerance
            }.sorted { $0.boundingBox.x < $1.boundingBox.x }
            var joinedBlocks = [block]
            for adjacent in sameLine.prefix(Self.dateValueMaximumBlockCount) {
                guard let previous = joinedBlocks.last,
                      adjacent.boundingBox.x
                        - (previous.boundingBox.x + previous.boundingBox.width)
                        <= Self.dateValueMaximumHorizontalGap else {
                    break
                }
                joinedBlocks.append(adjacent)
                let joinedText = joinedBlocks.map(\.text).joined(separator: " ")
                let references = joinedBlocks.compactMap(sourceReference(for:))
                if let candidate = dateCandidate(
                    in: joinedText,
                    references: references,
                    id: block.id
                ) {
                    append(candidate, to: &candidates, seen: &seen)
                    break
                }
            }
        }
        return candidates
    }

    private func append(
        _ candidate: ReportDateCandidate,
        to candidates: inout [ReportDateCandidate],
        seen: inout Set<DateCandidateIdentity>
    ) {
        let identity = DateCandidateIdentity(date: candidate.date, kind: candidate.kind)
        guard seen.insert(identity).inserted else { return }
        candidates.append(candidate)
    }

    private func reportedResults(
        in ordered: [OCRBlock],
        blocksByPage: [Int: [OCRBlock]]
    ) -> SourceField? {
        let headers = resultTableHeaders(in: ordered, blocksByPage: blocksByPage)
        guard !headers.isEmpty else { return nil }
        var lines: [String] = []
        var referencedBlocks: [OCRBlock] = []

        for header in headers {
            let lowerBoundary = tableLowerBoundary(
                for: header,
                headers: headers,
                pageBlocks: blocksByPage[header.pageNumber, default: []]
            )
            let body = blocksByPage[header.pageNumber, default: []].filter { block in
                guard !header.blockIDs.contains(block.id),
                      block.boundingBox.y < header.y - Self.headerAlignmentTolerance else {
                    return false
                }
                if let lowerBoundary,
                   block.boundingBox.y <= lowerBoundary + Self.rowAlignmentTolerance {
                    return false
                }
                return true
            }
            let firstBoundary = (header.itemX + header.resultX) / 2
            let secondBoundary = (header.resultX + header.referenceX) / 2

            for row in alignedRows(body) {
                let item = joinedCell(row.filter { $0.boundingBox.x < firstBoundary })
                let result = joinedCell(row.filter {
                    ($0.boundingBox.x >= firstBoundary && $0.boundingBox.x < secondBoundary)
                        || isPrintedMarker($0.text)
                })
                let reference = joinedCell(row.filter {
                    $0.boundingBox.x >= secondBoundary && !isPrintedMarker($0.text)
                })
                guard !item.isEmpty, !result.isEmpty else { continue }
                lines.append([item, result, reference].filter { !$0.isEmpty }.joined(separator: "\t"))
                referencedBlocks.append(contentsOf: row)
            }
        }

        guard !lines.isEmpty else { return nil }
        return try? SourceField(
            originalTranscription: lines.joined(separator: "\n"),
            references: referencedBlocks.compactMap(sourceReference(for:))
        )
    }

    private func resultTableHeaders(
        in ordered: [OCRBlock],
        blocksByPage: [Int: [OCRBlock]]
    ) -> [ResultTableHeader] {
        var headers: [ResultTableHeader] = []
        for item in ordered where normalizedHeaderCell(item.text) == "项目" {
            let sameLine = blocksByPage[item.pageNumber, default: []].filter { block in
                abs(block.boundingBox.y - item.boundingBox.y) <= Self.headerAlignmentTolerance
            }
            guard let result = sameLine.first(where: { normalizedHeaderCell($0.text) == "结果" }),
                  let reference = sameLine.first(where: {
                      let text = normalizedHeaderCell($0.text)
                      return text == "参考值" || text == "参考范围"
                  }),
                  item.boundingBox.x < result.boundingBox.x,
                  result.boundingBox.x < reference.boundingBox.x else {
                continue
            }
            headers.append(ResultTableHeader(
                pageNumber: item.pageNumber,
                y: max(item.boundingBox.y, result.boundingBox.y, reference.boundingBox.y),
                itemX: item.boundingBox.x,
                resultX: result.boundingBox.x,
                referenceX: reference.boundingBox.x,
                blockIDs: [item.id, result.id, reference.id]
            ))
        }
        return headers
    }

    private func tableLowerBoundary(
        for header: ResultTableHeader,
        headers: [ResultTableHeader],
        pageBlocks: [OCRBlock]
    ) -> Double? {
        let footerY = pageBlocks
            .filter { block in
                guard block.boundingBox.y < header.y else { return false }
                let rawText = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let headingText = textDroppingHeadingDecorations(rawText)
                return Self.resultTableFooterHeadings.contains(where: {
                    rawText.hasPrefix($0) || headingText.hasPrefix($0)
                })
            }
            .map(\.boundingBox.y)
            .max()
        let nextHeaderY = headers
            .filter { $0.pageNumber == header.pageNumber && $0.y < header.y }
            .map(\.y)
            .max()
        return [footerY, nextHeaderY].compactMap { $0 }.max()
    }

    private func alignedRows(_ blocks: [OCRBlock]) -> [[OCRBlock]] {
        let ordered = blocks.sorted(by: readingOrder)
        var rows: [[OCRBlock]] = []
        for block in ordered {
            if let index = rows.indices.last,
               let anchor = rows[index].first,
               abs(anchor.boundingBox.y - block.boundingBox.y) <= Self.rowAlignmentTolerance {
                rows[index].append(block)
            } else {
                rows.append([block])
            }
        }
        return rows.map { $0.sorted { $0.boundingBox.x < $1.boundingBox.x } }
    }

    private func joinedCell(_ blocks: [OCRBlock]) -> String {
        blocks.sorted { $0.boundingBox.x < $1.boundingBox.x }
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func normalizedHeaderCell(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
    }

    private func textDroppingHeadingDecorations(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let scalars = trimmed.unicodeScalars.drop { Self.headingDecorations.contains($0) }
        return String(String.UnicodeScalarView(scalars))
    }

    private func isPrintedMarker(_ text: String) -> Bool {
        text.range(of: Self.printedMarkerPattern, options: .regularExpression) != nil
    }

    private func isStandalonePrintedMarker(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.range(
            of: Self.standalonePrintedMarkerPattern,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private func likelyNumericOverlayBlockIDs(in blocks: [OCRBlock]) -> Set<OCRBlock.ID> {
        let numericCandidates = blocks.filter(isStrongNumericOverlay)
        let strongOverlays = numericCandidates.filter { block in
            numericCandidates.contains { candidate in
                candidate.id != block.id
                    && candidate.pageNumber == block.pageNumber
                    && normalizedOverlayText(candidate.text) == normalizedOverlayText(block.text)
                    && verticallyOverlaps(candidate.boundingBox, block.boundingBox)
            }
        }
        var result = Set(strongOverlays.map(\.id))
        for block in blocks where !result.contains(block.id) && isWeakNumericOverlayFragment(block) {
            let overlappingStrongCount = strongOverlays.count { candidate in
                candidate.pageNumber == block.pageNumber
                    && verticallyOverlaps(candidate.boundingBox, block.boundingBox)
            }
            if overlappingStrongCount >= 2 {
                result.insert(block.id)
            }
        }
        return result
    }

    private func normalizedOverlayText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isStrongNumericOverlay(_ block: OCRBlock) -> Bool {
        guard let confidence = block.confidence, confidence <= 0.5 else { return false }
        let scalars = contentScalars(in: block.text)
        guard !scalars.isEmpty,
              !scalars.contains(where: { CharacterSet.letters.contains($0) }) else {
            return false
        }
        let digitCount = scalars.count(where: { CharacterSet.decimalDigits.contains($0) })
        return digitCount >= 2 && digitCount * 2 >= scalars.count
    }

    private func isWeakNumericOverlayFragment(_ block: OCRBlock) -> Bool {
        guard let confidence = block.confidence, confidence <= 0.5,
              block.boundingBox.width <= 0.08 else {
            return false
        }
        let scalars = contentScalars(in: block.text)
        let digitCount = scalars.count(where: { CharacterSet.decimalDigits.contains($0) })
        return !scalars.isEmpty
            && scalars.count <= 4
            && digitCount >= 2
            && digitCount * 2 >= scalars.count
            && !scalars.contains(where: isHanCharacter)
    }

    private func contentScalars(in text: String) -> [Unicode.Scalar] {
        text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    private func isHanCharacter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
            true
        default:
            false
        }
    }

    private func verticallyOverlaps(_ left: NormalizedRect, _ right: NormalizedRect) -> Bool {
        left.y <= right.y + right.height && right.y <= left.y + left.height
    }

    private func readingOrder(_ left: OCRBlock, _ right: OCRBlock) -> Bool {
        if left.pageNumber != right.pageNumber { return left.pageNumber < right.pageNumber }
        let verticalDelta = abs(left.boundingBox.y - right.boundingBox.y)
        if verticalDelta > 0.01 { return left.boundingBox.y > right.boundingBox.y }
        if left.boundingBox.x != right.boundingBox.x { return left.boundingBox.x < right.boundingBox.x }
        return left.id.uuidString < right.id.uuidString
    }

    private func labeledValue(in text: String, labels: [String]) -> String? {
        for label in labels where text.hasPrefix(label) {
            let remainder = String(text.dropFirst(label.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: " :："))
            if !remainder.isEmpty { return remainder }
        }
        return nil
    }

    private func dateCandidate(
        in text: String,
        references: [SourceReference],
        id: UUID
    ) -> ReportDateCandidate? {
        guard let (label, kind) = dateLabel(in: text),
              let date = parseDate(text) else { return nil }
        let sourceText = labeledValue(in: text, labels: [label]) ?? text
        guard let field = try? SourceField(
            originalTranscription: sourceText,
            references: references
        ) else { return nil }
        return ReportDateCandidate(
            id: id,
            date: date,
            kind: kind,
            source: field
        )
    }

    private func dateLabel(in text: String) -> (String, ReportDateKind)? {
        Self.dateLabelMappings.first(where: { text.hasPrefix($0.0) })
    }

    private func parseDate(_ text: String) -> Date? {
        let pattern = #"(\d{4})\s*(?:-|/|年)\s*(\d{1,2})\s*(?:-|/|月)\s*(\d{1,2})(?:日)?"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
              ),
              match.numberOfRanges == 4,
              let year = integerCapture(1, match: match, text: text),
              let month = integerCapture(2, match: match, text: text),
              let day = integerCapture(3, match: match, text: text) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: 12
        )) else { return nil }
        let resolved = calendar.dateComponents([.year, .month, .day], from: date)
        guard resolved.year == year,
              resolved.month == month,
              resolved.day == day else { return nil }
        return date
    }

    private func integerCapture(
        _ index: Int,
        match: NSTextCheckingResult,
        text: String
    ) -> Int? {
        guard let range = Range(match.range(at: index), in: text) else { return nil }
        return Int(text[range])
    }

    private func sourceReference(for block: OCRBlock) -> SourceReference? {
        if let sourceID = block.sourceID, let attachmentID = block.attachmentID {
            return try? SourceReference(
                sourceID: sourceID,
                attachmentID: attachmentID,
                filePageNumber: block.filePageNumber,
                boundingBox: block.boundingBox,
                blockID: block.id
            )
        }
        return try? SourceReference(
            pageNumber: block.filePageNumber,
            boundingBox: block.boundingBox,
            blockID: block.id
        )
    }

    private func sourceField(
        _ text: String,
        reference: SourceReference?
    ) -> SourceField? {
        try? SourceField(
            originalTranscription: text,
            references: reference.map { [$0] } ?? []
        )
    }

    private func blockReplacingText(_ block: OCRBlock, text: String) -> OCRBlock {
        block.replacingText(with: text)
    }
}

private struct DateCandidateIdentity: Hashable {
    let date: Date
    let kind: ReportDateKind
}

private struct ResultTableHeader {
    let pageNumber: Int
    let y: Double
    let itemX: Double
    let resultX: Double
    let referenceX: Double
    let blockIDs: Set<OCRBlock.ID>
}
