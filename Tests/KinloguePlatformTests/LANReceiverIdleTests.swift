import NIOCore
import Testing
@testable import KinloguePlatform

@Suite(.serialized)
struct LANReceiverIdleTests {
    @Test
    func sessionPollingDoesNotKeepTheReceiverAlive() async throws {
        let fixture = try await LANInboxStoreTestFixture.make()
        defer { fixture.destroy() }
        let receiver = LANReceiver(
            rootURL: fixture.rootURL,
            session: LANSession(),
            idleDuration: .milliseconds(2_500)
        )
        let presentation = try await receiver.start(
            at: .init(interfaceName: "lo0", host: "127.0.0.1"),
            port: 0,
            allowLoopbackForTesting: true,
            pipelineInstaller: { channel, _, _, _ in
                channel.eventLoop.makeSucceededFuture(())
            }
        )
        let peer = LANTransportPeer(host: "127.0.0.1", port: 44_006)
        let paired = try await receiver.pair(
            LANPairRequest(code: presentation.pairingCode.value),
            from: peer
        )
        let capability = LANHTTPBrowserCapability(cookieValue: paired.cookieValue)

        for _ in 0..<2 {
            try await Task.sleep(for: .milliseconds(1_100))
            _ = try await receiver.restoreFileSession(capability, from: peer)
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await receiver.isActive, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        await #expect(throws: LANHTTPApplicationFailure.sessionEnded) {
            try await receiver.restoreFileSession(capability, from: peer)
        }
        #expect(!(await receiver.isActive))
        await receiver.stop()
    }
}
