import Foundation
import KinlogueCore

/// Import-time, versioned ordering policy for one classic single-frame Series.
/// Paths and raw UIDs are deliberately absent from the input. The content
/// identity is used only as the final deterministic fallback/tie breaker.
enum DICOMSeriesGeometry {
    static let orientationTolerance = 1e-4
    static let positionTolerance = 1e-3

    struct Slice<Value: Sendable>: Sendable {
        let value: Value
        let attributes: DICOMStudyIndex.ImageAttributes
        let instanceNumber: Int?
        let stableContentIdentity: Data
    }

    struct Ordered<Value: Sendable>: Sendable {
        let slices: [Slice<Value>]
        let provenance: DICOMStudyIndex.OrderingProvenance
    }

    static func order<Value: Sendable>(
        _ slices: [Slice<Value>]
    ) throws -> Ordered<Value> {
        guard !slices.isEmpty else { throw DICOMImportError.corruptImage }
        try validatePixelLayout(slices.map(\.attributes))

        let geometryPresence = slices.map { slice in
            (
                slice.attributes.imagePositionPatient != nil,
                slice.attributes.imageOrientationPatientRow != nil,
                slice.attributes.imageOrientationPatientColumn != nil
            )
        }
        if geometryPresence.allSatisfy({ !$0.0 && !$0.1 && !$0.2 }) {
            return fallbackOrder(slices)
        }
        guard geometryPresence.allSatisfy({ $0.0 && $0.1 && $0.2 }) else {
            throw DICOMImportError.corruptImage
        }

        guard let projectedGeometry = try projectedGeometry(slices) else {
            return fallbackOrder(slices)
        }
        let projected = projectedGeometry.sorted { lhs, rhs in
            if lhs.position != rhs.position { return lhs.position < rhs.position }
            return lhs.slice.stableContentIdentity.lexicographicallyPrecedes(
                rhs.slice.stableContentIdentity
            )
        }
        guard hasIncreasingPositions(projected) else { return fallbackOrder(slices) }
        return Ordered(
            slices: projected.map(\.slice),
            provenance: .geometryProjection
        )
    }

    static func validatePersistedGeometryOrder(_ index: DICOMStudyIndex) throws {
        let byID = Dictionary(uniqueKeysWithValues: index.instances.map { ($0.id, $0) })
        for series in index.series where series.orderingProvenance == .geometryProjection {
            let persisted = try series.instanceIDs.map { id -> Slice<Void> in
                guard let instance = byID[id] else { throw DICOMImportError.corruptImage }
                return Slice(
                    value: (),
                    attributes: instance.attributes,
                    instanceNumber: nil,
                    stableContentIdentity: Data()
                )
            }
            try validatePixelLayout(persisted.map(\.attributes))
            guard let projected = try projectedGeometry(persisted),
                  hasIncreasingPositions(projected) else {
                throw DICOMImportError.corruptImage
            }
        }
    }

    private static func projectedGeometry<Value: Sendable>(
        _ slices: [Slice<Value>]
    ) throws -> [(slice: Slice<Value>, position: Double)]? {
        guard let first = slices.first else { throw DICOMImportError.corruptImage }
        let referenceRow = try normalized(try require(
            first.attributes.imageOrientationPatientRow
        ))
        let referenceColumn = try normalized(try require(
            first.attributes.imageOrientationPatientColumn
        ))
        guard abs(dot(referenceRow, referenceColumn)) <= orientationTolerance else {
            throw DICOMImportError.corruptImage
        }
        let referenceNormal = try normalized(cross(referenceRow, referenceColumn))

        var projected: [(slice: Slice<Value>, position: Double)] = []
        projected.reserveCapacity(slices.count)
        for slice in slices {
            let attributes = slice.attributes
            let row = try normalized(try require(attributes.imageOrientationPatientRow))
            let column = try normalized(try require(
                attributes.imageOrientationPatientColumn
            ))
            guard abs(dot(row, column)) <= orientationTolerance else {
                throw DICOMImportError.corruptImage
            }
            let normal = try normalized(cross(row, column))
            guard distance(row, referenceRow) <= orientationTolerance,
                  distance(column, referenceColumn) <= orientationTolerance,
                  distance(normal, referenceNormal) <= orientationTolerance else {
                return nil
            }
            let position = dot(
                try require(attributes.imagePositionPatient),
                referenceNormal
            )
            guard position.isFinite else { throw DICOMImportError.corruptImage }
            projected.append((slice, position))
        }
        return projected
    }

