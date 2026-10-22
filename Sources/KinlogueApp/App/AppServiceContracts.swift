import Foundation
import KinlogueCore
import KinloguePlatform

enum AppServiceError: Error, Equatable, Sendable {
    case runtimeUnavailable
    case vaultUnavailable
    case memberUnavailable
    case memberStillReferenced(recordCount: Int, draftCount: Int)
    case memberStillReferencedByDICOMStudy(studyCount: Int)
    case draftUnavailable
    case recordUnavailable
    case recordChanged
    case dicomStudyUnavailable
    case invalidReview
    case importFailed
}

enum AppFailureCode: String, Equatable, Sendable {
    case vaultUnavailable
    case importFailed
    case unsupportedFile
    case lockedPDF
    case resourceLimit
    case damagedFile
}

struct DraftSummary: Identifiable, Equatable, Sendable {
    let id: ImportDraft.ID
    let state: ImportState
    let revision: UInt64
    let failureCode: ImportFailureCode?
    let canRetryRecovery: Bool
    /// The first original's file name, which tells waiting drafts apart.
    let displayName: String?

    init(draft: LibraryDraftSummary, canRetryRecovery: Bool = false) {
        id = draft.id; state = draft.state; revision = draft.revision
        failureCode = draft.failureCode; self.canRetryRecovery = canRetryRecovery
        displayName = draft.displayName
    }

    init(draft: ImportDraft, canRetryRecovery: Bool = false) {
        id = draft.id
        state = draft.state
        revision = draft.revision
        failureCode = draft.failureCode
        self.canRetryRecovery = canRetryRecovery
        displayName = draft.sources.first.displayName
    }
}

struct DICOMStudySummary: Identifiable, Equatable, Sendable {
    let id: DICOMStudy.ID
    let state: DICOMStudyState
    let retainedObjectCount: Int
    let confirmedMemberID: FamilyMember.ID?
    let effectiveDate: Date?
    let contentRevision: UInt64

    init(
        id: DICOMStudy.ID,
        state: DICOMStudyState,
        retainedObjectCount: Int,
        confirmedMemberID: FamilyMember.ID?,
        effectiveDate: Date?,
        contentRevision: UInt64 = 0
    ) {
        self.id = id
        self.state = state
        self.retainedObjectCount = retainedObjectCount
        self.confirmedMemberID = confirmedMemberID
        self.effectiveDate = effectiveDate
        self.contentRevision = contentRevision
    }

    init(study: LibraryDICOMStudySummary) {
        self.init(id: study.id, state: study.state, retainedObjectCount: study.retainedObjectCount,
                  confirmedMemberID: study.confirmedMemberID, effectiveDate: study.effectiveDate,
                  contentRevision: study.contentRevision)
    }
}

enum AppTimelineEntry: Identifiable, Equatable, Sendable {
    enum ID: Hashable, Sendable {
        case record(HealthRecord.ID)
        case dicomStudy(DICOMStudy.ID)
    }

    case record(LibraryReportSummary)
    case dicomStudy(DICOMStudySummary)

    var id: ID {
        switch self {
        case .record(let record): .record(record.id)
        case .dicomStudy(let study): .dicomStudy(study.id)
        }
    }

    var timelineDate: Date? {
        switch self {
        case .record(let record): record.timelineDate
        case .dicomStudy(let study): study.effectiveDate
        }
    }

    var stableOrder: String {
        switch self {
        case .record(let record): "0-\(record.id.uuidString)"
        case .dicomStudy(let study): "1-\(study.id.uuidString)"
        }
    }
}

enum AppTimelineFilter: Hashable, CaseIterable, Sendable {
    case all
    case reports
    case imaging
}

struct AppTimelineSection: Equatable, Sendable {
    let group: TimelineDateGroup
    let entries: [AppTimelineEntry]

    var records: [LibraryReportSummary] {
        entries.compactMap {
            guard case .record(let record) = $0 else { return nil }
            return record
        }
    }

    var dicomStudies: [DICOMStudySummary] {
        entries.compactMap {
            guard case .dicomStudy(let study) = $0 else { return nil }
            return study
        }
    }
}

struct DICOMSeriesSummary: Identifiable, Equatable, Sendable {
    let id: DICOMStudyIndex.Series.ID
    let ordinal: Int
    let sliceCount: Int
    let rows: Int
    let columns: Int
    let orderingProvenance: DICOMStudyIndex.OrderingProvenance
}

struct AppSnapshot: Equatable, Sendable {
    let revision: LibraryRevision
    let members: [LibraryMemberSummary]
    let dicomStudies: [DICOMStudySummary]
    let reportCount: Int
    let draftCount: Int
    let damagedMemberIDs: [UUID]
    let damagedStudyIDs: [UUID]
    var generation: UInt64 { revision.generation }

