import Darwin
import Foundation
import KinlogueCore
import Testing
@testable import KinloguePlatform

@Test
func localConfigurationStoreCreatesStrictPrivateCanonicalRecordAndReloadsIdentity() async throws {
    try await withBackupStoreFixture { fixture in
        let pending = try fixture.pending()
        let created = try await fixture.store.createPending(pending)
        let enabled = try await fixture.store.promotePending(
            enrollmentEpoch: created.enrollmentEpoch,
            expectedRevision: created.revision
        )
        let reopened = BackupLocalConfigurationStore(rootURL: fixture.root)

        #expect(enabled.phase == .enabled)
        #expect(!enabled.automation.isAutomaticBackupEnabled)
        #expect(enabled.automation.retentionCount.value == 5)
        #expect(try await reopened.load() == enabled)

        let rootMode = try mode(of: fixture.root)
        let recordMode = try mode(of: fixture.root.appendingPathComponent("configuration.json"))
        #expect(rootMode == 0o700)
        #expect(recordMode == 0o600)

        let bytes = try Data(contentsOf: fixture.root.appendingPathComponent("configuration.json"))
        #expect(!bytes.containsSubsequence(fixture.recoverySeed))
        #expect(!String(decoding: bytes, as: UTF8.self).contains("KLG1-"))
    }
}

@Test
func localConfigurationStoreFailsClosedForConcurrentCASAndHostileLeafs() async throws {
    try await withBackupStoreFixture { fixture in
        let created = try await fixture.store.createPending(try fixture.pending())
        _ = try await fixture.store.promotePending(
            enrollmentEpoch: created.enrollmentEpoch,
            expectedRevision: created.revision
        )
        do {
            _ = try await fixture.store.promotePending(
                enrollmentEpoch: created.enrollmentEpoch,
                expectedRevision: created.revision
            )
            Issue.record("stale CAS unexpectedly succeeded")
        } catch let error as BackupLocalConfigurationStoreError {
            #expect(error == .compareAndSwapFailed)
        }
    }

    try await withBackupStoreFixture { fixture in
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        let target = fixture.base.appendingPathComponent("foreign")
        try Data("foreign".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appendingPathComponent("configuration.json"),
            withDestinationURL: target
        )
        do {
            _ = try await fixture.store.createPending(try fixture.pending())
            Issue.record("symlink record unexpectedly accepted")
        } catch is BackupLocalConfigurationStoreError {
        }
        #expect(try Data(contentsOf: target) == Data("foreign".utf8))
    }
}

@Test
func twoStoreInstancesSerializeInitialEnrollmentAndPersistOnlyOneSigner() async throws {
    try await withBackupStoreFixture { fixture in
        let other = BackupLocalConfigurationStore(rootURL: fixture.root)
        let pending = try fixture.pending()
        let first = Task { try await fixture.store.createPending(pending) }
        let second = Task { try await other.createPending(pending) }
        let results = await [first.result, second.result]
        let successCount = results.reduce(into: 0) { count, result in
            if case .success = result { count += 1 }
        }
        let collisionCount = results.reduce(into: 0) { count, result in
            if case let .failure(error) = result,
               error as? BackupLocalConfigurationStoreError == .configurationAlreadyExists {
                count += 1
            }
        }
        #expect(successCount == 1)
        #expect(collisionCount == 1)
        #expect(try await fixture.store.load()?.deviceSigningSeed == pending.deviceSigningSeed)
    }
}

@Test
func localConfigurationStoreRejectsWrongModeHardlinkAndReplacedParent() async throws {
    try await withBackupStoreFixture { fixture in
        _ = try await fixture.store.createPending(try fixture.pending())
        let record = fixture.root.appendingPathComponent("configuration.json")
        #expect(chmod(record.path, 0o644) == 0)
        do {
            _ = try await fixture.store.load()
            Issue.record("wrong-mode record unexpectedly accepted")
        } catch is BackupLocalConfigurationStoreError {
        }
    }

    try await withBackupStoreFixture { fixture in
        _ = try await fixture.store.createPending(try fixture.pending())
        let record = fixture.root.appendingPathComponent("configuration.json")
        #expect(link(record.path, fixture.base.appendingPathComponent("alias").path) == 0)
        do {
            _ = try await fixture.store.load()
            Issue.record("hard-linked record unexpectedly accepted")
        } catch is BackupLocalConfigurationStoreError {
        }
    }

    try await withBackupStoreFixture { fixture in
        _ = try await fixture.store.createPending(try fixture.pending())
        let original = fixture.base.appendingPathComponent("original")
        try FileManager.default.moveItem(at: fixture.root, to: original)
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: false)
        do {
            _ = try await fixture.store.load()
            Issue.record("replaced root unexpectedly accepted")
        } catch is BackupLocalConfigurationStoreError {
        }
    }

    try await withBackupStoreFixture { fixture in
        _ = try await fixture.store.createPending(try fixture.pending())
        let original = fixture.base.appendingPathComponent("original")
        try FileManager.default.moveItem(at: fixture.root, to: original)
        try FileManager.default.createDirectory(
            at: fixture.root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let copiedRecord = fixture.root.appendingPathComponent("configuration.json")
        try FileManager.default.copyItem(
            at: original.appendingPathComponent("configuration.json"),
            to: copiedRecord
        )
        #expect(chmod(copiedRecord.path, 0o600) == 0)
        let relaunched = BackupLocalConfigurationStore(rootURL: fixture.root)
        do {
            _ = try await relaunched.load()
            Issue.record("copied root-bound record unexpectedly accepted after relaunch")
        } catch is BackupLocalConfigurationStoreError {
        }
    }
}

