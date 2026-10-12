import Foundation
import os

/// What inspection has already established in one open epoch, so that an interrupted or
/// repeated pass does not redo it.
///
/// Row checks stay bound to one revision: a saved position is used only while the library state
/// and SQLite's data version are the ones it was saved under, so a commit from this connection or
/// from any other one starts the rows again. Original bytes are immutable, and a verified file
/// stays verified while its row and its file identity, size and timestamps are unchanged. Damage
/// that leaves all of those intact is found by the next read of that original or after the
/// library is reopened.
final class SQLiteIntegrityProgress: Sendable {
    struct Position: Sendable {
        let state: SQLiteLibraryState
        let dataVersion: Int64
        var structureChecked = false
        var kindIndex = 0
        var after = Data()
        var checked = 0
        var damaged: [SQLiteIntegrityTarget] = []
        var completedAt: Date?
    }

    private struct VerifiedOriginal: Sendable {
        let rowHash: Data
        let snapshot: SQLiteOriginalSnapshot
    }

    private struct State: Sendable {
        var position: Position?
        var originals: [UUID: VerifiedOriginal] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func position(state library: SQLiteLibraryState, dataVersion: Int64) -> Position {
        state.withLock { state in
            if let position = state.position, position.state == library, position.dataVersion == dataVersion { return position }
            return Position(state: library, dataVersion: dataVersion)
        }
    }

    func save(_ position: Position) { state.withLock { $0.position = position } }

    func isVerified(_ original: SQLiteOriginal, snapshot: SQLiteOriginalSnapshot) -> Bool {
        let rowHash = original.contentHash
        return state.withLock { state in
            guard let verified = state.originals[original.id] else { return false }
            return verified.rowHash == rowHash && verified.snapshot == snapshot
        }
    }

    func noteVerified(_ original: SQLiteOriginal, snapshot: SQLiteOriginalSnapshot) {
        let verified = VerifiedOriginal(rowHash: original.contentHash, snapshot: snapshot)
        state.withLock { $0.originals[original.id] = verified }
    }

    func forget(_ id: UUID) { state.withLock { _ = $0.originals.removeValue(forKey: id) } }

    /// Drops originals that no longer exist, so the record cannot outgrow the library.
    func retainOriginals(_ present: Set<UUID>) {
        state.withLock { state in state.originals = state.originals.filter { present.contains($0.key) } }
    }

    func removeAll() { state.withLock { $0 = State() } }
}
