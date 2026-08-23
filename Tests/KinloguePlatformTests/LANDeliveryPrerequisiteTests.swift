import Darwin
import Foundation
import NIOCore
import NIOEmbedded
import Testing
@testable import KinloguePlatform

struct LANDeliveryPrerequisiteTests {
    @Test
    func oneEligibleAddressIsSelectedAutomatically() throws {
        let resolution = LANNetworkInterfaceResolver.resolve([
            .init(name: "lo0", address: "127.0.0.1", isUp: true, isRunning: true),
            .init(name: "en0", address: "192.168.1.23", isUp: true, isRunning: true),
            .init(name: "en1", address: "169.254.10.2", isUp: true, isRunning: true),
        ])

        #expect(resolution == .automatic(.init(interfaceName: "en0", host: "192.168.1.23")))
    }

    @Test
    func multipleEligibleAddressesRequireAnExplicitChoice() throws {
        let candidates: [LANNetworkInterfaceSnapshot] = [
            .init(name: "en5", address: "10.0.0.8", isUp: true, isRunning: true),
            .init(name: "en0", address: "192.168.1.23", isUp: true, isRunning: true),
        ]

        #expect(LANNetworkInterfaceResolver.resolve(candidates) == .selectionRequired([
            .init(interfaceName: "en0", host: "192.168.1.23"),
            .init(interfaceName: "en5", host: "10.0.0.8"),
        ]))
        #expect(try LANNetworkInterfaceResolver.requireExactAddress("10.0.0.8", from: candidates)
            == .init(interfaceName: "en5", host: "10.0.0.8"))
    }

    @Test
    func canonicalIPv6AddressIsEligibleAndSelectable() throws {
        let candidates: [LANNetworkInterfaceSnapshot] = [
            .init(name: "en0", address: "2001:db8::23", isUp: true, isRunning: true),
            .init(name: "en0", address: "2001:0db8::23", isUp: true, isRunning: true),
            .init(name: "en0", address: "fe80::1", isUp: true, isRunning: true),
        ]

        #expect(LANNetworkInterfaceResolver.resolve(candidates) == .automatic(
            .init(interfaceName: "en0", host: "2001:db8::23")
        ))
        #expect(try LANNetworkInterfaceResolver.requireExactAddress(
            "2001:db8::23",
            from: candidates
        ) == .init(interfaceName: "en0", host: "2001:db8::23"))
    }

    @Test(arguments: [
        "0.0.0.0",
        "127.0.0.1",
        "169.254.8.9",
        "192.168.1.0/24",
        "192.168.001.23",
        "3232235799",
        "::",
        "::1",
        "fe80::1",
        "2001:0db8::1",
        "2001:DB8::1",
        "[2001:db8::1]",
        "example.test",
    ])
    func wildcardLoopbackLinkLocalAndSubnetInputsAreRejected(_ address: String) {
        let candidates: [LANNetworkInterfaceSnapshot] = [
            .init(name: "en0", address: "192.168.1.23", isUp: true, isRunning: true),
        ]

        #expect(throws: LANNetworkInterfaceResolverError.self) {
            try LANNetworkInterfaceResolver.requireExactAddress(address, from: candidates)
        }
    }

    @Test
    func transportBindsOneNumericAddressAndRejectsConnectionsAfterStop() async throws {
        let received = LockedPayloads()
        let transport = LANServerTransport(testingByteSink: { bytes, peer in
            received.append(bytes, peer: peer)
        })
        let endpoint = try await transport.start(host: "127.0.0.1", port: 0)
        #expect(endpoint.host == "127.0.0.1")
        #expect(endpoint.port > 0)

        try send(Data("X-Forwarded-For: 203.0.113.8\r\n\r\nsynthetic".utf8), to: endpoint)
        let receiveDeadline = ContinuousClock.now + .seconds(1)
        while received.snapshot().isEmpty, ContinuousClock.now < receiveDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let item = try #require(received.snapshot().first)
        #expect(item.bytes.contains(Data("synthetic".utf8)))
        #expect(item.peer.host == "127.0.0.1")
        #expect(item.peer.host != "203.0.113.8")

        await transport.stop()
        #expect(throws: Error.self) {
            try send(Data("after-stop".utf8), to: endpoint)
        }
    }

    @Test
    func stopClosesAnAcceptedLiveChild() async throws {
        let received = LockedPayloads()
        let transport = LANServerTransport(testingByteSink: { bytes, peer in
            received.append(bytes, peer: peer)
        })
        let endpoint = try await transport.start(host: "127.0.0.1", port: 0)
        let descriptor = try connectedSocket(to: endpoint)
        defer { _ = Darwin.close(descriptor) }

        try send(Data("synthetic-live-child".utf8), through: descriptor)
        let receiveDeadline = ContinuousClock.now + .seconds(1)
        while received.snapshot().isEmpty, ContinuousClock.now < receiveDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!received.snapshot().isEmpty)

        await transport.stop()
        let closeResult = receiveOneByte(from: descriptor, timeout: 1)

        #expect(closeResult == .endOfFile || closeResult == .connectionReset)
    }

    @Test
    func childRegistrationAfterStopBeginsIsRejectedDeterministically() throws {
        let registry = LANChannelRegistry()
        let alreadyAccepted = EmbeddedChannel()
        let racingChild = EmbeddedChannel()
        defer {
            _ = try? alreadyAccepted.finish()
            _ = try? racingChild.finish()
        }

        #expect(registry.insertIfAccepting(alreadyAccepted, peerHost: "192.0.2.1"))
        let acceptedBeforeStop = registry.beginStopping()

        #expect(acceptedBeforeStop.count == 1)
        #expect(!registry.insertIfAccepting(racingChild, peerHost: "192.0.2.2"))
    }

    @Test
    func registryEnforcesGlobalAndRealPeerConnectionCaps() throws {
        let perPeerRegistry = LANChannelRegistry()
        let samePeer = (0..<5).map { _ in EmbeddedChannel() }
        defer { for channel in samePeer { _ = try? channel.finish() } }

        for channel in samePeer.prefix(4) {
            #expect(perPeerRegistry.insertIfAccepting(channel, peerHost: "198.51.100.4"))
        }
        #expect(!perPeerRegistry.insertIfAccepting(
            samePeer[4],
            peerHost: "198.51.100.4"
        ))
        perPeerRegistry.remove(samePeer[0])
        #expect(perPeerRegistry.insertIfAccepting(
            samePeer[4],
            peerHost: "198.51.100.4"
        ))
        _ = perPeerRegistry.beginStopping()

        let globalRegistry = LANChannelRegistry()
        let distinctPeers = (0..<9).map { _ in EmbeddedChannel() }
        defer { for channel in distinctPeers { _ = try? channel.finish() } }
        for (index, channel) in distinctPeers.prefix(8).enumerated() {
            #expect(globalRegistry.insertIfAccepting(
                channel,
                peerHost: "203.0.113.\(index + 1)"
            ))
        }
        #expect(!globalRegistry.insertIfAccepting(
            distinctPeers[8],
            peerHost: "203.0.113.9"
        ))
        _ = globalRegistry.beginStopping()
    }

    @Test
    func concurrentStartsCannotCreateTwoListeners() async throws {
        let gate = StartGate()
        let transport = LANServerTransport(
            testingByteSink: { _, _ in },
            startHook: { await gate.wait() }
        )
        let first = Task {
            try await transport.start(host: "127.0.0.1", port: 0)
        }
        await gate.waitUntilEntered()

        await #expect(throws: LANServerTransportError.alreadyStarted) {
            try await transport.start(host: "127.0.0.1", port: 0)
        }
        await gate.release()
        _ = try await first.value
        await transport.stop()
    }

    @Test
    func stopDuringStartCannotResurrectAListener() async throws {
        let gate = StartGate()
        let transport = LANServerTransport(
            testingByteSink: { _, _ in },
            startHook: { await gate.wait() }
        )
        let start = Task {
            try await transport.start(host: "127.0.0.1", port: 0)
        }
        await gate.waitUntilEntered()
        let stop = Task { await transport.stop() }
        await Task.yield()
        await gate.release()

        await #expect(throws: LANServerTransportError.stopped) {
            try await start.value
        }
        await stop.value
        await #expect(throws: LANServerTransportError.stopped) {
            try await transport.start(host: "127.0.0.1", port: 0)
        }
    }

    @Test(arguments: [
        "0.0.0.0",
        "127.0.0.1",
        "169.254.8.9",
        "::",
        "::1",
        "fe80::1",
        "example.test",
        "192.168.1.0/24",
        "192.168.001.23",
        "3232235799",
        "2001:0db8::1",
        "[2001:db8::1]",
    ])
    func productionTransportRejectsNonExactOrUnsafeBinding(_ host: String) async {
        let transport = LANServerTransport { _, _ in }
        await #expect(throws: LANServerTransportError.invalidHost(host)) {
            try await transport.start(host: host, port: 0)
        }
        await transport.stop()
    }

    @Test
    func endpointAuthorityBracketsIPv6AndLeavesIPv4Unbracketed() {
        #expect(LANServerEndpoint(host: "192.168.1.23", port: 8080).urlAuthority
            == "192.168.1.23:8080")
        #expect(LANServerEndpoint(host: "2001:db8::23", port: 8080).urlAuthority
            == "[2001:db8::23]:8080")
    }

    @Test
    func exactBoundAddressComparisonSupportsBothAddressFamilies() throws {
        let ipv4 = try SocketAddress(ipAddress: "192.168.1.23", port: 8080)
        let ipv6 = try SocketAddress(ipAddress: "2001:db8::23", port: 8080)

        #expect(LANServerTransport.isExactBoundAddress(
            ipv4,
            requestedHost: "192.168.1.23"
        ))
        #expect(!LANServerTransport.isExactBoundAddress(
            ipv4,
            requestedHost: "192.168.1.24"
        ))
        #expect(LANServerTransport.isExactBoundAddress(
            ipv6,
            requestedHost: "2001:db8::23"
        ))
        #expect(!LANServerTransport.isExactBoundAddress(
            ipv6,
            requestedHost: "2001:db8::24"
        ))
    }

    @Test
    func testingSeamBindsCanonicalIPv6AndReportsBracketedAuthority() async throws {
        let received = LockedPayloads()
        let transport = LANServerTransport(testingByteSink: { bytes, peer in
            received.append(bytes, peer: peer)
        })
        let endpoint = try await transport.start(host: "::1", port: 0)
        #expect(endpoint.urlAuthority == "[::1]:\(endpoint.port)")

        try send(Data("synthetic-ipv6".utf8), to: endpoint)
        let deadline = ContinuousClock.now + .seconds(1)
        while received.snapshot().isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(received.snapshot().first?.peer.host == "::1")
        await transport.stop()
    }

    @Test
    func customChildInitializerRunsOnlyAfterSocketPeerAdmission() async throws {
        let peers = LockedPeers()
        let transport = LANServerTransport(
            childChannelInitializer: { channel, peer in
                peers.append(peer)
                channel.read()
                return channel.eventLoop.makeSucceededFuture(())
            },
            allowLoopbackForTesting: true
        )
        let endpoint = try await transport.start(host: "127.0.0.1", port: 0)
        let descriptor = try connectedSocket(to: endpoint)
        defer { _ = Darwin.close(descriptor) }

        let deadline = ContinuousClock.now + .seconds(1)
        while peers.snapshot().isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(peers.snapshot().first?.host == "127.0.0.1")
        await transport.stop()
    }

    @Test
    func acceptedChannelsUseBoundedManualReadOptions() async throws {
        let observed = LockedTransportChannelOptions()
        let transport = LANServerTransport(
            childChannelInitializer: { channel, _ in
                channel.getOption(.autoRead)
                    .and(channel.getOption(.maxMessagesPerRead))
                    .and(channel.getOption(.recvAllocator))
                    .map { autoAndMessages, allocator in
                        observed.record(
                            autoRead: autoAndMessages.0,
                            maxMessagesPerRead: autoAndMessages.1,
                            receiveCapacity: (allocator as? FixedSizeRecvByteBufferAllocator)?
                                .capacity
                        )
                        channel.read()
                    }
            },
            allowLoopbackForTesting: true
        )
        let endpoint = try await transport.start(host: "127.0.0.1", port: 0)
        let descriptor = try connectedSocket(to: endpoint)
        defer { _ = Darwin.close(descriptor) }

        let deadline = ContinuousClock.now + .seconds(1)
        while observed.snapshot() == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(observed.snapshot() == .init(
            autoRead: false,
            maxMessagesPerRead: 1,
            receiveCapacity: 16 * 1_024
        ))
        await transport.stop()
    }

    private func send(_ data: Data, to endpoint: LANServerEndpoint) throws {
        let descriptor = try connectedSocket(to: endpoint)
        defer { _ = Darwin.close(descriptor) }

        try send(data, through: descriptor)
    }

    private func connectedSocket(to endpoint: LANServerEndpoint) throws -> Int32 {
        guard let parsedHost = LANIPAddress.parseCanonical(endpoint.host) else {
            throw POSIXError(.EINVAL)
        }
        let family = parsedHost.isIPv6 ? AF_INET6 : AF_INET
        let descriptor = socket(family, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }

        let connected: Int32
        switch parsedHost {
        case .v4:
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(endpoint.port).bigEndian
            guard inet_pton(AF_INET, endpoint.host, &address.sin_addr) == 1 else {
                throw POSIXError(.EINVAL)
            }
            connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        case .v6:
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = in_port_t(endpoint.port).bigEndian
            guard inet_pton(AF_INET6, endpoint.host, &address.sin6_addr) == 1 else {
                throw POSIXError(.EINVAL)
            }
            connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        }
        guard connected == 0 else {
            _ = Darwin.close(descriptor)
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        return descriptor
    }

    private func send(_ data: Data, through descriptor: Int32) throws {
        let sent = data.withUnsafeBytes { buffer in
            Darwin.send(descriptor, buffer.baseAddress, buffer.count, 0)
        }
        guard sent == data.count else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }

    private func receiveOneByte(from descriptor: Int32, timeout: Int) -> SocketCloseResult {
        var timeoutValue = timeval(tv_sec: timeout, tv_usec: 0)
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeoutValue,
            socklen_t(MemoryLayout<timeval>.size)
        )
        var byte: UInt8 = 0
        let result = Darwin.recv(descriptor, &byte, 1, 0)
        if result == 0 { return .endOfFile }
        if result < 0, errno == ECONNRESET { return .connectionReset }
        return .stillOpenOrTimedOut
    }
}

