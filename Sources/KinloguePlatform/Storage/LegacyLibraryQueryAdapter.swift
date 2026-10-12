import Foundation
import KinlogueCore

/// Temporary JSON bridge while the production composition awaits the unified SQLite cutover.
package actor LegacyLibraryQueryAdapter: LibraryReportStoring, LibraryDICOMStoring {
    private let vault: any VaultStore
    private let drafts: any ImportDraftStore
    private let epoch = UUID()
    package init(vault: any VaultStore, drafts: any ImportDraftStore) { self.vault = vault; self.drafts = drafts }
    package func initializeLibrary() async throws -> LibraryHeader {
        let catalog: VaultCatalog
        do { catalog = try await vault.loadValidatedCatalog() }
        catch VaultError.vaultMissing { catalog = try await vault.initialize() }
        return try header(catalog)
    }
    private func revision(_ catalog: VaultCatalog) -> LibraryRevision {
        let bytes = ContentDigest.sha256(Data("\(catalog.vaultID):\(catalog.generation)".utf8)).prefix(16)
        return LibraryRevision(libraryID: catalog.vaultID, openEpoch: epoch, generation: catalog.generation,
            commitID: UUID(sqliteBytes: Data(bytes))!)
    }
    package func header() async throws -> LibraryHeader {
        try header(await vault.loadCatalog())
    }
    private func header(_ catalog: VaultCatalog) throws -> LibraryHeader {
        return LibraryHeader(revision: revision(catalog), members: catalog.members.map(LibraryMemberSummary.init),
            studies: try catalog.dicomStudies.map { try Self.summary($0, generation: catalog.generation) }, reportCount: catalog.records.count { $0.importState == .confirmed }, draftCount: catalog.importDrafts.count)
    }
    package func member(_ id: UUID) async throws -> FamilyMember {
        guard let value = try await vault.loadCatalog().members.first(where: { $0.id == id }) else { throw LibraryReportError.memberNotFound }
        return value
    }
    package func saveMember(_ member: FamilyMember, replacing expected: FamilyMember?) async throws {
        try await mutate { catalog in
            var members = catalog.members
            if let expected {
                guard let index = members.firstIndex(where: { $0.id == member.id }), members[index] == expected else { throw LibraryReportError.staleRevision }
                members[index] = member
            } else {
                guard !members.contains(where: { $0.id == member.id }) else { throw LibraryReportError.staleRevision }
                members.append(member)
            }
            return try Self.next(catalog, members: members)
        }
    }
    package func deleteMember(_ id: UUID) async throws { try await mutate { try $0.deletingMember(id: id) } }
    package func draft(_ id: UUID) async throws -> ImportDraft {
        guard let draft = try await vault.loadCatalog().importDrafts.first(where: { $0.id == id }) else { throw LibraryReportError.draftNotFound }
        return draft
    }
    package func record(_ id: UUID) async throws -> HealthRecord {
        guard let record = try await vault.loadCatalog().records.first(where: { $0.id == id && $0.importState == .confirmed }) else { throw LibraryReportError.recordNotFound }
        return record
    }
    package func draftDisposition(_ id: UUID) async throws -> LibraryDraftDisposition {
        let catalog = try await vault.loadCatalog()
        return LibraryDraftDisposition(draft: catalog.importDrafts.first { $0.id == id },
            record: catalog.records.first { $0.id == id })
    }
    package func recordSelection(_ ids: [UUID]) async throws -> LibraryRecordSelection {
        guard ids.count <= 2, Set(ids).count == ids.count else { throw LibraryReportError.resourceLimit }
        let catalog = try await vault.loadCatalog()
        return LibraryRecordSelection(revision: revision(catalog), records: try ids.map { id in
            guard let record = catalog.records.first(where: { $0.id == id && $0.importState == .confirmed }) else { throw LibraryReportError.recordNotFound }
            return record
        })
    }
    package func reportPage(query: String, memberID: UUID?, limit: Int, cursor: LibraryQueryCursor?) async throws -> LibraryReportPage {
        let catalog = try await vault.loadCatalog(), revision = revision(catalog)
        let scope = "reports:" + query.trimmingCharacters(in: .whitespacesAndNewlines)
        try validate(cursor, revision: revision, scope: scope, memberID: memberID)
        let records = RecordQuery.search(query, records: catalog.records, members: catalog.members, memberID: memberID)
            .filter { follows(.report(LibraryReportSummary(record: $0)), cursor: cursor) }
        let items = records.prefix(limit).map(LibraryReportSummary.init(record:))
        return LibraryReportPage(revision: revision, items: items, nextCursor: records.count > limit ? items.last.map { self.cursor(.report($0), revision: revision, scope: scope, memberID: memberID) } : nil)
    }
    package func timelinePage(memberID: UUID?, limit: Int, cursor: LibraryQueryCursor?) async throws -> LibraryTimelinePage {
        let catalog = try await vault.loadCatalog(), revision = revision(catalog)
        try validate(cursor, revision: revision, scope: "timeline", memberID: memberID)
        let reports = catalog.records.filter { $0.importState == .confirmed && (memberID == nil || $0.memberID == memberID) }.map { LibraryTimelineItem.report(LibraryReportSummary(record: $0)) }
        let studies = try catalog.dicomStudies.filter { $0.state == .confirmed && (memberID == nil || $0.confirmedMemberID == memberID) }.map { LibraryTimelineItem.study(try Self.summary($0, generation: catalog.generation)) }
        let ordered = (reports + studies).sorted(by: Self.precedes).filter { follows($0, cursor: cursor) }
        let items = Array(ordered.prefix(limit))
        return LibraryTimelinePage(revision: revision, items: items, nextCursor: ordered.count > limit ? items.last.map { self.cursor($0, revision: revision, scope: "timeline", memberID: memberID) } : nil, damagedIDs: [])
    }
    package func draftPage(states: [ImportState], limit: Int, cursor: LibraryQueryCursor?) async throws -> LibraryDraftPage {
        let catalog = try await vault.loadCatalog(), revision = revision(catalog)
        let scope = "drafts:" + Set(states.map(\.rawValue)).sorted().joined(separator: ",")
        try validate(cursor, revision: revision, scope: scope, memberID: nil)
        let drafts = catalog.importDrafts.filter { states.contains($0.state) && (cursor == nil || $0.id.uuidString > cursor!.lastID.uuidString) }.sorted { $0.id.uuidString < $1.id.uuidString }
        let items = drafts.prefix(limit).map { LibraryDraftSummary(id: $0.id, state: $0.state, revision: $0.revision, memberID: $0.memberID, failureCode: $0.failureCode, sourceCount: $0.sources.count) }
        return LibraryDraftPage(revision: revision, items: items, nextCursor: drafts.count > limit ? items.last.map { LibraryQueryCursor(libraryID: revision.libraryID, commitID: revision.commitID, openEpoch: epoch, scope: scope, memberID: nil, lastID: $0.id, lastDate: nil) } : nil)
    }
    package func reviewContent(draftID: UUID) async throws -> LibraryReviewSnapshot {
        let value = try await drafts.loadReviewSnapshot(draftID: draftID)
        return LibraryReviewSnapshot(revision: try await header().revision, draft: value.draft, document: value.document,
            members: value.members.map(LibraryMemberSummary.init), attachment: value.attachment, originalData: value.originalData)
    }
    package func original(recordID: UUID, expectedRevision: UInt64, sourceID: UUID, expectedLibrary: LibraryRevision) async throws -> (Attachment, Data) {
        try await original(id: recordID, revision: expectedRevision, sourceID: sourceID, report: true, expectedLibrary: expectedLibrary)
    }
    package func original(draftID: UUID, expectedRevision: UInt64, sourceID: UUID, expectedLibrary: LibraryRevision) async throws -> (Attachment, Data) {
        try await original(id: draftID, revision: expectedRevision, sourceID: sourceID, report: false, expectedLibrary: expectedLibrary)
    }
    private func original(id: UUID, revision: UInt64, sourceID: UUID, report: Bool, expectedLibrary: LibraryRevision) async throws -> (Attachment, Data) {
        let epoch = self.epoch
        let snapshot = try await vault.readSnapshot { catalog in
            guard catalog.vaultID == expectedLibrary.libraryID, epoch == expectedLibrary.openEpoch else { throw LibraryReportError.staleRevision }
            let sources: ReportSources
            if report {
                guard let value = catalog.records.first(where: { $0.id == id && $0.importState == .confirmed }) else { throw LibraryReportError.recordNotFound }
                guard value.revision == revision else { throw LibraryReportError.staleRevision }
                sources = value.sources
            } else {
                guard let value = catalog.importDrafts.first(where: { $0.id == id }) else { throw LibraryReportError.draftNotFound }
                guard value.revision == revision else { throw LibraryReportError.staleRevision }
                sources = value.sources
            }
            guard let source = sources.elements.first(where: { $0.id == sourceID }) else { throw LibraryReportError.invalidDocument }
            return [VaultObjectReference(id: source.attachmentID, kind: .attachment)]
        }
        guard let reference = snapshot.objects.keys.first,
              let attachment = snapshot.catalog.attachments.first(where: { $0.id == reference.id }) else { throw LibraryReportError.invalidDocument }
        return (attachment, try snapshot.data(for: reference))
    }
    package func updateRecord(_ record: HealthRecord, expectedRevision: UInt64) async throws {
        try await mutate { catalog in
            guard let index = catalog.records.firstIndex(where: { $0.id == record.id }) else { throw LibraryReportError.recordNotFound }
            guard catalog.records[index].revision == expectedRevision else { throw LibraryReportError.staleRevision }
            var records = catalog.records; records[index] = record
            return try Self.next(catalog, records: records)
        }
    }
    package func deleteRecord(_ id: UUID, expectedRevision: UInt64) async throws {
        try await mutate { catalog in
            guard catalog.records.first(where: { $0.id == id })?.revision == expectedRevision else { throw LibraryReportError.staleRevision }
            return try catalog.deletingRecord(id: id)
        }
    }
    package func details(_ id: UUID) async throws -> LibraryDICOMStudyDetails {
        let snapshot = try await vault.readSnapshot { catalog in
            guard let study = catalog.dicomStudies.first(where: { $0.id == id }) else { throw DICOMSliceServiceError.studyUnavailable }
            return [VaultObjectReference(id: study.indexObjectID, kind: .record)]
        }
        guard let study = snapshot.catalog.dicomStudies.first(where: { $0.id == id }) else { throw DICOMSliceServiceError.studyUnavailable }
        let index = try CanonicalVaultJSON.decode(DICOMStudyIndex.self, from: snapshot.data(for: VaultObjectReference(id: study.indexObjectID, kind: .record)))
        let instances = Dictionary(uniqueKeysWithValues: index.instances.map { ($0.id, $0) })
        let series = try index.series.sorted { $0.ordinal < $1.ordinal }.map { value in
            guard let id = value.instanceIDs.first, let first = instances[id] else { throw DICOMSliceServiceError.integrityFailure }
            return LibraryDICOMSeriesSummary(id: value.id, ordinal: value.ordinal, sliceCount: value.instanceIDs.count, rows: first.attributes.rows, columns: first.attributes.columns, orderingProvenance: value.orderingProvenance)
        }
        let base = try Self.summary(study, generation: snapshot.catalog.generation)
        return LibraryDICOMStudyDetails(study: LibraryDICOMStudySummary(id: base.id, state: base.state, confirmedMemberID: base.confirmedMemberID, effectiveDate: base.effectiveDate, contentRevision: base.contentRevision, retainedObjectCount: base.retainedObjectCount, viewableInstanceCount: index.instances.count, seriesCount: series.count), series: series)
    }
    package func confirm(_ id: UUID, expectedRevision: UInt64, memberID: UUID, effectiveDate: Date) async throws -> LibraryDICOMStudySummary {
        try await mutate { catalog in
            guard let index = catalog.dicomStudies.firstIndex(where: { $0.id == id }),
                  try Self.summary(catalog.dicomStudies[index], generation: catalog.generation).contentRevision == expectedRevision else { throw DICOMImportError.publicationConflict }
            var studies = catalog.dicomStudies
            studies[index] = try studies[index].reassigning(memberID: memberID, effectiveDate: effectiveDate)
            return try Self.next(catalog, studies: studies)
        }
        return try await details(id).study
    }
    package func delete(_ id: UUID, expectedRevision: UInt64) async throws {
        try await mutate(removedStudies: [id]) { catalog in
            guard let study = catalog.dicomStudies.first(where: { $0.id == id }), try Self.summary(study, generation: catalog.generation).contentRevision == expectedRevision else { throw DICOMImportError.publicationConflict }
            return try catalog.deletingDICOMStudy(id: id)
        }
    }
    private func mutate(removedStudies: Set<UUID> = [], _ transform: (VaultCatalog) throws -> VaultCatalog) async throws {
        let current = try await vault.loadCatalog(), next = try transform(current)
        do { _ = try await vault.commit(try VaultCommitRequest(expectedGeneration: current.generation, catalog: next, writes: [], removedDICOMStudyIDs: removedStudies)) }
        catch { guard try await vault.loadCatalog() == next else { throw error } }
    }
    private static func next(_ catalog: VaultCatalog, members: [FamilyMember]? = nil, records: [HealthRecord]? = nil, studies: [DICOMStudy]? = nil) throws -> VaultCatalog {
        try VaultCatalog(vaultID: catalog.vaultID, generation: VaultGeneration.successor(of: catalog.generation), members: members ?? catalog.members,
            records: records ?? catalog.records, attachments: catalog.attachments, importDrafts: catalog.importDrafts, dicomStudies: studies ?? catalog.dicomStudies)
    }
    // The old renderer binds a whole-catalog ticket. Removed with this adapter at U10.
    private static func summary(_ study: DICOMStudy, generation: UInt64) throws -> LibraryDICOMStudySummary {
        LibraryDICOMStudySummary(id: study.id, state: study.state, confirmedMemberID: study.confirmedMemberID, effectiveDate: study.effectiveDate,
            contentRevision: generation, retainedObjectCount: study.attachmentIDs.count, viewableInstanceCount: 0, seriesCount: 0)
    }
    private func validate(_ cursor: LibraryQueryCursor?, revision: LibraryRevision, scope: String, memberID: UUID?) throws {
        guard let cursor else { return }
        guard cursor.libraryID == revision.libraryID, cursor.openEpoch == epoch, cursor.commitID == revision.commitID, cursor.scope == scope, cursor.memberID == memberID else { throw LibraryReportError.staleCursor }
    }
    private func cursor(_ item: LibraryTimelineItem, revision: LibraryRevision, scope: String, memberID: UUID?) -> LibraryQueryCursor {
        LibraryQueryCursor(libraryID: revision.libraryID, commitID: revision.commitID, openEpoch: epoch, scope: scope, memberID: memberID, lastID: item.id, lastDate: item.date, lastKind: item.kind)
    }
    private func follows(_ item: LibraryTimelineItem, cursor: LibraryQueryCursor?) -> Bool {
        guard let cursor else { return true }
        if let date = cursor.lastDate { if item.date == nil { return true }; if item.date != date { return item.date! < date } }
        else if item.date != nil { return false }
        return item.kind > cursor.lastKind || (item.kind == cursor.lastKind && item.id.uuidString > cursor.lastID.uuidString)
    }
    private static func precedes(_ a: LibraryTimelineItem, _ b: LibraryTimelineItem) -> Bool {
        if let x = a.date, let y = b.date, x != y { return x > y }
        if a.date != nil && b.date == nil { return true }; if a.date == nil && b.date != nil { return false }
        return a.kind != b.kind ? a.kind < b.kind : a.id.uuidString < b.id.uuidString
    }
}
