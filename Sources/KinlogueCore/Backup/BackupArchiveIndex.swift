import Foundation

public enum BackupArchiveError: Error, Equatable, Sendable {
    /// The archive was written by a newer Kinlogue, uses another format, or is encrypted.
    case unsupportedFormat
    /// The index or an entry does not match the archive, or breaks a format rule.
    case invalidArchive
    case resourceLimit
}

public enum BackupArchiveLimits {
    public static let maximumOriginalCount = 25_000
    public static let maximumIndexByteCount = 16 * 1_024 * 1_024
    /// Covers the index, the read-me and the data stream beside the originals.
    public static let maximumEntryCount = maximumOriginalCount + 64
    public static let maximumPathByteCount = 1_024
    public static let maximumContentTypeByteCount = 256
    public static let maximumCreatorFieldByteCount = 128
    /// The logical stream and every original together; matches the logical-v1 budget.
    public static let maximumPlaintextByteCount: UInt64 = 4 * 1_024 * 1_024 * 1_024 * 1_024
    /// Free space kept on top of the computed need, both for writing and for restoring.
    public static let capacityHeadroomByteCount: UInt64 = 256 * 1_024 * 1_024
}

/// The library commit a backup holds, as the logical stream's header records it.
public struct BackupLibraryRevision: Codable, Hashable, Sendable {
    public let libraryID: UUID
    public let generation: Int64
    public let commitID: UUID

    public init(libraryID: UUID, generation: Int64, commitID: UUID) throws {
        guard generation >= 0 else { throw BackupArchiveError.invalidArchive }
        self.libraryID = libraryID
        self.generation = generation
        self.commitID = commitID
    }
}

/// `kinlogue-backup.json`: what a backup archive holds and where each original sits in it.
///
/// The index is the only entry a restore trusts for locating content. Every path it names is
/// looked up in the archive by exact name; no path from the archive becomes a path on disk.
public struct BackupArchiveIndex: Equatable, Sendable {
    public static let fileName = "kinlogue-backup.json"
    public static let formatName = "kinlogue-backup"
    public static let currentFormatVersion = 1
    public static let readerVersion = 1
    public static let dataPath = "data/library.klog"
    public static let dataEncoding = "logical-v1"
    public static let originalsDirectory = "files"

    public struct Creator: Equatable, Sendable {
        public let app: String
        public let version: String
        public let build: String

