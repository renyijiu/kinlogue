import Foundation
import Testing
@testable import KinloguePlatform

struct LANSessionTests {
    @Test
    func pairingCodeUsesUnbiasedRejectionAndSixDigitFormatting() async throws {
        let fixture = try SessionFixture()
        fixture.entropy.appendRaw(Array(repeating: 0xFF, count: 4))
        fixture.entropy.appendSessionMaterial(codeSample: 42, seed: 0x10)

        let presentation = try await fixture.session.startNewSession()

        #expect(presentation.pairingCode.value == "000042")
        #expect(presentation.pairingCode.value.count == 6)
        #expect(presentation.expiresInSeconds == 600)
        #expect(presentation.runtimeGeneration == 1)
        #expect(await fixture.session.currentState() == .awaitingPairing)
    }

    @Test
    func firstConcurrentSuccessfulPairConsumesTheCode() async throws {
        let fixture = try SessionFixture()
        fixture.entropy.appendSessionMaterial(codeSample: 123_456, seed: 0x20)
        let presentation = try await fixture.session.startNewSession()

        async let first = fixture.session.pair(
            code: presentation.pairingCode.value,
            from: fixture.peerA
        )
        async let second = fixture.session.pair(
            code: presentation.pairingCode.value,
            from: fixture.peerB
        )
        let results = await [first, second]

        #expect(results.filter(\.isPaired).count == 1)
        #expect(results.filter { $0 == .failed(.rejected) }.count == 1)
        #expect(await fixture.session.currentState() == .paired)
    }

    @Test
    func wrongExpiredAndReplayedCodesShareTheRejectedClass() async throws {
        let wrongFixture = try SessionFixture()
        wrongFixture.entropy.appendSessionMaterial(codeSample: 111_111, seed: 0x30)
        _ = try await wrongFixture.session.startNewSession()
        #expect(
            await wrongFixture.session.pair(code: "999999", from: wrongFixture.peerA)
                == .failed(.rejected)
        )

