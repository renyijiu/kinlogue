import Foundation
import Testing
@testable import KinlogueApp
@testable import KinlogueCore
@testable import KinloguePlatform

/// The member chat section of Settings: what it saves, what it refuses, and whom it tells.
@MainActor
@Suite(.serialized)
struct AssistantSettingsModelTests {
    @Test
    func enablingSavesTheSwitchAndChecksTheCLI() async throws {
        let fixture = try await AssistantServiceFixture()
        defer { fixture.close() }
        let (defaults, suite) = try Self.defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AssistantSettingsStore(defaults: defaults)
        let model = AssistantSettingsModel(store: store, service: fixture.service, conversation: nil, isAvailable: true)

        #expect(!model.settings.isEnabled)
        #expect(model.status == nil)
        await model.checkIfNeeded()
        #expect(model.status == nil, "nothing is checked while the feature is off")

        await model.setEnabled(true)
        #expect(store.settings.isEnabled)
        #expect(model.settings.isEnabled)
        #expect(model.status?.cliVersion == "0.162.0")
        #expect(model.status?.model == "gpt-synthetic")

        fixture.backend.setStatus(failure: .notLoggedIn)
        await model.check()
        #expect(model.status?.failure == .notLoggedIn)

        await model.setEnabled(false)
        #expect(!store.settings.isEnabled)
        #expect(model.status == nil)
    }

