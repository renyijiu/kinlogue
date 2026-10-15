import Foundation
import KinlogueAssistantCLI
import KinlogueAssistantIPC
import os
import Testing
@testable import KinlogueCore
@testable import KinloguePlatform

/// `BridgeAssistantProvider` end to end: the Core request is encoded, crosses a client that calls
/// `CodexBridge` in process instead of over XPC, runs the fake CLI, and comes back as a Core reply
/// or a Core failure.
@Suite(.serialized)
struct AssistantProviderTests {
    @Test
    func aTurnReturnsTheCLIAnswerAsACoreReply() async throws {
        let setup = try ProviderSetup(scenario: ["check": "clean", "turn": "answer"])
        defer { setup.remove() }
        let input = "<records>\n合成\n</records>\n\n<question>\n合成问题\n</question>\n"

        let reply = try await setup.provider.respond(to: AssistantProviderRequest(
            model: "gpt-synthetic", instructions: AssistantPrompt.instructions, input: input
        ))

        #expect(reply.answer == "fake answer bytes=\(input.utf8.count)")
        #expect(reply.provider == (try AssistantProviderDescriptor(kind: .codex, cliVersion: "0.162.0", model: "gpt-synthetic")))
    }

    @Test
    func bridgeFailuresBecomeCoreFailures() async throws {
        let cases: [([String: Any], AssistantFailure)] = [
            (["check": "clean", "turn": "failed401"], .notLoggedIn),
            (["check": "clean", "turn": "rateLimited"], .rateLimited),
            (["check": "clean", "turn": "exit3"], .failed(exitCode: 3)),
            (["check": "clean", "turn": "toolUse"], .toolUseDetected),
            (["check": "tools", "turn": "answer"], .unsupportedCLI),
        ]
        for (scenario, expected) in cases {
            let setup = try ProviderSetup(scenario: scenario)
            defer { setup.remove() }
            await #expect(throws: expected, "\(scenario)") {
                _ = try await setup.provider.respond(to: syntheticRequest())
            }
        }

        let missing = try ProviderSetup(scenario: [:], executable: "/nonexistent/synthetic/codex")
        defer { missing.remove() }
        await #expect(throws: AssistantFailure.cliNotFound) {
            _ = try await missing.provider.respond(to: syntheticRequest())
        }
    }

    @Test
    func cancellingTheTaskStopsTheTurn() async throws {
        let setup = try ProviderSetup(scenario: ["check": "clean", "turn": "hang"])
        defer { setup.remove() }
        _ = await setup.provider.status(model: "gpt-synthetic")

        let turn = Task { try await setup.provider.respond(to: syntheticRequest()) }
        let codex = try setup.home.waitForPID("codex.pid")
        turn.cancel()

        await #expect(throws: AssistantFailure.cancelled) { _ = try await turn.value }
        #expect(setup.client.cancelledRequests.count == 1)
        let deadline = Date().addingTimeInterval(5)
        while kill(codex, 0) == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(kill(codex, 0) != 0)
    }

    @Test
    func statusMapsTheBridgeReport() async throws {
        let ready = try ProviderSetup(scenario: ["check": "clean"])
        defer { ready.remove() }
        let status = await ready.provider.status(model: "gpt-synthetic")
        #expect(status.failure == nil)
        #expect(status.cliVersion == "0.162.0")
        #expect(status.isLoggedIn)
        #expect(status.isVerifiedVersion)
        #expect(status.executablePath?.hasSuffix("/KinlogueAssistantCLIFixture") == true)
        #expect(status.model == "gpt-synthetic")
        #expect(await ready.provider.status(model: nil).model == "gpt-synthetic", "the first model of the CLI's catalog")

        let loggedOut = try ProviderSetup(scenario: ["check": "clean", "loggedOut": true])
        defer { loggedOut.remove() }
        #expect(await loggedOut.provider.status(model: nil).failure == .notLoggedIn)
    }

    @Test
    func aMissingOrBrokenBridgeIsReportedAsUnavailable() async throws {
        for client in [SilentClient(reply: nil), SilentClient(reply: Data("not a property list".utf8))] {
            let provider = BridgeAssistantProvider(client: client, settings: try AssistantCLISettings(executablePath: nil, proxy: [:]))
            await #expect(throws: AssistantFailure.bridgeUnavailable) { _ = try await provider.respond(to: syntheticRequest()) }
            #expect(await provider.status(model: nil).failure == .bridgeUnavailable)
        }
    }

    @Test
    func settingsRejectWhatTheBridgeWouldRefuse() throws {
        _ = try AssistantCLISettings(executablePath: "/opt/homebrew/bin/codex", proxy: ["HTTPS_PROXY": "http://127.0.0.1:6152"])
        #expect(throws: AssistantCLISettingsError.invalid) {
            try AssistantCLISettings(executablePath: "codex", proxy: [:])
        }
        #expect(throws: AssistantCLISettingsError.invalid) {
            try AssistantCLISettings(executablePath: nil, proxy: ["DYLD_INSERT_LIBRARIES": "/tmp/x"])
        }
        #expect(KinlogueAssistantService.name == "com.kinlogue.mac.assistant-bridge")
    }
}

