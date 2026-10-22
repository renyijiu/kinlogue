import Foundation
import KinlogueCore
import KinloguePlatform

struct LANReceiverDetails: Equatable, Sendable {
    let url: URL
    let pairingCode: String
    let pairingExpiresInSeconds: Int
}

protocol LANInboxServicing: Sendable {
    func initialize() async throws -> LANInboxQueueScreen
    func refresh() async throws -> LANInboxQueueScreen
    func loadPage(cursor: LANInboxPageCursor) async throws -> LANInboxQueueScreen
    func processingPage(cursor: LANInboxPageCursor?) async throws -> LANInboxPage
    func loadItems(ids: [UUID]) async throws -> [LANInboxItem]
    func resolveAddresses() async throws -> LANNetworkInterfaceResolution
    func startReceiving(at address: LANNetworkAddress) async throws -> LANReceiverDetails
    func stopReceiving() async
    func isReceiving() async -> Bool
    func changeGeneration() async -> UInt64
    func preprocess(itemID: LANInboxItem.ID, expectedRevision: UInt64?) async throws
    func delete(itemID: LANInboxItem.ID, expectedRevision: UInt64) async throws
    func archive(
        itemIDs: [LANInboxItem.ID],
        expectedRevisions: [UInt64]?,
        memberID: FamilyMember.ID,
        canonicalReportDate: Date
    ) async throws -> LANArchiveOutcome
    func loadPreview(itemID: LANInboxItem.ID) async throws -> LANInboxPreviewPayload
}

extension LANInboxServicing {
    func preprocess(itemID: LANInboxItem.ID) async throws { try await preprocess(itemID: itemID, expectedRevision: nil) }
    func changeGeneration() async -> UInt64 { 0 }
    func archive(itemIDs: [UUID], memberID: UUID, canonicalReportDate: Date) async throws -> LANArchiveOutcome {
        try await archive(itemIDs: itemIDs, expectedRevisions: nil, memberID: memberID, canonicalReportDate: canonicalReportDate)
    }
}

