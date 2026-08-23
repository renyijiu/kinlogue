import Foundation

/// Persistent, privacy-minimized identity for one imported DICOM examination.
/// Raw DICOM UIDs are deliberately transient importer input and never appear
/// in this type.
public struct DICOMStudyFingerprint: Codable, Hashable, Sendable {
    public static let currentVersion = 1
    public static let maximumObjectCount = 2_000
    public static let domain = "kinlogue.dicom.study-fingerprint"

    public struct ObjectDigest: Codable, Hashable, Sendable {
        public let sha256Digest: Data
        public let byteCount: Int

        public init(sha256Digest: Data, byteCount: Int) throws {
            guard sha256Digest.count == 32 else {
                throw DomainValidationError.invalidDigestLength
            }
            guard byteCount >= 0 else { throw DomainValidationError.invalidByteCount }
            self.sha256Digest = sha256Digest
            self.byteCount = byteCount
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try decoder.rejectUnknownKeys(["sha256Digest", "byteCount"])
            do {
                try self.init(
                    sha256Digest: container.decode(Data.self, forKey: .sha256Digest),
                    byteCount: container.decode(Int.self, forKey: .byteCount)
                )
            } catch {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid DICOM object digest"
                ))
            }
        }
    }

    public let version: Int
    public let domain: String
    /// Explicit so a bounded decoder can reject a payload that lies about its
    /// logical member count before later code treats the fingerprint as an ID.
    public let uniqueObjectCount: Int
    public let objects: [ObjectDigest]

    public init(version: Int = Self.currentVersion, objects: [ObjectDigest]) throws {
        guard version == Self.currentVersion else {
            throw DomainValidationError.invalidFormatVersion
        }
        guard !objects.isEmpty, objects.count <= Self.maximumObjectCount else {
            throw DomainValidationError.invalidCatalogReference
        }
        let ordered = objects.sorted(by: Self.precedes)
        guard Set(ordered).count == ordered.count else {
            throw DomainValidationError.duplicateIdentifier
        }
        self.version = version
        self.domain = Self.domain
        self.uniqueObjectCount = ordered.count
        self.objects = ordered
    }

    private init(version: Int, domain: String, uniqueObjectCount: Int, objects: [ObjectDigest]) throws {
        try self.init(version: version, objects: objects)
        guard domain == Self.domain, uniqueObjectCount == self.objects.count else {
            throw DomainValidationError.invalidCatalogReference
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try decoder.rejectUnknownKeys(["version", "domain", "uniqueObjectCount", "objects"])
        do {
            try self.init(
                version: container.decode(Int.self, forKey: .version),
                domain: container.decode(String.self, forKey: .domain),
                uniqueObjectCount: container.decode(Int.self, forKey: .uniqueObjectCount),
                objects: container.decodeBoundedArray(
                    ObjectDigest.self,
                    forKey: .objects,
                    maximumCount: Self.maximumObjectCount
                )
            )
        } catch {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Invalid DICOM study fingerprint"
            ))
        }
    }

    private static func precedes(_ lhs: ObjectDigest, _ rhs: ObjectDigest) -> Bool {
        if lhs.sha256Digest != rhs.sha256Digest {
            return lhs.sha256Digest.lexicographicallyPrecedes(rhs.sha256Digest)
        }
        return lhs.byteCount < rhs.byteCount
    }

    /// Canonical, length-framed identity input for a future digest operation.
    /// It commits to a fixed domain/version/count and sorted `(digest,length)` pairs;
    /// callers must not hash a JSON representation instead.
    public var canonicalIdentityBytes: Data {
        var result = Data(Self.domain.utf8)
        result.append(0)
        result.append(contentsOf: Self.uint64Bytes(UInt64(version)))
        result.append(contentsOf: Self.uint64Bytes(UInt64(uniqueObjectCount)))
        for object in objects {
            result.append(contentsOf: Self.uint64Bytes(UInt64(object.sha256Digest.count)))
            result.append(object.sha256Digest)
            result.append(contentsOf: Self.uint64Bytes(UInt64(object.byteCount)))
        }
        return result
    }

    private static func uint64Bytes(_ value: UInt64) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian, Array.init)
    }
}

