import AppKit
import KinlogueCore
import SwiftUI
import Testing
@testable import KinlogueApp

@MainActor
struct RecordEditViewLayoutTests {
    @Test
    func reloadingAConflictReplacesTheFormAndUsesTheLatestRevisionForTheNextSave() throws {
        let fixture = try makeFixture(usesManualDate: false)
        let latest = try HealthRecord(
            id: fixture.record.id,
            memberID: fixture.member.id,
            sources: fixture.record.sources,
            importState: .confirmed,
            revision: fixture.record.revision + 1,
            title: try SourceField(originalTranscription: "Latest title"),
            conclusion: try SourceField(originalTranscription: "Latest conclusion"),
            notes: [try UserNote(text: "Latest note")]
        )
        var state = RecordEditState(
            record: fixture.record,
            now: Date(timeIntervalSince1970: 100)
        )
        state.title = "Unsaved local title"

        state.load(latest, now: Date(timeIntervalSince1970: 200))
        let command = state.command()

        #expect(command.recordID == latest.id)
        #expect(command.expectedRevision == latest.revision)
        #expect(command.title == "Latest title")
        #expect(command.conclusion == "Latest conclusion")
        #expect(command.userNote == "Latest note")
    }

    @Test(arguments: [false, true])
    func actionsRemainVisibleInTheFixedEditorViewport(usesManualDate: Bool) throws {
        let fixture = try makeFixture(usesManualDate: usesManualDate)
        let hostingView = try makeHostingView(record: fixture.record, member: fixture.member)
        defer {
            hostingView.window?.orderOut(nil)
            hostingView.window?.contentView = nil
        }

        let views = viewDescendants(of: hostingView)
        // On the supported SwiftUI/AppKit toolchain, pure SwiftUI buttons are
        // materialized as key-view proxies. Manual-date mode adds the calendar
        // button to the editor's fixed cancel and save actions.
        let actionProxies = views.filter {
            String(describing: type(of: $0)) == "KeyViewProxy"
        }
        #expect(actionProxies.count == (usesManualDate ? 3 : 2))
        for button in actionProxies {
            let frame = button.convert(button.bounds, to: hostingView)
            #expect(hostingView.bounds.intersects(frame))
            #expect(hostingView.bounds.contains(frame))
        }
    }

    @Test
    func editorShowsOriginalPaneBesideTheScrollableForm() throws {
        let fixture = try makeFixture(usesManualDate: false)
        let hostingView = try makeHostingView(record: fixture.record, member: fixture.member)
        defer {
            hostingView.window?.orderOut(nil)
            hostingView.window?.contentView = nil
        }

        let views = viewDescendants(of: hostingView)
        let splitView = try #require(views.compactMap { $0 as? NSSplitView }.first)
        #expect(splitView.isVertical)
        #expect(splitView.subviews.count >= 2)

        let formScrollViews = viewDescendants(of: hostingView)
            .compactMap { $0 as? NSScrollView }
            .filter { scrollView in
                var ancestor = scrollView.superview
                while let current = ancestor {
                    if current is NSScrollView { return false }
                    ancestor = current.superview
                }
                return true
            }
        #expect(!formScrollViews.isEmpty)
    }

