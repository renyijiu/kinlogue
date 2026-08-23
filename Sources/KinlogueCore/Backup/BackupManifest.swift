import Foundation

public struct BackupManifestEntry: Hashable, Sendable {
    public static let magic = Data("ENT1".utf8)

    public enum Kind: UInt8, CaseIterable, Hashable, Sendable {
        case vaultCatalog = 1
        case lanInboxManifest = 2
        case vaultObject = 3
        case lanInboxBlob = 4
        case lanInboxDerivedArtifact = 5
        case lanInboxReceipt = 6
    }

    public let kind: Kind
    public let path: String
    public let plaintextByteCount: UInt64
    public let plaintextDigest: Data
    public let firstFrameIndex: UInt64
    public let frameCount: UInt32

    public init(
        kind: Kind,
        path: String,
        plaintextByteCount: UInt64,
        plaintextDigest: Data,
        firstFrameIndex: UInt64,
        frameCount: UInt32
    ) throws {
        guard Self.isCanonicalInternalPath(path),
              plaintextByteCount <= BackupFormatLimits.maximumPlaintextByteCount,
              plaintextDigest.count == 32,
              frameCount > 0 else {
            throw BackupContractError.invalidField
        }
        let endFrame = firstFrameIndex.addingReportingOverflow(UInt64(frameCount))
        guard !endFrame.overflow,
              endFrame.partialValue <= UInt64(BackupFormatLimits.maximumFrameCount) else {
            throw BackupContractError.resourceLimit
        }
        self.kind = kind
        self.path = path
        self.plaintextByteCount = plaintextByteCount
        self.plaintextDigest = plaintextDigest
        self.firstFrameIndex = firstFrameIndex
        self.frameCount = frameCount
    }

    public var canonicalBytes: Data {
        var writer = BackupCanonicalWriter()
        writer.append(Self.magic)
        writer.append(kind.rawValue)
        writer.appendLengthPrefixed(Data(path.utf8))
        writer.append(plaintextByteCount)
        writer.append(plaintextDigest)
        writer.append(firstFrameIndex)
        writer.append(frameCount)
        return writer.data
    }

    static func decodeCanonical(_ data: Data) throws -> Self {
        var reader = BackupCanonicalReader(data: data)
        try reader.requireMagic(magic)
        guard let kind = Kind(rawValue: try reader.readUInt8()) else {
            throw BackupContractError.invalidField
        }
        let pathBytes = try reader.readLengthPrefixed(
            maximum: BackupFormatLimits.maximumPathByteCount
        )
        guard let path = String(data: pathBytes, encoding: .utf8) else {
            throw BackupContractError.invalidField
        }
        let value = try Self(
            kind: kind,
            path: path,
            plaintextByteCount: reader.readUInt64(),
            plaintextDigest: reader.readFixed(count: 32),
            firstFrameIndex: reader.readUInt64(),
            frameCount: reader.readUInt32()
        )
        try reader.requireEnd()
        guard value.canonicalBytes == data else { throw BackupContractError.invalidField }
        return value
    }

    private static func isCanonicalInternalPath(_ path: String) -> Bool {
        let normalized = path.precomposedStringWithCanonicalMapping
        guard path == normalized,
              !path.isEmpty,
              !path.hasPrefix("/"),
              !path.hasSuffix("/"),
              !path.contains("\\"),
              !path.contains("\0"),
              path.utf8.count <= BackupFormatLimits.maximumPathByteCount else {
            return false
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return false
        }
        return path.unicodeScalars.allSatisfy { scalar in
            let value = scalar.value
            return (48...57).contains(value)
                || (65...90).contains(value)
                || (97...122).contains(value)
                || value == 45 || value == 46 || value == 47 || value == 95
        }
    }
}

public struct BackupManifest: Hashable, Sendable {
    public static let magic = Data("KLGMNF01".utf8)

    public let formatVersion: BackupFormatVersion
    public let suite: BackupCryptoSuite
    public let revisionPair: BackupRevisionPair
    public let entryCount: Int
    public let totalPlaintextByteCount: UInt64
    public let totalFrameCount: UInt64
    public let entries: [BackupManifestEntry]

