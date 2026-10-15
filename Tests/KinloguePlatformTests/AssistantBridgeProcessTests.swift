import Foundation
import KinlogueAssistantCLI
import KinlogueAssistantIPC
import Testing

/// The bridge's process handling and Codex flow, driven against `KinlogueAssistantCLIFixture`, a
/// fake `codex` that reads its scenario from `$HOME/kl-fake-codex.json`. Nothing here runs a real
/// CLI or reaches a network beyond 127.0.0.1.
@Suite(.serialized)
struct AssistantBridgeProcessTests {
    @Test
    func runnerFeedsStdinAndKeepsTheInputOutOfArgumentsAndEnvironment() throws {
        let home = try FakeHome(scenario: ["turn": "answer"])
        defer { home.remove() }
        let input = Data(("<records>KL-SECRET-INPUT</records>" + String(repeating: "合成", count: 40_000)).utf8)
        var lines: [String] = []

        let result = CLIProcess.run(
            executable: try fixtureExecutable(),
            arguments: ["exec", "--json", "-"],
            environment: ["HOME": home.path, "PATH": "/usr/bin:/bin"],
            workingDirectory: home.path,
            input: input,
            supervisor: try fixtureExecutable(),
            limits: .testing,
            cancellation: nil,
            onLine: { lines.append(String(decoding: $0, as: UTF8.self)) }
        )

        #expect(result.ending == .exited(0))
        #expect(lines.contains { $0.contains("fake answer bytes=\(input.count)") })
        let record = try home.record()
        #expect(record["stdinBytes"] as? Int == input.count)
        #expect(!(record["arguments"] as? [String] ?? []).joined().contains("KL-SECRET-INPUT"))
        #expect(Set(record["environmentKeys"] as? [String] ?? []) == ["HOME", "PATH"])
        #expect(record["processGroupLeader"] as? Bool == false)
    }

    @Test
    func silentProcessesHitTheStartTimeoutAndAreKilled() throws {
        let home = try FakeHome(scenario: ["turn": "silent"])
        defer { home.remove() }
        var limits = CLIProcessLimits.testing
        limits.startTimeout = 0.5

        let started = Date()
        let result = try runFakeExec(home: home, limits: limits)

        #expect(result.ending == .timedOut)
        #expect(Date().timeIntervalSince(started) < 5)
        try expectGone(home.pid("codex.pid"))
    }

    @Test
    func timeoutsKillTheWholeProcessGroupIncludingGrandchildren() throws {
        let home = try FakeHome(scenario: ["turn": "hang"])
        defer { home.remove() }
        var limits = CLIProcessLimits.testing
        limits.totalTimeout = 1

        let result = try runFakeExec(home: home, limits: limits)

        #expect(result.ending == .timedOut)
        try expectGone(home.pid("codex.pid"))
        try expectGone(home.pid("grandchild.pid"))
    }

    @Test
    func cancellationStopsTheTurnAndItsDescendants() throws {
        let home = try FakeHome(scenario: ["turn": "hang"])
        defer { home.remove() }
        let cancellation = CLICancellation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.7) { cancellation.cancel() }

        let result = try runFakeExec(home: home, cancellation: cancellation)

