import Foundation
import KinlogueCore

enum ComparisonSelectionResult: Equatable {
    case selected(count: Int)
    case deselected(count: Int)
    case limitReached
    case ineligible
}

enum ComparisonOriginalLoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed
}

enum ComparisonSide: Equatable {
    case left
    case right
}

private enum ComparisonSideLoadResult: Sendable {
    case left(OriginalDocumentPayload?)
    case right(OriginalDocumentPayload?)
}

private enum ComparisonMessage: Equatable {
    case selectionMode(selectedCount: Int)
    case onlyConfirmedRecords
    case selectionRemoved(selectedCount: Int)
    case selectionLimitReached
    case recordSelected(ordinal: Int, selectedCount: Int)
    case selectionCleared
    case selectionExited
    case comparisonAlreadyOpen
    case chooseTwoConfirmedRecords
    case recordsCannotBeCompared
    case originalsLoaded
    case someOriginalsUnavailable
    case comparisonClosed

    var localizedText: String {
        switch self {
        case .selectionMode(let selectedCount):
            AppLocalization.string("比较选择模式，已选择 \(Self.countText(selectedCount))")
        case .onlyConfirmedRecords:
            AppLocalization.string("只有已确认记录可以比较")
        case .selectionRemoved(let selectedCount):
            AppLocalization.string("已取消选择，当前 \(Self.countText(selectedCount))")
        case .selectionLimitReached:
            AppLocalization.string("最多只能选择两条记录")
        case .recordSelected(let ordinal, let selectedCount):
            AppLocalization.string("已选择第 \(ordinal) 条记录，当前 \(Self.countText(selectedCount))")
        case .selectionCleared:
            AppLocalization.string("已清空比较选择，当前 0/2")
        case .selectionExited:
            AppLocalization.string("已退出比较选择模式")
        case .comparisonAlreadyOpen:
            AppLocalization.string("比较窗口已打开")
        case .chooseTwoConfirmedRecords:
            AppLocalization.string("请选择两条已确认记录后再比较")
        case .recordsCannotBeCompared:
            AppLocalization.string("所选记录无法比较")
        case .originalsLoaded:
            AppLocalization.string("两份原件已载入内存")
        case .someOriginalsUnavailable:
            AppLocalization.string("部分原件暂时无法打开")
        case .comparisonClosed:
            AppLocalization.string("已关闭比较并释放原件")
        }
    }

    private static func countText(_ count: Int) -> String { "\(count)/2" }
}

@MainActor
final class ComparisonModel: ObservableObject {
    private let service: any AppDataServicing
    private var recordsByID: [HealthRecord.ID: HealthRecord] = [:]
    private var loadID: UUID?
    private var leftLoadID: UUID?
    private var rightLoadID: UUID?
    private var leftLoadTask: Task<OriginalDocumentPayload, Error>?
    private var rightLoadTask: Task<OriginalDocumentPayload, Error>?
    @Published private var announcementMessage: ComparisonMessage?
    @Published private var userErrorMessage: ComparisonMessage?

    @Published private(set) var isSelecting = false
    @Published private(set) var selectedRecordIDs: [HealthRecord.ID] = []
    @Published private(set) var comparison: RecordComparison?
    @Published private(set) var leftOriginal: OriginalDocumentPayload?
    @Published private(set) var rightOriginal: OriginalDocumentPayload?
    @Published private(set) var leftSelectedSourceID: ReportSource.ID?
    @Published private(set) var rightSelectedSourceID: ReportSource.ID?
    @Published private(set) var isLoadingOriginals = false
    @Published private(set) var leftLoadState: ComparisonOriginalLoadState = .idle
    @Published private(set) var rightLoadState: ComparisonOriginalLoadState = .idle
    @Published private(set) var isPresented = false

    init(service: any AppDataServicing) {
        self.service = service
    }

    var selectionCountText: String { "\(selectedRecordIDs.count)/2" }
    var announcement: String { announcementMessage?.localizedText ?? "" }
    var errorMessage: String? { userErrorMessage?.localizedText }
    var canCompare: Bool {
        selectedRecordIDs.count == 2 && !isPresented && !isLoadingOriginals
    }

    func updateAvailableRecords(_ records: [HealthRecord]) {
        recordsByID = Dictionary(uniqueKeysWithValues: records
            .filter { $0.importState == .confirmed }
            .map { ($0.id, $0) })
        selectedRecordIDs.removeAll { recordsByID[$0] == nil }
        if comparison.map({ recordsByID[$0.left.recordID] == nil || recordsByID[$0.right.recordID] == nil }) == true {
            closeComparison()
        }
    }

    func startSelection() {
        isSelecting = true
        announcementMessage = .selectionMode(selectedCount: selectedRecordIDs.count)
        userErrorMessage = nil
    }

    @discardableResult
    func toggle(_ record: HealthRecord) -> ComparisonSelectionResult {
        guard isSelecting,
              record.importState == .confirmed,
              recordsByID[record.id] != nil else {
            announcementMessage = .onlyConfirmedRecords
            return .ineligible
        }
        if let index = selectedRecordIDs.firstIndex(of: record.id) {
            selectedRecordIDs.remove(at: index)
            announcementMessage = .selectionRemoved(selectedCount: selectedRecordIDs.count)
            userErrorMessage = nil
            return .deselected(count: selectedRecordIDs.count)
        }
        guard selectedRecordIDs.count < 2 else {
            announcementMessage = .selectionLimitReached
            userErrorMessage = .selectionLimitReached
            return .limitReached
        }
        selectedRecordIDs.append(record.id)
        announcementMessage = .recordSelected(
            ordinal: selectedRecordIDs.count,
            selectedCount: selectedRecordIDs.count
        )
        userErrorMessage = nil
        return .selected(count: selectedRecordIDs.count)
    }