        public init(app: String, version: String, build: String) throws {
            for value in [app, version, build] {
                guard value.utf8.count <= BackupArchiveLimits.maximumCreatorFieldByteCount,
                      !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                    throw BackupArchiveError.invalidArchive
                }
            }
            self.app = app
            self.version = version
            self.build = build
        }
    }

    public struct Counts: Equatable, Sendable {
        public let members: Int
        public let records: Int
        public let drafts: Int
        public let inboxItems: Int
        public let dicomStudies: Int
        public let originals: Int

        public init(members: Int, records: Int, drafts: Int, inboxItems: Int, dicomStudies: Int, originals: Int) throws {
            guard [members, records, drafts, inboxItems, dicomStudies, originals].allSatisfy({ $0 >= 0 }),
                  originals <= BackupArchiveLimits.maximumOriginalCount else {
                throw BackupArchiveError.invalidArchive
            }
            self.members = members
            self.records = records
            self.drafts = drafts
            self.inboxItems = inboxItems
            self.dicomStudies = dicomStudies
            self.originals = originals
        }
    }

    public struct Entry: Equatable, Sendable {
        public let path: String
        public let byteCount: UInt64
        public let sha256: Data

        public init(path: String, byteCount: UInt64, sha256: Data) throws {
            guard BackupArchiveIndex.isSafePath(path), sha256.count == 32 else {
                throw BackupArchiveError.invalidArchive
            }
            self.path = path
            self.byteCount = byteCount
            self.sha256 = sha256
        }
    }

    public struct Original: Equatable, Sendable {
        public let id: UUID
        public let entry: Entry
        public let contentType: String

        public init(id: UUID, entry: Entry, contentType: String) throws {
            guard entry.path.hasPrefix(BackupArchiveIndex.originalsDirectory + "/"),
                  !contentType.isEmpty,
                  contentType.utf8.count <= BackupArchiveLimits.maximumContentTypeByteCount,
                  entry.byteCount <= UInt64(Int.max) else {
                throw BackupArchiveError.invalidArchive
            }
            self.id = id
            self.entry = entry
            self.contentType = contentType
        }
    }

    public let formatVersion: Int
    public let minimumReaderVersion: Int
    public let backupID: UUID
    public let createdAt: Date
    public let creator: Creator
    public let library: BackupLibraryRevision
    public let counts: Counts
    public let data: Entry
    public let originals: [Original]

    public init(
        backupID: UUID,
        createdAt: Date,
        creator: Creator,
        library: BackupLibraryRevision,
        counts: Counts,
        data: Entry,
        originals: [Original]
    ) throws {
        try self.init(
            formatVersion: Self.currentFormatVersion,
            minimumReaderVersion: Self.currentFormatVersion,
            backupID: backupID,
            createdAt: createdAt,
            creator: creator,
            library: library,
            counts: counts,
            data: data,
            originals: originals
        )
    }

    init(
        formatVersion: Int,
        minimumReaderVersion: Int,
        backupID: UUID,
        createdAt: Date,
        creator: Creator,
        library: BackupLibraryRevision,
        counts: Counts,
        data: Entry,
        originals: [Original]
    ) throws {
        guard minimumReaderVersion >= 1, formatVersion >= minimumReaderVersion else {
            throw BackupArchiveError.invalidArchive
        }
        guard minimumReaderVersion <= Self.readerVersion else {
            throw BackupArchiveError.unsupportedFormat
        }
        guard createdAt.timeIntervalSinceReferenceDate.isFinite,
              data.path == Self.dataPath,
              counts.originals == originals.count else {
            throw BackupArchiveError.invalidArchive
        }
        guard originals.count <= BackupArchiveLimits.maximumOriginalCount else {
            throw BackupArchiveError.resourceLimit
        }
        var ids: Set<UUID> = []
        var paths: Set<String> = [Self.fileName, data.path]
        var total = data.byteCount
        for original in originals {
            guard ids.insert(original.id).inserted, paths.insert(original.entry.path).inserted else {
                throw BackupArchiveError.invalidArchive
            }
            let next = total.addingReportingOverflow(original.entry.byteCount)
            guard !next.overflow, next.partialValue <= BackupArchiveLimits.maximumPlaintextByteCount else {
                throw BackupArchiveError.resourceLimit
            }
            total = next.partialValue
        }
        self.formatVersion = formatVersion
        self.minimumReaderVersion = minimumReaderVersion
        self.backupID = backupID
        // Whole seconds: exactly what the JSON carries, so a written index equals the one read back.
        self.createdAt = Date(timeIntervalSince1970: createdAt.timeIntervalSince1970.rounded(.down))
        self.creator = creator
        self.library = library
        self.counts = counts
        self.data = data
        self.originals = originals
    }

    /// The logical stream plus every original, before ZIP framing.
    public var totalByteCount: UInt64 {
        originals.reduce(data.byteCount) { $0 + $1.entry.byteCount }
    }

    /// A relative path of non-empty components that cannot leave the archive root or name a
    /// device. It is only ever compared with entry names, never joined onto a directory.
    public static func isSafePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              path.utf8.count <= BackupArchiveLimits.maximumPathByteCount,
              !path.hasPrefix("/"),
              !path.contains("\\"),
              !path.unicodeScalars.contains(where: { $0.value == 0 || CharacterSet.controlCharacters.contains($0) }) else {
            return false
        }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { component in
            !component.isEmpty && component != "." && component != ".."
        }
    }
}

// MARK: - JSON

