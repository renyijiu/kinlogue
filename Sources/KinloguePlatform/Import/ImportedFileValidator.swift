import CryptoKit
import Darwin
import Foundation
import ImageIO
import KinlogueCore
import PDFKit
import UniformTypeIdentifiers

public struct ImportValidationLimits: Equatable, Sendable {
    public let maximumFileBytes: Int
    public let maximumPDFPages: Int
    public let maximumRasterEdge: Int
    public let maximumRasterPixels: Int
    public let maximumPDFBoxEdge: CGFloat

    public init(
        maximumFileBytes: Int = 100 * 1024 * 1024,
        maximumPDFPages: Int = 200,
        maximumRasterEdge: Int = 20_000,
        maximumRasterPixels: Int = 120_000_000,
        maximumPDFBoxEdge: CGFloat = 14_400
    ) {
        self.maximumFileBytes = maximumFileBytes
        self.maximumPDFPages = maximumPDFPages
        self.maximumRasterEdge = maximumRasterEdge
        self.maximumRasterPixels = maximumRasterPixels
        self.maximumPDFBoxEdge = maximumPDFBoxEdge
    }
}

public enum ImportedFileValidationError: Error, Equatable, Sendable {
    case fileTooLarge
    case unsupportedType
    case unreadableFile
    case lockedPDF
    case pdfPageCountExceeded
    case pdfMediaBoxExceeded
    case rasterDimensionsExceeded
    case rasterPixelCountExceeded
    case animatedOrMultipageImage
}

public struct ImportedFileValidator: Sendable {
    public let limits: ImportValidationLimits

    public init(limits: ImportValidationLimits = ImportValidationLimits()) {
        self.limits = limits
    }

    /// The caller must retain security-scoped access and any file coordination for this call.
    public func validate(fileAt url: URL) throws -> ValidatedImportedFile {
        guard url.isFileURL else {
            throw ImportedFileValidationError.unreadableFile
        }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw ImportedFileValidationError.unreadableFile }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_size >= 0 else {
            throw ImportedFileValidationError.unreadableFile
        }
        guard metadata.st_size <= limits.maximumFileBytes else {
            throw ImportedFileValidationError.fileTooLarge
        }
        let data: Data
        do {
            data = try handle.read(upToCount: limits.maximumFileBytes + 1) ?? Data()
        } catch { throw ImportedFileValidationError.unreadableFile }
        guard data.count <= limits.maximumFileBytes else {
            throw ImportedFileValidationError.fileTooLarge
        }
        return try validate(data: data)
    }

    /// Validates bytes already copied while the caller owns any required security scope.
    public func validate(data: Data) throws -> ValidatedImportedFile {
        guard data.count <= limits.maximumFileBytes else {
            throw ImportedFileValidationError.fileTooLarge
        }
        guard !data.isEmpty else { throw ImportedFileValidationError.unreadableFile }

        if isPDF(data) {
            return try validatePDF(data)
        }
        return try validateImage(data)
    }

    private func validatePDF(_ data: Data) throws -> ValidatedImportedFile {
        guard let document = PDFDocument(data: data) else {
            throw ImportedFileValidationError.unreadableFile
        }
        guard !document.isLocked else { throw ImportedFileValidationError.lockedPDF }
        guard document.pageCount > 0 else { throw ImportedFileValidationError.unreadableFile }
        guard document.pageCount <= limits.maximumPDFPages else {
            throw ImportedFileValidationError.pdfPageCountExceeded
        }
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else {
                throw ImportedFileValidationError.unreadableFile
            }
            let box = page.bounds(for: .mediaBox)
            let values = [box.minX, box.minY, box.width, box.height]
            guard values.allSatisfy(\.isFinite),
                  box.width > 0,
                  box.height > 0,
                  box.width <= limits.maximumPDFBoxEdge,
                  box.height <= limits.maximumPDFBoxEdge else {
                throw ImportedFileValidationError.pdfMediaBoxExceeded
            }
        }
        return try validated(data: data, kind: .pdf, type: .pdf, pageCount: document.pageCount)
    }

    private func validateImage(_ data: Data) throws -> ValidatedImportedFile {
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ), let actualIdentifier = CGImageSourceGetType(source) as String?,
           let actualType = UTType(actualIdentifier) else {
            throw ImportedFileValidationError.unsupportedType
        }
        let supportedTypes: [UTType] = [.jpeg, .png, .heic, .tiff]
        guard supportedTypes.contains(where: { actualType.conforms(to: $0) }) else {
            throw ImportedFileValidationError.unsupportedType
        }
        guard CGImageSourceGetCount(source) == 1 else {
            throw ImportedFileValidationError.animatedOrMultipageImage
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(
            source,
            0,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0,
              height > 0 else {
            throw ImportedFileValidationError.unreadableFile
        }
        guard width <= limits.maximumRasterEdge, height <= limits.maximumRasterEdge else {
            throw ImportedFileValidationError.rasterDimensionsExceeded
        }
        guard width <= limits.maximumRasterPixels / height else {
            throw ImportedFileValidationError.rasterPixelCountExceeded
        }
        let probeOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 64,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            probeOptions as CFDictionary
        ) != nil else {
            throw ImportedFileValidationError.unreadableFile
        }
        return try validated(data: data, kind: .image, type: actualType, pageCount: 1)
    }

    private func validated(
        data: Data,
        kind: ImportedContentKind,
        type: UTType,
        pageCount: Int
    ) throws -> ValidatedImportedFile {
        try ValidatedImportedFile(
            data: data,
            kind: kind,
            contentTypeIdentifier: type.identifier,
            sha256Digest: Data(SHA256.hash(data: data)),
            pageCount: pageCount
        )
    }

    private func isPDF(_ data: Data) -> Bool {
        let prefix = data.prefix(min(data.count, 1_024))
        return prefix.range(of: Data("%PDF-".utf8)) != nil
    }
}