        let expiryFixture = try SessionFixture()
        expiryFixture.entropy.appendSessionMaterial(codeSample: 222_222, seed: 0x40)
        let expiryPresentation = try await expiryFixture.session.startNewSession()
        expiryFixture.clock.advance(by: 600)
        #expect(
            await expiryFixture.session.pair(
                code: expiryPresentation.pairingCode.value,
                from: expiryFixture.peerA
            ) == .failed(.rejected)
        )
        #expect(await expiryFixture.session.currentState() == .inactive)

        let replayFixture = try SessionFixture()
        replayFixture.entropy.appendSessionMaterial(codeSample: 333_333, seed: 0x50)
        let replayPresentation = try await replayFixture.session.startNewSession()
        let first = await replayFixture.session.pair(
            code: replayPresentation.pairingCode.value,
            from: replayFixture.peerA
        )
        #expect(first.isPaired)
        #expect(
            await replayFixture.session.pair(
                code: replayPresentation.pairingCode.value,
                from: replayFixture.peerA
            ) == .failed(.rejected)
        )
    }

    @Test
    func credentialsHaveRequiredEntropyAndRemainSharedAcrossPeers() async throws {
        let fixture = try SessionFixture()
        fixture.entropy.appendSessionMaterial(codeSample: 444_444, seed: 0x60)
        let (_, credentials) = try await fixture.startAndPair()
        let proof = LANSessionProof(credentials: credentials)

        #expect(credentials.sessionID.rawValue.utf8.count == 32)
        #expect(LANSessionID(uuid: credentials.sessionID.uuid) == credentials.sessionID)
        #expect(LANSessionID(rawValue: credentials.sessionID.rawValue)?.uuid == credentials.sessionID.uuid)
        #expect(credentials.capabilityCookieValue.utf8.count == 64)
        #expect(credentials.csrfToken.utf8.count == 64)
        #expect(credentials.capabilityCookieValue != credentials.csrfToken)
        #expect(
            await fixture.session.authenticate(proof, from: fixture.peerA, operation: .body)
                .isAuthorized
        )
        #expect(
            await fixture.session.authenticate(proof, from: fixture.peerB, operation: .body)
                .isAuthorized
        )
    }

    @Test
    func authenticationRequiresEveryExactCurrentSessionField() async throws {
        let fixture = try SessionFixture()
        fixture.entropy.appendSessionMaterial(codeSample: 555_555, seed: 0x70)
        let (_, credentials) = try await fixture.startAndPair()
        let valid = LANSessionProof(credentials: credentials)
        let differentID = try #require(
            LANSessionID(rawValue: togglingFirstHexDigit(credentials.sessionID.rawValue))
        )
        let invalidProofs = [
            LANSessionProof(
                sessionID: differentID,
                runtimeGeneration: credentials.runtimeGeneration,
                capabilityCookieValue: credentials.capabilityCookieValue,
                csrfToken: credentials.csrfToken
            ),
            LANSessionProof(
                sessionID: credentials.sessionID,
                runtimeGeneration: credentials.runtimeGeneration + 1,
                capabilityCookieValue: credentials.capabilityCookieValue,
                csrfToken: credentials.csrfToken
            ),
            LANSessionProof(
                sessionID: credentials.sessionID,
                runtimeGeneration: credentials.runtimeGeneration,
                capabilityCookieValue: "missing",
                csrfToken: credentials.csrfToken
            ),
            LANSessionProof(
                sessionID: credentials.sessionID,
                runtimeGeneration: credentials.runtimeGeneration,
                capabilityCookieValue: credentials.capabilityCookieValue,
                csrfToken: "missing"
            ),
        ]

        for proof in invalidProofs {
            #expect(
                await fixture.session.authenticate(proof, from: fixture.peerA, operation: .body)
                    == .failed(.rejected)
            )
        }
        #expect(
            await fixture.session.authenticate(valid, from: fixture.peerA, operation: .body)
                .isAuthorized
        )
    }

    @Test
    func failedAndUnauthenticatedTrafficNeverRefreshesIdle() async throws {
        let fixture = try SessionFixture()
        fixture.entropy.appendSessionMaterial(codeSample: 666_666, seed: 0x80)
        let (presentation, credentials) = try await fixture.startAndPair()
        let invalid = LANSessionProof(
            sessionID: credentials.sessionID,
            runtimeGeneration: credentials.runtimeGeneration,
            capabilityCookieValue: "invalid",
            csrfToken: credentials.csrfToken
        )

        fixture.clock.advance(by: 899)
        #expect(
            await fixture.session.authenticate(invalid, from: fixture.peerA, operation: .body)
                == .failed(.rejected)
        )
        #expect(
            await fixture.session.pair(
                code: presentation.pairingCode.value,
                from: fixture.peerA
            ) == .failed(.rejected)
        )
        fixture.clock.advance(by: 1)
        #expect(
            await fixture.session.authenticate(
                LANSessionProof(credentials: credentials),
                from: fixture.peerA,
                operation: .body
            ) == .failed(.unavailable)
        )
        #expect(await fixture.session.currentState() == .inactive)
    }

    @Test
    func onlyRecordedSuccessfulActivityRefreshesFifteenMinuteIdleWindow() async throws {
        let fixture = try SessionFixture()
        fixture.entropy.appendSessionMaterial(codeSample: 777_777, seed: 0x90)
        let (_, credentials) = try await fixture.startAndPair()
        let proof = LANSessionProof(credentials: credentials)

        fixture.clock.advance(by: 899)
        let first = await fixture.session.authenticate(
            proof,
            from: fixture.peerA,
            operation: .body
        )
        let firstAuthorization = try #require(first.authorization)
        #expect(await fixture.session.recordSuccessfulActivity(firstAuthorization))
        fixture.clock.advance(by: 899)
        let second = await fixture.session.authenticate(
            proof,
            from: fixture.peerA,
            operation: .body
        )
        let secondAuthorization = try #require(second.authorization)
        #expect(await fixture.session.recordSuccessfulActivity(secondAuthorization))
        fixture.clock.advance(by: 900)
        #expect(
            await fixture.session.authenticate(proof, from: fixture.peerA, operation: .body)
                == .failed(.unavailable)
        )
    }

    @Test
    func authorizationWithoutSuccessfulActivityDoesNotRefreshIdle() async throws {
        let fixture = try SessionFixture()
        fixture.entropy.appendSessionMaterial(codeSample: 787_878, seed: 0x91)
        let (_, credentials) = try await fixture.startAndPair()
        let proof = LANSessionProof(credentials: credentials)

        fixture.clock.advance(by: 899)
        #expect(
            await fixture.session.authenticate(
                proof,
                from: fixture.peerA,
                operation: .body
            ).isAuthorized
        )
        fixture.clock.advance(by: 1)
        #expect(
            await fixture.session.authenticate(
                proof,
                from: fixture.peerA,
                operation: .body
            ) == .failed(.unavailable)
        )
    }

    @Test
    func aNewSessionInvalidatesEveryOldCredentialAndAdvancesGeneration() async throws {
        let fixture = try SessionFixture()
        fixture.entropy.appendSessionMaterial(codeSample: 101_010, seed: 0xA0)
        fixture.entropy.appendSessionMaterial(codeSample: 202_020, seed: 0xB0)
        let (oldPresentation, oldCredentials) = try await fixture.startAndPair()
        let replacement = try await fixture.session.startNewSession()

        #expect(replacement.runtimeGeneration == oldPresentation.runtimeGeneration + 1)
        #expect(
            await fixture.session.authenticate(
                LANSessionProof(credentials: oldCredentials),
                from: fixture.peerA,
                operation: .body
            ) == .failed(.unavailable)
        )
        #expect(
            await fixture.session.pair(
                code: oldPresentation.pairingCode.value,
                from: fixture.peerA
            ) == .failed(.rejected)
        )
        let replacementResult = await fixture.session.pair(
            code: replacement.pairingCode.value,
            from: fixture.peerA
        )
        #expect(replacementResult.isPaired)
    }

    @Test
    func failedReplacementStartStillInvalidatesOldCredentials() async throws {
        let fixture = try SessionFixture()
        fixture.entropy.appendSessionMaterial(codeSample: 303_030, seed: 0xC0)
        let (_, oldCredentials) = try await fixture.startAndPair()

        do {
            _ = try await fixture.session.startNewSession()
            Issue.record("Expected exhausted deterministic randomness to fail")
        } catch {
            #expect(error as? LANSessionStartError == .randomnessUnavailable)
        }
        #expect(
            await fixture.session.authenticate(
                LANSessionProof(credentials: oldCredentials),
                from: fixture.peerA,
                operation: .body
            ) == .failed(.unavailable)
        )
    }

    @Test
    func peerCodeFailureLimitCoolsOnlyThatPeerForSixtySeconds() async throws {
        let fixture = try SessionFixture()
        fixture.entropy.appendSessionMaterial(codeSample: 404_040, seed: 0xD0)
        let presentation = try await fixture.session.startNewSession()

        for _ in 0..<5 {
            #expect(
                await fixture.session.pair(code: "000000", from: fixture.peerA)
                    == .failed(.rejected)
            )
        }
        #expect(
            await fixture.session.pair(
                code: presentation.pairingCode.value,
                from: fixture.peerA
            ) == .failed(.temporarilyLimited)
        )
        #expect(
            await fixture.session.pair(
                code: presentation.pairingCode.value,
                from: fixture.peerB
            ).isPaired
        )
    }

    @Test
    func globalCodeFailureLimitCoolsEveryPeerForSixtySeconds() async throws {
        let fixture = try SessionFixture()
        fixture.entropy.appendSessionMaterial(codeSample: 505_050, seed: 0xE0)
        let presentation = try await fixture.session.startNewSession()
        var failingPeers: [LANPeerKey] = []
        for value in 10..<16 {
            failingPeers.append(try LANPeerKey(socketDerivedBytes: [UInt8(value)]))
        }

        for peer in failingPeers {
            for _ in 0..<5 {
                #expect(
                    await fixture.session.pair(code: "000000", from: peer)
                        == .failed(.rejected)
                )
            }
        }
        #expect(
            await fixture.session.pair(
                code: presentation.pairingCode.value,
                from: fixture.peerB
            ) == .failed(.temporarilyLimited)
        )
        fixture.clock.advance(by: 60)
        #expect(
            await fixture.session.pair(
                code: presentation.pairingCode.value,
                from: fixture.peerB
            ).isPaired
        )
    }

    @Test
    func authenticatedNonBodyOperationsAreLimitedPerPeerAndWindow() async throws {
        let fixture = try SessionFixture()
        fixture.entropy.appendSessionMaterial(codeSample: 606_060, seed: 0xF0)
        let (_, credentials) = try await fixture.startAndPair()
        let proof = LANSessionProof(credentials: credentials)

        for _ in 0..<60 {
            #expect(
                await fixture.session.authenticate(
                    proof,
                    from: fixture.peerA,
                    operation: .nonBody
                ).isAuthorized
            )
        }
        #expect(
            await fixture.session.authenticate(proof, from: fixture.peerA, operation: .nonBody)
                == .failed(.temporarilyLimited)
        )
        #expect(
            await fixture.session.authenticate(proof, from: fixture.peerB, operation: .nonBody)
                .isAuthorized
        )
        fixture.clock.advance(by: 60)
        #expect(
            await fixture.session.authenticate(proof, from: fixture.peerA, operation: .nonBody)
                .isAuthorized
        )
    }

    @Test
    func pollingIsAllowedAtMostOncePerSecondPerPeer() async throws {
        let fixture = try SessionFixture()
        fixture.entropy.appendSessionMaterial(codeSample: 707_070, seed: 0x12)
        let (_, credentials) = try await fixture.startAndPair()
        let proof = LANSessionProof(credentials: credentials)

        #expect(
            await fixture.session.authenticate(proof, from: fixture.peerA, operation: .poll)
                .isAuthorized
        )
        fixture.clock.advance(by: 0.999)
        #expect(
            await fixture.session.authenticate(proof, from: fixture.peerA, operation: .poll)
                == .failed(.pollTooFrequent)
        )
        #expect(
            await fixture.session.authenticate(proof, from: fixture.peerB, operation: .poll)
                .isAuthorized
        )
        fixture.clock.advance(by: 0.001)
        #expect(
            await fixture.session.authenticate(proof, from: fixture.peerA, operation: .poll)
                .isAuthorized
        )
    }

    @Test
    func cookieOnlyRestoreReturnsExistingCSRFForRefreshAndOtherTabs() async throws {
        let fixture = try SessionFixture()
        fixture.entropy.appendSessionMaterial(codeSample: 717_171, seed: 0x23)
        let (_, credentials) = try await fixture.startAndPair()
        let capability = LANSessionCapabilityProof(credentials: credentials)

        let first = await fixture.session.restoreSession(capability, from: fixture.peerA)
        let second = await fixture.session.restoreSession(capability, from: fixture.peerB)

        guard case let .restored(firstCredentials) = first,
              case let .restored(secondCredentials) = second
        else {
            Issue.record("Expected both tabs to restore the current capability")
            return
        }
        #expect(firstCredentials == credentials)
        #expect(secondCredentials == credentials)
        #expect(firstCredentials.csrfToken == credentials.csrfToken)
    }

    @Test
    func cookieOnlyRestoreRejectsEveryStaleOrMismatchedField() async throws {
        let fixture = try SessionFixture()
        fixture.entropy.appendSessionMaterial(codeSample: 727_272, seed: 0x35)
        fixture.entropy.appendSessionMaterial(codeSample: 737_373, seed: 0x45)
        let (_, oldCredentials) = try await fixture.startAndPair()
        let newPresentation = try await fixture.session.startNewSession()
        let newResult = await fixture.session.pair(
            code: newPresentation.pairingCode.value,
            from: fixture.peerA
        )
        let newCredentials = try #require(newResult.credentials)
        let differentID = try #require(
            LANSessionID(rawValue: togglingFirstHexDigit(newCredentials.sessionID.rawValue))
        )
        let invalidProofs = [
            LANSessionCapabilityProof(credentials: oldCredentials),
            LANSessionCapabilityProof(
                sessionID: differentID,
                runtimeGeneration: newCredentials.runtimeGeneration,
                capabilityCookieValue: newCredentials.capabilityCookieValue
            ),
            LANSessionCapabilityProof(
                sessionID: newCredentials.sessionID,
                runtimeGeneration: newCredentials.runtimeGeneration + 1,
                capabilityCookieValue: newCredentials.capabilityCookieValue
            ),
            LANSessionCapabilityProof(
                sessionID: newCredentials.sessionID,
                runtimeGeneration: newCredentials.runtimeGeneration,
                capabilityCookieValue: "invalid"
            ),
        ]

        for proof in invalidProofs {
            #expect(
                await fixture.session.restoreSession(proof, from: fixture.peerA)
                    == .failed(.rejected)
            )
        }
    }

    @Test
    func cookieOnlyRestoreUsesPollAndNonBodyLimitsWithoutFailedIdleRefresh() async throws {
        let fixture = try SessionFixture()
        fixture.entropy.appendSessionMaterial(codeSample: 747_474, seed: 0x56)
        let (_, credentials) = try await fixture.startAndPair()
        let capability = LANSessionCapabilityProof(credentials: credentials)
        let fullProof = LANSessionProof(credentials: credentials)

        #expect(
            await fixture.session.restoreSession(capability, from: fixture.peerA).isRestored
        )
        fixture.clock.advance(by: 0.999)
        #expect(
            await fixture.session.restoreSession(capability, from: fixture.peerA)
                == .failed(.pollTooFrequent)
        )
        fixture.clock.advance(by: 0.001)
        #expect(
            await fixture.session.restoreSession(capability, from: fixture.peerA).isRestored
        )

        fixture.clock.advance(by: 60)
        for _ in 0..<60 {
            #expect(
                await fixture.session.authenticate(
                    fullProof,
                    from: fixture.peerB,
                    operation: .nonBody
                ).isAuthorized
            )
        }
        fixture.clock.advance(by: 0.5)
        #expect(
            await fixture.session.restoreSession(capability, from: fixture.peerB)
                == .failed(.temporarilyLimited)
        )
        fixture.clock.advance(by: 899.5)
        #expect(
            await fixture.session.restoreSession(capability, from: fixture.peerB)
                == .failed(.unavailable)
        )
    }

    @Test
    func invalidCookieOnlyRestoreDoesNotRefreshIdle() async throws {
        let fixture = try SessionFixture()
        fixture.entropy.appendSessionMaterial(codeSample: 757_575, seed: 0x67)
        let (_, credentials) = try await fixture.startAndPair()
        let invalid = LANSessionCapabilityProof(
            sessionID: credentials.sessionID,
            runtimeGeneration: credentials.runtimeGeneration,
            capabilityCookieValue: "invalid"
        )

        fixture.clock.advance(by: 899)
        #expect(
            await fixture.session.restoreSession(invalid, from: fixture.peerA)
                == .failed(.rejected)
        )
        fixture.clock.advance(by: 1)
        #expect(
            await fixture.session.restoreSession(
                LANSessionCapabilityProof(credentials: credentials),
                from: fixture.peerA
            ) == .failed(.unavailable)
        )
    }

    @Test
    func descriptionsNeverExposePairingOrCapabilityMaterial() async throws {
        let fixture = try SessionFixture()
        fixture.entropy.appendSessionMaterial(codeSample: 808_080, seed: 0x34)
        let (presentation, credentials) = try await fixture.startAndPair()
        let proof = LANSessionProof(credentials: credentials)
        let capability = LANSessionCapabilityProof(credentials: credentials)
        let pairingResult = LANPairingResult.paired(credentials)
        let restorationResult = LANSessionRestorationResult.restored(credentials)
        let values = [
            String(describing: presentation),
            String(reflecting: presentation),
            String(describing: credentials),
            String(reflecting: credentials),
            String(describing: proof),
            String(reflecting: proof),
            String(describing: capability),
            String(reflecting: capability),
            String(describing: pairingResult),
            String(reflecting: pairingResult),
            String(describing: restorationResult),
            String(reflecting: restorationResult),
            String(describing: fixture.peerA),
            String(reflecting: fixture.peerA),
        ]

        for value in values {
            #expect(!value.contains(presentation.pairingCode.value))
            #expect(!value.contains(credentials.capabilityCookieValue))
            #expect(!value.contains(credentials.csrfToken))
            #expect(!value.contains(credentials.sessionID.rawValue))
        }
    }

    @Test
    func invalidPeerAndSessionIdentifiersFailClosed() throws {
        #expect(throws: LANPeerKeyError.invalidKey) {
            _ = try LANPeerKey(socketDerivedBytes: [])
        }
        #expect(LANSessionID(rawValue: "") == nil)
        #expect(LANSessionID(rawValue: String(repeating: "g", count: 32)) == nil)
        #expect(LANSessionID(rawValue: String(repeating: "a", count: 32)) != nil)
        #expect(LANConstantTime.equal("123456", "123456"))
        #expect(!LANConstantTime.equal("123456", "123457"))
        #expect(!LANConstantTime.equal("123456", "1234567"))
        #expect(!LANConstantTime.equal("123456", "12345"))
    }
}

