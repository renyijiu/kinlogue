import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import KinlogueCore
@testable import KinloguePlatform

private enum SyntheticFixtureError: Error {
    case bitmapContext
    case bitmapImage
    case imageDestination
    case pdfConsumer
    case pdfContext
}

@Suite
struct OCRNormalizedRectTests {
    @Test
    func projectsAndClampsPageCoordinates() throws {
        let normalized = try OCRNormalizedRect.projecting(
            CGRect(x: -5, y: 5, width: 20, height: 20),
            within: CGRect(x: 0, y: 0, width: 10, height: 10)
        )
        let expected = try NormalizedRect(x: 0, y: 0.5, width: 1, height: 0.5)

        #expect(normalized == expected)
    }

    @Test
    func preservesCoordinatesAlreadyInTheUnitRectangle() throws {
        let normalized = try OCRNormalizedRect.projecting(
            CGRect(x: 0.25, y: 0.5, width: 0.25, height: 0.25),
            within: OCRNormalizedRect.unitBounds
        )
        let expected = try NormalizedRect(x: 0.25, y: 0.5, width: 0.25, height: 0.25)

        #expect(normalized == expected)
    }
}

@Suite(.serialized)
struct AppleDocumentIntegrationTests {
    @Test
    func visionLanguageAttemptsPreservePreferredAndDefaultFallbackOrder() {
        #expect(VisionRecognition.languageAttempts(
            supportedLanguages: ["fr-FR", "en-US", "zh-Hans"]
        ) == [
            ["zh-Hans", "en-US"],
            ["zh-Hans"],
            ["en-US"],
            [],
        ])
        #expect(VisionRecognition.languageAttempts(
            supportedLanguages: ["fr-FR"]
        ) == [[]])
    }

    @Test
    func visionRecognizesAProgrammaticallyGeneratedASCIIAnchor() async throws {
        let data = try syntheticTextPNG("SYNTHETIC ANCHOR")
        let file = try ImportedFileValidator().validate(data: data)
        guard let blocks = try await visionBlocks(using: VisionTextRecognizer(), from: file) else {
            return
        }
        #expect(blocks.contains { normalized($0.text).contains("SYNTHETIC") })
        #expect(blocks.allSatisfy { $0.method == .vision && $0.pageNumber == 1 })
        #expect(blocks.allSatisfy { (0...1).contains($0.boundingBox.x) })
    }

    @Test
    func visionRecognizerAcceptsImageTextWithinInjectedOutputLimits() async throws {
        let data = try syntheticTextPNG("SYNTHETIC ANCHOR")
        let file = try ImportedFileValidator().validate(data: data)
        let extractor = VisionTextRecognizer(outputLimits: .init(
            maximumBlockCount: 4,
            maximumBlockUTF8ByteCount: 64,
            maximumTotalTextUTF8ByteCount: 128
        ))

        guard let blocks = try await visionBlocks(using: extractor, from: file) else { return }

        #expect(blocks.contains { normalized($0.text).contains("SYNTHETIC") })
        #expect(blocks.allSatisfy { $0.method == .vision && $0.pageNumber == 1 })
    }

    @Test
    func visionRecognizerRejectsABlockOverTheUTF8ByteLimit() async throws {
        let data = try syntheticTextPNG("SYNTHETIC ANCHOR")
        let file = try ImportedFileValidator().validate(data: data)
        let extractor = VisionTextRecognizer(outputLimits: .init(
            maximumBlockCount: 4,
            maximumBlockUTF8ByteCount: 1,
            maximumTotalTextUTF8ByteCount: 128
        ))

        do {
            guard try await visionBlocks(using: extractor, from: file) != nil else { return }
            Issue.record("Expected the Vision block to exceed its UTF-8 byte limit")
        } catch TextExtractionError.resourceLimitExceeded {
            // Expected.
        }
    }

    @Test
    func visionRecognizerRejectsCumulativeTextOverTheUTF8ByteLimit() async throws {
        let data = try syntheticTextPNG("SYNTHETIC ANCHOR")
        let file = try ImportedFileValidator().validate(data: data)
        let extractor = VisionTextRecognizer(outputLimits: .init(
            maximumBlockCount: 4,
            maximumBlockUTF8ByteCount: 128,
            maximumTotalTextUTF8ByteCount: 1
        ))

        do {
            guard try await visionBlocks(using: extractor, from: file) != nil else { return }
            Issue.record("Expected Vision text to exceed its cumulative UTF-8 byte limit")
        } catch TextExtractionError.resourceLimitExceeded {
            // Expected.
        }
    }

    @Test
    func visionRecognizerRejectsMoreThanTheMaximumBlockCount() async throws {
        let data = try syntheticTextPNG(lines: [
            "FIRST SYNTHETIC ANCHOR",
            "SECOND SYNTHETIC ANCHOR",
            "THIRD SYNTHETIC ANCHOR",
        ])
        let file = try ImportedFileValidator().validate(data: data)
        let baselineExtractor = VisionTextRecognizer(outputLimits: .init(
            maximumBlockCount: 64,
            maximumBlockUTF8ByteCount: 128,
            maximumTotalTextUTF8ByteCount: 512
        ))
        guard let baseline = try await visionBlocks(using: baselineExtractor, from: file) else {
            return
        }
        guard baseline.count > 1 else {
            Issue.record("Expected the separated synthetic lines to produce multiple Vision blocks")
            return
        }
        let extractor = VisionTextRecognizer(outputLimits: .init(
            maximumBlockCount: baseline.count - 1,
            maximumBlockUTF8ByteCount: 128,
            maximumTotalTextUTF8ByteCount: 512
        ))

        do {
            guard try await visionBlocks(using: extractor, from: file) != nil else { return }
            Issue.record("Expected Vision output to exceed its block-count limit")
        } catch TextExtractionError.resourceLimitExceeded {
            // Expected.
        }
    }

    @Test
    func pdfExtractorUsesTextLayerAndVisionPerPageWithoutDuplication() async throws {
        let scan = try syntheticTextImage("SCANNED ANCHOR")
        let data = try syntheticMixedPDF(digitalText: "DIGITAL ANCHOR", scannedImage: scan)
        let file = try ImportedFileValidator().validate(data: data)
        let blocks: [OCRBlock]
        do {
            blocks = try await PDFTextExtractor().extractText(from: file)
        } catch TextExtractionError.visionRequestFailed {
            withKnownIssue(
                "The outer execution sandbox may deny access to the on-device Vision model"
            ) {
                throw TextExtractionError.visionRequestFailed
            }
            return
        }
        let firstPage = blocks.filter { $0.pageNumber == 1 }
        let secondPage = blocks.filter { $0.pageNumber == 2 }
        #expect(firstPage.contains { normalized($0.text).contains("DIGITAL") })
        #expect(firstPage.allSatisfy { $0.method == .pdfTextLayer })
        #expect(secondPage.contains { normalized($0.text).contains("SCANNED") })
        #expect(secondPage.allSatisfy { $0.method == .vision })
    }

    @Test
    func pdfExtractorUsesAUsableTextLayerWithoutInvokingVision() async throws {
        let data = try syntheticDigitalPDF(text: "DIGITAL TEXT ANCHOR")
        let file = try ImportedFileValidator().validate(data: data)

        let blocks = try await PDFTextExtractor().extractText(from: file)

        #expect(blocks.contains { normalized($0.text).contains("DIGITALTEXTANCHOR") })
        #expect(blocks.allSatisfy { $0.method == .pdfTextLayer && $0.pageNumber == 1 })
    }

    @Test
    func pdfExtractorAcceptsTextWithinInjectedOutputLimits() async throws {
        let data = try syntheticDigitalPDF(pages: ["FIRST PAGE ANCHOR", "SECOND PAGE ANCHOR"])
        let file = try ImportedFileValidator().validate(data: data)
        let extractor = PDFTextExtractor(outputLimits: .init(
            maximumBlockCount: 2,
            maximumBlockUTF8ByteCount: 64,
            maximumTotalTextUTF8ByteCount: 128
        ))

        let blocks = try await extractor.extractText(from: file)

        #expect(blocks.count == 2)
        #expect(blocks.map(\.pageNumber) == [1, 2])
        #expect(blocks.allSatisfy { $0.method == .pdfTextLayer })
    }

    @Test
    func pdfExtractorRejectsATextLayerBlockOverTheUTF8ByteLimit() async throws {
        // Eleven visible characters, but twelve UTF-8 bytes because of "É".
        let data = try syntheticDigitalPDF(text: "CAFÉ REPORT")
        let file = try ImportedFileValidator().validate(data: data)
        let extractor = PDFTextExtractor(outputLimits: .init(
            maximumBlockCount: 4,
            maximumBlockUTF8ByteCount: 11,
            maximumTotalTextUTF8ByteCount: 128
        ))

        await #expect(throws: TextExtractionError.resourceLimitExceeded) {
            try await extractor.extractText(from: file)
        }
    }

    @Test
    func pdfExtractorRejectsCumulativeTextOverTheUTF8ByteLimit() async throws {
        let data = try syntheticDigitalPDF(pages: ["FIRST PAGE ANCHOR", "SECOND PAGE ANCHOR"])
        let file = try ImportedFileValidator().validate(data: data)
        let extractor = PDFTextExtractor(outputLimits: .init(
            maximumBlockCount: 4,
            maximumBlockUTF8ByteCount: 64,
            maximumTotalTextUTF8ByteCount: 24
        ))

        await #expect(throws: TextExtractionError.resourceLimitExceeded) {
            try await extractor.extractText(from: file)
        }
    }

    @Test
    func pdfExtractorRejectsMoreThanTheMaximumBlockCount() async throws {
        let data = try syntheticDigitalPDF(pages: ["FIRST PAGE ANCHOR", "SECOND PAGE ANCHOR"])
        let file = try ImportedFileValidator().validate(data: data)
        let extractor = PDFTextExtractor(outputLimits: .init(
            maximumBlockCount: 1,
            maximumBlockUTF8ByteCount: 64,
            maximumTotalTextUTF8ByteCount: 128
        ))

        await #expect(throws: TextExtractionError.resourceLimitExceeded) {
            try await extractor.extractText(from: file)
        }
    }
}

