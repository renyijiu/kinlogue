import Foundation

/// Upper bounds for the member chat. They bound what one turn sends and what one conversation
/// keeps, so the same numbers become the storage limits once conversations are saved.
package enum AssistantLimits {
    /// Confirmed reports in one context pack.
    package static let maxPackRecords = 20
    /// UTF-8 bytes of all record bodies in one pack.
    package static let maxPackBytes = 60_000
    /// UTF-8 bytes of one record body; a longer body is cut and marked as cut.
    package static let maxRecordBytes = 12_000
    /// Sources one saved turn keeps. Schema v3 holds this many; v2 held 20.
    package static let maxTurnSources = 300
    package static let maxQuestionCharacters = 2_000
    package static let maxAnswerBytes = 32 * 1024
    package static let maxTurnsPerConversation = 20
    /// Earlier questions and answers sent again with a new question.
    package static let maxResentTranscriptBytes = 40_000
    package static let maxConversationsPerMember = 200
    /// UTF-8 bytes of the CLI version and of the model name.
    package static let maxProviderFieldBytes = 128
}
