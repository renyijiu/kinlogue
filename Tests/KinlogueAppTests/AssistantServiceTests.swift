import Foundation
import os
import Testing
@testable import KinlogueApp
@testable import KinlogueCore
@testable import KinloguePlatform

/// The App's assistant service on a real SQLite library, with the bridge replaced by a backend the
/// test controls.
@Suite(.serialized)
struct AssistantServiceTests {
    @Test
    func aDisabledAssistantOrInvalidSettingsSendNothing() async throws {
        let fixture = try await AssistantServiceFixture()
        defer { fixture.close() }
        let (pack, consent) = try await fixture.consentedPack()

        await #expect(throws: AssistantServiceError.disabled) {
            _ = try await fixture.service.send("Q", conversationID: nil, pack: pack, consent: consent, settings: AssistantSettings())
        }
        await #expect(throws: AssistantServiceError.disabled) {
            _ = try await fixture.service.status(settings: AssistantSettings())
        }
        let invalid = AssistantSettings(isEnabled: true, executablePath: "relative/codex")
        await #expect(throws: AssistantServiceError.invalidSettings) {
            _ = try await fixture.service.status(settings: invalid)
        }
        #expect(fixture.backend.requests.isEmpty)
    }

    @Test
    func aTurnSendsThePackHistoryAndQuestionAndStoresTheCompletedTurn() async throws {
        let fixture = try await AssistantServiceFixture()
        defer { fixture.close() }
        let (pack, consent) = try await fixture.consentedPack()

        let first = try await fixture.service.send("空腹血糖是多少？", conversationID: nil, pack: pack, consent: consent, settings: .enabled)
        let second = try await fixture.service.send("还有别的吗？", conversationID: first.id, pack: pack, consent: consent, settings: .enabled)

        #expect(first.turns.count == 1)
        #expect(second.id == first.id)
        #expect(second.turns.map(\.question) == ["空腹血糖是多少？", "还有别的吗？"])
        #expect(second.turns[0].sources == pack.manifest)
        #expect(second.provider == consent.receiver)
        #expect(second.memberID == fixture.member.id)
        let requests = fixture.backend.requests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.model == consent.receiver.model && $0.instructions == AssistantPrompt.instructions })
        #expect(requests[0].input == AssistantPrompt.input(pack: pack, history: [], question: "空腹血糖是多少？"))
        #expect(requests[1].input.contains("<conversation>"))
        #expect(requests[1].input.contains("空腹血糖是多少？"))
        #expect(!requests.contains { $0.input.contains("Synthetic member") })
        #expect(try await fixture.service.summaries(memberID: fixture.member.id).map(\.id) == [second.id])
        #expect(try await fixture.service.conversation(second.id) == second)
    }

    @Test
    func savedConversationsOutliveTheServiceAndCanBeDeleted() async throws {
        let fixture = try await AssistantServiceFixture()
        defer { fixture.close() }
        let (pack, consent) = try await fixture.consentedPack()
        let first = try await fixture.service.send("First", conversationID: nil, pack: pack, consent: consent, settings: .enabled)
        let second = try await fixture.service.send("Second", conversationID: nil, pack: pack, consent: consent, settings: .enabled)

        // A new service on the same library, as after the App restarts.
        let restarted = LiveAssistantService(library: fixture.library.repository, store: fixture.library.repository,
                                             lifecycle: LibraryLifecycleCoordinator(), makeBackend: { _ in fixture.backend })
        #expect(try await restarted.summaries(memberID: fixture.member.id).map(\.id) == [second.id, first.id])
        #expect(try await restarted.conversation(first.id) == first)

        try await restarted.deleteConversation(first.id)
        #expect(try await restarted.summaries(memberID: fixture.member.id).map(\.id) == [second.id])
        try await restarted.deleteAllConversations()
        #expect(try await restarted.summaries(memberID: fixture.member.id).isEmpty)
    }

    @Test
    func consentLapsesWhenThePackTheCLIOrTheMemberChanges() async throws {
        let fixture = try await AssistantServiceFixture()
        defer { fixture.close() }
        let (pack, consent) = try await fixture.consentedPack()

        let other = try await fixture.library.member("Other synthetic member")
        _ = try await fixture.library.confirmed(other, day: 9, results: "Other")
        let otherPack = try await fixture.service.pack(memberID: other.id).pack
        await #expect(throws: AssistantServiceError.consentRequired) {
            _ = try await fixture.service.send("Q", conversationID: nil, pack: otherPack, consent: consent, settings: .enabled)
        }

        let organization = try await fixture.service.pack(memberID: fixture.member.id, includeOrganization: true).pack
        await #expect(throws: AssistantServiceError.consentRequired) {
            _ = try await fixture.service.send("Q", conversationID: nil, pack: organization, consent: consent, settings: .enabled)
        }

        fixture.backend.setStatus(cliVersion: "0.163.0")
        await #expect(throws: AssistantServiceError.consentRequired) {
            _ = try await fixture.service.send("Q", conversationID: nil, pack: pack, consent: consent, settings: .enabled)
        }
        #expect(fixture.backend.requests.isEmpty)
    }

    @Test
    func failedAndCancelledTurnsLeaveNoTrace() async throws {
        let fixture = try await AssistantServiceFixture()
        defer { fixture.close() }
        let (pack, consent) = try await fixture.consentedPack()

        fixture.backend.setBehavior(.fail(.notLoggedIn))
        await #expect(throws: AssistantServiceError.provider(.notLoggedIn)) {
            _ = try await fixture.service.send("Q", conversationID: nil, pack: pack, consent: consent, settings: .enabled)
        }

        fixture.backend.setBehavior(.waitForCancellation)
        let turn = Task { try await fixture.service.send("Q", conversationID: nil, pack: pack, consent: consent, settings: .enabled) }
        try await fixture.backend.waitUntilStarted()
        turn.cancel()
        await #expect(throws: AssistantServiceError.provider(.cancelled)) { _ = try await turn.value }

        await #expect(throws: AssistantServiceError.invalidQuestion) {
            _ = try await fixture.service.send("  ", conversationID: nil, pack: pack, consent: consent, settings: .enabled)
        }
        #expect(try await fixture.service.summaries(memberID: fixture.member.id).isEmpty)
    }

    @Test
    func aFullConversationRefusesAnotherTurn() async throws {
        let fixture = try await AssistantServiceFixture()
        defer { fixture.close() }
        let (pack, consent) = try await fixture.consentedPack()
        var conversation = try await fixture.service.send("Q0", conversationID: nil, pack: pack, consent: consent, settings: .enabled)
        for index in 1..<AssistantLimits.maxTurnsPerConversation {
            conversation = try await fixture.service.send("Q\(index)", conversationID: conversation.id, pack: pack, consent: consent, settings: .enabled)
        }

        await #expect(throws: AssistantServiceError.conversationFull) {
            _ = try await fixture.service.send("One more", conversationID: conversation.id, pack: pack, consent: consent, settings: .enabled)
        }
        #expect(fixture.backend.requests.count == AssistantLimits.maxTurnsPerConversation)
    }

    @Test
    func revocationCancelsTheTurnAndRefusesMoreWithoutWriting() async throws {
        let fixture = try await AssistantServiceFixture()
        defer { fixture.close() }
        let (pack, consent) = try await fixture.consentedPack()
        _ = try await fixture.service.send("Kept until revocation", conversationID: nil, pack: pack, consent: consent, settings: .enabled)
        try await fixture.lifecycle.register(id: UUID()) { [service = fixture.service] in await service.revoke() }

        fixture.backend.setBehavior(.waitForCancellation)
        let turn = Task { try await fixture.service.send("Q", conversationID: nil, pack: pack, consent: consent, settings: .enabled) }
        try await fixture.backend.waitUntilStarted()
        await fixture.lifecycle.revoke()

        await #expect(throws: AssistantServiceError.self) { _ = try await turn.value }
        // The library is being deleted or replaced: revocation stops the service but writes nothing.
        #expect(try await fixture.library.repository.assistantConversationSummaries(memberID: fixture.member.id).count == 1)
        await #expect(throws: AssistantServiceError.libraryUnavailable) {
            _ = try await fixture.service.summaries(memberID: fixture.member.id)
        }
        await #expect(throws: AssistantServiceError.libraryUnavailable) {
            _ = try await fixture.service.send("Q", conversationID: nil, pack: pack, consent: consent, settings: .enabled)
        }
        await #expect(throws: AssistantServiceError.libraryUnavailable) {
            _ = try await fixture.service.pack(memberID: fixture.member.id)
        }
    }

    @Test @MainActor
    func settingsLiveInTheAppsPreferencesAndRejectUnusableValues() throws {
        let suite = "kinlogue.assistant.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AssistantSettings(
            isEnabled: true, executablePath: "/opt/homebrew/bin/codex", model: "gpt-synthetic",
            proxy: ["HTTPS_PROXY": "http://127.0.0.1:6152"]
        )
        #expect(AssistantSettingsStore(defaults: defaults).settings == AssistantSettings())
        AssistantSettingsStore(defaults: defaults).update(settings)
        #expect(AssistantSettingsStore(defaults: defaults).settings == settings)

        defaults.set("not a model", forKey: AssistantSettingsStore.Key.model)
        defaults.set(["DYLD_INSERT_LIBRARIES": "/tmp/x", "HTTPS_PROXY": "http://127.0.0.1:6152"], forKey: AssistantSettingsStore.Key.proxy)
        let read = AssistantSettingsStore(defaults: defaults).settings
        #expect(read.model == nil)
        #expect(read.proxy == ["HTTPS_PROXY": "http://127.0.0.1:6152"])
    }
}

