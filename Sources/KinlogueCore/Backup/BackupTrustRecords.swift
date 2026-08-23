import Foundation

public enum BackupTranscriptRole: UInt16, CaseIterable, Hashable, Sendable {
    case recoverySigningRootDerivation = 1
    case recoveryHPKERootDerivation = 2
    case backupSetDescriptorSignature = 3
    case deviceAuthorizationSignature = 4
    case hpkeInfo = 5
    case hpkeAdditionalAuthenticatedData = 6
    case manifestAdditionalAuthenticatedData = 7
    case frameAdditionalAuthenticatedData = 8
    case ciphertextCommitment = 9
    case checkpointCommitSignature = 10
}

public struct BackupCanonicalTranscript: Hashable, Sendable {
    public static let magic = Data("KLGTRN01".utf8)
    public static let productIdentifier = "com.kinlogue.backup"
    public static let protocolIdentifier = "encrypted-folder-checkpoint"

    public let formatVersion: BackupFormatVersion
    public let role: BackupTranscriptRole
    public let fields: [Data]

    public init(
        formatVersion: BackupFormatVersion = .current,
        role: BackupTranscriptRole,
        fields: [Data]
    ) throws {
        guard fields.count <= BackupFormatLimits.maximumTranscriptFieldCount,
              fields.allSatisfy({ $0.count <= BackupFormatLimits.maximumTranscriptFieldByteCount }) else {
            throw BackupContractError.resourceLimit
        }
        self.formatVersion = formatVersion
        self.role = role
        self.fields = fields
    }

    public var canonicalBytes: Data {
        var writer = BackupCanonicalWriter()
        writer.append(Self.magic)
        writer.appendLengthPrefixed(Data(Self.productIdentifier.utf8))
        writer.appendLengthPrefixed(Data(Self.protocolIdentifier.utf8))
        writer.append(formatVersion)
        writer.append(role.rawValue)
        writer.append(UInt16(fields.count))
        for field in fields {
            writer.appendLengthPrefixed(field)
        }
        return writer.data
    }

    public static func decodeCanonical(_ data: Data) throws -> Self {
        let maximum = (
            BackupFormatLimits.maximumTranscriptFieldByteCount
                * BackupFormatLimits.maximumTranscriptFieldCount
        ) + 1_024
        guard data.count <= maximum else { throw BackupContractError.resourceLimit }

        var reader = BackupCanonicalReader(data: data)
        try reader.requireMagic(magic)
        guard try reader.readLengthPrefixed(maximum: 64) == Data(productIdentifier.utf8),
              try reader.readLengthPrefixed(maximum: 64) == Data(protocolIdentifier.utf8) else {
            throw BackupContractError.invalidMagic
        }
        let version = try reader.readCurrentVersion()
        guard let role = BackupTranscriptRole(rawValue: try reader.readUInt16()) else {
            throw BackupContractError.unsupportedRole
        }
        let count = Int(try reader.readUInt16())
        guard count <= BackupFormatLimits.maximumTranscriptFieldCount else {
            throw BackupContractError.resourceLimit
        }
        var fields: [Data] = []
        fields.reserveCapacity(count)
        for _ in 0..<count {
            fields.append(try reader.readLengthPrefixed(
                maximum: BackupFormatLimits.maximumTranscriptFieldByteCount
            ))
        }
        try reader.requireEnd()
        let value = try Self(formatVersion: version, role: role, fields: fields)
        guard value.canonicalBytes == data else { throw BackupContractError.invalidField }
        return value
    }
}

public struct BackupSetDescriptor: Hashable, Sendable {
    public static let magic = Data("KLGSET01".utf8)

    public let formatVersion: BackupFormatVersion
    public let suite: BackupCryptoSuite
    public let setID: BackupSetID
    public let recoverySigningPublicKey: Data
    public let recoveryHPKEPublicKey: Data
    public let rootSignature: Data

