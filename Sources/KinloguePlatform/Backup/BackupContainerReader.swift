import CryptoKit
import Foundation
import KinlogueCore

public struct BackupContainerReadResult: Sendable {
    public let publicVerification: BackupPublicContainerVerification
    public let manifest: BackupManifest
}

public struct BackupContainerReader: Sendable {
    public init() {}

    public func read(
        source: BackupContainerByteSource,
        recoverySeed: Data,
        sink: BackupContainerEntrySink
    ) throws -> BackupContainerReadResult {
        try Task.checkCancellation()
        let parsed = try BackupContainerParser.parse(source: source)
        let privateKey: Curve25519.KeyAgreement.PrivateKey
        do {
            privateKey = try BackupKeyHierarchy.recoveryHPKEPrivateKey(
                recoverySeed: recoverySeed,
                descriptor: parsed.descriptor
            )
        } catch {
            throw BackupContainerError.authenticationFailed
        }
        let publicVerification = try BackupTrustVerifier.verify(
            parsed: parsed,
            trustedDescriptor: parsed.descriptor
        )
        let descriptorDigest = BackupCrypto.digest(parsed.descriptor.canonicalBytes)
        let authorizationDigest = BackupCrypto.digest(parsed.authorization.canonicalBytes)
        var recipient: HPKE.Recipient
        do {
            recipient = try HPKE.Recipient(
                privateKey: privateKey,
                ciphersuite: .Curve25519_SHA256_ChachaPoly,
                info: BackupCrypto.hpkeInfo(
                    descriptor: parsed.descriptor,
                    prologue: parsed.prologue
                ),
                encapsulatedKey: parsed.envelope.encapsulatedKey
            )
        } catch {
            throw BackupContainerError.authenticationFailed
        }
        let dekBytes: Data
        do {
            dekBytes = try recipient.open(
                parsed.envelope.sealedKey,
                authenticating: BackupCrypto.hpkeAAD(
                    descriptorDigest: descriptorDigest,
                    authorizationDigest: authorizationDigest,
                    prologue: parsed.prologue
                )
            )
        } catch {
            throw BackupContainerError.authenticationFailed
        }
        guard dekBytes.count == 32 else { throw BackupContainerError.authenticationFailed }
        let manifest = try Self.decrypt(
            parsed: parsed,
            dek: SymmetricKey(data: dekBytes),
            sink: sink
        )
        return BackupContainerReadResult(
            publicVerification: publicVerification,
            manifest: manifest
        )
    }