private final class LockedPeers: @unchecked Sendable {
    private let lock = NSLock()
    private var peers: [LANTransportPeer] = []

    func append(_ peer: LANTransportPeer) {
        lock.withLock { peers.append(peer) }
    }

    func snapshot() -> [LANTransportPeer] {
        lock.withLock { peers }
    }
}

private final class LockedTransportChannelOptions: @unchecked Sendable {
    struct Snapshot: Equatable, Sendable {
        let autoRead: Bool
        let maxMessagesPerRead: UInt
        let receiveCapacity: Int?
    }

    private let lock = NSLock()
    private var value: Snapshot?

    func record(
        autoRead: Bool,
        maxMessagesPerRead: UInt,
        receiveCapacity: Int?
    ) {
        lock.withLock {
            value = .init(
                autoRead: autoRead,
                maxMessagesPerRead: maxMessagesPerRead,
                receiveCapacity: receiveCapacity
            )
        }
    }

    func snapshot() -> Snapshot? {
        lock.withLock { value }
    }
}

private enum SocketCloseResult {
    case endOfFile
    case connectionReset
    case stillOpenOrTimedOut
}

private actor StartGate {
    private var entered = false
    private var released = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        guard !released else { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func waitUntilEntered() async {
        while !entered { await Task.yield() }
    }

    func release() {
        released = true
        let pending = continuations
        continuations.removeAll()
        for continuation in pending { continuation.resume() }
    }
}

private final class LockedPayloads: @unchecked Sendable {
    struct Item: Sendable {
        let bytes: Data
        let peer: LANTransportPeer
    }

    private let lock = NSLock()
    private var items: [Item] = []

    func append(_ bytes: Data, peer: LANTransportPeer) {
        lock.withLock { items.append(.init(bytes: bytes, peer: peer)) }
    }

    func snapshot() -> [Item] {
        lock.withLock { items }
    }
}