    public init(
        formatVersion: BackupFormatVersion = .current,
        suite: BackupCryptoSuite = .v1,
        setID: BackupSetID,
        recoverySigningPublicKey: Data,
        recoveryHPKEPublicKey: Data,
        rootSignature: Data
    ) throws {
        guard recoverySigningPublicKey.count == 32,
              recoveryHPKEPublicKey.count == 32,
              rootSignature.count == 64 else {
            throw BackupContractError.invalidLength
        }
        self.formatVersion = formatVersion
        self.suite = suite
        self.setID = setID
        self.recoverySigningPublicKey = recoverySigningPublicKey
        self.recoveryHPKEPublicKey = recoveryHPKEPublicKey
        self.rootSignature = rootSignature
    }

    private var signaturePreimage: Data {
        var writer = BackupCanonicalWriter()
        writer.append(Self.magic)
        writer.append(formatVersion)
        writer.append(suite.rawValue)
        writer.append(setID.bytes)
        writer.append(recoverySigningPublicKey)
        writer.append(recoveryHPKEPublicKey)
        return writer.data
    }

    public var signatureTranscript: BackupCanonicalTranscript {
        try! .init(role: .backupSetDescriptorSignature, fields: [signaturePreimage])
    }

    public var canonicalBytes: Data {
        var result = signaturePreimage
        result.append(rootSignature)
        return result
    }

    public static func decodeCanonical(_ data: Data) throws -> Self {
        var reader = BackupCanonicalReader(data: data)
        try reader.requireMagic(magic)
        let value = try Self(
            formatVersion: reader.readCurrentVersion(),
            suite: reader.readCurrentSuite(),
            setID: .init(bytes: reader.readFixed(count: 16)),
            recoverySigningPublicKey: reader.readFixed(count: 32),
            recoveryHPKEPublicKey: reader.readFixed(count: 32),
            rootSignature: reader.readFixed(count: 64)
        )
        try reader.requireEnd()
        guard value.canonicalBytes == data else { throw BackupContractError.invalidField }
        return value
    }
}

public struct BackupDeviceAuthorization: Hashable, Sendable {
    public static let magic = Data("KLGAUT01".utf8)

    public let formatVersion: BackupFormatVersion
    public let suite: BackupCryptoSuite
    public let descriptorDigest: Data
    public let setID: BackupSetID
    public let authorizationID: BackupAuthorizationID
    public let deviceID: BackupDeviceID
    public let deviceSigningPublicKey: Data
    public let sequenceFloor: UInt64
    public let rootSignature: Data

    public init(
        formatVersion: BackupFormatVersion = .current,
        suite: BackupCryptoSuite = .v1,
        descriptorDigest: Data,
        setID: BackupSetID,
        authorizationID: BackupAuthorizationID,
        deviceID: BackupDeviceID,
        deviceSigningPublicKey: Data,
        sequenceFloor: UInt64,
        rootSignature: Data
    ) throws {
        guard descriptorDigest.count == 32,
              deviceSigningPublicKey.count == 32,
              rootSignature.count == 64 else {
            throw BackupContractError.invalidLength
        }
        self.formatVersion = formatVersion
        self.suite = suite
        self.descriptorDigest = descriptorDigest
        self.setID = setID
        self.authorizationID = authorizationID
        self.deviceID = deviceID
        self.deviceSigningPublicKey = deviceSigningPublicKey
        self.sequenceFloor = sequenceFloor
        self.rootSignature = rootSignature
    }

    private var signaturePreimage: Data {
        var writer = BackupCanonicalWriter()
        writer.append(Self.magic)
        writer.append(formatVersion)
        writer.append(suite.rawValue)
        writer.append(descriptorDigest)
        writer.append(setID.bytes)
        writer.append(authorizationID.bytes)
        writer.append(deviceID.bytes)
        writer.append(deviceSigningPublicKey)
        writer.append(sequenceFloor)
        return writer.data
    }

    public var signatureTranscript: BackupCanonicalTranscript {
        try! .init(role: .deviceAuthorizationSignature, fields: [signaturePreimage])
    }

    public var canonicalBytes: Data {
        var result = signaturePreimage
        result.append(rootSignature)
        return result
    }

