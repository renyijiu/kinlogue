import Foundation

package enum AssistantConversationError: Error, Equatable, Sendable {
    case invalidQuestion
    case questionTooLong
    case invalidAnswer
    case answerTooLarge
    case invalidSource
    case duplicateSourceLabel
    case tooManySources
    case invalidOrdinal
    case tooManyTurns
    case invalidProvider
    case invalidPromptVersion
}

package enum AssistantProviderKind: String, Codable, Hashable, Sendable {
    case codex
}

/// The CLI and model that received a conversation's content. It stays with the conversation so a
/// later reader knows where the content went.
package struct AssistantProviderDescriptor: Codable, Hashable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case cliVersion
        case model
    }

    package let kind: AssistantProviderKind
    package let cliVersion: String
    package let model: String

    package init(kind: AssistantProviderKind, cliVersion: String, model: String) throws {
        guard Self.isBounded(cliVersion), Self.isBounded(model) else {
            throw AssistantConversationError.invalidProvider
        }
        self.kind = kind
        self.cliVersion = cliVersion
        self.model = model
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                kind: container.decode(AssistantProviderKind.self, forKey: .kind),
                cliVersion: container.decode(String.self, forKey: .cliVersion),
                model: container.decode(String.self, forKey: .model)
            )
        } catch {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid provider"))
        }
    }

    /// Non-empty, short, and free of whitespace and control characters: these values are shown
    /// to the user and passed as command-line arguments.
    private static func isBounded(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= AssistantLimits.maxProviderFieldBytes
            && !value.unicodeScalars.contains {
                CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
            }
    }
}

/// The library's view of a cited record now, for comparison with what a turn sent.
package struct AssistantRecordState: Hashable, Sendable {
    package let revision: UInt64
    package let projectionDigest: Data

    package init(revision: UInt64, projectionDigest: Data) {
        self.revision = revision
        self.projectionDigest = projectionDigest
    }
}

package enum AssistantCitationStatus: Hashable, Sendable {
    case current
    case changed
    case deleted
}

/// One entry of a turn's send manifest: the record a label stood for, its revision, and a digest
/// of the text sent for it. A label means nothing outside its turn.
package struct AssistantTurnSource: Codable, Hashable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case label
        case recordID
        case recordRevision
        case projectionDigest
    }

    package let label: String
    package let recordID: UUID
    package let recordRevision: UInt64
    package let projectionDigest: Data

    package init(label: String, recordID: UUID, recordRevision: UInt64, projectionDigest: Data) throws {
        guard AssistantCitationParser.normalizedLabel(label[...]) == label, projectionDigest.count == 32 else {
            throw AssistantConversationError.invalidSource
        }
        self.label = label
        self.recordID = recordID
        self.recordRevision = recordRevision
        self.projectionDigest = projectionDigest
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                label: container.decode(String.self, forKey: .label),
                recordID: container.decode(UUID.self, forKey: .recordID),
                recordRevision: container.decode(UInt64.self, forKey: .recordRevision),
                projectionDigest: container.decode(Data.self, forKey: .projectionDigest)
            )
        } catch {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid turn source"))
        }
    }

    /// Whether the record still says what was sent. A new revision that leaves the sent text
    /// alone, such as an added note, still counts as current.
    package func status(current: AssistantRecordState?) -> AssistantCitationStatus {
        guard let current else { return .deleted }
        return current.revision == recordRevision || current.projectionDigest == projectionDigest ? .current : .changed
    }
}

/// A completed question and answer. Cancelled or failed turns are never made into one.
package struct AssistantTurn: Codable, Hashable, Identifiable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case id
        case ordinal
        case question
        case answer
        case completedAt
        case sources
    }

    package let id: UUID
    package let ordinal: Int
    package let question: String
    package let answer: String
    package let completedAt: Date
    /// The send manifest of this turn, in label order.
    package let sources: [AssistantTurnSource]

    package init(
        id: UUID = UUID(),
        ordinal: Int,
        question: String,
        answer: String,
        completedAt: Date,
        sources: [AssistantTurnSource]
    ) throws {
        guard ordinal >= 0 else { throw AssistantConversationError.invalidOrdinal }
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { throw AssistantConversationError.invalidQuestion }
        guard question.count <= AssistantLimits.maxQuestionCharacters else {
            throw AssistantConversationError.questionTooLong
        }
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AssistantConversationError.invalidAnswer
        }
        guard answer.utf8.count <= AssistantLimits.maxAnswerBytes else { throw AssistantConversationError.answerTooLarge }
        guard sources.count <= AssistantLimits.maxTurnSources else { throw AssistantConversationError.tooManySources }
        guard Set(sources.map(\.label)).count == sources.count else {
            throw AssistantConversationError.duplicateSourceLabel
        }
        self.id = id
        self.ordinal = ordinal
        self.question = question
        self.answer = answer
        self.completedAt = completedAt
        self.sources = sources
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(UUID.self, forKey: .id),
                ordinal: container.decode(Int.self, forKey: .ordinal),
                question: container.decode(String.self, forKey: .question),
                answer: container.decode(String.self, forKey: .answer),
                completedAt: container.decode(Date.self, forKey: .completedAt),
                sources: container.decode([AssistantTurnSource].self, forKey: .sources)
            )
        } catch {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid turn"))
        }
    }
}

