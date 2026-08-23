import Darwin
import CryptoKit
import Foundation
import KinlogueCore
@_spi(KinlogueAcceptance) import KinloguePlatform

enum InstalledLANAcceptanceEventCode: String, Codable, Sendable {
    case receiverComplete = "KLA_LAN_RECEIVER_COMPLETE"
    case restartComplete = "KLA_LAN_RESTART_COMPLETE"
}

struct InstalledLANAcceptanceEvent: Codable, Equatable, Sendable {
    let code: InstalledLANAcceptanceEventCode
    let ok: Bool
    let executableSHA256: String
    let listenerAbsentBeforeStart: Bool
    let listenerActiveAfterStart: Bool
    let channelClosedAfterStop: Bool
    let listenerAbsentAfterStop: Bool
    let oldSessionRejected: Bool
    let pairingRejected: Bool
    let authenticationRejected: Bool
    let hostRejected: Bool
    let originRejected: Bool
    let framingRejected: Bool
    let uniqueFilesStored: Bool
    let streamingUploadVerified: Bool
    let interruptedUploadCleanupVerified: Bool

    init(
        executableSHA256: String,
        listenerAbsentBeforeStart: Bool,
        listenerActiveAfterStart: Bool,
        channelClosedAfterStop: Bool,
        listenerAbsentAfterStop: Bool,
        oldSessionRejected: Bool,
        pairingRejected: Bool,
        authenticationRejected: Bool,
        hostRejected: Bool,
        originRejected: Bool,
        framingRejected: Bool,
        uniqueFilesStored: Bool,
        streamingUploadVerified: Bool,
        interruptedUploadCleanupVerified: Bool
    ) throws {
        let checks = [
            ("listenerAbsentBeforeStart", listenerAbsentBeforeStart),
            ("listenerActiveAfterStart", listenerActiveAfterStart),
            ("channelClosedAfterStop", channelClosedAfterStop),
            ("listenerAbsentAfterStop", listenerAbsentAfterStop),
            ("oldSessionRejected", oldSessionRejected),
            ("pairingRejected", pairingRejected),
            ("authenticationRejected", authenticationRejected),
            ("hostRejected", hostRejected),
            ("originRejected", originRejected),
            ("framingRejected", framingRejected),
            ("uniqueFilesStored", uniqueFilesStored),
            ("streamingUploadVerified", streamingUploadVerified),
            ("interruptedUploadCleanupVerified", interruptedUploadCleanupVerified),
        ]
        guard Self.validSHA256(executableSHA256) else {
            throw InstalledLANAcceptanceProbeError.requiredEvidence(
                "executableSHA256"
            )
        }
        if let failed = checks.first(where: { !$0.1 }) {
            throw InstalledLANAcceptanceProbeError.requiredEvidence(failed.0)
        }
        code = .receiverComplete
        ok = true
        self.executableSHA256 = executableSHA256
        self.listenerAbsentBeforeStart = listenerAbsentBeforeStart
        self.listenerActiveAfterStart = listenerActiveAfterStart
        self.channelClosedAfterStop = channelClosedAfterStop
        self.listenerAbsentAfterStop = listenerAbsentAfterStop
        self.oldSessionRejected = oldSessionRejected
        self.pairingRejected = pairingRejected
        self.authenticationRejected = authenticationRejected
        self.hostRejected = hostRejected
        self.originRejected = originRejected
        self.framingRejected = framingRejected
        self.uniqueFilesStored = uniqueFilesStored
        self.streamingUploadVerified = streamingUploadVerified
        self.interruptedUploadCleanupVerified = interruptedUploadCleanupVerified
    }

    func emit() throws {
        try Self.encodeAndEmit(self)
    }

    fileprivate static func encodeAndEmit<Value: Encodable>(_ value: Value) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let line = try encoder.encode(value)
        FileHandle.standardOutput.write(line)
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    static func validSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
                || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
        }
    }
}

struct InstalledLANRestartEvent: Codable, Equatable, Sendable {
    let code: InstalledLANAcceptanceEventCode
    let ok: Bool
    let executableSHA256: String
    let completedFilesAfterProcessRestart: Bool
    let listenerAbsentAfterRestartStop: Bool