    public static func decodeCanonical(_ data: Data) throws -> Self {
        var reader = BackupCanonicalReader(data: data)
        try reader.requireMagic(magic)
        let value = try Self(
            formatVersion: reader.readCurrentVersion(),
            suite: reader.readCurrentSuite(),
            descriptorDigest: reader.readFixed(count: 32),
            setID: .init(bytes: reader.readFixed(count: 16)),
            authorizationID: .init(bytes: reader.readFixed(count: 16)),
            deviceID: .init(bytes: reader.readFixed(count: 16)),
            deviceSigningPublicKey: reader.readFixed(count: 32),
            sequenceFloor: reader.readUInt64(),
            rootSignature: reader.readFixed(count: 64)
        )
        try reader.requireEnd()
        guard value.canonicalBytes == data else { throw BackupContractError.invalidField }
        return value
    }
}

public struct BackupHPKEEnvelope: Hashable, Sendable {
    public static let magic = Data("KLGENV01".utf8)

    public let formatVersion: BackupFormatVersion
    public let suite: BackupCryptoSuite
    public let encapsulatedKey: Data
    public let sealedKey: Data

    public init(
        formatVersion: BackupFormatVersion = .current,
        suite: BackupCryptoSuite = .v1,
        encapsulatedKey: Data,
        sealedKey: Data
    ) throws {
        guard !encapsulatedKey.isEmpty,
              encapsulatedKey.count <= BackupFormatLimits.maximumHPKEEncapsulatedKeyByteCount,
              !sealedKey.isEmpty,
              sealedKey.count <= BackupFormatLimits.maximumHPKESealedKeyByteCount else {
            throw BackupContractError.resourceLimit
        }
        self.formatVersion = formatVersion
        self.suite = suite
        self.encapsulatedKey = encapsulatedKey
        self.sealedKey = sealedKey
    }

    public var canonicalBytes: Data {
        var writer = BackupCanonicalWriter()
        writer.append(Self.magic)
        writer.append(formatVersion)
        writer.append(suite.rawValue)
        writer.appendLengthPrefixed(encapsulatedKey)
        writer.appendLengthPrefixed(sealedKey)
        return writer.data
    }

    public static func decodeCanonical(_ data: Data) throws -> Self {
        var reader = BackupCanonicalReader(data: data)
        try reader.requireMagic(magic)
        let value = try Self(
            formatVersion: reader.readCurrentVersion(),
            suite: reader.readCurrentSuite(),
            encapsulatedKey: reader.readLengthPrefixed(
                maximum: BackupFormatLimits.maximumHPKEEncapsulatedKeyByteCount
            ),
            sealedKey: reader.readLengthPrefixed(
                maximum: BackupFormatLimits.maximumHPKESealedKeyByteCount
            )
        )
        try reader.requireEnd()
        guard value.canonicalBytes == data else { throw BackupContractError.invalidField }
        return value
    }
}

public enum BackupCommitmentAlgorithm: UInt16, CaseIterable, Hashable, Sendable {
    case sha256 = 1
}

public struct BackupCiphertextCommitment: Hashable, Sendable {
    public static let magic = Data("KLGCOM01".utf8)

    public let algorithm: BackupCommitmentAlgorithm
    public let digest: Data
    public let ciphertextByteCount: UInt64

    public init(
        algorithm: BackupCommitmentAlgorithm = .sha256,
        digest: Data,
        ciphertextByteCount: UInt64
    ) throws {
        let maximum = BackupFormatLimits.maximumPlaintextByteCount.addingReportingOverflow(
            BackupFormatLimits.targetFormatAllowanceByteCount
        )
        guard !maximum.overflow,
              digest.count == 32,
              ciphertextByteCount > 0,
              ciphertextByteCount <= maximum.partialValue else {
            throw BackupContractError.invalidField
        }
        self.algorithm = algorithm
        self.digest = digest
        self.ciphertextByteCount = ciphertextByteCount
    }

    public var canonicalBytes: Data {
        var writer = BackupCanonicalWriter()
        writer.append(Self.magic)
        writer.append(algorithm.rawValue)
        writer.append(digest)
        writer.append(ciphertextByteCount)
        return writer.data
    }

