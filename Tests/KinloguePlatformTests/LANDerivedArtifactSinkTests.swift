import CryptoKit
import Darwin
import Foundation
import NIOCore
import XCTest
@testable import KinlogueCore
@testable import KinloguePlatform

final class LANDerivedArtifactSinkTests: XCTestCase {
    func testProductionAdmissionUsesTheDocumentedStoreAndOwnerBounds() {
        XCTAssertEqual(
            LANPendingWriteAdmission.Limits.derivedProduction,
            .init(
                maximumPendingBytesPerOwner: 4 * 1_024 * 1_024,
                maximumTotalPendingBytes: 16 * 1_024 * 1_024,
                maximumPendingChunksPerOwner: 64,
                maximumTotalPendingChunks: 256
            )
        )
    }

    func testProductionStoreBudgetIsReservedBeforeAnyDerivedActorHop() async throws {
        let chunkByteCount = 4 * 1_024 * 1_024
        let admission = try LANPendingWriteAdmission(limits: .derivedProduction)
        let fixtures = try (0..<4).map { _ in try DerivedDescriptorFixture() }
        defer { for fixture in fixtures { fixture.destroy() } }
        let recorder = DerivedCallbackRecorder()
        let preActorGate = DerivedBlockingGate(expectedEntries: 4)
        defer { preActorGate.release() }
        let rejectionSignal = DerivedSignal()
        let injector = LANDerivedArtifactSink.FailureInjector { point, _ in
            if point == .admittedBeforeActorHop { preActorGate.enterAndWait() }
            if point == .pendingAdmissionRejected { rejectionSignal.signal() }
        }
        let sinks = try fixtures.map { fixture in
            try LANDerivedArtifactSink(
                attemptID: fixture.attemptID,
                descriptor: fixture.transferDescriptor(),
                abort: { descriptor in
                    await recorder.recordAbort(descriptor: descriptor)
                },
                finalize: { completed, descriptor in
                    try await recorder.recordFinalize(completed, descriptor: descriptor)
                },
                failureInjector: injector,
                pendingWriteOwner: admission.acquireOwner()
            )
        }

        let writes = sinks.enumerated().map { index, sink in
            runDerivedSynchronousWriteOnDedicatedThread {
                sink.write(
                    Data(repeating: UInt8(0x70 + index), count: chunkByteCount)
                )
            }
        }
        try await preActorGate.waitUntilEntered()

        XCTAssertEqual(
            admission.currentUsage,
            .init(
                activeOwnerCount: 4,
                pendingByteCount: 4 * chunkByteCount,
                pendingChunkCount: 4
            )
        )
        XCTAssertEqual(injector.occurrenceCount(for: .admittedBeforeActorHop), 4)
        XCTAssertEqual(injector.occurrenceCount(for: .beforeWrite), 0)

        let rejectedWrite = Task {
            try await sinks[0].write(
                Data(repeating: 0x7f, count: chunkByteCount)
            ).value
        }
        try await rejectionSignal.wait()
        XCTAssertEqual(admission.highWaterMark.pendingByteCount, 4 * chunkByteCount)
        XCTAssertEqual(injector.occurrenceCount(for: .beforeDataCopy), 4)
        XCTAssertEqual(injector.occurrenceCount(for: .admittedBeforeActorHop), 4)
        let postRejectionWrite = sinks[0].write(
            Data(repeating: 0x7e, count: chunkByteCount)
        )
        await assertThrows(LANInboxError.invalidState) {
            try await postRejectionWrite.value
        }
        XCTAssertEqual(injector.occurrenceCount(for: .beforeDataCopy), 4)

        preActorGate.release()
        await assertThrows(LANInboxError.invalidState) {
            try await writes[0].value
        }
        for write in writes.dropFirst() { try await write.value }
        await assertThrows(LANInboxError.resourceLimitExceeded) {
            try await rejectedWrite.value
        }
        for sink in sinks { await sink.abort() }
        XCTAssertEqual(
            admission.currentUsage,
            .init(activeOwnerCount: 0, pendingByteCount: 0, pendingChunkCount: 0)
        )
    }

