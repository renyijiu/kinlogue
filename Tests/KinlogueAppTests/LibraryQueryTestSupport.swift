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
        // A real commit always changes the commit ID, so fixtures with different content must
        // not share one: the model skips a reload when the revision it already shows comes back.
        var hasher = Hasher()
        hasher.combine(members.map { "\($0)" }); hasher.combine(records.map { "\($0)" })
        hasher.combine(drafts.map { "\($0)" }); hasher.combine(dicomStudies.map { "\($0)" })
        let content = UInt64(bitPattern: Int64(hasher.finalize()))
        return LibraryRevision(libraryID: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
                        openEpoch: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
                        generation: generation,
                        commitID: UUID(uuidString: String(format: "10000000-0000-0000-%04llx-%012llx",
                            generation & 0xFFFF, content & 0xFFFF_FFFF_FFFF))!)
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

/// A report store that forwards to a real one and lets a test act around individual calls:
/// pause one, count them, or fail one before or after it reached the library.
final class InterceptedReportStore: LibraryReportStoring {
    enum Call: Sendable, Equatable {
        case initializeLibrary, header, member, saveMember, deleteMember, draft, record, draftDisposition
        case recordSelection, reportPage, timelinePage, draftPage, reviewContent
        case recordOriginal, draftOriginal, updateRecord, deleteRecord
    }
    typealias Hook = @Sendable (Call) async throws -> Void

    private let base: any LibraryReportStoring
    private let before: Hook
    private let after: Hook

    init(_ base: any LibraryReportStoring, before: @escaping Hook = { _ in }, after: @escaping Hook = { _ in }) {
        self.base = base
        self.before = before
        self.after = after
    }

    private func call<Value: Sendable>(_ call: Call, _ body: () async throws -> Value) async throws -> Value {
        try await before(call)
        let value = try await body()
        try await after(call)
        return value
    }

    func initializeLibrary() async throws -> LibraryHeader { try await call(.initializeLibrary) { try await base.initializeLibrary() } }
    func header() async throws -> LibraryHeader { try await call(.header) { try await base.header() } }
    func member(_ id: UUID) async throws -> FamilyMember { try await call(.member) { try await base.member(id) } }
    func saveMember(_ member: FamilyMember, replacing expected: FamilyMember?) async throws {
        try await call(.saveMember) { try await base.saveMember(member, replacing: expected) }
    }
    func deleteMember(_ id: UUID) async throws { try await call(.deleteMember) { try await base.deleteMember(id) } }
    func draft(_ id: UUID) async throws -> ImportDraft { try await call(.draft) { try await base.draft(id) } }
    func record(_ id: UUID) async throws -> HealthRecord { try await call(.record) { try await base.record(id) } }
    func draftDisposition(_ id: UUID) async throws -> LibraryDraftDisposition {
        try await call(.draftDisposition) { try await base.draftDisposition(id) }
    }
    func recordSelection(_ ids: [UUID]) async throws -> LibraryRecordSelection {
        try await call(.recordSelection) { try await base.recordSelection(ids) }
    }
    func reportPage(query: String, memberID: UUID?, limit: Int, cursor: LibraryQueryCursor?) async throws -> LibraryReportPage {
        try await call(.reportPage) { try await base.reportPage(query: query, memberID: memberID, limit: limit, cursor: cursor) }
    }
    func timelinePage(memberID: UUID?, limit: Int, cursor: LibraryQueryCursor?) async throws -> LibraryTimelinePage {
        try await call(.timelinePage) { try await base.timelinePage(memberID: memberID, limit: limit, cursor: cursor) }
    }
    func draftPage(states: [ImportState], limit: Int, cursor: LibraryQueryCursor?) async throws -> LibraryDraftPage {
        try await call(.draftPage) { try await base.draftPage(states: states, limit: limit, cursor: cursor) }
    }
    func reviewContent(draftID: UUID) async throws -> LibraryReviewSnapshot {
        try await call(.reviewContent) { try await base.reviewContent(draftID: draftID) }
    }
    func original(recordID: UUID, expectedRevision: UInt64, sourceID: UUID, expectedLibrary: LibraryRevision) async throws -> (Attachment, Data) {
        try await before(.recordOriginal)
        let value = try await base.original(recordID: recordID, expectedRevision: expectedRevision, sourceID: sourceID, expectedLibrary: expectedLibrary)
        try await after(.recordOriginal)
        return value
    }
    func original(draftID: UUID, expectedRevision: UInt64, sourceID: UUID, expectedLibrary: LibraryRevision) async throws -> (Attachment, Data) {
        try await before(.draftOriginal)
        let value = try await base.original(draftID: draftID, expectedRevision: expectedRevision, sourceID: sourceID, expectedLibrary: expectedLibrary)
        try await after(.draftOriginal)
        return value
    }
    func updateRecord(_ record: HealthRecord, expectedRevision: UInt64) async throws {
        try await call(.updateRecord) { try await base.updateRecord(record, expectedRevision: expectedRevision) }
    }
    func deleteRecord(_ id: UUID, expectedRevision: UInt64) async throws {
        try await call(.deleteRecord) { try await base.deleteRecord(id, expectedRevision: expectedRevision) }
    }
}

