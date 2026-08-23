import CryptoKit
import Darwin
import Foundation
import KinlogueCore
import KinlogueDICOMIPC

public protocol DICOMFrameDecoding: Sendable {
    func decode(
        descriptor: FileHandle,
        declaredByteCount: Int
    ) async throws -> KinlogueDICOMDecodedFrame
}

extension DICOMDecoderAdapter: DICOMFrameDecoding {}

public struct DICOMIndexedObject: Equatable, Sendable {
    public let staged: VaultDICOMStagedObject
    public let attachment: Attachment
}

public struct DICOMIndexedStudyProposal: Equatable, Sendable {
    public let study: DICOMStudy
    public let index: DICOMStudyIndex
    public let objects: [DICOMIndexedObject]
    public let ignoredDuplicateCount: Int
}

public struct DICOMStudyIndexer: Sendable {
    private let decoder: any DICOMFrameDecoding
    private let policy: DICOMImportPolicy
    private let metrics: DICOMImportMetricsRecorder?

    public init(
        decoder: any DICOMFrameDecoding = DICOMDecoderAdapter(),
        policy: DICOMImportPolicy = .default
    ) {
        self.decoder = decoder
        self.policy = policy
        metrics = nil
    }

    init(
        decoder: any DICOMFrameDecoding,
        policy: DICOMImportPolicy,
        metrics: DICOMImportMetricsRecorder?
    ) {
        self.decoder = decoder
        self.policy = policy
        self.metrics = metrics
    }

