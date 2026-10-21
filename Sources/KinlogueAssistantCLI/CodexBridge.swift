import Darwin
import Foundation
import KinlogueAssistantIPC
import os

public struct CodexBridgeEnvironment: Sendable {
    /// The user's real home, from the account database rather than `HOME`, which a sandboxed
    /// helper sees as its container.
    public let home: String
    public let userName: String
    /// Per-run directories live here; everything in it is removed when the bridge starts.
    public let temporaryRoot: URL
    /// An executable that implements `CLISupervisor`; normally the bridge itself.
    public let supervisor: String?
    public let candidatePaths: [String]
    public let limits: CLIProcessLimits

    public init(
        home: String,
        userName: String,
        temporaryRoot: URL,
        supervisor: String?,
        candidatePaths: [String],
        limits: CLIProcessLimits
    ) {
        self.home = home
        self.userName = userName
        self.temporaryRoot = temporaryRoot
        self.supervisor = supervisor
        self.candidatePaths = candidatePaths
        self.limits = limits
    }

    public static func current(supervisor: String?) -> CodexBridgeEnvironment {
        let account = getpwuid(getuid())
        let home = account.map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return CodexBridgeEnvironment(
            home: home,
            userName: account.map { String(cString: $0.pointee.pw_name) } ?? "",
            temporaryRoot: FileManager.default.temporaryDirectory.appendingPathComponent("kinlogue-assistant", isDirectory: true),
            supervisor: supervisor,
            candidatePaths: CLIExecutable.candidatePaths(home: home),
            limits: CLIProcessLimits()
        )
    }
}

/// Runs the user's Codex for the assistant: finds and checks the executable, proves the hardened
/// command line sends no tools and no local context, then runs one turn at a time.
public final class CodexBridge: Sendable {
    static let checkInstructions = "Kinlogue capability check. Reply with one short sentence."
    static let checkInput = "<records>\n<record id=\"R1\" date=\"2000-01-01\">\nTitle: Synthetic check\n</record>\n</records>\n\n<question>\nSynthetic check\n</question>\n"
    static let checkAnswer = "Kinlogue capability check passed."
    static let checkKeyVariable = "KINLOGUE_CHECK_KEY"

    private let environment: CodexBridgeEnvironment
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// A capability holds for one executable file and one model: the tools a request carries
    /// depend on the model's catalog entry.
    private struct Identity: Hashable, Sendable {
        let model: String
        let path: String
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modified: Int
    }

    private struct Capability: Sendable {
        /// The model the check ran with, once one was chosen.
        var model: String? = nil
        let version: String?
        let disabledFeatures: [String]
        /// Nil when every safety check passed.
        let failure: KinlogueAssistantFailureCode?
    }

    private struct Running: Sendable {
        let requestID: UUID
        let cancellation: CLICancellation
    }

    /// What `codex debug models` offers: the default for a request without a model, and the
    /// models the user may pick.
    private struct ModelListing: Sendable {
        var defaultModel: String?
        var choices: [KinlogueAssistantModelChoice] = []
        /// The CLI never ran.
        var couldNotStart = false
    }

    private struct State: Sendable {
        var capabilities: [Identity: Capability] = [:]
        /// Per executable file, so a turn's status check does not list the models again.
        var listings: [Identity: ModelListing] = [:]
        var running: Running?
    }

