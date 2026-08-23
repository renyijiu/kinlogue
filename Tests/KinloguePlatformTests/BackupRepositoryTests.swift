import CryptoKit
import Darwin
import Foundation
import KinlogueCore
import Testing
@testable import KinloguePlatform

@Suite("Backup repository", .serialized)
struct BackupRepositoryTests {
    @Test
    func scanOnlyTrustsOpaqueDirectRegularLeavesAndPreservesUnknownCorruptAndWorkFiles() async throws {
        try await withRepositoryFixture { fixture in
            let valid = try await fixture.publish(sequence: 3, marker: 0x31)
            let corruptName = String(repeating: "4", count: 32) + ".kinloguebackup"
            try fixture.write(Data("corrupt".utf8), named: corruptName)
            try fixture.write(Data("work".utf8), named: ".checkpoint-opaque.work")
            try fixture.write(Data("unknown".utf8), named: "notes.txt")
            let nested = fixture.repository.appendingPathComponent("nested", isDirectory: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
            try Data("nested".utf8).write(
                to: nested.appendingPathComponent(String(repeating: "5", count: 32) + ".kinloguebackup")
            )

            let scan = try fixture.scanner.scan()
            #expect(scan.maximumSequence == 3)
            #expect(scan.history == .linear)
            #expect(scan.entries.count == 5)
            #expect(scan.entry(for: valid.checkpoint.checkpointID)?.verification
                == .verified(valid.checkpoint))
            #expect(scan.entries.contains { $0.leafName == corruptName && $0.isRejected })
            #expect(scan.entries.contains { $0.leafName == ".checkpoint-opaque.work" && $0.isIndeterminate })
            #expect(scan.entries.contains { $0.leafName == "notes.txt" && $0.isIndeterminate })
            #expect(scan.entries.contains { $0.leafName == "nested" && $0.isIndeterminate })
            #expect(FileManager.default.fileExists(atPath: nested.path))
        }
    }

    @Test
    func scanNeverFollowsSymlinkHardlinkDirectoryOrFIFOCheckpointLeaves() async throws {
        try await withRepositoryFixture { fixture in
            let foreign = fixture.base.appendingPathComponent("foreign")
            try Data("foreign".utf8).write(to: foreign)
            let names = (1...4).map {
                String(format: "%032x", $0) + ".kinloguebackup"
            }
            try FileManager.default.createSymbolicLink(
                at: fixture.repository.appendingPathComponent(names[0]),
                withDestinationURL: foreign
            )
            #expect(link(foreign.path, fixture.repository.appendingPathComponent(names[1]).path) == 0)
            try FileManager.default.createDirectory(
                at: fixture.repository.appendingPathComponent(names[2]),
                withIntermediateDirectories: false
            )
            #expect(mkfifo(fixture.repository.appendingPathComponent(names[3]).path, 0o600) == 0)

            let scan = try fixture.scanner.scan()
            #expect(scan.entries.count == 4)
            #expect(scan.entries.allSatisfy { $0.isIndeterminate })
            #expect(try Data(contentsOf: foreign) == Data("foreign".utf8))
        }
    }

    @Test
    func sameSequenceDifferentCommitmentIsAHistoryForkAndExactDeleteRejectsLeafReplacement() async throws {
        try await withRepositoryFixture { fixture in
            let first = try await fixture.publish(sequence: 8, marker: 0x41)
            _ = try await fixture.publish(sequence: 8, marker: 0x42)
            let scan = try fixture.scanner.scan()
            #expect(scan.history == .fork(.sameSequenceDifferentCommitment))

            let entry = try #require(scan.entry(for: first.checkpoint.checkpointID))
            let url = fixture.repository.appendingPathComponent(entry.leafName)
            try FileManager.default.removeItem(at: url)
            try fixture.write(first.bytes, named: entry.leafName)
            #expect(throws: BackupRepositoryError.identityChanged) {
                try fixture.scanner.deleteExact(entry)
            }
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test
    func exactDeleteReportsUnsupportedDirectorySynchronizationAsFailure() async throws {
        try await withRepositoryFixture { fixture in
            let point = try await fixture.publish(sequence: 1, marker: 0x51)
            let failing = BackupRepository(
                repositoryURL: fixture.repository,
                expectedIdentity: fixture.scanner.expectedIdentity,
                trustedDescriptor: fixture.enrollment.descriptor,
                expectedAuthorizationID: fixture.enrollment.authorization.authorizationID,
                leaseAuthority: fixture.scanner.leaseAuthority,
                directorySynchronizer: { _ in
                    throw BackupRepositoryError.synchronizationFailed
                }
            )
            let entry = try #require(failing.scan().entry(for: point.checkpoint.checkpointID))
            #expect(throws: BackupRepositoryError.synchronizationFailed) {
                try failing.deleteExact(entry)
            }
        }
    }