    public func index(
        stagedObjects: [VaultDICOMStagedObject],
        vaultID: UUID,
        staging: VaultDICOMStudyStaging
    ) async throws -> DICOMIndexedStudyProposal {
        do { try policy.validateDICOMObjectCount(stagedObjects.count) }
        catch { throw DICOMImportError.resourceLimit }
        guard let firstOperation = stagedObjects.first?.operationID,
              stagedObjects.allSatisfy({ $0.operationID == firstOperation }) else {
            throw DICOMImportError.integrityFailure
        }
        var candidates: [Candidate] = []
        candidates.reserveCapacity(stagedObjects.count)
        var decodedByContent: [DICOMContentIdentity: ValidatedImage] = [:]

        for staged in stagedObjects {
            if Task.isCancelled { throw DICOMImportError.cancelled }
            await metrics?.recordStagingDescriptorsOpened(3)
            let candidate: Candidate
            do {
                candidate = try await staging.withDescriptor(staged) { descriptor in
                    let measured = try hash(descriptor: descriptor, expectedByteCount: staged.byteCount)
                    guard measured == staged.sha256Digest else {
                        throw DICOMImportError.integrityFailure
                    }
                    await metrics?.recordIndexFullRead(
                        digest: staged.sha256Digest,
                        byteCount: staged.byteCount
                    )
                    do {
                        _ = try DICOMPart10Envelope.validate(
                            descriptor: descriptor,
                            declaredByteCount: staged.byteCount
                        )
                    } catch let error as DICOMDecoderAdapterError {
                        switch error {
                        case .resourceLimit: throw DICOMImportError.resourceLimit
                        default: throw DICOMImportError.invalidPart10
                        }
                    }
                    let metadata = try DICOMAllowlistMetadata.read(
                        descriptor: descriptor.fileDescriptor,
                        byteCount: staged.byteCount
                    )
                    if metadata.isSupportedMRImage {
                        let contentKey = DICOMContentIdentity(
                            digest: staged.sha256Digest,
                            byteCount: staged.byteCount
                        )
                        let image: ValidatedImage
                        if let decoded = decodedByContent[contentKey] {
                            guard decoded.metadata == metadata else {
                                throw DICOMImportError.corruptImage
                            }
                            image = decoded
                        } else {
                            let frame: KinlogueDICOMDecodedFrame
                            do {
                                frame = try await decoder.decode(
                                    descriptor: descriptor,
                                    declaredByteCount: staged.byteCount
                                )
                                await metrics?.recordDecoderFullRead(
                                    digest: staged.sha256Digest,
                                    byteCount: staged.byteCount
                                )
                            } catch let error as DICOMDecoderAdapterError {
                                switch error {
                                case .unsupportedObject: throw DICOMImportError.unsupportedImage
                                case .resourceLimit: throw DICOMImportError.resourceLimit
                                case .invalidPart10, .invalidDescriptor, .invalidResponse, .decoderFailed:
                                    throw DICOMImportError.corruptImage
                                case .helperUnavailable, .helperInterrupted, .helperTimedOut:
                                    throw DICOMImportError.decoderUnavailable
                                }
                            }
                            try validate(frame: frame, matches: metadata, policy: policy)
                            image = try ValidatedImage(
                                metadata: metadata,
                                attributes: DICOMImageAttributesMapper.attributes(for: frame),
                                instanceNumber: frame.instanceNumber
                            )
                            decodedByContent[contentKey] = image
                        }
                        return Candidate(
                            staged: staged,
                            metadata: metadata,
                            imageAttributes: image.attributes,
                            instanceNumber: image.instanceNumber
                        )
                    }
                    guard metadata.isAllowedInertObject else {
                        throw DICOMImportError.unsupportedImage
                    }
                    return Candidate(
                        staged: staged,
                        metadata: metadata,
                        imageAttributes: nil,
                        instanceNumber: nil
                    )
                }
            } catch {
                await metrics?.recordStagingDescriptorsClosed(3)
                throw error
            }
            await metrics?.recordStagingDescriptorsClosed(3)
            candidates.append(candidate)
        }

        let studyUIDs = Set(candidates.map(\.metadata.studyInstanceUID))
        guard studyUIDs.count == 1, let studyUID = studyUIDs.first else {
            throw DICOMImportError.mixedStudy
        }
        var bySOP: [String: Candidate] = [:]
        var byContent: [DICOMContentIdentity: Candidate] = [:]
        var ignoredDuplicateCount = 0
        for candidate in candidates {
            let contentKey = DICOMContentIdentity(
                digest: candidate.staged.sha256Digest,
                byteCount: candidate.staged.byteCount
            )
            if let prior = bySOP[candidate.metadata.sopInstanceUID] {
                guard prior.staged.sha256Digest == candidate.staged.sha256Digest,
                      prior.staged.byteCount == candidate.staged.byteCount else {
                    throw DICOMImportError.sopInstanceConflict
                }
                ignoredDuplicateCount += 1
                continue
            }
            bySOP[candidate.metadata.sopInstanceUID] = candidate
            if byContent[contentKey] != nil {
                ignoredDuplicateCount += 1
            } else {
                byContent[contentKey] = candidate
            }
        }
        let unique = byContent.values.sorted { lhs, rhs in
            if lhs.staged.sha256Digest != rhs.staged.sha256Digest {
                return lhs.staged.sha256Digest.lexicographicallyPrecedes(rhs.staged.sha256Digest)
            }
            return lhs.staged.byteCount < rhs.staged.byteCount
        }
        guard !unique.isEmpty else { throw DICOMImportError.noDICOMObjects }

        let studyID = UUID()
        var indexedObjects: [DICOMIndexedObject] = []
        var retained: [DICOMStudyIndex.RetainedObject] = []
        var imageCandidates: [(Candidate, Attachment)] = []
        for candidate in unique {
            let attachment = try Attachment(
                contentTypeIdentifier: "org.nema.dicom",
                byteCount: candidate.staged.byteCount,
                sha256Digest: candidate.staged.sha256Digest
            )
            indexedObjects.append(.init(staged: candidate.staged, attachment: attachment))
            let kind: DICOMStudyIndex.RetainedObjectKind = candidate.imageAttributes == nil
                ? .inertAttachment : .viewableImage
            retained.append(.init(attachmentID: attachment.id, kind: kind))
            if candidate.imageAttributes != nil { imageCandidates.append((candidate, attachment)) }
        }

        let grouped = Dictionary(grouping: imageCandidates) { $0.0.metadata.seriesInstanceUID }
        let orderedGroups = grouped.keys.map { rawUID in
            (
                rawUID: rawUID,
                digest: uidDigest(vaultID: vaultID, scope: .series, uid: rawUID)
            )
        }.sorted { lhs, rhs in
            lhs.digest.digest.lexicographicallyPrecedes(rhs.digest.digest)
        }
        var instances: [DICOMStudyIndex.Instance] = []
        var series: [DICOMStudyIndex.Series] = []
        for (seriesOffset, group) in orderedGroups.enumerated() {
            let seriesID = UUID()
            let ordered = try DICOMSeriesGeometry.order(
                (grouped[group.rawUID] ?? []).map { pair in
                    DICOMSeriesGeometry.Slice(
                        value: pair,
                        attributes: try require(pair.0.imageAttributes),
                        instanceNumber: pair.0.instanceNumber,
                        stableContentIdentity: stableContentIdentity(pair.0.staged)
                    )
                }
            )
            var seriesInstanceIDs: [UUID] = []
            for (order, orderedSlice) in ordered.slices.enumerated() {
                let pair = orderedSlice.value
                let attributes = try require(pair.0.imageAttributes)
                let instanceID = UUID()
                seriesInstanceIDs.append(instanceID)
                instances.append(try DICOMStudyIndex.Instance(
                    id: instanceID,
                    attachmentID: pair.1.id,
                    seriesID: seriesID,
                    sopInstanceUIDDigest: uidDigest(
                        vaultID: vaultID,
                        scope: .sopInstance,
                        uid: pair.0.metadata.sopInstanceUID
                    ),
                    canonicalOrder: order,
                    sopClass: .mrImageStorage,
                    transferSyntax: .explicitVRLittleEndian,
                    modality: .mr,
                    attributes: attributes
                ))
            }
            series.append(try DICOMStudyIndex.Series(
                id: seriesID,
                ordinal: seriesOffset + 1,
                instanceIDs: seriesInstanceIDs,
                seriesUIDDigest: group.digest,
                orderingProvenance: ordered.provenance
            ))
        }

        let fingerprint = try DICOMStudyFingerprint(objects: indexedObjects.map {
            try DICOMStudyFingerprint.ObjectDigest(
                sha256Digest: $0.attachment.sha256Digest,
                byteCount: $0.attachment.byteCount
            )
        })
        let indexObjectID = UUID()
        let study = try DICOMStudy(
            id: studyID,
            state: .needsReview,
            fingerprint: fingerprint,
            indexObjectID: indexObjectID,
            attachmentIDs: indexedObjects.map(\.attachment.id)
        )
        let index = try DICOMStudyIndex(
            studyID: studyID,
            studyUIDDigest: uidDigest(vaultID: vaultID, scope: .study, uid: studyUID),
            retainedObjects: retained,
            instances: instances,
            series: series
        )
        return DICOMIndexedStudyProposal(
            study: study,
            index: index,
            objects: indexedObjects,
            ignoredDuplicateCount: ignoredDuplicateCount
        )
    }

}

