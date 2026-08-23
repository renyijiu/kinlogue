import Foundation
import Testing
@testable import KinlogueApp
@testable import KinlogueCore

@MainActor
struct AppModelTests {
    @Test
    func bootstrapBuildsConfirmedTimelineAndKeepsDraftsSeparate() async throws {
        let fixture = try AppFixture()
        let service = AppServiceSpy(snapshot: fixture.snapshot)
        let model = AppModel(service: service)

        await model.start()

        #expect(model.phase == .ready)
        #expect(model.members.map(\.id) == [fixture.member.id])
        #expect(model.timelineSections.flatMap(\.records).map(\.id) == [fixture.confirmed.id])
        #expect(model.reviewQueue.map(\.id) == [fixture.draft.id])
        #expect(model.searchResults.isEmpty)
    }

    @Test
    func searchOnlyUsesConfirmedCatalogProjection() async throws {
        let fixture = try AppFixture()
        let service = AppServiceSpy(snapshot: fixture.snapshot)
        let model = AppModel(service: service)
        await model.start()
        await model.selectRecord(fixture.confirmed.id)

        model.searchText = "Confirmed anchor"

        #expect(model.searchResults.map(\.id) == [fixture.confirmed.id])
        model.searchText = "Unconfirmed anchor"
        #expect(model.searchResults.isEmpty)
    }

    @Test
    func searchTracksTheSelectedFamilyMemberAndClearsThePreviousDetail() async throws {
        let firstMember = try FamilyMember(displayName: "First synthetic member")
        let secondMember = try FamilyMember(displayName: "Second synthetic member")
        let firstRecord = try HealthRecord(
            memberID: firstMember.id,
            attachmentID: UUID(),
            importState: .confirmed,
            conclusion: try SourceField(originalTranscription: "Shared synthetic conclusion")
        )
        let secondRecord = try HealthRecord(
            memberID: secondMember.id,
            attachmentID: UUID(),
            importState: .confirmed,
            conclusion: try SourceField(originalTranscription: "Shared synthetic conclusion")
        )
        let service = AppServiceSpy(
            snapshot: AppSnapshot(
                members: [firstMember, secondMember],
                records: [firstRecord, secondRecord],
                drafts: []
            ),
            originals: [
                firstRecord.id: OriginalDocumentPayload(
                    data: Data([0x25, 0x50, 0x44, 0x46]),
                    contentTypeIdentifier: "com.adobe.pdf"
                )
            ]
        )
        let model = AppModel(service: service)
        await model.start()
        model.searchText = "Shared"
        #expect(Set(model.searchResults.map(\.id)) == Set([firstRecord.id, secondRecord.id]))

        model.selectedMemberID = firstMember.id
        #expect(model.searchResults.map(\.id) == [firstRecord.id])
        await model.selectRecord(firstRecord.id)
        #expect(model.selectedRecord?.id == firstRecord.id)

        model.selectedMemberID = secondMember.id
        #expect(model.searchResults.map(\.id) == [secondRecord.id])
        #expect(model.selectedRecord == nil)

        model.selectedMemberID = nil
        #expect(Set(model.searchResults.map(\.id)) == Set([firstRecord.id, secondRecord.id]))
    }

    @Test
    func importerCancellationDoesNotInvokeTheService() async throws {
        let service = AppServiceSpy(snapshot: .empty)
        let model = AppModel(service: service)

        await model.handleImporterResult(.failure(CocoaError(.userCancelled)))

        #expect(await service.importCallCount == 0)
        #expect(model.banner == nil)
    }

    @Test
    func importingRefreshesTheSnapshotAndOpensReview() async throws {
        let fixture = try AppFixture()
        let service = AppServiceSpy(
            snapshot: .empty,
            importOutcomes: [.needsReview(fixture.draft.id)],
            refreshedSnapshot: fixture.snapshot
        )
        let model = AppModel(service: service)

        await model.handleImporterResult(.success([URL(fileURLWithPath: "/synthetic/input.pdf")]))

        #expect(await service.importCallCount == 1)
        #expect(model.reviewDraftID == fixture.draft.id)
        #expect(model.reviewQueue.map(\.id) == [fixture.draft.id])
    }

    @Test
    func primaryPresentationsAreMutuallyExclusiveAndReviewRequiresAQueuedDraft() async throws {
        let fixture = try AppFixture()
        let model = AppModel(service: AppServiceSpy(snapshot: fixture.snapshot))
        await model.start()

        model.presentReviewDraft(UUID())
        #expect(model.reviewingDraft == nil)

        model.presentNewMemberEditor()
        #expect(model.isMemberEditorPresented)
        model.presentReviewDraft(fixture.draft.id)
        #expect(model.reviewingDraft == nil)

        model.isMemberEditorPresented = false
        model.presentReviewDraft(fixture.draft.id)
        #expect(model.reviewDraftID == fixture.draft.id)
        model.presentImporter()
        #expect(!model.isImporterPresented)

        model.reviewingDraft = nil
        model.isVaultDeletionPresented = true
        model.presentReviewDraft(fixture.draft.id)
        #expect(model.reviewingDraft == nil)
        model.presentImporter()
        #expect(!model.isImporterPresented)

        model.isVaultDeletionPresented = false
        model.presentImporter()
        #expect(model.isImporterPresented)
    }

    @Test
    func backgroundErrorsWaitUntilTheActiveSheetHasClosed() async throws {
        let member = try FamilyMember(displayName: "Synthetic deferred error member")
        let model = AppModel(service: UnavailableAppService())
        model.isVaultDeletionPresented = true

        await model.archiveMember(member)

        #expect(model.banner == nil)
        model.isVaultDeletionPresented = false
        model.presentationDidEnd()
        #expect(model.banner?.message == AppLocalization.string("无法归档家庭成员"))
    }

    @Test
    func automaticReviewWaitsUntilTheActiveSheetHasClosed() async throws {
        let fixture = try AppFixture()
        let service = AppServiceSpy(
            snapshot: fixture.snapshot,
            importOutcomes: [.needsReview(fixture.draft.id)]
        )
        let model = AppModel(service: service)
        await model.start()
        model.isVaultDeletionPresented = true

        await model.retryDraft(fixture.draft.id)

        #expect(model.reviewingDraft == nil)
        model.isVaultDeletionPresented = false
        model.presentationDidEnd()
        #expect(model.reviewDraftID == fixture.draft.id)
    }

