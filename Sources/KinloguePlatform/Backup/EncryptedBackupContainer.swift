import CryptoKit
import Foundation
import KinlogueCore

public struct BackupContainerEntrySource: Sendable {
    public let kind: BackupManifestEntry.Kind
    public let path: String
    public let plaintextByteCount: UInt64
    public let plaintextDigest: Data
    private let legacyReader: (@Sendable (UInt64, Int) throws -> Data)?
    private let opener: @Sendable () async throws -> BackupContainerOpenedEntrySource

    public init(
        kind: BackupManifestEntry.Kind,
        path: String,
        plaintextByteCount: UInt64,
        plaintextDigest: Data,
        read: @escaping @Sendable (UInt64, Int) throws -> Data
    ) {
        self.kind = kind
        self.path = path
        self.plaintextByteCount = plaintextByteCount
        self.plaintextDigest = plaintextDigest
        legacyReader = read
        opener = { BackupContainerOpenedEntrySource(read: read) }
    }

    public init(
        kind: BackupManifestEntry.Kind,
        path: String,
        plaintextByteCount: UInt64,
        plaintextDigest: Data,
        open: @escaping @Sendable () async throws -> BackupContainerOpenedEntrySource
    ) {
        self.kind = kind
        self.path = path
        self.plaintextByteCount = plaintextByteCount
        self.plaintextDigest = plaintextDigest
        legacyReader = nil
        opener = open
    }

    func open() async throws -> BackupContainerOpenedEntrySource {
        try await opener()
    }

    public func read(offset: UInt64, maximumByteCount: Int) throws -> Data {
        guard maximumByteCount >= 0,
              maximumByteCount <= BackupFormatLimits.maximumFramePlaintextByteCount,
              let legacyReader else {
            throw BackupContainerError.resourceLimit
        }
        let bytes = try legacyReader(offset, maximumByteCount)
        guard bytes.count <= maximumByteCount else { throw BackupContainerError.sourceIntegrityFailure }
        return bytes
    }

    public func withRead(
        _ replacement: @escaping @Sendable (UInt64, Int) throws -> Data
    ) -> Self {
        Self(
            kind: kind,
            path: path,
            plaintextByteCount: plaintextByteCount,
            plaintextDigest: plaintextDigest,
            read: replacement
        )
    }
}

// SAFETY: Reads are immutable `pread`-style operations. The lock only makes
// ownership release idempotent when cancellation races cleanup.
public final class BackupContainerOpenedEntrySource: @unchecked Sendable {
    private let reader: @Sendable (UInt64, Int) throws -> Data
    private let closer: @Sendable () -> Void
    private let lock = NSLock()
    private var isClosed = false

    public init(
        read: @escaping @Sendable (UInt64, Int) throws -> Data,
        close: @escaping @Sendable () -> Void = {}
    ) {
        reader = read
        closer = close
    }

    public func read(offset: UInt64, maximumByteCount: Int) throws -> Data {
        guard maximumByteCount >= 0,
              maximumByteCount <= BackupFormatLimits.maximumFramePlaintextByteCount,
              !lock.withLock({ isClosed }) else {
            throw BackupContainerError.sourceIntegrityFailure
        }
        let bytes = try reader(offset, maximumByteCount)
        guard bytes.count <= maximumByteCount else {
            throw BackupContainerError.sourceIntegrityFailure
        }
        return bytes
    }

    public func close() {
        let shouldClose = lock.withLock { () -> Bool in
            guard !isClosed else { return false }
            isClosed = true
            return true
        }
        if shouldClose { closer() }
    }

    deinit { close() }
}

public struct BackupContainerByteSource: Sendable {
    public let byteCount: UInt64
    private let reader: @Sendable (UInt64, Int) throws -> Data

    public init(
        byteCount: UInt64,
        read: @escaping @Sendable (UInt64, Int) throws -> Data
    ) {
        self.byteCount = byteCount
        reader = read
    }