    static func decrypt(
        parsed: ParsedBackupContainer,
        dek: SymmetricKey,
        sink: BackupContainerEntrySink
    ) throws -> BackupManifest {
        let descriptorDigest = BackupCrypto.digest(parsed.descriptor.canonicalBytes)
        let authorizationDigest = BackupCrypto.digest(parsed.authorization.canonicalBytes)
        let envelopeDigest = BackupCrypto.digest(parsed.envelope.canonicalBytes)
        let encryptedManifest = try exactRead(
            source: parsed.source,
            offset: parsed.encryptedManifestOffset,
            count: parsed.encryptedManifestByteCount
        )
        let manifestTag = try exactRead(
            source: parsed.source,
            offset: parsed.encryptedManifestTagOffset,
            count: ContainerFormat.authenticationTagByteCount
        )
        let manifestBytes: Data
        do {
            let nonce = try BackupCrypto.nonce(
                prefix: parsed.header.noncePrefix,
                counter: 0
            )
            manifestBytes = try AES.GCM.open(
                AES.GCM.SealedBox(combined: nonce.bytes + encryptedManifest + manifestTag),
                using: dek,
                authenticating: BackupCrypto.manifestAAD(
                    descriptorDigest: descriptorDigest,
                    authorizationDigest: authorizationDigest,
                    envelopeDigest: envelopeDigest,
                    prologue: parsed.prologue
                )
            )
        } catch {
            throw BackupContainerError.authenticationFailed
        }
        guard manifestBytes.count == parsed.header.manifestPlaintextByteCount else {
            throw BackupContainerError.invalidFormat
        }
        let manifest = try mapContractError {
            try BackupManifest.decodeCanonical(manifestBytes)
        }
        try validateGraph(manifest: manifest, parsed: parsed)

        var frameCursor = 0
        for entry in manifest.entries {
            try Task.checkCancellation()
            let writer: BackupContainerEntrySink.Writer
            do { writer = try sink.writer(for: entry) }
            catch is CancellationError { throw CancellationError() }
            catch { throw BackupContainerError.outputFailure }
            var entryHasher = SHA256()
            var entryByteCount: UInt64 = 0
            for localIndex in 0..<Int(entry.frameCount) {
                try Task.checkCancellation()
                let layout = parsed.frames[frameCursor]
                let remaining = entry.plaintextByteCount - entryByteCount
                let expectedLength = Int(min(
                    UInt64(BackupFormatLimits.maximumFramePlaintextByteCount),
                    remaining
                ))
                guard layout.index == UInt64(frameCursor),
                      layout.plaintextByteCount == expectedLength,
                      localIndex + 1 < Int(entry.frameCount)
                        ? expectedLength == BackupFormatLimits.maximumFramePlaintextByteCount
                        : true else {
                    throw BackupContainerError.graphInvalid
                }
                let ciphertext = try exactRead(
                    source: parsed.source,
                    offset: layout.ciphertextOffset,
                    count: layout.ciphertextByteCount
                )
                let tag = try exactRead(
                    source: parsed.source,
                    offset: layout.tagOffset,
                    count: ContainerFormat.authenticationTagByteCount
                )
                let plaintext: Data
                do {
                    let counter = try BackupCrypto.payloadCounter(frameIndex: layout.index)
                    let nonce = try BackupCrypto.nonce(
                        prefix: parsed.header.noncePrefix,
                        counter: counter
                    )
                    plaintext = try AES.GCM.open(
                        AES.GCM.SealedBox(combined: nonce.bytes + ciphertext + tag),
                        using: dek,
                        authenticating: BackupCrypto.frameAAD(
                            prologue: parsed.prologue,
                            frameIndex: layout.index,
                            plaintextByteCount: layout.plaintextByteCount
                        )
                    )
                } catch {
                    throw BackupContainerError.authenticationFailed
                }
                guard plaintext.count == expectedLength else {
                    throw BackupContainerError.authenticationFailed
                }
                entryHasher.update(data: plaintext)
                do { try writer(plaintext) }
                catch is CancellationError { throw CancellationError() }
                catch { throw BackupContainerError.outputFailure }
                entryByteCount += UInt64(plaintext.count)
                frameCursor += 1
            }
            guard entryByteCount == entry.plaintextByteCount,
                  Data(entryHasher.finalize()) == entry.plaintextDigest else {
                throw BackupContainerError.sourceIntegrityFailure
            }
            do { try sink.finish(entry) }
            catch is CancellationError { throw CancellationError() }
            catch { throw BackupContainerError.outputFailure }
        }
        guard frameCursor == parsed.frames.count else { throw BackupContainerError.graphInvalid }
        return manifest
    }

    private static func validateGraph(
        manifest: BackupManifest,
        parsed: ParsedBackupContainer
    ) throws {
        guard manifest.formatVersion == parsed.header.version,
              manifest.suite == parsed.header.suite,
              manifest.totalFrameCount == UInt64(parsed.frames.count),
              manifest.entryCount <= BackupFormatLimits.maximumEntryCount,
              manifest.totalPlaintextByteCount <= BackupFormatLimits.maximumPlaintextByteCount else {
            throw BackupContainerError.graphInvalid
        }
        for entry in manifest.entries {
            let validPath: Bool
            switch entry.kind {
            case .vaultCatalog:
                validPath = entry.path == "library.json"
            case .lanInboxManifest:
                validPath = entry.path == "lan-inbox/inbox.json"
            case .vaultObject:
                validPath = entry.path.hasPrefix("objects/")
            case .lanInboxBlob:
                validPath = entry.path.hasPrefix("lan-inbox/blobs/")
            case .lanInboxDerivedArtifact:
                validPath = entry.path.hasPrefix("lan-inbox/derived/")
            case .lanInboxReceipt:
                validPath = entry.path.hasPrefix("lan-inbox/receipts/")
            }
            guard validPath else { throw BackupContainerError.graphInvalid }
            let end = entry.firstFrameIndex.addingReportingOverflow(UInt64(entry.frameCount))
            guard !end.overflow,
                  end.partialValue <= UInt64(parsed.frames.count) else {
                throw BackupContainerError.graphInvalid
            }
        }
    }
}