    init(
        executableSHA256: String,
        completedFilesAfterProcessRestart: Bool,
        listenerAbsentAfterRestartStop: Bool
    ) throws {
        guard InstalledLANAcceptanceEvent.validSHA256(executableSHA256),
              completedFilesAfterProcessRestart,
              listenerAbsentAfterRestartStop else {
            throw InstalledLANAcceptanceProbeError.invariantFailed
        }
        code = .restartComplete
        ok = true
        self.executableSHA256 = executableSHA256
        self.completedFilesAfterProcessRestart = completedFilesAfterProcessRestart
        self.listenerAbsentAfterRestartStop = listenerAbsentAfterRestartStop
    }

    func emit() throws {
        try InstalledLANAcceptanceEvent.encodeAndEmit(self)
    }
}

struct InstalledLANAcceptanceFailureEvent: Encodable, Equatable, Sendable {
    let code = "KLA_LAN_RECEIVER_FAILED"
    let ok = false
    let reason: String

    init(error: InstalledLANAcceptanceProbeError) {
        switch error {
        case .invariantFailed:
            reason = "invariant-failed"
        case .requiredEvidence(let field):
            switch field {
            case "executableSHA256",
                 "listenerAbsentBeforeStart",
                 "listenerActiveAfterStart",
                 "channelClosedAfterStop",
                 "listenerAbsentAfterStop",
                 "oldSessionRejected",
                 "pairingRejected",
                 "authenticationRejected",
                 "hostRejected",
                 "originRejected",
                 "framingRejected",
                 "uniqueFilesStored",
                 "streamingUploadVerified",
                 "interruptedUploadCleanupVerified":
                reason = "required-" + field
            default:
                reason = "required-evidence"
            }
        case .malformedResponse:
            reason = "malformed-response"
        case .socketFailure(let operation):
            reason = "socket-" + operation.rawValue
        case .responseTooLarge:
            reason = "response-too-large"
        case .dependencyFailure:
            reason = "dependency-failure"
        }
    }

    func emit() throws {
        try InstalledLANAcceptanceEvent.encodeAndEmit(self)
    }
}

enum InstalledLANSocketOperation: String, Equatable, Sendable {
    case create
    case configure
    case address
    case bind
    case inspectAddress = "inspect-address"
    case connect
    case send
    case receive
}

enum InstalledLANAcceptanceProbeError: Error, Equatable, Sendable {
    case invariantFailed
    case requiredEvidence(String)
    case malformedResponse
    case socketFailure(InstalledLANSocketOperation)
    case responseTooLarge
    case dependencyFailure
}

struct InstalledLANAcceptanceProbe: Sendable {
    private enum UploadFraming {
        case contentLength
        case chunked
    }

    private struct Response {
        let status: Int
        let headers: [String: [String]]
        let body: Data
    }

    private struct Credentials {
        let cookie: String
        let csrf: String
    }

    private static let loopbackHost = "127.0.0.1"
    private static let completedFileDomain = "kinlogue.acceptance.lan.file.v2"
    private static let interruptedFileDomain = "kinlogue.acceptance.lan.interrupted.v2"
    private static let completedFixtureBytes = [
        Data("synthetic-lan-page-a".utf8),
        Data("synthetic-lan-page-b".utf8),
    ]

    let rootURL: URL
    let runID: String
    let executableURL: URL

    func run() async throws -> InstalledLANAcceptanceEvent {
        let receiver = LANReceiver(rootURL: rootURL)
        do {
            return try await exercise(receiver: receiver)
        } catch {
            await receiver.stop()
            throw (error as? InstalledLANAcceptanceProbeError) ?? .dependencyFailure
        }
    }

