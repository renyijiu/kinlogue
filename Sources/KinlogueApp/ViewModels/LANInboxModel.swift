import AppKit
import Foundation
import KinlogueCore
import KinloguePlatform
import SwiftUI

enum LANInboxReceiverPhase: Equatable {
    case inactive
    case starting
    case active
    case stopping
}

struct LANInboxArchiveNotice: Equatable, Identifiable {
    let id = UUID()
    let draftID: ImportDraft.ID?
    let duplicateDestination: LANReportDuplicateDestination?
}

struct LANInboxPreviewPresentation: Identifiable, Equatable {
    let id: UUID
    let payload: OriginalDocumentPayload
}

struct LANInboxDeleteTarget: Equatable, Sendable {
    let itemID: LANInboxItem.ID
    let expectedRevision: UInt64
}

struct LANInboxDeleteCommand: Equatable, Sendable {
    let targets: [LANInboxDeleteTarget]
}

private enum LANInboxUserError {
    case cannotOpenQueue
    case cannotLoadMore
    case cannotRefreshQueue
    case noNetworkAddress
    case cannotReadNetworkAddress
    case privateNetworkAcknowledgementRequired
    case networkAddressSelectionRequired
    case cannotStartReceiving
    case cannotArchiveSelection
    case cannotOpenOriginal
    case staleItem
    case preprocessingFailed

    var localizedMessage: String {
        switch self {
        case .cannotOpenQueue:
            AppLocalization.string("无法打开手机上传待确认队列，请稍后重试。")
        case .cannotLoadMore:
            AppLocalization.string("无法加载更多待确认项，请重试。")
        case .cannotRefreshQueue:
            AppLocalization.string("待确认队列暂时无法刷新。")
        case .noNetworkAddress:
            AppLocalization.string("没有可用的局域网地址。请连接 Wi-Fi 或有线网络后重试。")
        case .cannotReadNetworkAddress:
            AppLocalization.string("无法读取这台 Mac 的局域网地址。")
        case .privateNetworkAcknowledgementRequired:
            AppLocalization.string("请先确认仅在可信任的私人局域网中使用。")
        case .networkAddressSelectionRequired:
            AppLocalization.string("请选择一个局域网地址。")
        case .cannotStartReceiving:
            AppLocalization.string("无法开始接收。请检查防火墙、网络连接或稍后重试。")
        case .cannotArchiveSelection:
            AppLocalization.string("所选资料未能加入待确认，资料仍保留在队列中。")
        case .cannotOpenOriginal:
            AppLocalization.string("原件暂时无法打开。")
        case .staleItem:
            AppLocalization.string("资料已发生变化，请刷新后重试。")
        case .preprocessingFailed:
            AppLocalization.string("有资料未能完成本机识别，可单独重试。")
        }
    }
}

@MainActor
final class LANInboxModel: ObservableObject {
    typealias CatalogChangeHook = @Sendable () async -> Void
    typealias DurableStateChangeHook = @Sendable () async -> Void

    private let service: any LANInboxServicing
    private let processing: AppProcessingCoordinator
    private let onCatalogChanged: CatalogChangeHook
    private let onDurableStateChanged: DurableStateChangeHook
    private let lifecycleMonitor: LANSessionLifecycleMonitor
    private var lifecycleAdapter: LANSessionLifecycleNotificationAdapter?
    private var primaryWindowID: ObjectIdentifier?
    private var pollTask: Task<Void, Never>?
    private var retainedItems: [UUID: LANInboxItem] = [:]
    private var queueRequestGeneration: UInt64 = 0
    private var selectedRevisions: [LANInboxItem.ID: UInt64] = [:]
    private var previewRequestGeneration: UInt64 = 0
    private var previewItemRevision: UInt64?
    private var hasStarted = false
    private var vaultLifecycleGeneration: UInt64 = 0
    private var vaultLifecycleIsLocked = false
    private var observedChangeGeneration: UInt64?

