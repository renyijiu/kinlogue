import CryptoKit
import Darwin
import Foundation
import NIOCore
import Testing
@testable import KinlogueCore
@testable import KinloguePlatform

@Suite(.serialized)
struct LANUploadSinkTests {
    @Test
    func productionBodiesAreReservedBeforeTheyCanQueueAtTheActorHop() async throws {
        let chunkByteCount = 4 * 1_024 * 1_024
        let policy = try LANInboxAdmissionPolicy()
        let firstFixture = try PartialFixture()
        let secondFixture = try PartialFixture()
        defer {
            firstFixture.destroy()
            secondFixture.destroy()
        }
        let preActorGate = BlockingGate(expectedEntries: 2)
        defer { preActorGate.release() }
        let rejectionSignal = AsyncSignal()
        let injector = LANUploadSink.FailureInjector { point, _ in
            if point == .admittedBeforeActorHop { preActorGate.enterAndWait() }
            if point == .pendingMemoryRejected { rejectionSignal.signal() }
        }
        let firstSink = try makeSink(
            fixture: firstFixture,
            policy: policy,
            declaredByteCount: nil,
            recorder: PublishRecorder(),
            failureInjector: injector
        )
        let secondSink = try makeSink(
            fixture: secondFixture,
            policy: policy,
            declaredByteCount: nil,
            recorder: PublishRecorder(),
            failureInjector: injector
        )

        let firstWrite = Task {
            try await firstSink.write(
                Data(repeating: 0x61, count: chunkByteCount)
            ).value
        }
        let secondWrite = Task {
            try await secondSink.write(
                Data(repeating: 0x62, count: chunkByteCount)
            ).value
        }
        try await preActorGate.waitUntilEntered()

        #expect(
            policy.currentUsage
                == .init(
                    activeUploadCount: 2,
                    totalPendingByteCount: 2 * chunkByteCount
                )
        )
        #expect(injector.occurrenceCount(for: .admittedBeforeActorHop) == 2)
        #expect(injector.occurrenceCount(for: .beforeWrite) == 0)

