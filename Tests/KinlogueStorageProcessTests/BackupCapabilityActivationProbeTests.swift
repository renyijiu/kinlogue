import Darwin
import Foundation
import Testing

/// Drives the installed-build restore probe as a separate process: each case seeds two
/// libraries, lets the production restore transaction kill itself at one phase, and has a
/// fresh process settle what was left.
@Suite(.serialized)
struct BackupCapabilityActivationProbeTests {
    @Test
    func activationIsRefusedWhileAnotherProcessOwnsTheLibraryAndSucceedsOnceItLetsGo() async throws {
        try await withCapabilityDirectory { directory in
            let caseID = "real-writer"
            try runProbe(
                [
                    "activation-seed", "--scenario", "existing",
                    "--case-id", caseID,
                ],
                workingDirectory: directory
            )
            let current = directory
                .appendingPathComponent("activation-\(caseID)", isDirectory: true)
                .appendingPathComponent("Vault", isDirectory: true)
            let execute = [
                "activation-execute", "--scenario", "existing",
                "--case-id", caseID, "--fault", "none",
            ]

            try await withStorageProcessFixture(processCount: 1) { processes in
                let owner = processes[0]
                try owner.send(.init(operation: "openSQLite", rootURL: current))
                #expect(try await owner.nextResponse().event == "sqliteOpened")

                // A library has one owner. A restore from another process is turned away
                // before it prepares anything.
                let refused = try runProbeExpectingFailure(execute, workingDirectory: directory)
                #expect(try decode(ProbeFailure.self, from: refused).code == "libraryOccupied")

                try owner.send(.init(operation: "closeSQLite"))
                #expect(try await owner.nextResponse().event == "sqliteClosed")
                let untouched = try decode(ActivationVerification.self, from: try runProbe(
                    ["activation-verify", "--case-id", caseID],
                    workingDirectory: directory
                ))
                #expect(untouched.rootState == "old")
                #expect(!untouched.receiptPresent)
                #expect(!untouched.stagingPresent)
                #expect(!untouched.rollbackPresent)

                try runProbe(execute, workingDirectory: directory)
                let verified = try decode(ActivationVerification.self, from: try runProbe(
                    ["activation-verify", "--case-id", caseID],
                    workingDirectory: directory
                ))
                #expect(verified.rootState == "new")
                #expect(!verified.mixedState)
                #expect(!verified.receiptPresent)
                #expect(!verified.stagingPresent)
                #expect(!verified.rollbackPresent)
                #expect(verified.semanticValidated)
                #expect(verified.libraryGeneration > 1)
                #expect(verified.memberCount == 1)
                #expect(verified.inboxItemCount == 1)
                #expect(verified.inboxTerminalCount == 1)

                // The process that owned the replaced library opens the restored one like any other.
                try owner.send(.init(operation: "openSQLite", rootURL: current))
                #expect(try await owner.nextResponse().event == "sqliteOpened")
                try owner.send(.init(operation: "closeSQLite"))
                #expect(try await owner.nextResponse().event == "sqliteClosed")
            }
        }
    }

    @Test
    func productionFaultsWithExistingRootReconcileToTheirExactTerminalRoot() async throws {
        try await verifyActivationFaults(
            scenario: "existing",
            expectedRootStates: [
                "after-intent": "old",
                "after-writer-reset": "old",
                "after-old-root-move": "old",
                "after-new-root-activation": "new",
                "after-validation": "new",
                "after-commit": "new",
            ]
        )
    }

    @Test
    func productionFaultsWithAbsentRootReconcileToTheirExactTerminalRoot() async throws {
        try await verifyActivationFaults(
            scenario: "absent",
            expectedRootStates: [
                "after-intent": "absent",
                "after-writer-reset": "absent",
                "after-new-root-activation": "new",
                "after-validation": "new",
                "after-commit": "new",
            ]
        )
    }

    @Test
    func truncatedProductionReceiptFailsClosed() async throws {
        try await withCapabilityDirectory { directory in
            try runProbe(
                ["activation-seed", "--scenario", "existing"],
                workingDirectory: directory
            )
            _ = try run(
                [
                    "activation-execute", "--scenario", "existing",
                    "--fault", "after-intent",
                ],
                workingDirectory: directory
            )
            try runProbe(
                ["activation-truncate-receipt"],
                workingDirectory: directory
            )
            let rejected = try runProbeExpectingFailure(
                ["activation-reconcile"],
                workingDirectory: directory
            )
            #expect(try decode(ProbeFailure.self, from: rejected).code == "receiptInvalid")
            let verified = try runProbe(
                ["activation-verify"],
                workingDirectory: directory
            )
            #expect(try decode(ActivationVerification.self, from: verified).rootState == "old")
        }

    }

