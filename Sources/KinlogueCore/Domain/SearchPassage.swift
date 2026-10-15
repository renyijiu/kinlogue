import Foundation

/// One sentence of a confirmed narrative field in which a search term is found, such as a line of
/// an ultrasound's findings. The sentence is the report's own text; nothing is parsed or compared.
public struct SearchPassage: Hashable, Sendable {
    public enum Field: Hashable, Sendable {
        case reportedResults
        case conclusion
    }

    public let field: Field
    /// The sentence, cut around the match when it is longer than an excerpt.
    public let excerpt: SearchExcerpt

    public init(field: Field, excerpt: SearchExcerpt) {
        self.field = field; self.excerpt = excerpt
    }

    /// Sentences end at these marks. A full stop is left out because it is also a decimal point,
    /// and a line break because recognition breaks lines wherever the page wraps.
    private static let sentenceEnds: Set<Unicode.Scalar> = ["。", "；", ";", "！", "!", "？", "?"]

    /// The sentences of `field` in which `term` is found, in order: the first `limit` as passages
    /// and the number of all of them. Each sentence counts once however often the term recurs in it.
    public static func sentences(matching term: String, in text: String, field: Field, limit: Int,
                                 locale: Locale = .current) -> (passages: [Self], count: Int) {
        guard RecordQuery.canLocate(term) else { return ([], 0) }
        var passages: [Self] = [], count = 0
        // Sentence marks are single scalars, so the scans go scalar by scalar; each found match is
        // cut from the text in place, without being searched for again.
        let scalars = text.unicodeScalars
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let found = text.range(of: term, options: .caseInsensitive,
                                     range: searchStart..<text.endIndex, locale: locale) {
            let start = scalars[..<found.lowerBound].lastIndex(where: sentenceEnds.contains)
                .map { scalars.index(after: $0) } ?? scalars.startIndex
            // A term that ends with a sentence mark ends its sentence there.
            let last = found.isEmpty ? found.upperBound : scalars.index(before: found.upperBound)
            let end = scalars[last...].firstIndex(where: sentenceEnds.contains).map { scalars.index(after: $0) }
                ?? scalars.endIndex
            if passages.count < limit {
                if let excerpt = SearchExcerpt(term: term, in: text[start..<end], match: found, locale: locale) {
                    passages.append(Self(field: field, excerpt: excerpt))
                    count += 1
                }
            } else {
                count += 1
            }
            searchStart = end
        }
        return (passages, count)
    }

    /// The sentence cut to `maximumScalars` Unicode scalars, for a list row.
    package func bounded(toScalars maximumScalars: Int) -> Self {
        Self(field: field, excerpt: excerpt.bounded(toScalars: maximumScalars))
    }
}
