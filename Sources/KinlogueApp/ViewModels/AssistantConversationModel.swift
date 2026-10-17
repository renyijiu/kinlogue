import Foundation
import KinlogueCore
import KinloguePlatform

/// Why the conversation cannot go on as asked. Kept as a value; the view chooses the words.
enum AssistantIssue: Equatable, Sendable {
    case disabled
    case invalidSettings
    case noConfirmedRecords
    case memberArchived
    /// The chosen reports cannot all be sent.
    case selection
    case libraryUnavailable
    /// The pack, the CLI or the model changed; the user has to confirm again.
    case consentRequired
    case conversationFull
    case tooManyConversations
    case invalidQuestion
    case storage
    case cli(AssistantFailure)
}

/// One member's conversation: the pack to send, the consent for it, the turns so far, and the
/// member's saved conversations. A generation fence drops results for a member, pack or library that
/// is no longer current.
@MainActor
final class AssistantConversationModel: ObservableObject {
    enum Phase: Equatable, Sendable {
        case closed
        case loading
        case needsConsent
        case ready
        case sending
        case unavailable
    }

    @Published private(set) var phase: Phase = .closed
    @Published private(set) var memberID: UUID?
    @Published private(set) var pack: AssistantContextPack?
    @Published private(set) var damagedRecordIDs: [UUID] = []
    @Published private(set) var cliStatus: AssistantCLIStatus?
    @Published private(set) var conversation: AssistantConversation?
    @Published private(set) var issue: AssistantIssue?
    @Published private(set) var includeOrganization = false
    @Published private(set) var recordStates: [UUID: AssistantRecordState] = [:]
    /// The member's saved conversations, newest first.
    @Published private(set) var history: [AssistantConversationSummary] = []
    /// The question of the turn that is running, shown until its answer arrives.
    @Published private(set) var pendingQuestion: String?
    @Published private(set) var sendingStartedAt: Date?
    /// Changed settings are being checked; nothing can be confirmed or sent until the result is in.
    @Published private(set) var isCheckingCLI = false

    private let service: LiveAssistantService
    private let currentSettings: @MainActor () -> AssistantSettings
    private var consent: AssistantConsent?
    private var checkedRecordIDs: Set<UUID> = []
    private var generation: UInt64 = 0
    private var locked = false
    private var sending: Task<AssistantConversation, any Error>?
    private var refreshAfterSending = false
    private var cliCheck: UInt64 = 0

    init(service: LiveAssistantService, settings: @escaping @MainActor () -> AssistantSettings) {
        self.service = service
        currentSettings = settings
    }

    var hasConsent: Bool { consent != nil }

    /// False when the conversation on screen came from another CLI or model than the one consented
    /// to; the next question then starts a new conversation.
    var continuesShownConversation: Bool {
        guard let conversation, let consent else { return true }
        return conversation.provider == consent.receiver
    }

    /// Before the library has been asked, a cited record counts as unchanged.
    func citationStatus(of source: AssistantTurnSource) -> AssistantCitationStatus {
        guard checkedRecordIDs.contains(source.recordID) else { return .current }
        return source.status(current: recordStates[source.recordID])
    }

    func open(memberID: UUID) async {
        guard !locked else { return }
        let generation = reset(memberID: memberID)
        let settings = currentSettings()
        guard settings.isEnabled else {
            show(.disabled, phase: .unavailable)
            return
        }
        phase = .loading
        guard await loadPack(generation: generation) else { return }
        do {
            let status = try await service.status(settings: settings)
            guard generation == self.generation else { return }
            cliStatus = status
            if let failure = status.failure {
                show(.cli(failure), phase: .unavailable)
                return
            }
        } catch {
            guard generation == self.generation else { return }
            show(Self.issue(for: error), phase: .unavailable)
            return
        }
        let summaries = (try? await service.summaries(memberID: memberID)) ?? []
        guard generation == self.generation else { return }
        history = summaries
        if let latest = summaries.first {
            let loaded = try? await service.conversation(latest.id)
            guard generation == self.generation else { return }
            conversation = loaded
        }
        await refreshRecordStates(generation: generation)
        guard generation == self.generation else { return }
        phase = .needsConsent
    }

    /// The user confirmed the sheet: send this pack to this CLI and model.
    func confirm() {
        guard !locked, phase == .needsConsent, !isCheckingCLI, let pack, let cliStatus else { return }
        do {
            consent = try service.consent(pack: pack, status: cliStatus)
            issue = nil
            phase = .ready
        } catch {
            show(Self.issue(for: error), phase: .unavailable)
        }
    }

