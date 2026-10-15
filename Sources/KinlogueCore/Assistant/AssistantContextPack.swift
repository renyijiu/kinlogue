import Foundation

package enum AssistantPackSelection: Hashable, Sendable {
    /// The newest confirmed reports that fit the limits.
    case automatic
    /// Exactly these reports; the build fails rather than dropping any of them.
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

/// One confirmed report as it is sent. The label means something only inside this pack; the body
/// is the escaped, possibly cut text the model sees.
package struct AssistantPackEntry: Hashable, Sendable {
    package let label: String
    package let recordID: UUID
    package let recordRevision: UInt64
    /// `yyyy-MM-dd` in the canonical report calendar, or nil for a report without a timeline date.
    package let date: String?
    package let dateKind: ReportDateKind?
    package let body: String
    package let isTruncated: Bool
    /// See `AssistantContextPackBuilder.projectionDigest(of:digest:)`.
    package let projectionDigest: Data
}

/// The confirmed reports of one member that one conversation sends, labelled R1…Rn from oldest to
/// newest. It carries no member name, note, file name, original, or record ID in its text.
package struct AssistantContextPack: Hashable, Sendable {
    package let memberID: UUID
    package let entries: [AssistantPackEntry]
    package let includesOrganization: Bool
    /// Confirmed reports of the member that are not in the pack.
    package let omittedRecordCount: Int

    package var byteCount: Int { entries.reduce(0) { $0 + $1.body.utf8.count } }

    package var manifest: [AssistantTurnSource] {
        entries.map(AssistantTurnSource.init(entry:))
    }

    package func renderedRecords() -> String {
        let records = entries.map { entry in
            var attributes = #"id="\#(entry.label)" date="\#(entry.date ?? "unknown")""#
            if entry.date != nil, let kind = entry.dateKind {
                attributes += #" date-kind="\#(kind.rawValue)""#
            }
            return "<record \(attributes)>\n\(entry.body)\n</record>"
        }
        return (["<records>"] + records + ["</records>"]).joined(separator: "\n")
    }

    /// The key a send consent is bound to: anything that changes what is sent, or who receives it,
    /// changes the key.
    package func consentFingerprint(
        provider: AssistantProviderDescriptor,
        promptVersion: Int,
        digest: (Data) -> Data
    ) throws -> Data {
        var fields = [
            "kinlogue.assistant.consent.v1", String(promptVersion), provider.kind.rawValue, provider.cliVersion,
            provider.model, memberID.uuidString, includesOrganization ? "organization" : "-",
        ]
        for entry in entries {
            fields += [
                entry.label, entry.recordID.uuidString, String(entry.recordRevision), entry.date ?? "",
                entry.dateKind?.rawValue ?? "", entry.isTruncated ? "cut" : "-", entry.body,
            ]
        }
        return try AssistantContextPackBuilder.checkedDigest(AssistantContextPackBuilder.canonical(fields), digest)
    }
}

package enum AssistantContextPackBuilder {
    package static let truncationMarker = "\n[truncated]"

    /// Builds the pack from the member's records. Records of other members and records that are
    /// not confirmed are left out here as well as in the query that supplies them.
    package static func build(
        member: FamilyMember,
        records: [HealthRecord],
        selection: AssistantPackSelection = .automatic,
        includeOrganization: Bool = false,
        digest: (Data) -> Data
    ) throws -> AssistantContextPack {
        guard !member.isArchived else { throw AssistantPackError.memberArchived }
        var seen = Set<UUID>()
        let confirmed = records.filter {
            $0.memberID == member.id && $0.importState == .confirmed && seen.insert($0.id).inserted
        }
        let bodies = Dictionary(uniqueKeysWithValues: confirmed.map {
            ($0.id, body(of: $0, includeOrganization: includeOrganization))
        })

        var chosen: [HealthRecord] = []
        switch selection {
        case .automatic:
            guard !confirmed.isEmpty else { throw AssistantPackError.noConfirmedRecords }
            // Newest first, stopping at the first report that does not fit: skipping it for an
            // older, shorter one would leave a gap the model cannot see.
            var bytes = 0
            for record in confirmed.sorted(by: newestFirst) {
                let size = bodies[record.id]!.text.utf8.count
                guard chosen.count < AssistantLimits.maxPackRecords,
                      bytes + size <= AssistantLimits.maxPackBytes else { break }
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
            let bytes = chosen.reduce(0) { $0 + bodies[$1.id]!.text.utf8.count }
            guard chosen.count <= AssistantLimits.maxPackRecords, bytes <= AssistantLimits.maxPackBytes else {
                throw AssistantPackError.selectionTooLarge
            }
        }

        let entries = try chosen.sorted(by: oldestFirst).enumerated().map { index, record in
            let candidate = record.timelineDateCandidate
            return AssistantPackEntry(
                label: "R\(index + 1)",
                recordID: record.id,
                recordRevision: record.revision,
                date: candidate.map { canonicalDay($0.date) },
                dateKind: candidate?.kind,
                body: bodies[record.id]!.text,
                isTruncated: bodies[record.id]!.isTruncated,
                projectionDigest: try projectionDigest(of: record, digest: digest)
            )
        }
        return AssistantContextPack(
            memberID: member.id,
            entries: entries,
            includesOrganization: includeOrganization,
            omittedRecordCount: confirmed.count - chosen.count
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
            projectionLines(of: record, includeOrganization: false).joined(separator: "\n"),
        ]
        return try checkedDigest(canonical(fields), digest)
    }

    // MARK: - Rendering

    private static func body(of record: HealthRecord, includeOrganization: Bool) -> (text: String, isTruncated: Bool) {
        let lines = projectionLines(of: record, includeOrganization: includeOrganization)
        let full = AssistantPrompt.escaped(lines.isEmpty ? "(no transcribed content)" : lines.joined(separator: "\n"))
        guard full.utf8.count > AssistantLimits.maxRecordBytes else { return (full, false) }
        let budget = AssistantLimits.maxRecordBytes - truncationMarker.utf8.count
        var kept = ""
        var bytes = 0
        for character in full {
            let size = character.utf8.count
            guard bytes + size <= budget else { break }
            bytes += size
            kept.append(character)
        }
        return (kept + truncationMarker, true)
    }

    private static func projectionLines(of record: HealthRecord, includeOrganization: Bool) -> [String] {
        var lines: [String] = []
        if let title = (record.title ?? record.reportType)?.transcription {
            lines.append("Title: \(title)")
        }
        if includeOrganization, let organization = record.organization?.transcription {
            lines.append("Organization: \(organization)")
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