    private static func hasIncreasingPositions<Value>(
        _ projected: [(slice: Value, position: Double)]
    ) -> Bool {
        for (lhs, rhs) in zip(projected, projected.dropFirst()) {
            let spacing = rhs.position - lhs.position
            guard spacing.isFinite, spacing > positionTolerance else { return false }
        }
        return true
    }

    private static func fallbackOrder<Value: Sendable>(
        _ slices: [Slice<Value>]
    ) -> Ordered<Value> {
        if slices.allSatisfy({ $0.instanceNumber != nil }) {
            return Ordered(
                slices: slices.sorted { lhs, rhs in
                    let left = lhs.instanceNumber!
                    let right = rhs.instanceNumber!
                    if left != right { return left < right }
                    return lhs.stableContentIdentity.lexicographicallyPrecedes(
                        rhs.stableContentIdentity
                    )
                },
                provenance: .instanceNumberFallback
            )
        }
        return Ordered(
            slices: slices.sorted {
                $0.stableContentIdentity.lexicographicallyPrecedes($1.stableContentIdentity)
            },
            provenance: .stableContentFallback
        )
    }

    private static func validatePixelLayout(
        _ attributes: [DICOMStudyIndex.ImageAttributes]
    ) throws {
        guard let first = attributes.first,
              attributes.allSatisfy({
                  $0.rows == first.rows
                    && $0.columns == first.columns
                    && $0.samplesPerPixel == first.samplesPerPixel
                    && $0.bitsAllocated == first.bitsAllocated
                    && $0.bitsStored == first.bitsStored
                    && $0.highBit == first.highBit
                    && $0.pixelRepresentation == first.pixelRepresentation
                    && $0.photometricInterpretation == first.photometricInterpretation
              }) else {
            throw DICOMImportError.corruptImage
        }
    }

    private static func normalized(_ vector: DICOMStudyIndex.Vector3) throws
        -> DICOMStudyIndex.Vector3 {
        let length = magnitude(vector)
        guard length.isFinite, length > orientationTolerance else {
            throw DICOMImportError.corruptImage
        }
        return try DICOMStudyIndex.Vector3(
            x: vector.x / length,
            y: vector.y / length,
            z: vector.z / length
        )
    }

    private static func cross(
        _ lhs: DICOMStudyIndex.Vector3,
        _ rhs: DICOMStudyIndex.Vector3
    ) throws -> DICOMStudyIndex.Vector3 {
        try .init(
            x: lhs.y * rhs.z - lhs.z * rhs.y,
            y: lhs.z * rhs.x - lhs.x * rhs.z,
            z: lhs.x * rhs.y - lhs.y * rhs.x
        )
    }

    private static func dot(
        _ lhs: DICOMStudyIndex.Vector3,
        _ rhs: DICOMStudyIndex.Vector3
    ) -> Double {
        lhs.x * rhs.x + lhs.y * rhs.y + lhs.z * rhs.z
    }

    private static func magnitude(_ value: DICOMStudyIndex.Vector3) -> Double {
        dot(value, value).squareRoot()
    }

    private static func distance(
        _ lhs: DICOMStudyIndex.Vector3,
        _ rhs: DICOMStudyIndex.Vector3
    ) -> Double {
        magnitude(subtract(lhs, rhs))
    }

    private static func subtract(
        _ lhs: DICOMStudyIndex.Vector3,
        _ rhs: DICOMStudyIndex.Vector3
    ) -> DICOMStudyIndex.Vector3 {
        // Inputs were already finite, so this cannot fail validation.
        try! .init(x: lhs.x - rhs.x, y: lhs.y - rhs.y, z: lhs.z - rhs.z)
    }

    private static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw DICOMImportError.corruptImage }
        return value
    }
}
