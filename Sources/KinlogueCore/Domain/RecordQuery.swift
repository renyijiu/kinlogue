import Foundation

public enum TimelineDateGroup: Hashable, Sendable {
    case dated(Date)
    case unknown
}

public struct TimelineSection: Equatable, Sendable {
    public let group: TimelineDateGroup
    public let records: [HealthRecord]

    public init(group: TimelineDateGroup, records: [HealthRecord]) {
        self.group = group
        self.records = records
    }
}

public enum RecordQuery {
    public static func timeline(
        records: [HealthRecord],
        memberID: FamilyMember.ID
    ) -> [TimelineSection] {
        let confirmed = records.filter {
            $0.memberID == memberID && $0.importState == .confirmed
        }
        let datedGroups = Dictionary(grouping: confirmed.compactMap { record in
            record.timelineDate.map { ($0, record) }
        }, by: { $0.0 })

        var sections = datedGroups
            .map { date, entries in
                TimelineSection(
                    group: .dated(date),
                    records: entries.map(\.1).sorted(by: stableRecordOrder)
                )
            }
            .sorted { left, right in
                guard case let .dated(leftDate) = left.group,
                      case let .dated(rightDate) = right.group else { return false }
                return leftDate > rightDate
            }

        let unknown = confirmed
            .filter { $0.timelineDate == nil }
            .sorted(by: stableRecordOrder)
        if !unknown.isEmpty {
            sections.append(TimelineSection(group: .unknown, records: unknown))
        }
        return sections
    }

    public static func search(
        _ query: String,
        records: [HealthRecord],
        members: [FamilyMember],
        memberID: FamilyMember.ID? = nil
    ) -> [HealthRecord] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let membersByID = Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0) })
        let dateFormatter = term.isEmpty ? nil : ISO8601DateFormatter()

        return records
            .filter { record in
                guard record.importState == .confirmed else { return false }
                guard memberID == nil || record.memberID == memberID else { return false }
                guard !term.isEmpty, let dateFormatter else { return true }
                return matchesSearchTerm(
                    term,
                    record: record,
                    member: membersByID[record.memberID],
                    dateFormatter: dateFormatter
                )
            }
            .sorted { left, right in
                switch (left.timelineDate, right.timelineDate) {
                case let (leftDate?, rightDate?) where leftDate != rightDate:
                    return leftDate > rightDate
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    return stableRecordOrder(left, right)
                }
            }
    }

    public static func selectableMembers(
        from members: [FamilyMember],
        includeArchived: Bool = false
    ) -> [FamilyMember] {
        members
            .filter { includeArchived || !$0.isArchived }
            .sorted {
                let order = $0.displayName.localizedStandardCompare($1.displayName)
                return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
            }
    }

    public static func selectionLabels(
        for members: [FamilyMember]
    ) -> [FamilyMember.ID: String] {
        let nameCounts = Dictionary(grouping: members, by: { normalizedName($0.displayName) })
            .mapValues(\.count)

        return Dictionary(uniqueKeysWithValues: members.map { member in
            let isDuplicate = nameCounts[normalizedName(member.displayName), default: 0] > 1
            guard isDuplicate else { return (member.id, member.displayName) }
            let disambiguator = member.disambiguationLabel ?? member.stableShortID
            return (member.id, "\(member.displayName) (\(disambiguator))")
        })
    }

    private static func matchesSearchTerm(
        _ term: String,
        record: HealthRecord,
        member: FamilyMember?,
        dateFormatter: ISO8601DateFormatter
    ) -> Bool {
        matchesSearchTerm(term, fields: searchableFields(record: record, dateFormatter: dateFormatter)
            + [member?.displayName, member?.disambiguationLabel].compactMap { $0 })
    }

    package static func matchesSearchTerm(_ term: String, fields: [String]) -> Bool {
        fields.contains { localizedContains(term, in: $0, locale: .current) }
    }

    /// The localized, case-insensitive search behind every query path.
    ///
    /// When the term ends in NUL, Foundation's localized search reads past the end of the text as if
    /// NUL followed it: it reports a match that is not there, and for some text it traps. The text is
    /// then searched with one more unit that is not NUL, which keeps that read inside the text and
    /// can never be part of a match.
    package static func localizedContains(_ term: String, in field: String, locale: Locale) -> Bool {
        let text = term.unicodeScalars.last?.value == 0 ? field + "\u{1}" : field
        return text.range(of: term, options: .caseInsensitive, locale: locale) != nil
    }

    package static func searchableFields(record: HealthRecord) -> [String] {
        searchableFields(record: record, dateFormatter: ISO8601DateFormatter())
    }

    private static func searchableFields(record: HealthRecord, dateFormatter: ISO8601DateFormatter) -> [String] {
        [record.title, record.organization, record.department, record.reportType, record.reportedResults, record.conclusion]
            .compactMap { $0?.transcription }
            + record.abnormalItems.map(\.transcription)
            + (record.timelineDate.map { [dateFormatter.string(from: $0)] } ?? [])
    }

    private static func normalizedName(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static func stableRecordOrder(_ left: HealthRecord, _ right: HealthRecord) -> Bool {
        left.id.uuidString < right.id.uuidString
    }
}