    func isSelected(_ recordID: HealthRecord.ID) -> Bool {
        selectedRecordIDs.contains(recordID)
    }

    func clearSelection() {
        selectedRecordIDs = []
        announcementMessage = .selectionCleared
        userErrorMessage = nil
    }

    func cancelSelection() {
        clearSelection()
        isSelecting = false
        announcementMessage = .selectionExited
    }

    func openComparison() async {
        guard !isPresented, !isLoadingOriginals else {
            announcementMessage = .comparisonAlreadyOpen
            return
        }
        guard selectedRecordIDs.count == 2,
              let leftRecord = recordsByID[selectedRecordIDs[0]],
              let rightRecord = recordsByID[selectedRecordIDs[1]] else {
            announcementMessage = .chooseTwoConfirmedRecords
            userErrorMessage = .chooseTwoConfirmedRecords
            return
        }
        do {
            comparison = try RecordComparison(records: [leftRecord, rightRecord])
        } catch {
            announcementMessage = .recordsCannotBeCompared
            userErrorMessage = .recordsCannotBeCompared
            return
        }

        leftOriginal = nil
        rightOriginal = nil
        isPresented = true
        isLoadingOriginals = true
        leftLoadState = .loading
        rightLoadState = .loading
        userErrorMessage = nil
        let requestID = UUID()
        loadID = requestID
        let leftSourceID = leftRecord.sources.first.id
        let rightSourceID = rightRecord.sources.first.id
        leftSelectedSourceID = leftSourceID
        rightSelectedSourceID = rightSourceID
        let service = service
        let leftTask = Task {
            let payload = try await service.loadOriginal(
                recordID: leftRecord.id,
                sourceID: leftSourceID
            )
            try Task.checkCancellation()
            return payload
        }
        let rightTask = Task {
            let payload = try await service.loadOriginal(
                recordID: rightRecord.id,
                sourceID: rightSourceID
            )
            try Task.checkCancellation()
            return payload
        }
        leftLoadID = requestID
        rightLoadID = requestID
        leftLoadTask = leftTask
        rightLoadTask = rightTask
        await withTaskGroup(of: ComparisonSideLoadResult.self) { group in
            group.addTask { .left(try? await leftTask.value) }
            group.addTask { .right(try? await rightTask.value) }
            for await result in group {
                guard loadID == requestID else { return }
                switch result {
                case .left(let payload) where leftLoadID == requestID:
                    leftLoadTask = nil
                    leftOriginal = payload
                    leftLoadState = payload == nil ? .failed : .loaded
                case .right(let payload) where rightLoadID == requestID:
                    rightLoadTask = nil
                    rightOriginal = payload
                    rightLoadState = payload == nil ? .failed : .loaded
                default:
                    continue
                }
                isLoadingOriginals = leftLoadState == .loading || rightLoadState == .loading
            }
        }
        guard loadID == requestID else { return }
        finishLoadingSummaryIfSettled()
    }

    func selectOriginalSource(_ sourceID: ReportSource.ID, side: ComparisonSide) async {
        guard let comparison, isPresented else { return }
        let pane = side == .left ? comparison.left : comparison.right
        let currentSourceID = side == .left
            ? leftSelectedSourceID
            : rightSelectedSourceID
        guard pane.sources.elements.contains(where: { $0.id == sourceID }),
              sourceID != currentSourceID else { return }

        let requestID = UUID()
        let recordID = pane.recordID
        let service = service
        switch side {
        case .left:
            leftLoadTask?.cancel()
            leftLoadID = requestID
            leftSelectedSourceID = sourceID
            leftOriginal = nil
            leftLoadState = .loading
        case .right:
            rightLoadTask?.cancel()
            rightLoadID = requestID
            rightSelectedSourceID = sourceID
            rightOriginal = nil
            rightLoadState = .loading
        }
        isLoadingOriginals = true
        let task = Task {
            let payload = try await service.loadOriginal(
                recordID: recordID,
                sourceID: sourceID
            )
            try Task.checkCancellation()
            return payload
        }
        switch side {
        case .left:
            leftLoadTask = task
        case .right:
            rightLoadTask = task
        }

        let payload = try? await task.value
        guard isPresented else { return }
        switch side {
        case .left where leftLoadID == requestID:
            leftLoadTask = nil
            leftOriginal = payload
            leftLoadState = payload == nil ? .failed : .loaded
        case .right where rightLoadID == requestID:
            rightLoadTask = nil
            rightOriginal = payload
            rightLoadState = payload == nil ? .failed : .loaded
        default:
            return
        }
        finishLoadingSummaryIfSettled()
    }

    private func finishLoadingSummaryIfSettled() {
        isLoadingOriginals = leftLoadState == .loading || rightLoadState == .loading
        guard !isLoadingOriginals else { return }
        if leftLoadState == .loaded, rightLoadState == .loaded {
            userErrorMessage = nil
            announcementMessage = .originalsLoaded
        } else {
            userErrorMessage = .someOriginalsUnavailable
            announcementMessage = .someOriginalsUnavailable
        }
    }

    func closeComparison() {
        loadID = nil
        leftLoadID = nil
        rightLoadID = nil
        leftLoadTask?.cancel()
        rightLoadTask?.cancel()
        leftLoadTask = nil
        rightLoadTask = nil
        leftOriginal = nil
        rightOriginal = nil
        leftSelectedSourceID = nil
        rightSelectedSourceID = nil
        comparison = nil
        isLoadingOriginals = false
        leftLoadState = .idle
        rightLoadState = .idle
        isPresented = false
        selectedRecordIDs = []
        isSelecting = false
        userErrorMessage = nil
        announcementMessage = .comparisonClosed
    }

}
