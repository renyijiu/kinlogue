import Foundation
import KinlogueCore
import NIOCore

public enum LANReceiverError: Error, Equatable, Sendable {
    case alreadyStarted
    case sessionEnded
    case invalidRequest
    case conflict
    case retryLater
    case storageUnavailable
}

enum LANCanonicalAuthorityError: Error, Equatable, Sendable {
    case alreadyInstalled
    case invalidAuthority
    case revoked
}

/// A listener started with port zero does not know its canonical authority
/// until bind completes. HTTP handlers share this set-once gate so a request
/// racing that interval fails closed instead of accepting `host:0` or a
/// wildcard. Revocation is synchronous and precedes asynchronous channel
/// teardown.
// SAFETY: `lock` serializes the set-once/revoked authority state and every read.
final class LANCanonicalAuthorityProvider: @unchecked Sendable {
    private enum State {
        case unset
        case installed(String)
        case revoked
    }

    private let lock = NSLock()
    private var state: State = .unset

    func install(_ authority: String) throws {
        guard !authority.isEmpty,
              !authority.contains("/"),
              !authority.contains("@") else {
            throw LANCanonicalAuthorityError.invalidAuthority
        }
        try lock.withLock {
            switch state {
            case .unset:
                state = .installed(authority)
            case .installed:
                throw LANCanonicalAuthorityError.alreadyInstalled
            case .revoked:
                throw LANCanonicalAuthorityError.revoked
            }
        }
    }

    func accepts(authority candidate: String) -> Bool {
        lock.withLock {
            guard case let .installed(authority) = state else { return false }
            return candidate == authority
        }
    }

    func accepts(origin candidate: String) -> Bool {
        lock.withLock {
            guard case let .installed(authority) = state else { return false }
            return candidate == "http://\(authority)"
        }
    }

    func currentAuthority() -> String? {
        lock.withLock {
            guard case let .installed(authority) = state else { return nil }
            return authority
        }
    }

    func revoke() {
        lock.withLock { state = .revoked }
    }
}

public struct LANReceiverPresentation: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    public let endpoint: LANServerEndpoint
    public let pairingCode: LANPairingCode
    public let pairingExpiresInSeconds: Int

    public var url: URL? {
        URL(string: "http://\(endpoint.urlAuthority)/")
    }

    public var description: String { "<redacted-lan-receiver-presentation>" }
    public var debugDescription: String { description }
}

enum LANReceiverStoreOperation: Sendable {
    case initialize
    case loadStatus
    case startUpload
    case revoke
}

typealias LANReceiverPipelineInstaller = @Sendable (
    any Channel,
    LANTransportPeer,
    LANCanonicalAuthorityProvider,
    LANReceiver
) -> EventLoopFuture<Void>

public enum LANReceiverFileUploadStart: Sendable {
    case receive(LANReceiverFileUploadLease)
    case alreadySaved(LANFileSavedResponse, expectedByteCount: Int64)
}

/// Receiver-owned lease for one file-level upload. Network disconnects call
/// `cancel()` and remain retryable; the explicit cancel route calls
/// `cancelForUser()` and records a terminal transport result.
// SAFETY: `lock` protects upload state and byte accounting; immutable tokens and
// the actor reference are initialized before the lease crosses executors.
public final class LANReceiverFileUploadLease: LANHTTPFileUploadBodySink,
    @unchecked Sendable
{
    private enum State {
        case open
        case finishing
        case finished
        case cancelled
    }

    public let remoteFileID: UUID
    public let attemptRevision: UInt64

    private weak var receiver: LANReceiver?
    private let runtimeToken: UUID
    private let attemptToken: UUID
    private let sink: LANUploadSink
    private let lock = NSLock()
    private var state: State = .open
    private var receivedBytes: Int64 = 0

    fileprivate init(
        receiver: LANReceiver,
        runtimeToken: UUID,
        attemptToken: UUID,
        remoteFileID: UUID,
        attemptRevision: UInt64,
        sink: LANUploadSink
    ) {
        self.receiver = receiver
        self.runtimeToken = runtimeToken
        self.attemptToken = attemptToken
        self.remoteFileID = remoteFileID
        self.attemptRevision = attemptRevision
        self.sink = sink
    }

    public var receivedByteCount: Int64 {
        lock.withLock { receivedBytes }
    }

    public func write(_ buffer: ByteBuffer) -> Task<Void, Error> {
        let byteCount = buffer.readableBytes
        guard lock.withLock({ state == .open }),
              let count = Int64(exactly: byteCount) else {
            return Task { throw LANReceiverError.conflict }
        }
        let admitted = sink.write(buffer)
        return Task { [weak self] in
            try await admitted.value
            guard let self else { throw LANReceiverError.sessionEnded }
            try self.lock.withLock {
                guard self.state == .open else { throw LANReceiverError.sessionEnded }
                let next = self.receivedBytes.addingReportingOverflow(count)
                guard !next.overflow else { throw LANReceiverError.invalidRequest }
                self.receivedBytes = next.partialValue
            }
        }
    }

    public func finish() async throws -> LANFileSavedResponse {
        guard lock.withLock({
            guard state == .open else { return false }
            state = .finishing
            return true
        }) else {
            throw LANReceiverError.conflict
        }
        do {
            let completed = try await sink.finish()
            guard let byteCount = Int64(exactly: completed.byteCount) else {
                throw LANReceiverError.invalidRequest
            }
            guard let receiver else { throw LANReceiverError.sessionEnded }
            await receiver.fileUploadPublished()
            lock.withLock {
                receivedBytes = byteCount
                state = .finished
            }
            return try await receiver.fileUploadFinished(
                runtimeToken: runtimeToken,
                attemptToken: attemptToken,
                remoteFileID: remoteFileID,
                byteCount: byteCount
            )
        } catch {
            lock.withLock { state = .cancelled }
            await receiver?.fileUploadInterrupted(
                runtimeToken: runtimeToken,
                attemptToken: attemptToken,
                remoteFileID: remoteFileID
            )
            throw error
        }
    }

    public func cancel() async {
        guard markCancelled() else { return }
        await sink.cancel()
        await receiver?.fileUploadInterrupted(
            runtimeToken: runtimeToken,
            attemptToken: attemptToken,
            remoteFileID: remoteFileID
        )
    }

    fileprivate func cancelForUser() async throws {
        guard markCancelled() else { throw LANReceiverError.conflict }
        await sink.cancel()
        guard let receiver else { throw LANReceiverError.sessionEnded }
        try await receiver.fileUploadCancelledByUser(
            runtimeToken: runtimeToken,
            attemptToken: attemptToken,
            remoteFileID: remoteFileID,
            attemptRevision: attemptRevision
        )
    }

    private func markCancelled() -> Bool {
        lock.withLock {
            switch state {
            case .open, .finishing:
                state = .cancelled
                return true
            case .finished, .cancelled:
                return false
            }
        }
    }
}

