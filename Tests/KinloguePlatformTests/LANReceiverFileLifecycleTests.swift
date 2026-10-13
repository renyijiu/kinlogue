import Foundation
import NIOCore
import Testing
@testable import KinlogueCore
@testable import KinloguePlatform

@Suite("LAN receiver file lifecycle", .serialized)
struct LANReceiverFileLifecycleTests {
    @Test
    func interruptionRetrySaveReplayAndReservedCancellationStayFileScoped() async throws {
        let fixture = try await LANInboxStoreTestFixture.make()
        defer { fixture.destroy() }
        let receiver = LANReceiver(store: fixture.store, session: LANSession())
        defer { Task { await receiver.stop() } }
        let (_, authorization) = try await startAndAuthorize(receiver)
        let bytes = Data("synthetic receiver lifecycle".utf8)
        let remoteFileID = UUID()

        _ = try await receiver.reserveFile(
            request(remoteFileID: remoteFileID, bytes: bytes, revision: 0),
            authorizedBy: authorization
        )
        let interruptedLease = try await receiveLease(
            receiver: receiver,
            remoteFileID: remoteFileID,
            revision: 0,
            byteCount: bytes.count,
            authorization: authorization
        )
        try await interruptedLease.write(buffer(bytes)).value
        await interruptedLease.cancel()
        #expect(try await receiver.fileStatus(
            remoteFileID: remoteFileID,
            authorizedBy: authorization
        ).state == .interrupted)

        _ = try await receiver.reserveFile(
            request(remoteFileID: remoteFileID, bytes: bytes, revision: 1),
            authorizedBy: authorization
        )
        let retryLease = try await receiveLease(
            receiver: receiver,
            remoteFileID: remoteFileID,
            revision: 1,
            byteCount: bytes.count,
            authorization: authorization
        )
        try await retryLease.write(buffer(bytes)).value
        _ = try await retryLease.finish()
        #expect(try await receiver.fileStatus(
            remoteFileID: remoteFileID,
            authorizedBy: authorization
        ).state == .saved)
        guard case .alreadySaved = try await receiver.startFileUpload(
            remoteFileID: remoteFileID,
            attemptRevision: 1,
            declaredContentLength: Int64(bytes.count),
            authorizedBy: authorization
        ) else {
            Issue.record("Expected a body-free terminal replay")
            return
        }

        let cancelledID = UUID()
        _ = try await receiver.reserveFile(
            request(remoteFileID: cancelledID, bytes: bytes, revision: 0),
            authorizedBy: authorization
        )
        _ = try await receiver.cancelFile(
            remoteFileID: cancelledID,
            attemptRevision: 0,
            authorizedBy: authorization
        )
        #expect(try await receiver.fileStatus(
            remoteFileID: cancelledID,
            authorizedBy: authorization
        ).state == .cancelled)

        let stored = try await fixture.store.loadSnapshot()
        #expect(stored.items.count == 1)
        #expect(stored.transportReceipts.contains { receipt in
            guard receipt.transport.remoteFileID == remoteFileID,
                  receipt.attemptRevision == 1 else { return false }
            if case .published = receipt.outcome { return true }
            return false
        })
        #expect(stored.transportReceipts.contains { receipt in
            guard receipt.transport.remoteFileID == cancelledID else { return false }
            if case .cancelled = receipt.outcome { return true }
            return false
        })

        await receiver.stop()
        #expect(!(await receiver.isActive))
    }

    @Test
    func cancellationAfterDurablePublicationReportsConflictAndProjectsSaved() async throws {
        let fixture = try await LANInboxStoreTestFixture.make()
        defer { fixture.destroy() }
        let gate = FilePublicationGate()
        let receiver = LANReceiver(
            store: fixture.store,
            session: LANSession(),
            fileUploadPublishedHook: { await gate.arriveAndWaitForRelease() }
        )
        defer { Task { await receiver.stop() } }
        let (_, authorization) = try await startAndAuthorize(receiver)
        let bytes = Data("synthetic publication cancel race".utf8)
        let remoteFileID = UUID()
        _ = try await receiver.reserveFile(
            request(remoteFileID: remoteFileID, bytes: bytes, revision: 0),
            authorizedBy: authorization
        )
        let lease = try await receiveLease(
            receiver: receiver,
            remoteFileID: remoteFileID,
            revision: 0,
            byteCount: bytes.count,
            authorization: authorization
        )
        try await lease.write(buffer(bytes)).value
        let finishing = Task { try await lease.finish() }
        await gate.waitForArrival()

        await #expect(throws: LANReceiverError.conflict) {
            _ = try await receiver.cancelFile(
                remoteFileID: remoteFileID,
                attemptRevision: 0,
                authorizedBy: authorization
            )
        }
        #expect(try await receiver.fileStatus(
            remoteFileID: remoteFileID,
            authorizedBy: authorization
        ).state == .saved)
        await gate.release()
        await #expect(throws: LANReceiverError.sessionEnded) {
            _ = try await finishing.value
        }
    }

    @Test
    func concurrentReservationsCountPendingAdmissionsTowardTheSessionLimit() async throws {
        let fixture = try await LANInboxStoreTestFixture.make()
        defer { fixture.destroy() }
        let admission = AdmissionGate()
        let receiver = LANReceiver(store: GatedUploadStore(base: fixture.store, gate: admission), session: LANSession())
        defer { Task { await receiver.stop() } }
        let (credentials, authorization) = try await startAndAuthorize(receiver)
        let bytes = Data([0])
        for _ in 0..<(LANFileSessionResponse.maximumFileCount - 1) {
            _ = try await receiver.reserveFile(
                request(remoteFileID: UUID(), bytes: bytes, revision: 0),
                authorizedBy: authorization
            )
        }

        await admission.arm()
        let lastRequest = try request(remoteFileID: UUID(), bytes: bytes, revision: 0)
        let last = Task {
            try await receiver.reserveFile(lastRequest, authorizedBy: authorization)
        }
        defer { last.cancel() }
        for _ in 0..<10_000 where await admission.waitingCount == 0 {
            await Task.yield()
        }
        #expect(await admission.waitingCount == 1)

        let excessRequest = try request(remoteFileID: UUID(), bytes: bytes, revision: 0)
        let excess = Task {
            try await receiver.reserveFile(excessRequest, authorizedBy: authorization)
        }
        defer { excess.cancel() }
        // The reservation waiting on storage exposes actor reentrancy without adding a receiver
        // hook. A correct rejection never reaches storage.
        for _ in 0..<10_000 where await admission.waitingCount < 2 {
            await Task.yield()
        }
        #expect(await admission.waitingCount == 1)
        await admission.release()

        #expect(try await last.value.file.remoteFileID == lastRequest.remoteFileID)
        await #expect(throws: LANReceiverError.retryLater) {
            _ = try await excess.value
        }
        let snapshot = try await receiver.fileSessionResponse(
            restoredCredentials: credentials
        )
        #expect(snapshot.files.count == LANFileSessionResponse.maximumFileCount)
        #expect(!(try LANHTTPJSONCodec.encode(snapshot)).isEmpty)
        await receiver.stop()
    }

    private func startAndAuthorize(
        _ receiver: LANReceiver
    ) async throws -> (LANBrowserCredentials, LANAuthorizedSession) {
        let presentation = try await receiver.start(
            at: .init(
                interfaceName: "lo0",
                host: "127.0.0.1",
                networkPrefixLength: 8
            ),
            port: 0,
            allowLoopbackForTesting: true,
            pipelineInstaller: { channel, _, _, _ in
                channel.eventLoop.makeSucceededFuture(())
            }
        )
        let peer = try LANPeerKey(socketDerivedBytes: [127, 0, 0, 1])
        guard case let .paired(credentials) = await receiver.pair(
            try LANPairRequest(code: presentation.pairingCode.value),
            from: peer
        ) else {
            throw LANReceiverError.sessionEnded
        }
        guard case let .authorized(authorization) = await receiver.authenticate(
            LANSessionProof(credentials: credentials),
            from: peer,
            operation: .nonBody
        ) else {
            throw LANReceiverError.sessionEnded
        }
        return (credentials, authorization)
    }

    private func request(
        remoteFileID: UUID,
        bytes: Data,
        revision: UInt64
    ) throws -> LANReserveFileRequest {
        try LANReserveFileRequest(
            remoteFileID: remoteFileID,
            displayName: "report.bin",
            declaredByteCount: Int64(bytes.count),
            mediaType: "application/octet-stream",
            attemptRevision: revision
        )
    }

    private func receiveLease(
        receiver: LANReceiver,
        remoteFileID: UUID,
        revision: UInt64,
        byteCount: Int,
        authorization: LANAuthorizedSession
    ) async throws -> LANReceiverFileUploadLease {
        guard case let .receive(lease) = try await receiver.startFileUpload(
            remoteFileID: remoteFileID,
            attemptRevision: revision,
            declaredContentLength: Int64(byteCount),
            authorizedBy: authorization
        ) else {
            throw LANReceiverError.conflict
        }
        return lease
    }

    private func buffer(_ data: Data) -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)
        return buffer
    }
}