private struct Candidate: Sendable {
    let staged: VaultDICOMStagedObject
    let metadata: DICOMAllowlistMetadata
    let imageAttributes: DICOMStudyIndex.ImageAttributes?
    let instanceNumber: Int?
}

private struct ValidatedImage: Sendable {
    let metadata: DICOMAllowlistMetadata
    let attributes: DICOMStudyIndex.ImageAttributes
    let instanceNumber: Int?
}

private struct DICOMAllowlistMetadata: Equatable, Sendable {
    let transferSyntaxUID: String
    let sopClassUID: String
    let studyInstanceUID: String
    let seriesInstanceUID: String
    let sopInstanceUID: String
    let modality: String

    var isSupportedMRImage: Bool {
        transferSyntaxUID == KinlogueDICOMSupportedObject.explicitVRLittleEndian
            && sopClassUID == KinlogueDICOMSupportedObject.mrImageStorage
            && modality == KinlogueDICOMSupportedObject.modality
    }

    var isAllowedInertObject: Bool {
        transferSyntaxUID == KinlogueDICOMSupportedObject.explicitVRLittleEndian
            && (sopClassUID.hasPrefix("1.2.840.10008.5.1.4.1.1.88.")
                || sopClassUID.hasPrefix("1.2.840.10008.5.1.4.1.1.104."))
    }

