import Foundation

/// A socket-derived rate-accounting key. It deliberately carries no network
/// semantics: callers must derive it from the accepted socket and must not use
/// forwarded headers as its source.
public struct LANPeerKey: Hashable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    private let bytes: Data

    public init(socketDerivedBytes: [UInt8]) throws {
        guard !socketDerivedBytes.isEmpty else {
            throw LANPeerKeyError.invalidKey
        }
        bytes = Data(socketDerivedBytes)
    }

    public var description: String { "<opaque-peer>" }
    public var debugDescription: String { description }
}

public enum LANPeerKeyError: Error, Equatable, Sendable {
    case invalidKey
}

public struct LANSessionID: Hashable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    public let rawValue: String
    public let uuid: UUID

    public init?(rawValue: String) {
        guard let bytes = Self.decodeHex(rawValue) else { return nil }
        self.init(randomBytes: bytes)
    }

    public init(uuid: UUID) {
        let value = uuid.uuid
        self.uuid = uuid
        rawValue = Self.encodeHex([
            value.0, value.1, value.2, value.3,
            value.4, value.5, value.6, value.7,
            value.8, value.9, value.10, value.11,
            value.12, value.13, value.14, value.15,
        ])
    }

    public var description: String { "<redacted-session-id>" }
    public var debugDescription: String { description }

    fileprivate init?(randomBytes: [UInt8]) {
        guard randomBytes.count == 16 else { return nil }
        uuid = UUID(uuid: (
            randomBytes[0], randomBytes[1], randomBytes[2], randomBytes[3],
            randomBytes[4], randomBytes[5], randomBytes[6], randomBytes[7],
            randomBytes[8], randomBytes[9], randomBytes[10], randomBytes[11],
            randomBytes[12], randomBytes[13], randomBytes[14], randomBytes[15]
        ))
        rawValue = Self.encodeHex(randomBytes)
    }

    private static func encodeHex(_ bytes: [UInt8]) -> String {
        let alphabet = Array("0123456789abcdef".utf8)
        var output = [UInt8]()
        output.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            output.append(alphabet[Int(byte >> 4)])
            output.append(alphabet[Int(byte & 0x0F)])
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static func decodeHex(_ value: String) -> [UInt8]? {
        let encoded = Array(value.utf8)
        guard encoded.count == 32 else { return nil }
        var output = [UInt8]()
        output.reserveCapacity(16)
        for index in stride(from: 0, to: encoded.count, by: 2) {
            guard let high = hexValue(encoded[index]),
                  let low = hexValue(encoded[index + 1])
            else {
                return nil
            }
            output.append((high << 4) | low)
        }
        return output
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0") ... UInt8(ascii: "9"):
            byte - UInt8(ascii: "0")
        case UInt8(ascii: "a") ... UInt8(ascii: "f"):
            byte - UInt8(ascii: "a") + 10
        default:
            nil
        }
    }
}

public struct LANPairingCode: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    public let value: String

    fileprivate init(value: String) {
        self.value = value
    }

    public var description: String { "<redacted-pairing-code>" }
    public var debugDescription: String { description }
}

public struct LANPairingPresentation: Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    public let sessionID: LANSessionID
    public let runtimeGeneration: UInt64
    public let pairingCode: LANPairingCode
    public let expiresInSeconds: Int

    public var description: String { "<redacted-pairing-presentation>" }
    public var debugDescription: String { description }
}

/// In-memory browser credentials returned by the successful pairing request.
/// The HTTP layer is responsible for putting `capabilityCookieValue` in a
/// host-only, session-only HttpOnly cookie. This value intentionally is not
/// Codable and its descriptions never reveal credential material.
public struct LANBrowserCredentials: Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    public let sessionID: LANSessionID
    public let runtimeGeneration: UInt64
    public let capabilityCookieValue: String
    public let csrfToken: String

    public var description: String { "<redacted-browser-credentials>" }
    public var debugDescription: String { description }
}