    @Test
    func mixedImportShowsItsErrorThenPresentsThePendingReview() async throws {
        let fixture = try AppFixture()
        let service = AppServiceSpy(
            snapshot: .empty,
            importOutcomes: [.needsReview(fixture.draft.id), .failed(.damagedFile)],
            refreshedSnapshot: fixture.snapshot
        )
        let model = AppModel(service: service)

        await model.handleImporterResult(.success([
            URL(fileURLWithPath: "/synthetic/review.pdf"),
            URL(fileURLWithPath: "/synthetic/damaged.pdf"),
        ]))

        #expect(model.banner?.message == AppLocalization.string("文件无法读取"))
        #expect(model.reviewingDraft == nil)

        model.dismissBanner()

        #expect(model.reviewDraftID == fixture.draft.id)
    }

    @Test
    func editorSaveFailuresStayInsideTheEditorInsteadOfOpeningARootAlert() async {
        let model = AppModel(service: UnavailableAppService())

        let saved = await model.createMember(
            displayName: "Synthetic unavailable member",
            disambiguationLabel: nil
        )

        #expect(!saved)
        #expect(model.banner == nil)
    }

    @Test
    func recordEditorPresentationAlwaysCarriesASelectedRecordPayload() async throws {
        let fixture = try AppFixture()
        let service = AppServiceSpy(
            snapshot: fixture.snapshot,
            originals: [fixture.confirmed.id: OriginalDocumentPayload(
                data: Data([0x25, 0x50, 0x44, 0x46]),
                contentTypeIdentifier: "com.adobe.pdf"
            )]
        )
        let model = AppModel(service: service)
        await model.start()

        model.presentRecordEditor()
        #expect(model.editingRecord == nil)

        await model.selectRecord(fixture.confirmed.id)
        model.presentRecordEditor()
        #expect(model.editingRecord?.id == fixture.confirmed.id)

        model.clearSelection()
        #expect(model.editingRecord == nil)
    }

    @Test
    func originalViewerRequiresALoadedSelectionAndBlocksOtherPresentations() async throws {
        let fixture = try AppFixture()
        let payload = OriginalDocumentPayload(
            data: Data([0x89, 0x50, 0x4E, 0x47]),
            contentTypeIdentifier: "public.png"
        )
        let service = AppServiceSpy(
            snapshot: fixture.snapshot,
            originals: [fixture.confirmed.id: payload]
        )
        let model = AppModel(service: service)
        await model.start()

        model.presentOriginalViewer()
        #expect(model.viewingOriginal == nil)

        await model.selectRecord(fixture.confirmed.id)
        model.presentOriginalViewer()

        #expect(model.viewingOriginal?.id == fixture.confirmed.id)
        model.presentRecordEditor()
        #expect(model.editingRecord == nil)
        model.presentImporter()
        #expect(!model.isImporterPresented)

        model.viewingOriginal = nil
        model.presentationDidEnd()
        model.presentRecordEditor()
        #expect(model.editingRecord?.id == fixture.confirmed.id)

        model.editingRecord = nil
        model.presentationDidEnd()
        model.presentOriginalViewer()
        #expect(model.viewingOriginal != nil)
        model.clearSelection()
        #expect(model.viewingOriginal == nil)

        await model.selectRecord(fixture.confirmed.id)
        model.presentOriginalViewer()
        #expect(model.viewingOriginal != nil)
        await model.beginDestructiveVaultLifecycle()
        #expect(model.viewingOriginal == nil)
    }

    @Test
    func refreshRemovingAQueuedDraftDismissesItsReviewPresentation() async throws {
        let fixture = try AppFixture()
        let refreshed = AppSnapshot(
            generation: fixture.snapshot.generation + 1,
            members: fixture.snapshot.members,
            records: fixture.snapshot.records,
            drafts: []
        )
        let model = AppModel(service: AppServiceSpy(
            snapshot: fixture.snapshot,
            refreshedSnapshot: refreshed
        ))
        await model.start()
        model.presentReviewDraft(fixture.draft.id)
        #expect(model.reviewDraftID == fixture.draft.id)

        await model.refresh()

        #expect(model.reviewingDraft == nil)
        #expect(model.reviewQueue.isEmpty)
    }

    @Test
    func selectingAConfirmedRecordLoadsOriginalOnlyInMemory() async throws {
        let fixture = try AppFixture()
        let bytes = Data([0x25, 0x50, 0x44, 0x46])
        let service = AppServiceSpy(
            snapshot: fixture.snapshot,
            originals: [fixture.confirmed.id: OriginalDocumentPayload(
                data: bytes,
                contentTypeIdentifier: "com.adobe.pdf"
            )]
        )
        let model = AppModel(service: service)
        await model.start()

        await model.selectRecord(fixture.confirmed.id)

        #expect(model.selectedRecord?.id == fixture.confirmed.id)
        #expect(model.originalDocument?.data == bytes)
        model.clearSelection()
        #expect(model.originalDocument == nil)
    }

    @Test
    func selectionKeepsTheDetailEmptyUntilTheOriginalIsReady() async throws {
        let fixture = try AppFixture()
        let bytes = Data([0x25, 0x50, 0x44, 0x46])
        let originalLoadGate = OriginalLoadGate()
        let service = AppServiceSpy(
            snapshot: fixture.snapshot,
            originals: [fixture.confirmed.id: OriginalDocumentPayload(
                data: bytes,
                contentTypeIdentifier: "com.adobe.pdf"
            )],
            originalLoadGate: originalLoadGate
        )
        let model = AppModel(service: service)
        await model.start()

        let selection = Task { await model.selectRecord(fixture.confirmed.id) }
        await originalLoadGate.waitUntilLoadStarts()

        #expect(model.isOriginalLoading)
        #expect(model.selectedRecord == nil)
        #expect(model.originalDocument == nil)

        await originalLoadGate.open()
        await selection.value
        #expect(!model.isOriginalLoading)
        #expect(model.selectedRecord?.id == fixture.confirmed.id)
        #expect(model.originalDocument?.data == bytes)
    }

