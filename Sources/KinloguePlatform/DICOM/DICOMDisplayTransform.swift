import Foundation
import KinlogueCore

enum DICOMDisplayTransformError: Error, Equatable, Sendable {
    case invalidSamples
    case invalidWindow
    case resourceLimit
}

struct DICOMWindow: Equatable, Sendable {
    let center: Double
    let width: Double

    init(center: Double, width: Double) throws {
        guard center.isFinite, width.isFinite, width >= 1 else {
            throw DICOMDisplayTransformError.invalidWindow
        }
        self.center = center
        self.width = width
    }
}

struct DICOMCanonicalSlice: Sendable {
    let rows: Int
    let columns: Int
    private let pixels: DICOMCanonicalPixelBuffer
    let defaultWindow: DICOMWindow
    let photometricInterpretation: DICOMStudyIndex.PhotometricInterpretation

    init(
        rows: Int,
        columns: Int,
        intensities: [Float],
        defaultWindow: DICOMWindow,
        photometricInterpretation: DICOMStudyIndex.PhotometricInterpretation
    ) {
        self.rows = rows
        self.columns = columns
        pixels = DICOMCanonicalPixelBuffer(intensities)
        self.defaultWindow = defaultWindow
        self.photometricInterpretation = photometricInterpretation
    }

    var byteCount: Int { pixels.byteCount }

    func withIntensities<Result>(
        _ operation: (UnsafeBufferPointer<Float>) throws -> Result
    ) rethrows -> Result {
        try pixels.withValues(operation)
    }

    @discardableResult
    func zeroize() -> Int { pixels.zeroize() }
}

// SAFETY: `lock` protects the optional pixel storage across reads and zeroize;
// immutable `byteCount` is initialized before publication.
private final class DICOMCanonicalPixelBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Float]?
    let byteCount: Int

    init(_ values: [Float]) {
        self.values = values
        byteCount = values.count * MemoryLayout<Float>.stride
    }

    func withValues<Result>(
        _ operation: (UnsafeBufferPointer<Float>) throws -> Result
    ) rethrows -> Result {
        try lock.withLock {
            try (values ?? []).withUnsafeBufferPointer(operation)
        }
    }

    func zeroize() -> Int {
        lock.withLock {
            guard values != nil else { return 0 }
            values?.withUnsafeMutableBufferPointer { buffer in
                buffer.initialize(repeating: 0)
            }
            values = nil
            return byteCount
        }
    }

    deinit { _ = zeroize() }
}

struct DICOMRenderedSlice: Equatable, Sendable {
    let rows: Int
    let columns: Int
    let grayscaleBytes: Data
    let window: DICOMWindow
}

/// Pure Kinlogue-owned conversion from native Explicit-VR-LE sample bytes to
/// canonical rescaled intensity and then an 8-bit presentation buffer.
enum DICOMDisplayTransformer {
    private static let maximumCanonicalByteCount = 256 * 1_024 * 1_024

    private struct PresentationWindow {
        let centerOffset: Double
        let denominator: Double
        let lower: Double
        let upper: Double

        init(_ window: DICOMWindow) {
            centerOffset = window.center - 0.5
            denominator = window.width - 1
            lower = centerOffset - denominator / 2
            upper = centerOffset + denominator / 2
        }
    }

