import Foundation

/// The independently stored canonical DICOM graph for one study. It is
/// intentionally self-describing: every retained original is declared here,
/// while only `.viewableImage` objects participate in a Series/instance map.
/// This lets inert DICOM attachments remain immutable originals without being
/// presented as images.
public struct DICOMStudyIndex: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let currentOrderingPolicyVersion = 2
    public static let maximumRetainedObjectCount = DICOMStudyFingerprint.maximumObjectCount
    public static let maximumSeriesCount = 4_096

    /// A vault-local, domain-separated digest of a transient DICOM UID.  The
    /// source UID is never persisted, and a digest for one UID role cannot be
    /// substituted for another role.
    public struct UIDDigest: Codable, Hashable, Sendable {
        public static let currentVersion = 1
        public static let domain = "kinlogue.dicom.uid.vault-local"

        public enum Scope: String, Codable, Hashable, Sendable {
            case study
            case series
            case sopInstance
        }

        public let domain: String
        public let version: Int
        public let scope: Scope
        public let digest: Data

        public init(scope: Scope, digest: Data, domain: String = Self.domain) throws {
            guard domain == Self.domain, digest.count == 32 else {
                throw DomainValidationError.invalidDigestLength
            }
            self.domain = domain
            self.version = Self.currentVersion
            self.scope = scope
            self.digest = digest
        }

        private init(domain: String, version: Int, scope: Scope, digest: Data) throws {
            guard domain == Self.domain,
                  version == Self.currentVersion,
                  digest.count == 32 else {
                throw DomainValidationError.invalidDigestLength
            }
            self.domain = domain
            self.version = version
            self.scope = scope
            self.digest = digest
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try decoder.rejectUnknownKeys(["domain", "version", "scope", "digest"])
            try self.init(
                domain: container.decode(String.self, forKey: .domain),
                version: container.decode(Int.self, forKey: .version),
                scope: container.decode(Scope.self, forKey: .scope),
                digest: container.decode(Data.self, forKey: .digest)
            )
        }

    }

    public enum RetainedObjectKind: String, Codable, Hashable, Sendable {
        case viewableImage
        case inertAttachment
    }

    public enum SOPClass: String, Codable, Hashable, Sendable {
        case mrImageStorage
        case inertNonImage
    }

    public enum TransferSyntax: String, Codable, Hashable, Sendable {
        case explicitVRLittleEndian
        case inertAttachment
    }

    public enum Modality: String, Codable, Hashable, Sendable {
        case mr
        case inert
    }

    public enum PixelRepresentation: String, Codable, Hashable, Sendable {
        case unsigned
        case signed
    }

    public enum PhotometricInterpretation: String, Codable, Hashable, Sendable {
        case monochrome1
        case monochrome2
    }

    public enum OrderingProvenance: String, Codable, Hashable, Sendable {
        case geometryProjection
        case instanceNumberFallback
        case stableContentFallback
    }

    public struct Vector3: Codable, Hashable, Sendable {
        public let x: Double
        public let y: Double
        public let z: Double

        public init(x: Double, y: Double, z: Double) throws {
            guard x.isFinite, y.isFinite, z.isFinite else {
                throw DomainValidationError.invalidCatalogReference
            }
            self.x = x
            self.y = y
            self.z = z
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try decoder.rejectUnknownKeys(["x", "y", "z"])
            try self.init(
                x: container.decode(Double.self, forKey: .x),
                y: container.decode(Double.self, forKey: .y),
                z: container.decode(Double.self, forKey: .z)
            )
        }
    }

    public struct ImageAttributes: Codable, Hashable, Sendable {
        public let rows: Int
        public let columns: Int
        public let samplesPerPixel: Int
        public let bitsAllocated: Int
        public let bitsStored: Int
        public let highBit: Int
        public let pixelRepresentation: PixelRepresentation
        public let photometricInterpretation: PhotometricInterpretation
        public let imagePositionPatient: Vector3?
        public let imageOrientationPatientRow: Vector3?
        public let imageOrientationPatientColumn: Vector3?
        public let rescaleSlope: Double
        public let rescaleIntercept: Double
        public let windowCenter: Double?
        public let windowWidth: Double?

        public init(
            rows: Int,
            columns: Int,
            samplesPerPixel: Int,
            bitsAllocated: Int,
            bitsStored: Int,
            highBit: Int,
            pixelRepresentation: PixelRepresentation,
            photometricInterpretation: PhotometricInterpretation,
            imagePositionPatient: Vector3?,
            imageOrientationPatientRow: Vector3?,
            imageOrientationPatientColumn: Vector3?,
            rescaleSlope: Double,
            rescaleIntercept: Double,
            windowCenter: Double?,
            windowWidth: Double?
        ) throws {
            guard (1...8_192).contains(rows), (1...8_192).contains(columns),
                  samplesPerPixel == 1, [8, 16].contains(bitsAllocated),
                  (1...bitsAllocated).contains(bitsStored),
                  (bitsStored - 1...bitsAllocated - 1).contains(highBit),
                  rescaleSlope.isFinite, rescaleSlope != 0, rescaleIntercept.isFinite,
                  (windowCenter == nil) == (windowWidth == nil),
                  windowCenter?.isFinite != false, windowWidth?.isFinite != false,
                  windowWidth.map({ $0 >= 1 }) != false,
                  (imageOrientationPatientRow == nil && imageOrientationPatientColumn == nil)
                    || (imageOrientationPatientRow != nil && imageOrientationPatientColumn != nil) else {
                throw DomainValidationError.invalidCatalogReference
            }
            self.rows = rows
            self.columns = columns
            self.samplesPerPixel = samplesPerPixel
            self.bitsAllocated = bitsAllocated
            self.bitsStored = bitsStored
            self.highBit = highBit
            self.pixelRepresentation = pixelRepresentation
            self.photometricInterpretation = photometricInterpretation
            self.imagePositionPatient = imagePositionPatient
            self.imageOrientationPatientRow = imageOrientationPatientRow
            self.imageOrientationPatientColumn = imageOrientationPatientColumn
            self.rescaleSlope = rescaleSlope
            self.rescaleIntercept = rescaleIntercept
            self.windowCenter = windowCenter
            self.windowWidth = windowWidth
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try decoder.rejectUnknownKeys([
                "rows", "columns", "samplesPerPixel", "bitsAllocated", "bitsStored", "highBit", "pixelRepresentation", "photometricInterpretation", "imagePositionPatient", "imageOrientationPatientRow", "imageOrientationPatientColumn", "rescaleSlope", "rescaleIntercept", "windowCenter", "windowWidth",
            ])
            try self.init(
                rows: container.decode(Int.self, forKey: .rows),
                columns: container.decode(Int.self, forKey: .columns),
                samplesPerPixel: container.decode(Int.self, forKey: .samplesPerPixel),
                bitsAllocated: container.decode(Int.self, forKey: .bitsAllocated),
                bitsStored: container.decode(Int.self, forKey: .bitsStored),
                highBit: container.decode(Int.self, forKey: .highBit),
                pixelRepresentation: container.decode(PixelRepresentation.self, forKey: .pixelRepresentation),
                photometricInterpretation: container.decode(PhotometricInterpretation.self, forKey: .photometricInterpretation),
                imagePositionPatient: container.decodeIfPresent(Vector3.self, forKey: .imagePositionPatient),
                imageOrientationPatientRow: container.decodeIfPresent(Vector3.self, forKey: .imageOrientationPatientRow),
                imageOrientationPatientColumn: container.decodeIfPresent(Vector3.self, forKey: .imageOrientationPatientColumn),
                rescaleSlope: container.decode(Double.self, forKey: .rescaleSlope),
                rescaleIntercept: container.decode(Double.self, forKey: .rescaleIntercept),
                windowCenter: container.decodeIfPresent(Double.self, forKey: .windowCenter),
                windowWidth: container.decodeIfPresent(Double.self, forKey: .windowWidth)
            )
        }
    }

    public struct RetainedObject: Codable, Identifiable, Hashable, Sendable {
        public let attachmentID: Attachment.ID
        public let kind: RetainedObjectKind

        public var id: Attachment.ID { attachmentID }

        public init(attachmentID: Attachment.ID, kind: RetainedObjectKind) {
            self.attachmentID = attachmentID
            self.kind = kind
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try decoder.rejectUnknownKeys(["attachmentID", "kind"])
            self.init(
                attachmentID: try container.decode(UUID.self, forKey: .attachmentID),
                kind: try container.decode(RetainedObjectKind.self, forKey: .kind)
            )
        }
    }

    public struct Instance: Codable, Identifiable, Hashable, Sendable {
        public let id: UUID
        public let attachmentID: Attachment.ID
        public let seriesID: UUID
        public let sopInstanceUIDDigest: UIDDigest
        public let canonicalOrder: Int
        public let sopClass: SOPClass
        public let transferSyntax: TransferSyntax
        public let modality: Modality
        public let attributes: ImageAttributes

        public init(
            id: UUID,
            attachmentID: Attachment.ID,
            seriesID: UUID,
            sopInstanceUIDDigest: UIDDigest,
            canonicalOrder: Int,
            sopClass: SOPClass,
            transferSyntax: TransferSyntax,
            modality: Modality,
            attributes: ImageAttributes
        ) throws {
            guard sopInstanceUIDDigest.scope == .sopInstance, canonicalOrder >= 0,
                  sopClass == .mrImageStorage, transferSyntax == .explicitVRLittleEndian,
                  modality == .mr else {
                throw DomainValidationError.invalidCatalogReference
            }
            self.id = id
            self.attachmentID = attachmentID
            self.seriesID = seriesID
            self.sopInstanceUIDDigest = sopInstanceUIDDigest
            self.canonicalOrder = canonicalOrder
            self.sopClass = sopClass
            self.transferSyntax = transferSyntax
            self.modality = modality
            self.attributes = attributes
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try decoder.rejectUnknownKeys(["id", "attachmentID", "seriesID", "sopInstanceUIDDigest", "canonicalOrder", "sopClass", "transferSyntax", "modality", "attributes"])
            let id = try container.decode(UUID.self, forKey: .id)
            try self.init(
                id: id,
                attachmentID: try container.decode(UUID.self, forKey: .attachmentID),
                seriesID: try container.decode(UUID.self, forKey: .seriesID),
                sopInstanceUIDDigest: container.decode(UIDDigest.self, forKey: .sopInstanceUIDDigest),
                canonicalOrder: try container.decode(Int.self, forKey: .canonicalOrder),
                sopClass: try container.decode(SOPClass.self, forKey: .sopClass),
                transferSyntax: try container.decode(TransferSyntax.self, forKey: .transferSyntax),
                modality: try container.decode(Modality.self, forKey: .modality),
                attributes: try container.decode(ImageAttributes.self, forKey: .attributes)
            )
        }

    }

    public struct Series: Codable, Identifiable, Hashable, Sendable {
        public let id: UUID
        public let ordinal: Int
        public let instanceIDs: [Instance.ID]
        public let seriesUIDDigest: UIDDigest
        public let orderingProvenance: OrderingProvenance

        public init(
            id: UUID,
            ordinal: Int,
            instanceIDs: [Instance.ID],
            seriesUIDDigest: UIDDigest,
            orderingProvenance: OrderingProvenance
        ) throws {
            guard ordinal > 0, !instanceIDs.isEmpty else {
                throw DomainValidationError.invalidCatalogReference
            }
            guard Set(instanceIDs).count == instanceIDs.count else {
                throw DomainValidationError.duplicateIdentifier
            }
            self.id = id
            self.ordinal = ordinal
            self.instanceIDs = instanceIDs
            guard seriesUIDDigest.scope == .series else {
                throw DomainValidationError.invalidCatalogReference
            }
            self.seriesUIDDigest = seriesUIDDigest
            self.orderingProvenance = orderingProvenance
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try decoder.rejectUnknownKeys(["id", "ordinal", "instanceIDs", "seriesUIDDigest", "orderingProvenance"])
            do {
                try self.init(
                    id: container.decode(UUID.self, forKey: .id),
                    ordinal: container.decode(Int.self, forKey: .ordinal),
                    instanceIDs: container.decodeBoundedArray(
                        UUID.self,
                        forKey: .instanceIDs,
                        maximumCount: DICOMStudyIndex.maximumRetainedObjectCount
                    ),
                    seriesUIDDigest: container.decode(UIDDigest.self, forKey: .seriesUIDDigest),
                    orderingProvenance: container.decode(OrderingProvenance.self, forKey: .orderingProvenance)
                )
            } catch {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid DICOM series"
                ))
            }
        }
    }

    public let version: Int
    public let orderingPolicyVersion: Int
    public let studyID: DICOMStudy.ID
    public let studyUIDDigest: UIDDigest
    public let retainedObjects: [RetainedObject]
    public let instances: [Instance]
    public let series: [Series]

    public init(
        version: Int = Self.currentVersion,
        orderingPolicyVersion: Int = Self.currentOrderingPolicyVersion,
        studyID: DICOMStudy.ID,
        studyUIDDigest: UIDDigest,
        retainedObjects: [RetainedObject],
        instances: [Instance],
        series: [Series]
    ) throws {
        guard version == Self.currentVersion,
              orderingPolicyVersion == Self.currentOrderingPolicyVersion else {
            throw DomainValidationError.invalidFormatVersion
        }
        guard !retainedObjects.isEmpty,
              retainedObjects.count <= Self.maximumRetainedObjectCount,
              series.count <= Self.maximumSeriesCount else {
            throw DomainValidationError.invalidCatalogReference
        }
        let instanceIDs = Set(instances.map(\.id))
        let seriesIDs = Set(series.map(\.id))
        guard Set(retainedObjects.map(\.attachmentID)).count == retainedObjects.count,
              instanceIDs.count == instances.count,
              Set(instances.map(\.attachmentID)).count == instances.count,
              seriesIDs.count == series.count,
              Set(series.map(\.ordinal)).count == series.count else {
            throw DomainValidationError.duplicateIdentifier
        }
        guard studyUIDDigest.scope == .study,
              instances.allSatisfy({
                  $0.sopInstanceUIDDigest.scope == .sopInstance && $0.canonicalOrder >= 0
                    && $0.sopClass == .mrImageStorage
                    && $0.transferSyntax == .explicitVRLittleEndian
                    && $0.modality == .mr
              }),
              series.allSatisfy({ $0.seriesUIDDigest.scope == .series }),
              Set(instances.map(\.sopInstanceUIDDigest)).count == instances.count else {
            throw DomainValidationError.invalidCatalogReference
        }
        let retainedByAttachment = Dictionary(
            uniqueKeysWithValues: retainedObjects.map { ($0.attachmentID, $0) }
        )
        let instancesByID = Dictionary(uniqueKeysWithValues: instances.map { ($0.id, $0) })
        guard instances.allSatisfy({ instance in
            retainedByAttachment[instance.attachmentID]?.kind == .viewableImage
        }), instances.allSatisfy({ instance in
            seriesIDs.contains(instance.seriesID)
        }), Set(retainedObjects.filter { $0.kind == .viewableImage }.map(\.attachmentID))
            == Set(instances.map(\.attachmentID)),
            Set(series.map(\.seriesUIDDigest)).count == series.count else {
            throw DomainValidationError.invalidCatalogReference
        }
        let declaredInstanceIDs = Set(series.flatMap(\.instanceIDs))
        guard declaredInstanceIDs == instanceIDs,
              series.allSatisfy({ series in
                  series.instanceIDs.allSatisfy { instanceID in
                      instancesByID[instanceID]?.seriesID == series.id
                  }
              }) else {
            throw DomainValidationError.invalidCatalogReference
        }
        for series in series {
            let ordered = series.instanceIDs.compactMap { instancesByID[$0] }
            guard ordered.count == series.instanceIDs.count,
                  ordered.map(\.canonicalOrder) == Array(0..<ordered.count),
                  Set(ordered.map { $0.attributes.rows }).count == 1,
                  Set(ordered.map { $0.attributes.columns }).count == 1,
                  Set(ordered.map { $0.attributes.samplesPerPixel }).count == 1,
                  Set(ordered.map { $0.attributes.bitsAllocated }).count == 1,
                  Set(ordered.map { $0.attributes.bitsStored }).count == 1,
                  Set(ordered.map { $0.attributes.highBit }).count == 1,
                  Set(ordered.map { $0.attributes.pixelRepresentation }).count == 1,
                  Set(ordered.map { $0.attributes.photometricInterpretation }).count == 1,
                  (series.orderingProvenance != .geometryProjection || ordered.allSatisfy {
                      $0.attributes.imagePositionPatient != nil
                        && $0.attributes.imageOrientationPatientRow != nil
                        && $0.attributes.imageOrientationPatientColumn != nil
                  }) else {
                throw DomainValidationError.invalidCatalogReference
            }
        }
        self.version = version
        self.orderingPolicyVersion = orderingPolicyVersion
        self.studyID = studyID
        self.studyUIDDigest = studyUIDDigest
        self.retainedObjects = retainedObjects
        self.instances = instances
        self.series = series
    }

    /// Validates the independent index against its catalog owner. The index
    /// may contain zero viewable instances when every retained object is inert.
    public func validate(studyID: DICOMStudy.ID, attachmentIDs: Set<Attachment.ID>) throws {
        guard self.studyID == studyID,
              Set(retainedObjects.map(\.attachmentID)) == attachmentIDs else {
            throw DomainValidationError.invalidCatalogReference
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try decoder.rejectUnknownKeys([
            "version", "orderingPolicyVersion", "studyID", "studyUIDDigest", "retainedObjects", "instances", "series",
        ])
        do {
            try self.init(
                version: container.decode(Int.self, forKey: .version),
                orderingPolicyVersion: container.decode(Int.self, forKey: .orderingPolicyVersion),
                studyID: container.decode(UUID.self, forKey: .studyID),
                studyUIDDigest: container.decode(UIDDigest.self, forKey: .studyUIDDigest),
                retainedObjects: container.decodeBoundedArray(
                    RetainedObject.self,
                    forKey: .retainedObjects,
                    maximumCount: Self.maximumRetainedObjectCount
                ),
                instances: container.decodeBoundedArray(
                    Instance.self,
                    forKey: .instances,
                    maximumCount: Self.maximumRetainedObjectCount
                ),
                series: container.decodeBoundedArray(
                    Series.self,
                    forKey: .series,
                    maximumCount: Self.maximumSeriesCount
                )
            )
        } catch {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Invalid DICOM study index"
            ))
        }
    }
}