    private func exercise(
        receiver: LANReceiver
    ) async throws -> InstalledLANAcceptanceEvent {
        let reserved = try reserveLoopbackEndpoint()
        let listenerAbsentBeforeStart = !canConnect(to: reserved)
        let presentation = try await receiver.startInstalledAcceptanceProbe(
            port: reserved.port
        )
        let endpoint = presentation.endpoint
        let authority = endpoint.urlAuthority
        let listenerActiveAfterStart = canConnect(to: endpoint)

        let hostRejected = try request(
            endpoint: endpoint,
            bytes: getRequest(target: "/", authority: "127.0.0.1:1")
        ).status == 400
        let wrongCode = presentation.pairingCode.value.first == "0"
            ? "1" + presentation.pairingCode.value.dropFirst()
            : "0" + presentation.pairingCode.value.dropFirst()
        let pairingRejected = try request(
            endpoint: endpoint,
            bytes: jsonRequest(
                method: "POST",
                target: "/api/pair",
                authority: authority,
                body: try LANHTTPJSONCodec.encode(LANPairRequest(code: wrongCode))
            )
        ).status == 403
        let pairResponse = try request(
            endpoint: endpoint,
            bytes: jsonRequest(
                method: "POST",
                target: "/api/pair",
                authority: authority,
                body: try LANHTTPJSONCodec.encode(
                    LANPairRequest(code: presentation.pairingCode.value)
                )
            )
        )
        guard pairResponse.status == 200 else {
            throw InstalledLANAcceptanceProbeError.invariantFailed
        }
        let paired = try LANHTTPJSONCodec.decode(
            LANPairResponse.self,
            from: pairResponse.body
        )
        let credentials = Credentials(
            cookie: try sessionCookie(from: pairResponse),
            csrf: paired.csrfToken
        )

        let completedRequests = try Self.completedFixtureBytes.indices.map { index in
            try LANReserveFileRequest(
                remoteFileID: deterministicUUID(domain: "completed-file-\(index)"),
                displayName: "synthetic-page-\(index + 1).bin",
                declaredByteCount: Int64(Self.completedFixtureBytes[index].count),
                mediaType: "application/octet-stream",
                attemptRevision: 0
            )
        }
        let reserveBody = try LANHTTPJSONCodec.encode(completedRequests[0])
        let authenticationRejected = try request(
            endpoint: endpoint,
            bytes: jsonRequest(
                method: "POST",
                target: "/api/files/reserve",
                authority: authority,
                body: reserveBody,
                csrf: credentials.csrf
            )
        ).status == 401
        let originRejected = try request(
            endpoint: endpoint,
            bytes: jsonRequest(
                method: "POST",
                target: "/api/files/reserve",
                authority: authority,
                origin: "http://127.0.0.1:1",
                body: reserveBody,
                credentials: credentials
            )
        ).status == 403
        let framingRejected = try request(
            endpoint: endpoint,
            bytes: ambiguousFramingRequest(
                target: "/api/files/reserve",
                authority: authority,
                body: reserveBody,
                credentials: credentials
            )
        ).status == 400

        var uploadResponses: [LANFileSavedResponse] = []
        for index in completedRequests.indices {
            let reserveResponse = try request(
                endpoint: endpoint,
                bytes: jsonRequest(
                    method: "POST",
                    target: "/api/files/reserve",
                    authority: authority,
                    body: try LANHTTPJSONCodec.encode(completedRequests[index]),
                    credentials: credentials
                )
            )
            guard reserveResponse.status == 201 else {
                throw InstalledLANAcceptanceProbeError.invariantFailed
            }
            let reservedFile = try LANHTTPJSONCodec.decode(
                LANReserveFileResponse.self,
                from: reserveResponse.body
            )
            let uploadResponse = try streamUpload(
                endpoint: endpoint,
                authority: authority,
                fileID: completedRequests[index].remoteFileID,
                attemptRevision: reservedFile.file.attemptRevision,
                credentials: credentials,
                body: Self.completedFixtureBytes[index],
                framing: index == 0 ? .contentLength : .chunked
            )
            guard uploadResponse.status == 200 else {
                throw InstalledLANAcceptanceProbeError.invariantFailed
            }
            uploadResponses.append(try LANHTTPJSONCodec.decode(
                LANFileSavedResponse.self,
                from: uploadResponse.body
            ))
        }

        let interruptedRequest = try LANReserveFileRequest(
            remoteFileID: deterministicUUID(domain: Self.interruptedFileDomain),
            displayName: "synthetic-interrupted.bin",
            declaredByteCount: 32,
            mediaType: "application/octet-stream",
            attemptRevision: 0
        )
        let interruptedReserve = try request(
            endpoint: endpoint,
            bytes: jsonRequest(
                method: "POST",
                target: "/api/files/reserve",
                authority: authority,
                body: try LANHTTPJSONCodec.encode(interruptedRequest),
                credentials: credentials
            )
        )
        guard interruptedReserve.status == 201 else {
            throw InstalledLANAcceptanceProbeError.invariantFailed
        }
        let interruptedStatus = try LANHTTPJSONCodec.decode(
            LANReserveFileResponse.self,
            from: interruptedReserve.body
        )
        let partialDescriptor = try connectedSocket(to: endpoint)
        try sendAll(
            uploadHead(
                authority: authority,
                fileID: interruptedRequest.remoteFileID,
                attemptRevision: interruptedStatus.file.attemptRevision,
                credentials: credentials,
                framing: .contentLength,
                byteCount: 32
            ),
            through: partialDescriptor
        )
        try await waitUntil {
            let response = try request(
                endpoint: endpoint,
                bytes: authenticatedGetRequest(
                    target: "/api/files/"
                        + interruptedRequest.remoteFileID.uuidString.lowercased(),
                    authority: authority,
                    credentials: credentials
                )
            )
            guard response.status == 200 else { return false }
            return try LANHTTPJSONCodec.decode(
                LANPhoneFileStatus.self,
                from: response.body
            ).state == .receiving
        }
        try sendAll(Data(repeating: 0x31, count: 7), through: partialDescriptor)
        _ = Darwin.close(partialDescriptor)

        let observationStore = try PlaintextLANInboxStore(rootURL: rootURL)
        try await waitUntil {
            let summary = try await observationStore.storageSummary()
            let response = try request(
                endpoint: endpoint,
                bytes: authenticatedGetRequest(
                    target: "/api/files/"
                        + interruptedRequest.remoteFileID.uuidString.lowercased(),
                    authority: authority,
                    credentials: credentials
                )
            )
            guard response.status == 200 else { return false }
            let status = try LANHTTPJSONCodec.decode(
                LANPhoneFileStatus.self,
                from: response.body
            )
            return status.state == .interrupted && summary.partialObjectCount == 0
        }

        let slowDescriptor = try connectedSocket(to: endpoint)
        try sendAll(Data("G".utf8), through: slowDescriptor)
        let stopStart = ContinuousClock.now
        await receiver.stop()
        let stopWithinOneSecond = stopStart.duration(to: .now) <= .seconds(1)
        let channelClosedAfterStop = stopWithinOneSecond
            && socketObservedRemoteClose(slowDescriptor)
        _ = Darwin.close(slowDescriptor)
        let listenerAbsentAfterStop = !canConnect(to: endpoint)

        let store = try PlaintextLANInboxStore(rootURL: rootURL)
        _ = try await store.initialize()
        let snapshot = try await store.loadSnapshot()
        let expectedIdentities = try Self.completedFixtureBytes.map { data in
            try LANInboxContentIdentity(
                sha256Digest: Data(SHA256.hash(data: data)),
                byteCount: data.count
            )
        }
        let uniqueFilesStored = expectedIdentities.allSatisfy { identity in
            snapshot.items.contains(where: { $0.contentIdentity == identity })
        } && snapshot.blobs.count == expectedIdentities.count
        let streamingUploadVerified = uploadResponses.count
                == Self.completedFixtureBytes.count
            && uploadResponses.allSatisfy { $0.outcome == .saved }
        let interruptedUploadCleanupVerified =
            (try await store.storageSummary()).partialObjectCount == 0

        let restarted = try await receiver.startInstalledAcceptanceProbe(
            port: endpoint.port
        )
        let staleResponse = try request(
            endpoint: restarted.endpoint,
            bytes: jsonRequest(
                method: "POST",
                target: "/api/files/reserve",
                authority: restarted.endpoint.urlAuthority,
                body: reserveBody,
                credentials: credentials
            )
        )
        let oldSessionRejected = staleResponse.status == 401
        await receiver.stop()

        return try InstalledLANAcceptanceEvent(
            executableSHA256: try executableSHA256(),
            listenerAbsentBeforeStart: listenerAbsentBeforeStart,
            listenerActiveAfterStart: listenerActiveAfterStart,
            channelClosedAfterStop: channelClosedAfterStop,
            listenerAbsentAfterStop: listenerAbsentAfterStop,
            oldSessionRejected: oldSessionRejected,
            pairingRejected: pairingRejected,
            authenticationRejected: authenticationRejected,
            hostRejected: hostRejected,
            originRejected: originRejected,
            framingRejected: framingRejected,
            uniqueFilesStored: uniqueFilesStored,
            streamingUploadVerified: streamingUploadVerified,
            interruptedUploadCleanupVerified: interruptedUploadCleanupVerified
        )
    }