    @Test
    func newerSelectionPublishesOnlyItsMatchingRecordAndOriginal() async throws {
        let firstMember = try FamilyMember(displayName: "First selection member")
        let secondMember = try FamilyMember(displayName: "Second selection member")
        let firstRecord = try HealthRecord(
            memberID: firstMember.id,
            attachmentID: UUID(),
            importState: .confirmed,
            conclusion: try SourceField(originalTranscription: "First synthetic record")
        )
        let secondRecord = try HealthRecord(
            memberID: secondMember.id,
            attachmentID: UUID(),
            importState: .confirmed,
            conclusion: try SourceField(originalTranscription: "Second synthetic record")
        )
        let firstBytes = Data([1])
        let secondBytes = Data([2])
        let service = AppServiceSpy(
            snapshot: AppSnapshot(
                members: [firstMember, secondMember],
                records: [firstRecord, secondRecord],
                drafts: []
            ),
            originals: [
                firstRecord.id: OriginalDocumentPayload(
                    data: firstBytes,
                    contentTypeIdentifier: "public.png"
                ),
                secondRecord.id: OriginalDocumentPayload(
                    data: secondBytes,
                    contentTypeIdentifier: "public.png"
                )
            ],
            originalLoadDelays: [
                firstRecord.id: .milliseconds(500),
                secondRecord.id: .milliseconds(50)
            ],
            ignoresOriginalLoadCancellation: true
        )
        let model = AppModel(service: service)
        await model.start()

        let firstSelection = Task { await model.selectRecord(firstRecord.id) }
        while await service.originalLoadCallIDs.count < 1 { await Task.yield() }
        let secondSelection = Task { await model.selectRecord(secondRecord.id) }
        while await service.originalLoadCallIDs.count < 2 { await Task.yield() }

        #expect(model.isOriginalLoading)
        #expect(model.selectedRecord == nil)
        #expect(model.originalDocument == nil)

        await secondSelection.value
        #expect(!model.isOriginalLoading)
        #expect(model.selectedRecord?.id == secondRecord.id)
        #expect(model.originalDocument?.data == secondBytes)

        await firstSelection.value
        #expect(model.selectedRecord?.id == secondRecord.id)
        #expect(model.originalDocument?.data == secondBytes)
    }

    @Test
    func refreshFailureClearsPreviouslyLoadedStateAndLocksTheUI() async throws {
        let fixture = try AppFixture()
        let bytes = Data([0x25, 0x50, 0x44, 0x46])
        let service = AppServiceSpy(
            snapshot: fixture.snapshot,
            refreshError: .vaultUnavailable,
            originals: [fixture.confirmed.id: OriginalDocumentPayload(
                data: bytes,
                contentTypeIdentifier: "com.adobe.pdf"
            )]
        )
        let model = AppModel(service: service)
        await model.start()
        await model.selectRecord(fixture.confirmed.id)
        #expect(model.originalDocument?.data == bytes)

        await model.refresh()

        #expect(model.phase == .locked)
        #expect(model.members.isEmpty)
        #expect(model.timelineSections.isEmpty)
        #expect(model.selectedRecord == nil)
        #expect(model.originalDocument == nil)
    }

    @Test
    func anOlderRefreshCannotUnlockTheUIAfterANewerRefreshFails() async throws {
        let fixture = try AppFixture()
        let service = OutOfOrderRefreshService(snapshot: fixture.snapshot)
        let model = AppModel(service: service)
        await model.start()

        let olderRefresh = Task { await model.refresh() }
        while await service.refreshCallCount == 0 { await Task.yield() }

        await model.refresh()
        #expect(model.phase == .locked)
        #expect(model.members.isEmpty)

        await service.completeOlderRefresh()
        await olderRefresh.value

        #expect(model.phase == .locked)
        #expect(model.members.isEmpty)
        #expect(model.timelineSections.isEmpty)
    }

    @Test
    func beginningWholeVaultLifecycleClearsDataAndRejectsLateSnapshots() async throws {
        let fixture = try AppFixture()
        let service = OutOfOrderRefreshService(snapshot: fixture.snapshot)
        let model = AppModel(service: service)
        await model.start()

        let refresh = Task { await model.refresh() }
        while await service.refreshCallCount == 0 { await Task.yield() }

        await model.beginDestructiveVaultLifecycle()
        #expect(model.phase == .changingVault)
        #expect(model.members.isEmpty)
        #expect(model.timelineSections.isEmpty)
        #expect(model.selectedRecord == nil)
        #expect(model.originalDocument == nil)

        await service.completeOlderRefresh()
        await refresh.value

        #expect(model.phase == .changingVault)
        #expect(model.members.isEmpty)
        #expect(model.timelineSections.isEmpty)

        model.requireRestartAfterVaultLifecycle()
        #expect(model.phase == .restartRequired)
        await model.refresh()
        #expect(model.phase == .restartRequired)
    }

    @Test
    func completedWholeVaultDeletionRemainsTerminalUntilProcessRestart() async throws {
        let fixture = try AppFixture()
        let service = AppServiceSpy(snapshot: fixture.snapshot)
        let model = AppModel(service: service)
        await model.start()

        await model.beginDestructiveVaultLifecycle()
        model.finishVaultDeletion()

        #expect(model.phase == .vaultDeleted)
        #expect(model.members.isEmpty)
        await model.start()
        #expect(model.phase == .vaultDeleted)
        #expect(model.members.isEmpty)
    }

    @Test
    func failedDraftRemainsVisibleForRetryButCannotOpenAsReview() async throws {
        let attachmentID = UUID()
        let failed = ImportDraft(
            attachmentID: attachmentID,
            state: .failed,
            revision: 1,
            failureCode: .textExtractionFailed
        )
        let service = AppServiceSpy(snapshot: AppSnapshot(
            members: [],
            records: [],
            drafts: [DraftSummary(draft: failed)]
        ))
        let model = AppModel(service: service)

        await model.start()

        #expect(model.reviewQueue.isEmpty)
        #expect(model.backgroundDrafts.map(\.id) == [failed.id])
        #expect(model.reviewDraftID == nil)
    }

