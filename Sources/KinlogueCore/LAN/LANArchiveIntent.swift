import Foundation

public struct LANArchiveSource: Codable, Hashable, Sendable {
    public let itemID: LANInboxItem.ID
    public let itemRevision: UInt64
    public let contentIdentity: LANInboxContentIdentity
    public let reportSourceID: UUID
    public let attachmentID: UUID

    public init(
        itemID: LANInboxItem.ID,
        itemRevision: UInt64,
        contentIdentity: LANInboxContentIdentity,
        reportSourceID: UUID,
        attachmentID: UUID
    ) throws {
        self.itemID = itemID
        self.itemRevision = itemRevision
        self.contentIdentity = contentIdentity
        self.reportSourceID = reportSourceID
        self.attachmentID = attachmentID
    }
}

public struct LANArchiveIntent: Codable, Identifiable, Hashable, Sendable {
    public static let maximumSourceCount = 20

    public let id: UUID
    public let vaultID: UUID
    public let orderedSources: [LANArchiveSource]
    public let memberID: FamilyMember.ID
    public let canonicalReportDate: Date
    public let fingerprint: ReportFingerprint
    public let draftID: ImportDraft.ID
    public let documentObjectID: UUID

    public init(
        id: UUID = UUID(),
        vaultID: UUID,
        orderedSources: [LANArchiveSource],
        memberID: FamilyMember.ID,
        canonicalReportDate: Date,
        draftID: ImportDraft.ID,
        documentObjectID: UUID
    ) throws {
        guard !orderedSources.isEmpty,
              orderedSources.count <= Self.maximumSourceCount,
              Set(orderedSources.map(\.itemID)).count == orderedSources.count,
              Set(orderedSources.map(\.reportSourceID)).count == orderedSources.count,
              Set(orderedSources.map(\.attachmentID)).count == orderedSources.count,
              canonicalReportDate.timeIntervalSinceReferenceDate.isFinite else {
            throw LANInboxError.invalidModel
        }
        let fingerprint = try ReportFingerprint(
            sources: orderedSources.map { try $0.contentIdentity.reportSourceDigest }
        )
        self.id = id
        self.vaultID = vaultID
        self.orderedSources = orderedSources
        self.memberID = memberID
        self.canonicalReportDate = canonicalReportDate
        self.fingerprint = fingerprint
        self.draftID = draftID
        self.documentObjectID = documentObjectID
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let sources = try container.decodeBoundedArray(
            LANArchiveSource.self,
            forKey: .orderedSources,
            maximumCount: Self.maximumSourceCount
        )
        let decodedFingerprint = try container.decodeReportFingerprint(
            forKey: .fingerprint,
            maximumSourceCount: Self.maximumSourceCount
        )
        do {
            let value = try Self(
                id: container.decode(UUID.self, forKey: .id),
                vaultID: container.decode(UUID.self, forKey: .vaultID),
                orderedSources: sources,
                memberID: container.decode(FamilyMember.ID.self, forKey: .memberID),
                canonicalReportDate: container.decode(Date.self, forKey: .canonicalReportDate),
                draftID: container.decode(ImportDraft.ID.self, forKey: .draftID),
                documentObjectID: container.decode(UUID.self, forKey: .documentObjectID)
            )
            guard value.fingerprint == decodedFingerprint else {
                throw LANInboxError.invalidModel
            }
            self = value
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid archive intent")
            )
        }
    }
}

public enum LANReportDuplicateDestinationKind: String, Codable, CaseIterable,
    Hashable, Sendable
{
    case importDraft
    case healthRecord
}

public struct LANReportDuplicateDestination: Codable, Hashable, Sendable {
    public let kind: LANReportDuplicateDestinationKind
    public let id: UUID

    public init(
        kind: LANReportDuplicateDestinationKind,
        id: UUID
    ) {
        self.kind = kind
        self.id = id
    }
}

public enum LANArchiveOutcome: Codable, Hashable, Sendable {
    case accepted(draftID: ImportDraft.ID)
    case duplicateSkipped(LANReportDuplicateDestination)
}

public struct LANArchiveReceipt: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let intentID: LANArchiveIntent.ID
    public let completedAt: Date
    public let vaultRevision: VaultRevision
    public let outcome: LANArchiveOutcome

    public init(
        id: UUID = UUID(),
        intentID: LANArchiveIntent.ID,
        completedAt: Date,
        vaultRevision: VaultRevision,
        outcome: LANArchiveOutcome
    ) throws {
        guard completedAt.timeIntervalSinceReferenceDate.isFinite,
              vaultRevision.generation > 0 else {
            throw LANInboxError.invalidModel
        }
        self.id = id
        self.intentID = intentID
        self.completedAt = completedAt
        self.vaultRevision = vaultRevision
        self.outcome = outcome
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(UUID.self, forKey: .id),
                intentID: container.decode(LANArchiveIntent.ID.self, forKey: .intentID),
                completedAt: container.decode(Date.self, forKey: .completedAt),
                vaultRevision: container.decode(VaultRevision.self, forKey: .vaultRevision),
                outcome: container.decode(LANArchiveOutcome.self, forKey: .outcome)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid archive receipt")
            )
        }
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(intentID)
        hasher.combine(completedAt)
        hasher.combine(vaultRevision.generation)
        hasher.combine(vaultRevision.commitID)
        hasher.combine(vaultRevision.catalogDigest)
        hasher.combine(outcome)
    }
}

public struct LANArchiveTerminal: Codable, Identifiable, Hashable, Sendable {
    public var id: LANArchiveReceipt.ID { receipt.id }
    public let intent: LANArchiveIntent
    public let receipt: LANArchiveReceipt

    public init(intent: LANArchiveIntent, receipt: LANArchiveReceipt) throws {
        guard receipt.intentID == intent.id else { throw LANInboxError.invalidReference }
        switch receipt.outcome {
        case let .accepted(draftID):
            guard draftID == intent.draftID else { throw LANInboxError.invalidReference }
        case .duplicateSkipped:
            break
        }
        self.intent = intent
        self.receipt = receipt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                intent: container.decode(LANArchiveIntent.self, forKey: .intent),
                receipt: container.decode(LANArchiveReceipt.self, forKey: .receipt)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid archive terminal")
            )
        }
    }
}
