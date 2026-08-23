import Foundation
import Testing
@testable import KinlogueApp
@testable import KinlogueCore

@Suite(.serialized)
@MainActor
struct ImportReviewModelTests {
    @Test
    func deferringPersistsTheCurrentReviewBeforeClosing() async throws {
        let fixture = try ReviewFixture()
        let service = AppServiceSpy(snapshot: fixture.snapshot, documents: [fixture.draft.id: fixture.content])
        let model = ImportReviewModel(draftID: fixture.draft.id, service: service)
        let manualDate = Date(timeIntervalSince1970: 1_784_419_200)
        await model.load()
        model.selectedMemberID = fixture.member.id
        model.dateSelectionMode = .manual
        model.manualTimelineDate = manualDate
        model.title = "Edited title"
        model.organization = "Edited organization"
        model.department = "Edited department"
        model.reportType = "Edited report type"
        model.reportedResults = "Edited results"
        model.conclusion = "Edited conclusion"
        model.abnormalItems = ["Edited abnormal item"]
        model.userNote = "Edited note"

        await model.deferReview()

        #expect(await service.deferredCommands == [DeferDraftCommand(
            draftID: fixture.draft.id,
            expectedRevision: fixture.draft.revision,
            memberID: fixture.member.id,
            timelineDateSelection: .manual(manualDate),
            title: "Edited title",
            organization: "Edited organization",
            department: "Edited department",
            reportType: "Edited report type",
            reportedResults: "Edited results",
            conclusion: "Edited conclusion",
            abnormalItems: ["Edited abnormal item"],
            userNote: "Edited note"
        )])
        #expect(await service.discardedDraftIDs.isEmpty)
        #expect(model.isPresented == false)
    }

    @Test
    func reopeningADeferredReviewRestoresAllPersistedEdits() async throws {
        let manualDate = Date(timeIntervalSince1970: 1_784_419_200)
        let canonicalDate = try #require(ReportDateSemantics.canonicalDate(from: manualDate))
        let pickerDate = try #require(ReportDateSemantics.pickerDate(from: canonicalDate))
        let reviewState = ImportDraftReviewState(
            timelineDateSelection: .manual(canonicalDate),
            title: "Saved title",
            organization: "Saved organization",
            department: "Saved department",
            reportType: "Saved report type",
            reportedResults: "Saved results",
            conclusion: "Saved conclusion",
            abnormalItems: ["Saved abnormal item"],
            userNote: "Saved note"
        )
        let fixture = try ReviewFixture(memberID: .fixtureMember, reviewState: reviewState)
        let service = AppServiceSpy(
            snapshot: fixture.snapshot,
            documents: [fixture.draft.id: fixture.content]
        )
        let model = ImportReviewModel(draftID: fixture.draft.id, service: service)

        await model.load()

        #expect(model.selectedMemberID == fixture.member.id)
        #expect(model.dateSelectionMode == .manual)
        #expect(model.manualTimelineDate == pickerDate)
        #expect(model.title == "Saved title")
        #expect(model.organization == "Saved organization")
        #expect(model.department == "Saved department")
        #expect(model.reportType == "Saved report type")
        #expect(model.reportedResults == "Saved results")
        #expect(model.conclusion == "Saved conclusion")
        #expect(model.abnormalItems == ["Saved abnormal item"])
        #expect(model.userNote == "Saved note")
    }

    @Test
    func failedDeferralKeepsTheReviewAndOriginalOpen() async throws {
        let fixture = try ReviewFixture()
        let service = AppServiceSpy(
            snapshot: fixture.snapshot,
            documents: [fixture.draft.id: fixture.content],
            deferError: .vaultUnavailable
        )
        let model = ImportReviewModel(draftID: fixture.draft.id, service: service)
        await model.load()

        await model.deferReview()

        #expect(model.isPresented)
        #expect(model.originalDocument == fixture.content.original)
        #expect(model.errorMessage == AppLocalization.string("稍后处理未保存，请重试"))
    }

    @Test
    func reopeningPreservesFieldsTheUserExplicitlyCleared() async throws {
        let clearedState = ImportDraftReviewState(
            timelineDateSelection: .unknown,
            title: "",
            organization: "",
            department: "",
            reportType: "",
            reportedResults: "",
            conclusion: "",
            abnormalItems: [],
            userNote: ""
        )
        let fixture = try ReviewFixture(reviewState: clearedState)
        let service = AppServiceSpy(
            snapshot: fixture.snapshot,
            documents: [fixture.draft.id: fixture.content]
        )
        let model = ImportReviewModel(draftID: fixture.draft.id, service: service)

        await model.load()

        #expect(model.conclusion.isEmpty)
        #expect(model.abnormalItems.isEmpty)
    }

    @Test
    func explicitRecognitionReplacesCurrentFieldsAndPreservesUserSelections() async throws {
        let savedState = ImportDraftReviewState(
            timelineDateSelection: .unknown,
            title: "Saved title",
            organization: "Saved organization",
            department: "Saved department",
            reportType: "Saved report type",
            reportedResults: "Saved results",
            conclusion: "Saved conclusion",
            abnormalItems: ["Saved abnormal item"],
            userNote: "Saved note"
        )
        let fixture = try ReviewFixture(memberID: .fixtureMember, reviewState: savedState)
        let manualDate = Date(timeIntervalSince1970: 1_784_419_200)
        let canonicalDate = try #require(ReportDateSemantics.canonicalDate(from: manualDate))
        let recognizedDocument = try recognizedDocument(
            timelineDateSelection: .manual(canonicalDate),
            userNote: "Current note"
        )
        let service = AppServiceSpy(
            snapshot: fixture.snapshot,
            documents: [fixture.draft.id: fixture.content],
            recognizedReviews: [fixture.draft.id: RecognizedReviewContent(
                draftRevision: fixture.draft.revision + 1,
                document: recognizedDocument
            )]
        )
        let model = ImportReviewModel(draftID: fixture.draft.id, service: service)
        await model.load()
        model.dateSelectionMode = .manual
        model.manualTimelineDate = manualDate
        model.title = "Current title"
        model.organization = "Current organization"
        model.department = "Current department"
        model.reportType = "Current report type"
        model.reportedResults = "Current results"
        model.conclusion = "Current conclusion"
        model.abnormalItems = ["Current abnormal item"]
        model.userNote = "Current note"

        await model.recognizeAgain()

        #expect(model.selectedMemberID == fixture.member.id)
        #expect(model.dateSelectionMode == .manual)
        #expect(model.manualTimelineDate == ReportDateSemantics.pickerDate(from: canonicalDate))
        #expect(model.title == "Recognized title")
        #expect(model.organization == "Recognized organization")
        #expect(model.department == "Recognized department")
        #expect(model.reportType == "Recognized report type")
        #expect(model.reportedResults == "Recognized results")
        #expect(model.conclusion == "Recognized conclusion")
        #expect(model.abnormalItems == ["Recognized abnormal item"])
        #expect(model.userNote == "Current note")
        #expect(model.fieldSourceDescriptions[.conclusion] != nil)
        #expect(await service.recognizeReviewCommands == [RecognizeReviewCommand(
            draftID: fixture.draft.id,
            expectedRevision: fixture.draft.revision,
            memberID: fixture.member.id,
            timelineDateSelection: .manual(manualDate),
            userNote: "Current note"
        )])

        await model.deferReview()
        #expect(await service.deferredCommands.last?.expectedRevision == fixture.draft.revision + 1)
    }

    @Test
    func explicitRecognitionFailureKeepsCurrentEdits() async throws {
        let fixture = try ReviewFixture()
        let service = AppServiceSpy(
            snapshot: fixture.snapshot,
            documents: [fixture.draft.id: fixture.content],
            recognizeReviewError: .importFailed
        )
        let model = ImportReviewModel(draftID: fixture.draft.id, service: service)
        await model.load()
        model.title = "Current title"
        model.conclusion = "Current conclusion"
        model.userNote = "Current note"

        await model.recognizeAgain()

        #expect(model.title == "Current title")
        #expect(model.conclusion == "Current conclusion")
        #expect(model.userNote == "Current note")
        #expect(model.errorMessage == AppLocalization.string("重新识别失败，当前内容已保留"))
        #expect(!model.isRecognitionInFlight)
    }

    @Test
    func retainedErrorTracksTheSelectedLanguage() async throws {
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
        let fixture = try ReviewFixture()
        let service = AppServiceSpy(
            snapshot: fixture.snapshot,
            documents: [fixture.draft.id: fixture.content],
            recognizeReviewError: .importFailed
        )
        let model = ImportReviewModel(draftID: fixture.draft.id, service: service)
        await model.load()

        await model.recognizeAgain()

        #expect(model.errorMessage == "重新识别失败，当前内容已保留")
        defaults.set(
            AppLanguage.english.rawValue,
            forKey: AppLocalization.languagePreferenceKey
        )
        #expect(model.errorMessage == "Recognition failed. Current fields were kept.")
    }

    @Test
    func closedReviewIgnoresLateRecognitionResult() async throws {
        let fixture = try ReviewFixture()
        let gate = OriginalLoadGate()
        let service = AppServiceSpy(
            snapshot: fixture.snapshot,
            documents: [fixture.draft.id: fixture.content],
            recognizedReviews: [fixture.draft.id: RecognizedReviewContent(
                draftRevision: fixture.draft.revision + 1,
                document: try recognizedDocument()
            )],
            recognizeReviewGate: gate
        )
        let model = ImportReviewModel(draftID: fixture.draft.id, service: service)
        await model.load()
        model.conclusion = "Current conclusion"

        let recognition = Task { await model.recognizeAgain() }
        await gate.waitUntilLoadStarts()
        model.closeReview()
        await gate.open()
        await recognition.value

        #expect(!model.isPresented)
        #expect(model.conclusion == "Current conclusion")
        #expect(model.errorMessage == nil)
    }

    @Test
    func discardRequiresAnExplicitSecondAction() async throws {
        let fixture = try ReviewFixture()
        let service = AppServiceSpy(snapshot: fixture.snapshot, documents: [fixture.draft.id: fixture.content])
        let model = ImportReviewModel(draftID: fixture.draft.id, service: service)
        await model.load()

        model.requestDiscard()
        #expect(model.isDiscardConfirmationPresented)
        #expect(await service.discardedDraftIDs.isEmpty)

        await model.confirmDiscard()
        #expect(await service.discardedDraftIDs == [fixture.draft.id])
        #expect(await service.discardedDraftCommands == [DiscardDraftCommand(
            draftID: fixture.draft.id,
            expectedRevision: fixture.draft.revision
        )])
        #expect(model.isPresented == false)
    }

    @Test
    func confirmationKeepsCorrectionAndUserNoteSeparate() async throws {
        let fixture = try ReviewFixture()
        let service = AppServiceSpy(snapshot: fixture.snapshot, documents: [fixture.draft.id: fixture.content])
        let model = ImportReviewModel(draftID: fixture.draft.id, service: service)
        await model.load()
        model.selectedMemberID = fixture.member.id
        model.conclusion = "Corrected verbatim conclusion"
        model.userNote = "Private user note"

        await model.confirm()

        let command = try #require(await service.confirmedCommands.first)
        #expect(command.conclusion == "Corrected verbatim conclusion")
        #expect(command.userNote == "Private user note")
        #expect(command.memberID == fixture.member.id)
        #expect(command.expectedRevision == fixture.draft.revision)
    }

    @Test
    func confirmationPassesManualDateAndMissingSourceTextAsExplicitUserInput() async throws {
        let fixture = try ReviewFixture()
        let service = AppServiceSpy(snapshot: fixture.snapshot, documents: [fixture.draft.id: fixture.content])
        let model = ImportReviewModel(draftID: fixture.draft.id, service: service)
        let manualDate = Date(timeIntervalSince1970: 1_784_332_800)
        await model.load()
        model.selectedMemberID = fixture.member.id
        model.dateSelectionMode = .manual
        model.manualTimelineDate = manualDate
        model.reportedResults = "Manually transcribed result"
        model.conclusion = "Manually transcribed conclusion"

        await model.confirm()

        let command = try #require(await service.confirmedCommands.first)
        #expect(command.timelineDateSelection == .manual(manualDate))
        #expect(command.reportedResults == "Manually transcribed result")
        #expect(command.conclusion == "Manually transcribed conclusion")
        #expect(command.userNote.isEmpty)
    }

    @Test
    func confirmationRequiresAMemberButAllowsUnknownDate() async throws {
        let fixture = try ReviewFixture()
        let service = AppServiceSpy(snapshot: fixture.snapshot, documents: [fixture.draft.id: fixture.content])
        let model = ImportReviewModel(draftID: fixture.draft.id, service: service)
        await model.load()

        await model.confirm()

        #expect(model.errorMessage == AppLocalization.string("请选择家庭成员"))
        #expect(await service.confirmedCommands.isEmpty)
    }

    @Test
    func reviewDoesNotSilentlySelectTheFirstDetectedDate() async throws {
        let fixture = try ReviewFixture(includeDate: true)
        let service = AppServiceSpy(snapshot: fixture.snapshot, documents: [fixture.draft.id: fixture.content])
        let model = ImportReviewModel(draftID: fixture.draft.id, service: service)

        await model.load()

        #expect(!model.dateCandidates.isEmpty)
        #expect(model.dateSelectionMode == .unknown)
    }

    @Test
    func aClosedReviewDoesNotRepopulateItsReleasedOriginal() async throws {
        let fixture = try ReviewFixture()
        let service = AppServiceSpy(
            snapshot: fixture.snapshot,
            documents: [fixture.draft.id: fixture.content]
        )
        let model = ImportReviewModel(draftID: fixture.draft.id, service: service)
        model.closeReview()

        await model.load()

        #expect(model.isPresented == false)
        #expect(model.originalDocument == nil)
    }

    @Test
    func aReviewThatCannotLoadHasAnExplicitSafeClosePath() async throws {
        let fixture = try ReviewFixture()
        let service = AppServiceSpy(snapshot: fixture.snapshot)
        let model = ImportReviewModel(draftID: fixture.draft.id, service: service)

        await model.load()

        #expect(model.loadFailed)
        #expect(model.errorMessage == AppLocalization.string("待确认内容暂时无法打开"))
        #expect(model.isPresented)

        model.closeReview()

        #expect(!model.isPresented)
    }

    @Test
    func provenancePagesFollowCurrentMultiOriginalOrderInReviewAndRecordPresentation() async throws {
        let member = try FamilyMember(displayName: "Synthetic member")
        let first = try ReportSource(
            attachmentID: UUID(),
            displayName: "first.pdf",
            pageCount: 2
        )
        let second = try ReportSource(
            attachmentID: UUID(),
            displayName: "second.png",
            pageCount: 1
        )
        let forward = try ReportSources([first, second])
        let reversed = try ReportSources([second, first])
        let block = try OCRBlock(
            sourceID: second.id,
            attachmentID: second.attachmentID,
            filePageNumber: 1,
            text: "Synthetic conclusion",
            boundingBox: NormalizedRect(x: 0.1, y: 0.7, width: 0.4, height: 0.1),
            confidence: 1,
            method: .vision,
            engineVersion: "synthetic"
        )
        let reference = try SourceReference(
            sourceID: second.id,
            attachmentID: second.attachmentID,
            filePageNumber: 1,
            boundingBox: block.boundingBox,
            blockID: block.id
        )
        let conclusion = try SourceField(
            originalTranscription: "Synthetic conclusion",
            references: [reference]
        )
        let draft = ImportDraft(
            sources: forward,
            state: .needsReview,
            documentObjectID: UUID()
        )
        let content = ImportReviewContent(
            draft: draft,
            document: ImportDraftDocument(
                blocks: [block],
                candidates: ReportCandidates(conclusion: conclusion)
            ),
            members: [member],
            original: OriginalDocumentPayload(
                data: Data([1]),
                contentTypeIdentifier: "public.png"
            )
        )
        let service = AppServiceSpy(
            snapshot: AppSnapshot(
                members: [member],
                records: [],
                drafts: [DraftSummary(draft: draft)]
            ),
            documents: [draft.id: content]
        )
        let model = ImportReviewModel(draftID: draft.id, service: service)

        await model.load()

        #expect(
            model.fieldSourceDescriptions[.conclusion]?.contains(
                AppLocalization.string("，第 \("3") 页")
            ) == true
        )
        #expect(conclusion.sourcePageNumbersDescription(for: forward) == "3")
        #expect(conclusion.sourcePageNumbersDescription(for: reversed) == "1")
    }

    @Test
    func reviewNavigatesOrderedOriginalsWithoutReplacingClinicalFields() async throws {
        let member = try FamilyMember(displayName: "Synthetic member")
        let first = try ReportSource(
            attachmentID: UUID(),
            displayName: "first.png",
            pageCount: 1
        )
        let second = try ReportSource(
            attachmentID: UUID(),
            displayName: "second.png",
            pageCount: 1
        )
        let draft = ImportDraft(
            sources: try ReportSources([first, second]),
            state: .needsReview,
            documentObjectID: UUID()
        )
        let content = ImportReviewContent(
            draft: draft,
            document: ImportDraftDocument(
                blocks: [],
                candidates: ReportCandidates(
                    conclusion: try SourceField(originalTranscription: "Synthetic conclusion")
                )
            ),
            members: [member],
            original: OriginalDocumentPayload(
                data: Data([1]),
                contentTypeIdentifier: "public.png"
            )
        )
        let service = AppServiceSpy(
            snapshot: AppSnapshot(
                members: [member],
                records: [],
                drafts: [DraftSummary(draft: draft)]
            ),
            documents: [draft.id: content],
            reviewSourceOriginals: [second.id: OriginalDocumentPayload(
                data: Data([2]),
                contentTypeIdentifier: "public.png"
            )]
        )
        let model = ImportReviewModel(draftID: draft.id, service: service)

        await model.load()
        model.conclusion = "Manual correction"
        await model.selectOriginalSource(second.id)

        #expect(model.originalSources?.elements.map(\.id) == [first.id, second.id])
        #expect(model.selectedOriginalSourceID == second.id)
        #expect(model.originalDocument?.data == Data([2]))
        #expect(model.conclusion == "Manual correction")
        #expect(await service.reviewSourceOriginalLoadCallIDs == [second.id])
    }
}

