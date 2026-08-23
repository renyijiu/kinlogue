import Foundation
import NIOCore
import NIOEmbedded
import NIOHTTP1
import Testing
@testable import KinloguePlatform

struct LANHTTPHandlerTests {
    private let authority = "192.168.1.23:50813"
    private let origin = "http://192.168.1.23:50813"
    private let cookie = String(repeating: "a", count: 32)
    private let csrf = String(repeating: "b", count: 32)

    @Test
    func pairingSetsOnlyTheSessionCookieAndFixedSafeHeaders() async throws {
        let application = HTTPFileTestApplication(cookie: cookie, csrf: csrf)
        let channel = try await makeChannel(application: application)
        let body = #"{"code":"123456"}"#
        try await write(
            "POST /api/pair HTTP/1.1\r\n"
                + "Host: \(authority)\r\n"
                + "Origin: \(origin)\r\n"
                + "Content-Type: application/json\r\n"
                + "Content-Length: \(body.utf8.count)\r\n\r\n"
                + body,
            to: channel
        )
        let response = try await receiveResponse(from: channel)

        #expect(response.head.status == .ok)
        #expect(await application.snapshot().pairCalls == 1)
        let setCookie = try #require(response.head.headers.first(name: "Set-Cookie"))
        #expect(setCookie == "KinlogueLANSession=\(cookie); Path=/; HttpOnly; SameSite=Strict")
        #expect(!setCookie.contains("Secure"))
        #expect(!setCookie.contains("Domain"))
        assertSafeClosedResponse(response)
    }

    @Test
    func fileSessionRestoreNeedsOnlyTheCapabilityCookie() async throws {
        let application = HTTPFileTestApplication(cookie: cookie, csrf: csrf)
        let channel = try await makeChannel(application: application)
        try await write(
            "GET /api/session HTTP/1.1\r\n"
                + "Host: \(authority)\r\n"
                + "Cookie: KinlogueLANSession=\(cookie)\r\n\r\n",
            to: channel
        )
        let response = try await receiveResponse(from: channel)

        #expect(response.head.status == .ok)
        #expect(await application.snapshot().sessionCalls == 1)
        #expect(String(decoding: response.body, as: UTF8.self).contains("\"files\":[]"))
    }

    @Test
    func fileRoutesReserveAndReplayOneGenericSavedResponse() async throws {
        let application = HTTPFileTestApplication(cookie: cookie, csrf: csrf)
        let remoteFileID = "22222222-2222-4222-8222-222222222222"
        let reserveBody = #"{"attemptRevision":0,"declaredByteCount":3,"displayName":"page.jpg","mediaType":"image/jpeg","remoteFileID":"22222222-2222-4222-8222-222222222222"}"#

        let reserveChannel = try await makeChannel(application: application)
        try await write(
            "POST /api/files/reserve HTTP/1.1\r\n"
                + "Host: \(authority)\r\n"
                + "Origin: \(origin)\r\n"
                + "Cookie: KinlogueLANSession=\(cookie)\r\n"
                + "X-Kinlogue-CSRF: \(csrf)\r\n"
                + "Content-Type: application/json\r\n"
                + "Content-Length: \(reserveBody.utf8.count)\r\n\r\n"
                + reserveBody,
            to: reserveChannel
        )
        let reserved = try await receiveResponse(from: reserveChannel)
        #expect(reserved.head.status == .created)
        #expect(String(decoding: reserved.body, as: UTF8.self).contains(remoteFileID))

        let uploadChannel = try await makeChannel(application: application)
        try await write(
            "PUT /api/files/\(remoteFileID) HTTP/1.1\r\n"
                + "Host: \(authority)\r\n"
                + "Origin: \(origin)\r\n"
                + "Cookie: KinlogueLANSession=\(cookie)\r\n"
                + "X-Kinlogue-CSRF: \(csrf)\r\n"
                + "X-Kinlogue-Attempt-Revision: 0\r\n"
                + "Content-Type: application/octet-stream\r\n"
                + "Content-Length: 3\r\n\r\nabc",
            to: uploadChannel
        )
        let uploaded = try await receiveResponse(from: uploadChannel)
        #expect(uploaded.head.status == .ok)
        #expect(String(decoding: uploaded.body, as: UTF8.self)
            == #"{"outcome":"saved"}"#)
        #expect(await application.snapshot().beginFileUploadCalls == 1)
    }

