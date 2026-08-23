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
    private let onCatalogChanged: CatalogChangeHook
    private let onDurableStateChanged: DurableStateChangeHook
    private let lifecycleMonitor: LANSessionLifecycleMonitor
    private var lifecycleAdapter: LANSessionLifecycleNotificationAdapter?
    private var primaryWindowID: ObjectIdentifier?
    private var pollTask: Task<Void, Never>?
    private var preprocessingTask: Task<Void, Never>?
    private var automaticPreprocessingFailures: Set<LANInboxItem.ID> = []
    private var selectedRevisions: [LANInboxItem.ID: UInt64] = [:]
    private var previewRequestGeneration: UInt64 = 0
    private var previewItemRevision: UInt64?
    private var hasStarted = false
    private var vaultLifecycleGeneration: UInt64 = 0
    private var vaultLifecycleIsLocked = false
    private var observedChangeGeneration: UInt64?

    @Published private(set) var isLoading = false
    @Published private(set) var snapshot: LANInboxSnapshot?
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
    @Published private(set) var busyItemIDs: Set<LANInboxItem.ID> = []
    @Published var archiveNotice: LANInboxArchiveNotice?
    @Published var previewPresentation: LANInboxPreviewPresentation?
    @Published private(set) var pendingDeleteCommand: LANInboxDeleteCommand?

    init(
        service: any LANInboxServicing,
        onCatalogChanged: @escaping CatalogChangeHook = {},
        onDurableStateChanged: @escaping DurableStateChangeHook = {}
    ) {
        self.service = service
        self.onCatalogChanged = onCatalogChanged
        self.onDurableStateChanged = onDurableStateChanged
        lifecycleMonitor = LANSessionLifecycleMonitor(
            stopReceiving: { await service.stopReceiving() },
            invalidateCredential: {}
        )
    }

    deinit {
        pollTask?.cancel()
        preprocessingTask?.cancel()
    }

    var items: [LANInboxItem] {
        snapshot?.items ?? []
    }

    var selectedItem: LANInboxItem? {
        guard selectedItemIDs.count == 1, let id = selectedItemIDs.first else {
            return nil
        }
        return items.first { $0.id == id }
    }

    var userErrorMessage: String? {
        userError?.localizedMessage
    }

    var orderedSelectedItems: [LANInboxItem] {
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
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
            apply(screen)
            observedChangeGeneration = changeGeneration
            startPolling()
            schedulePreprocessing()
        } catch {
            guard acceptsVaultLifecycleResult(lifecycleGeneration) else { return }
            hasStarted = false
            userError = .cannotOpenQueue
        }
    }

    func refresh() async { await refresh(allowAutomaticPreprocessing: true) }

    private func refresh(allowAutomaticPreprocessing: Bool) async {
        guard let lifecycleGeneration = currentVaultLifecycleGeneration() else { return }
        do {
            let changeGeneration = await service.changeGeneration()
            let previousChangeGeneration = observedChangeGeneration
            guard acceptsVaultLifecycleResult(lifecycleGeneration) else { return }
            let screen = try await service.refresh()
            guard acceptsVaultLifecycleResult(lifecycleGeneration) else { return }
            apply(screen)
            observedChangeGeneration = changeGeneration
            if let previousChangeGeneration,
               changeGeneration > previousChangeGeneration {
                await onDurableStateChanged()
                guard acceptsVaultLifecycleResult(lifecycleGeneration) else { return }
            }
            if allowAutomaticPreprocessing { schedulePreprocessing() }
        } catch {
            guard acceptsVaultLifecycleResult(lifecycleGeneration) else { return }
            userError = .cannotRefreshQueue
        }
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
        preprocessingTask?.cancel()
        preprocessingTask = nil
        lifecycleAdapter?.stop()
        lifecycleAdapter = nil
        primaryWindowID = nil
        automaticPreprocessingFailures.removeAll()
        selectedRevisions.removeAll()
        busyItemIDs.removeAll()
        snapshot = nil
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
        let currentByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
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
        for item in items where selectedItemIDs.contains(item.id)
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
        busyItemIDs.formUnion(orderedIDs)
        defer {
            if acceptsVaultLifecycleResult(lifecycleGeneration) {
                busyItemIDs.subtract(orderedIDs)
            }
        }
        do {
            let result = try await service.archive(
                itemIDs: orderedIDs,
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
              let item = items.first(where: { $0.id == itemID }) else { return }
        switch item.state {
        case .stored, .failed, .unsupported:
            break
        case .preprocessing, .reviewable, .integrityFailed:
            return
        }
        let succeeded = await performItemMutation(
            itemID: itemID,
            refreshAfter: false,
            lifecycleGeneration: lifecycleGeneration
        ) {
            try await service.preprocess(itemID: itemID)
        }
        guard acceptsVaultLifecycleResult(lifecycleGeneration) else { return }
        if succeeded {
            automaticPreprocessingFailures.remove(itemID)
        } else {
            automaticPreprocessingFailures.insert(itemID)
        }
        await refresh(allowAutomaticPreprocessing: succeeded)
    }

    func requestDelete(_ ids: Set<LANInboxItem.ID>) {
        guard !vaultLifecycleIsLocked else { return }
        let targets = items.compactMap { item -> LANInboxDeleteTarget? in
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
              let item = items.first(where: { $0.id == itemID }), item.isReviewable else {
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
        guard items.first(where: { $0.id == itemID })?.isReviewable == true else {
            userError = .cannotOpenOriginal
            return
        }
        let generation = beginPreviewRequest()
        guard let item = items.first(where: { $0.id == itemID }),
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
              items.first(where: { $0.id == itemID })?.isReviewable == true else {
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
              busyItemIDs.insert(itemID).inserted else { return false }
        defer {
            if acceptsVaultLifecycleResult(lifecycleGeneration) {
                busyItemIDs.remove(itemID)
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

    private func apply(_ screen: LANInboxScreenSnapshot) {
        guard !vaultLifecycleIsLocked else { return }
        if let snapshot, screen.snapshot.generation < snapshot.generation { return }
        if snapshot != screen.snapshot {
            snapshot = screen.snapshot
            let currentIDs = Set(screen.snapshot.items.map(\.id))
            selectedItemIDs.formIntersection(currentIDs)
            automaticPreprocessingFailures.formIntersection(currentIDs)
            reconcileSelectionOrder()
        }
        if let presentation = previewPresentation,
           let previewItemRevision,
           !screen.snapshot.items.contains(where: {
               $0.id == presentation.id
                   && $0.revision == previewItemRevision
                   && $0.isReviewable
           }) {
            invalidatePreview()
        }
        if storage != screen.storage { storage = screen.storage }
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
            && items.contains(where: {
                $0.id == itemID
                    && $0.revision == expectedRevision
                    && $0.isReviewable
            })
    }

    private func schedulePreprocessing() {
        guard let lifecycleGeneration = currentVaultLifecycleGeneration(),
              preprocessingTask == nil else { return }
        preprocessingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var attemptedItemIDs: Set<LANInboxItem.ID> = []
            while !Task.isCancelled,
                  acceptsVaultLifecycleResult(lifecycleGeneration) {
                guard let item = items.first(where: {
                    guard case .stored = $0.state else { return false }
                    return !attemptedItemIDs.contains($0.id)
                        && !automaticPreprocessingFailures.contains($0.id)
                }) else { break }
                let itemID = item.id
                attemptedItemIDs.insert(itemID)
                busyItemIDs.insert(itemID)
                do {
                    try await service.preprocess(itemID: itemID)
                    guard acceptsVaultLifecycleResult(lifecycleGeneration) else { return }
                    automaticPreprocessingFailures.remove(itemID)
                } catch {
                    guard acceptsVaultLifecycleResult(lifecycleGeneration) else { return }
                    automaticPreprocessingFailures.insert(itemID)
                    userError = .preprocessingFailed
                }
                busyItemIDs.remove(itemID)
                await refresh(allowAutomaticPreprocessing: false)
            }
            if acceptsVaultLifecycleResult(lifecycleGeneration) {
                preprocessingTask = nil
            }
        }
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
