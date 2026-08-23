import Foundation
import KinlogueCore
import Testing
@testable import KinloguePlatform

struct DICOMSeriesGeometryTests {
    @Test
    func missingGeometryUsesInstanceNumberThenStableContentFallback() throws {
        let attributes = try imageAttributes(position: nil, row: nil, column: nil)
        let numbered = try DICOMSeriesGeometry.order([
            slice("third", attributes, instance: 30, content: 3),
            slice("first", attributes, instance: 10, content: 2),
            slice("second", attributes, instance: 20, content: 1),
        ])
        #expect(numbered.provenance == .instanceNumberFallback)
        #expect(numbered.slices.map(\.value) == ["first", "second", "third"])

        let contentOnly = try DICOMSeriesGeometry.order([
            slice("third", attributes, instance: nil, content: 3),
            slice("first", attributes, instance: 2, content: 1),
            slice("second", attributes, instance: 1, content: 2),
        ])
        #expect(contentOnly.provenance == .stableContentFallback)
        #expect(contentOnly.slices.map(\.value) == ["first", "second", "third"])
    }

    @Test(arguments: [GeometryFailure.partialGeometry, .nonOrthogonalOrientation])
    func ambiguousGeometryFailsClosed(_ failure: GeometryFailure) throws {
        let slices: [DICOMSeriesGeometry.Slice<Int>]
        switch failure {
        case .partialGeometry:
            slices = [
                slice(0, try imageAttributes(z: 0), instance: 1, content: 1),
                slice(
                    1,
                    try imageAttributes(position: nil, row: nil, column: nil),
                    instance: 2,
                    content: 2
                ),
            ]
        case .nonOrthogonalOrientation:
            slices = [slice(
                0,
                try imageAttributes(
                    row: try vector(1, 0, 0),
                    column: try vector(1, 0, 0)
                ),
                instance: 1,
                content: 1
            )]
        }
        #expect(throws: DICOMImportError.corruptImage) {
            _ = try DICOMSeriesGeometry.order(slices)
        }
    }

    @Test
    func duplicateAndVaryingGeometryUseNonSpatialFallback() throws {
        let duplicatePosition = try DICOMSeriesGeometry.order([
            slice("second", try imageAttributes(z: 0), instance: 2, content: 1),
            slice("first", try imageAttributes(z: 0.000_1), instance: 1, content: 2),
        ])
        #expect(duplicatePosition.provenance == .instanceNumberFallback)
        #expect(duplicatePosition.slices.map(\.value) == ["first", "second"])

        let varyingOrientation = try DICOMSeriesGeometry.order([
            slice("second", try imageAttributes(z: 1), instance: 2, content: 1),
            slice(
                "first",
                try imageAttributes(
                    row: try vector(0, 1, 0),
                    column: try vector(0, 0, 1),
                    z: 0
                ),
                instance: 1,
                content: 2
            ),
        ])
        #expect(varyingOrientation.provenance == .instanceNumberFallback)
        #expect(varyingOrientation.slices.map(\.value) == ["first", "second"])
    }

    @Test
    func inconsistentPixelLayoutFailsClosed() throws {
        #expect(throws: DICOMImportError.corruptImage) {
            _ = try DICOMSeriesGeometry.order([
                slice(0, try imageAttributes(z: 0), instance: 1, content: 1),
                slice(
                    1,
                    try imageAttributes(z: 1, columns: 3),
                    instance: 2,
                    content: 2
                ),
            ])
        }
    }

    @Test
    func reversedVariablePositionsAndSmallOrientationDriftRemainDeterministic() throws {
        let ordered = try DICOMSeriesGeometry.order([
            slice(
                "high",
                try imageAttributes(
                    row: try vector(1, 0.000_05, 0),
                    column: try vector(-0.000_05, 1, 0),
                    z: 7
                ),
                instance: 1,
                content: 1
            ),
            slice(
                "low",
                try imageAttributes(z: -3),
                instance: 3,
                content: 3
            ),
            slice(
                "middle",
                try imageAttributes(z: 1),
                instance: 2,
                content: 2
            ),
        ])

        #expect(ordered.slices.map(\.value) == ["low", "middle", "high"])
        #expect(ordered.provenance == .geometryProjection)
    }

    @Test
    func persistedGeometryValidationAcceptsVariableSpacingAndRejectsOutOfOrder() throws {
        try DICOMSeriesGeometry.validatePersistedGeometryOrder(
            persistedGeometryIndex(positions: [-3, 1, 7])
        )
        #expect(throws: DICOMImportError.corruptImage) {
            try DICOMSeriesGeometry.validatePersistedGeometryOrder(
                persistedGeometryIndex(positions: [7, 1, -3])
            )
        }
    }
}

enum GeometryFailure: Sendable {
    case partialGeometry
    case nonOrthogonalOrientation
}

private func slice<Value: Sendable>(
    _ value: Value,
    _ attributes: DICOMStudyIndex.ImageAttributes,
    instance: Int?,
    content: UInt8
) -> DICOMSeriesGeometry.Slice<Value> {
    .init(
        value: value,
        attributes: attributes,
        instanceNumber: instance,
        stableContentIdentity: Data([content])
    )
}

private func imageAttributes(
    position: DICOMStudyIndex.Vector3? = try? vector(0, 0, 0),
    row: DICOMStudyIndex.Vector3? = try? vector(1, 0, 0),
    column: DICOMStudyIndex.Vector3? = try? vector(0, 1, 0),
    z: Double? = nil,
    columns: Int = 2
) throws -> DICOMStudyIndex.ImageAttributes {
    try .init(
        rows: 2,
        columns: columns,
        samplesPerPixel: 1,
        bitsAllocated: 16,
        bitsStored: 12,
        highBit: 11,
        pixelRepresentation: .unsigned,
        photometricInterpretation: .monochrome2,
        imagePositionPatient: z.map { try! vector(0, 0, $0) } ?? position,
        imageOrientationPatientRow: row,
        imageOrientationPatientColumn: column,
        rescaleSlope: 1,
        rescaleIntercept: 0,
        windowCenter: nil,
        windowWidth: nil
    )
}

private func vector(_ x: Double, _ y: Double, _ z: Double) throws
    -> DICOMStudyIndex.Vector3 {
    try .init(x: x, y: y, z: z)
}

private func persistedGeometryIndex(positions: [Double]) throws -> DICOMStudyIndex {
    let studyID = UUID()
    let seriesID = UUID()
    let instances = try positions.enumerated().map { offset, position in
        try DICOMStudyIndex.Instance(
            id: UUID(),
            attachmentID: UUID(),
            seriesID: seriesID,
            sopInstanceUIDDigest: .init(
                scope: .sopInstance,
                digest: Data(repeating: UInt8(offset + 1), count: 32)
            ),
            canonicalOrder: offset,
            sopClass: .mrImageStorage,
            transferSyntax: .explicitVRLittleEndian,
            modality: .mr,
            attributes: imageAttributes(z: position)
        )
    }
    return try DICOMStudyIndex(
        studyID: studyID,
        studyUIDDigest: .init(scope: .study, digest: Data(repeating: 0x41, count: 32)),
        retainedObjects: instances.map {
            .init(attachmentID: $0.attachmentID, kind: .viewableImage)
        },
        instances: instances,
        series: [try .init(
            id: seriesID,
            ordinal: 1,
            instanceIDs: instances.map(\.id),
            seriesUIDDigest: .init(
                scope: .series,
                digest: Data(repeating: 0x42, count: 32)
            ),
            orderingProvenance: .geometryProjection
        )]
    )
}
