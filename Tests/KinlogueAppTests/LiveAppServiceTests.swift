import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import KinlogueApp
@testable import KinlogueCore
@testable import KinloguePlatform

/// `LiveAppService` on a real SQLite library. A test that needs to pause or fail one storage
/// call wraps the repository in an intercepting store; nothing here replaces the library itself.
struct LiveAppServiceTests {
    @Test
    func restoreRevocationCancelsAndDrainsBlockedReportOCRBeforeReturning() async throws {
        let fixture = try SQLiteAppQueryFixture()
        defer { fixture.destroy() }
        let draftID = try await stagedDraft(fixture, try liveServicePNG())
        let extractor = LiveServiceGatedExtractor()
        let lifecycle = LibraryLifecycleCoordinator()
        let service = liveService(fixture, extractor: extractor, lifecycle: lifecycle)

        let importing = Task { try await service.retryDraft(id: draftID) }
        await extractor.waitUntilEntered()
        let revokeCompleted = LiveServiceCompletionProbe()
        let revoking = Task {
            await lifecycle.revoke()
            await revokeCompleted.markCompleted()
        }
        try await Task.sleep(for: .milliseconds(30))
        #expect(!(await revokeCompleted.isCompleted))

        await extractor.resume()
        await #expect(throws: CancellationError.self) {
            _ = try await importing.value
        }
        await revoking.value
        let settled = try await fixture.reports.draft(draftID)
        try await Task.sleep(for: .milliseconds(30))
        let later = try await fixture.reports.draft(draftID)

