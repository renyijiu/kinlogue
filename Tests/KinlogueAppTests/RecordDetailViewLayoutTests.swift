import AppKit
import KinlogueCore
import PDFKit
import SwiftUI
import Testing
@testable import KinlogueApp

@Suite(.serialized)
@MainActor
struct RecordDetailViewLayoutTests {
    @Test
    func originalPaneAvoidsTheCrashingAccessibilityContainerShape() throws {
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(source.contains("Label(AppLocalization.string(\"原件\"), systemImage: \"doc.richtext\")"))
        #expect(source.contains(".accessibilityIdentifier(\"record-original-pane\")"))
        #expect(!source.contains("GroupBox(AppLocalization.string(\"原件\"))"))
        #expect(!source.contains(".accessibilityElement(children: .contain)"))
    }

    @Test
    func fittedPreviewPreservesAspectRatioAtContainerWidth() {
        #expect(OriginalDocumentLayout.widthFittedSize(
            content: CGSize(width: 1_200, height: 2_400),
            containerWidth: 300
        ) == CGSize(width: 300, height: 600))
        #expect(OriginalDocumentLayout.widthFittedSize(
            content: CGSize(width: 2_400, height: 1_200),
            containerWidth: 800
        ) == CGSize(width: 800, height: 400))
        #expect(OriginalDocumentLayout.widthFittedSize(
            content: CGSize(width: 200, height: 100),
            containerWidth: 800
        ) == CGSize(width: 800, height: 400))
        #expect(OriginalDocumentLayout.widthFittedSize(
            content: CGSize(width: 1_200, height: 2_400),
            containerWidth: 300,
            zoom: 1.4
        ) == CGSize(width: 420, height: 840))
        #expect(OriginalDocumentLayout.widthFittedSize(
            content: .zero,
            containerWidth: 800
        ) == .zero)
        #expect(OriginalDocumentLayout.widthFittedSize(
            content: CGSize(width: -200, height: 100),
            containerWidth: 800
        ) == .zero)
        #expect(OriginalDocumentLayout.widthFittedSize(
            content: CGSize(width: 200, height: 100),
            containerWidth: 0
        ) == .zero)
        #expect(OriginalDocumentLayout.widthFittedSize(
            content: CGSize(width: 200, height: 100),
            containerWidth: 800,
            zoom: 0
        ) == .zero)
    }

    @Test
    func imageAndPDFFitPreviewsEmbedSharedZoomControls() throws {
        let source = try String(contentsOf: originalDocumentSourceURL, encoding: .utf8)
        let controlReferences = source.components(
            separatedBy: "PreviewZoomControls(zoomPercent: $fitZoomPercent)"
        ).count - 1

        #expect(controlReferences == 2)
        #expect(source.contains(".accessibilityIdentifier(\"record-original-zoom-out\")"))
        #expect(source.contains(".accessibilityIdentifier(\"record-original-zoom-in\")"))
    }

    @Test
    func imagePreviewsExposeQuarterTurnControlsWithoutChangingTheOriginal() throws {
        let source = try String(contentsOf: originalDocumentSourceURL, encoding: .utf8)
        let controlReferences = source.components(
            separatedBy: "ImageRotationControls(rotation: $rotation)"
        ).count - 1

        #expect(controlReferences == 2)
        #expect(source.contains(".accessibilityIdentifier(\"record-original-rotate-left\")"))
        #expect(source.contains(".accessibilityIdentifier(\"record-original-rotate-right\")"))
        #expect(!source.contains("payload.data ="))
    }

    @Test
    func imageRotationPolicyCyclesAndSwapsQuarterTurnDimensions() {
        var clockwise = OriginalDocumentRotation.zero
        for expected in [
            OriginalDocumentRotation.clockwise90,
            .clockwise180,
            .clockwise270,
            .zero,
        ] {
            clockwise.rotateRight()
            #expect(clockwise == expected)
        }

        var counterclockwise = OriginalDocumentRotation.zero
        for expected in [
            OriginalDocumentRotation.clockwise270,
            .clockwise180,
            .clockwise90,
            .zero,
        ] {
            counterclockwise.rotateLeft()
            #expect(counterclockwise == expected)
        }

        let quarterTurn = OriginalDocumentRotation.clockwise270
        #expect(quarterTurn.orientedSize(CGSize(width: 1_200, height: 2_400)) == CGSize(
            width: 2_400,
            height: 1_200
        ))
        #expect(quarterTurn.unrotatedRenderSize(CGSize(width: 800, height: 400)) == CGSize(
            width: 400,
            height: 800
        ))
    }

    @Test
    func previewZoomPolicyAppliesStepsAndBounds() {
        var zoomPercent = OriginalDocumentPreviewZoom.zoomedIn(from: 100)
        #expect(zoomPercent == 120)
        zoomPercent = OriginalDocumentPreviewZoom.zoomedOut(from: zoomPercent)
        #expect(zoomPercent == 100)
        zoomPercent = OriginalDocumentPreviewZoom.zoomedOut(from: zoomPercent)
        zoomPercent = OriginalDocumentPreviewZoom.zoomedOut(from: zoomPercent)
        #expect(zoomPercent == OriginalDocumentPreviewZoom.minimum)

        zoomPercent = 100
        for _ in 0..<7 {
            zoomPercent = OriginalDocumentPreviewZoom.zoomedIn(from: zoomPercent)
        }
        #expect(zoomPercent == OriginalDocumentPreviewZoom.maximum)
        #expect(OriginalDocumentPreviewZoom.zoomedIn(from: zoomPercent) == zoomPercent)
        #expect(OriginalDocumentPreviewZoom.zoomedOut(
            from: OriginalDocumentPreviewZoom.minimum
        ) == OriginalDocumentPreviewZoom.minimum)
    }

    @Test
    func PDFPreviewUsesCancellableBackgroundRasterPublication() throws {
        let source = try String(contentsOf: originalDocumentSourceURL, encoding: .utf8)

        #expect(source.contains("@State private var image: NSImage?"))
        #expect(source.contains(".task(id: renderKey)"))
        #expect(source.contains("await OriginalDocumentPDFRenderer.render("))
        #expect(source.contains("InteractivePDFPage("))
        #expect(source.contains("guard !Task.isCancelled"))
        #expect(!source.contains("import PDFKit"))
        #expect(!source.contains("PDFDocument(data:"))
        #expect(!source.contains("document.page(at:"))
        #expect(!source.contains(".bounds(for: .mediaBox)"))
        #expect(!source.contains(".thumbnail("))
    }

    @Test
    func inlinePreviewRendersWithAndWithoutAViewerAction() async throws {
        let payload = OriginalDocumentPayload(
            data: try OriginalDocumentTestFixture.pdfData(),
            contentTypeIdentifier: "com.adobe.pdf"
        )
        let staticView = makeFitPreviewHostingView(payload: payload, onOpenOriginal: nil)
        defer {
            staticView.window?.orderOut(nil)
            staticView.window?.contentView = nil
        }
        #expect(await waitForScrollViews(count: 1, in: staticView) != nil)

        var openCount = 0
        let presentation = OriginalDocumentPresentation.inline(onOpenOriginal: {
            openCount += 1
        })
        let clickableView = makeFitPreviewHostingView(
            payload: payload,
            onOpenOriginal: {
                openCount += 1
            }
        )
        defer {
            clickableView.window?.orderOut(nil)
            clickableView.window?.contentView = nil
        }
        #expect(await waitForScrollViews(count: 1, in: clickableView) != nil)
        guard case let .inline(openOriginal) = presentation else {
            Issue.record("Expected inline original presentation")
            return
        }
        let openOriginalAction = try #require(openOriginal)
        openOriginalAction()
        #expect(openCount == 1)

        let source = try? String(contentsOf: originalDocumentSourceURL, encoding: .utf8)
        #expect(source?.contains("if let onOpenOriginal {") == true)
        #expect(source?.contains("Button(AppLocalization.string(\"查看原图\"), action: onOpenOriginal)") == true)
        #expect(source?.contains("fittedImage(size: fittedSize)") == true)
    }

    @Test
    func quarterTurnRasterPreviewsExposeTheirFullHorizontalScrollExtent() async throws {
        for rotation in [
            OriginalDocumentRotation.clockwise90,
            OriginalDocumentRotation.clockwise270,
        ] {
            let hostingView = makeRotatedFitImageHostingView(rotation: rotation)
            defer {
                hostingView.window?.orderOut(nil)
                hostingView.window?.contentView = nil
            }
            let scrollView = try #require(await waitForScrollViews(
                count: 1,
                in: hostingView
            )?.first)
            let documentView = try #require(scrollView.documentView)

            #expect(documentView.frame.width >= 575)
            #expect(documentView.frame.width > scrollView.contentSize.width)
            #expect(documentView.frame.height >= scrollView.contentSize.height)
        }
    }

    @Test
    func invalidPDFShowsTheUnavailableState() throws {
        let source = try String(contentsOf: originalDocumentSourceURL, encoding: .utf8)
        #expect(source.contains("guard let session = await OriginalDocumentPDFRenderer.open(data: data)"))
        #expect(source.contains(".accessibilityIdentifier(\"original-document-unavailable\")"))
    }

    @Test
    func interactiveOriginalStartsFittedAndCanReachDecodedActualSize() throws {
        let source = try String(contentsOf: originalDocumentSourceURL, encoding: .utf8)

        #expect(source.contains("@State private var zoom = 1.0"))
        #expect(source.contains("OriginalDocumentLayout.zoomedSize("))
        #expect(source.contains("OriginalDocumentLayout.maximumZoom("))
        #expect(source.contains("Button { zoom = min(maximumZoom, zoom + 0.2) }"))
        #expect(!source.contains("zoom = min(2.4, zoom + 0.2)"))
        #expect(source.contains("zoom = min(zoom, maximumZoom)"))
        #expect(source.contains("max(displaySize.width, proxy.size.width)"))
        #expect(source.contains("max(displaySize.height, proxy.size.height)"))
        #expect(OriginalDocumentLayout.zoomedSize(
            content: CGSize(width: 1_600, height: 3_200),
            container: CGSize(width: 800, height: 600),
            zoom: 1
        ) == CGSize(width: 300, height: 600))
        #expect(OriginalDocumentLayout.zoomedSize(
            content: CGSize(width: 1_600, height: 3_200),
            container: CGSize(width: 800, height: 600),
            zoom: 2
        ) == CGSize(width: 600, height: 1_200))
        let maximumZoom = OriginalDocumentLayout.maximumZoom(
            content: CGSize(width: 1_600, height: 3_200),
            container: CGSize(width: 800, height: 600)
        )
        let actualSize = OriginalDocumentLayout.zoomedSize(
            content: CGSize(width: 1_600, height: 3_200),
            container: CGSize(width: 800, height: 600),
            zoom: maximumZoom
        )
        #expect(abs(actualSize.width - 1_600) < 0.001)
        #expect(abs(actualSize.height - 3_200) < 0.001)
        #expect(OriginalDocumentLayout.maximumZoom(
            content: CGSize(width: 200, height: 100),
            container: CGSize(width: 800, height: 600)
        ) == 2.4)
    }

    @Test
    func emptyAndLoadingDetailsKeepTheSameSplitRootStructure() {
        var splitChildCounts: [Int] = []
        for isLoading in [false, true] {
            let hostingView = makeHostingView(
                record: nil,
                memberLabel: nil,
                original: nil,
                isOriginalLoading: isLoading
            )
            defer { hostingView.window?.orderOut(nil) }

            let splitViews = viewDescendants(of: hostingView).compactMap {
                $0 as? NSSplitView
            }
            #expect(splitViews.count == 1)
            if let splitView = splitViews.first {
                splitChildCounts.append(splitView.subviews.count)
                #expect(splitView.subviews.count >= 2)
            }
        }
        #expect(splitChildCounts.count == 2)
        #expect(Set(splitChildCounts).count == 1)
    }

    @Test
    func summaryAndFittedOriginalPreviewScrollIndependently() async throws {
        let member = try FamilyMember(displayName: "Layout member")
        let source = try SourceField.manualEntry("Layout source")
        let record = try HealthRecord(
            memberID: member.id,
            attachmentID: UUID(),
            importState: .confirmed,
            title: source,
            organization: source,
            department: source,
            reportType: source,
            reportedResults: source,
            conclusion: source,
            notes: [try UserNote(text: "Layout note")]
        )
        let hostingView = NSHostingView(rootView: RecordDetailView(
            record: record,
            memberLabel: member.displayName,
            original: OriginalDocumentPayload(
                data: try OriginalDocumentTestFixture.pdfData(),
                contentTypeIdentifier: "com.adobe.pdf"
            ),
            isOriginalLoading: false,
            onOpenOriginal: {},
            onEdit: {},
            onDelete: {}
        ))
        hostingView.frame = NSRect(x: 0, y: 0, width: 720, height: 760)
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
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        let scrollViews = try #require(await waitForScrollViews(
            count: 2,
            in: hostingView
        ))
        for scrollView in scrollViews {
            var ancestor = scrollView.superview
            while let current = ancestor {
                #expect(!(current is NSScrollView))
                ancestor = current.superview
            }
        }
    }

    private func makeFitPreviewHostingView(
        payload: OriginalDocumentPayload,
        onOpenOriginal: (() -> Void)?
    ) -> NSHostingView<OriginalDocumentFitPreview> {
        let hostingView = NSHostingView(rootView: OriginalDocumentFitPreview(
            payload: payload,
            onOpenOriginal: onOpenOriginal
        ))
        hostingView.frame = NSRect(x: 0, y: 0, width: 320, height: 400)
        _ = makeWindow(for: hostingView)
        refresh(hostingView, delay: 0.05)
        return hostingView
    }

    private func makeRotatedFitImageHostingView(
        rotation: OriginalDocumentRotation
    ) -> NSHostingView<FittedOriginalImage> {
        let image = NSImage(size: NSSize(width: 120, height: 240))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()
        let hostingView = NSHostingView(rootView: FittedOriginalImage(
            image: image,
            accessibilityLabel: "Rotated original preview",
            zoom: 1.8,
            rotation: rotation,
            onOpenOriginal: nil
        ))
        hostingView.frame = NSRect(x: 0, y: 0, width: 320, height: 400)
        _ = makeWindow(for: hostingView)
        refresh(hostingView, delay: 0.05)
        return hostingView
    }

    private func makeWindow<Content: View>(
        for hostingView: NSHostingView<Content>
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.alphaValue = 0
        window.orderBack(nil)
        return window
    }

    private func waitForScrollViews(
        count: Int,
        in hostingView: NSView
    ) async -> [NSScrollView]? {
        let deadline = Date(timeIntervalSinceNow: 2)
        repeat {
            let scrollViews = viewDescendants(of: hostingView).compactMap { $0 as? NSScrollView }
            if scrollViews.count == count {
                return scrollViews
            }
            hostingView.layoutSubtreeIfNeeded()
            hostingView.displayIfNeeded()
            try? await Task.sleep(for: .milliseconds(20))
        } while Date() < deadline
        return nil
    }

    private func refresh(_ view: NSView, delay: TimeInterval) {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: delay))
    }

    private func makeHostingView(
        record: HealthRecord?,
        memberLabel: String?,
        original: OriginalDocumentPayload?,
        isOriginalLoading: Bool
    ) -> NSHostingView<RecordDetailView> {
        let hostingView = NSHostingView(rootView: RecordDetailView(
            record: record,
            memberLabel: memberLabel,
            original: original,
            isOriginalLoading: isOriginalLoading,
            onOpenOriginal: {},
            onEdit: {},
            onDelete: {}
        ))
        hostingView.frame = NSRect(x: 0, y: 0, width: 720, height: 760)
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
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        return hostingView
    }

    private func viewDescendants(of root: NSView) -> [NSView] {
        var result = [root]
        for child in root.subviews {
            result.append(contentsOf: viewDescendants(of: child))
        }
        return result
    }

    private var sourceURL: URL {
        repositoryURL
            .appendingPathComponent("Sources/KinlogueApp/Views/RecordDetailView.swift")
    }

    private var originalDocumentSourceURL: URL {
        repositoryURL
            .appendingPathComponent("Sources/KinlogueApp/Views/OriginalDocumentView.swift")
    }

    private var repositoryURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

@MainActor
enum OriginalDocumentTestFixture {
    static func pdfData(pageCount: Int = 1) throws -> Data {
        let document = PDFDocument()
        for pageIndex in 0..<pageCount {
            let image = NSImage(size: NSSize(width: 612, height: 792))
            image.lockFocus()
            NSColor.white.setFill()
            NSRect(origin: .zero, size: image.size).fill()
            image.unlockFocus()

            guard let page = PDFPage(image: image) else {
                throw FixtureError.pdfPage
            }
            document.insert(page, at: pageIndex)
        }
        guard let data = document.dataRepresentation() else {
            throw FixtureError.pdfData
        }
        return data
    }

    private enum FixtureError: Error {
        case pdfPage
        case pdfData
    }
}
