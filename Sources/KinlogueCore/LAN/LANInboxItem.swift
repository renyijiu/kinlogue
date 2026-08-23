import Foundation

public struct LANInboxDisplayName: Codable, Hashable, Sendable {
    public static let maxUTF8ByteCount = 1_024
    public let rawValue: String

    public init(rawValue: String) throws {
        let normalized = rawValue
            .precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let forbiddenScalars = normalized.unicodeScalars.contains { scalar in
            CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet.illegalCharacters.contains(scalar)
                || scalar == "/" || scalar == "\\"
                || (0x202A...0x202E).contains(scalar.value)
                || (0x2066...0x2069).contains(scalar.value)
        }
        guard !normalized.isEmpty,
              normalized != ".",
              normalized != "..",
              normalized.utf8.count <= Self.maxUTF8ByteCount,
              !forbiddenScalars else {
            throw LANInboxError.invalidDisplayName
        }
        self.rawValue = normalized
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        do {
            try self.init(rawValue: container.decode(String.self))
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid LAN inbox display name"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct LANInboxDerivedArtifact: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let sha256Digest: Data
    public let byteCount: Int

    public init(id: UUID = UUID(), sha256Digest: Data, byteCount: Int) throws {
        guard sha256Digest.count == 32 else { throw LANInboxError.invalidDigest }
        guard byteCount >= 0 else { throw LANInboxError.invalidByteCount }
        self.id = id
        self.sha256Digest = sha256Digest
        self.byteCount = byteCount
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
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid derived artifact")
            )
        }
    }
}

public enum LANInboxFileIssue: String, Codable, CaseIterable, Hashable, Sendable {
    case unsupportedContent
    case preprocessingFailed
    case integrityMismatch
    case storageFailure
}

public struct LANInboxContentIdentity: Codable, Hashable, Sendable {
    public let sha256Digest: Data
    public let byteCount: Int

    public init(sha256Digest: Data, byteCount: Int) throws {
        guard sha256Digest.count == 32 else { throw LANInboxError.invalidDigest }
        guard byteCount >= 0 else { throw LANInboxError.invalidByteCount }
        self.sha256Digest = sha256Digest
        self.byteCount = byteCount
    }

    public var reportSourceDigest: ReportFingerprint.SourceDigest {
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
                sha256Digest: container.decode(Data.self, forKey: .sha256Digest),
                byteCount: container.decode(Int.self, forKey: .byteCount)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid content identity")
            )
        }
    }
}

public enum LANInboxItemState: Codable, Hashable, Sendable {
    case stored(blobID: LANInboxBlob.ID)
    case preprocessing(blobID: LANInboxBlob.ID, attemptID: UUID)
    case reviewable(blobID: LANInboxBlob.ID, derived: LANInboxDerivedArtifact)
    case unsupported(blobID: LANInboxBlob.ID, issue: LANInboxFileIssue)
    case failed(blobID: LANInboxBlob.ID, issue: LANInboxFileIssue)
    case integrityFailed(blobID: LANInboxBlob.ID, issue: LANInboxFileIssue)
}