    func testEmptyDataAndBuffersDoNotConsumeDerivedTurnsAndCloseWithFinish() async throws {
        let fixture = try DerivedDescriptorFixture()
        defer { fixture.destroy() }
        let recorder = DerivedCallbackRecorder()
        let admission = try LANPendingWriteAdmission(limits: .derivedProduction)
        let injector = LANDerivedArtifactSink.FailureInjector { _, _ in }
        let sink = try LANDerivedArtifactSink(
            attemptID: fixture.attemptID,
            descriptor: fixture.transferDescriptor(),
            abort: { descriptor in
                await recorder.recordAbort(descriptor: descriptor)
            },
            finalize: { completed, descriptor in
                try await recorder.recordFinalize(completed, descriptor: descriptor)
            },
            failureInjector: injector,
            pendingWriteOwner: admission.acquireOwner()
        )
        let dataWrites = (0...64).map { _ in sink.write(Data()) }
        let emptyBuffer = ByteBufferAllocator().buffer(capacity: 0)
        let bufferWrites = (0...64).map { _ in sink.write(emptyBuffer) }

        for write in dataWrites + bufferWrites { try await write.value }
        XCTAssertEqual(
            admission.currentUsage,
            .init(activeOwnerCount: 1, pendingByteCount: 0, pendingChunkCount: 0)
        )
        XCTAssertEqual(injector.occurrenceCount(for: .beforeDataCopy), 0)
        XCTAssertEqual(injector.occurrenceCount(for: .admittedBeforeActorHop), 0)
        XCTAssertEqual(injector.occurrenceCount(for: .writeQueued), 0)
        XCTAssertEqual(injector.occurrenceCount(for: .beforeWrite), 0)

        _ = try await sink.finish()
        await assertThrows(LANInboxError.invalidState) {
            try await sink.write(Data()).value
        }
        await assertThrows(LANInboxError.invalidState) {
            try await sink.write(emptyBuffer).value
        }
        XCTAssertEqual(
            admission.currentUsage,
            .init(activeOwnerCount: 0, pendingByteCount: 0, pendingChunkCount: 0)
        )
        let abortCount = await recorder.abortCount
        XCTAssertEqual(abortCount, 0)
    }

    func testSharedAdmissionAppliesTotalLimitsAcrossOwners() throws {
        let admission = try makeDerivedAdmission(
            ownerBytes: 8,
            totalBytes: 8,
            ownerChunks: 2,
            totalChunks: 2
        )
        let firstOwner = admission.acquireOwner()
        let secondOwner = admission.acquireOwner()
        let firstPermit = try firstOwner.acquire(byteCount: 8)

        assertThrows(LANInboxError.resourceLimitExceeded) {
            try secondOwner.acquire(byteCount: 1)
        }
        XCTAssertEqual(
            admission.currentUsage,
            .init(activeOwnerCount: 2, pendingByteCount: 8, pendingChunkCount: 1)
        )

        firstPermit.release()
        firstOwner.release()
        secondOwner.release()
        XCTAssertEqual(
            admission.currentUsage,
            .init(activeOwnerCount: 0, pendingByteCount: 0, pendingChunkCount: 0)
        )
    }

    func testStreamsMultipleChunkKindsAndSyncsBeforeOneReplayableFinalize() async throws {
        let fixture = try DerivedDescriptorFixture()
        defer { fixture.destroy() }
        let recorder = DerivedCallbackRecorder()
        let events = DerivedEventLog()
        let injector = LANDerivedArtifactSink.FailureInjector { point, _ in
            if point == .afterSync { events.append("synced") }
        }
        let sink = try LANDerivedArtifactSink(
            attemptID: fixture.attemptID,
            descriptor: fixture.transferDescriptor(),
            abort: { descriptor in
                await recorder.recordAbort(descriptor: descriptor)
            },
            finalize: { completed, descriptor in
                events.append("finalized")
                try await recorder.recordFinalize(
                    completed,
                    descriptor: descriptor
                )
            },
            failureInjector: injector,
            maximumWriteByteCount: 2
        )

        let first = Data("derived-".utf8)
        let second = Data("artifact".utf8)
        var buffer = ByteBufferAllocator().buffer(capacity: second.count)
        buffer.writeBytes(second)
        try await sink.write(first).value
        try await sink.write(buffer).value
        let completed = try await sink.finish()
        let replayed = try await sink.finish()
        let expected = first + second
        XCTAssertEqual(completed, replayed)
        XCTAssertEqual(completed.attemptID, fixture.attemptID)
        XCTAssertEqual(completed.byteCount, expected.count)
        XCTAssertEqual(completed.sha256Digest, Data(SHA256.hash(data: expected)))
        let finalizedArtifacts = await recorder.finalizedArtifacts
        let finalizedBytes = await recorder.finalizedBytes
        let abortCount = await recorder.abortCount
        XCTAssertEqual(finalizedArtifacts, [completed])
        XCTAssertEqual(finalizedBytes, [expected])
        XCTAssertEqual(abortCount, 0)
        XCTAssertEqual(events.snapshot, ["synced", "finalized"])
        XCTAssertTrue(try fixture.canAcquireExclusiveLock())
    }