// MARK: - Fixtures

extension AssistantSettings {
    static let enabled = AssistantSettings(isEnabled: true)
}

struct AssistantServiceFixture {
    let library: AssistantAppLibrary
    let lifecycle = LibraryLifecycleCoordinator()
    let backend = FakeAssistantBackend()
    let service: LiveAssistantService
    let member: FamilyMember

    init() async throws {
        library = try AssistantAppLibrary()
        let backend = self.backend
        service = LiveAssistantService(
            library: library.repository, store: library.repository, lifecycle: lifecycle, makeBackend: { _ in backend }
        )
        member = try await library.member("Synthetic member")
        _ = try await library.confirmed(member, day: 1, results: "Glucose\t5.1")
        _ = try await library.confirmed(member, day: 2, results: "Glucose\t5.2")
    }

    func consentedPack() async throws -> (AssistantContextPack, AssistantConsent) {
        let pack = try await service.pack(memberID: member.id).pack
        let status = try await service.status(settings: .enabled)
        return (pack, try service.consent(pack: pack, status: status))
    }

    func close() { library.close() }
}

/// Stands in for the bridge: reports a ready CLI and answers, fails or waits as told.
final class FakeAssistantBackend: AssistantBackend {
    enum Behavior: Sendable {
        case answer
        case fail(AssistantFailure)
        case waitForCancellation
    }

