import Foundation

/// A record label cited by an answer. A label resolves only through the manifest of the turn that
/// produced the answer.
package struct AssistantCitation: Hashable, Sendable {
    package let label: String
    /// Nil when the answer cites a label that was not sent in this turn.
    package let source: AssistantTurnSource?
}

/// Reads `[R3]`, `[R1, R2]` and `【R4】` from an answer. A bracket counts only when everything in it
/// is a label, so `[1]` or `[see R7]` is ordinary text.
package enum AssistantCitationParser {
    // Answers are bounded by `AssistantLimits.maxAnswerBytes`, so one pass over them is cheap.
    private static let bracket = try! NSRegularExpression(pattern: #"\[([^\[\]]{1,64})\]|【([^【】]{1,64})】"#)
    private static let separators = CharacterSet(charactersIn: ",，、;；").union(.whitespacesAndNewlines)

    /// Unique labels in order of first appearance, normalized to `R` followed by the number.
    package static func labels(in answer: String) -> [String] {
        let text = answer as NSString
        var seen = Set<String>()
        var labels: [String] = []
        for match in bracket.matches(in: answer, range: NSRange(location: 0, length: text.length)) {
            let inner = [1, 2].map { match.range(at: $0) }.first { $0.location != NSNotFound }.map(text.substring(with:)) ?? ""
            let tokens = inner.components(separatedBy: separators).filter { !$0.isEmpty }
            let normalized = tokens.compactMap { normalizedLabel($0[...]) }
            guard !tokens.isEmpty, normalized.count == tokens.count else { continue }
            for label in normalized where seen.insert(label).inserted {
                labels.append(label)
            }
        }
        return labels
    }

    package static func resolve(answer: String, manifest: [AssistantTurnSource]) -> [AssistantCitation] {
        let byLabel = Dictionary(manifest.map { ($0.label, $0) }, uniquingKeysWith: { first, _ in first })
        return labels(in: answer).map { AssistantCitation(label: $0, source: byLabel[$0]) }
    }

    /// `R` and one to four ASCII digits naming a positive number; leading zeros are dropped.
    package static func normalizedLabel(_ token: Substring) -> String? {
        guard token.first == "R" else { return nil }
        let digits = token.dropFirst()
        guard (1...4).contains(digits.count), digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let number = Int(digits), number > 0 else { return nil }
        return "R\(number)"
    }
}
