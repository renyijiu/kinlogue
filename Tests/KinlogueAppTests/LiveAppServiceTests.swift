import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import KinlogueApp
@testable import KinlogueCore
@testable import KinloguePlatform

struct LiveAppServiceTests {
    @Test
    func defaultEnvironmentCreatesOnlyThePrivateVaultParent() throws {
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(
                "kinlogue-live-environment-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(
            at: base,
            withIntermediateDirectories: false
        )
        let identity = try AppRuntimeIdentity.resolve(
            bundleInfo: [
                "CFBundleIdentifier": AppRuntimeIdentity.productionBundleIdentifier,
            ],
            arguments: ["Kinlogue"],
            trustedApplicationSupportDirectory: base
        )

        _ = try LiveAppServiceEnvironment.makeDefault(identity: identity)

        let parent = base.appendingPathComponent("Kinlogue", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: parent.path))
        #expect(!FileManager.default.fileExists(atPath: identity.sourceVault.rootURL.path))
        let permissions = try FileManager.default.attributesOfItem(atPath: parent.path)[
            .posixPermissions
        ] as? NSNumber
        #expect(permissions?.intValue == 0o700)
    }

    @Test
    func defaultEnvironmentBootstrapsAndDeletesWithoutExternalCredentials() async throws {
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(
                "kinlogue-plaintext-environment-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(
            at: base,
            withIntermediateDirectories: false
        )
        let identity = try AppRuntimeIdentity.resolve(
            bundleInfo: [
                "CFBundleIdentifier": AppRuntimeIdentity.productionBundleIdentifier,
            ],
            arguments: ["Kinlogue"],
            trustedApplicationSupportDirectory: base
        )
        let environment = try LiveAppServiceEnvironment.makeDefault(identity: identity)

        let snapshot = try await environment.dataService.bootstrap()

        #expect(snapshot.generation == 1)
        #expect(snapshot.members.isEmpty)
        #expect(snapshot.records.isEmpty)
        #expect(snapshot.drafts.isEmpty)
        let inbox = try await environment.lanInboxService.initialize()
        let catalog = try await PlaintextVault(
            rootURL: identity.sourceVault.rootURL
        ).loadCatalog()
        #expect(inbox.snapshot.vaultID == catalog.vaultID)
        #expect(inbox.snapshot.items.isEmpty)
        let manifestURL = identity.sourceVault.rootURL.appendingPathComponent("library.json")
        let manifest = try Data(contentsOf: manifestURL)
        #expect(manifest.range(of: Data("KLGPLAINTEXT1".utf8)) != nil)

        try await environment.destroyService.destroyCurrentVault()
        #expect(!FileManager.default.fileExists(atPath: identity.sourceVault.rootURL.path))
        do {
            _ = try await environment.lanInboxService.refresh()
            Issue.record("A revoked LAN runtime reopened the deleted root")
        } catch {
            #expect(!FileManager.default.fileExists(atPath: identity.sourceVault.rootURL.path))
        }
    }

    @Test
    func restoreRevocationCancelsAndDrainsBlockedReportOCRBeforeReturning() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kinlogue-report-restore-lifecycle-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: parent) }
        let vault = try PlaintextVault(
            rootURL: parent.appendingPathComponent("Vault", isDirectory: true)
        )
        _ = try await vault.initialize()
        let store = VaultImportDraftStore(vault: vault)
        let staged = try await store.stage(
            ImportedFileValidator().validate(data: try reportLifecyclePNG())
        )
        guard case .created(let draftID) = staged else {
            Issue.record("Expected a newly staged synthetic report")
            return
        }
        let extractor = ReportLifecycleTextExtractor()
        let lifecycle = LibraryLifecycleCoordinator()
        let service = LiveAppService(
            vault: vault,
            draftStore: store,
            workflow: ImportWorkflow(store: store, textExtractor: extractor),
            textExtractor: extractor,
            startupCompleted: true,
            lifecycle: lifecycle
        )

        let importing = Task { try await service.retryDraft(id: draftID) }
        await extractor.waitUntilEntered()
        let revokeCompleted = ReportLifecycleCompletionProbe()
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
        let settled = try await vault.loadCatalog()
        try await Task.sleep(for: .milliseconds(30))
        let later = try await vault.loadCatalog()

        #expect(await extractor.observedCancellation)
        #expect(settled == later)
        #expect(settled.importDrafts.count == 1)
        #expect(settled.importDrafts.first?.state == .processing)
    }

    @Test
    func defaultEnvironmentRejectsCatalogV2WithoutRewritingTheVault() async throws {
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(
                "kinlogue-current-catalog-environment-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(
            at: base,
            withIntermediateDirectories: false
        )
        let identity = try AppRuntimeIdentity.resolve(
            bundleInfo: [
                "CFBundleIdentifier": AppRuntimeIdentity.productionBundleIdentifier,
            ],
            arguments: ["Kinlogue"],
            trustedApplicationSupportDirectory: base
        )
        let environment = try LiveAppServiceEnvironment.makeDefault(identity: identity)
        let vault = try PlaintextVault(rootURL: identity.sourceVault.rootURL)
        _ = try await vault.initialize()
        let manifestURL = identity.sourceVault.rootURL.appendingPathComponent("library.json")
        try rewriteCatalogVersionForStartupTest(2, manifestURL: manifestURL)
        let before = try startupTestVaultContents(at: identity.sourceVault.rootURL)

        await #expect(throws: AppServiceError.vaultUnavailable) {
            _ = try await environment.dataService.bootstrap()
        }
        #expect(try startupTestVaultContents(at: identity.sourceVault.rootURL) == before)
    }

    @Test
    func vaultDeletionWaitsForReceiverStartupToExit() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kinlogue-lan-start-delete-race-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Vault", isDirectory: true)
        let vault = try PlaintextVault(rootURL: root)
        _ = try await vault.initialize()
        let gate = AsyncOperationGate()
        let lifecycle = LibraryLifecycleCoordinator()
        let revocationGate = try await installRevocationGate(on: lifecycle)
        let receiver = LANReceiver(rootURL: root)
        let service = LiveLANInboxService(
            rootURL: root,
            vault: vault,
            lifecycle: lifecycle,
            dependencies: .init(
                receiver: receiver,
                receiverStart: { receiver, _ in
                    await gate.wait()
                    return try await receiver.start(
                        at: .init(interfaceName: "lo0", host: "127.0.0.1"),
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
                host: "192.168.1.2"
            ))
        }
        guard await gate.waitUntilStarted() else {
            start.cancel()
            await gate.open()
            _ = try? await start.value
            Issue.record("Timed out waiting for receiver startup")
            return
        }
        let destroy = LANVaultDestroySpy()
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
            Issue.record("Receiver startup unexpectedly survived vault deletion")
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

    @Test
    func bootstrapFullyValidatesBeforeTheFinalCatalogAccess() async throws {
        let catalog = try syntheticCatalog()
        let fixture = try LiveAppServiceFixture(
            state: try readyState(for: catalog),
            initializedCatalog: catalog,
            catalogReads: [.success(catalog)],
            requiresBootstrap: true
        )

        _ = try await fixture.service.bootstrap()

        #expect(await fixture.bootstrapCalls.values == [
            .loadValidatedCatalog,
            .loadCatalog,
        ])
    }

    @Test
    func concurrentVaultAccessWaitsForTheSharedStartupTask() async throws {
        let catalog = try syntheticCatalog()
        let calls = LiveAppServiceBootstrapCallRecorder()
        let inspectGate = AsyncOperationGate()
        let vault = LiveAppServiceVaultStub(
            state: try readyState(for: catalog),
            initializedCatalog: catalog,
            catalogReads: [
                .success(catalog),
                .success(catalog),
            ],
            commitErrorAfterApplying: false,
            bootstrapCalls: calls,
            inspectGate: inspectGate
        )
        let draftStore = LiveAppServiceDraftStoreStub()
        let service = LiveAppService(
            vault: vault,
            draftStore: draftStore,
            workflow: ImportWorkflow(
                store: draftStore,
                textExtractor: LiveAppServiceTextExtractorStub()
            )
        )

        let bootstrap = Task { try await service.bootstrap() }
        guard await inspectGate.waitUntilStarted() else {
            bootstrap.cancel()
            await inspectGate.open()
            _ = try? await bootstrap.value
            Issue.record("Timed out waiting for validated Vault startup")
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
            await inspectGate.open()
            _ = try? await bootstrap.value
            _ = try? await refresh.value
            Issue.record("Timed out waiting for refresh to join Vault startup")
            return
        }

        #expect(await calls.values == [.loadValidatedCatalog])
        #expect(await vault.callCounts == LiveAppServiceVaultCallCounts(
            initialize: 0,
            loadValidatedCatalog: 0,
            loadCatalog: 0,
            commit: 0
        ))

        await refreshWaitGate.open()
        await inspectGate.open()
        _ = try await bootstrap.value
        #expect(try await refresh.value.generation == catalog.generation)
        #expect(await vault.callCounts.loadCatalog == 2)
    }

    @Test
    func repeatedBootstrapReloadsTheVaultInsteadOfReturningCachedStartupState() async throws {
        let catalog = try syntheticCatalog()
        let fixture = try LiveAppServiceFixture(
            state: try readyState(for: catalog),
            initializedCatalog: catalog,
            catalogReads: [
                .success(catalog),
                .failure(.catalogRead),
            ],
            requiresBootstrap: true
        )

        _ = try await fixture.service.bootstrap()
        await #expect(throws: LiveAppServiceFixtureError.catalogRead) {
            try await fixture.service.bootstrap()
        }

        #expect(await fixture.vault.callCounts.loadCatalog == 2)
    }

    @Test
    func cancellingOneStartupWaiterDoesNotCancelTheSharedStartupTask() async throws {
        let catalog = try syntheticCatalog()
        let calls = LiveAppServiceBootstrapCallRecorder()
        let inspectGate = AsyncOperationGate()
        let vault = LiveAppServiceVaultStub(
            state: try readyState(for: catalog),
            initializedCatalog: catalog,
            catalogReads: [.success(catalog)],
            commitErrorAfterApplying: false,
            bootstrapCalls: calls,
            inspectGate: inspectGate
        )
        let draftStore = LiveAppServiceDraftStoreStub()
        let service = LiveAppService(
            vault: vault,
            draftStore: draftStore,
            workflow: ImportWorkflow(
                store: draftStore,
                textExtractor: LiveAppServiceTextExtractorStub()
            )
        )

        let bootstrap = Task { try await service.bootstrap() }
        guard await inspectGate.waitUntilStarted() else {
            bootstrap.cancel()
            await inspectGate.open()
            _ = try? await bootstrap.value
            Issue.record("Timed out waiting for validated Vault startup")
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
            await inspectGate.open()
            _ = try? await bootstrap.value
            _ = try? await cancelledRefresh.value
            Issue.record("Timed out waiting for refresh to join Vault startup")
            return
        }
        cancelledRefresh.cancel()
        await refreshWaitGate.open()
        await inspectGate.open()

        #expect(try await bootstrap.value.generation == catalog.generation)
        await #expect(throws: CancellationError.self) {
            try await cancelledRefresh.value
        }
        #expect(await vault.callCounts.loadCatalog == 1)
    }

    @Test(arguments: [
        VaultAccessState.operationInProgress,
        VaultAccessState.legacyEncrypted,
        VaultAccessState.damaged,
        VaultAccessState.unsupportedVersion,
    ])
    func bootstrapFailsClosedForUnusableVaultStates(_ state: VaultAccessState) async throws {
        let fixture = try LiveAppServiceFixture(
            state: state,
            requiresBootstrap: true
        )

        await #expect(throws: AppServiceError.vaultUnavailable) {
            try await fixture.service.bootstrap()
        }

        let vaultCalls = await fixture.vault.callCounts
        #expect(vaultCalls.initialize == 0)
        #expect(vaultCalls.loadValidatedCatalog == 1)
        #expect(vaultCalls.loadCatalog == 0)
        #expect(vaultCalls.commit == 0)
        #expect(await fixture.draftStore.resumableCallCount == 0)
    }

    @Test
    func startupSynchronizationTimesOutWhenInspectionIsNeverReached() async {
        let inspectGate = AsyncOperationGate()

        #expect(!(await inspectGate.waitUntilStarted(timeout: .milliseconds(20))))
    }

    @Test
    func absentVaultInitializesExactlyOnceAndReturnsThePersistedSnapshot() async throws {
        let catalog = try syntheticCatalog()
        let fixture = try LiveAppServiceFixture(
            state: .absent,
            initializedCatalog: catalog,
            catalogReads: [.success(catalog)],
            requiresBootstrap: true
        )

        let snapshot = try await fixture.service.bootstrap()

        #expect(snapshot == AppSnapshot(
            generation: catalog.generation,
            members: catalog.members,
            records: catalog.records,
            drafts: catalog.importDrafts.map(DraftSummary.init)
        ))
        let vaultCalls = await fixture.vault.callCounts
        #expect(vaultCalls.initialize == 1)
        #expect(vaultCalls.loadCatalog == 1)
        #expect(vaultCalls.commit == 0)
        #expect(await fixture.draftStore.resumableCallCount == 0)
    }

    @Test
    func readyVaultPropagatesFinalReadFailureAfterRecoveryInsteadOfReturningStaleSnapshot() async throws {
        let catalog = try syntheticCatalog()
        let fixture = try LiveAppServiceFixture(
            state: try readyState(for: catalog),
            initializedCatalog: catalog,
            catalogReads: [.failure(.catalogRead)],
            requiresBootstrap: true
        )

        await #expect(throws: LiveAppServiceFixtureError.catalogRead) {
            try await fixture.service.bootstrap()
        }

        let vaultCalls = await fixture.vault.callCounts
        #expect(vaultCalls.initialize == 0)
        #expect(vaultCalls.loadValidatedCatalog == 1)
        #expect(vaultCalls.loadCatalog == 1)
        #expect(vaultCalls.commit == 0)
        #expect(await fixture.draftStore.resumableCallCount == 0)
    }

    @Test
    func bootstrapUsesTheValidatedCatalogInsteadOfEnumeratingDraftsAgain() async throws {
        let catalog = try syntheticCatalog()
        let fixture = try LiveAppServiceFixture(
            state: try readyState(for: catalog),
            initializedCatalog: catalog,
            catalogReads: [.success(catalog)],
            resumableError: .recoveryRead,
            requiresBootstrap: true
        )

        _ = try await fixture.service.bootstrap()

        #expect(await fixture.draftStore.resumableCallCount == 0)
    }

    @Test
    func bootstrapPropagatesRecoveryProcessingFailureAndRetriesOnNextCall() async throws {
        let transaction = try SyntheticDraftTransaction()
        let resumableDraft = ImportDraft(attachmentID: transaction.attachment.id)
        let catalog = try VaultCatalog(
            vaultID: transaction.beforeCommit.vaultID,
            generation: transaction.beforeCommit.generation,
            members: [transaction.member],
            attachments: [transaction.attachment],
            importDrafts: [resumableDraft]
        )
        let fixture = try LiveAppServiceFixture(
            state: try readyState(for: catalog),
            initializedCatalog: catalog,
            beginProcessingError: .recoveryProcessing,
            requiresBootstrap: true
        )

        for _ in 0..<2 {
            await #expect(throws: LiveAppServiceFixtureError.recoveryProcessing) {
                try await fixture.service.bootstrap()
            }
        }

        #expect(await fixture.draftStore.resumableCallCount == 0)
        #expect(await fixture.draftStore.beginProcessingCallCount == 2)
    }

    @Test
    func confirmDraftReturnsTheStoreCommittedSnapshotWithoutASecondCatalogRead() async throws {
        let transaction = try SyntheticDraftTransaction()
        let fixture = try LiveAppServiceFixture(
            state: try readyState(for: transaction.beforeCommit),
            initializedCatalog: transaction.beforeCommit,
            catalogReads: [.success(transaction.beforeCommit)],
            draftDocument: transaction.document,
            confirmCatalog: transaction.afterCommit
        )
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

        let snapshot = try await fixture.service.confirmDraft(command)

        #expect(snapshot.records.map(\.id) == [transaction.committedRecord.id])
        #expect(snapshot.drafts.isEmpty)
        #expect(await fixture.draftStore.confirmCallCount == 1)
        #expect(
            await fixture.draftStore.lastConfirmedExpectedRevision
                == command.expectedRevision
        )
        let vaultCalls = await fixture.vault.callCounts
        #expect(vaultCalls.loadCatalog == 1)
        #expect(vaultCalls.commit == 0)
    }

    @Test
    func confirmDraftRejectsAStaleRevisionBeforeLoadingTheDraftDocument() async throws {
        let transaction = try SyntheticDraftTransaction()
        let fixture = try LiveAppServiceFixture(
            state: try readyState(for: transaction.beforeCommit),
            initializedCatalog: transaction.beforeCommit,
            catalogReads: [.success(transaction.beforeCommit)]
        )
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
            try await fixture.service.confirmDraft(staleCommand)
        }

        #expect(await fixture.draftStore.confirmCallCount == 0)
        #expect(await fixture.vault.callCounts.loadCatalog == 1)
    }

    @Test
    func deferDraftPersistsTheCompleteReviewStateThroughTheDraftStore() async throws {
        let transaction = try SyntheticDraftTransaction()
        let fixture = try LiveAppServiceFixture(
            state: try readyState(for: transaction.beforeCommit),
            initializedCatalog: transaction.beforeCommit,
            catalogReads: [.success(transaction.beforeCommit)],
            draftDocument: transaction.document
        )
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

        try await fixture.service.deferDraft(command)

        #expect(await fixture.draftStore.lastSavedReviewMemberID == transaction.member.id)
        let canonicalDate = try #require(ReportDateSemantics.canonicalDate(from: manualDate))
        #expect(await fixture.draftStore.lastSavedReviewState == ImportDraftReviewState(
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
        let transaction = try SyntheticDraftTransaction()
        let fixture = try LiveAppServiceFixture(
            state: try readyState(for: transaction.beforeCommit),
            initializedCatalog: transaction.beforeCommit,
            catalogReads: [.success(transaction.beforeCommit)],
            draftDocument: transaction.document,
            confirmCatalog: transaction.afterCommit
        )
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

        _ = try await fixture.service.confirmDraft(command)

        let record = try #require(await fixture.draftStore.lastConfirmedRecord)
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
        let transaction = try SyntheticDraftTransaction()
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
        let fixture = try LiveAppServiceFixture(
            state: try readyState(for: transaction.beforeCommit),
            initializedCatalog: transaction.beforeCommit,
            catalogReads: [.success(transaction.beforeCommit)],
            draftDocument: ImportDraftDocument(
                blocks: [],
                candidates: ReportCandidates(dateCandidates: [candidate])
            ),
            confirmCatalog: transaction.afterCommit
        )
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

        _ = try await fixture.service.confirmDraft(command)

        let record = try #require(await fixture.draftStore.lastConfirmedRecord)
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
        let transaction = try SyntheticDraftTransaction()
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
        let fixture = try LiveAppServiceFixture(
            state: try readyState(for: transaction.beforeCommit),
            initializedCatalog: transaction.beforeCommit,
            catalogReads: [.success(transaction.beforeCommit)],
            draftDocument: legacyDocument,
            confirmCatalog: transaction.afterCommit
        )
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

        _ = try await fixture.service.confirmDraft(command)

        let record = try #require(await fixture.draftStore.lastConfirmedRecord)
        #expect(record.conclusion?.entryMethod == nil)
        #expect(record.conclusion?.references.map(\.blockID) == [body.id])
    }

    @Test
    func confirmDraftReextractsStaleMultiSourceOCRWithoutConflatingFileLocalPages() async throws {
        let member = try FamilyMember(displayName: "Synthetic member")
        let firstAttachment = try Attachment(
            contentTypeIdentifier: "public.png",
            byteCount: 4,
            sha256Digest: Data(repeating: 0x31, count: 32)
        )
        let secondAttachment = try Attachment(
            contentTypeIdentifier: "public.png",
            byteCount: 4,
            sha256Digest: Data(repeating: 0x32, count: 32)
        )
        let firstSource = try ReportSource(
            attachmentID: firstAttachment.id,
            displayName: "synthetic-first.png",
            pageCount: 1
        )
        let secondSource = try ReportSource(
            attachmentID: secondAttachment.id,
            displayName: "synthetic-second.png",
            pageCount: 1
        )
        let sources = try ReportSources([firstSource, secondSource])
        let documentObjectID = UUID()
        let draft = ImportDraft(
            sources: sources,
            state: .needsReview,
            documentObjectID: documentObjectID
        )
        let firstLabel = try OCRBlock(
            sourceID: firstSource.id,
            attachmentID: firstAttachment.id,
            filePageNumber: 1,
            text: "报告日期：",
            boundingBox: NormalizedRect(x: 0.05, y: 0.8, width: 0.12, height: 0.04),
            confidence: 0.99,
            method: .vision,
            engineVersion: "synthetic"
        )
        let firstValue = try OCRBlock(
            sourceID: firstSource.id,
            attachmentID: firstAttachment.id,
            filePageNumber: 1,
            text: "2026-07-18",
            boundingBox: NormalizedRect(x: 0.22, y: 0.8, width: 0.15, height: 0.04),
            confidence: 0.99,
            method: .vision,
            engineVersion: "synthetic"
        )
        let secondLabel = try OCRBlock(
            sourceID: secondSource.id,
            attachmentID: secondAttachment.id,
            filePageNumber: 1,
            text: "报告日期：",
            boundingBox: NormalizedRect(x: 0.05, y: 0.8, width: 0.12, height: 0.04),
            confidence: 0.99,
            method: .vision,
            engineVersion: "synthetic"
        )
        let secondValue = try OCRBlock(
            sourceID: secondSource.id,
            attachmentID: secondAttachment.id,
            filePageNumber: 1,
            text: "2026-07-19",
            boundingBox: NormalizedRect(x: 0.26, y: 0.8, width: 0.15, height: 0.04),
            confidence: 0.99,
            method: .vision,
            engineVersion: "synthetic"
        )
        let staleDocument = ImportDraftDocument(
            blocks: [firstLabel, firstValue, secondLabel, secondValue],
            candidates: ReportCandidates(),
            candidateExtractionVersion: nil
        )
        let beforeCommit = try VaultCatalog(
            vaultID: UUID(),
            generation: 1,
            members: [member],
            attachments: [firstAttachment, secondAttachment],
            importDrafts: [draft]
        )
        let committedRecord = try HealthRecord(
            id: draft.id,
            memberID: member.id,
            sources: sources,
            ocrDocumentObjectID: documentObjectID,
            importState: .confirmed
        )
        let afterCommit = try VaultCatalog(
            vaultID: beforeCommit.vaultID,
            generation: 2,
            members: [member],
            records: [committedRecord],
            attachments: [firstAttachment, secondAttachment]
        )
        let fixture = try LiveAppServiceFixture(
            state: try readyState(for: beforeCommit),
            initializedCatalog: beforeCommit,
            catalogReads: [.success(beforeCommit)],
            draftDocument: staleDocument,
            confirmCatalog: afterCommit
        )
        let command = ConfirmDraftCommand(
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

        _ = try await fixture.service.confirmDraft(command)

        let record = try #require(await fixture.draftStore.lastConfirmedRecord)
        #expect(record.dateCandidates.count == 2)
        let firstCandidate = try #require(record.dateCandidates.first {
            $0.id == firstLabel.id
        })
        let secondCandidate = try #require(record.dateCandidates.first {
            $0.id == secondLabel.id
        })
        #expect(firstCandidate.source.transcription == "2026-07-18")
        #expect(secondCandidate.source.transcription == "2026-07-19")
        #expect(firstCandidate.source.references.map(\.sourceID) == [
            firstSource.id,
            firstSource.id,
        ])
        #expect(secondCandidate.source.references.map(\.sourceID) == [
            secondSource.id,
            secondSource.id,
        ])
        #expect(firstCandidate.source.references.map(\.filePageNumber) == [1, 1])
        #expect(secondCandidate.source.references.map(\.filePageNumber) == [1, 1])
        #expect(firstCandidate.source.references.compactMap {
            $0.logicalPage(in: sources)
        } == [1, 1])
        #expect(secondCandidate.source.references.compactMap {
            $0.logicalPage(in: sources)
        } == [2, 2])
    }

    @Test
    func loadReviewShowsRefreshedCandidatesForAnExistingLegacyDraft() async throws {
        let transaction = try SyntheticDraftTransaction()
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
        let fixture = try LiveAppServiceFixture(
            state: try readyState(for: transaction.beforeCommit),
            initializedCatalog: transaction.beforeCommit,
            catalogReads: [.success(transaction.beforeCommit)],
            draftDocument: ImportDraftDocument(
                blocks: [heading, body],
                candidates: ReportCandidates(),
                candidateExtractionVersion: nil
            ),
            readObjectData: Data([1, 2, 3, 4])
        )

        let review = try await fixture.service.loadReview(draftID: transaction.draft.id)

        #expect(review.document.candidates.conclusion?.transcription == "Synthetic refreshed conclusion")
        #expect(review.document.candidates.conclusion?.references.map(\.blockID) == [body.id])
        #expect(review.original.data == Data([1, 2, 3, 4]))
        #expect(await fixture.draftStore.loadReviewSnapshotCallCount == 1)
        #expect(await fixture.draftStore.loadDocumentCallCount == 0)
        #expect(await fixture.vault.callCounts.loadCatalog == 0)
    }

    @Test
    func loadReviewRefreshesCandidatesFromThePreviousExtractionVersion() async throws {
        let transaction = try SyntheticDraftTransaction()
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
        let fixture = try LiveAppServiceFixture(
            state: try readyState(for: transaction.beforeCommit),
            initializedCatalog: transaction.beforeCommit,
            catalogReads: [.success(transaction.beforeCommit)],
            draftDocument: ImportDraftDocument(
                blocks: [findingHeading, findingBody, conclusionHeading, conclusionBody, examinationTime],
                candidates: ReportCandidates(),
                candidateExtractionVersion: ReportCandidateExtractor.extractionVersion - 1
            ),
            readObjectData: Data([1, 2, 3, 4])
        )

        let review = try await fixture.service.loadReview(draftID: transaction.draft.id)

        #expect(review.document.candidateExtractionVersion == ReportCandidateExtractor.extractionVersion)
        #expect(review.document.candidates.reportedResults?.transcription == "Synthetic refreshed finding")
        #expect(review.document.candidates.conclusion?.transcription == "Synthetic refreshed conclusion")
        #expect(review.document.candidates.dateCandidates.first?.kind == .examination)
    }

    @Test
    func loadReviewPreservesPopulatedLegacyCandidatesOverReextraction() async throws {
        let transaction = try SyntheticDraftTransaction()
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
        let fixture = try LiveAppServiceFixture(
            state: try readyState(for: transaction.beforeCommit),
            initializedCatalog: transaction.beforeCommit,
            catalogReads: [.success(transaction.beforeCommit)],
            draftDocument: ImportDraftDocument(
                blocks: [heading, body, dateBlock],
                candidates: ReportCandidates(
                    dateCandidates: [storedDateCandidate],
                    reportedResults: storedResults,
                    conclusion: storedConclusion
                ),
                candidateExtractionVersion: nil
            ),
            readObjectData: Data([1, 2, 3, 4])
        )

        let review = try await fixture.service.loadReview(draftID: transaction.draft.id)

        #expect(review.document.candidates.reportedResults == storedResults)
        #expect(review.document.candidates.reportedResults?.entryMethod == .manual)
        #expect(review.document.candidates.conclusion == storedConclusion)
        #expect(review.document.candidates.conclusion?.references == [storedReference])
        #expect(review.document.candidates.dateCandidates == [storedDateCandidate])
    }

    @Test
    func explicitRecognitionRerunsOCRAndPersistsRecognizedValuesOverSavedEdits() async throws {
        let transaction = try SyntheticDraftTransaction()
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
        let extractor = LiveAppServiceTextExtractorStub(blocks: blocks)
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
        let fixture = try LiveAppServiceFixture(
            state: try readyState(for: transaction.beforeCommit),
            initializedCatalog: transaction.beforeCommit,
            catalogReads: [
                .success(transaction.beforeCommit),
                .success(transaction.beforeCommit),
            ],
            draftDocument: oldDocument,
            readObjectDataByID: [transaction.attachment.id: Data([1, 2, 3, 4])],
            textExtractor: extractor
        )

        let recognized = try await fixture.service.recognizeReview(RecognizeReviewCommand(
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
        #expect(await fixture.draftStore.lastSavedReviewMemberID == transaction.member.id)
        #expect(await fixture.draftStore.lastSavedReviewDocument == recognized.document)
        #expect(await fixture.draftStore.lastSavedReviewExpectedRevision == transaction.draft.revision)
        #expect(await extractor.files.map(\.data) == [Data([1, 2, 3, 4])])
        #expect(recognized.document.blocks.allSatisfy {
            $0.sourceID == transaction.draft.sources.first.id
                && $0.attachmentID == transaction.attachment.id
        })
    }

    @Test
    func discardDraftReturnsTheStoreCommittedSnapshotWithoutLoadingTheCatalog() async throws {
        let transaction = try SyntheticDraftTransaction()
        let fixture = try LiveAppServiceFixture(
            state: try readyState(for: transaction.beforeCommit),
            initializedCatalog: transaction.beforeCommit,
            discardCatalog: transaction.afterCommit
        )

        let command = DiscardDraftCommand(
            draftID: transaction.draft.id,
            expectedRevision: transaction.draft.revision
        )
        let snapshot = try await fixture.service.discardDraft(command)

        #expect(snapshot.records.map(\.id) == [transaction.committedRecord.id])
        #expect(snapshot.drafts.isEmpty)
        #expect(await fixture.draftStore.discardCallCount == 1)
        #expect(await fixture.draftStore.lastDiscardedDraftID == command.draftID)
        #expect(await fixture.draftStore.lastDiscardedExpectedRevision == command.expectedRevision)
        let vaultCalls = await fixture.vault.callCounts
        #expect(vaultCalls.loadCatalog == 0)
        #expect(vaultCalls.commit == 0)
    }

    @Test
    func refreshProjectsOnlyConfirmedRecordsFromTheCatalog() async throws {
        let projection = try SyntheticRecordProjection()
        let fixture = try LiveAppServiceFixture(
            state: try readyState(for: projection.catalog),
            initializedCatalog: projection.catalog,
            catalogReads: [.success(projection.catalog)]
        )

        let snapshot = try await fixture.service.refresh()

        #expect(snapshot.records.map(\.id) == [projection.confirmed.id])
        #expect(!snapshot.records.contains { $0.id == projection.needsReview.id })
        #expect(await fixture.vault.callCounts.loadCatalog == 1)
    }

    @Test
    func updateRecordCanReplaceUnknownDateAndMissingFieldsWithManualValues() async throws {
        let member = try FamilyMember(displayName: "Synthetic member")
        let attachment = try Attachment(
            contentTypeIdentifier: "public.png",
            byteCount: 4,
            sha256Digest: Data(repeating: 0x44, count: 32)
        )
        let record = try HealthRecord(
            memberID: member.id,
            attachmentID: attachment.id,
            importState: .confirmed
        )
        let catalog = try VaultCatalog(
            vaultID: UUID(),
            generation: 1,
            members: [member],
            records: [record],
            attachments: [attachment]
        )
        let fixture = try LiveAppServiceFixture(
            state: try readyState(for: catalog),
            initializedCatalog: catalog,
            catalogReads: [.success(catalog)]
        )
        let manualDate = Date(timeIntervalSince1970: 1_784_332_800)

        let snapshot = try await fixture.service.updateRecord(UpdateRecordCommand(
            recordID: record.id,
            expectedRevision: record.revision,
            memberID: member.id,
            timelineDateSelection: .manual(manualDate),
            title: "",
            organization: "",
            department: "",
            reportType: "",
            reportedResults: "Manual result",
            conclusion: "Manual conclusion",
            abnormalItems: [],
            userNote: ""
        ))

        let updated = try #require(snapshot.records.first)
        #expect(updated.timelineDateCandidate?.source.entryMethod == .manual)
        #expect(updated.reportedResults?.entryMethod == .manual)
        #expect(updated.reportedResults?.transcription == "Manual result")
        #expect(updated.conclusion?.entryMethod == .manual)
        #expect(await fixture.vault.callCounts.commit == 1)
    }

    @Test
    func updateRecordRejectsAnUnknownDetectedDateCandidate() async throws {
        let projection = try SyntheticRecordProjection()
        let fixture = try LiveAppServiceFixture(
            state: try readyState(for: projection.catalog),
            initializedCatalog: projection.catalog,
            catalogReads: [.success(projection.catalog)]
        )

        await #expect(throws: AppServiceError.invalidReview) {
            try await fixture.service.updateRecord(UpdateRecordCommand(
                recordID: projection.confirmed.id,
                expectedRevision: projection.confirmed.revision,
                memberID: projection.confirmed.memberID,
                timelineDateSelection: .detected(UUID()),
                title: "",
                organization: "",
                department: "",
                reportType: "",
                reportedResults: "",
                conclusion: "",
                abnormalItems: [],
                userNote: ""
            ))
        }

        #expect(await fixture.vault.callCounts.commit == 0)
    }

    @Test
    func updateRecordRejectsRevisionExhaustionWithoutCommitting() async throws {
        let member = try FamilyMember(displayName: "Synthetic member")
        let attachment = try Attachment(
            contentTypeIdentifier: "public.png",
            byteCount: 4,
            sha256Digest: Data(repeating: 0x73, count: 32)
        )
        let record = try HealthRecord(
            memberID: member.id,
            attachmentID: attachment.id,
            importState: .confirmed,
            revision: UInt64.max
        )
        let catalog = try VaultCatalog(
            vaultID: UUID(),
            generation: 1,
            members: [member],
            records: [record],
            attachments: [attachment]
        )
        let fixture = try LiveAppServiceFixture(
            state: try readyState(for: catalog),
            initializedCatalog: catalog,
            catalogReads: [.success(catalog)]
        )

        await #expect(throws: AppServiceError.recordChanged) {
            try await fixture.service.updateRecord(UpdateRecordCommand(
                recordID: record.id,
                expectedRevision: record.revision,
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
            ))
        }

        #expect(await fixture.vault.callCounts.commit == 0)
    }

    @Test
    func staleRecordEditFromAnotherServiceCannotOverwriteTheNewerSave() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kinlogue-stale-record-edit-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let seedVault = try PlaintextVault(rootURL: root)
        let initial = try await seedVault.initialize()
        let member = try FamilyMember(displayName: "Synthetic member")
        let attachmentBytes = Data(repeating: 0x74, count: 4)
        let attachment = try Attachment(
            contentTypeIdentifier: "public.png",
            byteCount: attachmentBytes.count,
            sha256Digest: ContentDigest.sha256(attachmentBytes)
        )
        let record = try HealthRecord(
            memberID: member.id,
            attachmentID: attachment.id,
            importState: .confirmed,
            title: try .manualEntry("Original title")
        )
        _ = try await seedVault.commit(try VaultCommitRequest(
            expectedGeneration: initial.generation,
            catalog: try VaultCatalog(
                vaultID: initial.vaultID,
                generation: initial.generation + 1,
                members: [member],
                records: [record],
                attachments: [attachment]
            ),
            writes: [VaultObjectWrite(
                reference: VaultObjectReference(id: attachment.id, kind: .attachment),
                plaintext: attachmentBytes
            )]
        ))
        let first = try makeRealDataService(rootURL: root)
        let stale = try makeRealDataService(rootURL: root)
        let firstCommand = UpdateRecordCommand(
            recordID: record.id,
            expectedRevision: record.revision,
            memberID: member.id,
            timelineDateSelection: .unknown,
            title: "First saved title",
            organization: "",
            department: "",
            reportType: "",
            reportedResults: "",
            conclusion: "",
            abnormalItems: [],
            userNote: ""
        )
        let staleCommand = UpdateRecordCommand(
            recordID: record.id,
            expectedRevision: record.revision,
            memberID: member.id,
            timelineDateSelection: .unknown,
            title: "Stale overwritten title",
            organization: "",
            department: "",
            reportType: "",
            reportedResults: "",
            conclusion: "",
            abnormalItems: [],
            userNote: ""
        )

        let firstSnapshot = try await first.updateRecord(firstCommand)
        #expect(firstSnapshot.records.first?.revision == record.revision + 1)
        await #expect(throws: AppServiceError.recordChanged) {
            try await stale.updateRecord(staleCommand)
        }

        let persisted = try #require(
            try await PlaintextVault(rootURL: root).loadCatalog().records.first
        )
        #expect(persisted.title?.transcription == "First saved title")
        #expect(persisted.revision == record.revision + 1)
    }

    @Test
    func originalLoadingRejectsAnUnconfirmedRecordBeforeReadingItsObject() async throws {
        let projection = try SyntheticRecordProjection()
        let fixture = try LiveAppServiceFixture(
            state: try readyState(for: projection.catalog),
            initializedCatalog: projection.catalog,
            catalogReads: [.success(projection.catalog)]
        )

        await #expect(throws: AppServiceError.recordUnavailable) {
            try await fixture.service.loadOriginal(
                recordID: projection.needsReview.id,
                sourceID: projection.needsReview.sources.first.id
            )
        }

        #expect(await fixture.vault.callCounts.loadCatalog == 1)
    }

    @Test
    func orderedOriginalLoadingReadsTheExactSelectedSource() async throws {
        let member = try FamilyMember(displayName: "Synthetic member")
        let firstAttachment = try Attachment(
            contentTypeIdentifier: "public.png",
            byteCount: 1,
            sha256Digest: Data(repeating: 0x31, count: 32)
        )
        let secondAttachment = try Attachment(
            contentTypeIdentifier: "com.adobe.pdf",
            byteCount: 1,
            sha256Digest: Data(repeating: 0x32, count: 32)
        )
        let firstSource = try ReportSource(
            attachmentID: firstAttachment.id,
            displayName: "first.png",
            pageCount: 1
        )
        let secondSource = try ReportSource(
            attachmentID: secondAttachment.id,
            displayName: "second.pdf",
            pageCount: 2
        )
        let record = try HealthRecord(
            memberID: member.id,
            sources: ReportSources([firstSource, secondSource]),
            importState: .confirmed
        )
        let catalog = try VaultCatalog(
            vaultID: UUID(),
            generation: 1,
            members: [member],
            records: [record],
            attachments: [firstAttachment, secondAttachment]
        )
        let fixture = try LiveAppServiceFixture(
            state: try readyState(for: catalog),
            initializedCatalog: catalog,
            catalogReads: [.success(catalog), .success(catalog)],
            readObjectDataByID: [
                firstAttachment.id: Data([1]),
                secondAttachment.id: Data([2]),
            ]
        )

        let first = try await fixture.service.loadOriginal(
            recordID: record.id,
            sourceID: firstSource.id
        )
        let second = try await fixture.service.loadOriginal(
            recordID: record.id,
            sourceID: secondSource.id
        )

        #expect(first.data == Data([1]))
        #expect(first.sourceID == firstSource.id)
        #expect(second.data == Data([2]))
        #expect(second.sourceID == secondSource.id)
        #expect(second.attachmentID == secondAttachment.id)
        #expect(second.displayName == "second.pdf")
        #expect(second.pageCount == 2)
        #expect(await fixture.vault.readObjectReferences.map(\.id) == [
            firstAttachment.id,
            secondAttachment.id,
        ])
    }

    @Test
    func confirmDraftReconcilesACommittedExactRecordAfterTheStoreThrows() async throws {
        let transaction = try SyntheticDraftTransaction()
        let fixture = try LiveAppServiceFixture(
            state: try readyState(for: transaction.beforeCommit),
            initializedCatalog: transaction.beforeCommit,
            catalogReads: [
                .success(transaction.beforeCommit),
                .success(transaction.afterCommit),
            ],
            draftDocument: transaction.document,
            confirmError: .commitResponseLost
        )

        let snapshot = try await fixture.service.confirmDraft(
            transaction.confirmCommand
        )

        #expect(snapshot.records == [transaction.committedRecord])
        #expect(snapshot.drafts.isEmpty)
        #expect(await fixture.draftStore.confirmCallCount == 1)
        #expect(await fixture.vault.callCounts.loadCatalog == 2)
    }

    @Test
    func confirmDraftRethrowsWhenReconciliationRecordIsNotAnExactMatch() async throws {
        let transaction = try SyntheticDraftTransaction()
        let mismatchedRecord = try HealthRecord(
            id: transaction.draft.id,
            memberID: transaction.member.id,
            attachmentID: transaction.attachment.id,
            ocrDocumentObjectID: transaction.draft.documentObjectID,
            importState: .confirmed,
            conclusion: try SourceField(originalTranscription: "Synthetic mismatch")
        )
        let mismatchedCatalog = try VaultCatalog(
            vaultID: transaction.beforeCommit.vaultID,
            generation: 2,
            members: [transaction.member],
            records: [mismatchedRecord],
            attachments: [transaction.attachment]
        )
        let fixture = try LiveAppServiceFixture(
            state: try readyState(for: transaction.beforeCommit),
            initializedCatalog: transaction.beforeCommit,
            catalogReads: [
                .success(transaction.beforeCommit),
                .success(mismatchedCatalog),
            ],
            draftDocument: transaction.document,
            confirmError: .commitResponseLost
        )

        await #expect(throws: LiveAppServiceFixtureError.commitResponseLost) {
            try await fixture.service.confirmDraft(transaction.confirmCommand)
        }

        #expect(await fixture.draftStore.confirmCallCount == 1)
        #expect(await fixture.vault.callCounts.loadCatalog == 2)
    }

    @Test
    func discardDraftReconcilesSuccessWhenNeitherDraftNorSameIDRecordRemains() async throws {
        let transaction = try SyntheticDraftTransaction()
        let fixture = try LiveAppServiceFixture(
            state: try readyState(for: transaction.beforeCommit),
            initializedCatalog: transaction.beforeCommit,
            catalogReads: [.success(transaction.afterDiscard)],
            discardError: .commitResponseLost
        )

        let snapshot = try await fixture.service.discardDraft(DiscardDraftCommand(
            draftID: transaction.draft.id,
            expectedRevision: transaction.draft.revision
        ))

        #expect(snapshot.records.isEmpty)
        #expect(snapshot.drafts.isEmpty)
        #expect(await fixture.draftStore.discardCallCount == 1)
        #expect(await fixture.vault.callCounts.loadCatalog == 1)
    }

    @Test
    func discardDraftRethrowsWhenAConfirmedRecordWithTheDraftIDExists() async throws {
        let transaction = try SyntheticDraftTransaction()
        let fixture = try LiveAppServiceFixture(
            state: try readyState(for: transaction.beforeCommit),
            initializedCatalog: transaction.beforeCommit,
            catalogReads: [.success(transaction.afterCommit)],
            discardError: .commitResponseLost
        )

        await #expect(throws: LiveAppServiceFixtureError.commitResponseLost) {
            try await fixture.service.discardDraft(DiscardDraftCommand(
                draftID: transaction.draft.id,
                expectedRevision: transaction.draft.revision
            ))
        }

        #expect(await fixture.draftStore.discardCallCount == 1)
        #expect(await fixture.vault.callCounts.loadCatalog == 1)
    }

    @Test
    func createMemberReconcilesTheExactAppliedCatalogAfterCommitResponseIsLost() async throws {
        let catalog = try VaultCatalog(vaultID: UUID(), generation: 1)
        let fixture = try LiveAppServiceFixture(
            state: try readyState(for: catalog),
            initializedCatalog: catalog,
            catalogReads: [.success(catalog)],
            commitErrorAfterApplying: true
        )

        let snapshot = try await fixture.service.createMember(
            displayName: "Synthetic new member",
            disambiguationLabel: nil
        )

        let applied = try #require(await fixture.vault.lastCommitCatalog)
        #expect(snapshot.generation == 2)
        #expect(snapshot.members.count == 1)
        #expect(snapshot.members == applied.members)
        #expect(snapshot.members.first?.displayName == "Synthetic new member")
        let vaultCalls = await fixture.vault.callCounts
        #expect(vaultCalls.loadCatalog == 2)
        #expect(vaultCalls.commit == 1)
    }

    @Test
    func deleteRecordReconcilesTheAppliedCatalogAfterCommitResponseIsLost() async throws {
        let projection = try SyntheticDeletionProjection()
        let fixture = try LiveAppServiceFixture(
            state: try readyState(for: projection.catalog),
            initializedCatalog: projection.catalog,
            catalogReads: [.success(projection.catalog)],
            commitErrorAfterApplying: true
        )

        let snapshot = try await fixture.service.deleteRecord(id: projection.record.id)

        #expect(snapshot.records.isEmpty)
        #expect(snapshot.drafts.map(\.id) == [projection.draft.id])
        let applied = try #require(await fixture.vault.lastCommitCatalog)
        #expect(applied.records.isEmpty)
        #expect(applied.attachments == [projection.draftAttachment])
        let vaultCalls = await fixture.vault.callCounts
        #expect(vaultCalls.loadCatalog == 2)
        #expect(vaultCalls.commit == 1)
    }

    @Test
    func deleteMemberReturnsOnlyReferenceCountsWithoutCommitting() async throws {
        let projection = try SyntheticDeletionProjection()
        let fixture = try LiveAppServiceFixture(
            state: try readyState(for: projection.catalog),
            initializedCatalog: projection.catalog,
            catalogReads: [.success(projection.catalog)]
        )

        await #expect(throws: AppServiceError.memberStillReferenced(
            recordCount: 1,
            draftCount: 1
        )) {
            try await fixture.service.deleteMember(id: projection.member.id)
        }

        let vaultCalls = await fixture.vault.callCounts
        #expect(vaultCalls.loadCatalog == 1)
        #expect(vaultCalls.commit == 0)
    }

    @Test
    func deleteUnreferencedMemberReconcilesTheAppliedCatalogAfterResponseLoss() async throws {
        let projection = try SyntheticDeletionProjection()
        let catalog = try VaultCatalog(
            vaultID: projection.catalog.vaultID,
            generation: projection.catalog.generation,
            members: [projection.member]
        )
        let fixture = try LiveAppServiceFixture(
            state: try readyState(for: catalog),
            initializedCatalog: catalog,
            catalogReads: [.success(catalog)],
            commitErrorAfterApplying: true
        )

        let snapshot = try await fixture.service.deleteMember(id: projection.member.id)

        #expect(snapshot.members.isEmpty)
        #expect(snapshot.records.isEmpty)
        let vaultCalls = await fixture.vault.callCounts
        #expect(vaultCalls.loadCatalog == 2)
        #expect(vaultCalls.commit == 1)
    }
}

