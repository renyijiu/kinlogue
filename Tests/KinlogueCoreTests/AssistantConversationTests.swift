import Foundation
import Testing
@testable import KinlogueCore

@Test
func assistantCitationLabelsAreReadFromSquareAndCornerBracketsOnly() {
    let answer = """
    Glucose was 5.1 [R1][R2]、5.3【R3】, see also [R2, R4] and [R5；R6].
    Not citations: [1] [R] [Rx] [see R7] (R8) R9 [R01x].
    """

    #expect(AssistantCitationParser.labels(in: answer) == ["R1", "R2", "R3", "R4", "R5", "R6"])
    #expect(AssistantCitationParser.labels(in: "No citations here.").isEmpty)
    #expect(AssistantCitationParser.labels(in: "[R007]") == ["R7"])
}

@Test
func assistantCitationsResolveAgainstTheTurnManifestAndFlagUnknownLabels() throws {
    let manifest = try (1...3).map { try turnSource(label: "R\($0)") }

    let citations = AssistantCitationParser.resolve(answer: "A [R2] B [R9] C [R1][R2]", manifest: manifest)

    #expect(citations.map(\.label) == ["R2", "R9", "R1"])
    #expect(citations.map(\.source) == [manifest[1], nil, manifest[0]])
}

@Test
func assistantCitationStatusComparesRevisionAndProjectionDigest() throws {
    let source = try turnSource(label: "R1", revision: 3, digestByte: 1)

    #expect(source.status(current: AssistantRecordState(revision: 3, projectionDigest: digest(1))) == .current)
    #expect(source.status(current: AssistantRecordState(revision: 4, projectionDigest: digest(1))) == .current)
    #expect(source.status(current: AssistantRecordState(revision: 4, projectionDigest: digest(2))) == .changed)
    #expect(source.status(current: nil) == .deleted)
}

@Test
func assistantTurnValidatesQuestionAnswerAndSources() throws {
    let source = try turnSource(label: "R1")
    func turn(question: String = "Question", answer: String = "Answer", sources: [AssistantTurnSource]? = nil) throws {
        _ = try AssistantTurn(ordinal: 0, question: question, answer: answer, completedAt: Date(), sources: sources ?? [source])
    }

    try turn()
    try turn(question: String(repeating: "问", count: AssistantLimits.maxQuestionCharacters))
    #expect(throws: AssistantConversationError.invalidQuestion) { try turn(question: " \n ") }
    #expect(throws: AssistantConversationError.questionTooLong) {
        try turn(question: String(repeating: "问", count: AssistantLimits.maxQuestionCharacters + 1))
    }
    #expect(throws: AssistantConversationError.invalidAnswer) { try turn(answer: "") }
    #expect(throws: AssistantConversationError.answerTooLarge) {
        try turn(answer: String(repeating: "a", count: AssistantLimits.maxAnswerBytes + 1))
    }
    #expect(throws: AssistantConversationError.duplicateSourceLabel) { try turn(sources: [source, source]) }
    #expect(throws: AssistantConversationError.tooManySources) {
        try turn(sources: try (1...(AssistantLimits.maxPackRecords + 1)).map { try turnSource(label: "R\($0)") })
    }
    #expect(throws: AssistantConversationError.invalidSource) { _ = try AssistantTurnSource(
        label: "R1", recordID: UUID(), recordRevision: 0, projectionDigest: Data([1])
    ) }
    #expect(throws: AssistantConversationError.invalidSource) { _ = try AssistantTurnSource(
        label: "Q1", recordID: UUID(), recordRevision: 0, projectionDigest: digest(1)
    ) }
    #expect(throws: AssistantConversationError.invalidOrdinal) {
        _ = try AssistantTurn(ordinal: -1, question: "Q", answer: "A", completedAt: Date(), sources: [])
    }
}