    func testConcurrentFinishesJoinAndAbortCannotRunBesideFinalization() async throws {
        let fixture = try DerivedDescriptorFixture()
        defer { fixture.destroy() }
        let recorder = DerivedCallbackRecorder()
        let finalizeGate = DerivedAsyncGate()
        defer { Task { await finalizeGate.release() } }
        let sink = try LANDerivedArtifactSink(
            attemptID: fixture.attemptID,
            descriptor: fixture.transferDescriptor(),
            abort: { descriptor in
                await recorder.recordAbort(descriptor: descriptor)
            },
            finalize: { completed, descriptor in
                try await recorder.recordFinalize(
                    completed,
                    descriptor: descriptor
                )
                await finalizeGate.pause()
            }
        )
        try await sink.write(Data("one-finalization".utf8)).value
        let firstFinish = Task { try await sink.finish() }
        try await finalizeGate.waitUntilPaused()
        let joinedFinishes = (0..<8).map { _ in
            Task { try await sink.finish() }
        }
        let racingAborts = (0..<8).map { _ in
            Task { await sink.abort() }
        }
        await assertThrows(LANInboxError.invalidState) {
            try await sink.write(Data("too-late".utf8)).value
        }
        await finalizeGate.release()

        let firstResult = try await firstFinish.value
        for task in joinedFinishes {
            let joinedResult = try await task.value
            XCTAssertEqual(joinedResult, firstResult)
        }
        for task in racingAborts { await task.value }
        let replayedResult = try await sink.finish()
        let finalizedArtifacts = await recorder.finalizedArtifacts
        let abortCount = await recorder.abortCount
        XCTAssertEqual(replayedResult, firstResult)
        XCTAssertEqual(finalizedArtifacts, [firstResult])
        XCTAssertEqual(abortCount, 0)
    }

    func testConcurrentAbortsJoinOneDescriptorBoundCallbackAndRejectFinishAndWrite() async throws {
        let fixture = try DerivedDescriptorFixture()
        defer { fixture.destroy() }
        let recorder = DerivedCallbackRecorder()
        let abortGate = DerivedAsyncGate()
        defer { Task { await abortGate.release() } }
        let sink = try LANDerivedArtifactSink(
            attemptID: fixture.attemptID,
            descriptor: fixture.transferDescriptor(),
            abort: { descriptor in
                await recorder.recordAbort(descriptor: descriptor)
                await abortGate.pause()
            },
            finalize: { completed, descriptor in
                try await recorder.recordFinalize(
                    completed,
                    descriptor: descriptor
                )
            }
        )
        try await sink.write(Data("abort-me".utf8)).value
        let firstAbort = Task { await sink.abort() }
        try await abortGate.waitUntilPaused()
        let joinedAborts = (0..<8).map { _ in Task { await sink.abort() } }
        let finishWhileAborting = Task { () -> Bool in
            do {
                _ = try await sink.finish()
                return false
            } catch LANInboxError.invalidState {
                return true
            } catch {
                return false
            }
        }
        await assertThrows(LANInboxError.invalidState) {
            try await sink.write(Data("too-late".utf8)).value
        }
        await abortGate.release()

        await firstAbort.value
        for task in joinedAborts { await task.value }
        let finishWasRejected = await finishWhileAborting.value
        let abortCount = await recorder.abortCount
        let finalizedArtifacts = await recorder.finalizedArtifacts
        XCTAssertTrue(finishWasRejected)
        XCTAssertEqual(abortCount, 1)
        XCTAssertTrue(finalizedArtifacts.isEmpty)
        XCTAssertTrue(try fixture.canAcquireExclusiveLock())
    }