private func makeRealDataService(rootURL: URL) throws -> LiveAppService {
    let vault = try PlaintextVault(rootURL: rootURL)
    let store = VaultImportDraftStore(vault: vault)
    let extractor = LiveAppServiceTextExtractorStub()
    return LiveAppService(
        vault: vault,
        draftStore: store,
        workflow: ImportWorkflow(store: store, textExtractor: extractor),
        textExtractor: extractor,
        startupCompleted: true
    )
}

private func rewriteCatalogVersionForStartupTest(
    _ version: Int,
    manifestURL: URL
) throws {
    var manifest = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL))
            as? [String: Any]
    )
    var catalog = try #require(manifest["catalog"] as? [String: Any])
    catalog["formatVersion"] = version
    let catalogData = try JSONSerialization.data(withJSONObject: catalog, options: [.sortedKeys])
    manifest["catalog"] = catalog
    manifest["catalogSHA256"] = ContentDigest.sha256(catalogData).base64EncodedString()
    try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        .write(to: manifestURL, options: .atomic)
}

private func startupTestVaultContents(at root: URL) throws -> [String: Data] {
    let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [
        .isRegularFileKey,
    ]))
    var contents: [String: Data] = [:]
    for case let url as URL in enumerator
    where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
        contents[url.path.replacingOccurrences(of: root.path + "/", with: "")] = try Data(
            contentsOf: url
        )
    }
    return contents
}