    private struct State: Sendable {
        var cliVersion = "0.162.0"
        var failure: AssistantFailure?
        var behavior = Behavior.answer
        var requests: [AssistantProviderRequest] = []
        var started = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var requests: [AssistantProviderRequest] { state.withLock { $0.requests } }

    func setStatus(cliVersion: String = "0.162.0", failure: AssistantFailure? = nil) {
        state.withLock { $0.cliVersion = cliVersion; $0.failure = failure }
    }

    func setBehavior(_ behavior: Behavior) { state.withLock { $0.behavior = behavior } }

    func waitUntilStarted() async throws {
        let started = state.withLock { $0.started }
        let deadline = Date().addingTimeInterval(5)
        while state.withLock({ $0.started }) == started, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func status(model: String?) async -> AssistantCLIStatus {
        let (version, failure) = state.withLock { ($0.cliVersion, $0.failure) }
        return AssistantCLIStatus(
            executablePath: "/opt/homebrew/Caskroom/codex/synthetic/bin/codex", cliVersion: version, isLoggedIn: failure != .notLoggedIn,
            isVerifiedVersion: version == "0.162.0", failure: failure, model: model ?? "gpt-synthetic"
        )
    }

    func respond(to request: AssistantProviderRequest) async throws(AssistantFailure) -> AssistantProviderReply {
        let behavior = state.withLock { state -> Behavior in
            state.started += 1
            return state.behavior
        }
        switch behavior {
        case .answer:
            state.withLock { $0.requests.append(request) }
            let version = state.withLock { $0.cliVersion }
            guard let provider = try? AssistantProviderDescriptor(kind: .codex, cliVersion: version, model: request.model) else {
                throw .failed(exitCode: nil)
            }
            return AssistantProviderReply(answer: "Synthetic answer [R1]", provider: provider)
        case let .fail(failure):
            throw failure
        case .waitForCancellation:
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
            throw .cancelled
        }
    }
}

/// A fresh SQLite library with confirmed reports added through the real import path.
struct AssistantAppLibrary {
    let root: URL
    let store: SQLiteLibraryStore
    let repository: SQLiteReportRepository