    init(header: LibraryHeader) {
        revision = header.revision; members = header.members
        dicomStudies = header.studies.map(DICOMStudySummary.init)
        reportCount = header.reportCount; draftCount = header.draftCount
        damagedMemberIDs = header.damagedMemberIDs; damagedStudyIDs = header.damagedStudyIDs
    }
}

struct AppDraftPage: Sendable {
    let revision: LibraryRevision
    let items: [DraftSummary]
    let nextCursor: LibraryQueryCursor?
    let damagedIDs: [UUID]
}

enum DICOMStudyDestination: Equatable, Sendable {
    case review
    case timeline
}

struct DICOMAppImportOutcome: Equatable, Sendable {
    let studyID: DICOMStudy.ID
    let destination: DICOMStudyDestination
    let wasExisting: Bool
    let viewableInstanceCount: Int
    let inertObjectCount: Int
    let ignoredNonDICOMCount: Int
    let ignoredDuplicateCount: Int
}

struct DICOMStudyViewerContent: Equatable, Sendable {
    let study: DICOMStudySummary
    let confirmedMemberLabel: String?
    let viewableInstanceCount: Int
    let inertObjectCount: Int
    let series: [DICOMSeriesSummary]

    var seriesCount: Int { series.count }
}

struct DICOMStudyReviewContent: Equatable, Sendable {
    let viewerContent: DICOMStudyViewerContent
    let selectableMembers: [LibraryMemberSummary]

    var study: DICOMStudySummary { viewerContent.study }
    var viewableInstanceCount: Int { viewerContent.viewableInstanceCount }
    var inertObjectCount: Int { viewerContent.inertObjectCount }
    var seriesCount: Int { viewerContent.seriesCount }
}

protocol DICOMSliceViewing: Sendable {
    func openSeries(
        studyID: DICOMStudy.ID,
        seriesID: DICOMStudyIndex.Series.ID
    ) async throws -> DICOMSliceSeriesSession
    func render(
        session: DICOMSliceSeriesSession,
        instanceID: DICOMStudyIndex.Instance.ID,
        windowCenter: Double?,
        windowWidth: Double?
    ) async throws -> DICOMSliceImage
    @discardableResult
    func prefetch(
        session: DICOMSliceSeriesSession,
        instanceID: DICOMStudyIndex.Instance.ID
    ) async -> Bool
    func handleMemoryPressure() async
    func close() async
}

extension DICOMSliceService: DICOMSliceViewing {}

struct SaveDICOMStudyCommand: Equatable, Sendable {
    let studyID: DICOMStudy.ID
    let expectedRevision: UInt64
    let memberID: FamilyMember.ID
    let effectiveDate: Date
}

protocol DICOMStudyViewerMetadataServicing: Sendable {
    func loadDICOMStudyViewer(studyID: DICOMStudy.ID) async throws -> DICOMStudyViewerContent
}

protocol DICOMAppServicing: DICOMStudyViewerMetadataServicing, Sendable {
    func importDICOMDirectory(at url: URL) async throws -> DICOMAppImportOutcome
    func cancelDICOMImport() async throws -> DICOMAppImportOutcome?
    func loadDICOMStudyReview(studyID: DICOMStudy.ID) async throws -> DICOMStudyReviewContent
    func saveDICOMStudy(_ command: SaveDICOMStudyCommand) async throws -> AppSnapshot
    func deleteDICOMStudy(id: DICOMStudy.ID) async throws -> AppSnapshot
}

extension DICOMAppServicing {
    func loadDICOMStudyViewer(
        studyID: DICOMStudy.ID
    ) async throws -> DICOMStudyViewerContent {
        try await loadDICOMStudyReview(studyID: studyID).viewerContent
    }
}

enum AppImportOutcome: Equatable, Sendable {
    case needsReview(ImportDraft.ID)
    case existingRecord(HealthRecord.ID)
    case existingDraft(ImportDraft.ID)
    case failed(AppFailureCode)
}

struct ImportReviewContent: Equatable, Sendable {
    let revision: LibraryRevision
    let draft: ImportDraft
    let document: ImportDraftDocument
    let members: [LibraryMemberSummary]
    let original: OriginalDocumentPayload
}

struct RecognizedReviewContent: Equatable, Sendable {
    let draftRevision: UInt64
    let document: ImportDraftDocument
}

enum TimelineDateSelection: Equatable, Sendable {
    case unknown
    case detected(ReportDateCandidate.ID)
    case manual(Date)
}

struct ConfirmDraftCommand: Equatable, Sendable {
    let draftID: ImportDraft.ID
    let expectedRevision: UInt64
    let memberID: FamilyMember.ID
    let timelineDateSelection: TimelineDateSelection
    var detectedDateCandidate: ReportDateCandidate? = nil
    let title: String
    let organization: String
    let department: String
    let reportType: String
    let reportedResults: String
    let conclusion: String
    let abnormalItems: [String]
    let userNote: String
}

struct DiscardDraftCommand: Equatable, Sendable {
    let draftID: ImportDraft.ID
    let expectedRevision: UInt64
}

