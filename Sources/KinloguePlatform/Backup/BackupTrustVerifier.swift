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
              parsed.header.suite == .v1,
              parsed.descriptor.formatVersion == .legacy,
              parsed.descriptor.suite == .v1,
              parsed.authorization.formatVersion == .legacy,
              parsed.authorization.suite == .v1,
              parsed.prologue.formatVersion == parsed.header.version,
              parsed.prologue.suite == .v1,
              parsed.envelope.formatVersion == .legacy,
              parsed.envelope.suite == .v1,
              parsed.footer.formatVersion == parsed.header.version,
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
    let framesOffset: UInt64
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

    var endOffset: UInt64 { tagOffset + UInt64(ContainerFormat.authenticationTagByteCount) }

    init(header: Data, offset: UInt64, expectedIndex: UInt64) throws {
        guard Data(header.prefix(4)) == ContainerFormat.frameMagic else {
            throw BackupContainerError.invalidFormat
        }
        let index: UInt64 = BackupContainerParser.integer(header, at: 4)
        let plaintext = Int(BackupContainerParser.integer(header, at: 12) as UInt32)
        let ciphertext = Int(BackupContainerParser.integer(header, at: 16) as UInt32)
        guard index == expectedIndex,
              plaintext <= BackupFormatLimits.maximumFramePlaintextByteCount,
              ciphertext == plaintext else { throw BackupContainerError.invalidFormat }
        let size = UInt64(ContainerFormat.frameHeaderByteCount + ciphertext
            + ContainerFormat.authenticationTagByteCount)
        let end = offset.addingReportingOverflow(size)
        guard !end.overflow else { throw BackupContainerError.arithmeticOverflow }
        self.index = index
        plaintextByteCount = plaintext
        headerOffset = offset
        ciphertextOffset = offset + UInt64(ContainerFormat.frameHeaderByteCount)
        ciphertextByteCount = ciphertext
        tagOffset = end.partialValue - UInt64(ContainerFormat.authenticationTagByteCount)
    }

    static func read(
        source: BackupContainerByteSource, offset: UInt64, expectedIndex: UInt64
    ) throws -> Self {
        let header = try exactRead(source: source, offset: offset, count: ContainerFormat.frameHeaderByteCount)
        let layout = try Self(header: header, offset: offset, expectedIndex: expectedIndex)
        guard layout.endOffset <= source.byteCount else { throw BackupContainerError.invalidFormat }
        return layout
    }
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

    static func readHeader(
        source: BackupContainerByteSource, readerMinor: UInt16 = 1
    ) throws -> BackupContainerHeader {
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
            version = try .init(major: major, minor: minor, minimumReaderMinor: minimumReaderMinor, readerMinor: readerMinor)
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
              frameCount <= BackupFormatLimits.maximumFrameCount(for: version),
              manifestByteCount > 0,
              manifestByteCount <= BackupFormatLimits.maximumCanonicalManifestByteCount(for: version),
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
        let header = try readHeader(source: source)
        guard source.byteCount <= BackupFormatLimits.maximumContainerByteCount(for: header.version) else {
            throw BackupContainerError.resourceLimit
        }
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

        let framesOffset = cursor.offset
        let minimumFramesSize = UInt64(header.frameCount) * UInt64(
            ContainerFormat.frameHeaderByteCount + ContainerFormat.authenticationTagByteCount
        )
        guard framesOffset <= source.byteCount,
              minimumFramesSize <= source.byteCount - framesOffset else {
            throw BackupContainerError.invalidFormat
        }
        var plaintextByteCount: UInt64 = 0
        for expectedIndex in 0..<header.frameCount {
            try Task.checkCancellation()
            let headerOffset = cursor.offset
            let frameHeader = try cursor.read(count: ContainerFormat.frameHeaderByteCount, commit: true)
            let frame = try BackupContainerFrameLayout(
                header: frameHeader, offset: headerOffset, expectedIndex: UInt64(expectedIndex)
            )
            let next = plaintextByteCount.addingReportingOverflow(UInt64(frame.plaintextByteCount))
            guard !next.overflow,
                  next.partialValue <= BackupFormatLimits.maximumPlaintextByteCount(for: header.version) else {
                throw BackupContainerError.resourceLimit
            }
            plaintextByteCount = next.partialValue
            try cursor.skip(count: frame.ciphertextByteCount, commit: true)
            try cursor.skip(count: ContainerFormat.authenticationTagByteCount, commit: true)
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
                formatVersion: header.version,
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
            framesOffset: framesOffset,
            bodyByteCount: bodyByteCount,
            bodyDigest: bodyDigest,
            footer: footer,
            source: source
        )
    }

    static func integer<T: FixedWidthInteger>(_ data: Data, at offset: Int) -> T {
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
            try Task.checkCancellation()
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
