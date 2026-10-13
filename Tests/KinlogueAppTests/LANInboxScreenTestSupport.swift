import Foundation
import KinlogueCore
@testable import KinlogueApp
@testable import KinloguePlatform

// Service doubles keep a whole inbox snapshot in memory. These page it the way the library
// pages its rows: in sequence order, one hundred at a time, bound to a revision and an open epoch.

extension LANInboxQueueScreen {
    init(snapshot: LANInboxSnapshot, storage: LANInboxStorageSummary, openEpoch: UUID) {
        let revision = LibraryRevision(libraryID: snapshot.vaultID, openEpoch: openEpoch,
            generation: snapshot.generation, commitID: snapshot.commitID)
        let items = Array(snapshot.items.prefix(100))
        let cursor = snapshot.items.count > 100 ? items.last.map {
            LANInboxPageCursor(revision: revision, sequence: $0.sequence, id: $0.id, processing: false)
        } : nil
        self.init(page: LANInboxPage(revision: revision, items: items, nextCursor: cursor), storage: storage)
    }
}

func stubInboxPage(
    _ snapshot: LANInboxSnapshot,
    cursor: LANInboxPageCursor?,
    processing: Bool,
    openEpoch: UUID
) throws -> LANInboxPage {
    let revision = LibraryRevision(libraryID: snapshot.vaultID, openEpoch: openEpoch,
        generation: snapshot.generation, commitID: snapshot.commitID)
    if let cursor {
        guard cursor.processing == processing, cursor.revision.libraryID == revision.libraryID,
              cursor.revision.openEpoch == revision.openEpoch,
              processing || cursor.revision == revision else { throw LibraryReportError.staleCursor }
    }
    let remaining = snapshot.items.sorted { ($0.sequence, $0.id.uuidString) < ($1.sequence, $1.id.uuidString) }.filter {
        guard let cursor else { return true }
        return ($0.sequence, $0.id.uuidString) > (cursor.sequence, cursor.id.uuidString)
    }
    let items = Array(remaining.prefix(100))
    let next = remaining.count > 100 ? items.last.map {
        LANInboxPageCursor(revision: revision, sequence: $0.sequence, id: $0.id, processing: processing)
    } : nil
    return LANInboxPage(revision: revision, items: items, nextCursor: next)
}
