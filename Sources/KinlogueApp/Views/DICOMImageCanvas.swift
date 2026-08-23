import AppKit
import CoreGraphics
import KinloguePlatform
import SwiftUI

struct DICOMImageCanvas: NSViewRepresentable {
    let image: DICOMSliceImage?
    let zoomScale: Double
    let panOffset: DICOMViewerOffset
    let onWindow: (Double, Double) -> Void
    let onPan: (Double, Double) -> Void
    let onZoom: (Double, Double, Double) -> Void
    let onSliceStep: (Int) -> Void

    func makeNSView(context: Context) -> DICOMImageCanvasView {
        let view = DICOMImageCanvasView()
        update(view)
        return view
    }

    func updateNSView(_ view: DICOMImageCanvasView, context: Context) {
        update(view)
    }

    private func update(_ view: DICOMImageCanvasView) {
        view.updateDisplay(
            image: image,
            zoomScale: zoomScale,
            panOffset: panOffset
        )
        view.onWindow = onWindow
        view.onPan = onPan
        view.onZoom = onZoom
        view.onSliceStep = onSliceStep
    }
}

struct DICOMCanvasRenderedImage: Sendable {
    let renderID: UUID
    let image: CGImage
}

protocol DICOMCanvasRendering: Sendable {
    func render(_ image: DICOMSliceImage) async throws -> DICOMCanvasRenderedImage?
}

actor DICOMCanvasImageRenderer: DICOMCanvasRendering {
    static let shared = DICOMCanvasImageRenderer()

    func render(_ image: DICOMSliceImage) async throws -> DICOMCanvasRenderedImage? {
        try Task.checkCancellation()
        let renderedImage = try DICOMCanvasImageFactory.makeRenderedImage(from: image)
        try Task.checkCancellation()
        return renderedImage
    }
}

enum DICOMCanvasImageFactory {
    static func makeRenderedImage(
        from image: DICOMSliceImage
    ) throws -> DICOMCanvasRenderedImage? {
        guard image.rows > 0, image.columns > 0 else { return nil }
        let expectedCount = image.rows.multipliedReportingOverflow(by: image.columns)
        guard !expectedCount.overflow else { return nil }

        let ownedPixels = try image.withGrayscaleBytes { bytes -> Data? in
            guard expectedCount.partialValue == bytes.count else { return nil }
            return Data(bytes)
        }
        guard let ownedPixels,
              let provider = CGDataProvider(data: ownedPixels as CFData) else { return nil }

        guard let renderedImage = CGImage(
            width: image.columns,
            height: image.rows,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: image.columns,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else { return nil }

        return DICOMCanvasRenderedImage(
            renderID: image.renderID,
            image: renderedImage
        )
    }
}

@MainActor
final class DICOMImageCanvasView: NSView {
    private struct DisplayState: Equatable {
        let renderID: UUID?
        let zoomScale: Double
        let panOffset: DICOMViewerOffset
    }

    var zoomScale = 1.0
    var panOffset = DICOMViewerOffset.zero
    var onWindow: ((Double, Double) -> Void)?
    var onPan: ((Double, Double) -> Void)?
    var onZoom: ((Double, Double, Double) -> Void)?
    var onSliceStep: ((Int) -> Void)?

    private var spaceIsPressed = false
    private var accumulatedScroll = 0.0
    private let renderer: any DICOMCanvasRendering
    private var renderTask: Task<Void, Never>?
    private var renderGeneration: UInt64 = 0
    private var canvasImage: CGImage?
    private(set) var renderedImageID: UUID?
    private var displayState = DisplayState(
        renderID: nil,
        zoomScale: 1,
        panOffset: .zero
    )

    override init(frame frameRect: NSRect) {
        renderer = DICOMCanvasImageRenderer.shared
        super.init(frame: frameRect)
        configureAccessibility()
    }

    init(frame frameRect: NSRect, renderer: any DICOMCanvasRendering) {
        self.renderer = renderer
        super.init(frame: frameRect)
        configureAccessibility()
    }

    required init?(coder: NSCoder) {
        renderer = DICOMCanvasImageRenderer.shared
        super.init(coder: coder)
        configureAccessibility()
    }