@Test
func localConfigurationStoreCASPersistsAutomationDueFailureSuccessAndDestructiveDisable() async throws {
    try await withBackupStoreFixture { fixture in
        let created = try await fixture.store.createPending(try fixture.pending())
        var current = try await fixture.store.promotePending(
            enrollmentEpoch: created.enrollmentEpoch,
            expectedRevision: created.revision
        )
        let pair = try schedulerPair(generation: 7)
        let observedAt = Date(timeIntervalSince1970: 1_000.123_45)
        let dueAt = observedAt.addingTimeInterval(300)
        let canonicalObservedAt = Date(timeIntervalSince1970: 1_000.123)
        let canonicalDueAt = Date(timeIntervalSince1970: 1_300.123)

        current = try await fixture.store.updateAutomation(
            isAutomaticBackupEnabled: true,
            retentionCount: try BackupRetentionCount(2),
            expectedRevision: current.revision
        )
        current = try await fixture.store.observeRevisionPair(
            pair,
            observedAt: observedAt,
            dueAt: dueAt,
            expectedRevision: current.revision
        )
        current = try await fixture.store.markBackupFailure(
            .sourceChanged,
            retryAttempt: 1,
            retryDueAt: dueAt.addingTimeInterval(60),
            expectedRevision: current.revision
        )

        #expect(current.automation.isAutomaticBackupEnabled)
        #expect(current.automation.retentionCount.value == 2)
        #expect(current.scheduler.firstObservedRevisionPair == pair)
        #expect(current.scheduler.firstObservedAt == canonicalObservedAt)
        #expect(current.scheduler.dueAt == canonicalDueAt)
        #expect(current.scheduler.lastFailure == .sourceChanged)
        #expect(current.scheduler.mutationRetryAttempt == 1)

        let verifiedAt = dueAt.addingTimeInterval(90)
        let canonicalVerifiedAt = Date(timeIntervalSince1970: 1_390.123)
        current = try await fixture.store.markBackupSuccess(
            pair,
            verifiedAt: verifiedAt,
            expectedRevision: current.revision
        )
        #expect(current.scheduler.lastCoveredRevisionPair == pair)
        #expect(current.scheduler.lastLocalVerificationAt == canonicalVerifiedAt)
        #expect(current.scheduler.firstObservedRevisionPair == nil)
        #expect(current.scheduler.dueAt == nil)
        #expect(current.scheduler.lastFailure == nil)
        #expect(current.scheduler.mutationRetryAttempt == 0)

        current = try await fixture.store.disableForDestructiveReset(
            expectedRevision: current.revision
        )
        #expect(!current.automation.isAutomaticBackupEnabled)
        #expect(current.scheduler.firstObservedRevisionPair == nil)
        #expect(current.scheduler.retryDueAt == nil)
        #expect(try await BackupLocalConfigurationStore(rootURL: fixture.root).load() == current)
    }
}

@Test
func localConfigurationStoreRejectsStaleSchedulerCASWithoutLosingTheWinningState() async throws {
    try await withBackupStoreFixture { fixture in
        let created = try await fixture.store.createPending(try fixture.pending())
        let enabled = try await fixture.store.promotePending(
            enrollmentEpoch: created.enrollmentEpoch,
            expectedRevision: created.revision
        )
        let pair = try schedulerPair(generation: 3)
        let winning = try await fixture.store.observeRevisionPair(
            pair,
            observedAt: Date(timeIntervalSince1970: 2_000),
            dueAt: Date(timeIntervalSince1970: 2_300),
            expectedRevision: enabled.revision
        )

        await #expect(throws: BackupLocalConfigurationStoreError.compareAndSwapFailed) {
            _ = try await fixture.store.updateAutomation(
                isAutomaticBackupEnabled: true,
                retentionCount: nil,
                expectedRevision: enabled.revision
            )
        }
        #expect(try await fixture.store.load() == winning)
    }
}