// MARK: - Fixtures

private func syntheticRequest() -> AssistantProviderRequest {
    AssistantProviderRequest(model: "gpt-synthetic", instructions: "Synthetic instructions", input: "Synthetic input")
}

private final class ProviderFixtureLocator {}

private struct ProviderSetup {
    let home: ProviderHome
    let client: InProcessBridgeClient
    let provider: BridgeAssistantProvider

    init(scenario: [String: Any], executable: String? = nil) throws {
        home = try ProviderHome(scenario: scenario)
        let fixture = Bundle(for: ProviderFixtureLocator.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("KinlogueAssistantCLIFixture")
        var limits = CLIProcessLimits()
        limits.startTimeout = 10
        limits.totalTimeout = 20
        limits.terminationGrace = 0.3
        let bridge = try CodexBridge(environment: CodexBridgeEnvironment(
            home: home.path, userName: "kl-synthetic-user", temporaryRoot: URL(fileURLWithPath: home.path + "/runs"),
            supervisor: fixture.path, candidatePaths: [], limits: limits
        ))
        client = InProcessBridgeClient(bridge: bridge)
        provider = BridgeAssistantProvider(
            client: client, settings: try AssistantCLISettings(executablePath: executable ?? home.codexPath, proxy: [:])
        )
    }

    func remove() { home.remove() }
}

/// Calls the bridge directly, as the XPC service would, including cancellation of a cancelled task.
private final class InProcessBridgeClient: KinlogueAssistantBridgeClient {
    let bridge: CodexBridge
    private let cancelled = OSAllocatedUnfairLock(initialState: [UUID]())

    init(bridge: CodexBridge) { self.bridge = bridge }

    var cancelledRequests: [UUID] { cancelled.withLock { $0 } }

    func status(_ request: Data) async -> Data? {
        await offload { [bridge] in
            guard let request = try? KinlogueAssistantIPCCodec.decodeStatusRequest(request) else { return nil }
            return try? KinlogueAssistantIPCCodec.encode(bridge.status(configuration: request.configuration, model: request.model))
        }
    }

    func respond(_ request: Data, requestID: UUID) async -> Data? {
        await withTaskCancellationHandler {
            await offload { [bridge] in
                guard let request = try? KinlogueAssistantIPCCodec.decodeTurnRequest(request) else { return nil }
                return try? KinlogueAssistantIPCCodec.encode(bridge.respond(request, cancellation: CLICancellation()))
            }
        } onCancel: { [bridge, cancelled] in
            cancelled.withLock { $0.append(requestID) }
            _ = bridge.cancel(requestID: requestID)
        }
    }

    func cancel(requestID: UUID) async -> Bool {
        cancelled.withLock { $0.append(requestID) }
        return bridge.cancel(requestID: requestID)
    }

    private func offload(_ work: @escaping @Sendable () -> Data?) async -> Data? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: work()) }
        }
    }
}

/// A bridge that is gone or answers with garbage.
private struct SilentClient: KinlogueAssistantBridgeClient {
    let reply: Data?
    func status(_ request: Data) async -> Data? { reply }
    func respond(_ request: Data, requestID: UUID) async -> Data? { reply }
    func cancel(requestID: UUID) async -> Bool { false }
}

private struct ProviderHome {
    let path: String

    init(scenario: [String: Any]) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kl-provider-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
        guard let resolved = realpath(root.path, nil) else { throw CocoaError(.fileNoSuchFile) }
        path = String(cString: resolved)
        free(resolved)
        let fixture = Bundle(for: ProviderFixtureLocator.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("KinlogueAssistantCLIFixture")
        try FileManager.default.createSymbolicLink(
            at: URL(fileURLWithPath: path + "/bin/codex"), withDestinationURL: fixture
        )
        try JSONSerialization.data(withJSONObject: scenario).write(to: URL(fileURLWithPath: path + "/kl-fake-codex.json"))
    }

    var codexPath: String { path + "/bin/codex" }

    func waitForPID(_ name: String) throws -> pid_t {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let text = try? String(contentsOfFile: path + "/" + name, encoding: .utf8),
               let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) { return pid }
            usleep(20_000)
        }
        throw CocoaError(.fileReadNoSuchFile)
    }

    func remove() { try? FileManager.default.removeItem(atPath: path) }
}