    init() throws {
        let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("kinlogue-assistant-app-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        root = parent.appendingPathComponent("Vault", isDirectory: true)
        store = try SQLiteLibraryStore(rootURL: root)
        repository = SQLiteReportRepository(store: store)
    }

    func close() {
        try? store.close()
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    func member(_ name: String) async throws -> FamilyMember {
        let member = try FamilyMember(displayName: name)
        try await repository.saveMember(member, replacing: nil)
        return member
    }

    func confirmed(_ member: FamilyMember, day: Int, results: String) async throws -> HealthRecord {
        let data = Data("assistant-app-\(member.id)-\(day)-\(results)".utf8)
        let file = try ValidatedImportedFile(
            data: data, kind: .image, contentTypeIdentifier: "public.png", sha256Digest: ContentDigest.sha256(data)
        )
        guard case let .created(id) = try await repository.stage(file) else { throw LibraryReportError.invalidDocument }
        let lease = try await repository.beginProcessing(draftID: id, attemptID: UUID())
        try await repository.completeProcessing(lease: lease, document: ImportDraftDocument(blocks: [], candidates: ReportCandidates()))
        let draft = try await repository.draft(id)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = try #require(calendar.date(from: DateComponents(year: 2000 + day, month: 6, day: 1, hour: 12)))
        let candidate = ReportDateCandidate(date: date, kind: .report, source: try SourceField.manualEntry("Synthetic date"))
        let record = try HealthRecord(
            memberID: member.id, sources: draft.sources, ocrDocumentObjectID: draft.documentObjectID, importState: .confirmed,
            title: SourceField.manualEntry("Synthetic panel"), organization: SourceField.manualEntry("Synthetic Hospital"),
            dateCandidates: [candidate], timelineDateCandidateID: candidate.id, reportedResults: SourceField.manualEntry(results)
        )
        try await repository.confirm(draftID: id, expectedRevision: draft.revision, record: record)
        return record
    }

    func edit(_ record: HealthRecord, results: String) async throws -> HealthRecord {
        let next = try HealthRecord(
            id: record.id, memberID: record.memberID, sources: record.sources, ocrDocumentObjectID: record.ocrDocumentObjectID,
            importState: .confirmed, revision: record.revision + 1, title: record.title, organization: record.organization,
            dateCandidates: record.dateCandidates, timelineDateCandidateID: record.timelineDateCandidateID,
            reportedResults: SourceField.manualEntry(results)
        )
        try await repository.updateRecord(next, expectedRevision: record.revision)
        return next
    }
}
