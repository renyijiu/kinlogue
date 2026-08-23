import CryptoKit
import Darwin
import Foundation
import NIOCore
import Testing
@testable import KinlogueCore
@testable import KinloguePlatform

@Suite(.serialized)
struct LANDerivedArtifactSinkTests {
    @Test
    func productionAdmissionUsesTheDocumentedStoreAndOwnerBounds() {
        #expect(
            LANPendingWriteAdmission.Limits.derivedProduction
                == .init(
                    maximumPendingBytesPerOwner: 4 * 1_024 * 1_024,
                    maximumTotalPendingBytes: 16 * 1_024 * 1_024,
                    maximumPendingChunksPerOwner: 64,
                    maximumTotalPendingChunks: 256
                )
        )
    }

    @Test
    func productionStoreBudgetIsReservedBeforeAnyDerivedActorHop() async throws {
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
            Task {
                try await sink.write(
                    Data(repeating: UInt8(0x70 + index), count: chunkByteCount)
                ).value
            }
        }
        try await preActorGate.waitUntilEntered()

        #expect(
            admission.currentUsage
                == .init(
                    activeOwnerCount: 4,
                    pendingByteCount: 4 * chunkByteCount,
                    pendingChunkCount: 4
                )
        )
        #expect(injector.occurrenceCount(for: .admittedBeforeActorHop) == 4)
        #expect(injector.occurrenceCount(for: .beforeWrite) == 0)

        let rejectedWrite = Task {
            try await sinks[0].write(
                Data(repeating: 0x7f, count: chunkByteCount)
            ).value
        }
        try await rejectionSignal.wait()
        #expect(admission.highWaterMark.pendingByteCount == 4 * chunkByteCount)
        #expect(injector.occurrenceCount(for: .beforeDataCopy) == 4)
        #expect(injector.occurrenceCount(for: .admittedBeforeActorHop) == 4)
        let postRejectionWrite = sinks[0].write(
            Data(repeating: 0x7e, count: chunkByteCount)
        )
        await #expect(throws: LANInboxError.invalidState) {
            try await postRejectionWrite.value
        }
        #expect(injector.occurrenceCount(for: .beforeDataCopy) == 4)

        preActorGate.release()
        await #expect(throws: LANInboxError.invalidState) {
            try await writes[0].value
        }
        for write in writes.dropFirst() { try await write.value }
        await #expect(throws: LANInboxError.resourceLimitExceeded) {
            try await rejectedWrite.value
        }
        for sink in sinks { await sink.abort() }
        #expect(
            admission.currentUsage
                == .init(activeOwnerCount: 0, pendingByteCount: 0, pendingChunkCount: 0)
        )
    }

    @Test
    func emptyDataAndBuffersDoNotConsumeDerivedTurnsAndCloseWithFinish() async throws {
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
        #expect(
            admission.currentUsage
                == .init(activeOwnerCount: 1, pendingByteCount: 0, pendingChunkCount: 0)
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
            admission.currentUsage
                == .init(activeOwnerCount: 0, pendingByteCount: 0, pendingChunkCount: 0)
        )
        #expect(await recorder.abortCount == 0)
    }

    @Test
    func sharedAdmissionAppliesTotalLimitsAcrossOwners() throws {
        let admission = try makeDerivedAdmission(
            ownerBytes: 8,
            totalBytes: 8,
            ownerChunks: 2,
            totalChunks: 2
        )
        let firstOwner = admission.acquireOwner()
        let secondOwner = admission.acquireOwner()
        let firstPermit = try firstOwner.acquire(byteCount: 8)

        #expect(throws: LANInboxError.resourceLimitExceeded) {
            try secondOwner.acquire(byteCount: 1)
        }
        #expect(
            admission.currentUsage
                == .init(activeOwnerCount: 2, pendingByteCount: 8, pendingChunkCount: 1)
        )

        firstPermit.release()
        firstOwner.release()
        secondOwner.release()
        #expect(
            admission.currentUsage
                == .init(activeOwnerCount: 0, pendingByteCount: 0, pendingChunkCount: 0)
        )
    }

    @Test
    func streamsMultipleChunkKindsAndSyncsBeforeOneReplayableFinalize() async throws {
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
        #expect(completed == replayed)
        #expect(completed.attemptID == fixture.attemptID)
        #expect(completed.byteCount == expected.count)
        #expect(completed.sha256Digest == Data(SHA256.hash(data: expected)))
        #expect(await recorder.finalizedArtifacts == [completed])
        #expect(await recorder.finalizedBytes == [expected])
        #expect(await recorder.abortCount == 0)
        #expect(events.snapshot == ["synced", "finalized"])
        #expect(try fixture.canAcquireExclusiveLock())
    }

    @Test
    func concurrentFinishesJoinAndAbortCannotRunBesideFinalization() async throws {
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
        await #expect(throws: LANInboxError.invalidState) {
            try await sink.write(Data("too-late".utf8)).value
        }
        await finalizeGate.release()

        let firstResult = try await firstFinish.value
        for task in joinedFinishes {
            #expect(try await task.value == firstResult)
        }
        for task in racingAborts { await task.value }
        #expect(try await sink.finish() == firstResult)
        #expect(await recorder.finalizedArtifacts == [firstResult])
        #expect(await recorder.abortCount == 0)
    }

    @Test
    func concurrentAbortsJoinOneDescriptorBoundCallbackAndRejectFinishAndWrite() async throws {
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
        await #expect(throws: LANInboxError.invalidState) {
            try await sink.write(Data("too-late".utf8)).value
        }
        await abortGate.release()

        await firstAbort.value
        for task in joinedAborts { await task.value }
        #expect(await finishWhileAborting.value)
        #expect(await recorder.abortCount == 1)
        #expect(await recorder.finalizedArtifacts.isEmpty)
        #expect(try fixture.canAcquireExclusiveLock())
    }

    @Test
    func writeFailureAndRacingTerminalCallsStillAbortExactlyOnce() async throws {
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

        await #expect(throws: SyntheticDerivedSinkFailure.self) {
            try await failingWrite.value
        }
        await joinedAbort.value
        #expect(await rejectedFinish.value)
        #expect(await recorder.abortCount == 1)
        #expect(await recorder.finalizedArtifacts.isEmpty)
    }

    @Test
    func thirdPendingChunkIsRejectedBeforeCopyAndDrainsExactlyOnce() async throws {
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
        #expect(
            admission.currentUsage
                == .init(activeOwnerCount: 1, pendingByteCount: 8, pendingChunkCount: 2)
        )

        let rejected = Task { try await sink.write(Data([0x43])).value }
        try await rejectionSignal.wait()
        #expect(injector.occurrenceCount(for: .beforeDataCopy) == 2)
        #expect(
            admission.highWaterMark
                == .init(pendingByteCount: 8, pendingChunkCount: 2)
        )
        #expect(await recorder.abortCount == 0)

        writeGate.release()
        await #expect(throws: LANInboxError.invalidState) {
            try await first.value
        }
        await #expect(throws: LANInboxError.invalidState) {
            try await second.value
        }
        await #expect(throws: LANInboxError.resourceLimitExceeded) {
            try await rejected.value
        }
        #expect(await recorder.abortCount == 1)
        #expect(await recorder.finalizedArtifacts.isEmpty)
        #expect(
            admission.currentUsage
                == .init(activeOwnerCount: 0, pendingByteCount: 0, pendingChunkCount: 0)
        )
    }

    @Test
    func tinyChunksCannotExceedConfiguredHighWaterMark() async throws {
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

        #expect(injector.occurrenceCount(for: .beforeDataCopy) == 4)
        #expect(
            admission.currentUsage
                == .init(activeOwnerCount: 1, pendingByteCount: 4, pendingChunkCount: 4)
        )
        #expect(
            admission.highWaterMark
                == .init(pendingByteCount: 4, pendingChunkCount: 4)
        )

        writeGate.release()
        for task in admitted {
            await #expect(throws: LANInboxError.invalidState) {
                try await task.value
            }
        }
        await #expect(throws: LANInboxError.resourceLimitExceeded) {
            try await rejected.value
        }
        #expect(await recorder.abortCount == 1)
        #expect(
            admission.currentUsage
                == .init(activeOwnerCount: 0, pendingByteCount: 0, pendingChunkCount: 0)
        )
    }

    @Test
    func byteBufferRetainedCapacityIsRejectedWithoutEnteringIO() async throws {
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
        let slice = try #require(backing.getSlice(at: 0, length: 1))
        #expect(slice.readableBytes == 1)
        #expect(slice.storageCapacity >= 32)

        await #expect(throws: LANInboxError.resourceLimitExceeded) {
            try await sink.write(slice).value
        }
        #expect(injector.occurrenceCount(for: .beforeWrite) == 0)
        #expect(await recorder.abortCount == 1)
        #expect(admission.highWaterMark == .init(pendingByteCount: 0, pendingChunkCount: 0))
        #expect(
            admission.currentUsage
                == .init(activeOwnerCount: 0, pendingByteCount: 0, pendingChunkCount: 0)
        )
    }

    @Test
    func abortRacingQueuedFinishDrainsPermitAndOwnsTerminalTransition() async throws {
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
        await #expect(throws: LANInboxError.invalidState) {
            try await writing.value
        }
        await #expect(throws: LANInboxError.invalidState) {
            try await finishing.value
        }
        await aborting.value
        #expect(await recorder.abortCount == 1)
        #expect(await recorder.finalizedArtifacts.isEmpty)
        #expect(
            admission.currentUsage
                == .init(activeOwnerCount: 0, pendingByteCount: 0, pendingChunkCount: 0)
        )
    }

    @Test
    func rejectsNonPrivateOrHardLinkedDescriptorsAtOwnershipTransfer() throws {
        let wrongMode = try DerivedDescriptorFixture(
            mode: 0o640,
            minimumDescriptor: 4_096
        )
        defer { wrongMode.destroy() }
        #expect(throws: LANInboxError.invalidState) {
            _ = try LANDerivedArtifactSink(
                attemptID: wrongMode.attemptID,
                descriptor: wrongMode.transferDescriptor(),
                abort: { _ in },
                finalize: { _, _ in }
            )
        }
        let wrongModeResult = fcntl(wrongMode.rawDescriptor, F_GETFD)
        let wrongModeError = errno
        #expect(wrongModeResult == -1)
        #expect(wrongModeError == EBADF)

        let hardLinked = try DerivedDescriptorFixture(
            addHardLink: true,
            minimumDescriptor: 4_096
        )
        defer { hardLinked.destroy() }
        #expect(throws: LANInboxError.invalidState) {
            _ = try LANDerivedArtifactSink(
                attemptID: hardLinked.attemptID,
                descriptor: hardLinked.transferDescriptor(),
                abort: { _ in },
                finalize: { _, _ in }
            )
        }
        let hardLinkResult = fcntl(hardLinked.rawDescriptor, F_GETFD)
        let hardLinkError = errno
        #expect(hardLinkResult == -1)
        #expect(hardLinkError == EBADF)
    }
}

