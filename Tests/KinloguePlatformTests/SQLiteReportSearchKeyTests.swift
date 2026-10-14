import Foundation
import Testing
@testable import KinloguePlatform

/// The search key may only remove text that Foundation would not match. These tests compare it
/// with the Foundation search itself, on this system's Unicode tables, rather than with a copy of
/// the rules the key was written from.
private let searchKeyLocales = ["en_US", "zh_Hans_CN", "tr_TR", "az_AZ", "lt_LT", "nl_NL", "el_GR", "de_DE", "ja_JP"]
    .map(Locale.init(identifier:))

/// Foundation itself, not the project's wrapper. A term ending in NUL is left out: Foundation reads
/// past the end of the text for it, which `RecordQuery.localizedContains` and its own test cover.
private func foundationFinds(_ term: String, in field: String, locale: Locale) -> Bool {
    guard term.unicodeScalars.last?.value != 0 else { return false }
    return field.range(of: term, options: .caseInsensitive, locale: locale) != nil
}

private func keyFinds(_ term: String, in field: String) -> Bool {
    SQLiteReportSearchKey.contains(SQLiteReportSearchKey.key(term), in: SQLiteReportSearchKey.key(field))
}

/// Swift compares strings by canonical equivalence, so a set of strings would merge exactly the
/// composed and decomposed forms these tests need to tell apart. Scalars keep them distinct.
private func distinctByScalars(_ texts: [String]) -> [String] {
    var seen: Set<[UInt32]> = []
    return texts.filter { seen.insert($0.unicodeScalars.map(\.value)).inserted }
}

private func caseAndCanonicalVariants(of scalar: Unicode.Scalar) -> [String] {
    let text = String(scalar), properties = scalar.properties
    return distinctByScalars([
        text, properties.lowercaseMapping, properties.uppercaseMapping, properties.titlecaseMapping,
        text.decomposedStringWithCanonicalMapping, text.precomposedStringWithCanonicalMapping,
    ])
}

/// Case and canonical variants of one scalar are exactly what a case-insensitive, non-literal
/// search may treat as equal, so their keys must be identical for every scalar there is.
@Test
func sqliteSearchKeyIsTheSameForEveryCaseAndCanonicalVariantOfEachScalar() {
    var checked = 0, failures: [String] = []
    for value in UInt32(0)...0x10FFFF {
        guard let scalar = Unicode.Scalar(value) else { continue }
        let variants = caseAndCanonicalVariants(of: scalar)
        guard variants.count > 1 else { continue }
        checked += 1
        let key = SQLiteReportSearchKey.key(variants[0])
        for variant in variants.dropFirst() where SQLiteReportSearchKey.key(variant) != key {
            failures.append(String(value, radix: 16))
        }
    }
    // Cased letters, precomposed letters, Hangul syllables and compatibility ideographs.
    #expect(checked > 15_000, "checked \(checked)")
    #expect(failures.isEmpty, "scalars whose variants have different keys: \(failures.prefix(20))")
}

/// The same variants, checked against the real search: wherever Foundation finds one variant in
/// another, alone or inside other text, the key must find it too.
@Test
func sqliteSearchKeyNeverRejectsAVariantPairThatFoundationMatches() {
    var matched = 0, failures: [String] = []
    for value in UInt32(0)...0x10FFFF {
        guard let scalar = Unicode.Scalar(value) else { continue }
        let variants = caseAndCanonicalVariants(of: scalar)
        guard variants.count > 1 else { continue }
        // A third of the locales per scalar keeps the run short while every locale sees every block.
        let locale = searchKeyLocales[Int(value) % searchKeyLocales.count]
        for term in variants {
            for field in variants {
                for candidate in [field, "x" + field + "y"] where foundationFinds(term, in: candidate, locale: locale) {
                    matched += 1
                    if !keyFinds(term, in: candidate) { failures.append(String(value, radix: 16)) }
                }
            }
        }
    }
    #expect(matched > 50_000, "matched \(matched)")
    #expect(failures.isEmpty, "scalars with a Foundation match the key rejects: \(Set(failures).sorted().prefix(20))")
}

