import Foundation
import KinlogueCore
import KinloguePlatform
import Testing
@testable import KinlogueApp

@Suite("Backup operation coordinator", .serialized)
struct BackupOperationCoordinatorTests {
    @Test
    func duplicateManualClicksNeverRunParallelAndAcceptedClicksAlwaysCreateNewPoints() async throws {
        try await withCoordinatorFixture { fixture in
            let gate = CoordinatorGate()
            await fixture.creator.setGate(gate)
            let first = Task { try await fixture.coordinator.backUpNow(at: fixture.now) }
            await gate.waitUntilEntered()

            await #expect(throws: BackupOperationCoordinatorError.operationInProgress) {
                _ = try await fixture.coordinator.backUpNow(at: fixture.now)
            }
            await gate.release()
            _ = try await first.value

            await fixture.creator.setGate(nil)
            _ = try await fixture.coordinator.backUpNow(at: fixture.now.addingTimeInterval(1))
            #expect(await fixture.creator.callCount == 2)
            #expect(await fixture.creator.maximumConcurrentCalls == 1)
        }
    }

    @Test
    func cleanupFailureDoesNotRollbackVerifiedBackup() async throws {
        try await withCoordinatorFixture(cleanup: .deferred(.retentionDeferred)) { fixture in
            let result = try await fixture.coordinator.backUpNow(at: fixture.now)
            #expect(result.cleanup == .deferred(.retentionDeferred))
            #expect(await fixture.creator.callCount == 1)
            #expect(try await fixture.store.load()?.scheduler.lastCoveredRevisionPair == fixture.pair)
        }
    }

    @Test
    func destructiveFenceCancelsPrepublicationBackupAndRejectsNewWriters() async throws {
        try await withCoordinatorFixture { fixture in
            let gate = CoordinatorGate()
            await fixture.creator.setGate(gate)
            let backup = Task { try await fixture.coordinator.backUpNow(at: fixture.now) }
            await gate.waitUntilEntered()

            let destructive = Task {
                try await fixture.coordinator.withDestructiveFence {
                    await gate.markDestructiveEntered()
                    try await gate.waitForDestructiveRelease()
                }
            }
            await gate.waitUntilDestructiveEntered()
            await #expect(throws: BackupOperationCoordinatorError.destructiveOperationInProgress) {
                _ = try await fixture.coordinator.backUpNow(at: fixture.now)
            }
            await gate.releaseDestructive()
            try await destructive.value
            await #expect(throws: CancellationError.self) { _ = try await backup.value }
        }
    }
}

private struct CoordinatorFixture {
    let store: BackupLocalConfigurationStore
    let pair: BackupRevisionPair
    let now: Date
    let creator: CoordinatorCreator
    let coordinator: BackupOperationCoordinator
}

private func withCoordinatorFixture(
    cleanup: BackupCleanupOutcome = .complete,
    _ body: (CoordinatorFixture) async throws -> Void
) async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(
        "KinlogueCoordinator-\(UUID().uuidString)", isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let store = BackupLocalConfigurationStore(
        rootURL: base.appendingPathComponent("BackupIdentity", isDirectory: true)
    )
    let configuration = try await makeEnabledCoordinatorConfiguration(store: store)
    let pair = try coordinatorPair(2)
    let creator = CoordinatorCreator(pair: pair)
    let retention = CoordinatorRetention(outcome: cleanup)
    let coordinator = BackupOperationCoordinator(
        configurationStore: store,
        checkpointCreator: creator,
        retentionExecutor: retention
    )
    try await body(.init(
        store: store,
        pair: pair,
        now: Date(timeIntervalSince1970: 50_000),
        creator: creator,
        coordinator: coordinator
    ))
    _ = configuration
}

private actor CoordinatorCreator: BackupCheckpointCreating {
    let pair: BackupRevisionPair
    private var gate: CoordinatorGate?
    private(set) var callCount = 0
    private(set) var currentConcurrentCalls = 0
    private(set) var maximumConcurrentCalls = 0

    init(pair: BackupRevisionPair) { self.pair = pair }
    func setGate(_ gate: CoordinatorGate?) { self.gate = gate }

    func createCheckpoint(
        configuration: BackupLocalConfiguration
    ) async throws -> BackupCheckpointCreation {
        callCount += 1
        currentConcurrentCalls += 1
        maximumConcurrentCalls = max(maximumConcurrentCalls, currentConcurrentCalls)
        defer { currentConcurrentCalls -= 1 }
        if let gate {
            await gate.enter()
            try await gate.waitForRelease()
        }
        return .init(revisionPair: pair)
    }
}

private struct CoordinatorRetention: BackupRetentionExecuting {
    let outcome: BackupCleanupOutcome
    func applyRetention(
        configuration: BackupLocalConfiguration,
        now: Date
    ) async -> BackupCleanupOutcome { outcome }
}

private actor CoordinatorGate {
    private var entered = false
    private var enterWaiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private var destructiveEntered = false
    private var destructiveWaiters: [CheckedContinuation<Void, Never>] = []
    private var destructiveReleaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enter() {
        entered = true
        enterWaiters.forEach { $0.resume() }
        enterWaiters.removeAll()
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enterWaiters.append($0) }
    }
    func release() {
        released = true
    }
    func waitForRelease() async throws {
        while !released {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    func markDestructiveEntered() {
        destructiveEntered = true
        destructiveWaiters.forEach { $0.resume() }
        destructiveWaiters.removeAll()
    }
    func waitUntilDestructiveEntered() async {
        if destructiveEntered { return }
        await withCheckedContinuation { destructiveWaiters.append($0) }
    }
    func waitForDestructiveRelease() async throws {
        await withCheckedContinuation { destructiveReleaseWaiters.append($0) }
    }
    func releaseDestructive() {
        destructiveReleaseWaiters.forEach { $0.resume() }
        destructiveReleaseWaiters.removeAll()
    }
}

func makeEnabledCoordinatorConfiguration(
    store: BackupLocalConfigurationStore
) async throws -> BackupLocalConfiguration {
    let material = try BackupKeyHierarchy.makeEnrollment(
        recoverySeed: Data((1...32).map(UInt8.init)),
        setID: .init(bytes: Data(repeating: 0x21, count: 16)),
        deviceSigningSeed: Data(repeating: 0x22, count: 32),
        deviceID: .init(bytes: Data(repeating: 0x23, count: 16)),
        authorizationID: .init(bytes: Data(repeating: 0x24, count: 16)),
        writerEpoch: .init(bytes: Data(repeating: 0x25, count: 16))
    )
    let pending = try BackupPendingEnrollment(
        bookmarkData: Data("opaque".utf8),
        selectedDirectoryIdentity: .init(device: 1, inode: 2),
        repositoryDirectoryIdentity: .init(device: 1, inode: 3),
        descriptor: material.descriptor,
        authorization: material.authorization,
        deviceSigningSeed: material.deviceSigningSeed,
        writerEpoch: material.writerEpoch
    )
    let created = try await store.createPending(pending)
    return try await store.promotePending(
        enrollmentEpoch: created.enrollmentEpoch,
        expectedRevision: created.revision
    )
}

func coordinatorPair(_ generation: UInt64) throws -> BackupRevisionPair {
    try .init(
        vault: .init(generation: generation, commitID: UUID(), manifestDigest: Data(repeating: 1, count: 32)),
        lanInbox: .init(generation: generation, commitID: UUID(), manifestDigest: Data(repeating: 2, count: 32))
    )
}