    func setIncludeOrganization(_ include: Bool) async {
        guard !locked, memberID != nil, include != includeOrganization, phase != .sending, phase != .loading else { return }
        includeOrganization = include
        consent = nil
        let generation = self.generation
        guard await loadPack(generation: generation) else { return }
        phase = cliStatus?.failure == nil && cliStatus != nil ? .needsConsent : .unavailable
    }

    func send(_ question: String) async {
        guard !locked, phase != .sending, !isCheckingCLI else { return }
        guard phase == .ready, let consent, let pack else {
            issue = .consentRequired
            return
        }
        let generation = self.generation
        let settings = currentSettings()
        let conversationID = continuesShownConversation ? conversation?.id : nil
        phase = .sending
        issue = nil
        pendingQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        sendingStartedAt = Date()
        let task = Task { [service] in
            try await service.send(question, conversationID: conversationID, pack: pack, consent: consent, settings: settings)
        }
        sending = task
        do {
            let updated = try await task.value
            guard generation == self.generation else { return }
            endSending()
            conversation = updated
            for entry in pack.entries {
                recordStates[entry.recordID] = AssistantRecordState(revision: entry.recordRevision, projectionDigest: entry.projectionDigest)
                checkedRecordIDs.insert(entry.recordID)
            }
            phase = .ready
            await refreshHistory(generation: generation)
        } catch {
            guard generation == self.generation else { return }
            endSending()
            show(Self.issue(for: error), phase: self.consent == nil ? .needsConsent : .ready)
        }
        if refreshAfterSending {
            refreshAfterSending = false
            await libraryChanged()
        }
    }

    func stop() {
        sending?.cancel()
    }

    /// Checks the CLI and reloads the pack again, for example after the user fixed the login.
    func recheck() async {
        guard let memberID else { return }
        await open(memberID: memberID)
    }

    /// Shows a saved conversation of this member. Its consent is the one already given, if any.
    func selectConversation(_ id: UUID) async {
        guard !locked, phase != .sending, phase != .loading, memberID != nil, conversation?.id != id else { return }
        let generation = self.generation
        do {
            let loaded = try await service.conversation(id)
            guard generation == self.generation else { return }
            guard let loaded, loaded.memberID == memberID else {
                await refreshHistory(generation: generation)
                return
            }
            conversation = loaded
            issue = nil
            recordStates = [:]
            checkedRecordIDs = []
            await refreshRecordStates(generation: generation)
        } catch {
            guard generation == self.generation else { return }
            issue = Self.issue(for: error)
        }
    }

    func deleteConversation(_ id: UUID) async {
        guard !locked, phase != .sending, memberID != nil else { return }
        let generation = self.generation
        do {
            try await service.deleteConversation(id)
            guard generation == self.generation else { return }
            if conversation?.id == id {
                conversation = nil
                recordStates = [:]
                checkedRecordIDs = []
            }
            await refreshHistory(generation: generation)
        } catch {
            guard generation == self.generation else { return }
            issue = Self.issue(for: error)
        }
    }

    func startNewConversation() {
        guard !locked, phase != .sending else { return }
        conversation = nil
        recordStates = [:]
        checkedRecordIDs = []
        issue = nil
    }

    /// A commit landed: rebuild the pack, ask again if what would be sent changed, and recheck the
    /// records earlier answers cite.
    func libraryChanged() async {
        guard !locked, memberID != nil, pack != nil else { return }
        guard phase != .sending else {
            refreshAfterSending = true
            return
        }
        let generation = self.generation
        let previous = pack
        guard await loadPack(generation: generation) else { return }
        if let consent, let pack, let cliStatus, pack != previous,
           (try? service.consent(pack: pack, status: cliStatus))?.fingerprint != consent.fingerprint {
            self.consent = nil
            show(.consentRequired, phase: .needsConsent)
        }
        await refreshHistory(generation: generation)
        await refreshRecordStates(generation: generation)
    }