private final class DerivedDescriptorFixture: @unchecked Sendable {
    let parentURL: URL
    let fileURL: URL
    let attemptID = UUID()
    let rawDescriptor: Int32

    private let lock = NSLock()
    private var fixtureOwnsDescriptor = true

    init(
        mode: mode_t = S_IRUSR | S_IWUSR,
        addHardLink: Bool = false,
        minimumDescriptor: Int32? = nil
    ) throws {
        parentURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kinlogue-derived-sink-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: parentURL,
            withIntermediateDirectories: false
        )
        fileURL = parentURL.appendingPathComponent("owned.partial")
        let openedDescriptor = Darwin.open(
            fileURL.path,
            O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode
        )
        guard openedDescriptor >= 0 else {
            throw DerivedSinkPOSIXFailure(code: errno)
        }
        if let minimumDescriptor {
            let duplicatedDescriptor = fcntl(
                openedDescriptor,
                F_DUPFD_CLOEXEC,
                minimumDescriptor
            )
            guard duplicatedDescriptor >= 0 else {
                let code = errno
                _ = Darwin.close(openedDescriptor)
                throw DerivedSinkPOSIXFailure(code: code)
            }
            _ = Darwin.close(openedDescriptor)
            rawDescriptor = duplicatedDescriptor
        } else {
            rawDescriptor = openedDescriptor
        }
        if addHardLink {
            let secondURL = parentURL.appendingPathComponent("second-link.partial")
            guard Darwin.link(fileURL.path, secondURL.path) == 0 else {
                _ = Darwin.close(rawDescriptor)
                throw DerivedSinkPOSIXFailure(code: errno)
            }
        }
    }

    func transferDescriptor() -> Int32 {
        lock.withLock {
            precondition(fixtureOwnsDescriptor)
            fixtureOwnsDescriptor = false
            return rawDescriptor
        }
    }

    func canAcquireExclusiveLock() throws -> Bool {
        let descriptor = Darwin.open(
            fileURL.path,
            O_RDWR | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw DerivedSinkPOSIXFailure(code: errno)
        }
        defer { _ = Darwin.close(descriptor) }

        let result = flock(descriptor, LOCK_EX | LOCK_NB)
        if result == 0 {
            _ = flock(descriptor, LOCK_UN)
            return true
        }
        if errno == EWOULDBLOCK { return false }
        throw DerivedSinkPOSIXFailure(code: errno)
    }

    func destroy() {
        let shouldClose = lock.withLock { () -> Bool in
            guard fixtureOwnsDescriptor else { return false }
            fixtureOwnsDescriptor = false
            return true
        }
        if shouldClose { _ = Darwin.close(rawDescriptor) }
        try? FileManager.default.removeItem(at: parentURL)
    }
}

