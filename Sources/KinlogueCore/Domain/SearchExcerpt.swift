import Foundation

/// A short stretch of one confirmed field around the first place a search term is found, for a
/// result row whose visible fields do not show why it matched. Runs of whitespace, tabs and line
/// breaks read as one space; the characters themselves are the transcription's own.
public struct SearchExcerpt: Hashable, Sendable {
    public static let maximumCharacters = 120
    /// How much text before the match the excerpt keeps, so the match does not open the line.
    public static let leadingCharacters = 30

    public let text: String
    public let isTruncatedAtStart: Bool
    public let isTruncatedAtEnd: Bool

    /// Nil when the term is not found in `field` by the localized, case-insensitive search.
    public init?(term: String, in field: String, locale: Locale = .current) {
        // A term with NUL takes a guarded path in the match predicate; it gets no excerpt.
        guard !term.isEmpty, !term.unicodeScalars.contains(where: { $0.value == 0 }),
              let raw = field.range(of: term, options: .caseInsensitive, locale: locale) else { return nil }
        // Whitespace is folded only near the match, so a long field costs one search. Each folded
        // run was at least one character, so this window holds the whole excerpt.
        let windowStart = field.index(raw.lowerBound, offsetBy: -Self.leadingCharacters, limitedBy: field.startIndex)
            ?? field.startIndex
        let windowEnd = field.index(raw.upperBound, offsetBy: Self.maximumCharacters, limitedBy: field.endIndex)
            ?? field.endIndex
        let flat = field[windowStart..<windowEnd].split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard let match = flat.range(of: term, options: .caseInsensitive, locale: locale) else { return nil }
        let start = flat.index(match.lowerBound, offsetBy: -Self.leadingCharacters, limitedBy: flat.startIndex)
            ?? flat.startIndex
        let budgetEnd = flat.index(start, offsetBy: Self.maximumCharacters, limitedBy: flat.endIndex) ?? flat.endIndex
        let end = max(budgetEnd, match.upperBound)
        text = String(flat[start..<end])
        isTruncatedAtStart = start > flat.startIndex || field[..<windowStart].contains { !$0.isWhitespace }
        isTruncatedAtEnd = end < flat.endIndex || field[windowEnd...].contains { !$0.isWhitespace }
    }

    private init(text: String, isTruncatedAtStart: Bool, isTruncatedAtEnd: Bool) {
        self.text = text; self.isTruncatedAtStart = isTruncatedAtStart; self.isTruncatedAtEnd = isTruncatedAtEnd
    }

    /// The excerpt with an ellipsis wherever the field goes on.
    public var displayText: String {
        (isTruncatedAtStart ? "…" : "") + text + (isTruncatedAtEnd ? "…" : "")
    }

    /// The text cut to `maximumScalars` Unicode scalars, for a list row.
    package func bounded(toScalars maximumScalars: Int) -> Self {
        guard text.unicodeScalars.count > maximumScalars else { return self }
        return Self(text: String(String.UnicodeScalarView(text.unicodeScalars.prefix(maximumScalars))),
                    isTruncatedAtStart: isTruncatedAtStart, isTruncatedAtEnd: true)
    }
}
