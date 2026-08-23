import AppKit
import Foundation
import Testing
@testable import KinlogueApp

@Suite(.serialized)
@MainActor
struct OriginalDocumentPDFRendererTests {
    @Test
    func opensWithoutTouchingPagesAndLoadsMetadataOnDemand() async throws {
        let pageAccesses = PDFPageAccessRecorder()
        let renderer = OriginalDocumentPDFRenderer(pageAccessObserver: pageAccesses.append)

        let session = try #require(await renderer.open(
            data: OriginalDocumentTestFixture.pdfData(pageCount: 2)
        ))

        #expect(session.pageCount == 2)
        #expect(pageAccesses.values.isEmpty)

        let metadata = try #require(await renderer.pageMetadata(
            sessionID: session.id,
            pageIndex: 1
        ))
        #expect(abs(metadata.mediaBoxSize.width - 612) < 0.001)
        #expect(abs(metadata.mediaBoxSize.height - 792) < 0.001)
        #expect(pageAccesses.values == [1])

        _ = await renderer.pageMetadata(sessionID: session.id, pageIndex: 1)
        #expect(pageAccesses.values == [1])
        #expect(await renderer.pageMetadata(sessionID: session.id, pageIndex: 2) == nil)
        #expect(pageAccesses.values == [1])
    }

    @Test
    func invalidPDFCannotOpen() async {
        let renderer = OriginalDocumentPDFRenderer()

        let session = await renderer.open(data: Data("not a pdf".utf8))

        #expect(session == nil)
    }

    @Test
    func rendersPageToAnImmutableBoundedRaster() async throws {
        let renderer = OriginalDocumentPDFRenderer()
        let session = try #require(await renderer.open(
            data: OriginalDocumentTestFixture.pdfData()
        ))

        let raster = try #require(await renderer.render(
            sessionID: session.id,
            pageIndex: 0,
            renderSize: CGSize(width: 800, height: 1_200)
        ))

        #expect(raster.cgImage.width > 0)
        #expect(raster.cgImage.height > 0)
        #expect(raster.cgImage.width <= 800)
        #expect(raster.cgImage.height <= 1_200)
        let maximumScaleRaster = try #require(await renderer.render(
            sessionID: session.id,
            pageIndex: 0,
            renderSize: CGSize(width: 10_000, height: 10_000)
        ))
        #expect(max(maximumScaleRaster.cgImage.width, maximumScaleRaster.cgImage.height) <= 3_960)
        #expect(await renderer.render(
            sessionID: session.id,
            pageIndex: 1,
            renderSize: CGSize(width: 800, height: 1_200)
        ) == nil)
    }

    @Test
    func releaseDropsTheActorConfinedDocument() async throws {
        let renderer = OriginalDocumentPDFRenderer()
        let session = try #require(await renderer.open(
            data: OriginalDocumentTestFixture.pdfData()
        ))

        await renderer.release(sessionID: session.id)

        #expect(await renderer.pageMetadata(sessionID: session.id, pageIndex: 0) == nil)
        #expect(await renderer.render(
            sessionID: session.id,
            pageIndex: 0,
            renderSize: CGSize(width: 80, height: 120)
        ) == nil)
    }

    @Test
    func cancellationBeforeOpenOrRenderPublishesNothing() async throws {
        let data = try OriginalDocumentTestFixture.pdfData()
        let renderer = OriginalDocumentPDFRenderer()
        let cancelledOpen = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await renderer.open(data: data)
        }
        #expect(await cancelledOpen.value == nil)

        let session = try #require(await renderer.open(data: data))
        let cancelledMetadata = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await renderer.pageMetadata(sessionID: session.id, pageIndex: 0)
        }
        #expect(await cancelledMetadata.value == nil)
        let cancelledRender = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await renderer.render(
                sessionID: session.id,
                pageIndex: 0,
                renderSize: CGSize(width: 80, height: 120)
            )
        }
        #expect(await cancelledRender.value == nil)
    }

    @Test
    func renderSizeKeepsTheExistingScaleAndPixelLimits() {
        #expect(OriginalDocumentPDFLayout.renderSize(
            pageSize: CGSize(width: 100, height: 200),
            zoom: 1
        ) == CGSize(width: 500, height: 1_000))
        #expect(OriginalDocumentPDFLayout.renderSize(
            pageSize: CGSize(width: 10_000, height: 20_000),
            zoom: 10
        ) == CGSize(width: 2_000, height: 4_000))
        #expect(OriginalDocumentPDFLayout.renderSize(
            pageSize: .zero,
            zoom: 1
        ) == .zero)
    }
}

private final class PDFPageAccessRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var pageIndices: [Int] = []

    var values: [Int] {
        lock.withLock { pageIndices }
    }

    func append(_ pageIndex: Int) {
        lock.withLock { pageIndices.append(pageIndex) }
    }
}
