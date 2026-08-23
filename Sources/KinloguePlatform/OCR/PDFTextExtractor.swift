import CoreGraphics
import Foundation
import KinlogueCore
import PDFKit

public actor PDFTextExtractor: TextExtractionService {
    private let maximumPageCount: Int
    private let maximumMediaBoxEdge: CGFloat
    private let maximumRenderEdge: Int
    private let outputLimits: TextExtractionOutputLimits

    public init(
        maximumPageCount: Int = 200,
        maximumMediaBoxEdge: CGFloat = 14_400,
        maximumRenderEdge: Int = 2_400
    ) {
        self.maximumPageCount = maximumPageCount
        self.maximumMediaBoxEdge = maximumMediaBoxEdge
        self.maximumRenderEdge = maximumRenderEdge
        self.outputLimits = .standard
    }

    init(
        maximumPageCount: Int = 200,
        maximumMediaBoxEdge: CGFloat = 14_400,
        maximumRenderEdge: Int = 2_400,
        outputLimits: TextExtractionOutputLimits
    ) {
        self.maximumPageCount = maximumPageCount
        self.maximumMediaBoxEdge = maximumMediaBoxEdge
        self.maximumRenderEdge = maximumRenderEdge
        self.outputLimits = outputLimits
    }

    public func extractText(from file: ValidatedImportedFile) async throws -> [OCRBlock] {
        guard file.kind == .pdf else { throw TextExtractionError.unsupportedContent }
        return try Self.extractSynchronously(
            data: file.data,
            maximumPageCount: maximumPageCount,
            maximumMediaBoxEdge: maximumMediaBoxEdge,
            maximumRenderEdge: maximumRenderEdge,
            outputLimits: outputLimits
        )
    }

    private static func extractSynchronously(
        data: Data,
        maximumPageCount: Int,
        maximumMediaBoxEdge: CGFloat,
        maximumRenderEdge: Int,
        outputLimits: TextExtractionOutputLimits
    ) throws -> [OCRBlock] {
        guard let document = PDFDocument(data: data) else {
            throw TextExtractionError.unreadablePDF
        }
        guard !document.isLocked else { throw TextExtractionError.lockedPDF }
        guard document.pageCount > 0, document.pageCount <= maximumPageCount else {
            throw TextExtractionError.resourceLimitExceeded
        }

        var blocks: [OCRBlock] = []
        var outputBudget = TextExtractionOutputBudget(limits: outputLimits)
        var visionLanguageAttempts: [[String]]?
        for pageIndex in 0..<document.pageCount {
            try Task.checkCancellation()
            let pageBlocks = try autoreleasepool { () throws -> [OCRBlock] in
                guard let page = document.page(at: pageIndex) else {
                    throw TextExtractionError.unreadablePDF
                }
                let box = page.bounds(for: .mediaBox)
                guard box.width.isFinite,
                      box.height.isFinite,
                      box.width > 0,
                      box.height > 0,
                      box.width <= maximumMediaBoxEdge,
                      box.height <= maximumMediaBoxEdge else {
                    throw TextExtractionError.resourceLimitExceeded
                }
                if let text = page.string {
                    try outputBudget.validateTextLayerUpperBound(text)
                    if Self.isUsableTextLayer(text) {
                        return try Self.textLayerBlocks(
                            text: text,
                            page: page,
                            pageNumber: pageIndex + 1,
                            validateBlock: { try outputBudget.consume($0) }
                        )
                    }
                }
                let image = try Self.render(page: page, maximumRenderEdge: maximumRenderEdge)
                if visionLanguageAttempts == nil {
                    visionLanguageAttempts = try VisionRecognition.configuredLanguageAttempts()
                }
                return try VisionRecognition.recognize(
                    image,
                    orientation: .up,
                    pageNumber: pageIndex + 1,
                    languageAttempts: visionLanguageAttempts,
                    validateBlock: { try outputBudget.consume($0) }
                )
            }
            blocks.append(contentsOf: pageBlocks)
            try Task.checkCancellation()
        }
        return blocks
    }

    private static func isUsableTextLayer(_ text: String) -> Bool {
        var scalarCount = 0
        var meaningfulCount = 0
        var controlsOrReplacementCount = 0
        for scalar in text.unicodeScalars where !scalar.properties.isWhitespace {
            scalarCount += 1
            if CharacterSet.alphanumerics.contains(scalar)
                || (0x3400...0x9FFF).contains(Int(scalar.value)) {
                meaningfulCount += 1
            }
            if CharacterSet.controlCharacters.contains(scalar) || scalar.value == 0xFFFD {
                controlsOrReplacementCount += 1
            }
        }
        return scalarCount >= 8
            && meaningfulCount >= 8
            && controlsOrReplacementCount * 10 <= scalarCount
    }

    private static func textLayerBlocks(
        text: String,
        page: PDFPage,
        pageNumber: Int,
        validateBlock: (OCRBlock) throws -> Void
    ) throws -> [OCRBlock] {
        let source = text as NSString
        let pageBounds = page.bounds(for: .mediaBox)
        var lineLocation = 0
        var blocks: [OCRBlock] = []
        while lineLocation < source.length {
            var lineStart = 0
            var lineEnd = 0
            var contentEnd = 0
            source.getLineStart(
                &lineStart,
                end: &lineEnd,
                contentsEnd: &contentEnd,
                for: NSRange(location: lineLocation, length: 0)
            )
            guard lineEnd > lineLocation else {
                throw TextExtractionError.unreadablePDF
            }
            lineLocation = lineEnd
            let range = NSRange(location: lineStart, length: contentEnd - lineStart)
            let rawLine = source.substring(with: range)
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let selectedBounds = page.selection(for: range)?.bounds(for: page) ?? pageBounds
            let block = try OCRBlock(
                pageNumber: pageNumber,
                text: line,
                boundingBox: OCRNormalizedRect.projecting(
                    selectedBounds,
                    within: pageBounds
                ),
                confidence: nil,
                method: .pdfTextLayer,
                engineVersion: "pdfkit-text-v1"
            )
            try validateBlock(block)
            blocks.append(block)
        }
        return blocks
    }

    private static func render(page: PDFPage, maximumRenderEdge: Int) throws -> CGImage {
        guard let pageReference = page.pageRef else { throw TextExtractionError.unreadablePDF }
        let sourceBox = pageReference.getBoxRect(.mediaBox)
        guard sourceBox.width > 0, sourceBox.height > 0 else {
            throw TextExtractionError.unreadablePDF
        }
        let scale = min(
            CGFloat(maximumRenderEdge) / max(sourceBox.width, sourceBox.height),
            2
        )
        let width = max(1, Int(ceil(sourceBox.width * scale)))
        let height = max(1, Int(ceil(sourceBox.height * scale)))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw TextExtractionError.resourceLimitExceeded }
        let target = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(target)
        context.concatenate(pageReference.getDrawingTransform(
            .mediaBox,
            rect: target,
            rotate: 0,
            preserveAspectRatio: true
        ))
        context.drawPDFPage(pageReference)
        guard let image = context.makeImage() else {
            throw TextExtractionError.unreadablePDF
        }
        return image
    }
}
