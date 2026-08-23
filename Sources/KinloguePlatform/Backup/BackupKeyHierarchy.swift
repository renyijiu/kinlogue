import CryptoKit
import Foundation
import KinlogueCore

public enum BackupKeyHierarchyError: Error, Equatable, Sendable {
    case invalidRecoverySeed
    case invalidRecoveryCode
    case descriptorMismatch
    case authorizationMismatch
    case deviceIdentityMismatch
    case signatureFailure
}

/// A printable, fixed-version representation of the full 256-bit recovery
/// seed. The checksum detects transcription mistakes; it is not a password KDF.
public enum BackupRecoveryCode {
    private static let prefix = "KLG1"
    private static let checksumByteCount = 4

    public static func encode(seed: Data) throws -> String {
        guard seed.count == 32 else { throw BackupKeyHierarchyError.invalidRecoverySeed }
        let payload = seed + checksum(for: seed)
        let hex = payload.map { String(format: "%02X", $0) }.joined()
        let groups = stride(from: 0, to: hex.count, by: 8).map { offset -> String in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            let end = hex.index(start, offsetBy: min(8, hex.count - offset))
            return String(hex[start..<end])
        }
        return ([prefix] + groups).joined(separator: "-")
    }

    public static func decode(_ code: String) throws -> Data {
        let components = code.split(separator: "-", omittingEmptySubsequences: false)
        guard components.count == 10,
              components.first == Substring(prefix),
              components.dropFirst().allSatisfy({ $0.count == 8 }) else {
            throw BackupKeyHierarchyError.invalidRecoveryCode
        }
        let hex = components.dropFirst().joined()
        guard hex.count == 72,
              hex.allSatisfy({ $0.isNumber || ("A"..."F").contains(String($0)) }) else {
            throw BackupKeyHierarchyError.invalidRecoveryCode
        }
        var bytes = Data()
        bytes.reserveCapacity(36)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                throw BackupKeyHierarchyError.invalidRecoveryCode
            }
            bytes.append(byte)
            index = next
        }
        let seed = bytes.prefix(32)
        let encodedChecksum = bytes.suffix(checksumByteCount)
        guard constantTimeEqual(Data(encodedChecksum), checksum(for: Data(seed))) else {
            throw BackupKeyHierarchyError.invalidRecoveryCode
        }
        return Data(seed)
    }

    private static func checksum(for seed: Data) -> Data {
        var input = Data("com.kinlogue.backup/recovery-code/v1/checksum".utf8)
        input.append(seed)
        return Data(SHA256.hash(data: input).prefix(checksumByteCount))
    }
}

public struct BackupEnrollmentMaterial: Sendable {
    public let recoveryCode: String
    public let descriptor: BackupSetDescriptor
    public let authorization: BackupDeviceAuthorization
    public let deviceSigningSeed: Data
    public let writerEpoch: BackupWriterEpoch

    fileprivate init(
        recoveryCode: String,
        descriptor: BackupSetDescriptor,
        authorization: BackupDeviceAuthorization,
        deviceSigningSeed: Data,
        writerEpoch: BackupWriterEpoch
    ) {
        self.recoveryCode = recoveryCode
        self.descriptor = descriptor
        self.authorization = authorization
        self.deviceSigningSeed = deviceSigningSeed
        self.writerEpoch = writerEpoch
    }
}

/// The persisted writer profile deliberately contains only a device signing
/// seed and recovery public roots. It has no API capable of deriving or opening
/// the recovery HPKE private key.
public struct BackupDeviceSigner: Sendable {
    public let descriptor: BackupSetDescriptor
    public let authorization: BackupDeviceAuthorization
    private let signingKey: Curve25519.Signing.PrivateKey