    func verifyAfterProcessRestart() async throws -> InstalledLANRestartEvent {
        let store = try PlaintextLANInboxStore(rootURL: rootURL)
        _ = try await store.initialize()
        let snapshot = try await store.loadSnapshot()
        let completedFilesAfterProcessRestart =
            try Self.completedFixtureBytes.allSatisfy { data in
                let identity = try LANInboxContentIdentity(
                    sha256Digest: Data(SHA256.hash(data: data)),
                    byteCount: data.count
                )
                return snapshot.items.contains(where: {
                    $0.contentIdentity == identity
                })
            }
        let receiver = LANReceiver(rootURL: rootURL)
        do {
            let presentation = try await receiver.startInstalledAcceptanceProbe()
            await receiver.stop()
            return try InstalledLANRestartEvent(
                executableSHA256: try executableSHA256(),
                completedFilesAfterProcessRestart: completedFilesAfterProcessRestart,
                listenerAbsentAfterRestartStop: !canConnect(to: presentation.endpoint)
            )
        } catch {
            await receiver.stop()
            throw (error as? InstalledLANAcceptanceProbeError) ?? .dependencyFailure
        }
    }

    private func deterministicUUID(domain: String) -> UUID {
        AcceptanceFixtureIdentity.deterministicUUID(
            domain: domain,
            runID: runID,
            ordinal: 0
        )
    }

