import CoreGraphics
import KinlogueCore

enum OCRNormalizedRect {
    static let unitBounds = CGRect(x: 0, y: 0, width: 1, height: 1)

    static func projecting(
        _ rect: CGRect,
        within bounds: CGRect
    ) throws -> KinlogueCore.NormalizedRect {
        let x = min(max((rect.minX - bounds.minX) / bounds.width, 0), 1)
        let y = min(max((rect.minY - bounds.minY) / bounds.height, 0), 1)
        let maxX = min(max((rect.maxX - bounds.minX) / bounds.width, x), 1)
        let maxY = min(max((rect.maxY - bounds.minY) / bounds.height, y), 1)
        return try KinlogueCore.NormalizedRect(
            x: Double(x),
            y: Double(y),
            width: Double(maxX - x),
            height: Double(maxY - y)
        )
    }
}