public enum DICOMStudyState: String, Codable, Hashable, Sendable {
    case needsReview
    case confirmed
}

/// One catalog-owned DICOM graph. The `.record` object named by
/// `indexObjectID` is a self-describing `DICOMStudyIndex`; attachments are
/// immutable originals. Only confirmation metadata can change after publish.
public struct DICOMStudy: Codable, Identifiable, Hashable, Sendable {
    public static let maximumAttachmentCount = DICOMStudyFingerprint.maximumObjectCount

    public let id: UUID
    public let state: DICOMStudyState
    public let fingerprint: DICOMStudyFingerprint
    public let indexObjectID: UUID
    public let attachmentIDs: [Attachment.ID]
    public let confirmedMemberID: FamilyMember.ID?
    public let effectiveDate: Date?

    public init(
        id: UUID = UUID(),
        state: DICOMStudyState,
        fingerprint: DICOMStudyFingerprint,
        indexObjectID: UUID,
        attachmentIDs: [Attachment.ID],
        confirmedMemberID: FamilyMember.ID? = nil,
        effectiveDate: Date? = nil
    ) throws {
        guard !attachmentIDs.isEmpty,
              attachmentIDs.count <= Self.maximumAttachmentCount,
              Set(attachmentIDs).count == attachmentIDs.count,
              attachmentIDs.count == fingerprint.objects.count else {
            throw DomainValidationError.invalidCatalogReference
        }
        let confirmationIsPresent = confirmedMemberID != nil || effectiveDate != nil
        switch state {
        case .needsReview:
            guard !confirmationIsPresent else {
                throw DomainValidationError.invalidStateTransition
            }
        case .confirmed:
            guard let effectiveDate,
                  confirmedMemberID != nil,
                  effectiveDate.timeIntervalSinceReferenceDate.isFinite else {
                throw DomainValidationError.invalidStateTransition
            }
        }
        self.id = id
        self.state = state
        self.fingerprint = fingerprint
        self.indexObjectID = indexObjectID
        self.attachmentIDs = attachmentIDs.sorted(by: Self.uuidPrecedes)
        self.confirmedMemberID = confirmedMemberID
        self.effectiveDate = effectiveDate
    }

    public func confirmed(memberID: FamilyMember.ID, effectiveDate: Date) throws -> Self {
        try Self(
            id: id,
            state: .confirmed,
            fingerprint: fingerprint,
            indexObjectID: indexObjectID,
            attachmentIDs: attachmentIDs,
            confirmedMemberID: memberID,
            effectiveDate: effectiveDate
        )
    }

    public func reassigning(memberID: FamilyMember.ID, effectiveDate: Date) throws -> Self {
        try confirmed(memberID: memberID, effectiveDate: effectiveDate)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try decoder.rejectUnknownKeys([
            "id", "state", "fingerprint", "indexObjectID", "attachmentIDs", "confirmedMemberID", "effectiveDate",
        ])
        do {
            try self.init(
                id: container.decode(UUID.self, forKey: .id),
                state: container.decode(DICOMStudyState.self, forKey: .state),
                fingerprint: container.decode(DICOMStudyFingerprint.self, forKey: .fingerprint),
                indexObjectID: container.decode(UUID.self, forKey: .indexObjectID),
                attachmentIDs: container.decodeBoundedArray(
                    UUID.self,
                    forKey: .attachmentIDs,
                    maximumCount: Self.maximumAttachmentCount
                ),
                confirmedMemberID: container.decodeIfPresent(UUID.self, forKey: .confirmedMemberID),
                effectiveDate: container.decodeIfPresent(Date.self, forKey: .effectiveDate)
            )
        } catch {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Invalid DICOM study"
            ))
        }
    }

    private static func uuidPrecedes(_ lhs: UUID, _ rhs: UUID) -> Bool {
        lhs.uuidString.lowercased() < rhs.uuidString.lowercased()
    }
}
