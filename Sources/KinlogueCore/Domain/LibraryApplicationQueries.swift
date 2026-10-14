import Foundation

package struct LibraryMemberSummary: Equatable, Identifiable, Sendable {
    package let id: UUID
    package let displayName: String
    package let disambiguationLabel: String?
    package let isArchived: Bool
    package init(id: UUID, displayName: String, disambiguationLabel: String?, isArchived: Bool) {
        self.id = id; self.displayName = displayName; self.disambiguationLabel = disambiguationLabel; self.isArchived = isArchived
    }
    package init(_ member: FamilyMember) {
        self.init(id: member.id, displayName: Self.preview(member.displayName),
            disambiguationLabel: member.disambiguationLabel.map(Self.preview), isArchived: member.isArchived)
    }
    package static func preview(_ value: String) -> String { String(String.UnicodeScalarView(value.unicodeScalars.prefix(160))) }
    package var stableShortID: String { String(id.uuidString.replacingOccurrences(of: "-", with: "").prefix(6)) }
    package static func selectable(_ members: [Self], includeArchived: Bool = false) -> [Self] {
        members.filter { includeArchived || !$0.isArchived }.sorted {
            let order = $0.displayName.localizedStandardCompare($1.displayName)
            return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
        }
    }
    package static func labels(_ members: [Self]) -> [UUID: String] {
        func key(_ value: String) -> String { value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) }
        let counts = Dictionary(grouping: members, by: { key($0.displayName) }).mapValues(\.count)
        return Dictionary(uniqueKeysWithValues: members.map { member in
            (member.id, counts[key(member.displayName), default: 0] > 1
                ? "\(member.displayName) (\(member.disambiguationLabel ?? member.stableShortID))" : member.displayName)
        })
    }
}

package struct LibraryHeader: Equatable, Sendable {
    package let revision: LibraryRevision
    package let members: [LibraryMemberSummary]
    package let studies: [LibraryDICOMStudySummary]
    package let reportCount: Int
    package let draftCount: Int
    package let damagedMemberIDs: [UUID]
    package let damagedStudyIDs: [UUID]
    package init(revision: LibraryRevision, members: [LibraryMemberSummary], studies: [LibraryDICOMStudySummary],
                 reportCount: Int, draftCount: Int, damagedMemberIDs: [UUID] = [], damagedStudyIDs: [UUID] = []) {
        self.revision = revision; self.members = members; self.studies = studies
        self.reportCount = reportCount; self.draftCount = draftCount
        self.damagedMemberIDs = damagedMemberIDs; self.damagedStudyIDs = damagedStudyIDs
    }
}

package enum LibraryTimelineItem: Equatable, Sendable {
    case report(LibraryReportSummary)
    case study(LibraryDICOMStudySummary)
    package var id: UUID { switch self { case .report(let r): r.id; case .study(let s): s.id } }
    package var date: Date? { switch self { case .report(let r): r.timelineDate; case .study(let s): s.effectiveDate } }
    package var kind: Int { switch self { case .report: 0; case .study: 1 } }
}

package struct LibraryTimelinePage: Sendable {
    package let revision: LibraryRevision
    package let items: [LibraryTimelineItem]
    package let nextCursor: LibraryQueryCursor?
    package let damagedIDs: [UUID]
    package init(revision: LibraryRevision, items: [LibraryTimelineItem], nextCursor: LibraryQueryCursor?, damagedIDs: [UUID]) {
        self.revision = revision; self.items = items; self.nextCursor = nextCursor; self.damagedIDs = damagedIDs
    }
}

package struct LibraryRecordSelection: Sendable {
    package let revision: LibraryRevision
    package let records: [HealthRecord]
    package init(revision: LibraryRevision, records: [HealthRecord]) { self.revision = revision; self.records = records }
}

package struct LibraryReviewSnapshot: Sendable {
    package let revision: LibraryRevision
    package let draft: ImportDraft
    package let document: ImportDraftDocument
    package let members: [LibraryMemberSummary]
    package let attachment: Attachment
    package let originalData: Data
    package init(revision: LibraryRevision, draft: ImportDraft, document: ImportDraftDocument, members: [LibraryMemberSummary], attachment: Attachment, originalData: Data) {
        self.revision = revision; self.draft = draft; self.document = document; self.members = members
        self.attachment = attachment; self.originalData = originalData
    }
}

/// Application queries and commands; a temporary JSON implementation is removed at the production cutover.
package struct LibraryDraftDisposition: Sendable {
    package let draft: ImportDraft?
    package let record: HealthRecord?
    package init(draft: ImportDraft?, record: HealthRecord?) { self.draft = draft; self.record = record }
}

package protocol LibraryReportStoring: Sendable {
    func initializeLibrary() async throws -> LibraryHeader
    func header() async throws -> LibraryHeader
    func member(_ id: UUID) async throws -> FamilyMember
    func saveMember(_ member: FamilyMember, replacing expected: FamilyMember?) async throws
    func deleteMember(_ id: UUID) async throws
    func draft(_ id: UUID) async throws -> ImportDraft
    func record(_ id: UUID) async throws -> HealthRecord
    func draftDisposition(_ id: UUID) async throws -> LibraryDraftDisposition
    func recordSelection(_ ids: [UUID]) async throws -> LibraryRecordSelection
    func reportPage(query: String, memberID: UUID?, limit: Int, cursor: LibraryQueryCursor?) async throws -> LibraryReportPage
    func timelinePage(memberID: UUID?, limit: Int, cursor: LibraryQueryCursor?) async throws -> LibraryTimelinePage
    func draftPage(states: [ImportState], limit: Int, cursor: LibraryQueryCursor?) async throws -> LibraryDraftPage
    func reviewContent(draftID: UUID) async throws -> LibraryReviewSnapshot
    func original(recordID: UUID, expectedRevision: UInt64, sourceID: UUID, expectedLibrary: LibraryRevision) async throws -> (Attachment, Data)
    func original(draftID: UUID, expectedRevision: UInt64, sourceID: UUID, expectedLibrary: LibraryRevision) async throws -> (Attachment, Data)
    func updateRecord(_ record: HealthRecord, expectedRevision: UInt64) async throws
    func deleteRecord(_ id: UUID, expectedRevision: UInt64) async throws
}

package protocol LibraryDICOMStoring: Sendable {
    func details(_ id: UUID) async throws -> LibraryDICOMStudyDetails
    func confirm(_ id: UUID, expectedRevision: UInt64, memberID: UUID, effectiveDate: Date) async throws -> LibraryDICOMStudySummary
    func delete(_ id: UUID, expectedRevision: UInt64) async throws
}
