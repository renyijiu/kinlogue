import Foundation

package enum AssistantPackSelection: Hashable, Sendable {
    /// The newest confirmed reports that fit the index.
    case automatic
    /// Exactly these reports; the build fails rather than dropping any of them from the index.
    case explicit([UUID])
}

package enum AssistantPackError: Error, Equatable, Sendable {
    case memberArchived
    case noConfirmedRecords
    case recordUnavailable
    case duplicateSelection
    case emptySelection
    case selectionTooLarge
    case invalidDigest
}

/// One confirmed report in the pack. The label means something only inside this pack; every layer
/// that mentions the report uses it.
package struct AssistantPackEntry: Hashable, Sendable {
    package let label: String
    package let recordID: UUID
    package let recordRevision: UInt64
    /// `yyyy-MM-dd` in the canonical report calendar, or nil for a report without a timeline date.
    package let date: String?
    package let dateKind: ReportDateKind?
    /// The report has lines in the conclusions layer.
    package let hasConclusion: Bool
    /// The report's rows in the results-by-item layer.
    package let resultRowCount: Int
    /// Title and results as the full-text layer sends them, escaped and possibly cut; nil when the
    /// report's full text is not sent.
    package let fullText: String?
    /// The full text was cut to `AssistantLimits.maxRecordBytes`.
    package let isTruncated: Bool
    /// See `AssistantContextPackBuilder.projectionDigest(of:digest:)`.
    package let projectionDigest: Data
}

/// What one conversation sends about one member, built on this Mac from the member's confirmed
/// reports (layered context plan, docs/plans/2026-10-18-feat-member-chat-layered-context-plan.md):
/// an index of every report, their conclusions and flagged items, their table rows grouped by item
/// name, and the full results of the newest reports that fit. Each layer only rearranges the
/// reports' own text. It carries no member name, note, file name, original, or record ID.
package struct AssistantContextPack: Hashable, Sendable {
    /// Bound into the consent: the same reports arranged another way ask again.
    package static let layout = "layered.v1"

    package let memberID: UUID
    /// Every indexed report, R1…Rn from oldest to newest.
    package let entries: [AssistantPackEntry]
    package let includesOrganization: Bool
    /// Confirmed reports of the member that are not in the index.
    package let omittedRecordCount: Int
    /// Indexed reports whose conclusion or flagged items did not fit their layer.
    package let omittedConclusionCount: Int
    package let resultItemCount: Int
    package let resultRowCount: Int
    package let omittedResultRowCount: Int
    package let omittedResultItemCount: Int
    private let rendered: String

    init(
        memberID: UUID, entries: [AssistantPackEntry], includesOrganization: Bool, omittedRecordCount: Int,
        omittedConclusionCount: Int, resultItemCount: Int, resultRowCount: Int, omittedResultRowCount: Int,
        omittedResultItemCount: Int, rendered: String
    ) {
        self.memberID = memberID
        self.entries = entries
        self.includesOrganization = includesOrganization
        self.omittedRecordCount = omittedRecordCount
        self.omittedConclusionCount = omittedConclusionCount
        self.resultItemCount = resultItemCount
        self.resultRowCount = resultRowCount
        self.omittedResultRowCount = omittedResultRowCount
        self.omittedResultItemCount = omittedResultItemCount
        self.rendered = rendered
    }

    /// UTF-8 bytes of the rendered `<records>` block.
    package var byteCount: Int { rendered.utf8.count }

    package var manifest: [AssistantTurnSource] {
        entries.map(AssistantTurnSource.init(entry:))
    }

    package func renderedRecords() -> String { rendered }

    /// The key a send consent is bound to: anything that changes what is sent, or who receives it,
    /// changes the key, including the revision of an indexed report whose full text is not sent.
    package func consentFingerprint(
        provider: AssistantProviderDescriptor,
        promptVersion: Int,
        digest: (Data) -> Data
    ) throws -> Data {
        var fields = [
            "kinlogue.assistant.consent.v2", String(promptVersion), provider.kind.rawValue, provider.cliVersion,
            provider.model, memberID.uuidString, includesOrganization ? "organization" : "-", Self.layout,
        ]
        for entry in entries {
            fields += [entry.label, entry.recordID.uuidString, String(entry.recordRevision)]
        }
        fields.append(rendered)
        return try AssistantContextPackBuilder.checkedDigest(AssistantContextPackBuilder.canonical(fields), digest)
    }
}

