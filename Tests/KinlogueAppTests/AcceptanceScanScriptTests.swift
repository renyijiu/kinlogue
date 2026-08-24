import CryptoKit
import Darwin
import Foundation
import Testing

@Suite(.serialized)
struct AcceptanceScanScriptTests {
    @Test(arguments: AcceptanceSyntheticLeak.allCases)
    func everySyntheticLeakFailsTheScan(
        _ leak: AcceptanceSyntheticLeak
    ) throws {
        let fixture = try AcceptanceScanFixture(runID: leak.runID)
        defer { fixture.remove() }
        try fixture.install(leak)

        let result = try fixture.runScanner()

        #expect(result.status == 1)
        #expect(result.event["code"] as? String == "KLA_SCAN_MATCH")
        #expect(result.event["ok"] as? Bool == false)
        #expect((result.event["count"] as? Int ?? 0) > 0)
        #expect(result.hasCanonicalDigest)
    }

    @Test
    func ignoreRulesCannotHideASyntheticLeak() throws {
        let fixture = try AcceptanceScanFixture(
            runID: AcceptanceSyntheticLeak.canary.runID
        )
        defer { fixture.remove() }
        try fixture.installIgnoredDataLeak(.canary)

        let result = try fixture.runScanner()

        #expect(result.status == 1)
        #expect(result.event["code"] as? String == "KLA_SCAN_MATCH")
        #expect(result.event["ok"] as? Bool == false)
        #expect((result.event["count"] as? Int ?? 0) > 0)
        #expect(result.hasCanonicalDigest)
    }

    @Test
    func repositoryBuildArtifactLeaksFailTheScan() throws {
        let fixture = try AcceptanceScanFixture(
            runID: AcceptanceSyntheticLeak.canary.runID
        )
        defer { fixture.remove() }
        try fixture.installInRepositoryBuild(.canary)

        let result = try fixture.runScanner()

        #expect(result.status == 1)
        #expect(result.event["code"] as? String == "KLA_SCAN_MATCH")
        #expect(result.event["ok"] as? Bool == false)
        #expect((result.event["count"] as? Int ?? 0) > 0)
        #expect(result.hasCanonicalDigest)
    }

    @Test
    func aNonstandardValidatedHomePathFailsTheScan() throws {
        let fixture = try AcceptanceScanFixture(
            runID: "d00000000000000000000010"
        )
        defer { fixture.remove() }
        try fixture.installNonstandardHomePathLeak()

        let result = try fixture.runScanner(useSimulatedHome: true)

        #expect(result.status == 1)
        #expect(result.event["code"] as? String == "KLA_SCAN_MATCH")
        #expect(result.event["ok"] as? Bool == false)
        #expect((result.event["count"] as? Int ?? 0) > 0)
        #expect(result.hasCanonicalDigest)
    }

    @Test(arguments: [
        AcceptanceSyntheticLeak.canary,
        .originalMagic,
        .memberToken,
        .titleToken,
        .organizationToken,
        .dateSourceToken,
        .conclusionToken,
        .pdfMagic,
    ])
    func intentionalPlaintextVaultContentIsNotReportedAsALeak(
        _ content: AcceptanceSyntheticLeak
    ) throws {
        let fixture = try AcceptanceScanFixture(runID: content.runID)
        defer { fixture.remove() }
        try fixture.installInSourceVault(content)

        let result = try fixture.runScanner()

        #expect(result.status == 0)
        #expect(result.event["code"] as? String == "KLA_SCAN_COMPLETE")
        #expect(result.event["ok"] as? Bool == true)
        #expect(result.event["count"] as? Int == 0)
        #expect(result.hasCanonicalDigest)
    }

    @Test
    func absoluteUserPathInsidePlaintextVaultStillFailsTheScan() throws {
        let fixture = try AcceptanceScanFixture(
            runID: "d00000000000000000000007"
        )
        defer { fixture.remove() }
        try fixture.installInSourceVault(.absoluteUserPath)

        let result = try fixture.runScanner()

        #expect(result.status == 1)
        #expect(result.event["code"] as? String == "KLA_SCAN_MATCH")
        #expect(result.event["ok"] as? Bool == false)
        #expect((result.event["count"] as? Int ?? 0) > 0)
        #expect(result.hasCanonicalDigest)
    }

    @Test
    func installedExecutablePDFBytesAreNotTreatedAsPersistedData() throws {
        let fixture = try AcceptanceScanFixture(
            runID: AcceptanceSyntheticLeak.pdfMagic.runID
        )
        defer { fixture.remove() }
        try fixture.installInInstalledExecutable(.pdfMagic)

        let result = try fixture.runScanner()

        #expect(result.status == 0)
        #expect(result.event["code"] as? String == "KLA_SCAN_COMPLETE")
        #expect(result.event["ok"] as? Bool == true)
    }