private struct LiveAppServiceFixture {
    let vault: LiveAppServiceVaultStub
    let draftStore: LiveAppServiceDraftStoreStub
    let bootstrapCalls: LiveAppServiceBootstrapCallRecorder
    let service: LiveAppService

    init(
        state: VaultAccessState,
        initializedCatalog: VaultCatalog? = nil,
        catalogReads: [LiveAppServiceCatalogRead] = [],
        draftDocument: ImportDraftDocument? = nil,
        confirmCatalog: VaultCatalog? = nil,
        discardCatalog: VaultCatalog? = nil,
        confirmError: LiveAppServiceFixtureError? = nil,
        discardError: LiveAppServiceFixtureError? = nil,
        resumableError: LiveAppServiceFixtureError? = nil,
        resumableDraftIDs: [ImportDraft.ID] = [],
        beginProcessingError: LiveAppServiceFixtureError? = nil,
        readObjectData: Data? = nil,
        readObjectDataByID: [KinlogueCore.Attachment.ID: Data] = [:],
        textExtractor: any TextExtractionService = LiveAppServiceTextExtractorStub(),
        commitErrorAfterApplying: Bool = false,
        requiresBootstrap: Bool = false
    ) throws {
        let catalog = try initializedCatalog ?? syntheticCatalog()
        let bootstrapCalls = LiveAppServiceBootstrapCallRecorder()
        let vault = LiveAppServiceVaultStub(
            state: state,
            initializedCatalog: catalog,
            catalogReads: catalogReads,
            readObjectData: readObjectData,
            readObjectDataByID: readObjectDataByID,
            commitErrorAfterApplying: commitErrorAfterApplying,
            bootstrapCalls: bootstrapCalls
        )
        let draftStore = LiveAppServiceDraftStoreStub(
            document: draftDocument,
            reviewCatalog: catalog,
            originalData: readObjectData,
            originalDataByID: readObjectDataByID,
            confirmCatalog: confirmCatalog,
            discardCatalog: discardCatalog,
            confirmError: confirmError,
            discardError: discardError,
            resumableError: resumableError,
            resumableDraftIDs: resumableDraftIDs,
            beginProcessingError: beginProcessingError
        )
        self.vault = vault
        self.draftStore = draftStore
        self.bootstrapCalls = bootstrapCalls
        service = LiveAppService(
            vault: vault,
            draftStore: draftStore,
            workflow: ImportWorkflow(
                store: draftStore,
                textExtractor: textExtractor
            ),
            textExtractor: textExtractor,
            startupCompleted: !requiresBootstrap
        )
    }
}

