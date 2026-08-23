import Foundation
import Testing
@testable import KinlogueApp
@testable import KinlogueCore

@Suite(.serialized)
@MainActor
struct ComparisonModelTests {
    @Test
    func selectionIsOrderedCappedAtTwoAndRejectsAThird() throws {
        let records = try (0..<3).map { _ in try makeRecord(state: .confirmed) }
        let service = AppServiceSpy(snapshot: .empty)
        let model = ComparisonModel(service: service)
        model.updateAvailableRecords(records)
        model.startSelection()

        #expect(model.toggle(records[1]) == .selected(count: 1))
        #expect(model.toggle(records[0]) == .selected(count: 2))
        #expect(model.toggle(records[2]) == .limitReached)
        #expect(model.selectedRecordIDs == [records[1].id, records[0].id])
        #expect(model.selectionCountText == "2/2")
        #expect(model.announcement == AppLocalization.string("最多只能选择两条记录"))
    }

    @Test
    func unconfirmedRecordCannotBeSelectedOrLoaded() async throws {
        let draft = try makeRecord(state: .needsReview)
        let confirmed = try makeRecord(state: .confirmed)
        let service = AppServiceSpy(snapshot: .empty)
        let model = ComparisonModel(service: service)
        model.updateAvailableRecords([draft, confirmed])
        model.startSelection()

        #expect(model.toggle(draft) == .ineligible)
        #expect(model.selectedRecordIDs.isEmpty)
        #expect(await service.originalLoadCallIDs.isEmpty)
    }

    @Test
    func openingLoadsTwoIndependentInMemoryOriginalsAndClosingReleasesThem() async throws {
        let left = try makeRecord(state: .confirmed)
        let right = try makeRecord(state: .confirmed)
        let leftBytes = Data([1, 2, 3])
        let rightBytes = Data([4, 5, 6])
        let service = AppServiceSpy(
            snapshot: .empty,
            originals: [
                left.id: OriginalDocumentPayload(data: leftBytes, contentTypeIdentifier: "public.png"),
                right.id: OriginalDocumentPayload(data: rightBytes, contentTypeIdentifier: "public.png"),
            ]
        )
        let model = ComparisonModel(service: service)
        model.updateAvailableRecords([left, right])
        model.startSelection()
        _ = model.toggle(left)
        _ = model.toggle(right)

        await model.openComparison()

        #expect(model.comparison?.left.recordID == left.id)
        #expect(model.leftOriginal?.data == leftBytes)
        #expect(model.rightOriginal?.data == rightBytes)
        #expect(Set(await service.originalLoadCallIDs) == Set([left.id, right.id]))

        model.closeComparison()
        #expect(model.leftOriginal == nil)
        #expect(model.rightOriginal == nil)
        #expect(model.comparison == nil)
        #expect(model.leftLoadState == .idle)
        #expect(model.rightLoadState == .idle)
    }

    @Test
    func aSecondOpenCannotReplaceTheCancelableOriginalLoadTasks() async throws {
        let left = try makeRecord(state: .confirmed)
        let right = try makeRecord(state: .confirmed)
        let service = AppServiceSpy(
            snapshot: .empty,
            originals: [
                left.id: OriginalDocumentPayload(data: Data([1]), contentTypeIdentifier: "public.png"),
                right.id: OriginalDocumentPayload(data: Data([2]), contentTypeIdentifier: "public.png"),
            ],
            originalLoadDelay: .milliseconds(100)
        )
        let model = ComparisonModel(service: service)
        model.updateAvailableRecords([left, right])
        model.startSelection()
        _ = model.toggle(left)
        _ = model.toggle(right)

        let firstOpen = Task { await model.openComparison() }
        while await service.originalLoadCallIDs.count < 2 { await Task.yield() }

        await model.openComparison()
        #expect(await service.originalLoadCallIDs.count == 2)
        #expect(model.announcement == AppLocalization.string("比较窗口已打开"))

        model.closeComparison()
        await firstOpen.value
        #expect(model.leftOriginal == nil)
        #expect(model.rightOriginal == nil)
    }

