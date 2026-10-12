import Foundation
import Testing
@testable import KinlogueCore

@Test
func checkpointPrologueHasStableStrictCanonicalBytes() throws {
    let prologue = try sampleBackupPrologue()
    let bytes = prologue.canonicalBytes

    #expect(try BackupCheckpointPrologue.decodeCanonical(bytes) == prologue)
    #expect(try sampleBackupPrologue().canonicalBytes == bytes)
    #expect(throws: BackupContractError.self) {
        _ = try BackupCheckpointPrologue.decodeCanonical(bytes + Data([0]))
    }

    var wrongMagic = bytes
    wrongMagic[0] ^= 0xFF
    #expect(throws: BackupContractError.self) {
        _ = try BackupCheckpointPrologue.decodeCanonical(wrongMagic)
    }

    var unknownSuite = bytes
    unknownSuite.replaceSubrange(14..<16, with: [0xFF, 0xFF])
    #expect(throws: BackupContractError.self) {
        _ = try BackupCheckpointPrologue.decodeCanonical(unknownSuite)
    }

    var unknownMajor = bytes
    unknownMajor.replaceSubrange(8..<10, with: [0, 2])
    #expect(throws: BackupContractError.self) {
        _ = try BackupCheckpointPrologue.decodeCanonical(unknownMajor)
    }
}

@Test
func manifestCanonicalizesEntryOrderAndRoundTripsExactly() throws {
    let pair = try sampleRevisionPair()
    let entries = try sampleManifestEntries()
    let forward = try BackupManifest(revisionPair: pair, entries: entries)
    let reversed = try BackupManifest(revisionPair: pair, entries: entries.reversed())

    #expect(forward.entries.map(\.path) == forward.entries.map(\.path).sorted())
    #expect(forward.canonicalBytes == reversed.canonicalBytes)
    #expect(try BackupManifest.decodeCanonical(forward.canonicalBytes) == forward)
    #expect(forward.entryCount == entries.count)
    #expect(forward.totalPlaintextByteCount == UInt64(entries.reduce(0) { $0 + $1.plaintextByteCount }))
    #expect(forward.totalFrameCount == UInt64(entries.reduce(0) { $0 + Int($1.frameCount) }))
}

@Test
func manifestRejectsMalformedNonCanonicalAndUnboundedInputs() throws {
    let pair = try sampleRevisionPair()
    let entries = try sampleManifestEntries()
    let manifest = try BackupManifest(revisionPair: pair, entries: entries)

    #expect(throws: BackupContractError.self) {
        _ = try BackupManifest.decodeCanonical(Data(manifest.canonicalBytes.dropLast()))
    }
    #expect(throws: BackupContractError.self) {
        _ = try BackupManifest.decodeCanonical(manifest.canonicalBytes + Data([0]))
    }

    var maliciousCount = manifest.canonicalBytes
    maliciousCount.replaceSubrange(128..<132, with: [0xFF, 0xFF, 0xFF, 0xFF])
    #expect(throws: BackupContractError.self) {
        _ = try BackupManifest.decodeCanonical(maliciousCount)
    }
    #expect(throws: BackupContractError.self) {
        _ = try BackupManifestEntry(
            kind: .vaultObject,
            path: "objects/../library.json",
            plaintextByteCount: 1,
            plaintextDigest: digest(9),
            firstFrameIndex: 0,
            frameCount: 1
        )
    }
    #expect(throws: BackupContractError.self) {
        _ = try BackupManifest(
            revisionPair: pair,
            entries: Array(
                repeating: entries[0],
                count: BackupFormatLimits.maximumEntryCount + 1
            )
        )
    }

    let tooLarge = try BackupManifestEntry(
        kind: .vaultObject,
        path: "objects/large-a",
        plaintextByteCount: BackupFormatLimits.maximumPlaintextByteCount,
        plaintextDigest: digest(10),
        firstFrameIndex: 0,
        frameCount: 1
    )
    let additional = try BackupManifestEntry(
        kind: .vaultObject,
        path: "objects/large-b",
        plaintextByteCount: 1,
        plaintextDigest: digest(11),
        firstFrameIndex: 1,
        frameCount: 1
    )
    #expect(throws: BackupContractError.self) {
        _ = try BackupManifest(revisionPair: pair, entries: [tooLarge, additional])
    }
}