    private func verifyActivationFaults(
        scenario: String,
        expectedRootStates: [String: String]
    ) async throws {
        for (fault, expectedRootState) in expectedRootStates.sorted(by: { $0.key < $1.key }) {
            try await withCapabilityDirectory { directory in
                try runProbe(
                    ["activation-seed", "--scenario", scenario],
                    workingDirectory: directory
                )
                let crashed = try run(
                    [
                        "activation-execute", "--scenario", scenario,
                        "--fault", fault,
                    ],
                    workingDirectory: directory
                )
                #expect(crashed.terminationReason == .uncaughtSignal)
                #expect(crashed.terminationStatus == SIGKILL)

                try runProbe(["activation-reconcile"], workingDirectory: directory)
                let output = try runProbe(
                    ["activation-verify"],
                    workingDirectory: directory
                )
                let verified = try decode(ActivationVerification.self, from: output)
                #expect(verified.rootState == expectedRootState)
                #expect(!verified.mixedState)
                #expect(!verified.receiptPresent)
                #expect(!verified.stagingPresent)
                #expect(!verified.rollbackPresent)
            }
        }
    }

    private func withCapabilityDirectory(
        _ body: (URL) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent(
                "kinlogue-backup-capability-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }

    @discardableResult
    private func runProbe(
        _ arguments: [String],
        workingDirectory: URL,
        timeout: Duration = .seconds(10)
    ) throws -> String {
        let result = try run(
            arguments,
            workingDirectory: workingDirectory,
            timeout: timeout
        )
        guard result.terminationReason == .exit,
              result.terminationStatus == 0 else {
            throw CapabilityHarnessError.unexpectedExit
        }
        return result.standardOutput
    }

    private func runProbeExpectingFailure(
        _ arguments: [String],
        workingDirectory: URL
    ) throws -> String {
        let result = try run(arguments, workingDirectory: workingDirectory)
        guard result.terminationReason == .exit,
              result.terminationStatus != 0 else {
            throw CapabilityHarnessError.unexpectedExit
        }
        return result.standardOutput
    }

    private func run(
        _ arguments: [String],
        workingDirectory: URL,
        timeout: Duration = .seconds(10)
    ) throws -> CapabilityProcessResult {
        try startProbe(arguments, workingDirectory: workingDirectory).finish(timeout: timeout)
    }

    private func startProbe(
        _ arguments: [String],
        workingDirectory: URL
    ) throws -> CapabilityRunningProcess {
        let executable = try StorageProcessFixture.fixtureExecutableURL(
            testBundleURL: Bundle(for: StorageProcessFixture.self).bundleURL
        )
        let process = Process()
        let standardOutput = Pipe()
        process.executableURL = executable
        process.arguments = [
            "--backup-capability",
            "--working-directory", workingDirectory.path,
        ] + arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = standardOutput
        process.standardError = FileHandle.nullDevice
        try process.run()
        return CapabilityRunningProcess(process: process, standardOutput: standardOutput)
    }

    private func decode<Value: Decodable>(
        _ type: Value.Type,
        from output: String
    ) throws -> Value {
        try JSONDecoder().decode(Value.self, from: Data(output.utf8))
    }
}

private struct ActivationVerification: Decodable {
    let rootState: String
    let mixedState: Bool
    let receiptPresent: Bool
    let stagingPresent: Bool
    let rollbackPresent: Bool
    let semanticValidated: Bool
    let libraryGeneration: UInt64
    let memberCount: Int
    let inboxItemCount: Int
    let inboxTerminalCount: Int
}

private struct ProbeFailure: Decodable {
    let code: String
}

private struct CapabilityProcessResult {
    let terminationReason: Process.TerminationReason
    let terminationStatus: Int32
    let standardOutput: String
}

private final class CapabilityRunningProcess: @unchecked Sendable {
    private let process: Process
    private let standardOutput: Pipe

    init(process: Process, standardOutput: Pipe) {
        self.process = process
        self.standardOutput = standardOutput
    }

    func finish(timeout: Duration) throws -> CapabilityProcessResult {
        let deadline = ContinuousClock.now + timeout
        while process.isRunning, ContinuousClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            throw CapabilityHarnessError.timedOut
        }
        return CapabilityProcessResult(
            terminationReason: process.terminationReason,
            terminationStatus: process.terminationStatus,
            standardOutput: String(
                decoding: standardOutput.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
        )
    }
}

private enum CapabilityHarnessError: Error {
    case timedOut
    case unexpectedExit
}
