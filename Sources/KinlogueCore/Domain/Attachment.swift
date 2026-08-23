import Foundation

public struct Attachment: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let contentTypeIdentifier: String
    public let byteCount: Int
    public let sha256Digest: Data

    public init(
        id: UUID = UUID(),
        contentTypeIdentifier: String,
        byteCount: Int,
        sha256Digest: Data
    ) throws {
        guard !contentTypeIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DomainValidationError.emptyRequiredText
        }
        guard byteCount >= 0 else {
            throw DomainValidationError.invalidByteCount
        }
        guard sha256Digest.count == 32 else {
            throw DomainValidationError.invalidDigestLength
        }

        self.id = id
        self.contentTypeIdentifier = contentTypeIdentifier
        self.byteCount = byteCount
        self.sha256Digest = sha256Digest
    }
}
