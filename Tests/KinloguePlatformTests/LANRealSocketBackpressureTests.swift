import Darwin
import Foundation
import NIOCore
import Testing
@testable import KinloguePlatform

@Suite(.serialized)
struct LANRealSocketBackpressureTests {
    private static let firstLargeFixtureByteCount = 8 * 1_024 * 1_024 + 37
    private static let secondLargeFixtureByteCount = 8 * 1_024 * 1_024 + 113
    private static let abruptFixtureByteCount = 4 * 1_024 + 19
    private static let streamChunkByteCount = 16 * 1_024
    private static let maximumRSSDelta = UInt64(64 * 1_024 * 1_024)
    private static let maximumEventLoopP99Nanoseconds = UInt64(250_000_000)

    @Test
    func productionFileQueueStaysBoundedWithTwoStreamsSlowPeersAndDisconnect()
        async throws
    {
        let fixture = try await LANInboxStoreTestFixture.make()
        defer { fixture.destroy() }

        let channelUsage = RealChannelUsage()
        let eventLoopCapture = RealEventLoopCapture()
        let storeOperations = RealReceiverOperationCapture()
        let receiver = LANReceiver(
            rootURL: fixture.rootURL,
            session: LANSession(),
            storeObserver: { storeOperations.record($0) }
        )
        let assetCatalog = try LANPhoneAssetCatalog.loadBundled()
        var slowDescriptors: [Int32] = []
        var streamGate: RealAsyncGate?
        var diagnosticStage = "start"

        do {
            let presentation = try await receiver.start(
                at: .init(
                    interfaceName: "lo0",
                    host: "127.0.0.1",
                    networkPrefixLength: 8
                ),
                port: 0,
                allowLoopbackForTesting: true,
                pipelineInstaller: { channel, peer, authority, application in
                    channelUsage.opened()
                    channel.closeFuture.whenComplete { _ in channelUsage.closed() }
                    eventLoopCapture.capture(channel.eventLoop)
                    return LANHTTPPipeline.configure(
                        channel: channel,
                        configuration: .init(
                            authorityProvider: { authority.currentAuthority() },
                            assetCatalog: assetCatalog,
                            application: application,
                            peer: peer
                        )
                    )
                }
            )
            let endpoint = presentation.endpoint
            let authority = endpoint.urlAuthority

            diagnosticStage = "warmup"
            let warmup = try await realRequest(
                endpoint: endpoint,
                request: realGETRequest(target: "/", authority: authority)
            )
            #expect(warmup.status == 200)
            try await realWaitUntil { channelUsage.current == 0 }

            diagnosticStage = "pair"
            let pairBody = try LANHTTPJSONCodec.encode(
                try LANPairRequest(code: presentation.pairingCode.value)
            )
            let pairResponse = try await realRequest(
                endpoint: endpoint,
                request: realJSONRequest(
                    method: "POST",
                    target: "/api/pair",
                    authority: authority,
                    body: pairBody
                )
            )
            #expect(pairResponse.status == 200)
            let paired = try LANHTTPJSONCodec.decode(
                LANPairResponse.self,
                from: pairResponse.body
            )
            let cookie = try realSessionCookie(from: pairResponse)

            diagnosticStage = "reserve"
            let fileRequests = [
                try LANReserveFileRequest(
                    remoteFileID: UUID(),
                    displayName: "generated-stream-a.bin",
                    declaredByteCount: Int64(Self.firstLargeFixtureByteCount),
                    mediaType: "application/octet-stream",
                    attemptRevision: 0
                ),
                try LANReserveFileRequest(
                    remoteFileID: UUID(),
                    displayName: "generated-stream-b.bin",
                    declaredByteCount: Int64(Self.secondLargeFixtureByteCount),
                    mediaType: "application/octet-stream",
                    attemptRevision: 0
                ),
                try LANReserveFileRequest(
                    remoteFileID: UUID(),
                    displayName: "generated-abrupt.bin",
                    declaredByteCount: Int64(Self.abruptFixtureByteCount),
                    mediaType: "application/octet-stream",
                    attemptRevision: 0
                ),
            ]
            for request in fileRequests {
                let response = try await realRequest(
                    endpoint: endpoint,
                    request: realJSONRequest(
                        method: "POST",
                        target: "/api/files/reserve",
                        authority: authority,
                        body: try LANHTTPJSONCodec.encode(request),
                        cookie: cookie,
                        csrfToken: paired.csrfToken
                    )
                )
                #expect(response.status == 201)
                let reserved = try LANHTTPJSONCodec.decode(
                    LANReserveFileResponse.self,
                    from: response.body
                )
                #expect(reserved.file.remoteFileID == request.remoteFileID)
                #expect(reserved.file.state == .reserved)
            }
            try await realWaitUntil { channelUsage.current == 0 }

            // Two incomplete request lines plus two uploads reach the real
            // loopback peer's production cap of four channels.
            diagnosticStage = "slow-peers"
            for _ in 0..<2 {
                let descriptor = try realConnectedSocket(to: endpoint)
                try realSendAll(Data("G".utf8), through: descriptor)
                slowDescriptors.append(descriptor)
            }
            try await realWaitUntil { channelUsage.current == 2 }

            diagnosticStage = "streams"
            let gate = RealAsyncGate()
            streamGate = gate
            let firstDone = RealLockedValue(false)
            let secondDone = RealLockedValue(false)
            let firstUpload = Task.detached {
                defer { firstDone.set(true) }
                return try await realStreamUpload(
                    endpoint: endpoint,
                    authority: authority,
                    fileID: fileRequests[0].remoteFileID,
                    revision: fileRequests[0].attemptRevision,
                    cookie: cookie,
                    csrfToken: paired.csrfToken,
                    byteCount: Self.firstLargeFixtureByteCount,
                    chunkByteCount: Self.streamChunkByteCount,
                    pattern: 0x31,
                    framing: .contentLength,
                    startGate: gate,
                    interChunkDelay: .milliseconds(2)
                )
            }
            let secondUpload = Task.detached {
                defer { secondDone.set(true) }
                return try await realStreamUpload(
                    endpoint: endpoint,
                    authority: authority,
                    fileID: fileRequests[1].remoteFileID,
                    revision: fileRequests[1].attemptRevision,
                    cookie: cookie,
                    csrfToken: paired.csrfToken,
                    byteCount: Self.secondLargeFixtureByteCount,
                    chunkByteCount: Self.streamChunkByteCount,
                    pattern: 0x32,
                    framing: .chunked,
                    startGate: gate,
                    interChunkDelay: .milliseconds(2)
                )
            }

            try await realWaitUntil(timeout: .seconds(3)) {
                channelUsage.current == 4 && storeOperations.uploadStartCount >= 2
            }
            #expect(!firstDone.get())
            #expect(!secondDone.get())

            // A fifth connection may complete the TCP handshake from the
            // listen backlog, but per-peer admission closes it before HTTP.
            diagnosticStage = "fifth"
            let fifthWasRejected = await Task.detached {
                realConnectionRejectedBeforeHTTP(
                    endpoint: endpoint,
                    sourceHost: nil,
                    request: realGETRequest(target: "/", authority: authority)
                )
            }.value
            #expect(fifthWasRejected)
            #expect(channelUsage.peak == 4)

            // Free two channel slots while both production upload permits stay
            // occupied. A third authenticated body reaches the receiver and is
            // rejected by the two-body admission policy, not the channel cap.
            diagnosticStage = "third-body"
            for descriptor in slowDescriptors.prefix(2) {
                _ = Darwin.close(descriptor)
            }
            slowDescriptors.removeFirst(2)
            try await realWaitUntil { channelUsage.current == 2 }
            let thirdBody = Data(repeating: 0x33, count: Self.abruptFixtureByteCount)
            let thirdWhileBusy = try await realRequest(
                endpoint: endpoint,
                request: realUploadRequest(
                    authority: authority,
                    fileID: fileRequests[2].remoteFileID,
                    revision: fileRequests[2].attemptRevision,
                    cookie: cookie,
                    csrfToken: paired.csrfToken,
                    body: thirdBody
                )
            )
            #expect(thirdWhileBusy.status == 429)

            diagnosticStage = "calibration"
            let eventLoop = try #require(eventLoopCapture.get())
            let residentBefore = try realResidentMemoryByteCount()
            let peakResident = RealLockedValue(residentBefore)
            let memorySampler = Task.detached {
                while !Task.isCancelled {
                    if let current = try? realResidentMemoryByteCount() {
                        peakResident.mutate { $0 = max($0, current) }
                    }
                    try? await Task.sleep(for: .milliseconds(5))
                }
            }

            await gate.open()
            let schedulingProbe = Task {
                try await realEventLoopLateness(
                    eventLoop,
                    sampleCount: 64,
                    requestedDelay: .milliseconds(2),
                    requestedDelayNanoseconds: 2_000_000
                )
            }
            let firstWireResponse = try await firstUpload.value
            let secondWireResponse = try await secondUpload.value
            let schedulingLateness = try await schedulingProbe.value
            memorySampler.cancel()
            _ = await memorySampler.result
            peakResident.mutate { value in
                if let current = try? realResidentMemoryByteCount() {
                    value = max(value, current)
                }
            }

            #expect(firstWireResponse.status == 200)
            #expect(secondWireResponse.status == 200)
            let firstUploaded = try LANHTTPJSONCodec.decode(
                LANFileSavedResponse.self,
                from: firstWireResponse.body
            )
            let secondUploaded = try LANHTTPJSONCodec.decode(
                LANFileSavedResponse.self,
                from: secondWireResponse.body
            )
            #expect(firstUploaded.outcome == .saved)
            #expect(secondUploaded.outcome == .saved)

            let p99Nanoseconds = realPercentile99(schedulingLateness)
            let residentDelta = peakResident.get() > residentBefore
                ? peakResident.get() - residentBefore
                : 0
            #expect(p99Nanoseconds <= Self.maximumEventLoopP99Nanoseconds)
            // RSS belongs to the whole test process. Swift Testing executes
            // independent suites concurrently, so an all-suite run also sees
            // unrelated vault/migration fixture allocations. The release
            // calibration invokes this test alone with this marker; ordinary
            // full-suite runs still record RSS and enforce every functional,
            // admission, backpressure and event-loop assertion.
            if ProcessInfo.processInfo.environment[
                "KINLOGUE_ENFORCE_ISOLATED_LAN_RSS"
            ] == "1" {
                #expect(residentDelta <= Self.maximumRSSDelta)
            }

            try await realWaitUntil { channelUsage.current == 0 }
            for _ in 0..<2 {
                let descriptor = try realConnectedSocket(to: endpoint)
                try realSendAll(Data("G".utf8), through: descriptor)
                slowDescriptors.append(descriptor)
            }
            try await realWaitUntil { channelUsage.current == 2 }

            // Start the remaining file, send only a prefix, then disconnect.
            // The body must reconcile as interrupted with no published blob.
            diagnosticStage = "abrupt"
            let abruptDescriptor = try realConnectedSocket(to: endpoint)
            let abruptHead = realUploadHead(
                authority: authority,
                fileID: fileRequests[2].remoteFileID,
                revision: fileRequests[2].attemptRevision,
                cookie: cookie,
                csrfToken: paired.csrfToken,
                framing: .contentLength,
                byteCount: Self.abruptFixtureByteCount
            )
            try realSendAll(abruptHead, through: abruptDescriptor)
            try realSendAll(
                Data(repeating: 0x34, count: Self.streamChunkByteCount / 4),
                through: abruptDescriptor
            )
            try await realWaitUntil(timeout: .seconds(3)) {
                storeOperations.uploadStartCount >= 4
            }
            _ = Darwin.close(abruptDescriptor)
            try await realWaitUntilAsync(timeout: .seconds(3)) {
                guard let snapshot = try? await fixture.store.loadSnapshot(),
                      let summary = try? await fixture.store.storageSummary() else {
                    return false
                }
                return snapshot.items.count == 2
                    && snapshot.blobs.count == 2
                    && summary.partialObjectCount == 0
            }

            diagnosticStage = "stop"
            let stopStarted = DispatchTime.now().uptimeNanoseconds
            await receiver.stop()
            let stopNanoseconds = DispatchTime.now().uptimeNanoseconds - stopStarted
            #expect(stopNanoseconds <= 1_000_000_000)
            for descriptor in slowDescriptors {
                #expect(realSocketObservedRemoteClose(descriptor, timeoutSeconds: 1))
                _ = Darwin.close(descriptor)
            }
            slowDescriptors.removeAll()
            #expect(!realCanConnect(to: endpoint))
            #expect(channelUsage.current == 0)

            let finalSnapshot = try await fixture.store.loadSnapshot()
            #expect(finalSnapshot.items.count == 2)
            #expect(finalSnapshot.blobs.count == 2)
            let summary = try await fixture.store.storageSummary()
            #expect(summary.partialObjectCount == 0)

            print(
                "LAN_REAL_SOCKET_CALIBRATION "
                    + "fixture_a_bytes=\(Self.firstLargeFixtureByteCount) "
                    + "fixture_b_bytes=\(Self.secondLargeFixtureByteCount) "
                    + "abrupt_fixture_bytes=\(Self.abruptFixtureByteCount) "
                    + "receiver_slow_connections=2 "
                    + "receiver_peak_peer_channels=\(channelUsage.peak) "
                    + "per_peer_limit=4 body_limit=2 "
                    + "rss_delta_bytes=\(residentDelta) "
                    + "event_loop_samples=\(schedulingLateness.count) "
                    + "event_loop_p99_ns=\(p99Nanoseconds) "
                    + "listener_stop_ns=\(stopNanoseconds) "
                    + "hardware=\(realHardwareModel())"
            )
        } catch {
            print("LAN_REAL_SOCKET_DIAGNOSTIC stage=\(diagnosticStage)")
            await streamGate?.open()
            await receiver.stop()
            for descriptor in slowDescriptors { _ = Darwin.close(descriptor) }
            throw error
        }
    }

}