    public init(
        formatVersion: BackupFormatVersion = .current,
        suite: BackupCryptoSuite = .v1,
        revisionPair: BackupRevisionPair,
        entries: some Collection<BackupManifestEntry>
    ) throws {
        guard entries.count <= BackupFormatLimits.maximumEntryCount else {
            throw BackupContractError.resourceLimit
        }
        let ordered = entries.sorted { lhs, rhs in lhs.path < rhs.path }
        guard Set(ordered.map(\.path)).count == ordered.count else {
            throw BackupContractError.duplicateEntry
        }
        guard ordered.filter({ $0.kind == .vaultCatalog }).count == 1,
              ordered.filter({ $0.kind == .lanInboxManifest }).count == 1,
              ordered.contains(where: { $0.kind == .vaultCatalog && $0.path == "library.json" }),
              ordered.contains(where: { $0.kind == .lanInboxManifest && $0.path == "lan-inbox/inbox.json" }) else {
            throw BackupContractError.invalidField
        }

        var totalBytes: UInt64 = 0
        var nextFrame: UInt64 = 0
        for entry in ordered {
            let bytes = totalBytes.addingReportingOverflow(entry.plaintextByteCount)
            guard !bytes.overflow,
                  bytes.partialValue <= BackupFormatLimits.maximumPlaintextByteCount,
                  entry.firstFrameIndex == nextFrame else {
                throw BackupContractError.resourceLimit
            }
            totalBytes = bytes.partialValue
            let frames = nextFrame.addingReportingOverflow(UInt64(entry.frameCount))
            guard !frames.overflow,
                  frames.partialValue <= UInt64(BackupFormatLimits.maximumFrameCount) else {
                throw BackupContractError.resourceLimit
            }
            nextFrame = frames.partialValue
        }

        self.formatVersion = formatVersion
        self.suite = suite
        self.revisionPair = revisionPair
        entryCount = ordered.count
        totalPlaintextByteCount = totalBytes
        totalFrameCount = nextFrame
        self.entries = ordered

        guard canonicalBytes.count <= BackupFormatLimits.maximumCanonicalManifestByteCount else {
            throw BackupContractError.resourceLimit
        }
    }

    public var canonicalBytes: Data {
        var writer = BackupCanonicalWriter()
        writer.append(Self.magic)
        writer.append(formatVersion)
        writer.append(suite.rawValue)
        writer.append(revisionPair.vault.generation)
        writer.appendUUID(revisionPair.vault.commitID)
        writer.append(revisionPair.vault.manifestDigest)
        writer.append(revisionPair.lanInbox.generation)
        writer.appendUUID(revisionPair.lanInbox.commitID)
        writer.append(revisionPair.lanInbox.manifestDigest)
        writer.append(UInt32(entryCount))
        writer.append(totalPlaintextByteCount)
        writer.append(totalFrameCount)
        for entry in entries {
            writer.appendLengthPrefixed(entry.canonicalBytes)
        }
        return writer.data
    }

    public static func decodeCanonical(_ data: Data) throws -> Self {
        guard data.count <= BackupFormatLimits.maximumCanonicalManifestByteCount else {
            throw BackupContractError.resourceLimit
        }
        var reader = BackupCanonicalReader(data: data)
        try reader.requireMagic(magic)
        let version = try reader.readCurrentVersion()
        let suite = try reader.readCurrentSuite()
        let pair = try BackupRevisionPair(
            vault: .init(
                generation: reader.readUInt64(),
                commitID: reader.readUUID(),
                manifestDigest: reader.readFixed(count: 32)
            ),
            lanInbox: .init(
                generation: reader.readUInt64(),
                commitID: reader.readUUID(),
                manifestDigest: reader.readFixed(count: 32)
            )
        )
        let encodedEntryCount = Int(try reader.readUInt32())
        guard encodedEntryCount <= BackupFormatLimits.maximumEntryCount else {
            throw BackupContractError.resourceLimit
        }
        let encodedPlaintextByteCount = try reader.readUInt64()
        let encodedFrameCount = try reader.readUInt64()
        guard encodedPlaintextByteCount <= BackupFormatLimits.maximumPlaintextByteCount,
              encodedFrameCount <= UInt64(BackupFormatLimits.maximumFrameCount) else {
            throw BackupContractError.resourceLimit
        }

        var entries: [BackupManifestEntry] = []
        entries.reserveCapacity(encodedEntryCount)
        let maximumEntryByteCount = BackupFormatLimits.maximumPathByteCount + 128
        for _ in 0..<encodedEntryCount {
            entries.append(try BackupManifestEntry.decodeCanonical(
                reader.readLengthPrefixed(maximum: maximumEntryByteCount)
            ))
        }
        try reader.requireEnd()
        let value = try Self(
            formatVersion: version,
            suite: suite,
            revisionPair: pair,
            entries: entries
        )
        guard value.entryCount == encodedEntryCount,
              value.totalPlaintextByteCount == encodedPlaintextByteCount,
              value.totalFrameCount == encodedFrameCount,
              value.canonicalBytes == data else {
            throw BackupContractError.nonCanonicalOrdering
        }
        return value
    }
}
