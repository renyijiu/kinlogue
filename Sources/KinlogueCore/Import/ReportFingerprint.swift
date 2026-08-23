import Foundation

public struct ReportFingerprint: Codable, Hashable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case version
        case sources
    }
    public static let currentVersion = 1
    /// A decoder-safety ceiling for fingerprints outside the more restrictive
    /// LAN inbox context. The LAN wire always supplies its per-report limit.
    static let maximumDecodedSourceCount = 20_000

    public struct SourceDigest: Codable, Hashable, Sendable {
        private enum CodingKeys: String, CodingKey {
            case sha256Digest
            case byteCount
        }
        public let sha256Digest: Data
        public let byteCount: Int

        public init(sha256Digest: Data, byteCount: Int) throws {
            guard sha256Digest.count == 32 else {
                throw DomainValidationError.invalidDigestLength
            }
            guard byteCount >= 0 else {
                throw DomainValidationError.invalidByteCount
            }
            self.sha256Digest = sha256Digest
            self.byteCount = byteCount
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            do {
                try self.init(
                    sha256Digest: container.decode(Data.self, forKey: .sha256Digest),
                    byteCount: container.decode(Int.self, forKey: .byteCount)
                )
            } catch {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "Invalid source digest")
                )
            }
        }
    }

    public let version: Int
    public let sources: [SourceDigest]

    public init(version: Int = Self.currentVersion, sources: [SourceDigest]) throws {
        guard version == Self.currentVersion else {
            throw DomainValidationError.invalidFormatVersion
        }
        guard !sources.isEmpty else {
            throw DomainValidationError.emptyReportSources
        }
        self.version = version
        self.sources = sources.sorted(by: Self.precedes)
    }

    public init(sources: ReportSources, attachments: [Attachment]) throws {
        guard Set(attachments.map(\.id)).count == attachments.count else {
            throw DomainValidationError.invalidCatalogReference
        }
        let byID = Dictionary(uniqueKeysWithValues: attachments.map { ($0.id, $0) })
        let digests = try sources.elements.map { source -> SourceDigest in
            guard let attachment = byID[source.attachmentID] else {
                throw DomainValidationError.invalidCatalogReference
            }
            return try SourceDigest(
                sha256Digest: attachment.sha256Digest,
                byteCount: attachment.byteCount
            )
        }
        try self.init(sources: digests)
    }

    public init(from decoder: any Decoder) throws {
        try self.init(
            from: decoder,
            maximumSourceCount: Self.maximumDecodedSourceCount
        )
    }

    init(from decoder: any Decoder, maximumSourceCount: Int) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        let decodedSources = try container.decodeBoundedArray(
            SourceDigest.self,
            forKey: .sources,
            maximumCount: maximumSourceCount
        )
        do {
            let validated = try Self(version: version, sources: decodedSources)
            guard validated.sources == decodedSources else {
                throw DomainValidationError.invalidCatalogReference
            }
            self = validated
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid report fingerprint")
            )
        }
    }

    private static func precedes(_ lhs: SourceDigest, _ rhs: SourceDigest) -> Bool {
        if lhs.sha256Digest != rhs.sha256Digest {
            return lhs.sha256Digest.lexicographicallyPrecedes(rhs.sha256Digest)
        }
        return lhs.byteCount < rhs.byteCount
    }
}

extension KeyedDecodingContainer {
    func decodeReportFingerprint(
        forKey key: Key,
        maximumSourceCount: Int
    ) throws -> ReportFingerprint {
        try ReportFingerprint(
            from: superDecoder(forKey: key),
            maximumSourceCount: maximumSourceCount
        )
    }

    func decodeReportFingerprintIfPresent(
        forKey key: Key,
        maximumSourceCount: Int
    ) throws -> ReportFingerprint? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        return try decodeReportFingerprint(
            forKey: key,
            maximumSourceCount: maximumSourceCount
        )
    }
}
