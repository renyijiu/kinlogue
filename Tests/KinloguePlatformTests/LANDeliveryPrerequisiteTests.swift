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
            .init(
                name: "lo0",
                address: "127.0.0.1",
                networkPrefixLength: 8,
                isUp: true,
                isRunning: true
            ),
            .init(
                name: "en0",
                address: "192.168.1.23",
                networkPrefixLength: 24,
                isUp: true,
                isRunning: true
            ),
            .init(
                name: "en1",
                address: "169.254.10.2",
                networkPrefixLength: 16,
                isUp: true,
                isRunning: true
            ),
        ])

        #expect(resolution == .automatic(.init(
            interfaceName: "en0",
            host: "192.168.1.23",
            networkPrefixLength: 24
        )))
    }

    @Test
    func multipleEligibleAddressesRequireAnExplicitChoice() throws {
        let candidates: [LANNetworkInterfaceSnapshot] = [
            .init(
                name: "en5",
                address: "10.0.0.8",
                networkPrefixLength: 8,
                isUp: true,
                isRunning: true
            ),
            .init(
                name: "en0",
                address: "192.168.1.23",
                networkPrefixLength: 24,
                isUp: true,
                isRunning: true
            ),
        ]

        #expect(LANNetworkInterfaceResolver.resolve(candidates) == .selectionRequired([
            .init(interfaceName: "en0", host: "192.168.1.23", networkPrefixLength: 24),
            .init(interfaceName: "en5", host: "10.0.0.8", networkPrefixLength: 8),
        ]))
        #expect(try LANNetworkInterfaceResolver.requireExactAddress("10.0.0.8", from: candidates)
            == .init(interfaceName: "en5", host: "10.0.0.8", networkPrefixLength: 8))
        #expect(try LANNetworkInterfaceResolver.requireExactAddress(
            .init(interfaceName: "en5", host: "10.0.0.8", networkPrefixLength: 8),
            from: candidates
        ) == .init(interfaceName: "en5", host: "10.0.0.8", networkPrefixLength: 8))
        #expect(throws: LANNetworkInterfaceResolverError.self) {
            try LANNetworkInterfaceResolver.requireExactAddress(
                .init(interfaceName: "en5", host: "10.0.0.8", networkPrefixLength: 16),
                from: candidates
            )
        }
    }

    @Test
    func canonicalIPv6AddressIsEligibleAndSelectable() throws {
        let candidates: [LANNetworkInterfaceSnapshot] = [
            .init(
                name: "en0",
                address: "2001:db8::23",
                networkPrefixLength: 64,
                isUp: true,
                isRunning: true
            ),
            .init(
                name: "en0",
                address: "2001:0db8::23",
                networkPrefixLength: 64,
                isUp: true,
                isRunning: true
            ),
            .init(
                name: "en0",
                address: "fe80::1",
                networkPrefixLength: 64,
                isUp: true,
                isRunning: true
            ),
        ]

        #expect(LANNetworkInterfaceResolver.resolve(candidates) == .automatic(
            .init(interfaceName: "en0", host: "2001:db8::23", networkPrefixLength: 64)
        ))
        #expect(try LANNetworkInterfaceResolver.requireExactAddress(
            "2001:db8::23",
            from: candidates
        ) == .init(interfaceName: "en0", host: "2001:db8::23", networkPrefixLength: 64))
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
            .init(
                name: "en0",
                address: "192.168.1.23",
                networkPrefixLength: 24,
                isUp: true,
                isRunning: true
            ),
        ]

        #expect(throws: LANNetworkInterfaceResolverError.self) {
            try LANNetworkInterfaceResolver.requireExactAddress(address, from: candidates)
        }
    }

    @Test
    func addressesWithoutAValidNonzeroNetworkPrefixAreIneligible() {
        let snapshots: [LANNetworkInterfaceSnapshot] = [
            .init(
                name: "en0",
                address: "192.168.1.23",
                networkPrefixLength: nil,
                isUp: true,
                isRunning: true
            ),
            .init(
                name: "en1",
                address: "192.168.2.23",
                networkPrefixLength: 0,
                isUp: true,
                isRunning: true
            ),
            .init(
                name: "en2",
                address: "192.168.3.23",
                networkPrefixLength: 33,
                isUp: true,
                isRunning: true
            ),
        ]

        #expect(LANNetworkInterfaceResolver.resolve(snapshots) == .unavailable)
    }

    @Test
    func interfaceNetmasksRequireContiguousIPv4AndIPv6Bits() throws {
        #expect(try #require(
            LANIPAddress.parseCanonical("255.255.255.0")
        ).contiguousNetworkPrefixLength == 24)
        #expect(try #require(
            LANIPAddress.parseCanonical("255.255.255.254")
        ).contiguousNetworkPrefixLength == 31)
        #expect(try #require(
            LANIPAddress.parseCanonical("255.0.255.0")
        ).contiguousNetworkPrefixLength == nil)
        #expect(try #require(
            LANIPAddress.parseCanonical("ffff:ffff:ffff:ffff::")
        ).contiguousNetworkPrefixLength == 64)
        #expect(try #require(
            LANIPAddress.parseCanonical("ffff:fffe:ffff::")
        ).contiguousNetworkPrefixLength == nil)
    }

    @Test
    func peerAdmissionRequiresTheSelectedIPv4OrIPv6Prefix() {
        let ipv4 = LANNetworkAddress(
            interfaceName: "en0",
            host: "192.168.7.42",
            networkPrefixLength: 24
        )
        #expect(LANServerTransport.isPeerHost("192.168.7.1", on: ipv4))
        #expect(LANServerTransport.isPeerHost("192.168.7.255", on: ipv4))
        #expect(!LANServerTransport.isPeerHost("192.168.8.1", on: ipv4))

        let ipv6 = LANNetworkAddress(
            interfaceName: "en0",
            host: "2001:db8:4:5::42",
            networkPrefixLength: 64
        )
        #expect(LANServerTransport.isPeerHost("2001:db8:4:5::1", on: ipv6))
        #expect(!LANServerTransport.isPeerHost("2001:db8:4:6::1", on: ipv6))
        #expect(!LANServerTransport.isPeerHost("::ffff:192.168.7.1", on: ipv4))
        #expect(!LANServerTransport.isPeerHost("not-an-address", on: ipv4))
    }

    @Test
    func peerAdmissionHandlesMaximumAndOneBitPrefixes() {
        let exactIPv4 = LANNetworkAddress(
            interfaceName: "en0",
            host: "192.0.2.9",
            networkPrefixLength: 32
        )
        #expect(LANServerTransport.isPeerHost("192.0.2.9", on: exactIPv4))
        #expect(!LANServerTransport.isPeerHost("192.0.2.8", on: exactIPv4))

        let firstIPv6Bit = LANNetworkAddress(
            interfaceName: "en0",
            host: "2001:db8::1",
            networkPrefixLength: 1
        )
        #expect(LANServerTransport.isPeerHost("7fff::1", on: firstIPv6Bit))
        #expect(!LANServerTransport.isPeerHost("8000::1", on: firstIPv6Bit))

        let exactIPv6 = LANNetworkAddress(
            interfaceName: "en0",
            host: "2001:db8::1",
            networkPrefixLength: 128
        )
        #expect(LANServerTransport.isPeerHost("2001:db8::1", on: exactIPv6))
        #expect(!LANServerTransport.isPeerHost("2001:db8::2", on: exactIPv6))
    }

    @Test
    func transportBindsOneNumericAddressAndRejectsConnectionsAfterStop() async throws {
        let received = LockedPayloads()
        let transport = LANServerTransport(testingByteSink: { bytes, peer in
            received.append(bytes, peer: peer)
        })
        let endpoint = try await transport.start(
            at: .init(interfaceName: "lo0", host: "127.0.0.1", networkPrefixLength: 8),
            port: 0
        )
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
        let endpoint = try await transport.start(
            at: .init(interfaceName: "lo0", host: "127.0.0.1", networkPrefixLength: 8),
            port: 0
        )
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
            try await transport.start(
                at: .init(
                    interfaceName: "lo0",
                    host: "127.0.0.1",
                    networkPrefixLength: 8
                ),
                port: 0
            )
        }
        await gate.waitUntilEntered()

        await #expect(throws: LANServerTransportError.alreadyStarted) {
            try await transport.start(
                at: .init(
                    interfaceName: "lo0",
                    host: "127.0.0.1",
                    networkPrefixLength: 8
                ),
                port: 0
            )
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
            try await transport.start(
                at: .init(
                    interfaceName: "lo0",
                    host: "127.0.0.1",
                    networkPrefixLength: 8
                ),
                port: 0
            )
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
            try await transport.start(
                at: .init(
                    interfaceName: "lo0",
                    host: "127.0.0.1",
                    networkPrefixLength: 8
                ),
                port: 0
            )
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
            try await transport.start(
                at: .init(interfaceName: "synthetic", host: host, networkPrefixLength: 24),
                port: 0
            )
        }
        await transport.stop()
    }

    @Test
    func productionTransportRejectsOutOfRangeNetworkPrefixes() async {
        let transport = LANServerTransport { _, _ in }
        await #expect(throws: LANServerTransportError.invalidNetworkPrefix(0)) {
            try await transport.start(
                at: .init(
                    interfaceName: "en0",
                    host: "192.0.2.1",
                    networkPrefixLength: 0
                ),
                port: 0
            )
        }
        await #expect(throws: LANServerTransportError.invalidNetworkPrefix(129)) {
            try await transport.start(
                at: .init(
                    interfaceName: "en0",
                    host: "2001:db8::1",
                    networkPrefixLength: 129
                ),
                port: 0
            )
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
        let endpoint = try await transport.start(
            at: .init(interfaceName: "lo0", host: "::1", networkPrefixLength: 128),
            port: 0
        )
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
        let endpoint = try await transport.start(
            at: .init(interfaceName: "lo0", host: "127.0.0.1", networkPrefixLength: 8),
            port: 0
        )
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
    func offPrefixAndMissingPeersCloseBeforeTheChildInitializerRuns() throws {
        let listeningAddress = LANNetworkAddress(
            interfaceName: "en0",
            host: "192.168.7.42",
            networkPrefixLength: 24
        )
        let registry = LANChannelRegistry()
        let peers = LockedPeers()
        let initializer: LANServerTransport.ChildChannelInitializer = { channel, peer in
            peers.append(peer)
            return channel.eventLoop.makeSucceededFuture(())
        }
        let offPrefix = EmbeddedChannel()
        let missingPeer = EmbeddedChannel()
        defer {
            _ = try? offPrefix.finish()
            _ = try? missingPeer.finish()
        }

        try LANServerTransport.initializeAcceptedChannel(
            offPrefix,
            peer: .init(host: "192.168.8.1", port: 52_000),
            listeningAddress: listeningAddress,
            registry: registry,
            childChannelInitializer: initializer,
            allowingLoopback: false
        ).wait()
        try LANServerTransport.initializeAcceptedChannel(
            missingPeer,
            peer: nil,
            listeningAddress: listeningAddress,
            registry: registry,
            childChannelInitializer: initializer,
            allowingLoopback: false
        ).wait()

        #expect(peers.snapshot().isEmpty)
        #expect(!offPrefix.isActive)
        #expect(!missingPeer.isActive)
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
        let endpoint = try await transport.start(
            at: .init(interfaceName: "lo0", host: "127.0.0.1", networkPrefixLength: 8),
            port: 0
        )
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
