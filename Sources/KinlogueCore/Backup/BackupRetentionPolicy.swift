import Foundation

public struct BackupRetentionCount: Hashable, Sendable {
    public static let allowedRange = 2...30
    public static let `default` = try! BackupRetentionCount(5)

    public let value: Int

    public init(_ value: Int) throws {
        guard Self.allowedRange.contains(value) else {
            throw BackupContractError.invalidField
        }
        self.value = value
    }
}

public struct BackupPublicCheckpoint: Hashable, Sendable {
    public let setID: BackupSetID
    public let checkpointID: BackupCheckpointID
    public let deviceID: BackupDeviceID
    public let authorizationID: BackupAuthorizationID
    public let sequence: UInt64
    public let commitment: BackupCiphertextCommitment

    public init(
        setID: BackupSetID,
        checkpointID: BackupCheckpointID,
        deviceID: BackupDeviceID,
        authorizationID: BackupAuthorizationID,
        sequence: UInt64,
        commitment: BackupCiphertextCommitment
    ) throws {
        self.setID = setID
        self.checkpointID = checkpointID
        self.deviceID = deviceID
        self.authorizationID = authorizationID
        self.sequence = sequence
        self.commitment = commitment
    }
}

public struct BackupRetentionCandidate: Hashable, Sendable {
    public let origin: BackupCheckpointOrigin
    public let verification: BackupPublicVerification
    /// Opaque, local-only identity of the exact materialized repository leaf.
    /// It is never derived from a path and is not part of the signed checkpoint.
    public let repositoryIdentityDigest: Data?

    public init(
        origin: BackupCheckpointOrigin,
        verification: BackupPublicVerification,
        repositoryIdentityDigest: Data? = nil
    ) {
        self.origin = origin
        self.verification = verification
        self.repositoryIdentityDigest = repositoryIdentityDigest
    }
}

/// A witness is issued by Platform only after a formally published checkpoint
/// passes a DEK-backed full reader and graph validation at its final URL and the
/// witness record itself is durably committed. Core intentionally cannot create
/// or verify cryptographic proof; it only matches this result contract exactly.
public struct BackupDurableFullReaderWitness: Hashable, Sendable {
    public static let conservativeDwell: TimeInterval = 24 * 60 * 60

    public let setID: BackupSetID
    public let checkpointID: BackupCheckpointID
    public let deviceID: BackupDeviceID
    public let authorizationID: BackupAuthorizationID
    public let sequence: UInt64
    public let commitment: BackupCiphertextCommitment
    public let writerEpoch: BackupWriterEpoch
    public let repositoryIdentityDigest: Data
    public let continuousObservationStartedAt: Date
    public let lastObservedAt: Date

    public init(
        checkpoint: BackupPublicCheckpoint,
        writerEpoch: BackupWriterEpoch,
        repositoryIdentityDigest: Data,
        continuousObservationStartedAt: Date,
        lastObservedAt: Date
    ) throws {
        guard repositoryIdentityDigest.count == 32,
              continuousObservationStartedAt.timeIntervalSinceReferenceDate.isFinite,
              lastObservedAt.timeIntervalSinceReferenceDate.isFinite,
              continuousObservationStartedAt <= lastObservedAt else {
            throw BackupContractError.invalidField
        }
        setID = checkpoint.setID
        checkpointID = checkpoint.checkpointID
        deviceID = checkpoint.deviceID
        authorizationID = checkpoint.authorizationID
        sequence = checkpoint.sequence
        commitment = checkpoint.commitment
        self.writerEpoch = writerEpoch
        self.repositoryIdentityDigest = repositoryIdentityDigest
        self.continuousObservationStartedAt = continuousObservationStartedAt
        self.lastObservedAt = lastObservedAt
    }

    public func replacingWriterEpoch(_ writerEpoch: BackupWriterEpoch) throws -> Self {
        try Self(
            checkpoint: .init(
                setID: setID,
                checkpointID: checkpointID,
                deviceID: deviceID,
                authorizationID: authorizationID,
                sequence: sequence,
                commitment: commitment
            ),
            writerEpoch: writerEpoch,
            repositoryIdentityDigest: repositoryIdentityDigest,
            continuousObservationStartedAt: continuousObservationStartedAt,
            lastObservedAt: lastObservedAt
        )
    }

    func exactlyMatches(
        _ checkpoint: BackupPublicCheckpoint,
        writerEpoch expectedEpoch: BackupWriterEpoch
    ) -> Bool {
        writerEpoch == expectedEpoch
            && setID == checkpoint.setID
            && checkpointID == checkpoint.checkpointID
            && deviceID == checkpoint.deviceID
            && authorizationID == checkpoint.authorizationID
            && sequence == checkpoint.sequence
            && commitment == checkpoint.commitment
    }
}

public struct BackupRetentionContext: Hashable, Sendable {
    public let currentSetID: BackupSetID
    public let currentWriterEpoch: BackupWriterEpoch
    public let retentionCount: BackupRetentionCount
    public let history: BackupRepositoryHistory
    public let continuity: BackupObservationContinuity
    public let now: Date
    public let previousEvaluationAt: Date?
    public let completedNewLocalVerification: Bool