    public static func decodeCanonical(_ data: Data) throws -> Self {
        var reader = BackupCanonicalReader(data: data)
        try reader.requireMagic(magic)
        guard let algorithm = BackupCommitmentAlgorithm(rawValue: try reader.readUInt16()) else {
            throw BackupContractError.invalidField
        }
        let value = try Self(
            algorithm: algorithm,
            digest: reader.readFixed(count: 32),
            ciphertextByteCount: reader.readUInt64()
        )
        try reader.requireEnd()
        guard value.canonicalBytes == data else { throw BackupContractError.invalidField }
        return value
    }
}

public enum BackupCommitState: UInt8, CaseIterable, Hashable, Sendable {
    case complete = 1
}

public struct BackupCheckpointFooter: Hashable, Sendable {
    public static let magic = Data("KLGFTR01".utf8)

    public let formatVersion: BackupFormatVersion
    public let suite: BackupCryptoSuite
    public let descriptorDigest: Data
    public let authorizationDigest: Data
    public let prologueDigest: Data
    public let envelopeDigest: Data
    public let commitment: BackupCiphertextCommitment
    public let state: BackupCommitState
    public let deviceSignature: Data

    public init(
        formatVersion: BackupFormatVersion = .current,
        suite: BackupCryptoSuite = .v1,
        descriptorDigest: Data,
        authorizationDigest: Data,
        prologueDigest: Data,
        envelopeDigest: Data,
        commitment: BackupCiphertextCommitment,
        state: BackupCommitState = .complete,
        deviceSignature: Data
    ) throws {
        guard descriptorDigest.count == 32,
              authorizationDigest.count == 32,
              prologueDigest.count == 32,
              envelopeDigest.count == 32,
              deviceSignature.count == 64 else {
            throw BackupContractError.invalidLength
        }
        self.formatVersion = formatVersion
        self.suite = suite
        self.descriptorDigest = descriptorDigest
        self.authorizationDigest = authorizationDigest
        self.prologueDigest = prologueDigest
        self.envelopeDigest = envelopeDigest
        self.commitment = commitment
        self.state = state
        self.deviceSignature = deviceSignature
    }

    private var signaturePreimage: Data {
        var writer = BackupCanonicalWriter()
        writer.append(Self.magic)
        writer.append(formatVersion)
        writer.append(suite.rawValue)
        writer.append(descriptorDigest)
        writer.append(authorizationDigest)
        writer.append(prologueDigest)
        writer.append(envelopeDigest)
        writer.appendLengthPrefixed(commitment.canonicalBytes)
        writer.append(state.rawValue)
        return writer.data
    }

    public var signatureTranscript: BackupCanonicalTranscript {
        try! .init(role: .checkpointCommitSignature, fields: [signaturePreimage])
    }

    public var canonicalBytes: Data {
        var result = signaturePreimage
        result.append(deviceSignature)
        return result
    }

    public static func decodeCanonical(_ data: Data) throws -> Self {
        var reader = BackupCanonicalReader(data: data)
        try reader.requireMagic(magic)
        let version = try reader.readCurrentVersion()
        let suite = try reader.readCurrentSuite()
        let descriptorDigest = try reader.readFixed(count: 32)
        let authorizationDigest = try reader.readFixed(count: 32)
        let prologueDigest = try reader.readFixed(count: 32)
        let envelopeDigest = try reader.readFixed(count: 32)
        let commitment = try BackupCiphertextCommitment.decodeCanonical(
            reader.readLengthPrefixed(maximum: 64)
        )
        guard let state = BackupCommitState(rawValue: try reader.readUInt8()) else {
            throw BackupContractError.invalidField
        }
        let value = try Self(
            formatVersion: version,
            suite: suite,
            descriptorDigest: descriptorDigest,
            authorizationDigest: authorizationDigest,
            prologueDigest: prologueDigest,
            envelopeDigest: envelopeDigest,
            commitment: commitment,
            state: state,
            deviceSignature: reader.readFixed(count: 64)
        )
        try reader.requireEnd()
        guard value.canonicalBytes == data else { throw BackupContractError.invalidField }
        return value
    }
}
