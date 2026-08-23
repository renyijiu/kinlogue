import Foundation

public enum SourceFieldEntryMethod: String, Codable, Hashable, Sendable {
    case manual
}

public struct SourceReference: Codable, Hashable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case sourceID
        case attachmentID
        case filePageNumber
        case boundingBox
        case blockID
    }

    public let sourceID: ReportSource.ID?
    public let attachmentID: Attachment.ID?
    public let filePageNumber: Int
    public let boundingBox: NormalizedRect?
    public let blockID: OCRBlock.ID?

    public init(
        sourceID: ReportSource.ID,
        attachmentID: Attachment.ID,
        filePageNumber: Int,
        boundingBox: NormalizedRect? = nil,
        blockID: OCRBlock.ID? = nil
    ) throws {
        guard filePageNumber > 0 else {
            throw DomainValidationError.invalidPageNumber
        }
        self.sourceID = sourceID
        self.attachmentID = attachmentID
        self.filePageNumber = filePageNumber
        self.boundingBox = boundingBox
        self.blockID = blockID
    }

    /// Transitional construction used while OCR is source-agnostic. Storage
    /// migration and report confirmation attach the stable source identity.
    public init(
        pageNumber: Int,
        boundingBox: NormalizedRect? = nil,
        blockID: OCRBlock.ID? = nil
    ) throws {
        guard pageNumber > 0 else {
            throw DomainValidationError.invalidPageNumber
        }
        sourceID = nil
        attachmentID = nil
        filePageNumber = pageNumber
        self.boundingBox = boundingBox
        self.blockID = blockID
    }

    public var pageNumber: Int { filePageNumber }

    /// Projects this file-local reference into the report's current ordered
    /// logical pages. The projected value is derived UI state and is never
    /// persisted in the reference wire format.
    public func logicalPage(in sources: ReportSources) -> Int? {
        guard let sourceID, let attachmentID,
              let source = sources.elements.first(where: { $0.id == sourceID }),
              source.attachmentID == attachmentID,
              filePageNumber <= source.pageCount else {
            return nil
        }
        return sources.logicalPage(forSourceID: sourceID, filePage: filePageNumber)
    }

    public func attributed(to source: ReportSource) throws -> Self {
        try Self(
            sourceID: source.id,
            attachmentID: source.attachmentID,
            filePageNumber: filePageNumber,
            boundingBox: boundingBox,
            blockID: blockID
        )
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                sourceID: container.decode(ReportSource.ID.self, forKey: .sourceID),
                attachmentID: container.decode(Attachment.ID.self, forKey: .attachmentID),
                filePageNumber: container.decode(Int.self, forKey: .filePageNumber),
                boundingBox: container.decodeIfPresent(NormalizedRect.self, forKey: .boundingBox),
                blockID: container.decodeIfPresent(OCRBlock.ID.self, forKey: .blockID)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid source reference")
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        guard let sourceID, let attachmentID else {
            throw EncodingError.invalidValue(
                self,
                .init(
                    codingPath: encoder.codingPath,
                    debugDescription: "A persisted source reference requires stable source identity"
                )
            )
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sourceID, forKey: .sourceID)
        try container.encode(attachmentID, forKey: .attachmentID)
        try container.encode(filePageNumber, forKey: .filePageNumber)
        try container.encodeIfPresent(boundingBox, forKey: .boundingBox)
        try container.encodeIfPresent(blockID, forKey: .blockID)
    }
}

public struct SourceField: Codable, Hashable, Sendable {
    public let originalTranscription: String
    public let correctedTranscription: String?
    public let references: [SourceReference]
    /// `nil` preserves the legacy meaning: text projected from the imported
    /// report. Manual text is explicit so the UI never invents OCR provenance.
    public let entryMethod: SourceFieldEntryMethod?

    public init(
        originalTranscription: String,
        correctedTranscription: String? = nil,
        references: [SourceReference] = [],
        entryMethod: SourceFieldEntryMethod? = nil
    ) throws {
        let original = originalTranscription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty else {
            throw DomainValidationError.emptyRequiredText
        }
        let correction = correctedTranscription?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let correction, correction.isEmpty {
            throw DomainValidationError.emptyRequiredText
        }

        self.originalTranscription = original
        self.correctedTranscription = correction
        self.references = references
        self.entryMethod = entryMethod
    }

    /// The confirmed verbatim transcription. A correction replaces OCR text, not its meaning.
    public var transcription: String {
        correctedTranscription ?? originalTranscription
    }

    public func correctingTranscription(to value: String) throws -> Self {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return try Self(
            originalTranscription: originalTranscription,
            correctedTranscription: normalized == originalTranscription ? nil : normalized,
            references: references,
            entryMethod: entryMethod
        )
    }

    public static func manualEntry(_ value: String) throws -> Self {
        try Self(
            originalTranscription: value,
            references: [],
            entryMethod: .manual
        )
    }

    public func attributedAndValidated(for sources: ReportSources) throws -> Self {
        let sourceByID = Dictionary(uniqueKeysWithValues: sources.elements.map { ($0.id, $0) })
        let attributed = try references.map { reference -> SourceReference in
            if let sourceID = reference.sourceID,
               let attachmentID = reference.attachmentID {
                guard let source = sourceByID[sourceID],
                      source.attachmentID == attachmentID,
                      reference.filePageNumber <= source.pageCount else {
                    throw DomainValidationError.invalidCatalogReference
                }
                return reference
            }
            guard let source = sources.soleSource else {
                throw DomainValidationError.invalidCatalogReference
            }
            guard reference.filePageNumber <= source.pageCount else {
                throw DomainValidationError.invalidPageNumber
            }
            return try reference.attributed(to: source)
        }
        return try Self(
            originalTranscription: originalTranscription,
            correctedTranscription: correctedTranscription,
            references: attributed,
            entryMethod: entryMethod
        )
    }
}

public struct UserNote: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let text: String

    public init(id: UUID = UUID(), text: String) throws {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw DomainValidationError.emptyRequiredText
        }
        self.id = id
        self.text = normalized
    }
}
