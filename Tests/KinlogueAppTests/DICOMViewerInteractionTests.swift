import AppKit
import Foundation
import Testing
@testable import KinlogueApp
@testable import KinloguePlatform

@MainActor
struct DICOMViewerInteractionTests {
    @Test
    func canvasMapsWindowPanZoomAndSliceInputsWithoutAmbiguity() throws {
        let canvas = DICOMImageCanvasView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        var windowDeltas: [(Double, Double)] = []
        var panDeltas: [(Double, Double)] = []
        var zooms: [(Double, Double, Double)] = []
        var sliceSteps: [Int] = []
        canvas.onWindow = { windowDeltas.append(($0, $1)) }
        canvas.onPan = { panDeltas.append(($0, $1)) }
        canvas.onZoom = { zooms.append(($0, $1, $2)) }
        canvas.onSliceStep = { sliceSteps.append($0) }

        canvas.handleDrag(deltaX: 5, deltaY: -3, panning: false)
        canvas.handleDrag(deltaX: 5, deltaY: -3, panning: true)
        canvas.handleMagnification(0.25, at: CGPoint(x: 120, y: 90))
        canvas.handleScroll(deltaY: 4, commandIsPressed: false, at: .zero)
        canvas.handleScroll(deltaY: 4, commandIsPressed: false, at: .zero)
        canvas.handleScroll(deltaY: -10, commandIsPressed: false, at: .zero)
        canvas.handleScroll(
            deltaY: -20,
            commandIsPressed: true,
            at: CGPoint(x: 20, y: 30)
        )

        #expect(windowDeltas.count == 1)
        #expect(windowDeltas[0].0 == 10)
        #expect(windowDeltas[0].1 == 6)
        #expect(panDeltas.count == 1)
        #expect(panDeltas[0].0 == 5)
        #expect(panDeltas[0].1 == -3)
        #expect(zooms.count == 2)
        #expect(zooms[0].0 == 1.25)
        #expect(zooms[0].1 == 120)
        #expect(zooms[0].2 == 90)
        #expect(zooms[1].0 > 1)
        #expect(zooms[1].1 == 20)
        #expect(zooms[1].2 == 30)
        #expect(sliceSteps == [1, -1])
        #expect(canvas.accessibilityIdentifier() == "dicom-viewer-canvas")
        #expect(canvas.accessibilityRole() == .image)
        #expect(try #require(canvas.accessibilityLabel()).isEmpty == false)
    }

    @Test
    func mainThreadPanAndZoomStateUpdatesStayWithinTheInputBudget() async throws {
        let study = dicomSummary(state: .confirmed)
        let model = DICOMStudyViewerModel(
            studyID: study.id,
            metadataService: DICOMAppServiceSpy(),
            sliceService: UnavailableDICOMSliceService()
        )
        let clock = ContinuousClock()
        var durations: [Duration] = []
        durations.reserveCapacity(600)

        for index in 0..<600 {
            let start = clock.now
            model.pan(horizontal: 0.5, vertical: -0.25)
            model.zoom(
                by: index.isMultiple(of: 2) ? 1.001 : 0.999,
                anchorX: 100,
                anchorY: 80
            )
            durations.append(start.duration(to: clock.now))
        }

        let p95 = durations.sorted()[Int(Double(durations.count - 1) * 0.95)]
        #expect(p95 < .milliseconds(8))
        #expect(model.zoomScale.isFinite)
        #expect(model.panOffset.x.isFinite)
        #expect(model.panOffset.y.isFinite)
    }

