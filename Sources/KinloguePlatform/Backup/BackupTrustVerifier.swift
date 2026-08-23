import CryptoKit
import Foundation
import KinlogueCore

public struct BackupPublicContainerVerification: Sendable {
    public let checkpoint: BackupPublicCheckpoint
    public let descriptor: BackupSetDescriptor
    public let authorization: BackupDeviceAuthorization
    public let prologue: BackupCheckpointPrologue
}

public struct BackupTrustVerifier: Sendable {
    public init() {}

    /// Verifies an exact signed checkpoint against the descriptor pinned in the
    /// app-private writer profile. It intentionally has no recovery-seed input.
    public func verify(
        source: BackupContainerByteSource,
        trustedDescriptor: BackupSetDescriptor
    ) throws -> BackupPublicContainerVerification {
        let parsed = try BackupContainerParser.parse(source: source)
        return try Self.verify(parsed: parsed, trustedDescriptor: trustedDescriptor)
    }

    static func verify(
        parsed: ParsedBackupContainer,
        trustedDescriptor: BackupSetDescriptor
    ) throws -> BackupPublicContainerVerification {
        guard parsed.descriptor.canonicalBytes == trustedDescriptor.canonicalBytes,
              parsed.header.version == .current,
              parsed.header.suite == .v1,
              parsed.descriptor.formatVersion == .current,
              parsed.descriptor.suite == .v1,
              parsed.authorization.formatVersion == .current,
              parsed.authorization.suite == .v1,
              parsed.prologue.formatVersion == .current,
              parsed.prologue.suite == .v1,
              parsed.envelope.formatVersion == .current,
              parsed.envelope.suite == .v1,
              parsed.footer.formatVersion == .current,
              parsed.footer.suite == .v1 else {
            throw BackupContainerError.trustFailure
        }
        let descriptorDigest = BackupCrypto.digest(parsed.descriptor.canonicalBytes)
        let authorizationDigest = BackupCrypto.digest(parsed.authorization.canonicalBytes)
        let prologueDigest = BackupCrypto.digest(parsed.prologue.canonicalBytes)
        let envelopeDigest = BackupCrypto.digest(parsed.envelope.canonicalBytes)
        guard parsed.authorization.descriptorDigest == descriptorDigest,
              parsed.authorization.setID == parsed.descriptor.setID,
              parsed.prologue.setID == parsed.descriptor.setID,
              parsed.prologue.authorizationID == parsed.authorization.authorizationID,
              parsed.prologue.deviceID == parsed.authorization.deviceID,
              parsed.prologue.sequence >= parsed.authorization.sequenceFloor,
              parsed.footer.descriptorDigest == descriptorDigest,
              parsed.footer.authorizationDigest == authorizationDigest,
              parsed.footer.prologueDigest == prologueDigest,
              parsed.footer.envelopeDigest == envelopeDigest,
              parsed.footer.commitment.ciphertextByteCount == parsed.bodyByteCount,
              parsed.footer.commitment.digest == parsed.bodyDigest,
              parsed.footer.state == .complete else {
            throw BackupContainerError.trustFailure
        }

        let recoveryRoot: Curve25519.Signing.PublicKey
        let deviceKey: Curve25519.Signing.PublicKey
        do {
            recoveryRoot = try .init(rawRepresentation: parsed.descriptor.recoverySigningPublicKey)
            deviceKey = try .init(rawRepresentation: parsed.authorization.deviceSigningPublicKey)
        } catch {
            throw BackupContainerError.trustFailure
        }
        guard recoveryRoot.isValidSignature(
            parsed.descriptor.rootSignature,
            for: parsed.descriptor.signatureTranscript.canonicalBytes
        ), recoveryRoot.isValidSignature(
            parsed.authorization.rootSignature,
            for: parsed.authorization.signatureTranscript.canonicalBytes
        ), deviceKey.isValidSignature(
            parsed.footer.deviceSignature,
            for: parsed.footer.signatureTranscript.canonicalBytes
        ) else {
            throw BackupContainerError.trustFailure
        }
        return BackupPublicContainerVerification(
            checkpoint: try BackupPublicCheckpoint(
                setID: parsed.prologue.setID,
                checkpointID: parsed.prologue.checkpointID,
                deviceID: parsed.prologue.deviceID,
                authorizationID: parsed.prologue.authorizationID,
                sequence: parsed.prologue.sequence,
                commitment: parsed.footer.commitment
            ),
            descriptor: parsed.descriptor,
            authorization: parsed.authorization,
            prologue: parsed.prologue
        )
    }
}

