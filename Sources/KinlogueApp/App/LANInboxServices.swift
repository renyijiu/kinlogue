import Foundation
import KinlogueCore
import KinloguePlatform

struct LANInboxScreenSnapshot: Equatable, Sendable {
    let snapshot: LANInboxSnapshot
    let storage: LANInboxStorageSummary
}

struct LANReceiverDetails: Equatable, Sendable {
    let url: URL
    let pairingCode: String
    let pairingExpiresInSeconds: Int
}

protocol LANInboxServicing: Sendable {
    func initialize() async throws -> LANInboxScreenSnapshot
    func refresh() async throws -> LANInboxScreenSnapshot
    func resolveAddresses() async throws -> LANNetworkInterfaceResolution
    func startReceiving(at address: LANNetworkAddress) async throws -> LANReceiverDetails
    func stopReceiving() async
    func isReceiving() async -> Bool
    func changeGeneration() async -> UInt64
    func preprocess(itemID: LANInboxItem.ID) async throws
    func delete(itemID: LANInboxItem.ID, expectedRevision: UInt64) async throws
    func archive(
        itemIDs: [LANInboxItem.ID],
        memberID: FamilyMember.ID,
        canonicalReportDate: Date
    ) async throws -> LANReportArchiveResult
    func loadPreview(itemID: LANInboxItem.ID) async throws -> LANInboxPreviewPayload
}

extension LANInboxServicing {
    func changeGeneration() async -> UInt64 { 0 }
}

actor LiveLANInboxService: LANInboxServicing {
    typealias ReceiverStart = @Sendable (
        LANReceiver,
        LANNetworkAddress
    ) async throws -> LANReceiverPresentation

    struct Dependencies: Sendable {
        let sourceVerificationWillHash:
            PlaintextLANInboxStore.SourceVerificationWillHash?
        let receiver: LANReceiver?
        let receiverStart: ReceiverStart

        init(
            sourceVerificationWillHash:
                PlaintextLANInboxStore.SourceVerificationWillHash? = nil,
            receiver: LANReceiver? = nil,
            receiverStart: @escaping ReceiverStart = { receiver, address in
                try await receiver.start(at: address)
            }
        ) {
            self.sourceVerificationWillHash = sourceVerificationWillHash
            self.receiver = receiver
            self.receiverStart = receiverStart
        }
    }

    private struct Runtime {
        let inbox: PlaintextLANInboxStore
        let workflow: LANPendingQueueWorkflow
        let publicationGuard: LANInboxPublicationGuard
        let changeMonitor: LANInboxChangeMonitor
    }

    private let rootURL: URL
    private let vault: PlaintextVault
    private let receiver: LANReceiver
    private let lifecycle: LibraryLifecycleCoordinator
    private let dependencies: Dependencies
    private let lifecycleRegistrationID = UUID()
    private var runtime: Runtime?
    private var lifecycleRegistered = false
    private var revoked = false

    init(
        rootURL: URL,
        vault: PlaintextVault,
        lifecycle: LibraryLifecycleCoordinator,
        dependencies: Dependencies = Dependencies()
    ) {
        self.rootURL = rootURL
        self.vault = vault
        self.lifecycle = lifecycle
        self.dependencies = dependencies
        receiver = dependencies.receiver ?? LANReceiver(rootURL: rootURL)
    }

    func initialize() async throws -> LANInboxScreenSnapshot {
        try await withActiveRuntimeOperation { runtime in
            await runtime.workflow.resumeInterruptedWork()
            return try await Self.screenSnapshot(runtime: runtime)
        }
    }

    func refresh() async throws -> LANInboxScreenSnapshot {
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
        runtime?.changeMonitor.currentGeneration() ?? 0
    }

    func preprocess(itemID: LANInboxItem.ID) async throws {
        try await withActiveRuntimeOperation { runtime in
            _ = try await runtime.workflow.preprocess(itemID: itemID)
        }
    }

    func delete(
        itemID: LANInboxItem.ID,
        expectedRevision: UInt64
    ) async throws {
        try await withActiveRuntimeOperation { [receiver] runtime in
            _ = try await runtime.inbox.deleteItem(
                itemID: itemID,
                expectedRevision: expectedRevision,
                activeSessionID: await receiver.activeSessionID
            )
        }
    }

    func archive(
        itemIDs: [LANInboxItem.ID],
        memberID: FamilyMember.ID,
        canonicalReportDate: Date
    ) async throws -> LANReportArchiveResult {
        try await withActiveRuntimeOperation { [receiver] runtime in
            try await runtime.workflow.archive(
                itemIDs: itemIDs,
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
        runtime?.changeMonitor.stop()
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

        let inbox = try PlaintextLANInboxStore(
            rootURL: rootURL,
            sourceVerificationWillHash: dependencies.sourceVerificationWillHash
        )
        _ = try await inbox.initialize()
        let changeMonitor = try LANInboxChangeMonitor(rootURL: rootURL)
        let publicationGuard = try await inbox.publicationGuard()
        let preprocessor = LANItemPreprocessor(inbox: inbox)
        let archiveCoordinator = try LANReportArchiveCoordinator(
            rootURL: rootURL,
            inbox: inbox,
            vault: vault,
            preprocessor: preprocessor
        )
        let runtime = Runtime(
            inbox: inbox,
            workflow: LANPendingQueueWorkflow(
                inbox: inbox,
                preprocessor: preprocessor,
                archiveCoordinator: archiveCoordinator
            ),
            publicationGuard: publicationGuard,
            changeMonitor: changeMonitor
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

    private static func screenSnapshot(
        runtime: Runtime
    ) async throws -> LANInboxScreenSnapshot {
        let projection = try await runtime.inbox.snapshotAndStorageSummary()
        return LANInboxScreenSnapshot(
            snapshot: projection.snapshot,
            storage: projection.storage
        )
    }
}

actor UnavailableLANInboxService: LANInboxServicing {
    func initialize() async throws -> LANInboxScreenSnapshot {
        throw AppServiceError.runtimeUnavailable
    }
    func refresh() async throws -> LANInboxScreenSnapshot {
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
    func preprocess(itemID: LANInboxItem.ID) async throws {
        throw AppServiceError.runtimeUnavailable
    }
    func delete(itemID: LANInboxItem.ID, expectedRevision: UInt64) async throws {
        throw AppServiceError.runtimeUnavailable
    }
    func archive(
        itemIDs: [LANInboxItem.ID],
        memberID: FamilyMember.ID,
        canonicalReportDate: Date
    ) async throws -> LANReportArchiveResult {
        throw AppServiceError.runtimeUnavailable
    }
    func loadPreview(itemID: LANInboxItem.ID) async throws -> LANInboxPreviewPayload {
        throw AppServiceError.runtimeUnavailable
    }
}