@Test
func assistantConversationAppendsContiguousTurnsUpToTheLimit() throws {
    let created = Date(timeIntervalSince1970: 1_000)
    var conversation = try AssistantConversation(
        memberID: UUID(), createdAt: created, provider: syntheticProvider(), promptVersion: AssistantPrompt.version
    )
    #expect(conversation.updatedAt == created)

    for ordinal in 0..<AssistantLimits.maxTurnsPerConversation {
        let completed = created.addingTimeInterval(Double(ordinal + 1))
        conversation = try conversation.appending(try AssistantTurn(
            ordinal: ordinal, question: "Q\(ordinal)", answer: "A\(ordinal)", completedAt: completed, sources: []
        ))
        #expect(conversation.updatedAt == completed)
    }
    #expect(conversation.turns.count == AssistantLimits.maxTurnsPerConversation)

    #expect(throws: AssistantConversationError.tooManyTurns) {
        try conversation.appending(try AssistantTurn(
            ordinal: AssistantLimits.maxTurnsPerConversation, question: "Q", answer: "A", completedAt: Date(), sources: []
        ))
    }
    let fresh = try AssistantConversation(
        memberID: UUID(), createdAt: created, provider: syntheticProvider(), promptVersion: AssistantPrompt.version
    )
    #expect(throws: AssistantConversationError.invalidOrdinal) {
        try fresh.appending(try AssistantTurn(ordinal: 1, question: "Q", answer: "A", completedAt: Date(), sources: []))
    }
}

@Test
func assistantConversationRoundTripsThroughCodableAndRejectsGaps() throws {
    var conversation = try AssistantConversation(
        memberID: UUID(), createdAt: Date(timeIntervalSince1970: 1_000), provider: syntheticProvider(),
        promptVersion: AssistantPrompt.version
    )
    conversation = try conversation.appending(try AssistantTurn(
        ordinal: 0, question: "空腹血糖是多少？", answer: "5.1 mmol/L [R1]",
        completedAt: Date(timeIntervalSince1970: 1_010), sources: [try turnSource(label: "R1", revision: 2, digestByte: 7)]
    ))

    let encoded = try JSONEncoder().encode(conversation)
    #expect(try JSONDecoder().decode(AssistantConversation.self, from: encoded) == conversation)

    var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    var turns = try #require(object["turns"] as? [[String: Any]])
    turns[0]["ordinal"] = 1
    object["turns"] = turns
    let gapped = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(AssistantConversation.self, from: gapped) }
}

@Test
func assistantProviderDescriptorBoundsItsFields() throws {
    _ = try AssistantProviderDescriptor(kind: .codex, cliVersion: "0.162.0", model: "gpt-synthetic")
    #expect(throws: AssistantConversationError.invalidProvider) {
        try AssistantProviderDescriptor(kind: .codex, cliVersion: "", model: "gpt-synthetic")
    }
    #expect(throws: AssistantConversationError.invalidProvider) {
        try AssistantProviderDescriptor(kind: .codex, cliVersion: "0.162.0", model: String(repeating: "m", count: 129))
    }
    #expect(throws: AssistantConversationError.invalidProvider) {
        try AssistantProviderDescriptor(kind: .codex, cliVersion: "0.162.0", model: "bad\nmodel")
    }
}

@Test
func assistantResendWindowKeepsTheNewestTurnsWithinTheByteBudget() throws {
    var conversation = try AssistantConversation(
        memberID: UUID(), createdAt: Date(), provider: syntheticProvider(), promptVersion: AssistantPrompt.version
    )
    let answer = String(repeating: "答", count: 4_000) // 12,000 UTF-8 bytes
    for ordinal in 0..<5 {
        conversation = try conversation.appending(try AssistantTurn(
            ordinal: ordinal, question: "Q\(ordinal)", answer: answer, completedAt: Date(), sources: []
        ))
    }

    let window = conversation.resendWindow()

    #expect(window.turns.map(\.ordinal) == [2, 3, 4])
    #expect(window.droppedCount == 2)
    #expect(window.turns.reduce(0) { $0 + $1.question.utf8.count + $1.answer.utf8.count } <= AssistantLimits.maxResentTranscriptBytes)

    let empty = try AssistantConversation(
        memberID: UUID(), createdAt: Date(), provider: syntheticProvider(), promptVersion: AssistantPrompt.version
    )
    #expect(empty.resendWindow().turns.isEmpty)
    #expect(empty.resendWindow().droppedCount == 0)
}

// MARK: - Fixtures

private func digest(_ byte: UInt8) -> Data { Data(repeating: byte, count: 32) }

private func turnSource(label: String, revision: UInt64 = 0, digestByte: UInt8 = 1) throws -> AssistantTurnSource {
    try AssistantTurnSource(label: label, recordID: UUID(), recordRevision: revision, projectionDigest: digest(digestByte))
}

private func syntheticProvider() throws -> AssistantProviderDescriptor {
    try AssistantProviderDescriptor(kind: .codex, cliVersion: "0.162.0", model: "gpt-synthetic")
}