    public func read(offset: UInt64, maximumByteCount: Int) throws -> Data {
        guard maximumByteCount >= 0,
              offset <= byteCount else { throw BackupContainerError.invalidFormat }
        let bytes = try reader(offset, maximumByteCount)
        guard bytes.count <= maximumByteCount,
              UInt64(bytes.count) <= byteCount - offset else {
            throw BackupContainerError.invalidFormat
        }
        return bytes
    }
}

/// A sequential writer plus a read-back view of the exact bytes already
/// written. Production file sinks should expose the same opened descriptor.
public struct BackupContainerWriteSink: Sendable {
    private let writer: @Sendable (Data) throws -> Void
    private let sourceProvider: @Sendable () throws -> BackupContainerByteSource
    private let finalizedSourceProvider:
        @Sendable (BackupCheckpointID) async throws -> BackupContainerByteSource

    public init(
        write: @escaping @Sendable (Data) throws -> Void,
        readBackSource: @escaping @Sendable () throws -> BackupContainerByteSource,
        finalizeAndReadBackSource:
            (@Sendable (BackupCheckpointID) async throws -> BackupContainerByteSource)? = nil
    ) {
        writer = write
        sourceProvider = readBackSource
        finalizedSourceProvider = finalizeAndReadBackSource ?? { _ in
            try readBackSource()
        }
    }

    func write(_ bytes: Data) throws { try writer(bytes) }
    func readBackSource() throws -> BackupContainerByteSource { try sourceProvider() }
    func finalizedReadBackSource(
        checkpointID: BackupCheckpointID
    ) async throws -> BackupContainerByteSource {
        try await finalizedSourceProvider(checkpointID)
    }
}

public struct BackupContainerEntrySink: Sendable {
    public typealias Writer = @Sendable (Data) throws -> Void
    private let factory: @Sendable (BackupManifestEntry) throws -> Writer
    private let finisher: @Sendable (BackupManifestEntry) throws -> Void

    public init(
        _ factory: @escaping @Sendable (BackupManifestEntry) throws -> Writer,
        finish: @escaping @Sendable (BackupManifestEntry) throws -> Void = { _ in }
    ) {
        self.factory = factory
        finisher = finish
    }

    func writer(for entry: BackupManifestEntry) throws -> Writer { try factory(entry) }
    func finish(_ entry: BackupManifestEntry) throws { try finisher(entry) }
}

public struct EncryptedBackupContainerWriteResult: Sendable {
    public let checkpointID: BackupCheckpointID
    public let manifest: BackupManifest
    public let commitment: BackupCiphertextCommitment
    public let bodyByteCount: UInt64
    public let maximumBufferedPlaintextByteCount: Int
}

public struct EncryptedBackupContainerWriter: Sendable {
    private let randomBytes: @Sendable (Int) -> Data

    public init() {
        randomBytes = { count in
            var generator = SystemRandomNumberGenerator()
            return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        }
    }

    /// Test-only seam. It is internal and therefore unavailable to App composition.
    init(randomBytes: @escaping @Sendable (Int) -> Data) {
        self.randomBytes = randomBytes
    }

