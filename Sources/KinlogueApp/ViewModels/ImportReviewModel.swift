import Foundation
import KinlogueCore

enum TimelineDateSelectionMode: Hashable {
    case unknown
    case detected(ReportDateCandidate.ID)
    case manual

    func selection(manualDate: Date) -> TimelineDateSelection {
        switch self {
        case .unknown: .unknown
        case .detected(let id): .detected(id)
        case .manual: .manual(manualDate)
        }
    }
}

enum ImportReviewField: Hashable {
    case title
    case organization
    case department
    case reportType
    case reportedResults
    case conclusion
}

private enum ImportReviewError: Equatable {
    case unavailable
    case recognitionFailed
    case originalUnavailable
    case memberRequired
    case confirmationFailed
    case deferralFailed
    case discardFailed

    var localizedText: String {
        switch self {
        case .unavailable:
            AppLocalization.string("待确认内容暂时无法打开")
        case .recognitionFailed:
            AppLocalization.string("重新识别失败，当前内容已保留")
        case .originalUnavailable:
            AppLocalization.string("所选原件暂时无法打开")
        case .memberRequired:
            AppLocalization.string("请选择家庭成员")
        case .confirmationFailed:
            AppLocalization.string("确认未保存，请重试")
        case .deferralFailed:
            AppLocalization.string("稍后处理未保存，请重试")
        case .discardFailed:
            AppLocalization.string("无法放弃这份导入")
        }
    }
}

@MainActor
final class ImportReviewModel: ObservableObject {
    private let draftID: ImportDraft.ID
    private let service: any AppDataServicing
    private var draftRevision: UInt64 = 0
    private var originalLoadTask: Task<OriginalDocumentPayload, Error>?
    private var originalLoadID: UUID?
    private var recognitionRequestID: UUID?

    @Published private(set) var isLoading = true
    @Published private(set) var loadFailed = false
    @Published private(set) var isTerminalActionInFlight = false
    @Published private(set) var isRecognitionInFlight = false
    @Published var isPresented = true
    @Published var isDiscardConfirmationPresented = false
    @Published private(set) var members: [FamilyMember] = []
    @Published private(set) var memberSelectionLabels: [FamilyMember.ID: String] = [:]
    @Published private(set) var dateCandidates: [ReportDateCandidate] = []
    @Published var selectedMemberID: FamilyMember.ID?
    @Published var dateSelectionMode: TimelineDateSelectionMode = .unknown
    @Published var manualTimelineDate = Date()
    @Published var title = ""
    @Published var organization = ""
    @Published var department = ""
    @Published var reportType = ""
    @Published var reportedResults = ""
    @Published var conclusion = ""
    @Published var abnormalItems: [String] = []
    @Published var userNote = ""
    @Published private(set) var sourceMethodDescription = ""
    @Published private(set) var originalDocument: OriginalDocumentPayload?
    @Published private(set) var originalSources: ReportSources?
    @Published private(set) var selectedOriginalSourceID: ReportSource.ID?
    @Published private(set) var isOriginalLoading = false
    @Published private(set) var fieldSourceDescriptions: [ImportReviewField: String] = [:]
    @Published private(set) var dateSourceDescriptions: [ReportDateCandidate.ID: String] = [:]
    @Published private(set) var abnormalSourceDescriptions: [String] = []
    @Published private var userError: ImportReviewError?

    init(draftID: ImportDraft.ID, service: any AppDataServicing) {
        self.draftID = draftID
        self.service = service
    }

    var errorMessage: String? { userError?.localizedText }

    func load() async {
        isLoading = true
        loadFailed = false
        userError = nil
        do {
            let content = try await service.loadReview(draftID: draftID)
            guard isPresented else {
                isLoading = false
                return
            }
            draftRevision = content.draft.revision
            members = content.members
            memberSelectionLabels = RecordQuery.selectionLabels(for: content.members)
            selectedMemberID = content.draft.memberID.flatMap { memberID in
                content.members.contains(where: { $0.id == memberID }) ? memberID : nil
            }
            apply(document: content.document, sources: content.draft.sources)
            originalSources = content.draft.sources
            selectedOriginalSourceID = content.draft.sources.first.id
            originalDocument = content.original
        } catch {
            loadFailed = true
            userError = .unavailable
        }
        isLoading = false
    }

    func recognizeAgain() async {
        guard !isLoading, !isTerminalActionInFlight, !isRecognitionInFlight,
              let sources = originalSources else { return }
        let requestID = UUID()
        recognitionRequestID = requestID
        isRecognitionInFlight = true
        userError = nil
        defer {
            if recognitionRequestID == requestID {
                recognitionRequestID = nil
                isRecognitionInFlight = false
            }
        }
        do {
            let recognized = try await service.recognizeReview(RecognizeReviewCommand(
                draftID: draftID,
                expectedRevision: draftRevision,
                memberID: selectedMemberID,
                timelineDateSelection: dateSelectionMode.selection(manualDate: manualTimelineDate),
                detectedDateCandidate: selectedDetectedDateCandidate,
                userNote: userNote
            ))
            guard isPresented, recognitionRequestID == requestID else { return }
            draftRevision = recognized.draftRevision
            apply(document: recognized.document, sources: sources)
        } catch is CancellationError {
            // Closing the review releases the result without changing the form.
        } catch {
            guard isPresented, recognitionRequestID == requestID else { return }
            userError = .recognitionFailed
        }
    }