struct ParsedBackupContainer: Sendable {
    let header: BackupContainerHeader
    let descriptor: BackupSetDescriptor
    let authorization: BackupDeviceAuthorization
    let prologue: BackupCheckpointPrologue
    let envelope: BackupHPKEEnvelope
    let encryptedManifestOffset: UInt64
    let encryptedManifestByteCount: Int
    let encryptedManifestTagOffset: UInt64
    let frames: [BackupContainerFrameLayout]
    let bodyByteCount: UInt64
    let bodyDigest: Data
    let footer: BackupCheckpointFooter
    let source: BackupContainerByteSource
}

struct BackupContainerHeader: Sendable {
    let version: BackupFormatVersion
    let suite: BackupCryptoSuite
    let frameCount: Int
    let manifestPlaintextByteCount: Int
    let descriptorByteCount: Int
    let authorizationByteCount: Int
    let prologueByteCount: Int
    let envelopeByteCount: Int
    let noncePrefix: Data
}

struct BackupContainerFrameLayout: Sendable {
    let index: UInt64
    let plaintextByteCount: Int
    let headerOffset: UInt64
    let ciphertextOffset: UInt64
    let ciphertextByteCount: Int
    let tagOffset: UInt64
}

enum BackupContainerParser {
    static func parse(source: BackupContainerByteSource) throws -> ParsedBackupContainer {
        try parse(source: source, requiresFooter: true)
    }

    static func verifyUnsignedBody(
        source: BackupContainerByteSource,
        expectedCommitment: BackupCiphertextCommitment,
        expectedManifest: BackupManifest,
        expectedDescriptor: BackupSetDescriptor,
        expectedAuthorization: BackupDeviceAuthorization,
        expectedPrologue: BackupCheckpointPrologue,
        expectedEnvelope: BackupHPKEEnvelope,
        dek: SymmetricKey
    ) throws {
        let parsed = try parse(source: source, requiresFooter: false)
        guard parsed.descriptor == expectedDescriptor,
              parsed.authorization == expectedAuthorization,
              parsed.prologue == expectedPrologue,
              parsed.envelope == expectedEnvelope,
              parsed.bodyByteCount == expectedCommitment.ciphertextByteCount,
              parsed.bodyDigest == expectedCommitment.digest else {
            throw BackupContainerError.outputFailure
        }
        let manifest = try BackupContainerReader.decrypt(
            parsed: parsed,
            dek: dek,
            sink: .init { _ in { _ in } }
        )
        guard manifest == expectedManifest else { throw BackupContainerError.outputFailure }
    }

    static func readHeader(source: BackupContainerByteSource) throws -> BackupContainerHeader {
        let raw = try exactRead(
            source: source,
            offset: 0,
            count: ContainerFormat.fixedHeaderByteCount
        )
        guard Data(raw.prefix(8)) == ContainerFormat.magic else {
            throw BackupContainerError.invalidFormat
        }
        let major: UInt16 = integer(raw, at: 8)
        let minor: UInt16 = integer(raw, at: 10)
        let minimumReaderMinor: UInt16 = integer(raw, at: 12)
        let version: BackupFormatVersion
        do {
            version = try .init(major: major, minor: minor, minimumReaderMinor: minimumReaderMinor)
        } catch {
            throw BackupContainerError.unsupportedVersion
        }
        let suiteRaw: UInt16 = integer(raw, at: 14)
        guard let suite = BackupCryptoSuite(rawValue: suiteRaw) else {
            throw BackupContainerError.unsupportedSuite
        }
        let chunkByteCount: UInt32 = integer(raw, at: 16)
        let frameCount = Int(integer(raw, at: 20) as UInt32)
        let manifestByteCount = Int(integer(raw, at: 24) as UInt32)
        let descriptorByteCount = Int(integer(raw, at: 28) as UInt32)
        let authorizationByteCount = Int(integer(raw, at: 32) as UInt32)
        let prologueByteCount = Int(integer(raw, at: 36) as UInt32)
        let envelopeByteCount = Int(integer(raw, at: 40) as UInt32)
        guard chunkByteCount == UInt32(BackupFormatLimits.maximumFramePlaintextByteCount),
              frameCount <= BackupFormatLimits.maximumFrameCount,
              manifestByteCount > 0,
              manifestByteCount <= BackupFormatLimits.maximumCanonicalManifestByteCount,
              descriptorByteCount > 0,
              descriptorByteCount <= ContainerFormat.maximumDescriptorByteCount,
              authorizationByteCount > 0,
              authorizationByteCount <= ContainerFormat.maximumAuthorizationByteCount,
              prologueByteCount > 0,
              prologueByteCount <= ContainerFormat.maximumPrologueByteCount,
              envelopeByteCount > 0,
              envelopeByteCount <= ContainerFormat.maximumEnvelopeByteCount else {
            throw BackupContainerError.resourceLimit
        }
        return BackupContainerHeader(
            version: version,
            suite: suite,
            frameCount: frameCount,
            manifestPlaintextByteCount: manifestByteCount,
            descriptorByteCount: descriptorByteCount,
            authorizationByteCount: authorizationByteCount,
            prologueByteCount: prologueByteCount,
            envelopeByteCount: envelopeByteCount,
            noncePrefix: Data(raw[44..<48])
        )
    }