        #expect(await extractor.observedCancellation)
        #expect(settled == later)
        #expect(settled.state == .processing)
        #expect(try await fixture.reports.header().draftCount == 1)
    }

    @Test(arguments: [false, true])
    @MainActor
    func recoveredOCRPublishesItsTerminalStateAfterTheLibraryIsReady(fails: Bool) async throws {
        let fixture = try SQLiteAppQueryFixture()
        defer { fixture.destroy() }
        let member = try FamilyMember(displayName: "Synthetic member")
        try await fixture.reports.saveMember(member, replacing: nil)
        let record = try await fixture.confirmed(member: member, seed: "synthetic confirmed original")
        // The result of recognition, success or failure, waits here before it is committed.
        let commitGate = AsyncOperationGate()
        let drafts = InterceptedDraftStore(fixture.reports, before: { call in
            switch call {
            case .completeProcessing, .failProcessing: await commitGate.wait()
            default: break
            }
        })
        _ = try await stagedDraft(fixture, try liveServicePNG())
        if fails { _ = try await stagedDraft(fixture, try liveServicePNG(red: 0.5)) }
        // Recovery takes the drafts in the order the library lists them, not the order staged.
        let recoveryOrder = try await fixture.reports.resumableDraftIDs()
        let draftID = try #require(recoveryOrder.first)
        let followingDraftID = fails ? recoveryOrder.last : nil
        let extractor = LiveServiceGatedExtractor(fails: fails)
        let lifecycle = LibraryLifecycleCoordinator()
        let service = liveService(fixture, drafts: drafts, extractor: extractor, startupCompleted: false, lifecycle: lifecycle)
        let model = AppModel(service: service)
        let completion = AsyncOperationGate()
        let followingCompletion = AsyncOperationGate()
        let completed = LiveServiceCompletionProbe()
        let processing = AppProcessingCoordinator(
            lanService: UnavailableLANInboxService(), lifecycle: lifecycle,
            onCatalogChanged: {
                await model.refresh()
                await completed.markCompleted()
                if await completed.count == 1 { await completion.wait() }
                else { await followingCompletion.wait() }
            }
        )

        await model.start()
        #expect(model.phase == .ready)
        #expect(model.members == [LibraryMemberSummary(member)])
        #expect(await extractor.callCount == 0)
        await processing.startRecovery(using: service)
        await extractor.waitUntilEntered()
        await processing.startRecovery(using: service)
        await model.refresh()
        #expect(model.phase == .ready)
        #expect(model.members == [LibraryMemberSummary(member)])
        #expect(await extractor.callCount == 1)
        model.selectedMemberID = member.id
        await model.waitForCurrentPage()
        #expect(model.timelineSections.flatMap(\.records) == [LibraryReportSummary(record: record)])
        await model.selectRecord(record.id)
        #expect(model.originalDocument?.data == Data("synthetic confirmed original".utf8))
        await extractor.resume()
        #expect(await commitGate.waitUntilStarted())
        #expect(await model.createMember(displayName: "Concurrent synthetic member", disambiguationLabel: nil))
        #expect(model.phase == .ready)
        #expect(model.members.count == 2)
        await commitGate.open()
        #expect(await completion.waitUntilStarted())
        if fails {
            #expect(model.backgroundDrafts.first?.id == draftID)
            #expect(model.backgroundDrafts.first?.state == .failed)
        } else {
            #expect(model.reviewQueue.first?.id == draftID)
            #expect(model.backgroundDrafts.isEmpty)
        }
        #expect(await extractor.callCount == 1)
        await completion.open()
        if let followingDraftID {
            #expect(await followingCompletion.waitUntilStarted())
            #expect(model.reviewQueue.map(\.id) == [followingDraftID])
            #expect(model.backgroundDrafts.first?.state == .failed)
            #expect(await extractor.callCount == 2)
            await followingCompletion.open()
        }
        await lifecycle.revoke()
        await model.beginDestructiveVaultLifecycle()
    }

    @Test(arguments: [ImportState.processing, .needsReview], [false, true])
    @MainActor
    func recoveryPersistenceFailureOffersExplicitRetryWithoutRestart(
        failingState: ImportState,
        superseded: Bool
    ) async throws {
        let fixture = try SQLiteAppQueryFixture()
        defer { fixture.destroy() }
        let fault = LiveServiceCommitFailureInjector(state: failingState)
        let retryGate = AsyncOperationGate()
        let drafts = InterceptedDraftStore(fixture.reports, before: { call in
            if await fault.isRetry(call) { await retryGate.wait() }
            try await fault.beforeCommit(call)
        })
        let draftID = try await stagedDraft(fixture, try liveServicePNG())
        let followingID = try await stagedDraft(fixture, try liveServicePNG(red: 0.5))
        let extractor = LiveServiceRecordingExtractor(blocks: [])
        let service = liveService(fixture, drafts: drafts, extractor: extractor, startupCompleted: false)
        let model = AppModel(service: service)
        let completion = AsyncOperationGate()
        let followingCompletion = AsyncOperationGate()
        let completed = LiveServiceCompletionProbe()
        let processing = AppProcessingCoordinator(
            lanService: UnavailableLANInboxService(),
            onCatalogChanged: {
                await model.refresh()
                await completed.markCompleted()
                if await completed.count == 1 { await completion.wait() }
                else { await followingCompletion.wait() }
            }
        )
        await model.start()
        await processing.startRecovery(using: service)
        #expect(await completion.waitUntilStarted())
        #expect(model.phase == .ready)
        // The injected failure belongs to whichever draft recovery reached first.
        let failedID = try #require(await fault.failedDraftID)
        let otherID = failedID == draftID ? followingID : draftID
        #expect(model.backgroundDrafts.first(where: { $0.id == failedID })?.canRetryRecovery == true)
        #expect(model.backgroundDrafts.first(where: { $0.id == failedID })?.state == (failingState == .processing ? .staging : .processing))
        model.requestDiscardDraft(failedID)
        #expect(model.pendingDiscardDraftID == nil)
        await completion.open()
        #expect(await followingCompletion.waitUntilStarted())
        #expect(model.reviewQueue.map(\.id) == [otherID])
        await followingCompletion.open()
        await processing.startRecovery(using: service)
        await service.resumeInterruptedImports(onDraftCompleted: {})
        await model.refresh()
        #expect(await fault.failureCount == 1)
        #expect(model.backgroundDrafts.first(where: { $0.id == failedID })?.canRetryRecovery == true)
        #expect(await extractor.files.count == (failingState == .processing ? 1 : 2))

        if superseded {
            _ = try await fixture.reports.beginProcessing(draftID: failedID, attemptID: UUID())
            await model.refresh()
            #expect(model.backgroundDrafts.first(where: { $0.id == failedID })?.state == .processing)
            #expect(model.backgroundDrafts.first(where: { $0.id == failedID })?.canRetryRecovery == false)
            await processing.cancelAndDrain()
            await model.beginDestructiveVaultLifecycle()
            return
        }
        let retry = Task { await model.retryDraft(failedID) }
        #expect(await retryGate.waitUntilStarted())
        await model.refresh()
        #expect(model.backgroundDrafts.first(where: { $0.id == failedID })?.canRetryRecovery == false)
        #expect(await extractor.files.count == (failingState == .processing ? 1 : 2))
        await retryGate.open()
        await retry.value
        #expect(await fault.failureCount == 2)
        #expect(model.backgroundDrafts.first(where: { $0.id == failedID })?.canRetryRecovery == true)

        await model.retryDraft(failedID)
        #expect(model.phase == .ready)
        #expect(Set(model.reviewQueue.map(\.id)) == [failedID, otherID])
        #expect(model.reviewQueue.allSatisfy { !$0.canRetryRecovery })
        #expect(model.backgroundDrafts.isEmpty)
        await processing.cancelAndDrain()
        await model.beginDestructiveVaultLifecycle()
    }

    @Test(arguments: [false, true])
    @MainActor
    func revocationDrainsStartupRecoveryAndRejectsItsLateCallback(atCommitBoundary: Bool) async throws {
        let fixture = try SQLiteAppQueryFixture()
        defer { fixture.destroy() }
        let commitGate = AsyncOperationGate()
        let drafts = InterceptedDraftStore(fixture.reports, before: { call in
            if case .completeProcessing = call { await commitGate.wait() }
        })
        let draftID = try await stagedDraft(fixture, try liveServicePNG())
        let extractor = LiveServiceGatedExtractor()
        let lifecycle = LibraryLifecycleCoordinator()
        let service = liveService(fixture, drafts: drafts, extractor: extractor, startupCompleted: false, lifecycle: lifecycle)
        let model = AppModel(service: service)
        let callback = LiveServiceCompletionProbe()
        let processing = AppProcessingCoordinator(
            lanService: UnavailableLANInboxService(), lifecycle: lifecycle,
            onCatalogChanged: { await callback.markCompleted() }
        )
        await model.start()
        await processing.startRecovery(using: service)
        await extractor.waitUntilEntered()
        if atCommitBoundary {
            await extractor.resume()
            #expect(await commitGate.waitUntilStarted())
        }
        await model.beginDestructiveVaultLifecycle()
        let drained = LiveServiceCompletionProbe()
        let revocation = Task {
            await lifecycle.revoke()
            await drained.markCompleted()
        }
        try await Task.sleep(for: .milliseconds(30))
        #expect(!(await drained.isCompleted))
        if atCommitBoundary { await commitGate.open() }
        else { await extractor.resume() }
        await revocation.value
        #expect(await extractor.observedCancellation == !atCommitBoundary)
        #expect(!(await callback.isCompleted))
        #expect(model.reviewQueue.isEmpty)
        #expect(model.backgroundDrafts.isEmpty)
        #expect(try await fixture.reports.draft(draftID).state == .processing)
    }

    @Test
    func libraryDeletionWaitsForReceiverStartupToExit() async throws {
        let fixture = try SQLiteAppQueryFixture()
        defer { fixture.destroy() }
        let gate = AsyncOperationGate()
        let lifecycle = LibraryLifecycleCoordinator()
        let revocationGate = try await installRevocationGate(on: lifecycle)
        let service = try LiveLANInboxService(
            store: fixture.store,
            lifecycle: lifecycle,
            dependencies: .init(
                receiverStart: { receiver, _ in
                    await gate.wait()
                    return try await receiver.start(
                        at: .init(
                            interfaceName: "lo0",
                            host: "127.0.0.1",
                            networkPrefixLength: 8
                        ),
                        port: 0,
                        allowLoopbackForTesting: true,
                        pipelineInstaller: { channel, _, _, _ in
                            channel.eventLoop.makeSucceededFuture(())
                        }
                    )
                }
            )
        )
        _ = try await service.initialize()
        let start = Task {
            try await service.startReceiving(at: .init(
                interfaceName: "en0",
                host: "192.168.1.2",
                networkPrefixLength: 24
            ))
        }
        guard await gate.waitUntilStarted() else {
            start.cancel()
            await gate.open()
            _ = try? await start.value
            Issue.record("Timed out waiting for receiver startup")
            return
        }
        let destroy = LiveServiceDestroySpy()
        let coordinated = LifecycleCoordinatedVaultDestroyService(
            lifecycle: lifecycle,
            underlying: destroy
        )

        let deletion = Task {
            try await coordinated.destroyCurrentVault()
        }
        guard await revocationGate.waitUntilStarted() else {
            deletion.cancel()
            await revocationGate.open()
            await gate.open()
            _ = try? await start.value
            _ = try? await deletion.value
            Issue.record("Timed out waiting for lifecycle revocation")
            return
        }
        await revocationGate.open()

        #expect(await destroy.callCount == 0)
        await gate.open()
        do {
            _ = try await start.value
            Issue.record("Receiver startup unexpectedly survived library deletion")
        } catch LibraryLifecycleCoordinatorError.revoked {
            // Expected: the late-started receiver was stopped before returning.
        } catch LANReceiverError.sessionEnded {
            // Also expected when revocation reaches the receiver during startup.
        } catch {
            Issue.record("Unexpected receiver startup error: \(error)")
        }
        try await deletion.value
        #expect(await destroy.callCount == 1)
        #expect(!(await service.isReceiving()))
    }

    // MARK: Startup

    @Test
    func bootstrapInitializesTheLibraryEnumeratesRecoveryAndThenReadsTheHeader() async throws {
        let fixture = try SQLiteAppQueryFixture()
        defer { fixture.destroy() }
        _ = try await stagedDraft(fixture, try liveServicePNG())
        let log = StorageCallLog()
        let service = liveService(
            fixture,
            reports: InterceptedReportStore(fixture.reports, before: { await log.append("\($0)") }),
            drafts: InterceptedDraftStore(fixture.reports, before: { await log.append($0.name) }),
            startupCompleted: false
        )

        let snapshot = try await service.bootstrap()

        // Recovery is only enumerated here; nothing starts processing before the library is ready.
        #expect(await log.values == ["initializeLibrary", "resumableDraftIDs", "header"])
        #expect(snapshot.draftCount == 1 && snapshot.reportCount == 0)
    }

    @Test
    func concurrentAccessWaitsForTheSharedStartupTask() async throws {
        let fixture = try SQLiteAppQueryFixture()
        defer { fixture.destroy() }
        let log = StorageCallLog()
        let initializeGate = AsyncOperationGate()
        let service = liveService(fixture, reports: InterceptedReportStore(fixture.reports, before: { call in
            await log.append("\(call)")
            if call == .initializeLibrary { await initializeGate.wait() }
        }), startupCompleted: false)

        let bootstrap = Task { try await service.bootstrap() }
        guard await initializeGate.waitUntilStarted() else {
            bootstrap.cancel()
            await initializeGate.open()
            _ = try? await bootstrap.value
            Issue.record("Timed out waiting for library startup")
            return
        }
        let refreshWaitGate = AsyncOperationGate()
        await service.installStartupWaitObserverForTesting {
            await refreshWaitGate.wait()
        }
        let refresh = Task { try await service.refresh() }
        guard await refreshWaitGate.waitUntilStarted() else {
            refresh.cancel()
            bootstrap.cancel()
            await refreshWaitGate.open()
            await initializeGate.open()
            _ = try? await bootstrap.value
            _ = try? await refresh.value
            Issue.record("Timed out waiting for refresh to join library startup")
            return
        }

        #expect(await log.values == ["initializeLibrary"])

        await refreshWaitGate.open()
        await initializeGate.open()
        let started = try await bootstrap.value
        #expect(try await refresh.value.revision == started.revision)
        #expect(await log.count("header") == 2)
        #expect(await log.count("initializeLibrary") == 1)
    }

    @Test
    func repeatedBootstrapReadsTheLibraryAgainInsteadOfReturningCachedStartupState() async throws {
        let fixture = try SQLiteAppQueryFixture()
        defer { fixture.destroy() }
        let log = StorageCallLog()
        let service = liveService(fixture, reports: InterceptedReportStore(fixture.reports, before: { call in
            await log.append("\(call)")
            if call == .header, await log.count("header") == 2 { throw LiveServiceSyntheticFailure() }
        }), startupCompleted: false)

        _ = try await service.bootstrap()
        await #expect(throws: LiveServiceSyntheticFailure.self) {
            try await service.bootstrap()
        }

        #expect(await log.count("header") == 2)
        #expect(await log.count("initializeLibrary") == 1)
    }

    @Test
    func cancellingOneStartupWaiterDoesNotCancelTheSharedStartupTask() async throws {
        let fixture = try SQLiteAppQueryFixture()
        defer { fixture.destroy() }
        let log = StorageCallLog()
        let initializeGate = AsyncOperationGate()
        let service = liveService(fixture, reports: InterceptedReportStore(fixture.reports, before: { call in
            await log.append("\(call)")
            if call == .initializeLibrary { await initializeGate.wait() }
        }), startupCompleted: false)

        let bootstrap = Task { try await service.bootstrap() }
        guard await initializeGate.waitUntilStarted() else {
            bootstrap.cancel()
            await initializeGate.open()
            _ = try? await bootstrap.value
            Issue.record("Timed out waiting for library startup")
            return
        }
        let refreshWaitGate = AsyncOperationGate()
        await service.installStartupWaitObserverForTesting {
            await refreshWaitGate.wait()
        }
        let cancelledRefresh = Task { try await service.refresh() }
        guard await refreshWaitGate.waitUntilStarted() else {
            cancelledRefresh.cancel()
            bootstrap.cancel()
            await refreshWaitGate.open()
            await initializeGate.open()
            _ = try? await bootstrap.value
            _ = try? await cancelledRefresh.value
            Issue.record("Timed out waiting for refresh to join library startup")
            return
        }
        cancelledRefresh.cancel()
        await refreshWaitGate.open()
        await initializeGate.open()

        _ = try await bootstrap.value
        await #expect(throws: CancellationError.self) {
            try await cancelledRefresh.value
        }
        #expect(await log.count("header") == 1)
    }

    @Test
    func bootstrapPropagatesALibraryFailureWithoutEnumeratingRecovery() async throws {
        let fixture = try SQLiteAppQueryFixture()
        defer { fixture.destroy() }
        let log = StorageCallLog()
        let service = liveService(
            fixture,
            reports: InterceptedReportStore(fixture.reports, before: { call in
                await log.append("\(call)")
                if call == .initializeLibrary { throw SQLiteLibraryError.damaged }
            }),
            drafts: InterceptedDraftStore(fixture.reports, before: { await log.append($0.name) }),
            startupCompleted: false
        )

        await #expect(throws: SQLiteLibraryError.damaged) {
            try await service.bootstrap()
        }

        #expect(await log.values == ["initializeLibrary"])
    }

    @Test
    func startupSynchronizationTimesOutWhenTheGateIsNeverReached() async {
        let gate = AsyncOperationGate()

        #expect(!(await gate.waitUntilStarted(timeout: .milliseconds(20))))
    }

    @Test
    func bootstrapPropagatesAFinalReadFailureAfterRecoveryInsteadOfReturningAStaleSnapshot() async throws {
        let fixture = try SQLiteAppQueryFixture()
        defer { fixture.destroy() }
        let log = StorageCallLog()
        let service = liveService(
            fixture,
            reports: InterceptedReportStore(fixture.reports, before: { call in
                await log.append("\(call)")
                if call == .header { throw LiveServiceSyntheticFailure() }
            }),
            drafts: InterceptedDraftStore(fixture.reports, before: { await log.append($0.name) }),
            startupCompleted: false
        )

        await #expect(throws: LiveServiceSyntheticFailure.self) {
            try await service.bootstrap()
        }

        #expect(await log.values == ["initializeLibrary", "resumableDraftIDs", "header"])
    }

    @Test
    func bootstrapReadinessDoesNotDependOnRecoveryProcessing() async throws {
        let fixture = try SQLiteAppQueryFixture()
        defer { fixture.destroy() }
        _ = try await stagedDraft(fixture, try liveServicePNG())
        let log = StorageCallLog()
        let service = liveService(fixture, drafts: InterceptedDraftStore(fixture.reports, before: { call in
            await log.append(call.name)
            if case .beginProcessing = call { throw LiveServiceSyntheticFailure() }
        }), startupCompleted: false)

        _ = try await service.bootstrap()
        _ = try await service.bootstrap()
        #expect(await log.count("beginProcessing") == 0)
        await service.resumeInterruptedImports(onDraftCompleted: {})
        await service.resumeInterruptedImports(onDraftCompleted: {})
        #expect(await log.count("resumableDraftIDs") == 1)
        #expect(await log.count("beginProcessing") == 1)
        #expect(try await service.draftPage(states: [.staging], cursor: nil).items.first?.canRetryRecovery == true)
    }

    // MARK: Review, confirmation and discard

    @Test
    func confirmDraftLoadsTheSnapshotAfterTheStoreCommits() async throws {
        let fixture = try SQLiteAppQueryFixture()
        defer { fixture.destroy() }
        let transaction = try await LiveServiceReviewDraft.make(fixture)
        let service = liveService(fixture)
        let command = ConfirmDraftCommand(
            draftID: transaction.draft.id,
            expectedRevision: transaction.draft.revision,
            memberID: transaction.member.id,
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

        let snapshot = try await service.confirmDraft(command)

        #expect(try await service.reportPage(query: "", memberID: nil, cursor: nil).items.map(\.id) == [transaction.draft.id])
        #expect(snapshot.draftCount == 0 && snapshot.reportCount == 1)
        #expect(try await fixture.reports.record(transaction.draft.id).memberID == transaction.member.id)
    }

    @Test
    func confirmDraftRejectsAStaleRevisionBeforeLoadingTheDraftDocument() async throws {
        let fixture = try SQLiteAppQueryFixture()
        defer { fixture.destroy() }
        let transaction = try await LiveServiceReviewDraft.make(fixture)
        let log = StorageCallLog()
        let service = liveService(fixture, drafts: InterceptedDraftStore(fixture.reports, before: { await log.append($0.name) }))
        let staleCommand = ConfirmDraftCommand(
            draftID: transaction.confirmCommand.draftID,
            expectedRevision: transaction.confirmCommand.expectedRevision + 1,
            memberID: transaction.confirmCommand.memberID,
            timelineDateSelection: transaction.confirmCommand.timelineDateSelection,
            title: transaction.confirmCommand.title,
            organization: transaction.confirmCommand.organization,
            department: transaction.confirmCommand.department,
            reportType: transaction.confirmCommand.reportType,
            reportedResults: transaction.confirmCommand.reportedResults,
            conclusion: transaction.confirmCommand.conclusion,
            abnormalItems: transaction.confirmCommand.abnormalItems,
            userNote: transaction.confirmCommand.userNote
        )

        await #expect(throws: AppServiceError.invalidReview) {
            try await service.confirmDraft(staleCommand)
        }

        // The stale revision is refused before the draft store is asked for anything.
        #expect(await log.values.isEmpty)
        #expect(try await fixture.reports.draft(transaction.draft.id) == transaction.draft)
    }

    @Test
    func deferDraftPersistsTheCompleteReviewStateThroughTheDraftStore() async throws {
        let fixture = try SQLiteAppQueryFixture()
        defer { fixture.destroy() }
        let transaction = try await LiveServiceReviewDraft.make(fixture)
        let service = liveService(fixture)
        let manualDate = Date(timeIntervalSince1970: 1_784_419_200)
        let command = DeferDraftCommand(
            draftID: transaction.draft.id,
            expectedRevision: transaction.draft.revision,
            memberID: transaction.member.id,
            timelineDateSelection: .manual(manualDate),
            title: "Synthetic title",
            organization: "Synthetic organization",
            department: "Synthetic department",
            reportType: "Synthetic type",
            reportedResults: "Synthetic results",
            conclusion: "Synthetic conclusion",
            abnormalItems: ["Synthetic abnormal item"],
            userNote: "Synthetic note"
        )

        try await service.deferDraft(command)

        #expect(try await fixture.reports.draft(transaction.draft.id).memberID == transaction.member.id)
        let canonicalDate = try #require(ReportDateSemantics.canonicalDate(from: manualDate))
        #expect(try await fixture.reports.loadDocument(draftID: transaction.draft.id).reviewState == ImportDraftReviewState(
            timelineDateSelection: .manual(canonicalDate),
            title: "Synthetic title",
            organization: "Synthetic organization",
            department: "Synthetic department",
            reportType: "Synthetic type",
            reportedResults: "Synthetic results",
            conclusion: "Synthetic conclusion",
            abnormalItems: ["Synthetic abnormal item"],
            userNote: "Synthetic note"
        ))
    }

    @Test
    func confirmDraftPersistsManualDateResultsAndConclusionWithoutOCRCandidates() async throws {
        let fixture = try SQLiteAppQueryFixture()
        defer { fixture.destroy() }
        let transaction = try await LiveServiceReviewDraft.make(fixture)
        let service = liveService(fixture)
        let manualDate = Date(timeIntervalSince1970: 1_784_332_800)
        let command = ConfirmDraftCommand(
            draftID: transaction.draft.id,
            expectedRevision: transaction.draft.revision,
            memberID: transaction.member.id,
            timelineDateSelection: .manual(manualDate),
            title: "Manual title",
            organization: "",
            department: "",
            reportType: "",
            reportedResults: "Manual result",
            conclusion: "Manual conclusion",
            abnormalItems: [],
            userNote: ""
        )

        _ = try await service.confirmDraft(command)

        let record = try await fixture.reports.record(transaction.draft.id)
        #expect(record.timelineDate != nil)
        #expect(record.timelineDate.flatMap(ReportDateSemantics.transcription) == "2026-07-18")
        #expect(record.dateCandidates.count == 1)
        #expect(record.timelineDateCandidate?.kind == .other)
        #expect(record.timelineDateCandidate?.source.entryMethod == .manual)
        #expect(record.reportedResults?.transcription == "Manual result")
        #expect(record.reportedResults?.entryMethod == .manual)
        #expect(record.conclusion?.transcription == "Manual conclusion")
        #expect(record.conclusion?.entryMethod == .manual)
    }

    @Test
    func confirmDraftPersistsTheSelectedDetectedDateAndItsSource() async throws {
        let fixture = try SQLiteAppQueryFixture()
        defer { fixture.destroy() }
        let source = try SourceField(
            originalTranscription: "2026-07-18",
            references: [try SourceReference(pageNumber: 1)]
        )
        let date = try #require(ReportDateSemantics.canonicalDate(
            from: Date(timeIntervalSince1970: 1_784_332_800),
            timeZone: TimeZone(secondsFromGMT: 0)!
        ))
        let candidate = ReportDateCandidate(
            date: date,
            kind: .report,
            source: source
        )
        let transaction = try await LiveServiceReviewDraft.make(fixture, document: ImportDraftDocument(
                blocks: [],
                candidates: ReportCandidates(dateCandidates: [candidate])
            ))
        let service = liveService(fixture)
        let command = ConfirmDraftCommand(
            draftID: transaction.draft.id,
            expectedRevision: transaction.draft.revision,
            memberID: transaction.member.id,
            timelineDateSelection: .detected(candidate.id),
            title: "",
            organization: "",
            department: "",
            reportType: "",
            reportedResults: "",
            conclusion: "",
            abnormalItems: [],
            userNote: ""
        )

        _ = try await service.confirmDraft(command)

        let record = try await fixture.reports.record(transaction.draft.id)
        let attributedCandidate = ReportDateCandidate(
            id: candidate.id,
            date: candidate.date,
            kind: candidate.kind,
            source: try candidate.source.attributedAndValidated(for: transaction.draft.sources)
        )
        #expect(record.timelineDateCandidateID == candidate.id)
        #expect(record.timelineDateCandidate == attributedCandidate)
        #expect(record.timelineDateCandidate?.source.entryMethod == nil)
    }

    @Test
    func confirmDraftReprojectsLegacyCachedCandidatesFromStoredOCRBlocks() async throws {
        let fixture = try SQLiteAppQueryFixture()
        defer { fixture.destroy() }
        let heading = try OCRBlock(
            pageNumber: 1,
            text: "丨检查结论",
            boundingBox: NormalizedRect(x: 0.05, y: 0.7, width: 0.4, height: 0.04),
            confidence: 0.98,
            method: .vision,
            engineVersion: "synthetic"
        )
        let body = try OCRBlock(
            pageNumber: 1,
            text: "Synthetic projected conclusion",
            boundingBox: NormalizedRect(x: 0.05, y: 0.6, width: 0.8, height: 0.04),
            confidence: 0.97,
            method: .vision,
            engineVersion: "synthetic"
        )
        let legacyDocument = ImportDraftDocument(
            blocks: [heading, body],
            candidates: ReportCandidates(),
            candidateExtractionVersion: nil
        )
        let transaction = try await LiveServiceReviewDraft.make(fixture, document: legacyDocument)
        let service = liveService(fixture)
        let command = ConfirmDraftCommand(
            draftID: transaction.draft.id,
            expectedRevision: transaction.draft.revision,
            memberID: transaction.member.id,
            timelineDateSelection: .unknown,
            title: "",
            organization: "",
            department: "",
            reportType: "",
            reportedResults: "",
            conclusion: "Synthetic projected conclusion",
            abnormalItems: [],
            userNote: ""
        )

        _ = try await service.confirmDraft(command)

        let record = try await fixture.reports.record(transaction.draft.id)
        #expect(record.conclusion?.entryMethod == nil)
        #expect(record.conclusion?.references.map(\.blockID) == [body.id])
    }

    @Test
    func ruleUpdateBringsAConfirmedReportToTheCurrentRulesOnlyForTheFieldsTheUserTakes() async throws {
        let fixture = try SQLiteAppQueryFixture()
        defer { fixture.destroy() }
        func cell(_ text: String, _ x: Double, _ y: Double) throws -> OCRBlock {
            try OCRBlock(pageNumber: 1, text: text, boundingBox: NormalizedRect(x: x, y: y, width: 0.08, height: 0.02),
                         confidence: 0.9, method: .vision, engineVersion: "synthetic")
        }
        let blocks = try [
            cell("项目", 0.05, 0.82), cell("结果", 0.35, 0.82), cell("提示", 0.48, 0.82), cell("参考值", 0.6, 0.82),
            cell("合成葡萄糖", 0.05, 0.79), cell("6.85", 0.35, 0.79), cell("↑", 0.49, 0.79), cell("3.89-6.11", 0.6, 0.79),
            cell("合成胰岛素", 0.05, 0.76), cell("3.0", 0.35, 0.76), cell("1.9-23", 0.6, 0.76),
        ]
        // Recognized under older rules: the retained candidates read no table, and the user typed
        // a title and confirmed nothing else.
        let older = ImportDraftDocument(
            blocks: blocks,
            candidates: ReportCandidates(),
            candidateExtractionVersion: ReportCandidateExtractor.extractionVersion - 1
        )
        let transaction = try await LiveServiceReviewDraft.make(fixture, document: older, original: Data([1, 2, 3, 4]))
        let service = liveService(fixture)
        _ = try await service.confirmDraft(ConfirmDraftCommand(
            draftID: transaction.draft.id, expectedRevision: transaction.draft.revision, memberID: transaction.member.id,
            timelineDateSelection: .unknown, title: "合成手写标题", organization: "", department: "", reportType: "",
            reportedResults: "", conclusion: "", abnormalItems: [], userNote: ""
        ))
        let id = transaction.draft.id
        let before = try await fixture.reports.record(id)

        let update = try #require(try await service.ruleUpdate(recordID: id))
        #expect(update.changes.map(\.field) == [.title, .reportedResults, .abnormalItems])
        #expect(update.changes.map(\.replacesUserText) == [true, false, false])
        #expect(update.recordRevision == before.revision)

        // A revision or rules version other than the one the user saw changes nothing.
        for (revision, version) in [(before.revision + 1, update.extractionVersion), (before.revision, update.extractionVersion - 1)] {
            await #expect(throws: AppServiceError.recordChanged) {
                _ = try await service.applyRuleUpdate(ApplyRuleUpdateCommand(
                    recordID: id, expectedRevision: revision, extractionVersion: version, acceptedFields: [.reportedResults]
                ))
            }
        }
        #expect(try await fixture.reports.record(id) == before)

        _ = try await service.applyRuleUpdate(ApplyRuleUpdateCommand(
            recordID: id, expectedRevision: before.revision, extractionVersion: update.extractionVersion,
            acceptedFields: [.reportedResults, .abnormalItems]
        ))
        let after = try await fixture.reports.record(id)
        #expect(after.revision == before.revision + 1)
        #expect(after.reportedResults?.transcription == "合成葡萄糖\t6.85 ↑\t3.89-6.11\n合成胰岛素\t3.0\t1.9-23")
        #expect(after.reportedResults?.references.compactMap(\.blockID).count == 7)
        #expect(after.abnormalItems.map(\.transcription) == ["合成葡萄糖 6.85 ↑ 3.89-6.11"])
        #expect(after.title == before.title && after.memberID == before.memberID)

        // The retained document now carries the current rules and the same blocks, so nothing more is offered.
        let stored = try await fixture.reports.recordDocument(id)
        let document = try #require(stored.document)
        #expect(document.candidateExtractionVersion == ReportCandidateExtractor.extractionVersion)
        #expect(document.blocks.map(\.text) == blocks.map(\.text))
        #expect(document.candidates.reportedResults == after.reportedResults)
        #expect(try await service.ruleUpdate(recordID: id) == nil)
        // Search lists the table line the report now holds.
        let page = try await fixture.reports.reportPage(query: "葡萄糖", memberID: nil, limit: 10, cursor: nil)
        #expect(page.items.first?.matchedResultLines.map(\.cells) == [["合成葡萄糖", "6.85 ↑", "3.89-6.11"]])

        // The library keeps the blocks and the revision order whatever the caller sends.
        let next = try #require(RecordRuleUpdate.proposal(for: after, candidates: ReportCandidates(), extractionVersion: 99))
            .applying([], to: after)
        await #expect(throws: LibraryReportError.invalidDocument) {
            try await fixture.reports.updateRecord(next, expectedRevision: after.revision, document: ImportDraftDocument(
                blocks: Array(document.blocks.dropLast()), candidates: document.candidates,
                candidateExtractionVersion: document.candidateExtractionVersion
            ))
        }
        await #expect(throws: LibraryReportError.staleRevision) {
            try await fixture.reports.updateRecord(next, expectedRevision: before.revision, document: document)
        }
        #expect(try await fixture.reports.record(id) == after)
    }

    @Test
    func confirmDraftKeepsWhatRecognitionReadBehindARestoredVariantCharacter() async throws {
        let fixture = try SQLiteAppQueryFixture()
        defer { fixture.destroy() }
        let heading = try OCRBlock(
            pageNumber: 1,
            text: "检査所见：",
            boundingBox: NormalizedRect(x: 0.05, y: 0.7, width: 0.4, height: 0.04),
            confidence: 0.5,
            method: .vision,
            engineVersion: "synthetic"
        )
        let body = try OCRBlock(
            pageNumber: 1,
            text: "合成复査所见。",
            boundingBox: NormalizedRect(x: 0.05, y: 0.6, width: 0.8, height: 0.04),
            confidence: 0.97,
            method: .vision,
            engineVersion: "synthetic"
        )
        let previousVersionDocument = ImportDraftDocument(
            blocks: [heading, body],
            candidates: ReportCandidates(),
            candidateExtractionVersion: ReportCandidateExtractor.extractionVersion - 1
        )
        let transaction = try await LiveServiceReviewDraft.make(fixture, document: previousVersionDocument, original: Data([1, 2, 3, 4]))
        let service = liveService(fixture)

        let review = try await service.loadReview(draftID: transaction.draft.id)
        let proposal = try #require(review.document.candidates.reportedResults)
        #expect(proposal.transcription == "合成复查所见。")
        #expect(review.document.blocks.map(\.text) == ["检査所见：", "合成复査所见。"])

        let command = ConfirmDraftCommand(
            draftID: transaction.draft.id,
            expectedRevision: transaction.draft.revision,
            memberID: transaction.member.id,
            timelineDateSelection: .unknown,
            title: "",
            organization: "",
            department: "",
            reportType: "",
            reportedResults: proposal.transcription,
            conclusion: "",
            abnormalItems: [],
            userNote: ""
        )
        _ = try await service.confirmDraft(command)

        let record = try await fixture.reports.record(transaction.draft.id)
        #expect(record.reportedResults?.transcription == "合成复查所见。")
        #expect(record.reportedResults?.originalTranscription == "合成复査所见。")
        #expect(record.reportedResults?.entryMethod == nil)
        #expect(record.reportedResults?.references.map(\.blockID) == [body.id])
    }

    @Test
    func loadReviewShowsRefreshedCandidatesForAnExistingLegacyDraft() async throws {
        let fixture = try SQLiteAppQueryFixture()
        defer { fixture.destroy() }
        let heading = try OCRBlock(
            pageNumber: 1,
            text: "丨检查结论",
            boundingBox: NormalizedRect(x: 0.05, y: 0.7, width: 0.4, height: 0.04),
            confidence: 0.98,
            method: .vision,
            engineVersion: "synthetic"
        )
        let body = try OCRBlock(
            pageNumber: 1,
            text: "Synthetic refreshed conclusion",
            boundingBox: NormalizedRect(x: 0.05, y: 0.6, width: 0.8, height: 0.04),
            confidence: 0.97,
            method: .vision,
            engineVersion: "synthetic"
        )
        let transaction = try await LiveServiceReviewDraft.make(fixture, document: ImportDraftDocument(
                blocks: [heading, body],
                candidates: ReportCandidates(),
                candidateExtractionVersion: nil
            ), original: Data([1, 2, 3, 4]))
        let service = liveService(fixture)

        let review = try await service.loadReview(draftID: transaction.draft.id)

        #expect(review.document.candidates.conclusion?.transcription == "Synthetic refreshed conclusion")
        #expect(review.document.candidates.conclusion?.references.map(\.blockID) == [body.id])
        #expect(review.original.data == Data([1, 2, 3, 4]))
    }

    @Test
    func loadReviewRefreshesCandidatesFromThePreviousExtractionVersion() async throws {
        let fixture = try SQLiteAppQueryFixture()
        defer { fixture.destroy() }
        let findingHeading = try OCRBlock(
            pageNumber: 1,
            text: "放射学表现",
            boundingBox: NormalizedRect(x: 0.05, y: 0.8, width: 0.4, height: 0.04),
            confidence: 0.98,
            method: .vision,
            engineVersion: "synthetic"
        )
        let findingBody = try OCRBlock(
            pageNumber: 1,
            text: "Synthetic refreshed finding",
            boundingBox: NormalizedRect(x: 0.05, y: 0.7, width: 0.8, height: 0.04),
            confidence: 0.97,
            method: .vision,
            engineVersion: "synthetic"
        )
        let conclusionHeading = try OCRBlock(
            pageNumber: 1,
            text: "放射学诊断",
            boundingBox: NormalizedRect(x: 0.05, y: 0.6, width: 0.4, height: 0.04),
            confidence: 0.98,
            method: .vision,
            engineVersion: "synthetic"
        )
        let conclusionBody = try OCRBlock(
            pageNumber: 1,
            text: "Synthetic refreshed conclusion",
            boundingBox: NormalizedRect(x: 0.05, y: 0.5, width: 0.8, height: 0.04),
            confidence: 0.97,
            method: .vision,
            engineVersion: "synthetic"
        )
        let examinationTime = try OCRBlock(
            pageNumber: 1,
            text: "检查时间：2026-07-22 15:30:00",
            boundingBox: NormalizedRect(x: 0.05, y: 0.4, width: 0.6, height: 0.04),
            confidence: 0.96,
            method: .vision,
            engineVersion: "synthetic"
        )
        let transaction = try await LiveServiceReviewDraft.make(fixture, document: ImportDraftDocument(
                blocks: [findingHeading, findingBody, conclusionHeading, conclusionBody, examinationTime],
                candidates: ReportCandidates(),
                candidateExtractionVersion: ReportCandidateExtractor.extractionVersion - 1
            ), original: Data([1, 2, 3, 4]))
        let service = liveService(fixture)

        let review = try await service.loadReview(draftID: transaction.draft.id)

        #expect(review.document.candidateExtractionVersion == ReportCandidateExtractor.extractionVersion)
        #expect(review.document.candidates.reportedResults?.transcription == "Synthetic refreshed finding")
        #expect(review.document.candidates.conclusion?.transcription == "Synthetic refreshed conclusion")
        #expect(review.document.candidates.dateCandidates.first?.kind == .examination)
    }

    @Test
    func loadReviewPreservesPopulatedLegacyCandidatesOverReextraction() async throws {
        let fixture = try SQLiteAppQueryFixture()
        defer { fixture.destroy() }
        let heading = try OCRBlock(
            pageNumber: 1,
            text: "丨检查结论",
            boundingBox: NormalizedRect(x: 0.05, y: 0.8, width: 0.4, height: 0.04),
            confidence: 0.98,
            method: .vision,
            engineVersion: "synthetic"
        )
        let body = try OCRBlock(
            pageNumber: 1,
            text: "Synthetic re-extracted conclusion",
            boundingBox: NormalizedRect(x: 0.05, y: 0.7, width: 0.8, height: 0.04),
            confidence: 0.97,
            method: .vision,
            engineVersion: "synthetic"
        )
        let dateBlock = try OCRBlock(
            pageNumber: 1,
            text: "报告日期：2026-07-19",
            boundingBox: NormalizedRect(x: 0.05, y: 0.6, width: 0.5, height: 0.04),
            confidence: 0.96,
            method: .vision,
            engineVersion: "synthetic"
        )
        let storedReference = try SourceReference(
            pageNumber: 1,
            boundingBox: body.boundingBox,
            blockID: body.id
        )
        let storedConclusion = try SourceField(
            originalTranscription: "Synthetic stored conclusion",
            correctedTranscription: "Synthetic corrected conclusion",
            references: [storedReference]
        )
        let storedResults = try SourceField.manualEntry("Synthetic stored results")
        let storedDate = try #require(ReportDateSemantics.canonicalDate(
            from: Date(timeIntervalSince1970: 1_784_332_800),
            timeZone: TimeZone(secondsFromGMT: 0)!
        ))
        let storedDateCandidate = ReportDateCandidate(
            date: storedDate,
            kind: .report,
            source: try SourceField(
                originalTranscription: "2026-07-18",
                references: [storedReference]
            )
        )
        let transaction = try await LiveServiceReviewDraft.make(fixture, document: ImportDraftDocument(
                blocks: [heading, body, dateBlock],
                candidates: ReportCandidates(
                    dateCandidates: [storedDateCandidate],
                    reportedResults: storedResults,
                    conclusion: storedConclusion
                ),
                candidateExtractionVersion: nil
            ), original: Data([1, 2, 3, 4]))
        let service = liveService(fixture)

        let review = try await service.loadReview(draftID: transaction.draft.id)

        #expect(review.document.candidates.reportedResults == storedResults)
        #expect(review.document.candidates.reportedResults?.entryMethod == .manual)
        // The library keeps references attributed to the draft's source; the stored text and
        // the block each field points at are what the review must preserve.
        let sources = transaction.draft.sources
        let attributedConclusion = try storedConclusion.attributedAndValidated(for: sources)
        #expect(review.document.candidates.conclusion == attributedConclusion)
        #expect(review.document.candidates.conclusion?.transcription == "Synthetic corrected conclusion")
        #expect(review.document.candidates.conclusion?.references.map(\.blockID) == [body.id])
        #expect(review.document.candidates.dateCandidates == [ReportDateCandidate(
            id: storedDateCandidate.id,
            date: storedDateCandidate.date,
            kind: storedDateCandidate.kind,
            source: try storedDateCandidate.source.attributedAndValidated(for: sources)
        )])
    }

    @Test
    func explicitRecognitionRerunsOCRAndPersistsRecognizedValuesOverSavedEdits() async throws {
        let fixture = try SQLiteAppQueryFixture()
        defer { fixture.destroy() }
        let blocks = try [
            OCRBlock(
                pageNumber: 1,
                text: "报告标题：Recognized title",
                boundingBox: NormalizedRect(x: 0.05, y: 0.9, width: 0.7, height: 0.04),
                confidence: 0.98,
                method: .vision,
                engineVersion: "synthetic"
            ),
            OCRBlock(
                pageNumber: 1,
                text: "*检查所见",
                boundingBox: NormalizedRect(x: 0.05, y: 0.7, width: 0.3, height: 0.04),
                confidence: 0.98,
                method: .vision,
                engineVersion: "synthetic"
            ),
            OCRBlock(
                pageNumber: 1,
                text: "Recognized results",
                boundingBox: NormalizedRect(x: 0.05, y: 0.6, width: 0.7, height: 0.04),
                confidence: 0.97,
                method: .vision,
                engineVersion: "synthetic"
            ),
            OCRBlock(
                pageNumber: 1,
                text: "*检查结论",
                boundingBox: NormalizedRect(x: 0.05, y: 0.5, width: 0.3, height: 0.04),
                confidence: 0.98,
                method: .vision,
                engineVersion: "synthetic"
            ),
            OCRBlock(
                pageNumber: 1,
                text: "Recognized conclusion",
                boundingBox: NormalizedRect(x: 0.05, y: 0.4, width: 0.7, height: 0.04),
                confidence: 0.97,
                method: .vision,
                engineVersion: "synthetic"
            ),
        ]
        let extractor = LiveServiceRecordingExtractor(blocks: blocks)
        let oldDocument = ImportDraftDocument(
            blocks: [],
            candidates: ReportCandidates(),
            reviewState: ImportDraftReviewState(
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
        )
        let manualDate = Date(timeIntervalSince1970: 1_784_419_200)
        let transaction = try await LiveServiceReviewDraft.make(fixture, document: oldDocument, original: Data([1, 2, 3, 4]))
        let service = liveService(fixture, extractor: extractor)

        let recognized = try await service.recognizeReview(RecognizeReviewCommand(
            draftID: transaction.draft.id,
            expectedRevision: transaction.draft.revision,
            memberID: transaction.member.id,
            timelineDateSelection: .manual(manualDate),
            userNote: "Current note"
        ))

        #expect(recognized.draftRevision == transaction.draft.revision + 1)
        #expect(recognized.document.candidates.title?.transcription == "Recognized title")
        #expect(recognized.document.candidates.reportedResults?.transcription == "Recognized results")
        #expect(recognized.document.candidates.conclusion?.transcription == "Recognized conclusion")
        #expect(recognized.document.reviewState?.title == "Recognized title")
        #expect(recognized.document.reviewState?.reportedResults == "Recognized results")
        #expect(recognized.document.reviewState?.conclusion == "Recognized conclusion")
        #expect(recognized.document.reviewState?.userNote == "Current note")
        guard case .manual(let persistedDate) = recognized.document.reviewState?.timelineDateSelection else {
            Issue.record("Expected the user's manual date to survive recognition")
            return
        }
        #expect(persistedDate == ReportDateSemantics.canonicalDate(from: manualDate))
        let saved = try await fixture.reports.draft(transaction.draft.id)
        #expect(saved.memberID == transaction.member.id && saved.revision == transaction.draft.revision + 1)
        #expect(try await fixture.reports.loadDocument(draftID: transaction.draft.id) == recognized.document)
        #expect(await extractor.files.map(\.data) == [Data([1, 2, 3, 4])])
        #expect(recognized.document.blocks.allSatisfy {
            $0.sourceID == transaction.draft.sources.first.id
                && $0.attachmentID == transaction.draft.sources.first.attachmentID
        })
    }

    @Test
    func discardDraftLoadsTheSnapshotAfterTheStoreCommits() async throws {
        let fixture = try SQLiteAppQueryFixture()
        defer { fixture.destroy() }
        let transaction = try await LiveServiceReviewDraft.make(fixture)
        let service = liveService(fixture)

        let command = DiscardDraftCommand(
            draftID: transaction.draft.id,
            expectedRevision: transaction.draft.revision
        )
        let snapshot = try await service.discardDraft(command)

        #expect(try await service.reportPage(query: "", memberID: nil, cursor: nil).items.isEmpty)
        #expect(snapshot.draftCount == 0 && snapshot.reportCount == 0)
        await #expect(throws: (any Error).self) { try await fixture.reports.draft(transaction.draft.id) }
    }

    @Test
    func confirmDraftReextractsStaleMultiSourceOCRWithoutConflatingFileLocalPages() async throws {
        let fixture = try SQLiteAppQueryFixture()
        defer { fixture.destroy() }
        let member = try FamilyMember(displayName: "Synthetic member")
        try await fixture.reports.saveMember(member, replacing: nil)
        var labels: [OCRBlock] = []
        // Both files carry their date on their own first page.
        let draft = try await multiSourceReviewDraft(fixture, files: [
            .init(data: Data("synthetic first page".utf8), name: "synthetic-first.png"),
            .init(data: Data("synthetic second page".utf8), name: "synthetic-second.png"),
        ]) { sources in
            var blocks: [OCRBlock] = []
            for (source, value) in zip(sources.elements, ["2026-07-18", "2026-07-19"]) {
                let label = try OCRBlock(
                    sourceID: source.id, attachmentID: source.attachmentID, filePageNumber: 1,
                    text: "报告日期：",
                    boundingBox: NormalizedRect(x: 0.05, y: 0.8, width: 0.12, height: 0.04),
                    confidence: 0.99, method: .vision, engineVersion: "synthetic")
                labels.append(label)
                blocks.append(label)
                blocks.append(try OCRBlock(
                    sourceID: source.id, attachmentID: source.attachmentID, filePageNumber: 1,
                    text: value,
                    boundingBox: NormalizedRect(x: 0.22, y: 0.8, width: 0.15, height: 0.04),
                    confidence: 0.99, method: .vision, engineVersion: "synthetic"))
            }
            return ImportDraftDocument(blocks: blocks, candidates: ReportCandidates(), candidateExtractionVersion: nil)
        }
        let sources = draft.sources
        let command = ConfirmDraftCommand(
            draftID: draft.id, expectedRevision: draft.revision, memberID: member.id,
            timelineDateSelection: .unknown, title: "", organization: "", department: "", reportType: "",
            reportedResults: "", conclusion: "", abnormalItems: [], userNote: "")

        _ = try await liveService(fixture).confirmDraft(command)

        let record = try await fixture.reports.record(draft.id)
        #expect(record.dateCandidates.count == 2)
        let firstCandidate = try #require(record.dateCandidates.first { $0.id == labels[0].id })
        let secondCandidate = try #require(record.dateCandidates.first { $0.id == labels[1].id })
        #expect(firstCandidate.source.transcription == "2026-07-18")
        #expect(secondCandidate.source.transcription == "2026-07-19")
        #expect(firstCandidate.source.references.map(\.sourceID) == [sources.elements[0].id, sources.elements[0].id])
        #expect(secondCandidate.source.references.map(\.sourceID) == [sources.elements[1].id, sources.elements[1].id])
        #expect(firstCandidate.source.references.map(\.filePageNumber) == [1, 1])
        #expect(secondCandidate.source.references.map(\.filePageNumber) == [1, 1])
        #expect(firstCandidate.source.references.compactMap { $0.logicalPage(in: sources) } == [1, 1])
        #expect(secondCandidate.source.references.compactMap { $0.logicalPage(in: sources) } == [2, 2])
    }

    // MARK: Confirmed records and their originals

    @Test
    func reportPageListsConfirmedReportsAndNeverADraftWaitingForReview() async throws {
        let fixture = try SQLiteAppQueryFixture()
        defer { fixture.destroy() }
        let waiting = try await LiveServiceReviewDraft.make(fixture)
        let confirmed = try await fixture.confirmed(member: waiting.member, seed: "synthetic confirmed report")
        let service = liveService(fixture)

        let snapshot = try await service.refresh()

        #expect(try await service.reportPage(query: "", memberID: nil, cursor: nil).items.map(\.id) == [confirmed.id])
        #expect(snapshot.reportCount == 1 && snapshot.draftCount == 1)
        #expect(try await service.draftPage(states: [.needsReview], cursor: nil).items.map(\.id) == [waiting.draft.id])
    }

    @Test
    func updateRecordCanReplaceUnknownDateAndMissingFieldsWithManualValues() async throws {
        let fixture = try SQLiteAppQueryFixture()
        defer { fixture.destroy() }
        let member = try FamilyMember(displayName: "Synthetic member")
        try await fixture.reports.saveMember(member, replacing: nil)
        let draft = try await LiveServiceReviewDraft.make(fixture, member: member)
        let service = liveService(fixture)
        _ = try await service.confirmDraft(draft.confirmCommand)
        let record = try await fixture.reports.record(draft.draft.id)
        let manualDate = Date(timeIntervalSince1970: 1_784_332_800)

        _ = try await service.updateRecord(UpdateRecordCommand(
            recordID: record.id, expectedRevision: record.revision, memberID: member.id,
            timelineDateSelection: .manual(manualDate), title: "", organization: "", department: "", reportType: "",
            reportedResults: "Manual result", conclusion: "Manual conclusion", abnormalItems: [], userNote: ""))

        let updated = try #require(try await service.loadRecords(ids: [record.id]).records.first)
        #expect(updated.timelineDateCandidate?.source.entryMethod == .manual)
        #expect(updated.reportedResults?.entryMethod == .manual)
        #expect(updated.reportedResults?.transcription == "Manual result")
        #expect(updated.conclusion?.entryMethod == .manual)
        #expect(updated.revision == record.revision + 1)
    }

    @Test
    func updateRecordRejectsAnUnknownDetectedDateCandidate() async throws {
        let fixture = try SQLiteAppQueryFixture()
        defer { fixture.destroy() }
        let member = try FamilyMember(displayName: "Synthetic member")
        try await fixture.reports.saveMember(member, replacing: nil)
        let record = try await fixture.confirmed(member: member, seed: "synthetic unknown date candidate")
        let service = liveService(fixture)

        await #expect(throws: AppServiceError.invalidReview) {
            try await service.updateRecord(UpdateRecordCommand(
                recordID: record.id, expectedRevision: record.revision, memberID: member.id,
                timelineDateSelection: .detected(UUID()), title: "", organization: "", department: "", reportType: "",
                reportedResults: "", conclusion: "", abnormalItems: [], userNote: ""))
        }

        #expect(try await fixture.reports.record(record.id) == record)
    }

    @Test
    func staleRecordEditFromAnotherServiceCannotOverwriteTheNewerSave() async throws {
        let fixture = try SQLiteAppQueryFixture()
        defer { fixture.destroy() }
        let member = try FamilyMember(displayName: "Synthetic member")
        try await fixture.reports.saveMember(member, replacing: nil)
        let record = try await fixture.confirmed(member: member, seed: "synthetic stale edit")
        let first = liveService(fixture)
        let stale = liveService(fixture)
        func command(title: String) -> UpdateRecordCommand {
            UpdateRecordCommand(
                recordID: record.id, expectedRevision: record.revision, memberID: member.id,
                timelineDateSelection: .unknown, title: title, organization: "", department: "", reportType: "",
                reportedResults: "", conclusion: "", abnormalItems: [], userNote: "")
        }

        let firstSnapshot = try await first.updateRecord(command(title: "First saved title"))
        #expect(firstSnapshot.reportCount == 1)
        #expect(try await first.loadRecords(ids: [record.id]).records.first?.revision == record.revision + 1)

        await #expect(throws: AppServiceError.recordChanged) {
            try await stale.updateRecord(command(title: "Stale overwritten title"))
        }

        let persisted = try await fixture.reports.record(record.id)
        #expect(persisted.title?.transcription == "First saved title")
        #expect(persisted.revision == record.revision + 1)
    }

    @Test
    func originalLoadingRejectsADraftBeforeReadingAnyOriginal() async throws {
        let fixture = try SQLiteAppQueryFixture()
        defer { fixture.destroy() }
        let waiting = try await LiveServiceReviewDraft.make(fixture)
        let service = liveService(fixture)
        let library = try await service.refresh().revision
        let readBefore = fixture.store.originalReadMetrics.verifiedReadByteCount

        // A draft is not a record, even though a confirmed record would take over its identifier.
        await #expect(throws: (any Error).self) {
            _ = try await service.loadOriginal(
                recordID: waiting.draft.id, sourceID: waiting.draft.sources.first.id,
                expectedRevision: waiting.draft.revision, expectedLibrary: library)
        }

        #expect(fixture.store.originalReadMetrics.verifiedReadByteCount == readBefore)
    }

    @Test
    func orderedOriginalLoadingReadsTheExactSelectedSource() async throws {
        let fixture = try SQLiteAppQueryFixture()
        defer { fixture.destroy() }
        let member = try FamilyMember(displayName: "Synthetic member")
        try await fixture.reports.saveMember(member, replacing: nil)
        let firstBytes = Data([1])
        let secondBytes = Data(repeating: 2, count: 4_096)
        let draft = try await multiSourceReviewDraft(fixture, files: [
            .init(data: firstBytes, name: "first.png"),
            .init(data: secondBytes, name: "second.pdf", kind: .pdf, contentType: "com.adobe.pdf", pageCount: 2),
        ]) { _ in ImportDraftDocument(blocks: [], candidates: ReportCandidates()) }
        try await fixture.reports.confirm(draftID: draft.id, expectedRevision: draft.revision, record: HealthRecord(
            id: draft.id, memberID: member.id, sources: draft.sources,
            ocrDocumentObjectID: draft.documentObjectID, importState: .confirmed))
        let (firstSource, secondSource) = (draft.sources.elements[0], draft.sources.elements[1])
        let service = liveService(fixture)
        let metrics = fixture.store.originalReadMetrics
        let readBefore = metrics.verifiedReadByteCount

        let first = try await service.loadTestOriginal(recordID: draft.id, sourceID: firstSource.id)
        // Only the selected original was read; the other one is far larger than what was read.
        #expect(metrics.verifiedReadByteCount - readBefore < UInt64(secondBytes.count))
        let second = try await service.loadTestOriginal(recordID: draft.id, sourceID: secondSource.id)

        #expect(first.data == firstBytes)
        #expect(first.sourceID == firstSource.id)
        #expect(second.data == secondBytes)
        #expect(second.sourceID == secondSource.id)
        #expect(second.attachmentID == secondSource.attachmentID)
        #expect(second.displayName == "second.pdf")
        #expect(second.pageCount == 2)
    }

    // MARK: A store that fails after it committed

    @Test
    func confirmDraftReconcilesACommittedExactRecordAfterTheStoreThrows() async throws {
        let fixture = try SQLiteAppQueryFixture()
        defer { fixture.destroy() }
        let transaction = try await LiveServiceReviewDraft.make(fixture)
        let log = StorageCallLog()
        let service = liveService(fixture, drafts: InterceptedDraftStore(fixture.reports, after: { call in
            guard case .confirm = call else { return }
            await log.append(call.name)
            throw LiveServiceSyntheticFailure()
        }))

        let snapshot = try await service.confirmDraft(transaction.confirmCommand)

        #expect(try await service.loadRecords(ids: [transaction.draft.id]).records.map(\.id) == [transaction.draft.id])
        #expect(snapshot.draftCount == 0 && snapshot.reportCount == 1)
        #expect(await log.values == ["confirm"])
    }

    @Test
    func confirmDraftRethrowsWhenReconciliationRecordIsNotAnExactMatch() async throws {
        let fixture = try SQLiteAppQueryFixture()
        defer { fixture.destroy() }
        let transaction = try await LiveServiceReviewDraft.make(fixture)
        // Something else confirms the draft with different content just before this confirmation fails.
        let mismatched = try HealthRecord(
            id: transaction.draft.id, memberID: transaction.member.id, sources: transaction.draft.sources,
            ocrDocumentObjectID: transaction.draft.documentObjectID, importState: .confirmed,
            conclusion: try SourceField.manualEntry("Synthetic mismatch"))
        let service = liveService(fixture, drafts: InterceptedDraftStore(fixture.reports, before: { call in
            guard case .confirm = call else { return }
            try await fixture.reports.confirm(draftID: transaction.draft.id, expectedRevision: transaction.draft.revision, record: mismatched)
            throw LiveServiceSyntheticFailure()
        }))

        await #expect(throws: LiveServiceSyntheticFailure.self) {
            try await service.confirmDraft(transaction.confirmCommand)
        }

        #expect(try await fixture.reports.record(transaction.draft.id) == mismatched)
    }

    @Test
    func discardDraftReconcilesSuccessWhenNeitherDraftNorSameIDRecordRemains() async throws {
        let fixture = try SQLiteAppQueryFixture()
        defer { fixture.destroy() }
        let transaction = try await LiveServiceReviewDraft.make(fixture)
        let service = liveService(fixture, drafts: InterceptedDraftStore(fixture.reports, after: { call in
            if case .discard = call { throw LiveServiceSyntheticFailure() }
        }))

        let snapshot = try await service.discardDraft(DiscardDraftCommand(
            draftID: transaction.draft.id,
            expectedRevision: transaction.draft.revision
        ))

        #expect(snapshot.reportCount == 0)
        #expect(snapshot.draftCount == 0)
    }

    @Test
    func discardDraftRethrowsWhenAConfirmedRecordWithTheDraftIDExists() async throws {
        let fixture = try SQLiteAppQueryFixture()
        defer { fixture.destroy() }
        let transaction = try await LiveServiceReviewDraft.make(fixture)
        let confirmed = try HealthRecord(
            id: transaction.draft.id, memberID: transaction.member.id, sources: transaction.draft.sources,
            ocrDocumentObjectID: transaction.draft.documentObjectID, importState: .confirmed)
        let service = liveService(fixture, drafts: InterceptedDraftStore(fixture.reports, before: { call in
            guard case .discard = call else { return }
            try await fixture.reports.confirm(draftID: transaction.draft.id, expectedRevision: transaction.draft.revision, record: confirmed)
            throw LiveServiceSyntheticFailure()
        }))

        await #expect(throws: LiveServiceSyntheticFailure.self) {
            try await service.discardDraft(DiscardDraftCommand(
                draftID: transaction.draft.id,
                expectedRevision: transaction.draft.revision
            ))
        }

        #expect(try await fixture.reports.record(transaction.draft.id) == confirmed)
    }

    @Test
    func deleteMemberReturnsOnlyReferenceCountsWithoutChangingTheLibrary() async throws {
        let fixture = try SQLiteAppQueryFixture()
        defer { fixture.destroy() }
        let waiting = try await LiveServiceReviewDraft.make(fixture)
        _ = try await fixture.confirmed(member: waiting.member, seed: "synthetic referenced report")
        let service = liveService(fixture)
        // The waiting draft is assigned to the same member, as a saved review does.
        try await service.deferDraft(DeferDraftCommand(
            draftID: waiting.draft.id, expectedRevision: waiting.draft.revision, memberID: waiting.member.id,
            timelineDateSelection: .unknown, title: "", organization: "", department: "", reportType: "",
            reportedResults: "", conclusion: "", abnormalItems: [], userNote: ""))
        let before = try await service.refresh()

        await #expect(throws: AppServiceError.memberStillReferenced(
            recordCount: 1,
            draftCount: 1
        )) {
            try await service.deleteMember(id: waiting.member.id)
        }

        #expect(try await service.refresh().revision == before.revision)
    }
}