    static func read(descriptor: Int32, byteCount: Int) throws -> Self {
        let parser = DICOMExplicitVRParser(descriptor: descriptor, byteCount: byteCount)
        return try parser.readAllowlist()
    }
}

private struct DICOMExplicitVRParser {
    let descriptor: Int32
    let byteCount: Int

    func readAllowlist() throws -> DICOMAllowlistMetadata {
        guard byteCount >= 144, try bytes(at: 128, count: 4) == Data("DICM".utf8) else {
            throw DICOMImportError.invalidPart10
        }
        var cursor = 132
        var values: [UInt32: String] = [:]
        var remainingSkippedElements = 1_000_000
        while cursor < byteCount {
            let header = try elementHeader(at: cursor)
            if header.length == UInt32.max {
                guard header.vr == "SQ" else { throw DICOMImportError.invalidPart10 }
                cursor = try endOffsetOfUndefinedLengthSequence(
                    valueOffset: cursor + header.headerLength,
                    remainingElementBudget: &remainingSkippedElements
                )
                continue
            }
            let length = Int(header.length)
            guard length >= 0, cursor <= byteCount - header.headerLength,
                  length <= byteCount - cursor - header.headerLength else {
                throw DICOMImportError.invalidPart10
            }
            let valueOffset = cursor + header.headerLength
            let key = UInt32(header.group) << 16 | UInt32(header.element)
            if [0x0002_0002, 0x0002_0010, 0x0008_0016, 0x0008_0018,
                0x0008_0060, 0x0020_000d, 0x0020_000e].contains(key) {
                guard length <= 4_096 else { throw DICOMImportError.resourceLimit }
                values[key] = String(decoding: try bytes(at: valueOffset, count: length), as: UTF8.self)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\0 "))
            }
            cursor = valueOffset + length
            if hasRequiredAllowlistValues(values) || key == 0x7fe0_0010 { break }
        }
        let sopClass = values[0x0008_0016] ?? values[0x0002_0002]
        guard let transferSyntax = values[0x0002_0010],
              let sopClass,
              let study = values[0x0020_000d],
              let series = values[0x0020_000e],
              let instance = values[0x0008_0018],
              let modality = values[0x0008_0060],
              let canonicalStudy = KinlogueDICOMUID.canonicalizing(study),
              let canonicalSeries = KinlogueDICOMUID.canonicalizing(series),
              let canonicalInstance = KinlogueDICOMUID.canonicalizing(instance) else {
            throw DICOMImportError.invalidPart10
        }
        return .init(
            transferSyntaxUID: transferSyntax,
            sopClassUID: sopClass,
            studyInstanceUID: canonicalStudy,
            seriesInstanceUID: canonicalSeries,
            sopInstanceUID: canonicalInstance,
            modality: modality
        )
    }

    private func elementHeader(
        at offset: Int
    ) throws -> (group: UInt16, element: UInt16, vr: String, headerLength: Int, length: UInt32) {
        let short = try bytes(at: offset, count: 8)
        let group = uint16(short, 0), element = uint16(short, 2)
        let vr = String(decoding: short[4..<6], as: UTF8.self)
        let long = ["OB", "OD", "OF", "OL", "OV", "OW", "SQ", "UC", "UN", "UR", "UT"].contains(vr)
        if long {
            let header = try bytes(at: offset, count: 12)
            guard header[6] == 0, header[7] == 0 else { throw DICOMImportError.invalidPart10 }
            return (group, element, vr, 12, uint32(header, 8))
        }
        guard vr.utf8.count == 2, vr.utf8.allSatisfy({ (65...90).contains($0) }) else {
            throw DICOMImportError.invalidPart10
        }
        return (group, element, vr, 8, UInt32(uint16(short, 6)))
    }