    private static func parse(
        source: BackupContainerByteSource,
        requiresFooter: Bool
    ) throws -> ParsedBackupContainer {
        let maximumBody = BackupFormatLimits.maximumPlaintextByteCount.addingReportingOverflow(
            BackupFormatLimits.targetFormatAllowanceByteCount
        )
        guard !maximumBody.overflow else { throw BackupContainerError.arithmeticOverflow }
        let maximumFile = maximumBody.partialValue.addingReportingOverflow(
            UInt64(4 + ContainerFormat.maximumFooterByteCount)
        )
        guard !maximumFile.overflow,
              source.byteCount <= maximumFile.partialValue else {
            throw BackupContainerError.resourceLimit
        }
        let header = try readHeader(source: source)
        var cursor = ContainerCursor(source: source)
        _ = try cursor.read(count: ContainerFormat.fixedHeaderByteCount, commit: true)
        let descriptor = try mapContractError {
            try BackupSetDescriptor.decodeCanonical(
                cursor.read(count: header.descriptorByteCount, commit: true)
            )
        }
        let authorization = try mapContractError {
            try BackupDeviceAuthorization.decodeCanonical(
                cursor.read(count: header.authorizationByteCount, commit: true)
            )
        }
        let prologue = try mapContractError {
            try BackupCheckpointPrologue.decodeCanonical(
                cursor.read(count: header.prologueByteCount, commit: true)
            )
        }
        let envelope = try mapContractError {
            try BackupHPKEEnvelope.decodeCanonical(
                cursor.read(count: header.envelopeByteCount, commit: true)
            )
        }
        let encryptedManifestOffset = cursor.offset
        try cursor.skip(count: header.manifestPlaintextByteCount, commit: true)
        let encryptedManifestTagOffset = cursor.offset
        try cursor.skip(count: ContainerFormat.authenticationTagByteCount, commit: true)

        var frames: [BackupContainerFrameLayout] = []
        frames.reserveCapacity(header.frameCount)
        for expectedIndex in 0..<header.frameCount {
            try Task.checkCancellation()
            let headerOffset = cursor.offset
            let frameHeader = try cursor.read(
                count: ContainerFormat.frameHeaderByteCount,
                commit: true
            )
            guard Data(frameHeader.prefix(4)) == ContainerFormat.frameMagic else {
                throw BackupContainerError.invalidFormat
            }
            let index: UInt64 = integer(frameHeader, at: 4)
            let plaintextByteCount = Int(integer(frameHeader, at: 12) as UInt32)
            let ciphertextByteCount = Int(integer(frameHeader, at: 16) as UInt32)
            guard index == UInt64(expectedIndex),
                  plaintextByteCount <= BackupFormatLimits.maximumFramePlaintextByteCount,
                  ciphertextByteCount == plaintextByteCount else {
                throw BackupContainerError.invalidFormat
            }
            let ciphertextOffset = cursor.offset
            try cursor.skip(count: ciphertextByteCount, commit: true)
            let tagOffset = cursor.offset
            try cursor.skip(count: ContainerFormat.authenticationTagByteCount, commit: true)
            frames.append(.init(
                index: index,
                plaintextByteCount: plaintextByteCount,
                headerOffset: headerOffset,
                ciphertextOffset: ciphertextOffset,
                ciphertextByteCount: ciphertextByteCount,
                tagOffset: tagOffset
            ))
        }
        let bodyByteCount = cursor.offset
        let bodyDigest = cursor.finalizeCommitment()
        let footer: BackupCheckpointFooter
        if requiresFooter {
            let encodedFooterLength: UInt32 = integer(
                try cursor.read(count: 4, commit: false),
                at: 0
            )
            guard encodedFooterLength > 0,
                  encodedFooterLength <= UInt32(ContainerFormat.maximumFooterByteCount) else {
                throw BackupContainerError.resourceLimit
            }
            footer = try mapContractError {
                try BackupCheckpointFooter.decodeCanonical(
                    cursor.read(count: Int(encodedFooterLength), commit: false)
                )
            }
            guard cursor.offset == source.byteCount else {
                throw BackupContainerError.trailingBytes
            }
        } else {
            guard cursor.offset == source.byteCount else {
                throw BackupContainerError.trailingBytes
            }
            footer = try BackupCheckpointFooter(
                descriptorDigest: Data(repeating: 0, count: 32),
                authorizationDigest: Data(repeating: 0, count: 32),
                prologueDigest: Data(repeating: 0, count: 32),
                envelopeDigest: Data(repeating: 0, count: 32),
                commitment: .init(digest: bodyDigest, ciphertextByteCount: bodyByteCount),
                deviceSignature: Data(repeating: 0, count: 64)
            )
        }
        return ParsedBackupContainer(
            header: header,
            descriptor: descriptor,
            authorization: authorization,
            prologue: prologue,
            envelope: envelope,
            encryptedManifestOffset: encryptedManifestOffset,
            encryptedManifestByteCount: header.manifestPlaintextByteCount,
            encryptedManifestTagOffset: encryptedManifestTagOffset,
            frames: frames,
            bodyByteCount: bodyByteCount,
            bodyDigest: bodyDigest,
            footer: footer,
            source: source
        )
    }

