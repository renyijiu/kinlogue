import Foundation

public enum DomainValidationError: Error, Equatable, Sendable {
    case emptyRequiredText
    case invalidByteCount
    case invalidDigestLength
    case invalidPageNumber
    case invalidNormalizedBounds
    case invalidConfidence
    case invalidTimelineDateSelection
    case invalidCatalogReference
    case duplicateIdentifier
    case invalidFormatVersion
    case invalidGeneration
    case invalidStateTransition
    case emptyReportSources
    case duplicateReportSourceIdentifier
    case invalidReportSourcePageCount
}

public struct FamilyMember: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var displayName: String
    public var disambiguationLabel: String?
    public var isArchived: Bool

    public init(
        id: UUID = UUID(),
        displayName: String,
        disambiguationLabel: String? = nil,
        isArchived: Bool = false
    ) throws {
        let normalizedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            throw DomainValidationError.emptyRequiredText
        }

        self.id = id
        self.displayName = normalizedName
        self.disambiguationLabel = disambiguationLabel?.nilIfBlank
        self.isArchived = isArchived
    }

    /// A stable, non-secret disambiguator. It contains no member-entered content.
    public var stableShortID: String {
        String(id.uuidString.replacingOccurrences(of: "-", with: "").prefix(6)).uppercased()
    }
}

extension String {
    fileprivate var nilIfBlank: String? {
        let normalized = trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}