public struct LANInboxItem: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let originatingSessionID: UUID
    public let displayName: LANInboxDisplayName
    public let receivedAt: Date
    public let sequence: UInt64
    public let revision: UInt64
    public let contentIdentity: LANInboxContentIdentity
    public let state: LANInboxItemState

    public init(
        id: UUID = UUID(),
        originatingSessionID: UUID,
        displayName: LANInboxDisplayName,
        receivedAt: Date,
        sequence: UInt64,
        revision: UInt64 = 0,
        contentIdentity: LANInboxContentIdentity,
        state: LANInboxItemState
    ) throws {
        guard receivedAt.timeIntervalSinceReferenceDate.isFinite,
              Self.isValid(state) else {
            throw LANInboxError.invalidState
        }
        self.id = id
        self.originatingSessionID = originatingSessionID
        self.displayName = displayName
        self.receivedAt = receivedAt
        self.sequence = sequence
        self.revision = revision
        self.contentIdentity = contentIdentity
        self.state = state
    }

    public var blobID: LANInboxBlob.ID {
        switch state {
        case let .stored(blobID),
             let .preprocessing(blobID, _),
             let .reviewable(blobID, _),
             let .unsupported(blobID, _),
             let .failed(blobID, _),
             let .integrityFailed(blobID, _):
            blobID
        }
    }

    public var attemptID: UUID? {
        if case let .preprocessing(_, attemptID) = state { return attemptID }
        return nil
    }

    public var derivedArtifact: LANInboxDerivedArtifact? {
        if case let .reviewable(_, derived) = state { return derived }
        return nil
    }

    public var issue: LANInboxFileIssue? {
        switch state {
        case let .unsupported(_, issue),
             let .failed(_, issue),
             let .integrityFailed(_, issue):
            issue
        default:
            nil
        }
    }

    public var isReviewable: Bool {
        if case .reviewable = state { return true }
        return false
    }

    public func transitioning(
        to destination: LANInboxItemState,
        expectedRevision: UInt64,
        expectedAttemptID: UUID? = nil
    ) throws -> Self {
        guard revision == expectedRevision,
              attemptID == expectedAttemptID else {
            throw LANInboxError.staleRevision
        }
        guard blobID == Self.blobID(in: destination),
              Self.canTransition(from: state, to: destination) else {
            throw LANInboxError.invalidState
        }
        let next = revision.addingReportingOverflow(1)
        guard !next.overflow else { throw LANInboxError.invalidRevision }
        return try Self(
            id: id,
            originatingSessionID: originatingSessionID,
            displayName: displayName,
            receivedAt: receivedAt,
            sequence: sequence,
            revision: next.partialValue,
            contentIdentity: contentIdentity,
            state: destination
        )
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(UUID.self, forKey: .id),
                originatingSessionID: container.decode(UUID.self, forKey: .originatingSessionID),
                displayName: container.decode(LANInboxDisplayName.self, forKey: .displayName),
                receivedAt: container.decode(Date.self, forKey: .receivedAt),
                sequence: container.decode(UInt64.self, forKey: .sequence),
                revision: container.decode(UInt64.self, forKey: .revision),
                contentIdentity: container.decode(
                    LANInboxContentIdentity.self,
                    forKey: .contentIdentity
                ),
                state: container.decode(LANInboxItemState.self, forKey: .state)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid inbox item")
            )
        }
    }

    private static func isValid(_ state: LANInboxItemState) -> Bool {
        switch state {
        case .stored, .preprocessing, .reviewable:
            true
        case let .unsupported(_, issue):
            issue == .unsupportedContent
        case let .failed(_, issue):
            issue == .preprocessingFailed || issue == .storageFailure
        case let .integrityFailed(_, issue):
            issue == .integrityMismatch
        }
    }

    private static func canTransition(
        from source: LANInboxItemState,
        to destination: LANInboxItemState
    ) -> Bool {
        switch (source, destination) {
        case (.stored, .preprocessing),
             (.stored, .unsupported),
             (.stored, .failed),
             (.stored, .integrityFailed),
             (.preprocessing, .reviewable),
             (.preprocessing, .unsupported),
             (.preprocessing, .failed),
             (.preprocessing, .integrityFailed),
             (.failed, .preprocessing),
             (.failed, .unsupported),
             (.failed, .integrityFailed),
             (.reviewable, .preprocessing),
             (.reviewable, .integrityFailed),
             (.unsupported, .preprocessing),
             (.unsupported, .failed),
             (.unsupported, .integrityFailed):
            true
        case let (.preprocessing(_, current), .preprocessing(_, updated)):
            current == updated
        default:
            false
        }
    }

    private static func blobID(in state: LANInboxItemState) -> LANInboxBlob.ID {
        switch state {
        case let .stored(blobID),
             let .preprocessing(blobID, _),
             let .reviewable(blobID, _),
             let .unsupported(blobID, _),
             let .failed(blobID, _),
             let .integrityFailed(blobID, _):
            blobID
        }
    }
}

public struct LANInboxTransportIdentity: Codable, Hashable, Sendable {
    public let sessionID: UUID
    public let remoteFileID: UUID

    public init(sessionID: UUID, remoteFileID: UUID) {
        self.sessionID = sessionID
        self.remoteFileID = remoteFileID
    }
}

public struct LANInboxTransportMetadata: Codable, Hashable, Sendable {
    public static let maximumMediaTypeUTF8ByteCount = 256

    public let displayName: LANInboxDisplayName
    public let declaredByteCount: Int
    public let mediaType: String?