    public init(
        currentSetID: BackupSetID,
        currentWriterEpoch: BackupWriterEpoch,
        retentionCount: BackupRetentionCount,
        history: BackupRepositoryHistory,
        continuity: BackupObservationContinuity,
        now: Date,
        previousEvaluationAt: Date?,
        completedNewLocalVerification: Bool
    ) {
        self.currentSetID = currentSetID
        self.currentWriterEpoch = currentWriterEpoch
        self.retentionCount = retentionCount
        self.history = history
        self.continuity = continuity
        self.now = now
        self.previousEvaluationAt = previousEvaluationAt
        self.completedNewLocalVerification = completedNewLocalVerification
    }
}

public enum BackupRetentionBlocker: String, CaseIterable, Hashable, Sendable {
    case historyFork
    case continuityUnproven
    case clockRollback
    case newVerificationRequired
    case latestSafetySetIncomplete
}

public struct BackupRetentionPlan: Hashable, Sendable {
    public let keep: [BackupCheckpointID]
    public let pending: [BackupCheckpointID]
    public let delete: [BackupCheckpointID]
    public let blocker: BackupRetentionBlocker?
    public let unmanagedCandidateCount: Int
}

public enum BackupRetentionPolicy {
    private struct VerifiedCandidate {
        let point: BackupPublicCheckpoint
        let repositoryIdentityDigest: Data?
    }

    public static func plan(
        candidates: [BackupRetentionCandidate],
        witnesses: [BackupDurableFullReaderWitness],
        context: BackupRetentionContext
    ) -> BackupRetentionPlan {
        var unmanagedCandidateCount = 0
        var currentPoints: [VerifiedCandidate] = []
        for candidate in candidates {
            guard case let .verified(point) = candidate.verification,
                  point.setID == context.currentSetID else {
                unmanagedCandidateCount += 1
                continue
            }
            currentPoints.append(.init(
                point: point,
                repositoryIdentityDigest: candidate.repositoryIdentityDigest
            ))
        }
        currentPoints.sort(by: precedes)

        let keepAll = currentPoints.map(\.point.checkpointID)
        func blocked(_ blocker: BackupRetentionBlocker) -> BackupRetentionPlan {
            BackupRetentionPlan(
                keep: keepAll,
                pending: [],
                delete: [],
                blocker: blocker,
                unmanagedCandidateCount: unmanagedCandidateCount
            )
        }

        if case .fork = context.history { return blocked(.historyFork) }
        guard context.continuity == .proven else { return blocked(.continuityUnproven) }
        guard context.now.timeIntervalSinceReferenceDate.isFinite,
              context.previousEvaluationAt.map({ $0 <= context.now }) ?? true,
              witnesses.allSatisfy({ $0.lastObservedAt <= context.now }) else {
            return blocked(.clockRollback)
        }
        guard context.completedNewLocalVerification else {
            return blocked(.newVerificationRequired)
        }

        let checkpointGroups = Dictionary(grouping: currentPoints, by: \.point.checkpointID)
        let sequenceGroups = Dictionary(grouping: currentPoints, by: \.point.sequence)
        guard checkpointGroups.values.allSatisfy({ $0.count == 1 }),
              sequenceGroups.values.allSatisfy({ $0.count == 1 }) else {
            return blocked(.historyFork)
        }

        let witnessGroups = Dictionary(grouping: witnesses, by: \.checkpointID)
        func exactWitness(for candidate: VerifiedCandidate) -> BackupDurableFullReaderWitness? {
            let point = candidate.point
            guard let identity = candidate.repositoryIdentityDigest,
                  identity.count == 32,
                  let group = witnessGroups[point.checkpointID], group.count == 1,
                  let witness = group.first,
                  witness.repositoryIdentityDigest == identity,
                  witness.exactlyMatches(point, writerEpoch: context.currentWriterEpoch) else {
                return nil
            }
            return witness
        }

        let target = context.retentionCount.value
        guard currentPoints.count >= target else {
            return blocked(.latestSafetySetIncomplete)
        }
        let safetySet = currentPoints.suffix(target)
        guard safetySet.allSatisfy({ exactWitness(for: $0) != nil }) else {
            return blocked(.latestSafetySetIncomplete)
        }

        let safetyIDs = Set(safetySet.map(\.point.checkpointID))
        var keep = currentPoints.filter {
            safetyIDs.contains($0.point.checkpointID)
        }.map(\.point.checkpointID)
        var pending: [BackupCheckpointID] = []
        var delete: [BackupCheckpointID] = []
        for candidate in currentPoints.dropLast(target) {
            guard let witness = exactWitness(for: candidate) else {
                keep.append(candidate.point.checkpointID)
                continue
            }
            let dwell = context.now.timeIntervalSince(witness.continuousObservationStartedAt)
            guard dwell >= BackupDurableFullReaderWitness.conservativeDwell else {
                pending.append(candidate.point.checkpointID)
                continue
            }
            delete.append(candidate.point.checkpointID)
        }

        return BackupRetentionPlan(
            keep: keep,
            pending: pending,
            delete: delete,
            blocker: nil,
            unmanagedCandidateCount: unmanagedCandidateCount
        )
    }

    private static func precedes(
        _ lhs: VerifiedCandidate,
        _ rhs: VerifiedCandidate
    ) -> Bool {
        if lhs.point.sequence != rhs.point.sequence {
            return lhs.point.sequence < rhs.point.sequence
        }
        return lhs.point.checkpointID.bytes.lexicographicallyPrecedes(
            rhs.point.checkpointID.bytes
        )
    }
}
