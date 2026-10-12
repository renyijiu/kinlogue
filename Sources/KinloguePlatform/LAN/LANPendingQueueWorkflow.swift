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
    private let inbox: any LANPendingItemStoring
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

    package init(inbox: any LANPendingItemStoring, preprocessor: LANItemPreprocessor, archiveCoordinator: LANReportArchiveCoordinator) {
        self.inbox = inbox; self.preprocessor = preprocessor; self.archiveCoordinator = archiveCoordinator
    }

    @discardableResult
    public func preprocess(itemID: LANInboxItem.ID, expectedRevision: UInt64? = nil) async throws -> LANInboxItem {
        try await preprocessor.preprocess(itemID: itemID, expectedRevision: expectedRevision)
    }

    public func archive(
        itemIDs: [LANInboxItem.ID],
        expectedRevisions: [UInt64]? = nil,
        memberID: FamilyMember.ID,
        canonicalReportDate: Date,
        activeSessionID: UUID? = nil
    ) async throws -> LANReportArchiveResult {
        try await archiveCoordinator.archive(
            itemIDs: itemIDs,
            expectedRevisions: expectedRevisions,
            memberID: memberID,
            canonicalReportDate: canonicalReportDate,
            activeSessionID: activeSessionID
        )
    }

    /// Loads only source content accepted by the inert image/PDF validator.
    public func loadPreview(
        itemID: LANInboxItem.ID
    ) async throws -> LANInboxPreviewPayload {
        let items = try await inbox.loadItems(ids: [itemID])
        guard let item = items.first, item.isReviewable else {
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
    /// App processing coordinator so startup is not blocked by a large OCR backlog.
    public func resumeInterruptedWork() async {
        guard let snapshot = try? await inbox.archiveRecoverySnapshot() else { return }
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
