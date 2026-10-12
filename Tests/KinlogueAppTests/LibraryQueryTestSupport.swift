import Foundation
@testable import KinlogueApp
@testable import KinlogueCore

/// Complete synthetic state owned by a test service. AppSnapshot carries only its bounded header.
struct TestLibrarySnapshot: Sendable {
    var generation: UInt64 = 0
    var members: [FamilyMember] = []
    var records: [HealthRecord] = []
    var drafts: [DraftSummary] = []
    var dicomStudies: [DICOMStudySummary] = []
    static let empty = Self()
    var revision: LibraryRevision {
        LibraryRevision(libraryID: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
                        openEpoch: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
                        generation: generation,
                        commitID: UUID(uuidString: String(format: "10000000-0000-0000-0000-%012llu", generation))!)
    }
    var header: AppSnapshot {
        AppSnapshot(header: LibraryHeader(revision: revision, members: members.map(LibraryMemberSummary.init),
            studies: dicomStudies.map(\.librarySummary), reportCount: records.filter { $0.importState == .confirmed }.count,
            draftCount: drafts.count, damagedMemberIDs: [], damagedStudyIDs: []))
    }
}

extension DICOMStudySummary {
    var librarySummary: LibraryDICOMStudySummary {
        LibraryDICOMStudySummary(id: id, state: state, confirmedMemberID: confirmedMemberID, effectiveDate: effectiveDate,
            contentRevision: contentRevision, retainedObjectCount: retainedObjectCount, viewableInstanceCount: 0, seriesCount: 0)
    }
}

protocol TestLibraryServing: AppDataServicing {
    func queryFixture() async -> TestLibrarySnapshot
    func beforePage(query: String?, memberID: UUID?, cursor: LibraryQueryCursor?) async throws
}

extension TestLibraryServing {
    func beforePage(query: String?, memberID: UUID?, cursor: LibraryQueryCursor?) async throws {}
    func timelinePage(memberID: UUID?, cursor: LibraryQueryCursor?) async throws -> LibraryTimelinePage {
        let fixture = await queryFixture()
        try await beforePage(query: nil, memberID: memberID, cursor: cursor)
        let reports = RecordQuery.search("", records: fixture.records, members: fixture.members, memberID: memberID)
            .map { LibraryTimelineItem.report(LibraryReportSummary(record: $0)) }
        let studies = fixture.dicomStudies.filter {
            $0.state == .confirmed && (memberID == nil || $0.confirmedMemberID == memberID)
        }.map { LibraryTimelineItem.study($0.librarySummary) }
        let items = (reports + studies).sorted {
            switch ($0.date, $1.date) {
            case let (left?, right?) where left != right: return left > right
            case (_?, nil): return true
            case (nil, _?): return false
            default: return $0.kind == $1.kind ? $0.id.uuidString < $1.id.uuidString : $0.kind < $1.kind
            }
        }
        let start = cursor.flatMap { cursor in items.firstIndex { $0.id == cursor.lastID && $0.kind == cursor.lastKind } }.map { $0 + 1 } ?? 0
        let page = Array(items.dropFirst(start).prefix(100))
        let next = start + page.count < items.count ? page.last.map {
            LibraryQueryCursor(libraryID: fixture.revision.libraryID, commitID: fixture.revision.commitID,
                openEpoch: fixture.revision.openEpoch, scope: "timeline", memberID: memberID,
                lastID: $0.id, lastDate: $0.date, lastKind: $0.kind)
        } : nil
        return LibraryTimelinePage(revision: fixture.revision, items: page, nextCursor: next, damagedIDs: [])
    }
    func reportPage(query: String, memberID: UUID?, cursor: LibraryQueryCursor?) async throws -> LibraryReportPage {
        let fixture = await queryFixture()
        try await beforePage(query: query, memberID: memberID, cursor: cursor)
        let records = RecordQuery.search(query, records: fixture.records, members: fixture.members, memberID: memberID)
        let start = cursor.flatMap { cursor in records.firstIndex { $0.id == cursor.lastID } }.map { $0 + 1 } ?? 0
        let page = Array(records.dropFirst(start).prefix(100))
        let next = start + page.count < records.count ? page.last.map {
            LibraryQueryCursor(libraryID: fixture.revision.libraryID, commitID: fixture.revision.commitID,
                openEpoch: fixture.revision.openEpoch, scope: query, memberID: memberID, lastID: $0.id, lastDate: $0.timelineDate)
        } : nil
        return LibraryReportPage(revision: fixture.revision, items: page.map(LibraryReportSummary.init), nextCursor: next)
    }
    func draftPage(states: [ImportState], cursor: LibraryQueryCursor?) async throws -> AppDraftPage {
        let fixture = await queryFixture()
        return AppDraftPage(revision: fixture.revision, items: Array(fixture.drafts.filter { states.contains($0.state) }.prefix(100)),
                            nextCursor: nil, damagedIDs: [])
    }
    func loadRecords(ids: [UUID]) async throws -> LibraryRecordSelection {
        let fixture = await queryFixture()
        let records = try ids.map { id in
            guard let record = fixture.records.first(where: { $0.id == id && $0.importState == .confirmed }) else {
                throw AppServiceError.recordUnavailable
            }
            return record
        }
        return LibraryRecordSelection(revision: fixture.revision, records: records)
    }
    func loadMember(id: UUID) async throws -> FamilyMember {
        guard let member = await queryFixture().members.first(where: { $0.id == id }) else { throw AppServiceError.memberUnavailable }
        return member
    }
    func loadDraft(id: UUID) async throws -> ImportDraft {
        let fixture = await queryFixture()
        guard let value = fixture.drafts.first(where: { $0.id == id }) else { throw AppServiceError.draftUnavailable }
        return ImportDraft(id: value.id, attachmentID: UUID(), state: value.state, revision: value.revision)
    }
}

func testReviewContent(draft: ImportDraft, document: ImportDraftDocument, members: [FamilyMember], original: OriginalDocumentPayload) -> ImportReviewContent {
    ImportReviewContent(revision: TestLibrarySnapshot.empty.revision, draft: draft, document: document,
                        members: members.map(LibraryMemberSummary.init), original: original)
}

extension LiveAppService {
    func loadTestOriginal(recordID: UUID, sourceID: UUID) async throws -> OriginalDocumentPayload {
        let selection = try await loadRecords(ids: [recordID])
        guard let record = selection.records.first else { throw AppServiceError.recordUnavailable }
        return try await loadOriginal(recordID: recordID, sourceID: sourceID,
                                      expectedRevision: record.revision, expectedLibrary: selection.revision)
    }
}
