import Foundation

/// A likely recognition misreading in one cell of a table line of a results transcription, with
/// the reading the form almost certainly printed. Only misreadings seen in synthetic recognition
/// checks are listed. A suggestion changes nothing until the user takes it, and taking it is a
/// user correction: the recognized text stays the field's original transcription.
public struct RecognitionSuggestion: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// "↑" read as "个" or "T" right after a result value.
        case raisedMarker
        /// "U/L" read as "UIL".
        case unit
        /// "白" read as "自" in 白细胞, 白蛋白 or 白球比.
        case itemName
    }

    public let kind: Kind
    /// The line's index in the transcription, counting lines split at "\n".
    public let lineIndex: Int
    /// The line as found, and the line with this one fix.
    public let line: String
    public let fixedLine: String
    /// The line's first cell, which names the row.
    public let item: String
    /// The cell as found, and the cell with this one fix.
    public let before: String
    public let after: String

    private struct Rule {
        enum Cells { case item, result, afterItem }
        let kind: Kind
        /// Which cells the rule reads: the item, the result after it, or every cell after the item.
        let cells: Cells
        let pattern: String
        let template: String

        func reads(cell index: Int) -> Bool {
            switch cells {
            case .item: index == 0
            case .result: index == 1
            case .afterItem: index > 0
            }
        }
    }

    private static let rules: [Rule] = [
        // A result value followed by the misread marker, then a space or the end: "6.85个",
        // "6.85 T mmol/L". "T/L" and "个/HP" are units and do not match, and a reference such as
        // "0-1个" is not a result.
        Rule(kind: .raisedMarker, cells: .result,
             pattern: #"(\d)(\s*)(?:个|T)(?=\s|$)"#, template: "$1$2↑"),
        Rule(kind: .unit, cells: .afterItem,
             pattern: #"(?<![A-Za-z])UIL(?![A-Za-z])"#, template: "U/L"),
        Rule(kind: .itemName, cells: .item,
             pattern: #"自(?=细胞|蛋白|球比)"#, template: "白"),
    ]

    /// The suggestions for every table line of `transcription`, line by line and cell by cell.
    /// Lines without a tab are narrative text and get none.
    public static func suggestions(in transcription: String) -> [Self] {
        guard transcription.utf8.contains(UInt8(ascii: "\t")) else { return [] }
        var found: [Self] = []
        for (lineIndex, line) in transcription.components(separatedBy: "\n").enumerated() {
            let segments = line.components(separatedBy: "\t")
            // The cells of a line are its non-empty segments, as `ReportedResultLine` reads them.
            let cellSegments = segments.indices.filter {
                !segments[$0].trimmingCharacters(in: .whitespaces).isEmpty
            }
            guard cellSegments.count >= 2 else { continue }
            let item = segments[cellSegments[0]].trimmingCharacters(in: .whitespaces)
            for (cell, segment) in cellSegments.enumerated() {
                for rule in rules where rule.reads(cell: cell) {
                    let text = segments[segment]
                    guard text.range(of: rule.pattern, options: .regularExpression) != nil else { continue }
                    let fixed = text.replacingOccurrences(of: rule.pattern, with: rule.template, options: .regularExpression)
                    var fixedSegments = segments
                    fixedSegments[segment] = fixed
                    found.append(Self(kind: rule.kind, lineIndex: lineIndex, line: line,
                                      fixedLine: fixedSegments.joined(separator: "\t"), item: item,
                                      before: text.trimmingCharacters(in: .whitespaces),
                                      after: fixed.trimmingCharacters(in: .whitespaces)))
                }
            }
        }
        return found
    }

    /// `transcription` with this fix, or nil when its line no longer reads as it did.
    public func applied(to transcription: String) -> String? {
        var lines = transcription.components(separatedBy: "\n")
        guard lines.indices.contains(lineIndex), lines[lineIndex] == line else { return nil }
        lines[lineIndex] = fixedLine
        return lines.joined(separator: "\n")
    }
}
