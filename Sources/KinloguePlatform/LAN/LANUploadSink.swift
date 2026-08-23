import CryptoKit
import Darwin
import Foundation
import KinlogueCore
import NIOCore
import NIOPosix

/// Owns one already-created partial-file descriptor for the lifetime of a LAN
/// upload attempt. The caller must create the descriptor with `O_NOFOLLOW`,
/// `O_CLOEXEC`, exclusive ownership and a zero byte offset before transferring
/// it to this actor.
public actor LANUploadSink {
    public struct CompletedUpload: Equatable, Sendable {
        public let attemptID: UUID
        public let sha256Digest: Data
        public let byteCount: Int

        public init(attemptID: UUID, sha256Digest: Data, byteCount: Int) {
            self.attemptID = attemptID
            self.sha256Digest = sha256Digest
            self.byteCount = byteCount
        }
    }

    /// The store must commit the durable attempt/interrupted transition before
    /// unlinking the partial through its retained directory descriptor.
    public typealias Cleanup = @Sendable (_ partialDescriptor: Int32) async throws -> Void

    /// A publisher must resolve response-loss ambiguity before returning: once
    /// its desired durable commit is observed it returns success, and it throws
    /// only while cleanup of this partial is still safe.
    public typealias Publish = @Sendable (
        _ completedUpload: CompletedUpload,
        _ partialDescriptor: Int32
    ) async throws -> Void

    enum FaultPoint: Hashable, Sendable {
        case beforeWrite
        case afterWrite
        case writeQueued
        case beforeDataCopy
        case pendingChunkRejected
        case pendingMemoryRejected
        case finishQueued
        case finishJoined
        case cancellationRequested
        case terminalCleanupJoined
        case admittedBeforeActorHop
        case beforeSync
        case afterSync
        case beforePublish
        case beforeCleanup
    }

    // SAFETY: `lock` protects occurrence counters, and the handler is an
    // immutable `@Sendable` closure.
    final class FailureInjector: @unchecked Sendable {
        typealias Handler = @Sendable (_ point: FaultPoint, _ occurrence: Int) throws -> Void

        static let none = FailureInjector { _, _ in }

        private let lock = NSLock()
        private var occurrences: [FaultPoint: Int] = [:]
        private let handler: Handler

        init(_ handler: @escaping Handler) {
            self.handler = handler
        }

        func failIfRequested(_ point: FaultPoint) throws {
            let occurrence = lock.withLock {
                let next = (occurrences[point] ?? 0) + 1
                occurrences[point] = next
                return next
            }
            try handler(point, occurrence)
        }

        func occurrenceCount(for point: FaultPoint) -> Int {
            lock.withLock { occurrences[point] ?? 0 }
        }
    }

    private enum State {
        case open
        case finished(CompletedUpload)
        case failed
        case cancelled
    }

    private typealias Chunk = LANFileWriteSupport.Chunk

    /// Bounds task-chain amplification independently of the byte budget. A
    /// caller can otherwise queue millions of one-byte chunks while remaining
    /// below the per-upload pending-memory limit.
    // SAFETY: Limiter count and permit ownership are independently lock-protected;
    // permit release is idempotent and never runs while holding the limiter lock.
    private final class PendingChunkLimiter: @unchecked Sendable {
        final class Permit: @unchecked Sendable {
            private let lock = NSLock()
            private var limiter: PendingChunkLimiter?

            fileprivate init(limiter: PendingChunkLimiter) {
                self.limiter = limiter
            }

            func release() {
                let limiter = lock.withLock { () -> PendingChunkLimiter? in
                    defer { self.limiter = nil }
                    return self.limiter
                }
                limiter?.release()
            }

            deinit { release() }
        }

        private let lock = NSLock()
        private let limit: Int
        private var count = 0

        init(limit: Int) {
            precondition(limit > 0)
            self.limit = limit
        }

        func acquire() throws -> Permit {
            try lock.withLock {
                guard count < limit else {
                    throw LANInboxError.resourceLimitExceeded
                }
                count += 1
                return Permit(limiter: self)
            }
        }

        private func release() {
            lock.withLock {
                precondition(count > 0)
                count -= 1
            }
        }
    }

    private final class PendingReservations: Sendable {
        private let memoryPermit: LANInboxAdmissionPolicy.PendingMemoryPermit
        private let chunkPermit: PendingChunkLimiter.Permit

        init(
            memoryPermit: LANInboxAdmissionPolicy.PendingMemoryPermit,
            chunkPermit: PendingChunkLimiter.Permit
        ) {
            self.memoryPermit = memoryPermit
            self.chunkPermit = chunkPermit
        }

        func release() {
            memoryPermit.release()
            chunkPermit.release()
        }

        deinit { release() }
    }

    // SAFETY: This immutable wrapper is created, thrown, and consumed within one
    // sink task chain; the existential error is never mutated or shared separately.
    private struct PendingAdmissionFailure: Error, @unchecked Sendable {
        let underlying: Error
        let faultPoint: FaultPoint
    }

    private static let ioThreadPool: NIOThreadPool = {
        let pool = NIOThreadPool(numberOfThreads: 2)
        pool.start()
        return pool
    }()

    private let attemptID: UUID
    private let descriptor: Int32
    private let declaredByteCount: Int?
    private let uploadPermit: LANInboxAdmissionPolicy.UploadPermit
    private let cleanup: Cleanup
    private let publish: Publish
    private let failureInjector: FailureInjector
    private let maximumWriteByteCount: Int
    private let pendingChunkLimiter = PendingChunkLimiter(limit: 64)
    private let preActorWriteQueue = LANPreActorWriteQueue()

    private var hasher = SHA256()
    private var receivedByteCount = 0
    private var state: State = .open
    private var writeTail: Task<Void, Error>?
    private var writeSequence = 0
    private var finishTask: Task<CompletedUpload, Error>?
    private var cancellationRequested = false
    private var failureRequested = false
    private var descriptorIsOpen = true
    private var terminalCleanupInProgress = false
    private var terminalCleanupWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        attemptID: UUID,
        descriptor: Int32,
        declaredByteCount: Int?,
        uploadPermit: LANInboxAdmissionPolicy.UploadPermit,
        cleanup: @escaping Cleanup,
        publish: @escaping Publish
    ) throws {
        do {
            if let declaredByteCount, declaredByteCount < 0 {
                throw LANInboxError.invalidState
            }
            try LANFileWriteSupport.validateEmptyOwnedDescriptor(descriptor)
        } catch {
            _ = Darwin.close(descriptor)
            uploadPermit.release()
            throw error
        }
        self.attemptID = attemptID
        self.descriptor = descriptor
        self.declaredByteCount = declaredByteCount
        self.uploadPermit = uploadPermit
        self.cleanup = cleanup
        self.publish = publish
        self.failureInjector = .none
        self.maximumWriteByteCount = .max
    }

    init(
        attemptID: UUID,
        descriptor: Int32,
        declaredByteCount: Int?,
        uploadPermit: LANInboxAdmissionPolicy.UploadPermit,
        cleanup: @escaping Cleanup,
        publish: @escaping Publish,
        failureInjector: FailureInjector,
        maximumWriteByteCount: Int = .max
    ) throws {
        guard maximumWriteByteCount > 0 else {
            _ = Darwin.close(descriptor)
            uploadPermit.release()
            throw LANInboxError.invalidState
        }
        do {
            if let declaredByteCount, declaredByteCount < 0 {
                throw LANInboxError.invalidState
            }
            try LANFileWriteSupport.validateEmptyOwnedDescriptor(descriptor)
        } catch {
            _ = Darwin.close(descriptor)
            uploadPermit.release()
            throw error
        }
        self.attemptID = attemptID
        self.descriptor = descriptor
        self.declaredByteCount = declaredByteCount
        self.uploadPermit = uploadPermit
        self.cleanup = cleanup
        self.publish = publish
        self.failureInjector = failureInjector
        self.maximumWriteByteCount = maximumWriteByteCount
    }

    deinit {
        _ = preActorWriteQueue.closeAndSnapshotTail()
        guard descriptorIsOpen else { return }
        let descriptor = descriptor
        let uploadPermit = uploadPermit
        Self.ioThreadPool.submit { state in
            _ = state
            _ = Darwin.close(descriptor)
            uploadPermit.release()
        }
    }

    /// Synchronously admits and owns a chunk before returning an asynchronous
    /// operation. Callers must await the returned task's `value`.
    ///
    /// Keeping this facade synchronous is security-relevant: an `async` actor
    /// entry can retain its `Data` argument in the actor mailbox before any
    /// admission code runs. Here the turn and memory permits are acquired on
    /// the caller's current executor before the right-sized body copy or actor
    /// hop can occur.
    public nonisolated func write(
        _ bytes: consuming Data
    ) -> Task<Void, Error> {
        var source = consume bytes
        guard !source.isEmpty else { return preActorWriteQueue.noOpWrite() }
        let turn: LANPreActorWriteQueue.Turn
        do {
            turn = try preActorWriteQueue.beginTurn()
        } catch {
            source = Data()
            return Task { throw error }
        }
        let reservations: PendingReservations
        do {
            reservations = try acquirePendingReservations(
                pendingByteCount: source.count
            )
        } catch {
            source = Data()
            let failure = (error as? PendingAdmissionFailure)
                ?? PendingAdmissionFailure(
                    underlying: error,
                    faultPoint: .pendingMemoryRejected
                )
            return schedulePendingAdmissionRejection(failure, turn: turn)
        }

        // Admission must precede the right-sized copy. Otherwise an oversized
        // rejected body can transiently bypass the pending-memory budget.
        try? failureInjector.failIfRequested(.beforeDataCopy)
        let rightSizedCopy = source.withUnsafeBytes { buffer -> Data in
            guard let baseAddress = buffer.baseAddress else { return Data() }
            return Data(bytes: baseAddress, count: buffer.count)
        }
        // A Data slice may retain a much larger backing allocation. Destroy
        // the consumed input before suspension so queued memory is exactly the
        // right-sized copy charged by admission accounting.
        source = Data()
        try? failureInjector.failIfRequested(.admittedBeforeActorHop)
        return scheduleAdmittedWrite(
            .data(rightSizedCopy),
            reservations: reservations,
            turn: turn
        )
    }

    /// Streams the readable region directly from NIO's body buffer without
    /// first materializing a second whole-chunk `Data` value.
    public nonisolated func write(_ buffer: ByteBuffer) -> Task<Void, Error> {
        guard buffer.readableBytes > 0 else { return preActorWriteQueue.noOpWrite() }
        let turn: LANPreActorWriteQueue.Turn
        do {
            turn = try preActorWriteQueue.beginTurn()
        } catch {
            return Task { throw error }
        }
        let reservations: PendingReservations
        do {
            reservations = try acquirePendingReservations(
                pendingByteCount: max(buffer.readableBytes, buffer.storageCapacity)
            )
        } catch {
            let failure = (error as? PendingAdmissionFailure)
                ?? PendingAdmissionFailure(
                    underlying: error,
                    faultPoint: .pendingMemoryRejected
                )
            return schedulePendingAdmissionRejection(failure, turn: turn)
        }
        try? failureInjector.failIfRequested(.admittedBeforeActorHop)
        return scheduleAdmittedWrite(
            .byteBuffer(buffer),
            reservations: reservations,
            turn: turn
        )
    }

    private nonisolated func scheduleAdmittedWrite(
        _ chunk: Chunk,
        reservations: PendingReservations,
        turn: LANPreActorWriteQueue.Turn
    ) -> Task<Void, Error> {
        return Task { [self] in
            if let predecessor = turn.predecessor { await predecessor.wait() }
            do {
                let accepted = try await self.accept(
                    chunk,
                    reservations: reservations
                )
                turn.admitted.signal()
                do {
                    try await accepted.task.value
                    await self.clearWriteTail(sequence: accepted.sequence)
                } catch {
                    await self.clearWriteTail(sequence: accepted.sequence)
                    throw error
                }
            } catch {
                turn.admitted.signal()
                throw error
            }
        }
    }

    private nonisolated func schedulePendingAdmissionRejection(
        _ failure: PendingAdmissionFailure,
        turn: LANPreActorWriteQueue.Turn
    ) -> Task<Void, Error> {
        // Close synchronously as well: if an earlier admitted body is paused
        // before its actor hop, waiting to close inside the actor would allow
        // an unbounded chain of already-rejected turns to accumulate behind it.
        _ = preActorWriteQueue.closeAndSnapshotTail()
        // Expose rejection at the same synchronous boundary as reservation so
        // tests and diagnostics can prove an oversized body never actor-hops.
        try? failureInjector.failIfRequested(failure.faultPoint)
        return Task { [self] in
            if let predecessor = turn.predecessor { await predecessor.wait() }
            do {
                let predecessor = try await self.beginPendingAdmissionRejection(failure)
                turn.admitted.signal()
                if let predecessor { _ = await predecessor.result }
                try await self.completePendingAdmissionRejection(failure)
            } catch {
                turn.admitted.signal()
                throw error
            }
        }
    }

    private func validateWriteAdmission(byteCount: Int) throws {
        guard case .open = state,
              finishTask == nil,
              !cancellationRequested,
              !failureRequested else {
            throw LANInboxError.invalidState
        }
        guard byteCount >= 0 else { throw LANInboxError.invalidState }
    }

    private nonisolated func acquirePendingReservations(
        pendingByteCount: Int
    ) throws -> PendingReservations {
        let chunkPermit: PendingChunkLimiter.Permit
        do {
            chunkPermit = try pendingChunkLimiter.acquire()
        } catch {
            throw PendingAdmissionFailure(
                underlying: error,
                faultPoint: .pendingChunkRejected
            )
        }

        do {
            let memoryPermit = try uploadPermit.acquirePendingMemoryPermit(
                byteCount: pendingByteCount
            )
            return PendingReservations(
                memoryPermit: memoryPermit,
                chunkPermit: chunkPermit
            )
        } catch {
            chunkPermit.release()
            throw PendingAdmissionFailure(
                underlying: error,
                faultPoint: .pendingMemoryRejected
            )
        }
    }

    private func beginPendingAdmissionRejection(
        _ failure: PendingAdmissionFailure
    ) throws -> Task<Void, Error>? {
        try validateWriteAdmission(byteCount: 0)
        failureRequested = true
        return writeTail
    }

    private func completePendingAdmissionRejection(
        _ failure: PendingAdmissionFailure
    ) async throws -> Never {
        if case .open = state { await abort(as: .failed) }
        throw failure.underlying
    }

    private struct AcceptedWrite: Sendable {
        let task: Task<Void, Error>
        let sequence: Int
    }

    private func accept(
        _ chunk: Chunk,
        reservations: PendingReservations
    ) throws -> AcceptedWrite {
        try validateWriteAdmission(byteCount: chunk.byteCount)

        let predecessor = writeTail
        if predecessor != nil {
            try? failureInjector.failIfRequested(.writeQueued)
        }
        writeSequence &+= 1
        let sequence = writeSequence
        let task = Task { [weak self] in
            defer { reservations.release() }
            if let predecessor { try await predecessor.value }
            guard let self else { throw LANInboxError.invalidState }
            try await self.performWrite(chunk)
        }
        writeTail = task
        return AcceptedWrite(task: task, sequence: sequence)
    }

    private func clearWriteTail(sequence: Int) {
        if writeSequence == sequence { writeTail = nil }
    }

    /// Syncs the complete partial and invokes the authoritative publication
    /// closure while the original descriptor is still open. Repeated finishes
    /// return the same value; a cancelled or failed attempt cannot finish late.
    public func finish() async throws -> CompletedUpload {
        let lastSubmittedWrite = preActorWriteQueue.closeAndSnapshotTail()
        if let lastSubmittedWrite { await lastSubmittedWrite.wait() }
        switch state {
        case .finished(let completed):
            return completed
        case .failed, .cancelled:
            throw LANInboxError.invalidState
        case .open:
            break
        }
        if let finishTask {
            try? failureInjector.failIfRequested(.finishJoined)
            return try await finishTask.value
        }
        guard !cancellationRequested, !failureRequested else {
            throw LANInboxError.invalidState
        }

        let predecessor = writeTail
        if predecessor != nil {
            try? failureInjector.failIfRequested(.finishQueued)
        }
        let task = Task { [weak self] in
            if let predecessor { try await predecessor.value }
            guard let self else { throw LANInboxError.invalidState }
            return try await self.performFinish()
        }
        finishTask = task
        return try await task.value
    }

    /// Cancels an attempt and waits until any in-flight blocking operation has
    /// released its pending-memory reservation before returning.
    public func cancel() async {
        let lastSubmittedWrite = preActorWriteQueue.closeAndSnapshotTail()
        if let lastSubmittedWrite { await lastSubmittedWrite.wait() }
        switch state {
        case .finished:
            return
        case .failed, .cancelled:
            await waitForTerminalCleanupIfNeeded()
            return
        case .open:
            break
        }
        cancellationRequested = true
        try? failureInjector.failIfRequested(.cancellationRequested)

        if let finishTask {
            _ = await finishTask.result
        } else if let writeTail {
            _ = await writeTail.result
        }

        if case .open = state {
            await abort(as: .cancelled)
        }
    }

    private func performWrite(_ chunk: Chunk) async throws {
        guard case .open = state,
              !cancellationRequested,
              !failureRequested else {
            if case .open = state {
                await abort(as: failureRequested ? .failed : .cancelled)
            }
            throw LANInboxError.invalidState
        }

        let nextByteCount: Int
        do {
            nextByteCount = try LANFileWriteSupport.checkedSum(
                receivedByteCount,
                chunk.byteCount
            )
            if let declaredByteCount, nextByteCount > declaredByteCount {
                throw LANInboxError.integrityCheckFailed
            }
        } catch {
            await abort(as: .failed)
            throw error
        }

        do {
            let descriptor = descriptor
            let failureInjector = failureInjector
            let maximumWriteByteCount = maximumWriteByteCount
            try await Self.ioThreadPool.runIfActive {
                try LANFileWriteSupport.writeAll(
                    chunk,
                    to: descriptor,
                    maximumWriteByteCount: maximumWriteByteCount,
                    beforeWrite: { try failureInjector.failIfRequested(.beforeWrite) },
                    afterWrite: { try failureInjector.failIfRequested(.afterWrite) }
                )
            }
            guard !cancellationRequested, !failureRequested else {
                await abort(as: failureRequested ? .failed : .cancelled)
                throw LANInboxError.invalidState
            }
            chunk.withUnsafeReadableBytes { hasher.update(bufferPointer: $0) }
            receivedByteCount = nextByteCount
        } catch {
            if case .open = state { await abort(as: .failed) }
            throw LANFileWriteSupport.mappedStorageError(error)
        }
    }

    private func performFinish() async throws -> CompletedUpload {
        guard case .open = state,
              !cancellationRequested,
              !failureRequested else {
            if case .open = state {
                await abort(as: failureRequested ? .failed : .cancelled)
            }
            throw LANInboxError.invalidState
        }
        guard declaredByteCount == nil || declaredByteCount == receivedByteCount else {
            await abort(as: .failed)
            throw LANInboxError.integrityCheckFailed
        }

        do {
            let descriptor = descriptor
            let failureInjector = failureInjector
            try await Self.ioThreadPool.runIfActive {
                try failureInjector.failIfRequested(.beforeSync)
                try Self.sync(descriptor)
                try failureInjector.failIfRequested(.afterSync)
            }
            guard !cancellationRequested, !failureRequested else {
                await abort(as: failureRequested ? .failed : .cancelled)
                throw LANInboxError.invalidState
            }

            let completed = CompletedUpload(
                attemptID: attemptID,
                sha256Digest: Data(hasher.finalize()),
                byteCount: receivedByteCount
            )
            try failureInjector.failIfRequested(.beforePublish)
            try await publish(completed, descriptor)

            await closeAfterSuccessfulPublication()
            state = .finished(completed)
            finishTask = nil
            uploadPermit.release()
            return completed
        } catch {
            if case .open = state { await abort(as: .failed) }
            throw LANFileWriteSupport.mappedStorageError(error)
        }
    }

    private enum AbortState {
        case failed
        case cancelled
    }

    private func abort(as terminalState: AbortState) async {
        _ = preActorWriteQueue.closeAndSnapshotTail()
        guard case .open = state else {
            await waitForTerminalCleanupIfNeeded()
            return
        }
        state = terminalState == .cancelled ? .cancelled : .failed
        finishTask = nil
        terminalCleanupInProgress = true

        if descriptorIsOpen {
            let descriptor = descriptor
            let cleanup = cleanup
            let failureInjector = failureInjector
            do {
                try failureInjector.failIfRequested(.beforeCleanup)
                try await cleanup(descriptor)
            } catch {
                // The authoritative interrupted/uploading state remains
                // recoverable. Closing the descriptor releases its advisory
                // lock so startup reconciliation can reclaim the partial.
            }
            await closeDescriptorIgnoringErrors()
        }
        uploadPermit.release()
        terminalCleanupInProgress = false
        let waiters = terminalCleanupWaiters
        terminalCleanupWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func waitForTerminalCleanupIfNeeded() async {
        guard terminalCleanupInProgress else { return }
        try? failureInjector.failIfRequested(.terminalCleanupJoined)
        await withCheckedContinuation { terminalCleanupWaiters.append($0) }
    }

    private func closeAfterSuccessfulPublication() async {
        guard descriptorIsOpen else { return }
        let descriptor = descriptor
        await Self.closeOnIOThread(descriptor)
        descriptorIsOpen = false
    }

    private func closeDescriptorIgnoringErrors() async {
        guard descriptorIsOpen else { return }
        let descriptor = descriptor
        await Self.closeOnIOThread(descriptor)
        descriptorIsOpen = false
    }

    private static func closeOnIOThread(_ descriptor: Int32) async {
        await withCheckedContinuation { continuation in
            ioThreadPool.submit { _ in
                // `submit` invokes this closure even when the pool is no
                // longer active, so task cancellation cannot skip the close.
                _ = Darwin.close(descriptor)
                continuation.resume()
            }
        }
    }

    private static func sync(_ descriptor: Int32) throws {
        if fcntl(descriptor, F_FULLFSYNC) != 0, fsync(descriptor) != 0 {
            throw LANFileWriteSupport.POSIXFailure(code: errno)
        }
    }
}