    public init(
        displayName: LANInboxDisplayName,
        declaredByteCount: Int,
        mediaType: String? = nil
    ) throws {
        guard declaredByteCount >= 0 else { throw LANInboxError.invalidByteCount }
        let normalized = mediaType?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized?.utf8.count ?? 0 <= Self.maximumMediaTypeUTF8ByteCount,
              normalized?.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) != true else {
            throw LANInboxError.invalidModel
        }
        self.displayName = displayName
        self.declaredByteCount = declaredByteCount
        if let normalized, !normalized.isEmpty {
            self.mediaType = normalized
        } else {
            self.mediaType = nil
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                displayName: container.decode(LANInboxDisplayName.self, forKey: .displayName),
                declaredByteCount: container.decode(Int.self, forKey: .declaredByteCount),
                mediaType: container.decodeIfPresent(String.self, forKey: .mediaType)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid transport metadata")
            )
        }
    }
}

public enum LANInboxTransportOutcome: Codable, Hashable, Sendable {
    case published(itemID: LANInboxItem.ID)
    case merged(itemID: LANInboxItem.ID)
    case archived
    case deleted
    case cancelled
}

public struct LANInboxTransportReceipt: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let transport: LANInboxTransportIdentity
    public let metadata: LANInboxTransportMetadata
    public let attemptRevision: UInt64
    public let contentIdentity: LANInboxContentIdentity?
    public let completedAt: Date
    public let outcome: LANInboxTransportOutcome

    public init(
        id: UUID = UUID(),
        transport: LANInboxTransportIdentity,
        metadata: LANInboxTransportMetadata,
        attemptRevision: UInt64,
        contentIdentity: LANInboxContentIdentity?,
        completedAt: Date,
        outcome: LANInboxTransportOutcome
    ) throws {
        guard completedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw LANInboxError.invalidModel
        }
        switch outcome {
        case .published, .merged, .archived, .deleted:
            guard contentIdentity != nil else { throw LANInboxError.invalidReference }
        case .cancelled:
            guard contentIdentity == nil else { throw LANInboxError.invalidReference }
        }
        self.id = id
        self.transport = transport
        self.metadata = metadata
        self.attemptRevision = attemptRevision
        self.contentIdentity = contentIdentity
        self.completedAt = completedAt
        self.outcome = outcome
    }

    public var blobID: LANInboxBlob.ID? { nil }

    public func matches(
        transport: LANInboxTransportIdentity,
        metadata: LANInboxTransportMetadata
    ) -> Bool {
        self.transport == transport && self.metadata == metadata
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(UUID.self, forKey: .id),
                transport: container.decode(
                    LANInboxTransportIdentity.self,
                    forKey: .transport
                ),
                metadata: container.decode(LANInboxTransportMetadata.self, forKey: .metadata),
                attemptRevision: container.decode(UInt64.self, forKey: .attemptRevision),
                contentIdentity: container.decodeIfPresent(
                    LANInboxContentIdentity.self,
                    forKey: .contentIdentity
                ),
                completedAt: container.decode(Date.self, forKey: .completedAt),
                outcome: container.decode(LANInboxTransportOutcome.self, forKey: .outcome)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid transport receipt")
            )
        }
    }
}

public enum LANInboxContentTerminalKind: Codable, Hashable, Sendable {
    case archived
    case deleted(admissionGenerationCutoff: UInt64)
}

public struct LANInboxContentTerminal: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let sessionID: UUID
    public let contentIdentity: LANInboxContentIdentity
    public let createdAt: Date
    public let kind: LANInboxContentTerminalKind

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        contentIdentity: LANInboxContentIdentity,
        createdAt: Date,
        kind: LANInboxContentTerminalKind
    ) throws {
        guard createdAt.timeIntervalSinceReferenceDate.isFinite else {
            throw LANInboxError.invalidModel
        }
        self.id = id
        self.sessionID = sessionID
        self.contentIdentity = contentIdentity
        self.createdAt = createdAt
        self.kind = kind
    }

    public func applies(sessionID: UUID, admissionGeneration: UInt64) -> Bool {
        guard self.sessionID == sessionID else { return false }
        switch kind {
        case .archived:
            return true
        case let .deleted(cutoff):
            return admissionGeneration <= cutoff
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(UUID.self, forKey: .id),
                sessionID: container.decode(UUID.self, forKey: .sessionID),
                contentIdentity: container.decode(
                    LANInboxContentIdentity.self,
                    forKey: .contentIdentity
                ),
                createdAt: container.decode(Date.self, forKey: .createdAt),
                kind: container.decode(LANInboxContentTerminalKind.self, forKey: .kind)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid content terminal")
            )
        }
    }
}