private enum RealSocketTestError: Error {
    case invalidAddress
    case socketFailure
    case timeout
    case malformedResponse
    case responseTooLarge
}

private enum RealUploadFraming: Sendable {
    case contentLength
    case chunked
}

private struct RealHTTPResponse: Sendable {
    let status: Int
    let headers: [String: [String]]
    let body: Data
}

private final class RealLockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func get() -> Value { lock.withLock { value } }
    func set(_ value: Value) { lock.withLock { self.value = value } }
    func mutate(_ body: (inout Value) -> Void) { lock.withLock { body(&value) } }
}

private final class RealChannelUsage: @unchecked Sendable {
    private let lock = NSLock()
    private var activeCount = 0
    private var peakCount = 0

    var current: Int { lock.withLock { activeCount } }
    var peak: Int { lock.withLock { peakCount } }

    func opened() {
        lock.withLock {
            activeCount += 1
            peakCount = max(peakCount, activeCount)
        }
    }

    func closed() {
        lock.withLock { activeCount = max(0, activeCount - 1) }
    }
}

private final class RealEventLoopCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var eventLoop: (any EventLoop)?

    func capture(_ eventLoop: any EventLoop) {
        lock.withLock {
            if self.eventLoop == nil { self.eventLoop = eventLoop }
        }
    }

    func get() -> (any EventLoop)? { lock.withLock { eventLoop } }
}