    @Published private(set) var hasDamagedItems = false
    @Published private(set) var isLoading = false
    @Published private(set) var page: LANInboxPage?
    @Published private(set) var loadedItems: [LANInboxItem] = []
    @Published private(set) var isLoadingMore = false
    @Published private(set) var usesContentByteTotals = false
    @Published private(set) var storage: LANInboxStorageSummary?
    @Published private(set) var receiverPhase: LANInboxReceiverPhase = .inactive
    @Published private(set) var receiverDetails: LANReceiverDetails?
    @Published private var userError: LANInboxUserError?
    @Published var isReceiverSheetPresented = false
    @Published var hasAcknowledgedPrivateNetwork = false
    @Published private(set) var availableAddresses: [LANNetworkAddress] = []
    @Published var selectedAddress: LANNetworkAddress?
    @Published var selectedItemIDs: Set<LANInboxItem.ID> = []
    @Published private(set) var archiveOrder: [LANInboxItem.ID] = []
    @Published var selectedMemberID: FamilyMember.ID?
    @Published var canonicalReportDate = Date()
    @Published private var mutationItemIDs: Set<LANInboxItem.ID> = []
    @Published private var processingItemIDs: Set<LANInboxItem.ID> = []

    var busyItemIDs: Set<LANInboxItem.ID> { mutationItemIDs.union(processingItemIDs) }
    @Published var archiveNotice: LANInboxArchiveNotice?
    @Published var previewPresentation: LANInboxPreviewPresentation?
    @Published private(set) var pendingDeleteCommand: LANInboxDeleteCommand?

    init(
        service: any LANInboxServicing,
        processing: AppProcessingCoordinator? = nil,
        onCatalogChanged: @escaping CatalogChangeHook = {},
        onDurableStateChanged: @escaping DurableStateChangeHook = {}
    ) {
        self.service = service
        self.processing = processing ?? AppProcessingCoordinator(lanService: service)
        self.onCatalogChanged = onCatalogChanged
        self.onDurableStateChanged = onDurableStateChanged
        lifecycleMonitor = LANSessionLifecycleMonitor(
            stopReceiving: { await service.stopReceiving() },
            invalidateCredential: {}
        )
        self.processing.onLANProcessingChanged = { [weak self] refresh in
            guard let self, !vaultLifecycleIsLocked else { return }
            processingItemIDs = self.processing.busyItemIDs
            if !self.processing.failedItemIDs.isEmpty { userError = .preprocessingFailed }
            if refresh { await self.refresh() }
        }
    }

    deinit {
        pollTask?.cancel()
    }

    var hasMore: Bool { page?.nextCursor != nil }

    var items: [LANInboxItem] {
        loadedItems
    }

    var selectedItem: LANInboxItem? {
        guard selectedItemIDs.count == 1, let id = selectedItemIDs.first else {
            return nil
        }
        return retainedItems[id] ?? items.first { $0.id == id }
    }

    var userErrorMessage: String? {
        userError?.localizedMessage
    }

    var orderedSelectedItems: [LANInboxItem] {
        let byID = knownItems
        return archiveOrder.compactMap { byID[$0] }
    }

    var canArchiveSelection: Bool {
        guard selectedMemberID != nil,
              !archiveOrder.isEmpty,
              archiveOrder.count <= LANArchiveIntent.maximumSourceCount,
              ReportDateSemantics.canonicalDate(from: canonicalReportDate) != nil else {
            return false
        }
        let selected = orderedSelectedItems
        return selected.count == archiveOrder.count
            && selected.allSatisfy {
                $0.isReviewable && !busyItemIDs.contains($0.id)
            }
    }

    func start() async {
        guard let lifecycleGeneration = currentVaultLifecycleGeneration(),
              !hasStarted else { return }
        hasStarted = true
        let request = beginQueueRequest()
        isLoading = true
        defer {
            if acceptsVaultLifecycleResult(lifecycleGeneration) {
                isLoading = false
            }
        }
        do {
            let changeGeneration = await service.changeGeneration()
            guard acceptsVaultLifecycleResult(lifecycleGeneration) else { return }
            let screen = try await service.initialize()
            guard acceptsVaultLifecycleResult(lifecycleGeneration) else { return }
            guard request == queueRequestGeneration else { return }
            apply(screen, retaining: [])
            observedChangeGeneration = changeGeneration
            startPolling()
            schedulePreprocessing()
        } catch {
            guard acceptsVaultLifecycleResult(lifecycleGeneration) else { return }
            guard request == queueRequestGeneration else { return }
            hasStarted = false
            userError = .cannotOpenQueue
        }
    }

