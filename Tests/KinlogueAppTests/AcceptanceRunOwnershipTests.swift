import Foundation
import KinloguePlatform
import Testing
@testable import KinlogueApp

struct AcceptanceRunOwnershipTests {
    @Test
    func claimLoadAndReleaseUseOnlyAnInodeBoundFilesystemReceipt() throws {
        let fixture = try AcceptanceOwnershipFixture()
        defer { fixture.remove() }

        let claimed = try fixture.claim()
        let loaded = try fixture.load()

        #expect(loaded.receipt == claimed.receipt)
        #expect(FileManager.default.fileExists(atPath: fixture.receiptURL.path))
        try loaded.releaseAfterVaultRemoval()
        #expect(!FileManager.default.fileExists(atPath: fixture.runRoot.path))
    }

    @Test
    func releaseRecognizesStableAndLegacyVaultLockFiles() async throws {
        let fixture = try AcceptanceOwnershipFixture()
        defer { fixture.remove() }
        let ownership = try fixture.claim()
        let sourceVault = fixture.runRoot.appendingPathComponent(
            "SourceVault",
            isDirectory: true
        )
        let vault = try PlaintextVault(rootURL: sourceVault)
        _ = try await vault.initialize()
        try await vault.destroy()

        let expectedLockNames = VaultMutationLockNaming.filenames(
            forRootURL: sourceVault
        )
        let namesBeforeRelease = Set(
            try FileManager.default.contentsOfDirectory(
                atPath: fixture.runRoot.path
            )
        )
        #expect(expectedLockNames.isSubset(of: namesBeforeRelease))

        try ownership.releaseAfterVaultRemoval()
        #expect(!FileManager.default.fileExists(atPath: fixture.runRoot.path))
    }

    @Test
    func aPreexistingRunRootIsRejectedWithoutDeletingItsContents() throws {
        let fixture = try AcceptanceOwnershipFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.runRoot,
            withIntermediateDirectories: true
        )
        let sentinelURL = fixture.runRoot.appendingPathComponent("sentinel.bin")
        let sentinel = Data("preexisting-synthetic-data".utf8)
        try sentinel.write(to: sentinelURL)

        #expect(throws: (any Error).self) {
            _ = try fixture.claim()
        }
        #expect(try Data(contentsOf: sentinelURL) == sentinel)
        #expect(!FileManager.default.fileExists(atPath: fixture.receiptURL.path))
    }

    @Test
    func receiptTamperingIsRejectedWithoutDeletingTheRunRoot() throws {
        let fixture = try AcceptanceOwnershipFixture()
        defer { fixture.remove() }
        _ = try fixture.claim()
        try Data("not-a-receipt".utf8).write(to: fixture.receiptURL)

        #expect(throws: (any Error).self) {
            _ = try fixture.load()
        }
        #expect(FileManager.default.fileExists(atPath: fixture.runRoot.path))
        #expect(FileManager.default.fileExists(atPath: fixture.receiptURL.path))
    }

    @Test
    func replacingTheOwnedDirectoryIsRejectedByItsRecordedInode() throws {
        let fixture = try AcceptanceOwnershipFixture()
        defer { fixture.remove() }
        let claimed = try fixture.claim()
        let displaced = fixture.baseURL.appendingPathComponent("displaced", isDirectory: true)
        try FileManager.default.moveItem(at: fixture.runRoot, to: displaced)
        try FileManager.default.createDirectory(at: fixture.runRoot, withIntermediateDirectories: false)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(claimed.receipt).write(to: fixture.receiptURL)

        #expect(throws: (any Error).self) {
            _ = try fixture.load()
        }
        #expect(FileManager.default.fileExists(atPath: displaced.path))
        #expect(FileManager.default.fileExists(atPath: fixture.runRoot.path))
    }

    @Test
    func anUnexpectedEntryBlocksReleaseBeforeTheReceiptIsRemoved() throws {
        let fixture = try AcceptanceOwnershipFixture()
        defer { fixture.remove() }
        let ownership = try fixture.claim()
        let extraURL = fixture.runRoot.appendingPathComponent("unexpected.bin")
        let extra = Data("unexpected-synthetic-data".utf8)
        try extra.write(to: extraURL)

        #expect(throws: (any Error).self) {
            try ownership.releaseAfterVaultRemoval()
        }
        #expect(try Data(contentsOf: extraURL) == extra)
        #expect(FileManager.default.fileExists(atPath: fixture.receiptURL.path))
    }

    @Test
    func aSymlinkedAcceptanceParentIsRejectedWithoutTouchingItsTarget() throws {
        let fixture = try AcceptanceOwnershipFixture()
        defer { fixture.remove() }
        let kinlogue = fixture.applicationSupport.appendingPathComponent("Kinlogue")
        try FileManager.default.createDirectory(at: kinlogue, withIntermediateDirectories: false)
        let target = fixture.baseURL.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(
            at: kinlogue.appendingPathComponent("Acceptance"),
            withDestinationURL: target
        )

        #expect(throws: (any Error).self) {
            _ = try fixture.claim()
        }
        #expect((try FileManager.default.contentsOfDirectory(atPath: target.path)).isEmpty)
    }
}

private struct AcceptanceOwnershipFixture {
    let baseURL: URL
    let applicationSupport: URL
    let runID = "0123456789abcdef01234567"

    var runRoot: URL {
        applicationSupport
            .appendingPathComponent("Kinlogue", isDirectory: true)
            .appendingPathComponent("Acceptance", isDirectory: true)
            .appendingPathComponent(runID, isDirectory: true)
    }

    var receiptURL: URL {
        runRoot.appendingPathComponent(AcceptanceRunOwnership.receiptName)
    }

    init() throws {
        baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinlogue-acceptance-owner-\(UUID().uuidString)")
        applicationSupport = baseURL.appendingPathComponent("Application Support")
        try FileManager.default.createDirectory(
            at: applicationSupport,
            withIntermediateDirectories: true
        )
    }

    func claim() throws -> AcceptanceRunOwnership {
        try AcceptanceRunOwnership.claim(
            applicationSupportURL: applicationSupport,
            runID: runID,
            operationID: UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
        )
    }

    func load() throws -> AcceptanceRunOwnership {
        try AcceptanceRunOwnership.load(
            applicationSupportURL: applicationSupport,
            runID: runID
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: baseURL)
    }
}