    /// Settings were saved. Turning the feature off stops and forgets everything; while the
    /// conversation is on screen, other changes only check the receiver again.
    func settingsChanged(to settings: AssistantSettings) async {
        guard !locked else { return }
        if !settings.isEnabled {
            _ = reset(memberID: memberID)
            service.stopRunningTurns()
            show(.disabled, phase: .unavailable)
        } else if pack != nil, phase == .ready || phase == .needsConsent {
            await recheckReceiver(settings)
        } else if let memberID {
            await open(memberID: memberID)
        }
    }

    func close() {
        guard !locked else { return }
        _ = reset(memberID: nil)
        phase = .closed
    }

    /// The library is being deleted or replaced: stop for good. The service stops its turn through
    /// its lifecycle registration.
    func beginDestructiveVaultLifecycle() {
        _ = reset(memberID: nil)
        phase = .closed
        locked = true
    }

    // MARK: - Private

    /// Starts a new generation for `memberID`, cancelling whatever the previous one was doing.
    private func reset(memberID: UUID?) -> UInt64 {
        generation &+= 1
        sending?.cancel()
        endSending()
        refreshAfterSending = false
        cliCheck &+= 1
        isCheckingCLI = false
        self.memberID = memberID
        pack = nil
        damagedRecordIDs = []
        cliStatus = nil
        conversation = nil
        consent = nil
        issue = nil
        recordStates = [:]
        checkedRecordIDs = []
        includeOrganization = false
        history = []
        return generation
    }

    /// Checks the CLI that `settings` name and keeps the pack, the history and the conversation on
    /// screen. The consent holds only for the same receiver and pack.
    private func recheckReceiver(_ settings: AssistantSettings) async {
        let generation = self.generation
        cliCheck &+= 1
        let check = cliCheck
        isCheckingCLI = true
        defer { if check == cliCheck { isCheckingCLI = false } }
        do {
            let status = try await service.status(settings: settings)
            guard generation == self.generation, check == cliCheck else { return }
            cliStatus = status
            if let failure = status.failure {
                consent = nil
                show(.cli(failure), phase: .unavailable)
                return
            }
            if let consent, let pack, (try? service.consent(pack: pack, status: status)) == consent { return }
            consent = nil
            show(.consentRequired, phase: .needsConsent)
        } catch {
            guard generation == self.generation, check == cliCheck else { return }
            consent = nil
            show(Self.issue(for: error), phase: .unavailable)
        }
    }

    private func endSending() {
        sending = nil
        pendingQuestion = nil
        sendingStartedAt = nil
    }

    private func loadPack(generation: UInt64) async -> Bool {
        guard let memberID else { return false }
        do {
            let load = try await service.pack(memberID: memberID, includeOrganization: includeOrganization)
            guard generation == self.generation else { return false }
            pack = load.pack
            damagedRecordIDs = load.damagedRecordIDs
            return true
        } catch {
            guard generation == self.generation else { return false }
            consent = nil
            show(Self.issue(for: error), phase: .unavailable)
            return false
        }
    }

    /// Rereads the member's saved conversations; one on screen that is no longer saved goes away.
    private func refreshHistory(generation: UInt64) async {
        guard let memberID, let summaries = try? await service.summaries(memberID: memberID),
              generation == self.generation else { return }
        history = summaries
        if let shown = conversation, !summaries.contains(where: { $0.id == shown.id }) {
            conversation = nil
            recordStates = [:]
            checkedRecordIDs = []
        }
    }

    private func refreshRecordStates(generation: UInt64) async {
        guard let conversation else { return }
        let ids = Set(conversation.turns.flatMap { $0.sources.map(\.recordID) })
        guard !ids.isEmpty, let states = try? await service.recordStates(Array(ids)), generation == self.generation else { return }
        recordStates = states
        checkedRecordIDs = ids
    }

    private func show(_ issue: AssistantIssue, phase: Phase) {
        self.issue = issue
        self.phase = phase
    }

    private static func issue(for error: any Error) -> AssistantIssue {
        switch error as? AssistantServiceError {
        case .disabled: .disabled
        case .invalidSettings: .invalidSettings
        case .consentRequired: .consentRequired
        case .conversationFull: .conversationFull
        case .tooManyConversations: .tooManyConversations
        case .invalidQuestion: .invalidQuestion
        case .libraryUnavailable: .libraryUnavailable
        case .storage, nil: .storage
        case .pack(.noConfirmedRecords): .noConfirmedRecords
        case .pack(.memberArchived): .memberArchived
        case .pack(.invalidDigest): .storage
        case .pack: .selection
        case let .provider(failure): .cli(failure)
        }
    }
}
