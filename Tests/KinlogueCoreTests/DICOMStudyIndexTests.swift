import Foundation
import Testing
@testable import KinlogueCore

@Test
func indexClosesViewableObjectsExactlyOverInstanceAttachments() throws {
    let index = try sampleIndex(includingInertObject: true)
    try index.validate(studyID: index.studyID, attachmentIDs: Set(index.retainedObjects.map(\.attachmentID)))

    let inertAttachment = try #require(index.retainedObjects.first(where: { $0.kind == .inertAttachment })?.attachmentID)
    #expect(throws: DomainValidationError.invalidCatalogReference) {
        _ = try DICOMStudyIndex(
            studyID: index.studyID, studyUIDDigest: studyDigest(1),
            retainedObjects: index.retainedObjects.map {
                $0.attachmentID == inertAttachment
                    ? .init(attachmentID: $0.attachmentID, kind: .viewableImage)
                    : $0
            },
            instances: index.instances, series: index.series
        )
    }
}

@Test
func indexRejectsDuplicateSeriesDigestAndMissingGeometryProjectionFields() throws {
    let index = try sampleIndex(includingInertObject: false)
    let secondID = UUID()
    let secondAttachment = UUID()
    let secondInstance = try instance(id: UUID(), attachmentID: secondAttachment, seriesID: secondID, order: 0, byte: 9)
    #expect(throws: DomainValidationError.invalidCatalogReference) {
        _ = try DICOMStudyIndex(
            studyID: index.studyID, studyUIDDigest: studyDigest(1),
            retainedObjects: index.retainedObjects + [.init(attachmentID: secondAttachment, kind: .viewableImage)],
            instances: index.instances + [secondInstance],
            series: index.series + [try .init(id: secondID, ordinal: 2, instanceIDs: [secondInstance.id], seriesUIDDigest: seriesDigest(1), orderingProvenance: .geometryProjection)]
        )
    }

    let noGeometry = try attributes(position: nil, row: nil, column: nil)
    let instanceWithoutGeometry = try instance(id: UUID(), attachmentID: UUID(), seriesID: UUID(), order: 0, byte: 8, attributes: noGeometry)
    #expect(throws: DomainValidationError.invalidCatalogReference) {
        _ = try invalidIndex(instances: [instanceWithoutGeometry], seriesID: instanceWithoutGeometry.seriesID)
    }
}

@Test
func strictDecodersRejectOneUnknownKeyOnOtherwiseValidEverySchema() throws {
    let index = try sampleIndex(includingInertObject: false)
    let fingerprint = try DICOMStudyFingerprint(objects: [.init(sha256Digest: digest(7), byteCount: 5)])
    let study = try DICOMStudy(state: .needsReview, fingerprint: fingerprint, indexObjectID: UUID(), attachmentIDs: [UUID()])
    let catalog = try VaultCatalog(vaultID: UUID(), generation: 1)
    let object = try #require(fingerprint.objects.first)
    let vector = try DICOMStudyIndex.Vector3(x: 1, y: 2, z: 3)
    let attrs = try attributes()
    let retained = DICOMStudyIndex.RetainedObject(attachmentID: UUID(), kind: .inertAttachment)
    let instance = try #require(index.instances.first)
    let series = try #require(index.series.first)
    let uid = studyDigest(1)

    try assertUnknownKeyRejected(DICOMStudyFingerprint.self, value: fingerprint)
    try assertUnknownKeyRejected(DICOMStudyFingerprint.ObjectDigest.self, value: object)
    try assertUnknownKeyRejected(DICOMStudy.self, value: study)
    try assertUnknownKeyRejected(DICOMStudyIndex.self, value: index)
    try assertUnknownKeyRejected(DICOMStudyIndex.UIDDigest.self, value: uid)
    try assertUnknownKeyRejected(DICOMStudyIndex.Vector3.self, value: vector)
    try assertUnknownKeyRejected(DICOMStudyIndex.ImageAttributes.self, value: attrs)
    try assertUnknownKeyRejected(DICOMStudyIndex.RetainedObject.self, value: retained)
    try assertUnknownKeyRejected(DICOMStudyIndex.Instance.self, value: instance)
    try assertUnknownKeyRejected(DICOMStudyIndex.Series.self, value: series)
    try assertUnknownKeyRejected(VaultCatalog.self, value: catalog)
}

@Test
func imageAttributesRejectInvalidBitLayoutAndNonFinitePresentationValues() throws {
    #expect(throws: DomainValidationError.invalidCatalogReference) {
        _ = try attributes(bitsAllocated: 8, bitsStored: 9, highBit: 8)
    }
    #expect(throws: DomainValidationError.invalidCatalogReference) {
        _ = try attributes(rescaleSlope: .infinity)
    }
    #expect(throws: DomainValidationError.invalidCatalogReference) {
        _ = try attributes(windowCenter: 0, windowWidth: 0.5)
    }
}