private enum LiveAppServiceFixtureError: Error, Equatable, Sendable {
    case catalogRead
    case commitResponseLost
    case recoveryRead
    case recoveryProcessing
    case unexpectedCall
}

private enum LiveAppServiceBootstrapCall: Equatable, Sendable {
    case loadValidatedCatalog
    case loadCatalog
}

private actor LiveAppServiceBootstrapCallRecorder {
    private(set) var values: [LiveAppServiceBootstrapCall] = []

    func append(_ value: LiveAppServiceBootstrapCall) {
        values.append(value)
    }
}

private enum LiveAppServiceCatalogRead: Sendable {
    case success(VaultCatalog)
    case failure(LiveAppServiceFixtureError)
}

private struct LiveAppServiceVaultCallCounts: Equatable, Sendable {
    let initialize: Int
    let loadValidatedCatalog: Int
    let loadCatalog: Int
    let commit: Int
}

private actor LiveAppServiceVaultStub: VaultStore {
    private let state: VaultAccessState
    private let initializedCatalog: VaultCatalog
    private let readObjectData: Data?
    private let readObjectDataByID: [KinlogueCore.Attachment.ID: Data]
    private let commitErrorAfterApplying: Bool
    private let bootstrapCalls: LiveAppServiceBootstrapCallRecorder
    private let inspectGate: AsyncOperationGate?
    private var catalogReads: [LiveAppServiceCatalogRead]
    private var appliedCatalog: VaultCatalog?
    private(set) var lastCommitCatalog: VaultCatalog?
    private(set) var readObjectReferences: [VaultObjectReference] = []
    private var initializeCallCount = 0
    private var loadValidatedCatalogCallCount = 0
    private var loadCatalogCallCount = 0
    private var commitCallCount = 0

    init(
        state: VaultAccessState,
        initializedCatalog: VaultCatalog,
        catalogReads: [LiveAppServiceCatalogRead],
        readObjectData: Data? = nil,
        readObjectDataByID: [KinlogueCore.Attachment.ID: Data] = [:],
        commitErrorAfterApplying: Bool,
        bootstrapCalls: LiveAppServiceBootstrapCallRecorder,
        inspectGate: AsyncOperationGate? = nil
    ) {
        self.state = state
        self.initializedCatalog = initializedCatalog
        self.readObjectData = readObjectData
        self.readObjectDataByID = readObjectDataByID
        self.catalogReads = catalogReads
        self.commitErrorAfterApplying = commitErrorAfterApplying
        self.bootstrapCalls = bootstrapCalls
        self.inspectGate = inspectGate
    }

    var callCounts: LiveAppServiceVaultCallCounts {
        LiveAppServiceVaultCallCounts(
            initialize: initializeCallCount,
            loadValidatedCatalog: loadValidatedCatalogCallCount,
            loadCatalog: loadCatalogCallCount,
            commit: commitCallCount
        )
    }

    func inspect() async -> VaultAccessState {
        state
    }

    func loadValidatedCatalog() async throws -> VaultCatalog {
        await bootstrapCalls.append(.loadValidatedCatalog)
        if let inspectGate { await inspectGate.wait() }
        loadValidatedCatalogCallCount += 1
        switch state {
        case .ready:
            return initializedCatalog
        case .absent:
            throw VaultError.vaultMissing
        case .operationInProgress:
            throw VaultError.mutationConflict
        case .legacyEncrypted:
            throw VaultError.legacyEncryptedVault
        case .damaged:
            throw VaultError.invalidCatalog
        case .unsupportedVersion:
            throw VaultError.unsupportedVersion(-1)
        }
    }

    func initialize() async throws -> VaultCatalog {
        initializeCallCount += 1
        return initializedCatalog
    }

    func loadCatalog() async throws -> VaultCatalog {
        await bootstrapCalls.append(.loadCatalog)
        loadCatalogCallCount += 1
        if !catalogReads.isEmpty {
            switch catalogReads.removeFirst() {
            case .success(let catalog): return catalog
            case .failure(let error): throw error
            }
        }
        if let appliedCatalog { return appliedCatalog }
        throw LiveAppServiceFixtureError.unexpectedCall
    }

    func readObject(_ reference: VaultObjectReference) async throws -> Data {
        readObjectReferences.append(reference)
        if let data = readObjectDataByID[reference.id] { return data }
        guard let readObjectData else { throw LiveAppServiceFixtureError.unexpectedCall }
        return readObjectData
    }

    func readSnapshot(
        selecting references: @Sendable (VaultCatalog) throws -> [VaultObjectReference]
    ) async throws -> VaultReadSnapshot {
        let catalog = try await loadCatalog()
        let selected = try references(catalog)
        guard selected.count <= VaultReadSnapshotPolicy.maximumObjectCount,
              Set(selected).count == selected.count else {
            throw VaultError.resourceLimitExceeded
        }
        var objects: [VaultObjectReference: Data] = [:]
        for reference in selected {
            objects[reference] = try await readObject(reference)
        }
        return try VaultReadSnapshot(catalog: catalog, objects: objects)
    }

    func commit(_ request: VaultCommitRequest) async throws -> VaultCatalog {
        commitCallCount += 1
        lastCommitCatalog = request.catalog
        if commitErrorAfterApplying {
            appliedCatalog = request.catalog
            throw LiveAppServiceFixtureError.commitResponseLost
        }
        return request.catalog
    }

    func destroy() async throws {}
}