private actor FilePublicationGate {
    private var arrived = false
    private var released = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func arriveAndWaitForRelease() async {
        arrived = true
        let waiters = arrivalWaiters
        arrivalWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitForArrival() async {
        guard !arrived else { return }
        await withCheckedContinuation { arrivalWaiters.append($0) }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

/// Once armed, admission-generation reads wait here until released.
private actor AdmissionGate {
    private var armed = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var waitingCount: Int { waiters.count }

    func arm() { armed = true }

    func pass() async {
        guard armed else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        armed = false
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

/// The real inbox store behind a gate on the one call a reservation waits for.
private struct GatedUploadStore: LANUploadStoring {
    let base: SQLiteLANInboxStore
    let gate: AdmissionGate

    func prepare() async throws { try await base.prepare() }
    func publicationGuard() async throws -> LANInboxPublicationGuard { try await base.publicationGuard() }
    func revokePublications(guardedBy guardValue: LANInboxPublicationGuard) async throws {
        try await base.revokePublications(guardedBy: guardValue)
    }
    func itemAdmissionGeneration() async throws -> UInt64 {
        await gate.pass()
        return try await base.itemAdmissionGeneration()
    }
    func startItemUpload(transport: LANInboxTransportIdentity, metadata: LANInboxTransportMetadata,
                         attemptRevision: UInt64, admissionGeneration: UInt64?,
                         publicationGuard: LANInboxPublicationGuard?) async throws -> LANItemUploadStartOutcome {
        try await base.startItemUpload(transport: transport, metadata: metadata, attemptRevision: attemptRevision,
                                       admissionGeneration: admissionGeneration, publicationGuard: publicationGuard)
    }
    func recordItemUploadCancellation(transport: LANInboxTransportIdentity, metadata: LANInboxTransportMetadata,
                                     attemptRevision: UInt64) async throws -> LANInboxTransportReceipt {
        try await base.recordItemUploadCancellation(transport: transport, metadata: metadata, attemptRevision: attemptRevision)
    }
    func endItemSession(sessionID: UUID) async throws { try await base.endItemSession(sessionID: sessionID) }
}
