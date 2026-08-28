import Foundation
import Testing
@testable import KinlogueApp
@testable import KinlogueCore
@testable import KinloguePlatform

@Suite("Pending queue model", .serialized)
@MainActor
struct LANInboxModelTests {
    @Test
    func selectionUsesQueueOrderAndMacReorderIsIndependent() async throws {
        let first = try item(seed: 1, sequence: 0, name: "first.png")
        let second = try item(seed: 2, sequence: 1, name: "second.png")
        let service = try LANPendingQueueServiceSpy(items: [first.item, second.item])
        let model = LANInboxModel(service: service)
        await model.start()

        model.selectedItemIDs = [second.item.id, first.item.id]
        model.reconcileSelectionOrder()
        #expect(model.archiveOrder == [first.item.id, second.item.id])

        model.moveArchiveItem(itemID: second.item.id, offset: -1)
        #expect(model.archiveOrder == [second.item.id, first.item.id])
        #expect(model.items.map(\.id) == [first.item.id, second.item.id])
    }

    @Test
    func revisionChangeDropsOnlyStaleSelection() async throws {
        let first = try item(seed: 10, sequence: 0, name: "first.png")
        let second = try item(seed: 20, sequence: 1, name: "second.png")
        let service = try LANPendingQueueServiceSpy(items: [first.item, second.item])
        let model = LANInboxModel(service: service)
        await model.start()
        model.selectedItemIDs = [first.item.id, second.item.id]
        model.reconcileSelectionOrder()

        let changed = try first.item.transitioning(
            to: .preprocessing(blobID: first.blob.id, attemptID: UUID()),
            expectedRevision: first.item.revision
        )
        try await service.replace(
            items: [changed, second.item],
            blobs: [first.blob, second.blob]
        )
        await model.refresh()

        #expect(model.selectedItemIDs == [second.item.id])
        #expect(model.archiveOrder == [second.item.id])
    }

