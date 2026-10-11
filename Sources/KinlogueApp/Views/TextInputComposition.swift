import AppKit

enum TextInputComposition {
    /// True while an input method holds uncommitted text in `responder`. A
    /// keyboard shortcut reaches a form before that text is committed, so a
    /// shortcut that saves the form must wait or the text is lost.
    @MainActor
    static func isActive(in responder: NSResponder?) -> Bool {
        (responder as? NSTextInputClient)?.hasMarkedText() ?? false
    }
}