        #expect(result.ending == .cancelled)
        #expect(cancellation.isCancelled)
        try expectGone(home.pid("codex.pid"))
        try expectGone(home.pid("grandchild.pid"))
    }

    @Test
    func floodsAndOverlongLinesStopAtTheOutputBounds() throws {
        var limits = CLIProcessLimits.testing
        limits.maximumOutputBytes = 64 * 1_024
        limits.maximumLineBytes = 16 * 1_024
        for scenario in ["flood", "longLine"] {
            let home = try FakeHome(scenario: ["turn": scenario])
            defer { home.remove() }

            let result = try runFakeExec(home: home, limits: limits)

            #expect(result.ending == .outputTooLarge, "\(scenario)")
            try expectGone(home.pid("codex.pid"))
        }
    }

    @Test
    func aLineHandlerThatThrowsStopsTheProcess() throws {
        let home = try FakeHome(scenario: ["turn": "toolUse"])
        defer { home.remove() }
        var events = CodexEventAccumulator()

        let result = CLIProcess.run(
            executable: try fixtureExecutable(), arguments: ["exec", "--json", "-"],
            environment: ["HOME": home.path], workingDirectory: home.path, input: Data("x".utf8),
            supervisor: try fixtureExecutable(), limits: .testing, cancellation: nil,
            onLine: { try events.consume($0) }
        )

        #expect(result.ending == .lineHandlerStopped)
        try expectGone(home.pid("codex.pid"))
    }

    @Test
    func theSupervisorKillsTheGroupWhenItsParentDies() throws {
        let home = try FakeHome(scenario: ["turn": "hang"])
        defer { home.remove() }
        let host = Process()
        host.executableURL = try fixtureExecutable()
        host.arguments = ["--host-hanging-turn"]
        host.environment = ["HOME": home.path]
        try host.run()
        defer { if host.isRunning { kill(host.processIdentifier, SIGKILL); host.waitUntilExit() } }

        let grandchild = try home.waitForPID("grandchild.pid")
        let codex = try home.waitForPID("codex.pid")
        kill(host.processIdentifier, SIGKILL)
        host.waitUntilExit()

        try expectGone(codex)
        try expectGone(grandchild)
    }

    @Test
    func executablesMustBeOwnedNamedRegularFilesThatOthersCannotWrite() throws {
        let home = try FakeHome(scenario: [:])
        defer { home.remove() }
        let directory = URL(fileURLWithPath: home.path).appendingPathComponent("candidates")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let real = directory.appendingPathComponent("codex-real")
        try FileManager.default.copyItem(at: try fixtureExecutable(), to: real)
        let link = directory.appendingPathComponent("codex")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        #expect(CLIExecutable.validated(link.path) == realPath(real.path))
        #expect(CLIExecutable.validated(real.path) == nil, "the requested name must be codex")
        #expect(CLIExecutable.validated(directory.path + "/missing/codex") == nil)
        #expect(CLIExecutable.validated("relative/codex") == nil)

        try FileManager.default.setAttributes([.posixPermissions: 0o757], ofItemAtPath: real.path)
        #expect(CLIExecutable.validated(link.path) == nil, "world-writable")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: real.path)
        #expect(CLIExecutable.validated(link.path) == nil, "not executable")

        let folder = directory.appendingPathComponent("nested/codex")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(CLIExecutable.validated(folder.path) == nil, "a directory")

        let candidates = CLIExecutable.candidatePaths(home: "/Users/synthetic")
        #expect(candidates.first == "/opt/homebrew/bin/codex")
        #expect(candidates.contains("/usr/local/bin/codex"))
        #expect(candidates.contains("/Users/synthetic/.local/bin/codex"))
        #expect(candidates.allSatisfy { $0.hasSuffix("/codex") && $0.hasPrefix("/") })
    }

    @Test
    func statusPassesOnlyWhenEveryCapabilityCheckPasses() throws {
        let ready = try bridgeStatus(["check": "clean"])
        #expect(ready.failure == nil)
        #expect(ready.cliVersion == "0.162.0")
        #expect(ready.isVerifiedVersion)
        #expect(ready.isLoggedIn)

        let newer = try bridgeStatus(["check": "clean", "version": "0.170.0"])
        #expect(newer.failure == nil)
        #expect(!newer.isVerifiedVersion)

        // A feature the list still shows as on does not fail the check by itself: the captured request does.
        #expect(try bridgeStatus(["check": "clean", "stickyFeature": true]).failure == nil)
        #expect(try bridgeStatus(["check": "clean", "loggedOut": true]).failure == .notLoggedIn)
        for unsafe: [String: Any] in [
            ["check": "tools"], ["check": "leakHome"], ["check": "extraMessage"], ["check": "clean", "missingFlag": true],
            ["check": "clean", "version": "unknown"], ["check": "clean", "features": "malformed"],
        ] {
            #expect(try bridgeStatus(unsafe).failure == .unsupportedCLI, "\(unsafe)")
        }
    }

    @Test
    func statusReportsMissingAndUnsupportedExecutables() throws {
        let home = try FakeHome(scenario: [:])
        defer { home.remove() }
        let bridge = try CodexBridge(environment: home.environment(supervisor: try fixtureExecutable()))

        let missing = bridge.status(configuration: try .init(executablePath: home.path + "/nowhere/codex", proxy: [:]))
        #expect(missing.failure == .cliNotFound)
        let wrongName = bridge.status(configuration: try .init(executablePath: try fixtureExecutable().path, proxy: [:]))
        #expect(wrongName.failure == .cliNotFound)
    }

    @Test
    func aTurnReturnsTheAnswerAndCleansUpAfterItself() throws {
        let home = try FakeHome(scenario: ["check": "clean", "turn": "answer"])
        defer { home.remove() }
        let bridge = try CodexBridge(environment: home.environment(supervisor: try fixtureExecutable()))
        let input = "<records>\n合成\n</records>\n\n<question>\n合成问题\n</question>\n"

        let response = bridge.respond(try home.turn(input: input), cancellation: CLICancellation())

        #expect(response == .answer(text: "fake answer bytes=\(input.utf8.count)", cliVersion: "0.162.0", model: "gpt-synthetic"))
        let record = try home.record()
        let arguments = record["arguments"] as? [String] ?? []
        #expect(arguments.contains("--strict-config"))
        #expect(!arguments.contains { $0.contains("kinlogue_check") }, "a real turn uses the CLI's own provider")
        #expect(!arguments.joined().contains("合成问题"))
        #expect(Set(record["environmentKeys"] as? [String] ?? []).isSubset(of: [
            "HOME", "USER", "LOGNAME", "PATH", "LANG", "LC_ALL", "TMPDIR", "HTTPS_PROXY",
        ]))
        #expect(record["environmentKeys"] as? [String] ?? [] == (record["environmentKeys"] as? [String] ?? []).sorted())
        #expect(try home.temporaryEntries().isEmpty)
    }

    @Test
    func turnFailuresBecomeSemanticCodes() throws {
        let cases: [(String, KinlogueAssistantTurnResponse)] = [
            ("failed401", .failure(code: .notLoggedIn, exitCode: 1)),
            ("rateLimited", .failure(code: .rateLimited, exitCode: 1)),
            ("exit3", .failure(code: .failed, exitCode: 3)),
            ("toolUse", .failure(code: .toolUseDetected, exitCode: nil)),
            ("noCompletion", .failure(code: .failed, exitCode: 0)),
        ]
        for (scenario, expected) in cases {
            let home = try FakeHome(scenario: ["check": "clean", "turn": scenario])
            defer { home.remove() }
            let bridge = try CodexBridge(environment: home.environment(supervisor: try fixtureExecutable()))

            #expect(bridge.respond(try home.turn(input: "Input"), cancellation: CLICancellation()) == expected, "\(scenario)")
            #expect(try home.temporaryEntries().isEmpty, "\(scenario)")
        }
    }

    @Test
    func aTurnIsRefusedWhileTheCapabilityCheckFailsOrAnotherTurnRuns() throws {
        let unsafe = try FakeHome(scenario: ["check": "tools", "turn": "answer"])
        defer { unsafe.remove() }
        let refusing = try CodexBridge(environment: unsafe.environment(supervisor: try fixtureExecutable()))
        #expect(refusing.respond(try unsafe.turn(input: "Input"), cancellation: CLICancellation())
            == .failure(code: .unsupportedCLI, exitCode: nil))
        #expect(!FileManager.default.fileExists(atPath: unsafe.path + "/kl-fake-record-turn.json"))

        let home = try FakeHome(scenario: ["check": "clean", "turn": "hang"])
        defer { home.remove() }
        let bridge = try CodexBridge(environment: home.environment(supervisor: try fixtureExecutable()))
        _ = bridge.status(configuration: try home.configuration())
        let first = try home.turn(input: "First")
        let finished = DispatchSemaphore(value: 0)
        let box = ResponseBox()
        DispatchQueue.global().async {
            box.value = bridge.respond(first, cancellation: CLICancellation())
            finished.signal()
        }
        _ = try home.waitForPID("codex.pid")

        #expect(bridge.respond(try home.turn(input: "Second"), cancellation: CLICancellation())
            == .failure(code: .busy, exitCode: nil))
        #expect(bridge.cancel(requestID: first.requestID))
        #expect(finished.wait(timeout: .now() + 10) == .success)
        #expect(box.value == .failure(code: .cancelled, exitCode: nil))
        #expect(!bridge.cancel(requestID: first.requestID))
    }

    @Test
    func theBridgeRemovesStaleRunDirectoriesWhenItStarts() throws {
        let home = try FakeHome(scenario: [:])
        defer { home.remove() }
        let stale = URL(fileURLWithPath: home.temporaryRoot).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: stale.appendingPathComponent("cwd"), withIntermediateDirectories: true)
        try Data("left over".utf8).write(to: stale.appendingPathComponent("catalog.json"))

        _ = try CodexBridge(environment: home.environment(supervisor: try fixtureExecutable()))

        #expect(try home.temporaryEntries().isEmpty)
    }
}

