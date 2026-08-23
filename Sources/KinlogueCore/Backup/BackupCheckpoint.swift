import Foundation

public enum BackupContractError: Error, Equatable, Sendable {
    case invalidMagic
    case unsupportedVersion
    case unsupportedSuite
    case unsupportedRole
    case invalidIdentifier
    case invalidField
    case invalidLength
    case duplicateEntry
    case nonCanonicalOrdering
    case arithmeticOverflow
    case resourceLimit
    case trailingBytes
}

public enum BackupFormatLimits {
    public static let maximumEntryCount = 20_000
    public static let maximumPlaintextByteCount: UInt64 = 2 * 1_024 * 1_024 * 1_024
    public static let maximumFramePlaintextByteCount = 256 * 1_024
    public static let maximumFrameCount = 30_000
    public static let maximumPathByteCount = 512
    public static let maximumCanonicalManifestByteCount = 16 * 1_024 * 1_024
    public static let maximumCandidateFileCount = 4_096
    public static let maximumHPKEEncapsulatedKeyByteCount = 128
    public static let maximumHPKESealedKeyByteCount = 512
    public static let maximumTranscriptFieldCount = 32
    public static let maximumTranscriptFieldByteCount = 1 * 1_024 * 1_024
    public static let maximumBackupDuration: TimeInterval = 15 * 60
    public static let maximumRestoreDuration: TimeInterval = 15 * 60
    public static let maximumPeakMemoryDeltaByteCount = 96 * 1_024 * 1_024
    public static let maximumOpenFileCount = 64
    public static let targetFormatAllowanceByteCount: UInt64 = 64 * 1_024 * 1_024
    public static let capacityHeadroomByteCount: UInt64 = 256 * 1_024 * 1_024
}

public struct BackupFormatVersion: Hashable, Sendable {
    public static let current = try! BackupFormatVersion(major: 1, minor: 0, minimumReaderMinor: 0)

    public let major: UInt16
    public let minor: UInt16
    public let minimumReaderMinor: UInt16

    public init(major: UInt16, minor: UInt16, minimumReaderMinor: UInt16) throws {
        guard major == 1, minor == 0, minimumReaderMinor == 0 else {
            throw BackupContractError.unsupportedVersion
        }
        self.major = major
        self.minor = minor
        self.minimumReaderMinor = minimumReaderMinor
    }
}

public enum BackupCryptoSuite: UInt16, CaseIterable, Hashable, Sendable {
    /// HKDF-SHA256 roots, Ed25519 signatures, RFC 9180 base mode
    /// X25519/HKDF-SHA256/ChaChaPoly DEK envelope, and AES-256-GCM frames.
    case v1 = 1
}

public struct BackupSetID: Hashable, Sendable {
    public let bytes: Data
    public init(bytes: Data) throws { self.bytes = try validateBackupOpaqueID(bytes) }
}

public struct BackupCheckpointID: Hashable, Sendable {
    public let bytes: Data
    public init(bytes: Data) throws { self.bytes = try validateBackupOpaqueID(bytes) }
}

public struct BackupDeviceID: Hashable, Sendable {
    public let bytes: Data
    public init(bytes: Data) throws { self.bytes = try validateBackupOpaqueID(bytes) }
}

public struct BackupAuthorizationID: Hashable, Sendable {
    public let bytes: Data
    public init(bytes: Data) throws { self.bytes = try validateBackupOpaqueID(bytes) }
}

public struct BackupWriterEpoch: Hashable, Sendable {
    public let bytes: Data
    public init(bytes: Data) throws { self.bytes = try validateBackupOpaqueID(bytes) }
}

private func validateBackupOpaqueID(_ bytes: Data) throws -> Data {
    guard bytes.count == 16, bytes.contains(where: { $0 != 0 }) else {
        throw BackupContractError.invalidIdentifier
    }
    return bytes
}

public struct BackupRevision: Hashable, Sendable {
    public let generation: UInt64
    public let commitID: UUID
    public let manifestDigest: Data

    public init(generation: UInt64, commitID: UUID, manifestDigest: Data) throws {
        guard generation > 0, manifestDigest.count == 32 else {
            throw BackupContractError.invalidField
        }
        self.generation = generation
        self.commitID = commitID
        self.manifestDigest = manifestDigest
    }
}

public struct BackupRevisionPair: Hashable, Sendable {
    public let vault: BackupRevision
    public let lanInbox: BackupRevision

    public init(vault: BackupRevision, lanInbox: BackupRevision) throws {
        self.vault = vault
        self.lanInbox = lanInbox
    }

    public init(vault: VaultRevision, lanInbox: LANInboxRevision) throws {
        try self.init(
            vault: .init(
                generation: vault.generation,
                commitID: vault.commitID,
                manifestDigest: vault.catalogDigest
            ),
            lanInbox: .init(
                generation: lanInbox.generation,
                commitID: lanInbox.commitID,
                manifestDigest: lanInbox.manifestDigest
            )
        )
    }
}

public struct BackupCheckpointPrologue: Hashable, Sendable {
    public static let magic = Data("KLGBKP01".utf8)

