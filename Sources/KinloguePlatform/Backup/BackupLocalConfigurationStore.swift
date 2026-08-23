import Darwin
import Foundation
import KinlogueCore

public enum BackupLocalConfigurationStoreError: Error, Equatable, Sendable {
    case invalidRoot
    case invalidRecord
    case recordTooLarge
    case configurationAlreadyExists
    case configurationMissing
    case compareAndSwapFailed
    case ioFailure
}

public struct BackupFilesystemIdentity: Codable, Hashable, Sendable {
    public let device: UInt64
    public let inode: UInt64

    public init(device: UInt64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }
}

public enum BackupEnrollmentPhase: String, Codable, Hashable, Sendable {
    case pending
    case enabled
}

public struct BackupSchedulerMetadata: Hashable, Sendable {
    public let firstObservedRevisionPair: BackupRevisionPair?
    public let firstObservedAt: Date?
    public let dueAt: Date?
    public let lastCoveredRevisionPair: BackupRevisionPair?
    public let lastLocalVerificationAt: Date?
    public let lastFailure: BackupSemanticError?
    public let mutationRetryAttempt: Int
    public let retryDueAt: Date?

    public init(
        firstObservedRevisionPair: BackupRevisionPair? = nil,
        firstObservedAt: Date? = nil,
        dueAt: Date? = nil,
        lastCoveredRevisionPair: BackupRevisionPair? = nil,
        lastLocalVerificationAt: Date? = nil,
        lastFailure: BackupSemanticError? = nil,
        mutationRetryAttempt: Int = 0,
        retryDueAt: Date? = nil
    ) {
        self.firstObservedRevisionPair = firstObservedRevisionPair
        self.firstObservedAt = firstObservedAt
        self.dueAt = dueAt
        self.lastCoveredRevisionPair = lastCoveredRevisionPair
        self.lastLocalVerificationAt = lastLocalVerificationAt
        self.lastFailure = lastFailure
        self.mutationRetryAttempt = mutationRetryAttempt
        self.retryDueAt = retryDueAt
    }
}

public struct BackupPendingEnrollment: Sendable {
    public static let maximumBookmarkByteCount = 128 * 1_024

    public let bookmarkData: Data
    public let selectedDirectoryIdentity: BackupFilesystemIdentity
    public let repositoryDirectoryIdentity: BackupFilesystemIdentity
    public let descriptor: BackupSetDescriptor
    public let authorization: BackupDeviceAuthorization
    public let deviceSigningSeed: Data
    public let writerEpoch: BackupWriterEpoch
    public let retentionCount: BackupRetentionCount

    public init(
        bookmarkData: Data,
        selectedDirectoryIdentity: BackupFilesystemIdentity,
        repositoryDirectoryIdentity: BackupFilesystemIdentity,
        descriptor: BackupSetDescriptor,
        authorization: BackupDeviceAuthorization,
        deviceSigningSeed: Data,
        writerEpoch: BackupWriterEpoch,
        retentionCount: BackupRetentionCount = .default
    ) throws {
        guard !bookmarkData.isEmpty,
              bookmarkData.count <= Self.maximumBookmarkByteCount,
              selectedDirectoryIdentity.device == repositoryDirectoryIdentity.device,
              selectedDirectoryIdentity != repositoryDirectoryIdentity else {
            throw BackupLocalConfigurationStoreError.invalidRecord
        }
        try BackupKeyHierarchy.validateEnrollment(
            descriptor: descriptor,
            authorization: authorization,
            deviceSigningSeed: deviceSigningSeed
        )
        self.bookmarkData = bookmarkData
        self.selectedDirectoryIdentity = selectedDirectoryIdentity
        self.repositoryDirectoryIdentity = repositoryDirectoryIdentity
        self.descriptor = descriptor
        self.authorization = authorization
        self.deviceSigningSeed = deviceSigningSeed
        self.writerEpoch = writerEpoch
        self.retentionCount = retentionCount
    }
}

public struct BackupLocalConfiguration: Hashable, Sendable {
    public let revision: UInt64
    public let phase: BackupEnrollmentPhase
    public let enrollmentEpoch: BackupWriterEpoch
    public let configurationRootIdentity: BackupFilesystemIdentity
    public let bookmarkData: Data
    public let selectedDirectoryIdentity: BackupFilesystemIdentity
    public let repositoryDirectoryIdentity: BackupFilesystemIdentity
    public let descriptor: BackupSetDescriptor
    public let authorization: BackupDeviceAuthorization
    public let deviceSigningSeed: Data
    public let writerEpoch: BackupWriterEpoch
    public let automation: BackupAutomationConfiguration
    public let scheduler: BackupSchedulerMetadata
    public let verificationWitnesses: [BackupDurableFullReaderWitness]

    /// Identity-bearing fields that must remain stable for one admitted
    /// checkpoint writer. Preferences, scheduler metadata, bookmark refreshes,
    /// revisions, and existing witnesses intentionally are not part of this
    /// value: they can change without authorizing a different writer.
    var writerIdentity: BackupWriterIdentity {
        .init(
            enrollmentEpoch: enrollmentEpoch,
            configurationRootIdentity: configurationRootIdentity,
            selectedDirectoryIdentity: selectedDirectoryIdentity,
            repositoryDirectoryIdentity: repositoryDirectoryIdentity,
            descriptor: descriptor,
            authorization: authorization,
            deviceSigningSeed: deviceSigningSeed,
            writerEpoch: writerEpoch
        )
    }
}

struct BackupWriterIdentity: Hashable, Sendable {
    let enrollmentEpoch: BackupWriterEpoch
    let configurationRootIdentity: BackupFilesystemIdentity
    let selectedDirectoryIdentity: BackupFilesystemIdentity
    let repositoryDirectoryIdentity: BackupFilesystemIdentity
    let descriptor: BackupSetDescriptor
    let authorization: BackupDeviceAuthorization
    let deviceSigningSeed: Data
    let writerEpoch: BackupWriterEpoch
}

/// App-private, root-bound configuration storage. Initializing the value is
/// read-only; the private directory is created only by the first mutation.
// SAFETY: processLock serializes every filesystem transaction across store
// instances and stateLock protects this instance's pinned root identity.
public final class BackupLocalConfigurationStore: @unchecked Sendable {
    private static let recordName = "configuration.json"
    private static let lockName = ".configuration.lock"
    private static let maximumRecordByteCount = 512 * 1_024
    static let maximumVerificationWitnessCount = 512
    private static let processLock = NSLock()