private actor LiveAppServiceDraftStoreStub: ImportDraftStore {
    private let document: ImportDraftDocument?
    private let reviewSnapshot: ImportDraftReviewSnapshot?
    private let confirmCatalog: VaultCatalog?
    private let discardCatalog: VaultCatalog?
    private let confirmError: LiveAppServiceFixtureError?
    private let discardError: LiveAppServiceFixtureError?
    private let resumableError: LiveAppServiceFixtureError?
    private let resumableDraftIDs: [ImportDraft.ID]
    private let beginProcessingError: LiveAppServiceFixtureError?
    private(set) var resumableCallCount = 0
    private(set) var beginProcessingCallCount = 0
    private(set) var loadDocumentCallCount = 0
    private(set) var loadReviewSnapshotCallCount = 0
    private(set) var confirmCallCount = 0
    private(set) var discardCallCount = 0
    private(set) var lastConfirmedRecord: HealthRecord?
    private(set) var lastConfirmedExpectedRevision: UInt64?
    private(set) var lastDiscardedDraftID: ImportDraft.ID?
    private(set) var lastDiscardedExpectedRevision: UInt64?
    private(set) var lastSavedReviewMemberID: FamilyMember.ID?
    private(set) var lastSavedReviewState: ImportDraftReviewState?
    private(set) var lastSavedReviewDocument: ImportDraftDocument?
    private(set) var lastSavedReviewExpectedRevision: UInt64?

    init(
        document: ImportDraftDocument? = nil,
        reviewCatalog: VaultCatalog? = nil,
        originalData: Data? = nil,
        originalDataByID: [KinlogueCore.Attachment.ID: Data] = [:],
        confirmCatalog: VaultCatalog? = nil,
        discardCatalog: VaultCatalog? = nil,
        confirmError: LiveAppServiceFixtureError? = nil,
        discardError: LiveAppServiceFixtureError? = nil,
        resumableError: LiveAppServiceFixtureError? = nil,
        resumableDraftIDs: [ImportDraft.ID] = [],
        beginProcessingError: LiveAppServiceFixtureError? = nil
    ) {
        self.document = document
        if let document,
           let reviewCatalog,
           let draft = reviewCatalog.importDrafts.first(where: { $0.state == .needsReview }),
           let attachment = reviewCatalog.attachments.first(where: {
               $0.id == draft.sources.first.attachmentID
           }),
           let data = originalDataByID[attachment.id] ?? originalData {
            reviewSnapshot = ImportDraftReviewSnapshot(
                draft: draft,
                document: document,
                members: reviewCatalog.members,
                attachment: attachment,
                originalData: data
            )
        } else {
            reviewSnapshot = nil
        }
        self.confirmCatalog = confirmCatalog
        self.discardCatalog = discardCatalog
        self.confirmError = confirmError
        self.discardError = discardError
        self.resumableError = resumableError
        self.resumableDraftIDs = resumableDraftIDs
        self.beginProcessingError = beginProcessingError
    }

    func stage(_ file: ValidatedImportedFile) async throws -> ImportStageOutcome {
        throw LiveAppServiceFixtureError.unexpectedCall
    }

    func beginProcessing(
        draftID: ImportDraft.ID,
        attemptID: UUID
    ) async throws -> ImportProcessingLease {
        beginProcessingCallCount += 1
        if let beginProcessingError { throw beginProcessingError }
        throw LiveAppServiceFixtureError.unexpectedCall
    }

    func loadSource(draftID: ImportDraft.ID) async throws -> ValidatedImportedFile {
        throw LiveAppServiceFixtureError.unexpectedCall
    }

    func completeProcessing(
        lease: ImportProcessingLease,
        document: ImportDraftDocument
    ) async throws {
        throw LiveAppServiceFixtureError.unexpectedCall
    }

    func failProcessing(
        lease: ImportProcessingLease,
        failureCode: ImportFailureCode
    ) async throws {
        throw LiveAppServiceFixtureError.unexpectedCall
    }

    func resumableDraftIDs() async throws -> [ImportDraft.ID] {
        resumableCallCount += 1
        if let resumableError { throw resumableError }
        return resumableDraftIDs
    }

    func loadDocument(draftID: ImportDraft.ID) async throws -> ImportDraftDocument {
        loadDocumentCallCount += 1
        guard let document else { throw LiveAppServiceFixtureError.unexpectedCall }
        return document
    }

    func loadReviewSnapshot(
        draftID: ImportDraft.ID
    ) async throws -> ImportDraftReviewSnapshot {
        loadReviewSnapshotCallCount += 1
        guard let reviewSnapshot, reviewSnapshot.draft.id == draftID else {
            throw LiveAppServiceFixtureError.unexpectedCall
        }
        return reviewSnapshot
    }

    func saveReview(
        draftID: ImportDraft.ID,
        expectedRevision: UInt64,
        memberID: FamilyMember.ID?,
        document: ImportDraftDocument
    ) async throws {
        lastSavedReviewMemberID = memberID
        lastSavedReviewState = document.reviewState
        lastSavedReviewDocument = document
        lastSavedReviewExpectedRevision = expectedRevision
    }

    func confirm(
        draftID: ImportDraft.ID,
        expectedRevision: UInt64,
        record: HealthRecord
    ) async throws -> VaultCatalog {
        confirmCallCount += 1
        lastConfirmedExpectedRevision = expectedRevision
        lastConfirmedRecord = record
        if let confirmError { throw confirmError }
        guard let confirmCatalog else { throw LiveAppServiceFixtureError.unexpectedCall }
        return confirmCatalog
    }

    func discard(
        draftID: ImportDraft.ID,
        expectedRevision: UInt64
    ) async throws -> VaultCatalog {
        discardCallCount += 1
        lastDiscardedDraftID = draftID
        lastDiscardedExpectedRevision = expectedRevision
        if let discardError { throw discardError }
        guard let discardCatalog else { throw LiveAppServiceFixtureError.unexpectedCall }
        return discardCatalog
    }
}