    @Test
    func mutationLeaseUsesPrivateOwnerOnlyDirectoryAndCreatesNoRepositoryControlLeaf() async throws {
        try await withRepositoryFixture { fixture in
            let lease = try await fixture.scanner.acquireMutationLease()
            defer { lease.release() }

            let scan = try fixture.scanner.scan(holding: lease)
            #expect(scan.entries.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: fixture.repository
                .appendingPathComponent(".kinlogue-publication.lock").path))
            var metadata = stat()
            #expect(lstat(fixture.scanner.leaseAuthority.namespaceURL.path, &metadata) == 0)
            #expect(metadata.st_mode & S_IFMT == S_IFDIR)
            #expect(metadata.st_uid == geteuid())
            #expect(metadata.st_nlink >= 2)
            #expect(metadata.st_mode & 0o777 == 0o700)
        }
    }

    @Test(arguments: ["symlink", "hardlink", "wrongMode"])
    func repositoryNamedLegacyLockCannotReplaceThePrivateMutationLease(
        _ kind: String
    ) async throws {
        try await withRepositoryFixture { fixture in
            let lockURL = fixture.repository.appendingPathComponent(
                ".kinlogue-publication.lock"
            )
            let foreign = fixture.base.appendingPathComponent("foreign-lock-target")
            try Data("foreign".utf8).write(to: foreign)
            if kind == "symlink" {
                try FileManager.default.createSymbolicLink(
                    at: lockURL,
                    withDestinationURL: foreign
                )
            } else if kind == "hardlink" {
                #expect(link(foreign.path, lockURL.path) == 0)
            } else {
                try Data("control".utf8).write(to: lockURL)
                #expect(chmod(lockURL.path, 0o644) == 0)
            }

            let lease = try await fixture.scanner.acquireMutationLease()
            lease.release()
            #expect(try Data(contentsOf: foreign) == Data("foreign".utf8))
        }
    }

    @Test
    func waitingMutationLeaseIsCancellationAwareAndReleasedLeaseCanBeReacquired() async throws {
        try await withRepositoryFixture { fixture in
            let first = try await fixture.scanner.acquireMutationLease()
            let competitor = BackupRepository(
                repositoryURL: fixture.repository,
                expectedIdentity: fixture.scanner.expectedIdentity,
                trustedDescriptor: fixture.enrollment.descriptor,
                expectedAuthorizationID: fixture.enrollment.authorization.authorizationID,
                leaseAuthority: fixture.scanner.leaseAuthority
            )
            let waiting = Task { try await competitor.acquireMutationLease() }
            try await Task.sleep(for: .milliseconds(50))
            waiting.cancel()
            await #expect(throws: CancellationError.self) {
                _ = try await waiting.value
            }

            first.release()
            let reacquired = try await competitor.acquireMutationLease()
            reacquired.release()
        }
    }
}

struct RepositoryFixture {
    let base: URL
    let repository: URL
    let enrollment: BackupEnrollmentMaterial
    let signer: BackupDeviceSigner
    let scanner: BackupRepository

    func publish(
        sequence: UInt64,
        marker: UInt8
    ) async throws -> (checkpoint: BackupPublicCheckpoint, bytes: Data) {
        let output = RepositoryLockedBytes()
        let pair = try repositoryPair(sequence)
        let writer = EncryptedBackupContainerWriter { count in
            Data(repeating: marker == 0 ? 1 : marker, count: count)
        }
        let result = try await writer.write(
            entries: [
                repositorySource(kind: .vaultCatalog, path: "library.json", bytes: Data()),
                repositorySource(kind: .lanInboxManifest, path: "lan-inbox/inbox.json", bytes: Data("{}".utf8)),
            ],
            revisionPair: pair,
            sequence: sequence,
            signer: signer,
            sink: .init(write: output.append, readBackSource: output.source)
        )
        let bytes = output.data
        let leafName = result.checkpointID.bytes.hex + ".kinloguebackup"
        try write(bytes, named: leafName)
        let verified = try BackupTrustVerifier().verify(
            source: output.source(),
            trustedDescriptor: enrollment.descriptor
        )
        return (verified.checkpoint, bytes)
    }

