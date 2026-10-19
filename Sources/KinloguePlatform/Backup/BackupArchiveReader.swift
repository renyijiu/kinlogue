import CryptoKit
import Darwin
import Foundation
import KinlogueCore
import ZIPFoundation

/// Reads one backup archive the person picked. Everything in it is untrusted input.
///
/// Only `kinlogue-backup.json` and the entries it names are ever read; other entries (notes
/// the person added, `__MACOSX/`, `.DS_Store`) are ignored. Entries are found by exact name and
/// streamed to the caller, which decides where bytes go: no name from the archive becomes a
/// path on disk. Each entry is bounded by the size the index declares and checked against its
/// CRC-32 and SHA-256.
final class BackupArchiveReader {
    struct Identity: Equatable {
        let device: UInt64
        let inode: UInt64
        let byteCount: UInt64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
    }

    static let bufferSize = 64 * 1_024

    let index: BackupArchiveIndex
    private let descriptor: Int32
    private let identity: Identity
    private let archive: Archive
    /// Archive entries by their name relative to the folder holding the index.
    private let entries: [String: Entry]
    private var closed = false

    init(url: URL) throws {
        guard url.isFileURL else { throw BackupRestoreError.invalidSource }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw BackupRestoreError.invalidSource }
        do {
            let identity = try Self.identity(of: descriptor)
            guard identity.byteCount > 0 else { throw BackupRestoreError.notABackup }
            let archive: Archive
            do { archive = try Archive(url: url, accessMode: .read) } catch { throw BackupRestoreError.notABackup }

            var all: [String: Entry] = [:]
            var count = 0
            for entry in archive {
                try Task.checkCancellation()
                count += 1
                guard count <= BackupArchiveLimits.maximumEntryCount else { throw BackupArchiveError.resourceLimit }
                // A name that appears twice could mean either entry; refuse rather than guess.
                guard all.updateValue(entry, forKey: entry.path) == nil else { throw BackupArchiveError.invalidArchive }
            }
            // The index sits at the root, or under one top-level folder when the archive was
            // unpacked and compressed again (Finder's "Compress" adds that folder).
            let candidates = all.keys.filter { path in
                guard !path.hasPrefix("__MACOSX/") else { return false }
                let parts = path.split(separator: "/", omittingEmptySubsequences: false)
                return parts.last.map(String.init) == BackupArchiveIndex.fileName && parts.count <= 2
            }
            guard candidates.count == 1, let indexPath = candidates.first else {
                throw candidates.isEmpty ? BackupRestoreError.notABackup : BackupArchiveError.invalidArchive
            }
            let prefix = String(indexPath.dropLast(BackupArchiveIndex.fileName.count))
            guard prefix.isEmpty || BackupArchiveIndex.isSafePath(String(prefix.dropLast())) else {
                throw BackupArchiveError.invalidArchive
            }
            var relative: [String: Entry] = [:]
            for (path, entry) in all where path.hasPrefix(prefix) {
                relative[String(path.dropFirst(prefix.count))] = entry
            }

            guard let indexEntry = relative[BackupArchiveIndex.fileName], indexEntry.type == .file,
                  indexEntry.uncompressedSize <= UInt64(BackupArchiveLimits.maximumIndexByteCount) else {
                throw BackupArchiveError.invalidArchive
            }
            var indexBytes = Data()
            try Self.extract(indexEntry, from: archive, byteCount: indexEntry.uncompressedSize) { indexBytes.append($0) }
            let index = try BackupArchiveIndex.decode(indexBytes)
            for expected in [index.data] + index.originals.map(\.entry) {
                guard let entry = relative[expected.path], entry.type == .file,
                      entry.uncompressedSize == expected.byteCount else {
                    throw BackupArchiveError.invalidArchive
                }
            }
            self.descriptor = descriptor
            self.identity = identity
            self.archive = archive
            self.entries = relative
            self.index = index
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    deinit { close() }

    func close() {
        guard !closed else { return }
        closed = true
        Darwin.close(descriptor)
    }

    /// Streams one entry the index names, checking its size, CRC-32 and SHA-256.
    func extract(_ expected: BackupArchiveIndex.Entry, consumer: (Data) throws -> Void) throws {
        guard !closed, let entry = entries[expected.path] else { throw BackupArchiveError.invalidArchive }
        var hasher = SHA256()
        try Self.extract(entry, from: archive, byteCount: expected.byteCount) { data in
            hasher.update(data: data)
            try consumer(data)
        }
        guard Data(hasher.finalize()) == expected.sha256 else { throw BackupArchiveError.invalidArchive }
    }

    /// Fails when the file was replaced or rewritten while it was being read.
    func checkUnchanged() throws {
        guard !closed, try Self.identity(of: descriptor) == identity else { throw BackupRestoreError.sourceChanged }
    }

    private static func extract(_ entry: Entry, from archive: Archive, byteCount: UInt64, consumer: (Data) throws -> Void) throws {
        var count: UInt64 = 0
        let crc: CRC32
        do {
            crc = try archive.extract(entry, bufferSize: bufferSize, skipCRC32: false) { data in
                try Task.checkCancellation()
                let next = count.addingReportingOverflow(UInt64(data.count))
                // Stop as soon as an entry inflates past its declared size.
                guard !next.overflow, next.partialValue <= byteCount else { throw BackupArchiveError.invalidArchive }
                count = next.partialValue
                try consumer(data)
            }
        } catch let error as BackupArchiveError {
            throw error
        } catch let error as BackupRestoreError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SQLiteLogicalBackupError {
            throw error
        } catch let error as SQLiteLibraryError {
            throw error
        } catch {
            throw BackupArchiveError.invalidArchive
        }
        guard count == byteCount, crc == entry.checksum else { throw BackupArchiveError.invalidArchive }
    }

    private static func identity(of descriptor: Int32) throws -> Identity {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFREG, metadata.st_size >= 0 else {
            throw BackupRestoreError.invalidSource
        }
        return Identity(
            device: UInt64(metadata.st_dev),
            inode: UInt64(metadata.st_ino),
            byteCount: UInt64(metadata.st_size),
            modifiedSeconds: Int64(metadata.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(metadata.st_mtimespec.tv_nsec)
        )
    }
}