actor LiveLANInboxService: LANInboxServicing {
    typealias ReceiverStart = @Sendable (
        LANReceiver,
        LANNetworkAddress
    ) async throws -> LANReceiverPresentation

    struct Dependencies: Sendable {
        let receiver: LANReceiver?
        let receiverStart: ReceiverStart

        init(
            receiver: LANReceiver? = nil,
            receiverStart: @escaping ReceiverStart = { receiver, address in
                try await receiver.start(at: address)
            }
        ) {
            self.receiver = receiver
            self.receiverStart = receiverStart
        }
    }

    private struct Runtime {
        let inbox: SQLiteLANInboxStore
        let workflow: LANPendingQueueWorkflow
        let publicationGuard: LANInboxPublicationGuard
    }

    private let inbox: SQLiteLANInboxStore
    private var lastAdmissionGeneration: UInt64?
    private var observedChangeGeneration: UInt64 = 0
    private let receiver: LANReceiver
    private let lifecycle: LibraryLifecycleCoordinator
    private let dependencies: Dependencies
    private let lifecycleRegistrationID = UUID()
    private var runtime: Runtime?
    private var lifecycleRegistered = false
    private var revoked = false

    init(store: SQLiteLibraryStore, lifecycle: LibraryLifecycleCoordinator, dependencies: Dependencies = Dependencies()) throws {
        let inbox = try SQLiteLANInboxStore(store: store)
        self.inbox = inbox
        self.lifecycle = lifecycle
        self.dependencies = dependencies
        receiver = dependencies.receiver ?? LANReceiver(store: inbox)
    }

    func initialize() async throws -> LANInboxQueueScreen {
        try await withActiveRuntimeOperation { runtime in
            return try await Self.screenSnapshot(runtime: runtime)
        }
    }

    func refresh() async throws -> LANInboxQueueScreen {
        try await withActiveRuntimeOperation { runtime in
            try await Self.screenSnapshot(runtime: runtime)
        }
    }

    func resolveAddresses() async throws -> LANNetworkInterfaceResolution {
        try await lifecycle.requireActive()
        return try LANNetworkInterfaceResolver.current()
    }

    func startReceiving(at address: LANNetworkAddress) async throws -> LANReceiverDetails {
        try await withActiveRuntimeOperation { [self] _ in
            try await lifecycle.requireActive()
            let presentation = try await dependencies.receiverStart(receiver, address)
            do {
                try await lifecycle.requireActive()
                guard let url = presentation.url else {
                    throw LANReceiverError.invalidRequest
                }
                return LANReceiverDetails(
                    url: url,
                    pairingCode: presentation.pairingCode.value,
                    pairingExpiresInSeconds: presentation.pairingExpiresInSeconds
                )
            } catch {
                await receiver.stop()
                throw error
            }
        }
    }

    func stopReceiving() async { await receiver.stop() }

    func isReceiving() async -> Bool { await receiver.isActive }

    func changeGeneration() async -> UInt64 {
        let generation = try? await inbox.itemAdmissionGeneration()
        if generation != lastAdmissionGeneration || inbox.admissionPolicy.currentUsage.activeUploadCount > 0 {
            lastAdmissionGeneration = generation
            observedChangeGeneration &+= 1
        }
        return observedChangeGeneration
    }

    func preprocess(itemID: LANInboxItem.ID, expectedRevision: UInt64? = nil) async throws {
        try await withActiveRuntimeOperation { runtime in
            _ = try await runtime.workflow.preprocess(itemID: itemID, expectedRevision: expectedRevision)
        }
    }

    func delete(
        itemID: LANInboxItem.ID,
        expectedRevision: UInt64
    ) async throws {
        try await withActiveRuntimeOperation { [receiver] runtime in
            try await runtime.inbox.removeItem(
                itemID: itemID,
                expectedRevision: expectedRevision,
                activeSessionID: await receiver.activeSessionID
            )
        }
    }

    func archive(
        itemIDs: [LANInboxItem.ID],
        expectedRevisions: [UInt64]?,
        memberID: FamilyMember.ID,
        canonicalReportDate: Date
    ) async throws -> LANArchiveOutcome {
        try await withActiveRuntimeOperation { [receiver] runtime in
            try await runtime.workflow.archive(
                itemIDs: itemIDs,
                expectedRevisions: expectedRevisions,
                memberID: memberID,
                canonicalReportDate: canonicalReportDate,
                activeSessionID: await receiver.activeSessionID
            )
        }
    }

    func loadPreview(
        itemID: LANInboxItem.ID
    ) async throws -> LANInboxPreviewPayload {
        try await withActiveRuntimeOperation { runtime in
            try await runtime.workflow.loadPreview(itemID: itemID)
        }
    }

    private func revokeForVaultDeletion() async {
        guard !revoked else { return }
        revoked = true
        await receiver.stop()
        if let runtime {
            try? await runtime.inbox.revokePublications(
                guardedBy: runtime.publicationGuard
            )
        }
        self.runtime = nil
    }

    private func requireRuntime() async throws -> Runtime {
        try await lifecycle.requireActive()
        guard !revoked else { throw LibraryLifecycleCoordinatorError.revoked }
        if let runtime { return runtime }

        if !lifecycleRegistered {
            let service = self
            try await lifecycle.register(id: lifecycleRegistrationID) {
                await service.revokeForVaultDeletion()
            }
            lifecycleRegistered = true
        }

        try await inbox.prepare()
        let preprocessor = LANItemPreprocessor(inbox: inbox)
        let archiveCoordinator = LANReportArchiveCoordinator(inbox: inbox, preprocessor: preprocessor)
        let publicationGuard = try await inbox.publicationGuard()
        let runtime = Runtime(
            inbox: inbox,
            workflow: LANPendingQueueWorkflow(
                inbox: inbox,
                preprocessor: preprocessor,
                archiveCoordinator: archiveCoordinator
            ),
            publicationGuard: publicationGuard
        )
        try await lifecycle.requireActive()
        guard !revoked else { throw LibraryLifecycleCoordinatorError.revoked }
        self.runtime = runtime
        return runtime
    }

    private func withActiveRuntimeOperation<Result: Sendable>(
        _ operation: @escaping @Sendable (Runtime) async throws -> Result
    ) async throws -> Result {
        try await lifecycle.withActiveOperation { [self] in
            let runtime = try await self.requireRuntime()
            return try await operation(runtime)
        }
    }

    private static func screenSnapshot(runtime: Runtime) async throws -> LANInboxQueueScreen {
        try await runtime.inbox.queueScreen(cursor: nil)
    }

    func loadPage(cursor: LANInboxPageCursor) async throws -> LANInboxQueueScreen {
        try await withActiveRuntimeOperation { try await $0.inbox.queueScreen(cursor: cursor) }
    }
    func processingPage(cursor: LANInboxPageCursor?) async throws -> LANInboxPage {
        try await withActiveRuntimeOperation { try await $0.inbox.itemPage(cursor: cursor, processing: true) }
    }
    func loadItems(ids: [UUID]) async throws -> [LANInboxItem] {
        try await withActiveRuntimeOperation { try await $0.inbox.loadItems(ids: ids) }
    }
}

actor UnavailableLANInboxService: LANInboxServicing {
    func loadPage(cursor: LANInboxPageCursor) async throws -> LANInboxQueueScreen { throw AppServiceError.runtimeUnavailable }
    func processingPage(cursor: LANInboxPageCursor?) async throws -> LANInboxPage { throw AppServiceError.runtimeUnavailable }
    func loadItems(ids: [UUID]) async throws -> [LANInboxItem] { throw AppServiceError.runtimeUnavailable }
    func initialize() async throws -> LANInboxQueueScreen {
        throw AppServiceError.runtimeUnavailable
    }
    func refresh() async throws -> LANInboxQueueScreen {
        throw AppServiceError.runtimeUnavailable
    }
    func resolveAddresses() async throws -> LANNetworkInterfaceResolution {
        throw AppServiceError.runtimeUnavailable
    }
    func startReceiving(at address: LANNetworkAddress) async throws -> LANReceiverDetails {
        throw AppServiceError.runtimeUnavailable
    }
    func stopReceiving() async {}
    func isReceiving() async -> Bool { false }
    func preprocess(itemID: LANInboxItem.ID, expectedRevision: UInt64? = nil) async throws {
        throw AppServiceError.runtimeUnavailable
    }
    func delete(itemID: LANInboxItem.ID, expectedRevision: UInt64) async throws {
        throw AppServiceError.runtimeUnavailable
    }
    func archive(
        itemIDs: [LANInboxItem.ID],
        expectedRevisions: [UInt64]?,
        memberID: FamilyMember.ID,
        canonicalReportDate: Date
    ) async throws -> LANArchiveOutcome {
        throw AppServiceError.runtimeUnavailable
    }
    func loadPreview(itemID: LANInboxItem.ID) async throws -> LANInboxPreviewPayload {
        throw AppServiceError.runtimeUnavailable
    }
}