    func write(_ bytes: Data, named name: String) throws {
        let url = repository.appendingPathComponent(name)
        try bytes.write(to: url, options: .withoutOverwriting)
        #expect(chmod(url.path, 0o600) == 0)
    }
}

func withRepositoryFixture(
    _ body: (RepositoryFixture) async throws -> Void
) async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(
        "KinlogueRepository-\(UUID().uuidString)", isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: base) }
    let repository = base.appendingPathComponent("repository", isDirectory: true)
    try FileManager.default.createDirectory(
        at: repository,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    #expect(chmod(repository.path, 0o700) == 0)
    let enrollment = try BackupKeyHierarchy.makeEnrollment(
        recoverySeed: Data((1...32).map(UInt8.init)),
        setID: .init(bytes: Data(repeating: 0x11, count: 16)),
        deviceSigningSeed: Data(repeating: 0x12, count: 32),
        deviceID: .init(bytes: Data(repeating: 0x13, count: 16)),
        authorizationID: .init(bytes: Data(repeating: 0x14, count: 16)),
        writerEpoch: .init(bytes: Data(repeating: 0x15, count: 16))
    )
    let signer = try BackupDeviceSigner(
        descriptor: enrollment.descriptor,
        authorization: enrollment.authorization,
        deviceSigningSeed: enrollment.deviceSigningSeed
    )
    let identity = try repositoryDirectoryIdentity(repository)
    let leaseRoot = base.appendingPathComponent("BackupIdentity", isDirectory: true)
    try FileManager.default.createDirectory(
        at: leaseRoot,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    #expect(chmod(leaseRoot.path, 0o700) == 0)
    let leaseAuthority = BackupRepositoryLeaseAuthority(
        namespaceURL: leaseRoot,
        namespaceIdentity: try repositoryDirectoryIdentity(leaseRoot),
        repositoryIdentity: identity,
        setID: enrollment.descriptor.setID,
        authorizationID: enrollment.authorization.authorizationID,
        writerEpoch: enrollment.writerEpoch
    )
    let scanner = BackupRepository(
        repositoryURL: repository,
        expectedIdentity: identity,
        trustedDescriptor: enrollment.descriptor,
        expectedAuthorizationID: enrollment.authorization.authorizationID,
        leaseAuthority: leaseAuthority
    )
    try await body(.init(
        base: base,
        repository: repository,
        enrollment: enrollment,
        signer: signer,
        scanner: scanner
    ))
}

func repositoryPair(_ generation: UInt64) throws -> BackupRevisionPair {
    try .init(
        vault: .init(generation: generation, commitID: UUID(), manifestDigest: Data(repeating: 1, count: 32)),
        lanInbox: .init(generation: generation, commitID: UUID(), manifestDigest: Data(repeating: 2, count: 32))
    )
}

func repositoryDirectoryIdentity(_ url: URL) throws -> BackupFilesystemIdentity {
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0 else { throw CocoaError(.fileReadUnknown) }
    return .init(device: UInt64(metadata.st_dev), inode: UInt64(metadata.st_ino))
}

private func repositorySource(
    kind: BackupManifestEntry.Kind,
    path: String,
    bytes: Data
) -> BackupContainerEntrySource {
    BackupContainerEntrySource(
        kind: kind,
        path: path,
        plaintextByteCount: UInt64(bytes.count),
        plaintextDigest: Data(SHA256.hash(data: bytes))
    ) { offset, maximum in
        guard offset <= UInt64(bytes.count) else { return Data() }
        let start = Int(offset)
        return Data(bytes[start..<min(bytes.count, start + maximum)])
    }
}

private final class RepositoryLockedBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    var data: Data { lock.withLock { storage } }
    func append(_ bytes: Data) { lock.withLock { storage.append(bytes) } }
    func source() -> BackupContainerByteSource {
        let snapshot = data
        return .init(byteCount: UInt64(snapshot.count)) { offset, count in
            guard offset <= UInt64(snapshot.count) else { return Data() }
            let start = Int(offset)
            return Data(snapshot[start..<min(snapshot.count, start + count)])
        }
    }
}

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

private extension BackupRepositoryEntry {
    var isRejected: Bool {
        if case .rejected = verification { return true }
        return false
    }
    var isIndeterminate: Bool {
        if case .indeterminate = verification { return true }
        return false
    }
}

private extension BackupRepositoryScan {
    func entry(for checkpointID: BackupCheckpointID) -> BackupRepositoryEntry? {
        entries.first {
            if case let .verified(point) = $0.verification {
                return point.checkpointID == checkpointID
            }
            return false
        }
    }
}
