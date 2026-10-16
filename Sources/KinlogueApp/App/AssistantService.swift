import Foundation
import KinlogueCore
import KinloguePlatform
import os

/// Member chat settings. They live in the App's preferences, never in the library.
struct AssistantSettings: Equatable, Sendable {
    var isEnabled = false
    /// Nil lets the bridge look for codex in its fixed locations.
    var executablePath: String?
    /// Nil uses the first model of the CLI's catalog.
    var model: String?
    var proxy: [String: String] = [:]
}

@MainActor
final class AssistantSettingsStore {
    enum Key {
        static let enabled = "assistant.enabled"
        static let executablePath = "assistant.executablePath"
        static let model = "assistant.model"
        static let proxy = "assistant.proxy"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The stored settings; a value the bridge would refuse reads as unset.
    var settings: AssistantSettings {
        let path = defaults.string(forKey: Key.executablePath)
        let model = defaults.string(forKey: Key.model)
        let proxy = (defaults.dictionary(forKey: Key.proxy) as? [String: String] ?? [:]).filter { key, value in
            (try? AssistantCLISettings(executablePath: nil, proxy: [key: value])) != nil
        }
        return AssistantSettings(
            isEnabled: defaults.bool(forKey: Key.enabled),
            executablePath: path.flatMap { (try? AssistantCLISettings(executablePath: $0, proxy: [:])) != nil ? $0 : nil },
            model: model.flatMap { AssistantCLISettings.isValidModel($0) ? $0 : nil },
            proxy: proxy
        )
    }

    func update(_ settings: AssistantSettings) {
        defaults.set(settings.isEnabled, forKey: Key.enabled)
        defaults.set(settings.executablePath, forKey: Key.executablePath)
        defaults.set(settings.model, forKey: Key.model)
        defaults.set(settings.proxy, forKey: Key.proxy)
    }
}

/// Whether this build carries the bridge. `scripts/build-app.sh` always embeds it; a build without
/// it, such as one run straight from SwiftPM, does not offer the feature.
enum AssistantAvailability {
    /// The bridge's product name in `scripts/build-app.sh`.
    static let bridgeProduct = "KinlogueAssistantBridge"

