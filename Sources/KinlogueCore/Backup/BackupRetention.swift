import Foundation

public struct BackupRetentionCount: Hashable, Sendable {
    public static let allowedRange = 1...30
    public static let `default` = try! BackupRetentionCount(5)

    public let value: Int

    public init(_ value: Int) throws {
        guard Self.allowedRange.contains(value) else { throw BackupArchiveError.invalidArchive }
        self.value = value
    }
}

/// One backup this Mac wrote into the backup folder, as it was when written.
///
/// The folder belongs to the person: they can rename, move, copy or delete what is in it.
/// Retention only ever deletes a file that is still exactly the one recorded here.
public struct BackupLedgerEntry: Codable, Hashable, Sendable {
    /// Grows by one for every backup written; ordering never depends on the clock.
    public let sequence: UInt64
    public let fileName: String
    public let inode: UInt64
    public let byteCount: UInt64
    public let modifiedSeconds: Int64
    public let modifiedNanoseconds: Int64
    public let backupID: UUID
    public let createdAt: Date
    public let library: BackupLibraryRevision

    public init(
        sequence: UInt64,
        fileName: String,
        inode: UInt64,
        byteCount: UInt64,
        modifiedSeconds: Int64,
        modifiedNanoseconds: Int64,
        backupID: UUID,
        createdAt: Date,
        library: BackupLibraryRevision
    ) {
        self.sequence = sequence
        self.fileName = fileName
        self.inode = inode
        self.byteCount = byteCount
        self.modifiedSeconds = modifiedSeconds
        self.modifiedNanoseconds = modifiedNanoseconds
        self.backupID = backupID
        self.createdAt = createdAt
        self.library = library
    }
}

public enum BackupLedgerObservation: Hashable, Sendable {
    /// Same name, same inode, size and modification time as recorded.
    case intact
    /// Missing, renamed, replaced or rewritten: no longer this Mac's to delete.
    case changed
}

public enum BackupRetention {
    public struct Plan: Hashable, Sendable {
        public let keep: [BackupLedgerEntry]
        public let delete: [BackupLedgerEntry]
        /// Entries to drop from the ledger without touching any file.
        public let forget: [BackupLedgerEntry]
    }

    /// Keeps the newest `count` intact backups and deletes the older intact ones. Nothing is
    /// deleted unless `newest`, the backup just written, is itself intact.
    public static func plan(
        entries: [BackupLedgerEntry],
        observations: [UInt64: BackupLedgerObservation],
        count: BackupRetentionCount,
        newest: UInt64
    ) -> Plan {
        let ordered = entries.sorted { $0.sequence > $1.sequence }
        let intact = ordered.filter { observations[$0.sequence] == .intact }
        let forget = ordered.filter { observations[$0.sequence] != .intact }
        guard intact.contains(where: { $0.sequence == newest }) else {
            return Plan(keep: intact, delete: [], forget: forget)
        }
        return Plan(
            keep: Array(intact.prefix(count.value)),
            delete: Array(intact.dropFirst(count.value)),
            forget: forget
        )
    }
}