// MARK: - Fixtures

private final class AssistantFixtureLocator {}

private final class ResponseBox: @unchecked Sendable {
    // SAFETY: written once on the worker queue before `finished.signal()` and read after the wait.
    var value: KinlogueAssistantTurnResponse?
}

private func fixtureExecutable() throws -> URL {
    let url = Bundle(for: AssistantFixtureLocator.self).bundleURL
        .deletingLastPathComponent()
        .appendingPathComponent("KinlogueAssistantCLIFixture")
    guard FileManager.default.isExecutableFile(atPath: url.path) else { throw FixtureError.missing }
    return url
}

private enum FixtureError: Error {
    case missing
    case timedOut
}

extension CLIProcessLimits {
    fileprivate static var testing: CLIProcessLimits {
        var limits = CLIProcessLimits()
        limits.startTimeout = 10
        limits.totalTimeout = 20
        limits.terminationGrace = 0.3
        return limits
    }
}

private func runFakeExec(
    home: FakeHome,
    limits: CLIProcessLimits = .testing,
    cancellation: CLICancellation? = nil
) throws -> CLIProcessResult {
    CLIProcess.run(
        executable: try fixtureExecutable(), arguments: ["exec", "--json", "-"],
        environment: ["HOME": home.path], workingDirectory: home.path, input: Data("Input".utf8),
        supervisor: try fixtureExecutable(), limits: limits, cancellation: cancellation, onLine: { _ in }
    )
}

