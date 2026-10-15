import Foundation
import Testing
@testable import KinlogueCore

@Test
func recognitionSuggestionsNameTheKnownMisreadingsOfTableCells() {
    let text = [
        "合成葡萄糖\t6.85个\t3.89-6.11",
        "合成甘油三酯\t2.31 T mmol/L\t<1.70",
        "合成丙氨酸氨基转移酶\t45 UIL\t7-40 UIL",
        "合成自细胞计数\t6.2\t3.5-9.5",
        // Units, counts in a reference and a word that only looks alike are left alone.
        "合成红细胞\t4.5 T/L\t4.3-5.8",
        "合成尿红细胞\t2个/HP\t0-1个",
        "合成自身抗体\t阴性",
        "合成叙述里的 6.85个",
    ].joined(separator: "\n")

    let found = RecognitionSuggestion.suggestions(in: text)

    #expect(found.map(\.kind) == [.raisedMarker, .raisedMarker, .unit, .unit, .itemName])
    #expect(found.map(\.item) == ["合成葡萄糖", "合成甘油三酯", "合成丙氨酸氨基转移酶", "合成丙氨酸氨基转移酶", "合成自细胞计数"])
    #expect(found.map(\.before) == ["6.85个", "2.31 T mmol/L", "45 UIL", "7-40 UIL", "合成自细胞计数"])
    #expect(found.map(\.after) == ["6.85↑", "2.31 ↑ mmol/L", "45 U/L", "7-40 U/L", "合成白细胞计数"])
    #expect(found.map(\.lineIndex) == [0, 1, 2, 2, 3])
    #expect(RecognitionSuggestion.suggestions(in: "合成叙述 6.85个\n合成 UIL").isEmpty)
}

@Test
func recognitionSuggestionsChangeOnlyTheirCellAndOnlyAWhileTheLineIsUnchanged() throws {
    // Blank cells, spacing and Windows line endings around the cell stay as they were.
    let text = "合成标题行\n合成葡萄糖\t\t 6.85个 \tUIL\r\n合成胰岛素\t3.0\t1.9~23"
    let found = RecognitionSuggestion.suggestions(in: text)
    #expect(found.map(\.kind) == [.raisedMarker, .unit])

    let marker = try #require(found.first)
    let fixed = try #require(marker.applied(to: text))
    #expect(fixed == "合成标题行\n合成葡萄糖\t\t 6.85↑ \tUIL\r\n合成胰岛素\t3.0\t1.9~23")
    // The other suggestion of the same line now reads a changed line; found again, it applies.
    #expect(found[1].applied(to: fixed) == nil)
    let unit = try #require(RecognitionSuggestion.suggestions(in: fixed).first)
    #expect(unit.applied(to: fixed) == "合成标题行\n合成葡萄糖\t\t 6.85↑ \tU/L\r\n合成胰岛素\t3.0\t1.9~23")
    #expect(RecognitionSuggestion.suggestions(in: try #require(unit.applied(to: fixed))).isEmpty)
    // An edit to the line, or fewer lines, leaves the transcription alone.
    #expect(marker.applied(to: "合成标题行\n合成葡萄糖\t6.86个") == nil)
    #expect(marker.applied(to: "合成标题行") == nil)
}
