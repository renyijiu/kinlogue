import Combine
import Foundation
import Testing
@testable import KinlogueApp
@testable import KinlogueCore

@Suite(.serialized)
@MainActor
struct LibraryQueryAppModelTests {
    @Test
    func lateSearchAndMemberPagesCannotReplaceTheCurrentFilter() async throws {
        let first = try FamilyMember(displayName: "First synthetic member")
        let second = try FamilyMember(displayName: "Second synthetic member")
        let old = try HealthRecord(memberID: first.id, attachmentID: UUID(), importState: .confirmed, title: SourceField.manualEntry("old"))
        let current = try HealthRecord(memberID: second.id, attachmentID: UUID(), importState: .confirmed, title: SourceField.manualEntry("new"))
        let service = AppServiceSpy(snapshot: TestLibrarySnapshot(members: [first, second], records: [old, current]))
        let model = AppModel(service: service)
        await model.start()
        let searchGate = OriginalLoadGate()
        await service.gatePage(searchGate, query: "old")
        model.searchText = "old"
        await searchGate.waitUntilLoadStarts()
        #expect(model.pageState == .loading && model.searchResults.isEmpty)
        model.searchText = "new"
        await model.waitForCurrentPage()
        await searchGate.open()
        for _ in 0..<30 { await Task.yield() }
        #expect(model.searchResults.map(\.id) == [current.id])
        model.searchText = ""
        await model.waitForCurrentPage()
        let memberGate = OriginalLoadGate()
        await service.gatePage(memberGate, member: first.id)
        model.selectedMemberID = first.id
        await memberGate.waitUntilLoadStarts()
        #expect(model.timelineSections.isEmpty)
        model.selectedMemberID = second.id
        await model.waitForCurrentPage()
        await memberGate.open()
        for _ in 0..<30 { await Task.yield() }
        #expect(model.timelineSections.flatMap(\.records).map(\.id) == [current.id])
        await model.beginDestructiveVaultLifecycle()
    }

    @Test
    func failedNextPageRetainsRowsAndRetriesTheSameCursor() async throws {
        let records = try (0..<103).map { _ in try HealthRecord(memberID: UUID(), attachmentID: UUID(), importState: .confirmed) }
        let service = AppServiceSpy(snapshot: TestLibrarySnapshot(records: records))
        let model = AppModel(service: service)
        await model.start()
        let initial = model.timelineSections.flatMap(\.records).map(\.id)
        #expect(initial.count == 100)
        await service.failNextPage()
        await model.loadNextRecordsPage()
        #expect(model.pageState == .failed && model.hasMoreRecords)
        #expect(model.timelineSections.flatMap(\.records).map(\.id) == initial)
        await model.retryRecordsPage()
        #expect(model.pageState == .loaded && !model.hasMoreRecords)
        #expect(Set(model.timelineSections.flatMap(\.records).map(\.id)).count == 103)
    }

    @Test
    func refreshKeepsShownRowsAndLoadedDepthInsteadOfReturningToTheFirstPage() async throws {
        let member = try FamilyMember(displayName: "Synthetic member")
        let records = try (0..<230).map { _ in try HealthRecord(memberID: member.id, attachmentID: UUID(), importState: .confirmed) }
        let added = try HealthRecord(memberID: member.id, attachmentID: UUID(), importState: .confirmed)
        let drafts = (0..<3).map { _ in DraftSummary(draft: LibraryDraftSummary(id: UUID(), state: .needsReview,
            revision: 0, memberID: nil, failureCode: nil, sourceCount: 1)) }
        let service = AppServiceSpy(
            snapshot: TestLibrarySnapshot(generation: 1, members: [member], records: records, drafts: drafts),
            refreshedSnapshot: TestLibrarySnapshot(generation: 2, members: [member], records: records + [added], drafts: drafts))
        let model = AppModel(service: service)
        await model.start()
        model.selectedMemberID = member.id
        await model.waitForCurrentPage()
        await model.loadNextRecordsPage()
        let shown = model.timelineSections.flatMap(\.records).map(\.id)
        #expect(shown.count == 200 && model.hasMoreRecords)
        #expect(model.reviewQueue.count == 3)

        var queueWasEmptied = false
        let observation = model.$reviewQueue.dropFirst().sink { if $0.isEmpty { queueWasEmptied = true } }
        defer { observation.cancel() }
        let gate = OriginalLoadGate()
        await service.gatePage(gate, member: member.id)
        let refreshing = Task { await model.refresh() }
        await gate.waitUntilLoadStarts()
        // The reload is in flight: what was shown is still shown.
        #expect(model.timelineSections.flatMap(\.records).map(\.id) == shown)
        #expect(model.pageState == .loading)
        await gate.open()
        await refreshing.value

        #expect(model.currentLibraryRevision?.generation == 2)
        #expect(model.pageState == .loaded && model.hasMoreRecords)
        #expect(model.timelineSections.flatMap(\.records).count == 200)
        #expect(model.reviewQueue.count == 3 && !queueWasEmptied)
    }

    @Test
    func anUnchangedRevisionReloadsNoListButAChangedOneAndAPlainRefreshDo() async throws {
        let record = try HealthRecord(memberID: UUID(), attachmentID: UUID(), importState: .confirmed)
        let added = try HealthRecord(memberID: UUID(), attachmentID: UUID(), importState: .confirmed)
        let service = AppServiceSpy(
            snapshot: TestLibrarySnapshot(generation: 1, records: [record]),
            refreshedSnapshot: TestLibrarySnapshot(generation: 2, records: [record, added]))
        let model = AppModel(service: service)
        await model.start()
        let afterStart = await service.pageCalls

        // The first hint brings a new revision, so the list is read again.
        await model.refresh(skippingUnchanged: true)
        #expect(await service.pageCalls == afterStart + 1)
        #expect(Set(model.timelineSections.flatMap(\.records).map(\.id)) == [record.id, added.id])

        // The same revision again, as on activation or after the model's own mutation.
        await model.refresh(skippingUnchanged: true)
        #expect(await service.pageCalls == afterStart + 1)
        #expect(model.pageState == .loaded)

        // A plain refresh reloads regardless: retry eligibility can change without a commit.
        await model.refresh()
        #expect(await service.pageCalls == afterStart + 2)
    }