    public func write(
        entries: [BackupContainerEntrySource],
        revisionPair: BackupRevisionPair,
        sequence: UInt64,
        signer: BackupDeviceSigner,
        sink: BackupContainerWriteSink
    ) async throws -> EncryptedBackupContainerWriteResult {
        try Task.checkCancellation()
        guard sequence >= signer.authorization.sequenceFloor else {
            throw BackupContainerError.trustFailure
        }
        let ordered = entries.sorted { $0.path < $1.path }
        var manifestEntries: [BackupManifestEntry] = []
        manifestEntries.reserveCapacity(ordered.count)
        var nextFrame: UInt64 = 0
        for source in ordered {
            let frameCount = try Self.frameCount(for: source.plaintextByteCount)
            manifestEntries.append(try BackupManifestEntry(
                kind: source.kind,
                path: source.path,
                plaintextByteCount: source.plaintextByteCount,
                plaintextDigest: source.plaintextDigest,
                firstFrameIndex: nextFrame,
                frameCount: frameCount
            ))
            let advanced = nextFrame.addingReportingOverflow(UInt64(frameCount))
            guard !advanced.overflow else { throw BackupContainerError.arithmeticOverflow }
            nextFrame = advanced.partialValue
        }
        let manifest = try mapContractError {
            try BackupManifest(revisionPair: revisionPair, entries: manifestEntries)
        }
        guard nextFrame <= UInt64(UInt32.max),
              nextFrame <= UInt64(BackupFormatLimits.maximumFrameCount) else {
            throw BackupContainerError.resourceLimit
        }

        let checkpointID = try BackupCheckpointID(bytes: checkedRandom(count: 16))
        let noncePrefix = checkedRandom(count: 4)
        let dekBytes = checkedRandom(count: 32)
        let prologue = try BackupCheckpointPrologue(
            setID: signer.descriptor.setID,
            checkpointID: checkpointID,
            deviceID: signer.authorization.deviceID,
            authorizationID: signer.authorization.authorizationID,
            sequence: sequence
        )
        let descriptorDigest = BackupCrypto.digest(signer.descriptor.canonicalBytes)
        let authorizationDigest = BackupCrypto.digest(signer.authorization.canonicalBytes)
        let recipient = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: signer.descriptor.recoveryHPKEPublicKey
        )
        var hpkeSender = try HPKE.Sender(
            recipientKey: recipient,
            ciphersuite: .Curve25519_SHA256_ChachaPoly,
            info: BackupCrypto.hpkeInfo(descriptor: signer.descriptor, prologue: prologue)
        )
        let sealedDEK = try hpkeSender.seal(
            dekBytes,
            authenticating: BackupCrypto.hpkeAAD(
                descriptorDigest: descriptorDigest,
                authorizationDigest: authorizationDigest,
                prologue: prologue
            )
        )
        let envelope = try BackupHPKEEnvelope(
            encapsulatedKey: hpkeSender.encapsulatedKey,
            sealedKey: sealedDEK
        )
        let envelopeDigest = BackupCrypto.digest(envelope.canonicalBytes)
        let manifestBytes = manifest.canonicalBytes
        guard manifestBytes.count <= BackupFormatLimits.maximumCanonicalManifestByteCount,
              manifestBytes.count <= Int(UInt32.max) else {
            throw BackupContainerError.resourceLimit
        }
        let dek = SymmetricKey(data: dekBytes)
        let manifestBox = try AES.GCM.seal(
            manifestBytes,
            using: dek,
            nonce: BackupCrypto.nonce(prefix: noncePrefix, counter: 0).cryptoKitNonce,
            authenticating: BackupCrypto.manifestAAD(
                descriptorDigest: descriptorDigest,
                authorizationDigest: authorizationDigest,
                envelopeDigest: envelopeDigest,
                prologue: prologue
            )
        )

        let body = ContainerBodyWriter(sink: sink)
        try body.append(ContainerFormat.header(
            frameCount: UInt32(nextFrame),
            manifestPlaintextByteCount: UInt32(manifestBytes.count),
            descriptorByteCount: signer.descriptor.canonicalBytes.count,
            authorizationByteCount: signer.authorization.canonicalBytes.count,
            prologueByteCount: prologue.canonicalBytes.count,
            envelopeByteCount: envelope.canonicalBytes.count,
            noncePrefix: noncePrefix
        ))
        try body.append(signer.descriptor.canonicalBytes)
        try body.append(signer.authorization.canonicalBytes)
        try body.append(prologue.canonicalBytes)
        try body.append(envelope.canonicalBytes)
        try body.append(manifestBox.ciphertext)
        try body.append(manifestBox.tag)

