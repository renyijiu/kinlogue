import AppKit
import Testing
@testable import KinlogueApp

@MainActor
struct TextInputCompositionTests {
    @Test
    func uncommittedInputMethodTextCountsAsAnActiveComposition() {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        #expect(TextInputComposition.isActive(in: textView) == false)

        textView.setMarkedText(
            "he cheng",
            selectedRange: NSRange(location: 8, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        #expect(TextInputComposition.isActive(in: textView))

        textView.unmarkText()
        #expect(TextInputComposition.isActive(in: textView) == false)
    }

    @Test
    func aResponderThatTakesNoTextIsNeverComposing() {
        #expect(TextInputComposition.isActive(in: nil) == false)
        #expect(TextInputComposition.isActive(in: NSButton(frame: .zero)) == false)
    }
}
