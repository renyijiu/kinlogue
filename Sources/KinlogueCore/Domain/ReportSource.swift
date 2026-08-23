import Foundation

public struct ReportSource: Codable, Identifiable, Hashable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case id
        case attachmentID
        case displayName
        case pageCount
    }

    public let id: UUID
    public let attachmentID: Attachment.ID
    public let displayName: String?
    public let pageCount: Int

    public init(
        id: UUID = UUID(),
        attachmentID: Attachment.ID,
        displayName: String? = nil,
        pageCount: Int
    ) throws {
        let normalizedName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedName == nil || !normalizedName!.isEmpty else {
            throw DomainValidationError.emptyRequiredText
        }
        guard pageCount > 0 else {
            throw DomainValidationError.invalidReportSourcePageCount
        }
        self.id = id
        self.attachmentID = attachmentID
        self.displayName = normalizedName
        self.pageCount = pageCount
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(UUID.self, forKey: .id),
                attachmentID: container.decode(Attachment.ID.self, forKey: .attachmentID),
                displayName: container.decodeIfPresent(String.self, forKey: .displayName),
                pageCount: container.decode(Int.self, forKey: .pageCount)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid report source")
            )
        }
    }

    static func unnamedSinglePage(id: UUID, attachmentID: Attachment.ID) -> Self {
        Self(
            id: id,
            attachmentID: attachmentID,
            displayName: nil,
            pageCount: 1,
            validated: ()
        )
    }

    private init(
        id: UUID,
        attachmentID: Attachment.ID,
        displayName: String?,
        pageCount: Int,
        validated: Void
    ) {
        self.id = id
        self.attachmentID = attachmentID
        self.displayName = displayName
        self.pageCount = pageCount
    }
}

/// A report's ordered, non-empty logical source rows.
///
/// Multiple rows may legally reference the same attachment. Row identity is
/// therefore the only unambiguous way to project a file-local page into the
/// report's current logical page order.
public struct ReportSources: Codable, Hashable, Sendable {
    public let elements: [ReportSource]

    public init(_ elements: [ReportSource]) throws {
        guard !elements.isEmpty else {
            throw DomainValidationError.emptyReportSources
        }
        guard Set(elements.map(\.id)).count == elements.count else {
            throw DomainValidationError.duplicateReportSourceIdentifier
        }
        var pageCountByAttachmentID: [Attachment.ID: Int] = [:]
        for source in elements {
            if let existing = pageCountByAttachmentID[source.attachmentID],
               existing != source.pageCount {
                throw DomainValidationError.invalidReportSourcePageCount
            }
            pageCountByAttachmentID[source.attachmentID] = source.pageCount
        }
        self.elements = elements
    }

    static func unnamedSinglePage(ownerID: UUID, attachmentID: Attachment.ID) -> Self {
        Self(
            elements: [.unnamedSinglePage(id: ownerID, attachmentID: attachmentID)],
            validated: ()
        )
    }

    public var count: Int { elements.count }
    public var first: ReportSource { elements[0] }
    public var soleSource: ReportSource? { elements.count == 1 ? elements[0] : nil }
    public var attachmentIDs: [Attachment.ID] { elements.map(\.attachmentID) }

    public func logicalPage(forSourceID sourceID: ReportSource.ID, filePage: Int) -> Int? {
        guard filePage > 0 else { return nil }
        var offset = 0
        for source in elements {
            if source.id == sourceID {
                guard filePage <= source.pageCount else { return nil }
                let result = offset.addingReportingOverflow(filePage)
                return result.overflow ? nil : result.partialValue
            }
            let nextOffset = offset.addingReportingOverflow(source.pageCount)
            guard !nextOffset.overflow else { return nil }
            offset = nextOffset.partialValue
        }
        return nil
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        do {
            try self.init(container.decode([ReportSource].self))
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Report sources must be non-empty with unique row identities"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(elements)
    }

    private init(elements: [ReportSource], validated: Void) {
        self.elements = elements
    }
}
