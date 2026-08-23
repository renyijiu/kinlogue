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
        if member?.displayName.localizedCaseInsensitiveContains(term) == true
            || member?.disambiguationLabel?.localizedCaseInsensitiveContains(term) == true
            || record.title?.transcription.localizedCaseInsensitiveContains(term) == true
            || record.organization?.transcription.localizedCaseInsensitiveContains(term) == true
            || record.department?.transcription.localizedCaseInsensitiveContains(term) == true
            || record.reportType?.transcription.localizedCaseInsensitiveContains(term) == true
            || record.reportedResults?.transcription.localizedCaseInsensitiveContains(term) == true
            || record.conclusion?.transcription.localizedCaseInsensitiveContains(term) == true {
            return true
        }
        if record.abnormalItems.contains(where: {
            $0.transcription.localizedCaseInsensitiveContains(term)
        }) {
            return true
        }
        guard let timelineDate = record.timelineDate else { return false }
        return dateFormatter.string(from: timelineDate)
            .localizedCaseInsensitiveContains(term)
    }

    private static func normalizedName(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static func stableRecordOrder(_ left: HealthRecord, _ right: HealthRecord) -> Bool {
        left.id.uuidString < right.id.uuidString
    }
}