    @Test
    func oneOriginalFailureDoesNotDiscardTheOtherSide() async throws {
        let left = try makeRecord(state: .confirmed)
        let right = try makeRecord(state: .confirmed)
        let service = AppServiceSpy(
            snapshot: .empty,
            originals: [left.id: OriginalDocumentPayload(
                data: Data([9]),
                contentTypeIdentifier: "public.png"
            )]
        )
        let model = ComparisonModel(service: service)
        model.updateAvailableRecords([left, right])
        model.startSelection()
        _ = model.toggle(left)
        _ = model.toggle(right)

        await model.openComparison()

        #expect(model.leftLoadState == .loaded)
        #expect(model.leftOriginal?.data == Data([9]))
        #expect(model.rightLoadState == .failed)
        #expect(model.rightOriginal == nil)
    }

    @Test
    func errorAndVoiceOverAnnouncementTrackLanguageOnTheSameModel() async throws {
        let defaults = UserDefaults.standard
        let previousLanguage = defaults.object(forKey: AppLocalization.languagePreferenceKey)
        defer {
            if let previousLanguage {
                defaults.set(previousLanguage, forKey: AppLocalization.languagePreferenceKey)
            } else {
                defaults.removeObject(forKey: AppLocalization.languagePreferenceKey)
            }
        }
        defaults.set(
            AppLanguage.simplifiedChinese.rawValue,
            forKey: AppLocalization.languagePreferenceKey
        )

        let left = try makeRecord(state: .confirmed)
        let right = try makeRecord(state: .confirmed)
        let service = AppServiceSpy(
            snapshot: .empty,
            originals: [left.id: OriginalDocumentPayload(
                data: Data([9]),
                contentTypeIdentifier: "public.png"
            )]
        )
        let model = ComparisonModel(service: service)
        model.updateAvailableRecords([left, right])
        model.startSelection()
        _ = model.toggle(left)
        _ = model.toggle(right)
        await model.openComparison()

        #expect(model.errorMessage == "部分原件暂时无法打开")
        #expect(model.announcement == "部分原件暂时无法打开")

        defaults.set(
            AppLanguage.english.rawValue,
            forKey: AppLocalization.languagePreferenceKey
        )
        #expect(model.errorMessage == "Some originals are temporarily unavailable")
        #expect(model.announcement == "Some originals are temporarily unavailable")
    }

    @Test
    func closingDuringLoadCancelsRequestsAndDropsLatePayloads() async throws {
        let left = try makeRecord(state: .confirmed)
        let right = try makeRecord(state: .confirmed)
        let service = AppServiceSpy(
            snapshot: .empty,
            originals: [
                left.id: OriginalDocumentPayload(data: Data([1]), contentTypeIdentifier: "public.png"),
                right.id: OriginalDocumentPayload(data: Data([2]), contentTypeIdentifier: "public.png"),
            ],
            originalLoadDelay: .milliseconds(200)
        )
        let model = ComparisonModel(service: service)
        model.updateAvailableRecords([left, right])
        model.startSelection()
        _ = model.toggle(left)
        _ = model.toggle(right)

        let opening = Task { await model.openComparison() }
        while await service.originalLoadCallIDs.isEmpty { await Task.yield() }
        model.closeComparison()
        await opening.value

        #expect(model.leftOriginal == nil)
        #expect(model.rightOriginal == nil)
        #expect(model.leftLoadState == .idle)
        #expect(model.rightLoadState == .idle)
        #expect(model.isPresented == false)
    }