    @Test
    func aStaleCursorOnLoadMoreKeepsTheRowsAndEndsWithTheNextPage() async throws {
        let records = try (0..<230).map { _ in try HealthRecord(memberID: UUID(), attachmentID: UUID(), importState: .confirmed) }
        let service = AppServiceSpy(snapshot: TestLibrarySnapshot(records: records))
        let model = AppModel(service: service)
        await model.start()
        let firstPage = model.timelineSections.flatMap(\.records).map(\.id)
        #expect(firstPage.count == 100)

        await service.staleNextPage()
        await model.loadNextRecordsPage()

        let reloaded = model.timelineSections.flatMap(\.records).map(\.id)
        #expect(model.pageState == .loaded && model.hasMoreRecords)
        #expect(reloaded.count == 200 && Array(reloaded.prefix(100)) == firstPage)
    }

    @Test
    func destructiveLifecycleDrainsRecordEditReadAndRejectsItsLateResult() async throws {
        let record = try HealthRecord(memberID: UUID(), attachmentID: UUID(), importState: .confirmed)
        let gate = OriginalLoadGate()
        let service = AppServiceSpy(snapshot: TestLibrarySnapshot(records: [record]), recordLoadGate: gate)
        let model = AppModel(service: service)
        await model.start()
        let command = UpdateRecordCommand(recordID: record.id, expectedRevision: record.revision, memberID: record.memberID,
            timelineDateSelection: .unknown, title: "", organization: "", department: "", reportType: "",
            reportedResults: "", conclusion: "Synthetic correction", abnormalItems: [], userNote: "")
        let saving = Task { await model.updateRecord(command) }
        await gate.waitUntilLoadStarts()
        var drained = false
        let deleting = Task { await model.beginDestructiveVaultLifecycle(); drained = true }
        for _ in 0..<30 { await Task.yield() }
        #expect(!drained && model.selectedRecord == nil)
        await gate.open()
        #expect(await saving.value == .failed)
        await deleting.value
        #expect(drained && model.phase == .changingVault && model.selectedRecord == nil)
    }

    @Test
    func duplicateNextDraftPageRequestsConsumeOneCursorOnlyOnce() async throws {
        let drafts = (0..<103).map { _ in DraftSummary(draft: LibraryDraftSummary(id: UUID(), state: .needsReview,
            revision: 0, memberID: nil, failureCode: nil, sourceCount: 1), canRetryRecovery: false) }
        let gate = OriginalLoadGate()
        let service = AppServiceSpy(snapshot: TestLibrarySnapshot(drafts: drafts), draftPageGate: gate)
        let model = AppModel(service: service)
        await model.start()
        #expect(model.reviewQueue.count == 100)
        let first = Task { await model.loadNextDraftPage(state: .needsReview) }
        await gate.waitUntilLoadStarts()
        let second = Task { await model.loadNextDraftPage(state: .needsReview) }
        for _ in 0..<30 { await Task.yield() }
        await gate.open()
        await first.value; await second.value
        #expect(await service.nextDraftPageCalls == 1)
        #expect(model.reviewQueue.count == 103)
        #expect(Set(model.reviewQueue.map(\.id)).count == 103)
    }

    @Test
    func unrelatedRefreshWhileDetailIsLoadingEventuallyDisplaysTheTarget() async throws {
        let member = try FamilyMember(displayName: "Synthetic member")
        let record = try HealthRecord(memberID: member.id, attachmentID: UUID(), importState: .confirmed)
        let gate = OriginalLoadGate()
        let initial = TestLibrarySnapshot(members: [member], records: [record])
        let service = AppServiceSpy(snapshot: initial, recordLoadGate: gate,
            originals: [record.id: OriginalDocumentPayload(data: Data([1]), contentTypeIdentifier: "public.png")])
        let model = AppModel(service: service)
        await model.start()
        let selecting = Task { await model.selectRecord(record.id) }
        await gate.waitUntilLoadStarts()
        await service.replaceFixture(TestLibrarySnapshot(generation: 1, members: [member], records: [record]))
        await model.refresh()
        await gate.open()
        await selecting.value
        #expect(model.selectedRecord?.id == record.id)
        #expect(!model.isOriginalLoading)
    }

    @Test
    func changingComparisonSelectionCancelsPendingRecordReadAndAllowsAnotherOpen() async throws {
        let records = try (0..<2).map { _ in try HealthRecord(memberID: UUID(), attachmentID: UUID(), importState: .confirmed) }
        let gate = OriginalLoadGate()
        let service = AppServiceSpy(snapshot: TestLibrarySnapshot(records: records), recordLoadGate: gate)
        let model = ComparisonModel(service: service)
        model.startSelection()
        for record in records { model.toggle(LibraryReportSummary(record: record)) }
        let opening = Task { await model.openComparison() }
        await gate.waitUntilLoadStarts()
        model.cancelSelection()
        await gate.open()
        await opening.value
        #expect(!model.isLoadingOriginals)
        #expect(!model.isPresented)
        model.startSelection()
        for record in records { model.toggle(LibraryReportSummary(record: record)) }
        #expect(model.canCompare)
        await model.openComparison()
        #expect(model.isPresented)
    }
}