    static func isBridgeEmbedded(inAppAt appURL: URL = Bundle.main.bundleURL) -> Bool {
        guard appURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame else { return false }
        let bridge = appURL.appendingPathComponent("Contents/XPCServices/\(bridgeProduct).xpc", isDirectory: true)
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: bridge.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

/// The bridge as the App uses it: a provider that can also report the CLI's status.
protocol AssistantBackend: AssistantProvider {
    func status(model: String?) async -> AssistantCLIStatus
}

extension BridgeAssistantProvider: AssistantBackend {}

/// The library reads the assistant needs.
protocol AssistantLibraryReading: Sendable {
    func assistantPack(memberID: UUID, selection: AssistantPackSelection, includeOrganization: Bool) async throws -> AssistantPackLoad
    func assistantRecordStates(_ ids: [UUID]) async throws -> [UUID: AssistantRecordState]
}

extension SQLiteReportRepository: AssistantLibraryReading {}

enum AssistantConversationStoreError: Error, Equatable, Sendable {
    case tooManyConversations
}

/// Where conversations are kept. The first version keeps them in memory; a saved version stores
/// the same values (docs/plans/2026-10-15-feat-member-cli-chat-plan.md, section 4.9).
protocol AssistantConversationStoring: Sendable {
    func conversation(_ id: UUID) async -> AssistantConversation?
    /// Newest first.
    func conversations(memberID: UUID) async -> [AssistantConversation]
    func save(_ conversation: AssistantConversation) async throws
    func deleteAll(memberID: UUID) async
    func deleteAll() async
}

actor InMemoryAssistantConversationStore: AssistantConversationStoring {
    private var conversations: [UUID: AssistantConversation] = [:]

    func conversation(_ id: UUID) -> AssistantConversation? { conversations[id] }

    func conversations(memberID: UUID) -> [AssistantConversation] {
        conversations.values.filter { $0.memberID == memberID }.sorted { $0.updatedAt > $1.updatedAt }
    }

    func save(_ conversation: AssistantConversation) throws {
        if conversations[conversation.id] == nil,
           conversations.values.filter({ $0.memberID == conversation.memberID }).count >= AssistantLimits.maxConversationsPerMember {
            throw AssistantConversationStoreError.tooManyConversations
        }
        conversations[conversation.id] = conversation
    }

    func deleteAll(memberID: UUID) {
        conversations = conversations.filter { $0.value.memberID != memberID }
    }

    func deleteAll() { conversations.removeAll() }
}

/// What the user agreed to send in the confirmation sheet: this member's pack, as fingerprinted,
/// to this CLI and model. It is never stored.
struct AssistantConsent: Equatable, Sendable {
    let memberID: UUID
    let receiver: AssistantProviderDescriptor
    let fingerprint: Data
}

enum AssistantServiceError: Error, Equatable, Sendable {
    case disabled
    case invalidSettings
    /// The pack, the CLI or the model changed since the consent was given.
    case consentRequired
    case conversationFull
    case invalidQuestion
    /// The library is being deleted or replaced.
    case libraryUnavailable
    case storage
    case pack(AssistantPackError)
    case provider(AssistantFailure)
}

/// Member chat for the App: reads packs, binds consent to what is sent and to whom, runs one turn
/// inside the library lifecycle, and keeps completed turns only.
final class LiveAssistantService: Sendable {
    private let library: any AssistantLibraryReading
    private let store: any AssistantConversationStoring
    private let lifecycle: LibraryLifecycleCoordinator
    private let makeBackend: @Sendable (AssistantSettings) throws -> any AssistantBackend
    private let state = OSAllocatedUnfairLock(initialState: State())

    private struct State: Sendable {
        var revoked = false
        var running: [UUID: Task<Result<AssistantProviderReply, AssistantFailure>, Never>] = [:]
    }

    init(
        library: any AssistantLibraryReading,
        store: any AssistantConversationStoring,
        lifecycle: LibraryLifecycleCoordinator,
        makeBackend: @escaping @Sendable (AssistantSettings) throws -> any AssistantBackend
    ) {
        self.library = library
        self.store = store
        self.lifecycle = lifecycle
        self.makeBackend = makeBackend
    }

    /// The production service: the bridge XPC service embedded in the App bundle.
    static func overXPC(library: any AssistantLibraryReading, lifecycle: LibraryLifecycleCoordinator) -> LiveAssistantService {
        LiveAssistantService(library: library, store: InMemoryAssistantConversationStore(), lifecycle: lifecycle) { settings in
            BridgeAssistantProvider.overXPC(settings: try AssistantCLISettings(executablePath: settings.executablePath, proxy: settings.proxy))
        }
    }

    func status(settings: AssistantSettings) async throws -> AssistantCLIStatus {
        let backend = try backend(for: settings)
        return await backend.status(model: settings.model)
    }

    func pack(
        memberID: UUID,
        selection: AssistantPackSelection = .automatic,
        includeOrganization: Bool = false
    ) async throws -> AssistantPackLoad {
        try requireUsable()
        do {
            return try await library.assistantPack(memberID: memberID, selection: selection, includeOrganization: includeOrganization)
        } catch let error as AssistantPackError {
            throw AssistantServiceError.pack(error)
        } catch {
            throw state.withLock({ $0.revoked }) ? AssistantServiceError.libraryUnavailable : AssistantServiceError.storage
        }
    }

    /// The consent for sending `pack` to the CLI and model `status` reports.
    func consent(pack: AssistantContextPack, status: AssistantCLIStatus) throws -> AssistantConsent {
        guard status.failure == nil, let version = status.cliVersion, let model = status.model,
              let receiver = try? AssistantProviderDescriptor(kind: .codex, cliVersion: version, model: model) else {
            throw AssistantServiceError.provider(status.failure ?? .unsupportedCLI)
        }
        return AssistantConsent(memberID: pack.memberID, receiver: receiver, fingerprint: try fingerprint(pack, receiver))
    }

    /// Sends one question with the pack and the conversation's earlier turns, and stores the turn
    /// once it completes. Cancelling the calling task stops the turn.
    func send(
        _ question: String,
        conversationID: UUID?,
        pack: AssistantContextPack,
        consent: AssistantConsent,
        settings: AssistantSettings
    ) async throws -> AssistantConversation {
        try requireUsable()
        let backend = try backend(for: settings)
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, question.count <= AssistantLimits.maxQuestionCharacters else {
            throw AssistantServiceError.invalidQuestion
        }
        guard consent.memberID == pack.memberID, (try? fingerprint(pack, consent.receiver)) == consent.fingerprint else {
            throw AssistantServiceError.consentRequired
        }
        let status = await backend.status(model: consent.receiver.model)
        if let failure = status.failure { throw AssistantServiceError.provider(failure) }
        guard status.cliVersion == consent.receiver.cliVersion, status.model == consent.receiver.model else {
            throw AssistantServiceError.consentRequired
        }

        var conversation: AssistantConversation
        if let conversationID {
            guard let existing = await store.conversation(conversationID), existing.memberID == pack.memberID,
                  existing.provider == consent.receiver else { throw AssistantServiceError.consentRequired }
            conversation = existing
        } else {
            conversation = try AssistantConversation(
                memberID: pack.memberID, createdAt: Date(), provider: consent.receiver, promptVersion: AssistantPrompt.version
            )
        }
        guard conversation.turns.count < AssistantLimits.maxTurnsPerConversation else {
            throw AssistantServiceError.conversationFull
        }

        let request = AssistantProviderRequest(
            model: consent.receiver.model, instructions: AssistantPrompt.instructions,
            input: AssistantPrompt.input(pack: pack, history: conversation.resendWindow().turns, question: question)
        )
        let reply: AssistantProviderReply
        do {
            reply = try await lifecycle.withActiveOperation { try await self.run(backend, request).get() }
        } catch let failure as AssistantFailure {
            throw AssistantServiceError.provider(failure)
        } catch {
            throw AssistantServiceError.libraryUnavailable
        }
        try requireUsable()

        do {
            conversation = try conversation.appending(AssistantTurn(
                ordinal: conversation.turns.count, question: question, answer: reply.answer,
                completedAt: Date(), sources: pack.manifest
            ))
        } catch AssistantConversationError.answerTooLarge {
            throw AssistantServiceError.provider(.outputTooLarge)
        } catch {
            throw AssistantServiceError.provider(.failed(exitCode: nil))
        }
        do { try await store.save(conversation) } catch { throw AssistantServiceError.storage }
        return conversation
    }

    func recordStates(_ ids: [UUID]) async throws -> [UUID: AssistantRecordState] {
        try requireUsable()
        do { return try await library.assistantRecordStates(ids) } catch { throw AssistantServiceError.storage }
    }

    func conversations(memberID: UUID) async -> [AssistantConversation] {
        await store.conversations(memberID: memberID)
    }

    func discardConversations(memberID: UUID) async {
        await store.deleteAll(memberID: memberID)
    }

    /// Stops every running turn and forgets every conversation, for turning the feature off.
    func discardAll() async {
        cancelRunningTurns()
        await store.deleteAll()
    }

    /// The library is going away: stop, forget, and refuse further work.
    func revoke() async {
        state.withLock { $0.revoked = true }
        await discardAll()
    }

    // MARK: - Private

    private func requireUsable() throws {
        if state.withLock({ $0.revoked }) { throw AssistantServiceError.libraryUnavailable }
    }

    private func backend(for settings: AssistantSettings) throws -> any AssistantBackend {
        guard settings.isEnabled else { throw AssistantServiceError.disabled }
        guard (try? AssistantCLISettings(executablePath: settings.executablePath, proxy: settings.proxy)) != nil,
              settings.model.map(AssistantCLISettings.isValidModel) ?? true,
              let backend = try? makeBackend(settings) else { throw AssistantServiceError.invalidSettings }
        return backend
    }

    private func fingerprint(_ pack: AssistantContextPack, _ receiver: AssistantProviderDescriptor) throws -> Data {
        try pack.consentFingerprint(provider: receiver, promptVersion: AssistantPrompt.version, digest: ContentDigest.sha256)
    }

    /// Runs the turn in a task the service can cancel on revocation, and forwards the caller's
    /// cancellation to it.
    private func run(_ backend: any AssistantBackend, _ request: AssistantProviderRequest) async -> Result<AssistantProviderReply, AssistantFailure> {
        let id = UUID()
        let task = Task { () -> Result<AssistantProviderReply, AssistantFailure> in
            do throws(AssistantFailure) { return .success(try await backend.respond(to: request)) } catch { return .failure(error) }
        }
        let admitted = state.withLock { state -> Bool in
            guard !state.revoked else { return false }
            state.running[id] = task
            return true
        }
        guard admitted else {
            task.cancel()
            return .failure(.cancelled)
        }
        defer { state.withLock { _ = $0.running.removeValue(forKey: id) } }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private func cancelRunningTurns() {
        state.withLock { $0.running.values.forEach { $0.cancel() } }
    }
}