struct DeferDraftCommand: Equatable, Sendable {
    let draftID: ImportDraft.ID
    let expectedRevision: UInt64
    let memberID: FamilyMember.ID?
    let timelineDateSelection: TimelineDateSelection
    var detectedDateCandidate: ReportDateCandidate? = nil
    let title: String
    let organization: String
    let department: String
    let reportType: String
    let reportedResults: String
    let conclusion: String
    let abnormalItems: [String]
    let userNote: String
}

struct RecognizeReviewCommand: Equatable, Sendable {
    let draftID: ImportDraft.ID
    let expectedRevision: UInt64
    let memberID: FamilyMember.ID?
    let timelineDateSelection: TimelineDateSelection
    var detectedDateCandidate: ReportDateCandidate? = nil
    let userNote: String
}

struct UpdateRecordCommand: Equatable, Sendable {
    let recordID: HealthRecord.ID
    let expectedRevision: UInt64
    let memberID: FamilyMember.ID
    let timelineDateSelection: TimelineDateSelection
    let title: String
    let organization: String
    let department: String
    let reportType: String
    let reportedResults: String
    let conclusion: String
    let abnormalItems: [String]
    let userNote: String
}

/// Brings a confirmed record to the current extraction rules: the fields in `acceptedFields` take
/// the new candidates, the rest stay. The rules version and revision are those the user saw.
struct ApplyRuleUpdateCommand: Equatable, Sendable {
    let recordID: HealthRecord.ID
    let expectedRevision: UInt64
    let extractionVersion: Int
    let acceptedFields: Set<RecordRuleUpdate.Field>
}

struct OriginalDocumentPayload: Equatable, Sendable {
    let data: Data
    let contentTypeIdentifier: String
    let sourceID: ReportSource.ID?
    let attachmentID: Attachment.ID?
    let displayName: String?
    let pageCount: Int

    init(
        data: Data,
        contentTypeIdentifier: String,
        sourceID: ReportSource.ID? = nil,
        attachmentID: Attachment.ID? = nil,
        displayName: String? = nil,
        pageCount: Int = 1
    ) {
        self.data = data
        self.contentTypeIdentifier = contentTypeIdentifier
        self.sourceID = sourceID
        self.attachmentID = attachmentID
        self.displayName = displayName
        self.pageCount = pageCount
    }
}

protocol AppDataServicing: Sendable {
    func timelinePage(memberID: UUID?, cursor: LibraryQueryCursor?) async throws -> LibraryTimelinePage
    func reportPage(query: String, memberID: UUID?, cursor: LibraryQueryCursor?) async throws -> LibraryReportPage
    func draftPage(states: [ImportState], cursor: LibraryQueryCursor?) async throws -> AppDraftPage
    func loadRecords(ids: [UUID]) async throws -> LibraryRecordSelection
    func loadMember(id: UUID) async throws -> FamilyMember
    func loadDraft(id: UUID) async throws -> ImportDraft

    func bootstrap() async throws -> AppSnapshot
    func refresh() async throws -> AppSnapshot
    func createMember(displayName: String, disambiguationLabel: String?) async throws -> AppSnapshot
    func updateMember(_ member: FamilyMember, replacing expected: FamilyMember) async throws -> AppSnapshot
    func archiveMember(id: FamilyMember.ID) async throws -> AppSnapshot
    func deleteMember(id: FamilyMember.ID) async throws -> AppSnapshot
    func importFile(at url: URL) async throws -> AppImportOutcome
    func retryDraft(id: ImportDraft.ID) async throws -> AppImportOutcome
    func loadReview(draftID: ImportDraft.ID) async throws -> ImportReviewContent
    func recognizeReview(_ command: RecognizeReviewCommand) async throws -> RecognizedReviewContent
    func loadReviewOriginal(
        draftID: ImportDraft.ID,
        sourceID: ReportSource.ID,
        expectedRevision: UInt64,
        expectedLibrary: LibraryRevision
    ) async throws -> OriginalDocumentPayload
    func confirmDraft(_ command: ConfirmDraftCommand) async throws -> AppSnapshot
    func updateRecord(_ command: UpdateRecordCommand) async throws -> AppSnapshot
    /// What the current extraction rules read differently from a confirmed record, or nil.
    func ruleUpdate(recordID: HealthRecord.ID) async throws -> RecordRuleUpdate?
    func applyRuleUpdate(_ command: ApplyRuleUpdateCommand) async throws -> AppSnapshot
    func deleteRecord(id: HealthRecord.ID) async throws -> AppSnapshot
    func deferDraft(_ command: DeferDraftCommand) async throws
    func discardDraft(_ command: DiscardDraftCommand) async throws -> AppSnapshot
    func loadOriginal(
        recordID: HealthRecord.ID,
        sourceID: ReportSource.ID,
        expectedRevision: UInt64,
        expectedLibrary: LibraryRevision
    ) async throws -> OriginalDocumentPayload
}
