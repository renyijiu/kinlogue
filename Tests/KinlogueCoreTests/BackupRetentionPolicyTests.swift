import Foundation
import Testing
@testable import KinlogueCore

@Test
func retentionCountDefaultsToFiveAndAllowsOnlyTwoThroughThirty() throws {
    #expect(BackupRetentionCount.default.value == 5)
    #expect(try BackupRetentionCount(2).value == 2)
    #expect(try BackupRetentionCount(5).value == 5)
    #expect(try BackupRetentionCount(30).value == 30)
    #expect(throws: BackupContractError.self) { _ = try BackupRetentionCount(1) }
    #expect(throws: BackupContractError.self) { _ = try BackupRetentionCount(31) }
}

@Test
func mixedManualAndAutomaticPointsShareOneRetentionPool() throws {
    let fixture = try RetentionFixture(count: 7)
    let plan = BackupRetentionPolicy.plan(
        candidates: fixture.candidates,
        witnesses: fixture.witnesses,
        context: fixture.context(retention: 5)
    )

    #expect(plan.blocker == nil)
    #expect(plan.keep.count == 5)
    #expect(plan.delete == [fixture.checkpointIDs[0], fixture.checkpointIDs[1]])
    #expect(plan.pending.isEmpty)
    #expect(Set(plan.keep + plan.delete) == Set(fixture.checkpointIDs))
}

@Test
func dwellIsConservativeAndNeverUsesFilesystemModificationTime() throws {
    let fixture = try RetentionFixture(count: 7, dwellHours: 23)
    let plan = BackupRetentionPolicy.plan(
        candidates: fixture.candidates,
        witnesses: fixture.witnesses,
        context: fixture.context(retention: 5)
    )

    #expect(plan.delete.isEmpty)
    #expect(plan.pending == [fixture.checkpointIDs[0], fixture.checkpointIDs[1]])
    #expect(plan.keep.count == 5)
}

@Test
func historyForkClockRollbackAndIncompleteLatestSafetySetProduceNoDeletes() throws {
    let fixture = try RetentionFixture(count: 7)

    let forked = BackupRetentionPolicy.plan(
        candidates: fixture.candidates,
        witnesses: fixture.witnesses,
        context: fixture.context(retention: 5, history: .fork(.sameSequenceDifferentCommitment))
    )
    #expect(forked.delete.isEmpty)
    #expect(forked.blocker == .historyFork)

    let rollback = BackupRetentionPolicy.plan(
        candidates: fixture.candidates,
        witnesses: fixture.witnesses,
        context: fixture.context(retention: 5, previousEvaluationAt: fixture.now.addingTimeInterval(1))
    )
    #expect(rollback.delete.isEmpty)
    #expect(rollback.blocker == .clockRollback)

    let newestID = try #require(fixture.checkpointIDs.last)
    let incomplete = BackupRetentionPolicy.plan(
        candidates: fixture.candidates,
        witnesses: fixture.witnesses.filter { $0.checkpointID != newestID },
        context: fixture.context(retention: 5)
    )
    #expect(incomplete.delete.isEmpty)
    #expect(incomplete.blocker == .latestSafetySetIncomplete)
}

@Test
func onlyExactCurrentEpochFullReaderWitnessesCanBeDeleted() throws {
    let fixture = try RetentionFixture(count: 7)
    let oldestID = fixture.checkpointIDs[0]
    let wrongEpoch = try BackupWriterEpoch(bytes: Data(repeating: 0xEE, count: 16))
    let witnesses = try fixture.witnesses.map { witness in
        guard witness.checkpointID == oldestID else { return witness }
        return try witness.replacingWriterEpoch(wrongEpoch)
    }
    let plan = BackupRetentionPolicy.plan(
        candidates: fixture.candidates,
        witnesses: witnesses,
        context: fixture.context(retention: 5)
    )

    #expect(!plan.delete.contains(oldestID))
    #expect(plan.keep.contains(oldestID))
    #expect(plan.delete == [fixture.checkpointIDs[1]])
}

@Test
func identicalCheckpointBytesAtAReplacementIdentityCannotReuseOldDwell() throws {
    let fixture = try RetentionFixture(count: 7)
    let oldestID = fixture.checkpointIDs[0]
    let candidates = fixture.candidates.map { candidate in
        guard case let .verified(point) = candidate.verification,
              point.checkpointID == oldestID else { return candidate }
        return BackupRetentionCandidate(
            origin: candidate.origin,
            verification: candidate.verification,
            repositoryIdentityDigest: Data(repeating: 0xFE, count: 32)
        )
    }
    let plan = BackupRetentionPolicy.plan(
        candidates: candidates,
        witnesses: fixture.witnesses,
        context: fixture.context(retention: 5)
    )

    #expect(plan.keep.contains(oldestID))
    #expect(!plan.delete.contains(oldestID))
    #expect(plan.delete == [fixture.checkpointIDs[1]])
}

