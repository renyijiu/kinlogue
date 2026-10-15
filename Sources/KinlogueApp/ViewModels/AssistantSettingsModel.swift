import Foundation
import KinlogueCore
import KinloguePlatform

/// Why a settings draft cannot be saved. Kept as a value; the view chooses the words.
enum AssistantSettingsIssue: Error, Equatable, Sendable {
    case invalidPath
    case invalidModel
    case invalidProxy
    /// Settings live in the App's preferences in plain text, so a proxy password is refused.
    case proxyCredentials
}

/// The member chat section of Settings: the switch, the CLI fields and the CLI's status. Saving
/// tells the open conversation, which asks for consent again when the receiver changed.
@MainActor
final class AssistantSettingsModel: ObservableObject {
    struct Draft: Equatable, Sendable {
        var executablePath = ""
        var model = ""
        var proxy = ""
    }

    /// One proxy field sets both variables; `ALL_PROXY` and `NO_PROXY` are not offered.
    static let proxyKeys = ["HTTPS_PROXY", "HTTP_PROXY"]
    private static let proxySchemes: Set<String> = ["http", "https", "socks5", "socks5h"]

    @Published private(set) var settings: AssistantSettings
    @Published var draft: Draft
    @Published private(set) var draftIssue: AssistantSettingsIssue?
    @Published private(set) var status: AssistantCLIStatus?
    /// A check that could not run at all, such as settings the bridge refuses.
    @Published private(set) var checkIssue: AssistantIssue?
    @Published private(set) var isChecking = false
    let isAvailable: Bool

    private let store: AssistantSettingsStore
    private let service: LiveAssistantService
    private weak var conversation: AssistantConversationModel?
    private var generation: UInt64 = 0

    init(
        store: AssistantSettingsStore,
        service: LiveAssistantService,
        conversation: AssistantConversationModel?,
        isAvailable: Bool = AssistantAvailability.isBridgeEmbedded()
    ) {
        self.store = store
        self.service = service
        self.conversation = conversation
        self.isAvailable = isAvailable
        settings = store.settings
        draft = Self.draft(for: store.settings)
    }

    var hasUnsavedChanges: Bool {
        draft != Self.draft(for: settings)
    }

    func setEnabled(_ enabled: Bool) async {
        guard enabled != settings.isEnabled else { return }
        var next = settings
        next.isEnabled = enabled
        await apply(next)
    }

    func save() async {
        switch validated(draft) {
        case let .success(next):
            await apply(next)
        case let .failure(issue):
            draftIssue = issue
        }
    }

    func revertDraft() {
        draft = Self.draft(for: settings)
        draftIssue = nil
    }

    /// Checks the CLI the first time the section is shown with the feature on.
    func checkIfNeeded() async {
        guard settings.isEnabled, status == nil, checkIssue == nil, !isChecking else { return }
        await check()
    }

    func check() async {
        guard settings.isEnabled else { return }
        generation &+= 1
        let generation = generation
        isChecking = true
        defer { if generation == self.generation { isChecking = false } }
        do {
            let status = try await service.status(settings: settings)
            guard generation == self.generation else { return }
            self.status = status
            checkIssue = nil
        } catch {
            guard generation == self.generation else { return }
            status = nil
            checkIssue = (error as? AssistantServiceError) == .disabled ? .disabled : .invalidSettings
        }
    }

    // MARK: - Private

    private func apply(_ next: AssistantSettings) async {
        store.update(next)
        settings = store.settings
        draft = Self.draft(for: settings)
        draftIssue = nil
        generation &+= 1
        status = nil
        checkIssue = nil
        isChecking = false
        await conversation?.settingsChanged(to: settings)
        await check()
    }

    private func validated(_ draft: Draft) -> Result<AssistantSettings, AssistantSettingsIssue> {
        var next = settings
        let path = draft.executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty {
            next.executablePath = nil
        } else {
            guard path.hasPrefix("/"), !path.hasSuffix("/"),
                  (try? AssistantCLISettings(executablePath: path, proxy: [:])) != nil else { return .failure(.invalidPath) }
            next.executablePath = path
        }

        let model = draft.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.isEmpty {
            next.model = nil
        } else {
            guard AssistantCLISettings.isValidModel(model) else { return .failure(.invalidModel) }
            next.model = model
        }

        let proxy = draft.proxy.trimmingCharacters(in: .whitespacesAndNewlines)
        if proxy.isEmpty {
            next.proxy = [:]
        } else {
            guard let components = URLComponents(string: proxy),
                  let scheme = components.scheme?.lowercased(), Self.proxySchemes.contains(scheme),
                  let host = components.host, !host.isEmpty,
                  components.path.isEmpty || components.path == "/",
                  components.query == nil, components.fragment == nil else { return .failure(.invalidProxy) }
            guard components.user == nil, components.password == nil else { return .failure(.proxyCredentials) }
            let environment = Dictionary(uniqueKeysWithValues: Self.proxyKeys.map { ($0, proxy) })
            guard (try? AssistantCLISettings(executablePath: nil, proxy: environment)) != nil else { return .failure(.invalidProxy) }
            next.proxy = environment
        }
        return .success(next)
    }

    private static func draft(for settings: AssistantSettings) -> Draft {
        Draft(
            executablePath: settings.executablePath ?? "",
            model: settings.model ?? "",
            proxy: proxyKeys.lazy.compactMap { settings.proxy[$0] }.first ?? ""
        )
    }
}
