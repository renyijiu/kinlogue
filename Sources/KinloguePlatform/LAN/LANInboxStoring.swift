import Foundation
import KinlogueCore

/// What a receiver needs from the inbox while it accepts uploads.
package protocol LANUploadStoring: Sendable {
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

public enum LANItemUploadStartOutcome: Sendable {
    case sink(LANUploadSink)
    case terminal(LANInboxTransportReceipt)
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