    @Test
    func failedRetryOutcomeProducesAStableNonClinicalMessage() async throws {
        let failed = ImportDraft(
            attachmentID: UUID(),
            state: .failed,
            revision: 1,
            failureCode: .textExtractionFailed
        )
        let snapshot = AppSnapshot(
            members: [],
            records: [],
            drafts: [DraftSummary(draft: failed)]
        )
        let service = AppServiceSpy(
            snapshot: snapshot,
            importOutcomes: [.failed(.importFailed)],
            refreshedSnapshot: snapshot
        )
        let model = AppModel(service: service)
        await model.start()

        await model.retryDraft(failed.id)

        #expect(model.banner?.message == AppLocalization.string("导入未完成，可以稍后重试"))
        #expect(model.reviewDraftID == nil)
    }

    @Test
    func failedDraftDiscardUsesTheCapturedIDEvenAfterTheDialogDismisses() async throws {
        let failed = ImportDraft(
            attachmentID: UUID(),
            state: .failed,
            revision: 1,
            failureCode: .textExtractionFailed
        )
        let snapshot = AppSnapshot(
            members: [],
            records: [],
            drafts: [DraftSummary(draft: failed)]
        )
        let service = AppServiceSpy(snapshot: snapshot)
        let model = AppModel(service: service)
        await model.start()
        model.requestDiscardDraft(failed.id)
        #expect(model.pendingDiscardDraftID == failed.id)

        model.pendingDiscardDraftID = nil
        await model.confirmDiscardDraft(id: failed.id)

        #expect(await service.discardedDraftIDs == [failed.id])
        #expect(await service.discardedDraftCommands == [DiscardDraftCommand(
            draftID: failed.id,
            expectedRevision: failed.revision
        )])
    }

    @Test
    func aNewDiscardDialogReplacesTheCancelledDraftCommand() async throws {
        let first = ImportDraft(
            attachmentID: UUID(),
            state: .failed,
            revision: 1,
            failureCode: .textExtractionFailed
        )
        let second = ImportDraft(
            attachmentID: UUID(),
            state: .failed,
            revision: 7,
            failureCode: .textExtractionFailed
        )
        let service = AppServiceSpy(snapshot: AppSnapshot(
            members: [],
            records: [],
            drafts: [DraftSummary(draft: first), DraftSummary(draft: second)]
        ))
        let model = AppModel(service: service)
        await model.start()

        model.requestDiscardDraft(first.id)
        model.pendingDiscardDraftID = nil
        model.requestDiscardDraft(second.id)
        await model.confirmDiscardDraft(id: first.id)
        await model.confirmDiscardDraft(id: second.id)

        #expect(await service.discardedDraftCommands == [DiscardDraftCommand(
            draftID: second.id,
            expectedRevision: second.revision
        )])
    }

    @Test
    func anOlderSnapshotCannotOverwriteNewerVisibleState() async throws {
        let fixture = try AppFixture()
        let newer = AppSnapshot(
            generation: 3,
            members: fixture.snapshot.members,
            records: fixture.snapshot.records,
            drafts: fixture.snapshot.drafts
        )
        let older = AppSnapshot(generation: 2, members: [], records: [], drafts: [])
        let service = AppServiceSpy(snapshot: newer, refreshedSnapshot: older)
        let model = AppModel(service: service)
        await model.start()

        await model.refresh()

        #expect(model.members.map(\.id) == [fixture.member.id])
        #expect(model.timelineSections.flatMap(\.records).map(\.id) == [fixture.confirmed.id])
    }

    @Test
    func aNewDurableCatalogGenerationTriggersBackupSchedulingAfterBootstrap() async throws {
        let fixture = try AppFixture()
        let initial = AppSnapshot(
            generation: 7,
            members: fixture.snapshot.members,
            records: fixture.snapshot.records,
            drafts: fixture.snapshot.drafts
        )
        let refreshed = AppSnapshot(
            generation: 8,
            members: fixture.snapshot.members,
            records: fixture.snapshot.records,
            drafts: fixture.snapshot.drafts
        )
        let service = AppServiceSpy(snapshot: initial, refreshedSnapshot: refreshed)
        var durableStateChangeCount = 0
        let model = AppModel(service: service, onDurableStateChanged: {
            durableStateChangeCount += 1
        })

        await model.start()
        #expect(durableStateChangeCount == 0)

        await model.refresh()

        #expect(durableStateChangeCount == 1)
    }

    @Test
    func recordUpdateAPIHasNoAttachmentMutationSurface() async throws {
        let fixture = try AppFixture()
        let service = AppServiceSpy(snapshot: fixture.snapshot)
        let model = AppModel(service: service)
        await model.start()
        let command = UpdateRecordCommand(
            recordID: fixture.confirmed.id,
            expectedRevision: fixture.confirmed.revision,
            memberID: fixture.member.id,
            timelineDateSelection: .unknown,
            title: "",
            organization: "",
            department: "",
            reportType: "",
            reportedResults: "",
            conclusion: "Corrected source",
            abnormalItems: [],
            userNote: "Separate note"
        )

        #expect(await model.updateRecord(command) == .saved)

        #expect(await service.updatedCommands == [command])
        #expect(model.selectedRecord?.soleAttachmentID == fixture.attachment.id)
    }

    @Test
    func recordUpdateReportsARevisionConflictWithoutClosingTheEditor() async throws {
        let fixture = try AppFixture()
        let latest = try HealthRecord(
            id: fixture.confirmed.id,
            memberID: fixture.member.id,
            sources: fixture.confirmed.sources,
            importState: .confirmed,
            revision: fixture.confirmed.revision + 1,
            title: try SourceField(originalTranscription: "Latest external title")
        )
        let service = AppServiceSpy(
            snapshot: fixture.snapshot,
            refreshedSnapshot: AppSnapshot(
                generation: fixture.snapshot.generation + 1,
                members: fixture.snapshot.members,
                records: [fixture.draftRecord, latest],
                drafts: fixture.snapshot.drafts
            ),
            originals: [fixture.confirmed.id: OriginalDocumentPayload(
                data: Data("synthetic-conflict-original".utf8),
                contentTypeIdentifier: "public.png"
            )],
            recordUpdateError: .recordChanged
        )
        let model = AppModel(service: service)
        await model.start()
        await model.selectRecord(fixture.confirmed.id)
        model.presentRecordEditor()
        let command = UpdateRecordCommand(
            recordID: fixture.confirmed.id,
            expectedRevision: fixture.confirmed.revision,
            memberID: fixture.member.id,
            timelineDateSelection: .unknown,
            title: "Unsaved local title",
            organization: "",
            department: "",
            reportType: "",
            reportedResults: "",
            conclusion: "",
            abnormalItems: [],
            userNote: ""
        )

        #expect(await model.updateRecord(command) == .recordChanged(latest: latest))
        #expect(model.editingRecord?.id == fixture.confirmed.id)
        #expect(model.timelineSections.flatMap(\.records).first { $0.id == latest.id } == latest)
        #expect(await service.updatedCommands == [command])
    }

    @Test
    func recordUpdateConflictWithoutARefreshableLatestRecordRemainsExplicit() async throws {
        let fixture = try AppFixture()
        let service = AppServiceSpy(
            snapshot: fixture.snapshot,
            refreshError: .vaultUnavailable,
            recordUpdateError: .recordChanged
        )
        let model = AppModel(service: service)
        await model.start()
        let command = UpdateRecordCommand(
            recordID: fixture.confirmed.id,
            expectedRevision: fixture.confirmed.revision,
            memberID: fixture.member.id,
            timelineDateSelection: .unknown,
            title: "Unsaved local title",
            organization: "",
            department: "",
            reportType: "",
            reportedResults: "",
            conclusion: "",
            abnormalItems: [],
            userNote: ""
        )

        #expect(await model.updateRecord(command) == .recordChanged(latest: nil))
        #expect(await service.updatedCommands == [command])
    }

    @Test
    func deletingTheSelectedRecordReleasesItsOriginalBeforeTheServiceReturns() async throws {
        let fixture = try AppFixture()
        let deletedSnapshot = AppSnapshot(
            generation: fixture.snapshot.generation + 1,
            members: fixture.snapshot.members,
            records: [fixture.draftRecord],
            drafts: fixture.snapshot.drafts
        )
        let service = AppServiceSpy(
            snapshot: fixture.snapshot,
            originals: [fixture.confirmed.id: OriginalDocumentPayload(
                data: Data([0x25, 0x50, 0x44, 0x46]),
                contentTypeIdentifier: "com.adobe.pdf"
            )],
            recordDeletionSnapshot: deletedSnapshot,
            recordDeletionDelay: .milliseconds(200)
        )
        let model = AppModel(service: service)
        await model.start()
        await model.selectRecord(fixture.confirmed.id)
        #expect(model.originalDocument != nil)
        model.requestDeleteRecord(fixture.confirmed)

        let deletion = Task {
            await model.confirmDeleteRecord(id: fixture.confirmed.id)
        }
        while await service.deletedRecordIDs.isEmpty { await Task.yield() }

        #expect(model.selectedRecord == nil)
        #expect(model.originalDocument == nil)
        #expect(!model.isOriginalLoading)
        #expect(model.pendingDeleteRecordID == nil)

        await deletion.value
        #expect(model.timelineSections.flatMap(\.records).isEmpty)
        #expect(await service.deletedRecordIDs == [fixture.confirmed.id])
    }

    @Test
    func referencedMemberDeletionShowsOnlyCountsAndActionableGuidance() async throws {
        let fixture = try AppFixture()
        let service = AppServiceSpy(
            snapshot: fixture.snapshot,
            memberDeletionError: .memberStillReferenced(recordCount: 2, draftCount: 1)
        )
        let model = AppModel(service: service)
        await model.start()
        model.requestDeleteMember(fixture.member)

        await model.confirmDeleteMember(id: fixture.member.id)

        #expect(await service.deletedMemberIDs == [fixture.member.id])
        #expect(model.pendingDeleteMemberID == nil)
        #expect(model.members.map(\.id) == [fixture.member.id])
        #expect(
            model.banner?.message == AppLocalization.string(
                "该成员仍关联 \(2) 条记录和 \(1) 份草稿。请先重分配这些内容，或逐条删除后再试。"
            )
        )
        #expect(model.banner?.message.contains(fixture.member.displayName) == false)
    }

    @Test
    func unreferencedMemberDeletionAppliesTheReturnedSnapshot() async throws {
        let fixture = try AppFixture()
        let deletedSnapshot = AppSnapshot(
            generation: fixture.snapshot.generation + 1,
            members: [],
            records: [],
            drafts: []
        )
        let service = AppServiceSpy(
            snapshot: AppSnapshot(
                generation: fixture.snapshot.generation,
                members: [fixture.member],
                records: [],
                drafts: []
            ),
            memberDeletionSnapshot: deletedSnapshot
        )
        let model = AppModel(service: service)
        await model.start()
        model.selectedMemberID = fixture.member.id
        model.requestDeleteMember(fixture.member)

        await model.confirmDeleteMember(id: fixture.member.id)

        #expect(model.members.isEmpty)
        #expect(model.selectedMemberID == nil)
        #expect(await service.deletedMemberIDs == [fixture.member.id])
    }

    @Test
    func selectingASecondOriginalLoadsOnlyThatOrderedSource() async throws {
        let member = try FamilyMember(displayName: "Synthetic member")
        let first = try ReportSource(
            attachmentID: UUID(),
            displayName: "page-1.png",
            pageCount: 1
        )
        let second = try ReportSource(
            attachmentID: UUID(),
            displayName: "page-2.png",
            pageCount: 1
        )
        let record = try HealthRecord(
            memberID: member.id,
            sources: ReportSources([first, second]),
            importState: .confirmed
        )
        let firstPayload = OriginalDocumentPayload(
            data: Data([1]),
            contentTypeIdentifier: "public.png"
        )
        let secondPayload = OriginalDocumentPayload(
            data: Data([2]),
            contentTypeIdentifier: "public.png"
        )
        let service = AppServiceSpy(
            snapshot: AppSnapshot(
                members: [member],
                records: [record],
                drafts: []
            ),
            originals: [record.id: firstPayload],
            sourceOriginals: [second.id: secondPayload]
        )
        let model = AppModel(service: service)

        await model.start()
        await model.selectRecord(record.id)
        #expect(model.selectedOriginalSourceID == first.id)
        #expect(model.originalDocument?.data == Data([1]))

        await model.selectOriginalSource(second.id)

        #expect(model.selectedOriginalSourceID == second.id)
        #expect(model.originalDocument?.data == Data([2]))
        #expect(await service.sourceOriginalLoadCallIDs == [first.id, second.id])
    }

    @Test
    func completingAQueuedOriginalLoadKeepsTheUpdatedRecordProjection() async throws {
        let member = try FamilyMember(displayName: "Synthetic member")
        let first = try ReportSource(
            attachmentID: UUID(),
            displayName: "page-1.png",
            pageCount: 1
        )
        let second = try ReportSource(
            attachmentID: UUID(),
            displayName: "page-2.png",
            pageCount: 1
        )
        let record = try HealthRecord(
            memberID: member.id,
            sources: ReportSources([first, second]),
            importState: .confirmed,
            title: try .manualEntry("Original title")
        )
        let updatedRecord = try HealthRecord(
            id: record.id,
            memberID: member.id,
            sources: record.sources,
            importState: .confirmed,
            title: try .manualEntry("Updated title")
        )
        let initialSnapshot = AppSnapshot(
            generation: 1,
            members: [member],
            records: [record],
            drafts: []
        )
        let updatedSnapshot = AppSnapshot(
            generation: 2,
            members: [member],
            records: [updatedRecord],
            drafts: []
        )
        let secondLoadGate = OriginalLoadGate()
        let service = AppServiceSpy(
            snapshot: initialSnapshot,
            originals: [record.id: OriginalDocumentPayload(
                data: Data([1]),
                contentTypeIdentifier: "public.png"
            )],
            sourceOriginals: [second.id: OriginalDocumentPayload(
                data: Data([2]),
                contentTypeIdentifier: "public.png"
            )],
            sourceOriginalLoadGates: [second.id: secondLoadGate],
            recordUpdateSnapshot: updatedSnapshot
        )
        let model = AppModel(service: service)
        await model.start()
        await model.selectRecord(record.id)

        let sourceChange = Task { await model.selectOriginalSource(second.id) }
        await secondLoadGate.waitUntilLoadStarts()
        let command = UpdateRecordCommand(
            recordID: record.id,
            expectedRevision: record.revision,
            memberID: member.id,
            timelineDateSelection: .unknown,
            title: "Updated title",
            organization: "",
            department: "",
            reportType: "",
            reportedResults: "",
            conclusion: "",
            abnormalItems: [],
            userNote: ""
        )

        #expect(await model.updateRecord(command) == .saved)
        await secondLoadGate.open()
        await sourceChange.value

        #expect(model.selectedRecord?.title?.transcription == "Updated title")
        #expect(model.selectedOriginalSourceID == second.id)
        #expect(model.originalDocument?.data == Data([2]))
    }
}