private actor LiveAppServiceTextExtractorStub: TextExtractionService {
    private let blocks: [OCRBlock]?
    private(set) var files: [ValidatedImportedFile] = []

    init(blocks: [OCRBlock]? = nil) {
        self.blocks = blocks
    }

    func extractText(from file: ValidatedImportedFile) async throws -> [OCRBlock] {
        files.append(file)
        guard let blocks else { throw LiveAppServiceFixtureError.unexpectedCall }
        return blocks
    }
}

private actor ReportLifecycleTextExtractor: TextExtractionService {
    private let gate = AsyncOperationGate()
    private(set) var observedCancellation = false

    func extractText(from file: ValidatedImportedFile) async throws -> [OCRBlock] {
        _ = file
        await gate.wait()
        do {
            try Task.checkCancellation()
        } catch {
            observedCancellation = true
            throw error
        }
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

private actor ReportLifecycleCompletionProbe {
    private(set) var isCompleted = false

    func markCompleted() {
        isCompleted = true
    }
}

private func reportLifecyclePNG() throws -> Data {
    let context = try #require(CGContext(
        data: nil,
        width: 8,
        height: 8,
        bitsPerComponent: 8,
        bytesPerRow: 32,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
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

private actor LANVaultDestroySpy: VaultDestroyServicing {
    private(set) var callCount = 0

    func destroyCurrentVault() async throws {
        callCount += 1
    }
}

private func syntheticCatalog() throws -> VaultCatalog {
    let member = try FamilyMember(displayName: "Synthetic member")
    return try VaultCatalog(
        vaultID: UUID(),
        generation: 1,
        members: [member]
    )
}

private struct SyntheticDraftTransaction {
    let member: FamilyMember
    let attachment: KinlogueCore.Attachment
    let draft: ImportDraft
    let document: ImportDraftDocument
    let committedRecord: HealthRecord
    let beforeCommit: VaultCatalog
    let afterCommit: VaultCatalog
    let afterDiscard: VaultCatalog

    init() throws {
        let member = try FamilyMember(displayName: "Synthetic member")
        let attachment = try Attachment(
            contentTypeIdentifier: "com.adobe.pdf",
            byteCount: 4,
            sha256Digest: Data(repeating: 0x12, count: 32)
        )
        let documentObjectID = UUID()
        let draft = ImportDraft(
            attachmentID: attachment.id,
            state: .needsReview,
            documentObjectID: documentObjectID
        )
        let committedRecord = try HealthRecord(
            id: draft.id,
            memberID: member.id,
            attachmentID: attachment.id,
            ocrDocumentObjectID: documentObjectID,
            importState: .confirmed
        )
        self.member = member
        self.attachment = attachment
        self.draft = draft
        document = ImportDraftDocument(blocks: [], candidates: ReportCandidates())
        self.committedRecord = committedRecord
        beforeCommit = try VaultCatalog(
            vaultID: UUID(),
            generation: 1,
            members: [member],
            attachments: [attachment],
            importDrafts: [draft]
        )
        afterCommit = try VaultCatalog(
            vaultID: beforeCommit.vaultID,
            generation: 2,
            members: [member],
            records: [committedRecord],
            attachments: [attachment]
        )
        afterDiscard = try VaultCatalog(
            vaultID: beforeCommit.vaultID,
            generation: 2,
            members: [member],
            attachments: [attachment]
        )
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

private struct SyntheticRecordProjection {
    let confirmed: HealthRecord
    let needsReview: HealthRecord
    let catalog: VaultCatalog

    init() throws {
        let member = try FamilyMember(displayName: "Synthetic member")
        let attachment = try Attachment(
            contentTypeIdentifier: "public.jpeg",
            byteCount: 3,
            sha256Digest: Data(repeating: 0x34, count: 32)
        )
        confirmed = try HealthRecord(
            memberID: member.id,
            attachmentID: attachment.id,
            importState: .confirmed
        )
        needsReview = try HealthRecord(
            memberID: member.id,
            attachmentID: attachment.id,
            importState: .needsReview
        )
        catalog = try VaultCatalog(
            vaultID: UUID(),
            generation: 1,
            members: [member],
            records: [needsReview, confirmed],
            attachments: [attachment]
        )
    }
}

private struct SyntheticDeletionProjection {
    let member: FamilyMember
    let recordAttachment: KinlogueCore.Attachment
    let draftAttachment: KinlogueCore.Attachment
    let record: HealthRecord
    let draft: ImportDraft
    let catalog: VaultCatalog

    init() throws {
        member = try FamilyMember(displayName: "Synthetic deletion member")
        recordAttachment = try Attachment(
            contentTypeIdentifier: "public.jpeg",
            byteCount: 3,
            sha256Digest: Data(repeating: 0x61, count: 32)
        )
        draftAttachment = try Attachment(
            contentTypeIdentifier: "public.png",
            byteCount: 5,
            sha256Digest: Data(repeating: 0x62, count: 32)
        )
        record = try HealthRecord(
            memberID: member.id,
            attachmentID: recordAttachment.id,
            importState: .confirmed
        )
        draft = ImportDraft(
            attachmentID: draftAttachment.id,
            memberID: member.id
        )
        catalog = try VaultCatalog(
            vaultID: UUID(),
            generation: 4,
            members: [member],
            records: [record],
            attachments: [recordAttachment, draftAttachment],
            importDrafts: [draft]
        )
    }
}

private func readyState(for catalog: VaultCatalog) throws -> VaultAccessState {
    .ready(try VaultRevision(
        generation: catalog.generation,
        commitID: UUID(),
        catalogDigest: Data(repeating: 0xA5, count: 32)
    ))
}