private extension LANPairingResult {
    var isPaired: Bool {
        if case .paired = self { return true }
        return false
    }

    var credentials: LANBrowserCredentials? {
        if case let .paired(credentials) = self { return credentials }
        return nil
    }
}

private extension LANAuthenticationResult {
    var isAuthorized: Bool {
        if case .authorized = self { return true }
        return false
    }

    var authorization: LANAuthorizedSession? {
        if case let .authorized(authorization) = self { return authorization }
        return nil
    }
}

private extension LANSessionRestorationResult {
    var isRestored: Bool {
        if case .restored = self { return true }
        return false
    }
}

private final class ManualSessionClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval

    init(_ value: TimeInterval = 100) {
        self.value = value
    }

    func now() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        value += interval
        lock.unlock()
    }
}

private final class SessionEntropy: @unchecked Sendable {
    enum EntropyError: Error {
        case exhausted
    }

    private let lock = NSLock()
    private var outputs: [[UInt8]] = []

    func appendRaw(_ bytes: [UInt8]) {
        lock.lock()
        outputs.append(bytes)
        lock.unlock()
    }

    func appendSessionMaterial(codeSample: UInt32, seed: UInt8) {
        appendRaw([
            UInt8((codeSample >> 24) & 0xFF),
            UInt8((codeSample >> 16) & 0xFF),
            UInt8((codeSample >> 8) & 0xFF),
            UInt8(codeSample & 0xFF),
        ])
        appendRaw(Array(repeating: seed, count: 16))
        appendRaw(Array(repeating: seed &+ 1, count: 32))
        appendRaw(Array(repeating: seed &+ 2, count: 32))
    }

