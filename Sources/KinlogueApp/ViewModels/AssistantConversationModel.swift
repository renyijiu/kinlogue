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
    case invalidQuestion
    case storage
    case cli(AssistantFailure)
}

/// One member's conversation: the pack to send, the consent for it, and the turns so far. A
/// generation fence drops results for a member, pack or library that is no longer current.
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
    /// The question of the turn that is running, shown until its answer arrives.
    @Published private(set) var pendingQuestion: String?
    @Published private(set) var sendingStartedAt: Date?

    private let service: LiveAssistantService
    private let currentSettings: @MainActor () -> AssistantSettings
    private var consent: AssistantConsent?
    private var checkedRecordIDs: Set<UUID> = []
    private var generation: UInt64 = 0
    private var locked = false
    private var sending: Task<AssistantConversation, any Error>?
    private var refreshAfterSending = false

    init(service: LiveAssistantService, settings: @escaping @MainActor () -> AssistantSettings) {
        self.service = service
        currentSettings = settings
    }

    var hasConsent: Bool { consent != nil }

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
        let latest = await service.conversations(memberID: memberID).first
        guard generation == self.generation else { return }
        conversation = latest
        await refreshRecordStates(generation: generation)
        guard generation == self.generation else { return }
        phase = .needsConsent
    }

    /// The user confirmed the sheet: send this pack to this CLI and model.
    func confirm() {
        guard !locked, phase == .needsConsent, let pack, let cliStatus else { return }
        do {
            let consent = try service.consent(pack: pack, status: cliStatus)
            self.consent = consent
            if let conversation, conversation.provider != consent.receiver { self.conversation = nil }
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
        guard !locked, phase != .sending else { return }
        guard phase == .ready, let consent, let pack else {
            issue = .consentRequired
            return
        }
        let generation = self.generation
        let settings = currentSettings()
        let conversationID = conversation?.id
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
        await refreshRecordStates(generation: generation)
    }

    /// Settings were saved. Turning the feature off stops and forgets everything.
    func settingsChanged(to settings: AssistantSettings) async {
        guard !locked else { return }
        if !settings.isEnabled {
            _ = reset(memberID: memberID)
            await service.discardAll()
            show(.disabled, phase: .unavailable)
        } else if let memberID {
            await open(memberID: memberID)
        }
    }

    func close() {
        guard !locked else { return }
        _ = reset(memberID: nil)
        phase = .closed
    }

    /// The library is being deleted or replaced: stop for good. The service forgets the
    /// conversations through its lifecycle registration.
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
        return generation
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
