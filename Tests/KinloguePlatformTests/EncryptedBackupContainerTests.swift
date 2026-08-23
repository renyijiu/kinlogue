import CryptoKit
import Foundation
import KinlogueCore
import Testing
@testable import KinloguePlatform

@Test(arguments: [0, 1, 256 * 1_024 - 1, 256 * 1_024, 256 * 1_024 + 1, 3 * 256 * 1_024 + 17])
func encryptedContainerRoundTripsBoundaries(_ payloadByteCount: Int) async throws {
    let fixture = try ContainerFixture(payloadByteCount: payloadByteCount)
    let output = LockedBytes()
    let result = try await fixture.writer.write(
        entries: fixture.sources,
        revisionPair: fixture.revisionPair,
        sequence: 9,
        signer: fixture.signer,
        sink: .init(write: { output.append($0) }, readBackSource: output.source)
    )

    let source = output.source()
    let publicResult = try BackupTrustVerifier().verify(
        source: source,
        trustedDescriptor: fixture.enrollment.descriptor
    )
    #expect(publicResult.checkpoint.checkpointID == result.checkpointID)
    #expect(publicResult.checkpoint.sequence == 9)
    #expect(output.data.range(of: Data("objects/payload.bin".utf8)) == nil)

    let restored = LockedEntries()
    let read = try BackupContainerReader().read(
        source: source,
        recoverySeed: fixture.recoverySeed,
        sink: restored.sink
    )
    #expect(read.manifest.revisionPair == fixture.revisionPair)
    #expect(restored.value(for: "objects/payload.bin") == fixture.payload)
    #expect(restored.value(for: "library.json") == Data())
    #expect(restored.value(for: "lan-inbox/inbox.json") == Data([0x7B, 0x7D]))
    #expect(result.maximumBufferedPlaintextByteCount <= BackupFormatLimits.maximumFramePlaintextByteCount)
}

@Test
func encryptedContainerFinishesEachEntryBeforeOpeningTheNext() async throws {
    let fixture = try ContainerFixture(payloadByteCount: 700_000)
    let output = LockedBytes()
    _ = try await fixture.writer.write(
        entries: fixture.sources,
        revisionPair: fixture.revisionPair,
        sequence: 9,
        signer: fixture.signer,
        sink: .init(write: { output.append($0) }, readBackSource: output.source)
    )

    let restored = LockedEntryLifecycle()
    let result = try BackupContainerReader().read(
        source: output.source(),
        recoverySeed: fixture.recoverySeed,
        sink: restored.sink
    )

    #expect(restored.maximumActiveEntryCount == 1)
    #expect(restored.finishedPaths == result.manifest.entries.map(\.path))
}

@Test
func publicVerifierHasNoDecryptionCapabilityAndWrongSeedFails() async throws {
    let fixture = try ContainerFixture(payloadByteCount: 400_000)
    let output = LockedBytes()
    _ = try await fixture.writer.write(
        entries: fixture.sources,
        revisionPair: fixture.revisionPair,
        sequence: 1,
        signer: fixture.signer,
        sink: .init(write: { output.append($0) }, readBackSource: output.source)
    )
    let source = output.source()

    _ = try BackupTrustVerifier().verify(
        source: source,
        trustedDescriptor: fixture.enrollment.descriptor
    )
    let discarded = LockedEntries()
    #expect(throws: BackupContainerError.authenticationFailed) {
        _ = try BackupContainerReader().read(
            source: source,
            recoverySeed: Data(repeating: 0xEE, count: 32),
            sink: discarded.sink
        )
    }

    let other = try ContainerFixture(payloadByteCount: 1)
    #expect(throws: BackupContainerError.trustFailure) {
        _ = try BackupTrustVerifier().verify(
            source: source,
            trustedDescriptor: other.enrollment.descriptor
        )
    }
}

