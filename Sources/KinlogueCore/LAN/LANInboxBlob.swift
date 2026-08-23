import Foundation

public struct LANInboxBlob: Codable, Identifiable, Hashable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case id
        case sha256Digest
        case byteCount
    }

    public let id: UUID
    public let sha256Digest: Data
    public let byteCount: Int

    public init(
        id: UUID = UUID(),
        sha256Digest: Data,
        byteCount: Int
    ) throws {
        guard sha256Digest.count == 32 else { throw LANInboxError.invalidDigest }
        guard byteCount >= 0 else { throw LANInboxError.invalidByteCount }
        self.id = id
        self.sha256Digest = sha256Digest
        self.byteCount = byteCount
    }

    public var sourceDigest: ReportFingerprint.SourceDigest {
        get throws {
            try ReportFingerprint.SourceDigest(
                sha256Digest: sha256Digest,
                byteCount: byteCount
            )
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(UUID.self, forKey: .id),
                sha256Digest: container.decode(Data.self, forKey: .sha256Digest),
                byteCount: container.decode(Int.self, forKey: .byteCount)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid LAN inbox blob")
            )
        }
    }
}
