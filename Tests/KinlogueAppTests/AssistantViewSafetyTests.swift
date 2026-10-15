import Foundation
import Testing

/// Source checks for the member chat views: they show what the models hold and create nothing.
struct AssistantViewSafetyTests {
    private static let viewFiles = ["AssistantPanelView.swift", "AssistantConsentSheet.swift", "AssistantSettingsSection.swift"]

    @Test
    func viewsCreateNoServicesAndReadNoPreferences() throws {
        for file in Self.viewFiles {
            let source = try view(file)
            for forbidden in [
                "LiveAssistantService", "BridgeAssistantProvider", "KinlogueAssistantXPCClient", "AssistantSettingsStore",
                "UserDefaults", "@AppStorage", "SQLiteReportRepository", "Process(", "NSWorkspace",
            ] {
                #expect(!source.contains(forbidden), "\(file) must not use \(forbidden)")
            }
        }
    }

    @Test
    func answersAreLabelledNeutralAndRenderedWithoutLinks() throws {
        let panel = try view("AssistantPanelView.swift")

        #expect(panel.contains("AssistantText.answerLabel("))
        #expect(panel.contains("AssistantAnswerFormatting.attributed("))
        #expect(!panel.contains("LocalizedStringKey"), "a LocalizedStringKey would render the answer's markdown links")
        #expect(!panel.contains("Text(.init("))
        // Answers carry no judgement colour; only the issue line uses a status tone.
        for tone in ["KinlogueTheme.danger", "KinlogueTheme.warning", "KinlogueTheme.success", "KinlogueTheme.accent"] {
            #expect(!panel.contains(tone), "answer views must stay neutral: \(tone)")
        }
        #expect(panel.contains("KinlogueStatusLabel(issue.message(), tone: issue.tone)"))
        #expect(panel.contains(".textSelection(.enabled)"))
    }

    @Test
    func theQuestionEditorSendsWithCommandReturnAndWaitsForTheInputMethod() throws {
        let panel = try view("AssistantPanelView.swift")

        #expect(panel.contains("TextEditor(text: $draft)"))
        #expect(panel.contains(".writingToolsBehavior(.disabled)"))
        #expect(panel.contains(".keyboardShortcut(.return, modifiers: .command)"))
        #expect(panel.contains("TextInputComposition.isActive(in: NSApp.keyWindow?.firstResponder)"))
        #expect(!panel.contains(".onSubmit"), "Return adds a line; only Command-Return sends")
    }

    @Test
    func consentIsGivenOnlyFromTheSheetThatShowsWhatIsSent() throws {
        let panel = try view("AssistantPanelView.swift")
        let sheet = try view("AssistantConsentSheet.swift")

        #expect(!panel.contains("model.confirm()"), "the panel opens the sheet; it never confirms by itself")
        #expect(sheet.contains("model.confirm()"))
        #expect(sheet.contains("model.pack?.renderedRecords()") || sheet.contains("pack.renderedRecords()"))
        #expect(sheet.contains("model.setIncludeOrganization("))
        #expect(sheet.contains(".kinlogueSheetCanvas()"))
        #expect(sheet.contains(".disabled(model.phase != .needsConsent)"))
    }

    @Test
    func theShellOffersChatOnlyForOneMemberAndHidesItWithoutTheBridge() throws {
        let shell = try view("AppShellView.swift")
        let launch = try view("SQLiteAppLaunchView.swift")
        let settings = try view("SettingsView.swift")
        let section = try view("AssistantSettingsSection.swift")

        #expect(shell.contains("AssistantPanelView("))
        #expect(shell.contains("AssistantToolbarItem("))
        #expect(shell.contains("hasMember: model.selectedMemberID != nil"))
        #expect(launch.contains("assistantModel: composition.assistantModel"))
        #expect(launch.contains("assistantSettings: composition.assistantSettings"))
        #expect(settings.contains("AssistantSettingsSection("))
        #expect(section.contains("settings.isAvailable"))
        #expect(try view("AssistantPanelView.swift").contains("settings.isAvailable && settings.settings.isEnabled"))
    }

    private func view(_ file: String) throws -> String {
        try String(contentsOf: repositoryURL.appendingPathComponent("Sources/KinlogueApp/Views").appendingPathComponent(file), encoding: .utf8)
    }

    private var repositoryURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
}