    private func endOffsetOfUndefinedLengthSequence(
        valueOffset: Int,
        remainingElementBudget: inout Int
    ) throws -> Int {
        enum Container { case sequence, item }
        let maximumContainerDepth = 64
        var containers: [Container] = [.sequence]
        var cursor = valueOffset

        while let container = containers.last {
            remainingElementBudget -= 1
            guard remainingElementBudget >= 0 else {
                throw DICOMImportError.resourceLimit
            }
            let itemHeader = try bytes(at: cursor, count: 8)
            let group = uint16(itemHeader, 0)
            let element = uint16(itemHeader, 2)
            if group == 0xfffe {
                let length = uint32(itemHeader, 4)
                switch element {
                case 0xe000:
                    guard container == .sequence else { throw DICOMImportError.invalidPart10 }
                    cursor += 8
                    if length == UInt32.max {
                        guard containers.count < maximumContainerDepth else {
                            throw DICOMImportError.resourceLimit
                        }
                        containers.append(.item)
                    } else {
                        cursor = try advancing(cursor, by: Int(length))
                    }
                case 0xe00d:
                    guard container == .item, length == 0 else {
                        throw DICOMImportError.invalidPart10
                    }
                    containers.removeLast()
                    cursor += 8
                case 0xe0dd:
                    guard container == .sequence, length == 0 else {
                        throw DICOMImportError.invalidPart10
                    }
                    containers.removeLast()
                    cursor += 8
                    if containers.isEmpty { return cursor }
                default:
                    throw DICOMImportError.invalidPart10
                }
                continue
            }

            guard container == .item else { throw DICOMImportError.invalidPart10 }
            let header = try elementHeader(at: cursor)
            let nestedValueOffset = cursor + header.headerLength
            if header.length == UInt32.max {
                guard header.vr == "SQ", containers.count < maximumContainerDepth else {
                    throw DICOMImportError.invalidPart10
                }
                containers.append(.sequence)
                cursor = nestedValueOffset
            } else {
                cursor = try advancing(nestedValueOffset, by: Int(header.length))
            }
        }
        throw DICOMImportError.invalidPart10
    }

    private func advancing(_ offset: Int, by count: Int) throws -> Int {
        guard offset >= 0, count >= 0, offset <= byteCount - count else {
            throw DICOMImportError.invalidPart10
        }
        return offset + count
    }

    private func bytes(at offset: Int, count: Int) throws -> Data {
        guard offset >= 0, count >= 0, offset <= byteCount - count else {
            throw DICOMImportError.invalidPart10
        }
        var data = Data(count: count)
        let readCount = data.withUnsafeMutableBytes {
            pread(descriptor, $0.baseAddress, count, off_t(offset))
        }
        guard readCount == count else { throw DICOMImportError.invalidPart10 }
        return data
    }

    private func uint16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private func uint32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }

    private func hasRequiredAllowlistValues(_ values: [UInt32: String]) -> Bool {
        values[0x0002_0010] != nil
            && (values[0x0008_0016] != nil || values[0x0002_0002] != nil)
            && values[0x0008_0018] != nil
            && values[0x0008_0060] != nil
            && values[0x0020_000d] != nil
            && values[0x0020_000e] != nil
    }
}

private func hash(descriptor: FileHandle, expectedByteCount: Int) throws -> Data {
    try descriptor.seek(toOffset: 0)
    var hasher = SHA256()
    var remaining = expectedByteCount
    while remaining > 0 {
        let data = try descriptor.read(upToCount: min(64 * 1_024, remaining)) ?? Data()
        guard !data.isEmpty else { throw DICOMImportError.integrityFailure }
        hasher.update(data: data)
        remaining -= data.count
    }
    guard try descriptor.read(upToCount: 1)?.isEmpty != false else {
        throw DICOMImportError.integrityFailure
    }
    try descriptor.seek(toOffset: 0)
    return Data(hasher.finalize())
}