@Test(arguments: ["body-bit-flip", "footer-bit-flip", "truncate", "trailing", "frame-splice", "unknown-version", "unknown-suite", "oversize-length"])
func encryptedContainerRejectsMalformedOrTamperedBytes(_ mutation: String) async throws {
    let fixture = try ContainerFixture(payloadByteCount: 700_000)
    let output = LockedBytes()
    _ = try await fixture.writer.write(
        entries: fixture.sources,
        revisionPair: fixture.revisionPair,
        sequence: 1,
        signer: fixture.signer,
        sink: .init(write: { output.append($0) }, readBackSource: output.source)
    )
    var bytes = output.data
    switch mutation {
    case "body-bit-flip":
        bytes[bytes.count / 2] ^= 0x80
    case "footer-bit-flip":
        bytes[bytes.count - 1] ^= 0x80
    case "truncate":
        bytes.removeLast()
    case "trailing":
        bytes.append(0)
    case "frame-splice":
        let frames = try BackupContainerTestInspector.frameRanges(in: bytes)
        #expect(frames.count >= 2)
        bytes.replaceSubrange(frames[1], with: bytes[frames[0]])
    case "unknown-suite":
        bytes.replaceSubrange(14..<16, with: [0xFF, 0xFF])
    case "unknown-version":
        bytes.replaceSubrange(8..<10, with: [0xFF, 0xFF])
    case "oversize-length":
        bytes.replaceSubrange(24..<28, with: [0xFF, 0xFF, 0xFF, 0xFF])
    default:
        Issue.record("unknown mutation")
    }

    #expect(throws: BackupContainerError.self) {
        _ = try BackupTrustVerifier().verify(
            source: LockedBytes(bytes).source(),
            trustedDescriptor: fixture.enrollment.descriptor
        )
    }
}

@Test
func cancellationRetryNeverReusesCheckpointOrNoncePrefix() async throws {
    let fixture = try ContainerFixture(payloadByteCount: 600_000)
    let firstOutput = LockedBytes()
    let task = Task {
        try await fixture.writer.write(
            entries: fixture.sources.map { source in
                source.withRead { offset, maximum in
                    if source.path == "objects/payload.bin", offset >= UInt64(256 * 1_024) {
                        throw CancellationError()
                    }
                    return try source.read(offset: offset, maximumByteCount: maximum)
                }
            },
            revisionPair: fixture.revisionPair,
            sequence: 1,
            signer: fixture.signer,
            sink: .init(write: { firstOutput.append($0) }, readBackSource: firstOutput.source)
        )
    }
    await #expect(throws: CancellationError.self) { _ = try await task.value }

    let secondOutput = LockedBytes()
    let retry = try await fixture.writer.write(
        entries: fixture.sources,
        revisionPair: fixture.revisionPair,
        sequence: 1,
        signer: fixture.signer,
        sink: .init(write: { secondOutput.append($0) }, readBackSource: secondOutput.source)
    )
    let abandoned = try BackupContainerTestInspector.publicHeader(in: firstOutput.data)
    let completed = try BackupContainerTestInspector.publicHeader(in: secondOutput.data)
    #expect(abandoned.checkpointID != retry.checkpointID)
    #expect(abandoned.checkpointID != completed.checkpointID)
    #expect(abandoned.noncePrefix != completed.noncePrefix)
}

@Test
func semanticGoldenVectorFreezesCanonicalAadAndCommitmentDomains() throws {
    let prologue = try BackupCheckpointPrologue(
        setID: .init(bytes: Data((1...16).map(UInt8.init))),
        checkpointID: .init(bytes: Data((17...32).map(UInt8.init))),
        deviceID: .init(bytes: Data((33...48).map(UInt8.init))),
        authorizationID: .init(bytes: Data((49...64).map(UInt8.init))),
        sequence: 0x0102_0304_0506_0708
    )
    let descriptor = try BackupSetDescriptor(
        setID: prologue.setID,
        recoverySigningPublicKey: Data(repeating: 0x81, count: 32),
        recoveryHPKEPublicKey: Data(repeating: 0x82, count: 32),
        rootSignature: Data(repeating: 0x83, count: 64)
    )
    let vector = try BackupCrypto.semanticVector(
        prologue: prologue,
        descriptor: descriptor,
        authorizationDigest: Data(repeating: 0xB2, count: 32),
        envelopeDigest: Data(repeating: 0xC3, count: 32),
        frameIndex: 7,
        plaintextByteCount: 123
    )

    #expect(vector.hpkeInfoSHA256.hex == "4ca7f050df77610cd3d4d5e7cd5a29f7bab3748b92c067a595ef320629a23f67")
    #expect(vector.hpkeAADSHA256.hex == "a8aadefd4c328645f35eb1a9588c7ebd98a6d095a893175fcd6acf752b30e4d2")
    #expect(vector.frameAADSHA256.hex == "9383d12c3a77cdbdffbec36d256a2c7c2f18c5d0d60978cd8d593a9202a65df1")
    #expect(vector.commitmentDomainSHA256.hex == "86a2ebd8a5f65f7eb4e2a32a0e28160e6066c574c7cb80ecebafaa12e2207861")
}

