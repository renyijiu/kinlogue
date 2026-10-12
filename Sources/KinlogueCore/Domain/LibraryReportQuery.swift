import Foundation

package enum LibraryReportError: Error, Equatable, Sendable {
    case recordNotFound, draftNotFound, memberNotFound, invalidDocument, staleRevision, staleCursor, resourceLimit
}

/// Bounded display projections; full source transcriptions remain in the record detail.
package struct LibraryReportSummary: Equatable, Identifiable, Sendable {
    package let id: UUID
    package let memberID: UUID
    package let revision: UInt64
    package let timelineDate: Date?
    package let dateKind: ReportDateKind?
    package let title: String?
    package let reportType: String?
    package let organization: String?
    package let conclusion: String?

    package init(record: HealthRecord) {
        id = record.id; memberID = record.memberID; revision = record.revision
        timelineDate = record.timelineDate; dateKind = record.timelineDateCandidate?.kind
        title = record.title.map { String(String.UnicodeScalarView($0.transcription.unicodeScalars.prefix(160))) }
        reportType = record.reportType.map { String(String.UnicodeScalarView($0.transcription.unicodeScalars.prefix(128))) }
        organization = record.organization.map { String(String.UnicodeScalarView($0.transcription.unicodeScalars.prefix(128))) }
        conclusion = record.conclusion.map { String(String.UnicodeScalarView($0.transcription.unicodeScalars.prefix(512))) }
    }

    package init(id: UUID, memberID: UUID, revision: UInt64, timelineDate: Date?, dateKind: ReportDateKind?,
                 title: String?, reportType: String?, organization: String?, conclusion: String?) {
        self.id = id; self.memberID = memberID; self.revision = revision; self.timelineDate = timelineDate
        self.dateKind = dateKind; self.title = title; self.reportType = reportType
        self.organization = organization; self.conclusion = conclusion
    }
}

package struct LibraryRevision: Equatable, Sendable {
    package let libraryID: UUID
    package let openEpoch: UUID
    package let generation: UInt64
    package let commitID: UUID

    package init(libraryID: UUID, openEpoch: UUID, generation: UInt64, commitID: UUID) {
        self.libraryID = libraryID; self.openEpoch = openEpoch
        self.generation = generation; self.commitID = commitID
    }
}

package struct LibraryQueryCursor: Equatable, Sendable {
    package let libraryID: UUID
    package let commitID: UUID
    package let openEpoch: UUID
    package let scope: String
    package let memberID: UUID?
    package let lastID: UUID
    package let lastDate: Date?
    package let lastKind: Int

    package init(libraryID: UUID, commitID: UUID, openEpoch: UUID, scope: String, memberID: UUID?, lastID: UUID, lastDate: Date?, lastKind: Int = 0) {
        self.libraryID = libraryID; self.commitID = commitID; self.openEpoch = openEpoch; self.scope = scope; self.memberID = memberID
        self.lastID = lastID; self.lastDate = lastDate; self.lastKind = lastKind
    }
}

package struct LibraryReportPage: Sendable {
    package let revision: LibraryRevision
    package let items: [LibraryReportSummary]
    package let nextCursor: LibraryQueryCursor?
    package let damagedIDs: [UUID]
    package let damagedMemberIDs: [UUID]
    package init(revision: LibraryRevision, items: [LibraryReportSummary], nextCursor: LibraryQueryCursor?, damagedIDs: [UUID] = [], damagedMemberIDs: [UUID] = []) {
        self.revision = revision; self.items = items; self.nextCursor = nextCursor; self.damagedIDs = damagedIDs; self.damagedMemberIDs = damagedMemberIDs
    }
}

package struct LibraryDraftSummary: Equatable, Identifiable, Sendable {
    package let id: UUID
    package let state: ImportState
    package let revision: UInt64
    package let memberID: UUID?
    package let failureCode: ImportFailureCode?
    package let sourceCount: Int
    package init(id: UUID, state: ImportState, revision: UInt64, memberID: UUID?, failureCode: ImportFailureCode?, sourceCount: Int) {
        self.id = id; self.state = state; self.revision = revision; self.memberID = memberID
        self.failureCode = failureCode; self.sourceCount = sourceCount
    }
}

package struct LibraryDraftPage: Sendable {
    package let revision: LibraryRevision
    package let items: [LibraryDraftSummary]
    package let nextCursor: LibraryQueryCursor?
    package let damagedIDs: [UUID]
    package init(revision: LibraryRevision, items: [LibraryDraftSummary], nextCursor: LibraryQueryCursor?, damagedIDs: [UUID] = []) {
        self.revision = revision; self.items = items; self.nextCursor = nextCursor; self.damagedIDs = damagedIDs
    }
}