    private static func integer<T: FixedWidthInteger>(_ data: Data, at offset: Int) -> T {
        data[offset..<(offset + MemoryLayout<T>.size)].reduce(T.zero) {
            ($0 << 8) | T($1)
        }
    }
}

private struct ContainerCursor {
    let source: BackupContainerByteSource
    private(set) var offset: UInt64 = 0
    private var hasher = SHA256()
    private var didFinalize = false

    init(source: BackupContainerByteSource) {
        self.source = source
        hasher.update(data: BackupCrypto.commitmentDomain)
    }

    mutating func read(count: Int, commit: Bool) throws -> Data {
        guard !(didFinalize && commit) else { throw BackupContainerError.invalidFormat }
        let bytes = try exactRead(source: source, offset: offset, count: count)
        let advanced = offset.addingReportingOverflow(UInt64(count))
        guard !advanced.overflow else { throw BackupContainerError.arithmeticOverflow }
        offset = advanced.partialValue
        if commit { hasher.update(data: bytes) }
        return bytes
    }

    mutating func skip(count: Int, commit: Bool) throws {
        guard count >= 0 else { throw BackupContainerError.invalidFormat }
        var remaining = count
        while remaining > 0 {
            let batch = min(remaining, BackupFormatLimits.maximumFramePlaintextByteCount)
            _ = try read(count: batch, commit: commit)
            remaining -= batch
        }
    }

    mutating func finalizeCommitment() -> Data {
        precondition(!didFinalize)
        didFinalize = true
        return Data(hasher.finalize())
    }
}

func exactRead(
    source: BackupContainerByteSource,
    offset: UInt64,
    count: Int
) throws -> Data {
    guard count >= 0,
          offset <= source.byteCount,
          UInt64(count) <= source.byteCount - offset else {
        throw BackupContainerError.invalidFormat
    }
    guard count > 0 else { return Data() }
    let bytes: Data
    do { bytes = try source.read(offset: offset, maximumByteCount: count) }
    catch is CancellationError { throw CancellationError() }
    catch let error as BackupContainerError { throw error }
    catch { throw BackupContainerError.invalidFormat }
    guard bytes.count == count else { throw BackupContainerError.invalidFormat }
    return bytes
}
