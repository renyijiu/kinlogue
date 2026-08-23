import Darwin
import Foundation
import NIOCore
import NIOPosix

public struct LANServerEndpoint: Equatable, Sendable {
    public let host: String
    public let port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    /// The authority component for an HTTP URL. IPv6 literals must be
    /// bracketed so their colons cannot be confused with the port separator.
    public var urlAuthority: String {
        LANIPAddress.parseCanonical(host)?.isIPv6 == true
            ? "[\(host)]:\(port)"
            : "\(host):\(port)"
    }
}

public struct LANTransportPeer: Equatable, Sendable {
    public let host: String
    public let port: Int?

    public init(host: String, port: Int?) {
        self.host = host
        self.port = port
    }
}

public enum LANServerTransportError: Error, Equatable, Sendable {
    case alreadyStarted
    case stopped
    case invalidHost(String)
    case invalidPort(Int)
    case boundAddressMismatch
}

struct LANConnectionLimits: Equatable, Sendable {
    static let receiverDefault = Self(maxGlobal: 8, maxPerPeer: 4)

    let maxGlobal: Int
    let maxPerPeer: Int

    init(maxGlobal: Int, maxPerPeer: Int) {
        precondition(maxGlobal > 0)
        precondition(maxPerPeer > 0)
        precondition(maxPerPeer <= maxGlobal)
        self.maxGlobal = maxGlobal
        self.maxPerPeer = maxPerPeer
    }
}