    public let rootURL: URL
    private let stateLock = NSLock()
    private var pinnedRootIdentity: BackupFilesystemIdentity?

    public init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    public func load() async throws -> BackupLocalConfiguration? {
        do {
            return try withExclusiveAccess(createRoot: false) { rootDescriptor, rootIdentity in
                guard namedNodeExists(Self.recordName, at: rootDescriptor) else { return nil }
                return try readConfiguration(at: rootDescriptor, rootIdentity: rootIdentity).configuration
            }
        } catch BackupLocalConfigurationStoreError.configurationMissing {
            return nil
        }
    }

    public func createPending(
        _ pending: BackupPendingEnrollment
    ) async throws -> BackupLocalConfiguration {
        try withExclusiveAccess(createRoot: true) { rootDescriptor, rootIdentity in
            guard !namedNodeExists(Self.recordName, at: rootDescriptor) else {
                throw BackupLocalConfigurationStoreError.configurationAlreadyExists
            }
            let configuration = BackupLocalConfiguration(
                revision: 1,
                phase: .pending,
                enrollmentEpoch: pending.writerEpoch,
                configurationRootIdentity: rootIdentity,
                bookmarkData: pending.bookmarkData,
                selectedDirectoryIdentity: pending.selectedDirectoryIdentity,
                repositoryDirectoryIdentity: pending.repositoryDirectoryIdentity,
                descriptor: pending.descriptor,
                authorization: pending.authorization,
                deviceSigningSeed: pending.deviceSigningSeed,
                writerEpoch: pending.writerEpoch,
                automation: .init(isAutomaticBackupEnabled: false, retentionCount: pending.retentionCount),
                scheduler: .init(),
                verificationWitnesses: []
            )
            try write(configuration, at: rootDescriptor, exclusive: true)
            return configuration
        }
    }

    public func promotePending(
        enrollmentEpoch: BackupWriterEpoch,
        expectedRevision: UInt64
    ) async throws -> BackupLocalConfiguration {
        try withExclusiveAccess(createRoot: false) { rootDescriptor, rootIdentity in
            guard namedNodeExists(Self.recordName, at: rootDescriptor) else {
                throw BackupLocalConfigurationStoreError.configurationMissing
            }
            let stored = try readConfiguration(at: rootDescriptor, rootIdentity: rootIdentity)
            guard stored.configuration.phase == .pending,
                  stored.configuration.enrollmentEpoch == enrollmentEpoch,
                  stored.configuration.revision == expectedRevision,
                  expectedRevision < UInt64.max else {
                throw BackupLocalConfigurationStoreError.compareAndSwapFailed
            }
            let current = stored.configuration
            let promoted = BackupLocalConfiguration(
                revision: expectedRevision + 1,
                phase: .enabled,
                enrollmentEpoch: current.enrollmentEpoch,
                configurationRootIdentity: current.configurationRootIdentity,
                bookmarkData: current.bookmarkData,
                selectedDirectoryIdentity: current.selectedDirectoryIdentity,
                repositoryDirectoryIdentity: current.repositoryDirectoryIdentity,
                descriptor: current.descriptor,
                authorization: current.authorization,
                deviceSigningSeed: current.deviceSigningSeed,
                writerEpoch: current.writerEpoch,
                automation: .init(
                    isAutomaticBackupEnabled: false,
                    retentionCount: current.automation.retentionCount
                ),
                scheduler: current.scheduler,
                verificationWitnesses: current.verificationWitnesses
            )
            try ensureSameLeaf(stored.identity, named: Self.recordName, at: rootDescriptor)
            try write(promoted, at: rootDescriptor, exclusive: false)
            return promoted
        }
    }

    public func refreshPendingBookmark(
        _ bookmarkData: Data,
        enrollmentEpoch: BackupWriterEpoch,
        expectedRevision: UInt64
    ) async throws -> BackupLocalConfiguration {
        guard !bookmarkData.isEmpty,
              bookmarkData.count <= BackupPendingEnrollment.maximumBookmarkByteCount else {
            throw BackupLocalConfigurationStoreError.invalidRecord
        }
        return try withExclusiveAccess(createRoot: false) { rootDescriptor, rootIdentity in
            let stored = try readConfiguration(at: rootDescriptor, rootIdentity: rootIdentity)
            let current = stored.configuration
            guard current.phase == .pending,
                  current.enrollmentEpoch == enrollmentEpoch,
                  current.revision == expectedRevision,
                  expectedRevision < UInt64.max else {
                throw BackupLocalConfigurationStoreError.compareAndSwapFailed
            }
            let refreshed = BackupLocalConfiguration(
                revision: expectedRevision + 1,
                phase: current.phase,
                enrollmentEpoch: current.enrollmentEpoch,
                configurationRootIdentity: current.configurationRootIdentity,
                bookmarkData: bookmarkData,
                selectedDirectoryIdentity: current.selectedDirectoryIdentity,
                repositoryDirectoryIdentity: current.repositoryDirectoryIdentity,
                descriptor: current.descriptor,
                authorization: current.authorization,
                deviceSigningSeed: current.deviceSigningSeed,
                writerEpoch: current.writerEpoch,
                automation: current.automation,
                scheduler: current.scheduler,
                verificationWitnesses: current.verificationWitnesses
            )
            try ensureSameLeaf(stored.identity, named: Self.recordName, at: rootDescriptor)
            try write(refreshed, at: rootDescriptor, exclusive: false)
            return refreshed
        }
    }

    public func updateAutomation(
        isAutomaticBackupEnabled: Bool? = nil,
        retentionCount: BackupRetentionCount? = nil,
        expectedRevision: UInt64
    ) async throws -> BackupLocalConfiguration {
        try mutateEnabled(expectedRevision: expectedRevision) { current in
            let enabled = isAutomaticBackupEnabled
                ?? current.automation.isAutomaticBackupEnabled
            let scheduler = enabled ? current.scheduler : BackupSchedulerMetadata(
                lastCoveredRevisionPair: current.scheduler.lastCoveredRevisionPair,
                lastLocalVerificationAt: current.scheduler.lastLocalVerificationAt
            )
            return current.replacing(
                revision: expectedRevision + 1,
                automation: .init(
                    isAutomaticBackupEnabled: enabled,
                    retentionCount: retentionCount ?? current.automation.retentionCount
                ),
                scheduler: scheduler
            )
        }
    }

