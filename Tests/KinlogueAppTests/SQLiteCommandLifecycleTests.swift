import Foundation
import GRDB
import Testing
@testable import KinlogueApp
@testable import KinlogueCore
@testable import KinloguePlatform

@Suite(.serialized)
struct SQLiteCommandLifecycleTests {
    @Test
    func revocationDrainsAnAcceptedSQLCommandAndPreservesItsCommittedResponse() async throws {
        let fixture = try SQLiteAppQueryFixture()
        defer { fixture.destroy() }
        let lifecycle = LibraryLifecycleCoordinator()
        let service = LiveAppService(reports: fixture.reports, studies: fixture.studies,
            draftStore: fixture.reports, workflow: ImportWorkflow(store: fixture.reports,
            textExtractor: CommandExtractor()), lifecycle: lifecycle)
        _ = try await service.bootstrap()
        let gate = CommandCommitGate()
        try fixture.store.write { db in
            db.add(function: DatabaseFunction("hold_command", argumentCount: 0) { _ in
                gate.hold(); return 1
            })
            try db.execute(sql: "CREATE TEMP TRIGGER hold_member AFTER INSERT ON members BEGIN SELECT hold_command(); END")
        }
        let command = Task { try await service.createMember(displayName: "Synthetic accepted command", disambiguationLabel: nil) }
        for _ in 0..<500 where !gate.started { try await Task.sleep(for: .milliseconds(2)) }
        #expect(gate.started)
        let revoking = try await installRevocationGate(on: lifecycle)
        let revoked = CommandCompletion()
        let revocation = Task { await lifecycle.revoke(); await revoked.finish() }
        #expect(await revoking.waitUntilStarted())
        await revoking.open()
        #expect(!(await revoked.finished))
        await #expect(throws: LibraryLifecycleCoordinatorError.revoked) {
            try await service.createMember(displayName: "Synthetic rejected command", disambiguationLabel: nil)
        }
        gate.release()
        let response = try await command.value
        await revocation.value
        #expect(response.members.count == 1)
        #expect(try await fixture.reports.members().count == 1)
        try fixture.store.closeDatabaseForReplacement()
        #expect(await revoked.finished)
    }
}

// SAFETY: lock protects the start signal; the semaphore only holds the synthetic SQL callback.
private final class CommandCommitGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didStart = false
    private let semaphore = DispatchSemaphore(value: 0)
    var started: Bool { lock.withLock { didStart } }
    func hold() { lock.withLock { didStart = true }; _ = semaphore.wait(timeout: .now() + 10) }
    func release() { semaphore.signal() }
}
private actor CommandCompletion {
    private(set) var finished = false
    func finish() { finished = true }
}
private struct CommandExtractor: TextExtractionService {
    func extractText(from file: ValidatedImportedFile) async throws -> [OCRBlock] { [] }
}