    func next(count: Int) throws -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        guard !outputs.isEmpty else { throw EntropyError.exhausted }
        return outputs.removeFirst()
    }
}

private struct SessionFixture {
    let clock = ManualSessionClock()
    let entropy = SessionEntropy()
    let session: LANSession
    let peerA: LANPeerKey
    let peerB: LANPeerKey

    init() throws {
        let clock = self.clock
        let entropy = self.entropy
        session = LANSession(
            clock: { clock.now() },
            randomBytes: { try entropy.next(count: $0) }
        )
        peerA = try LANPeerKey(socketDerivedBytes: [0x01, 0x02, 0x03])
        peerB = try LANPeerKey(socketDerivedBytes: [0x04, 0x05, 0x06])
    }

    func startAndPair() async throws -> (LANPairingPresentation, LANBrowserCredentials) {
        let presentation = try await session.startNewSession()
        let result = await session.pair(
            code: presentation.pairingCode.value,
            from: peerA
        )
        guard case let .paired(credentials) = result else {
            Issue.record("Expected deterministic pairing to succeed")
            throw SessionFixtureError.pairingFailed
        }
        return (presentation, credentials)
    }
}

private enum SessionFixtureError: Error {
    case pairingFailed
}

private func togglingFirstHexDigit(_ value: String) -> String {
    guard let first = value.first else { return value }
    return String(first == "0" ? "1" : "0") + value.dropFirst()
}