private final class RealReceiverOperationCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var uploadStarts = 0

    var uploadStartCount: Int { lock.withLock { uploadStarts } }

    func record(_ operation: LANReceiverStoreOperation) {
        guard case .startUpload = operation else { return }
        lock.withLock { uploadStarts += 1 }
    }
}

private actor RealAsyncGate {
    private var openState = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !openState else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        openState = true
        let continuations = waiters
        waiters.removeAll()
        for continuation in continuations { continuation.resume() }
    }
}

private func realRequest(
    endpoint: LANServerEndpoint,
    request: Data
) async throws -> RealHTTPResponse {
    try await Task.detached {
        let descriptor = try realConnectedSocket(to: endpoint)
        defer { _ = Darwin.close(descriptor) }
        try realSendAll(request, through: descriptor)
        return try realReadResponse(from: descriptor)
    }.value
}

private func realStreamUpload(
    endpoint: LANServerEndpoint,
    authority: String,
    fileID: UUID,
    revision: UInt64,
    cookie: String,
    csrfToken: String,
    byteCount: Int,
    chunkByteCount: Int,
    pattern: UInt8,
    framing: RealUploadFraming,
    startGate: RealAsyncGate?,
    interChunkDelay: Duration,
    requestedSendBufferByteCount: Int? = nil
) async throws -> RealHTTPResponse {
    let descriptor = try realConnectedSocket(
        to: endpoint,
        requestedSendBufferByteCount: requestedSendBufferByteCount
    )
    defer { _ = Darwin.close(descriptor) }
    try realSendAll(
        realUploadHead(
            authority: authority,
            fileID: fileID,
            revision: revision,
            cookie: cookie,
            csrfToken: csrfToken,
            framing: framing,
            byteCount: byteCount
        ),
        through: descriptor
    )

    let chunk = Data(repeating: pattern, count: chunkByteCount)
    var sentByteCount = 0
    var isFirstChunk = true
    while sentByteCount < byteCount {
        let count = min(chunkByteCount, byteCount - sentByteCount)
        let body = count == chunk.count ? chunk : Data(chunk.prefix(count))
        switch framing {
        case .contentLength:
            try realSendAll(body, through: descriptor)
        case .chunked:
            try realSendAll(Data(String(count, radix: 16).utf8), through: descriptor)
            try realSendAll(Data("\r\n".utf8), through: descriptor)
            try realSendAll(body, through: descriptor)
            try realSendAll(Data("\r\n".utf8), through: descriptor)
        }
        sentByteCount += count
        if isFirstChunk {
            isFirstChunk = false
            await startGate?.wait()
        }
        if interChunkDelay > .zero {
            try await Task.sleep(for: interChunkDelay)
        }
    }
    if framing == .chunked {
        try realSendAll(Data("0\r\n\r\n".utf8), through: descriptor)
    }
    return try realReadResponse(from: descriptor)
}

