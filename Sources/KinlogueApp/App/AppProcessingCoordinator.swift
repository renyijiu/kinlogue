import Foundation
import KinlogueCore

/// App-owned recovery and LAN processing survive presentation changes. Durable
/// draft/item states remain the source of truth; failures need an explicit retry.
@MainActor
final class AppProcessingCoordinator {
    typealias ChangeHook = @Sendable () async -> Void

    private let lanService: any LANInboxServicing
    private let lifecycle: LibraryLifecycleCoordinator?
    private let onCatalogChanged: ChangeHook
    private let onDurableStateChanged: ChangeHook
    private let registrationID = UUID()
    private var registered = false
    private var revoked = false
    private var recoveryStarted = false
    private var recoveryTask: Task<Void, Never>?
    private var queueTask: Task<Void, Never>?
    private var itemTasks: [LANInboxItem.ID: Task<Bool, Never>] = [:]
    private var processingRefreshRequested = false
    private var processingEpoch: UUID?
    private var attemptedRevisions: [LANInboxItem.ID: UInt64] = [:]
    private(set) var failedItemIDs: Set<LANInboxItem.ID> = []
    var onLANProcessingChanged: (@MainActor (_ refresh: Bool) async -> Void)?

    var busyItemIDs: Set<LANInboxItem.ID> { Set(itemTasks.keys) }

    init(
        lanService: any LANInboxServicing,
        lifecycle: LibraryLifecycleCoordinator? = nil,
        onCatalogChanged: @escaping ChangeHook = {},
        onDurableStateChanged: @escaping ChangeHook = {}
    ) {
        self.lanService = lanService
        self.lifecycle = lifecycle
        self.onCatalogChanged = onCatalogChanged
        self.onDurableStateChanged = onDurableStateChanged
    }

    func startRecovery(using service: LiveAppService) async {
        guard !recoveryStarted, await requireActive(), !recoveryStarted else { return }
        recoveryStarted = true
        recoveryTask = Task { [self] in
            await service.resumeInterruptedImports { [weak self] in
                await self?.reportRecoveryChanged()
            }
            recoveryTask = nil
        }
    }

    func schedulePreprocessing() {
        guard !revoked else { return }
        processingRefreshRequested = true
        guard queueTask == nil else { return }
        queueTask = Task { [self] in
            defer { queueTask = nil }
            while processingRefreshRequested, !Task.isCancelled, await requireActive() {
                processingRefreshRequested = false
                var cursor: LANInboxPageCursor?
                var seen: Set<UUID> = []
                do {
                    repeat {
                        let page = try await lanService.processingPage(cursor: cursor)
                        try Task.checkCancellation()
                        guard !revoked else { return }
                        if processingEpoch != page.revision.openEpoch {
                            attemptedRevisions.removeAll(); failedItemIDs.removeAll()
                            processingEpoch = page.revision.openEpoch
                        }
                        seen.formUnion(page.items.map(\.id))
                        seen.formUnion(page.damagedItemIDs)
                        for item in page.items {
                            guard case .stored = item.state,
                                  attemptedRevisions[item.id] != item.revision else { continue }
                            try Task.checkCancellation()
                            attemptedRevisions[item.id] = item.revision
                            _ = await preprocess(itemID: item.id, expectedRevision: item.revision)
                        }
                        cursor = page.nextCursor
                    } while cursor != nil
                    // Only a complete independent sweep may prune retained attempts.
                    attemptedRevisions = attemptedRevisions.filter { seen.contains($0.key) }
                    failedItemIDs.formIntersection(seen)
                } catch {
                    // A request that arrived during the failed sweep still gets a sweep of its own.
                    // Without one, the loop ends here instead of retrying the same failure.
                    if processingRefreshRequested { continue }
                    return
                }
            }
        }
    }

    @discardableResult
    func preprocess(itemID: LANInboxItem.ID, expectedRevision: UInt64? = nil) async -> Bool {
        guard await requireActive() else { return false }
        if let task = itemTasks[itemID] { return await task.value }
        if expectedRevision == nil, let item = try? await lanService.loadItems(ids: [itemID]).first {
            attemptedRevisions[itemID] = item.revision
        }
        guard !revoked, !Task.isCancelled else { return false }
        if let task = itemTasks[itemID] { return await task.value }
        let service = lanService
        let task = Task {
            do {
                try Task.checkCancellation()
                try await service.preprocess(itemID: itemID, expectedRevision: expectedRevision)
                try Task.checkCancellation()
                return true
            } catch { return false }
        }
        itemTasks[itemID] = task
        await onLANProcessingChanged?(false)
        let succeeded = await task.value
        itemTasks.removeValue(forKey: itemID)
        guard !revoked, !Task.isCancelled else { return false }
        if succeeded { failedItemIDs.remove(itemID) }
        else { failedItemIDs.insert(itemID) }
        await onDurableStateChanged()
        guard !revoked, !Task.isCancelled else { return false }
        await onLANProcessingChanged?(true)
        return succeeded
    }

    func beginDestructiveVaultLifecycle() {
        guard !revoked else { return }
        revoked = true
        recoveryTask?.cancel()
        queueTask?.cancel()
        for task in itemTasks.values { task.cancel() }
        processingRefreshRequested = false
    }

    func cancelAndDrain() async {
        beginDestructiveVaultLifecycle()
        let recovery = recoveryTask
        let queue = queueTask
        let items = Array(itemTasks.values)
        await recovery?.value
        await queue?.value
        for task in items { _ = await task.value }
    }

    private func requireActive() async -> Bool {
        guard !revoked else { return false }
        do {
            if let lifecycle {
                try await lifecycle.requireActive()
                if !registered {
                    try await lifecycle.register(id: registrationID) { [weak self] in
                        await self?.cancelAndDrain()
                    }
                    registered = true
                }
            }
            return !revoked
        } catch { return false }
    }

    private func reportRecoveryChanged() async {
        guard !revoked, !Task.isCancelled else { return }
        await onCatalogChanged()
        guard !revoked, !Task.isCancelled else { return }
        await onDurableStateChanged()
    }
}