// MARK: - Fixture helpers

/// The live service on the fixture's library. `reports` and `drafts` replace the stores the
/// service talks to; both default to the real repository.
func liveService(
    _ fixture: SQLiteAppQueryFixture,
    reports: (any LibraryReportStoring)? = nil,
    drafts: (any ImportDraftStore)? = nil,
    extractor: any TextExtractionService = LiveServiceRecordingExtractor(),
    startupCompleted: Bool = true,
    lifecycle: LibraryLifecycleCoordinator? = nil
) -> LiveAppService {
    let draftStore = drafts ?? fixture.reports
    return LiveAppService(
        reports: reports ?? fixture.reports,
        studies: fixture.studies,
        draftStore: draftStore,
        workflow: ImportWorkflow(store: draftStore, textExtractor: extractor),
        textExtractor: extractor,
        startupCompleted: startupCompleted,
        lifecycle: lifecycle
    )
}

/// Stages one validated file and returns the draft the library made for it.
func stagedDraft(_ fixture: SQLiteAppQueryFixture, _ data: Data) async throws -> ImportDraft.ID {
    guard case .created(let id) = try await fixture.reports.stage(ImportedFileValidator().validate(data: data)) else {
        throw LibraryReportError.invalidDocument
    }
    return id
}

/// A member and one draft waiting for review on a real library.
struct LiveServiceReviewDraft {
    let member: FamilyMember
    let draft: ImportDraft