    @Test
    func installedAppResourcePDFBytesFailTheScan() throws {
        let fixture = try AcceptanceScanFixture(
            runID: AcceptanceSyntheticLeak.pdfMagic.runID
        )
        defer { fixture.remove() }
        try fixture.installInInstalledResource(.pdfMagic, name: "report.pdf")

        let result = try fixture.runScanner()

        #expect(result.status == 1)
        #expect(result.event["code"] as? String == "KLA_SCAN_MATCH")
        #expect(result.event["ok"] as? Bool == false)
        #expect((result.event["count"] as? Int ?? 0) > 0)
    }

    @Test
    func installedAppStillRejectsTheRunSpecificCanary() throws {
        let fixture = try AcceptanceScanFixture(
            runID: AcceptanceSyntheticLeak.canary.runID
        )
        defer { fixture.remove() }
        try fixture.installInInstalledResource(.canary, name: "fixture.bin")

        let result = try fixture.runScanner()

        #expect(result.status == 1)
        #expect(result.event["code"] as? String == "KLA_SCAN_MATCH")
        #expect(result.event["ok"] as? Bool == false)
    }

    @Test
    func scannerErrorsFailClosedForAnInstalledAppInternalSymlink() throws {
        let fixture = try AcceptanceScanFixture(
            runID: "e00000000000000000000003"
        )
        defer { fixture.remove() }
        try fixture.installInstalledAppResourceSymlink()

        let result = try fixture.runScanner()

        #expect(result.status == 70)
        #expect(result.event["code"] as? String == "KLA_SCAN_ERROR")
        #expect(result.event["ok"] as? Bool == false)
        #expect((result.event["count"] as? Int ?? 0) > 0)
        #expect(result.hasCanonicalDigest)
    }

    @Test
    func scannerErrorsFailClosedWithoutFollowingATestRootSymlink() throws {
        let fixture = try AcceptanceScanFixture(
            runID: "e00000000000000000000001"
        )
        defer { fixture.remove() }
        try fixture.installDataRootSymlink()

        let result = try fixture.runScanner()

        #expect(result.status == 70)
        #expect(result.event["code"] as? String == "KLA_SCAN_ERROR")
        #expect(result.event["ok"] as? Bool == false)
        #expect((result.event["count"] as? Int ?? 0) > 0)
        #expect(result.hasCanonicalDigest)
    }

    @Test
    func scannerErrorsFailClosedForAnInternalRepositorySymlink() throws {
        let fixture = try AcceptanceScanFixture(
            runID: "e00000000000000000000005"
        )
        defer { fixture.remove() }
        try fixture.installRepositoryRootSymlink()

        let result = try fixture.runScanner()

        #expect(result.status == 70)
        #expect(result.event["code"] as? String == "KLA_SCAN_ERROR")
        #expect(result.event["ok"] as? Bool == false)
        #expect((result.event["count"] as? Int ?? 0) > 0)
        #expect(result.hasCanonicalDigest)
    }

    @Test
    func scannerErrorsFailClosedForASourceVaultSymlink() throws {
        let fixture = try AcceptanceScanFixture(
            runID: "e00000000000000000000002"
        )
        defer { fixture.remove() }
        try fixture.installSourceVaultSymlink()

        let result = try fixture.runScanner()

        #expect(result.status == 70)
        #expect(result.event["code"] as? String == "KLA_SCAN_ERROR")
        #expect(result.event["ok"] as? Bool == false)
        #expect((result.event["count"] as? Int ?? 0) > 0)
        #expect(result.hasCanonicalDigest)
    }

    @Test
    func scannerErrorsFailClosedForAnInternalManagedRunSymlink() throws {
        let fixture = try AcceptanceScanFixture(
            runID: "e00000000000000000000004"
        )
        defer { fixture.remove() }
        try fixture.installManagedRunInternalSymlink()

        let result = try fixture.runScanner()

        #expect(result.status == 70)
        #expect(result.event["code"] as? String == "KLA_SCAN_ERROR")
        #expect(result.event["ok"] as? Bool == false)
        #expect((result.event["count"] as? Int ?? 0) > 0)
        #expect(result.hasCanonicalDigest)
    }
}

enum AcceptanceSyntheticLeak: String, CaseIterable, Sendable {
    case canary
    case originalMagic
    case memberToken
    case titleToken
    case organizationToken
    case dateSourceToken
    case conclusionToken
    case pdfMagic
    case absoluteUserPath

    var runID: String {
        switch self {
        case .canary: "d00000000000000000000001"
        case .originalMagic: "d00000000000000000000002"
        case .memberToken: "d00000000000000000000003"
        case .titleToken: "d00000000000000000000004"
        case .organizationToken: "d00000000000000000000005"
        case .dateSourceToken: "d00000000000000000000006"
        case .conclusionToken: "d00000000000000000000007"
        case .pdfMagic: "d00000000000000000000008"
        case .absoluteUserPath: "d00000000000000000000009"
        }
    }