/// `realpath(3)`; Foundation's symlink resolution drops `/private` from temporary paths.
private func realPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}

private func expectGone(_ pid: pid_t, sourceLocation: SourceLocation = #_sourceLocation) throws {
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
        if kill(pid, 0) != 0 && errno == ESRCH { return }
        usleep(20_000)
    }
    Issue.record("process \(pid) is still running", sourceLocation: sourceLocation)
}

private func bridgeStatus(_ scenario: [String: Any]) throws -> KinlogueAssistantStatus {
    let home = try FakeHome(scenario: scenario)
    defer { home.remove() }
    let bridge = try CodexBridge(environment: home.environment(supervisor: try fixtureExecutable()))
    return bridge.status(configuration: try home.configuration())
}

private struct FakeHome {
    let path: String
    let temporaryRoot: String

    init(scenario: [String: Any]) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kl-assistant-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        path = realPath(root.path)
        temporaryRoot = path + "/runs"
        let codexDirectory = URL(fileURLWithPath: path).appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: codexDirectory.appendingPathComponent("codex"), withDestinationURL: try fixtureExecutable()
        )
        try JSONSerialization.data(withJSONObject: scenario).write(to: URL(fileURLWithPath: path + "/kl-fake-codex.json"))
    }

    var codexPath: String { path + "/bin/codex" }

    func environment(supervisor: URL) -> CodexBridgeEnvironment {
        CodexBridgeEnvironment(
            home: path, userName: "kl-synthetic-user", temporaryRoot: URL(fileURLWithPath: temporaryRoot),
            supervisor: supervisor.path, candidatePaths: [codexPath], limits: .testing
        )
    }

    func configuration() throws -> KinlogueAssistantCLIConfiguration {
        try KinlogueAssistantCLIConfiguration(executablePath: codexPath, proxy: ["HTTPS_PROXY": "http://127.0.0.1:9"])
    }

    func turn(input: String) throws -> KinlogueAssistantTurnRequest {
        try KinlogueAssistantTurnRequest(
            requestID: UUID(), configuration: configuration(), model: "gpt-synthetic",
            instructions: "Synthetic instructions", input: input
        )
    }

    func record() throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path + "/kl-fake-record-turn.json"))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func pid(_ name: String) throws -> pid_t {
        let text = try String(contentsOfFile: path + "/" + name, encoding: .utf8)
        return try #require(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    func waitForPID(_ name: String) throws -> pid_t {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let pid = try? pid(name) { return pid }
            usleep(20_000)
        }
        throw FixtureError.timedOut
    }

    func temporaryEntries() throws -> [String] {
        guard FileManager.default.fileExists(atPath: temporaryRoot) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: temporaryRoot)
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: path)
    }
}