        var globalFrameIndex: UInt64 = 0
        var maximumBuffered = 0
        for source in ordered {
            let opened: BackupContainerOpenedEntrySource
            do {
                opened = try await source.open()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw BackupContainerError.sourceIntegrityFailure
            }
            defer { opened.close() }
            var offset: UInt64 = 0
            var sourceHasher = SHA256()
            let expectedFrames = try Self.frameCount(for: source.plaintextByteCount)
            for _ in 0..<expectedFrames {
                try Task.checkCancellation()
                let remaining = source.plaintextByteCount - offset
                let requested = Int(min(
                    UInt64(BackupFormatLimits.maximumFramePlaintextByteCount),
                    remaining
                ))
                let plaintext: Data
                do {
                    plaintext = try opened.read(
                        offset: offset,
                        maximumByteCount: requested
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw BackupContainerError.sourceIntegrityFailure
                }
                guard plaintext.count == requested else {
                    throw BackupContainerError.sourceIntegrityFailure
                }
                maximumBuffered = max(maximumBuffered, plaintext.count)
                sourceHasher.update(data: plaintext)
                let counter = try BackupCrypto.payloadCounter(frameIndex: globalFrameIndex)
                let sealed = try AES.GCM.seal(
                    plaintext,
                    using: dek,
                    nonce: BackupCrypto.nonce(prefix: noncePrefix, counter: counter).cryptoKitNonce,
                    authenticating: BackupCrypto.frameAAD(
                        prologue: prologue,
                        frameIndex: globalFrameIndex,
                        plaintextByteCount: plaintext.count
                    )
                )
                try body.append(ContainerFormat.frameHeader(
                    index: globalFrameIndex,
                    plaintextByteCount: plaintext.count,
                    ciphertextByteCount: sealed.ciphertext.count
                ))
                try body.append(sealed.ciphertext)
                try body.append(sealed.tag)
                offset += UInt64(plaintext.count)
                let advanced = globalFrameIndex.addingReportingOverflow(1)
                guard !advanced.overflow else { throw BackupContainerError.counterOverflow }
                globalFrameIndex = advanced.partialValue
            }
            let trailing: Data
            do {
                trailing = try opened.read(offset: offset, maximumByteCount: 1)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw BackupContainerError.sourceIntegrityFailure
            }
            guard offset == source.plaintextByteCount,
                  trailing.isEmpty,
                  Data(sourceHasher.finalize()) == source.plaintextDigest else {
                throw BackupContainerError.sourceIntegrityFailure
            }
        }
        guard globalFrameIndex == nextFrame else { throw BackupContainerError.graphInvalid }

        let bodyByteCount = body.byteCount
        let commitment = try BackupCiphertextCommitment(
            digest: body.finalizeDigest(),
            ciphertextByteCount: bodyByteCount
        )

        // Read back the exact bytes already emitted and decrypt every frame with
        // the still-transient DEK before the signed commit footer exists.
        let readBack = try sink.readBackSource()
        guard readBack.byteCount == bodyByteCount else { throw BackupContainerError.outputFailure }
        try BackupContainerParser.verifyUnsignedBody(
            source: readBack,
            expectedCommitment: commitment,
            expectedManifest: manifest,
            expectedDescriptor: signer.descriptor,
            expectedAuthorization: signer.authorization,
            expectedPrologue: prologue,
            expectedEnvelope: envelope,
            dek: dek
        )

        let unsignedFooter = try BackupCheckpointFooter(
            descriptorDigest: descriptorDigest,
            authorizationDigest: authorizationDigest,
            prologueDigest: BackupCrypto.digest(prologue.canonicalBytes),
            envelopeDigest: envelopeDigest,
            commitment: commitment,
            deviceSignature: Data(repeating: 0, count: 64)
        )
        let signature = try signer.signature(for: unsignedFooter.signatureTranscript.canonicalBytes)
        let footer = try BackupCheckpointFooter(
            descriptorDigest: descriptorDigest,
            authorizationDigest: authorizationDigest,
            prologueDigest: BackupCrypto.digest(prologue.canonicalBytes),
            envelopeDigest: envelopeDigest,
            commitment: commitment,
            deviceSignature: signature
        )
        var footerPrefix = Data()
        ContainerFormat.append(UInt32(footer.canonicalBytes.count), to: &footerPrefix)
        try rawWrite(footerPrefix, to: sink)
        try rawWrite(footer.canonicalBytes, to: sink)

        // The production sink publishes here, while the transient DEK is
        // still available. Its returned source must describe the exact opened
        // final inode, not a later path lookup.
        let finalizedSource = try await sink.finalizedReadBackSource(
            checkpointID: checkpointID
        )
        let parsedFinal = try BackupContainerParser.parse(source: finalizedSource)
        let publicFinal = try BackupTrustVerifier.verify(
            parsed: parsedFinal,
            trustedDescriptor: signer.descriptor
        )
        let privateManifest = try BackupContainerReader.decrypt(
            parsed: parsedFinal,
            dek: dek,
            sink: BackupContainerEntrySink { _ in { _ in } }
        )
        guard publicFinal.checkpoint.checkpointID == checkpointID,
              publicFinal.checkpoint.commitment == commitment,
              privateManifest == manifest else {
            throw BackupContainerError.outputFailure
        }
        return EncryptedBackupContainerWriteResult(
            checkpointID: checkpointID,
            manifest: manifest,
            commitment: commitment,
            bodyByteCount: bodyByteCount,
            maximumBufferedPlaintextByteCount: min(
                maximumBuffered,
                BackupFormatLimits.maximumFramePlaintextByteCount
            )
        )
    }