private enum ReviewMemberSelection: Equatable {
    case none
    case fixtureMember
}

private struct ReviewFixture {
    let member: FamilyMember
    let attachment: KinlogueCore.Attachment
    let draft: ImportDraft
    let content: ImportReviewContent
    let snapshot: AppSnapshot

    init(
        includeDate: Bool = false,
        memberID: ReviewMemberSelection = .none,
        reviewState: ImportDraftReviewState? = nil
    ) throws {
        member = try FamilyMember(displayName: "Synthetic member")
        attachment = try KinlogueCore.Attachment(
            contentTypeIdentifier: "public.png",
            byteCount: 4,
            sha256Digest: Data(repeating: 3, count: 32)
        )
        draft = ImportDraft(
            attachmentID: attachment.id,
            state: .needsReview,
            documentObjectID: UUID(),
            memberID: memberID == .fixtureMember ? member.id : nil
        )
        content = ImportReviewContent(
            draft: draft,
            document: ImportDraftDocument(
                blocks: [],
                candidates: ReportCandidates(
                    dateCandidates: includeDate ? [ReportDateCandidate(
                        date: Date(timeIntervalSince1970: 1_700_000_000),
                        kind: .report,
                        source: try SourceField(originalTranscription: "Synthetic date")
                    )] : [],
                    conclusion: try SourceField(originalTranscription: "OCR conclusion")
                ),
                reviewState: reviewState
            ),
            members: [member],
            original: OriginalDocumentPayload(
                data: Data([1, 2, 3, 4]),
                contentTypeIdentifier: "public.png"
            )
        )
        snapshot = AppSnapshot(members: [member], records: [], drafts: [DraftSummary(draft: draft)])
    }
}

