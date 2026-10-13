import Foundation
import KinlogueCore

package protocol LANUploadStoring: Sendable {
    func initialize() async throws -> LANInboxSnapshot
    func prepare() async throws
    func publicationGuard() async throws -> LANInboxPublicationGuard
    func revokePublications(guardedBy guardValue: LANInboxPublicationGuard) async throws
    func itemAdmissionGeneration() async throws -> UInt64
    func startItemUpload(transport: LANInboxTransportIdentity, metadata: LANInboxTransportMetadata,
                         attemptRevision: UInt64, admissionGeneration: UInt64?,
                         publicationGuard: LANInboxPublicationGuard?) async throws -> LANItemUploadStartOutcome
    func recordItemUploadCancellation(transport: LANInboxTransportIdentity, metadata: LANInboxTransportMetadata,
                                     attemptRevision: UInt64) async throws -> LANInboxTransportReceipt
    func endItemSession(sessionID: UUID) async throws
}

package protocol LANPendingItemStoring: LANInboxRepository, LANUploadStoring {
    func queueScreen(cursor: LANInboxPageCursor?) async throws -> LANInboxQueueScreen
    func itemPage(cursor: LANInboxPageCursor?, processing: Bool) async throws -> LANInboxPage
    func removeItem(itemID: UUID, expectedRevision: UInt64, activeSessionID: UUID?) async throws
    func loadItems(ids: [UUID]) async throws -> [LANInboxItem]
    func snapshotAndStorageSummary() async throws -> LANInboxSnapshotAndStorageSummary
    func deleteItem(itemID: UUID, expectedRevision: UInt64, activeSessionID: UUID?,
                    admissionGenerationCutoff: UInt64?) async throws -> LANInboxSnapshot
    func withVerifiedItemSourceContent<T: Sendable>(itemID: UUID, _ body: @escaping @Sendable (Int32) throws -> T) async throws -> T
    func markItemPreprocessingIssue(itemID: UUID, expectedRevision: UInt64, issue: LANInboxFileIssue) async throws -> LANInboxItem
    func reportAttachmentID(for item: LANInboxItem) async throws -> UUID
    func loadPreprocessedDocument(itemID: UUID, expectedRevision: UInt64) async throws -> LANPreprocessedSourceDocument
    func savePreprocessedDocument(itemID: UUID, expectedRevision: UInt64, document: LANPreprocessedSourceDocument) async throws -> LANInboxItem
}

extension LANUploadStoring {
    package func prepare() async throws { _ = try await initialize() }
}
extension LANPendingItemStoring {
    package func removeItem(itemID: UUID, expectedRevision: UInt64, activeSessionID: UUID?) async throws {
        _ = try await deleteItem(itemID: itemID, expectedRevision: expectedRevision, activeSessionID: activeSessionID, admissionGenerationCutoff: nil)
    }
}

public enum LANItemUploadStartOutcome: Sendable {
    case sink(LANUploadSink)
    case terminal(LANInboxTransportReceipt)
}

public enum LANArchivePreparationOutcome: Equatable, Sendable {
    case active(LANArchiveIntent)
    case completed(LANArchiveTerminal)
}

public struct LANInboxSnapshotAndStorageSummary: Sendable {
    public let damagedItemIDs: [UUID]
    public let damagedReceiptIDs: [UUID]
    public let damagedTerminalIDs: [UUID]
    public let damagedUploadIDs: [UUID]
    public let snapshot: LANInboxSnapshot
    public let storage: LANInboxStorageSummary

    public init(snapshot: LANInboxSnapshot, storage: LANInboxStorageSummary,
                damagedItemIDs: [UUID] = [], damagedReceiptIDs: [UUID] = [], damagedTerminalIDs: [UUID] = [], damagedUploadIDs: [UUID] = []) {
        self.damagedItemIDs = damagedItemIDs; self.damagedReceiptIDs = damagedReceiptIDs; self.damagedTerminalIDs = damagedTerminalIDs; self.damagedUploadIDs = damagedUploadIDs
        self.snapshot = snapshot
        self.storage = storage
    }
}

public struct LANInboxPublicationGuard: Equatable, Sendable {
    public let runtimeGeneration: UUID
    let token: UUID

    init(runtimeGeneration: UUID, token: UUID) {
        self.runtimeGeneration = runtimeGeneration
        self.token = token
    }
}