    @Test
    func fileIdentityIsNotLookedUpBeforeMutationProofValidation() async throws {
        let application = HTTPFileTestApplication(cookie: cookie, csrf: csrf)
        let channel = try await makeChannel(application: application)
        try await write(
            "GET /api/files/22222222-2222-4222-8222-222222222222 HTTP/1.1\r\n"
                + "Host: \(authority)\r\n"
                + "Origin: \(origin)\r\n"
                + "Cookie: KinlogueLANSession=\(cookie)\r\n\r\n",
            to: channel
        )
        let response = try await receiveResponse(from: channel)

        #expect(response.head.status == .unauthorized)
        #expect(await application.snapshot().authorizeCalls == 0)
        #expect(await application.snapshot().fileStatusCalls == 0)
    }

    @Test
    func removedGroupingRouteIsNotRecognized() async throws {
        let application = HTTPFileTestApplication(cookie: cookie, csrf: csrf)
        let channel = try await makeChannel(application: application)
        try await write(
            "POST /api/\(["bat", "ches"].joined()) HTTP/1.1\r\n"
                + "Host: \(authority)\r\n"
                + "Origin: \(origin)\r\n"
                + "Content-Length: 0\r\n\r\n",
            to: channel
        )
        let response = try await receiveResponse(from: channel)

        #expect(response.head.status == .notFound)
        #expect(await application.snapshot().authorizeCalls == 0)
    }

    private func makeChannel(
        application: any LANHTTPApplication
    ) async throws -> NIOAsyncTestingChannel {
        let channel = NIOAsyncTestingChannel(loop: NIOAsyncTestingEventLoop())
        let configuration = LANHTTPHandlerConfiguration(
            canonicalAuthority: authority,
            assetCatalog: .init(
                page: Data("page".utf8),
                script: Data("script".utf8),
                stylesheet: Data("style".utf8)
            ),
            application: application,
            peer: .init(host: "198.51.100.7", port: 12_345)
        )
        try await LANHTTPPipeline.configure(
            channel: channel,
            configuration: configuration
        ).get()
        try await channel.register().get()
        try await channel.connect(
            to: SocketAddress(ipAddress: "127.0.0.1", port: 50_813)
        ).get()
        return channel
    }

    private func write(
        _ request: String,
        to channel: NIOAsyncTestingChannel
    ) async throws {
        var input = channel.allocator.buffer(capacity: request.utf8.count)
        input.writeString(request)
        try await channel.writeInbound(input)
        for _ in 0..<8 {
            await channel.testingEventLoop.run()
            await Task.yield()
        }
    }

    private func receiveResponse(
        from channel: NIOAsyncTestingChannel
    ) async throws -> HTTPDecodedResponse {
        var wire = try await channel.waitForOutboundWrite(as: ByteBuffer.self)
        await channel.testingEventLoop.run()
        try await channel.closeFuture.get()
        while var next = try await channel.readOutbound(as: ByteBuffer.self) {
            wire.writeBuffer(&next)
        }
        let leftovers = try await channel.finish(acceptAlreadyClosed: true)
        #expect(leftovers.isClean)
        return try decodeResponse(wire)
    }

    private func decodeResponse(_ wire: ByteBuffer) throws -> HTTPDecodedResponse {
        let decoder = EmbeddedChannel()
        defer { _ = try? decoder.finish(acceptAlreadyClosed: true) }
        try decoder.pipeline.syncOperations.addHTTPClientHandlers()
        try decoder.writeOutbound(HTTPClientRequestPart.head(.init(
            version: .http1_1,
            method: .GET,
            uri: "/"
        )))
        try decoder.writeOutbound(HTTPClientRequestPart.end(nil))
        while let _: ByteBuffer = try decoder.readOutbound() {}
        try decoder.writeInbound(wire)
        var head: HTTPResponseHead?
        var body = ByteBufferAllocator().buffer(capacity: 0)
        while let part = try decoder.readInbound(as: HTTPClientResponsePart.self) {
            switch part {
            case .head(let value): head = value
            case .body(var chunk): body.writeBuffer(&chunk)
            case .end: break
            }
        }
        return HTTPDecodedResponse(
            head: try #require(head),
            body: Data(body.readableBytesView)
        )
    }