    /// Refreshes only the Powerbox bookmark for the same enabled writer. The
    /// exact revision CAS prevents a stale async directory operation from
    /// overwriting scheduler coverage, witnesses, or destructive reset state.
    public func refreshEnabledBookmark(
        _ bookmarkData: Data,
        expectedRevision: UInt64
    ) async throws -> BackupLocalConfiguration {
        guard !bookmarkData.isEmpty,
              bookmarkData.count <= BackupPendingEnrollment.maximumBookmarkByteCount else {
            throw BackupLocalConfigurationStoreError.invalidRecord
        }
        return try mutateEnabled(
            expectedRevision: expectedRevision,
            allowsBookmarkChange: true
        ) { current in
            current.replacing(
                revision: expectedRevision + 1,
                bookmarkData: bookmarkData
            )
        }
    }

    /// Records the first observation of one uncovered pair. Seeing the same
    /// pair after relaunch never resets its quiet-period clock.
    public func observeRevisionPair(
        _ pair: BackupRevisionPair,
        observedAt: Date,
        dueAt: Date,
        expectedRevision: UInt64
    ) async throws -> BackupLocalConfiguration {
        guard observedAt.timeIntervalSinceReferenceDate.isFinite,
              dueAt.timeIntervalSinceReferenceDate.isFinite,
              observedAt <= dueAt else {
            throw BackupLocalConfigurationStoreError.invalidRecord
        }
        let canonicalObservedAt = canonicalDate(observedAt)
        let canonicalDueAt = canonicalDate(dueAt)
        return try mutateEnabled(expectedRevision: expectedRevision) { current in
            let existing = current.scheduler
            let scheduler: BackupSchedulerMetadata
            if existing.lastCoveredRevisionPair == pair {
                scheduler = .init(
                    lastCoveredRevisionPair: existing.lastCoveredRevisionPair,
                    lastLocalVerificationAt: existing.lastLocalVerificationAt
                )
            } else if existing.firstObservedRevisionPair == pair,
                      let firstObservedAt = existing.firstObservedAt,
                      let existingDueAt = existing.dueAt {
                scheduler = .init(
                    firstObservedRevisionPair: pair,
                    firstObservedAt: firstObservedAt,
                    dueAt: existingDueAt,
                    lastCoveredRevisionPair: existing.lastCoveredRevisionPair,
                    lastLocalVerificationAt: existing.lastLocalVerificationAt,
                    lastFailure: existing.lastFailure,
                    mutationRetryAttempt: existing.mutationRetryAttempt,
                    retryDueAt: existing.retryDueAt
                )
            } else {
                scheduler = .init(
                    firstObservedRevisionPair: pair,
                    firstObservedAt: canonicalObservedAt,
                    dueAt: canonicalDueAt,
                    lastCoveredRevisionPair: existing.lastCoveredRevisionPair,
                    lastLocalVerificationAt: existing.lastLocalVerificationAt
                )
            }
            return current.replacing(
                revision: expectedRevision + 1,
                scheduler: scheduler
            )
        }
    }

    public func markBackupFailure(
        _ failure: BackupSemanticError,
        retryAttempt: Int,
        retryDueAt: Date?,
        expectedRevision: UInt64
    ) async throws -> BackupLocalConfiguration {
        guard (0...3).contains(retryAttempt),
              retryDueAt?.timeIntervalSinceReferenceDate.isFinite ?? true else {
            throw BackupLocalConfigurationStoreError.invalidRecord
        }
        let canonicalRetryDueAt = retryDueAt.map(canonicalDate)
        return try mutateEnabled(expectedRevision: expectedRevision) { current in
            let scheduler = current.scheduler
            return current.replacing(
                revision: expectedRevision + 1,
                scheduler: .init(
                    firstObservedRevisionPair: scheduler.firstObservedRevisionPair,
                    firstObservedAt: scheduler.firstObservedAt,
                    dueAt: scheduler.dueAt,
                    lastCoveredRevisionPair: scheduler.lastCoveredRevisionPair,
                    lastLocalVerificationAt: scheduler.lastLocalVerificationAt,
                    lastFailure: failure,
                    mutationRetryAttempt: retryAttempt,
                    retryDueAt: canonicalRetryDueAt
                )
            )
        }
    }

