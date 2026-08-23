import CryptoKit
import Foundation
import KinlogueCore

public enum BackupContainerError: Error, Equatable, Sendable {
    case invalidFormat
    case unsupportedVersion
    case unsupportedSuite
    case resourceLimit
    case arithmeticOverflow
    case counterOverflow
    case sourceIntegrityFailure
    case outputFailure
    case authenticationFailed
    case trustFailure
    case graphInvalid
    case trailingBytes
}

struct BackupNonce: Sendable {
    let bytes: Data
    var cryptoKitNonce: AES.GCM.Nonce { get throws { try AES.GCM.Nonce(data: bytes) } }
}

struct BackupCryptoSemanticVector: Sendable {
    let hpkeInfoSHA256: Data
    let hpkeAADSHA256: Data
    let frameAADSHA256: Data
    let commitmentDomainSHA256: Data
}

enum BackupCrypto {
    static let commitmentDomain = Data(
        "com.kinlogue.backup/encrypted-folder-checkpoint/v1/ciphertext-commitment".utf8
    )

    static func digest(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    static func nonce(prefix: Data, counter: UInt64) throws -> BackupNonce {
        guard prefix.count == 4 else { throw BackupContainerError.invalidFormat }
        var bytes = prefix
        bytes.append(bigEndian(counter))
        return BackupNonce(bytes: bytes)
    }

    static func payloadCounter(frameIndex: UInt64) throws -> UInt64 {
        let result = frameIndex.addingReportingOverflow(1)
        guard !result.overflow else { throw BackupContainerError.counterOverflow }
        return result.partialValue
    }

    static func hpkeInfo(
        descriptor: BackupSetDescriptor,
        prologue: BackupCheckpointPrologue
    ) throws -> Data {
        try BackupCanonicalTranscript(
            role: .hpkeInfo,
            fields: [descriptor.canonicalBytes, prologue.canonicalBytes]
        ).canonicalBytes
    }

    static func hpkeAAD(
        descriptorDigest: Data,
        authorizationDigest: Data,
        prologue: BackupCheckpointPrologue
    ) throws -> Data {
        try BackupCanonicalTranscript(
            role: .hpkeAdditionalAuthenticatedData,
            fields: [descriptorDigest, authorizationDigest, prologue.canonicalBytes]
        ).canonicalBytes
    }

    static func manifestAAD(
        descriptorDigest: Data,
        authorizationDigest: Data,
        envelopeDigest: Data,
        prologue: BackupCheckpointPrologue
    ) throws -> Data {
        try BackupCanonicalTranscript(
            role: .manifestAdditionalAuthenticatedData,
            fields: [
                descriptorDigest,
                authorizationDigest,
                envelopeDigest,
                prologue.canonicalBytes,
            ]
        ).canonicalBytes
    }

    static func frameAAD(
        prologue: BackupCheckpointPrologue,
        frameIndex: UInt64,
        plaintextByteCount: Int
    ) throws -> Data {
        guard plaintextByteCount >= 0,
              plaintextByteCount <= BackupFormatLimits.maximumFramePlaintextByteCount else {
            throw BackupContainerError.resourceLimit
        }
        return try BackupCanonicalTranscript(
            role: .frameAdditionalAuthenticatedData,
            fields: [
                prologue.canonicalBytes,
                Data("payload".utf8),
                bigEndian(frameIndex),
                bigEndian(UInt32(plaintextByteCount)),
                prologue.checkpointID.bytes,
            ]
        ).canonicalBytes
    }

    static func semanticVector(
        prologue: BackupCheckpointPrologue,
        descriptor: BackupSetDescriptor,
        authorizationDigest: Data,
        envelopeDigest: Data,
        frameIndex: UInt64,
        plaintextByteCount: Int
    ) throws -> BackupCryptoSemanticVector {
        BackupCryptoSemanticVector(
            hpkeInfoSHA256: digest(try hpkeInfo(
                descriptor: descriptor,
                prologue: prologue
            )),
            hpkeAADSHA256: digest(try hpkeAAD(
                descriptorDigest: digest(descriptor.canonicalBytes),
                authorizationDigest: authorizationDigest,
                prologue: prologue
            )),
            frameAADSHA256: digest(try frameAAD(
                prologue: prologue,
                frameIndex: frameIndex,
                plaintextByteCount: plaintextByteCount
            )),
            commitmentDomainSHA256: digest(commitmentDomain)
        )
    }

    private static func bigEndian<T: FixedWidthInteger>(_ value: T) -> Data {
        var encoded = value.bigEndian
        return withUnsafeBytes(of: &encoded) { Data($0) }
    }
}
