import CryptoKit
import Darwin
import Foundation
import KinlogueCore
import NIOCore
import NIOPosix

/// Streams one locally-produced derived artifact into a descriptor owned by
/// the inbox Store.
///
/// The sink never resolves a path and never renames the partial itself. Its
/// finalizer runs only after the complete descriptor has been synchronized,
/// while that same descriptor is still open and exclusively locked. The Store
/// can therefore validate its descriptor-bound context, rename with `renameat`,
/// and commit the manifest under its final mutation lease.
public actor LANDerivedArtifactSink {
    public struct CompletedArtifact: Equatable, Sendable {
        public let attemptID: UUID
        public let sha256Digest: Data
        public let byteCount: Int

        init(attemptID: UUID, sha256Digest: Data, byteCount: Int) {
            self.attemptID = attemptID
            self.sha256Digest = sha256Digest
            self.byteCount = byteCount
        }
    }

    /// Commits failure state and removes the exact partial through the Store's
    /// retained descriptor context. Cleanup failure is durable reconciliation
    /// debt and does not make a second abort callback eligible.
    typealias Abort = @Sendable (_ partialDescriptor: Int32) async throws -> Void

    /// Performs descriptor-bound publication and the authoritative manifest
    /// commit. Once that commit is observable, this callback must resolve any
    /// response-loss ambiguity as success rather than throw.
    typealias Finalize = @Sendable (
        _ completedArtifact: CompletedArtifact,
        _ partialDescriptor: Int32
    ) async throws -> Void

    enum FaultPoint: Hashable, Sendable {
        case beforeWrite
        case afterWrite
        case writeQueued
        case beforeDataCopy
        case pendingAdmissionRejected
        case finishQueued
        case finishJoined
        case abortRequested
        case terminalAbortJoined
        case admittedBeforeActorHop
        case beforeSync
        case afterSync
        case beforeFinalize
        case beforeAbort
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
        case finished(CompletedArtifact)
        case failed
        case aborted
    }

    private typealias Chunk = LANFileWriteSupport.Chunk

    private static let ioThreadPool: NIOThreadPool = {
        let pool = NIOThreadPool(numberOfThreads: 1)
        pool.start()
        return pool
    }()

    private let attemptID: UUID
    private let descriptor: Int32
    private let abortCallback: Abort
    private let finalizeCallback: Finalize
    private let failureInjector: FailureInjector
    private let maximumWriteByteCount: Int
    private let pendingWriteOwner: LANPendingWriteAdmission.Owner
    private let preActorWriteQueue = LANPreActorWriteQueue()

    private var hasher = SHA256()
    private var byteCount = 0
    private var state: State = .open
    private var writeTail: Task<Void, Error>?
    private var writeSequence = 0
    private var finishTask: Task<CompletedArtifact, Error>?
    private var abortRequested = false
    private var failureRequested = false
    private var descriptorIsOpen = true
    private var terminalAbortInProgress = false
    private var terminalAbortWaiters: [CheckedContinuation<Void, Never>] = []

    /// Internal by design: only KinloguePlatform's Store may transfer an owned
    /// partial descriptor and its descriptor-bound context into this sink.
    init(
        attemptID: UUID,
        descriptor: Int32,
        abort: @escaping Abort,
        finalize: @escaping Finalize,
        pendingWriteOwner: LANPendingWriteAdmission.Owner? = nil
    ) throws {
        let resolvedOwner: LANPendingWriteAdmission.Owner
        do {
            resolvedOwner = try Self.resolvePendingWriteOwner(pendingWriteOwner)
        } catch {
            _ = Darwin.close(descriptor)
            pendingWriteOwner?.release()
            throw error
        }
        do {
            try LANFileWriteSupport.validateEmptyOwnedDescriptor(descriptor)
        } catch {
            _ = Darwin.close(descriptor)
            resolvedOwner.release()
            throw error
        }
        self.attemptID = attemptID
        self.descriptor = descriptor
        abortCallback = abort
        finalizeCallback = finalize
        failureInjector = .none
        maximumWriteByteCount = .max
        self.pendingWriteOwner = resolvedOwner
    }

    init(
        attemptID: UUID,
        descriptor: Int32,
        abort: @escaping Abort,
        finalize: @escaping Finalize,
        failureInjector: FailureInjector,
        maximumWriteByteCount: Int = .max,
        pendingWriteOwner: LANPendingWriteAdmission.Owner? = nil
    ) throws {
        guard maximumWriteByteCount > 0 else {
            _ = Darwin.close(descriptor)
            pendingWriteOwner?.release()
            throw LANInboxError.invalidState
        }
        let resolvedOwner: LANPendingWriteAdmission.Owner
        do {
            resolvedOwner = try Self.resolvePendingWriteOwner(pendingWriteOwner)
        } catch {
            _ = Darwin.close(descriptor)
            pendingWriteOwner?.release()
            throw error
        }
        do {
            try LANFileWriteSupport.validateEmptyOwnedDescriptor(descriptor)
        } catch {
            _ = Darwin.close(descriptor)
            resolvedOwner.release()
            throw error
        }
        self.attemptID = attemptID
        self.descriptor = descriptor
        abortCallback = abort
        finalizeCallback = finalize
        self.failureInjector = failureInjector
        self.maximumWriteByteCount = maximumWriteByteCount
        self.pendingWriteOwner = resolvedOwner
    }

    deinit {
        _ = preActorWriteQueue.closeAndSnapshotTail()
        pendingWriteOwner.release()
        guard descriptorIsOpen else { return }
        let descriptor = descriptor
        Self.ioThreadPool.submit { _ in _ = Darwin.close(descriptor) }
    }

    /// Synchronously reserves pending memory before the transferred body can
    /// cross an actor/executor hop. Callers await the returned task's `value`.
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
        let permit: LANPendingWriteAdmission.Permit
        do {
            permit = try pendingWriteOwner.acquire(byteCount: source.count)
        } catch {
            source = Data()
            return schedulePendingAdmissionRejection(error, turn: turn)
        }

        try? failureInjector.failIfRequested(.beforeDataCopy)
        let rightSizedCopy = source.withUnsafeBytes { buffer -> Data in
            guard let baseAddress = buffer.baseAddress else { return Data() }
            return Data(bytes: baseAddress, count: buffer.count)
        }
        source = Data()
        try? failureInjector.failIfRequested(.admittedBeforeActorHop)
        return scheduleAdmittedWrite(.data(rightSizedCopy), permit: permit, turn: turn)
    }

    public nonisolated func write(_ buffer: ByteBuffer) -> Task<Void, Error> {
        guard buffer.readableBytes > 0 else { return preActorWriteQueue.noOpWrite() }
        let turn: LANPreActorWriteQueue.Turn
        do {
            turn = try preActorWriteQueue.beginTurn()
        } catch {
            return Task { throw error }
        }
        let permit: LANPendingWriteAdmission.Permit
        do {
            permit = try pendingWriteOwner.acquire(
                byteCount: max(buffer.readableBytes, buffer.storageCapacity)
            )
        } catch {
            return schedulePendingAdmissionRejection(error, turn: turn)
        }
        try? failureInjector.failIfRequested(.admittedBeforeActorHop)
        return scheduleAdmittedWrite(.byteBuffer(buffer), permit: permit, turn: turn)
    }

    private nonisolated func scheduleAdmittedWrite(
        _ chunk: Chunk,
        permit: LANPendingWriteAdmission.Permit,
        turn: LANPreActorWriteQueue.Turn
    ) -> Task<Void, Error> {
        return Task { [self] in
            if let predecessor = turn.predecessor { await predecessor.wait() }
            do {
                let accepted = try await self.accept(chunk, permit: permit)
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
        _ error: Error,
        turn: LANPreActorWriteQueue.Turn
    ) -> Task<Void, Error> {
        _ = preActorWriteQueue.closeAndSnapshotTail()
        try? failureInjector.failIfRequested(.pendingAdmissionRejected)
        return Task { [self] in
            if let predecessor = turn.predecessor { await predecessor.wait() }
            do {
                let predecessor = try await self.beginPendingAdmissionRejection()
                turn.admitted.signal()
                if let predecessor { _ = await predecessor.result }
                try await self.completePendingAdmissionRejection(error)
            } catch {
                turn.admitted.signal()
                throw error
            }
        }
    }

    private func validateWriteAdmission(byteCount: Int) throws {
        guard case .open = state,
              finishTask == nil,
              !abortRequested,
              !failureRequested else {
            throw LANInboxError.invalidState
        }
        guard byteCount >= 0 else { throw LANInboxError.invalidState }
    }

    private func beginPendingAdmissionRejection() throws -> Task<Void, Error>? {
        try validateWriteAdmission(byteCount: 0)
        failureRequested = true
        return writeTail
    }

    private func completePendingAdmissionRejection(_ error: Error) async throws -> Never {
        if case .open = state { await abortTerminal(as: .failed) }
        throw error
    }

    private struct AcceptedWrite: Sendable {
        let task: Task<Void, Error>
        let sequence: Int
    }

    private func accept(
        _ chunk: Chunk,
        permit: LANPendingWriteAdmission.Permit
    ) throws -> AcceptedWrite {
        try validateWriteAdmission(byteCount: chunk.byteCount)

        let predecessor = writeTail
        if predecessor != nil {
            try? failureInjector.failIfRequested(.writeQueued)
        }
        writeSequence &+= 1
        let sequence = writeSequence
        let task = Task { [weak self] in
            defer { permit.release() }
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

    /// Synchronizes the exact partial and invokes the Store finalizer while
    /// the descriptor is still open. Concurrent finishes join one finalizer;
    /// once finish has started, a racing abort waits for that result.
    public func finish() async throws -> CompletedArtifact {
        let lastSubmittedWrite = preActorWriteQueue.closeAndSnapshotTail()
        if let lastSubmittedWrite { await lastSubmittedWrite.wait() }
        switch state {
        case .finished(let completed):
            return completed
        case .failed, .aborted:
            throw LANInboxError.invalidState
        case .open:
            break
        }
        if let finishTask {
            try? failureInjector.failIfRequested(.finishJoined)
            return try await finishTask.value
        }
        guard !abortRequested, !failureRequested else {
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

    /// Aborts the partial exactly once. If finish already owns the terminal
    /// transition, abort joins it instead of running cleanup concurrently with
    /// a descriptor-bound rename or manifest publication.
    public func abort() async {
        let lastSubmittedWrite = preActorWriteQueue.closeAndSnapshotTail()
        if let lastSubmittedWrite { await lastSubmittedWrite.wait() }
        switch state {
        case .finished:
            return
        case .failed, .aborted:
            await waitForTerminalAbortIfNeeded()
            return
        case .open:
            break
        }
        abortRequested = true
        try? failureInjector.failIfRequested(.abortRequested)

        if let finishTask {
            _ = await finishTask.result
        } else if let writeTail {
            _ = await writeTail.result
        }

        if case .open = state {
            await abortTerminal(as: .aborted)
        } else {
            await waitForTerminalAbortIfNeeded()
        }
    }

    private func performWrite(_ chunk: Chunk) async throws {
        guard case .open = state,
              !abortRequested,
              !failureRequested else {
            if case .open = state {
                await abortTerminal(as: failureRequested ? .failed : .aborted)
            }
            throw LANInboxError.invalidState
        }

        let nextByteCount: Int
        do {
            nextByteCount = try LANFileWriteSupport.checkedSum(
                byteCount,
                chunk.byteCount
            )
        } catch {
            failureRequested = true
            await abortTerminal(as: .failed)
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
            guard !abortRequested, !failureRequested else {
                await abortTerminal(as: failureRequested ? .failed : .aborted)
                throw LANInboxError.invalidState
            }
            chunk.withUnsafeReadableBytes { hasher.update(bufferPointer: $0) }
            byteCount = nextByteCount
        } catch {
            failureRequested = true
            if case .open = state { await abortTerminal(as: .failed) }
            throw LANFileWriteSupport.mappedStorageError(error)
        }
    }

    private func performFinish() async throws -> CompletedArtifact {
        guard case .open = state,
              !abortRequested,
              !failureRequested else {
            if case .open = state {
                await abortTerminal(as: failureRequested ? .failed : .aborted)
            }
            throw LANInboxError.invalidState
        }

        do {
            let descriptor = descriptor
            let failureInjector = failureInjector
            try await Self.ioThreadPool.runIfActive {
                try failureInjector.failIfRequested(.beforeSync)
                try Self.sync(descriptor)
                try failureInjector.failIfRequested(.afterSync)
            }
            guard !abortRequested, !failureRequested else {
                await abortTerminal(as: failureRequested ? .failed : .aborted)
                throw LANInboxError.invalidState
            }

            let completed = CompletedArtifact(
                attemptID: attemptID,
                sha256Digest: Data(hasher.finalize()),
                byteCount: byteCount
            )
            try failureInjector.failIfRequested(.beforeFinalize)
            try await finalizeCallback(completed, descriptor)

            await closeDescriptorIgnoringErrors()
            state = .finished(completed)
            finishTask = nil
            pendingWriteOwner.release()
            return completed
        } catch {
            failureRequested = true
            if case .open = state { await abortTerminal(as: .failed) }
            throw LANFileWriteSupport.mappedStorageError(error)
        }
    }

    private enum AbortState {
        case failed
        case aborted
    }

    private func abortTerminal(as terminalState: AbortState) async {
        _ = preActorWriteQueue.closeAndSnapshotTail()
        guard case .open = state else {
            await waitForTerminalAbortIfNeeded()
            return
        }
        state = terminalState == .aborted ? .aborted : .failed
        finishTask = nil
        terminalAbortInProgress = true

        if descriptorIsOpen {
            let descriptor = descriptor
            do {
                try failureInjector.failIfRequested(.beforeAbort)
                try await abortCallback(descriptor)
            } catch {
                // The Store has either committed terminal state or left
                // restart-recoverable debt. The descriptor must still close.
            }
            await closeDescriptorIgnoringErrors()
        }
        pendingWriteOwner.release()
        terminalAbortInProgress = false
        let waiters = terminalAbortWaiters
        terminalAbortWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func waitForTerminalAbortIfNeeded() async {
        guard terminalAbortInProgress else { return }
        try? failureInjector.failIfRequested(.terminalAbortJoined)
        await withCheckedContinuation { terminalAbortWaiters.append($0) }
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
                _ = Darwin.close(descriptor)
                continuation.resume()
            }
        }
    }

    private static func resolvePendingWriteOwner(
        _ owner: LANPendingWriteAdmission.Owner?
    ) throws -> LANPendingWriteAdmission.Owner {
        if let owner { return owner }
        let admission = try LANPendingWriteAdmission(limits: .derivedProduction)
        return admission.acquireOwner()
    }

    private static func sync(_ descriptor: Int32) throws {
        if fcntl(descriptor, F_FULLFSYNC) == 0 { return }
        while fsync(descriptor) != 0 {
            if errno == EINTR { continue }
            throw LANFileWriteSupport.POSIXFailure(code: errno)
        }
    }
}