    public init(
        descriptor: BackupSetDescriptor,
        authorization: BackupDeviceAuthorization,
        deviceSigningSeed: Data
    ) throws {
        try BackupKeyHierarchy.validateEnrollment(
            descriptor: descriptor,
            authorization: authorization,
            deviceSigningSeed: deviceSigningSeed
        )
        self.descriptor = descriptor
        self.authorization = authorization
        signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: deviceSigningSeed)
    }

    public func signature(for message: Data) throws -> Data {
        try signingKey.signature(for: message)
    }
}

public enum BackupKeyHierarchy {
    private static let saltPrefix = Data("com.kinlogue.backup/encrypted-folder-checkpoint/v1/salt".utf8)

    public static func makeEnrollment() throws -> BackupEnrollmentMaterial {
        try makeEnrollment(
            recoverySeed: randomBytes(count: 32),
            setID: .init(bytes: randomBytes(count: 16)),
            deviceSigningSeed: Curve25519.Signing.PrivateKey().rawRepresentation,
            deviceID: .init(bytes: randomBytes(count: 16)),
            authorizationID: .init(bytes: randomBytes(count: 16)),
            writerEpoch: .init(bytes: randomBytes(count: 16))
        )
    }

    public static func makeEnrollment(
        recoverySeed: Data,
        setID: BackupSetID,
        deviceSigningSeed: Data,
        deviceID: BackupDeviceID,
        authorizationID: BackupAuthorizationID,
        writerEpoch: BackupWriterEpoch,
        sequenceFloor: UInt64 = 0
    ) throws -> BackupEnrollmentMaterial {
        guard recoverySeed.count == 32 else { throw BackupKeyHierarchyError.invalidRecoverySeed }
        let signingRoot = try Curve25519.Signing.PrivateKey(
            rawRepresentation: derivedSeed(
                recoverySeed: recoverySeed,
                setID: setID,
                role: .recoverySigningRootDerivation
            )
        )
        let hpkeRoot = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: derivedSeed(
                recoverySeed: recoverySeed,
                setID: setID,
                role: .recoveryHPKERootDerivation
            )
        )
        let unsignedDescriptor = try BackupSetDescriptor(
            setID: setID,
            recoverySigningPublicKey: signingRoot.publicKey.rawRepresentation,
            recoveryHPKEPublicKey: hpkeRoot.publicKey.rawRepresentation,
            rootSignature: Data(repeating: 0, count: 64)
        )
        let descriptor = try BackupSetDescriptor(
            setID: setID,
            recoverySigningPublicKey: signingRoot.publicKey.rawRepresentation,
            recoveryHPKEPublicKey: hpkeRoot.publicKey.rawRepresentation,
            rootSignature: try signingRoot.signature(
                for: unsignedDescriptor.signatureTranscript.canonicalBytes
            )
        )
        let descriptorDigest = digest(descriptor.canonicalBytes)
        let deviceKey: Curve25519.Signing.PrivateKey
        do {
            deviceKey = try .init(rawRepresentation: deviceSigningSeed)
        } catch {
            throw BackupKeyHierarchyError.deviceIdentityMismatch
        }
        let unsignedAuthorization = try BackupDeviceAuthorization(
            descriptorDigest: descriptorDigest,
            setID: setID,
            authorizationID: authorizationID,
            deviceID: deviceID,
            deviceSigningPublicKey: deviceKey.publicKey.rawRepresentation,
            sequenceFloor: sequenceFloor,
            rootSignature: Data(repeating: 0, count: 64)
        )
        let authorization = try BackupDeviceAuthorization(
            descriptorDigest: descriptorDigest,
            setID: setID,
            authorizationID: authorizationID,
            deviceID: deviceID,
            deviceSigningPublicKey: deviceKey.publicKey.rawRepresentation,
            sequenceFloor: sequenceFloor,
            rootSignature: try signingRoot.signature(
                for: unsignedAuthorization.signatureTranscript.canonicalBytes
            )
        )
        return BackupEnrollmentMaterial(
            recoveryCode: try BackupRecoveryCode.encode(seed: recoverySeed),
            descriptor: descriptor,
            authorization: authorization,
            deviceSigningSeed: deviceSigningSeed,
            writerEpoch: writerEpoch
        )
    }

    public static func validateRecoverySeed(
        _ recoverySeed: Data,
        descriptor: BackupSetDescriptor
    ) throws {
        guard recoverySeed.count == 32 else { throw BackupKeyHierarchyError.invalidRecoverySeed }
        let signingRoot = try Curve25519.Signing.PrivateKey(
            rawRepresentation: derivedSeed(
                recoverySeed: recoverySeed,
                setID: descriptor.setID,
                role: .recoverySigningRootDerivation
            )
        )
        let hpkeRoot = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: derivedSeed(
                recoverySeed: recoverySeed,
                setID: descriptor.setID,
                role: .recoveryHPKERootDerivation
            )
        )
        guard constantTimeEqual(
            signingRoot.publicKey.rawRepresentation,
            descriptor.recoverySigningPublicKey
        ), constantTimeEqual(
            hpkeRoot.publicKey.rawRepresentation,
            descriptor.recoveryHPKEPublicKey
        ), signingRoot.publicKey.isValidSignature(
            descriptor.rootSignature,
            for: descriptor.signatureTranscript.canonicalBytes
        ) else {
            throw BackupKeyHierarchyError.descriptorMismatch
        }
    }

    /// Seed-only restore primitive. Kept internal so the writer-facing public
    /// profile cannot derive or retain recovery private material.
    static func recoveryHPKEPrivateKey(
        recoverySeed: Data,
        descriptor: BackupSetDescriptor
    ) throws -> Curve25519.KeyAgreement.PrivateKey {
        try validateRecoverySeed(recoverySeed, descriptor: descriptor)
        return try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: derivedSeed(
                recoverySeed: recoverySeed,
                setID: descriptor.setID,
                role: .recoveryHPKERootDerivation
            )
        )
    }

    public static func validateEnrollment(
        descriptor: BackupSetDescriptor,
        authorization: BackupDeviceAuthorization,
        deviceSigningSeed: Data
    ) throws {
        let descriptorDigest = digest(descriptor.canonicalBytes)
        guard authorization.setID == descriptor.setID,
              constantTimeEqual(authorization.descriptorDigest, descriptorDigest) else {
            throw BackupKeyHierarchyError.authorizationMismatch
        }
        let root: Curve25519.Signing.PublicKey
        let device: Curve25519.Signing.PrivateKey
        do {
            root = try .init(rawRepresentation: descriptor.recoverySigningPublicKey)
            device = try .init(rawRepresentation: deviceSigningSeed)
        } catch {
            throw BackupKeyHierarchyError.deviceIdentityMismatch
        }
        guard root.isValidSignature(
            descriptor.rootSignature,
            for: descriptor.signatureTranscript.canonicalBytes
        ), root.isValidSignature(
            authorization.rootSignature,
            for: authorization.signatureTranscript.canonicalBytes
        ) else {
            throw BackupKeyHierarchyError.signatureFailure
        }
        guard constantTimeEqual(
            device.publicKey.rawRepresentation,
            authorization.deviceSigningPublicKey
        ) else {
            throw BackupKeyHierarchyError.deviceIdentityMismatch
        }
    }

    public static func digest(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    private static func derivedSeed(
        recoverySeed: Data,
        setID: BackupSetID,
        role: BackupTranscriptRole
    ) throws -> Data {
        var salt = saltPrefix
        salt.append(setID.bytes)
        let info = try BackupCanonicalTranscript(role: role, fields: [setID.bytes]).canonicalBytes
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: recoverySeed),
            salt: salt,
            info: info,
            outputByteCount: 32
        )
        return key.withUnsafeBytes { Data($0) }
    }

    private static func randomBytes(count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}

private func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
    guard lhs.count == rhs.count else { return false }
    return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
}