@Test
func unknownCorruptOtherSetAndNoWitnessCandidatesAreNeverDeletedOrUsedAsSafetyProof() throws {
    let fixture = try RetentionFixture(count: 7)
    let unmanaged = [
        BackupRetentionCandidate(origin: .manual, verification: .indeterminate(.unknownFile)),
        BackupRetentionCandidate(origin: .automatic, verification: .rejected(.corruptRecord)),
        BackupRetentionCandidate(origin: .manual, verification: .verified(try fixture.point(sequence: 99, setByte: 0xFE))),
    ]
    let noWitnessHighPoint = try fixture.point(sequence: 8)
    let plan = BackupRetentionPolicy.plan(
        candidates: fixture.candidates + unmanaged + [
            BackupRetentionCandidate(
                origin: .manual,
                verification: .verified(noWitnessHighPoint),
                repositoryIdentityDigest: Data(repeating: 0xA8, count: 32)
            ),
        ],
        witnesses: fixture.witnesses,
        context: fixture.context(retention: 5)
    )

    #expect(plan.delete.isEmpty)
    #expect(plan.blocker == .latestSafetySetIncomplete)
    #expect(plan.unmanagedCandidateCount == 3)
    #expect(plan.keep.contains(noWitnessHighPoint.checkpointID))
}

@Test
func deletionRequiresACompletedNewLocalVerificationAndProvenContinuity() throws {
    let fixture = try RetentionFixture(count: 7)
    let noNewPoint = BackupRetentionPolicy.plan(
        candidates: fixture.candidates,
        witnesses: fixture.witnesses,
        context: fixture.context(retention: 5, completedNewVerification: false)
    )
    #expect(noNewPoint.delete.isEmpty)
    #expect(noNewPoint.blocker == .newVerificationRequired)

    let unknownContinuity = BackupRetentionPolicy.plan(
        candidates: fixture.candidates,
        witnesses: fixture.witnesses,
        context: fixture.context(retention: 5, continuity: .unknown)
    )
    #expect(unknownContinuity.delete.isEmpty)
    #expect(unknownContinuity.blocker == .continuityUnproven)
}

private struct RetentionFixture {
    let now = Date(timeIntervalSince1970: 2_000_000)
    let setID: BackupSetID
    let writerEpoch: BackupWriterEpoch
    let authorizationID: BackupAuthorizationID
    let deviceID: BackupDeviceID
    let checkpointIDs: [BackupCheckpointID]
    let candidates: [BackupRetentionCandidate]
    let witnesses: [BackupDurableFullReaderWitness]

    init(count: Int, dwellHours: Int = 25) throws {
        setID = try BackupSetID(bytes: Data(repeating: 0x31, count: 16))
        writerEpoch = try BackupWriterEpoch(bytes: Data(repeating: 0x32, count: 16))
        authorizationID = try BackupAuthorizationID(bytes: Data(repeating: 0x33, count: 16))
        deviceID = try BackupDeviceID(bytes: Data(repeating: 0x34, count: 16))
        checkpointIDs = try (1...count).map {
            try BackupCheckpointID(bytes: Data(repeating: UInt8($0), count: 16))
        }

        var builtCandidates: [BackupRetentionCandidate] = []
        var builtWitnesses: [BackupDurableFullReaderWitness] = []
        for sequence in 1...count {
            let point = try Self.makePoint(
                sequence: UInt64(sequence),
                setID: setID,
                authorizationID: authorizationID,
                deviceID: deviceID,
                checkpointID: checkpointIDs[sequence - 1]
            )
            let identityDigest = Data(repeating: UInt8(0x40 + sequence), count: 32)
            builtCandidates.append(BackupRetentionCandidate(
                origin: sequence.isMultiple(of: 2) ? .automatic : .manual,
                verification: .verified(point),
                repositoryIdentityDigest: identityDigest
            ))
            builtWitnesses.append(try BackupDurableFullReaderWitness(
                checkpoint: point,
                writerEpoch: writerEpoch,
                repositoryIdentityDigest: identityDigest,
                continuousObservationStartedAt: now.addingTimeInterval(TimeInterval(-dwellHours * 60 * 60)),
                lastObservedAt: now
            ))
        }
        candidates = builtCandidates
        witnesses = builtWitnesses
    }

    func context(
        retention: Int,
        history: BackupRepositoryHistory = .linear,
        previousEvaluationAt: Date? = nil,
        completedNewVerification: Bool = true,
        continuity: BackupObservationContinuity = .proven
    ) -> BackupRetentionContext {
        BackupRetentionContext(
            currentSetID: setID,
            currentWriterEpoch: writerEpoch,
            retentionCount: try! BackupRetentionCount(retention),
            history: history,
            continuity: continuity,
            now: now,
            previousEvaluationAt: previousEvaluationAt,
            completedNewLocalVerification: completedNewVerification
        )
    }

    func point(sequence: UInt64, setByte: UInt8 = 0x31) throws -> BackupPublicCheckpoint {
        try Self.makePoint(
            sequence: sequence,
            setID: .init(bytes: Data(repeating: setByte, count: 16)),
            authorizationID: authorizationID,
            deviceID: deviceID,
            checkpointID: .init(bytes: Data(repeating: UInt8(truncatingIfNeeded: sequence), count: 16))
        )
    }

    private static func makePoint(
        sequence: UInt64,
        setID: BackupSetID,
        authorizationID: BackupAuthorizationID,
        deviceID: BackupDeviceID,
        checkpointID: BackupCheckpointID
    ) throws -> BackupPublicCheckpoint {
        try BackupPublicCheckpoint(
            setID: setID,
            checkpointID: checkpointID,
            deviceID: deviceID,
            authorizationID: authorizationID,
            sequence: sequence,
            commitment: .init(
                digest: Data(repeating: UInt8(truncatingIfNeeded: sequence), count: 32),
                ciphertextByteCount: 1_000 + sequence
            )
        )
    }
}