    func testWriteFailureAndRacingTerminalCallsStillAbortExactlyOnce() async throws {
        let fixture = try DerivedDescriptorFixture()
        defer { fixture.destroy() }
        let recorder = DerivedCallbackRecorder()
        let abortGate = DerivedAsyncGate()
        defer { Task { await abortGate.release() } }
        let injector = LANDerivedArtifactSink.FailureInjector { point, occurrence in
            if point == .afterWrite, occurrence == 1 {
                throw SyntheticDerivedSinkFailure()
            }
        }
        let sink = try LANDerivedArtifactSink(
            attemptID: fixture.attemptID,
            descriptor: fixture.transferDescriptor(),
            abort: { descriptor in
                await recorder.recordAbort(descriptor: descriptor)
                await abortGate.pause()
            },
            finalize: { completed, descriptor in
                try await recorder.recordFinalize(
                    completed,
                    descriptor: descriptor
                )
            },
            failureInjector: injector
        )

        let failingWrite = Task {
            try await sink.write(Data("fails-after-write".utf8)).value
        }
        try await abortGate.waitUntilPaused()
        let joinedAbort = Task { await sink.abort() }
        let rejectedFinish = Task { () -> Bool in
            do {
                _ = try await sink.finish()
                return false
            } catch LANInboxError.invalidState {
                return true
            } catch {
                return false
            }
        }
        await abortGate.release()

        await assertThrows(SyntheticDerivedSinkFailure.self) {
            try await failingWrite.value
        }
        await joinedAbort.value
        let finishWasRejected = await rejectedFinish.value
        let abortCount = await recorder.abortCount
        let finalizedArtifacts = await recorder.finalizedArtifacts
        XCTAssertTrue(finishWasRejected)
        XCTAssertEqual(abortCount, 1)
        XCTAssertTrue(finalizedArtifacts.isEmpty)
    }

    func testThirdPendingChunkIsRejectedBeforeCopyAndDrainsExactlyOnce() async throws {
        let fixture = try DerivedDescriptorFixture()
        defer { fixture.destroy() }
        let admission = try makeDerivedAdmission(
            ownerBytes: 8,
            totalBytes: 8,
            ownerChunks: 2,
            totalChunks: 2
        )
        let recorder = DerivedCallbackRecorder()
        let writeGate = DerivedBlockingGate()
        defer { writeGate.release() }
        let rejectionSignal = DerivedSignal()
        let injector = LANDerivedArtifactSink.FailureInjector { point, occurrence in
            if point == .beforeWrite, occurrence == 1 { writeGate.enterAndWait() }
            if point == .pendingAdmissionRejected { rejectionSignal.signal() }
        }
        let sink = try LANDerivedArtifactSink(
            attemptID: fixture.attemptID,
            descriptor: fixture.transferDescriptor(),
            abort: { descriptor in
                await recorder.recordAbort(descriptor: descriptor)
            },
            finalize: { completed, descriptor in
                try await recorder.recordFinalize(
                    completed,
                    descriptor: descriptor
                )
            },
            failureInjector: injector,
            pendingWriteOwner: admission.acquireOwner()
        )

        let first = Task { try await sink.write(Data(repeating: 0x41, count: 4)).value }
        try await waitForDerivedOccurrence(
            injector,
            point: .beforeDataCopy,
            expectedCount: 1
        )
        try await writeGate.waitUntilEntered()
        let second = Task { try await sink.write(Data(repeating: 0x42, count: 4)).value }
        try await waitForDerivedOccurrence(
            injector,
            point: .beforeDataCopy,
            expectedCount: 2
        )
        XCTAssertEqual(
            admission.currentUsage,
            .init(activeOwnerCount: 1, pendingByteCount: 8, pendingChunkCount: 2)
        )

        let rejected = Task { try await sink.write(Data([0x43])).value }
        try await rejectionSignal.wait()
        XCTAssertEqual(injector.occurrenceCount(for: .beforeDataCopy), 2)
        XCTAssertEqual(
            admission.highWaterMark,
            .init(pendingByteCount: 8, pendingChunkCount: 2)
        )
        let preReleaseAbortCount = await recorder.abortCount
        XCTAssertEqual(preReleaseAbortCount, 0)

        writeGate.release()
        await assertThrows(LANInboxError.invalidState) {
            try await first.value
        }
        await assertThrows(LANInboxError.invalidState) {
            try await second.value
        }
        await assertThrows(LANInboxError.resourceLimitExceeded) {
            try await rejected.value
        }
        let abortCount = await recorder.abortCount
        let finalizedArtifacts = await recorder.finalizedArtifacts
        XCTAssertEqual(abortCount, 1)
        XCTAssertTrue(finalizedArtifacts.isEmpty)
        XCTAssertEqual(
            admission.currentUsage,
            .init(activeOwnerCount: 0, pendingByteCount: 0, pendingChunkCount: 0)
        )
    }