@Test
func enabledBookmarkRefreshIsExactCASAndSurvivesRelaunchWithoutChangingAutomation() async throws {
    try await withBackupStoreFixture { fixture in
        let created = try await fixture.store.createPending(try fixture.pending())
        var enabled = try await fixture.store.promotePending(
            enrollmentEpoch: created.enrollmentEpoch,
            expectedRevision: created.revision
        )
        enabled = try await fixture.store.updateAutomation(
            isAutomaticBackupEnabled: true,
            expectedRevision: enabled.revision
        )
        let refreshed = Data("refreshed-bookmark".utf8)
        let updated = try await fixture.store.refreshEnabledBookmark(
            refreshed,
            expectedRevision: enabled.revision
        )

        #expect(updated.bookmarkData == refreshed)
        #expect(updated.automation == enabled.automation)
        #expect(updated.scheduler == enabled.scheduler)
        #expect(try await BackupLocalConfigurationStore(rootURL: fixture.root).load() == updated)

        await #expect(throws: BackupLocalConfigurationStoreError.compareAndSwapFailed) {
            _ = try await fixture.store.refreshEnabledBookmark(
                Data("stale".utf8),
                expectedRevision: enabled.revision
            )
        }
        #expect(try await fixture.store.load() == updated)
    }
}

@Test
func destructiveResetRemovesTheLocalWriterProfileAndIsIdempotentWhenUnconfigured() async throws {
    try await withBackupStoreFixture { fixture in
        let created = try await fixture.store.createPending(try fixture.pending())
        _ = try await fixture.store.promotePending(
            enrollmentEpoch: created.enrollmentEpoch,
            expectedRevision: created.revision
        )

        try await fixture.store.removeForDestructiveReset()
        #expect(try await fixture.store.load() == nil)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.root.appendingPathComponent("configuration.json").path
        ))

        try await fixture.store.removeForDestructiveReset()
        #expect(try await fixture.store.load() == nil)
    }
}

private struct BackupStoreFixture {
    let base: URL
    let root: URL
    let store: BackupLocalConfigurationStore
    let recoverySeed = Data((1...32).map(UInt8.init))

    func pending() throws -> BackupPendingEnrollment {
        let material = try BackupKeyHierarchy.makeEnrollment(
            recoverySeed: recoverySeed,
            setID: .init(bytes: Data((33...48).map(UInt8.init))),
            deviceSigningSeed: Data((65...96).map(UInt8.init)),
            deviceID: .init(bytes: Data((97...112).map(UInt8.init))),
            authorizationID: .init(bytes: Data((113...128).map(UInt8.init))),
            writerEpoch: .init(bytes: Data((129...144).map(UInt8.init)))
        )
        return try BackupPendingEnrollment(
            bookmarkData: Data("opaque-bookmark".utf8),
            selectedDirectoryIdentity: .init(device: 1, inode: 2),
            repositoryDirectoryIdentity: .init(device: 1, inode: 3),
            descriptor: material.descriptor,
            authorization: material.authorization,
            deviceSigningSeed: material.deviceSigningSeed,
            writerEpoch: material.writerEpoch
        )
    }
}

private func withBackupStoreFixture(
    _ body: (BackupStoreFixture) async throws -> Void
) async throws {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("KinlogueBackupStore-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let root = base.appendingPathComponent("BackupIdentity", isDirectory: true)
    try await body(.init(base: base, root: root, store: .init(rootURL: root)))
}

private func mode(of url: URL) throws -> mode_t {
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0 else { throw CocoaError(.fileReadUnknown) }
    return metadata.st_mode & S_IRWXU | metadata.st_mode & S_IRWXG | metadata.st_mode & S_IRWXO
}

private func schedulerPair(generation: UInt64) throws -> BackupRevisionPair {
    try .init(
        vault: .init(
            generation: generation,
            commitID: UUID(),
            manifestDigest: Data(repeating: UInt8(truncatingIfNeeded: generation), count: 32)
        ),
        lanInbox: .init(
            generation: generation,
            commitID: UUID(),
            manifestDigest: Data(repeating: UInt8(truncatingIfNeeded: generation + 1), count: 32)
        )
    )
}

private extension Data {
    func containsSubsequence(_ other: Data) -> Bool {
        range(of: other) != nil
    }
}
