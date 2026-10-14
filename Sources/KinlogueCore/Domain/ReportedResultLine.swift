import Foundation

/// One line of a confirmed results transcription whose cells are separated by tabs, the form in
/// which the table extraction writes a row's item, result and reference value.
///
/// The cells stay verbatim. Nothing here reads a number, unit or range out of them, compares them
/// with another report, or decides whether a value is normal; a printed marker such as "↑" is part
/// of the cell it was printed in.
public struct ReportedResultLine: Hashable, Sendable {
    public let cells: [String]

    public init?(_ line: some StringProtocol) {
        let cells = line.split(separator: "\t", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard cells.count >= 2 else { return nil }
        self.cells = cells
    }

    private init(cells: [String]) { self.cells = cells }

    /// The lines in which `term` is found by the localized, case-insensitive search that decides
    /// whether a report matches, applied to the line as stored, tabs included.
    public static func lines(matching term: String, in transcription: String, locale: Locale = .current) -> [Self] {
        guard !term.isEmpty, !term.contains(where: \.isNewline),
              transcription.utf8.contains(UInt8(ascii: "\t")) else { return [] }
        // A term with NUL needs the guarded predicate, line by line.
        guard RecordQuery.canLocate(term) else {
            return transcription.split(whereSeparator: \.isNewline).compactMap { line in
                RecordQuery.localizedContains(term, in: String(line), locale: locale) ? Self(line) : nil
            }
        }
        // One search per matching line: each finds the next match, which names its line, and the
        // next search starts after that line's break, so every pass moves forward.
        var lines: [Self] = []
        var searchStart = transcription.startIndex
        while searchStart < transcription.endIndex,
              let found = transcription.range(of: term, options: .caseInsensitive,
                                              range: searchStart..<transcription.endIndex, locale: locale) {
            let lineStart = transcription[..<found.lowerBound].lastIndex(where: \.isNewline)
                .map { transcription.index(after: $0) } ?? transcription.startIndex
            let lineEnd = transcription[found.lowerBound...].firstIndex(where: \.isNewline) ?? transcription.endIndex
            if let line = Self(transcription[lineStart..<lineEnd]) { lines.append(line) }
            guard lineEnd < transcription.endIndex else { break }
            searchStart = transcription.index(after: lineEnd)
        }
        return lines
    }

    /// Each cell cut to `maximumScalars` Unicode scalars, for a list row.
    package func bounded(toScalars maximumScalars: Int) -> Self {
        Self(cells: cells.map { String(String.UnicodeScalarView($0.unicodeScalars.prefix(maximumScalars))) })
    }
}