public actor LANReceiver {
    typealias StoreObserver = @Sendable (LANReceiverStoreOperation) -> Void
    typealias PostBindHook = @Sendable (
        LANServerEndpoint,
        LANCanonicalAuthorityProvider
    ) async -> Void
    typealias StoreInitializationHook = @Sendable () async throws -> Void
    typealias PreActivationHook = @Sendable (
        @escaping @Sendable () async -> Void
    ) async -> Void
    typealias PublicationRevocationHook = @Sendable () async -> Void
    typealias FileUploadPublishedHook = @Sendable () async -> Void

    private struct ItemDefinition: Equatable, Sendable {
        let remoteFileID: UUID
        let displayName: String
        let declaredByteCount: Int64
        let mediaType: String?

        init(_ request: LANReserveFileRequest) {
            remoteFileID = request.remoteFileID
            displayName = request.displayName
            declaredByteCount = request.declaredByteCount
            mediaType = request.mediaType
        }
    }

    private enum ItemTransportState {
        case reserved
        case opening(UUID)
        case receiving(UUID)
        case saved
        case interrupted
        case cancelled
    }

    private struct TrackedItemFile {
        let definition: ItemDefinition
        let metadata: LANInboxTransportMetadata
        let admissionGeneration: UInt64
        var attemptRevision: UInt64
        var state: ItemTransportState
    }

    // SAFETY: The enclosing `LANReceiver` actor exclusively mutates runtime
    // collections and tasks; immutable services are Sendable or internally synchronized.
    private final class Runtime: @unchecked Sendable {
        let token: UUID
        let sessionID: LANSessionID
        let presentation: LANPairingPresentation
        let store: PlaintextLANInboxStore
        let publicationGuard: LANInboxPublicationGuard
        let transport: LANServerTransport
        let networkMonitor: LANNetworkMonitor?
        let authority: LANCanonicalAuthorityProvider
        var idleTask: Task<Void, Never>?
        var files: [UUID: TrackedItemFile] = [:]
        var fileOrder: [UUID] = []
        var reservingFiles: Set<UUID> = []
        var fileUploads: [UUID: LANReceiverFileUploadLease] = [:]

        init(
            token: UUID,
            sessionID: LANSessionID,
            presentation: LANPairingPresentation,
            store: PlaintextLANInboxStore,
            publicationGuard: LANInboxPublicationGuard,
            transport: LANServerTransport,
            networkMonitor: LANNetworkMonitor?,
            authority: LANCanonicalAuthorityProvider
        ) {
            self.token = token
            self.sessionID = sessionID
            self.presentation = presentation
            self.store = store
            self.publicationGuard = publicationGuard
            self.transport = transport
            self.networkMonitor = networkMonitor
            self.authority = authority
        }
    }

    private enum Phase {
        case inactive
        case starting(UUID)
        case active(Runtime)
        case stopping(UUID)
    }

    private let rootURL: URL
    private let session: LANSession
    private let idleDuration: Duration
    private let storeObserver: StoreObserver
    private let postBindHook: PostBindHook
    private let storeInitializationHook: StoreInitializationHook
    private let preActivationHook: PreActivationHook
    private let publicationRevocationHook: PublicationRevocationHook
    private let fileUploadPublishedHook: FileUploadPublishedHook
    private var phase: Phase = .inactive
    private var startStopWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]

    public init(rootURL: URL) {
        self.rootURL = rootURL
        session = LANSession()
        idleDuration = .seconds(15 * 60)
        storeObserver = { _ in }
        postBindHook = { _, _ in }
        storeInitializationHook = {}
        preActivationHook = { _ in }
        publicationRevocationHook = {}
        fileUploadPublishedHook = {}
    }

    init(
        rootURL: URL,
        session: LANSession,
        idleDuration: Duration = .seconds(15 * 60),
        storeObserver: @escaping StoreObserver = { _ in },
        postBindHook: @escaping PostBindHook = { _, _ in },
        storeInitializationHook: @escaping StoreInitializationHook = {},
        preActivationHook: @escaping PreActivationHook = { _ in },
        publicationRevocationHook: @escaping PublicationRevocationHook = {},
        fileUploadPublishedHook: @escaping FileUploadPublishedHook = {}
    ) {
        self.rootURL = rootURL
        self.session = session
        self.idleDuration = idleDuration
        self.storeObserver = storeObserver
        self.postBindHook = postBindHook
        self.storeInitializationHook = storeInitializationHook
        self.preActivationHook = preActivationHook
        self.publicationRevocationHook = publicationRevocationHook
        self.fileUploadPublishedHook = fileUploadPublishedHook
    }

    public func start(
        at address: LANNetworkAddress,
        port: Int = 0
    ) async throws -> LANReceiverPresentation {
        let exactAddress = try LANNetworkInterfaceResolver.requireExactAddress(
            address,
            from: LANNetworkInterfaceResolver.currentSnapshots()
        )
        return try await startProductionHTTP(
            at: exactAddress,
            port: port,
            allowLoopbackForTesting: false
        )
    }

    private func startProductionHTTP(
        at address: LANNetworkAddress,
        port: Int,
        allowLoopbackForTesting: Bool
    ) async throws -> LANReceiverPresentation {
        let assetCatalog = try LANPhoneAssetCatalog.loadBundled()
        return try await start(
            at: address,
            port: port,
            allowLoopbackForTesting: allowLoopbackForTesting,
            pipelineInstaller: { channel, peer, authority, application in
                LANHTTPPipeline.configure(
                    channel: channel,
                    peer: peer,
                    authorityProvider: { authority.currentAuthority() },
                    assetCatalog: assetCatalog,
                    application: application
                )
            }
        )
    }

    /// Installed-acceptance-only entry point. It uses the production HTTP
    /// pipeline, session, streaming store, and socket lifecycle while allowing
    /// the isolated acceptance identity to bind loopback.
    @_spi(KinlogueAcceptance)
    public func startInstalledAcceptanceProbe(
        port: Int = 0
    ) async throws -> LANReceiverPresentation {
        try await startProductionHTTP(
            at: .init(
                interfaceName: "lo0",
                host: "127.0.0.1",
                networkPrefixLength: 8
            ),
            port: port,
            allowLoopbackForTesting: true
        )
    }

    /// A redacted lifecycle probe for the Mac surface. Pairing material and
    /// endpoint details remain owned by the caller that started the session.
    public var isActive: Bool {
        if case .active = phase { return true }
        return false
    }

    /// Non-secret session identity used only to fence Mac-side archive/delete
    /// decisions against bodies already admitted in the active session.
    public var activeSessionID: UUID? {
        guard case let .active(runtime) = phase else { return nil }
        return runtime.sessionID.uuid
    }

    /// Test seam that retains the production listener/session/store lifecycle
    /// while allowing a loopback bind and an embedded pipeline.
    func start(
        at address: LANNetworkAddress,
        port: Int,
        allowLoopbackForTesting: Bool,
        pipelineInstaller: @escaping LANReceiverPipelineInstaller
    ) async throws -> LANReceiverPresentation {
        guard case .inactive = phase else { throw LANReceiverError.alreadyStarted }
        let token = UUID()
        phase = .starting(token)

        let pairing: LANPairingPresentation
        let store: PlaintextLANInboxStore
        let guardValue: LANInboxPublicationGuard
        do {
            pairing = try await session.startNewSession()
            store = try PlaintextLANInboxStore(
                rootURL: rootURL,
                runtimeGeneration: UUID()
            )
            try await storeInitializationHook()
            storeObserver(.initialize)
            _ = try await store.initialize()
            guardValue = try await store.publicationGuard()
        } catch {
            await session.stop()
            finishStarting(token)
            throw Self.map(error)
        }

        guard isStarting(token) else {
            storeObserver(.revoke)
            try? await store.revokePublications(guardedBy: guardValue)
            await session.stop()
            finishStarting(token)
            throw LANReceiverError.sessionEnded
        }

        let authority = LANCanonicalAuthorityProvider()
        let receiver = self
        let transport = LANServerTransport(
            childChannelInitializer: { channel, peer in
                pipelineInstaller(channel, peer, authority, receiver)
            },
            allowLoopbackForTesting: allowLoopbackForTesting
        )
        var monitor: LANNetworkMonitor?

        do {
            let endpoint = try await transport.start(at: address, port: port)
            guard isStarting(token) else { throw LANReceiverError.sessionEnded }
            await postBindHook(endpoint, authority)
            guard isStarting(token) else { throw LANReceiverError.sessionEnded }

            if !allowLoopbackForTesting {
                let created = LANNetworkMonitor(
                    advertisedAddress: address,
                    stopReceiving: { [weak receiver] in
                        await receiver?.stop(ifRuntime: token)
                    },
                    invalidateCredential: { [weak receiver] in
                        await receiver?.stop(ifRuntime: token)
                    }
                )
                try await created.start()
                monitor = created
            }

            await preActivationHook { [weak receiver] in
                await receiver?.requestStop(ifRuntime: token)
            }
            guard isStarting(token) else { throw LANReceiverError.sessionEnded }
            try authority.install(endpoint.urlAuthority)
            let runtime = Runtime(
                token: token,
                sessionID: pairing.sessionID,
                presentation: pairing,
                store: store,
                publicationGuard: guardValue,
                transport: transport,
                networkMonitor: monitor,
                authority: authority
            )
            phase = .active(runtime)
            resetIdleTimer(for: runtime)
            return LANReceiverPresentation(
                endpoint: endpoint,
                pairingCode: pairing.pairingCode,
                pairingExpiresInSeconds: pairing.expiresInSeconds
            )
        } catch {
            authority.revoke()
            if let monitor { await monitor.stop() }
            storeObserver(.revoke)
            try? await store.revokePublications(guardedBy: guardValue)
            await transport.stop()
            await session.stop()
            finishStarting(token)
            throw Self.map(error)
        }
    }

    public func stop() async {
        switch phase {
        case .inactive:
            return
        case let .starting(token):
            await stopStarting(token, waitForCleanup: true)
        case let .active(runtime):
            await stop(runtime)
        case let .stopping(token):
            await waitForStartCleanup(token)
        }
    }

    private func stop(ifRuntime token: UUID) async {
        switch phase {
        case let .starting(current) where current == token:
            await stopStarting(token, waitForCleanup: true)
        case let .active(runtime) where runtime.token == token:
            await stop(runtime)
        case let .stopping(current) where current == token:
            await waitForStartCleanup(token)
        default:
            return
        }
    }

    /// Used by a hook running inline with `start`; it must mark the token as
    /// cancelled without waiting for that same `start` call to unwind.
    private func requestStop(ifRuntime token: UUID) async {
        switch phase {
        case let .starting(current) where current == token:
            await stopStarting(token, waitForCleanup: false)
        case let .active(runtime) where runtime.token == token:
            await stop(runtime)
        default:
            return
        }
    }

    private func stopStarting(
        _ token: UUID,
        waitForCleanup: Bool
    ) async {
        guard case let .starting(current) = phase, current == token else {
            if waitForCleanup,
               case let .stopping(current) = phase,
               current == token {
                await waitForStartCleanup(token)
            }
            return
        }
        phase = .stopping(token)
        await session.stop()
        if waitForCleanup { await waitForStartCleanup(token) }
    }

    private func stop(_ runtime: Runtime) async {
        phase = .stopping(runtime.token)
        runtime.authority.revoke()
        runtime.idleTask?.cancel()
        let fileLeases = Array(runtime.fileUploads.values)
        async let transportStop: Void = runtime.transport.stop()
        async let sessionStop: Void = session.stop()
        async let leaseCancellation: Void = withTaskGroup(of: Void.self) { group in
            for lease in fileLeases { group.addTask { await lease.cancel() } }
        }
        async let monitorStop: Void = Self.stopMonitor(runtime.networkMonitor)

        _ = await (
            transportStop,
            sessionStop,
            leaseCancellation,
            monitorStop
        )
        try? await runtime.store.endItemSession(sessionID: runtime.sessionID.uuid)
        storeObserver(.revoke)
        await publicationRevocationHook()
        try? await runtime.store.revokePublications(
            guardedBy: runtime.publicationGuard
        )
        finishStarting(runtime.token)
    }

    public func pair(
        _ request: LANPairRequest,
        from peer: LANPeerKey
    ) async -> LANPairingResult {
        guard case let .active(runtime) = phase else {
            return .failed(.unavailable)
        }
        let result = await session.pair(code: request.code, from: peer)
        guard currentRuntime(token: runtime.token) != nil else {
            return .failed(.unavailable)
        }
        if case .paired = result { resetIdleTimer(for: runtime) }
        return result
    }

    public func authenticate(
        _ proof: LANSessionProof,
        from peer: LANPeerKey,
        operation: LANAuthenticatedOperation
    ) async -> LANAuthenticationResult {
        guard case let .active(runtime) = phase else {
            return .failed(.unavailable)
        }
        let result = await session.authenticate(proof, from: peer, operation: operation)
        guard currentRuntime(token: runtime.token) != nil else {
            return .failed(.unavailable)
        }
        if case let .authorized(authorization) = result,
           authorization.sessionID == runtime.sessionID,
           authorization.runtimeGeneration == runtime.presentation.runtimeGeneration {
            return result
        }
        if case .authorized = result { return .failed(.rejected) }
        return result
    }

    public func restoreSession(
        _ proof: LANSessionCapabilityProof,
        from peer: LANPeerKey
    ) async -> LANSessionRestorationResult {
        guard case let .active(runtime) = phase else {
            return .failed(.unavailable)
        }
        let result = await session.restoreSession(proof, from: peer)
        guard currentRuntime(token: runtime.token) != nil else {
            return .failed(.unavailable)
        }
        if case let .restored(credentials) = result,
           credentials.sessionID == runtime.sessionID,
           credentials.runtimeGeneration == runtime.presentation.runtimeGeneration {
            return result
        }
        if case .restored = result { return .failed(.rejected) }
        return result
    }

    public func logout(
        _ proof: LANSessionProof,
        from peer: LANPeerKey
    ) async -> LANAuthenticationResult {
        guard case let .active(runtime) = phase else {
            return .failed(.unavailable)
        }
        let result = await session.logout(proof, from: peer)
        guard currentRuntime(token: runtime.token) != nil else {
            return .failed(.unavailable)
        }
        if case let .authorized(authorization) = result,
           authorization.sessionID == runtime.sessionID,
           authorization.runtimeGeneration == runtime.presentation.runtimeGeneration {
            return result
        }
        if case .authorized = result { return .failed(.rejected) }
        return result
    }

    public func reserveFile(
        _ request: LANReserveFileRequest,
        authorizedBy authorization: LANAuthorizedSession
    ) async throws -> LANReserveFileResponse {
        let runtime = try authorizedRuntime(authorization)
        let definition = ItemDefinition(request)
        if var existing = runtime.files[request.remoteFileID] {
            guard existing.definition == definition else {
                throw LANReceiverError.conflict
            }
            guard request.attemptRevision >= existing.attemptRevision else {
                throw LANReceiverError.conflict
            }
            if request.attemptRevision > existing.attemptRevision {
                switch existing.state {
                case .reserved, .interrupted:
                    existing.attemptRevision = request.attemptRevision
                    existing.state = .reserved
                    runtime.files[request.remoteFileID] = existing
                case .opening, .receiving:
                    throw LANReceiverError.retryLater
                case .saved, .cancelled:
                    break
                }
            }
            return LANReserveFileResponse(file: try phoneFile(existing))
        }
        guard runtime.files.count < LANFileSessionResponse.maximumFileCount,
              runtime.reservingFiles.insert(request.remoteFileID).inserted else {
            throw LANReceiverError.retryLater
        }
        defer { runtime.reservingFiles.remove(request.remoteFileID) }

        do {
            let admissionGeneration = try await runtime.store.itemAdmissionGeneration()
            let current = try activeRuntime(token: runtime.token)
            if let installed = current.files[request.remoteFileID] {
                guard installed.definition == definition else {
                    throw LANReceiverError.conflict
                }
                return LANReserveFileResponse(file: try phoneFile(installed))
            }
            let sanitized = try LANInboxDisplayMetadataSanitizer()
                .sanitize(request.displayName)
            let metadata = try LANInboxTransportMetadata(
                displayName: LANInboxDisplayName(rawValue: sanitized),
                declaredByteCount: Int(request.declaredByteCount),
                mediaType: request.mediaType
            )
            let tracked = TrackedItemFile(
                definition: definition,
                metadata: metadata,
                admissionGeneration: admissionGeneration,
                attemptRevision: request.attemptRevision,
                state: .reserved
            )
            current.files[request.remoteFileID] = tracked
            current.fileOrder.append(request.remoteFileID)
            return LANReserveFileResponse(file: try phoneFile(tracked))
        } catch {
            throw Self.map(error)
        }
    }

    public func startFileUpload(
        remoteFileID: UUID,
        attemptRevision: UInt64,
        declaredContentLength: Int64?,
        authorizedBy authorization: LANAuthorizedSession
    ) async throws -> LANReceiverFileUploadStart {
        let runtime = try authorizedRuntime(authorization)
        guard var tracked = runtime.files[remoteFileID],
              tracked.attemptRevision == attemptRevision else {
            throw LANReceiverError.conflict
        }
        if let declaredContentLength,
           declaredContentLength != tracked.definition.declaredByteCount {
            throw LANReceiverError.invalidRequest
        }
        switch tracked.state {
        case .saved:
            return .alreadySaved(
                LANFileSavedResponse(),
                expectedByteCount: tracked.definition.declaredByteCount
            )
        case .opening, .receiving:
            throw LANReceiverError.retryLater
        case .cancelled:
            throw LANReceiverError.conflict
        case .reserved, .interrupted:
            break
        }

        let attemptToken = UUID()
        tracked.state = .opening(attemptToken)
        runtime.files[remoteFileID] = tracked
        do {
            storeObserver(.startUpload)
            let outcome = try await runtime.store.startItemUpload(
                transport: LANInboxTransportIdentity(
                    sessionID: runtime.sessionID.uuid,
                    remoteFileID: remoteFileID
                ),
                metadata: tracked.metadata,
                attemptRevision: attemptRevision,
                admissionGeneration: tracked.admissionGeneration,
                publicationGuard: runtime.publicationGuard
            )
            let current = try activeRuntime(token: runtime.token)
            guard var currentFile = current.files[remoteFileID],
                  currentFile.attemptRevision == attemptRevision,
                  case let .opening(currentAttempt) = currentFile.state,
                  currentAttempt == attemptToken else {
                if case let .sink(sink) = outcome { await sink.cancel() }
                throw LANReceiverError.sessionEnded
            }
            switch outcome {
            case .terminal:
                currentFile.state = .saved
                current.files[remoteFileID] = currentFile
                return .alreadySaved(
                    LANFileSavedResponse(),
                    expectedByteCount: currentFile.definition.declaredByteCount
                )
            case let .sink(sink):
                let lease = LANReceiverFileUploadLease(
                    receiver: self,
                    runtimeToken: current.token,
                    attemptToken: attemptToken,
                    remoteFileID: remoteFileID,
                    attemptRevision: attemptRevision,
                    sink: sink
                )
                currentFile.state = .receiving(attemptToken)
                current.files[remoteFileID] = currentFile
                current.fileUploads[attemptToken] = lease
                return .receive(lease)
            }
        } catch {
            if let current = currentRuntime(token: runtime.token),
               var currentFile = current.files[remoteFileID],
               case let .opening(currentAttempt) = currentFile.state,
               currentAttempt == attemptToken {
                currentFile.state = .interrupted
                current.files[remoteFileID] = currentFile
            }
            throw Self.map(error)
        }
    }

    public func fileStatus(
        remoteFileID: UUID,
        authorizedBy authorization: LANAuthorizedSession
    ) throws -> LANPhoneFileStatus {
        let runtime = try authorizedRuntime(authorization)
        guard let file = runtime.files[remoteFileID] else {
            throw LANReceiverError.conflict
        }
        return try phoneFile(file)
    }

    public func cancelFile(
        remoteFileID: UUID,
        attemptRevision: UInt64,
        authorizedBy authorization: LANAuthorizedSession
    ) async throws -> LANFileCancelResponse {
        let runtime = try authorizedRuntime(authorization)
        guard var file = runtime.files[remoteFileID],
              file.attemptRevision == attemptRevision else {
            throw LANReceiverError.conflict
        }
        switch file.state {
        case .saved, .cancelled:
            throw LANReceiverError.conflict
        case let .receiving(attemptToken), let .opening(attemptToken):
            guard let lease = runtime.fileUploads[attemptToken] else {
                throw LANReceiverError.retryLater
            }
            try await lease.cancelForUser()
            return LANFileCancelResponse()
        case .reserved, .interrupted:
            let receipt = try await runtime.store.recordItemUploadCancellation(
                transport: LANInboxTransportIdentity(
                    sessionID: runtime.sessionID.uuid,
                    remoteFileID: remoteFileID
                ),
                metadata: file.metadata,
                attemptRevision: attemptRevision
            )
            guard case .cancelled = receipt.outcome else {
                throw LANReceiverError.conflict
            }
            file.state = .cancelled
            runtime.files[remoteFileID] = file
            return LANFileCancelResponse()
        }
    }

    public func fileSessionResponse(
        restoredCredentials credentials: LANBrowserCredentials
    ) throws -> LANFileSessionResponse {
        let runtime = try credentialsRuntime(credentials)
        let files = try runtime.fileOrder.compactMap { remoteFileID in
            runtime.files[remoteFileID]
        }.map(phoneFile)
        return try LANFileSessionResponse(
            csrfToken: credentials.csrfToken,
            files: files
        )
    }

    fileprivate func fileUploadFinished(
        runtimeToken: UUID,
        attemptToken: UUID,
        remoteFileID: UUID,
        byteCount: Int64
    ) throws -> LANFileSavedResponse {
        let runtime = try activeRuntime(token: runtimeToken)
        guard var file = runtime.files[remoteFileID],
              file.definition.declaredByteCount == byteCount,
              case let .receiving(currentAttempt) = file.state,
              currentAttempt == attemptToken else {
            throw LANReceiverError.sessionEnded
        }
        file.state = .saved
        runtime.files[remoteFileID] = file
        runtime.fileUploads.removeValue(forKey: attemptToken)
        return LANFileSavedResponse()
    }

    fileprivate func fileUploadPublished() async {
        await fileUploadPublishedHook()
    }

    fileprivate func fileUploadInterrupted(
        runtimeToken: UUID,
        attemptToken: UUID,
        remoteFileID: UUID
    ) {
        guard let runtime = currentRuntime(token: runtimeToken),
              var file = runtime.files[remoteFileID] else { return }
        switch file.state {
        case .opening(let current) where current == attemptToken,
             .receiving(let current) where current == attemptToken:
            file.state = .interrupted
            runtime.files[remoteFileID] = file
        default:
            break
        }
        runtime.fileUploads.removeValue(forKey: attemptToken)
    }

    fileprivate func fileUploadCancelledByUser(
        runtimeToken: UUID,
        attemptToken: UUID,
        remoteFileID: UUID,
        attemptRevision: UInt64
    ) async throws {
        let runtime = try activeRuntime(token: runtimeToken)
        guard let file = runtime.files[remoteFileID],
              file.attemptRevision == attemptRevision else {
            throw LANReceiverError.sessionEnded
        }
        switch file.state {
        case .opening(let current) where current == attemptToken,
             .receiving(let current) where current == attemptToken:
            break
        default:
            throw LANReceiverError.conflict
        }
        let receipt = try await runtime.store.recordItemUploadCancellation(
            transport: LANInboxTransportIdentity(
                sessionID: runtime.sessionID.uuid,
                remoteFileID: remoteFileID
            ),
            metadata: file.metadata,
            attemptRevision: attemptRevision
        )
        let current = try activeRuntime(token: runtimeToken)
        guard var currentFile = current.files[remoteFileID] else {
            throw LANReceiverError.sessionEnded
        }
        switch receipt.outcome {
        case .cancelled:
            currentFile.state = .cancelled
        case .published, .merged, .archived, .deleted:
            currentFile.state = .saved
            current.files[remoteFileID] = currentFile
            current.fileUploads.removeValue(forKey: attemptToken)
            throw LANReceiverError.conflict
        }
        current.files[remoteFileID] = currentFile
        current.fileUploads.removeValue(forKey: attemptToken)
    }

    private func phoneFile(_ file: TrackedItemFile) throws -> LANPhoneFileStatus {
        let state: LANPhoneFileStatusState
        let received: Int64
        switch file.state {
        case .reserved, .opening:
            state = .reserved
            received = 0
        case let .receiving(attempt):
            state = .receiving
            received = currentRuntimeFileUploadBytes(attempt) ?? 0
        case .saved:
            state = .saved
            received = file.definition.declaredByteCount
        case .interrupted:
            state = .interrupted
            received = 0
        case .cancelled:
            state = .cancelled
            received = 0
        }
        return try LANPhoneFileStatus(
            remoteFileID: file.definition.remoteFileID,
            displayName: file.metadata.displayName.rawValue,
            declaredByteCount: file.definition.declaredByteCount,
            receivedByteCount: min(received, file.definition.declaredByteCount),
            attemptRevision: file.attemptRevision,
            state: state
        )
    }

    private func currentRuntimeFileUploadBytes(_ attempt: UUID) -> Int64? {
        guard case let .active(runtime) = phase else { return nil }
        return runtime.fileUploads[attempt]?.receivedByteCount
    }

    private func authorizedRuntime(
        _ authorization: LANAuthorizedSession
    ) throws -> Runtime {
        guard case let .active(runtime) = phase,
              runtime.sessionID == authorization.sessionID,
              runtime.presentation.runtimeGeneration == authorization.runtimeGeneration else {
            throw LANReceiverError.sessionEnded
        }
        return runtime
    }

    private func credentialsRuntime(
        _ credentials: LANBrowserCredentials
    ) throws -> Runtime {
        guard case let .active(runtime) = phase,
              runtime.sessionID == credentials.sessionID,
              runtime.presentation.runtimeGeneration == credentials.runtimeGeneration else {
            throw LANReceiverError.sessionEnded
        }
        return runtime
    }

    private func activeRuntime(token: UUID) throws -> Runtime {
        guard let runtime = currentRuntime(token: token) else {
            throw LANReceiverError.sessionEnded
        }
        return runtime
    }

    private func currentRuntime(token: UUID) -> Runtime? {
        guard case let .active(runtime) = phase, runtime.token == token else { return nil }
        return runtime
    }

    private func isStarting(_ token: UUID) -> Bool {
        guard case let .starting(current) = phase else { return false }
        return current == token
    }

    private func waitForStartCleanup(_ token: UUID) async {
        guard case let .stopping(current) = phase, current == token else { return }
        await withCheckedContinuation { continuation in
            guard case let .stopping(current) = phase, current == token else {
                continuation.resume()
                return
            }
            startStopWaiters[token, default: []].append(continuation)
        }
    }

    private func finishStarting(_ token: UUID) {
        switch phase {
        case .starting(let current) where current == token:
            phase = .inactive
        case .stopping(let current) where current == token:
            phase = .inactive
        default:
            return
        }
        let waiters = startStopWaiters.removeValue(forKey: token) ?? []
        for waiter in waiters { waiter.resume() }
    }

    private static func stopMonitor(_ monitor: LANNetworkMonitor?) async {
        if let monitor { await monitor.stop() }
    }

    private func resetIdleTimer(for runtime: Runtime) {
        runtime.idleTask?.cancel()
        let duration = idleDuration
        let token = runtime.token
        runtime.idleTask = Task { [weak self] in
            do { try await Task.sleep(for: duration) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.stop(ifRuntime: token)
        }
    }

    private static func int64(_ value: Int) throws -> Int64 {
        guard let converted = Int64(exactly: value) else {
            throw LANReceiverError.invalidRequest
        }
        return converted
    }

    private static func map(_ error: Error) -> Error {
        if let receiver = error as? LANReceiverError { return receiver }
        if error is CancellationError { return LANReceiverError.sessionEnded }
        guard let inbox = error as? LANInboxError else {
            return LANReceiverError.storageUnavailable
        }
        switch inbox {
        case .resourceLimitExceeded:
            return LANReceiverError.retryLater
        case .staleRevision, .mutationConflict, .receiptConflict:
            return LANReceiverError.conflict
        case .invalidModel, .invalidDisplayName, .invalidByteCount,
             .duplicateIdentifier, .invalidRevision,
             .invalidGeneration, .arithmeticOverflow:
            return LANReceiverError.invalidRequest
        case .invalidState, .invalidReference, .fileNotFound:
            return LANReceiverError.conflict
        case .unsupportedVersion, .vaultUnavailable, .vaultIDMismatch,
             .integrityCheckFailed, .storageFailure, .invalidDigest:
            return LANReceiverError.storageUnavailable
        }
    }
}