actor AppServiceSpy: AppDataServicing {
    private var currentSnapshot: AppSnapshot
    private let refreshedSnapshot: AppSnapshot?
    private let refreshError: AppServiceError?
    private var outcomes: [AppImportOutcome]
    private let documents: [ImportDraft.ID: ImportReviewContent]
    private let originals: [HealthRecord.ID: OriginalDocumentPayload]
    private let sourceOriginals: [ReportSource.ID: OriginalDocumentPayload]
    private let reviewSourceOriginals: [ReportSource.ID: OriginalDocumentPayload]
    private let recognizedReviews: [ImportDraft.ID: RecognizedReviewContent]
    private let recognizeReviewError: AppServiceError?
    private let recognizeReviewGate: OriginalLoadGate?
    private let originalLoadDelay: Duration?
    private let originalLoadDelays: [HealthRecord.ID: Duration]
    private let sourceOriginalLoadDelays: [ReportSource.ID: Duration]
    private let ignoresOriginalLoadCancellation: Bool
    private let originalLoadGate: OriginalLoadGate?
    private let originalLoadGates: [HealthRecord.ID: OriginalLoadGate]
    private let sourceOriginalLoadGates: [ReportSource.ID: OriginalLoadGate]
    private let recordDeletionSnapshot: AppSnapshot?
    private let recordUpdateSnapshot: AppSnapshot?
    private let recordUpdateError: AppServiceError?
    private let recordDeletionDelay: Duration?
    private let memberDeletionSnapshot: AppSnapshot?
    private let memberDeletionError: AppServiceError?
    private let deferError: AppServiceError?
    private(set) var importCallCount = 0
    private(set) var confirmedCommands: [ConfirmDraftCommand] = []
    private(set) var updatedCommands: [UpdateRecordCommand] = []
    private(set) var discardedDraftCommands: [DiscardDraftCommand] = []
    var discardedDraftIDs: [ImportDraft.ID] { discardedDraftCommands.map(\.draftID) }
    private(set) var deferredCommands: [DeferDraftCommand] = []
    private(set) var originalLoadCallIDs: [HealthRecord.ID] = []
    private(set) var sourceOriginalLoadCallIDs: [ReportSource.ID] = []
    private(set) var reviewSourceOriginalLoadCallIDs: [ReportSource.ID] = []
    private(set) var recognizeReviewCommands: [RecognizeReviewCommand] = []
    private(set) var deletedRecordIDs: [HealthRecord.ID] = []
    private(set) var deletedMemberIDs: [FamilyMember.ID] = []

    init(
        snapshot: AppSnapshot,
        importOutcomes: [AppImportOutcome] = [],
        refreshedSnapshot: AppSnapshot? = nil,
        refreshError: AppServiceError? = nil,
        documents: [ImportDraft.ID: ImportReviewContent] = [:],
        originals: [HealthRecord.ID: OriginalDocumentPayload] = [:],
        sourceOriginals: [ReportSource.ID: OriginalDocumentPayload] = [:],
        reviewSourceOriginals: [ReportSource.ID: OriginalDocumentPayload] = [:],
        recognizedReviews: [ImportDraft.ID: RecognizedReviewContent] = [:],
        recognizeReviewError: AppServiceError? = nil,
        recognizeReviewGate: OriginalLoadGate? = nil,
        originalLoadDelay: Duration? = nil,
        originalLoadDelays: [HealthRecord.ID: Duration] = [:],
        sourceOriginalLoadDelays: [ReportSource.ID: Duration] = [:],
        ignoresOriginalLoadCancellation: Bool = false,
        originalLoadGate: OriginalLoadGate? = nil,
        originalLoadGates: [HealthRecord.ID: OriginalLoadGate] = [:],
        sourceOriginalLoadGates: [ReportSource.ID: OriginalLoadGate] = [:],
        recordUpdateSnapshot: AppSnapshot? = nil,
        recordUpdateError: AppServiceError? = nil,
        recordDeletionSnapshot: AppSnapshot? = nil,
        recordDeletionDelay: Duration? = nil,
        memberDeletionSnapshot: AppSnapshot? = nil,
        memberDeletionError: AppServiceError? = nil,
        deferError: AppServiceError? = nil
    ) {
        currentSnapshot = snapshot
        self.outcomes = importOutcomes
        self.refreshedSnapshot = refreshedSnapshot
        self.refreshError = refreshError
        self.documents = documents
        self.originals = originals
        self.sourceOriginals = sourceOriginals
        self.reviewSourceOriginals = reviewSourceOriginals
        self.recognizedReviews = recognizedReviews
        self.recognizeReviewError = recognizeReviewError
        self.recognizeReviewGate = recognizeReviewGate
        self.originalLoadDelay = originalLoadDelay
        self.originalLoadDelays = originalLoadDelays
        self.sourceOriginalLoadDelays = sourceOriginalLoadDelays
        self.ignoresOriginalLoadCancellation = ignoresOriginalLoadCancellation
        self.originalLoadGate = originalLoadGate
        self.originalLoadGates = originalLoadGates
        self.sourceOriginalLoadGates = sourceOriginalLoadGates
        self.recordUpdateSnapshot = recordUpdateSnapshot
        self.recordUpdateError = recordUpdateError
        self.recordDeletionSnapshot = recordDeletionSnapshot
        self.recordDeletionDelay = recordDeletionDelay
        self.memberDeletionSnapshot = memberDeletionSnapshot
        self.memberDeletionError = memberDeletionError
        self.deferError = deferError
    }

    func bootstrap() async throws -> AppSnapshot { currentSnapshot }
    func refresh() async throws -> AppSnapshot {
        if let refreshError { throw refreshError }
        if let refreshedSnapshot { currentSnapshot = refreshedSnapshot }
        return currentSnapshot
    }
    func createMember(displayName: String, disambiguationLabel: String?) async throws -> AppSnapshot {
        currentSnapshot
    }
    func updateMember(_ member: FamilyMember) async throws -> AppSnapshot { currentSnapshot }
    func archiveMember(id: FamilyMember.ID) async throws -> AppSnapshot { currentSnapshot }
    func importFile(at url: URL) async throws -> AppImportOutcome {
        importCallCount += 1
        return outcomes.isEmpty ? .failed(.importFailed) : outcomes.removeFirst()
    }
    func retryDraft(id: ImportDraft.ID) async throws -> AppImportOutcome {
        outcomes.isEmpty ? .failed(.importFailed) : outcomes.removeFirst()
    }
    func loadReview(draftID: ImportDraft.ID) async throws -> ImportReviewContent {
        guard let value = documents[draftID] else { throw AppServiceError.draftUnavailable }
        return value
    }
    func recognizeReview(_ command: RecognizeReviewCommand) async throws -> RecognizedReviewContent {
        recognizeReviewCommands.append(command)
        if let recognizeReviewGate { await recognizeReviewGate.wait() }
        if let recognizeReviewError { throw recognizeReviewError }
        guard let value = recognizedReviews[command.draftID] else {
            throw AppServiceError.draftUnavailable
        }
        return value
    }
    func loadReviewOriginal(
        draftID: ImportDraft.ID,
        sourceID: ReportSource.ID
    ) async throws -> OriginalDocumentPayload {
        reviewSourceOriginalLoadCallIDs.append(sourceID)
        guard documents[draftID]?.draft.sources.elements.contains(where: {
            $0.id == sourceID
        }) == true else { throw AppServiceError.draftUnavailable }
        if let value = reviewSourceOriginals[sourceID] { return value }
        guard let value = documents[draftID]?.original else {
            throw AppServiceError.draftUnavailable
        }
        return value
    }
    func confirmDraft(_ command: ConfirmDraftCommand) async throws -> AppSnapshot {
        confirmedCommands.append(command)
        return currentSnapshot
    }
    func updateRecord(_ command: UpdateRecordCommand) async throws -> AppSnapshot {
        updatedCommands.append(command)
        if let recordUpdateError { throw recordUpdateError }
        if let recordUpdateSnapshot { currentSnapshot = recordUpdateSnapshot }
        return currentSnapshot
    }
    func deleteRecord(id: HealthRecord.ID) async throws -> AppSnapshot {
        deletedRecordIDs.append(id)
        if let recordDeletionDelay { try await Task.sleep(for: recordDeletionDelay) }
        if let recordDeletionSnapshot { currentSnapshot = recordDeletionSnapshot }
        return currentSnapshot
    }
    func deleteMember(id: FamilyMember.ID) async throws -> AppSnapshot {
        deletedMemberIDs.append(id)
        if let memberDeletionError { throw memberDeletionError }
        if let memberDeletionSnapshot { currentSnapshot = memberDeletionSnapshot }
        return currentSnapshot
    }
    func deferDraft(_ command: DeferDraftCommand) async throws {
        if let deferError { throw deferError }
        deferredCommands.append(command)
    }
    func discardDraft(_ command: DiscardDraftCommand) async throws -> AppSnapshot {
        discardedDraftCommands.append(command)
        return currentSnapshot
    }
    private func loadFallbackOriginal(
        recordID: HealthRecord.ID
    ) async throws -> OriginalDocumentPayload {
        originalLoadCallIDs.append(recordID)
        if let gate = originalLoadGates[recordID] ?? originalLoadGate {
            await gate.wait()
        }
        if let delay = originalLoadDelays[recordID] ?? originalLoadDelay {
            if ignoresOriginalLoadCancellation {
                await Task.detached { try? await Task.sleep(for: delay) }.value
            } else {
                try await Task.sleep(for: delay)
            }
        }
        guard let value = originals[recordID] else { throw AppServiceError.recordUnavailable }
        return value
    }
    func loadOriginal(
        recordID: HealthRecord.ID,
        sourceID: ReportSource.ID
    ) async throws -> OriginalDocumentPayload {
        sourceOriginalLoadCallIDs.append(sourceID)
        if let value = sourceOriginals[sourceID] {
            originalLoadCallIDs.append(recordID)
            if let gate = sourceOriginalLoadGates[sourceID] {
                await gate.wait()
            }
            if let delay = sourceOriginalLoadDelays[sourceID]
                ?? originalLoadDelays[recordID]
                ?? originalLoadDelay {
                if ignoresOriginalLoadCancellation {
                    await Task.detached { try? await Task.sleep(for: delay) }.value
                } else {
                    try await Task.sleep(for: delay)
                }
            }
            return value
        }
        return try await loadFallbackOriginal(recordID: recordID)
    }
}