    @Test
    func eachComparisonSideNavigatesItsOwnOrderedOriginals() async throws {
        let leftSources = try makeSources(prefix: "left")
        let rightSources = try makeSources(prefix: "right")
        let left = try makeRecord(state: .confirmed, sources: leftSources)
        let right = try makeRecord(state: .confirmed, sources: rightSources)
        let service = AppServiceSpy(
            snapshot: .empty,
            originals: [
                left.id: OriginalDocumentPayload(data: Data([1]), contentTypeIdentifier: "public.png"),
                right.id: OriginalDocumentPayload(data: Data([2]), contentTypeIdentifier: "public.png"),
            ],
            sourceOriginals: [
                leftSources.elements[1].id: OriginalDocumentPayload(
                    data: Data([3]),
                    contentTypeIdentifier: "public.png"
                ),
            ]
        )
        let model = ComparisonModel(service: service)
        model.updateAvailableRecords([left, right])
        model.startSelection()
        _ = model.toggle(left)
        _ = model.toggle(right)

        await model.openComparison()
        await model.selectOriginalSource(leftSources.elements[1].id, side: .left)

        #expect(model.leftSelectedSourceID == leftSources.elements[1].id)
        #expect(model.leftOriginal?.data == Data([3]))
        #expect(model.rightSelectedSourceID == rightSources.first.id)
        #expect(model.rightOriginal?.data == Data([2]))
    }

    @Test
    func initialLoadCannotClearANewerSideNavigationTask() async throws {
        let leftSources = try makeSources(prefix: "left-race")
        let left = try makeRecord(state: .confirmed, sources: leftSources)
        let right = try makeRecord(state: .confirmed)
        let rightGate = OriginalLoadGate()
        let navigationGate = OriginalLoadGate()
        let service = AppServiceSpy(
            snapshot: .empty,
            originals: [
                left.id: OriginalDocumentPayload(data: Data([1]), contentTypeIdentifier: "public.png"),
                right.id: OriginalDocumentPayload(data: Data([2]), contentTypeIdentifier: "public.png"),
            ],
            sourceOriginals: [
                leftSources.elements[1].id: OriginalDocumentPayload(
                    data: Data([3]),
                    contentTypeIdentifier: "public.png"
                ),
            ],
            originalLoadGates: [right.id: rightGate],
            sourceOriginalLoadGates: [leftSources.elements[1].id: navigationGate]
        )
        let model = ComparisonModel(service: service)
        model.updateAvailableRecords([left, right])
        model.startSelection()
        _ = model.toggle(left)
        _ = model.toggle(right)

        let opening = Task { await model.openComparison() }
        while model.leftLoadState != .loaded || model.rightLoadState != .loading {
            await Task.yield()
        }
        let navigation = Task {
            await model.selectOriginalSource(leftSources.elements[1].id, side: .left)
        }
        await navigationGate.waitUntilLoadStarts()
        await rightGate.open()
        await opening.value

        #expect(model.leftLoadState == .loading)
        #expect(model.isLoadingOriginals)
        model.closeComparison()
        await navigationGate.open()
        await navigation.value
        #expect(model.leftOriginal == nil)
        #expect(model.leftLoadState == .idle)
    }

    @Test
    func escapeCancelClearsSelectionAndReturnsToNormalMode() throws {
        let record = try makeRecord(state: .confirmed)
        let model = ComparisonModel(service: AppServiceSpy(snapshot: .empty))
        model.updateAvailableRecords([record])
        model.startSelection()
        _ = model.toggle(record)

        model.cancelSelection()

        #expect(model.isSelecting == false)
        #expect(model.selectedRecordIDs.isEmpty)
        #expect(model.selectionCountText == "0/2")
    }
}

private func makeRecord(
    state: ImportState,
    sources: ReportSources? = nil
) throws -> HealthRecord {
    if let sources {
        return try HealthRecord(
            memberID: UUID(),
            sources: sources,
            importState: state
        )
    }
    return try HealthRecord(
        memberID: UUID(),
        attachmentID: UUID(),
        importState: state
    )
}

private func makeSources(prefix: String) throws -> ReportSources {
    try ReportSources([
        ReportSource(
            attachmentID: UUID(),
            displayName: "\(prefix)-1.png",
            pageCount: 1
        ),
        ReportSource(
            attachmentID: UUID(),
            displayName: "\(prefix)-2.png",
            pageCount: 1
        ),
    ])
}
