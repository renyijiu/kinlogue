import CoreGraphics
import Foundation
import ImageIO

/// Carries the immutable decoded thumbnail back to the main actor for AppKit
/// publication without crossing actors with an `NSImage`.
struct BoundedImageThumbnail: Sendable {
    let cgImage: CGImage
}

/// Serializes all production ImageIO work through one process-wide actor.
/// `operation` contains no suspension point, so actor reentrancy cannot overlap
/// decodes; test instances can use the same lane with a controlled operation.
actor BoundedImageThumbnailDecoder {
    typealias Operation = @Sendable (Data, Int) -> BoundedImageThumbnail?

    static let defaultMaximumPixelSize = 4_000
    private static let shared = BoundedImageThumbnailDecoder(operation: decodeSynchronously)

    private let operation: Operation

    init(operation: @escaping Operation) {
        self.operation = operation
    }

    static func decode(
        data: Data,
        maximumPixelSize: Int = defaultMaximumPixelSize
    ) async -> BoundedImageThumbnail? {
        await shared.decode(data: data, maximumPixelSize: maximumPixelSize)
    }

    func decode(data: Data, maximumPixelSize: Int) -> BoundedImageThumbnail? {
        guard maximumPixelSize > 0, !Task.isCancelled else { return nil }
        let thumbnail = operation(data, maximumPixelSize)
        return Task.isCancelled ? nil : thumbnail
    }

    private static func decodeSynchronously(
        data: Data,
        maximumPixelSize: Int
    ) -> BoundedImageThumbnail? {
        guard !Task.isCancelled,
              let source = CGImageSourceCreateWithData(
                  data as CFData,
                  [kCGImageSourceShouldCache: false] as CFDictionary
              ) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard !Task.isCancelled,
              let image = CGImageSourceCreateThumbnailAtIndex(
                  source,
                  0,
                  options as CFDictionary
              ),
              !Task.isCancelled else {
            return nil
        }
        return BoundedImageThumbnail(cgImage: image)
    }
}
