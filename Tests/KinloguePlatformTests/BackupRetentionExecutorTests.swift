import Darwin
import Foundation
import KinlogueCore
import Testing
@testable import KinloguePlatform

@Suite("Backup retention executor", .serialized)
struct BackupRetentionExecutorTests {
    @Test
    func thirtyToTwoRetentionUsesOneRealRepositoryScanAndExactLeafDeletes() async throws {
        try await withRepositoryFixture { fixture in
            for sequence in 1...30 {
                _ = try await fixture.publish(
                    sequence: UInt64(sequence),
                    marker: UInt8(sequence + 80)
                )
            }
            let store = try await retentionStore(fixture, retentionCount: 2, witnessAll: true)
            let scanCounter = RetentionScanCounter()
            let repository = BackupRepository(
                repositoryURL: fixture.repository,
                expectedIdentity: fixture.scanner.expectedIdentity,
                trustedDescriptor: fixture.enrollment.descriptor,
                expectedAuthorizationID: fixture.enrollment.authorization.authorizationID,
                leaseAuthority: fixture.scanner.leaseAuthority,
                scanObserver: { scanCounter.increment() }
            )
            let executor = BackupRetentionExecutor(
                repository: repository,
                configurationStore: store,
                continuityStartedAt: Date(timeIntervalSince1970: 2_000_000 - 25 * 60 * 60)
            )

            let outcome = await executor.execute(
                configuration: try #require(await store.load()),
                now: Date(timeIntervalSince1970: 2_000_000)
            )

            #expect(outcome == .complete(deletedCount: 28))
            #expect(scanCounter.value == 1)
            #expect(try fixture.scanner.scan().entries.filter {
                if case .verified = $0.verification { return true }
                return false
            }.count == 2)
        }
    }

    @Test(arguments: [2, 5, 30])
    func retentionKeepsLatestConfiguredCountFromOneManualAutomaticPool(_ count: Int) async throws {
        try await withRepositoryFixture { repositoryFixture in
            for sequence in 1...count + 1 {
                _ = try await repositoryFixture.publish(
                    sequence: UInt64(sequence),
                    marker: UInt8(sequence + 20)
                )
            }
            let store = try await retentionStore(
                repositoryFixture,
                retentionCount: count,
                witnessAll: true
            )
            let executor = BackupRetentionExecutor(
                repository: repositoryFixture.scanner,
                configurationStore: store,
                continuityStartedAt: Date(timeIntervalSince1970: 2_000_000 - 25 * 60 * 60)
            )
            let current = try #require(await store.load())
            let outcome = await executor.execute(
                configuration: current,
                now: Date(timeIntervalSince1970: 2_000_000)
            )

            #expect(outcome == .complete(deletedCount: 1))
            let remaining = try repositoryFixture.scanner.scan().entries.filter {
                if case .verified = $0.verification { return true }
                return false
            }
            #expect(remaining.count == count)
            #expect(try #require(await store.load()).verificationWitnesses.count == count)
        }
    }

    @Test
    func noWitnessCorruptUnknownAndHistoryForkNeverDeleteAnything() async throws {
        try await withRepositoryFixture { fixture in
            _ = try await fixture.publish(sequence: 1, marker: 0x31)
            _ = try await fixture.publish(sequence: 2, marker: 0x32)
            _ = try await fixture.publish(sequence: 3, marker: 0x33)
            try fixture.write(Data("unknown".utf8), named: "notes.txt")
            let corrupt = String(repeating: "a", count: 32) + ".kinloguebackup"
            try fixture.write(Data("bad".utf8), named: corrupt)
            let store = try await retentionStore(fixture, retentionCount: 2, witnessAll: false)
            let executor = BackupRetentionExecutor(
                repository: fixture.scanner,
                configurationStore: store,
                continuityStartedAt: Date(timeIntervalSince1970: 2_000_000 - 25 * 60 * 60)
            )
            let before = try FileManager.default.contentsOfDirectory(atPath: fixture.repository.path).sorted()
            let outcome = await executor.execute(
                configuration: try #require(await store.load()),
                now: Date(timeIntervalSince1970: 2_000_000)
            )
            #expect(outcome == .complete(deletedCount: 0))
            #expect(try retentionDataLeafNames(in: fixture.repository) == before)
        }

        try await withRepositoryFixture { fixture in
            _ = try await fixture.publish(sequence: 7, marker: 0x41)
            _ = try await fixture.publish(sequence: 7, marker: 0x42)
            let store = try await retentionStore(fixture, retentionCount: 2, witnessAll: true)
            let executor = BackupRetentionExecutor(
                repository: fixture.scanner,
                configurationStore: store,
                continuityStartedAt: Date(timeIntervalSince1970: 2_000_000 - 25 * 60 * 60)
            )
            let before = try FileManager.default.contentsOfDirectory(atPath: fixture.repository.path).sorted()
            let outcome = await executor.execute(
                configuration: try #require(await store.load()),
                now: Date(timeIntervalSince1970: 2_000_000)
            )
            #expect(outcome == .deferred(.repositoryHistoryFork))
            #expect(try retentionDataLeafNames(in: fixture.repository) == before)
        }
    }

    @Test
    func leafReplacementOrDeleteSyncFailureDefersCleanupWithoutRollingBackNewCheckpoint() async throws {
        try await withRepositoryFixture { fixture in
            for sequence in 1...3 {
                _ = try await fixture.publish(sequence: UInt64(sequence), marker: UInt8(sequence + 50))
            }
            let store = try await retentionStore(fixture, retentionCount: 2, witnessAll: true)
            let executor = BackupRetentionExecutor(
                repository: fixture.scanner,
                configurationStore: store,
                continuityStartedAt: Date(timeIntervalSince1970: 2_000_000 - 25 * 60 * 60),
                beforeDelete: { entry in
                    let url = fixture.repository.appendingPathComponent(entry.leafName)
                    let bytes = try Data(contentsOf: url)
                    try FileManager.default.removeItem(at: url)
                    try bytes.write(to: url, options: .withoutOverwriting)
                    #expect(chmod(url.path, 0o600) == 0)
                }
            )
            let outcome = await executor.execute(
                configuration: try #require(await store.load()),
                now: Date(timeIntervalSince1970: 2_000_000)
            )
            #expect(outcome == .deferred(.retentionDeferred))
            #expect(try fixture.scanner.scan().entries.filter {
                if case .verified = $0.verification { return true }
                return false
            }.count == 3)
        }
    }

    @Test(arguments: ["remove", "replace"])
    func nonTargetPlannedKeepMutationDefersBeforeRetentionUnlinksItsTarget(
        _ mutation: String
    ) async throws {
        try await withRepositoryFixture { fixture in
            for sequence in 1...3 {
                _ = try await fixture.publish(
                    sequence: UInt64(sequence),
                    marker: UInt8(sequence + 55)
                )
            }
            let initialScan = try fixture.scanner.scan()
            let oldest = try #require(initialScan.entries.first { entry in
                guard case let .verified(point) = entry.verification else { return false }
                return point.sequence == 1
            })
            let plannedKeep = try #require(initialScan.entries.first { entry in
                guard case let .verified(point) = entry.verification else { return false }
                return point.sequence == 3
            })
            let keepURL = fixture.repository.appendingPathComponent(plannedKeep.leafName)
            let keepBytes = try Data(contentsOf: keepURL)
            let store = try await retentionStore(fixture, retentionCount: 2, witnessAll: true)
            let executor = BackupRetentionExecutor(
                repository: fixture.scanner,
                configurationStore: store,
                continuityStartedAt: Date(timeIntervalSince1970: 2_000_000 - 25 * 60 * 60),
                beforeDelete: { _ in
                    try FileManager.default.removeItem(at: keepURL)
                    if mutation == "replace" {
                        try keepBytes.write(to: keepURL, options: .withoutOverwriting)
                        #expect(chmod(keepURL.path, 0o600) == 0)
                    }
                }
            )

            let outcome = await executor.execute(
                configuration: try #require(await store.load()),
                now: Date(timeIntervalSince1970: 2_000_000)
            )

            #expect(outcome == .deferred(.retentionDeferred))
            #expect(FileManager.default.fileExists(
                atPath: fixture.repository.appendingPathComponent(oldest.leafName).path
            ))
        }
    }

    @Test
    func retentionPolicyRevisionChangingDuringBeforeDeleteDefersWithoutDeletingTheLeaf() async throws {
        try await withRepositoryFixture { fixture in
            for sequence in 1...3 {
                _ = try await fixture.publish(sequence: UInt64(sequence), marker: UInt8(sequence + 60))
            }
            let store = try await retentionStore(fixture, retentionCount: 2, witnessAll: true)
            let mutationFinished = DispatchSemaphore(value: 0)
            let executor = BackupRetentionExecutor(
                repository: fixture.scanner,
                configurationStore: store,
                continuityStartedAt: Date(timeIntervalSince1970: 2_000_000 - 25 * 60 * 60),
                beforeDelete: { _ in
                    Task {
                        if let current = try? await store.load() {
                            _ = try? await store.updateAutomation(
                                retentionCount: try? .init(3),
                                expectedRevision: current.revision
                            )
                        }
                        mutationFinished.signal()
                    }
                    #expect(mutationFinished.wait(timeout: .now() + 5) == .success)
                }
            )

            let outcome = await executor.execute(
                configuration: try #require(await store.load()),
                now: Date(timeIntervalSince1970: 2_000_000)
            )

            #expect(outcome == .deferred(.retentionDeferred))
            #expect(try fixture.scanner.scan().entries.filter {
                if case .verified = $0.verification { return true }
                return false
            }.count == 3)
        }
    }

    @Test
    func cancellationDuringBeforeDeleteDefersBeforeAnyLeafIsRemoved() async throws {
        try await withRepositoryFixture { fixture in
            for sequence in 1...3 {
                _ = try await fixture.publish(sequence: UInt64(sequence), marker: UInt8(sequence + 70))
            }
            let store = try await retentionStore(fixture, retentionCount: 2, witnessAll: true)
            let executor = BackupRetentionExecutor(
                repository: fixture.scanner,
                configurationStore: store,
                continuityStartedAt: Date(timeIntervalSince1970: 2_000_000 - 25 * 60 * 60),
                beforeDelete: { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            )

            let configuration = try #require(await store.load())
            let operation = Task {
                await executor.execute(
                    configuration: configuration,
                    now: Date(timeIntervalSince1970: 2_000_000)
                )
            }
            let outcome = await operation.value

            #expect(outcome == .deferred(.retentionDeferred))
            #expect(try fixture.scanner.scan().entries.filter {
                if case .verified = $0.verification { return true }
                return false
            }.count == 3)
        }
    }

    @Test
    func ordinaryRelaunchPreservesDurableWitnessDwell() async throws {
        try await withRepositoryFixture { fixture in
            for sequence in 1...3 {
                _ = try await fixture.publish(
                    sequence: UInt64(sequence),
                    marker: UInt8(sequence + 65)
                )
            }
            let store = try await retentionStore(
                fixture,
                retentionCount: 2,
                witnessAll: true
            )
            let executor = BackupRetentionExecutor(
                repository: fixture.scanner,
                configurationStore: store
            )

            #expect(await executor.execute(
                configuration: try #require(await store.load()),
                now: Date(timeIntervalSince1970: 2_000_000)
            ) == .complete(deletedCount: 1))
        }
    }

    @Test
    func newProcessContinuityResetsOldWitnessDwellAndPerformsNoDeletion() async throws {
        try await withRepositoryFixture { fixture in
            for sequence in 1...3 {
                _ = try await fixture.publish(sequence: UInt64(sequence), marker: UInt8(sequence + 70))
            }
            let store = try await retentionStore(fixture, retentionCount: 2, witnessAll: true)
            let now = Date(timeIntervalSince1970: 2_000_000)
            let executor = BackupRetentionExecutor(
                repository: fixture.scanner,
                configurationStore: store,
                continuityStartedAt: now
            )
            #expect(await executor.execute(
                configuration: try #require(await store.load()),
                now: now
            ) == .complete(deletedCount: 0))
            #expect(try fixture.scanner.scan().entries.filter {
                if case .verified = $0.verification { return true }
                return false
            }.count == 3)
        }
    }
}