    func testTinyChunksCannotExceedConfiguredHighWaterMark() async throws {
        let fixture = try DerivedDescriptorFixture()
        defer { fixture.destroy() }
        let admission = try makeDerivedAdmission(
            ownerBytes: 64,
            totalBytes: 64,
            ownerChunks: 4,
            totalChunks: 4
        )
        let recorder = DerivedCallbackRecorder()
        let writeGate = DerivedBlockingGate()
        defer { writeGate.release() }
        let rejectionSignal = DerivedSignal()
        let injector = LANDerivedArtifactSink.FailureInjector { point, occurrence in
            if point == .beforeWrite, occurrence == 1 { writeGate.enterAndWait() }
            if point == .pendingAdmissionRejected { rejectionSignal.signal() }
        }
        let sink = try LANDerivedArtifactSink(
            attemptID: fixture.attemptID,
            descriptor: fixture.transferDescriptor(),
            abort: { descriptor in
                await recorder.recordAbort(descriptor: descriptor)
            },
            finalize: { completed, descriptor in
                try await recorder.recordFinalize(
                    completed,
                    descriptor: descriptor
                )
            },
            failureInjector: injector,
            pendingWriteOwner: admission.acquireOwner()
        )

        var admitted: [Task<Void, Error>] = []
        for value in UInt8(0)..<UInt8(4) {
            admitted.append(Task { try await sink.write(Data([value])).value })
            try await waitForDerivedOccurrence(
                injector,
                point: .beforeDataCopy,
                expectedCount: admitted.count
            )
            if value == 0 { try await writeGate.waitUntilEntered() }
        }
        let rejected = Task { try await sink.write(Data([0xff])).value }
        try await rejectionSignal.wait()

        XCTAssertEqual(injector.occurrenceCount(for: .beforeDataCopy), 4)
        XCTAssertEqual(
            admission.currentUsage,
            .init(activeOwnerCount: 1, pendingByteCount: 4, pendingChunkCount: 4)
        )
        XCTAssertEqual(
            admission.highWaterMark,
            .init(pendingByteCount: 4, pendingChunkCount: 4)
        )

        writeGate.release()
        for task in admitted {
            await assertThrows(LANInboxError.invalidState) {
                try await task.value
            }
        }
        await assertThrows(LANInboxError.resourceLimitExceeded) {
            try await rejected.value
        }
        let abortCount = await recorder.abortCount
        XCTAssertEqual(abortCount, 1)
        XCTAssertEqual(
            admission.currentUsage,
            .init(activeOwnerCount: 0, pendingByteCount: 0, pendingChunkCount: 0)
        )
    }

    func testByteBufferRetainedCapacityIsRejectedWithoutEnteringIO() async throws {
        let fixture = try DerivedDescriptorFixture()
        defer { fixture.destroy() }
        let admission = try makeDerivedAdmission(
            ownerBytes: 4,
            totalBytes: 4,
            ownerChunks: 2,
            totalChunks: 2
        )
        let recorder = DerivedCallbackRecorder()
        let injector = LANDerivedArtifactSink.FailureInjector { _, _ in }
        let sink = try LANDerivedArtifactSink(
            attemptID: fixture.attemptID,
            descriptor: fixture.transferDescriptor(),
            abort: { descriptor in
                await recorder.recordAbort(descriptor: descriptor)
            },
            finalize: { completed, descriptor in
                try await recorder.recordFinalize(
                    completed,
                    descriptor: descriptor
                )
            },
            failureInjector: injector,
            pendingWriteOwner: admission.acquireOwner()
        )
        var backing = ByteBufferAllocator().buffer(capacity: 32)
        backing.writeInteger(UInt8(0x51))
        let slice = try XCTUnwrap(backing.getSlice(at: 0, length: 1))
        XCTAssertEqual(slice.readableBytes, 1)
        XCTAssertGreaterThanOrEqual(slice.storageCapacity, 32)

        await assertThrows(LANInboxError.resourceLimitExceeded) {
            try await sink.write(slice).value
        }
        let abortCount = await recorder.abortCount
        XCTAssertEqual(injector.occurrenceCount(for: .beforeWrite), 0)
        XCTAssertEqual(abortCount, 1)
        XCTAssertEqual(
            admission.highWaterMark,
            .init(pendingByteCount: 0, pendingChunkCount: 0)
        )
        XCTAssertEqual(
            admission.currentUsage,
            .init(activeOwnerCount: 0, pendingByteCount: 0, pendingChunkCount: 0)
        )
    }