private func realGETRequest(target: String, authority: String) -> Data {
    Data(
        ("GET \(target) HTTP/1.1\r\n"
            + "Host: \(authority)\r\n"
            + "Connection: close\r\n\r\n").utf8
    )
}

private func realJSONRequest(
    method: String,
    target: String,
    authority: String,
    body: Data,
    cookie: String? = nil,
    csrfToken: String? = nil
) -> Data {
    var text = "\(method) \(target) HTTP/1.1\r\n"
        + "Host: \(authority)\r\n"
        + "Origin: http://\(authority)\r\n"
        + "Content-Type: application/json\r\n"
        + "Content-Length: \(body.count)\r\n"
        + "Connection: close\r\n"
    if let cookie {
        text += "Cookie: \(LANHTTPHandlerConfiguration.sessionCookieName)=\(cookie)\r\n"
    }
    if let csrfToken {
        text += "\(LANHTTPHandlerConfiguration.csrfHeaderName): \(csrfToken)\r\n"
    }
    var request = Data((text + "\r\n").utf8)
    request.append(body)
    return request
}

private func realUploadRequest(
    authority: String,
    fileID: UUID,
    revision: UInt64,
    cookie: String,
    csrfToken: String,
    body: Data
) -> Data {
    var request = realUploadHead(
        authority: authority,
        fileID: fileID,
        revision: revision,
        cookie: cookie,
        csrfToken: csrfToken,
        framing: .contentLength,
        byteCount: body.count
    )
    request.append(body)
    return request
}