    private func executableSHA256() throws -> String {
        let handle = try FileHandle(forReadingFrom: executableURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return Data(hasher.finalize()).hexadecimalString
    }

    private func reserveLoopbackEndpoint() throws -> LANServerEndpoint {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw InstalledLANAcceptanceProbeError.socketFailure(.create)
        }
        defer { _ = Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        guard inet_pton(AF_INET, Self.loopbackHost, &address.sin_addr) == 1 else {
            throw InstalledLANAcceptanceProbeError.socketFailure(.address)
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            throw InstalledLANAcceptanceProbeError.socketFailure(.bind)
        }
        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let read = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard read == 0 else {
            throw InstalledLANAcceptanceProbeError.socketFailure(.inspectAddress)
        }
        return LANServerEndpoint(
            host: Self.loopbackHost,
            port: Int(in_port_t(bigEndian: local.sin_port))
        )
    }

    private func request(endpoint: LANServerEndpoint, bytes: Data) throws -> Response {
        let descriptor = try connectedSocket(to: endpoint)
        defer { _ = Darwin.close(descriptor) }
        try sendAll(bytes, through: descriptor)
        return try readResponse(from: descriptor)
    }

    private func streamUpload(
        endpoint: LANServerEndpoint,
        authority: String,
        fileID: UUID,
        attemptRevision: UInt64,
        credentials: Credentials,
        body: Data,
        framing: UploadFraming
    ) throws -> Response {
        let descriptor = try connectedSocket(to: endpoint)
        defer { _ = Darwin.close(descriptor) }
        try sendAll(
            uploadHead(
                authority: authority,
                fileID: fileID,
                attemptRevision: attemptRevision,
                credentials: credentials,
                framing: framing,
                byteCount: body.count
            ),
            through: descriptor
        )
        for chunk in body.chunked(maxByteCount: 5) {
            if framing == .chunked {
                try sendAll(Data(String(chunk.count, radix: 16).utf8), through: descriptor)
                try sendAll(Data("\r\n".utf8), through: descriptor)
            }
            try sendAll(chunk, through: descriptor)
            if framing == .chunked {
                try sendAll(Data("\r\n".utf8), through: descriptor)
            }
        }
        if framing == .chunked {
            try sendAll(Data("0\r\n\r\n".utf8), through: descriptor)
        }
        return try readResponse(from: descriptor)
    }

    private func getRequest(target: String, authority: String) -> Data {
        Data(("GET \(target) HTTP/1.1\r\n"
            + "Host: \(authority)\r\n"
            + "Connection: close\r\n\r\n").utf8)
    }

    private func authenticatedGetRequest(
        target: String,
        authority: String,
        credentials: Credentials
    ) -> Data {
        Data(("GET \(target) HTTP/1.1\r\n"
            + "Host: \(authority)\r\n"
            + "Origin: http://\(authority)\r\n"
            + "Cookie: \(LANHTTPHandlerConfiguration.sessionCookieName)="
            + credentials.cookie + "\r\n"
            + "\(LANHTTPHandlerConfiguration.csrfHeaderName): "
            + credentials.csrf + "\r\n"
            + "Connection: close\r\n\r\n").utf8)
    }

    private func jsonRequest(
        method: String,
        target: String,
        authority: String,
        origin: String? = nil,
        body: Data,
        credentials: Credentials? = nil,
        csrf: String? = nil
    ) -> Data {
        var head = "\(method) \(target) HTTP/1.1\r\n"
            + "Host: \(authority)\r\n"
            + "Origin: \(origin ?? "http://\(authority)")\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Connection: close\r\n"
        if let credentials {
            head += "Cookie: \(LANHTTPHandlerConfiguration.sessionCookieName)="
                + credentials.cookie + "\r\n"
            head += "\(LANHTTPHandlerConfiguration.csrfHeaderName): "
                + credentials.csrf + "\r\n"
        } else if let csrf {
            head += "\(LANHTTPHandlerConfiguration.csrfHeaderName): \(csrf)\r\n"
        }
        var request = Data((head + "\r\n").utf8)
        request.append(body)
        return request
    }

    private func ambiguousFramingRequest(
        target: String,
        authority: String,
        body: Data,
        credentials: Credentials
    ) -> Data {
        Data(("POST \(target) HTTP/1.1\r\n"
            + "Host: \(authority)\r\n"
            + "Origin: http://\(authority)\r\n"
            + "Cookie: \(LANHTTPHandlerConfiguration.sessionCookieName)="
            + credentials.cookie + "\r\n"
            + "\(LANHTTPHandlerConfiguration.csrfHeaderName): \(credentials.csrf)\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Transfer-Encoding: chunked\r\n"
            + "Connection: close\r\n\r\n0\r\n\r\n").utf8)
    }

    private func uploadHead(
        authority: String,
        fileID: UUID,
        attemptRevision: UInt64,
        credentials: Credentials,
        framing: UploadFraming,
        byteCount: Int
    ) -> Data {
        var head = "PUT /api/files/\(fileID.uuidString.lowercased()) HTTP/1.1\r\n"
            + "Host: \(authority)\r\n"
            + "Origin: http://\(authority)\r\n"
            + "Cookie: \(LANHTTPHandlerConfiguration.sessionCookieName)="
            + credentials.cookie + "\r\n"
            + "\(LANHTTPHandlerConfiguration.csrfHeaderName): \(credentials.csrf)\r\n"
            + "\(LANHTTPHandlerConfiguration.attemptRevisionHeaderName): "
            + "\(attemptRevision)\r\n"
            + "Content-Type: application/octet-stream\r\n"
        switch framing {
        case .contentLength:
            head += "Content-Length: \(byteCount)\r\n"
        case .chunked:
            head += "Transfer-Encoding: chunked\r\n"
        }
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8)
    }