private func normalized(_ value: String) -> String {
    value.uppercased().filter { $0.isLetter || $0.isNumber }
}

private func visionBlocks(
    using extractor: VisionTextRecognizer,
    from file: ValidatedImportedFile
) async throws -> [OCRBlock]? {
    do {
        return try await extractor.extractText(from: file)
    } catch TextExtractionError.visionRequestFailed {
        withKnownIssue(
            "The outer execution sandbox may deny access to the on-device Vision model"
        ) {
            throw TextExtractionError.visionRequestFailed
        }
        return nil
    }
}

private func syntheticTextPNG(_ text: String) throws -> Data {
    let image = try syntheticTextImage(text)
    return try pngData(for: image)
}

private func syntheticTextPNG(lines: [String]) throws -> Data {
    let image = try syntheticTextImage(lines: lines)
    return try pngData(for: image)
}

private func pngData(for image: CGImage) throws -> Data {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        data,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else { throw SyntheticFixtureError.imageDestination }
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

private func syntheticTextImage(_ text: String) throws -> CGImage {
    try syntheticTextImage(lines: [text])
}

private func syntheticTextImage(lines: [String]) throws -> CGImage {
    let width = 1_200
    let height = max(360, lines.count * 180)
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { throw SyntheticFixtureError.bitmapContext }
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    for (index, text) in lines.enumerated() {
        let y = lines.count == 1 ? 130 : height - 140 - index * 160
        let size: CGFloat = lines.count == 1 ? 88 : 72
        drawText(text, in: context, at: CGPoint(x: 50, y: y), size: size)
    }
    guard let image = context.makeImage() else { throw SyntheticFixtureError.bitmapImage }
    return image
}

private func syntheticMixedPDF(digitalText: String, scannedImage: CGImage) throws -> Data {
    let data = NSMutableData()
    guard let consumer = CGDataConsumer(data: data) else {
        throw SyntheticFixtureError.pdfConsumer
    }
    var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
        throw SyntheticFixtureError.pdfContext
    }

    context.beginPDFPage([kCGPDFContextMediaBox as String: mediaBox] as CFDictionary)
    drawText(digitalText, in: context, at: CGPoint(x: 60, y: 650), size: 42)
    context.endPDFPage()

    context.beginPDFPage([kCGPDFContextMediaBox as String: mediaBox] as CFDictionary)
    context.draw(scannedImage, in: CGRect(x: 30, y: 300, width: 552, height: 166))
    context.endPDFPage()
    context.closePDF()
    return data as Data
}

private func syntheticDigitalPDF(text: String) throws -> Data {
    try syntheticDigitalPDF(pages: [text])
}

private func syntheticDigitalPDF(pages: [String]) throws -> Data {
    let data = NSMutableData()
    guard let consumer = CGDataConsumer(data: data) else {
        throw SyntheticFixtureError.pdfConsumer
    }
    var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
        throw SyntheticFixtureError.pdfContext
    }
    for text in pages {
        context.beginPDFPage([kCGPDFContextMediaBox as String: mediaBox] as CFDictionary)
        drawText(text, in: context, at: CGPoint(x: 60, y: 650), size: 42)
        context.endPDFPage()
    }
    context.closePDF()
    return data as Data
}

private func drawText(_ text: String, in context: CGContext, at point: CGPoint, size: CGFloat) {
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
    ]
    let line = CTLineCreateWithAttributedString(
        NSAttributedString(string: text, attributes: attributes)
    )
    context.textPosition = point
    CTLineDraw(line, context)
}