    func selectOriginalSource(_ sourceID: ReportSource.ID) async {
        guard let sources = originalSources,
              sources.elements.contains(where: { $0.id == sourceID }),
              sourceID != selectedOriginalSourceID,
              isPresented else { return }
        originalLoadTask?.cancel()
        let requestID = UUID()
        originalLoadID = requestID
        selectedOriginalSourceID = sourceID
        originalDocument = nil
        isOriginalLoading = true
        let task = Task { [service, draftID] in
            let payload = try await service.loadReviewOriginal(
                draftID: draftID,
                sourceID: sourceID
            )
            try Task.checkCancellation()
            return payload
        }
        originalLoadTask = task
        do {
            let payload = try await task.value
            guard isPresented, originalLoadID == requestID else { return }
            originalDocument = payload
            isOriginalLoading = false
            originalLoadTask = nil
        } catch is CancellationError {
            // A newer source selection owns the presentation state.
        } catch {
            guard isPresented, originalLoadID == requestID else { return }
            isOriginalLoading = false
            originalLoadTask = nil
            userError = .originalUnavailable
        }
    }

    func confirm() async {
        guard !isLoading, !isTerminalActionInFlight, !isRecognitionInFlight else { return }
        guard let selectedMemberID else {
            userError = .memberRequired
            return
        }
        isTerminalActionInFlight = true
        defer { isTerminalActionInFlight = false }
        do {
            _ = try await service.confirmDraft(ConfirmDraftCommand(
                draftID: draftID,
                expectedRevision: draftRevision,
                memberID: selectedMemberID,
                timelineDateSelection: dateSelectionMode.selection(manualDate: manualTimelineDate),
                detectedDateCandidate: selectedDetectedDateCandidate,
                title: title,
                organization: organization,
                department: department,
                reportType: reportType,
                reportedResults: reportedResults,
                conclusion: conclusion,
                abnormalItems: abnormalItems,
                userNote: userNote
            ))
            closeReview()
        } catch {
            userError = .confirmationFailed
        }
    }

    func deferReview() async {
        guard !isLoading, !isTerminalActionInFlight, !isRecognitionInFlight else { return }
        isTerminalActionInFlight = true
        defer { isTerminalActionInFlight = false }
        do {
            try await service.deferDraft(DeferDraftCommand(
                draftID: draftID,
                expectedRevision: draftRevision,
                memberID: selectedMemberID,
                timelineDateSelection: dateSelectionMode.selection(manualDate: manualTimelineDate),
                detectedDateCandidate: selectedDetectedDateCandidate,
                title: title,
                organization: organization,
                department: department,
                reportType: reportType,
                reportedResults: reportedResults,
                conclusion: conclusion,
                abnormalItems: abnormalItems,
                userNote: userNote
            ))
            closeReview()
        } catch {
            userError = .deferralFailed
        }
    }

    func requestDiscard() {
        guard !isLoading, !isTerminalActionInFlight, !isRecognitionInFlight else { return }
        isDiscardConfirmationPresented = true
    }

    func confirmDiscard() async {
        guard !isLoading, !isTerminalActionInFlight, !isRecognitionInFlight else { return }
        isTerminalActionInFlight = true
        defer { isTerminalActionInFlight = false }
        do {
            _ = try await service.discardDraft(DiscardDraftCommand(
                draftID: draftID,
                expectedRevision: draftRevision
            ))
            isDiscardConfirmationPresented = false
            closeReview()
        } catch {
            userError = .discardFailed
        }
    }

    func closeReview() {
        originalLoadTask?.cancel()
        originalLoadTask = nil
        originalLoadID = nil
        originalDocument = nil
        originalSources = nil
        selectedOriginalSourceID = nil
        isOriginalLoading = false
        recognitionRequestID = nil
        isRecognitionInFlight = false
        isPresented = false
    }

