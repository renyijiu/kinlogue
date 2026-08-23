import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers
@testable import KinlogueCore
@testable import KinloguePlatform

extension AppleDocumentIntegrationTests {
    @Test
    func validatorRecognizesImageBytesAndHashesTheOriginal() throws {
        let data = try syntheticPNG(width: 8, height: 6)

        let validated = try ImportedFileValidator().validate(data: data)

        #expect(validated.kind == .image)
        #expect(validated.contentTypeIdentifier == UTType.png.identifier)
        #expect(validated.sha256Digest.count == 32)
        #expect(validated.data == data)
    }

    @Test
    func validatorReadsASelectedURLWhileTheCallerOwnsItsSecurityScope() throws {
        let data = try syntheticPNG(width: 8, height: 6)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinlogue-selected-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url, options: .atomic)

        let validated = try ImportedFileValidator().validate(fileAt: url)

        #expect(validated.data == data)
        #expect(validated.kind == .image)
    }

    @Test
    func validatorRejectsSymbolicLinks() throws {
        let data = try syntheticPNG(width: 8, height: 6)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinlogue-link-\(UUID().uuidString)", isDirectory: true)
        let source = directory.appendingPathComponent("source.png")
        let link = directory.appendingPathComponent("link.png")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try data.write(to: source)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)

        #expect(throws: ImportedFileValidationError.unreadableFile) {
            _ = try ImportedFileValidator().validate(fileAt: link)
        }
    }

    @Test
    func validatorRejectsFileAndRasterResourceLimitsBeforeOCR() throws {
        let data = try syntheticPNG(width: 8, height: 6)

        #expect(throws: ImportedFileValidationError.fileTooLarge) {
            _ = try ImportedFileValidator(
                limits: ImportValidationLimits(maximumFileBytes: data.count - 1)
            ).validate(data: data)
        }
        #expect(throws: ImportedFileValidationError.rasterDimensionsExceeded) {
            _ = try ImportedFileValidator(
                limits: ImportValidationLimits(maximumRasterEdge: 7)
            ).validate(data: data)
        }
        #expect(throws: ImportedFileValidationError.rasterPixelCountExceeded) {
            _ = try ImportedFileValidator(
                limits: ImportValidationLimits(maximumRasterPixels: 47)
            ).validate(data: data)
        }
    }

    @Test
    func validatorRejectsTooManyPagesOversizedBoxesAndLockedPDFs() throws {
        let twoPages = try syntheticPDF(pageCount: 2)
        #expect(throws: ImportedFileValidationError.pdfPageCountExceeded) {
            _ = try ImportedFileValidator(
                limits: ImportValidationLimits(maximumPDFPages: 1)
            ).validate(data: twoPages)
        }

        let oversized = try syntheticPDF(pageCount: 1, pageSize: CGSize(width: 700, height: 700))
        #expect(throws: ImportedFileValidationError.pdfMediaBoxExceeded) {
            _ = try ImportedFileValidator(
                limits: ImportValidationLimits(maximumPDFBoxEdge: 600)
            ).validate(data: oversized)
        }

        let document = try #require(PDFDocument(data: try syntheticPDF(pageCount: 1)))
        let locked = try #require(document.dataRepresentation(options: [
            PDFDocumentWriteOption.ownerPasswordOption: "owner-secret",
            PDFDocumentWriteOption.userPasswordOption: "secret",
        ]))
        #expect(throws: ImportedFileValidationError.lockedPDF) {
            _ = try ImportedFileValidator().validate(data: locked)
        }
    }
}

private func syntheticPNG(width: Int, height: Int) throws -> Data {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = try #require(CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(
        data,
        UTType.png.identifier as CFString,
        1,
        nil
    ))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

private func syntheticPDF(pageCount: Int, pageSize: CGSize = CGSize(width: 612, height: 792)) throws -> Data {
    let data = NSMutableData()
    let consumer = try #require(CGDataConsumer(data: data))
    var mediaBox = CGRect(origin: .zero, size: pageSize)
    let context = try #require(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
    for _ in 0..<pageCount {
        context.beginPDFPage([kCGPDFContextMediaBox as String: mediaBox] as CFDictionary)
        context.endPDFPage()
    }
    context.closePDF()
    return data as Data
}
