import Foundation

/// Upper bounds for the member chat. They bound what one turn sends and what one conversation
/// keeps, so the same numbers become the storage limits once conversations are saved.
package enum AssistantLimits {
    /// Confirmed reports in the index of one context pack.
    package static let maxPackRecords = 300
    /// UTF-8 bytes of the whole rendered pack.
    package static let maxPackBytes = 100_000
    /// UTF-8 bytes of the index, the conclusions and the result rows; what they leave unused goes
    /// to the full texts.
    package static let maxIndexBytes = 16_000
    package static let maxConclusionsBytes = 24_000
    package static let maxResultRowsBytes = 30_000
    /// UTF-8 bytes of one report's conclusion and flagged items; longer text is cut and marked.
    package static let maxConclusionBytesPerRecord = 600
    /// Unicode scalars of a title in the index and of one cell of a result row.
    package static let maxIndexTitleScalars = 80
    package static let maxResultCellScalars = 160
    /// UTF-8 bytes of one report's full text; a longer text is cut and marked as cut.
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