    public init(environment: CodexBridgeEnvironment) throws {
        self.environment = environment
        let manager = FileManager.default
        if manager.fileExists(atPath: environment.temporaryRoot.path) {
            for entry in try manager.contentsOfDirectory(atPath: environment.temporaryRoot.path) {
                try manager.removeItem(at: environment.temporaryRoot.appendingPathComponent(entry))
            }
        } else {
            try manager.createDirectory(
                at: environment.temporaryRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
        }
    }

    public func status(configuration: KinlogueAssistantCLIConfiguration, model: String? = nil) -> KinlogueAssistantStatus {
        guard let executable = CLIExecutable.locate(explicit: configuration.executablePath, candidates: environment.candidatePaths) else {
            return KinlogueAssistantStatus(
                executablePath: nil, cliVersion: nil, isLoggedIn: false, isVerifiedVersion: false,
                failure: notFound(configuration.executablePath)
            )
        }
        let listing = modelListing(executable, proxy: configuration.proxy)
        let capability = capability(of: executable, model: model, listing: listing, proxy: configuration.proxy)
        let loggedIn = (try? withRun { run in
            let result = short(executable, ["login", "status"], run: run, proxy: configuration.proxy)
            return CodexInvocation.isLoggedIn(statusOutput: result.errorTail + String(decoding: result.output, as: UTF8.self),
                                              exitStatus: result.exitCode ?? -1)
        }) ?? false
        return KinlogueAssistantStatus(
            executablePath: executable.resolved,
            cliVersion: capability.version,
            isLoggedIn: loggedIn,
            isVerifiedVersion: capability.version.map(CodexInvocation.isVerified(version:)) ?? false,
            failure: capability.failure ?? (loggedIn ? nil : .notLoggedIn),
            model: capability.model,
            defaultModel: listing.defaultModel,
            models: listing.choices
        )
    }

    public func respond(_ request: KinlogueAssistantTurnRequest, cancellation: CLICancellation) -> KinlogueAssistantTurnResponse {
        let claimed = state.withLock { state -> Bool in
            guard state.running == nil else { return false }
            state.running = Running(requestID: request.requestID, cancellation: cancellation)
            return true
        }
        guard claimed else { return .failure(code: .busy, exitCode: nil) }
        defer { state.withLock { $0.running = nil } }

        guard let executable = CLIExecutable.locate(
            explicit: request.configuration.executablePath, candidates: environment.candidatePaths
        ) else { return .failure(code: notFound(request.configuration.executablePath), exitCode: nil) }
        let capability = capability(of: executable, model: request.model, proxy: request.configuration.proxy)
        if let failure = capability.failure { return .failure(code: failure, exitCode: nil) }
        guard let version = capability.version else { return .failure(code: .unsupportedCLI, exitCode: nil) }
        guard !cancellation.isCancelled else { return .failure(code: .cancelled, exitCode: nil) }

        do {
            return try withRun { run in
                guard let catalog = catalog(executable, run: run, proxy: request.configuration.proxy) else {
                    return .failure(code: .unsupportedCLI, exitCode: nil)
                }
                let arguments = CodexInvocation.execArguments(
                    workingDirectory: run.workingDirectory.path, model: request.model, catalogPath: catalog.path,
                    instructions: request.instructions, disabledFeatures: capability.disabledFeatures, mockProvider: nil
                )
                var events = CodexEventAccumulator()
                var thrown: Error?
                let result = CLIProcess.run(
                    executable: URL(fileURLWithPath: executable.resolved), arguments: arguments,
                    environment: processEnvironment(executable: executable, run: run, proxy: request.configuration.proxy),
                    workingDirectory: run.workingDirectory.path, input: Data(request.input.utf8),
                    supervisor: environment.supervisor.map(URL.init(fileURLWithPath:)), limits: environment.limits,
                    cancellation: cancellation,
                    onLine: { line in
                        do { try events.consume(line) } catch { thrown = error; throw error }
                    }
                )
                return response(result, events: events, thrown: thrown, version: version, model: request.model)
            }
        } catch {
            return .failure(code: .failed, exitCode: nil)
        }
    }

    private func notFound(_ explicit: String?) -> KinlogueAssistantFailureCode {
        explicit.map(CLIExecutable.inspect) == .outsideAllowedLocations ? .unsupportedLocation : .cliNotFound
    }

    /// Stops the turn with this ID. False when no such turn is running.
    public func cancel(requestID: UUID) -> Bool {
        state.withLock { state in
            guard let running = state.running, running.requestID == requestID else { return false }
            running.cancellation.cancel()
            return true
        }
    }

    // MARK: - Turn

    private func response(
        _ result: CLIProcessResult,
        events: CodexEventAccumulator,
        thrown: Error?,
        version: String,
        model: String
    ) -> KinlogueAssistantTurnResponse {
        switch result.ending {
        case .cancelled: return .failure(code: .cancelled, exitCode: nil)
        case .timedOut: return .failure(code: .timedOut, exitCode: nil)
        case .outputTooLarge: return .failure(code: .outputTooLarge, exitCode: nil)
        case .lineHandlerStopped:
            return .failure(code: thrown as? CodexAdapterError == .toolUseDetected ? .toolUseDetected : .failed, exitCode: nil)
        case .launchFailed, .signaled: return .failure(code: .failed, exitCode: nil)
        case let .exited(code):
            if code == 0, let answer = events.answer {
                guard KinlogueAssistantText.isBoundedText(answer, maximumBytes: KinlogueAssistantIPCLimits.maximumAnswerBytes) else {
                    return .failure(code: answer.utf8.count > KinlogueAssistantIPCLimits.maximumAnswerBytes ? .outputTooLarge : .failed,
                                    exitCode: code)
                }
                return .answer(text: answer, cliVersion: version, model: model)
            }
            return .failure(code: CodexFailureClassifier.code(for: events.failureMessage ?? result.errorTail, exitStatus: code),
                            exitCode: code)
        }
    }

    // MARK: - Capability check

    private func capability(
        of executable: CLIExecutable.Located, model requested: String?, listing: ModelListing = ModelListing(), proxy: [String: String]
    ) -> Capability {
        // The listing only supplies the default; a turn always names its model.
        guard let model = requested ?? listing.defaultModel else {
            return Capability(version: nil, disabledFeatures: [], failure: listing.couldNotStart ? .unsupportedLocation : .unsupportedCLI)
        }
        guard let identity = identity(of: executable.resolved, model: model) else {
            return Capability(version: nil, disabledFeatures: [], failure: .cliNotFound)
        }
        if let cached = state.withLock({ $0.capabilities[identity] }) { return cached }
        var result = (try? withRun { run in check(executable, model: model, run: run, proxy: proxy) })
            ?? Capability(version: nil, disabledFeatures: [], failure: .failed)
        result.model = model
        let checked = result
        if checked.failure != .failed {
            state.withLock { $0.capabilities[identity] = checked }
        }
        return checked
    }

    private func modelListing(_ executable: CLIExecutable.Located, proxy: [String: String]) -> ModelListing {
        let identity = identity(of: executable.resolved, model: "")
        if let identity, let cached = state.withLock({ $0.listings[identity] }) { return cached }
        let listing = (try? withRun { run -> ModelListing in
            let result = short(executable, ["debug", "models"], run: run, proxy: proxy, limits: catalogLimits)
            guard result.exitCode == 0 else { return ModelListing(couldNotStart: result.couldNotStart) }
            return ModelListing(
                defaultModel: (try? CodexModelCatalog.slugs(result.output))?.first(where: KinlogueAssistantText.isToken),
                choices: (try? CodexModelCatalog.choices(result.output)) ?? []
            )
        }) ?? ModelListing()
        if let identity, listing.defaultModel != nil {
            state.withLock { $0.listings[identity] = listing }
        }
        return listing
    }

    private func check(_ executable: CLIExecutable.Located, model: String, run: RunDirectory, proxy: [String: String]) -> Capability {
        let unsupported = { (version: String?) in Capability(version: version, disabledFeatures: [], failure: .unsupportedCLI) }
        let versionResult = short(executable, ["--version"], run: run, proxy: proxy)
        if versionResult.couldNotStart {
            return Capability(version: nil, disabledFeatures: [], failure: .unsupportedLocation)
        }
        guard versionResult.exitCode == 0,
              let version = CodexInvocation.version(fromVersionOutput: String(decoding: versionResult.output, as: UTF8.self))
        else { return unsupported(nil) }

        let help = short(executable, ["exec", "--help"], run: run, proxy: proxy)
        guard help.exitCode == 0, CodexInvocation.missingExecFlags(inHelp: String(decoding: help.output, as: UTF8.self)).isEmpty
        else { return unsupported(version) }

        // The list only says what to disable. It reflects the user's configuration, which the turn
        // ignores, and on 0.162.0 it shows `unified_exec` on whatever is passed; the request the
        // check captures below decides whether any tool is offered.
        guard let listed = features(executable, run: run, proxy: proxy) else { return unsupported(version) }
        let disabled = CodexFeatureList.featuresToDisable(listed)

        guard let catalog = catalog(executable, run: run, proxy: proxy),
              let server = try? LoopbackResponsesServer(answer: Self.checkAnswer) else { return unsupported(version) }
        defer { server.stop() }
        let arguments = CodexInvocation.execArguments(
            workingDirectory: run.workingDirectory.path, model: model, catalogPath: catalog.path,
            instructions: Self.checkInstructions, disabledFeatures: disabled,
            mockProvider: .init(baseURL: server.baseURL, environmentKey: Self.checkKeyVariable)
        )
        var processEnvironment = processEnvironment(executable: executable, run: run, proxy: [:])
        processEnvironment[Self.checkKeyVariable] = UUID().uuidString
        var events = CodexEventAccumulator()
        let result = CLIProcess.run(
            executable: URL(fileURLWithPath: executable.resolved), arguments: arguments, environment: processEnvironment,
            workingDirectory: run.workingDirectory.path, input: Data(Self.checkInput.utf8),
            supervisor: environment.supervisor.map(URL.init(fileURLWithPath:)), limits: environment.limits, cancellation: nil,
            onLine: { try events.consume($0) }
        )
        let forbidden = [environment.home, run.root.path, environment.temporaryRoot.path]
            + (environment.userName.count >= 4 ? [environment.userName] : [])
        guard result.ending == .exited(0), events.answer == Self.checkAnswer, server.bodies.count == 1,
              CodexRequestInspection.violations(
                  in: server.bodies[0], instructions: Self.checkInstructions, input: Self.checkInput,
                  forbiddenText: forbidden, model: model
              ).isEmpty else { return unsupported(version) }
        return Capability(version: version, disabledFeatures: disabled, failure: nil)
    }

    private func features(_ executable: CLIExecutable.Located, run: RunDirectory, proxy: [String: String]) -> [CodexFeature]? {
        let result = short(executable, ["features", "list"], run: run, proxy: proxy)
        guard result.exitCode == 0 else { return nil }
        return try? CodexFeatureList.parse(String(decoding: result.output, as: UTF8.self))
    }

    /// Writes the rewritten model catalog into the run directory.
    private func catalog(_ executable: CLIExecutable.Located, run: RunDirectory, proxy: [String: String]) -> URL? {
        let result = short(executable, ["debug", "models"], run: run, proxy: proxy, limits: catalogLimits)
        guard result.exitCode == 0, let rewritten = try? CodexModelCatalog.rewrite(result.output) else { return nil }
        let url = run.root.appendingPathComponent("catalog.json")
        guard (try? rewritten.write(to: url, options: .withoutOverwriting)) != nil else { return nil }
        return url
    }

    // MARK: - Processes and directories

    private struct ShortResult {
        let exitCode: Int32?
        let output: Data
        let errorTail: String
        /// The CLI never ran: the spawn failed, or the supervisor reported 127 without output.
        let couldNotStart: Bool
    }

    private var catalogLimits: CLIProcessLimits {
        var limits = shortLimits
        limits.maximumOutputBytes = CodexModelCatalog.maximumBytes
        limits.maximumLineBytes = CodexModelCatalog.maximumBytes
        return limits
    }

    private var shortLimits: CLIProcessLimits {
        var limits = environment.limits
        limits.startTimeout = nil
        limits.totalTimeout = min(limits.totalTimeout, 60)
        limits.maximumOutputBytes = 256 * 1_024
        limits.maximumLineBytes = 256 * 1_024
        return limits
    }

    private func short(
        _ executable: CLIExecutable.Located,
        _ arguments: [String],
        run: RunDirectory,
        proxy: [String: String],
        limits: CLIProcessLimits? = nil
    ) -> ShortResult {
        let result = CLIProcess.run(
            executable: URL(fileURLWithPath: executable.resolved), arguments: arguments,
            environment: processEnvironment(executable: executable, run: run, proxy: proxy),
            workingDirectory: run.workingDirectory.path, input: Data(),
            supervisor: environment.supervisor.map(URL.init(fileURLWithPath:)), limits: limits ?? shortLimits,
            cancellation: nil, retainOutput: true, onLine: { _ in }
        )
        switch result.ending {
        case let .exited(code):
            let silent = result.output.isEmpty && result.errorTail.isEmpty
            return ShortResult(exitCode: code, output: result.output, errorTail: result.errorTail,
                               couldNotStart: code == CLISupervisor.couldNotStartStatus && silent)
        case .launchFailed:
            return ShortResult(exitCode: nil, output: Data(), errorTail: "", couldNotStart: true)
        default:
            return ShortResult(exitCode: nil, output: Data(), errorTail: "", couldNotStart: false)
        }
    }

    private func processEnvironment(executable: CLIExecutable.Located, run: RunDirectory, proxy: [String: String]) -> [String: String] {
        // The requested folder first: an npm-style `codex` resolves to a script whose interpreter
        // (`node`) sits next to the link, not next to the script.
        var path = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        for folder in [executable.requested, executable.resolved].map({ ($0 as NSString).deletingLastPathComponent })
        where !path.contains(folder) {
            path.append(folder)
        }
        var values = [
            "HOME": environment.home,
            "USER": environment.userName,
            "LOGNAME": environment.userName,
            "PATH": path.joined(separator: ":"),
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "TMPDIR": run.temporaryDirectory.path + "/",
        ]
        for (key, value) in proxy where KinlogueAssistantIPCLimits.proxyKeys.contains(key) {
            values[key] = value
        }
        return values
    }

    private struct RunDirectory {
        let root: URL
        var workingDirectory: URL { root.appendingPathComponent("cwd", isDirectory: true) }
        var temporaryDirectory: URL { root.appendingPathComponent("tmp", isDirectory: true) }
    }

    /// A fresh private directory for one run, removed afterwards whatever happens.
    private func withRun<Value>(_ body: (RunDirectory) throws -> Value) throws -> Value {
        let run = RunDirectory(root: environment.temporaryRoot.appendingPathComponent(UUID().uuidString, isDirectory: true))
        let manager = FileManager.default
        for directory in [run.root, run.workingDirectory, run.temporaryDirectory] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        defer { try? manager.removeItem(at: run.root) }
        return try body(run)
    }

    private func identity(of path: String, model: String) -> Identity? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return Identity(
            model: model, path: path, device: info.st_dev, inode: info.st_ino, size: info.st_size,
            modified: info.st_mtimespec.tv_sec * 1_000_000_000 + info.st_mtimespec.tv_nsec
        )
    }
}