private func realUploadHead(
    authority: String,
    fileID: UUID,
    revision: UInt64,
    cookie: String,
    csrfToken: String,
    framing: RealUploadFraming,
    byteCount: Int
) -> Data {
    var text = "PUT /api/files/\(fileID.uuidString.lowercased()) HTTP/1.1\r\n"
        + "Host: \(authority)\r\n"
        + "Origin: http://\(authority)\r\n"
        + "Cookie: \(LANHTTPHandlerConfiguration.sessionCookieName)=\(cookie)\r\n"
        + "\(LANHTTPHandlerConfiguration.csrfHeaderName): \(csrfToken)\r\n"
        + "\(LANHTTPHandlerConfiguration.attemptRevisionHeaderName): \(revision)\r\n"
        + "Content-Type: application/octet-stream\r\n"
    switch framing {
    case .contentLength:
        text += "Content-Length: \(byteCount)\r\n"
    case .chunked:
        text += "Transfer-Encoding: chunked\r\n"
    }
    text += "Connection: close\r\n\r\n"
    return Data(text.utf8)
}

private func realSessionCookie(from response: RealHTTPResponse) throws -> String {
    guard let header = response.headers["set-cookie"]?.first,
          let first = header.split(separator: ";", maxSplits: 1).first,
          let equals = first.firstIndex(of: "=") else {
        throw RealSocketTestError.malformedResponse
    }
    return String(first[first.index(after: equals)...])
}