    @Test
    func canvasDrawsRowsInPersistedTopToBottomOrder() async throws {
        let canvas = DICOMImageCanvasView(frame: NSRect(x: 0, y: 0, width: 2, height: 2))
        let image = DICOMSliceImage(
            instanceID: UUID(),
            rows: 2,
            columns: 2,
            windowCenter: 128,
            windowWidth: 256,
            pixels: DICOMSlicePixelBuffer(bytes: Data([0, 64, 128, 255]))
        )
        #expect(canvas.updateDisplay(image: image, zoomScale: 1, panOffset: .zero))
        await canvas.waitForPendingRender()
        let representation = try #require(
            canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds)
        )
        canvas.cacheDisplay(in: canvas.bounds, to: representation)

        let leftX = representation.pixelsWide / 4
        let rightX = representation.pixelsWide * 3 / 4
        let bottomY = representation.pixelsHigh / 4
        let topY = representation.pixelsHigh * 3 / 4
        let topLeft = try grayscale(representation, x: leftX, y: topY)
        let topRight = try grayscale(representation, x: rightX, y: topY)
        let bottomLeft = try grayscale(representation, x: leftX, y: bottomY)
        let bottomRight = try grayscale(representation, x: rightX, y: bottomY)
        #expect(topLeft.whiteComponent < topRight.whiteComponent)
        #expect(topRight.whiteComponent < bottomLeft.whiteComponent)
        #expect(bottomLeft.whiteComponent < bottomRight.whiteComponent)
    }

    @Test
    func canvasImageOwnsPixelsAfterSliceBufferIsInvalidated() async throws {
        let originalPixels = Data([0, 64, 128, 255])
        let pixelBuffer = DICOMSlicePixelBuffer(bytes: originalPixels)
        let slice = DICOMSliceImage(
            instanceID: UUID(),
            rows: 2,
            columns: 2,
            windowCenter: 128,
            windowWidth: 256,
            pixels: pixelBuffer
        )

        let rendered = try #require(
            try await DICOMCanvasImageRenderer().render(slice)
        )
        pixelBuffer.invalidate()

        let retainedPixels = try #require(rendered.image.dataProvider?.data)
        #expect(retainedPixels as Data == originalPixels)
    }

    @Test
    func canvasInvalidatesOnlyWhenTheRenderedImageOrTransformChanges() async {
        let renderer = RecordingDICOMCanvasRenderer()
        let canvas = DICOMImageCanvasView(
            frame: NSRect(x: 0, y: 0, width: 2, height: 2),
            renderer: renderer
        )
        let image = DICOMSliceImage(
            instanceID: UUID(),
            rows: 2,
            columns: 2,
            windowCenter: 128,
            windowWidth: 256,
            pixels: DICOMSlicePixelBuffer(bytes: Data([0, 64, 128, 255]))
        )
        #expect(canvas.updateDisplay(image: image, zoomScale: 1, panOffset: .zero))
        await canvas.waitForPendingRender()
        #expect(await renderer.renderCount == 1)
        #expect(!canvas.updateDisplay(image: image, zoomScale: 1, panOffset: .zero))
        #expect(canvas.updateDisplay(image: image, zoomScale: 2, panOffset: .zero))
        await canvas.waitForPendingRender()
        #expect(await renderer.renderCount == 1)
        #expect(canvas.renderedImageID == image.renderID)
    }

    @Test
    func lateRenderCannotReplaceANewerRenderedImage() async throws {
        let renderer = SuspendedDICOMCanvasRenderer()
        let canvas = DICOMImageCanvasView(
            frame: NSRect(x: 0, y: 0, width: 2, height: 2),
            renderer: renderer
        )
        let first = slice(pixels: [0, 16, 32, 48])
        let second = slice(pixels: [64, 96, 128, 255])

        #expect(canvas.updateDisplay(image: first, zoomScale: 1, panOffset: .zero))
        await waitForRequest(first.renderID, in: renderer)
        #expect(canvas.updateDisplay(image: second, zoomScale: 1, panOffset: .zero))
        await waitForRequest(second.renderID, in: renderer)

        await renderer.resume(second.renderID)
        await waitForRenderedImage(second.renderID, in: canvas)
        await renderer.resume(first.renderID)
        for _ in 0..<10 { await Task.yield() }

        #expect(canvas.renderedImageID == second.renderID)
    }

    @Test
    func lateRenderCannotRepopulateAClearedCanvas() async {
        let renderer = SuspendedDICOMCanvasRenderer()
        let canvas = DICOMImageCanvasView(
            frame: NSRect(x: 0, y: 0, width: 2, height: 2),
            renderer: renderer
        )
        let image = slice(pixels: [0, 64, 128, 255])

        #expect(canvas.updateDisplay(image: image, zoomScale: 1, panOffset: .zero))
        await waitForRequest(image.renderID, in: renderer)
        #expect(canvas.updateDisplay(image: nil, zoomScale: 1, panOffset: .zero))
        await renderer.resume(image.renderID)
        for _ in 0..<10 { await Task.yield() }

        #expect(canvas.renderedImageID == nil)
    }

    private func slice(pixels: [UInt8]) -> DICOMSliceImage {
        DICOMSliceImage(
            instanceID: UUID(),
            rows: 2,
            columns: 2,
            windowCenter: 128,
            windowWidth: 256,
            pixels: DICOMSlicePixelBuffer(bytes: Data(pixels))
        )
    }

    private func waitForRequest(
        _ renderID: UUID,
        in renderer: SuspendedDICOMCanvasRenderer
    ) async {
        for _ in 0..<100 {
            if await renderer.hasRequest(renderID) { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for canvas render request")
    }

    private func waitForRenderedImage(
        _ renderID: UUID,
        in canvas: DICOMImageCanvasView
    ) async {
        for _ in 0..<100 {
            if canvas.renderedImageID == renderID { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for canvas image publication")
    }

    private func grayscale(
        _ representation: NSBitmapImageRep,
        x: Int,
        y: Int
    ) throws -> NSColor {
        let color = try #require(representation.colorAt(x: x, y: y))
        return try #require(color.usingColorSpace(.deviceGray))
    }
}

private actor RecordingDICOMCanvasRenderer: DICOMCanvasRendering {
    private(set) var renderCount = 0

    func render(_ slice: DICOMSliceImage) throws -> DICOMCanvasRenderedImage? {
        renderCount += 1
        return try DICOMCanvasImageFactory.makeRenderedImage(from: slice)
    }
}

private actor SuspendedDICOMCanvasRenderer: DICOMCanvasRendering {
    private var continuations: [UUID: CheckedContinuation<Void, Never>] = [:]

    func render(_ slice: DICOMSliceImage) async throws -> DICOMCanvasRenderedImage? {
        await withCheckedContinuation { continuation in
            continuations[slice.renderID] = continuation
        }
        return try DICOMCanvasImageFactory.makeRenderedImage(from: slice)
    }

    func hasRequest(_ renderID: UUID) -> Bool {
        continuations[renderID] != nil
    }

    func resume(_ renderID: UUID) {
        continuations.removeValue(forKey: renderID)?.resume()
    }
}