/// Exact current-session proof supplied after the HTTP layer has parsed the
/// host-only capability cookie and the CSRF header/body field.
public struct LANSessionProof: Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    public let sessionID: LANSessionID
    public let runtimeGeneration: UInt64
    public let capabilityCookieValue: String
    public let csrfToken: String

    public init(
        sessionID: LANSessionID,
        runtimeGeneration: UInt64,
        capabilityCookieValue: String,
        csrfToken: String
    ) {
        self.sessionID = sessionID
        self.runtimeGeneration = runtimeGeneration
        self.capabilityCookieValue = capabilityCookieValue
        self.csrfToken = csrfToken
    }

    public init(credentials: LANBrowserCredentials) {
        self.init(
            sessionID: credentials.sessionID,
            runtimeGeneration: credentials.runtimeGeneration,
            capabilityCookieValue: credentials.capabilityCookieValue,
            csrfToken: credentials.csrfToken
        )
    }

    public var description: String { "<redacted-session-proof>" }
    public var debugDescription: String { description }
}

/// Cookie-only current-session proof for the same-origin, read-only status GET.
/// It cannot authorize a mutation and intentionally carries no CSRF value.
public struct LANSessionCapabilityProof: Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    public let sessionID: LANSessionID
    public let runtimeGeneration: UInt64
    public let capabilityCookieValue: String

    public init(
        sessionID: LANSessionID,
        runtimeGeneration: UInt64,
        capabilityCookieValue: String
    ) {
        self.sessionID = sessionID
        self.runtimeGeneration = runtimeGeneration
        self.capabilityCookieValue = capabilityCookieValue
    }

    public init(credentials: LANBrowserCredentials) {
        self.init(
            sessionID: credentials.sessionID,
            runtimeGeneration: credentials.runtimeGeneration,
            capabilityCookieValue: credentials.capabilityCookieValue
        )
    }

    public var description: String { "<redacted-capability-proof>" }
    public var debugDescription: String { description }
}

public struct LANAuthorizedSession: Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    public let sessionID: LANSessionID
    public let runtimeGeneration: UInt64

    public var description: String { "<redacted-authorized-session>" }
    public var debugDescription: String { description }
}

public enum LANPairingFailure: Error, Equatable, Sendable {
    /// Wrong, expired, replayed, or otherwise unusable pairing material.
    case rejected
    /// The fixed failure class used while a peer or global cooldown is active.
    case temporarilyLimited
    /// There is no current session that can accept pairing.
    case unavailable
}

public enum LANPairingResult: Equatable, Sendable {
    case paired(LANBrowserCredentials)
    case failed(LANPairingFailure)
}

public enum LANAuthenticationFailure: Error, Equatable, Sendable {
    /// Missing, stale, or mismatched current-session proof.
    case rejected
    /// The authenticated operation exceeded its per-peer request limit.
    case temporarilyLimited
    /// A poll arrived less than one second after the peer's prior allowed poll.
    case pollTooFrequent
    /// There is no current paired session, including after idle expiry.
    case unavailable
}

public enum LANAuthenticationResult: Equatable, Sendable {
    case authorized(LANAuthorizedSession)
    case failed(LANAuthenticationFailure)
}

public enum LANSessionRestorationResult: Equatable, Sendable {
    /// Returns the existing in-memory credentials so a same-origin status GET
    /// can restore the CSRF token for a refreshed page or another browser tab.
    case restored(LANBrowserCredentials)
    case failed(LANAuthenticationFailure)
}

public enum LANAuthenticatedOperation: Equatable, Sendable {
    /// A request whose body has its own streaming admission controls.
    case body
    /// An authenticated operation with no upload body.
    case nonBody
    /// A status poll, which is also subject to the non-body request limit.
    case poll
}

public enum LANSessionState: Equatable, Sendable {
    case inactive
    case awaitingPairing
    case paired
}