        let rejectedWrite = Task {
            try await firstSink.write(
                Data(repeating: 0x63, count: chunkByteCount)
            ).value
        }
        try await rejectionSignal.wait()
        #expect(policy.currentUsage.totalPendingByteCount == 2 * chunkByteCount)
        #expect(injector.occurrenceCount(for: .admittedBeforeActorHop) == 2)
        #expect(injector.occurrenceCount(for: .beforeDataCopy) == 2)
        let postRejectionWrite = firstSink.write(
            Data(repeating: 0x64, count: chunkByteCount)
        )
        await #expect(throws: LANInboxError.invalidState) {
            try await postRejectionWrite.value
        }
        #expect(injector.occurrenceCount(for: .beforeDataCopy) == 2)

        preActorGate.release()
        // The already-admitted write may finish before the rejection reaches
        // the sink actor, or observe the actor's failure fence. Both outcomes
        // preserve the synchronous body budget and terminal cleanup contract.
        do {
            try await firstWrite.value
        } catch LANInboxError.invalidState {
            // The rejection reached the actor before descriptor IO completed.
        } catch {
            Issue.record("An admitted write failed with an unexpected error")
        }
        try await secondWrite.value
        await #expect(throws: LANInboxError.resourceLimitExceeded) {
            try await rejectedWrite.value
        }
        await firstSink.cancel()
        await secondSink.cancel()
        #expect(
            policy.currentUsage
                == .init(activeUploadCount: 0, totalPendingByteCount: 0)
        )
    }

    @Test(arguments: [false, true])
    func streamsDataAndByteBuffersWithOptionalExactLength(
        declaresLength: Bool
    ) async throws {
        let first = Data("first-".utf8)
        let second = Data("second".utf8)
        let expected = first + second
        let fixture = try PartialFixture()
        defer { fixture.destroy() }
        let policy = try LANInboxAdmissionPolicy()
        let recorder = PublishRecorder()
        let sink = try makeSink(
            fixture: fixture,
            policy: policy,
            declaredByteCount: declaresLength ? expected.count : nil,
            recorder: recorder
        )

        try await sink.write(first).value
        var buffer = ByteBufferAllocator().buffer(capacity: second.count)
        buffer.writeBytes(second)
        try await sink.write(buffer).value
        let firstFinish = try await sink.finish()
        let replayedFinish = try await sink.finish()
        #expect(firstFinish == replayedFinish)
        #expect(firstFinish.byteCount == expected.count)
        #expect(firstFinish.sha256Digest == Data(SHA256.hash(data: expected)))
        #expect(try Data(contentsOf: fixture.fileURL) == expected)
        #expect(await recorder.completions == [firstFinish])
        #expect(policy.currentUsage == .init(activeUploadCount: 0, totalPendingByteCount: 0))
        #expect(fixture.cleanupCount == 0)
    }

    @Test
    func declaredLengthSmallerThanBodyFailsBeforePublishing() async throws {
        let fixture = try PartialFixture()
        defer { fixture.destroy() }
        let policy = try LANInboxAdmissionPolicy()
        let recorder = PublishRecorder()
        let sink = try makeSink(
            fixture: fixture,
            policy: policy,
            declaredByteCount: 3,
            recorder: recorder
        )

        await #expect(throws: LANInboxError.integrityCheckFailed) {
            try await sink.write(Data(repeating: 0x31, count: 4)).value
        }
        await #expect(throws: LANInboxError.invalidState) {
            try await sink.finish()
        }
        #expect(await recorder.completions.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.fileURL.path))
        #expect(policy.currentUsage == .init(activeUploadCount: 0, totalPendingByteCount: 0))
    }

    @Test
    func declaredLengthLargerThanBodyFailsAtFinish() async throws {
        let fixture = try PartialFixture()
        defer { fixture.destroy() }
        let policy = try LANInboxAdmissionPolicy()
        let recorder = PublishRecorder()
        let sink = try makeSink(
            fixture: fixture,
            policy: policy,
            declaredByteCount: 5,
            recorder: recorder
        )

        try await sink.write(Data(repeating: 0x32, count: 4)).value
        await #expect(throws: LANInboxError.integrityCheckFailed) {
            try await sink.finish()
        }
        #expect(await recorder.completions.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.fileURL.path))
        #expect(policy.currentUsage == .init(activeUploadCount: 0, totalPendingByteCount: 0))
    }

    @Test
    func zeroByteUploadFinishesWithTheEmptyDigest() async throws {
        let fixture = try PartialFixture()
        defer { fixture.destroy() }
        let policy = try LANInboxAdmissionPolicy()
        let recorder = PublishRecorder()
        let sink = try makeSink(
            fixture: fixture,
            policy: policy,
            declaredByteCount: 0,
            recorder: recorder
        )

        try await sink.write(Data()).value
        let completed = try await sink.finish()
        #expect(completed.byteCount == 0)
        #expect(completed.sha256Digest == Data(SHA256.hash(data: Data())))
        #expect(await recorder.completions == [completed])
        #expect(policy.currentUsage == .init(activeUploadCount: 0, totalPendingByteCount: 0))
    }

    @Test
    func emptyDataAndBuffersDoNotCreateTurnsAndRespectTerminalClosure() async throws {
        let fixture = try PartialFixture()
        defer { fixture.destroy() }
        let policy = try LANInboxAdmissionPolicy()
        let injector = LANUploadSink.FailureInjector { _, _ in }
        let sink = try makeSink(
            fixture: fixture,
            policy: policy,
            declaredByteCount: 0,
            recorder: PublishRecorder(),
            failureInjector: injector
        )
        let dataWrites = (0...64).map { _ in sink.write(Data()) }
        let emptyBuffer = ByteBufferAllocator().buffer(capacity: 0)
        let bufferWrites = (0...64).map { _ in sink.write(emptyBuffer) }

        for write in dataWrites + bufferWrites { try await write.value }
        #expect(
            policy.currentUsage
                == .init(activeUploadCount: 1, totalPendingByteCount: 0)
        )
        #expect(injector.occurrenceCount(for: .beforeDataCopy) == 0)
        #expect(injector.occurrenceCount(for: .admittedBeforeActorHop) == 0)
        #expect(injector.occurrenceCount(for: .writeQueued) == 0)
        #expect(injector.occurrenceCount(for: .beforeWrite) == 0)

        _ = try await sink.finish()
        await #expect(throws: LANInboxError.invalidState) {
            try await sink.write(Data()).value
        }
        await #expect(throws: LANInboxError.invalidState) {
            try await sink.write(emptyBuffer).value
        }
        #expect(
            policy.currentUsage
                == .init(activeUploadCount: 0, totalPendingByteCount: 0)
        )
    }

    @Test
    func replayedFinishAfterAResponseLossDoesNotRepublish() async throws {
        let fixture = try PartialFixture()
        defer { fixture.destroy() }
        let policy = try LANInboxAdmissionPolicy()
        let recorder = PublishRecorder()
        let sink = try makeSink(
            fixture: fixture,
            policy: policy,
            declaredByteCount: nil,
            recorder: recorder
        )

        try await sink.write(Data("response-replay".utf8)).value
        let resultWhoseResponseWasLost = try await sink.finish()
        let replayedResult = try await sink.finish()

        #expect(replayedResult == resultWhoseResponseWasLost)
        #expect(await recorder.completions == [resultWhoseResponseWasLost])
        #expect(policy.currentUsage == .init(activeUploadCount: 0, totalPendingByteCount: 0))
    }

    @Test
    func concurrentFinishesJoinOneBlockedPublication() async throws {
        let fixture = try PartialFixture()
        defer { fixture.destroy() }
        let policy = try LANInboxAdmissionPolicy()
        let recorder = PublishRecorder()
        let publishGate = AsyncCleanupGate()
        defer { Task { await publishGate.release() } }
        let finishJoined = AsyncSignal()
        let injector = LANUploadSink.FailureInjector { point, _ in
            if point == .finishJoined { finishJoined.signal() }
        }
        let sink = try makeSink(
            fixture: fixture,
            policy: policy,
            declaredByteCount: nil,
            recorder: recorder,
            failureInjector: injector,
            publish: { completed, descriptor in
                await recorder.record(completed, descriptor: descriptor)
                await publishGate.pause()
            }
        )
        try await sink.write(Data("single-publication".utf8)).value
        let firstFinish = Task { try await sink.finish() }
        try await publishGate.waitUntilPaused()
        let secondFinish = Task { try await sink.finish() }
        try await finishJoined.wait()

        #expect(await recorder.completions.count == 1)
        #expect(fixture.cleanupCount == 0)
        #expect(policy.currentUsage.activeUploadCount == 1)
        await publishGate.release()

        let first = try await firstFinish.value
        let second = try await secondFinish.value
        #expect(first == second)
        #expect(await recorder.completions == [first])
        #expect(policy.currentUsage == .init(activeUploadCount: 0, totalPendingByteCount: 0))
    }

    @Test
    func cancelDuringCommittedPublishLetsResolvedResponseLossWin() async throws {
        let fixture = try PartialFixture()
        defer { fixture.destroy() }
        let policy = try LANInboxAdmissionPolicy()
        let recorder = PublishRecorder()
        let publishGate = AsyncCleanupGate()
        defer { Task { await publishGate.release() } }
        let committed = AsyncFlag()
        let cancellationEntered = AsyncSignal()
        let injector = LANUploadSink.FailureInjector { point, _ in
            if point == .cancellationRequested { cancellationEntered.signal() }
        }
        let sink = try makeSink(
            fixture: fixture,
            policy: policy,
            declaredByteCount: nil,
            recorder: recorder,
            failureInjector: injector,
            publish: { completed, descriptor in
                await recorder.record(completed, descriptor: descriptor)
                await committed.set()
                await publishGate.pause()

                // The store sees its exact durable commit after a simulated
                // response loss, so it resolves the ambiguity as success.
                do {
                    throw SyntheticPublishResponseLoss()
                } catch {
                    guard await committed.value else { throw error }
                }
            }
        )
        let competingDescriptor = Darwin.open(
            fixture.fileURL.path,
            O_WRONLY | O_NOFOLLOW | O_CLOEXEC
        )
        #expect(competingDescriptor >= 0)
        defer { if competingDescriptor >= 0 { _ = Darwin.close(competingDescriptor) } }

        try await sink.write(Data("committed-response-loss".utf8)).value
        let finishing = Task { try await sink.finish() }
        try await publishGate.waitUntilPaused()
        #expect(await committed.value)
        #expect(flock(competingDescriptor, LOCK_EX | LOCK_NB) == -1)

        let cancelling = Task { await sink.cancel() }
        try await cancellationEntered.wait()
        #expect(fixture.cleanupCount == 0)
        #expect(policy.currentUsage.activeUploadCount == 1)

        await publishGate.release()
        let completed = try await finishing.value
        await cancelling.value
        #expect(try await sink.finish() == completed)
        #expect(await recorder.completions == [completed])
        #expect(fixture.cleanupCount == 0)
        #expect(flock(competingDescriptor, LOCK_EX | LOCK_NB) == 0)
        #expect(policy.currentUsage == .init(activeUploadCount: 0, totalPendingByteCount: 0))
    }

    @Test
    func publishFailureBeforeCommitCleansThePartialExactlyOnce() async throws {
        let fixture = try PartialFixture()
        defer { fixture.destroy() }
        let policy = try LANInboxAdmissionPolicy()
        let recorder = PublishRecorder()
        let publishGate = AsyncCleanupGate()
        defer { Task { await publishGate.release() } }
        let cancellationEntered = AsyncSignal()
        let injector = LANUploadSink.FailureInjector { point, _ in
            if point == .cancellationRequested { cancellationEntered.signal() }
        }
        let sink = try makeSink(
            fixture: fixture,
            policy: policy,
            declaredByteCount: nil,
            recorder: recorder,
            failureInjector: injector,
            publish: { completed, descriptor in
                await recorder.record(completed, descriptor: descriptor)
                await publishGate.pause()
                throw SyntheticPublicationFailure()
            }
        )

        try await sink.write(Data("publication-failure".utf8)).value
        let finishing = Task { try await sink.finish() }
        try await publishGate.waitUntilPaused()
        let cancelling = Task { await sink.cancel() }
        try await cancellationEntered.wait()
        #expect(fixture.cleanupCount == 0)

        await publishGate.release()
        await #expect(throws: SyntheticPublicationFailure.self) {
            try await finishing.value
        }
        await cancelling.value
        await #expect(throws: LANInboxError.invalidState) {
            try await sink.finish()
        }
        #expect(await recorder.completions.count == 1)
        #expect(fixture.cleanupCount == 1)
        #expect(!FileManager.default.fileExists(atPath: fixture.fileURL.path))
        #expect(policy.currentUsage == .init(activeUploadCount: 0, totalPendingByteCount: 0))
    }

    @Test
    func loopsAcrossBoundedWritesAndHashesIncrementally() async throws {
        let bytes = Data("abcdefgh".utf8)
        let fixture = try PartialFixture()
        defer { fixture.destroy() }
        let policy = try policy(
            maximumActiveUploads: 2,
            maximumPendingBytesPerUpload: 4,
            maximumTotalPendingBytes: 8
        )
        let recorder = PublishRecorder()
        let injector = LANUploadSink.FailureInjector { _, _ in }
        let sink = try makeSink(
            fixture: fixture,
            policy: policy,
            declaredByteCount: bytes.count,
            recorder: recorder,
            failureInjector: injector,
            maximumWriteByteCount: 2
        )

        try await sink.write(bytes.prefix(4)).value
        #expect(policy.currentUsage.totalPendingByteCount == 0)
        try await sink.write(bytes.suffix(4)).value
        let completed = try await sink.finish()

        #expect(injector.occurrenceCount(for: .beforeWrite) == 4)
        #expect(injector.occurrenceCount(for: .afterWrite) == 4)
        #expect(completed.sha256Digest == Data(SHA256.hash(data: bytes)))
        #expect(try Data(contentsOf: fixture.fileURL) == bytes)
        #expect(policy.currentUsage == .init(activeUploadCount: 0, totalPendingByteCount: 0))
    }

    @Test
    func finishWaitsForQueuedWritesAndRejectsEveryLaterWrite() async throws {
        let fixture = try PartialFixture()
        defer { fixture.destroy() }
        let policy = try LANInboxAdmissionPolicy()
        let recorder = PublishRecorder()
        let gate = BlockingGate(expectedEntries: 1)
        defer { gate.release() }
        let writeQueued = AsyncSignal()
        let finishQueued = AsyncSignal()
        let injector = LANUploadSink.FailureInjector { point, occurrence in
            if point == .beforeWrite, occurrence == 1 { gate.enterAndWait() }
            if point == .writeQueued { writeQueued.signal() }
            if point == .finishQueued { finishQueued.signal() }
        }
        let sink = try makeSink(
            fixture: fixture,
            policy: policy,
            declaredByteCount: nil,
            recorder: recorder,
            failureInjector: injector
        )

        let first = Task { try await sink.write(Data("one".utf8)).value }
        try await gate.waitUntilEntered()
        let second = Task { try await sink.write(Data("two".utf8)).value }
        try await writeQueued.wait()
        let finishing = Task { try await sink.finish() }
        try await finishQueued.wait()

        await #expect(throws: LANInboxError.invalidState) {
            try await sink.write(Data("late".utf8)).value
        }
        #expect(await recorder.completions.isEmpty)
        #expect(fixture.cleanupCount == 0)

        gate.release()
        try await first.value
        try await second.value
        let completed = try await finishing.value

        #expect(try Data(contentsOf: fixture.fileURL) == Data("onetwo".utf8))
        #expect(await recorder.completions == [completed])
    }

    @Test
    func cancelWaitsForABlockedWriteAndRejectsEveryLaterOperation() async throws {
        let fixture = try PartialFixture()
        defer { fixture.destroy() }
        let policy = try LANInboxAdmissionPolicy()
        let gate = BlockingGate(expectedEntries: 1)
        defer { gate.release() }
        let cancellationEntered = AsyncSignal()
        let injector = LANUploadSink.FailureInjector { point, occurrence in
            if point == .beforeWrite, occurrence == 1 { gate.enterAndWait() }
            if point == .cancellationRequested { cancellationEntered.signal() }
        }
        let sink = try makeSink(
            fixture: fixture,
            policy: policy,
            declaredByteCount: nil,
            recorder: PublishRecorder(),
            failureInjector: injector
        )

        let activeWrite = Task { try await sink.write(Data("blocked".utf8)).value }
        try await gate.waitUntilEntered()
        let cancellation = Task { await sink.cancel() }
        try await cancellationEntered.wait()

        await #expect(throws: LANInboxError.invalidState) {
            try await sink.write(Data("late".utf8)).value
        }
        await #expect(throws: LANInboxError.invalidState) {
            try await sink.finish()
        }
        #expect(fixture.cleanupCount == 0)
        #expect(policy.currentUsage.activeUploadCount == 1)

        gate.release()
        await #expect(throws: LANInboxError.invalidState) {
            try await activeWrite.value
        }
        await cancellation.value
        #expect(fixture.cleanupCount == 1)
        #expect(policy.currentUsage == .init(activeUploadCount: 0, totalPendingByteCount: 0))
    }

    @Test
    func secondWriteFaultCleansThePartialAndReleasesAllPermits() async throws {
        let fixture = try PartialFixture()
        defer { fixture.destroy() }
        let policy = try LANInboxAdmissionPolicy()
        let recorder = PublishRecorder()
        let injector = LANUploadSink.FailureInjector { point, occurrence in
            if point == .beforeWrite, occurrence == 2 {
                throw LANInboxError.storageFailure
            }
        }
        let sink = try makeSink(
            fixture: fixture,
            policy: policy,
            declaredByteCount: nil,
            recorder: recorder,
            failureInjector: injector
        )

        try await sink.write(Data("kept-until-failure".utf8)).value
        await #expect(throws: LANInboxError.storageFailure) {
            try await sink.write(Data("fault".utf8)).value
        }

        #expect(fixture.cleanupCount == 1)
        #expect(!FileManager.default.fileExists(atPath: fixture.fileURL.path))
        #expect(await recorder.completions.isEmpty)
        #expect(policy.currentUsage == .init(activeUploadCount: 0, totalPendingByteCount: 0))
    }

    @Test
    func syncFaultDoesNotPublishAndCleansThePartial() async throws {
        let fixture = try PartialFixture()
        defer { fixture.destroy() }
        let policy = try LANInboxAdmissionPolicy()
        let recorder = PublishRecorder()
        let injector = LANUploadSink.FailureInjector { point, _ in
            if point == .beforeSync { throw LANInboxError.storageFailure }
        }
        let sink = try makeSink(
            fixture: fixture,
            policy: policy,
            declaredByteCount: nil,
            recorder: recorder,
            failureInjector: injector
        )

        try await sink.write(Data("sync-fault".utf8)).value
        await #expect(throws: LANInboxError.storageFailure) {
            try await sink.finish()
        }

        #expect(fixture.cleanupCount == 1)
        #expect(!FileManager.default.fileExists(atPath: fixture.fileURL.path))
        #expect(await recorder.completions.isEmpty)
        #expect(policy.currentUsage == .init(activeUploadCount: 0, totalPendingByteCount: 0))
    }

    @Test
    func faultAfterSuccessfulSyncStillDoesNotPublish() async throws {
        let fixture = try PartialFixture()
        defer { fixture.destroy() }
        let policy = try LANInboxAdmissionPolicy()
        let recorder = PublishRecorder()
        let injector = LANUploadSink.FailureInjector { point, _ in
            if point == .afterSync { throw LANInboxError.storageFailure }
        }
        let sink = try makeSink(
            fixture: fixture,
            policy: policy,
            declaredByteCount: nil,
            recorder: recorder,
            failureInjector: injector
        )

        try await sink.write(Data("after-sync-fault".utf8)).value
        await #expect(throws: LANInboxError.storageFailure) {
            try await sink.finish()
        }
        #expect(injector.occurrenceCount(for: .afterSync) == 1)
        #expect(await recorder.completions.isEmpty)
        #expect(fixture.cleanupCount == 1)
        #expect(policy.currentUsage == .init(activeUploadCount: 0, totalPendingByteCount: 0))
    }

    @Test
    func cancelIsIdempotentAndRetainsTheAdvisoryLockUntilClose() async throws {
        let fixture = try PartialFixture()
        defer { fixture.destroy() }
        let policy = try LANInboxAdmissionPolicy()
        let recorder = PublishRecorder()
        let sink = try makeSink(
            fixture: fixture,
            policy: policy,
            declaredByteCount: nil,
            recorder: recorder
        )
        let competingDescriptor = Darwin.open(
            fixture.fileURL.path,
            O_WRONLY | O_NOFOLLOW | O_CLOEXEC
        )
        #expect(competingDescriptor >= 0)
        defer { if competingDescriptor >= 0 { _ = Darwin.close(competingDescriptor) } }

        #expect(flock(competingDescriptor, LOCK_EX | LOCK_NB) == -1)
        await sink.cancel()
        await sink.cancel()
        #expect(flock(competingDescriptor, LOCK_EX | LOCK_NB) == 0)
        await #expect(throws: LANInboxError.invalidState) {
            try await sink.finish()
        }
        #expect(fixture.cleanupCount == 1)
        #expect(policy.currentUsage == .init(activeUploadCount: 0, totalPendingByteCount: 0))
    }

    @Test
    func invalidDescriptorInitializationClosesAndReleasesItsPermit() throws {
        let fixture = try PartialFixture()
        defer { fixture.destroy() }
        _ = Darwin.close(fixture.descriptor)
        let readOnlyDescriptor = Darwin.open(
            fixture.fileURL.path,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        #expect(readOnlyDescriptor >= 0)
        let policy = try LANInboxAdmissionPolicy()
        let permit = try policy.acquireUploadPermit()

        #expect(throws: LANInboxError.invalidState) {
            try LANUploadSink(
                attemptID: fixture.attemptID,
                descriptor: readOnlyDescriptor,
                declaredByteCount: nil,
                uploadPermit: permit,
                cleanup: { _ in },
                publish: { _, _ in }
            )
        }

        let competingDescriptor = Darwin.open(
            fixture.fileURL.path,
            O_WRONLY | O_NOFOLLOW | O_CLOEXEC
        )
        #expect(competingDescriptor >= 0)
        defer {
            if competingDescriptor >= 0 { _ = Darwin.close(competingDescriptor) }
        }
        #expect(flock(competingDescriptor, LOCK_EX | LOCK_NB) == 0)
        #expect(policy.currentUsage == .init(activeUploadCount: 0, totalPendingByteCount: 0))
    }

    @Test
    func twoSlowBodiesHoldBoundedMemoryAndAThirdBodyIsRejected() async throws {
        let policy = try policy(
            maximumActiveUploads: 2,
            maximumPendingBytesPerUpload: 4,
            maximumTotalPendingBytes: 8
        )
        let firstFixture = try PartialFixture()
        let secondFixture = try PartialFixture()
        defer {
            firstFixture.destroy()
            secondFixture.destroy()
        }
        let gate = BlockingGate(expectedEntries: 2)
        defer { gate.release() }
        let injector = LANUploadSink.FailureInjector { point, _ in
            if point == .beforeWrite { gate.enterAndWait() }
        }
        let first = try makeSink(
            fixture: firstFixture,
            policy: policy,
            declaredByteCount: nil,
            recorder: PublishRecorder(),
            failureInjector: injector
        )
        let second = try makeSink(
            fixture: secondFixture,
            policy: policy,
            declaredByteCount: nil,
            recorder: PublishRecorder(),
            failureInjector: injector
        )

        #expect(throws: LANInboxError.resourceLimitExceeded) {
            try policy.acquireUploadPermit()
        }
        let firstWrite = Task { try await first.write(Data(repeating: 0x41, count: 4)).value }
        let secondWrite = Task { try await second.write(Data(repeating: 0x42, count: 4)).value }
        try await gate.waitUntilEntered()
        #expect(policy.currentUsage == .init(activeUploadCount: 2, totalPendingByteCount: 8))

        gate.release()
        try await firstWrite.value
        try await secondWrite.value
        await first.cancel()
        await second.cancel()
        #expect(policy.currentUsage == .init(activeUploadCount: 0, totalPendingByteCount: 0))
    }

    @Test
    func pendingMemoryRejectionStillReleasesTheBodyPermit() async throws {
        let fixture = try PartialFixture()
        defer { fixture.destroy() }
        let policy = try policy(
            maximumActiveUploads: 2,
            maximumPendingBytesPerUpload: 3,
            maximumTotalPendingBytes: 6
        )
        let injector = LANUploadSink.FailureInjector { _, _ in }
        let sink = try makeSink(
            fixture: fixture,
            policy: policy,
            declaredByteCount: nil,
            recorder: PublishRecorder(),
            failureInjector: injector
        )

        await #expect(throws: LANInboxError.resourceLimitExceeded) {
            try await sink.write(Data(repeating: 0x43, count: 4)).value
        }
        #expect(injector.occurrenceCount(for: .beforeDataCopy) == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.fileURL.path))
        #expect(policy.currentUsage == .init(activeUploadCount: 0, totalPendingByteCount: 0))
    }

    @Test
    func sixtyFifthPendingChunkIsRejectedBeforeCopyAndDrainsExactlyOnce() async throws {
        let fixture = try PartialFixture()
        defer { fixture.destroy() }
        let policy = try LANInboxAdmissionPolicy()
        let gate = BlockingGate(expectedEntries: 1)
        defer { gate.release() }
        let rejectionSignal = AsyncSignal()
        let injector = LANUploadSink.FailureInjector { point, occurrence in
            if point == .beforeWrite, occurrence == 1 { gate.enterAndWait() }
            if point == .pendingChunkRejected { rejectionSignal.signal() }
        }
        let sink = try makeSink(
            fixture: fixture,
            policy: policy,
            declaredByteCount: nil,
            recorder: PublishRecorder(),
            failureInjector: injector
        )

        var admitted: [Task<Void, Error>] = []
        admitted.append(Task { try await sink.write(Data([0])).value })
        try await waitForOccurrence(
            injector,
            point: .beforeDataCopy,
            expectedCount: 1
        )
        try await gate.waitUntilEntered()

        for value in UInt8(1)..<UInt8(64) {
            admitted.append(Task { try await sink.write(Data([value])).value })
            try await waitForOccurrence(
                injector,
                point: .beforeDataCopy,
                expectedCount: admitted.count
            )
        }
        #expect(injector.occurrenceCount(for: .beforeDataCopy) == 64)
        #expect(policy.currentUsage.totalPendingByteCount == 64)

        let rejected = Task {
            try await sink.write(Data([0xff])).value
        }
        try await rejectionSignal.wait()
        #expect(injector.occurrenceCount(for: .beforeDataCopy) == 64)
        #expect(policy.currentUsage.totalPendingByteCount == 64)
        #expect(fixture.cleanupCount == 0)

        gate.release()
        for task in admitted {
            await #expect(throws: LANInboxError.invalidState) {
                try await task.value
            }
        }
        await #expect(throws: LANInboxError.resourceLimitExceeded) {
            try await rejected.value
        }
        #expect(fixture.cleanupCount == 1)
        #expect(!FileManager.default.fileExists(atPath: fixture.fileURL.path))
        #expect(policy.currentUsage == .init(activeUploadCount: 0, totalPendingByteCount: 0))
    }

    @Test
    func queuedMemoryRejectionDrainsTheActiveWriteBeforeCleanup() async throws {
        let fixture = try PartialFixture()
        defer { fixture.destroy() }
        let policy = try policy(
            maximumActiveUploads: 2,
            maximumPendingBytesPerUpload: 4,
            maximumTotalPendingBytes: 8
        )
        let gate = BlockingGate(expectedEntries: 1)
        defer { gate.release() }
        let rejectionSignal = AsyncSignal()
        let injector = LANUploadSink.FailureInjector { point, occurrence in
            if point == .beforeWrite, occurrence == 1 { gate.enterAndWait() }
            if point == .pendingMemoryRejected { rejectionSignal.signal() }
        }
        let sink = try makeSink(
            fixture: fixture,
            policy: policy,
            declaredByteCount: nil,
            recorder: PublishRecorder(),
            failureInjector: injector
        )

        let activeWrite = Task {
            try await sink.write(Data(repeating: 0x51, count: 4)).value
        }
        try await gate.waitUntilEntered()
        let rejectedWrite = Task {
            try await sink.write(Data(repeating: 0x52, count: 1)).value
        }
        try await rejectionSignal.wait()

        #expect(fixture.cleanupCount == 0)
        #expect(FileManager.default.fileExists(atPath: fixture.fileURL.path))
        #expect(policy.currentUsage == .init(activeUploadCount: 1, totalPendingByteCount: 4))

        gate.release()
        await #expect(throws: LANInboxError.invalidState) {
            try await activeWrite.value
        }
        await #expect(throws: LANInboxError.resourceLimitExceeded) {
            try await rejectedWrite.value
        }
        #expect(fixture.cleanupCount == 1)
        #expect(!FileManager.default.fileExists(atPath: fixture.fileURL.path))
        #expect(policy.currentUsage == .init(activeUploadCount: 0, totalPendingByteCount: 0))
    }

    @Test
    func byteBufferRetainedCapacityCountsAgainstPendingMemory() async throws {
        let fixture = try PartialFixture()
        defer { fixture.destroy() }
        let policy = try policy(
            maximumActiveUploads: 2,
            maximumPendingBytesPerUpload: 4,
            maximumTotalPendingBytes: 8
        )
        let sink = try makeSink(
            fixture: fixture,
            policy: policy,
            declaredByteCount: nil,
            recorder: PublishRecorder()
        )
        var backing = ByteBufferAllocator().buffer(capacity: 32)
        backing.writeInteger(UInt8(0x53))
        let buffer = try #require(backing.getSlice(at: 0, length: 1))
        #expect(buffer.capacity == 1)
        #expect(buffer.storageCapacity >= 32)

        await #expect(throws: LANInboxError.resourceLimitExceeded) {
            try await sink.write(buffer).value
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.fileURL.path))
        #expect(policy.currentUsage == .init(activeUploadCount: 0, totalPendingByteCount: 0))
    }

    @Test
    func dataSlicesAreRightSizedBeforePendingAccounting() async throws {
        let fixture = try PartialFixture()
        defer { fixture.destroy() }
        let policy = try policy(
            maximumActiveUploads: 2,
            maximumPendingBytesPerUpload: 4,
            maximumTotalPendingBytes: 8
        )
        let gate = BlockingGate(expectedEntries: 1)
        defer { gate.release() }
        let usageAtCopy = UploadUsageCapture()
        let injector = LANUploadSink.FailureInjector { point, occurrence in
            if point == .beforeDataCopy {
                usageAtCopy.record(policy.currentUsage)
            }
            if point == .beforeWrite, occurrence == 1 { gate.enterAndWait() }
        }
        let sink = try makeSink(
            fixture: fixture,
            policy: policy,
            declaredByteCount: 1,
            recorder: PublishRecorder(),
            failureInjector: injector
        )
        let largeBacking = Data(repeating: 0x54, count: 32)
        let oneByteSlice = largeBacking.prefix(1)

        let writing = Task { try await sink.write(oneByteSlice).value }
        try await gate.waitUntilEntered()
        #expect(
            usageAtCopy.value
                == .init(activeUploadCount: 1, totalPendingByteCount: 1)
        )
        #expect(injector.occurrenceCount(for: .beforeDataCopy) == 1)
        #expect(policy.currentUsage == .init(activeUploadCount: 1, totalPendingByteCount: 1))
        gate.release()
        try await writing.value
        _ = try await sink.finish()
        #expect(policy.currentUsage == .init(activeUploadCount: 0, totalPendingByteCount: 0))
    }

    @Test
    func cleanupFaultCannotLeakDescriptorsOrAdmissionCounters() async throws {
        let fixture = try PartialFixture()
        defer { fixture.destroy() }
        let policy = try LANInboxAdmissionPolicy()
        let injector = LANUploadSink.FailureInjector { point, _ in
            if point == .beforeCleanup { throw LANInboxError.storageFailure }
        }
        let sink = try makeSink(
            fixture: fixture,
            policy: policy,
            declaredByteCount: nil,
            recorder: PublishRecorder(),
            failureInjector: injector
        )

        await sink.cancel()
        #expect(FileManager.default.fileExists(atPath: fixture.fileURL.path))
        #expect(fixture.cleanupCount == 0)
        #expect(policy.currentUsage == .init(activeUploadCount: 0, totalPendingByteCount: 0))

        let descriptor = Darwin.open(
            fixture.fileURL.path,
            O_WRONLY | O_NOFOLLOW | O_CLOEXEC
        )
        #expect(descriptor >= 0)
        if descriptor >= 0 {
            #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
            _ = Darwin.close(descriptor)
        }
    }

    @Test
    func concurrentCancelWaitsForTheSharedTerminalCleanup() async throws {
        let fixture = try PartialFixture()
        defer { fixture.destroy() }
        let policy = try LANInboxAdmissionPolicy()
        let cleanupGate = AsyncCleanupGate()
        defer { Task { await cleanupGate.release() } }
        let cleanupJoined = AsyncSignal()
        let secondCancelFinished = AsyncFlag()
        let injector = LANUploadSink.FailureInjector { point, _ in
            if point == .terminalCleanupJoined { cleanupJoined.signal() }
        }
        let sink = try makeSink(
            fixture: fixture,
            policy: policy,
            declaredByteCount: nil,
            recorder: PublishRecorder(),
            failureInjector: injector,
            cleanup: { descriptor in
                await cleanupGate.pause()
                try await fixture.cleanup(descriptor)
            }
        )
        let competingDescriptor = Darwin.open(
            fixture.fileURL.path,
            O_WRONLY | O_NOFOLLOW | O_CLOEXEC
        )
        #expect(competingDescriptor >= 0)
        defer { if competingDescriptor >= 0 { _ = Darwin.close(competingDescriptor) } }
        #expect(flock(competingDescriptor, LOCK_EX | LOCK_NB) == -1)

        let firstCancel = Task { await sink.cancel() }
        try await cleanupGate.waitUntilPaused()
        #expect(flock(competingDescriptor, LOCK_EX | LOCK_NB) == -1)
        firstCancel.cancel()
        let secondCancel = Task {
            await sink.cancel()
            await secondCancelFinished.set()
        }
        try await cleanupJoined.wait()
        #expect(await secondCancelFinished.value == false)
        #expect(policy.currentUsage.activeUploadCount == 1)

        await cleanupGate.release()
        await firstCancel.value
        await secondCancel.value
        #expect(await secondCancelFinished.value)
        #expect(policy.currentUsage == .init(activeUploadCount: 0, totalPendingByteCount: 0))
        #expect(fixture.cleanupCount == 1)
        #expect(flock(competingDescriptor, LOCK_EX | LOCK_NB) == 0)
    }

    @Test
    func blockingGateTimeoutAlwaysReleasesAnEnteredWriter() async throws {
        let gate = BlockingGate(expectedEntries: 2)
        defer { gate.release() }
        let blockedWriter = Task.detached { gate.enterAndWait() }
        try await gate.waitUntilEntryCount(1)

        await #expect(throws: BlockingGateTimeout.self) {
            try await gate.waitUntilEntered(timeout: .milliseconds(20))
        }
        await blockedWriter.value
    }
}

