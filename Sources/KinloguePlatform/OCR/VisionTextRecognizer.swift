import CoreGraphics
import Foundation
import ImageIO
import KinlogueCore
import Vision

public enum TextExtractionError: Error, Equatable, Sendable {
    case unsupportedContent
    case unreadableImage
    case unreadablePDF
    case lockedPDF
    case resourceLimitExceeded
    case visionLanguageConfigurationFailed
    case visionRequestFailed
}

public actor VisionTextRecognizer: TextExtractionService {
    private let outputLimits: TextExtractionOutputLimits

    public init() {
        self.outputLimits = .standard
    }

    init(outputLimits: TextExtractionOutputLimits) {
        self.outputLimits = outputLimits
    }

    public func extractText(from file: ValidatedImportedFile) async throws -> [OCRBlock] {
        guard file.kind == .image else { throw TextExtractionError.unsupportedContent }
        try Task.checkCancellation()
        var outputBudget = TextExtractionOutputBudget(limits: outputLimits)
        return try autoreleasepool {
            guard let source = CGImageSourceCreateWithData(
                file.data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary
            ), CGImageSourceGetCount(source) == 1 else {
                throw TextExtractionError.unreadableImage
            }
            let properties = CGImageSourceCopyPropertiesAtIndex(
                source,
                0,
                [kCGImageSourceShouldCache: false] as CFDictionary
            ) as? [CFString: Any]
            let rawOrientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
            let orientation = CGImagePropertyOrientation(rawValue: rawOrientation) ?? .up
            let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
            let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
            let image: CGImage?
            if max(width, height) <= 2_400 {
                image = CGImageSourceCreateImageAtIndex(
                    source,
                    0,
                    [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
                )
            } else {
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: false,
                    kCGImageSourceThumbnailMaxPixelSize: 2_400,
                    kCGImageSourceShouldCacheImmediately: true,
                ]
                image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            }
            guard let image else { throw TextExtractionError.unreadableImage }
            return try VisionRecognition.recognize(
                image,
                orientation: orientation,
                pageNumber: 1,
                validateBlock: { try outputBudget.consume($0) }
            )
        }
    }
}

enum VisionRecognition {
    static func recognize(
        _ image: CGImage,
        orientation: CGImagePropertyOrientation,
        pageNumber: Int,
        languageAttempts: [[String]]? = nil,
        validateBlock: (OCRBlock) throws -> Void
    ) throws -> [OCRBlock] {
        let languageAttempts = try languageAttempts ?? configuredLanguageAttempts()
        var completedRequest: VNRecognizeTextRequest?
        for languages in languageAttempts {
            let request = configuredRequest(languages: languages)
            let handler = VNImageRequestHandler(
                cgImage: image,
                orientation: orientation,
                options: [:]
            )
            if (try? handler.perform([request])) != nil {
                completedRequest = request
                break
            }
        }
        guard let request = completedRequest else { throw TextExtractionError.visionRequestFailed }
        let observations = (request.results ?? []).sorted(by: observationOrder)
        return try observations.compactMap { observation -> OCRBlock? in
            guard let candidate = observation.topCandidates(1).first,
                  !candidate.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            let block = try OCRBlock(
                pageNumber: pageNumber,
                text: candidate.string,
                boundingBox: OCRNormalizedRect.projecting(
                    observation.boundingBox,
                    within: OCRNormalizedRect.unitBounds
                ),
                confidence: Double(candidate.confidence),
                method: .vision,
                engineVersion: "vision-vnrecognizetext-r3"
            )
            try validateBlock(block)
            return block
        }
    }

    static func configuredLanguageAttempts() throws -> [[String]] {
        let capabilityRequest = configuredRequest(languages: nil)
        let supported: [String]
        do {
            supported = try capabilityRequest.supportedRecognitionLanguages()
        } catch {
            throw TextExtractionError.visionLanguageConfigurationFailed
        }
        return languageAttempts(supportedLanguages: supported)
    }

    static func languageAttempts(supportedLanguages: [String]) -> [[String]] {
        let preferredLanguages = ["zh-Hans", "en-US"].filter(supportedLanguages.contains)
        return preferredLanguages.isEmpty
            ? [[]]
            : [preferredLanguages] + preferredLanguages.map { [$0] } + [[]]
    }

    private static func configuredRequest(languages: [String]?) -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.revision = VNRecognizeTextRequestRevision3
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        if let languages, !languages.isEmpty { request.recognitionLanguages = languages }
        return request
    }

    private static func observationOrder(
        _ left: VNRecognizedTextObservation,
        _ right: VNRecognizedTextObservation
    ) -> Bool {
        if abs(left.boundingBox.minY - right.boundingBox.minY) > 0.01 {
            return left.boundingBox.minY > right.boundingBox.minY
        }
        return left.boundingBox.minX < right.boundingBox.minX
    }

}
