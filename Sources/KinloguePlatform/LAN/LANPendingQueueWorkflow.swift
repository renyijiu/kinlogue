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
    private let inbox: SQLiteLANInboxStore
    private let preprocessor: LANItemPreprocessor
    private let archiveCoordinator: LANReportArchiveCoordinator

    package init(inbox: SQLiteLANInboxStore, preprocessor: LANItemPreprocessor, archiveCoordinator: LANReportArchiveCoordinator) {
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
    ) async throws -> LANArchiveOutcome {
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
}