private func makeSink(
    fixture: PartialFixture,
    policy: LANInboxAdmissionPolicy,
    declaredByteCount: Int?,
    recorder: PublishRecorder,
    failureInjector: LANUploadSink.FailureInjector = .none,
    maximumWriteByteCount: Int = .max,
    cleanup: LANUploadSink.Cleanup? = nil,
    publish: LANUploadSink.Publish? = nil
) throws -> LANUploadSink {
    let permit = try policy.acquireUploadPermit()
    return try LANUploadSink(
        attemptID: fixture.attemptID,
        descriptor: fixture.descriptor,
        declaredByteCount: declaredByteCount,
        uploadPermit: permit,
        cleanup: cleanup ?? fixture.cleanup,
        publish: publish ?? { completed, descriptor in
            await recorder.record(completed, descriptor: descriptor)
        },
        failureInjector: failureInjector,
        maximumWriteByteCount: maximumWriteByteCount
    )
}

private func policy(
    maximumActiveUploads: Int,
    maximumPendingBytesPerUpload: Int,
    maximumTotalPendingBytes: Int
) throws -> LANInboxAdmissionPolicy {
    try LANInboxAdmissionPolicy(
        limits: .init(
            maximumActiveUploads: maximumActiveUploads,
            maximumPendingBytesPerUpload: maximumPendingBytesPerUpload,
            maximumTotalPendingBytes: maximumTotalPendingBytes
        )
    )
}

