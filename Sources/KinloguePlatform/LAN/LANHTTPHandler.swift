import Foundation
import NIOCore
import NIOHTTP1

public struct LANHTTPBrowserCapability: Equatable, Sendable {
    public let cookieValue: String

    public init(cookieValue: String) {
        self.cookieValue = cookieValue
    }
}

public struct LANHTTPBrowserProof: Equatable, Sendable {
    public let cookieValue: String
    public let csrfToken: String

    public init(cookieValue: String, csrfToken: String) {
        self.cookieValue = cookieValue
        self.csrfToken = csrfToken
    }
}

public struct LANHTTPPairSuccess: Equatable, Sendable {
    public let cookieValue: String
    public let response: LANPairResponse

    public init(cookieValue: String, response: LANPairResponse) {
        self.cookieValue = cookieValue
        self.response = response
    }
}

/// Deliberately small failure vocabulary exposed by the receiver composition.
/// Detailed session, storage and lookup failures never cross the phone boundary.
public enum LANHTTPApplicationFailure: Error, Equatable, Sendable {
    case rejected
    case retryLater
    case sessionEnded
    case conflict
    case unavailable
}

public protocol LANHTTPFileUploadBodySink: Sendable {
    nonisolated func write(_ buffer: ByteBuffer) -> Task<Void, Error>
    func finish() async throws -> LANFileSavedResponse
    func cancel() async
}

public enum LANHTTPFileUploadStart: Sendable {
    case sink(any LANHTTPFileUploadBodySink)
    case alreadySaved(LANFileSavedResponse, expectedByteCount: Int64)
}

/// Application dispatcher used by the protocol boundary. Implementations must
/// authenticate `proof` before mapping remote IDs, consulting retained counts,
/// opening an upload sink or touching the inbox store.
public protocol LANHTTPApplication: Sendable {
    func pair(
        _ request: LANPairRequest,
        from peer: LANTransportPeer
    ) async throws -> LANHTTPPairSuccess

    func restoreFileSession(
        _ capability: LANHTTPBrowserCapability,
        from peer: LANTransportPeer
    ) async throws -> LANFileSessionResponse

    /// Performs credential verification and request-rate admission before the
    /// handler decodes any authenticated request body or exposes remote IDs to
    /// the receiver. The returned value is the only authority accepted by the
    /// typed mutation methods below.
    func authorize(
        _ proof: LANHTTPBrowserProof,
        from peer: LANTransportPeer,
        operation: LANAuthenticatedOperation
    ) async throws -> LANAuthorizedSession

    /// Atomically validates and invalidates the active browser session. The
    /// handler clears the browser cookie only after this succeeds.
    func logout(
        _ proof: LANHTTPBrowserProof,
        from peer: LANTransportPeer
    ) async throws

    func reserveFile(
        _ request: LANReserveFileRequest,
        authorization: LANAuthorizedSession
    ) async throws -> LANReserveFileResponse

    func beginFileUpload(
        remoteFileID: UUID,
        attemptRevision: UInt64,
        declaredByteCount: Int?,
        authorization: LANAuthorizedSession
    ) async throws -> LANHTTPFileUploadStart

    func fileStatus(
        remoteFileID: UUID,
        authorization: LANAuthorizedSession
    ) async throws -> LANPhoneFileStatus

    func cancelFile(
        remoteFileID: UUID,
        attemptRevision: UInt64,
        authorization: LANAuthorizedSession
    ) async throws -> LANFileCancelResponse
}

public extension LANHTTPApplication {
    func restoreFileSession(
        _ capability: LANHTTPBrowserCapability,
        from peer: LANTransportPeer
    ) async throws -> LANFileSessionResponse {
        throw LANHTTPApplicationFailure.unavailable
    }

    func reserveFile(
        _ request: LANReserveFileRequest,
        authorization: LANAuthorizedSession
    ) async throws -> LANReserveFileResponse {
        throw LANHTTPApplicationFailure.unavailable
    }

    func beginFileUpload(
        remoteFileID: UUID,
        attemptRevision: UInt64,
        declaredByteCount: Int?,
        authorization: LANAuthorizedSession
    ) async throws -> LANHTTPFileUploadStart {
        throw LANHTTPApplicationFailure.unavailable
    }

    func fileStatus(
        remoteFileID: UUID,
        authorization: LANAuthorizedSession
    ) async throws -> LANPhoneFileStatus {
        throw LANHTTPApplicationFailure.unavailable
    }

    func cancelFile(
        remoteFileID: UUID,
        attemptRevision: UInt64,
        authorization: LANAuthorizedSession
    ) async throws -> LANFileCancelResponse {
        throw LANHTTPApplicationFailure.unavailable
    }
}

public enum LANHTTPLogRoute: String, Equatable, Sendable {
    case unknown
    case asset
    case pair
    case session
    case logout
    case upload
    case reserveFile
    case fileStatus
    case cancelFile
}

public enum LANHTTPLogReason: String, Equatable, Sendable {
    case malformedProtocol
    case requestLineTooLarge
    case invalidTarget
    case invalidAuthority
    case unsupportedRequest
    case invalidFraming
    case invalidOrigin
    case invalidCredentials
    case bodyTooLarge
    case deadlineExceeded
    case applicationRejected
    case applicationUnavailable
    case responseSent
    case disconnected
}

/// Allowlisted diagnostics only. No event carries a target, header, peer,
/// credential, filename, remote identifier, digest or underlying error text.
public struct LANHTTPLogEvent: Equatable, Sendable {
    public let route: LANHTTPLogRoute
    public let reason: LANHTTPLogReason
    public let statusClass: Int?

    public init(
        route: LANHTTPLogRoute,
        reason: LANHTTPLogReason,
        statusClass: Int? = nil
    ) {
        self.route = route
        self.reason = reason
        self.statusClass = statusClass
    }
}

public struct LANHTTPHandlerConfiguration: Sendable {
    public static let sessionCookieName = "KinlogueLANSession"
    public static let csrfHeaderName = "X-Kinlogue-CSRF"
    public static let attemptRevisionHeaderName = "X-Kinlogue-Attempt-Revision"

    public let authorityProvider: @Sendable () -> String?
    public let assetCatalog: LANPhoneAssetCatalog
    public let application: any LANHTTPApplication
    public let peer: LANTransportPeer
    public let logger: @Sendable (LANHTTPLogEvent) -> Void
    public let headerDeadline: TimeAmount
    public let progressDeadline: TimeAmount
    public let JSONBodyDeadline: TimeAmount
    public let uploadBodyDeadline: TimeAmount

    public init(
        authorityProvider: @escaping @Sendable () -> String?,
        assetCatalog: LANPhoneAssetCatalog,
        application: any LANHTTPApplication,
        peer: LANTransportPeer,
        logger: @escaping @Sendable (LANHTTPLogEvent) -> Void = { _ in },
        headerDeadline: TimeAmount = .seconds(15),
        progressDeadline: TimeAmount = .seconds(30),
        JSONBodyDeadline: TimeAmount = .seconds(30),
        uploadBodyDeadline: TimeAmount = .minutes(15)
    ) {
        self.authorityProvider = authorityProvider
        self.assetCatalog = assetCatalog
        self.application = application
        self.peer = peer
        self.logger = logger
        self.headerDeadline = headerDeadline
        self.progressDeadline = progressDeadline
        self.JSONBodyDeadline = JSONBodyDeadline
        self.uploadBodyDeadline = uploadBodyDeadline
    }