    public func markBackupSuccess(
        _ pair: BackupRevisionPair,
        verifiedAt: Date,
        expectedRevision: UInt64
    ) async throws -> BackupLocalConfiguration {
        guard verifiedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw BackupLocalConfigurationStoreError.invalidRecord
        }
        let canonicalVerifiedAt = canonicalDate(verifiedAt)
        return try mutateEnabled(expectedRevision: expectedRevision) { current in
            current.replacing(
                revision: expectedRevision + 1,
                scheduler: .init(
                    lastCoveredRevisionPair: pair,
                    lastLocalVerificationAt: canonicalVerifiedAt
                )
            )
        }
    }

    /// U6/U7 can call this before beginning a destructive reset. It makes the
    /// persisted scheduler barrier conservative without deleting the external
    /// repository or pretending to revoke copied device credentials.
    public func disableForDestructiveReset(
        expectedRevision: UInt64
    ) async throws -> BackupLocalConfiguration {
        try mutateEnabled(expectedRevision: expectedRevision) { current in
            current.replacing(
                revision: expectedRevision + 1,
                automation: .init(
                    isAutomaticBackupEnabled: false,
                    retentionCount: current.automation.retentionCount
                ),
                scheduler: .init(
                    lastCoveredRevisionPair: current.scheduler.lastCoveredRevisionPair,
                    lastLocalVerificationAt: current.scheduler.lastLocalVerificationAt
                )
            )
        }
    }

    /// Removes only the app-private writer profile. External checkpoints and
    /// repository contents are outside this transaction and are never touched.
    /// The restore transaction writes its typed intent before invoking this
    /// operation, so a crash cannot silently re-enable the old scheduler.
    public func removeForDestructiveReset() async throws {
        do {
            try withExclusiveAccess(createRoot: false) { rootDescriptor, rootIdentity in
                guard namedNodeExists(Self.recordName, at: rootDescriptor) else { return }
                let stored = try readConfiguration(
                    at: rootDescriptor,
                    rootIdentity: rootIdentity
                )
                try ensureSameLeaf(stored.identity, named: Self.recordName, at: rootDescriptor)
                guard unlinkat(rootDescriptor, Self.recordName, 0) == 0 else {
                    throw BackupLocalConfigurationStoreError.ioFailure
                }
                try synchronize(rootDescriptor)
            }
        } catch BackupLocalConfigurationStoreError.configurationMissing {
            return
        }
    }

    /// Durably registers only a full-reader witness for the exact active
    /// writer epoch. This is the final CAS of checkpoint publication.
    func appendVerificationWitness(
        _ witness: BackupDurableFullReaderWitness,
        expectedWriterIdentity: BackupWriterIdentity
    ) async throws -> BackupLocalConfiguration {
        try withExclusiveAccess(createRoot: false) { rootDescriptor, rootIdentity in
            let stored = try readConfiguration(at: rootDescriptor, rootIdentity: rootIdentity)
            let current = stored.configuration
            guard current.phase == .enabled,
                  current.writerIdentity == expectedWriterIdentity,
                  current.revision < UInt64.max,
                  current.writerEpoch == witness.writerEpoch,
                  current.descriptor.setID == witness.setID,
                  current.authorization.setID == witness.setID,
                  current.authorization.deviceID == witness.deviceID,
                  current.authorization.authorizationID == witness.authorizationID,
                  witness.sequence >= current.authorization.sequenceFloor,
                  !current.verificationWitnesses.contains(where: {
                    $0.checkpointID == witness.checkpointID
                  }) else {
                throw BackupLocalConfigurationStoreError.compareAndSwapFailed
            }
            guard current.verificationWitnesses.count < Self.maximumVerificationWitnessCount else {
                throw BackupLocalConfigurationStoreError.recordTooLarge
            }
            let updated = BackupLocalConfiguration(
                revision: current.revision + 1,
                phase: current.phase,
                enrollmentEpoch: current.enrollmentEpoch,
                configurationRootIdentity: current.configurationRootIdentity,
                bookmarkData: current.bookmarkData,
                selectedDirectoryIdentity: current.selectedDirectoryIdentity,
                repositoryDirectoryIdentity: current.repositoryDirectoryIdentity,
                descriptor: current.descriptor,
                authorization: current.authorization,
                deviceSigningSeed: current.deviceSigningSeed,
                writerEpoch: current.writerEpoch,
                automation: current.automation,
                scheduler: current.scheduler,
                verificationWitnesses: current.verificationWitnesses + [witness]
            )
            try ensureSameLeaf(stored.identity, named: Self.recordName, at: rootDescriptor)
            try write(updated, at: rootDescriptor, exclusive: false)
            return updated
        }
    }

    /// Removes the exact witness only after its repository leaf has been
    /// durably deleted. A crash before this CAS leaves an extra conservative
    /// witness; it never makes another checkpoint eligible for deletion.
    public func removeVerificationWitness(
        checkpointID: BackupCheckpointID,
        expectedConfigurationRevision: UInt64
    ) async throws -> BackupLocalConfiguration {
        try await removeVerificationWitness(
            checkpointID: checkpointID,
            expectedConfigurationRevision: expectedConfigurationRevision,
            beforeRemoval: {}
        )
    }

    /// Holds the configuration lease across the exact repository deletion so
    /// a retention preference update cannot race between the final revision
    /// fence and unlink. The repository lease is already held by the caller,
    /// preserving the global repository -> configuration lock order.
    func removeVerificationWitness(
        checkpointID: BackupCheckpointID,
        expectedConfigurationRevision: UInt64,
        beforeRemoval: @Sendable () throws -> Void
    ) async throws -> BackupLocalConfiguration {
        try withExclusiveAccess(createRoot: false) { rootDescriptor, rootIdentity in
            let stored = try readConfiguration(at: rootDescriptor, rootIdentity: rootIdentity)
            let current = stored.configuration
            guard current.phase == .enabled,
                  current.revision == expectedConfigurationRevision,
                  expectedConfigurationRevision < UInt64.max,
                  current.verificationWitnesses.contains(where: {
                      $0.checkpointID == checkpointID
                  }) else {
                throw BackupLocalConfigurationStoreError.compareAndSwapFailed
            }
            try beforeRemoval()
            let updated = BackupLocalConfiguration(
                revision: expectedConfigurationRevision + 1,
                phase: current.phase,
                enrollmentEpoch: current.enrollmentEpoch,
                configurationRootIdentity: current.configurationRootIdentity,
                bookmarkData: current.bookmarkData,
                selectedDirectoryIdentity: current.selectedDirectoryIdentity,
                repositoryDirectoryIdentity: current.repositoryDirectoryIdentity,
                descriptor: current.descriptor,
                authorization: current.authorization,
                deviceSigningSeed: current.deviceSigningSeed,
                writerEpoch: current.writerEpoch,
                automation: current.automation,
                scheduler: current.scheduler,
                verificationWitnesses: current.verificationWitnesses.filter {
                    $0.checkpointID != checkpointID
                }
            )
            try ensureSameLeaf(stored.identity, named: Self.recordName, at: rootDescriptor)
            try write(updated, at: rootDescriptor, exclusive: false)
            return updated
        }
    }

    public func abandonPending(
        enrollmentEpoch: BackupWriterEpoch,
        expectedRevision: UInt64
    ) async throws {
        try withExclusiveAccess(createRoot: false) { rootDescriptor, rootIdentity in
            let stored = try readConfiguration(at: rootDescriptor, rootIdentity: rootIdentity)
            guard stored.configuration.phase == .pending,
                  stored.configuration.enrollmentEpoch == enrollmentEpoch,
                  stored.configuration.revision == expectedRevision else {
                throw BackupLocalConfigurationStoreError.compareAndSwapFailed
            }
            try ensureSameLeaf(stored.identity, named: Self.recordName, at: rootDescriptor)
            guard unlinkat(rootDescriptor, Self.recordName, 0) == 0 else {
                throw BackupLocalConfigurationStoreError.ioFailure
            }
            try synchronize(rootDescriptor)
        }
    }

    private func mutateEnabled(
        expectedRevision: UInt64,
        allowsBookmarkChange: Bool = false,
        _ mutation: (BackupLocalConfiguration) throws -> BackupLocalConfiguration
    ) throws -> BackupLocalConfiguration {
        try withExclusiveAccess(createRoot: false) { rootDescriptor, rootIdentity in
            let stored = try readConfiguration(at: rootDescriptor, rootIdentity: rootIdentity)
            let current = stored.configuration
            guard current.phase == .enabled,
                  current.revision == expectedRevision,
                  expectedRevision < UInt64.max else {
                throw BackupLocalConfigurationStoreError.compareAndSwapFailed
            }
            let updated = try mutation(current)
            guard updated.revision == expectedRevision + 1,
                  updated.phase == current.phase,
                  updated.enrollmentEpoch == current.enrollmentEpoch,
                  updated.configurationRootIdentity == current.configurationRootIdentity,
                  (allowsBookmarkChange || updated.bookmarkData == current.bookmarkData),
                  !updated.bookmarkData.isEmpty,
                  updated.bookmarkData.count <= BackupPendingEnrollment.maximumBookmarkByteCount,
                  updated.selectedDirectoryIdentity == current.selectedDirectoryIdentity,
                  updated.repositoryDirectoryIdentity == current.repositoryDirectoryIdentity,
                  updated.descriptor == current.descriptor,
                  updated.authorization == current.authorization,
                  updated.deviceSigningSeed == current.deviceSigningSeed,
                  updated.writerEpoch == current.writerEpoch,
                  updated.verificationWitnesses == current.verificationWitnesses else {
                throw BackupLocalConfigurationStoreError.invalidRecord
            }
            try ensureSameLeaf(stored.identity, named: Self.recordName, at: rootDescriptor)
            try write(updated, at: rootDescriptor, exclusive: false)
            return updated
        }
    }

    private func withExclusiveAccess<T>(
        createRoot: Bool,
        _ body: (Int32, BackupFilesystemIdentity) throws -> T
    ) throws -> T {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        let rootDescriptor = try openRoot(create: createRoot)
        defer { Darwin.close(rootDescriptor) }
        let rootIdentity = try strictDirectoryIdentity(rootDescriptor, expectedMode: 0o700)
        try checkAndPinRoot(rootIdentity)

        let lockDescriptor = openat(
            rootDescriptor,
            Self.lockName,
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard lockDescriptor >= 0 else { throw BackupLocalConfigurationStoreError.ioFailure }
        defer { Darwin.close(lockDescriptor) }
        _ = fchmod(lockDescriptor, 0o600)
        _ = try strictRegularFileIdentity(lockDescriptor, expectedMode: 0o600)
        guard flock(lockDescriptor, LOCK_EX) == 0 else {
            throw BackupLocalConfigurationStoreError.ioFailure
        }
        defer { _ = flock(lockDescriptor, LOCK_UN) }

        let currentRoot = try strictDirectoryIdentity(rootDescriptor, expectedMode: 0o700)
        guard currentRoot == rootIdentity else {
            throw BackupLocalConfigurationStoreError.invalidRoot
        }
        return try body(rootDescriptor, rootIdentity)
    }

    private func openRoot(create: Bool) throws -> Int32 {
        if create {
            let parentURL = rootURL.deletingLastPathComponent()
            let leafName = rootURL.lastPathComponent
            guard !leafName.isEmpty, leafName != ".", leafName != ".." else {
                throw BackupLocalConfigurationStoreError.invalidRoot
            }
            let parentDescriptor = Darwin.open(
                parentURL.path,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard parentDescriptor >= 0 else {
                throw BackupLocalConfigurationStoreError.invalidRoot
            }
            defer { Darwin.close(parentDescriptor) }
            let created: Bool
            if mkdirat(parentDescriptor, leafName, 0o700) == 0 {
                created = true
            } else if errno == EEXIST {
                created = false
            } else {
                throw BackupLocalConfigurationStoreError.invalidRoot
            }
            let descriptor = openat(
                parentDescriptor,
                leafName,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard descriptor >= 0 else {
                throw BackupLocalConfigurationStoreError.invalidRoot
            }
            guard !created || fchmod(descriptor, 0o700) == 0 else {
                if descriptor >= 0 { Darwin.close(descriptor) }
                throw BackupLocalConfigurationStoreError.invalidRoot
            }
            return descriptor
        }
        let descriptor = Darwin.open(
            rootURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            if !create && errno == ENOENT { throw BackupLocalConfigurationStoreError.configurationMissing }
            throw BackupLocalConfigurationStoreError.invalidRoot
        }
        return descriptor
    }

    private func checkAndPinRoot(_ identity: BackupFilesystemIdentity) throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        if let pinnedRootIdentity {
            guard pinnedRootIdentity == identity else {
                throw BackupLocalConfigurationStoreError.invalidRoot
            }
        } else {
            pinnedRootIdentity = identity
        }
    }

    private func readConfiguration(
        at rootDescriptor: Int32,
        rootIdentity: BackupFilesystemIdentity
    ) throws -> (configuration: BackupLocalConfiguration, identity: BackupFilesystemIdentity) {
        let descriptor = openat(
            rootDescriptor,
            Self.recordName,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw BackupLocalConfigurationStoreError.invalidRecord
        }
        defer { Darwin.close(descriptor) }
        let identity = try strictRegularFileIdentity(descriptor, expectedMode: 0o600)
        let bytes = try boundedRead(descriptor, maximum: Self.maximumRecordByteCount)
        try ensureSameLeaf(identity, named: Self.recordName, at: rootDescriptor)
        let wire: WireRecord
        do {
            wire = try CanonicalVaultJSON.decode(WireRecord.self, from: bytes)
        } catch {
            throw BackupLocalConfigurationStoreError.invalidRecord
        }
        guard wire.magic == "KLG-BACKUP-LOCAL-1", wire.version == 1 else {
            throw BackupLocalConfigurationStoreError.invalidRecord
        }
        let configuration = try wire.configuration()
        guard configuration.configurationRootIdentity == rootIdentity,
              try CanonicalVaultJSON.encode(wire) == bytes else {
            throw BackupLocalConfigurationStoreError.invalidRecord
        }
        return (configuration, identity)
    }

    private func write(
        _ configuration: BackupLocalConfiguration,
        at rootDescriptor: Int32,
        exclusive: Bool
    ) throws {
        let wire = WireRecord(configuration)
        let bytes: Data
        do {
            bytes = try CanonicalVaultJSON.encode(wire)
        } catch {
            throw BackupLocalConfigurationStoreError.invalidRecord
        }
        guard bytes.count <= Self.maximumRecordByteCount else {
            throw BackupLocalConfigurationStoreError.recordTooLarge
        }
        let workName = ".configuration.\(UUID().uuidString).work"
        let descriptor = openat(
            rootDescriptor,
            workName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard descriptor >= 0 else { throw BackupLocalConfigurationStoreError.ioFailure }
        var published = false
        defer {
            Darwin.close(descriptor)
            if !published { _ = unlinkat(rootDescriptor, workName, 0) }
        }
        guard fchmod(descriptor, 0o600) == 0 else {
            throw BackupLocalConfigurationStoreError.ioFailure
        }
        try writeAll(bytes, to: descriptor)
        try synchronize(descriptor)
        _ = try strictRegularFileIdentity(descriptor, expectedMode: 0o600)

        let result: Int32
        if exclusive {
            result = renameatx_np(
                rootDescriptor,
                workName,
                rootDescriptor,
                Self.recordName,
                UInt32(RENAME_EXCL)
            )
        } else {
            result = renameat(rootDescriptor, workName, rootDescriptor, Self.recordName)
        }
        guard result == 0 else {
            if exclusive && errno == EEXIST {
                throw BackupLocalConfigurationStoreError.configurationAlreadyExists
            }
            throw BackupLocalConfigurationStoreError.ioFailure
        }
        published = true
        try synchronize(rootDescriptor)
        let loaded = try readConfiguration(
            at: rootDescriptor,
            rootIdentity: configuration.configurationRootIdentity
        ).configuration
        guard loaded == configuration else {
            throw BackupLocalConfigurationStoreError.invalidRecord
        }
    }

}

private struct WireRecord: Codable {
    let magic: String
    let version: Int
    let revision: UInt64
    let phase: BackupEnrollmentPhase
    let enrollmentEpoch: Data
    let configurationRootIdentity: BackupFilesystemIdentity
    let bookmarkData: Data
    let selectedDirectoryIdentity: BackupFilesystemIdentity
    let repositoryDirectoryIdentity: BackupFilesystemIdentity
    let descriptor: Data
    let authorization: Data
    let deviceSigningSeed: Data
    let writerEpoch: Data
    let automaticEnabled: Bool
    let retentionCount: Int
    let scheduler: WireScheduler
    let verificationWitnesses: [WireWitness]

    init(_ configuration: BackupLocalConfiguration) {
        magic = "KLG-BACKUP-LOCAL-1"
        version = 1
        revision = configuration.revision
        phase = configuration.phase
        enrollmentEpoch = configuration.enrollmentEpoch.bytes
        configurationRootIdentity = configuration.configurationRootIdentity
        bookmarkData = configuration.bookmarkData
        selectedDirectoryIdentity = configuration.selectedDirectoryIdentity
        repositoryDirectoryIdentity = configuration.repositoryDirectoryIdentity
        descriptor = configuration.descriptor.canonicalBytes
        authorization = configuration.authorization.canonicalBytes
        deviceSigningSeed = configuration.deviceSigningSeed
        writerEpoch = configuration.writerEpoch.bytes
        automaticEnabled = configuration.automation.isAutomaticBackupEnabled
        retentionCount = configuration.automation.retentionCount.value
        scheduler = WireScheduler(configuration.scheduler)
        verificationWitnesses = configuration.verificationWitnesses.map(WireWitness.init)
    }

    func configuration() throws -> BackupLocalConfiguration {
        guard verificationWitnesses.count
                <= BackupLocalConfigurationStore.maximumVerificationWitnessCount,
              Set(verificationWitnesses.map(\.checkpointID)).count
                == verificationWitnesses.count else {
            throw BackupLocalConfigurationStoreError.invalidRecord
        }
        let descriptor = try BackupSetDescriptor.decodeCanonical(descriptor)
        let authorization = try BackupDeviceAuthorization.decodeCanonical(authorization)
        try BackupKeyHierarchy.validateEnrollment(
            descriptor: descriptor,
            authorization: authorization,
            deviceSigningSeed: deviceSigningSeed
        )
        return BackupLocalConfiguration(
            revision: revision,
            phase: phase,
            enrollmentEpoch: try .init(bytes: enrollmentEpoch),
            configurationRootIdentity: configurationRootIdentity,
            bookmarkData: bookmarkData,
            selectedDirectoryIdentity: selectedDirectoryIdentity,
            repositoryDirectoryIdentity: repositoryDirectoryIdentity,
            descriptor: descriptor,
            authorization: authorization,
            deviceSigningSeed: deviceSigningSeed,
            writerEpoch: try .init(bytes: writerEpoch),
            automation: .init(
                isAutomaticBackupEnabled: automaticEnabled,
                retentionCount: try .init(retentionCount)
            ),
            scheduler: try scheduler.value(),
            verificationWitnesses: try verificationWitnesses.map { try $0.value() }
        )
    }
}

private struct WireScheduler: Codable {
    let firstObservedRevisionPair: WireRevisionPair?
    let firstObservedMilliseconds: Int64?
    let dueMilliseconds: Int64?
    let lastCoveredRevisionPair: WireRevisionPair?
    let lastLocalVerificationMilliseconds: Int64?
    let lastFailure: String?
    let mutationRetryAttempt: Int?
    let retryDueMilliseconds: Int64?

    init(_ value: BackupSchedulerMetadata) {
        firstObservedRevisionPair = value.firstObservedRevisionPair.map(WireRevisionPair.init)
        firstObservedMilliseconds = value.firstObservedAt.map(milliseconds)
        dueMilliseconds = value.dueAt.map(milliseconds)
        lastCoveredRevisionPair = value.lastCoveredRevisionPair.map(WireRevisionPair.init)
        lastLocalVerificationMilliseconds = value.lastLocalVerificationAt.map(milliseconds)
        lastFailure = value.lastFailure?.rawValue
        mutationRetryAttempt = value.mutationRetryAttempt
        retryDueMilliseconds = value.retryDueAt.map(milliseconds)
    }

    func value() throws -> BackupSchedulerMetadata {
        let retryAttempt = mutationRetryAttempt ?? 0
        let failure: BackupSemanticError?
        if let lastFailure {
            guard let decoded = BackupSemanticError(rawValue: lastFailure) else {
                throw BackupLocalConfigurationStoreError.invalidRecord
            }
            failure = decoded
        } else {
            failure = nil
        }
        guard (0...3).contains(retryAttempt),
              retryAttempt > 0 || retryDueMilliseconds == nil else {
            throw BackupLocalConfigurationStoreError.invalidRecord
        }
        return .init(
            firstObservedRevisionPair: try firstObservedRevisionPair?.value(),
            firstObservedAt: firstObservedMilliseconds.map(date),
            dueAt: dueMilliseconds.map(date),
            lastCoveredRevisionPair: try lastCoveredRevisionPair?.value(),
            lastLocalVerificationAt: lastLocalVerificationMilliseconds.map(date),
            lastFailure: failure,
            mutationRetryAttempt: retryAttempt,
            retryDueAt: retryDueMilliseconds.map(date)
        )
    }
}

private extension BackupLocalConfiguration {
    func replacing(
        revision: UInt64,
        bookmarkData: Data? = nil,
        automation: BackupAutomationConfiguration? = nil,
        scheduler: BackupSchedulerMetadata? = nil
    ) -> BackupLocalConfiguration {
        BackupLocalConfiguration(
            revision: revision,
            phase: phase,
            enrollmentEpoch: enrollmentEpoch,
            configurationRootIdentity: configurationRootIdentity,
            bookmarkData: bookmarkData ?? self.bookmarkData,
            selectedDirectoryIdentity: selectedDirectoryIdentity,
            repositoryDirectoryIdentity: repositoryDirectoryIdentity,
            descriptor: descriptor,
            authorization: authorization,
            deviceSigningSeed: deviceSigningSeed,
            writerEpoch: writerEpoch,
            automation: automation ?? self.automation,
            scheduler: scheduler ?? self.scheduler,
            verificationWitnesses: verificationWitnesses
        )
    }
}

private struct WireRevisionPair: Codable {
    let vault: WireRevision
    let lanInbox: WireRevision

    init(_ value: BackupRevisionPair) {
        vault = .init(value.vault)
        lanInbox = .init(value.lanInbox)
    }

    func value() throws -> BackupRevisionPair {
        try .init(vault: vault.value(), lanInbox: lanInbox.value())
    }
}

private struct WireRevision: Codable {
    let generation: UInt64
    let commitID: UUID
    let manifestDigest: Data

    init(_ value: BackupRevision) {
        generation = value.generation
        commitID = value.commitID
        manifestDigest = value.manifestDigest
    }

    func value() throws -> BackupRevision {
        try .init(generation: generation, commitID: commitID, manifestDigest: manifestDigest)
    }
}

private struct WireWitness: Codable {
    let setID: Data
    let checkpointID: Data
    let deviceID: Data
    let authorizationID: Data
    let sequence: UInt64
    let commitmentDigest: Data
    let commitmentByteCount: UInt64
    let writerEpoch: Data
    let repositoryIdentityDigest: Data
    let continuousObservationStartedMilliseconds: Int64
    let lastObservedMilliseconds: Int64

    init(_ value: BackupDurableFullReaderWitness) {
        setID = value.setID.bytes
        checkpointID = value.checkpointID.bytes
        deviceID = value.deviceID.bytes
        authorizationID = value.authorizationID.bytes
        sequence = value.sequence
        commitmentDigest = value.commitment.digest
        commitmentByteCount = value.commitment.ciphertextByteCount
        writerEpoch = value.writerEpoch.bytes
        repositoryIdentityDigest = value.repositoryIdentityDigest
        continuousObservationStartedMilliseconds = milliseconds(value.continuousObservationStartedAt)
        lastObservedMilliseconds = milliseconds(value.lastObservedAt)
    }

    func value() throws -> BackupDurableFullReaderWitness {
        let checkpoint = try BackupPublicCheckpoint(
            setID: try .init(bytes: setID),
            checkpointID: try .init(bytes: checkpointID),
            deviceID: try .init(bytes: deviceID),
            authorizationID: try .init(bytes: authorizationID),
            sequence: sequence,
            commitment: try .init(
                digest: commitmentDigest,
                ciphertextByteCount: commitmentByteCount
            )
        )
        return try .init(
            checkpoint: checkpoint,
            writerEpoch: .init(bytes: writerEpoch),
            repositoryIdentityDigest: repositoryIdentityDigest,
            continuousObservationStartedAt: date(continuousObservationStartedMilliseconds),
            lastObservedAt: date(lastObservedMilliseconds)
        )
    }
}

private func milliseconds(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 * 1_000).rounded())
}