private actor DerivedCallbackRecorder {
    private(set) var finalizedArtifacts: [LANDerivedArtifactSink.CompletedArtifact] = []
    private(set) var finalizedBytes: [Data] = []
    private(set) var abortCount = 0

    func recordFinalize(
        _ completed: LANDerivedArtifactSink.CompletedArtifact,
        descriptor: Int32
    ) throws {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_nlink == 1 else {
            throw DerivedSinkPOSIXFailure(code: errno)
        }
        finalizedArtifacts.append(completed)
        finalizedBytes.append(try readDescriptor(
            descriptor,
            byteCount: completed.byteCount
        ))
    }

    func recordAbort(descriptor: Int32) {
        var metadata = stat()
        #expect(fstat(descriptor, &metadata) == 0)
        #expect((metadata.st_mode & S_IFMT) == S_IFREG)
        abortCount += 1
    }
}

private final class DerivedEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    func append(_ event: String) {
        lock.withLock { events.append(event) }
    }

    var snapshot: [String] { lock.withLock { events } }
}

private actor DerivedAsyncGate {
    private var paused = false
    private var released = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func pause() async {
        paused = true
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilPaused(timeout: Duration = .seconds(5)) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !paused {
            if clock.now >= deadline {
                release()
                throw DerivedSinkGateTimeout()
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private func readDescriptor(_ descriptor: Int32, byteCount: Int) throws -> Data {
    var data = Data(count: byteCount)
    try data.withUnsafeMutableBytes { buffer in
        guard let baseAddress = buffer.baseAddress else { return }
        var offset = 0
        while offset < byteCount {
            let count = pread(
                descriptor,
                baseAddress.advanced(by: offset),
                byteCount - offset,
                off_t(offset)
            )
            if count < 0 {
                if errno == EINTR { continue }
                throw DerivedSinkPOSIXFailure(code: errno)
            }
            guard count > 0 else { throw DerivedSinkPOSIXFailure(code: EIO) }
            offset += count
        }
    }
    return data
}

private func makeDerivedAdmission(
    ownerBytes: Int,
    totalBytes: Int,
    ownerChunks: Int,
    totalChunks: Int
) throws -> LANPendingWriteAdmission {
    try LANPendingWriteAdmission(
        limits: .init(
            maximumPendingBytesPerOwner: ownerBytes,
            maximumTotalPendingBytes: totalBytes,
            maximumPendingChunksPerOwner: ownerChunks,
            maximumTotalPendingChunks: totalChunks
        )
    )
}

private func waitForDerivedOccurrence(
    _ injector: LANDerivedArtifactSink.FailureInjector,
    point: LANDerivedArtifactSink.FaultPoint,
    expectedCount: Int,
    timeout: Duration = .seconds(5)
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while injector.occurrenceCount(for: point) < expectedCount {
        if clock.now >= deadline { throw DerivedSinkGateTimeout() }
        try await Task.sleep(for: .milliseconds(1))
    }
}

private final class DerivedBlockingGate: @unchecked Sendable {
    private let condition = NSCondition()
    private let expectedEntries: Int
    private var entries = 0
    private var released = false

    init(expectedEntries: Int = 1) {
        self.expectedEntries = expectedEntries
    }

    func enterAndWait() {
        condition.lock()
        entries += 1
        condition.broadcast()
        while !released { condition.wait() }
        condition.unlock()
    }

    func waitUntilEntered(timeout: Duration = .seconds(5)) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !hasExpectedEntries {
            if clock.now >= deadline {
                release()
                throw DerivedSinkGateTimeout()
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private var hasExpectedEntries: Bool {
        condition.lock()
        defer { condition.unlock() }
        return entries >= expectedEntries
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

private final class DerivedSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var signaled = false

    func signal() {
        lock.withLock { signaled = true }
    }

    func wait(timeout: Duration = .seconds(5)) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !isSignaled {
            if clock.now >= deadline { throw DerivedSinkGateTimeout() }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private var isSignaled: Bool {
        lock.withLock { signaled }
    }
}

private struct SyntheticDerivedSinkFailure: Error, Equatable, Sendable {}
private struct DerivedSinkGateTimeout: Error, Equatable, Sendable {}

private struct DerivedSinkPOSIXFailure: Error, Equatable, Sendable {
    let code: Int32
}