    static func canonicalize(
        sampleBytes: Data,
        attributes: DICOMStudyIndex.ImageAttributes
    ) throws -> DICOMCanonicalSlice {
        let pixels = attributes.rows.multipliedReportingOverflow(by: attributes.columns)
        guard !pixels.overflow else { throw DICOMDisplayTransformError.resourceLimit }
        let bytesPerSample = attributes.bitsAllocated / 8
        let expectedBytes = pixels.partialValue.multipliedReportingOverflow(by: bytesPerSample)
        let canonicalBytes = pixels.partialValue.multipliedReportingOverflow(
            by: MemoryLayout<Float>.stride
        )
        guard !expectedBytes.overflow, !canonicalBytes.overflow,
              expectedBytes.partialValue == sampleBytes.count,
              canonicalBytes.partialValue <= maximumCanonicalByteCount else {
            throw expectedBytes.overflow || canonicalBytes.overflow
                ? DICOMDisplayTransformError.resourceLimit
                : DICOMDisplayTransformError.invalidSamples
        }

        let shift = attributes.highBit - attributes.bitsStored + 1
        guard shift >= 0, shift < attributes.bitsAllocated else {
            throw DICOMDisplayTransformError.invalidSamples
        }
        let mask = (UInt32(1) << UInt32(attributes.bitsStored)) - 1
        let signBit = UInt32(1) << UInt32(attributes.bitsStored - 1)
        let signRange = Int64(1) << Int64(attributes.bitsStored)
        var intensities = [Float]()
        intensities.reserveCapacity(pixels.partialValue)

        for offset in stride(from: 0, to: sampleBytes.count, by: bytesPerSample) {
            let container: UInt32
            if bytesPerSample == 1 {
                container = UInt32(sampleBytes[offset])
            } else if bytesPerSample == 2, offset <= sampleBytes.count - 2 {
                container = UInt32(sampleBytes[offset])
                    | UInt32(sampleBytes[offset + 1]) << 8
            } else {
                throw DICOMDisplayTransformError.invalidSamples
            }
            let stored = (container >> UInt32(shift)) & mask
            let numeric: Double
            if attributes.pixelRepresentation == .signed, stored & signBit != 0 {
                numeric = Double(Int64(stored) - signRange)
            } else {
                numeric = Double(stored)
            }
            let rescaled = numeric * attributes.rescaleSlope + attributes.rescaleIntercept
            guard rescaled.isFinite, Float(rescaled).isFinite else {
                throw DICOMDisplayTransformError.invalidSamples
            }
            intensities.append(Float(rescaled))
        }
        guard intensities.count == pixels.partialValue else {
            throw DICOMDisplayTransformError.invalidSamples
        }

        let window: DICOMWindow
        if let center = attributes.windowCenter, let width = attributes.windowWidth {
            window = try DICOMWindow(center: center, width: width)
        } else {
            window = try robustWindow(intensities)
        }
        return DICOMCanonicalSlice(
            rows: attributes.rows,
            columns: attributes.columns,
            intensities: intensities,
            defaultWindow: window,
            photometricInterpretation: attributes.photometricInterpretation
        )
    }

    static func render(
        _ canonical: DICOMCanonicalSlice,
        window requestedWindow: DICOMWindow? = nil
    ) throws -> DICOMRenderedSlice {
        let window = requestedWindow ?? canonical.defaultWindow
        let presentation = PresentationWindow(window)
        let invert = canonical.photometricInterpretation == .monochrome1
        var output = Data(count: canonical.rows * canonical.columns)
        canonical.withIntensities { intensities in
            output.withUnsafeMutableBytes { raw in
                guard let bytes = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                for (index, value) in intensities.enumerated() {
                    let grayscale = presentedValue(Double(value), window: presentation)
                    bytes[index] = invert
                        ? 255 &- grayscale
                        : grayscale
                }
            }
        }
        return DICOMRenderedSlice(
            rows: canonical.rows,
            columns: canonical.columns,
            grayscaleBytes: output,
            window: window
        )
    }

    private static func robustWindow(_ values: [Float]) throws -> DICOMWindow {
        guard !values.isEmpty, values.allSatisfy(\.isFinite) else {
            throw DICOMDisplayTransformError.invalidSamples
        }
        let sorted = values.sorted()
        let last = sorted.count - 1
        let lowerIndex = Int((Double(last) * 0.01).rounded(.down))
        let upperIndex = Int((Double(last) * 0.99).rounded(.up))
        let lower = Double(sorted[lowerIndex])
        let upper = Double(sorted[upperIndex])
        guard lower.isFinite, upper.isFinite, lower <= upper else {
            throw DICOMDisplayTransformError.invalidSamples
        }
        if lower == upper {
            return try DICOMWindow(center: lower + 0.5, width: 1)
        }
        return try DICOMWindow(
            center: (lower + upper + 1) / 2,
            width: upper - lower + 1
        )
    }

    private static func presentedValue(
        _ value: Double,
        window: PresentationWindow
    ) -> UInt8 {
        if window.denominator == 0 {
            return value > window.centerOffset ? 255 : 0
        }
        if value <= window.lower { return 0 }
        if value > window.upper { return 255 }
        let scaled = ((value - window.centerOffset) / window.denominator + 0.5) * 255
        return UInt8(clamping: Int(scaled.rounded()))
    }
}