    var payload: Data {
        let value: String
        switch self {
        case .canary:
            value = derivedToken(
                prefix: "KLA-",
                domain: "kinlogue.acceptance.canary.v1"
            )
        case .originalMagic:
            value = derivedToken(
                prefix: "KLO-",
                domain: "kinlogue.acceptance.original.v1"
            )
        case .memberToken:
            value = derivedToken(
                prefix: "KLM-",
                domain: "kinlogue.acceptance.member.v1"
            )
        case .titleToken:
            value = derivedToken(
                prefix: "KLT-",
                domain: "kinlogue.acceptance.title.v1"
            )
        case .organizationToken:
            value = derivedToken(
                prefix: "KLH-",
                domain: "kinlogue.acceptance.organization.v1"
            )
        case .dateSourceToken:
            value = derivedToken(
                prefix: "KLD-",
                domain: "kinlogue.acceptance.date-source.v1"
            )
        case .conclusionToken:
            value = derivedToken(
                prefix: "KLC-",
                domain: "kinlogue.acceptance.conclusion.v1"
            )
        case .pdfMagic:
            value = "%PDF-1.7 synthetic scanner fixture"
        case .absoluteUserPath:
            value = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("synthetic/private/artifact")
                .path
        }
        return Data(value.utf8)
    }

    private func derivedToken(prefix: String, domain: String) -> String {
        var input = Data(domain.utf8)
        input.append(0)
        input.append(contentsOf: runID.utf8)
        let digest = SHA256.hash(data: input).map {
            String(format: "%02x", $0)
        }.joined()
        return prefix + digest
    }
}

private struct AcceptanceScanResult {
    let status: Int32
    let event: [String: Any]

    var hasCanonicalDigest: Bool {
        guard let digest = event["summarySHA256"] as? String else {
            return false
        }
        return digest.range(
            of: "^[0-9a-f]{64}$",
            options: .regularExpression
        ) != nil
    }
}

private final class AcceptanceScanFixture {
    let runID: String
    let root: URL

    private var dataRoot: URL {
        root.appendingPathComponent("Data", isDirectory: true)
    }

    private var simulatedHome: URL {
        root.appendingPathComponent("NonstandardHome", isDirectory: true)
    }

    private var repositoryRoot: URL {
        root.appendingPathComponent("Repository", isDirectory: true)
    }

    init(runID: String) throws {
        self.runID = runID
        root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(
                "kinlogue-acceptance-scan-test.\(UUID().uuidString)",
                isDirectory: true
            )
        try createPrivateDirectory(root)
        try createPrivateDirectory(
            root.appendingPathComponent("CrashReports", isDirectory: true)
        )
        try createPrivateDirectory(simulatedHome)
        try createPrivateDirectory(repositoryRoot)
    }

    func install(_ leak: AcceptanceSyntheticLeak) throws {
        try createPrivateDirectory(dataRoot)
        try leak.payload.write(
            to: dataRoot.appendingPathComponent("synthetic-leak.bin"),
            options: .withoutOverwriting
        )
    }

    func installIgnoredDataLeak(_ leak: AcceptanceSyntheticLeak) throws {
        try createPrivateDirectory(dataRoot)
        try Data("ignored-leak.bin\n".utf8).write(
            to: dataRoot.appendingPathComponent(".ignore"),
            options: .withoutOverwriting
        )
        try leak.payload.write(
            to: dataRoot.appendingPathComponent("ignored-leak.bin"),
            options: .withoutOverwriting
        )
    }

    func installInRepositoryBuild(_ leak: AcceptanceSyntheticLeak) throws {
        let buildRoot = repositoryRoot.appendingPathComponent(
            ".build",
            isDirectory: true
        )
        try createPrivateDirectory(buildRoot)
        try leak.payload.write(
            to: buildRoot.appendingPathComponent("synthetic-leak.bin"),
            options: .withoutOverwriting
        )
    }

    func installNonstandardHomePathLeak() throws {
        try createPrivateDirectory(dataRoot)
        let leakedPath = simulatedHome
            .appendingPathComponent("private/report.pdf")
            .path
        try Data(leakedPath.utf8).write(
            to: dataRoot.appendingPathComponent("nonstandard-home-leak.bin"),
            options: .withoutOverwriting
        )
    }