private func waitForOccurrence(
    _ injector: LANUploadSink.FailureInjector,
    point: LANUploadSink.FaultPoint,
    expectedCount: Int,
    timeout: Duration = .seconds(5)
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while injector.occurrenceCount(for: point) < expectedCount {
        if clock.now >= deadline { throw BlockingGateTimeout() }
        try await Task.sleep(for: .milliseconds(1))
    }
}

private final class UploadUsageCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var usage: LANInboxAdmissionPolicy.Usage?

    func record(_ usage: LANInboxAdmissionPolicy.Usage) {
        lock.withLock { self.usage = usage }
    }

    var value: LANInboxAdmissionPolicy.Usage? {
        lock.withLock { usage }
    }
}

private actor PublishRecorder {
    private(set) var completions: [LANUploadSink.CompletedUpload] = []

    func record(
        _ completed: LANUploadSink.CompletedUpload,
        descriptor: Int32
    ) {
        var metadata = stat()
        #expect(fstat(descriptor, &metadata) == 0)
        #expect((metadata.st_mode & S_IFMT) == S_IFREG)
        completions.append(completed)
    }
}

private actor AsyncCleanupGate {
    private var isPaused = false
    private var isReleased = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func pause() async {
        isPaused = true
        guard !isReleased else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilPaused(timeout: Duration = .seconds(5)) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !isPaused {
            if clock.now >= deadline {
                release()
                throw BlockingGateTimeout()
            }
            do {
                try await Task.sleep(for: .milliseconds(1))
            } catch {
                release()
                throw error
            }
        }
    }

    func release() {
        isReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private actor AsyncFlag {
    private(set) var value = false

    func set() { value = true }
}

private final class BlockingGate: @unchecked Sendable {
    private let condition = NSCondition()
    private let expectedEntries: Int
    private var entries = 0
    private var isReleased = false

    init(expectedEntries: Int) {
        self.expectedEntries = expectedEntries
    }

    func enterAndWait() {
        condition.lock()
        entries += 1
        condition.broadcast()
        while !isReleased { condition.wait() }
        condition.unlock()
    }

    func waitUntilEntered(timeout: Duration = .seconds(5)) async throws {
        try await waitUntilEntryCount(expectedEntries, timeout: timeout)
    }

    func waitUntilEntryCount(
        _ expectedCount: Int,
        timeout: Duration = .seconds(5)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !hasEntryCount(expectedCount) {
            if clock.now >= deadline {
                release()
                throw BlockingGateTimeout()
            }
            do {
                try await Task.sleep(for: .milliseconds(1))
            } catch {
                release()
                throw error
            }
        }
    }

    private func hasEntryCount(_ expectedCount: Int) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return entries >= expectedCount
    }

    func release() {
        condition.lock()
        isReleased = true
        condition.broadcast()
        condition.unlock()
    }
}

private struct BlockingGateTimeout: Error {}
private struct SyntheticPublishResponseLoss: Error {}
private struct SyntheticPublicationFailure: Error {}

private final class AsyncSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var isSignaled = false

    func signal() {
        lock.withLock { isSignaled = true }
    }

    func wait() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !hasSignal() {
            if clock.now >= deadline { throw BlockingGateTimeout() }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private func hasSignal() -> Bool {
        lock.withLock { isSignaled }
    }
}

private final class PartialFixture: @unchecked Sendable {
    let attemptID: UUID
    let fileURL: URL
    let descriptor: Int32

    private let rootURL: URL
    private let name: String
    private let lock = NSLock()
    private var directoryDescriptor: Int32
    private var didDestroy = false
    private var cleanupInvocations = 0

    var cleanupCount: Int { lock.withLock { cleanupInvocations } }

    lazy var cleanup: LANUploadSink.Cleanup = { [self] descriptor in
        try unlinkOwnedPartial(descriptor: descriptor)
    }

    init() throws {
        let attemptID = UUID()
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinlogue-upload-sink-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        guard chmod(rootURL.path, 0o700) == 0 else {
            try? FileManager.default.removeItem(at: rootURL)
            throw LANInboxError.storageFailure
        }
        let directoryDescriptor = Darwin.open(
            rootURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directoryDescriptor >= 0 else {
            try? FileManager.default.removeItem(at: rootURL)
            throw LANInboxError.storageFailure
        }

        let name = "\(attemptID.uuidString.lowercased()).partial"
        let fileURL = rootURL.appendingPathComponent(name, isDirectory: false)
        let descriptor = Darwin.openat(
            directoryDescriptor,
            name,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0,
              fchmod(descriptor, S_IRUSR | S_IWUSR) == 0,
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if descriptor >= 0 { _ = Darwin.close(descriptor) }
            _ = Darwin.close(directoryDescriptor)
            try? FileManager.default.removeItem(at: rootURL)
            throw LANInboxError.storageFailure
        }

        self.attemptID = attemptID
        self.rootURL = rootURL
        self.directoryDescriptor = directoryDescriptor
        self.name = name
        self.fileURL = fileURL
        self.descriptor = descriptor
    }

    deinit {
        destroy()
    }

    func destroy() {
        let descriptorToClose: Int32? = lock.withLock {
            guard !didDestroy else { return nil }
            didDestroy = true
            let current = directoryDescriptor
            directoryDescriptor = -1
            return current
        }
        if let descriptorToClose { _ = Darwin.close(descriptorToClose) }
        try? FileManager.default.removeItem(at: rootURL)
    }

    private func unlinkOwnedPartial(descriptor: Int32) throws {
        let directoryDescriptor = lock.withLock { () -> Int32 in
            cleanupInvocations += 1
            return self.directoryDescriptor
        }
        guard directoryDescriptor >= 0 else { throw LANInboxError.storageFailure }

        var expected = stat()
        guard fstat(descriptor, &expected) == 0 else {
            throw LANInboxError.storageFailure
        }
        var actual = stat()
        guard fstatat(directoryDescriptor, name, &actual, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return }
            throw LANInboxError.storageFailure
        }
        guard expected.st_dev == actual.st_dev,
              expected.st_ino == actual.st_ino,
              (actual.st_mode & S_IFMT) == S_IFREG else {
            throw LANInboxError.invalidState
        }
        guard unlinkat(directoryDescriptor, name, 0) == 0 || errno == ENOENT else {
            throw LANInboxError.storageFailure
        }
    }
}
