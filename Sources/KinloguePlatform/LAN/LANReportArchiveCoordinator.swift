import Foundation
import KinlogueCore

public typealias LANReportArchiveResult = LANArchiveOutcome

/// Turns one ordered Mac selection into at most one review draft. The inbox moves the
/// selection's originals and recognised text into the draft in one transaction, so an
/// interrupted archive leaves either the queue items or the draft, never part of each.
public actor LANReportArchiveCoordinator {
    private let inbox: SQLiteLANInboxStore
    private let preprocessor: LANItemPreprocessor

    package init(inbox: SQLiteLANInboxStore, preprocessor: LANItemPreprocessor) {
        self.inbox = inbox
        self.preprocessor = preprocessor
    }

    public func archive(
        itemIDs: [LANInboxItem.ID],
        expectedRevisions: [UInt64]? = nil,
        memberID: FamilyMember.ID,
        canonicalReportDate: Date,
        activeSessionID: UUID? = nil
    ) async throws -> LANReportArchiveResult {
        if let result = try await inbox.completedArchive(itemIDs: itemIDs, memberID: memberID, canonicalReportDate: canonicalReportDate) {
            return result
        }
        if expectedRevisions == nil { _ = try await preprocessor.preprocess(itemIDs: itemIDs) }
        let prepared = try await preprocessor.preparedSelection(
            itemIDs: itemIDs,
            canonicalReportDate: CanonicalVaultJSON.persistenceStableDate(canonicalReportDate)
        )
        if let expectedRevisions, prepared.items.map(\.revision) != expectedRevisions { throw LANInboxError.staleRevision }
        return try await inbox.archive(prepared, memberID: memberID, canonicalReportDate: canonicalReportDate, activeSessionID: activeSessionID)
    }
}