private func date(_ milliseconds: Int64) -> Date {
    Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
}

private func canonicalDate(_ value: Date) -> Date {
    date(milliseconds(value))
}

private func strictDirectoryIdentity(
    _ descriptor: Int32,
    expectedMode: mode_t
) throws -> BackupFilesystemIdentity {
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
          (metadata.st_mode & S_IFMT) == S_IFDIR,
          metadata.st_uid == geteuid(),
          metadata.st_nlink >= 2,
          metadata.st_mode & 0o777 == expectedMode else {
        throw BackupLocalConfigurationStoreError.invalidRoot
    }
    return .init(device: UInt64(metadata.st_dev), inode: UInt64(metadata.st_ino))
}

private func strictRegularFileIdentity(
    _ descriptor: Int32,
    expectedMode: mode_t
) throws -> BackupFilesystemIdentity {
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
          (metadata.st_mode & S_IFMT) == S_IFREG,
          metadata.st_uid == geteuid(),
          metadata.st_nlink == 1,
          metadata.st_mode & 0o777 == expectedMode else {
        throw BackupLocalConfigurationStoreError.invalidRecord
    }
    return .init(device: UInt64(metadata.st_dev), inode: UInt64(metadata.st_ino))
}

private func namedNodeExists(_ name: String, at parent: Int32) -> Bool {
    var metadata = stat()
    return name.withCString { fstatat(parent, $0, &metadata, AT_SYMLINK_NOFOLLOW) } == 0
}