@Test
func manifestDecoderRejectsUnknownEntryKindAndNonCanonicalOrdering() throws {
    let manifest = try BackupManifest(
        revisionPair: sampleRevisionPair(),
        entries: sampleManifestEntries()
    )
    let firstObject = try #require(manifest.entries.first(where: { $0.path == "objects/aa" }))
    let secondObject = try #require(manifest.entries.first(where: { $0.path == "objects/bb" }))
    let firstBytes = firstObject.canonicalBytes
    let secondBytes = secondObject.canonicalBytes
    #expect(firstBytes.count == secondBytes.count)

    var unordered = manifest.canonicalBytes
    let firstRange = try #require(unordered.range(of: firstBytes))
    let secondRange = try #require(unordered.range(of: secondBytes))
    unordered.replaceSubrange(secondRange, with: firstBytes)
    unordered.replaceSubrange(firstRange, with: secondBytes)
    #expect(throws: BackupContractError.self) {
        _ = try BackupManifest.decodeCanonical(unordered)
    }

    var unknownKind = manifest.canonicalBytes
    let entryRange = try #require(unknownKind.range(of: firstBytes))
    unknownKind[entryRange.lowerBound + 4] = 0xFF
    #expect(throws: BackupContractError.self) {
        _ = try BackupManifest.decodeCanonical(unknownKind)
    }
}

@Test
func formatLimitsRetainOperationalBudgetsAndExpandCapacity() {
    #expect(BackupFormatLimits.maximumEntryCount == 30_002)
    #expect(BackupFormatLimits.maximumPlaintextByteCount >= 10 * 1_024 * 1_024 * 1_024)
    #expect(BackupFormatLimits.maximumFramePlaintextByteCount == 256 * 1_024)
    #expect(BackupFormatLimits.maximumBackupDuration == 15 * 60)
    #expect(BackupFormatLimits.maximumRestoreDuration == 15 * 60)
    #expect(BackupFormatLimits.maximumPeakMemoryDeltaByteCount == 96 * 1_024 * 1_024)
    #expect(BackupFormatLimits.maximumOpenFileCount == 64)
}

private func sampleBackupPrologue() throws -> BackupCheckpointPrologue {
    try BackupCheckpointPrologue(
        setID: .init(bytes: idBytes(1)),
        checkpointID: .init(bytes: idBytes(2)),
        deviceID: .init(bytes: idBytes(3)),
        authorizationID: .init(bytes: idBytes(4)),
        sequence: 42
    )
}

private func sampleRevisionPair() throws -> BackupRevisionPair {
    try BackupRevisionPair(
        vault: .init(
            generation: 7,
            commitID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            manifestDigest: digest(1)
        ),
        lanInbox: .init(
            generation: 8,
            commitID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            manifestDigest: digest(2)
        )
    )
}

private func sampleManifestEntries() throws -> [BackupManifestEntry] {
    try [
        .init(kind: .vaultCatalog, path: "library.json", plaintextByteCount: 10, plaintextDigest: digest(1), firstFrameIndex: 1, frameCount: 1),
        .init(kind: .lanInboxManifest, path: "lan-inbox/inbox.json", plaintextByteCount: 20, plaintextDigest: digest(2), firstFrameIndex: 0, frameCount: 1),
        .init(kind: .vaultObject, path: "objects/aa", plaintextByteCount: 30, plaintextDigest: digest(3), firstFrameIndex: 2, frameCount: 1),
        .init(kind: .vaultObject, path: "objects/bb", plaintextByteCount: 40, plaintextDigest: digest(4), firstFrameIndex: 3, frameCount: 1),
    ]
}

private func digest(_ byte: UInt8) -> Data { Data(repeating: byte, count: 32) }
private func idBytes(_ byte: UInt8) -> Data { Data(repeating: byte, count: 16) }

@Test
func capacityManifestVersionsKeepLegacyLimitsAndAcceptLargeSnapshots() throws {
    let legacy = try BackupFormatVersion(major: 1, minor: 0, minimumReaderMinor: 0)
    let expanded = try BackupFormatVersion(major: 1, minor: 1, minimumReaderMinor: 1)
    var entries = try sampleManifestEntries().filter { $0.kind != .vaultObject }
    let size: UInt64 = 100 * 1_024 * 1_024
    for index in 0..<100 {
        entries.append(try BackupManifestEntry(
            kind: .vaultObject, path: String(format: "objects/%05d", index),
            plaintextByteCount: size, plaintextDigest: digest(3),
            firstFrameIndex: 2 + UInt64(index * 400), frameCount: 400
        ))
    }
    let manifest = try BackupManifest(formatVersion: expanded, revisionPair: sampleRevisionPair(), entries: entries)
    #expect(manifest.totalPlaintextByteCount > 9 * 1_024 * 1_024 * 1_024)
    #expect(manifest.totalFrameCount > 30_000)
    #expect(try BackupManifest.decodeCanonical(manifest.canonicalBytes) == manifest)
    #expect(throws: BackupContractError.resourceLimit) {
        _ = try BackupManifest(formatVersion: legacy, revisionPair: sampleRevisionPair(), entries: entries)
    }
}