    @Test
    func confirmationDismissalDoesNotErasePendingDeleteCommand() async throws {
        let fixture = try item(seed: 25, sequence: 0, name: "delete.png")
        let service = try LANPendingQueueServiceSpy(items: [fixture.item])
        let model = LANInboxModel(service: service)
        await model.start()

        model.requestDelete([fixture.item.id])
        let command = try #require(model.pendingDeleteCommand)
        #expect(command.targets == [LANInboxDeleteTarget(
            itemID: fixture.item.id,
            expectedRevision: fixture.item.revision
        )])

        // SwiftUI dismisses the confirmation dialog before its asynchronous
        // action reaches the MainActor model.
        model.cancelDeleteRequest()
        await model.confirmDeleteItems(command)

        #expect(model.items.isEmpty)
    }

    @Test
    func deleteFailureKeepsTheItemAndSurfacesARefreshableError() async throws {
        let fixture = try item(seed: 26, sequence: 0, name: "delete-failure.png")
        let service = try LANPendingQueueServiceSpy(items: [fixture.item])
        await service.setDeleteError(LANInboxError.storageFailure)
        let model = LANInboxModel(service: service)
        await model.start()

        model.requestDelete([fixture.item.id])
        let command = try #require(model.pendingDeleteCommand)
        model.cancelDeleteRequest()
        await model.confirmDeleteItems(command)

        #expect(model.items.map(\.id) == [fixture.item.id])
        #expect(model.pendingDeleteCommand == nil)
        #expect(
            model.userErrorMessage
                == AppLocalization.string("资料已发生变化，请刷新后重试。")
        )
    }

    @Test
    func staleRevisionAfterDeleteConfirmationSnapshotDoesNotDeleteTheNewItem() async throws {
        let fixture = try item(seed: 27, sequence: 0, name: "stale-delete.png")
        let service = try LANPendingQueueServiceSpy(items: [fixture.item])
        let model = LANInboxModel(service: service)
        await model.start()

        model.requestDelete([fixture.item.id])
        let command = try #require(model.pendingDeleteCommand)
        let changed = try fixture.item.transitioning(
            to: .preprocessing(blobID: fixture.blob.id, attemptID: UUID()),
            expectedRevision: fixture.item.revision
        )
        try await service.replace(items: [changed], blobs: [fixture.blob])
        await model.refresh()

        await model.confirmDeleteItems(command)

        #expect(model.items.map(\.id) == [fixture.item.id])
        #expect(model.items.first?.revision == changed.revision)
        #expect(await service.deleteRequests == command.targets)
        #expect(
            model.userErrorMessage
                == AppLocalization.string("资料已发生变化，请刷新后重试。")
        )
    }

    @Test
    func archivePassesExplicitOrderMemberAndCanonicalDateThenClearsSelection() async throws {
        let first = try item(seed: 30, sequence: 0, name: "first.png")
        let second = try item(seed: 40, sequence: 1, name: "second.png")
        let service = try LANPendingQueueServiceSpy(items: [first.item, second.item])
        let hook = CatalogRefreshProbe()
        let model = LANInboxModel(
            service: service,
            onCatalogChanged: { await hook.record() }
        )
        await model.start()
        model.selectedItemIDs = [first.item.id, second.item.id]
        model.reconcileSelectionOrder()
        model.moveArchiveItem(itemID: second.item.id, offset: -1)
        let memberID = UUID()
        let date = Date(timeIntervalSinceReferenceDate: 123_456)
        model.selectedMemberID = memberID
        model.canonicalReportDate = date

        await model.archiveSelectedItems()

        let request = try #require(await service.lastArchiveRequest)
        let expectedDate = try #require(ReportDateSemantics.canonicalDate(from: date))
        #expect(request.itemIDs == [second.item.id, first.item.id])
        #expect(request.memberID == memberID)
        #expect(request.date == expectedDate)
        #expect(model.selectedItemIDs.isEmpty)
        #expect(model.archiveOrder.isEmpty)
        #expect(model.archiveNotice?.draftID != nil)
        #expect(await hook.count == 1)
    }

    @Test
    func archiveFailureRetainsActionableSelection() async throws {
        let fixture = try item(seed: 50, sequence: 0, name: "retry.png")
        let service = try LANPendingQueueServiceSpy(items: [fixture.item])
        await service.setArchiveError(LANInboxError.storageFailure)
        let model = LANInboxModel(service: service)
        await model.start()
        model.selectedItemIDs = [fixture.item.id]
        model.reconcileSelectionOrder()
        model.selectedMemberID = UUID()

        await model.archiveSelectedItems()

        #expect(model.selectedItemIDs == [fixture.item.id])
        #expect(model.archiveOrder == [fixture.item.id])
        #expect(
            model.userErrorMessage
                == AppLocalization.string("所选资料未能加入待确认，资料仍保留在队列中。")
        )
    }

    @Test
    func visibleErrorTracksTheSelectedAppLanguage() async throws {
        let defaults = UserDefaults.standard
        let previousLanguage = defaults.object(forKey: AppLocalization.languagePreferenceKey)
        defer {
            if let previousLanguage {
                defaults.set(previousLanguage, forKey: AppLocalization.languagePreferenceKey)
            } else {
                defaults.removeObject(forKey: AppLocalization.languagePreferenceKey)
            }
        }
        defaults.set(AppLanguage.simplifiedChinese.rawValue, forKey: AppLocalization.languagePreferenceKey)

        let fixture = try item(seed: 51, sequence: 0, name: "retry.png")
        let service = try LANPendingQueueServiceSpy(items: [fixture.item])
        await service.setArchiveError(LANInboxError.storageFailure)
        let model = LANInboxModel(service: service)
        await model.start()
        model.selectedItemIDs = [fixture.item.id]
        model.reconcileSelectionOrder()
        model.selectedMemberID = UUID()
        await model.archiveSelectedItems()

        #expect(model.userErrorMessage == "所选资料未能加入待确认，资料仍保留在队列中。")
        defaults.set(AppLanguage.english.rawValue, forKey: AppLocalization.languagePreferenceKey)
        #expect(
            model.userErrorMessage
                == "The selection couldn't be added for review. It remains in the queue."
        )
    }

    @Test
    func unsupportedItemDoesNotBlockReadyItemAndCanRetryIndependently() async throws {
        let ready = try item(seed: 60, sequence: 0, name: "ready.png")
        let unsupportedBase = try item(seed: 70, sequence: 1, name: "unknown.bin")
        let unsupported = try LANInboxItem(
            id: unsupportedBase.item.id,
            originatingSessionID: unsupportedBase.item.originatingSessionID,
            displayName: unsupportedBase.item.displayName,
            receivedAt: unsupportedBase.item.receivedAt,
            sequence: unsupportedBase.item.sequence,
            revision: unsupportedBase.item.revision,
            contentIdentity: unsupportedBase.item.contentIdentity,
            state: .unsupported(
                blobID: unsupportedBase.blob.id,
                issue: .unsupportedContent
            )
        )
        let service = try LANPendingQueueServiceSpy(
            items: [ready.item, unsupported],
            blobs: [ready.blob, unsupportedBase.blob]
        )
        let model = LANInboxModel(service: service)
        await model.start()
        model.selectedItemIDs = [ready.item.id, unsupported.id]
        model.reconcileSelectionOrder()

        #expect(model.selectedItemIDs == [ready.item.id])
        await model.retry(itemID: unsupported.id)
        #expect(await service.preprocessedItemIDs == [unsupported.id])
    }

    @Test
    func previewPayloadCanBeLoadedForInlineAndModalPreviews() async throws {
        let fixture = try item(seed: 75, sequence: 0, name: "preview.png")
        let service = try LANPendingQueueServiceSpy(items: [fixture.item])
        let payload = LANInboxPreviewPayload(
            data: Data([0x01, 0x02, 0x03]),
            contentTypeIdentifier: "public.png"
        )
        await service.setPreviewPayload(payload, for: fixture.item.id)
        let model = LANInboxModel(service: service)
        await model.start()

        let loaded = try await model.loadPreviewPayload(itemID: fixture.item.id)
        model.presentPreview(itemID: fixture.item.id, payload: loaded)

        #expect(loaded.data == payload.data)
        #expect(loaded.contentTypeIdentifier == payload.contentTypeIdentifier)
        #expect(model.previewPresentation?.payload == loaded)
        #expect(await service.previewLoadCount == 1)
    }

    @Test
    func modalPreviewIsLatestRequestWinsAndLifecycleRejectsLatePayloads() async throws {
        let first = try item(seed: 76, sequence: 0, name: "first-preview.png")
        let second = try item(seed: 77, sequence: 1, name: "second-preview.png")
        let service = try LANPendingQueueServiceSpy(
            items: [first.item, second.item],
            blobs: [first.blob, second.blob]
        )
        let firstPayload = LANInboxPreviewPayload(
            data: Data([0x01, 0x02]),
            contentTypeIdentifier: "public.png"
        )
        let secondPayload = LANInboxPreviewPayload(
            data: Data([0x03, 0x04]),
            contentTypeIdentifier: "public.png"
        )
        await service.setPreviewPayload(firstPayload, for: first.item.id)
        await service.setPreviewPayload(secondPayload, for: second.item.id)
        let firstGate = AsyncOperationGate()
        await service.setPreviewGate(firstGate, for: first.item.id)
        let model = LANInboxModel(service: service)
        await model.start()

        let staleFirstRequest = Task { await model.openPreview(itemID: first.item.id) }
        #expect(await firstGate.waitUntilStarted())
        await model.openPreview(itemID: second.item.id)
        #expect(model.previewPresentation?.id == second.item.id)
        #expect(model.previewPresentation?.payload.data == secondPayload.data)

        await firstGate.open()
        await staleFirstRequest.value
        #expect(model.previewPresentation?.id == second.item.id)
        #expect(model.previewPresentation?.payload.data == secondPayload.data)

        model.dismissPreview()
        #expect(model.previewPresentation == nil)
        let lifecycleGate = AsyncOperationGate()
        await service.setPreviewGate(lifecycleGate, for: first.item.id)
        let lifecycleRequest = Task { await model.openPreview(itemID: first.item.id) }
        #expect(await lifecycleGate.waitUntilStarted())
        model.beginDestructiveVaultLifecycle()
        await lifecycleGate.open()
        await lifecycleRequest.value

        #expect(model.previewPresentation == nil)
        #expect(model.items.isEmpty)
    }

    @Test
    func destructiveLifecycleRejectsLateInitializeAndFutureStarts() async throws {
        let fixture = try item(seed: 78, sequence: 0, name: "late-initialize.png")
        let service = try LANPendingQueueServiceSpy(items: [fixture.item])
        let gate = AsyncOperationGate()
        await service.setInitializeGate(gate)
        let model = LANInboxModel(service: service)

        let starting = Task { await model.start() }
        #expect(await gate.waitUntilStarted())
        model.beginDestructiveVaultLifecycle()
        await gate.open()
        await starting.value

        #expect(model.items.isEmpty)
        #expect(model.storage == nil)
        #expect(!model.isLoading)
        #expect(model.userErrorMessage == nil)

        await model.start()
        #expect(await service.initializeCallCount == 1)
        #expect(model.items.isEmpty)
    }

    @Test
    func destructiveLifecycleRejectsLateRefreshAndFutureRefreshes() async throws {
        let fixture = try item(seed: 79, sequence: 0, name: "late-refresh.png")
        let service = try LANPendingQueueServiceSpy(items: [fixture.item])
        let model = LANInboxModel(service: service)
        await model.start()
        let gate = AsyncOperationGate()
        await service.setRefreshGate(gate)

        let refreshing = Task { await model.refresh() }
        #expect(await gate.waitUntilStarted())
        model.beginDestructiveVaultLifecycle()
        await gate.open()
        await refreshing.value

        #expect(model.items.isEmpty)
        #expect(model.storage == nil)
        #expect(model.userErrorMessage == nil)

        await model.refresh()
        #expect(await service.refreshCallCount == 1)
        #expect(model.items.isEmpty)
    }

    @Test
    func destructiveLifecycleRejectsLateAddressResolution() async throws {
        let service = try LANPendingQueueServiceSpy(items: [])
        await service.configureReceiver(
            resolution: .automatic(
                LANNetworkAddress(
                    interfaceName: "en0",
                    host: "192.0.2.1",
                    networkPrefixLength: 24
                )
            ),
            replacementOnStop: nil
        )
        let gate = AsyncOperationGate()
        await service.setResolveAddressesGate(gate)
        let model = LANInboxModel(service: service)
        await model.start()

        let resolving = Task { await model.prepareReceiving() }
        #expect(await gate.waitUntilStarted())
        model.beginDestructiveVaultLifecycle()
        await gate.open()
        await resolving.value

        #expect(model.availableAddresses.isEmpty)
        #expect(model.selectedAddress == nil)
        #expect(!model.isReceiverSheetPresented)
        #expect(model.userErrorMessage == nil)
        await model.prepareReceiving()
        #expect(await service.resolveAddressesCallCount == 1)
    }

    @Test
    func destructiveLifecycleStopsAReceiverWhoseStartReturnsLate() async throws {
        let service = try LANPendingQueueServiceSpy(items: [])
        await service.configureReceiver(
            resolution: .automatic(
                LANNetworkAddress(
                    interfaceName: "en0",
                    host: "192.0.2.1",
                    networkPrefixLength: 24
                )
            ),
            replacementOnStop: nil
        )
        let model = LANInboxModel(service: service)
        await model.start()
        await model.prepareReceiving()
        model.hasAcknowledgedPrivateNetwork = true
        let gate = AsyncOperationGate()
        await service.setStartReceivingGate(gate)

        let starting = Task { await model.startReceiving() }
        #expect(await gate.waitUntilStarted())
        model.beginDestructiveVaultLifecycle()
        await gate.open()
        await starting.value

        #expect(model.receiverPhase == .inactive)
        #expect(model.receiverDetails == nil)
        #expect(!(await service.isReceiving()))
        #expect(await service.stopReceivingCallCount == 1)
    }

    @Test
    func destructiveLifecycleRejectsALateArchiveResultAndCatalogCallback() async throws {
        let fixture = try item(seed: 82, sequence: 0, name: "late-archive.png")
        let service = try LANPendingQueueServiceSpy(items: [fixture.item])
        let gate = AsyncOperationGate()
        await service.setArchiveGate(gate)
        let hook = CatalogRefreshProbe()
        let model = LANInboxModel(service: service) { await hook.record() }
        await model.start()
        model.selectedItemIDs = [fixture.item.id]
        model.reconcileSelectionOrder()
        model.selectedMemberID = UUID()

        let archiving = Task { await model.archiveSelectedItems() }
        #expect(await gate.waitUntilStarted())
        model.beginDestructiveVaultLifecycle()
        await gate.open()
        await archiving.value

        #expect(model.items.isEmpty)
        #expect(model.archiveNotice == nil)
        #expect(model.busyItemIDs.isEmpty)
        #expect(await hook.count == 0)
        #expect(await service.refreshCallCount == 0)
    }

    @Test
    func destructiveLifecycleStopsAMultiDeleteAfterTheInFlightTarget() async throws {
        let first = try item(seed: 83, sequence: 0, name: "first-delete.png")
        let second = try item(seed: 84, sequence: 1, name: "second-delete.png")
        let service = try LANPendingQueueServiceSpy(
            items: [first.item, second.item],
            blobs: [first.blob, second.blob]
        )
        let gate = AsyncOperationGate()
        await service.setDeleteGate(gate, for: first.item.id)
        let model = LANInboxModel(service: service)
        await model.start()
        model.requestDelete([first.item.id, second.item.id])
        let command = try #require(model.pendingDeleteCommand)

        let deleting = Task { await model.confirmDeleteItems(command) }
        #expect(await gate.waitUntilStarted())
        model.beginDestructiveVaultLifecycle()
        await gate.open()
        await deleting.value

        #expect(model.items.isEmpty)
        #expect(model.busyItemIDs.isEmpty)
        #expect(await service.deleteRequests == [command.targets[0]])
        #expect(await service.refreshCallCount == 0)
    }

    @Test
    func destructiveLifecycleRejectsLatePreprocessAndFutureMutations() async throws {
        let fixture = try item(seed: 81, sequence: 0, name: "late-preprocess.png")
        let failed = try LANInboxItem(
            id: fixture.item.id,
            originatingSessionID: fixture.item.originatingSessionID,
            displayName: fixture.item.displayName,
            receivedAt: fixture.item.receivedAt,
            sequence: fixture.item.sequence,
            revision: fixture.item.revision,
            contentIdentity: fixture.item.contentIdentity,
            state: .failed(blobID: fixture.blob.id, issue: .preprocessingFailed)
        )
        let service = try LANPendingQueueServiceSpy(
            items: [failed],
            blobs: [fixture.blob]
        )
        let model = LANInboxModel(service: service)
        await model.start()
        let gate = AsyncOperationGate()
        await service.setPreprocessGate(gate, for: failed.id)

        let preprocessing = Task { await model.retry(itemID: failed.id) }
        #expect(await gate.waitUntilStarted())
        model.beginDestructiveVaultLifecycle()
        await gate.open()
        await preprocessing.value

        #expect(model.items.isEmpty)
        #expect(model.busyItemIDs.isEmpty)
        #expect(model.userErrorMessage == nil)
        #expect(await service.refreshCallCount == 0)

        await model.retry(itemID: failed.id)
        await model.refresh()
        #expect(await service.preprocessedItemIDs == [failed.id])
        #expect(await service.refreshCallCount == 0)
    }

    @Test
    func stoppingReceiverPerformsAFinalQueueRefresh() async throws {
        let completed = try item(seed: 80, sequence: 0, name: "completed.png")
        let service = try LANPendingQueueServiceSpy(items: [])
        await service.configureReceiver(
            resolution: .automatic(
                LANNetworkAddress(
                    interfaceName: "en0",
                    host: "192.0.2.1",
                    networkPrefixLength: 24
                )
            ),
            replacementOnStop: ([completed.item], [completed.blob])
        )
        let model = LANInboxModel(service: service)
        await model.start()
        await model.prepareReceiving()
        model.hasAcknowledgedPrivateNetwork = true
        await model.startReceiving()
        #expect(model.receiverPhase == .active)

        await model.stopReceiving()

        #expect(model.receiverPhase == .inactive)
        #expect(model.items.map(\.id) == [completed.item.id])
    }

    private func item(
        seed: UInt8,
        sequence: UInt64,
        name: String
    ) throws -> (item: LANInboxItem, blob: LANInboxBlob) {
        let digest = Data(repeating: seed, count: 32)
        let blob = try LANInboxBlob(
            id: uuid(seed),
            sha256Digest: digest,
            byteCount: Int(seed) + 1
        )
        let artifact = try LANInboxDerivedArtifact(
            id: uuid(seed &+ 100),
            sha256Digest: Data(repeating: seed &+ 1, count: 32),
            byteCount: Int(seed) + 10
        )
        return (
            try LANInboxItem(
                id: uuid(seed &+ 150),
                originatingSessionID: uuid(seed &+ 151),
                displayName: LANInboxDisplayName(rawValue: name),
                receivedAt: Date(timeIntervalSinceReferenceDate: Double(seed)),
                sequence: sequence,
                contentIdentity: LANInboxContentIdentity(
                    sha256Digest: digest,
                    byteCount: blob.byteCount
                ),
                state: .reviewable(blobID: blob.id, derived: artifact)
            ),
            blob
        )
    }

    private func uuid(_ seed: UInt8) -> UUID {
        UUID(uuid: (
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, seed
        ))
    }
}