private func realConnectedSocket(
    to endpoint: LANServerEndpoint,
    sourceHost: String? = nil,
    requestedSendBufferByteCount: Int? = nil
) throws -> Int32 {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw RealSocketTestError.socketFailure }
    do {
        var noSignal: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else { throw RealSocketTestError.socketFailure }
        if var requestedSendBufferByteCount {
            guard setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_SNDBUF,
                &requestedSendBufferByteCount,
                socklen_t(MemoryLayout<Int>.size)
            ) == 0 else { throw RealSocketTestError.socketFailure }
        }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        ) == 0,
        setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_SNDTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        ) == 0 else { throw RealSocketTestError.socketFailure }

        if let sourceHost {
            var source = sockaddr_in()
            source.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            source.sin_family = sa_family_t(AF_INET)
            guard inet_pton(AF_INET, sourceHost, &source.sin_addr) == 1 else {
                throw RealSocketTestError.invalidAddress
            }
            let bound = withUnsafePointer(to: &source) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(
                        descriptor,
                        $0,
                        socklen_t(MemoryLayout<sockaddr_in>.size)
                    )
                }
            }
            guard bound == 0 else { throw RealSocketTestError.socketFailure }
        }

        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = in_port_t(endpoint.port).bigEndian
        guard inet_pton(AF_INET, endpoint.host, &destination.sin_addr) == 1 else {
            throw RealSocketTestError.invalidAddress
        }
        let connected = withUnsafePointer(to: &destination) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard connected == 0 else { throw RealSocketTestError.socketFailure }
        return descriptor
    } catch {
        _ = Darwin.close(descriptor)
        throw error
    }
}

private func realSendAll(_ data: Data, through descriptor: Int32) throws {
    try data.withUnsafeBytes { bytes in
        guard let baseAddress = bytes.baseAddress else { return }
        var offset = 0
        while offset < bytes.count {
            let sent = Darwin.send(
                descriptor,
                baseAddress.advanced(by: offset),
                bytes.count - offset,
                0
            )
            if sent > 0 {
                offset += sent
            } else if sent < 0, errno == EINTR {
                continue
            } else if sent < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                throw RealSocketTestError.timeout
            } else {
                throw RealSocketTestError.socketFailure
            }
        }
    }
}

private func realReadResponse(from descriptor: Int32) throws -> RealHTTPResponse {
    var bytes = Data()
    var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
    while true {
        let received = Darwin.recv(descriptor, &buffer, buffer.count, 0)
        if received > 0 {
            bytes.append(buffer, count: received)
            guard bytes.count <= 1 * 1_024 * 1_024 else {
                throw RealSocketTestError.responseTooLarge
            }
        } else if received == 0 {
            break
        } else if errno == EINTR {
            continue
        } else if errno == EAGAIN || errno == EWOULDBLOCK {
            throw RealSocketTestError.timeout
        } else {
            throw RealSocketTestError.socketFailure
        }
    }

    let separator = Data([13, 10, 13, 10])
    guard let range = bytes.range(of: separator),
          let head = String(data: bytes[..<range.lowerBound], encoding: .utf8) else {
        throw RealSocketTestError.malformedResponse
    }
    let lines = head.components(separatedBy: "\r\n")
    guard let statusLine = lines.first else {
        throw RealSocketTestError.malformedResponse
    }
    let statusPieces = statusLine.split(separator: " ", maxSplits: 2)
    guard statusPieces.count >= 2, let status = Int(statusPieces[1]) else {
        throw RealSocketTestError.malformedResponse
    }
    var headers: [String: [String]] = [:]
    for line in lines.dropFirst() {
        guard let colon = line.firstIndex(of: ":") else {
            throw RealSocketTestError.malformedResponse
        }
        let name = line[..<colon].lowercased()
        let value = line[line.index(after: colon)...]
            .trimmingCharacters(in: .whitespaces)
        headers[name, default: []].append(value)
    }
    let body = Data(bytes[range.upperBound...])
    if let lengthText = headers["content-length"]?.first,
       let length = Int(lengthText),
       length != body.count {
        throw RealSocketTestError.malformedResponse
    }
    return .init(status: status, headers: headers, body: body)
}