@Test
func sqliteSearchKeyKeepsFoundationMatchesAcrossScriptsLocalesAndFoldingEdgeCases() {
    let fields = [
        "Straße 12", "STRASSE 12", "ﬁnal ﬂoor ﬃ", "FINAL FLOOR FFI", "İstanbul ISTANBUL ıstanbul istanbul",
        "300 K 300 K", "Å Å A\u{30A}", "ǅ ǆ Ǆ dž", "οδός ΟΔΟΣ οδοσ ὈΔΌΣ", "ᾳ ᾼ ΑΙ", "ŉ ʼN", "ǰ J\u{30C}",
        "한국어 한국어", "がぎぐ か\u{3099}", "ｶﾞ ガ", "豈 豈 葛\u{E0100}", "合成报告 项目9876 2026-01-15",
        "ＡＢＣ１２３ ABC123", "①②③ ½ ²", "Ⅷ ⅷ", "Ⓐ ⓐ", "𝐀𝐛𝐜", "Привет ПРИВЕТ", "և ԵՒ", "Ꭰ ꭰ", "𐐀 𐐨",
        "co\u{AD}operate", "e\u{34F}\u{301}", "e\u{301}\u{323} ẹ\u{301}", "a\u{0}b", "👩‍👩‍👧‍👦 zwj\u{200D}text",
        "مرحبا", "שלום", "résumé RÉSUMÉ re\u{301}sume\u{301}", "Ǆungla ǅungla džungla",
    ]
    var pieces: [String] = []
    for field in fields {
        let scalars = Array(field.unicodeScalars)
        for start in scalars.indices {
            for length in 1...4 where start + length <= scalars.count {
                var view = String.UnicodeScalarView()
                view.append(contentsOf: scalars[start..<(start + length)])
                let piece = String(view)
                pieces += [piece, piece.uppercased(), piece.lowercased(), piece.capitalized,
                    piece.decomposedStringWithCanonicalMapping, piece.precomposedStringWithCanonicalMapping]
            }
        }
    }
    let terms = distinctByScalars(pieces).filter { !$0.isEmpty }
    var matched = 0, failures: [String] = []
    for locale in searchKeyLocales {
        for term in terms {
            for field in fields where foundationFinds(term, in: field, locale: locale) {
                matched += 1
                if !keyFinds(term, in: field) { failures.append("\(locale.identifier): \(term.unicodeScalars.map { String($0.value, radix: 16) }) in \(field)") }
            }
        }
    }
    #expect(matched > 5_000, "matched \(matched)")
    #expect(failures.isEmpty, "\(failures.prefix(10))")
}

@Test
func sqliteSearchKeyKeepsFoundationMatchesForGeneratedMixedText() {
    // A fixed linear congruential sequence keeps the generated corpus the same on every run.
    var state: UInt64 = 0x4B49_4E4C_4F47_5545
    func next(_ bound: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((state >> 33) % UInt64(bound))
    }
    let pool: [String] = [
        "a", "B", "i", "I", "İ", "ı", "s", "S", "ß", "ẞ", "ſ", "k", "K", "K", "é", "e\u{301}", "É", "ü", "U\u{308}",
        "σ", "ς", "Σ", "ά", "Ά", "ᾳ", "ﬁ", "ǆ", "ǅ", "合", "成", "报", "告", "豈", "豈", "한", "が", "か", "\u{3099}", "ｶ", "ﾞ",
        "1", "２", "②", "-", " ", "/", "\u{0}", "\u{AD}", "\u{200D}", "\u{301}", "\u{323}", "\u{FE0F}", "д", "Д", "և", "👍",
    ]
    func transformed(_ text: String) -> String {
        switch next(6) {
        case 0: text.uppercased()
        case 1: text.lowercased()
        case 2: text.decomposedStringWithCanonicalMapping
        case 3: text.precomposedStringWithCanonicalMapping
        case 4: text.capitalized
        default: text
        }
    }
    var matched = 0, failures: [String] = []
    for _ in 0..<4_000 {
        let pieces = (0..<(4 + next(12))).map { _ in pool[next(pool.count)] }
        let field = pieces.joined()
        let start = next(pieces.count), length = 1 + next(min(4, pieces.count - start))
        let term = transformed(pieces[start..<(start + length)].joined())
        let locale = searchKeyLocales[next(searchKeyLocales.count)]
        for candidate in [field, transformed(field)] where foundationFinds(term, in: candidate, locale: locale) {
            matched += 1
            if !keyFinds(term, in: candidate) {
                failures.append("\(locale.identifier): \(term.unicodeScalars.map { String($0.value, radix: 16) }) in \(candidate.unicodeScalars.map { String($0.value, radix: 16) })")
            }
        }
    }
    #expect(matched > 2_000, "matched \(matched)")
    #expect(failures.isEmpty, "\(failures.prefix(5))")
}

@Test
func sqliteSearchKeyDoesNotMatchAcrossFieldsAndReportsWhichFieldsMayMatch() {
    let fields = ["合成报告", "Synthetic Clinic", "2026-01-15", ""]
    let key = SQLiteReportSearchKey.key(fields: fields)
    #expect(SQLiteReportSearchKey.matchingFields(SQLiteReportSearchKey.key("clinic"), in: key) == [1])
    #expect(SQLiteReportSearchKey.matchingFields(SQLiteReportSearchKey.key("2026-01"), in: key) == [2])
    #expect(SQLiteReportSearchKey.matchingFields(SQLiteReportSearchKey.key("报告"), in: key) == [0])
    // The end of one field and the start of the next never form a match.
    #expect(!SQLiteReportSearchKey.contains(SQLiteReportSearchKey.key("告syn"), in: key))
    #expect(!SQLiteReportSearchKey.contains(SQLiteReportSearchKey.key("clinic2026"), in: key))
    // A term without letters or numbers has no key, so it removes nothing.
    #expect(SQLiteReportSearchKey.key("-/ \u{301}").isEmpty)
    #expect(SQLiteReportSearchKey.contains([], in: key))
}