    func refresh() async { await refresh(allowAutomaticPreprocessing: true) }

    private func refresh(allowAutomaticPreprocessing: Bool) async {
        guard let lifecycleGeneration = currentVaultLifecycleGeneration() else { return }
        let request = beginQueueRequest()
        do {
            let changeGeneration = await service.changeGeneration()
            let previousChangeGeneration = observedChangeGeneration
            guard acceptsVaultLifecycleResult(lifecycleGeneration) else { return }
            let screen = try await service.refresh()
            guard acceptsVaultLifecycleResult(lifecycleGeneration) else { return }
            let selection = Array(selectedItemIDs)
            var retained: [LANInboxItem] = []
            for offset in stride(from: 0, to: selection.count, by: LANArchiveIntent.maximumSourceCount) {
                let batch = Array(selection[offset..<min(offset + LANArchiveIntent.maximumSourceCount, selection.count)])
                retained += (try? await service.loadItems(ids: batch)) ?? []
                guard acceptsVaultLifecycleResult(lifecycleGeneration), request == queueRequestGeneration else { return }
            }
            if let previewID = previewPresentation?.id, !selection.contains(previewID) {
                retained += (try? await service.loadItems(ids: [previewID])) ?? []
            }
            guard acceptsVaultLifecycleResult(lifecycleGeneration), request == queueRequestGeneration else { return }
            apply(screen, retaining: retained)
            observedChangeGeneration = changeGeneration
            if let previousChangeGeneration,
               changeGeneration > previousChangeGeneration {
                await onDurableStateChanged()
                guard acceptsVaultLifecycleResult(lifecycleGeneration) else { return }
            }
            if allowAutomaticPreprocessing { schedulePreprocessing() }
        } catch {
            guard acceptsVaultLifecycleResult(lifecycleGeneration) else { return }
            guard request == queueRequestGeneration else { return }
            userError = .cannotRefreshQueue
        }
    }

    var canRetryQueueLoad: Bool {
        switch userError {
        case .cannotOpenQueue?, .cannotLoadMore?, .cannotRefreshQueue?: true
        default: false
        }
    }

    func retryQueueLoad() async {
        switch userError {
        case .cannotOpenQueue?: await start()
        case .cannotLoadMore?: await loadMore()
        case .cannotRefreshQueue?: await refresh()
        default: break
        }
    }

    func loadMore() async {
        guard let lifecycleGeneration = currentVaultLifecycleGeneration(), let cursor = page?.nextCursor,
              !isLoadingMore else { return }
        let request = beginQueueRequest()
        isLoadingMore = true
        defer { if request == queueRequestGeneration { isLoadingMore = false } }
        do {
            let screen = try await service.loadPage(cursor: cursor)
            guard acceptsVaultLifecycleResult(lifecycleGeneration), request == queueRequestGeneration else { return }
            apply(screen, retaining: Array(retainedItems.values), appending: true)
        } catch LibraryReportError.staleCursor {
            guard acceptsVaultLifecycleResult(lifecycleGeneration), request == queueRequestGeneration else { return }
            await refresh()
        } catch {
            guard acceptsVaultLifecycleResult(lifecycleGeneration), request == queueRequestGeneration else { return }
            userError = .cannotLoadMore
        }
    }