private func ensureSameLeaf(
    _ expected: BackupFilesystemIdentity,
    named name: String,
    at parent: Int32
) throws {
    var metadata = stat()
    guard name.withCString({ fstatat(parent, $0, &metadata, AT_SYMLINK_NOFOLLOW) }) == 0,
          (metadata.st_mode & S_IFMT) == S_IFREG,
          metadata.st_uid == geteuid(),
          metadata.st_nlink == 1,
          metadata.st_mode & 0o777 == 0o600,
          BackupFilesystemIdentity(
            device: UInt64(metadata.st_dev),
            inode: UInt64(metadata.st_ino)
          ) == expected else {
        throw BackupLocalConfigurationStoreError.invalidRecord
    }
}

private func boundedRead(_ descriptor: Int32, maximum: Int) throws -> Data {
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
          metadata.st_size >= 0,
          metadata.st_size <= maximum else {
        throw BackupLocalConfigurationStoreError.recordTooLarge
    }
    var result = Data()
    result.reserveCapacity(Int(metadata.st_size))
    var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
    while true {
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        if count == 0 { break }
        guard count > 0 else {
            if errno == EINTR { continue }
            throw BackupLocalConfigurationStoreError.ioFailure
        }
        guard result.count <= maximum - count else {
            throw BackupLocalConfigurationStoreError.recordTooLarge
        }
        result.append(contentsOf: buffer[..<count])
    }
    return result
}

