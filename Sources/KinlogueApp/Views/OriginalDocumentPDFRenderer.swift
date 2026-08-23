import AppKit
import CoreGraphics
import Foundation
import PDFKit

struct OriginalDocumentPDFPageMetadata: Equatable, Sendable {
    let mediaBoxSize: CGSize
}

struct OriginalDocumentPDFSession: Equatable, Sendable {
    let id: UUID
    let pageCount: Int
}

struct OriginalDocumentPDFRaster: Sendable {
    let cgImage: CGImage
}

enum OriginalDocumentPDFLayout {
    static let maximumRenderEdge: CGFloat = 4_000
    private static let baseRenderEdge: CGFloat = 1_600
    private static let maximumPageScale: CGFloat = 5

    static func renderSize(pageSize: CGSize, zoom: Double) -> CGSize {
        guard pageSize.width.isFinite,
              pageSize.height.isFinite,
              zoom.isFinite,
              pageSize.width > 0,
              pageSize.height > 0,
              zoom > 0 else {
            return .zero
        }
        let longestEdge = max(pageSize.width, pageSize.height)
        let targetEdge = min(maximumRenderEdge, baseRenderEdge * zoom)
        let scale = min(targetEdge / longestEdge, maximumPageScale)
        guard scale.isFinite, scale > 0 else { return .zero }
        return CGSize(width: pageSize.width * scale, height: pageSize.height * scale)
    }

    static func boundedRenderSize(_ requestedSize: CGSize, pageSize: CGSize) -> CGSize {
        guard requestedSize.width.isFinite,
              requestedSize.height.isFinite,
              pageSize.width.isFinite,
              pageSize.height.isFinite,
              requestedSize.width > 0,
              requestedSize.height > 0,
              pageSize.width > 0,
              pageSize.height > 0 else {
            return .zero
        }
        let longestEdge = max(requestedSize.width, requestedSize.height)
        let maximumAllowedEdge = min(
            maximumRenderEdge,
            max(pageSize.width, pageSize.height) * maximumPageScale
        )
        let scale = min(1, maximumAllowedEdge / longestEdge)
        guard scale.isFinite, scale > 0 else { return .zero }
        return CGSize(
            width: max(1, requestedSize.width * scale),
            height: max(1, requestedSize.height * scale)
        )
    }
}

/// Keeps every PDFKit object inside one serial actor. Callers receive only
/// immutable metadata and Core Graphics rasters, never `PDFDocument`, `PDFPage`
/// or `NSImage` instances.
actor OriginalDocumentPDFRenderer {
    private static let shared = OriginalDocumentPDFRenderer()
    private static let maximumCachedPageMetadataCount = 200

    private struct StoredDocument {
        let document: PDFDocument
        var pageMetadata: [Int: OriginalDocumentPDFPageMetadata] = [:]
    }

    private var documents: [UUID: StoredDocument] = [:]
    private let pageAccessObserver: @Sendable (Int) -> Void

    init(pageAccessObserver: @escaping @Sendable (Int) -> Void = { _ in }) {
        self.pageAccessObserver = pageAccessObserver
    }

    static func open(data: Data) async -> OriginalDocumentPDFSession? {
        await shared.open(data: data)
    }

    static func render(
        sessionID: UUID,
        pageIndex: Int,
        renderSize: CGSize
    ) async -> OriginalDocumentPDFRaster? {
        await shared.render(
            sessionID: sessionID,
            pageIndex: pageIndex,
            renderSize: renderSize
        )
    }

    static func pageMetadata(
        sessionID: UUID,
        pageIndex: Int
    ) async -> OriginalDocumentPDFPageMetadata? {
        await shared.pageMetadata(sessionID: sessionID, pageIndex: pageIndex)
    }

    static func release(sessionID: UUID) async {
        await shared.release(sessionID: sessionID)
    }

    func open(data: Data) -> OriginalDocumentPDFSession? {
        guard !Task.isCancelled,
              let document = PDFDocument(data: data),
              document.pageCount > 0,
              !document.isLocked else {
            return nil
        }
        guard !Task.isCancelled else { return nil }
        let id = UUID()
        documents[id] = StoredDocument(document: document)
        return OriginalDocumentPDFSession(id: id, pageCount: document.pageCount)
    }

    func pageMetadata(
        sessionID: UUID,
        pageIndex: Int
    ) -> OriginalDocumentPDFPageMetadata? {
        guard !Task.isCancelled,
              var stored = documents[sessionID],
              pageIndex >= 0,
              pageIndex < stored.document.pageCount else {
            return nil
        }
        if let cached = stored.pageMetadata[pageIndex] { return cached }
        guard let page = page(in: stored.document, at: pageIndex),
              let metadata = Self.metadata(for: page),
              !Task.isCancelled else {
            return nil
        }
        if stored.pageMetadata.count < Self.maximumCachedPageMetadataCount {
            stored.pageMetadata[pageIndex] = metadata
            documents[sessionID] = stored
        }
        return metadata
    }

    func render(
        sessionID: UUID,
        pageIndex: Int,
        renderSize: CGSize
    ) -> OriginalDocumentPDFRaster? {
        guard !Task.isCancelled,
              let document = documents[sessionID]?.document,
              pageIndex >= 0,
              pageIndex < document.pageCount,
              let page = page(in: document, at: pageIndex),
              let metadata = Self.metadata(for: page) else {
            return nil
        }
        let boundedSize = OriginalDocumentPDFLayout.boundedRenderSize(
            renderSize,
            pageSize: metadata.mediaBoxSize
        )
        guard boundedSize != .zero else { return nil }
        let thumbnail = page.thumbnail(of: boundedSize, for: .mediaBox)
        guard !Task.isCancelled else { return nil }
        var proposedRect = CGRect(origin: .zero, size: thumbnail.size)
        guard let cgImage = thumbnail.cgImage(
            forProposedRect: &proposedRect,
            context: nil,
            hints: nil
        ), !Task.isCancelled else {
            return nil
        }
        return OriginalDocumentPDFRaster(cgImage: cgImage)
    }

    func release(sessionID: UUID) {
        documents.removeValue(forKey: sessionID)
    }

    private func page(in document: PDFDocument, at index: Int) -> PDFPage? {
        pageAccessObserver(index)
        return document.page(at: index)
    }

    private static func metadata(for page: PDFPage) -> OriginalDocumentPDFPageMetadata? {
        let size = page.bounds(for: .mediaBox).standardized.size
        guard size.width.isFinite,
              size.height.isFinite,
              size.width > 0,
              size.height > 0 else {
            return nil
        }
        return OriginalDocumentPDFPageMetadata(mediaBoxSize: size)
    }
}