extension LANReceiver: LANHTTPApplication {
    public func pair(
        _ request: LANPairRequest,
        from peer: LANTransportPeer
    ) async throws -> LANHTTPPairSuccess {
        let peerKey = try Self.peerKey(peer)
        switch await pair(request, from: peerKey) {
        case let .paired(credentials):
            return LANHTTPPairSuccess(
                cookieValue: credentials.capabilityCookieValue,
                response: try LANPairResponse(csrfToken: credentials.csrfToken)
            )
        case let .failed(failure):
            throw Self.httpPairingFailure(failure)
        }
    }

    public func restoreFileSession(
        _ capability: LANHTTPBrowserCapability,
        from peer: LANTransportPeer
    ) async throws -> LANFileSessionResponse {
        guard case let .active(runtime) = phase else {
            throw LANHTTPApplicationFailure.sessionEnded
        }
        let proof = LANSessionCapabilityProof(
            sessionID: runtime.sessionID,
            runtimeGeneration: runtime.presentation.runtimeGeneration,
            capabilityCookieValue: capability.cookieValue
        )
        switch await restoreSession(proof, from: try Self.peerKey(peer)) {
        case let .restored(credentials):
            do {
                return try fileSessionResponse(
                    restoredCredentials: credentials
                )
            } catch {
                throw Self.httpFailure(error)
            }
        case let .failed(failure):
            throw Self.httpAuthenticationFailure(failure)
        }
    }