    private func apply(document: ImportDraftDocument, sources: ReportSources) {
        let candidates = document.candidates
        let blockIndex = OCRBlockIndex(document.blocks)
        dateCandidates = candidates.dateCandidates
        if let reviewState = document.reviewState {
            restore(reviewState)
        } else {
            dateSelectionMode = .unknown
            title = candidates.title?.transcription ?? ""
            organization = candidates.organization?.transcription ?? ""
            department = candidates.department?.transcription ?? ""
            reportType = candidates.reportType?.transcription ?? ""
            reportedResults = candidates.reportedResults?.transcription ?? ""
            conclusion = candidates.conclusion?.transcription ?? ""
            abnormalItems = candidates.abnormalItems.map(\.transcription)
        }
        sourceMethodDescription = Self.sourceDescription(document.blocks)
        fieldSourceDescriptions = Self.fieldSources(
            candidates: candidates,
            blockIndex: blockIndex,
            sources: sources
        )
        dateSourceDescriptions = Dictionary(uniqueKeysWithValues:
            candidates.dateCandidates.map {
                ($0.id, Self.provenanceDescription(
                    $0.source,
                    blockIndex: blockIndex,
                    sources: sources
                ))
            }
        )
        abnormalSourceDescriptions = candidates.abnormalItems.map {
            Self.provenanceDescription(
                $0,
                blockIndex: blockIndex,
                sources: sources
            )
        }
    }

    private func restore(_ state: ImportDraftReviewState) {
        switch state.timelineDateSelection {
        case .unknown:
            dateSelectionMode = .unknown
        case .detected(let id):
            dateSelectionMode = dateCandidates.contains(where: { $0.id == id })
                ? .detected(id)
                : .unknown
        case .manual(let date):
            dateSelectionMode = .manual
            manualTimelineDate = ReportDateSemantics.pickerDate(from: date) ?? date
        }
        title = state.title
        organization = state.organization
        department = state.department
        reportType = state.reportType
        reportedResults = state.reportedResults
        conclusion = state.conclusion
        abnormalItems = state.abnormalItems
        userNote = state.userNote
    }

    private var selectedDetectedDateCandidate: ReportDateCandidate? {
        guard case .detected(let id) = dateSelectionMode else { return nil }
        return dateCandidates.first { $0.id == id }
    }

    private static func sourceDescription(_ blocks: [OCRBlock]) -> String {
        let methods = Set(blocks.map(\.method))
        return switch (methods.contains(.pdfTextLayer), methods.contains(.vision)) {
        case (true, true): AppLocalization.string("PDF 原文字层与本机文字识别")
        case (true, false): AppLocalization.string("PDF 原文字层")
        case (false, true): AppLocalization.string("本机文字识别")
        case (false, false): AppLocalization.string("未识别到文字")
        }
    }

    private static func fieldSources(
        candidates: ReportCandidates,
        blockIndex: OCRBlockIndex,
        sources: ReportSources
    ) -> [ImportReviewField: String] {
        let fields: [(ImportReviewField, SourceField?)] = [
            (.title, candidates.title),
            (.organization, candidates.organization),
            (.department, candidates.department),
            (.reportType, candidates.reportType),
            (.reportedResults, candidates.reportedResults),
            (.conclusion, candidates.conclusion),
        ]
        return Dictionary(uniqueKeysWithValues: fields.compactMap { key, field in
            guard let field else { return nil }
            return (key, provenanceDescription(
                field,
                blockIndex: blockIndex,
                sources: sources
            ))
        })
    }

    private static func provenanceDescription(
        _ field: SourceField,
        blockIndex: OCRBlockIndex,
        sources: ReportSources
    ) -> String {
        let blockIDs = Set(field.references.compactMap(\.blockID))
        let matched = blockIndex.matching(blockIDs)
        let pages = Set(field.references.compactMap { $0.logicalPage(in: sources) })
            .sorted()
            .map(String.init)
            .joined(separator: AppLocalization.string("、"))
        let methods = Set(matched.map(\.method))
        let method: String
        switch (methods.contains(.pdfTextLayer), methods.contains(.vision)) {
        case (true, true): method = AppLocalization.string("原文字层与本机识别")
        case (true, false): method = AppLocalization.string("PDF 原文字层")
        case (false, true): method = AppLocalization.string("本机文字识别")
        case (false, false): method = AppLocalization.string("来源位置不可用")
        }
        let confidences = matched.compactMap(\.confidence)
        let confidence = confidences.isEmpty
            ? ""
            : AppLocalization.string("，识别置信度 \(Int((confidences.reduce(0, +) / Double(confidences.count)) * 100))%")
        let page = pages.isEmpty ? "" : AppLocalization.string("，第 \(pages) 页")
        return AppLocalization.string("来源：\(method)\(page)\(confidence)")
    }

}

private struct OCRBlockIndex {
    private let blocks: [OCRBlock]
    private let offsetsByID: [OCRBlock.ID: [Int]]

    init(_ blocks: [OCRBlock]) {
        self.blocks = blocks
        offsetsByID = Dictionary(grouping: blocks.indices, by: { blocks[$0].id })
    }

    func matching(_ ids: Set<OCRBlock.ID>) -> [OCRBlock] {
        ids.flatMap { offsetsByID[$0, default: []] }
            .sorted()
            .map { blocks[$0] }
    }
}
