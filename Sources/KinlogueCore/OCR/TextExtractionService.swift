import Foundation

public enum ImportedContentKind: String, Codable, Hashable, Sendable {
    case pdf
    case image
}

public struct ValidatedImportedFile: Equatable, Sendable {
    public let data: Data
    public let kind: ImportedContentKind
    public let contentTypeIdentifier: String
    public let sha256Digest: Data
    public let pageCount: Int

    public init(
        data: Data,
        kind: ImportedContentKind,
        contentTypeIdentifier: String,
        sha256Digest: Data,
        pageCount: Int = 1
    ) throws {
        guard sha256Digest.count == 32 else {
            throw DomainValidationError.invalidDigestLength
        }
        guard pageCount > 0 else {
            throw DomainValidationError.invalidReportSourcePageCount
        }
        self.data = data
        self.kind = kind
        self.contentTypeIdentifier = contentTypeIdentifier
        self.sha256Digest = sha256Digest
        self.pageCount = pageCount
    }
}

public protocol TextExtractionService: Sendable {
    func extractText(from file: ValidatedImportedFile) async throws -> [OCRBlock]
}