    private func checkedRandom(count: Int) -> Data {
        let value = randomBytes(count)
        if value.count == count { return value }
        preconditionFailure("Backup random source returned an invalid length")
    }

    private static func frameCount(for byteCount: UInt64) throws -> UInt32 {
        guard byteCount <= BackupFormatLimits.maximumPlaintextByteCount else {
            throw BackupContainerError.resourceLimit
        }
        if byteCount == 0 { return 1 }
        let chunk = UInt64(BackupFormatLimits.maximumFramePlaintextByteCount)
        let adjusted = byteCount.addingReportingOverflow(chunk - 1)
        guard !adjusted.overflow else { throw BackupContainerError.arithmeticOverflow }
        let count = adjusted.partialValue / chunk
        guard count <= UInt64(UInt32.max),
              count <= UInt64(BackupFormatLimits.maximumFrameCount) else {
            throw BackupContainerError.resourceLimit
        }
        return UInt32(count)
    }
}

private final class ContainerBodyWriter {
    private let sink: BackupContainerWriteSink
    private var hasher = SHA256()
    private(set) var byteCount: UInt64 = 0

    init(sink: BackupContainerWriteSink) {
        self.sink = sink
        hasher.update(data: BackupCrypto.commitmentDomain)
    }

    func append(_ bytes: Data) throws {
        let next = byteCount.addingReportingOverflow(UInt64(bytes.count))
        guard !next.overflow else { throw BackupContainerError.arithmeticOverflow }
        do { try sink.write(bytes) } catch is CancellationError { throw CancellationError() }
        catch { throw BackupContainerError.outputFailure }
        hasher.update(data: bytes)
        byteCount = next.partialValue
    }

    func finalizeDigest() -> Data { Data(hasher.finalize()) }
}

private func rawWrite(_ bytes: Data, to sink: BackupContainerWriteSink) throws {
    do { try sink.write(bytes) } catch is CancellationError { throw CancellationError() }
    catch { throw BackupContainerError.outputFailure }
}