    private var knownItems: [UUID: LANInboxItem] {
        retainedItems.merging(Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })) { _, visible in visible }
    }

    private func beginQueueRequest() -> UInt64 {
        queueRequestGeneration &+= 1
        isLoadingMore = false
        return queueRequestGeneration
    }

    func prepareReceiving() async {
        guard let lifecycleGeneration = currentVaultLifecycleGeneration() else { return }
        userError = nil
        hasAcknowledgedPrivateNetwork = false
        do {
            let resolution = try await service.resolveAddresses()
            guard acceptsVaultLifecycleResult(lifecycleGeneration) else { return }
            switch resolution {
            case .unavailable:
                availableAddresses = []
                selectedAddress = nil
                userError = .noNetworkAddress
            case .automatic(let address):
                availableAddresses = [address]
                selectedAddress = address
            case .selectionRequired(let addresses):
                availableAddresses = addresses
                selectedAddress = nil
            }
            isReceiverSheetPresented = true
        } catch {
            guard acceptsVaultLifecycleResult(lifecycleGeneration) else { return }
            availableAddresses = []
            selectedAddress = nil
            userError = .cannotReadNetworkAddress
            isReceiverSheetPresented = true
        }
    }

    func startReceiving() async {
        guard let lifecycleGeneration = currentVaultLifecycleGeneration() else { return }
        userError = nil
        guard receiverPhase == .inactive else { return }
        guard hasAcknowledgedPrivateNetwork else {
            userError = .privateNetworkAcknowledgementRequired
            return
        }
        guard let selectedAddress else {
            userError = .networkAddressSelectionRequired
            return
        }
        receiverPhase = .starting
        do {
            let details = try await service.startReceiving(at: selectedAddress)
            guard acceptsVaultLifecycleResult(lifecycleGeneration) else {
                await service.stopReceiving()
                return
            }
            let sessionBegan = await lifecycleMonitor.beginSession(credential: UUID())
            guard acceptsVaultLifecycleResult(lifecycleGeneration) else {
                if sessionBegan {
                    await lifecycleMonitor.handle(.manualStop)
                } else {
                    await service.stopReceiving()
                }
                return
            }
            guard sessionBegan else {
                await service.stopReceiving()
                throw LANReceiverError.alreadyStarted
            }
            receiverDetails = details
            receiverPhase = .active
        } catch {
            guard acceptsVaultLifecycleResult(lifecycleGeneration) else { return }
            clearReceiverPresentation()
            userError = .cannotStartReceiving
        }
    }

    func stopReceiving() async {
        guard let lifecycleGeneration = currentVaultLifecycleGeneration() else { return }
        guard receiverPhase == .active || receiverPhase == .starting else {
            clearReceiverPresentation()
            return
        }
        receiverPhase = .stopping
        if receiverDetails == nil {
            await service.stopReceiving()
        } else {
            await lifecycleMonitor.handle(.manualStop)
        }
        guard acceptsVaultLifecycleResult(lifecycleGeneration) else { return }
        await refresh()
        guard acceptsVaultLifecycleResult(lifecycleGeneration) else { return }
        clearReceiverPresentation()
    }

    func configurePrimaryWindow(_ window: NSWindow?) {
        guard !vaultLifecycleIsLocked, let window else { return }
        let identity = ObjectIdentifier(window)
        guard identity != primaryWindowID else { return }
        lifecycleAdapter?.stop()
        primaryWindowID = identity
        let adapter = LANSessionLifecycleNotificationAdapter(
            monitor: lifecycleMonitor,
            primaryWindow: window,
            eventObserver: { [weak self] event in
                guard event.endsSession else { return }
                Task { @MainActor [weak self] in await self?.finishExternalStop() }
            }
        )
        lifecycleAdapter = adapter
        adapter.start()
    }

    func beginDestructiveVaultLifecycle() {
        guard !vaultLifecycleIsLocked else { return }
        vaultLifecycleIsLocked = true
        vaultLifecycleGeneration &+= 1
        pollTask?.cancel()
        pollTask = nil
        observedChangeGeneration = nil
        processing.beginDestructiveVaultLifecycle()
        lifecycleAdapter?.stop()
        lifecycleAdapter = nil
        primaryWindowID = nil
        selectedRevisions.removeAll()
        mutationItemIDs.removeAll()
        processingItemIDs.removeAll()
        page = nil
        loadedItems = []
        retainedItems = [:]
        _ = beginQueueRequest()
        hasDamagedItems = false
        storage = nil
        availableAddresses = []
        selectedAddress = nil
        selectedItemIDs = []
        archiveOrder = []
        invalidatePreview()
        archiveNotice = nil
        pendingDeleteCommand = nil
        isReceiverSheetPresented = false
        isLoading = false
        hasStarted = false
        userError = nil
        clearReceiverPresentation()
    }

    func reconcileSelectionOrder() {
        guard !vaultLifecycleIsLocked else { return }
        let currentByID = knownItems
        let validSelected = selectedItemIDs.filter { id in
            guard let item = currentByID[id], item.isReviewable else { return false }
            if let frozenRevision = selectedRevisions[id] {
                return frozenRevision == item.revision
            }
            selectedRevisions[id] = item.revision
            return true
        }
        selectedItemIDs = Set(validSelected)
        archiveOrder.removeAll { !selectedItemIDs.contains($0) }
        for item in currentByID.values.sorted(by: { ($0.sequence, $0.id.uuidString) < ($1.sequence, $1.id.uuidString) }) where selectedItemIDs.contains(item.id)
            && !archiveOrder.contains(item.id) {
            archiveOrder.append(item.id)
        }
        selectedRevisions = selectedRevisions.filter {
            selectedItemIDs.contains($0.key)
        }
    }

    func moveArchiveItem(itemID: LANInboxItem.ID, offset: Int) {
        guard !vaultLifecycleIsLocked else { return }
        guard let index = archiveOrder.firstIndex(of: itemID) else { return }
        let destination = index + offset
        guard archiveOrder.indices.contains(destination),
              !archiveOrder.contains(where: busyItemIDs.contains) else { return }
        archiveOrder.swapAt(index, destination)
    }

    func archiveSelectedItems() async {
        guard let lifecycleGeneration = currentVaultLifecycleGeneration(),
              canArchiveSelection,
              let selectedMemberID,
              let reportDate = ReportDateSemantics.canonicalDate(
                from: canonicalReportDate
              ) else { return }
        let orderedIDs = archiveOrder
        let expectedRevisions = orderedSelectedItems.map(\.revision)
        _ = beginQueueRequest()
        invalidatePreview()
        mutationItemIDs.formUnion(orderedIDs)
        defer {
            if acceptsVaultLifecycleResult(lifecycleGeneration) {
                mutationItemIDs.subtract(orderedIDs)
            }
        }
        do {
            let result = try await service.archive(
                itemIDs: orderedIDs,
                expectedRevisions: expectedRevisions,
                memberID: selectedMemberID,
                canonicalReportDate: reportDate
            )
            guard acceptsVaultLifecycleResult(lifecycleGeneration) else { return }
            switch result {
            case let .accepted(draftID):
                archiveNotice = LANInboxArchiveNotice(
                    draftID: draftID,
                    duplicateDestination: nil
                )
                await onCatalogChanged()
                guard acceptsVaultLifecycleResult(lifecycleGeneration) else { return }
            case let .duplicateSkipped(destination):
                archiveNotice = LANInboxArchiveNotice(
                    draftID: nil,
                    duplicateDestination: destination
                )
            }
            selectedItemIDs = []
            archiveOrder = []
            selectedRevisions = [:]
            await refresh()
        } catch {
            guard acceptsVaultLifecycleResult(lifecycleGeneration) else { return }
            userError = .cannotArchiveSelection
            await refresh(allowAutomaticPreprocessing: false)
        }
    }

    func retry(itemID: LANInboxItem.ID) async {
        guard let lifecycleGeneration = currentVaultLifecycleGeneration(),
              let item = knownItems[itemID] else { return }
        switch item.state {
        case .stored, .failed, .unsupported:
            break
        case .preprocessing, .reviewable, .integrityFailed:
            return
        }
        guard !busyItemIDs.contains(itemID) else { return }
        let succeeded = await processing.preprocess(itemID: itemID)
        guard acceptsVaultLifecycleResult(lifecycleGeneration) else { return }
        if !succeeded { userError = .staleItem }
        await refresh(allowAutomaticPreprocessing: succeeded)
    }

    func requestDelete(_ ids: Set<LANInboxItem.ID>) {
        guard !vaultLifecycleIsLocked else { return }
        let targets = knownItems.values.sorted { ($0.sequence, $0.id.uuidString) < ($1.sequence, $1.id.uuidString) }.compactMap { item -> LANInboxDeleteTarget? in
            guard ids.contains(item.id), !busyItemIDs.contains(item.id) else { return nil }
            return LANInboxDeleteTarget(
                itemID: item.id,
                expectedRevision: item.revision
            )
        }
        pendingDeleteCommand = targets.isEmpty
            ? nil
            : LANInboxDeleteCommand(targets: targets)
    }

    func cancelDeleteRequest() {
        guard !vaultLifecycleIsLocked else { return }
        pendingDeleteCommand = nil
    }

    func confirmDeleteItems(_ command: LANInboxDeleteCommand) async {
        guard let lifecycleGeneration = currentVaultLifecycleGeneration() else { return }
        if pendingDeleteCommand == command { pendingDeleteCommand = nil }
        for target in command.targets {
            guard acceptsVaultLifecycleResult(lifecycleGeneration) else { return }
            _ = await performItemMutation(
                itemID: target.itemID,
                refreshAfter: false,
                lifecycleGeneration: lifecycleGeneration
            ) {
                try await service.delete(
                    itemID: target.itemID,
                    expectedRevision: target.expectedRevision
                )
            }
        }
        guard acceptsVaultLifecycleResult(lifecycleGeneration) else { return }
        await refresh()
    }

    func openPreview(itemID: LANInboxItem.ID) async {
        guard let lifecycleGeneration = currentVaultLifecycleGeneration(),
              let item = knownItems[itemID], item.isReviewable else {
            return
        }
        let expectedRevision = item.revision
        let generation = beginPreviewRequest()
        do {
            let payload = try await loadPreviewPayload(itemID: itemID)
            guard acceptsVaultLifecycleResult(lifecycleGeneration),
                  isCurrentPreviewRequest(
                generation,
                itemID: itemID,
                expectedRevision: expectedRevision
            ) else { return }
            previewItemRevision = expectedRevision
            previewPresentation = LANInboxPreviewPresentation(id: itemID, payload: payload)
        } catch {
            guard acceptsVaultLifecycleResult(lifecycleGeneration),
                  generation == previewRequestGeneration else { return }
            userError = .cannotOpenOriginal
        }
    }

    func presentPreview(
        itemID: LANInboxItem.ID,
        payload: OriginalDocumentPayload
    ) {
        guard !vaultLifecycleIsLocked else { return }
        guard knownItems[itemID]?.isReviewable == true else {
            userError = .cannotOpenOriginal
            return
        }
        let generation = beginPreviewRequest()
        guard let item = knownItems[itemID],
              isCurrentPreviewRequest(
                generation,
                itemID: itemID,
                expectedRevision: item.revision
              ) else { return }
        previewItemRevision = item.revision
        previewPresentation = LANInboxPreviewPresentation(id: itemID, payload: payload)
    }

    func dismissPreview() {
        guard !vaultLifecycleIsLocked else { return }
        invalidatePreview()
    }

    func loadPreviewPayload(itemID: LANInboxItem.ID) async throws -> OriginalDocumentPayload {
        guard let lifecycleGeneration = currentVaultLifecycleGeneration(),
              knownItems[itemID]?.isReviewable == true else {
            throw LANInboxError.invalidState
        }
        let preview = try await service.loadPreview(itemID: itemID)
        guard acceptsVaultLifecycleResult(lifecycleGeneration) else {
            throw LANInboxError.invalidState
        }
        return OriginalDocumentPayload(
            data: preview.data,
            contentTypeIdentifier: preview.contentTypeIdentifier
        )
    }

    @discardableResult
    private func performItemMutation(
        itemID: LANInboxItem.ID,
        refreshAfter: Bool = true,
        lifecycleGeneration: UInt64,
        operation: () async throws -> Void
    ) async -> Bool {
        guard acceptsVaultLifecycleResult(lifecycleGeneration),
              !busyItemIDs.contains(itemID) else { return false }
        _ = beginQueueRequest()
        if previewPresentation?.id == itemID { invalidatePreview() }
        mutationItemIDs.insert(itemID)
        defer {
            if acceptsVaultLifecycleResult(lifecycleGeneration) {
                mutationItemIDs.remove(itemID)
            }
        }
        do {
            try await operation()
        } catch {
            guard acceptsVaultLifecycleResult(lifecycleGeneration) else { return false }
            userError = .staleItem
            if refreshAfter { await refresh() }
            return false
        }
        guard acceptsVaultLifecycleResult(lifecycleGeneration) else { return false }
        if refreshAfter { await refresh() }
        return true
    }

    private func apply(_ screen: LANInboxQueueScreen, retaining: [LANInboxItem], appending: Bool = false) {
        guard !vaultLifecycleIsLocked else { return }
        let incoming = screen.page
        if let page {
            guard page.revision.libraryID == incoming.revision.libraryID,
                  page.revision.openEpoch == incoming.revision.openEpoch,
                  incoming.revision.generation >= page.revision.generation else { return }
            if appending && page.revision != incoming.revision { return }
        }
        switch userError {
        case .cannotOpenQueue?, .cannotRefreshQueue?, .cannotLoadMore?: userError = nil
        default: break
        }
        page = incoming
        if appending {
            let existing = Set(loadedItems.map(\.id))
            loadedItems += incoming.items.filter { !existing.contains($0.id) }
        } else { loadedItems = incoming.items }
        retainedItems = Dictionary(uniqueKeysWithValues: retaining.map { ($0.id, $0) })
        hasDamagedItems = (appending && hasDamagedItems) || !incoming.damagedItemIDs.isEmpty || !screen.damagedUploadIDs.isEmpty || !screen.damagedReceiptIDs.isEmpty || !screen.damagedTerminalIDs.isEmpty
        selectedItemIDs.formIntersection(Set(knownItems.keys))
        reconcileSelectionOrder()
        if let presentation = previewPresentation, let previewItemRevision {
            let item = knownItems[presentation.id]
            if item?.revision != previewItemRevision || item?.isReviewable != true { invalidatePreview() }
        }
        storage = screen.storage
        usesContentByteTotals = screen.usesContentByteTotals
    }

    private func beginPreviewRequest() -> UInt64 {
        previewRequestGeneration &+= 1
        previewPresentation = nil
        previewItemRevision = nil
        return previewRequestGeneration
    }

    private func invalidatePreview() {
        previewRequestGeneration &+= 1
        previewPresentation = nil
        previewItemRevision = nil
    }

    private func isCurrentPreviewRequest(
        _ generation: UInt64,
        itemID: LANInboxItem.ID,
        expectedRevision: UInt64
    ) -> Bool {
        generation == previewRequestGeneration
            && knownItems[itemID]?.revision == expectedRevision
            && knownItems[itemID]?.isReviewable == true
    }

    private func schedulePreprocessing() {
        guard !vaultLifecycleIsLocked else { return }
        processingItemIDs = processing.busyItemIDs
        processing.schedulePreprocessing()
    }

    private func startPolling() {
        guard let lifecycleGeneration = currentVaultLifecycleGeneration(),
              pollTask == nil else { return }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled,
                      acceptsVaultLifecycleResult(lifecycleGeneration) else { return }
                await pollReceiverOnce()
            }
        }
    }

    func pollReceiverOnce() async {
        guard let lifecycleGeneration = currentVaultLifecycleGeneration(),
              receiverPhase == .active else { return }
        let isReceiving = await service.isReceiving()
        guard acceptsVaultLifecycleResult(lifecycleGeneration) else { return }
        guard isReceiving else {
            await refresh()
            guard acceptsVaultLifecycleResult(lifecycleGeneration) else { return }
            clearReceiverPresentation()
            return
        }
        let changeGeneration = await service.changeGeneration()
        guard acceptsVaultLifecycleResult(lifecycleGeneration) else { return }
        if observedChangeGeneration != changeGeneration { await refresh() }
    }

    private func finishExternalStop() async {
        guard let lifecycleGeneration = currentVaultLifecycleGeneration(),
              receiverPhase == .active || receiverPhase == .starting else { return }
        receiverPhase = .stopping
        await service.stopReceiving()
        guard acceptsVaultLifecycleResult(lifecycleGeneration) else { return }
        await refresh()
        guard acceptsVaultLifecycleResult(lifecycleGeneration) else { return }
        clearReceiverPresentation()
    }

    private func clearReceiverPresentation() {
        receiverPhase = .inactive
        receiverDetails = nil
        hasAcknowledgedPrivateNetwork = false
    }

    private func currentVaultLifecycleGeneration() -> UInt64? {
        vaultLifecycleIsLocked ? nil : vaultLifecycleGeneration
    }

    private func acceptsVaultLifecycleResult(_ generation: UInt64) -> Bool {
        !vaultLifecycleIsLocked && generation == vaultLifecycleGeneration
    }
}