/// The imaging counterpart of `InterceptedReportStore`.
final class InterceptedDICOMStore: LibraryDICOMStoring {
    enum Call: Sendable, Equatable { case details, confirm, delete }
    typealias Hook = @Sendable (Call) async throws -> Void

    private let base: any LibraryDICOMStoring
    private let before: Hook
    private let after: Hook

    init(_ base: any LibraryDICOMStoring, before: @escaping Hook = { _ in }, after: @escaping Hook = { _ in }) {
        self.base = base
        self.before = before
        self.after = after
    }

    func details(_ id: UUID) async throws -> LibraryDICOMStudyDetails {
        try await before(.details)
        let value = try await base.details(id)
        try await after(.details)
        return value
    }
    func confirm(_ id: UUID, expectedRevision: UInt64, memberID: UUID, effectiveDate: Date) async throws -> LibraryDICOMStudySummary {
        try await before(.confirm)
        let value = try await base.confirm(id, expectedRevision: expectedRevision, memberID: memberID, effectiveDate: effectiveDate)
        try await after(.confirm)
        return value
    }
    func delete(_ id: UUID, expectedRevision: UInt64) async throws {
        try await before(.delete)
        try await base.delete(id, expectedRevision: expectedRevision)
        try await after(.delete)
    }
}

/// A draft store that forwards to a real one, with a hook around each call. The hook receives
/// the draft a call is about, so a test can pause or fail one transition of one draft.
final class InterceptedDraftStore: ImportDraftStore {
    enum Call: Sendable, Equatable {
        case stage, resumableDraftIDs
        case beginProcessing(UUID), loadSource(UUID), completeProcessing(UUID), failProcessing(UUID)
        case loadDocument(UUID), loadReviewSnapshot(UUID), saveReview(UUID), confirm(UUID), discard(UUID)

        /// The call without the draft it is about.
        var name: String { String(String(describing: self).prefix { $0 != "(" }) }
    }
    typealias Hook = @Sendable (Call) async throws -> Void

    private let base: any ImportDraftStore
    private let before: Hook
    private let after: Hook

    init(_ base: any ImportDraftStore, before: @escaping Hook = { _ in }, after: @escaping Hook = { _ in }) {
        self.base = base
        self.before = before
        self.after = after
    }

    private func call<Value: Sendable>(_ call: Call, _ body: () async throws -> Value) async throws -> Value {
        try await before(call)
        let value = try await body()
        try await after(call)
        return value
    }

    func stage(_ file: ValidatedImportedFile) async throws -> ImportStageOutcome {
        try await call(.stage) { try await base.stage(file) }
    }
    func beginProcessing(draftID: ImportDraft.ID, attemptID: UUID) async throws -> ImportProcessingLease {
        try await call(.beginProcessing(draftID)) { try await base.beginProcessing(draftID: draftID, attemptID: attemptID) }
    }
    func loadSource(draftID: ImportDraft.ID) async throws -> ValidatedImportedFile {
        try await call(.loadSource(draftID)) { try await base.loadSource(draftID: draftID) }
    }
    func completeProcessing(lease: ImportProcessingLease, document: ImportDraftDocument) async throws {
        try await call(.completeProcessing(lease.draftID)) { try await base.completeProcessing(lease: lease, document: document) }
    }
    func failProcessing(lease: ImportProcessingLease, failureCode: ImportFailureCode) async throws {
        try await call(.failProcessing(lease.draftID)) { try await base.failProcessing(lease: lease, failureCode: failureCode) }
    }
    func resumableDraftIDs() async throws -> [ImportDraft.ID] {
        try await call(.resumableDraftIDs) { try await base.resumableDraftIDs() }
    }
    func loadDocument(draftID: ImportDraft.ID) async throws -> ImportDraftDocument {
        try await call(.loadDocument(draftID)) { try await base.loadDocument(draftID: draftID) }
    }
    func loadReviewSnapshot(draftID: ImportDraft.ID) async throws -> ImportDraftReviewSnapshot {
        try await call(.loadReviewSnapshot(draftID)) { try await base.loadReviewSnapshot(draftID: draftID) }
    }
    func saveReview(draftID: ImportDraft.ID, expectedRevision: UInt64, memberID: FamilyMember.ID?, document: ImportDraftDocument) async throws {
        try await call(.saveReview(draftID)) {
            try await base.saveReview(draftID: draftID, expectedRevision: expectedRevision, memberID: memberID, document: document)
        }
    }
    func confirm(draftID: ImportDraft.ID, expectedRevision: UInt64, record: HealthRecord) async throws {
        try await call(.confirm(draftID)) { try await base.confirm(draftID: draftID, expectedRevision: expectedRevision, record: record) }
    }
    func discard(draftID: ImportDraft.ID, expectedRevision: UInt64) async throws {
        try await call(.discard(draftID)) { try await base.discard(draftID: draftID, expectedRevision: expectedRevision) }
    }
}

/// The storage calls a service made, in order.
actor StorageCallLog {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
    func count(_ value: String) -> Int { values.filter { $0 == value }.count }
}