@Test
func indexRejectsNoncurrentOrderingPolicyAtConstructionAndDecode() throws {
    let current = try sampleIndex(includingInertObject: false)
    #expect(current.orderingPolicyVersion == 2)
    #expect(throws: DomainValidationError.invalidFormatVersion) {
        _ = try DICOMStudyIndex(
            orderingPolicyVersion: 1,
            studyID: current.studyID,
            studyUIDDigest: current.studyUIDDigest,
            retainedObjects: current.retainedObjects,
            instances: current.instances,
            series: current.series
        )
    }

    var encoded = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(current))
            as? [String: Any]
    )
    encoded["orderingPolicyVersion"] = 1
    let noncurrent = try JSONSerialization.data(
        withJSONObject: encoded,
        options: [.sortedKeys]
    )
    #expect(throws: DecodingError.self) {
        _ = try JSONDecoder().decode(DICOMStudyIndex.self, from: noncurrent)
    }
}

private func sampleIndex(includingInertObject: Bool) throws -> DICOMStudyIndex {
    let studyID = UUID(); let seriesID = UUID()
    let first = try instance(id: UUID(), attachmentID: UUID(), seriesID: seriesID, order: 0, byte: 3)
    let second = try instance(id: UUID(), attachmentID: UUID(), seriesID: seriesID, order: 1, byte: 4)
    var retained: [DICOMStudyIndex.RetainedObject] = [
        .init(attachmentID: first.attachmentID, kind: .viewableImage),
        .init(attachmentID: second.attachmentID, kind: .viewableImage),
    ]
    if includingInertObject { retained.append(.init(attachmentID: UUID(), kind: .inertAttachment)) }
    return try DICOMStudyIndex(
        studyID: studyID, studyUIDDigest: studyDigest(1), retainedObjects: retained,
        instances: [first, second],
        series: [try .init(id: seriesID, ordinal: 1, instanceIDs: [first.id, second.id], seriesUIDDigest: seriesDigest(1), orderingProvenance: .geometryProjection)]
    )
}

private func invalidIndex(instances: [DICOMStudyIndex.Instance], seriesID: UUID) throws -> DICOMStudyIndex {
    try DICOMStudyIndex(
        studyID: UUID(), studyUIDDigest: studyDigest(1),
        retainedObjects: instances.map { .init(attachmentID: $0.attachmentID, kind: .viewableImage) },
        instances: instances,
        series: [try .init(id: seriesID, ordinal: 1, instanceIDs: instances.map(\.id), seriesUIDDigest: seriesDigest(1), orderingProvenance: .geometryProjection)]
    )
}

private func instance(id: UUID, attachmentID: UUID, seriesID: UUID, order: Int, byte: UInt8, attributes: DICOMStudyIndex.ImageAttributes? = nil) throws -> DICOMStudyIndex.Instance {
    let resolvedAttributes = try attributes ?? defaultAttributes()
    return try DICOMStudyIndex.Instance(id: id, attachmentID: attachmentID, seriesID: seriesID,
              sopInstanceUIDDigest: try DICOMStudyIndex.UIDDigest(scope: .sopInstance, digest: digest(byte)), canonicalOrder: order,
              sopClass: .mrImageStorage, transferSyntax: .explicitVRLittleEndian, modality: .mr,
              attributes: resolvedAttributes)
}

private func attributes(bitsAllocated: Int = 16, bitsStored: Int = 12, highBit: Int = 11, rescaleSlope: Double = 1, position: DICOMStudyIndex.Vector3? = nil, row: DICOMStudyIndex.Vector3? = nil, column: DICOMStudyIndex.Vector3? = nil, windowCenter: Double? = nil, windowWidth: Double? = nil) throws -> DICOMStudyIndex.ImageAttributes {
    try .init(rows: 2, columns: 2, samplesPerPixel: 1, bitsAllocated: bitsAllocated, bitsStored: bitsStored, highBit: highBit,
              pixelRepresentation: .unsigned, photometricInterpretation: .monochrome2,
              imagePositionPatient: position, imageOrientationPatientRow: row, imageOrientationPatientColumn: column,
              rescaleSlope: rescaleSlope, rescaleIntercept: 0,
              windowCenter: windowCenter, windowWidth: windowWidth)
}

private func defaultAttributes() throws -> DICOMStudyIndex.ImageAttributes {
    try attributes(position: .init(x: 0, y: 0, z: 0), row: .init(x: 1, y: 0, z: 0), column: .init(x: 0, y: 1, z: 0))
}

private func digest(_ byte: UInt8) -> Data { Data(repeating: byte, count: 32) }
private func studyDigest(_ byte: UInt8) -> DICOMStudyIndex.UIDDigest { try! .init(scope: .study, digest: digest(byte)) }
private func seriesDigest(_ byte: UInt8) -> DICOMStudyIndex.UIDDigest { try! .init(scope: .series, digest: digest(byte)) }

private func assertUnknownKeyRejected<T: Codable>(_ type: T.Type, value: T) throws {
    let encoded = try JSONEncoder().encode(value)
    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object["unexpectedSyntheticField"] = true
    let polluted = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    #expect(throws: DecodingError.self) { _ = try JSONDecoder().decode(type, from: polluted) }
}