private struct ArchiveRequest: Equatable, Sendable {
    let itemIDs: [LANInboxItem.ID]
    let memberID: FamilyMember.ID
    let date: Date
}

private actor LANPendingQueueServiceSpy: LANInboxServicing {
    private(set) var screenSnapshot: LANInboxScreenSnapshot
    private(set) var preprocessedItemIDs: [LANInboxItem.ID] = []
    private(set) var lastArchiveRequest: ArchiveRequest?
    private var archiveError: (any Error)?
    private var deleteError: (any Error)?
    private var receiving = false
    private var resolution: LANNetworkInterfaceResolution = .unavailable
    private var replacementOnStop: ([LANInboxItem], [LANInboxBlob])?
    private var previewPayloads: [LANInboxItem.ID: LANInboxPreviewPayload] = [:]
    private var previewGates: [LANInboxItem.ID: AsyncOperationGate] = [:]
    private var initializeGate: AsyncOperationGate?
    private var refreshGate: AsyncOperationGate?
    private var resolveAddressesGate: AsyncOperationGate?
    private var startReceivingGate: AsyncOperationGate?
    private var archiveGate: AsyncOperationGate?
    private var deleteGates: [LANInboxItem.ID: AsyncOperationGate] = [:]
    private var preprocessGates: [LANInboxItem.ID: AsyncOperationGate] = [:]
    private(set) var previewLoadCount = 0
    private(set) var initializeCallCount = 0
    private(set) var refreshCallCount = 0
    private(set) var resolveAddressesCallCount = 0
    private(set) var stopReceivingCallCount = 0
    private(set) var deleteRequests: [LANInboxDeleteTarget] = []

    init(items: [LANInboxItem], blobs: [LANInboxBlob]? = nil) throws {
        let resolvedBlobs = blobs ?? items.map { item in
            try! LANInboxBlob(
                id: item.blobID,
                sha256Digest: item.contentIdentity.sha256Digest,
                byteCount: item.contentIdentity.byteCount
            )
        }
        let snapshot = try LANInboxSnapshot(
            vaultID: UUID(),
            generation: 1,
            commitID: UUID(),
            lastWriterRuntimeGeneration: UUID(),
            items: items,
            blobs: resolvedBlobs
        )
        screenSnapshot = LANInboxScreenSnapshot(
            snapshot: snapshot,
            storage: try LANInboxStorageSummary(
                itemCount: items.count,
                uniqueBlobCount: resolvedBlobs.count,
                sourceByteCount: resolvedBlobs.reduce(0) { $0 + $1.byteCount },
                derivedArtifactCount: items.compactMap(\.derivedArtifact).count,
                derivedByteCount: items.compactMap(\.derivedArtifact)
                    .reduce(0) { $0 + $1.byteCount },
                pendingUploadCount: 0,
                pendingByteCount: 0,
                metadataByteCount: 0
            )
        )
    }

    func replace(items: [LANInboxItem], blobs: [LANInboxBlob]) throws {
        screenSnapshot = LANInboxScreenSnapshot(
            snapshot: try screenSnapshot.snapshot.replacing(
                generation: screenSnapshot.snapshot.generation + 1,
                commitID: UUID(),
                lastWriterRuntimeGeneration:
                    screenSnapshot.snapshot.lastWriterRuntimeGeneration,
                items: items,
                blobs: blobs
            ),
            storage: screenSnapshot.storage
        )
    }

    func setArchiveError(_ error: any Error) { archiveError = error }
    func setDeleteError(_ error: any Error) { deleteError = error }

    func setPreviewPayload(_ payload: LANInboxPreviewPayload, for itemID: LANInboxItem.ID) {
        previewPayloads[itemID] = payload
    }

    func setPreviewGate(_ gate: AsyncOperationGate, for itemID: LANInboxItem.ID) {
        previewGates[itemID] = gate
    }

    func setInitializeGate(_ gate: AsyncOperationGate) { initializeGate = gate }
    func setRefreshGate(_ gate: AsyncOperationGate) { refreshGate = gate }
    func setResolveAddressesGate(_ gate: AsyncOperationGate) { resolveAddressesGate = gate }
    func setStartReceivingGate(_ gate: AsyncOperationGate) { startReceivingGate = gate }
    func setArchiveGate(_ gate: AsyncOperationGate) { archiveGate = gate }
    func setDeleteGate(_ gate: AsyncOperationGate, for itemID: LANInboxItem.ID) {
        deleteGates[itemID] = gate
    }

    func setPreprocessGate(_ gate: AsyncOperationGate, for itemID: LANInboxItem.ID) {
        preprocessGates[itemID] = gate
    }

    func configureReceiver(
        resolution: LANNetworkInterfaceResolution,
        replacementOnStop: ([LANInboxItem], [LANInboxBlob])?
    ) {
        self.resolution = resolution
        self.replacementOnStop = replacementOnStop
    }

    func initialize() async throws -> LANInboxScreenSnapshot {
        initializeCallCount += 1
        let response = screenSnapshot
        if let gate = initializeGate {
            initializeGate = nil
            await gate.wait()
        }
        return response
    }
    func refresh() async throws -> LANInboxScreenSnapshot {
        refreshCallCount += 1
        let response = screenSnapshot
        if let gate = refreshGate {
            refreshGate = nil
            await gate.wait()
        }
        return response
    }
    func resolveAddresses() async throws -> LANNetworkInterfaceResolution {
        resolveAddressesCallCount += 1
        if let gate = resolveAddressesGate {
            resolveAddressesGate = nil
            await gate.wait()
        }
        return resolution
    }
    func startReceiving(at address: LANNetworkAddress) async throws -> LANReceiverDetails {
        receiving = true
        if let gate = startReceivingGate {
            startReceivingGate = nil
            await gate.wait()
        }
        return LANReceiverDetails(
            url: URL(string: "http://192.0.2.1")!,
            pairingCode: "123456",
            pairingExpiresInSeconds: 300
        )
    }
    func stopReceiving() async {
        stopReceivingCallCount += 1
        receiving = false
        if let replacementOnStop {
            try? replace(items: replacementOnStop.0, blobs: replacementOnStop.1)
            self.replacementOnStop = nil
        }
    }
    func isReceiving() async -> Bool { receiving }
    func preprocess(itemID: LANInboxItem.ID) async throws {
        preprocessedItemIDs.append(itemID)
        if let gate = preprocessGates.removeValue(forKey: itemID) {
            await gate.wait()
        }
    }
    func delete(itemID: LANInboxItem.ID, expectedRevision: UInt64) async throws {
        deleteRequests.append(LANInboxDeleteTarget(
            itemID: itemID,
            expectedRevision: expectedRevision
        ))
        if let gate = deleteGates.removeValue(forKey: itemID) {
            await gate.wait()
        }
        if let deleteError { throw deleteError }
        guard let item = screenSnapshot.snapshot.items.first(where: { $0.id == itemID }),
              item.revision == expectedRevision else {
            throw LANInboxError.staleRevision
        }
        let retainedItems = screenSnapshot.snapshot.items.filter { $0.id != itemID }
        let retainedBlobIDs = Set(retainedItems.map(\.blobID))
        try replace(
            items: retainedItems,
            blobs: screenSnapshot.snapshot.blobs.filter { retainedBlobIDs.contains($0.id) }
        )
    }
    func archive(
        itemIDs: [LANInboxItem.ID],
        memberID: FamilyMember.ID,
        canonicalReportDate: Date
    ) async throws -> LANReportArchiveResult {
        lastArchiveRequest = ArchiveRequest(
            itemIDs: itemIDs,
            memberID: memberID,
            date: canonicalReportDate
        )
        if let archiveError { throw archiveError }
        let removed = Set(itemIDs)
        let retainedItems = screenSnapshot.snapshot.items.filter {
            !removed.contains($0.id)
        }
        let retainedBlobIDs = Set(retainedItems.map(\.blobID))
        try replace(
            items: retainedItems,
            blobs: screenSnapshot.snapshot.blobs.filter {
                retainedBlobIDs.contains($0.id)
            }
        )
        if let archiveGate {
            self.archiveGate = nil
            await archiveGate.wait()
        }
        return .accepted(draftID: UUID())
    }
    func loadPreview(itemID: LANInboxItem.ID) async throws -> LANInboxPreviewPayload {
        previewLoadCount += 1
        if let gate = previewGates.removeValue(forKey: itemID) {
            await gate.wait()
        }
        guard let payload = previewPayloads[itemID] else {
            throw LANInboxError.invalidState
        }
        return payload
    }
}

private actor CatalogRefreshProbe {
    private(set) var count = 0
    func record() { count += 1 }
}
