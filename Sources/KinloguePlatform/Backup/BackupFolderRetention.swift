import Darwin
import Foundation
import KinlogueCore

/// Applies the retention count to the backups this Mac wrote into the backup folder.
///
/// A ledger entry is only acted on while the file under its name is still the very file that
/// was written: same inode, size and modification time, a regular file with one link. Anything
/// else is the person's now and is dropped from the ledger without being touched.
public enum BackupFolderRetention {
    public struct Outcome: Equatable, Sendable {
        public let ledger: [BackupLedgerEntry]
        /// Some old backup could not be checked or deleted; it stays in the ledger.
        public let deferred: Bool
        public let deletedCount: Int
    }

    /// The caller holds access to `folder` for the duration of the call.
    public static func apply(
        folder: URL,
        ledger: [BackupLedgerEntry],
        count: BackupRetentionCount,
        newest: UInt64
    ) -> Outcome {
        let descriptor = Darwin.open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return Outcome(ledger: ledger, deferred: true, deletedCount: 0) }
        defer { Darwin.close(descriptor) }

        var observations: [UInt64: BackupLedgerObservation] = [:]
        for entry in ledger {
            switch observe(entry, in: descriptor) {
            case .some(let observation): observations[entry.sequence] = observation
            case .none: return Outcome(ledger: ledger, deferred: true, deletedCount: 0)
            }
        }
        let plan = BackupRetention.plan(entries: ledger, observations: observations, count: count, newest: newest)
        var remaining = plan.keep
        var deferred = false
        var deleted = 0
        for entry in plan.delete {
            switch observe(entry, in: descriptor) {
            case .intact?:
                if unlinkat(descriptor, entry.fileName, 0) == 0 {
                    deleted += 1
                } else if errno != ENOENT {
                    remaining.append(entry)
                    deferred = true
                }
            case .changed?:
                continue
            case nil:
                remaining.append(entry)
                deferred = true
            }
        }
        if deleted > 0 { _ = fsync(descriptor) }
        return Outcome(ledger: remaining.sorted { $0.sequence < $1.sequence }, deferred: deferred, deletedCount: deleted)
    }

    /// `nil` when the file could not be checked at all, which must not count as either answer.
    static func observe(_ entry: BackupLedgerEntry, in folder: Int32) -> BackupLedgerObservation? {
        guard BackupArchiveWriter.isSinglePathComponent(entry.fileName) else { return .changed }
        var metadata = stat()
        guard fstatat(folder, entry.fileName, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
            return errno == ENOENT || errno == ENOTDIR ? .changed : nil
        }
        let intact = (metadata.st_mode & S_IFMT) == S_IFREG
            && metadata.st_nlink == 1
            && UInt64(metadata.st_ino) == entry.inode
            && metadata.st_size >= 0 && UInt64(metadata.st_size) == entry.byteCount
            && Int64(metadata.st_mtimespec.tv_sec) == entry.modifiedSeconds
            && Int64(metadata.st_mtimespec.tv_nsec) == entry.modifiedNanoseconds
        return intact ? .intact : .changed
    }
}
