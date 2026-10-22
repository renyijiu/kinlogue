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

/// Where conversations are kept: the library, so saved chats go into backups and are
/// deleted with their member or the library (docs/plans/2026-10-15-feat-member-cli-chat-plan.md, 4.9).
protocol AssistantConversationStoring: Sendable {
    func savedConversation(_ id: UUID) async throws -> AssistantConversation?
    /// Newest first.
    func savedConversationSummaries(memberID: UUID) async throws -> [AssistantConversationSummary]
    func saveConversation(_ conversation: AssistantConversation) async throws
    func deleteConversation(_ id: UUID) async throws
    func deleteAllConversations() async throws
}

extension SQLiteReportRepository: AssistantConversationStoring {
    func savedConversation(_ id: UUID) async throws -> AssistantConversation? { try await assistantConversation(id) }
    func savedConversationSummaries(memberID: UUID) async throws -> [AssistantConversationSummary] {
        try await assistantConversationSummaries(memberID: memberID)
    }
    func saveConversation(_ conversation: AssistantConversation) async throws { try await saveAssistantConversation(conversation) }
    func deleteConversation(_ id: UUID) async throws { try await deleteAssistantConversation(id) }
    func deleteAllConversations() async throws { try await deleteAllAssistantConversations() }
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
    /// The member already keeps `AssistantLimits.maxConversationsPerMember` saved conversations.
    case tooManyConversations
    case invalidQuestion
    /// The library is being deleted or replaced.
    case libraryUnavailable
    case storage
    case pack(AssistantPackError)
    case provider(AssistantFailure)
}

/// Member chat for the App: reads packs, binds consent to what is sent and to whom, runs one turn
/// and saves it inside the library lifecycle, and keeps completed turns only.
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

    /// The production service: the bridge XPC service embedded in the App bundle, and conversations
    /// saved in the library.
    static func overXPC(
        library: any AssistantLibraryReading & AssistantConversationStoring, lifecycle: LibraryLifecycleCoordinator
    ) -> LiveAssistantService {
        LiveAssistantService(library: library, store: library, lifecycle: lifecycle) { settings in
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

    /// The reports an answer cites, in the order the pack lists them. A turn keeps only these: the
    /// pack may number hundreds, and a citation shows only through its own source.
    static func citedSources(_ answer: String, in manifest: [AssistantTurnSource]) -> [AssistantTurnSource] {
        let cited = Set(AssistantCitationParser.labels(in: answer))
        return manifest.filter { cited.contains($0.label) }
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
            guard let existing = try await stored({ try await self.store.savedConversation(conversationID) }),
                  existing.memberID == pack.memberID,
                  existing.continues(with: consent.receiver, promptVersion: AssistantPrompt.version) else {
                throw AssistantServiceError.consentRequired
            }
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
        let started = conversation
        let store = store
        do {
            // The turn and its save are one active operation: deleting or replacing the library
            // waits for both, or cancels the turn first.
            return try await lifecycle.withActiveOperation {
                let reply = try await self.run(backend, request).get()
                try self.requireUsable()
                let updated: AssistantConversation
                do {
                    updated = try started.appending(AssistantTurn(
                        ordinal: started.turns.count, question: question, answer: reply.answer,
                        completedAt: Date(), sources: Self.citedSources(reply.answer, in: pack.manifest)
                    ))
                } catch AssistantConversationError.answerTooLarge {
                    throw AssistantServiceError.provider(.outputTooLarge)
                } catch {
                    throw AssistantServiceError.provider(.failed(exitCode: nil))
                }
                do {
                    try await store.saveConversation(updated)
                    // What the user sees is what was saved.
                    guard let saved = try await store.savedConversation(updated.id) else { throw AssistantServiceError.storage }
                    return saved
                } catch LibraryReportError.resourceLimit {
                    throw AssistantServiceError.tooManyConversations
                } catch let error as AssistantServiceError {
                    throw error
                } catch {
                    throw AssistantServiceError.storage
                }
            }
        } catch let failure as AssistantFailure {
            throw AssistantServiceError.provider(failure)
        } catch let error as AssistantServiceError {
            throw error
        } catch {
            throw AssistantServiceError.libraryUnavailable
        }
    }

    func recordStates(_ ids: [UUID]) async throws -> [UUID: AssistantRecordState] {
        try requireUsable()
        do { return try await library.assistantRecordStates(ids) } catch { throw AssistantServiceError.storage }
    }

    /// One member's saved conversations, newest first.
    func summaries(memberID: UUID) async throws -> [AssistantConversationSummary] {
        try requireUsable()
        return try await stored { try await self.store.savedConversationSummaries(memberID: memberID) }
    }

    func conversation(_ id: UUID) async throws -> AssistantConversation? {
        try requireUsable()
        return try await stored { try await self.store.savedConversation(id) }
    }

    func deleteConversation(_ id: UUID) async throws {
        try requireUsable()
        try await stored { try await self.store.deleteConversation(id) }
    }

    /// Deletes every saved conversation of every member, as asked for in Settings.
    func deleteAllConversations() async throws {
        try requireUsable()
        try await stored { try await self.store.deleteAllConversations() }
    }

    /// Stops every running turn, for turning the feature off. Saved conversations stay.
    func stopRunningTurns() {
        cancelRunningTurns()
    }

    /// The library is going away: stop and refuse further work. Nothing is written; the library
    /// itself is being deleted or replaced.
    func revoke() async {
        state.withLock { $0.revoked = true }
        cancelRunningTurns()
    }

    // MARK: - Private

    private func requireUsable() throws {
        if state.withLock({ $0.revoked }) { throw AssistantServiceError.libraryUnavailable }
    }

    /// A store call inside the library lifecycle, with its failures as service errors.
    private func stored<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        do {
            return try await lifecycle.withActiveOperation(body)
        } catch {
            throw state.withLock({ $0.revoked }) ? AssistantServiceError.libraryUnavailable : AssistantServiceError.storage
        }
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