    public init(
        canonicalAuthority: String,
        assetCatalog: LANPhoneAssetCatalog,
        application: any LANHTTPApplication,
        peer: LANTransportPeer,
        logger: @escaping @Sendable (LANHTTPLogEvent) -> Void = { _ in },
        headerDeadline: TimeAmount = .seconds(15),
        progressDeadline: TimeAmount = .seconds(30),
        JSONBodyDeadline: TimeAmount = .seconds(30),
        uploadBodyDeadline: TimeAmount = .minutes(15)
    ) {
        self.init(
            authorityProvider: { canonicalAuthority },
            assetCatalog: assetCatalog,
            application: application,
            peer: peer,
            logger: logger,
            headerDeadline: headerDeadline,
            progressDeadline: progressDeadline,
            JSONBodyDeadline: JSONBodyDeadline,
            uploadBodyDeadline: uploadBodyDeadline
        )
    }
}

/// Shared production/real-channel pipeline configuration. The decoder's own
/// limits are necessary but insufficient for the request target because NIO
/// emits the URI only after parsing the complete request head; the bounded raw
/// request-line guard therefore runs immediately before it.
public enum LANHTTPPipeline {
    public static let maximumHeaderFieldCount = 32
    public static let maximumHeaderByteCount = 16 * 1_024
    public static let maximumTargetByteCount = 2 * 1_024
    public static let maximumJSONBodyByteCount = 64 * 1_024
    static let maximumRequestLineByteCount = maximumTargetByteCount + 32
    static let receiveBufferByteCount = 16 * 1_024

    public static var decoderLimitConfiguration: NIOHTTPDecoderLimitConfiguration {
        var limits = NIOHTTPDecoderLimitConfiguration()
        limits.maxHeaderFieldCount = maximumHeaderFieldCount
        limits.maxHeaderFieldSize = maximumHeaderByteCount
        limits.maxHeaderListSize = maximumHeaderByteCount
        return limits
    }

    public static func configure(
        channel: any Channel,
        peer: LANTransportPeer,
        authorityProvider: @escaping @Sendable () -> String?,
        assetCatalog: LANPhoneAssetCatalog,
        application: any LANHTTPApplication,
        logger: @escaping @Sendable (LANHTTPLogEvent) -> Void = { _ in }
    ) -> EventLoopFuture<Void> {
        let configuration = LANHTTPHandlerConfiguration(
            authorityProvider: authorityProvider,
            assetCatalog: assetCatalog,
            application: application,
            peer: peer,
            logger: logger
        )
        return configure(channel: channel, configuration: configuration)
    }

    public static func configure(
        channel: any Channel,
        configuration: LANHTTPHandlerConfiguration
    ) -> EventLoopFuture<Void> {
        channel.setOption(ChannelOptions.autoRead, value: false).flatMap {
            channel.setOption(ChannelOptions.maxMessagesPerRead, value: 1)
        }.flatMap {
            channel.setOption(
                ChannelOptions.recvAllocator,
                value: FixedSizeRecvByteBufferAllocator(
                    capacity: receiveBufferByteCount
                )
            )
        }.flatMap {
            addHandlers(channel: channel, configuration: configuration)
        }
    }

    static func addHandlers(
        channel: any Channel,
        configuration: LANHTTPHandlerConfiguration
    ) -> EventLoopFuture<Void> {
        channel.pipeline.addHandler(
            LANHTTPRequestLineLimitHandler(
                maximumByteCount: maximumRequestLineByteCount
            )
        ).flatMap {
            channel.pipeline.configureHTTPServerPipeline(
                withPipeliningAssistance: false,
                withServerUpgrade: nil,
                withErrorHandling: false,
                withOutboundHeaderValidation: true,
                withEncoderConfiguration: .init(),
                withDecoderLimitConfiguration: decoderLimitConfiguration
            )
        }.flatMap {
            channel.pipeline.addHandler(
                LANHTTPHandler(configuration: configuration)
            )
        }
    }
}

private enum LANHTTPBoundaryError: Error, Equatable, Sendable {
    case requestLineTooLarge
    case malformedProtocol
}

// SAFETY: SwiftNIO invokes this handler and all of its mutable request-line
// state only on the owning channel event loop.
final class LANHTTPRequestLineLimitHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private let maximumByteCount: Int
    private var requestLineByteCount = 0
    private var previousByteWasCarriageReturn = false
    private var requestLineComplete = false
    private var failed = false

    init(maximumByteCount: Int) {
        precondition(maximumByteCount > 0)
        self.maximumByteCount = maximumByteCount
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !failed else { return }
        let buffer = unwrapInboundIn(data)
        if !requestLineComplete {
            for byte in buffer.readableBytesView {
                requestLineByteCount += 1
                guard requestLineByteCount != 1 || (byte != 0x0D && byte != 0x0A) else {
                    failed = true
                    context.fireErrorCaught(LANHTTPBoundaryError.malformedProtocol)
                    return
                }
                guard requestLineByteCount <= maximumByteCount else {
                    failed = true
                    context.fireErrorCaught(LANHTTPBoundaryError.requestLineTooLarge)
                    return
                }
                if previousByteWasCarriageReturn, byte == 0x0A {
                    requestLineComplete = true
                    break
                }
                previousByteWasCarriageReturn = byte == 0x0D
            }
        }
        context.fireChannelRead(wrapInboundOut(buffer))
    }
}

private enum LANHTTPRoute: Sendable {
    case asset(LANPhoneAsset)
    case pair
    case session
    case logout
    case reserveFile
    case uploadFile(remoteFileID: UUID)
    case fileStatus(remoteFileID: UUID)
    case cancelFile(remoteFileID: UUID)

    var logRoute: LANHTTPLogRoute {
        switch self {
        case .asset: .asset
        case .pair: .pair
        case .session: .session
        case .logout: .logout
        case .reserveFile: .reserveFile
        case .uploadFile: .upload
        case .fileStatus: .fileStatus
        case .cancelFile: .cancelFile
        }
    }

    var bodyKind: LANHTTPBodyKind {
        switch self {
        case .asset, .session, .logout, .fileStatus, .cancelFile: .none
        case .pair, .reserveFile: .json
        case .uploadFile: .upload
        }
    }

    var requiresMutationProof: Bool {
        switch self {
        case .logout, .reserveFile, .uploadFile, .fileStatus, .cancelFile:
            true
        case .asset, .pair, .session: false
        }
    }
}

private enum LANHTTPBodyKind: Sendable {
    case none
    case json
    case upload
}

private struct LANHTTPValidatedHead: Sendable {
    let route: LANHTTPRoute
    let declaredByteCount: Int?
    let isChunked: Bool
    let capability: LANHTTPBrowserCapability?
    let proof: LANHTTPBrowserProof?
    let attemptRevision: UInt64?
}

private enum LANHTTPPhase: Sendable {
    case awaitingHead
    case receivingJSON
    case openingUpload
    case receivingUpload
    case writingUpload
    case discardingReplayUpload
    case finishing
    case responding
    case poisoned
    case closed
}