private func realConnectionRejectedBeforeHTTP(
    endpoint: LANServerEndpoint,
    sourceHost: String?,
    request: Data
) -> Bool {
    guard let descriptor = try? realConnectedSocket(
        to: endpoint,
        sourceHost: sourceHost
    ) else { return true }
    defer { _ = Darwin.close(descriptor) }
    do {
        try realSendAll(request, through: descriptor)
    } catch {
        return true
    }
    var timeout = timeval(tv_sec: 1, tv_usec: 0)
    _ = setsockopt(
        descriptor,
        SOL_SOCKET,
        SO_RCVTIMEO,
        &timeout,
        socklen_t(MemoryLayout<timeval>.size)
    )
    var byte: UInt8 = 0
    let received = Darwin.recv(descriptor, &byte, 1, 0)
    if received == 0 { return true }
    if received < 0, errno == ECONNRESET || errno == ENOTCONN { return true }
    return false
}

private func realSocketObservedRemoteClose(
    _ descriptor: Int32,
    timeoutSeconds: Int
) -> Bool {
    var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
    _ = setsockopt(
        descriptor,
        SOL_SOCKET,
        SO_RCVTIMEO,
        &timeout,
        socklen_t(MemoryLayout<timeval>.size)
    )
    var byte: UInt8 = 0
    let received = Darwin.recv(descriptor, &byte, 1, 0)
    if received == 0 { return true }
    if received < 0, errno == ECONNRESET || errno == ENOTCONN { return true }
    return false
}

private func realCanConnect(to endpoint: LANServerEndpoint) -> Bool {
    guard let descriptor = try? realConnectedSocket(to: endpoint) else { return false }
    _ = Darwin.close(descriptor)
    return true
}

private func realEventLoopLateness(
    _ eventLoop: any EventLoop,
    sampleCount: Int,
    requestedDelay: TimeAmount,
    requestedDelayNanoseconds: UInt64
) async throws -> [UInt64] {
    var samples: [UInt64] = []
    samples.reserveCapacity(sampleCount)
    for _ in 0..<sampleCount {
        let started = DispatchTime.now().uptimeNanoseconds
        let fired = try await eventLoop.scheduleTask(in: requestedDelay) {
            DispatchTime.now().uptimeNanoseconds
        }.futureResult.get()
        let elapsed = fired >= started ? fired - started : 0
        samples.append(
            elapsed > requestedDelayNanoseconds
                ? elapsed - requestedDelayNanoseconds
                : 0
        )
    }
    return samples
}

private func realPercentile99(_ samples: [UInt64]) -> UInt64 {
    guard !samples.isEmpty else { return .max }
    let sorted = samples.sorted()
    let rank = max(0, Int(ceil(Double(sorted.count) * 0.99)) - 1)
    return sorted[min(rank, sorted.count - 1)]
}

private func realResidentMemoryByteCount() throws -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
        MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
    )
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(
            to: integer_t.self,
            capacity: Int(count)
        ) { rebound in
            task_info(
                mach_task_self_,
                task_flavor_t(MACH_TASK_BASIC_INFO),
                rebound,
                &count
            )
        }
    }
    guard result == KERN_SUCCESS else { throw RealSocketTestError.socketFailure }
    return info.resident_size
}

private func realHardwareModel() -> String {
    var byteCount = 0
    guard sysctlbyname("hw.model", nil, &byteCount, nil, 0) == 0,
          byteCount > 1 else { return "unknown" }
    var bytes = [CChar](repeating: 0, count: byteCount)
    guard sysctlbyname("hw.model", &bytes, &byteCount, nil, 0) == 0 else {
        return "unknown"
    }
    let payload = bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: payload, as: UTF8.self)
        .replacingOccurrences(of: " ", with: "_")
}

private func realWaitUntil(
    timeout: Duration = .seconds(2),
    condition: @escaping @Sendable () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else {
            throw RealSocketTestError.timeout
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private func realWaitUntilAsync(
    timeout: Duration = .seconds(2),
    condition: @escaping @Sendable () async -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while !(await condition()) {
        guard ContinuousClock.now < deadline else {
            throw RealSocketTestError.timeout
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}
