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
    /// The table lines of the confirmed results in which a search term was found, at most
    /// `maximumMatchedResultLines` of them. Empty outside a search.
    package let matchedResultLines: [ReportedResultLine]
    /// Every line the term was found in, including those beyond `matchedResultLines`.
    package let matchedResultLineCount: Int
    /// Where a search term was found when no listed line and no visible field shows it.
    package let matchedExcerpt: SearchExcerpt?

    package static let maximumMatchedResultLines = 8
    package static let maximumResultCellScalars = 160
    package static let maximumExcerptScalars = 480

    package init(record: HealthRecord) {
        id = record.id; memberID = record.memberID; revision = record.revision
        timelineDate = record.timelineDate; dateKind = record.timelineDateCandidate?.kind
        title = record.title.map { String(String.UnicodeScalarView($0.transcription.unicodeScalars.prefix(160))) }
        reportType = record.reportType.map { String(String.UnicodeScalarView($0.transcription.unicodeScalars.prefix(128))) }
        organization = record.organization.map { String(String.UnicodeScalarView($0.transcription.unicodeScalars.prefix(128))) }
        conclusion = record.conclusion.map { String(String.UnicodeScalarView($0.transcription.unicodeScalars.prefix(512))) }
        matchedResultLines = []; matchedResultLineCount = 0; matchedExcerpt = nil
    }

    package init(id: UUID, memberID: UUID, revision: UInt64, timelineDate: Date?, dateKind: ReportDateKind?,
                 title: String?, reportType: String?, organization: String?, conclusion: String?,
                 matchedResultLines: [ReportedResultLine] = [], matchedExcerpt: SearchExcerpt? = nil) {
        self.id = id; self.memberID = memberID; self.revision = revision; self.timelineDate = timelineDate
        self.dateKind = dateKind; self.title = title; self.reportType = reportType
        self.organization = organization; self.conclusion = conclusion
        self.matchedResultLines = matchedResultLines.prefix(Self.maximumMatchedResultLines)
            .map { $0.bounded(toScalars: Self.maximumResultCellScalars) }
        matchedResultLineCount = matchedResultLines.count
        self.matchedExcerpt = matchedExcerpt?.bounded(toScalars: Self.maximumExcerptScalars)
    }

    /// This summary showing where a search term was found, bounded for a list row.
    package func listing(_ match: LibraryReportSearchMatch) -> Self {
        Self(id: id, memberID: memberID, revision: revision, timelineDate: timelineDate, dateKind: dateKind,
             title: title, reportType: reportType, organization: organization, conclusion: conclusion,
             matchedResultLines: match.resultLines, matchedExcerpt: match.excerpt)
    }

    /// The text a row already shows for this report: its heading and organization, each possibly
    /// cut short of the field it comes from.
    package var visibleSearchText: [String] {
        [title ?? reportType, organization].compactMap { $0 }
    }
}

/// What a listed report shows of a search match: the table lines of its results the term was
/// found in or, when there are none, an excerpt of a field the row does not already show.
package struct LibraryReportSearchMatch: Equatable, Sendable {
    package let resultLines: [ReportedResultLine]
    package let excerpt: SearchExcerpt?

    package static let none = Self(resultLines: [], excerpt: nil)

    package init(resultLines: [ReportedResultLine], excerpt: SearchExcerpt?) {
        self.resultLines = resultLines
        self.excerpt = resultLines.isEmpty ? excerpt : nil
    }

    package var isEmpty: Bool { resultLines.isEmpty && excerpt == nil }

    /// The excerpt from the first of `fields` the term is found in, skipping a field whose match
    /// the row already shows. `fields` are a report's search fields in their stored order and
    /// `visible` the text the row shows of them; a visible text may be the start of a longer field,
    /// so the field is skipped only when the term is found in that start.
    package static func excerpt(term: String, fields: [String], hiding visible: [String],
                                locale: Locale = .current) -> SearchExcerpt? {
        for field in fields {
            let shown = visible.contains { text in
                field.unicodeScalars.starts(with: text.unicodeScalars)
                    && RecordQuery.localizedContains(term, in: text, locale: locale)
            }
            if !shown, let excerpt = SearchExcerpt(term: term, in: field, locale: locale) { return excerpt }
        }
        return nil
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
    /// The first source's file name, bounded for a list row; nil when the source has none.
    package let displayName: String?
    package init(id: UUID, state: ImportState, revision: UInt64, memberID: UUID?, failureCode: ImportFailureCode?, sourceCount: Int, displayName: String? = nil) {
        self.id = id; self.state = state; self.revision = revision; self.memberID = memberID
        self.failureCode = failureCode; self.sourceCount = sourceCount
        self.displayName = displayName.map(LibraryMemberSummary.preview)
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