private final class RetentionScanCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.withLock { count += 1 }
    }

    var value: Int { lock.withLock { count } }
}

private func retentionDataLeafNames(in repository: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: repository.path)
        .filter { $0 != ".kinlogue-publication.lock" }
        .sorted()
}

private func retentionStore(
    _ fixture: RepositoryFixture,
    retentionCount: Int,
    witnessAll: Bool
) async throws -> BackupLocalConfigurationStore {
    let store = BackupLocalConfigurationStore(
        rootURL: fixture.base.appendingPathComponent("BackupIdentity", isDirectory: true)
    )
    let pending = try BackupPendingEnrollment(
        bookmarkData: Data("opaque".utf8),
        selectedDirectoryIdentity: .init(
            device: fixture.scanner.expectedIdentity.device,
            inode: fixture.scanner.expectedIdentity.inode + 1
        ),
        repositoryDirectoryIdentity: fixture.scanner.expectedIdentity,
        descriptor: fixture.enrollment.descriptor,
        authorization: fixture.enrollment.authorization,
        deviceSigningSeed: fixture.enrollment.deviceSigningSeed,
        writerEpoch: fixture.enrollment.writerEpoch,
        retentionCount: try .init(retentionCount)
    )
    let created = try await store.createPending(pending)
    var current = try await store.promotePending(
        enrollmentEpoch: created.enrollmentEpoch,
        expectedRevision: created.revision
    )
    guard witnessAll else { return store }
    let scan = try fixture.scanner.scan()
    let observedAt = Date(timeIntervalSince1970: 2_000_000 - 25 * 60 * 60)
    for entry in scan.entries {
        guard case let .verified(point) = entry.verification,
              let identity = entry.repositoryIdentityDigest else { continue }
        let witness = try BackupDurableFullReaderWitness(
            checkpoint: point,
            writerEpoch: current.writerEpoch,
            repositoryIdentityDigest: identity,
            continuousObservationStartedAt: observedAt,
            lastObservedAt: observedAt
        )
        current = try await store.appendVerificationWitness(
            witness,
            expectedWriterIdentity: current.writerIdentity
        )
    }
    return store
}