    func installInSourceVault(_ leak: AcceptanceSyntheticLeak) throws {
        let sourceVault = dataRoot
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Kinlogue", isDirectory: true)
            .appendingPathComponent("Acceptance", isDirectory: true)
            .appendingPathComponent(runID, isDirectory: true)
            .appendingPathComponent("SourceVault", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceVault,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try #require(chmod(sourceVault.path, 0o700) == 0)
        try leak.payload.write(
            to: sourceVault.appendingPathComponent("\(leak.rawValue)-fixture.bin"),
            options: .withoutOverwriting
        )
    }

    func installInInstalledExecutable(_ leak: AcceptanceSyntheticLeak) throws {
        let locations = try createInstalledAppDirectories()
        try leak.payload.write(
            to: locations.executable,
            options: .withoutOverwriting
        )
        try #require(chmod(locations.executable.path, 0o700) == 0)
    }

    func installInInstalledResource(
        _ leak: AcceptanceSyntheticLeak,
        name: String
    ) throws {
        let locations = try createInstalledAppDirectories()
        try installBenignExecutable(at: locations.executable)
        try leak.payload.write(
            to: locations.resources.appendingPathComponent(name),
            options: .withoutOverwriting
        )
    }

    func installInstalledAppResourceSymlink() throws {
        let locations = try createInstalledAppDirectories()
        try installBenignExecutable(at: locations.executable)
        let target = root.appendingPathComponent("linked-resource-target.pdf")
        try Data("benign synthetic target".utf8).write(
            to: target,
            options: .withoutOverwriting
        )
        try FileManager.default.createSymbolicLink(
            at: locations.resources.appendingPathComponent("report.pdf"),
            withDestinationURL: target
        )
    }

    func installDataRootSymlink() throws {
        let target = root.appendingPathComponent("symlink-target", isDirectory: true)
        try createPrivateDirectory(target)
        try FileManager.default.createSymbolicLink(
            at: dataRoot,
            withDestinationURL: target
        )
    }

    func installRepositoryRootSymlink() throws {
        try FileManager.default.removeItem(at: repositoryRoot)
        let target = root.appendingPathComponent(
            "repository-symlink-target",
            isDirectory: true
        )
        try createPrivateDirectory(target)
        try FileManager.default.createSymbolicLink(
            at: repositoryRoot,
            withDestinationURL: target
        )
    }

    func installSourceVaultSymlink() throws {
        let runRoot = dataRoot
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Kinlogue", isDirectory: true)
            .appendingPathComponent("Acceptance", isDirectory: true)
            .appendingPathComponent(runID, isDirectory: true)
        try FileManager.default.createDirectory(
            at: runRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let target = root.appendingPathComponent(
            "source-vault-symlink-target",
            isDirectory: true
        )
        try createPrivateDirectory(target)
        try FileManager.default.createSymbolicLink(
            at: runRoot.appendingPathComponent("SourceVault", isDirectory: true),
            withDestinationURL: target
        )
    }

    func installManagedRunInternalSymlink() throws {
        let runRoot = dataRoot
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Kinlogue", isDirectory: true)
            .appendingPathComponent("Acceptance", isDirectory: true)
            .appendingPathComponent(runID, isDirectory: true)
        try FileManager.default.createDirectory(
            at: runRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let target = root.appendingPathComponent(
            "managed-run-symlink-target",
            isDirectory: true
        )
        try createPrivateDirectory(target)
        try FileManager.default.createSymbolicLink(
            at: runRoot.appendingPathComponent("hidden-output", isDirectory: true),
            withDestinationURL: target
        )
    }

    func runScanner(useSimulatedHome: Bool = false) throws -> AcceptanceScanResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [scannerURL.path, runID]
        var environment = ProcessInfo.processInfo.environment
        environment["KINLOGUE_ACCEPTANCE_INTERNAL_SCAN_TEST_ROOT"] = root.path
        if useSimulatedHome {
            environment["KINLOGUE_ACCEPTANCE_INTERNAL_SCAN_TEST_HOME"] =
                simulatedHome.path
        }
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let error = stderr.fileHandleForReading.readDataToEndOfFile()
        try #require(error.isEmpty)
        try #require(output.filter { $0 == 0x0A }.count == 1)
        let event = try #require(
            JSONSerialization.jsonObject(with: output) as? [String: Any]
        )
        return AcceptanceScanResult(
            status: process.terminationStatus,
            event: event
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private var scannerURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/scan-acceptance.sh")
    }

    private func createInstalledAppDirectories() throws -> (
        executable: URL,
        resources: URL
    ) {
        let app = root.appendingPathComponent("Installed.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try createPrivateDirectory(app)
        try createPrivateDirectory(contents)
        try createPrivateDirectory(macOS)
        try createPrivateDirectory(resources)
        return (
            executable: macOS.appendingPathComponent("Kinlogue"),
            resources: resources
        )
    }

    private func installBenignExecutable(at url: URL) throws {
        try Data("synthetic executable without document bytes".utf8).write(
            to: url,
            options: .withoutOverwriting
        )
        try #require(chmod(url.path, 0o700) == 0)
    }

    private func createPrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try #require(chmod(url.path, 0o700) == 0)
    }
}
