import Foundation
import Testing
@testable import KinlogueApp
@testable import KinlogueCore
@testable import KinloguePlatform

/// The per-member conversation model over the real service and SQLite library.
@MainActor
@Suite(.serialized)
struct AssistantConversationModelTests {
    @Test
    func openingAMemberAsksForConsentThenSends() async throws {
        let fixture = try await AssistantServiceFixture()
        defer { fixture.close() }
        let model = AssistantConversationModel(service: fixture.service, settings: { .enabled })

        await model.open(memberID: fixture.member.id)
        #expect(model.phase == .needsConsent)
        #expect(model.pack?.entries.count == 2)
        #expect(model.cliStatus?.cliVersion == "0.162.0")
        #expect(!model.hasConsent)

        await model.send("Before consent")
        #expect(model.issue == .consentRequired)
        #expect(fixture.backend.requests.isEmpty)

        model.confirm()
        #expect(model.phase == .ready)
        await model.send("空腹血糖是多少？")

        #expect(model.phase == .ready)
        #expect(model.issue == nil)
        #expect(model.conversation?.turns.map(\.answer) == ["Synthetic answer [R1]"])
        let source = try #require(model.conversation?.turns.first?.sources.first)
        #expect(model.citationStatus(of: source) == .current)

        model.startNewConversation()
        #expect(model.conversation == nil)
        #expect(model.phase == .ready, "a new conversation keeps the consent for the same pack and receiver")
    }

    @Test
    func aResultForAMemberNoLongerShownIsDropped() async throws {
        let fixture = try await AssistantServiceFixture()
        defer { fixture.close() }
        let other = try await fixture.library.member("Other synthetic member")
        _ = try await fixture.library.confirmed(other, day: 5, results: "Other")
        let model = AssistantConversationModel(service: fixture.service, settings: { .enabled })
        await model.open(memberID: fixture.member.id)
        model.confirm()

        fixture.backend.setBehavior(.waitForCancellation)
        let sending = Task { await model.send("Slow question") }
        try await fixture.backend.waitUntilStarted()
        #expect(model.phase == .sending)
        await model.open(memberID: other.id)
        await sending.value

        #expect(model.memberID == other.id)
        #expect(model.conversation == nil)
        #expect(model.phase == .needsConsent)
        #expect(model.issue == nil)
        #expect(await fixture.service.conversations(memberID: fixture.member.id).isEmpty)
    }

    @Test
    func stoppingATurnKeepsTheConversationAndReportsTheStop() async throws {
        let fixture = try await AssistantServiceFixture()
        defer { fixture.close() }
        let model = AssistantConversationModel(service: fixture.service, settings: { .enabled })
        await model.open(memberID: fixture.member.id)
        model.confirm()
        await model.send("  First \n")
        #expect(model.pendingQuestion == nil, "a completed turn is shown from the conversation")

        fixture.backend.setBehavior(.waitForCancellation)
        let sending = Task { await model.send("Second") }
        try await fixture.backend.waitUntilStarted()
        #expect(model.pendingQuestion == "Second")
        #expect(model.sendingStartedAt != nil)
        model.stop()
        await sending.value

        #expect(model.pendingQuestion == nil)
        #expect(model.sendingStartedAt == nil)
        #expect(model.phase == .ready)
        #expect(model.issue == .cli(.cancelled))
        #expect(model.conversation?.turns.map(\.question) == ["First"])
    }

    @Test
    func libraryChangesRebuildThePackAndClearConsentOnlyWhenItChanged() async throws {
        let fixture = try await AssistantServiceFixture()
        defer { fixture.close() }
        let model = AssistantConversationModel(service: fixture.service, settings: { .enabled })
        await model.open(memberID: fixture.member.id)
        model.confirm()
        await model.send("Q")
        let cited = try #require(model.conversation?.turns.first?.sources.last)

        await model.libraryChanged()
        #expect(model.phase == .ready, "an unrelated commit leaves the consent in place")

        let record = try await fixture.library.repository.record(cited.recordID)
        _ = try await fixture.library.edit(record, results: "Glucose\t6.0")
        await model.libraryChanged()

        #expect(model.phase == .needsConsent)
        #expect(model.issue == .consentRequired)
        #expect(model.citationStatus(of: cited) == .changed)
        #expect(model.pack?.renderedRecords().contains("Glucose\t6.0") == true)
        #expect(model.conversation?.turns.count == 1, "earlier answers stay")
    }

