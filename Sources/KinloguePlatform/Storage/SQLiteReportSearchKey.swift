import Foundation
import os

/// A coarse key that lets search skip text that cannot match, without deciding what does match.
///
/// Guarantee: if Foundation's case-insensitive, non-literal search finds a term in a field under any
/// locale, the key of the term is a byte substring of the key of that field. The reverse does not
/// hold, so every key hit is still confirmed by the Foundation predicate on the original text.
///
/// The guarantee rests on how Core Foundation decides that two character clusters are equal in such
/// a search: canonical equivalence plus case folding, including length-changing folds and the
/// language-specific forms of I. The key is the same for every such variant because each scalar is
/// compatibility-decomposed, mapped to uppercase and back to lowercase one scalar at a time until
/// stable, and then reduced to its letters and numbers. Marks, punctuation, symbols, spaces and
/// format characters produce nothing on both sides. Mappings are per scalar on purpose: a
/// whole-string lowercase is context sensitive, as with a final sigma, and would break the guarantee.
enum SQLiteReportSearchKey {
    /// Never occurs in UTF-8, so a term cannot match across two fields.
    static let fieldSeparator: UInt8 = 0xFF

    private static let slowScalars = OSAllocatedUnfairLock<[UInt32: [UInt8]]>(initialState: [:])

    static func key(_ text: String) -> [UInt8] {
        var key: [UInt8] = []
        append(text, to: &key)
        return key
    }

    static func key(fields: [String]) -> [UInt8] {
        var key: [UInt8] = []
        key.reserveCapacity(fields.reduce(fields.count) { $0 + $1.utf8.count })
        for (index, field) in fields.enumerated() {
            if index > 0 { key.append(fieldSeparator) }
            append(field, to: &key)
        }
        return key
    }

    static func append(_ text: String, to key: inout [UInt8]) {
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if value < 0x80 {
                let byte = UInt8(value)
                switch byte {
                case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"): key.append(byte)
                case UInt8(ascii: "A")...UInt8(ascii: "Z"): key.append(byte + 0x20)
                default: break
                }
            } else if (0x4E00...0x9FFF).contains(value) || (0x3400...0x4DBF).contains(value) {
                // Unified ideographs have no case and no decomposition.
                key.append(UInt8(0xE0 | (value >> 12)))
                key.append(UInt8(0x80 | ((value >> 6) & 0x3F)))
                key.append(UInt8(0x80 | (value & 0x3F)))
            } else {
                key.append(contentsOf: slow(scalar))
            }
        }
    }

    /// Whether `needle` occurs in one field of a key built by `key(fields:)`.
    static func contains(_ needle: [UInt8], in key: [UInt8]) -> Bool {
        guard !needle.isEmpty else { return true }
        guard needle.count <= key.count else { return false }
        return key.withUnsafeBytes { haystack in
            needle.withUnsafeBytes { memmem(haystack.baseAddress, haystack.count, $0.baseAddress, $0.count) != nil }
        }
    }

    /// The indexes of the fields whose part of the key contains `needle`.
    static func matchingFields(_ needle: [UInt8], in key: [UInt8]) -> [Int] {
        var indexes: [Int] = [], field = 0, start = 0
        func check(_ end: Int) {
            guard end - start >= needle.count else { return }
            let found = key.withUnsafeBytes { haystack in
                needle.withUnsafeBytes { memmem(haystack.baseAddress! + start, end - start, $0.baseAddress, $0.count) != nil }
            }
            if found { indexes.append(field) }
        }
        for position in key.indices where key[position] == fieldSeparator {
            check(position)
            field += 1; start = position + 1
        }
        check(key.count)
        return indexes
    }

    private static func slow(_ scalar: Unicode.Scalar) -> [UInt8] {
        if let cached = slowScalars.withLock({ $0[scalar.value] }) { return cached }
        let computed = fold(scalar)
        slowScalars.withLock { $0[scalar.value] = computed }
        return computed
    }

    private static func decomposed(_ scalars: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return Array(String(view).decomposedStringWithCompatibilityMapping.unicodeScalars)
    }

    private static func fold(_ scalar: Unicode.Scalar) -> [UInt8] {
        var scalars = decomposed([scalar])
        // Two rounds settle every assigned scalar; the bound only guards against a table change.
        for _ in 0..<8 {
            var mapped: [Unicode.Scalar] = []
            for value in scalars {
                for upper in value.properties.uppercaseMapping.unicodeScalars {
                    mapped.append(contentsOf: upper.properties.lowercaseMapping.unicodeScalars)
                }
            }
            let next = decomposed(mapped)
            if next == scalars { break }
            scalars = next
        }
        var bytes: [UInt8] = []
        for value in scalars {
            switch value.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                 .decimalNumber, .letterNumber, .otherNumber:
                bytes.append(contentsOf: Array(String(value).utf8))
            default: break
            }
        }
        return bytes
    }
}
