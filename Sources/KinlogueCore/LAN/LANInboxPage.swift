import Foundation

/// A queue page is not a complete durable inbox snapshot.
package struct LANInboxPageCursor: Equatable, Sendable {
    package let revision: LibraryRevision
    package let sequence: UInt64
    package let id: UUID
    package let processing: Bool
    package init(revision: LibraryRevision, sequence: UInt64, id: UUID, processing: Bool) {
        self.revision = revision; self.sequence = sequence; self.id = id; self.processing = processing
    }
}

package struct LANInboxPage: Equatable, Sendable {
    package let revision: LibraryRevision
    package let items: [LANInboxItem]
    package let nextCursor: LANInboxPageCursor?
    package let damagedItemIDs: [UUID]
    package init(revision: LibraryRevision, items: [LANInboxItem], nextCursor: LANInboxPageCursor?, damagedItemIDs: [UUID] = []) {
        self.revision = revision; self.items = items; self.nextCursor = nextCursor; self.damagedItemIDs = damagedItemIDs
    }
}

package struct LANInboxQueueScreen: Equatable, Sendable {
    package let page: LANInboxPage
    package let storage: LANInboxStorageSummary
    /// SQL totals describe metadata content bytes, not physical occupancy or a full integrity check.
    package let usesContentByteTotals: Bool
    package let damagedReceiptIDs: [UUID]
    package let damagedTerminalIDs: [UUID]
    package let damagedUploadIDs: [UUID]
    package init(page: LANInboxPage, storage: LANInboxStorageSummary, usesContentByteTotals: Bool = false, damagedUploadIDs: [UUID] = [], damagedReceiptIDs: [UUID] = [], damagedTerminalIDs: [UUID] = []) {
        self.damagedReceiptIDs = damagedReceiptIDs; self.damagedTerminalIDs = damagedTerminalIDs
        self.page = page; self.storage = storage; self.usesContentByteTotals = usesContentByteTotals; self.damagedUploadIDs = damagedUploadIDs
    }
}