package enum AssistantContextPackBuilder {
    package static let truncationMarker = "\n[truncated]"
    /// Bytes each layer keeps free for its line saying what it left out.
    static let noteAllowance = 64
    private static let untitled = "(untitled)"

    /// Builds the pack from the member's records. Records of other members and records that are
    /// not confirmed are left out here as well as in the query that supplies them.
    ///
    /// A query may pass only the newest reports; `confirmedRecordCount` is then the member's total,
    /// so the pack still says how many reports it leaves out.
    package static func build(
        member: FamilyMember,
        records: [HealthRecord],
        selection: AssistantPackSelection = .automatic,
        includeOrganization: Bool = false,
        confirmedRecordCount: Int? = nil,
        digest: (Data) -> Data
    ) throws -> AssistantContextPack {
        guard !member.isArchived else { throw AssistantPackError.memberArchived }
        var seen = Set<UUID>()
        let confirmed = records.filter {
            $0.memberID == member.id && $0.importState == .confirmed && seen.insert($0.id).inserted
        }
        // Lines are measured with the widest label, since labels are given after the choice.
        let widestLabel = "R\(AssistantLimits.maxPackRecords)"
        func indexSize(_ record: HealthRecord) -> Int {
            indexLine(label: widestLabel, record, includeOrganization: includeOrganization).utf8.count + 1
        }

        var chosen: [HealthRecord] = []
        switch selection {
        case .automatic:
            guard !confirmed.isEmpty else { throw AssistantPackError.noConfirmedRecords }
            // Newest first, stopping at the first report that does not fit: skipping it for an
            // older one would leave a gap the model cannot see.
            var bytes = 0
            for record in confirmed.sorted(by: newestFirst) {
                let size = indexSize(record)
                guard chosen.count < AssistantLimits.maxPackRecords,
                      bytes + size <= AssistantLimits.maxIndexBytes - noteAllowance else { break }
                bytes += size
                chosen.append(record)
            }
        case let .explicit(ids):
            guard !ids.isEmpty else { throw AssistantPackError.emptySelection }
            guard Set(ids).count == ids.count else { throw AssistantPackError.duplicateSelection }
            let byID = Dictionary(uniqueKeysWithValues: confirmed.map { ($0.id, $0) })
            chosen = try ids.map {
                guard let record = byID[$0] else { throw AssistantPackError.recordUnavailable }
                return record
            }
            guard chosen.count <= AssistantLimits.maxPackRecords,
                  chosen.reduce(0, { $0 + indexSize($1) }) <= AssistantLimits.maxIndexBytes - noteAllowance else {
                throw AssistantPackError.selectionTooLarge
            }
        }

        let ordered = chosen.sorted(by: oldestFirst)
        let labels = ordered.indices.map { "R\($0 + 1)" }
        let dates = ordered.map { $0.timelineDateCandidate.map { canonicalDay($0.date) } }
        let omittedRecords = max(confirmedRecordCount ?? 0, confirmed.count) - chosen.count

        // Layer 1: the index.
        var indexLines = ordered.indices.map { indexLine(label: labels[$0], ordered[$0], includeOrganization: includeOrganization) }
        if omittedRecords > 0 {
            let which = selection == .automatic ? "earlier" : "other"
            indexLines.append("(\(omittedRecords) \(which) \(omittedRecords == 1 ? "record" : "records") not listed)")
        }

        // Layer 2: conclusions and flagged items, newest first within the budget.
        var conclusionBlocks: [Int: String] = [:]
        var omittedConclusions = 0
        var conclusionBytes = 0
        for position in ordered.indices.reversed() {
            guard let block = conclusionBlock(label: labels[position], ordered[position]) else { continue }
            let size = block.utf8.count + 1
            if omittedConclusions == 0, conclusionBytes + size <= AssistantLimits.maxConclusionsBytes - noteAllowance {
                conclusionBytes += size
                conclusionBlocks[position] = block
            } else {
                omittedConclusions += 1
            }
        }
        var conclusionLines = ordered.indices.compactMap { conclusionBlocks[$0] }
        if omittedConclusions > 0 {
            conclusionLines.append("(\(omittedConclusions) earlier \(omittedConclusions == 1 ? "conclusion" : "conclusions") not listed)")
        }

        // Layer 3: table rows grouped by identical item names.
        let results = resultsByItem(ordered, labels: labels, dates: dates)

        // Layer 4: full results of the newest reports, in whatever budget is left.
        let fixedParts = section("index", indexLines.joined(separator: "\n"))
            + section("conclusions", conclusionLines.joined(separator: "\n"))
            + section("results-by-item", results.text)
        var used = "<records>\n".utf8.count + fixedParts.utf8.count + "</records>".utf8.count
        var fullTexts: [Int: (text: String, isTruncated: Bool)] = [:]
        for position in ordered.indices.reversed() {
            guard let body = fullTextBody(ordered[position], includeOrganization: includeOrganization) else { continue }
            let size = recordBlock(label: labels[position], date: dates[position], kind: ordered[position].timelineDateCandidate?.kind,
                                   body: body.text).utf8.count + 1
            guard used + size <= AssistantLimits.maxPackBytes else { break }
            used += size
            fullTexts[position] = body
        }

        var rendered = "<records>\n" + fixedParts
        for position in ordered.indices {
            guard let body = fullTexts[position] else { continue }
            rendered += recordBlock(label: labels[position], date: dates[position], kind: ordered[position].timelineDateCandidate?.kind,
                                    body: body.text) + "\n"
        }
        rendered += "</records>"

        let entries = try ordered.indices.map { position in
            let record = ordered[position]
            return AssistantPackEntry(
                label: labels[position],
                recordID: record.id,
                recordRevision: record.revision,
                date: dates[position],
                dateKind: record.timelineDateCandidate?.kind,
                hasConclusion: conclusionBlocks[position] != nil,
                resultRowCount: results.rowsPerRecord[position, default: 0],
                fullText: fullTexts[position]?.text,
                isTruncated: fullTexts[position]?.isTruncated ?? false,
                projectionDigest: try projectionDigest(of: record, digest: digest)
            )
        }
        return AssistantContextPack(
            memberID: member.id,
            entries: entries,
            includesOrganization: includeOrganization,
            omittedRecordCount: omittedRecords,
            omittedConclusionCount: omittedConclusions,
            resultItemCount: results.itemCount,
            resultRowCount: results.rowCount,
            omittedResultRowCount: results.omittedRowCount,
            omittedResultItemCount: results.omittedItemCount,
            rendered: rendered
        )
    }

    /// A digest of the timeline date and every field the pack always sends, before escaping or
    /// cutting. It changes when that text changes and not for notes or other unsent edits. The
    /// optional organization line is left out so that status checks need no record of the setting.
    package static func projectionDigest(of record: HealthRecord, digest: (Data) -> Data) throws -> Data {
        let candidate = record.timelineDateCandidate
        let fields = [
            "kinlogue.assistant.projection.v1",
            candidate.map { canonicalDay($0.date) } ?? "",
            candidate?.kind.rawValue ?? "",
            projectionLines(of: record).joined(separator: "\n"),
        ]
        return try checkedDigest(canonical(fields), digest)
    }

    // MARK: - Layers

    private static func section(_ tag: String, _ text: String) -> String {
        text.isEmpty ? "" : "<\(tag)>\n\(text)\n</\(tag)>\n"
    }

    private static func indexLine(label: String, _ record: HealthRecord, includeOrganization: Bool) -> String {
        var date = "unknown"
        if let candidate = record.timelineDateCandidate {
            date = "\(canonicalDay(candidate.date)) (\(candidate.kind.rawValue))"
        }
        var line = "\(label) · \(date) · " + (oneLine((record.title ?? record.reportType)?.transcription,
                                                       scalars: AssistantLimits.maxIndexTitleScalars) ?? untitled)
        if includeOrganization, let organization = oneLine(record.organization?.transcription,
                                                           scalars: AssistantLimits.maxIndexTitleScalars) {
            line += " · \(organization)"
        }
        return line
    }

    private static func conclusionBlock(label: String, _ record: HealthRecord) -> String? {
        var lines: [String] = []
        if let conclusion = record.conclusion?.transcription {
            lines.append("[\(label)] Conclusion: \(AssistantPrompt.escaped(conclusion))")
        }
        if !record.abnormalItems.isEmpty {
            lines.append("[\(label)] Flagged: " + AssistantPrompt.escaped(record.abnormalItems.map(\.transcription).joined(separator: "; ")))
        }
        guard !lines.isEmpty else { return nil }
        return cut(lines.joined(separator: "\n"), toBytes: AssistantLimits.maxConclusionBytesPerRecord).text
    }

    private struct ResultRow {
        let position: Int
        let line: Int
        let text: String
    }

    private struct ResultsLayer {
        var text = ""
        var itemCount = 0
        var rowCount = 0
        var omittedRowCount = 0
        var omittedItemCount = 0
        var rowsPerRecord: [Int: Int] = [:]
    }

    /// Rows split into at least two cells by tabs, as the table extraction writes them, grouped
    /// when the first cell is spelled the same. Groups go most recently seen first; rows oldest
    /// first. Every group that fits keeps its newest row before older rows are added.
    private static func resultsByItem(_ ordered: [HealthRecord], labels: [String], dates: [String?]) -> ResultsLayer {
        var groups: [(name: String, rows: [ResultRow])] = []
        var groupIndex: [String: Int] = [:]
        for position in ordered.indices {
            guard let transcription = ordered[position].reportedResults?.transcription else { continue }
            for (line, text) in transcription.split(whereSeparator: \.isNewline).enumerated() {
                guard let row = ReportedResultLine(text) else { continue }
                let cells = row.bounded(toScalars: AssistantLimits.maxResultCellScalars).cells
                let name = cells[0]
                let rowText = "\(dates[position] ?? "unknown") [\(labels[position])] "
                    + AssistantPrompt.escaped(cells.dropFirst().joined(separator: " | "))
                if let index = groupIndex[name] {
                    groups[index].rows.append(ResultRow(position: position, line: line, text: rowText))
                } else {
                    groupIndex[name] = groups.count
                    groups.append((name, [ResultRow(position: position, line: line, text: rowText)]))
                }
            }
        }
        guard !groups.isEmpty else { return ResultsLayer() }
        // Rows were appended oldest first, so a group's last row is its newest.
        groups.sort { left, right in
            let l = left.rows.last!, r = right.rows.last!
            return l.position != r.position ? l.position > r.position : l.line < r.line
        }

        let budget = AssistantLimits.maxResultRowsBytes - noteAllowance
        func headerSize(_ name: String) -> Int { "<item>\nItem: \(AssistantPrompt.escaped(name))\n</item>\n".utf8.count }
        var used = 0
        var kept: [[ResultRow]] = []
        for group in groups {
            let newest = group.rows.last!
            let size = headerSize(group.name) + newest.text.utf8.count + 1 + (group.rows.count > 1 ? noteAllowance : 0)
            guard used + size <= budget else { break }
            used += size
            kept.append([newest])
        }
        // Older rows, newest first across the kept groups, until one does not fit.
        var older: [(group: Int, row: ResultRow)] = []
        for index in kept.indices {
            older += groups[index].rows.dropLast().map { (index, $0) }
        }
        older.sort { $0.row.position != $1.row.position ? $0.row.position > $1.row.position : $0.row.line < $1.row.line }
        for candidate in older {
            let size = candidate.row.text.utf8.count + 1
            let completes = kept[candidate.group].count + 1 == groups[candidate.group].rows.count
            guard used + size - (completes ? noteAllowance : 0) <= budget else { break }
            used += size - (completes ? noteAllowance : 0)
            kept[candidate.group].append(candidate.row)
        }

        var layer = ResultsLayer()
        var blocks: [String] = []
        for index in kept.indices {
            let rows = kept[index].sorted { $0.position != $1.position ? $0.position < $1.position : $0.line < $1.line }
            var lines = ["<item>", "Item: \(AssistantPrompt.escaped(groups[index].name))"] + rows.map(\.text)
            let left = groups[index].rows.count - rows.count
            if left > 0 { lines.append("(\(left) earlier \(left == 1 ? "result" : "results") not listed)") }
            lines.append("</item>")
            blocks.append(lines.joined(separator: "\n"))
            layer.rowCount += rows.count
            layer.omittedRowCount += left
            for row in rows { layer.rowsPerRecord[row.position, default: 0] += 1 }
        }
        layer.itemCount = kept.count
        layer.omittedItemCount = groups.count - kept.count
        layer.omittedRowCount += groups[kept.count...].reduce(0) { $0 + $1.rows.count }
        if layer.omittedItemCount > 0 {
            blocks.append("(\(layer.omittedItemCount) more \(layer.omittedItemCount == 1 ? "item" : "items") not listed)")
        }
        layer.text = blocks.joined(separator: "\n")
        return layer
    }

    private static func fullTextBody(_ record: HealthRecord, includeOrganization: Bool) -> (text: String, isTruncated: Bool)? {
        guard let results = record.reportedResults?.transcription else { return nil }
        var lines: [String] = []
        if let title = (record.title ?? record.reportType)?.transcription {
            lines.append("Title: \(title)")
        }
        if includeOrganization, let organization = record.organization?.transcription {
            lines.append("Organization: \(organization)")
        }
        lines.append("Results:\n\(results)")
        return cut(AssistantPrompt.escaped(lines.joined(separator: "\n")), toBytes: AssistantLimits.maxRecordBytes)
    }

    private static func recordBlock(label: String, date: String?, kind: ReportDateKind?, body: String) -> String {
        var attributes = #"id="\#(label)" date="\#(date ?? "unknown")""#
        if date != nil, let kind {
            attributes += #" date-kind="\#(kind.rawValue)""#
        }
        return "<record \(attributes)>\n\(body)\n</record>"
    }

    // MARK: - Text

    /// `text` within `bytes` UTF-8 bytes, ending in the truncation marker when it was cut.
    private static func cut(_ text: String, toBytes bytes: Int) -> (text: String, isTruncated: Bool) {
        guard text.utf8.count > bytes else { return (text, false) }
        let budget = bytes - truncationMarker.utf8.count
        var kept = ""
        var used = 0
        for character in text {
            let size = character.utf8.count
            guard used + size <= budget else { break }
            used += size
            kept.append(character)
        }
        return (kept + truncationMarker, true)
    }

    /// One escaped line of at most `scalars` Unicode scalars, or nil for blank text.
    private static func oneLine(_ text: String?, scalars: Int) -> String? {
        guard let text else { return nil }
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !flat.isEmpty else { return nil }
        return AssistantPrompt.escaped(String(String.UnicodeScalarView(flat.unicodeScalars.prefix(scalars))))
    }

    private static func projectionLines(of record: HealthRecord) -> [String] {
        var lines: [String] = []
        if let title = (record.title ?? record.reportType)?.transcription {
            lines.append("Title: \(title)")
        }
        if let results = record.reportedResults?.transcription {
            lines.append("Results:\n\(results)")
        }
        if let conclusion = record.conclusion?.transcription {
            lines.append("Conclusion: \(conclusion)")
        }
        if !record.abnormalItems.isEmpty {
            lines.append("Flagged items: " + record.abnormalItems.map(\.transcription).joined(separator: "; "))
        }
        return lines
    }

    /// Report dates are stored at noon UTC of their calendar day.
    private static func canonicalDay(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private static func newestFirst(_ left: HealthRecord, _ right: HealthRecord) -> Bool {
        switch (left.timelineDate, right.timelineDate) {
        case let (lhs?, rhs?) where lhs != rhs: lhs > rhs
        case (.some, nil): true
        case (nil, .some): false
        default: left.id.uuidString < right.id.uuidString
        }
    }

    private static func oldestFirst(_ left: HealthRecord, _ right: HealthRecord) -> Bool {
        switch (left.timelineDate, right.timelineDate) {
        case let (lhs?, rhs?) where lhs != rhs: lhs < rhs
        case (.some, nil): true
        case (nil, .some): false
        default: left.id.uuidString < right.id.uuidString
        }
    }

    // MARK: - Digests

    /// Length-prefixed fields, so no two different field lists share bytes.
    static func canonical(_ fields: [String]) -> Data {
        var data = Data()
        for field in fields {
            let bytes = Data(field.utf8)
            withUnsafeBytes(of: UInt32(bytes.count).bigEndian) { data.append(contentsOf: $0) }
            data.append(bytes)
        }
        return data
    }

    static func checkedDigest(_ data: Data, _ digest: (Data) -> Data) throws -> Data {
        let value = digest(data)
        guard value.count == 32 else { throw AssistantPackError.invalidDigest }
        return value
    }
}

extension AssistantTurnSource {
    /// Entries are built with a valid label and a checked 32-byte digest.
    init(entry: AssistantPackEntry) {
        label = entry.label
        recordID = entry.recordID
        recordRevision = entry.recordRevision
        projectionDigest = entry.projectionDigest
    }
}