private func validate(
    frame: KinlogueDICOMDecodedFrame,
    matches metadata: DICOMAllowlistMetadata,
    policy: DICOMImportPolicy
) throws {
    guard frame.rows <= policy.maximumRows,
          frame.columns <= policy.maximumColumns,
          frame.sampleBytes.count <= policy.maximumDecodedSampleBytes else {
        throw DICOMImportError.resourceLimit
    }
    do { try frame.validate() } catch { throw DICOMImportError.corruptImage }
    guard let frameStudyUID = KinlogueDICOMUID.canonicalizing(frame.studyInstanceUID),
          let frameSeriesUID = KinlogueDICOMUID.canonicalizing(frame.seriesInstanceUID),
          let frameSOPUID = KinlogueDICOMUID.canonicalizing(frame.sopInstanceUID),
          frame.transferSyntaxUID == metadata.transferSyntaxUID,
          frame.sopClassUID == metadata.sopClassUID,
          frameStudyUID == metadata.studyInstanceUID,
          frameSeriesUID == metadata.seriesInstanceUID,
          frameSOPUID == metadata.sopInstanceUID,
          frame.modality == metadata.modality else {
        throw DICOMImportError.corruptImage
    }
}

private func uidDigest(
    vaultID: UUID,
    scope: DICOMStudyIndex.UIDDigest.Scope,
    uid: String
) -> DICOMStudyIndex.UIDDigest {
    var input = Data(DICOMStudyIndex.UIDDigest.domain.utf8)
    input.append(0)
    input.append(Data(vaultID.uuidString.lowercased().utf8))
    input.append(0)
    input.append(Data(scope.rawValue.utf8))
    input.append(0)
    input.append(Data(uid.utf8))
    return try! .init(scope: scope, digest: ContentDigest.sha256(input))
}

enum DICOMImageAttributesMapper {
    static func attributes(
        for frame: KinlogueDICOMDecodedFrame
    ) throws -> DICOMStudyIndex.ImageAttributes {
        let position = try frame.imagePositionPatient.map {
            try DICOMStudyIndex.Vector3(x: $0[0], y: $0[1], z: $0[2])
        }
        let orientation = frame.imageOrientationPatient
        let row = try orientation.map {
            try DICOMStudyIndex.Vector3(x: $0[0], y: $0[1], z: $0[2])
        }
        let column = try orientation.map {
            try DICOMStudyIndex.Vector3(x: $0[3], y: $0[4], z: $0[5])
        }
        return try .init(
            rows: frame.rows, columns: frame.columns,
            samplesPerPixel: frame.samplesPerPixel,
            bitsAllocated: frame.bitsAllocated, bitsStored: frame.bitsStored,
            highBit: frame.highBit,
            pixelRepresentation: frame.pixelRepresentation == 0 ? .unsigned : .signed,
            photometricInterpretation: frame.photometricInterpretation == "MONOCHROME1"
                ? .monochrome1 : .monochrome2,
            imagePositionPatient: position, imageOrientationPatientRow: row,
            imageOrientationPatientColumn: column, rescaleSlope: frame.rescaleSlope,
            rescaleIntercept: frame.rescaleIntercept, windowCenter: frame.windowCenter,
            windowWidth: frame.windowWidth
        )
    }
}

private func require<T>(_ value: T?) throws -> T {
    guard let value else { throw DICOMImportError.corruptImage }
    return value
}

private func stableContentIdentity(_ staged: VaultDICOMStagedObject) -> Data {
    var data = staged.sha256Digest
    var byteCount = UInt64(staged.byteCount).bigEndian
    withUnsafeBytes(of: &byteCount) { data.append(contentsOf: $0) }
    return data
}