func mapContractError<T>(_ body: () throws -> T) throws -> T {
    do { return try body() }
    catch BackupContractError.unsupportedVersion { throw BackupContainerError.unsupportedVersion }
    catch BackupContractError.unsupportedSuite { throw BackupContainerError.unsupportedSuite }
    catch BackupContractError.resourceLimit { throw BackupContainerError.resourceLimit }
    catch BackupContractError.arithmeticOverflow { throw BackupContainerError.arithmeticOverflow }
    catch { throw BackupContainerError.invalidFormat }
}

enum ContainerFormat {
    static let magic = Data("KLGCNT01".utf8)
    static let frameMagic = Data("FRM1".utf8)
    static let fixedHeaderByteCount = 48
    static let frameHeaderByteCount = 20
    static let authenticationTagByteCount = 16
    static let maximumDescriptorByteCount = 256
    static let maximumAuthorizationByteCount = 320
    static let maximumPrologueByteCount = 160
    static let maximumEnvelopeByteCount = 1_024
    static let maximumFooterByteCount = 512

    static func header(
        frameCount: UInt32,
        manifestPlaintextByteCount: UInt32,
        descriptorByteCount: Int,
        authorizationByteCount: Int,
        prologueByteCount: Int,
        envelopeByteCount: Int,
        noncePrefix: Data
    ) -> Data {
        var data = magic
        append(UInt16(1), to: &data)
        append(UInt16(0), to: &data)
        append(UInt16(0), to: &data)
        append(BackupCryptoSuite.v1.rawValue, to: &data)
        append(UInt32(BackupFormatLimits.maximumFramePlaintextByteCount), to: &data)
        append(frameCount, to: &data)
        append(manifestPlaintextByteCount, to: &data)
        append(UInt32(descriptorByteCount), to: &data)
        append(UInt32(authorizationByteCount), to: &data)
        append(UInt32(prologueByteCount), to: &data)
        append(UInt32(envelopeByteCount), to: &data)
        data.append(noncePrefix)
        precondition(data.count == fixedHeaderByteCount)
        return data
    }

    static func frameHeader(index: UInt64, plaintextByteCount: Int, ciphertextByteCount: Int) -> Data {
        var data = frameMagic
        append(index, to: &data)
        append(UInt32(plaintextByteCount), to: &data)
        append(UInt32(ciphertextByteCount), to: &data)
        precondition(data.count == frameHeaderByteCount)
        return data
    }

    static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var encoded = value.bigEndian
        withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
    }
}

struct BackupContainerPublicHeader: Sendable {
    let checkpointID: BackupCheckpointID
    let noncePrefix: Data
}

enum BackupContainerTestInspector {
    static func publicHeader(in data: Data) throws -> BackupContainerPublicHeader {
        let source = BackupContainerByteSource(byteCount: UInt64(data.count)) { offset, count in
            let start = Int(offset)
            return Data(data[start..<min(data.count, start + count)])
        }
        let header = try BackupContainerParser.readHeader(source: source)
        let descriptorEnd = ContainerFormat.fixedHeaderByteCount + header.descriptorByteCount
        let authorizationEnd = descriptorEnd + header.authorizationByteCount
        let prologueEnd = authorizationEnd + header.prologueByteCount
        let prologue = try BackupCheckpointPrologue.decodeCanonical(
            Data(data[authorizationEnd..<prologueEnd])
        )
        return .init(checkpointID: prologue.checkpointID, noncePrefix: header.noncePrefix)
    }

    static func frameRanges(in data: Data) throws -> [Range<Int>] {
        let source = BackupContainerByteSource(byteCount: UInt64(data.count)) { offset, count in
            let start = Int(offset)
            return Data(data[start..<min(data.count, start + count)])
        }
        return try BackupContainerParser.parse(source: source).frames.map {
            Int($0.headerOffset)..<Int($0.tagOffset + UInt64(ContainerFormat.authenticationTagByteCount))
        }
    }
}