    deinit {
        renderTask?.cancel()
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    @discardableResult
    func updateDisplay(
        image: DICOMSliceImage?,
        zoomScale: Double,
        panOffset: DICOMViewerOffset
    ) -> Bool {
        let next = DisplayState(
            renderID: image?.renderID,
            zoomScale: zoomScale,
            panOffset: panOffset
        )
        let renderedImageChanged = next.renderID != displayState.renderID
        self.zoomScale = zoomScale
        self.panOffset = panOffset
        guard next != displayState else { return false }
        if renderedImageChanged {
            renderTask?.cancel()
            renderGeneration &+= 1
            canvasImage = nil
            renderedImageID = nil
        }
        displayState = next
        needsDisplay = true
        if renderedImageChanged, let image {
            prepareImage(image, generation: renderGeneration)
        }
        return true
    }

    func waitForPendingRender() async {
        await renderTask?.value
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        dirtyRect.fill()
        guard let canvasImage,
              let context = NSGraphicsContext.current?.cgContext else { return }

        context.interpolationQuality = .none
        context.draw(
            canvasImage,
            in: imageRect(rows: canvasImage.height, columns: canvasImage.width)
        )
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func mouseDragged(with event: NSEvent) {
        handleDrag(deltaX: event.deltaX, deltaY: event.deltaY, panning: spaceIsPressed)
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func rightMouseDragged(with event: NSEvent) {
        handleDrag(deltaX: event.deltaX, deltaY: event.deltaY, panning: true)
    }

    override func magnify(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        handleMagnification(event.magnification, at: location)
    }

    override func scrollWheel(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        handleScroll(
            deltaY: event.scrollingDeltaY,
            commandIsPressed: event.modifierFlags.contains(.command),
            at: location
        )
    }

    func handleDrag(deltaX: Double, deltaY: Double, panning: Bool) {
        if panning {
            onPan?(deltaX, deltaY)
        } else {
            onWindow?(deltaX * 2, -deltaY * 2)
        }
    }

    func handleMagnification(_ magnification: Double, at location: CGPoint) {
        onZoom?(max(0.1, 1 + magnification), location.x, location.y)
    }

    func handleScroll(
        deltaY: Double,
        commandIsPressed: Bool,
        at location: CGPoint
    ) {
        if commandIsPressed {
            accumulatedScroll = 0
            onZoom?(exp(-deltaY * 0.01), location.x, location.y)
            return
        }
        accumulatedScroll += deltaY
        guard abs(accumulatedScroll) >= 8 else { return }
        onSliceStep?(accumulatedScroll > 0 ? 1 : -1)
        accumulatedScroll = 0
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49:
            spaceIsPressed = true
        case 123:
            onSliceStep?(-1)
        case 124:
            onSliceStep?(1)
        default:
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 {
            spaceIsPressed = false
        } else {
            super.keyUp(with: event)
        }
    }

    override func resignFirstResponder() -> Bool {
        spaceIsPressed = false
        return super.resignFirstResponder()
    }

    private func prepareImage(_ image: DICOMSliceImage, generation: UInt64) {
        let renderer = self.renderer
        renderTask = Task { [weak self] in
            let renderedImage: DICOMCanvasRenderedImage?
            do {
                renderedImage = try await renderer.render(image)
            } catch {
                return
            }
            guard !Task.isCancelled, let renderedImage else { return }
            self?.publish(
                renderedImage,
                expectedRenderID: image.renderID,
                generation: generation
            )
        }
    }

    private func publish(
        _ renderedImage: DICOMCanvasRenderedImage,
        expectedRenderID: UUID,
        generation: UInt64
    ) {
        guard generation == renderGeneration,
              expectedRenderID == displayState.renderID,
              renderedImage.renderID == expectedRenderID else { return }
        canvasImage = renderedImage.image
        renderedImageID = renderedImage.renderID
        needsDisplay = true
    }

    private func imageRect(rows: Int, columns: Int) -> CGRect {
        let availableWidth = max(1, bounds.width)
        let availableHeight = max(1, bounds.height)
        let fittedScale = min(
            availableWidth / CGFloat(columns),
            availableHeight / CGFloat(rows)
        )
        let displayScale = fittedScale * CGFloat(zoomScale)
        let size = CGSize(
            width: CGFloat(columns) * displayScale,
            height: CGFloat(rows) * displayScale
        )
        return CGRect(
            x: ((availableWidth - size.width) / 2) + CGFloat(panOffset.x),
            y: ((availableHeight - size.height) / 2) + CGFloat(panOffset.y),
            width: size.width,
            height: size.height
        )
    }

    private func configureAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(AppLocalization.string("医学影像切片画布"))
        setAccessibilityHelp(AppLocalization.string("拖动调节窗宽窗位；按住空格或使用辅助拖动平移；滚动切换切片。"))
        setAccessibilityIdentifier("dicom-viewer-canvas")
    }
}
