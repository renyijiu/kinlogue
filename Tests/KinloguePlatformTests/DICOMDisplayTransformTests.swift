import Foundation
import KinlogueCore
import Testing
@testable import KinloguePlatform

struct DICOMDisplayTransformTests {
    @Test
    func unsignedHighBitMaskingAndExplicitWindowProduceExactGrayscale() throws {
        let attributes = try transformAttributes(
            bitsStored: 12,
            highBit: 14,
            representation: .unsigned,
            center: 128,
            width: 256
        )
        let stored: [UInt16] = [0 << 3 | 7, 64 << 3 | 3, 128 << 3, 255 << 3 | 4]
        let canonical = try DICOMDisplayTransformer.canonicalize(
            sampleBytes: littleEndian(stored),
            attributes: attributes
        )
        #expect(canonical.withIntensities { Array($0) } == [0, 64, 128, 255])
        let rendered = try DICOMDisplayTransformer.render(canonical)
        #expect(rendered.grayscaleBytes == Data([0, 64, 128, 255]))
        let expectedWindow = try DICOMWindow(center: 128, width: 256)
        #expect(rendered.window == expectedWindow)
    }

    @Test
    func signedSamplesRescaleBeforeWindowing() throws {
        let attributes = try transformAttributes(
            representation: .signed,
            slope: 2,
            intercept: -10,
            center: nil,
            width: nil
        )
        let canonical = try DICOMDisplayTransformer.canonicalize(
            sampleBytes: littleEndian([0x0800, 0x0fff, 0x0000, 0x07ff]),
            attributes: attributes
        )
        #expect(canonical.withIntensities { Array($0) } == [-4_106, -12, -10, 4_084])
        let expectedWindow = try DICOMWindow(center: -10.5, width: 8_191)
        #expect(canonical.defaultWindow == expectedWindow)
    }

    @Test
    func monochromeOneInvertsOnlyFinalPresentation() throws {
        let attributes = try transformAttributes(
            photometric: .monochrome1,
            center: 128,
            width: 256
        )
        let canonical = try DICOMDisplayTransformer.canonicalize(
            sampleBytes: littleEndian([0, 64, 128, 255]),
            attributes: attributes
        )
        #expect(canonical.withIntensities { Array($0) } == [0, 64, 128, 255])
        #expect(try DICOMDisplayTransformer.render(canonical).grayscaleBytes
            == Data([255, 191, 127, 0]))
    }

    @Test
    func missingWindowUsesDeterministicRobustFiniteRange() throws {
        let attributes = try transformAttributes(center: nil, width: nil)
        let canonical = try DICOMDisplayTransformer.canonicalize(
            sampleBytes: littleEndian([0, 1, 2, 1_000]),
            attributes: attributes
        )
        let expectedWindow = try DICOMWindow(center: 500.5, width: 1_001)
        #expect(canonical.defaultWindow == expectedWindow)
        #expect(try DICOMDisplayTransformer.render(canonical).grayscaleBytes
            == Data([0, 0, 1, 255]))
    }

    @Test
    func malformedSampleLengthAndNonFiniteWindowFailWithoutPartialPixels() throws {
        let attributes = try transformAttributes()
        #expect(throws: DICOMDisplayTransformError.invalidSamples) {
            _ = try DICOMDisplayTransformer.canonicalize(
                sampleBytes: Data([0, 1]),
                attributes: attributes
            )
        }
        #expect(throws: DICOMDisplayTransformError.invalidWindow) {
            _ = try DICOMWindow(center: Double.infinity, width: 1)
        }
        #expect(throws: DICOMDisplayTransformError.invalidWindow) {
            _ = try DICOMWindow(center: 0, width: 0)
        }
        #expect(throws: DICOMDisplayTransformError.invalidWindow) {
            _ = try DICOMWindow(center: 0, width: 0.5)
        }
    }
}

private func transformAttributes(
    bitsStored: Int = 12,
    highBit: Int = 11,
    representation: DICOMStudyIndex.PixelRepresentation = .unsigned,
    photometric: DICOMStudyIndex.PhotometricInterpretation = .monochrome2,
    slope: Double = 1,
    intercept: Double = 0,
    center: Double? = 128,
    width: Double? = 256
) throws -> DICOMStudyIndex.ImageAttributes {
    try .init(
        rows: 2,
        columns: 2,
        samplesPerPixel: 1,
        bitsAllocated: 16,
        bitsStored: bitsStored,
        highBit: highBit,
        pixelRepresentation: representation,
        photometricInterpretation: photometric,
        imagePositionPatient: nil,
        imageOrientationPatientRow: nil,
        imageOrientationPatientColumn: nil,
        rescaleSlope: slope,
        rescaleIntercept: intercept,
        windowCenter: center,
        windowWidth: width
    )
}

private func littleEndian(_ values: [UInt16]) -> Data {
    Data(values.flatMap { value -> [UInt8] in
        [UInt8(value & 0xff), UInt8((value >> 8) & 0xff)]
    })
}
