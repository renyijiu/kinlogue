import Foundation
import Testing

extension GitHubActionsWorkflowTests {
    @Test
    func releaseMainAncestryGuardAcceptsMainAndFailsClosedOtherwise() throws {
        let workflow = try releaseContents(".github/workflows/release.yml")
        let packageJob = try releaseJob(named: "package", in: workflow)
        let validationStep = try releaseExecutableStep(
            named: "Validate release inputs",
            in: packageJob
        )
        let validationScript = try releaseExecutableScript(in: validationStep)
        let testableScript = validationScript.replacingOccurrences(
            of: #"canonical_repository="https://github.com/${GITHUB_REPOSITORY}.git""#,
            with: #"canonical_repository="$KINLOGUE_TEST_CANONICAL_REPOSITORY""#
        )
        #expect(testableScript != validationScript)

        let fixture = try makeReleaseProvenanceFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }

        let accepted = try runReleaseValidation(
            script: testableScript,
            checkout: fixture.mainCheckout,
            canonicalRepository: fixture.canonicalRepository,
            tag: "v0.5.0"
        )
        #expect(accepted.status == 0, Comment(rawValue: accepted.output))

        let rejected = try runReleaseValidation(
            script: testableScript,
            checkout: fixture.sideCheckout,
            canonicalRepository: fixture.canonicalRepository,
            tag: "v0.5.1"
        )
        #expect(rejected.status != 0, Comment(rawValue: rejected.output))