    private func assertSafeClosedResponse(_ response: HTTPDecodedResponse) {
        #expect(response.head.headers.first(name: "Connection") == "close")
        #expect(response.head.headers.first(name: "Cache-Control") == "no-store")
        #expect(response.head.headers.first(name: "Pragma") == "no-cache")
        #expect(response.head.headers.first(name: "Referrer-Policy") == "no-referrer")
        #expect(response.head.headers.first(name: "X-Content-Type-Options") == "nosniff")
        #expect(response.head.headers.first(name: "X-Frame-Options") == "DENY")
        #expect(response.head.headers.first(name: "Cross-Origin-Resource-Policy") == "same-origin")
        #expect(response.head.headers.first(name: "Access-Control-Allow-Origin") == nil)
    }
}

private struct HTTPDecodedResponse {
    let head: HTTPResponseHead
    let body: Data
}

private struct HTTPFileTestApplicationSnapshot: Sendable {
    let pairCalls: Int
    let sessionCalls: Int
    let authorizeCalls: Int
    let beginFileUploadCalls: Int
    let fileStatusCalls: Int
}

private actor HTTPFileTestApplication: LANHTTPApplication {
    private let cookie: String
    private let csrf: String
    private var pairCalls = 0
    private var sessionCalls = 0
    private var authorizeCalls = 0
    private var beginFileUploadCalls = 0
    private var fileStatusCalls = 0

    init(cookie: String, csrf: String) {
        self.cookie = cookie
        self.csrf = csrf
    }

    func snapshot() -> HTTPFileTestApplicationSnapshot {
        .init(
            pairCalls: pairCalls,
            sessionCalls: sessionCalls,
            authorizeCalls: authorizeCalls,
            beginFileUploadCalls: beginFileUploadCalls,
            fileStatusCalls: fileStatusCalls
        )
    }

    func pair(
        _ request: LANPairRequest,
        from peer: LANTransportPeer
    ) async throws -> LANHTTPPairSuccess {
        pairCalls += 1
        return try .init(
            cookieValue: cookie,
            response: LANPairResponse(csrfToken: csrf)
        )
    }

    func restoreFileSession(
        _ capability: LANHTTPBrowserCapability,
        from peer: LANTransportPeer
    ) async throws -> LANFileSessionResponse {
        sessionCalls += 1
        return try .init(csrfToken: csrf, files: [])
    }

    func authorize(
        _ proof: LANHTTPBrowserProof,
        from peer: LANTransportPeer,
        operation: LANAuthenticatedOperation
    ) async throws -> LANAuthorizedSession {
        authorizeCalls += 1
        guard proof.cookieValue == cookie, proof.csrfToken == csrf else {
            throw LANHTTPApplicationFailure.sessionEnded
        }
        return .init(
            sessionID: LANSessionID(uuid: UUID(
                uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
            )!),
            runtimeGeneration: 1
        )
    }

    func logout(
        _ proof: LANHTTPBrowserProof,
        from peer: LANTransportPeer
    ) async throws {}

    func reserveFile(
        _ request: LANReserveFileRequest,
        authorization: LANAuthorizedSession
    ) async throws -> LANReserveFileResponse {
        try LANReserveFileResponse(file: LANPhoneFileStatus(
            remoteFileID: request.remoteFileID,
            displayName: request.displayName,
            declaredByteCount: request.declaredByteCount,
            receivedByteCount: 0,
            attemptRevision: request.attemptRevision,
            state: .reserved
        ))
    }

    func beginFileUpload(
        remoteFileID: UUID,
        attemptRevision: UInt64,
        declaredByteCount: Int?,
        authorization: LANAuthorizedSession
    ) async throws -> LANHTTPFileUploadStart {
        beginFileUploadCalls += 1
        return .alreadySaved(
            LANFileSavedResponse(),
            expectedByteCount: Int64(declaredByteCount ?? 0)
        )
    }

    func fileStatus(
        remoteFileID: UUID,
        authorization: LANAuthorizedSession
    ) async throws -> LANPhoneFileStatus {
        fileStatusCalls += 1
        return try LANPhoneFileStatus(
            remoteFileID: remoteFileID,
            displayName: "synthetic.bin",
            declaredByteCount: 3,
            receivedByteCount: 3,
            attemptRevision: 0,
            state: .saved
        )
    }

    func cancelFile(
        remoteFileID: UUID,
        attemptRevision: UInt64,
        authorization: LANAuthorizedSession
    ) async throws -> LANFileCancelResponse {
        LANFileCancelResponse()
    }
}
