import AppKit
import SwiftUI
import Testing
@testable import KinlogueApp

/// The member chat panel laid out in a real `NSHostingView`.
@MainActor
@Suite(.serialized)
struct AssistantPanelLayoutTests {
    /// A text view whose first line touches its clip bounds shows the top of Chinese text cut off
    /// while an input method composes it (the record editor had the same fault, see `InsetTextEditor`).
    @Test
    func theQuestionEditorKeepsTheFirstLineInsideTheClipBounds() async throws {
        let fixture = try await AssistantServiceFixture()
        defer { fixture.close() }
        let model = AssistantConversationModel(service: fixture.service, settings: { .enabled })
        await model.open(memberID: fixture.member.id)
        model.confirm()
        let hostingView = makeHostingView(model)
        defer {
            hostingView.window?.orderOut(nil)
            hostingView.window?.contentView = nil
        }

        let textView = try #require(viewDescendants(of: hostingView).compactMap { $0 as? NSTextView }.first)
        textView.insertText("合成问题", replacementRange: NSRange(location: NSNotFound, length: 0))
        settle(hostingView)

        let layoutManager = try #require(textView.layoutManager)
        let textContainer = try #require(textView.textContainer)
        let glyphRange = layoutManager.glyphRange(forCharacterRange: NSRange(location: 0, length: 1), actualCharacterRange: nil)
        let glyphBounds = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        let firstGlyphTop = textView.textContainerOrigin.y + glyphBounds.minY
        #expect(firstGlyphTop - textView.visibleRect.minY >= 8)
    }

    private func makeHostingView(_ model: AssistantConversationModel) -> NSHostingView<some View> {
        let hostingView = NSHostingView(rootView: AssistantPanelView(
            model: model, memberLabel: "Synthetic member", onShowRecord: { _ in }, onOpenSettings: {}, onClose: {}
        ))
        hostingView.frame = NSRect(x: 0, y: 0, width: 640, height: 640)
        let window = NSWindow(contentRect: hostingView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hostingView
        window.alphaValue = 0
        window.orderBack(nil)
        settle(hostingView)
        return hostingView
    }

    private func viewDescendants(of root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap { viewDescendants(of: $0) }
    }

    private func settle(_ hostingView: NSView) {
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        hostingView.layoutSubtreeIfNeeded()
    }
}