private enum LANHTTPResponseStatus: Int, Sendable {
    case ok = 200
    case created = 201
    case noContent = 204
    case badRequest = 400
    case unauthorized = 401
    case forbidden = 403
    case notFound = 404
    case conflict = 409
    case payloadTooLarge = 413
    case tooManyRequests = 429
    case internalServerError = 500
    case serviceUnavailable = 503
}

private struct LANHTTPWireResponse: Sendable {
    let status: LANHTTPResponseStatus
    let body: Data
    let contentType: String
    let cookieMutation: LANHTTPCookieMutation?

    static func json(
        status: LANHTTPResponseStatus = .ok,
        body: Data,
        cookieMutation: LANHTTPCookieMutation? = nil
    ) -> Self {
        .init(
            status: status,
            body: body,
            contentType: "application/json; charset=utf-8",
            cookieMutation: cookieMutation
        )
    }
}

private enum LANHTTPCookieMutation: Sendable {
    case set(String)
    case clear
}

/// NIO confines a context to its channel event loop. Async application work
/// carries only this unchecked reference and always hops back onto that event
/// loop before dereferencing it.
// SAFETY: The context is immutable here and every dereference occurs in an
// operation already scheduled on `context.eventLoop`.
private final class LANHTTPContextReference: @unchecked Sendable {
    let context: ChannelHandlerContext

    init(_ context: ChannelHandlerContext) {
        self.context = context
    }
}

/// Long-running application tasks retain this box, never the channel context.
/// A disconnected channel can therefore release its pipeline even when an
/// application implementation does not promptly observe task cancellation.
// SAFETY: Cross-executor callers only take a weak reference and schedule work;
// the resulting strong context is dereferenced on its event loop.
private final class LANHTTPWeakContextReference: @unchecked Sendable {
    private weak var context: ChannelHandlerContext?

    init(_ context: ChannelHandlerContext) {
        self.context = context
    }

    @discardableResult
    func execute(
        _ operation: @escaping @Sendable (ChannelHandlerContext) -> Void
    ) -> Bool {
        guard let context else { return false }
        let contextReference = LANHTTPContextReference(context)
        context.eventLoop.execute {
            operation(contextReference.context)
        }
        return true
    }
}

