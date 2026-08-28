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
        let receiver = LANReceiver(rootURL: fixture.rootURL, session: LANSession())
        defer { Task { await receiver.stop() } }
        let (presentation, authorization) = try await startAndAuthorize(receiver)
        _ = presentation
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
            rootURL: fixture.rootURL,
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

    private func startAndAuthorize(
        _ receiver: LANReceiver
    ) async throws -> (LANReceiverPresentation, LANAuthorizedSession) {
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
        return (presentation, authorization)
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