@Test
func capacityManifestIncludesVaultAndDurableInboxBeyondLegacyEntryLimit() throws {
    let expanded = try BackupFormatVersion(major: 1, minor: 1, minimumReaderMinor: 1)
    var entries = try sampleManifestEntries().filter { $0.kind != .vaultObject }
    for index in 0..<20_001 {
        entries.append(try BackupManifestEntry(
            kind: .vaultObject, path: String(format: "objects/%05d", index),
            plaintextByteCount: 0, plaintextDigest: digest(3),
            firstFrameIndex: UInt64(index + 2), frameCount: 1
        ))
    }
    let manifest = try BackupManifest(formatVersion: expanded, revisionPair: sampleRevisionPair(), entries: entries)
    #expect(manifest.entryCount == 20_003)
    #expect(try BackupManifest.decodeCanonical(manifest.canonicalBytes) == manifest)
    #expect(throws: BackupContractError.resourceLimit) {
        _ = try BackupManifest(formatVersion: .init(major: 1, minor: 0, minimumReaderMinor: 0), revisionPair: sampleRevisionPair(), entries: entries)
    }
}

@Test
func capacityBudgetCountsFrameRoundingAndCiphertextOverhead() throws {
    #expect(try BackupManifestEntry.requiredFrameCount(for: 0) == 1)
    #expect(try BackupManifestEntry.requiredFrameCount(for: 256 * 1_024 + 1) == 2)
    #expect(try BackupManifestEntry.requiredFrameCount(for: BackupFormatLimits.maximumPlaintextByteCount)
        == UInt32(BackupFormatLimits.maximumFrameCount))
    #expect(throws: BackupContractError.resourceLimit) {
        _ = try BackupManifestEntry.requiredFrameCount(for: UInt64.max)
    }
    #expect(throws: BackupContractError.resourceLimit) {
        _ = try BackupManifestEntry(
            kind: .vaultObject, path: "objects/counter-overflow", plaintextByteCount: 1,
            plaintextDigest: digest(3), firstFrameIndex: UInt64.max, frameCount: 1
        )
    }
    #expect(throws: BackupContractError.resourceLimit) {
        _ = try BackupManifestEntry(
            kind: .vaultObject, path: "objects/rounding-over-limit", plaintextByteCount: 1,
            plaintextDigest: digest(3),
            firstFrameIndex: UInt64(BackupFormatLimits.maximumFrameCount), frameCount: 1
        )
    }
    #expect(throws: BackupContractError.resourceLimit) {
        _ = try BackupFormatLimits.containerByteCount(plaintextByteCount: UInt64.max, frameCount: 1, manifestByteCount: 1)
    }
    #expect(throws: BackupContractError.resourceLimit) {
        _ = try BackupFormatLimits.containerByteCount(plaintextByteCount: 0, frameCount: UInt64.max, manifestByteCount: 1)
    }
    let manifest = try BackupManifest(revisionPair: sampleRevisionPair(), entries: sampleManifestEntries())
    #expect(manifest.maximumContainerByteCount == manifest.totalPlaintextByteCount
        + manifest.totalFrameCount * 36 + UInt64(manifest.canonicalBytes.count) + 4_096)
    let upper = try BackupFormatLimits.containerByteCount(
        plaintextByteCount: BackupFormatLimits.maximumPlaintextByteCount,
        frameCount: UInt64(BackupFormatLimits.maximumFrameCount),
        manifestByteCount: BackupFormatLimits.maximumCanonicalManifestByteCount
    )
    #expect(upper == BackupFormatLimits.maximumContainerByteCount(for: .current))
    #expect(upper - BackupFormatLimits.maximumPlaintextByteCount > BackupFormatLimits.targetFormatAllowanceByteCount)
}
