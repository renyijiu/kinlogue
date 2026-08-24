import Foundation
import Testing

@Test
func storageProcessFixtureTargetIsAvailableToTheTestGraph() async throws {
    try await withOwnedVaultFixture { fixture in
        try await withStorageProcessFixture(processCount: 1) { processes in
            try processes[0].send(.init(
                operation: "initialize",
                rootURL: fixture.rootURL
            ))
            let response = try await processes[0].nextResponse()
            #expect(response.event == "initialized")
        }
    }
}

@Test
func storageProcessFixtureRejectsAnIncompatibleProtocolHandshake() async throws {
    let process = try StorageProcessFixture()
    do {
        try process.start()
        try process.send(.init(
            operation: "handshake",
            protocolVersion: 0
        ))
        let response = try await process.nextResponse()
        #expect(response.event == "operationFailed")
        #expect(response.code == "invalidCommand")
        try await process.shutdown()
    } catch {
        process.terminateForCleanup()
        _ = await process.waitForExit()
        await process.waitForReader()
        throw error
    }
}

@Test
func storageProcessExitObservationDoesNotBlockAWorkerThread() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("FixtureProcess.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    #expect(source.contains("process.terminationHandler"))
    #expect(!source.contains("process.waitUntilExit()"))
}

@Test
func storageProcessExitObservationResumesConcurrentAndLateWaiters() async throws {
    let process = try StorageProcessFixture()
    do {
        try process.start()
        try await process.validateHandshake()
        let first = Task { await process.waitForExit() }
        let second = Task { await process.waitForExit() }

        try await process.shutdown()

        #expect(await first.value == 0)
        #expect(await second.value == 0)
        #expect(await process.waitForExit() == 0)
    } catch {
        process.terminateForCleanup()
        _ = await process.waitForExit()
        await process.waitForReader()
        throw error
    }
}

@Test
func storageProcessFixtureLocatorRejectsAnAncestorDecoy() throws {
    let fixture = try StorageProcessVaultFixture()
    defer { try? fixture.removeOwnedParent() }

    let buildDirectory = fixture.parentURL
        .appendingPathComponent("synthetic-build", isDirectory: true)
    let binDirectory = buildDirectory
        .appendingPathComponent("debug", isDirectory: true)
    let syntheticBundle = binDirectory
        .appendingPathComponent("SyntheticTests.xctest", isDirectory: true)
    try FileManager.default.createDirectory(
        at: syntheticBundle,
        withIntermediateDirectories: true
    )

    let ancestorDecoy = buildDirectory.appendingPathComponent(
        "KinlogueStorageProcessFixture",
        isDirectory: false
    )
    #expect(FileManager.default.createFile(
        atPath: ancestorDecoy.path,
        contents: Data([0x00]),
        attributes: [.posixPermissions: 0o700]
    ))

    #expect(throws: StorageProcessHarnessError.executableUnavailable) {
        try StorageProcessFixture.fixtureExecutableURL(
            testBundleURL: syntheticBundle
        )
    }
}