    /// Stages `original`, records `document` as what recognition produced, and returns the draft.
    static func make(
        _ fixture: SQLiteAppQueryFixture,
        member existing: FamilyMember? = nil,
        document: ImportDraftDocument = ImportDraftDocument(blocks: [], candidates: ReportCandidates()),
        original: Data = Data("synthetic review original".utf8)
    ) async throws -> Self {
        let member: FamilyMember
        if let existing { member = existing } else {
            member = try FamilyMember(displayName: "Synthetic member")
            try await fixture.reports.saveMember(member, replacing: nil)
        }
        let file = try ValidatedImportedFile(data: original, kind: .image, contentTypeIdentifier: "public.png",
                                             sha256Digest: ContentDigest.sha256(original))
        guard case .created(let id) = try await fixture.reports.stage(file) else { throw LibraryReportError.invalidDocument }
        let lease = try await fixture.reports.beginProcessing(draftID: id, attemptID: UUID())
        try await fixture.reports.completeProcessing(lease: lease, document: document)
        return Self(member: member, draft: try await fixture.reports.draft(id))
    }

    var confirmCommand: ConfirmDraftCommand {
        ConfirmDraftCommand(
            draftID: draft.id,
            expectedRevision: draft.revision,
            memberID: member.id,
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
    }
}

/// One original of a draft built by `multiSourceReviewDraft`.
struct LiveServiceSourceFile {
    var data: Data
    var name: String
    var kind: ImportedContentKind = .image
    var contentType = "public.png"
    var pageCount = 1
}

/// A draft waiting for review that owns several originals, as an archived phone selection does.
/// Staging makes one draft per original; this draft takes over all of them and the single
/// drafts are discarded. `document` receives the sources so its blocks can refer to them.
func multiSourceReviewDraft(
    _ fixture: SQLiteAppQueryFixture,
    files: [LiveServiceSourceFile],
    document: (ReportSources) throws -> ImportDraftDocument
) async throws -> ImportDraft {
    var staged: [ImportDraft] = []
    for file in files {
        let validated = try ValidatedImportedFile(data: file.data, kind: file.kind, contentTypeIdentifier: file.contentType,
                                                  sha256Digest: ContentDigest.sha256(file.data), pageCount: file.pageCount)
        guard case .created(let id) = try await fixture.reports.stage(validated) else { throw LibraryReportError.invalidDocument }
        staged.append(try await fixture.reports.draft(id))
    }
    let sources = try ReportSources(zip(staged, files).map { single, file in
        try ReportSource(attachmentID: single.sources.first.attachmentID, displayName: file.name, pageCount: file.pageCount)
    })
    let draft = ImportDraft(sources: sources, state: .needsReview, documentObjectID: UUID())
    let content = try document(sources)
    try fixture.store.write { db in
        let digest = try SQLiteReportRows.saveDocument(content, id: draft.documentObjectID!, revision: draft.revision, sources: sources, db)
        try SQLiteReportRows.saveDraft(draft, documentHash: digest, db, replaceSources: true)
        try SQLiteLibraryState.advance(in: db)
    }
    for single in staged { try await fixture.reports.discard(draftID: single.id, expectedRevision: single.revision) }
    return draft
}

func liveServicePNG(red: CGFloat = 1) throws -> Data {
    let context = try #require(CGContext(
        data: nil,
        width: 8,
        height: 8,
        bitsPerComponent: 8,
        bytesPerRow: 32,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(red: red, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(
        data,
        UTType.png.identifier as CFString,
        1,
        nil
    ))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

struct LiveServiceSyntheticFailure: Error, Equatable {}

/// Returns fixed blocks and remembers every file it was asked to read. Without blocks it fails,
/// which marks a test that must not reach recognition.
actor LiveServiceRecordingExtractor: TextExtractionService {
    private let blocks: [OCRBlock]?
    private(set) var files: [ValidatedImportedFile] = []

    init(blocks: [OCRBlock]? = nil) {
        self.blocks = blocks
    }

    func extractText(from file: ValidatedImportedFile) async throws -> [OCRBlock] {
        files.append(file)
        guard let blocks else { throw LiveServiceSyntheticFailure() }
        return blocks
    }
}

/// Blocks inside recognition until resumed, and records whether it was cancelled meanwhile.
actor LiveServiceGatedExtractor: TextExtractionService {
    private let gate = AsyncOperationGate()
    private let fails: Bool
    private(set) var observedCancellation = false
    private(set) var callCount = 0

    init(fails: Bool = false) { self.fails = fails }

    func extractText(from file: ValidatedImportedFile) async throws -> [OCRBlock] {
        _ = file
        callCount += 1
        await gate.wait()
        do {
            try Task.checkCancellation()
        } catch {
            observedCancellation = true
            throw error
        }
        if fails && callCount == 1 { throw LiveServiceSyntheticFailure() }
        return []
    }

    func waitUntilEntered() async {
        guard await gate.waitUntilStarted() else {
            Issue.record("Timed out waiting for report OCR")
            return
        }
    }

    func resume() async {
        await gate.open()
    }
}

actor LiveServiceCompletionProbe {
    private(set) var isCompleted = false
    private(set) var count = 0

    func markCompleted() {
        isCompleted = true
        count += 1
    }
}

/// Fails the first two attempts to commit one processing transition of one draft: starting
/// (`processing`) or completing (`needsReview`). The draft is the first one that reaches it.
actor LiveServiceCommitFailureInjector {
    let state: ImportState
    private(set) var failureCount = 0
    private(set) var failedDraftID: ImportDraft.ID?

    init(state: ImportState) { self.state = state }

    private func transition(_ call: InterceptedDraftStore.Call) -> (ImportDraft.ID, ImportState)? {
        switch call {
        case .beginProcessing(let id): (id, .processing)
        case .completeProcessing(let id): (id, .needsReview)
        case .failProcessing(let id): (id, .failed)
        default: nil
        }
    }

    func isRetry(_ call: InterceptedDraftStore.Call) -> Bool {
        guard let (id, state) = transition(call) else { return false }
        return failureCount == 1 && id == failedDraftID && state == .processing
    }

    func beforeCommit(_ call: InterceptedDraftStore.Call) throws {
        guard let (id, next) = transition(call), next == state, failureCount < 2,
              failedDraftID == nil || id == failedDraftID else { return }
        failedDraftID = id
        failureCount += 1
        throw LiveServiceSyntheticFailure()
    }
}

actor LiveServiceDestroySpy: VaultDestroyServicing {
    private(set) var callCount = 0

    func destroyCurrentVault() async throws {
        callCount += 1
    }
}