public enum LANSessionStartError: Error, Equatable, Sendable {
    case randomnessUnavailable
    case generationExhausted
}

/// Owns exactly one temporary LAN pairing and browser capability at a time.
/// All material and counters are memory-only and are discarded on stop or when
/// a replacement session starts.
public actor LANSession {
    public typealias Clock = @Sendable () -> TimeInterval
    public typealias RandomBytes = @Sendable (Int) throws -> [UInt8]

    private static let pairingLifetime: TimeInterval = 10 * 60
    private static let authenticatedIdleLifetime: TimeInterval = 15 * 60
    private static let rateWindow: TimeInterval = 60
    private static let cooldownLifetime: TimeInterval = 60
    private static let peerCodeFailureLimit = 5
    private static let globalCodeFailureLimit = 30
    private static let peerNonBodyLimit = 60
    private static let minimumPollInterval: TimeInterval = 1
    private static let maximumCodeRandomAttempts = 256

    private struct ActiveSession: Sendable {
        let sessionID: LANSessionID
        let generation: UInt64
        var pairingCode: LANPairingCode?
        let pairingExpiresAt: TimeInterval
        var credentials: LANBrowserCredentials?
        var lastAuthenticatedAt: TimeInterval?
    }

    private struct PeerRateState: Sendable {
        var codeFailures: [TimeInterval] = []
        var codeCooldownUntil: TimeInterval?
        var nonBodyOperations: [TimeInterval] = []
        var lastAllowedPollAt: TimeInterval?

        var isEmpty: Bool {
            codeFailures.isEmpty
                && codeCooldownUntil == nil
                && nonBodyOperations.isEmpty
                && lastAllowedPollAt == nil
        }
    }

    private let clock: Clock
    private let randomBytes: RandomBytes
    private var lastObservedTime: TimeInterval?
    private var nextGeneration: UInt64 = 1
    private var activeSession: ActiveSession?
    private var peerRates: [LANPeerKey: PeerRateState] = [:]
    private var globalCodeFailures: [TimeInterval] = []
    private var globalCodeCooldownUntil: TimeInterval?

    public init() {
        clock = { ProcessInfo.processInfo.systemUptime }
        randomBytes = { count in
            guard count >= 0 else {
                throw LANSessionStartError.randomnessUnavailable
            }
            var generator = SystemRandomNumberGenerator()
            return (0..<count).map { _ in
                UInt8.random(in: UInt8.min ... UInt8.max, using: &generator)
            }
        }
    }

    public init(
        clock: @escaping Clock,
        randomBytes: @escaping RandomBytes
    ) {
        self.clock = clock
        self.randomBytes = randomBytes
    }

    /// Starts a fresh runtime generation. Any previous pairing code and browser
    /// capability are invalidated before new randomness is requested.
    @discardableResult
    public func startNewSession() throws -> LANPairingPresentation {
        activeSession = nil
        peerRates.removeAll(keepingCapacity: true)
        globalCodeFailures.removeAll(keepingCapacity: true)
        globalCodeCooldownUntil = nil

        guard nextGeneration < UInt64.max else {
            throw LANSessionStartError.generationExhausted
        }
        let generation = nextGeneration
        nextGeneration += 1
        let now = monotonicNow()

        do {
            let code = try makeUniformPairingCode()
            guard let sessionID = LANSessionID(
                randomBytes: try exactRandomBytes(count: 16)
            ) else {
                throw LANSessionStartError.randomnessUnavailable
            }
            let credentials = LANBrowserCredentials(
                sessionID: sessionID,
                runtimeGeneration: generation,
                capabilityCookieValue: try makeHexToken(byteCount: 32),
                csrfToken: try makeHexToken(byteCount: 32)
            )
            activeSession = ActiveSession(
                sessionID: sessionID,
                generation: generation,
                pairingCode: code,
                pairingExpiresAt: now + Self.pairingLifetime,
                credentials: credentials,
                lastAuthenticatedAt: nil
            )
            return LANPairingPresentation(
                sessionID: sessionID,
                runtimeGeneration: generation,
                pairingCode: code,
                expiresInSeconds: Int(Self.pairingLifetime)
            )
        } catch {
            activeSession = nil
            throw LANSessionStartError.randomnessUnavailable
        }
    }

    /// Clears all current session material and rate-accounting state.
    public func stop() {
        activeSession = nil
        peerRates.removeAll(keepingCapacity: false)
        globalCodeFailures.removeAll(keepingCapacity: false)
        globalCodeCooldownUntil = nil
    }

    public func currentState() -> LANSessionState {
        let now = monotonicNow()
        expireSessionIfNeeded(at: now)
        guard let activeSession else { return .inactive }
        return activeSession.pairingCode == nil ? .paired : .awaitingPairing
    }

    /// The first matching code consumes the pairing code and returns the single
    /// capability shared by that browser's tabs. Every unsuccessful attempt has
    /// a fixed, phone-safe failure class and never changes authenticated idle.
    public func pair(code candidate: String, from peer: LANPeerKey) -> LANPairingResult {
        let now = monotonicNow()
        pruneRateState(at: now)

        guard activeSession != nil else { return .failed(.unavailable) }
        guard !isCodeLimited(peer: peer, at: now) else {
            return .failed(.temporarilyLimited)
        }

        let expectedCode = activeSession?.pairingCode?.value ?? "000000"
        let codeMatches = LANConstantTime.equal(expectedCode, candidate)
        guard activeSession?.pairingCode != nil,
              let expiresAt = activeSession?.pairingExpiresAt,
              now < expiresAt,
              codeMatches
        else {
            recordCodeFailure(for: peer, at: now)
            return .failed(.rejected)
        }

        guard var session = activeSession, let credentials = session.credentials else {
            // Credentials are generated at session start but are not valid until
            // the code is consumed. This branch is a fail-closed invariant guard.
            recordCodeFailure(for: peer, at: now)
            return .failed(.rejected)
        }
        session.pairingCode = nil
        session.lastAuthenticatedAt = now
        activeSession = session
        return .paired(credentials)
    }

    /// Validates every current-session field and performs rate accounting.
    /// Authorization alone never refreshes idle; the receiver records activity
    /// only after the requested operation is successfully accepted.
    public func authenticate(
        _ proof: LANSessionProof,
        from peer: LANPeerKey,
        operation: LANAuthenticatedOperation
    ) -> LANAuthenticationResult {
        let now = monotonicNow()
        expireSessionIfNeeded(at: now)

        guard let session = activeSession,
              session.pairingCode == nil,
              let credentials = session.credentials
        else {
            return .failed(.unavailable)
        }

        let sessionIDMatches = LANConstantTime.equal(
            credentials.sessionID.rawValue,
            proof.sessionID.rawValue
        )
        let capabilityMatches = LANConstantTime.equal(
            credentials.capabilityCookieValue,
            proof.capabilityCookieValue
        )
        let csrfMatches = LANConstantTime.equal(
            credentials.csrfToken,
            proof.csrfToken
        )
        let generationMatches = credentials.runtimeGeneration == proof.runtimeGeneration
        guard sessionIDMatches, capabilityMatches, csrfMatches, generationMatches else {
            return .failed(.rejected)
        }

        pruneRateState(at: now)
        var peerState = peerRates[peer] ?? PeerRateState()
        if operation == .poll {
            if let lastPoll = peerState.lastAllowedPollAt,
               now - lastPoll < Self.minimumPollInterval
            {
                return .failed(.pollTooFrequent)
            }
        }
        if operation != .body {
            guard peerState.nonBodyOperations.count < Self.peerNonBodyLimit else {
                return .failed(.temporarilyLimited)
            }
            peerState.nonBodyOperations.append(now)
            if operation == .poll {
                peerState.lastAllowedPollAt = now
            }
            peerRates[peer] = peerState
        }

        return .authorized(
            LANAuthorizedSession(
                sessionID: session.sessionID,
                runtimeGeneration: session.generation
            )
        )
    }

    /// Validates the active browser proof and immediately revokes the session.
    /// This is deliberately a single actor operation so no request can restore
    /// or use the capability between successful validation and invalidation.
    public func logout(
        _ proof: LANSessionProof,
        from peer: LANPeerKey
    ) -> LANAuthenticationResult {
        let result = authenticate(proof, from: peer, operation: .nonBody)
        guard case .authorized = result else { return result }
        activeSession = nil
        peerRates.removeAll(keepingCapacity: false)
        return result
    }

    /// Authenticates the same-origin, read-only session status GET using only
    /// the HttpOnly capability cookie and current session identity. Mutations
    /// must continue to use `authenticate`, which also requires the CSRF token.
    public func restoreSession(
        _ proof: LANSessionCapabilityProof,
        from peer: LANPeerKey
    ) -> LANSessionRestorationResult {
        let now = monotonicNow()
        expireSessionIfNeeded(at: now)

        guard let session = activeSession,
              session.pairingCode == nil,
              let credentials = session.credentials
        else {
            return .failed(.unavailable)
        }

        let sessionIDMatches = LANConstantTime.equal(
            credentials.sessionID.rawValue,
            proof.sessionID.rawValue
        )
        let capabilityMatches = LANConstantTime.equal(
            credentials.capabilityCookieValue,
            proof.capabilityCookieValue
        )
        let generationMatches = credentials.runtimeGeneration == proof.runtimeGeneration
        guard sessionIDMatches, capabilityMatches, generationMatches else {
            return .failed(.rejected)
        }

        pruneRateState(at: now)
        var peerState = peerRates[peer] ?? PeerRateState()
        if let lastPoll = peerState.lastAllowedPollAt,
           now - lastPoll < Self.minimumPollInterval
        {
            return .failed(.pollTooFrequent)
        }
        guard peerState.nonBodyOperations.count < Self.peerNonBodyLimit else {
            return .failed(.temporarilyLimited)
        }
        peerState.nonBodyOperations.append(now)
        peerState.lastAllowedPollAt = now
        peerRates[peer] = peerState

        return .restored(credentials)
    }

    /// Commits authenticated idle activity only after a receiver operation has
    /// succeeded or become durably replayable.
    @discardableResult
    public func recordSuccessfulActivity(
        _ authorization: LANAuthorizedSession
    ) -> Bool {
        let now = monotonicNow()
        expireSessionIfNeeded(at: now)
        guard var session = activeSession,
              session.pairingCode == nil,
              session.generation == authorization.runtimeGeneration,
              LANConstantTime.equal(
                session.sessionID.rawValue,
                authorization.sessionID.rawValue
              ) else {
            return false
        }
        session.lastAuthenticatedAt = now
        activeSession = session
        return true
    }

    private func monotonicNow() -> TimeInterval {
        let candidate = clock()
        let finiteCandidate = candidate.isFinite
            ? candidate
            : (lastObservedTime ?? 0)
        let result = max(lastObservedTime ?? finiteCandidate, finiteCandidate)
        lastObservedTime = result
        return result
    }

    private func expireSessionIfNeeded(at now: TimeInterval) {
        guard let session = activeSession else { return }
        if session.pairingCode != nil {
            if now >= session.pairingExpiresAt {
                activeSession = nil
            }
            return
        }
        guard let lastAuthenticatedAt = session.lastAuthenticatedAt else {
            activeSession = nil
            return
        }
        if now - lastAuthenticatedAt >= Self.authenticatedIdleLifetime {
            activeSession = nil
        }
    }

    private func isCodeLimited(peer: LANPeerKey, at now: TimeInterval) -> Bool {
        if let until = globalCodeCooldownUntil, now < until { return true }
        if let until = peerRates[peer]?.codeCooldownUntil, now < until { return true }
        return false
    }

    private func recordCodeFailure(for peer: LANPeerKey, at now: TimeInterval) {
        var peerState = peerRates[peer] ?? PeerRateState()
        peerState.codeFailures.append(now)
        if peerState.codeFailures.count >= Self.peerCodeFailureLimit {
            peerState.codeCooldownUntil = now + Self.cooldownLifetime
        }
        peerRates[peer] = peerState

        globalCodeFailures.append(now)
        if globalCodeFailures.count >= Self.globalCodeFailureLimit {
            globalCodeCooldownUntil = now + Self.cooldownLifetime
        }
    }

    private func pruneRateState(at now: TimeInterval) {
        let cutoff = now - Self.rateWindow
        globalCodeFailures.removeAll { $0 <= cutoff }
        if let until = globalCodeCooldownUntil, now >= until {
            globalCodeCooldownUntil = nil
        }

        for peer in Array(peerRates.keys) {
            guard var state = peerRates[peer] else { continue }
            state.codeFailures.removeAll { $0 <= cutoff }
            state.nonBodyOperations.removeAll { $0 <= cutoff }
            if let until = state.codeCooldownUntil, now >= until {
                state.codeCooldownUntil = nil
            }
            if let lastPoll = state.lastAllowedPollAt,
               now - lastPoll >= Self.rateWindow
            {
                state.lastAllowedPollAt = nil
            }
            if state.isEmpty {
                peerRates.removeValue(forKey: peer)
            } else {
                peerRates[peer] = state
            }
        }
    }

    private func makeUniformPairingCode() throws -> LANPairingCode {
        // 2^32 contains 4,294 complete million-value ranges. Reject the
        // incomplete tail before modulo reduction to avoid distribution bias.
        let upperExclusive = UInt32.max - (UInt32.max % 1_000_000)
        for _ in 0..<Self.maximumCodeRandomAttempts {
            let bytes = try exactRandomBytes(count: 4)
            let sample = bytes.reduce(UInt32.zero) { partial, byte in
                (partial << 8) | UInt32(byte)
            }
            guard sample < upperExclusive else { continue }
            let value = sample % 1_000_000
            return LANPairingCode(value: String(format: "%06u", value))
        }
        throw LANSessionStartError.randomnessUnavailable
    }

    private func makeHexToken(byteCount: Int) throws -> String {
        let bytes = try exactRandomBytes(count: byteCount)
        let alphabet = Array("0123456789abcdef".utf8)
        var output = [UInt8]()
        output.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            output.append(alphabet[Int(byte >> 4)])
            output.append(alphabet[Int(byte & 0x0F)])
        }
        return String(decoding: output, as: UTF8.self)
    }

    private func exactRandomBytes(count: Int) throws -> [UInt8] {
        let bytes = try randomBytes(count)
        guard bytes.count == count else {
            throw LANSessionStartError.randomnessUnavailable
        }
        return bytes
    }
}

internal enum LANConstantTime {
    /// Compares exactly the expected byte length plus one sentinel byte. The
    /// number of comparison rounds is independent of the candidate's prefix.
    static func equal(_ expected: String, _ candidate: String) -> Bool {
        let expectedBytes = Array(expected.utf8)
        let candidateBytes = Array(candidate.utf8.prefix(expectedBytes.count + 1))
        var difference = UInt64(expectedBytes.count ^ candidateBytes.count)
        for index in expectedBytes.indices {
            let candidateByte = index < candidateBytes.count
                ? candidateBytes[index]
                : 0
            difference |= UInt64(expectedBytes[index] ^ candidateByte)
        }
        return difference == 0
    }
}