    public let formatVersion: BackupFormatVersion
    public let suite: BackupCryptoSuite
    public let setID: BackupSetID
    public let checkpointID: BackupCheckpointID
    public let deviceID: BackupDeviceID
    public let authorizationID: BackupAuthorizationID
    public let sequence: UInt64

    public init(
        formatVersion: BackupFormatVersion = .current,
        suite: BackupCryptoSuite = .v1,
        setID: BackupSetID,
        checkpointID: BackupCheckpointID,
        deviceID: BackupDeviceID,
        authorizationID: BackupAuthorizationID,
        sequence: UInt64
    ) throws {
        self.formatVersion = formatVersion
        self.suite = suite
        self.setID = setID
        self.checkpointID = checkpointID
        self.deviceID = deviceID
        self.authorizationID = authorizationID
        self.sequence = sequence
    }

    public var canonicalBytes: Data {
        var writer = BackupCanonicalWriter()
        writer.append(Self.magic)
        writer.append(formatVersion)
        writer.append(suite.rawValue)
        writer.append(setID.bytes)
        writer.append(checkpointID.bytes)
        writer.append(deviceID.bytes)
        writer.append(authorizationID.bytes)
        writer.append(sequence)
        return writer.data
    }

    public static func decodeCanonical(_ data: Data) throws -> Self {
        var reader = BackupCanonicalReader(data: data)
        try reader.requireMagic(magic)
        let version = try reader.readCurrentVersion()
        let suite = try reader.readCurrentSuite()
        let value = try Self(
            formatVersion: version,
            suite: suite,
            setID: .init(bytes: reader.readFixed(count: 16)),
            checkpointID: .init(bytes: reader.readFixed(count: 16)),
            deviceID: .init(bytes: reader.readFixed(count: 16)),
            authorizationID: .init(bytes: reader.readFixed(count: 16)),
            sequence: reader.readUInt64()
        )
        try reader.requireEnd()
        guard value.canonicalBytes == data else { throw BackupContractError.invalidField }
        return value
    }
}

struct BackupCanonicalWriter {
    private(set) var data = Data()

    mutating func append(_ value: Data) { data.append(value) }
    mutating func append(_ value: UInt8) { data.append(value) }
    mutating func append(_ value: UInt16) { appendInteger(value) }
    mutating func append(_ value: UInt32) { appendInteger(value) }
    mutating func append(_ value: UInt64) { appendInteger(value) }

    mutating func append(_ version: BackupFormatVersion) {
        append(version.major)
        append(version.minor)
        append(version.minimumReaderMinor)
    }

    mutating func appendLengthPrefixed(_ value: Data) {
        append(UInt64(value.count))
        append(value)
    }

    mutating func appendUUID(_ value: UUID) {
        var tuple = value.uuid
        withUnsafeBytes(of: &tuple) { data.append(contentsOf: $0) }
    }

    private mutating func appendInteger<T: FixedWidthInteger>(_ value: T) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }
}

struct BackupCanonicalReader {
    let data: Data
    private(set) var offset = 0

    mutating func requireMagic(_ magic: Data) throws {
        guard try readFixed(count: magic.count) == magic else {
            throw BackupContractError.invalidMagic
        }
    }

    mutating func readUInt8() throws -> UInt8 {
        try readFixed(count: 1)[0]
    }

    mutating func readUInt16() throws -> UInt16 { try readInteger(UInt16.self) }
    mutating func readUInt32() throws -> UInt32 { try readInteger(UInt32.self) }
    mutating func readUInt64() throws -> UInt64 { try readInteger(UInt64.self) }

    mutating func readCurrentVersion() throws -> BackupFormatVersion {
        try BackupFormatVersion(
            major: readUInt16(),
            minor: readUInt16(),
            minimumReaderMinor: readUInt16()
        )
    }

    mutating func readCurrentSuite() throws -> BackupCryptoSuite {
        guard let suite = BackupCryptoSuite(rawValue: try readUInt16()) else {
            throw BackupContractError.unsupportedSuite
        }
        return suite
    }

    mutating func readFixed(count: Int) throws -> Data {
        guard count >= 0, offset <= data.count, count <= data.count - offset else {
            throw BackupContractError.invalidLength
        }
        let range = offset..<(offset + count)
        offset += count
        return Data(data[range])
    }

    mutating func readLengthPrefixed(maximum: Int) throws -> Data {
        let encodedLength = try readUInt64()
        guard encodedLength <= UInt64(maximum), encodedLength <= UInt64(Int.max) else {
            throw BackupContractError.resourceLimit
        }
        return try readFixed(count: Int(encodedLength))
    }

    mutating func readUUID() throws -> UUID {
        let bytes = [UInt8](try readFixed(count: 16))
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    mutating func requireEnd() throws {
        guard offset == data.count else { throw BackupContractError.trailingBytes }
    }

    private mutating func readInteger<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        let bytes = try readFixed(count: MemoryLayout<T>.size)
        return bytes.reduce(T.zero) { partial, byte in
            (partial << 8) | T(byte)
        }
    }
}