    @Test
    func includingTheOrganizationRebuildsThePackAndAsksAgain() async throws {
        let fixture = try await AssistantServiceFixture()
        defer { fixture.close() }
        let model = AssistantConversationModel(service: fixture.service, settings: { .enabled })
        await model.open(memberID: fixture.member.id)
        model.confirm()
        #expect(model.pack?.renderedRecords().contains("Synthetic Hospital") == false)

        await model.setIncludeOrganization(true)

        #expect(model.includeOrganization)
        #expect(model.pack?.renderedRecords().contains("Synthetic Hospital") == true)
        #expect(model.phase == .needsConsent)
    }

    @Test
    func destructiveLifecycleStopsAndClearsTheModelForGood() async throws {
        let fixture = try await AssistantServiceFixture()
        defer { fixture.close() }
        let model = AssistantConversationModel(service: fixture.service, settings: { .enabled })
        await model.open(memberID: fixture.member.id)
        model.confirm()
        fixture.backend.setBehavior(.waitForCancellation)
        let sending = Task { await model.send("Q") }
        try await fixture.backend.waitUntilStarted()

        model.beginDestructiveVaultLifecycle()
        await sending.value

        #expect(model.phase == .closed)
        #expect(model.memberID == nil)
        #expect(model.pack == nil)
        #expect(model.conversation == nil)
        await model.open(memberID: fixture.member.id)
        #expect(model.phase == .closed, "nothing opens again until the App restarts")
    }

    @Test
    func failuresAreKeptAsSemanticIssues() async throws {
        let fixture = try await AssistantServiceFixture()
        defer { fixture.close() }

        let disabled = AssistantConversationModel(service: fixture.service, settings: { AssistantSettings() })
        await disabled.open(memberID: fixture.member.id)
        #expect(disabled.phase == .unavailable)
        #expect(disabled.issue == .disabled)

        let empty = try await fixture.library.member("Empty synthetic member")
        let model = AssistantConversationModel(service: fixture.service, settings: { .enabled })
        await model.open(memberID: empty.id)
        #expect(model.phase == .unavailable)
        #expect(model.issue == .noConfirmedRecords)

        fixture.backend.setStatus(failure: .notLoggedIn)
        await model.open(memberID: fixture.member.id)
        #expect(model.phase == .unavailable)
        #expect(model.issue == .cli(.notLoggedIn))
        #expect(model.pack != nil, "the pack can still be previewed")

        fixture.backend.setStatus()
        await model.open(memberID: fixture.member.id)
        model.confirm()
        fixture.backend.setBehavior(.fail(.rateLimited))
        await model.send("Q")
        #expect(model.phase == .ready)
        #expect(model.issue == .cli(.rateLimited))

        await model.settingsChanged(to: AssistantSettings())
        #expect(model.phase == .unavailable)
        #expect(model.issue == .disabled)
        #expect(model.conversation == nil)
    }
}

/// The composed App on a real library: member chat is wired to the library lifecycle.
@MainActor
@Suite(.serialized)
struct AssistantCompositionTests {
    @Test
    func deletingTheLibraryStopsMemberChatForGood() async throws {
        let fixture = try SQLStartupFixture()
        defer { fixture.remove() }
        let context = try await SQLiteStartupContext.make(identity: fixture.identity)
        try await context.reconcile()
        let database = try await context.open()
        defer { try? database.close() }
        let reports = SQLiteReportRepository(store: database)
        let member = try FamilyMember(displayName: "Synthetic member")
        try await reports.saveMember(member, replacing: nil)
        let services = try await LiveAppServiceEnvironment.makeOpened(identity: fixture.identity, store: database, lifecycle: context.lifecycle)
        #expect(services.assistantLibrary != nil)
        let composition = AppComposition.makeOpened(identity: fixture.identity, services: services, context: context, database: database)
        #expect(await composition.startupCoordinator.start())
        let assistant = try #require(composition.assistantModel)
        #expect(composition.assistantSettings != nil)

        await assistant.open(memberID: member.id)
        #expect(assistant.memberID == member.id)

        composition.deletionModel.confirmationInput = VaultDeletionModel.confirmationPhrase
        await composition.deletionModel.deleteCurrentVault()

        #expect(assistant.phase == .closed)
        #expect(assistant.memberID == nil)
        await assistant.open(memberID: member.id)
        #expect(assistant.phase == .closed)
    }
}