private func recognizedDocument(
    timelineDateSelection: ImportDraftTimelineDateSelection = .unknown,
    userNote: String = ""
) throws -> ImportDraftDocument {
    let block = try OCRBlock(
        pageNumber: 1,
        text: "Synthetic recognized source",
        boundingBox: NormalizedRect(x: 0.1, y: 0.7, width: 0.4, height: 0.1),
        confidence: 1,
        method: .vision,
        engineVersion: "synthetic"
    )
    let reference = try SourceReference(
        pageNumber: 1,
        boundingBox: block.boundingBox,
        blockID: block.id
    )
    let candidates = ReportCandidates(
        organization: try SourceField(
            originalTranscription: "Recognized organization",
            references: [reference]
        ),
        department: try SourceField(
            originalTranscription: "Recognized department",
            references: [reference]
        ),
        reportType: try SourceField(
            originalTranscription: "Recognized report type",
            references: [reference]
        ),
        title: try SourceField(
            originalTranscription: "Recognized title",
            references: [reference]
        ),
        reportedResults: try SourceField(
            originalTranscription: "Recognized results",
            references: [reference]
        ),
        conclusion: try SourceField(
            originalTranscription: "Recognized conclusion",
            references: [reference]
        ),
        abnormalItems: [try SourceField(
            originalTranscription: "Recognized abnormal item",
            references: [reference]
        )]
    )
    return ImportDraftDocument(
        blocks: [block],
        candidates: candidates,
        reviewState: ImportDraftReviewState(
            timelineDateSelection: timelineDateSelection,
            title: "Recognized title",
            organization: "Recognized organization",
            department: "Recognized department",
            reportType: "Recognized report type",
            reportedResults: "Recognized results",
            conclusion: "Recognized conclusion",
            abnormalItems: ["Recognized abnormal item"],
            userNote: userNote
        )
    )
}