    @Test
    func multilineEditorsKeepTheFirstLineInsideTheClipBounds() throws {
        let fixture = try makeFixture(usesManualDate: false)
        let hostingView = try makeHostingView(record: fixture.record, member: fixture.member)
        defer {
            hostingView.window?.orderOut(nil)
            hostingView.window?.contentView = nil
        }

        let editorValues = ["Layout source", "Layout note"]
        let textViews = viewDescendants(of: hostingView)
            .compactMap { $0 as? NSTextView }
            .filter { editorValues.contains($0.string) }
        #expect(textViews.count == 3)

        for textView in textViews {
            let layoutManager = try #require(textView.layoutManager)
            let textContainer = try #require(textView.textContainer)
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: NSRange(location: 0, length: 1),
                actualCharacterRange: nil
            )
            let glyphBounds = layoutManager.boundingRect(
                forGlyphRange: glyphRange,
                in: textContainer
            )
            let firstGlyphTop = textView.textContainerOrigin.y + glyphBounds.minY
            let topGap = firstGlyphTop - textView.visibleRect.minY

            #expect(topGap >= 8)
        }
    }

    @Test
    func recordMultilineEditorsExposeFieldSpecificAccessibilityMetadata() throws {
        let fixture = try makeFixture(usesManualDate: false)
        let hostingView = try makeHostingView(record: fixture.record, member: fixture.member)
        defer {
            hostingView.window?.orderOut(nil)
            hostingView.window?.contentView = nil
        }

        let textViews = viewDescendants(of: hostingView)
            .compactMap { $0 as? NSTextView }
            .filter { ["Layout source", "Layout note"].contains($0.string) }
        #expect(textViews.count == 3)

        let sourceHelp = try #require(fixture.record.reportedResults)
            .sourceDescription(for: fixture.record.sources)
        let expectedMetadata = [
            AppLocalization.string("检查结果（逐字）"): sourceHelp,
            AppLocalization.string("检查结论（逐字）"): sourceHelp,
            AppLocalization.string("我的备注"):
                AppLocalization.string("填写仅供自己查看的备注，不会作为原报告内容"),
        ]

        for textView in textViews {
            let label = try #require(textView.accessibilityLabel())
            #expect(textView.accessibilityHelp() == expectedMetadata[label])
        }
        #expect(Set(textViews.compactMap { $0.accessibilityLabel() }) == Set(expectedMetadata.keys))
    }

    @Test
    func insetTextEditorSynchronizesNativeAndSwiftUIState() throws {
        let state = InsetTextEditorState(text: "Initial text", isEnabled: true)
        let hostingView = NSHostingView(rootView: InsetTextEditorHarness(state: state))
        hostingView.frame = NSRect(x: 0, y: 0, width: 320, height: 100)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.alphaValue = 0
        window.orderBack(nil)
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        defer {
            hostingView.window?.orderOut(nil)
            hostingView.window?.contentView = nil
        }

        let textView = try #require(viewDescendants(of: hostingView).compactMap { $0 as? NSTextView }.first)
        #expect(textView.accessibilityLabel() == "Bridge label")
        #expect(textView.accessibilityHelp() == "Bridge help")
        #expect(textView.isEditable)
        #expect(textView.isSelectable)

        textView.string = "Native update"
        textView.didChangeText()
        #expect(state.text == "Native update")

        state.text = "External update"
        settle(hostingView)
        #expect(textView.string == "External update")

        state.isEnabled = false
        settle(hostingView)
        #expect(!textView.isEditable)
        #expect(!textView.isSelectable)

        state.isEnabled = true
        settle(hostingView)
        #expect(textView.isEditable)
        #expect(textView.isSelectable)
    }

    @Test
    func appShellPassesTheSelectedOriginalIntoTheRecordEditor() throws {
        let source = try String(contentsOf: appShellSourceURL, encoding: .utf8)
        let editorStart = try #require(source.range(of: ".sheet(item: $model.editingRecord"))
        let viewerStart = try #require(source.range(
            of: ".sheet(item: $model.viewingOriginal",
            range: editorStart.upperBound..<source.endIndex
        ))
        let editorSheet = source[editorStart.lowerBound..<viewerStart.lowerBound]

        #expect(editorSheet.contains("original: model.originalDocument"))
        #expect(editorSheet.contains("isOriginalLoading: model.isOriginalLoading"))
        #expect(editorSheet.contains("selectedOriginalSourceID: model.selectedOriginalSourceID"))
        #expect(editorSheet.contains("Task { await model.selectOriginalSource(sourceID) }"))
    }

    private func makeFixture(
        usesManualDate: Bool
    ) throws -> (member: FamilyMember, record: HealthRecord) {
        let member = try FamilyMember(displayName: "Layout member")
        let source = try SourceField(originalTranscription: "Layout source")
        let manualDate = ReportDateCandidate(
            date: Date(timeIntervalSince1970: 1_700_000_000),
            kind: .other,
            source: try .manualEntry("2023-11-14")
        )
        let record = try HealthRecord(
            memberID: member.id,
            attachmentID: UUID(),
            importState: .confirmed,
            title: source,
            organization: source,
            department: source,
            reportType: source,
            dateCandidates: usesManualDate ? [manualDate] : [],
            timelineDateCandidateID: usesManualDate ? manualDate.id : nil,
            reportedResults: source,
            conclusion: source,
            abnormalItems: [source],
            notes: [try UserNote(text: "Layout note")]
        )
        return (member, record)
    }

    private func makeHostingView(
        record: HealthRecord,
        member: FamilyMember
    ) throws -> NSHostingView<RecordEditView> {
        let hostingView = NSHostingView(rootView: RecordEditView(
            record: record,
            members: [member],
            original: OriginalDocumentPayload(
                data: try OriginalDocumentTestFixture.pdfData(),
                contentTypeIdentifier: "com.adobe.pdf",
                sourceID: record.sources.first.id,
                attachmentID: record.sources.first.attachmentID,
                displayName: "Synthetic report",
                pageCount: 1
            ),
            isOriginalLoading: false,
            selectedOriginalSourceID: record.sources.first.id,
            onSelectOriginalSource: { _ in },
            onSave: { _ in .saved }
        ))
        hostingView.frame = NSRect(x: 0, y: 0, width: 1_080, height: 720)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.alphaValue = 0
        window.orderBack(nil)
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        return hostingView
    }

    private func viewDescendants(of root: NSView) -> [NSView] {
        var result = [root]
        for child in root.subviews {
            result.append(contentsOf: viewDescendants(of: child))
        }
        return result
    }

    private func settle(_ hostingView: NSView) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        hostingView.layoutSubtreeIfNeeded()
    }

    private var appShellSourceURL: URL {
        repositoryURL
            .appendingPathComponent("Sources/KinlogueApp/Views/AppShellView.swift")
    }

    private var repositoryURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

@MainActor
private final class InsetTextEditorState: ObservableObject {
    @Published var text: String
    @Published var isEnabled: Bool

    init(text: String, isEnabled: Bool) {
        self.text = text
        self.isEnabled = isEnabled
    }
}

private struct InsetTextEditorHarness: View {
    @ObservedObject var state: InsetTextEditorState

    var body: some View {
        InsetTextEditor(
            text: $state.text,
            accessibilityLabel: "Bridge label",
            accessibilityHelp: "Bridge help"
        )
        .disabled(!state.isEnabled)
        .frame(width: 320, height: 100)
    }
}