        let unavailableCanonical = try runReleaseValidation(
            script: testableScript,
            checkout: fixture.mainCheckout,
            canonicalRepository: fixture.container.appendingPathComponent("missing.git"),
            tag: "v0.5.0"
        )
        #expect(
            unavailableCanonical.status != 0,
            Comment(rawValue: unavailableCanonical.output)
        )
    }

    private func releaseContents(_ relativePath: String) throws -> String {
        try String(
            contentsOf: releaseRepository.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func releaseJob(named name: String, in workflow: String) throws -> String {
        let marker = "  \(name):\n"
        let start = try #require(workflow.range(of: marker))
        let expression = try NSRegularExpression(
            pattern: #"(?m)^  [A-Za-z0-9_-]+:\s*$"#
        )
        let searchRange = NSRange(start.upperBound..<workflow.endIndex, in: workflow)
        let end = expression.firstMatch(in: workflow, range: searchRange)
            .flatMap { Range($0.range, in: workflow) }?
            .lowerBound ?? workflow.endIndex
        return String(workflow[start.lowerBound..<end])
    }

    private func releaseExecutableStep(named name: String, in job: String) throws -> String {
        let marker = "      - name: \(name)\n"
        let start = try #require(job.range(of: marker))
        let next = job.range(
            of: "\n      - ",
            range: start.upperBound..<job.endIndex
        )?.lowerBound ?? job.endIndex
        let step = String(job[start.lowerBound..<next])
        _ = try #require(step.range(of: "\n        run:"))
        return step
    }

    private func releaseExecutableScript(in step: String) throws -> String {
        let marker = "        run: |\n"
        let start = try #require(step.range(of: marker))
        let lines = step[start.upperBound...].split(
            separator: "\n",
            omittingEmptySubsequences: false
        )
        return lines.map { line in
            line.hasPrefix("          ") ? String(line.dropFirst(10)) : String(line)
        }.joined(separator: "\n") + "\n"
    }

    private func makeReleaseProvenanceFixture() throws -> ReleaseProvenanceFixture {
        let fileManager = FileManager.default
        let container = fileManager.temporaryDirectory.appendingPathComponent(
            "KinlogueReleaseProvenance-\(UUID().uuidString)",
            isDirectory: true
        )
        let seed = container.appendingPathComponent("seed", isDirectory: true)
        let canonicalRepository = container.appendingPathComponent(
            "canonical.git",
            isDirectory: true
        )
        try fileManager.createDirectory(at: seed, withIntermediateDirectories: true)

        try runReleaseGit(["init", "--initial-branch=main"], at: seed)
        try runReleaseGit(["config", "user.name", "Kinlogue Tests"], at: seed)
        try runReleaseGit(["config", "user.email", "tests@kinlogue.invalid"], at: seed)
        try writeReleaseInfoPlist(version: "0.5.0", at: seed)
        try runReleaseGit(["add", "packaging/Info.plist"], at: seed)
        try runReleaseGit(["commit", "-m", "main release"], at: seed)
        try runReleaseGit(["tag", "v0.5.0"], at: seed)

        try runReleaseGit(["checkout", "-b", "side-release"], at: seed)
        try writeReleaseInfoPlist(version: "0.5.1", at: seed)
        try runReleaseGit(["add", "packaging/Info.plist"], at: seed)
        try runReleaseGit(["commit", "-m", "side release"], at: seed)
        try runReleaseGit(["tag", "v0.5.1"], at: seed)
        try runReleaseGit(["checkout", "main"], at: seed)

        try runReleaseGit(["init", "--bare", canonicalRepository.path], at: container)
        try runReleaseGit(["remote", "add", "canonical", canonicalRepository.path], at: seed)
        try runReleaseGit(["push", "canonical", "main", "--tags"], at: seed)

        let mainCheckout = container.appendingPathComponent(
            "main-checkout",
            isDirectory: true
        )
        let sideCheckout = container.appendingPathComponent(
            "side-checkout",
            isDirectory: true
        )
        try runReleaseGit(["clone", canonicalRepository.path, mainCheckout.path], at: container)
        try runReleaseGit(["checkout", "--detach", "v0.5.0"], at: mainCheckout)
        try runReleaseGit(["clone", canonicalRepository.path, sideCheckout.path], at: container)
        try runReleaseGit(["checkout", "--detach", "v0.5.1"], at: sideCheckout)

        return .init(
            container: container,
            canonicalRepository: canonicalRepository,
            mainCheckout: mainCheckout,
            sideCheckout: sideCheckout
        )
    }

    private func writeReleaseInfoPlist(version: String, at repository: URL) throws {
        let packaging = repository.appendingPathComponent("packaging", isDirectory: true)
        try FileManager.default.createDirectory(at: packaging, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleShortVersionString": version]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: packaging.appendingPathComponent("Info.plist"))
    }

    private func runReleaseGit(_ arguments: [String], at directory: URL) throws {
        let result = try runReleaseProcess(
            executable: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: arguments,
            directory: directory
        )
        guard result.status == 0 else {
            throw ReleaseProvenanceFixtureError.commandFailed(result.output)
        }
    }

    private func runReleaseValidation(
        script: String,
        checkout: URL,
        canonicalRepository: URL,
        tag: String
    ) throws -> ReleaseProcessResult {
        let output = checkout.appendingPathComponent("github-output.txt")
        try? FileManager.default.removeItem(at: output)
        var environment = ProcessInfo.processInfo.environment
        environment["RELEASE_TAG"] = tag
        environment["GITHUB_REPOSITORY"] = "renyijiu/kinlogue"
        environment["GITHUB_EVENT_NAME"] = "workflow_dispatch"
        environment["GITHUB_SHA"] = "unused-for-dispatch"
        environment["GITHUB_OUTPUT"] = output.path
        environment["KINLOGUE_TEST_CANONICAL_REPOSITORY"] = canonicalRepository.path
        return try runReleaseProcess(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: ["-c", script],
            directory: checkout,
            environment: environment
        )
    }

    private func runReleaseProcess(
        executable: URL,
        arguments: [String],
        directory: URL,
        environment: [String: String]? = nil
    ) throws -> ReleaseProcessResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = environment
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        return .init(status: process.terminationStatus, output: output)
    }

    private var releaseRepository: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private struct ReleaseProvenanceFixture {
    let container: URL
    let canonicalRepository: URL
    let mainCheckout: URL
    let sideCheckout: URL
}

private struct ReleaseProcessResult {
    let status: Int32
    let output: String
}

private enum ReleaseProvenanceFixtureError: Error {
    case commandFailed(String)
}
