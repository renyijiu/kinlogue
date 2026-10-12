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