    public func logout(
        _ proof: LANHTTPBrowserProof,
        from peer: LANTransportPeer
    ) async throws {
        guard case let .active(runtime) = phase else {
            throw LANHTTPApplicationFailure.sessionEnded
        }
        let sessionProof = LANSessionProof(
            sessionID: runtime.sessionID,
            runtimeGeneration: runtime.presentation.runtimeGeneration,
            capabilityCookieValue: proof.cookieValue,
            csrfToken: proof.csrfToken
        )
        switch await logout(sessionProof, from: try Self.peerKey(peer)) {
        case .authorized:
            return
        case let .failed(failure):
            throw Self.httpAuthenticationFailure(failure)
        }
    }

    public func reserveFile(
        _ request: LANReserveFileRequest,
        authorization: LANAuthorizedSession
    ) async throws -> LANReserveFileResponse {
        do {
            let response = try await reserveFile(request, authorizedBy: authorization)
            try await recordSuccessfulActivity(authorization)
            return response
        } catch {
            throw Self.httpFailure(error)
        }
    }

    public func beginFileUpload(
        remoteFileID: UUID,
        attemptRevision: UInt64,
        declaredByteCount: Int?,
        authorization: LANAuthorizedSession
    ) async throws -> LANHTTPFileUploadStart {
        do {
            let declared = try declaredByteCount.map { value -> Int64 in
                guard let converted = Int64(exactly: value) else {
                    throw LANReceiverError.invalidRequest
                }
                return converted
            }
            let response: LANHTTPFileUploadStart
            switch try await startFileUpload(
                remoteFileID: remoteFileID,
                attemptRevision: attemptRevision,
                declaredContentLength: declared,
                authorizedBy: authorization
            ) {
            case let .receive(lease):
                response = .sink(lease)
            case let .alreadySaved(saved, expectedByteCount):
                response = .alreadySaved(saved, expectedByteCount: expectedByteCount)
            }
            try await recordSuccessfulActivity(authorization)
            return response
        } catch {
            throw Self.httpFailure(error)
        }
    }