private func writeAll(_ data: Data, to descriptor: Int32) throws {
    try data.withUnsafeBytes { rawBuffer in
        var offset = 0
        while offset < rawBuffer.count {
            let count = Darwin.write(
                descriptor,
                rawBuffer.baseAddress!.advanced(by: offset),
                rawBuffer.count - offset
            )
            guard count > 0 else {
                if count < 0 && errno == EINTR { continue }
                throw BackupLocalConfigurationStoreError.ioFailure
            }
            offset += count
        }
    }
}

private func synchronize(_ descriptor: Int32) throws {
    if fcntl(descriptor, F_FULLFSYNC) == 0 { return }
    guard fsync(descriptor) == 0 else { throw BackupLocalConfigurationStoreError.ioFailure }
}

public enum BackupEnrollmentRepositoryError: Error, Equatable, Sendable {
    case offline
    case identityChanged
    case identityConflict
    case ioFailure
}

/// The hostile-directory portion of enrollment publication lives in Platform;
/// App only supplies a currently-authorized URL and the pinned directory
/// identity obtained while handling the security-scoped bookmark.
public struct BackupEnrollmentRepository: Sendable {
    public init() {}

    public func publish(
        descriptor: BackupSetDescriptor,
        authorization: BackupDeviceAuthorization,
        repositoryURL: URL,
        expectedIdentity: BackupFilesystemIdentity
    ) throws {
        guard authorization.setID == descriptor.setID,
              authorization.descriptorDigest == BackupKeyHierarchy.digest(descriptor.canonicalBytes) else {
            throw BackupEnrollmentRepositoryError.identityConflict
        }
        let repositoryDescriptor = Darwin.open(
            repositoryURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard repositoryDescriptor >= 0 else {
            throw BackupEnrollmentRepositoryError.offline
        }
        defer { Darwin.close(repositoryDescriptor) }
        guard try enrollmentDirectoryIdentity(repositoryDescriptor) == expectedIdentity else {
            throw BackupEnrollmentRepositoryError.identityChanged
        }
        try enrollmentExclusiveWriteOrValidate(
            descriptor.canonicalBytes,
            named: "backup-set-descriptor.bin",
            at: repositoryDescriptor
        )
        try enrollmentExclusiveWriteOrValidate(
            authorization.canonicalBytes,
            named: "writer-authorization.bin",
            at: repositoryDescriptor
        )
        try enrollmentSynchronize(repositoryDescriptor)
        guard try enrollmentStrictRead(
            "backup-set-descriptor.bin",
            at: repositoryDescriptor
        ) == descriptor.canonicalBytes,
        try enrollmentStrictRead(
            "writer-authorization.bin",
            at: repositoryDescriptor
        ) == authorization.canonicalBytes,
        try enrollmentDirectoryIdentity(repositoryDescriptor) == expectedIdentity else {
            throw BackupEnrollmentRepositoryError.identityConflict
        }
    }
}

private func enrollmentDirectoryIdentity(
    _ descriptor: Int32
) throws -> BackupFilesystemIdentity {
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
          (metadata.st_mode & S_IFMT) == S_IFDIR,
          metadata.st_uid == geteuid(),
          metadata.st_nlink >= 2,
          metadata.st_mode & 0o777 == 0o700 else {
        throw BackupEnrollmentRepositoryError.identityChanged
    }
    return .init(device: UInt64(metadata.st_dev), inode: UInt64(metadata.st_ino))
}

private func enrollmentExclusiveWriteOrValidate(
    _ bytes: Data,
    named name: String,
    at parent: Int32
) throws {
    let descriptor = openat(
        parent,
        name,
        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
        0o600
    )
    if descriptor < 0 {
        guard errno == EEXIST,
              try enrollmentStrictRead(name, at: parent) == bytes else {
            throw BackupEnrollmentRepositoryError.identityConflict
        }
        return
    }
    var completed = false
    defer {
        Darwin.close(descriptor)
        if !completed { _ = unlinkat(parent, name, 0) }
    }
    guard fchmod(descriptor, 0o600) == 0 else {
        throw BackupEnrollmentRepositoryError.ioFailure
    }
    do {
        try writeAll(bytes, to: descriptor)
        try enrollmentSynchronize(descriptor)
    } catch {
        throw BackupEnrollmentRepositoryError.ioFailure
    }
    _ = try enrollmentStrictRegularIdentity(descriptor)
    completed = true
}

private func enrollmentStrictRead(_ name: String, at parent: Int32) throws -> Data {
    let descriptor = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
        throw BackupEnrollmentRepositoryError.identityConflict
    }
    defer { Darwin.close(descriptor) }
    _ = try enrollmentStrictRegularIdentity(descriptor)
    do {
        return try boundedRead(descriptor, maximum: 256 * 1_024)
    } catch {
        throw BackupEnrollmentRepositoryError.identityConflict
    }
}

private func enrollmentStrictRegularIdentity(
    _ descriptor: Int32
) throws -> BackupFilesystemIdentity {
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
          (metadata.st_mode & S_IFMT) == S_IFREG,
          metadata.st_uid == geteuid(),
          metadata.st_nlink == 1,
          metadata.st_mode & 0o777 == 0o600,
          metadata.st_size >= 0,
          metadata.st_size <= 256 * 1_024 else {
        throw BackupEnrollmentRepositoryError.identityConflict
    }
    return .init(device: UInt64(metadata.st_dev), inode: UInt64(metadata.st_ino))
}

private func enrollmentSynchronize(_ descriptor: Int32) throws {
    if fcntl(descriptor, F_FULLFSYNC) == 0 { return }
    guard fsync(descriptor) == 0 else { throw BackupEnrollmentRepositoryError.ioFailure }
}
