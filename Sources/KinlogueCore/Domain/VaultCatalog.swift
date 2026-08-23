import Foundation

public struct VaultCatalog: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 3
    public static let maximumMemberCount = 256
    public static let maximumRecordCount = 20_000
    public static let maximumAttachmentCount = 20_000
    public static let maximumImportDraftCount = 20_000
    public static let maximumDICOMStudyCount = 256
    public static let maximumRetainedDICOMObjectCount = 10_000

    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case vaultID
        case generation
        case members
        case records
        case attachments
        case importDrafts
        case dicomStudies
    }

    public let formatVersion: Int
    public let vaultID: UUID
    public let generation: UInt64
    public var members: [FamilyMember]
    public var records: [HealthRecord]
    public var attachments: [Attachment]
    public var importDrafts: [ImportDraft]
    public var dicomStudies: [DICOMStudy]

    public init(
        formatVersion: Int = Self.currentFormatVersion,
        vaultID: UUID,
        generation: UInt64,
        members: [FamilyMember] = [],
        records: [HealthRecord] = [],
        attachments: [Attachment] = [],
        importDrafts: [ImportDraft] = [],
        dicomStudies: [DICOMStudy] = []
    ) throws {
        try Self.validate(
            formatVersion: formatVersion,
            generation: generation,
            members: members,
            records: records,
            attachments: attachments,
            importDrafts: importDrafts,
            dicomStudies: dicomStudies
        )

        self.formatVersion = formatVersion
        self.vaultID = vaultID
        self.generation = generation
        self.members = members
        self.records = records
        self.attachments = attachments
        self.importDrafts = importDrafts
        self.dicomStudies = dicomStudies
    }

    public func validate() throws {
        try Self.validate(
            formatVersion: formatVersion,
            generation: generation,
            members: members,
            records: records,
            attachments: attachments,
            importDrafts: importDrafts,
            dicomStudies: dicomStudies
        )
    }

    /// The immutable local objects reachable from this catalog.
    ///
    /// The result is de-duplicated and canonically ordered so snapshotting code
    /// never needs to enumerate the vault's object directory. Catalog and
    /// descriptor objects are generation metadata and are therefore added by
    /// the storage layer, not by this domain-level object graph.
    public var reachableObjectReferences: [VaultObjectReference] {
        // Every attachment described by the catalog is required by
        // Vault validation, including metadata retained briefly after
        // a record/draft transition. A portable snapshot must therefore carry
        // all of them, not only those currently referenced by a record.
        let references = attachments.map {
            VaultObjectReference(id: $0.id, kind: .attachment)
        } + Set(
            importDrafts.compactMap(\.documentObjectID)
                + records.compactMap(\.ocrDocumentObjectID)
        ).map {
            VaultObjectReference(id: $0, kind: .ocr)
        } + dicomStudies.map {
            VaultObjectReference(id: $0.indexObjectID, kind: .record)
        }
        return Set(references).sorted { lhs, rhs in
            if lhs.kind.rawValue != rhs.kind.rawValue {
                return lhs.kind.rawValue < rhs.kind.rawValue
            }
            return lhs.id.uuidString.lowercased() < rhs.id.uuidString.lowercased()
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try decoder.rejectUnknownKeys([
            "formatVersion", "vaultID", "generation", "members", "records", "attachments", "importDrafts", "dicomStudies",
        ])
        let formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        let vaultID = try container.decode(UUID.self, forKey: .vaultID)
        let generation = try container.decode(UInt64.self, forKey: .generation)
        let members = try container.decodeBoundedArray(
            FamilyMember.self, forKey: .members, maximumCount: Self.maximumMemberCount
        )
        let records = try container.decodeBoundedArray(
            HealthRecord.self, forKey: .records, maximumCount: Self.maximumRecordCount
        )
        let attachments = try container.decodeBoundedArray(
            Attachment.self, forKey: .attachments, maximumCount: Self.maximumAttachmentCount
        )
        let importDrafts = try container.decodeBoundedArray(
            ImportDraft.self, forKey: .importDrafts, maximumCount: Self.maximumImportDraftCount
        )
        let dicomStudies = try container.decodeBoundedArray(
            DICOMStudy.self, forKey: .dicomStudies, maximumCount: Self.maximumDICOMStudyCount
        )

        do {
            try Self.validate(
                formatVersion: formatVersion,
                generation: generation,
                members: members,
                records: records,
                attachments: attachments,
                importDrafts: importDrafts,
                dicomStudies: dicomStudies
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Catalog failed structural validation"
                )
            )
        }

        self.formatVersion = formatVersion
        self.vaultID = vaultID
        self.generation = generation
        self.members = members
        self.records = records
        self.attachments = attachments
        self.importDrafts = importDrafts
        self.dicomStudies = dicomStudies
    }

    public func encode(to encoder: any Encoder) throws {
        do {
            try validate()
        } catch {
            throw EncodingError.invalidValue(
                self,
                .init(
                    codingPath: encoder.codingPath,
                    debugDescription: "Catalog failed structural validation"
                )
            )
        }

        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(formatVersion, forKey: .formatVersion)
        try container.encode(vaultID, forKey: .vaultID)
        try container.encode(generation, forKey: .generation)
        try container.encode(members, forKey: .members)
        try container.encode(records, forKey: .records)
        try container.encode(attachments, forKey: .attachments)
        try container.encode(importDrafts, forKey: .importDrafts)
        try container.encode(dicomStudies, forKey: .dicomStudies)
    }

    private static func validate(
        formatVersion: Int,
        generation: UInt64,
        members: [FamilyMember],
        records: [HealthRecord],
        attachments: [Attachment],
        importDrafts: [ImportDraft],
        dicomStudies: [DICOMStudy]
    ) throws {
        guard formatVersion == currentFormatVersion else {
            throw DomainValidationError.invalidFormatVersion
        }
        guard generation > 0 else {
            throw DomainValidationError.invalidGeneration
        }
        guard members.count <= maximumMemberCount,
              records.count <= maximumRecordCount,
              attachments.count <= maximumAttachmentCount,
              importDrafts.count <= maximumImportDraftCount,
              dicomStudies.count <= maximumDICOMStudyCount else {
            throw DomainValidationError.invalidCatalogReference
        }
        guard members.haveUniqueIDs,
              records.haveUniqueIDs,
              attachments.haveUniqueIDs,
              importDrafts.haveUniqueIDs,
              dicomStudies.haveUniqueIDs else {
            throw DomainValidationError.duplicateIdentifier
        }
        guard records.allSatisfy({ $0.hasUniqueDateCandidateIDs }) else {
            throw DomainValidationError.duplicateIdentifier
        }

        let memberIDs = Set(members.map(\.id))
        let attachmentIDs = Set(attachments.map(\.id))
        let attachmentsByID = Dictionary(uniqueKeysWithValues: attachments.map { ($0.id, $0) })
        guard records.allSatisfy({ record in
            memberIDs.contains(record.memberID)
                && record.sources.elements.allSatisfy {
                    attachmentIDs.contains($0.attachmentID)
                }
                && record.hasValidTimelineDateSelection
                && record.hasValidSourceReferences
        }), importDrafts.allSatisfy({ draft in
            draft.sources.elements.allSatisfy {
                attachmentIDs.contains($0.attachmentID)
            }
                && draft.isStructurallyValid
                && (draft.memberID == nil || memberIDs.contains(draft.memberID!))
        }) else {
            throw DomainValidationError.invalidCatalogReference
        }

        var pageCountByAttachmentID: [Attachment.ID: Int] = [:]
        let allSources = records.flatMap(\.sources.elements)
            + importDrafts.flatMap(\.sources.elements)
        for source in allSources {
            if let existing = pageCountByAttachmentID[source.attachmentID],
               existing != source.pageCount {
                throw DomainValidationError.invalidReportSourcePageCount
            }
            pageCountByAttachmentID[source.attachmentID] = source.pageCount
        }

        let documentIDs = importDrafts.compactMap(\.documentObjectID)
            + records.compactMap(\.ocrDocumentObjectID)
        guard Set(documentIDs).count == documentIDs.count else {
            throw DomainValidationError.duplicateIdentifier
        }

        let indexObjectIDs = dicomStudies.map(\.indexObjectID)
        guard Set(indexObjectIDs).count == indexObjectIDs.count,
              Set(dicomStudies.map(\.fingerprint)).count == dicomStudies.count else {
            throw DomainValidationError.duplicateIdentifier
        }
        guard Set(dicomStudies.flatMap(\.attachmentIDs)).count
                <= Self.maximumRetainedDICOMObjectCount else {
            throw DomainValidationError.invalidCatalogReference
        }
        guard dicomStudies.allSatisfy({ study in
            let studyAttachmentIDs = Set(study.attachmentIDs)
            let sourceDigests = study.attachmentIDs.compactMap { attachmentID in
                attachmentsByID[attachmentID].map {
                    try? DICOMStudyFingerprint.ObjectDigest(
                        sha256Digest: $0.sha256Digest,
                        byteCount: $0.byteCount
                    )
                }
            }
            guard studyAttachmentIDs.isSubset(of: attachmentIDs),
                  sourceDigests.count == study.attachmentIDs.count,
                  !sourceDigests.contains(where: { $0 == nil }) else {
                return false
            }
            let digests = sourceDigests.compactMap { $0 }
            guard (try? DICOMStudyFingerprint(objects: digests)) == study.fingerprint else {
                return false
            }
            switch study.state {
            case .needsReview:
                return true
            case .confirmed:
                guard let memberID = study.confirmedMemberID else { return false }
                return members.contains { $0.id == memberID && !$0.isArchived }
            }
        }) else {
            throw DomainValidationError.invalidCatalogReference
        }
    }
}

private extension Array where Element: Identifiable, Element.ID: Hashable {
    var haveUniqueIDs: Bool {
        Set(map(\.id)).count == count
    }
}