    func testAbortRacingQueuedFinishDrainsPermitAndOwnsTerminalTransition() async throws {
        let fixture = try DerivedDescriptorFixture()
        defer { fixture.destroy() }
        let admission = try makeDerivedAdmission(
            ownerBytes: 8,
            totalBytes: 8,
            ownerChunks: 2,
            totalChunks: 2
        )
        let recorder = DerivedCallbackRecorder()
        let writeGate = DerivedBlockingGate()
        defer { writeGate.release() }
        let finishQueued = DerivedSignal()
        let abortRequested = DerivedSignal()
        let injector = LANDerivedArtifactSink.FailureInjector { point, occurrence in
            if point == .beforeWrite, occurrence == 1 { writeGate.enterAndWait() }
            if point == .finishQueued { finishQueued.signal() }
            if point == .abortRequested { abortRequested.signal() }
        }
        let sink = try LANDerivedArtifactSink(
            attemptID: fixture.attemptID,
            descriptor: fixture.transferDescriptor(),
            abort: { descriptor in
                await recorder.recordAbort(descriptor: descriptor)
            },
            finalize: { completed, descriptor in
                try await recorder.recordFinalize(
                    completed,
                    descriptor: descriptor
                )
            },
            failureInjector: injector,
            pendingWriteOwner: admission.acquireOwner()
        )

        let writing = Task { try await sink.write(Data("queued".utf8)).value }
        try await writeGate.waitUntilEntered()
        let finishing = Task { try await sink.finish() }
        try await finishQueued.wait()
        let aborting = Task { await sink.abort() }
        try await abortRequested.wait()

        writeGate.release()
        await assertThrows(LANInboxError.invalidState) {
            try await writing.value
        }
        await assertThrows(LANInboxError.invalidState) {
            try await finishing.value
        }
        await aborting.value
        let abortCount = await recorder.abortCount
        let finalizedArtifacts = await recorder.finalizedArtifacts
        XCTAssertEqual(abortCount, 1)
        XCTAssertTrue(finalizedArtifacts.isEmpty)
        XCTAssertEqual(
            admission.currentUsage,
            .init(activeOwnerCount: 0, pendingByteCount: 0, pendingChunkCount: 0)
        )
    }

    func testRejectsNonPrivateOrHardLinkedDescriptorsAtOwnershipTransfer() throws {
        let wrongMode = try DerivedDescriptorFixture(
            mode: 0o640,
            minimumDescriptor: 4_096
        )
        defer { wrongMode.destroy() }
        assertThrows(LANInboxError.invalidState) {
            _ = try LANDerivedArtifactSink(
                attemptID: wrongMode.attemptID,
                descriptor: wrongMode.transferDescriptor(),
                abort: { _ in },
                finalize: { _, _ in }
            )
        }
        let wrongModeResult = fcntl(wrongMode.rawDescriptor, F_GETFD)
        let wrongModeError = errno
        XCTAssertEqual(wrongModeResult, -1)
        XCTAssertEqual(wrongModeError, EBADF)

        let hardLinked = try DerivedDescriptorFixture(
            addHardLink: true,
            minimumDescriptor: 4_096
        )
        defer { hardLinked.destroy() }
        assertThrows(LANInboxError.invalidState) {
            _ = try LANDerivedArtifactSink(
                attemptID: hardLinked.attemptID,
                descriptor: hardLinked.transferDescriptor(),
                abort: { _ in },
                finalize: { _, _ in }
            )
        }
        let hardLinkResult = fcntl(hardLinked.rawDescriptor, F_GETFD)
        let hardLinkError = errno
        XCTAssertEqual(hardLinkResult, -1)
        XCTAssertEqual(hardLinkError, EBADF)
    }
}