public actor LANServerTransport {
    public typealias ByteSink = @Sendable (Data, LANTransportPeer) -> Void
    typealias ChildChannelInitializer = @Sendable (
        any Channel,
        LANTransportPeer
    ) -> EventLoopFuture<Void>
    typealias StartHook = @Sendable () async -> Void

    private enum Phase: Equatable {
        case idle
        case starting(UUID)
        case running
        case stopping
        case stopped
    }

    private enum AddressPolicy {
        case exactUsable
        case exactIncludingLoopbackForTesting

        var allowsLoopback: Bool {
            self == .exactIncludingLoopbackForTesting
        }
    }

    private let group: MultiThreadedEventLoopGroup
    private let channels: LANChannelRegistry
    private let childChannelInitializer: ChildChannelInitializer
    private let addressPolicy: AddressPolicy
    private let startHook: StartHook?
    private var listener: (any Channel)?
    private var phase: Phase = .idle
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    /// Creates the U1 byte-stream transport. The peer supplied to `byteSink`
    /// always comes from the accepted socket; application-layer forwarded
    /// headers are not inspected by this layer.
    public init(byteSink: @escaping ByteSink) {
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.channels = LANChannelRegistry(limits: .receiverDefault)
        self.childChannelInitializer = Self.byteSinkInitializer(byteSink)
        self.addressPolicy = .exactUsable
        self.startHook = nil
    }

    /// Test-only loopback seam that exercises real channels without weakening
    /// the public receiver's exact, non-loopback bind policy.
    init(
        testingByteSink byteSink: @escaping ByteSink,
        startHook: StartHook? = nil,
        connectionLimits: LANConnectionLimits = .receiverDefault
    ) {
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.channels = LANChannelRegistry(limits: connectionLimits)
        self.childChannelInitializer = Self.byteSinkInitializer(byteSink)
        self.addressPolicy = .exactIncludingLoopbackForTesting
        self.startHook = startHook
    }

    init(
        byteSink: @escaping ByteSink,
        startHook: @escaping StartHook
    ) {
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.channels = LANChannelRegistry(limits: .receiverDefault)
        self.childChannelInitializer = Self.byteSinkInitializer(byteSink)
        self.addressPolicy = .exactIncludingLoopbackForTesting
        self.startHook = startHook
    }

    /// Internal composition seam for U4's HTTP pipeline. Registration and
    /// admission happen before this closure, and transport stop still owns and
    /// closes every accepted child even when a custom pipeline is installed.
    init(
        childChannelInitializer: @escaping ChildChannelInitializer,
        startHook: StartHook? = nil,
        allowLoopbackForTesting: Bool = false,
        connectionLimits: LANConnectionLimits = .receiverDefault
    ) {
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.channels = LANChannelRegistry(limits: connectionLimits)
        self.childChannelInitializer = childChannelInitializer
        self.addressPolicy = allowLoopbackForTesting
            ? .exactIncludingLoopbackForTesting
            : .exactUsable
        self.startHook = startHook
    }

    public func start(host: String, port: Int = 0) async throws -> LANServerEndpoint {
        switch phase {
        case .idle:
            break
        case .starting, .running:
            throw LANServerTransportError.alreadyStarted
        case .stopping, .stopped:
            throw LANServerTransportError.stopped
        }
        guard (0...65_535).contains(port) else {
            throw LANServerTransportError.invalidPort(port)
        }
        guard LANIPAddress.parseUsableCanonical(
            host,
            allowingLoopback: addressPolicy.allowsLoopback
        ) != nil else {
            throw LANServerTransportError.invalidHost(host)
        }

        let generation = UUID()
        phase = .starting(generation)
        await startHook?()
        guard phase == .starting(generation) else {
            settleStartIfStopping()
            throw LANServerTransportError.stopped
        }

        let registry = channels
        let initializer = childChannelInitializer
        let channel: any Channel
        do {
            channel = try await ServerBootstrap(group: group)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .childChannelOption(.autoRead, value: false)
                .childChannelOption(.maxMessagesPerRead, value: 1)
                .childChannelOption(
                    .recvAllocator,
                    value: FixedSizeRecvByteBufferAllocator(capacity: 16 * 1_024)
                )
                .childChannelInitializer { channel in
                    let peer = Self.socketPeer(for: channel)
                    guard registry.insertIfAccepting(channel, peerHost: peer.host) else {
                        return channel.close()
                    }
                    channel.closeFuture.whenComplete { _ in
                        registry.remove(channel)
                    }
                    return initializer(channel, peer).flatMapError { error in
                        registry.remove(channel)
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                }
                .bind(to: try SocketAddress(ipAddress: host, port: port))
                .get()
        } catch {
            if phase == .starting(generation) {
                phase = .idle
            } else {
                settleStartIfStopping()
            }
            throw error
        }

        guard phase == .starting(generation) else {
            try? await channel.close().get()
            settleStartIfStopping()
            throw LANServerTransportError.stopped
        }

        guard let local = channel.localAddress,
              Self.isExactBoundAddress(local, requestedHost: host),
              let actualPort = local.port,
              actualPort > 0 else {
            try? await channel.close().get()
            phase = .idle
            throw LANServerTransportError.boundAddressMismatch
        }
        listener = channel
        phase = .running
        return .init(host: host, port: actualPort)
    }

    public func stop() async {
        var children: [any Channel] = []
        switch phase {
        case .stopped:
            return
        case .stopping:
            await waitUntilStopped()
            return
        case .starting:
            phase = .stopping
            children = channels.beginStopping()
            // Registration must happen synchronously in this actor turn. An
            // awaited helper here lets the in-flight start settle before this
            // continuation exists, which would leave stop suspended forever.
            await withCheckedContinuation { continuation in
                startWaiters.append(continuation)
            }
        case .idle, .running:
            phase = .stopping
        }

        children.append(contentsOf: channels.beginStopping())
        if let listener {
            try? await listener.close().get()
            self.listener = nil
        }
        await withTaskGroup(of: Void.self) { group in
            for channel in children {
                group.addTask { try? await channel.close().get() }
            }
        }
        try? await group.shutdownGracefully()
        phase = .stopped
        resumeStartWaiters()
    }

    private static func byteSinkInitializer(
        _ sink: @escaping ByteSink
    ) -> ChildChannelInitializer {
        { channel, _ in
            channel.pipeline.addHandlers([
                LANManualReadHandler(),
                LANInboundBytesHandler(byteSink: sink),
            ])
        }
    }

    private static func socketPeer(for channel: any Channel) -> LANTransportPeer {
        let address = channel.remoteAddress
        return .init(host: address?.ipAddress ?? "unknown", port: address?.port)
    }

    static func isExactBoundAddress(
        _ localAddress: SocketAddress,
        requestedHost: String
    ) -> Bool {
        guard let actualHost = localAddress.ipAddress,
              let actual = LANIPAddress.parseCanonical(actualHost),
              let requested = LANIPAddress.parseCanonical(requestedHost) else {
            return false
        }
        return actual == requested
    }

    private func settleStartIfStopping() {
        guard phase == .stopping else { return }
        resumeStartWaiters()
    }

    private func waitUntilStopped() async {
        while phase != .stopped {
            await Task.yield()
        }
    }

    private func resumeStartWaiters() {
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

// SAFETY: `lock` protects registration, admission, and shutdown state; channel
// operations are always dispatched through their owning event loops.
final class LANChannelRegistry: @unchecked Sendable {
    private struct Registration {
        let channel: any Channel
        let peerHost: String
    }

    private let lock = NSLock()
    private let limits: LANConnectionLimits
    private var channels: [ObjectIdentifier: Registration] = [:]
    private var peerCounts: [String: Int] = [:]
    private var accepting = true

    init(limits: LANConnectionLimits = .receiverDefault) {
        self.limits = limits
    }

    func insertIfAccepting(_ channel: any Channel, peerHost: String) -> Bool {
        lock.withLock {
            guard accepting,
                  channels.count < limits.maxGlobal,
                  peerCounts[peerHost, default: 0] < limits.maxPerPeer else {
                return false
            }
            channels[ObjectIdentifier(channel)] = .init(
                channel: channel,
                peerHost: peerHost
            )
            peerCounts[peerHost, default: 0] += 1
            return true
        }
    }

    func insertIfAccepting(_ channel: any Channel) -> Bool {
        insertIfAccepting(
            channel,
            peerHost: channel.remoteAddress?.ipAddress ?? "unknown"
        )
    }

    func remove(_ channel: any Channel) {
        lock.withLock {
            guard let registration = channels.removeValue(
                forKey: ObjectIdentifier(channel)
            ) else { return }
            let remaining = peerCounts[registration.peerHost, default: 1] - 1
            if remaining == 0 {
                peerCounts.removeValue(forKey: registration.peerHost)
            } else {
                peerCounts[registration.peerHost] = remaining
            }
        }
    }

    func beginStopping() -> [any Channel] {
        lock.withLock {
            accepting = false
            defer {
                channels.removeAll()
                peerCounts.removeAll()
            }
            return channels.values.map(\.channel)
        }
    }
}

private final class LANManualReadHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer

    func channelActive(context: ChannelHandlerContext) {
        context.fireChannelActive()
        context.read()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.fireChannelRead(data)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        context.fireChannelReadComplete()
        context.read()
    }
}

private final class LANInboundBytesHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer

    private let byteSink: LANServerTransport.ByteSink

    init(byteSink: @escaping LANServerTransport.ByteSink) {
        self.byteSink = byteSink
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        guard let bytes = buffer.readBytes(length: buffer.readableBytes),
              !bytes.isEmpty else { return }
        let address = context.channel.remoteAddress
        byteSink(
            Data(bytes),
            .init(host: address?.ipAddress ?? "unknown", port: address?.port)
        )
    }
}