    public func fileStatus(
        remoteFileID: UUID,
        authorization: LANAuthorizedSession
    ) async throws -> LANPhoneFileStatus {
        do {
            let response = try fileStatus(
                remoteFileID: remoteFileID,
                authorizedBy: authorization
            )
            try await recordSuccessfulActivity(authorization)
            return response
        } catch {
            throw Self.httpFailure(error)
        }
    }

    public func cancelFile(
        remoteFileID: UUID,
        attemptRevision: UInt64,
        authorization: LANAuthorizedSession
    ) async throws -> LANFileCancelResponse {
        do {
            let response = try await cancelFile(
                remoteFileID: remoteFileID,
                attemptRevision: attemptRevision,
                authorizedBy: authorization
            )
            try await recordSuccessfulActivity(authorization)
            return response
        } catch {
            throw Self.httpFailure(error)
        }
    }

    public func authorize(
        _ proof: LANHTTPBrowserProof,
        from peer: LANTransportPeer,
        operation: LANAuthenticatedOperation
    ) async throws -> LANAuthorizedSession {
        guard case let .active(runtime) = phase else {
            throw LANHTTPApplicationFailure.sessionEnded
        }
        let sessionProof = LANSessionProof(
            sessionID: runtime.sessionID,
            runtimeGeneration: runtime.presentation.runtimeGeneration,
            capabilityCookieValue: proof.cookieValue,
            csrfToken: proof.csrfToken
        )
        switch await authenticate(
            sessionProof,
            from: try Self.peerKey(peer),
            operation: operation
        ) {
        case let .authorized(authorization):
            return authorization
        case let .failed(failure):
            throw Self.httpAuthenticationFailure(failure)
        }
    }