    private func sessionCookie(from response: Response) throws -> String {
        guard let header = response.headers["set-cookie"]?.first,
              let first = header.split(separator: ";", maxSplits: 1).first,
              let equals = first.firstIndex(of: "=") else {
            throw InstalledLANAcceptanceProbeError.malformedResponse
        }
        return String(first[first.index(after: equals)...])
    }

    private func connectedSocket(to endpoint: LANServerEndpoint) throws -> Int32 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw InstalledLANAcceptanceProbeError.socketFailure(.create)
        }
        do {
            var noSignal: Int32 = 1
            guard setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &noSignal,
                socklen_t(MemoryLayout<Int32>.size)
            ) == 0 else {
                throw InstalledLANAcceptanceProbeError.socketFailure(.configure)
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
            ) == 0 else {
                throw InstalledLANAcceptanceProbeError.socketFailure(.configure)
            }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(endpoint.port).bigEndian
            guard inet_pton(AF_INET, endpoint.host, &address.sin_addr) == 1 else {
                throw InstalledLANAcceptanceProbeError.socketFailure(.address)
            }
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(
                        descriptor,
                        $0,
                        socklen_t(MemoryLayout<sockaddr_in>.size)
                    )
                }
            }
            guard result == 0 else {
                throw InstalledLANAcceptanceProbeError.socketFailure(.connect)
            }
            return descriptor
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    private func canConnect(to endpoint: LANServerEndpoint) -> Bool {
        guard let descriptor = try? connectedSocket(to: endpoint) else { return false }
        _ = Darwin.close(descriptor)
        return true
    }

    private func sendAll(_ data: Data, through descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let sent = Darwin.send(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset,
                    0
                )
                if sent > 0 {
                    offset += sent
                } else if sent < 0, errno == EINTR {
                    continue
                } else {
                    throw InstalledLANAcceptanceProbeError.socketFailure(.send)
                }
            }
        }
    }

    private func readResponse(from descriptor: Int32) throws -> Response {
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        while true {
            let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
            if count > 0 {
                bytes.append(buffer, count: count)
                guard bytes.count <= 1 * 1_024 * 1_024 else {
                    throw InstalledLANAcceptanceProbeError.responseTooLarge
                }
            } else if count == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                throw InstalledLANAcceptanceProbeError.socketFailure(.receive)
            }
        }
        let separator = Data([13, 10, 13, 10])
        guard let range = bytes.range(of: separator),
              let head = String(data: bytes[..<range.lowerBound], encoding: .utf8),
              let statusText = head.components(separatedBy: "\r\n").first?
                .split(separator: " ", maxSplits: 2).dropFirst().first,
              let status = Int(statusText) else {
            throw InstalledLANAcceptanceProbeError.malformedResponse
        }
        var headers: [String: [String]] = [:]
        for line in head.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else {
                throw InstalledLANAcceptanceProbeError.malformedResponse
            }
            headers[String(line[..<colon]).lowercased(), default: []].append(
                line[line.index(after: colon)...]
                    .trimmingCharacters(in: .whitespaces)
            )
        }
        let body = Data(bytes[range.upperBound...])
        if let lengthText = headers["content-length"]?.first,
           let length = Int(lengthText),
           length != body.count {
            throw InstalledLANAcceptanceProbeError.malformedResponse
        }
        return Response(status: status, headers: headers, body: body)
    }

    private func socketObservedRemoteClose(_ descriptor: Int32) -> Bool {
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )
        var byte: UInt8 = 0
        let count = Darwin.recv(descriptor, &byte, 1, 0)
        return count == 0 || (count < 0 && (errno == ECONNRESET || errno == ENOTCONN))
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @Sendable () async throws -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while try await condition() == false {
            guard ContinuousClock.now < deadline else {
                throw InstalledLANAcceptanceProbeError.invariantFailed
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private extension Data {
    func chunked(maxByteCount: Int) -> [Data] {
        guard !isEmpty else { return [] }
        return stride(from: 0, to: count, by: maxByteCount).map { offset in
            Data(self[offset..<Swift.min(offset + maxByteCount, count)])
        }
    }
}