    @Test
    func draftsAreCheckedBeforeAnythingIsSaved() async throws {
        let fixture = try await AssistantServiceFixture()
        defer { fixture.close() }
        let (defaults, suite) = try Self.defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AssistantSettingsStore(defaults: defaults)
        let model = AssistantSettingsModel(store: store, service: fixture.service, conversation: nil, isAvailable: true)
        await model.setEnabled(true)

        for (draft, issue) in [
            (AssistantSettingsModel.Draft(executablePath: "codex"), AssistantSettingsIssue.invalidPath),
            (.init(executablePath: "~/bin/codex"), .invalidPath),
            (.init(model: "two words"), .invalidModel),
            (.init(model: "--config"), .invalidModel),
            (.init(proxy: "127.0.0.1:6152"), .invalidProxy),
            (.init(proxy: "ftp://127.0.0.1:21"), .invalidProxy),
            (.init(proxy: "http://127.0.0.1:6152/path?q=1"), .invalidProxy),
            (.init(proxy: "http://user@127.0.0.1:6152"), .proxyCredentials),
        ] {
            model.draft = draft
            await model.save()
            #expect(model.draftIssue == issue, "\(draft)")
            #expect(store.settings == AssistantSettings(isEnabled: true), "nothing was saved for \(draft)")
        }

        model.draft = .init(executablePath: " /opt/homebrew/bin/codex ", model: " gpt-synthetic ", proxy: " http://127.0.0.1:6152 ")
        #expect(model.hasUnsavedChanges)
        await model.save()

        #expect(model.draftIssue == nil)
        #expect(store.settings == AssistantSettings(
            isEnabled: true, executablePath: "/opt/homebrew/bin/codex", model: "gpt-synthetic",
            proxy: ["HTTPS_PROXY": "http://127.0.0.1:6152", "HTTP_PROXY": "http://127.0.0.1:6152"]
        ))
        #expect(model.draft == .init(executablePath: "/opt/homebrew/bin/codex", model: "gpt-synthetic", proxy: "http://127.0.0.1:6152"))
        #expect(!model.hasUnsavedChanges)
        #expect(model.status?.model == "gpt-synthetic")

        model.draft = .init()
        await model.save()
        #expect(store.settings == AssistantSettings(isEnabled: true), "empty fields go back to the defaults")
    }

    @Test
    func savingTellsTheOpenConversation() async throws {
        let fixture = try await AssistantServiceFixture()
        defer { fixture.close() }
        let (defaults, suite) = try Self.defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AssistantSettingsStore(defaults: defaults)
        store.update(.enabled)
        let conversation = AssistantConversationModel(service: fixture.service, settings: { store.settings })
        let model = AssistantSettingsModel(store: store, service: fixture.service, conversation: conversation, isAvailable: true)
        await conversation.open(memberID: fixture.member.id)
        conversation.confirm()
        #expect(conversation.phase == .ready)

        model.draft.model = "gpt-other"
        await model.save()
        #expect(conversation.phase == .needsConsent, "another model needs another consent")
        #expect(conversation.cliStatus?.model == "gpt-other")

        await model.setEnabled(false)
        #expect(conversation.phase == .unavailable)
        #expect(conversation.issue == .disabled)
    }

    /// The chat panel's model menu saves at once, like the switch, and leaves other unsaved fields alone.
    @Test
    func choosingAModelSavesItAndAsksTheOpenConversationAgain() async throws {
        let fixture = try await AssistantServiceFixture()
        defer { fixture.close() }
        let (defaults, suite) = try Self.defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AssistantSettingsStore(defaults: defaults)
        store.update(.enabled)
        let conversation = AssistantConversationModel(service: fixture.service, settings: { store.settings })
        let model = AssistantSettingsModel(store: store, service: fixture.service, conversation: conversation, isAvailable: true)
        await model.check()
        await conversation.open(memberID: fixture.member.id)
        conversation.confirm()
        #expect(model.status?.models.map(\.slug) == ["gpt-synthetic-mini", "gpt-synthetic"])
        #expect(model.status?.defaultModel == "gpt-synthetic")

        model.draft.proxy = "http://127.0.0.1:6152"
        await model.selectModel("gpt-synthetic-mini")
        #expect(store.settings.model == "gpt-synthetic-mini")
        #expect(store.settings.proxy.isEmpty, "the menu saves the model only")
        #expect(model.draft == .init(model: "gpt-synthetic-mini", proxy: "http://127.0.0.1:6152"))
        #expect(model.status?.model == "gpt-synthetic-mini")
        #expect(conversation.phase == .needsConsent, "another model needs another consent")
        #expect(conversation.cliStatus?.model == "gpt-synthetic-mini")

        await model.selectModel(nil)
        #expect(store.settings.model == nil)
        #expect(conversation.cliStatus?.model == "gpt-synthetic")

        await model.selectModel("--config")
        #expect(store.settings.model == nil, "a name the bridge would refuse is not saved")
    }

    @Test
    func theFeatureIsOfferedOnlyWhenTheBridgeIsInTheAppBundle() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("kinlogue-assistant-bundle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Kinlogue.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/XPCServices"), withIntermediateDirectories: true)

        #expect(!AssistantAvailability.isBridgeEmbedded(inAppAt: app))
        let bridge = app.appendingPathComponent("Contents/XPCServices/KinlogueAssistantBridge.xpc", isDirectory: true)
        try Data().write(to: bridge)
        #expect(!AssistantAvailability.isBridgeEmbedded(inAppAt: app), "a file is not a service bundle")
        try FileManager.default.removeItem(at: bridge)
        try FileManager.default.createDirectory(at: bridge, withIntermediateDirectories: false)
        #expect(AssistantAvailability.isBridgeEmbedded(inAppAt: app))
        #expect(!AssistantAvailability.isBridgeEmbedded(inAppAt: root), "only an App bundle can embed it")

        let builder = try String(contentsOf: repositoryURL.appendingPathComponent("scripts/build-app.sh"), encoding: .utf8)
        #expect(builder.contains(#"ASSISTANT_BRIDGE_PRODUCT="\#(AssistantAvailability.bridgeProduct)""#))
        #expect(builder.contains(#"Contents/XPCServices/$ASSISTANT_BRIDGE_PRODUCT.xpc"#))
    }

    private static func defaults() throws -> (UserDefaults, String) {
        let suite = "kinlogue.assistant.settings.tests.\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suite)), suite)
    }

    private var repositoryURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
}