    private nonisolated static func peerKey(
        _ peer: LANTransportPeer
    ) throws -> LANPeerKey {
        try LANPeerKey(socketDerivedBytes: Array(peer.host.utf8))
    }

    private func recordSuccessfulActivity(
        _ authorization: LANAuthorizedSession
    ) async throws {
        let runtime = try authorizedRuntime(authorization)
        guard await session.recordSuccessfulActivity(authorization),
              currentRuntime(token: runtime.token) != nil else {
            throw LANReceiverError.sessionEnded
        }
        resetIdleTimer(for: runtime)
    }

    private nonisolated static func httpPairingFailure(
        _ failure: LANPairingFailure
    ) -> LANHTTPApplicationFailure {
        switch failure {
        case .rejected:
            return .rejected
        case .temporarilyLimited:
            return .retryLater
        case .unavailable:
            return .unavailable
        }
    }

    private nonisolated static func httpAuthenticationFailure(
        _ failure: LANAuthenticationFailure
    ) -> LANHTTPApplicationFailure {
        switch failure {
        case .rejected:
            return .sessionEnded
        case .temporarilyLimited, .pollTooFrequent:
            return .retryLater
        case .unavailable:
            return .sessionEnded
        }
    }

    private nonisolated static func httpFailure(_ error: Error) -> Error {
        if let failure = error as? LANHTTPApplicationFailure { return failure }
        guard let receiver = error as? LANReceiverError else {
            return LANHTTPApplicationFailure.unavailable
        }
        switch receiver {
        case .alreadyStarted, .storageUnavailable:
            return LANHTTPApplicationFailure.unavailable
        case .sessionEnded:
            return LANHTTPApplicationFailure.sessionEnded
        case .retryLater:
            return LANHTTPApplicationFailure.retryLater
        case .invalidRequest, .conflict:
            return LANHTTPApplicationFailure.conflict
        }
    }
}
