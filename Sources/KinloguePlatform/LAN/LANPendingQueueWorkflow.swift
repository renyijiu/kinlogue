import Foundation
import KinlogueCore

public struct LANInboxPreviewPayload: Equatable, Sendable {
    public let data: Data
    public let contentTypeIdentifier: String

    public init(data: Data, contentTypeIdentifier: String) {
        self.data = data
        self.contentTypeIdentifier = contentTypeIdentifier
    }
}

/// Item-oriented use cases shared by the Mac surface and launch recovery.
public actor LANPendingQueueWorkflow {
    private let inbox: PlaintextLANInboxStore
    private let preprocessor: LANItemPreprocessor
    private let archiveCoordinator: LANReportArchiveCoordinator

    public init(
        inbox: PlaintextLANInboxStore,
        preprocessor: LANItemPreprocessor,
        archiveCoordinator: LANReportArchiveCoordinator
    ) {
        self.inbox = inbox
        self.preprocessor = preprocessor
        self.archiveCoordinator = archiveCoordinator
    }

    @discardableResult
    public func preprocess(itemID: LANInboxItem.ID) async throws -> LANInboxItem {
        try await preprocessor.preprocess(itemID: itemID)
    }

    public func archive(
        itemIDs: [LANInboxItem.ID],
        memberID: FamilyMember.ID,
        canonicalReportDate: Date,
        activeSessionID: UUID? = nil
    ) async throws -> LANReportArchiveResult {
        try await archiveCoordinator.archive(
            itemIDs: itemIDs,
            memberID: memberID,
            canonicalReportDate: canonicalReportDate,
            activeSessionID: activeSessionID
        )
    }

    /// Loads only source content accepted by the inert image/PDF validator.
    public func loadPreview(
        itemID: LANInboxItem.ID
    ) async throws -> LANInboxPreviewPayload {
        let snapshot = try await inbox.loadSnapshot()
        guard let item = snapshot.item(id: itemID), item.isReviewable else {
            throw LANInboxError.invalidState
        }
        let validator = ImportedFileValidator()
        return try await inbox.withVerifiedItemSourceContent(itemID: itemID) { descriptor in
            let data = try BoundedRegularFileReader.read(
                descriptor: descriptor,
                maximumByteCount: validator.limits.maximumFileBytes,
                oversizeError: LANInboxError.storageFailure
            )
            let validated = try validator.validate(data: data)
            return LANInboxPreviewPayload(
                data: validated.data,
                contentTypeIdentifier: validated.contentTypeIdentifier
            )
        }
    }

    /// Re-enters durable archive intents. Stored items are scheduled by the
    /// Mac queue model so startup is not blocked by a large OCR backlog.
    public func resumeInterruptedWork() async {
        guard let snapshot = try? await inbox.loadSnapshot() else { return }
        await archiveCoordinator.reconcileTerminalStaging(in: snapshot)
        for intent in snapshot.archiveIntents {
            _ = try? await archiveCoordinator.archive(
                itemIDs: intent.orderedSources.map(\.itemID),
                memberID: intent.memberID,
                canonicalReportDate: intent.canonicalReportDate
            )
        }
    }
}