extension BackupArchiveIndex {
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(Wire(self))
        guard data.count <= BackupArchiveLimits.maximumIndexByteCount else {
            throw BackupArchiveError.resourceLimit
        }
        return data
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= BackupArchiveLimits.maximumIndexByteCount else {
            throw BackupArchiveError.resourceLimit
        }
        let wire: Wire
        do {
            wire = try JSONDecoder().decode(Wire.self, from: data)
        } catch {
            // A JSON document that is not ours at all says nothing about the version.
            throw BackupArchiveError.invalidArchive
        }
        return try wire.index()
    }

    /// Field names are part of the format; unknown fields from a newer writer are ignored.
    private struct Wire: Codable {
        struct Creator: Codable { let app: String; let version: String; let build: String }
        struct Library: Codable { let libraryID: String; let generation: Int64; let commitID: String }
        struct Counts: Codable {
            let members: Int; let records: Int; let drafts: Int
            let inboxItems: Int; let dicomStudies: Int; let originals: Int
        }
        struct DataEntry: Codable { let path: String; let encoding: String; let byteCount: UInt64; let sha256: String }
        struct Original: Codable {
            let id: String; let path: String; let byteCount: UInt64; let sha256: String; let contentType: String
        }

        let format: String
        let formatVersion: Int
        let minimumReaderVersion: Int
        let encryption: String
        let backupID: String
        let createdAt: String
        let creator: Creator
        let library: Library
        let counts: Counts
        let data: DataEntry
        let originals: [Original]

        init(_ index: BackupArchiveIndex) {
            format = BackupArchiveIndex.formatName
            formatVersion = index.formatVersion
            minimumReaderVersion = index.minimumReaderVersion
            encryption = "none"
            backupID = index.backupID.uuidString.lowercased()
            createdAt = index.createdAt.formatted(Self.dateStyle)
            creator = .init(app: index.creator.app, version: index.creator.version, build: index.creator.build)
            library = .init(
                libraryID: index.library.libraryID.uuidString.lowercased(),
                generation: index.library.generation,
                commitID: index.library.commitID.uuidString.lowercased()
            )
            counts = .init(
                members: index.counts.members, records: index.counts.records, drafts: index.counts.drafts,
                inboxItems: index.counts.inboxItems, dicomStudies: index.counts.dicomStudies,
                originals: index.counts.originals
            )
            data = .init(
                path: index.data.path,
                encoding: BackupArchiveIndex.dataEncoding,
                byteCount: index.data.byteCount,
                sha256: Self.hex(index.data.sha256)
            )
            originals = index.originals.map {
                .init(
                    id: $0.id.uuidString.lowercased(),
                    path: $0.entry.path,
                    byteCount: $0.entry.byteCount,
                    sha256: Self.hex($0.entry.sha256),
                    contentType: $0.contentType
                )
            }
        }

        func index() throws -> BackupArchiveIndex {
            guard format == BackupArchiveIndex.formatName else { throw BackupArchiveError.invalidArchive }
            guard minimumReaderVersion <= BackupArchiveIndex.readerVersion else {
                throw BackupArchiveError.unsupportedFormat
            }
            // An encrypted layer, if one is ever added, is unreadable here by design.
            guard encryption == "none", data.encoding == BackupArchiveIndex.dataEncoding else {
                throw BackupArchiveError.unsupportedFormat
            }
            guard originals.count <= BackupArchiveLimits.maximumOriginalCount else {
                throw BackupArchiveError.resourceLimit
            }
            guard let createdAt = try? Self.dateStyle.parse(createdAt) else {
                throw BackupArchiveError.invalidArchive
            }
            return try BackupArchiveIndex(
                formatVersion: formatVersion,
                minimumReaderVersion: minimumReaderVersion,
                backupID: Self.uuid(backupID),
                createdAt: createdAt,
                creator: .init(app: creator.app, version: creator.version, build: creator.build),
                library: .init(
                    libraryID: Self.uuid(library.libraryID),
                    generation: library.generation,
                    commitID: Self.uuid(library.commitID)
                ),
                counts: .init(
                    members: counts.members, records: counts.records, drafts: counts.drafts,
                    inboxItems: counts.inboxItems, dicomStudies: counts.dicomStudies, originals: counts.originals
                ),
                data: .init(path: data.path, byteCount: data.byteCount, sha256: Self.digest(data.sha256)),
                originals: originals.map {
                    try .init(
                        id: Self.uuid($0.id),
                        entry: .init(path: $0.path, byteCount: $0.byteCount, sha256: Self.digest($0.sha256)),
                        contentType: $0.contentType
                    )
                }
            )
        }

        static let dateStyle = Date.ISO8601FormatStyle()

        static func hex(_ data: Data) -> String {
            data.map { String(format: "%02x", $0) }.joined()
        }

        static func digest(_ text: String) throws -> Data {
            let bytes = Array(text.utf8)
            guard bytes.count == 64 else { throw BackupArchiveError.invalidArchive }
            var result = Data(capacity: 32)
            var index = 0
            while index < bytes.count {
                guard let high = nibble(bytes[index]), let low = nibble(bytes[index + 1]) else {
                    throw BackupArchiveError.invalidArchive
                }
                result.append(high << 4 | low)
                index += 2
            }
            return result
        }

        static func nibble(_ byte: UInt8) -> UInt8? {
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
            default: nil
            }
        }

        static func uuid(_ text: String) throws -> UUID {
            guard text.utf8.count == 36, let value = UUID(uuidString: text) else {
                throw BackupArchiveError.invalidArchive
            }
            return value
        }
    }
}