// SAFETY: SwiftNIO confines every mutable handler field and callback to the
// channel event loop; async completions hop back through the context wrapper.
private final class LANHTTPHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundIn = HTTPServerResponsePart
    typealias OutboundOut = HTTPServerResponsePart

    private static let securityHeaders: [(String, String)] = [
        ("Cache-Control", "no-store"),
        ("Pragma", "no-cache"),
        ("Referrer-Policy", "no-referrer"),
        ("X-Content-Type-Options", "nosniff"),
        ("X-Frame-Options", "DENY"),
        ("Cross-Origin-Resource-Policy", "same-origin"),
        (
            "Content-Security-Policy",
            "default-src 'none'; base-uri 'none'; object-src 'none'; "
                + "frame-ancestors 'none'; form-action 'self'; connect-src 'self'; "
                + "script-src 'self'; style-src 'self'; img-src 'self'"
        ),
    ]

    private let configuration: LANHTTPHandlerConfiguration
    private var phase: LANHTTPPhase = .awaitingHead
    private var route: LANHTTPRoute?
    private var validatedHead: LANHTTPValidatedHead?
    private var JSONBody = Data()
    private var fileUploadSink: (any LANHTTPFileUploadBodySink)?
    private var replayFileUploadResponse: LANFileSavedResponse?
    private var replayFileUploadExpectedByteCount: Int64?
    private var replayUploadByteCount: Int64 = 0
    private var deferredUploadBodies: [ByteBuffer] = []
    private var deferredUploadByteCount = 0
    private var deferredEnd = false
    private var readOutstanding = false
    private var activeTask: Task<Void, Never>?
    private var headerTimer: Scheduled<Void>?
    private var progressTimer: Scheduled<Void>?
    private var absoluteBodyTimer: Scheduled<Void>?

    init(configuration: LANHTTPHandlerConfiguration) {
        self.configuration = configuration
    }

    func channelActive(context: ChannelHandlerContext) {
        scheduleHeaderDeadline(context: context)
        requestRead(context: context)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let head):
            receiveHead(head, context: context)
        case .body(let buffer):
            receiveBody(buffer, context: context)
        case .end(let trailers):
            receiveEnd(trailers, context: context)
        }
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        readOutstanding = false
        if needsMoreNetworkInput {
            requestRead(context: context)
        }
        context.fireChannelReadComplete()
    }

    func channelInactive(context: ChannelHandlerContext) {
        phase = .closed
        cancelTimers()
        activeTask?.cancel()
        activeTask = nil
        cancelUploadSink()
        configuration.logger(.init(
            route: route?.logRoute ?? .unknown,
            reason: .disconnected
        ))
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        let reason: LANHTTPLogReason = error is LANHTTPBoundaryError
            ? ((error as? LANHTTPBoundaryError) == .requestLineTooLarge
                ? .requestLineTooLarge
                : .malformedProtocol)
            : .malformedProtocol
        reject(
            status: .badRequest,
            reason: reason,
            context: context
        )
    }

    private var needsMoreNetworkInput: Bool {
        switch phase {
        case .awaitingHead, .receivingJSON, .receivingUpload,
             .discardingReplayUpload:
            return !deferredEnd
        case .openingUpload, .writingUpload, .finishing, .responding,
             .poisoned, .closed:
            return false
        }
    }

    private func receiveHead(
        _ head: HTTPRequestHead,
        context: ChannelHandlerContext
    ) {
        guard phase == .awaitingHead else {
            poisonPipelinedConnection(context: context)
            return
        }
        headerTimer?.cancel()
        headerTimer = nil

        let validated: LANHTTPValidatedHead
        do {
            validated = try validate(head)
        } catch let failure as LANHTTPValidationFailure {
            reject(
                status: failure.status,
                reason: failure.reason,
                context: context
            )
            return
        } catch {
            reject(status: .badRequest, reason: .unsupportedRequest, context: context)
            return
        }

        route = validated.route
        validatedHead = validated
        switch validated.route.bodyKind {
        case .none:
            phase = .finishing
            scheduleNoBodyRequest(validated, context: context)
        case .json:
            phase = .receivingJSON
            scheduleBodyDeadlines(
                absolute: configuration.JSONBodyDeadline,
                context: context
            )
        case .upload:
            phase = .openingUpload
            scheduleBodyDeadlines(
                absolute: configuration.uploadBodyDeadline,
                context: context
            )
            scheduleOpenUpload(validated, context: context)
        }
    }

    private func receiveBody(
        _ buffer: ByteBuffer,
        context: ChannelHandlerContext
    ) {
        guard buffer.readableBytes > 0 else { return }
        switch phase {
        case .receivingJSON:
            let sum = JSONBody.count.addingReportingOverflow(buffer.readableBytes)
            guard !sum.overflow,
                  sum.partialValue <= LANHTTPPipeline.maximumJSONBodyByteCount else {
                reject(
                    status: .payloadTooLarge,
                    reason: .bodyTooLarge,
                    context: context
                )
                return
            }
            var copy = buffer
            if let bytes = copy.readBytes(length: copy.readableBytes) {
                JSONBody.append(contentsOf: bytes)
            }
            resetProgressDeadline(context: context)

        case .openingUpload, .writingUpload:
            guard enqueueDeferredUploadBody(buffer) else {
                reject(
                    status: .serviceUnavailable,
                    reason: .applicationUnavailable,
                    context: context
                )
                return
            }

        case .receivingUpload:
            writeUploadBody(buffer, context: context)

        case .discardingReplayUpload:
            let byteCount = Int64(buffer.readableBytes)
            let sum = replayUploadByteCount.addingReportingOverflow(byteCount)
            guard !sum.overflow else {
                reject(
                    status: .badRequest,
                    reason: .invalidFraming,
                    context: context
                )
                return
            }
            replayUploadByteCount = sum.partialValue
            resetProgressDeadline(context: context)

        case .awaitingHead, .finishing, .responding, .poisoned, .closed:
            reject(
                status: .badRequest,
                reason: .invalidFraming,
                context: context
            )
        }
    }

    private func receiveEnd(
        _ trailers: HTTPHeaders?,
        context: ChannelHandlerContext
    ) {
        guard trailers == nil else {
            reject(status: .badRequest, reason: .invalidFraming, context: context)
            return
        }
        switch phase {
        case .receivingJSON:
            phase = .finishing
            deferredEnd = true
            progressTimer?.cancel()
            progressTimer = nil
            absoluteBodyTimer?.cancel()
            absoluteBodyTimer = nil
            scheduleJSONRequest(context: context)

        case .openingUpload, .writingUpload:
            guard !deferredEnd else {
                reject(status: .badRequest, reason: .invalidFraming, context: context)
                return
            }
            deferredEnd = true

        case .receivingUpload:
            deferredEnd = true
            finishUploadWhenPipelineTurnCompletes(context: context)

        case .discardingReplayUpload:
            deferredEnd = true
            finishReplayWhenPipelineTurnCompletes(context: context)

        case .finishing, .responding, .poisoned, .closed:
            // A no-body request already moved to finishing at its head. Its
            // decoder-generated end is expected and side effects remain
            // deferred to the next event-loop turn.
            break

        case .awaitingHead:
            reject(status: .badRequest, reason: .invalidFraming, context: context)
        }
    }

    private func scheduleNoBodyRequest(
        _ head: LANHTTPValidatedHead,
        context: ChannelHandlerContext
    ) {
        let contextReference = LANHTTPContextReference(context)
        context.eventLoop.execute { [weak self, contextReference] in
            guard let self, self.phase == .finishing else { return }
            switch head.route {
            case .asset(let asset):
                let payload = self.configuration.assetCatalog.payload(for: asset)
                self.send(
                    .init(
                        status: .ok,
                        body: payload.data,
                        contentType: payload.contentType,
                        cookieMutation: nil
                    ),
                    context: contextReference.context
                )
            case .session:
                guard let capability = head.capability else {
                    self.reject(
                        status: .unauthorized,
                        reason: .invalidCredentials,
                        context: contextReference.context
                    )
                    return
                }
                self.scheduleAbsoluteDeadline(
                    in: self.configuration.JSONBodyDeadline,
                    context: contextReference.context
                )
                let application = self.configuration.application
                let peer = self.configuration.peer
                self.runApplicationTask(context: contextReference.context) {
                    let response = try await application.restoreFileSession(
                        capability,
                        from: peer
                    )
                    return try Self.encoded(response)
                }
            case .logout:
                guard let proof = head.proof else {
                    self.reject(
                        status: .unauthorized,
                        reason: .invalidCredentials,
                        context: contextReference.context
                    )
                    return
                }
                self.scheduleAbsoluteDeadline(
                    in: self.configuration.JSONBodyDeadline,
                    context: contextReference.context
                )
                let application = self.configuration.application
                let peer = self.configuration.peer
                self.runApplicationTask(context: contextReference.context) {
                    try await application.logout(
                        proof,
                        from: peer
                    )
                    return .json(
                        status: .noContent,
                        body: Data(),
                        cookieMutation: .clear
                    )
                }
            case let .fileStatus(remoteFileID):
                guard let proof = head.proof else {
                    self.reject(
                        status: .unauthorized,
                        reason: .invalidCredentials,
                        context: contextReference.context
                    )
                    return
                }
                self.scheduleAbsoluteDeadline(
                    in: self.configuration.JSONBodyDeadline,
                    context: contextReference.context
                )
                let application = self.configuration.application
                let peer = self.configuration.peer
                self.runApplicationTask(context: contextReference.context) {
                    let authorization = try await application.authorize(
                        proof,
                        from: peer,
                        operation: .nonBody
                    )
                    return try Self.encoded(try await application.fileStatus(
                        remoteFileID: remoteFileID,
                        authorization: authorization
                    ))
                }
            case let .cancelFile(remoteFileID):
                guard let proof = head.proof,
                      let attemptRevision = head.attemptRevision else {
                    self.reject(
                        status: .unauthorized,
                        reason: .invalidCredentials,
                        context: contextReference.context
                    )
                    return
                }
                self.scheduleAbsoluteDeadline(
                    in: self.configuration.JSONBodyDeadline,
                    context: contextReference.context
                )
                let application = self.configuration.application
                let peer = self.configuration.peer
                self.runApplicationTask(context: contextReference.context) {
                    let authorization = try await application.authorize(
                        proof,
                        from: peer,
                        operation: .nonBody
                    )
                    return try Self.encoded(try await application.cancelFile(
                        remoteFileID: remoteFileID,
                        attemptRevision: attemptRevision,
                        authorization: authorization
                    ))
                }
            default:
                self.reject(
                    status: .badRequest,
                    reason: .unsupportedRequest,
                    context: contextReference.context
                )
            }
        }
    }

    private func scheduleJSONRequest(context: ChannelHandlerContext) {
        let contextReference = LANHTTPContextReference(context)
        context.eventLoop.execute { [weak self, contextReference] in
            guard let self,
                  self.phase == .finishing,
                  let validated = self.validatedHead else { return }
            let body = self.JSONBody
            let application = self.configuration.application
            let peer = self.configuration.peer
            let proof = validated.proof
            self.runApplicationTask(context: contextReference.context) {
                switch validated.route {
                case .pair:
                    let request = try LANHTTPJSONCodec.decode(
                        LANPairRequest.self,
                        from: body
                    )
                    let paired = try await application.pair(request, from: peer)
                    guard Self.isValidToken(paired.cookieValue) else {
                        throw LANHTTPApplicationFailure.unavailable
                    }
                    return try Self.encoded(
                        paired.response,
                        cookieMutation: .set(paired.cookieValue)
                    )

                case .reserveFile:
                    guard let proof else {
                        throw LANHTTPApplicationFailure.sessionEnded
                    }
                    let authorization = try await application.authorize(
                        proof,
                        from: peer,
                        operation: .nonBody
                    )
                    let request = try LANHTTPJSONCodec.decode(
                        LANReserveFileRequest.self,
                        from: body
                    )
                    let response = try await application.reserveFile(
                        request,
                        authorization: authorization
                    )
                    return try Self.encoded(response, status: .created)

                default:
                    throw LANHTTPApplicationFailure.rejected
                }
            }
        }
    }

    private func scheduleOpenUpload(
        _ head: LANHTTPValidatedHead,
        context: ChannelHandlerContext
    ) {
        let contextReference = LANHTTPContextReference(context)
        context.eventLoop.execute { [weak self, contextReference] in
            guard let self, self.phase == .openingUpload else { return }
            guard let expectedRevision = head.attemptRevision else {
                self.reject(
                    status: .badRequest,
                    reason: .unsupportedRequest,
                    context: contextReference.context
                )
                return
            }
            let proof: LANHTTPBrowserProof
            do {
                proof = try self.requiredProof(head)
            } catch {
                self.reject(
                    status: .unauthorized,
                    reason: .invalidCredentials,
                    context: contextReference.context
                )
                return
            }

            let application = self.configuration.application
            let peer = self.configuration.peer
            let weakContextReference = LANHTTPWeakContextReference(
                contextReference.context
            )
            self.activeTask = Task { [weak self, weakContextReference] in
                let result: Result<LANHTTPFileUploadStart, Error>
                do {
                    let authorization = try await application.authorize(
                        proof,
                        from: peer,
                        operation: .body
                    )
                    switch head.route {
                    case let .uploadFile(remoteFileID):
                        result = .success(try await application.beginFileUpload(
                            remoteFileID: remoteFileID,
                            attemptRevision: expectedRevision,
                            declaredByteCount: head.declaredByteCount,
                            authorization: authorization
                        ))
                    default:
                        throw LANHTTPApplicationFailure.rejected
                    }
                } catch {
                    result = .failure(error)
                }
                let scheduled = weakContextReference.execute { [weak self] context in
                    self?.openedUpload(
                        result,
                        context: context
                    )
                }
                if !scheduled, case let .success(.sink(sink)) = result {
                    await sink.cancel()
                }
            }
        }
    }

    private func openedUpload(
        _ result: Result<LANHTTPFileUploadStart, Error>,
        context: ChannelHandlerContext
    ) {
        activeTask = nil
        guard phase == .openingUpload else {
            if case let .success(opened) = result {
                if case let .sink(sink) = opened { Task { await sink.cancel() } }
            }
            return
        }
        switch result {
        case .success(.sink(let sink)):
            fileUploadSink = sink
            phase = .receivingUpload
            resetProgressDeadline(context: context)
            drainDeferredUploadBodies(context: context)
        case let .success(.alreadySaved(response, expectedByteCount)):
            replayFileUploadResponse = response
            replayFileUploadExpectedByteCount = expectedByteCount
            replayUploadByteCount = Int64(deferredUploadByteCount)
            phase = .discardingReplayUpload
            deferredUploadBodies.removeAll(keepingCapacity: false)
            deferredUploadByteCount = 0
            resetProgressDeadline(context: context)
            if deferredEnd {
                finishReplayWhenPipelineTurnCompletes(context: context)
            } else if !readOutstanding {
                requestRead(context: context)
            }
        case .failure(let error):
            sendApplicationFailure(error, context: context)
        }
    }

    private func writeUploadBody(
        _ buffer: ByteBuffer,
        context: ChannelHandlerContext
    ) {
        guard let fileUploadSink else {
            reject(
                status: .serviceUnavailable,
                reason: .applicationUnavailable,
                context: context
            )
            return
        }
        phase = .writingUpload
        resetProgressDeadline(context: context)
        let write = fileUploadSink.write(buffer)
        let contextReference = LANHTTPWeakContextReference(context)
        activeTask = Task { [weak self, contextReference] in
            let result = await write.result
            contextReference.execute { [weak self] context in
                self?.finishedUploadWrite(
                    result,
                    context: context
                )
            }
        }
    }

    private func finishedUploadWrite(
        _ result: Result<Void, Error>,
        context: ChannelHandlerContext
    ) {
        activeTask = nil
        guard phase == .writingUpload else { return }
        switch result {
        case .success:
            phase = .receivingUpload
            resetProgressDeadline(context: context)
            drainDeferredUploadBodies(context: context)
        case .failure:
            reject(
                status: .serviceUnavailable,
                reason: .applicationUnavailable,
                context: context
            )
        }
    }

    private func enqueueDeferredUploadBody(_ buffer: ByteBuffer) -> Bool {
        let sum = deferredUploadByteCount.addingReportingOverflow(
            buffer.readableBytes
        )
        guard !sum.overflow,
              sum.partialValue <= LANHTTPPipeline.receiveBufferByteCount,
              deferredUploadBodies.count < 64 else {
            return false
        }
        deferredUploadBodies.append(buffer)
        deferredUploadByteCount = sum.partialValue
        return true
    }

    private func drainDeferredUploadBodies(context: ChannelHandlerContext) {
        guard phase == .receivingUpload else { return }
        if !deferredUploadBodies.isEmpty {
            let next = deferredUploadBodies.removeFirst()
            deferredUploadByteCount -= next.readableBytes
            writeUploadBody(next, context: context)
            return
        }
        if deferredEnd {
            finishUploadWhenPipelineTurnCompletes(context: context)
        } else if !readOutstanding {
            requestRead(context: context)
        }
    }

    private func finishUploadWhenPipelineTurnCompletes(
        context: ChannelHandlerContext
    ) {
        guard phase == .receivingUpload,
              deferredUploadBodies.isEmpty else { return }
        phase = .finishing
        let contextReference = LANHTTPContextReference(context)
        context.eventLoop.execute { [weak self, contextReference] in
            guard let self, self.phase == .finishing else { return }
            let fileSink = self.fileUploadSink
            guard let fileSink else { return }
            let weakContextReference = LANHTTPWeakContextReference(
                contextReference.context
            )
            self.activeTask = Task { [weak self, weakContextReference] in
                let result: Result<LANFileSavedResponse, Error>
                do {
                    result = .success(try await fileSink.finish())
                } catch {
                    result = .failure(error)
                }
                weakContextReference.execute { [weak self] context in
                    guard let self, self.phase == .finishing else { return }
                    self.activeTask = nil
                    switch result {
                    case .success(let response):
                        self.fileUploadSink = nil
                        do {
                            self.send(
                                try Self.encoded(response),
                                context: context
                            )
                        } catch {
                            self.reject(
                                status: .internalServerError,
                                reason: .applicationUnavailable,
                                context: context
                            )
                        }
                    case .failure:
                        self.reject(
                            status: .serviceUnavailable,
                            reason: .applicationUnavailable,
                            context: context
                        )
                    }
                }
            }
        }
    }

    private func finishReplayWhenPipelineTurnCompletes(
        context: ChannelHandlerContext
    ) {
        guard phase == .discardingReplayUpload else { return }
        let fileResponse = replayFileUploadResponse
        guard let fileResponse else { return }
        phase = .finishing
        let contextReference = LANHTTPContextReference(context)
        context.eventLoop.execute { [weak self, contextReference] in
            guard let self, self.phase == .finishing else { return }
            let expectedByteCount = self.replayFileUploadExpectedByteCount
            guard self.replayUploadByteCount == expectedByteCount else {
                self.reject(
                    status: .conflict,
                    reason: .applicationRejected,
                    context: contextReference.context
                )
                return
            }
            do {
                self.send(
                    try Self.encoded(fileResponse),
                    context: contextReference.context
                )
            } catch {
                self.reject(
                    status: .internalServerError,
                    reason: .applicationUnavailable,
                    context: contextReference.context
                )
            }
        }
    }

    private func runApplicationTask(
        context: ChannelHandlerContext,
        operation: @escaping @Sendable () async throws -> LANHTTPWireResponse
    ) {
        let contextReference = LANHTTPWeakContextReference(context)
        activeTask = Task { [weak self, contextReference] in
            let result: Result<LANHTTPWireResponse, Error>
            do {
                result = .success(try await operation())
            } catch {
                result = .failure(error)
            }
            contextReference.execute { [weak self] context in
                guard let self, self.phase == .finishing else { return }
                self.activeTask = nil
                switch result {
                case .success(let response):
                    self.send(response, context: context)
                case .failure(let error):
                    self.sendApplicationFailure(
                        error,
                        context: context
                    )
                }
            }
        }
    }

    private func requiredProof(
        _ head: LANHTTPValidatedHead
    ) throws -> LANHTTPBrowserProof {
        guard let proof = head.proof else {
            throw LANHTTPApplicationFailure.sessionEnded
        }
        return proof
    }

    private func sendApplicationFailure(
        _ error: Error,
        context: ChannelHandlerContext
    ) {
        if error is LANHTTPJSONError || error is LANHTTPDTOValidationError {
            reject(
                status: .badRequest,
                reason: .unsupportedRequest,
                context: context
            )
            return
        }
        let failure = error as? LANHTTPApplicationFailure ?? .unavailable
        let mapping: (
            status: LANHTTPResponseStatus,
            code: LANHTTPRejectionCode,
            retryable: Bool,
            reason: LANHTTPLogReason
        )
        switch failure {
        case .rejected:
            mapping = (.forbidden, .requestRejected, false, .applicationRejected)
        case .retryLater:
            mapping = (.tooManyRequests, .retryLater, true, .applicationRejected)
        case .sessionEnded:
            mapping = (.unauthorized, .sessionEnded, false, .invalidCredentials)
        case .conflict:
            mapping = (.conflict, .requestRejected, false, .applicationRejected)
        case .unavailable:
            mapping = (.serviceUnavailable, .retryLater, true, .applicationUnavailable)
        }
        let response = LANHTTPRejectionResponse(
            error: mapping.code,
            retryable: mapping.retryable
        )
        do {
            let encoded = try LANHTTPJSONCodec.encode(response)
            configuration.logger(.init(
                route: route?.logRoute ?? .unknown,
                reason: mapping.reason,
                statusClass: mapping.status.rawValue / 100
            ))
            send(
                .json(status: mapping.status, body: encoded),
                context: context
            )
        } catch {
            reject(
                status: .internalServerError,
                reason: .applicationUnavailable,
                context: context
            )
        }
    }

    private func reject(
        status: LANHTTPResponseStatus,
        reason: LANHTTPLogReason,
        context: ChannelHandlerContext
    ) {
        guard phase != .responding,
              phase != .closed,
              phase != .poisoned else { return }
        phase = .poisoned
        cancelTimers()
        activeTask?.cancel()
        activeTask = nil
        cancelUploadSink()
        configuration.logger(.init(
            route: route?.logRoute ?? .unknown,
            reason: reason,
            statusClass: status.rawValue / 100
        ))
        let rejection = LANHTTPRejectionResponse(
            error: status == .unauthorized
                ? .sessionEnded
                : (status == .serviceUnavailable || status == .tooManyRequests
                    ? .retryLater
                    : .requestRejected),
            retryable: status == .serviceUnavailable || status == .tooManyRequests
        )
        let body = (try? LANHTTPJSONCodec.encode(rejection))
            ?? Data(#"{"error":"requestRejected","retryable":false}"#.utf8)
        send(.json(status: status, body: body), context: context)
    }

    private func poisonPipelinedConnection(context: ChannelHandlerContext) {
        reject(status: .badRequest, reason: .invalidFraming, context: context)
    }

    private func cancelUploadSink() {
        let itemSink = fileUploadSink
        fileUploadSink = nil
        if let itemSink { Task { await itemSink.cancel() } }
    }

    private func send(
        _ response: LANHTTPWireResponse,
        context: ChannelHandlerContext
    ) {
        guard phase != .responding, phase != .closed else { return }
        phase = .responding
        cancelTimers()

        var headers = HTTPHeaders()
        headers.add(name: "Connection", value: "close")
        headers.add(name: "Content-Length", value: String(response.body.count))
        headers.add(name: "Content-Type", value: response.contentType)
        for (name, value) in Self.securityHeaders {
            headers.add(name: name, value: value)
        }
        if let mutation = response.cookieMutation {
            switch mutation {
            case .set(let token) where Self.isValidToken(token):
                headers.add(
                    name: "Set-Cookie",
                    value: Self.sessionCookie(token)
                )
            case .clear:
                headers.add(
                    name: "Set-Cookie",
                    value: Self.clearedSessionCookie
                )
            case .set:
                // A malformed application credential is never reflected.
                context.close(promise: nil)
                phase = .closed
                return
            }
        }

        let head = HTTPResponseHead(
            version: .http1_1,
            status: .init(statusCode: response.status.rawValue),
            headers: headers
        )
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        if !response.body.isEmpty {
            var buffer = context.channel.allocator.buffer(
                capacity: response.body.count
            )
            buffer.writeBytes(response.body)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        }
        let promise = context.eventLoop.makePromise(of: Void.self)
        let contextReference = LANHTTPContextReference(context)
        promise.futureResult.whenComplete { [weak self, contextReference] _ in
            self?.phase = .closed
            contextReference.context.close(mode: .all, promise: nil)
        }
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: promise)
        configuration.logger(.init(
            route: route?.logRoute ?? .unknown,
            reason: .responseSent,
            statusClass: response.status.rawValue / 100
        ))
    }

    private func requestRead(context: ChannelHandlerContext) {
        guard !readOutstanding, needsMoreNetworkInput else { return }
        readOutstanding = true
        context.read()
    }

    private func scheduleHeaderDeadline(context: ChannelHandlerContext) {
        let contextReference = LANHTTPContextReference(context)
        headerTimer = context.eventLoop.scheduleTask(
            in: configuration.headerDeadline
        ) { [weak self, contextReference] in
            guard let self, self.phase == .awaitingHead else { return }
            self.reject(
                status: .badRequest,
                reason: .deadlineExceeded,
                context: contextReference.context
            )
        }
    }

    private func scheduleBodyDeadlines(
        absolute: TimeAmount,
        context: ChannelHandlerContext
    ) {
        resetProgressDeadline(context: context)
        scheduleAbsoluteDeadline(in: absolute, context: context)
    }

    private func scheduleAbsoluteDeadline(
        in delay: TimeAmount,
        context: ChannelHandlerContext
    ) {
        absoluteBodyTimer?.cancel()
        let contextReference = LANHTTPContextReference(context)
        absoluteBodyTimer = context.eventLoop.scheduleTask(in: delay) {
            [weak self, contextReference] in
            guard let self,
                  self.phase != .responding,
                  self.phase != .closed else { return }
            self.reject(
                status: .badRequest,
                reason: .deadlineExceeded,
                context: contextReference.context
            )
        }
    }

    private func resetProgressDeadline(context: ChannelHandlerContext) {
        progressTimer?.cancel()
        let contextReference = LANHTTPContextReference(context)
        progressTimer = context.eventLoop.scheduleTask(
            in: configuration.progressDeadline
        ) { [weak self, contextReference] in
            guard let self,
                  self.phase != .finishing,
                  self.phase != .responding,
                  self.phase != .closed else { return }
            self.reject(
                status: .badRequest,
                reason: .deadlineExceeded,
                context: contextReference.context
            )
        }
    }

    private func cancelTimers() {
        headerTimer?.cancel()
        progressTimer?.cancel()
        absoluteBodyTimer?.cancel()
        headerTimer = nil
        progressTimer = nil
        absoluteBodyTimer = nil
    }

    private func validate(
        _ head: HTTPRequestHead
    ) throws -> LANHTTPValidatedHead {
        guard head.version == .http1_1 else {
            throw LANHTTPValidationFailure(
                status: .badRequest,
                reason: .unsupportedRequest
            )
        }
        guard head.uri.utf8.count <= LANHTTPPipeline.maximumTargetByteCount,
              head.uri.hasPrefix("/"),
              !head.uri.hasPrefix("//"),
              !head.uri.contains("?"),
              !head.uri.contains("#") else {
            throw LANHTTPValidationFailure(
                status: .badRequest,
                reason: .invalidTarget
            )
        }

        guard let canonicalAuthority = configuration.authorityProvider(),
              Self.isCanonicalNumericAuthority(canonicalAuthority) else {
            throw LANHTTPValidationFailure(
                status: .serviceUnavailable,
                reason: .applicationUnavailable
            )
        }
        let hosts = head.headers["host"]
        guard hosts.count == 1, hosts[0] == canonicalAuthority else {
            throw LANHTTPValidationFailure(
                status: .badRequest,
                reason: .invalidAuthority
            )
        }

        guard head.headers["expect"].isEmpty,
              head.headers["upgrade"].isEmpty,
              head.headers["trailer"].isEmpty,
              head.headers["te"].isEmpty,
              head.headers["content-encoding"].isEmpty,
              !head.headers[canonicalForm: "connection"].contains(where: {
                  $0.lowercased() == "upgrade"
              }) else {
            throw LANHTTPValidationFailure(
                status: .badRequest,
                reason: .unsupportedRequest
            )
        }

        let route = try Self.route(method: head.method, target: head.uri)
        let framing = try Self.framing(headers: head.headers)
        try Self.validateFraming(
            framing,
            bodyKind: route.bodyKind,
            headers: head.headers
        )
        try Self.validateOrigin(
            headers: head.headers,
            route: route,
            canonicalAuthority: canonicalAuthority
        )

        let cookie: String?
        switch route {
        case .asset, .pair:
            // Pairing must remain a recovery path when a stale or conflicting
            // host-scoped cookie was installed by another local HTTP service.
            cookie = nil
        case .session, .logout, .reserveFile, .uploadFile, .fileStatus, .cancelFile:
            cookie = try Self.capabilityCookie(
                headers: head.headers,
                required: true
            )
        }
        let csrf = try Self.csrfToken(
            headers: head.headers,
            required: route.requiresMutationProof
        )
        let proof: LANHTTPBrowserProof?
        if route.requiresMutationProof {
            guard let cookie, let csrf else {
                throw LANHTTPValidationFailure(
                    status: .unauthorized,
                    reason: .invalidCredentials
                )
            }
            proof = .init(cookieValue: cookie, csrfToken: csrf)
        } else {
            proof = nil
        }

        let attemptRevisionValues = head.headers[
            LANHTTPHandlerConfiguration.attemptRevisionHeaderName
        ]
        let attemptRevision: UInt64?
        if case .uploadFile = route {
            guard attemptRevisionValues.count == 1,
                  let parsed = Self.parseUInt64(attemptRevisionValues[0]) else {
                throw LANHTTPValidationFailure(
                    status: .badRequest,
                    reason: .unsupportedRequest
                )
            }
            attemptRevision = parsed
        } else if case .cancelFile = route {
            guard attemptRevisionValues.count == 1,
                  let parsed = Self.parseUInt64(attemptRevisionValues[0]) else {
                throw LANHTTPValidationFailure(
                    status: .badRequest,
                    reason: .unsupportedRequest
                )
            }
            attemptRevision = parsed
        } else {
            guard attemptRevisionValues.isEmpty else {
                throw LANHTTPValidationFailure(
                    status: .badRequest,
                    reason: .unsupportedRequest
                )
            }
            attemptRevision = nil
        }

        return .init(
            route: route,
            declaredByteCount: framing.contentLength,
            isChunked: framing.isChunked,
            capability: cookie.map(LANHTTPBrowserCapability.init(cookieValue:)),
            proof: proof,
            attemptRevision: attemptRevision
        )
    }

    private static func route(
        method: HTTPMethod,
        target: String
    ) throws -> LANHTTPRoute {
        if method == .GET, let asset = LANPhoneAsset(rawValue: target) {
            return .asset(asset)
        }
        if method == .POST, target == "/api/pair" { return .pair }
        if method == .GET, target == "/api/session" { return .session }
        if method == .POST, target == "/api/session/logout" { return .logout }
        if method == .POST, target == "/api/files/reserve" { return .reserveFile }

        let pieces = target.split(separator: "/", omittingEmptySubsequences: false)
        if pieces.count == 4,
           pieces[0].isEmpty,
           pieces[1] == "api",
           pieces[2] == "files",
           let fileID = canonicalUUID(String(pieces[3])) {
            if method == .PUT { return .uploadFile(remoteFileID: fileID) }
            if method == .GET { return .fileStatus(remoteFileID: fileID) }
        }

        if method == .POST,
           pieces.count == 5,
           pieces[0].isEmpty,
           pieces[1] == "api",
           pieces[2] == "files",
           pieces[4] == "cancel",
           let fileID = canonicalUUID(String(pieces[3])) {
            return .cancelFile(remoteFileID: fileID)
        }

        throw LANHTTPValidationFailure(
            status: .notFound,
            reason: .unsupportedRequest
        )
    }

    private struct Framing {
        let contentLength: Int?
        let isChunked: Bool
    }

    private static func framing(headers: HTTPHeaders) throws -> Framing {
        let lengths = headers["content-length"]
        let transferEncodings = headers["transfer-encoding"]
        guard !(lengths.isEmpty == false && transferEncodings.isEmpty == false),
              lengths.count <= 1,
              transferEncodings.count <= 1 else {
            throw LANHTTPValidationFailure(
                status: .badRequest,
                reason: .invalidFraming
            )
        }

        let length: Int?
        if let raw = lengths.first {
            guard let value = parseInt(raw) else {
                throw LANHTTPValidationFailure(
                    status: .badRequest,
                    reason: .invalidFraming
                )
            }
            length = value
        } else {
            length = nil
        }

        let chunked: Bool
        if !transferEncodings.isEmpty {
            let codings = headers[canonicalForm: "transfer-encoding"]
            guard codings.count == 1,
                  codings[0].lowercased() == "chunked" else {
                throw LANHTTPValidationFailure(
                    status: .badRequest,
                    reason: .invalidFraming
                )
            }
            chunked = true
        } else {
            chunked = false
        }
        return .init(contentLength: length, isChunked: chunked)
    }

    private static func validateFraming(
        _ framing: Framing,
        bodyKind: LANHTTPBodyKind,
        headers: HTTPHeaders
    ) throws {
        switch bodyKind {
        case .none:
            guard !framing.isChunked,
                  framing.contentLength == nil || framing.contentLength == 0 else {
                throw LANHTTPValidationFailure(
                    status: .badRequest,
                    reason: .invalidFraming
                )
            }
        case .json:
            guard framing.contentLength != nil || framing.isChunked,
                  headers["content-type"].count == 1,
                  headers["content-type"][0].lowercased() == "application/json" else {
                throw LANHTTPValidationFailure(
                    status: .badRequest,
                    reason: .invalidFraming
                )
            }
            if let contentLength = framing.contentLength,
               contentLength > LANHTTPPipeline.maximumJSONBodyByteCount {
                throw LANHTTPValidationFailure(
                    status: .payloadTooLarge,
                    reason: .bodyTooLarge
                )
            }
        case .upload:
            guard framing.contentLength != nil || framing.isChunked,
                  headers["content-type"].count == 1,
                  headers["content-type"][0].lowercased()
                    == "application/octet-stream" else {
                throw LANHTTPValidationFailure(
                    status: .badRequest,
                    reason: .invalidFraming
                )
            }
        }
    }

    private static func validateOrigin(
        headers: HTTPHeaders,
        route: LANHTTPRoute,
        canonicalAuthority: String
    ) throws {
        let origins = headers["origin"]
        let expected = "http://\(canonicalAuthority)"
        switch route {
        case .asset:
            guard origins.count <= 1,
                  origins.first.map({ $0 == expected }) ?? true else {
                throw LANHTTPValidationFailure(
                    status: .forbidden,
                    reason: .invalidOrigin
                )
            }
        case .session:
            guard origins.count <= 1,
                  origins.first.map({ $0 == expected }) ?? true else {
                throw LANHTTPValidationFailure(
                    status: .forbidden,
                    reason: .invalidOrigin
                )
            }
        case .pair, .logout, .reserveFile, .uploadFile, .fileStatus, .cancelFile:
            guard origins.count == 1, origins[0] == expected else {
                throw LANHTTPValidationFailure(
                    status: .forbidden,
                    reason: .invalidOrigin
                )
            }
        }
    }

    private static func capabilityCookie(
        headers: HTTPHeaders,
        required: Bool
    ) throws -> String? {
        let cookieHeaders = headers["cookie"]
        if cookieHeaders.isEmpty {
            if required {
                throw LANHTTPValidationFailure(
                    status: .unauthorized,
                    reason: .invalidCredentials
                )
            }
            return nil
        }
        guard cookieHeaders.count == 1 else {
            throw LANHTTPValidationFailure(
                status: .unauthorized,
                reason: .invalidCredentials
            )
        }

        var matches: [String] = []
        for component in cookieHeaders[0].split(separator: ";") {
            let trimmed = component.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let equals = trimmed.firstIndex(of: "=") else { continue }
            let name = String(trimmed[..<equals])
            guard name == LANHTTPHandlerConfiguration.sessionCookieName else { continue }
            let value = String(trimmed[trimmed.index(after: equals)...])
            matches.append(value)
        }
        guard matches.count <= 1,
              matches.first.map(isValidToken) ?? !required else {
            throw LANHTTPValidationFailure(
                status: .unauthorized,
                reason: .invalidCredentials
            )
        }
        return matches.first
    }

    private static func csrfToken(
        headers: HTTPHeaders,
        required: Bool
    ) throws -> String? {
        let values = headers[LANHTTPHandlerConfiguration.csrfHeaderName]
        if values.isEmpty {
            if required {
                throw LANHTTPValidationFailure(
                    status: .unauthorized,
                    reason: .invalidCredentials
                )
            }
            return nil
        }
        guard values.count == 1, isValidToken(values[0]) else {
            throw LANHTTPValidationFailure(
                status: .unauthorized,
                reason: .invalidCredentials
            )
        }
        return values[0]
    }

    private static func canonicalUUID(_ value: String) -> UUID? {
        guard value.utf8.count == 36,
              value == value.lowercased(),
              let id = UUID(uuidString: value),
              id.uuidString.lowercased() == value else {
            return nil
        }
        return id
    }

    private static func parseInt(_ value: String) -> Int? {
        guard !value.isEmpty,
              value.utf8.allSatisfy({ (48...57).contains($0) }) else {
            return nil
        }
        return Int(value)
    }

    private static func parseUInt64(_ value: String) -> UInt64? {
        guard !value.isEmpty,
              value.utf8.allSatisfy({ (48...57).contains($0) }) else {
            return nil
        }
        return UInt64(value)
    }

    private static func isValidToken(_ value: String) -> Bool {
        (22...128).contains(value.utf8.count)
            && value.utf8.allSatisfy {
                (48...57).contains($0)
                    || (65...90).contains($0)
                    || (97...122).contains($0)
                    || $0 == 0x2D
                    || $0 == 0x5F
            }
    }

    private static func isCanonicalNumericAuthority(_ value: String) -> Bool {
        if value.hasPrefix("[") {
            guard let closing = value.firstIndex(of: "]"),
                  value.index(after: closing) < value.endIndex,
                  value[value.index(after: closing)] == ":" else { return false }
            let host = String(value[value.index(after: value.startIndex)..<closing])
            let portStart = value.index(closing, offsetBy: 2)
            let portText = String(value[portStart...])
            guard case .v6 = LANIPAddress.parseCanonical(host),
                  let port = parseInt(portText),
                  (1...65_535).contains(port) else { return false }
            return value == "[\(host)]:\(port)"
        }

        guard value.filter({ $0 == ":" }).count == 1,
              let separator = value.lastIndex(of: ":") else { return false }
        let host = String(value[..<separator])
        let portText = String(value[value.index(after: separator)...])
        guard case .v4 = LANIPAddress.parseCanonical(host),
              let port = parseInt(portText),
              (1...65_535).contains(port) else { return false }
        return value == "\(host):\(port)"
    }

    private static func encoded<Value: Encodable>(
        _ value: Value,
        status: LANHTTPResponseStatus = .ok,
        cookieMutation: LANHTTPCookieMutation? = nil
    ) throws -> LANHTTPWireResponse {
        .json(
            status: status,
            body: try LANHTTPJSONCodec.encode(value),
            cookieMutation: cookieMutation
        )
    }

    private static func sessionCookie(_ token: String) -> String {
        "\(LANHTTPHandlerConfiguration.sessionCookieName)=\(token); "
            + "Path=/; HttpOnly; SameSite=Strict"
    }

    private static var clearedSessionCookie: String {
        "\(LANHTTPHandlerConfiguration.sessionCookieName)=; "
            + "Max-Age=0; Path=/; HttpOnly; SameSite=Strict"
    }
}

private struct LANHTTPValidationFailure: Error, Sendable {
    let status: LANHTTPResponseStatus
    let reason: LANHTTPLogReason
}