/// One member's conversation with one CLI and model, saved in the library as it grows. Consent is
/// never part of it.
package struct AssistantConversation: Codable, Hashable, Identifiable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case id
        case memberID
        case createdAt
        case updatedAt
        case provider
        case promptVersion
        case turns
    }

    package let id: UUID
    package let memberID: UUID
    package let createdAt: Date
    package let updatedAt: Date
    package let provider: AssistantProviderDescriptor
    package let promptVersion: Int
    package let turns: [AssistantTurn]

    package init(
        id: UUID = UUID(),
        memberID: UUID,
        createdAt: Date,
        provider: AssistantProviderDescriptor,
        promptVersion: Int
    ) throws {
        try self.init(
            id: id, memberID: memberID, createdAt: createdAt, updatedAt: createdAt,
            provider: provider, promptVersion: promptVersion, turns: []
        )
    }

    /// A whole conversation, as read back from storage; the same checks as decoding.
    package init(
        id: UUID,
        memberID: UUID,
        createdAt: Date,
        updatedAt: Date,
        provider: AssistantProviderDescriptor,
        promptVersion: Int,
        turns: [AssistantTurn]
    ) throws {
        guard promptVersion > 0 else { throw AssistantConversationError.invalidPromptVersion }
        guard turns.count <= AssistantLimits.maxTurnsPerConversation else {
            throw AssistantConversationError.tooManyTurns
        }
        guard turns.enumerated().allSatisfy({ $0.offset == $0.element.ordinal }) else {
            throw AssistantConversationError.invalidOrdinal
        }
        self.id = id
        self.memberID = memberID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.provider = provider
        self.promptVersion = promptVersion
        self.turns = turns
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(UUID.self, forKey: .id),
                memberID: container.decode(UUID.self, forKey: .memberID),
                createdAt: container.decode(Date.self, forKey: .createdAt),
                updatedAt: container.decode(Date.self, forKey: .updatedAt),
                provider: container.decode(AssistantProviderDescriptor.self, forKey: .provider),
                promptVersion: container.decode(Int.self, forKey: .promptVersion),
                turns: container.decode([AssistantTurn].self, forKey: .turns)
            )
        } catch {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid conversation"))
        }
    }

    package func appending(_ turn: AssistantTurn) throws -> Self {
        guard turns.count < AssistantLimits.maxTurnsPerConversation else { throw AssistantConversationError.tooManyTurns }
        guard turn.ordinal == turns.count else { throw AssistantConversationError.invalidOrdinal }
        return try Self(
            id: id, memberID: memberID, createdAt: createdAt, updatedAt: max(updatedAt, turn.completedAt),
            provider: provider, promptVersion: promptVersion, turns: turns + [turn]
        )
    }

    /// The latest turns that fit the resend budget, oldest first, and how many earlier turns were
    /// left out. Each new question is sent with these; the CLI keeps no session of its own.
    package func resendWindow() -> (turns: [AssistantTurn], droppedCount: Int) {
        var kept: [AssistantTurn] = []
        var bytes = 0
        for turn in turns.reversed() {
            let size = turn.question.utf8.count + turn.answer.utf8.count
            guard bytes + size <= AssistantLimits.maxResentTranscriptBytes else { break }
            bytes += size
            kept.append(turn)
        }
        return (kept.reversed(), turns.count - kept.count)
    }
}

/// What the history list shows of a saved conversation without reading its turns.
package struct AssistantConversationSummary: Hashable, Identifiable, Sendable {
    /// How much of the first question the list shows.
    package static let firstQuestionCharacters = 120

    package let id: UUID
    package let memberID: UUID
    package let createdAt: Date
    package let updatedAt: Date
    package let provider: AssistantProviderDescriptor
    package let turnCount: Int
    /// The beginning of the first question; nil before the first turn.
    package let firstQuestion: String?

    package init(
        id: UUID, memberID: UUID, createdAt: Date, updatedAt: Date, provider: AssistantProviderDescriptor,
        turnCount: Int, firstQuestion: String?
    ) {
        self.id = id
        self.memberID = memberID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.provider = provider
        self.turnCount = turnCount
        self.firstQuestion = firstQuestion.map { String($0.prefix(Self.firstQuestionCharacters)) }
    }

    package init(_ conversation: AssistantConversation) {
        self.init(
            id: conversation.id, memberID: conversation.memberID, createdAt: conversation.createdAt,
            updatedAt: conversation.updatedAt, provider: conversation.provider, turnCount: conversation.turns.count,
            firstQuestion: conversation.turns.first?.question
        )
    }
}