private struct ContainerFixture {
    let recoverySeed = Data((1...32).map(UInt8.init))
    let enrollment: BackupEnrollmentMaterial
    let signer: BackupDeviceSigner
    let revisionPair: BackupRevisionPair
    let payload: Data
    let sources: [BackupContainerEntrySource]
    let writer = EncryptedBackupContainerWriter()

    init(payloadByteCount: Int) throws {
        enrollment = try BackupKeyHierarchy.makeEnrollment(
            recoverySeed: recoverySeed,
            setID: .init(bytes: Data((33...48).map(UInt8.init))),
            deviceSigningSeed: Data((65...96).map(UInt8.init)),
            deviceID: .init(bytes: Data((97...112).map(UInt8.init))),
            authorizationID: .init(bytes: Data((113...128).map(UInt8.init))),
            writerEpoch: .init(bytes: Data((129...144).map(UInt8.init)))
        )
        signer = try BackupDeviceSigner(
            descriptor: enrollment.descriptor,
            authorization: enrollment.authorization,
            deviceSigningSeed: enrollment.deviceSigningSeed
        )
        revisionPair = try .init(
            vault: .init(generation: 1, commitID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, manifestDigest: Data(repeating: 1, count: 32)),
            lanInbox: .init(generation: 2, commitID: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!, manifestDigest: Data(repeating: 2, count: 32))
        )
        payload = Data((0..<payloadByteCount).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        sources = [
            Self.source(kind: .vaultCatalog, path: "library.json", bytes: Data()),
            Self.source(kind: .lanInboxManifest, path: "lan-inbox/inbox.json", bytes: Data([0x7B, 0x7D])),
            Self.source(kind: .vaultObject, path: "objects/payload.bin", bytes: payload),
        ]
    }

    private static func source(kind: BackupManifestEntry.Kind, path: String, bytes: Data) -> BackupContainerEntrySource {
        BackupContainerEntrySource(
            kind: kind,
            path: path,
            plaintextByteCount: UInt64(bytes.count),
            plaintextDigest: Data(SHA256.hash(data: bytes))
        ) { offset, maximum in
            guard offset <= UInt64(bytes.count) else { return Data() }
            let start = Int(offset)
            let end = min(bytes.count, start + maximum)
            return Data(bytes[start..<end])
        }
    }
}

private final class LockedBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Data
    init(_ data: Data = Data()) { storage = data }
    var data: Data { lock.withLock { storage } }
    func append(_ bytes: Data) { lock.withLock { storage.append(bytes) } }
    func source() -> BackupContainerByteSource {
        let snapshot = data
        return .init(byteCount: UInt64(snapshot.count)) { offset, count in
            guard offset <= UInt64(snapshot.count) else { return Data() }
            let start = Int(offset)
            let end = min(snapshot.count, start + count)
            return Data(snapshot[start..<end])
        }
    }
}

private final class LockedEntries: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    lazy var sink = BackupContainerEntrySink { [weak self] entry in
        { [weak self] bytes in self?.lock.withLock { self?.values[entry.path, default: Data()].append(bytes) } }
    }
    func value(for path: String) -> Data? { lock.withLock { values[path] } }
}

private final class LockedEntryLifecycle: @unchecked Sendable {
    private let lock = NSLock()
    private var activePath: String?
    private var maximumActive = 0
    private var finished: [String] = []

    lazy var sink = BackupContainerEntrySink({ [weak self] entry in
        guard let self else { throw BackupContainerError.outputFailure }
        try lock.withLock {
            guard activePath == nil else { throw BackupContainerError.outputFailure }
            activePath = entry.path
            maximumActive = max(maximumActive, 1)
        }
        return { _ in }
    }, finish: { [weak self] entry in
        guard let self else { throw BackupContainerError.outputFailure }
        try lock.withLock {
            guard activePath == entry.path else { throw BackupContainerError.outputFailure }
            activePath = nil
            finished.append(entry.path)
        }
    })

    var maximumActiveEntryCount: Int { lock.withLock { maximumActive } }
    var finishedPaths: [String] { lock.withLock { finished } }
}

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