actor OriginalLoadGate {
    private var loadHasStarted = false
    private var isOpen = false
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        loadHasStarted = true
        let pendingStartWaiters = startWaiters
        startWaiters.removeAll()
        pendingStartWaiters.forEach { $0.resume() }

        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            if isOpen {
                continuation.resume()
            } else {
                loadWaiters.append(continuation)
            }
        }
    }

    func waitUntilLoadStarts() async {
        guard !loadHasStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pendingLoadWaiters = loadWaiters
        loadWaiters.removeAll()
        pendingLoadWaiters.forEach { $0.resume() }
    }
}

private actor OutOfOrderRefreshService: AppDataServicing {
    private let snapshot: AppSnapshot
    private var olderRefresh: CheckedContinuation<AppSnapshot, any Error>?
    private(set) var refreshCallCount = 0

    init(snapshot: AppSnapshot) {
        self.snapshot = snapshot
    }

    func bootstrap() async throws -> AppSnapshot { snapshot }

    func refresh() async throws -> AppSnapshot {
        refreshCallCount += 1
        if refreshCallCount == 1 {
            return try await withCheckedThrowingContinuation { continuation in
                olderRefresh = continuation
            }
        }
        throw AppServiceError.vaultUnavailable
    }

    func completeOlderRefresh() {
        olderRefresh?.resume(returning: snapshot)
        olderRefresh = nil
    }

    func createMember(displayName: String, disambiguationLabel: String?) async throws -> AppSnapshot {
        snapshot
    }
    func updateMember(_ member: FamilyMember) async throws -> AppSnapshot { snapshot }
    func archiveMember(id: FamilyMember.ID) async throws -> AppSnapshot { snapshot }
    func importFile(at url: URL) async throws -> AppImportOutcome { .failed(.importFailed) }
    func retryDraft(id: ImportDraft.ID) async throws -> AppImportOutcome { .failed(.importFailed) }
    func loadReview(draftID: ImportDraft.ID) async throws -> ImportReviewContent {
        throw AppServiceError.draftUnavailable
    }
    func recognizeReview(_ command: RecognizeReviewCommand) async throws -> RecognizedReviewContent {
        throw AppServiceError.draftUnavailable
    }
    func loadReviewOriginal(
        draftID: ImportDraft.ID,
        sourceID: ReportSource.ID
    ) async throws -> OriginalDocumentPayload {
        throw AppServiceError.draftUnavailable
    }
    func confirmDraft(_ command: ConfirmDraftCommand) async throws -> AppSnapshot { snapshot }
    func updateRecord(_ command: UpdateRecordCommand) async throws -> AppSnapshot { snapshot }
    func deleteRecord(id: HealthRecord.ID) async throws -> AppSnapshot { snapshot }
    func deleteMember(id: FamilyMember.ID) async throws -> AppSnapshot { snapshot }
    func deferDraft(_ command: DeferDraftCommand) async throws {}
    func discardDraft(_ command: DiscardDraftCommand) async throws -> AppSnapshot { snapshot }
    func loadOriginal(
        recordID: HealthRecord.ID,
        sourceID: ReportSource.ID
    ) async throws -> OriginalDocumentPayload {
        throw AppServiceError.recordUnavailable
    }
}

private struct AppFixture {
    let member: FamilyMember
    let confirmed: HealthRecord
    let draftRecord: HealthRecord
    let attachment: KinlogueCore.Attachment
    let draft: ImportDraft
    let snapshot: AppSnapshot

    init() throws {
        member = try FamilyMember(displayName: "Synthetic member")
        attachment = try KinlogueCore.Attachment(
            contentTypeIdentifier: "com.adobe.pdf",
            byteCount: 4,
            sha256Digest: Data(repeating: 7, count: 32)
        )
        confirmed = try HealthRecord(
            memberID: member.id,
            attachmentID: attachment.id,
            importState: .confirmed,
            conclusion: try SourceField(originalTranscription: "Confirmed anchor")
        )
        draftRecord = try HealthRecord(
            memberID: member.id,
            attachmentID: attachment.id,
            importState: .needsReview,
            conclusion: try SourceField(originalTranscription: "Unconfirmed anchor")
        )
        draft = ImportDraft(attachmentID: attachment.id, state: .needsReview, documentObjectID: UUID())
        snapshot = AppSnapshot(
            members: [member],
            records: [draftRecord, confirmed],
            drafts: [DraftSummary(draft: draft)]
        )
    }
}
