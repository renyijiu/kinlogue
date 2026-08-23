import Foundation

public struct LANInboxRevision: Codable, Hashable, Sendable {
    public let generation: UInt64
    public let commitID: UUID
    public let manifestDigest: Data

    public init(generation: UInt64, commitID: UUID, manifestDigest: Data) throws {
        guard generation > 0 else { throw LANInboxError.invalidGeneration }
        guard manifestDigest.count == 32 else { throw LANInboxError.invalidDigest }
        self.generation = generation
        self.commitID = commitID
        self.manifestDigest = manifestDigest
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                generation: container.decode(UInt64.self, forKey: .generation),
                commitID: container.decode(UUID.self, forKey: .commitID),
                manifestDigest: container.decode(Data.self, forKey: .manifestDigest)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid LAN inbox revision")
            )
        }
    }
}

public struct LANInboxStorageSummary: Codable, Hashable, Sendable {
    public let itemCount: Int
    public let uniqueBlobCount: Int
    public let sourceByteCount: Int
    public let derivedArtifactCount: Int
    public let derivedByteCount: Int
    public let pendingUploadCount: Int
    /// Process-local pending memory, not physical vault storage.
    public let pendingByteCount: Int
    public var pendingInMemoryByteCount: Int { pendingByteCount }
    public let partialObjectCount: Int
    public let partialByteCount: Int
    public let reclaimableOrphanObjectCount: Int
    public let reclaimableOrphanByteCount: Int
    public let manifestByteCount: Int
    public let metadataByteCount: Int
    public let cleanupDebtObjectCount: Int
    public let cleanupDebtByteCount: Int
    public let totalPhysicalByteCount: Int
    public let totalTrackedByteCount: Int

    public init(
        itemCount: Int,
        uniqueBlobCount: Int,
        sourceByteCount: Int,
        derivedArtifactCount: Int,
        derivedByteCount: Int,
        pendingUploadCount: Int,
        pendingByteCount: Int,
        partialObjectCount: Int = 0,
        partialByteCount: Int = 0,
        reclaimableOrphanObjectCount: Int = 0,
        reclaimableOrphanByteCount: Int = 0,
        manifestByteCount: Int = 0,
        metadataByteCount: Int,
        cleanupDebtObjectCount: Int = 0,
        cleanupDebtByteCount: Int = 0
    ) throws {
        let values = [
            itemCount, uniqueBlobCount, sourceByteCount,
            derivedArtifactCount, derivedByteCount, pendingUploadCount,
            pendingByteCount, partialObjectCount, partialByteCount,
            reclaimableOrphanObjectCount, reclaimableOrphanByteCount,
            manifestByteCount, metadataByteCount, cleanupDebtObjectCount,
            cleanupDebtByteCount,
        ]
        guard values.allSatisfy({ $0 >= 0 }) else { throw LANInboxError.invalidByteCount }
        let physical = try Self.checkedSum([
            sourceByteCount, derivedByteCount, partialByteCount,
            reclaimableOrphanByteCount, manifestByteCount, metadataByteCount,
        ])
        let tracked = physical.addingReportingOverflow(pendingByteCount)
        guard !tracked.overflow else { throw LANInboxError.arithmeticOverflow }
        self.itemCount = itemCount
        self.uniqueBlobCount = uniqueBlobCount
        self.sourceByteCount = sourceByteCount
        self.derivedArtifactCount = derivedArtifactCount
        self.derivedByteCount = derivedByteCount
        self.pendingUploadCount = pendingUploadCount
        self.pendingByteCount = pendingByteCount
        self.partialObjectCount = partialObjectCount
        self.partialByteCount = partialByteCount
        self.reclaimableOrphanObjectCount = reclaimableOrphanObjectCount
        self.reclaimableOrphanByteCount = reclaimableOrphanByteCount
        self.manifestByteCount = manifestByteCount
        self.metadataByteCount = metadataByteCount
        self.cleanupDebtObjectCount = cleanupDebtObjectCount
        self.cleanupDebtByteCount = cleanupDebtByteCount
        totalPhysicalByteCount = physical
        totalTrackedByteCount = tracked.partialValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            let decodedPhysical = try container.decode(Int.self, forKey: .totalPhysicalByteCount)
            let decodedTracked = try container.decode(Int.self, forKey: .totalTrackedByteCount)
            let validated = try Self(
                itemCount: container.decode(Int.self, forKey: .itemCount),
                uniqueBlobCount: container.decode(Int.self, forKey: .uniqueBlobCount),
                sourceByteCount: container.decode(Int.self, forKey: .sourceByteCount),
                derivedArtifactCount: container.decode(Int.self, forKey: .derivedArtifactCount),
                derivedByteCount: container.decode(Int.self, forKey: .derivedByteCount),
                pendingUploadCount: container.decode(Int.self, forKey: .pendingUploadCount),
                pendingByteCount: container.decode(Int.self, forKey: .pendingByteCount),
                partialObjectCount: container.decode(Int.self, forKey: .partialObjectCount),
                partialByteCount: container.decode(Int.self, forKey: .partialByteCount),
                reclaimableOrphanObjectCount: container.decode(
                    Int.self,
                    forKey: .reclaimableOrphanObjectCount
                ),
                reclaimableOrphanByteCount: container.decode(
                    Int.self,
                    forKey: .reclaimableOrphanByteCount
                ),
                manifestByteCount: container.decode(Int.self, forKey: .manifestByteCount),
                metadataByteCount: container.decode(Int.self, forKey: .metadataByteCount),
                cleanupDebtObjectCount: container.decode(Int.self, forKey: .cleanupDebtObjectCount),
                cleanupDebtByteCount: container.decode(Int.self, forKey: .cleanupDebtByteCount)
            )
            guard decodedPhysical == validated.totalPhysicalByteCount,
                  decodedTracked == validated.totalTrackedByteCount else {
                throw LANInboxError.invalidModel
            }
            self = validated
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid storage summary")
            )
        }
    }

    private static func checkedSum(_ values: [Int]) throws -> Int {
        var total = 0
        for value in values {
            let next = total.addingReportingOverflow(value)
            guard !next.overflow else { throw LANInboxError.arithmeticOverflow }
            total = next.partialValue
        }
        return total
    }
}

/// Authoritative item-only LAN inbox manifest.
///
/// The app has not shipped, so this schema deliberately has no legacy fields
/// and no decoder defaults. Older development manifests fail as unsupported at
/// the envelope boundary instead of being guessed or migrated.
public struct LANInboxSnapshot: Codable, Hashable, Sendable {
    public static let currentFormatVersion = 1
    public static let maximumItemCount = 5_000
    public static let maximumTransportReceiptCount = 5_000
    public static let maximumTransportReceiptsPerSession = 1_000
    public static let maximumContentTerminalCount = 5_000
    public static let maximumArchiveIntentCount = 5_000
    public static let maximumArchiveTerminalCount = 5_000
    public static let maximumBlobCount = maximumItemCount

    public let formatVersion: Int
    public let vaultID: UUID
    public let generation: UInt64
    public let commitID: UUID
    /// Audit-only identity of the process-local runtime that authored this snapshot.
    public let lastWriterRuntimeGeneration: UUID
    public let items: [LANInboxItem]
    public let transportReceipts: [LANInboxTransportReceipt]
    public let contentTerminals: [LANInboxContentTerminal]
    public let archiveIntents: [LANArchiveIntent]
    public let archiveTerminals: [LANArchiveTerminal]
    public let blobs: [LANInboxBlob]

    public init(
        formatVersion: Int = Self.currentFormatVersion,
        vaultID: UUID,
        generation: UInt64,
        commitID: UUID,
        lastWriterRuntimeGeneration: UUID,
        items: [LANInboxItem] = [],
        transportReceipts: [LANInboxTransportReceipt] = [],
        contentTerminals: [LANInboxContentTerminal] = [],
        archiveIntents: [LANArchiveIntent] = [],
        archiveTerminals: [LANArchiveTerminal] = [],
        blobs: [LANInboxBlob] = []
    ) throws {
        guard formatVersion == Self.currentFormatVersion else {
            throw LANInboxError.invalidModel
        }
        guard generation > 0 else { throw LANInboxError.invalidGeneration }
        try Self.validateResourceLimits(
            items: items,
            transportReceipts: transportReceipts,
            contentTerminals: contentTerminals,
            archiveIntents: archiveIntents,
            archiveTerminals: archiveTerminals,
            blobs: blobs
        )
        let sortedItems = items.sorted(by: Self.itemPrecedes)
        let sortedTransportReceipts = transportReceipts.sorted(by: Self.transportReceiptPrecedes)
        let sortedContentTerminals = contentTerminals.sorted(by: Self.contentTerminalPrecedes)
        let sortedArchiveIntents = archiveIntents.sorted(by: Self.archiveIntentPrecedes)
        let sortedArchiveTerminals = archiveTerminals.sorted(by: Self.archiveTerminalPrecedes)
        let sortedBlobs = blobs.sorted(by: Self.blobPrecedes)
        try Self.validate(
            vaultID: vaultID,
            items: sortedItems,
            transportReceipts: sortedTransportReceipts,
            contentTerminals: sortedContentTerminals,
            archiveIntents: sortedArchiveIntents,
            archiveTerminals: sortedArchiveTerminals,
            blobs: sortedBlobs
        )
        self.formatVersion = formatVersion
        self.vaultID = vaultID
        self.generation = generation
        self.commitID = commitID
        self.lastWriterRuntimeGeneration = lastWriterRuntimeGeneration
        self.items = sortedItems
        self.transportReceipts = sortedTransportReceipts
        self.contentTerminals = sortedContentTerminals
        self.archiveIntents = sortedArchiveIntents
        self.archiveTerminals = sortedArchiveTerminals
        self.blobs = sortedBlobs
    }

    public func item(id: LANInboxItem.ID) -> LANInboxItem? {
        items.first { $0.id == id }
    }

    public func item(contentIdentity: LANInboxContentIdentity) -> LANInboxItem? {
        items.first { $0.contentIdentity == contentIdentity }
    }

    public func transportReceipt(
        transport: LANInboxTransportIdentity
    ) -> LANInboxTransportReceipt? {
        transportReceipts.first { $0.transport == transport }
    }

    public func contentTerminal(
        sessionID: UUID,
        contentIdentity: LANInboxContentIdentity,
        admissionGeneration: UInt64
    ) -> LANInboxContentTerminal? {
        contentTerminals.first {
            $0.contentIdentity == contentIdentity
                && $0.applies(sessionID: sessionID, admissionGeneration: admissionGeneration)
        }
    }

    public func archiveIntent(id: LANArchiveIntent.ID) -> LANArchiveIntent? {
        archiveIntents.first { $0.id == id }
    }

    public func archiveTerminal(intentID: LANArchiveIntent.ID) -> LANArchiveTerminal? {
        archiveTerminals.first { $0.intent.id == intentID }
    }

    public func storageSummary(
        pendingUploadCount: Int = 0,
        pendingByteCount: Int = 0,
        partialObjectCount: Int = 0,
        partialByteCount: Int = 0,
        reclaimableOrphanObjectCount: Int = 0,
        reclaimableOrphanByteCount: Int = 0,
        manifestByteCount: Int = 0,
        metadataByteCount: Int = 0,
        cleanupDebtObjectCount: Int = 0,
        cleanupDebtByteCount: Int = 0
    ) throws -> LANInboxStorageSummary {
        let sourceByteCount = try Self.checkedSum(blobs.map(\.byteCount))
        var derivedByID: [UUID: LANInboxDerivedArtifact] = [:]
        for artifact in items.compactMap(\.derivedArtifact) {
            if let existing = derivedByID[artifact.id], existing != artifact {
                throw LANInboxError.invalidReference
            }
            derivedByID[artifact.id] = artifact
        }
        let derivedByteCount = try Self.checkedSum(derivedByID.values.map(\.byteCount))
        return try LANInboxStorageSummary(
            itemCount: items.count,
            uniqueBlobCount: blobs.count,
            sourceByteCount: sourceByteCount,
            derivedArtifactCount: derivedByID.count,
            derivedByteCount: derivedByteCount,
            pendingUploadCount: pendingUploadCount,
            pendingByteCount: pendingByteCount,
            partialObjectCount: partialObjectCount,
            partialByteCount: partialByteCount,
            reclaimableOrphanObjectCount: reclaimableOrphanObjectCount,
            reclaimableOrphanByteCount: reclaimableOrphanByteCount,
            manifestByteCount: manifestByteCount,
            metadataByteCount: metadataByteCount,
            cleanupDebtObjectCount: cleanupDebtObjectCount,
            cleanupDebtByteCount: cleanupDebtByteCount
        )
    }

    public func replacing(
        generation: UInt64,
        commitID: UUID,
        lastWriterRuntimeGeneration: UUID,
        items: [LANInboxItem]? = nil,
        transportReceipts: [LANInboxTransportReceipt]? = nil,
        contentTerminals: [LANInboxContentTerminal]? = nil,
        archiveIntents: [LANArchiveIntent]? = nil,
        archiveTerminals: [LANArchiveTerminal]? = nil,
        blobs: [LANInboxBlob]? = nil
    ) throws -> Self {
        try Self(
            formatVersion: formatVersion,
            vaultID: vaultID,
            generation: generation,
            commitID: commitID,
            lastWriterRuntimeGeneration: lastWriterRuntimeGeneration,
            items: items ?? self.items,
            transportReceipts: transportReceipts ?? self.transportReceipts,
            contentTerminals: contentTerminals ?? self.contentTerminals,
            archiveIntents: archiveIntents ?? self.archiveIntents,
            archiveTerminals: archiveTerminals ?? self.archiveTerminals,
            blobs: blobs ?? self.blobs
        )
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedItems = try container.decodeBoundedArray(
            LANInboxItem.self,
            forKey: .items,
            maximumCount: Self.maximumItemCount
        )
        let decodedTransportReceipts = try container.decodeBoundedArray(
            LANInboxTransportReceipt.self,
            forKey: .transportReceipts,
            maximumCount: Self.maximumTransportReceiptCount
        )
        let decodedContentTerminals = try container.decodeBoundedArray(
            LANInboxContentTerminal.self,
            forKey: .contentTerminals,
            maximumCount: Self.maximumContentTerminalCount
        )
        let decodedArchiveIntents = try container.decodeBoundedArray(
            LANArchiveIntent.self,
            forKey: .archiveIntents,
            maximumCount: Self.maximumArchiveIntentCount
        )
        let decodedArchiveTerminals = try container.decodeBoundedArray(
            LANArchiveTerminal.self,
            forKey: .archiveTerminals,
            maximumCount: Self.maximumArchiveTerminalCount
        )
        let decodedBlobs = try container.decodeBoundedArray(
            LANInboxBlob.self,
            forKey: .blobs,
            maximumCount: Self.maximumBlobCount
        )
        do {
            let validated = try Self(
                formatVersion: container.decode(Int.self, forKey: .formatVersion),
                vaultID: container.decode(UUID.self, forKey: .vaultID),
                generation: container.decode(UInt64.self, forKey: .generation),
                commitID: container.decode(UUID.self, forKey: .commitID),
                lastWriterRuntimeGeneration: container.decode(
                    UUID.self,
                    forKey: .lastWriterRuntimeGeneration
                ),
                items: decodedItems,
                transportReceipts: decodedTransportReceipts,
                contentTerminals: decodedContentTerminals,
                archiveIntents: decodedArchiveIntents,
                archiveTerminals: decodedArchiveTerminals,
                blobs: decodedBlobs
            )
            guard validated.items == decodedItems,
                  validated.transportReceipts == decodedTransportReceipts,
                  validated.contentTerminals == decodedContentTerminals,
                  validated.archiveIntents == decodedArchiveIntents,
                  validated.archiveTerminals == decodedArchiveTerminals,
                  validated.blobs == decodedBlobs else {
                throw LANInboxError.invalidModel
            }
            self = validated
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid LAN inbox snapshot")
            )
        }
    }

    private static func validate(
        vaultID: UUID,
        items: [LANInboxItem],
        transportReceipts: [LANInboxTransportReceipt],
        contentTerminals: [LANInboxContentTerminal],
        archiveIntents: [LANArchiveIntent],
        archiveTerminals: [LANArchiveTerminal],
        blobs: [LANInboxBlob]
    ) throws {
        guard Set(items.map(\.id)).count == items.count,
              Set(items.map(\.sequence)).count == items.count,
              Set(transportReceipts.map(\.id)).count == transportReceipts.count,
              Set(transportReceipts.map(\.transport)).count == transportReceipts.count,
              Set(contentTerminals.map(\.id)).count == contentTerminals.count,
              Set(archiveIntents.map(\.id)).count == archiveIntents.count,
              Set(archiveTerminals.map(\.id)).count == archiveTerminals.count,
              Set(archiveTerminals.map { $0.intent.id }).count == archiveTerminals.count,
              Set(blobs.map(\.id)).count == blobs.count else {
            throw LANInboxError.duplicateIdentifier
        }

        let itemContentKeys = items.map { ContentKey(identity: $0.contentIdentity) }
        let blobContentKeys = blobs.map {
            ContentKey(digest: $0.sha256Digest, byteCount: $0.byteCount)
        }
        guard Set(itemContentKeys).count == itemContentKeys.count,
              Set(blobContentKeys).count == blobContentKeys.count else {
            throw LANInboxError.duplicateIdentifier
        }

        let terminalKeys = contentTerminals.map {
            ContentTerminalKey(sessionID: $0.sessionID, contentIdentity: $0.contentIdentity)
        }
        guard Set(terminalKeys).count == terminalKeys.count else {
            throw LANInboxError.receiptConflict
        }
        let terminalsByKey = Dictionary(uniqueKeysWithValues: zip(
            terminalKeys,
            contentTerminals
        ))

        var receiptCountBySession: [UUID: Int] = [:]
        for receipt in transportReceipts {
            receiptCountBySession[receipt.transport.sessionID, default: 0] += 1
            guard receiptCountBySession[receipt.transport.sessionID, default: 0]
                <= maximumTransportReceiptsPerSession else {
                throw LANInboxError.resourceLimitExceeded
            }
        }

        let blobsByID = Dictionary(uniqueKeysWithValues: blobs.map { ($0.id, $0) })
        let itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        for item in items {
            guard let blob = blobsByID[item.blobID],
                  blob.sha256Digest == item.contentIdentity.sha256Digest,
                  blob.byteCount == item.contentIdentity.byteCount else {
                throw LANInboxError.invalidReference
            }
        }
        guard Set(items.map(\.blobID)) == Set(blobsByID.keys) else {
            throw LANInboxError.invalidReference
        }

        for receipt in transportReceipts {
            switch receipt.outcome {
            case let .published(itemID), let .merged(itemID):
                guard let item = itemsByID[itemID],
                      receipt.contentIdentity == item.contentIdentity else {
                    throw LANInboxError.invalidReference
                }
            case .archived:
                guard let identity = receipt.contentIdentity,
                      terminalsByKey[ContentTerminalKey(
                          sessionID: receipt.transport.sessionID,
                          contentIdentity: identity
                      )]?.kind == .archived else {
                    throw LANInboxError.invalidReference
                }
            case .deleted:
                guard let identity = receipt.contentIdentity,
                      let terminal = terminalsByKey[ContentTerminalKey(
                          sessionID: receipt.transport.sessionID,
                          contentIdentity: identity
                      )],
                      case .deleted = terminal.kind else {
                    throw LANInboxError.invalidReference
                }
            case .cancelled:
                break
            }
        }

        let liveIntentIDs = Set(archiveIntents.map(\.id))
        var reservedItemIDs: Set<LANInboxItem.ID> = []
        var activeFingerprints: Set<ReportFingerprint> = []
        for intent in archiveIntents {
            guard intent.vaultID == vaultID else { throw LANInboxError.invalidReference }
            for source in intent.orderedSources {
                guard reservedItemIDs.insert(source.itemID).inserted,
                      let item = itemsByID[source.itemID],
                      item.isReviewable,
                      item.revision == source.itemRevision,
                      item.contentIdentity == source.contentIdentity else {
                    throw LANInboxError.invalidReference
                }
            }
            guard activeFingerprints.insert(intent.fingerprint).inserted else {
                throw LANInboxError.receiptConflict
            }
        }
        for terminal in archiveTerminals {
            guard terminal.intent.vaultID == vaultID,
                  !liveIntentIDs.contains(terminal.intent.id),
                  terminal.intent.orderedSources.allSatisfy({ itemsByID[$0.itemID] == nil }) else {
                throw LANInboxError.invalidReference
            }
        }

        var globallyOwnedIDs: Set<UUID> = []
        let ownedIDs = items.map(\.id)
            + transportReceipts.map(\.id)
            + contentTerminals.map(\.id)
            + archiveIntents.map(\.id)
            + archiveTerminals.map(\.id)
            + blobs.map(\.id)
            + items.compactMap(\.derivedArtifact).map(\.id)
            + archiveIntents.flatMap { intent in
                intent.orderedSources.flatMap { [$0.reportSourceID, $0.attachmentID] }
                    + [intent.draftID, intent.documentObjectID]
            }
            + archiveTerminals.flatMap { terminal in
                [terminal.intent.id]
                    + terminal.intent.orderedSources.flatMap {
                        [$0.itemID, $0.reportSourceID]
                    }
                    + [terminal.intent.draftID, terminal.intent.documentObjectID]
            }
        for id in ownedIDs {
            guard globallyOwnedIDs.insert(id).inserted else {
                throw LANInboxError.duplicateIdentifier
            }
        }
    }

    private static func validateResourceLimits(
        items: [LANInboxItem],
        transportReceipts: [LANInboxTransportReceipt],
        contentTerminals: [LANInboxContentTerminal],
        archiveIntents: [LANArchiveIntent],
        archiveTerminals: [LANArchiveTerminal],
        blobs: [LANInboxBlob]
    ) throws {
        guard items.count <= maximumItemCount,
              transportReceipts.count <= maximumTransportReceiptCount,
              contentTerminals.count <= maximumContentTerminalCount,
              archiveIntents.count <= maximumArchiveIntentCount,
              archiveTerminals.count <= maximumArchiveTerminalCount,
              blobs.count <= maximumBlobCount else {
            throw LANInboxError.resourceLimitExceeded
        }
    }

    private static func checkedSum(_ values: [Int]) throws -> Int {
        var total = 0
        for value in values {
            let next = total.addingReportingOverflow(value)
            guard !next.overflow else { throw LANInboxError.arithmeticOverflow }
            total = next.partialValue
        }
        return total
    }

    private static func itemPrecedes(_ lhs: LANInboxItem, _ rhs: LANInboxItem) -> Bool {
        if lhs.sequence != rhs.sequence { return lhs.sequence < rhs.sequence }
        return uuidPrecedes(lhs.id, rhs.id)
    }

    private static func transportReceiptPrecedes(
        _ lhs: LANInboxTransportReceipt,
        _ rhs: LANInboxTransportReceipt
    ) -> Bool {
        if lhs.completedAt != rhs.completedAt { return lhs.completedAt < rhs.completedAt }
        return uuidPrecedes(lhs.id, rhs.id)
    }

    private static func contentTerminalPrecedes(
        _ lhs: LANInboxContentTerminal,
        _ rhs: LANInboxContentTerminal
    ) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return uuidPrecedes(lhs.id, rhs.id)
    }

    private static func archiveIntentPrecedes(
        _ lhs: LANArchiveIntent,
        _ rhs: LANArchiveIntent
    ) -> Bool {
        uuidPrecedes(lhs.id, rhs.id)
    }

    private static func archiveTerminalPrecedes(
        _ lhs: LANArchiveTerminal,
        _ rhs: LANArchiveTerminal
    ) -> Bool {
        if lhs.receipt.completedAt != rhs.receipt.completedAt {
            return lhs.receipt.completedAt < rhs.receipt.completedAt
        }
        return uuidPrecedes(lhs.id, rhs.id)
    }

    private static func blobPrecedes(_ lhs: LANInboxBlob, _ rhs: LANInboxBlob) -> Bool {
        let digestOrder = lhs.sha256Digest.lexicographicallyPrecedes(rhs.sha256Digest)
        let reverseDigestOrder = rhs.sha256Digest.lexicographicallyPrecedes(lhs.sha256Digest)
        if digestOrder != reverseDigestOrder { return digestOrder }
        if lhs.byteCount != rhs.byteCount { return lhs.byteCount < rhs.byteCount }
        return uuidPrecedes(lhs.id, rhs.id)
    }

    private static func uuidPrecedes(_ lhs: UUID, _ rhs: UUID) -> Bool {
        lhs.uuidString.lowercased() < rhs.uuidString.lowercased()
    }

    private struct ContentKey: Hashable {
        let digest: Data
        let byteCount: Int

        init(digest: Data, byteCount: Int) {
            self.digest = digest
            self.byteCount = byteCount
        }

        init(identity: LANInboxContentIdentity) {
            self.init(digest: identity.sha256Digest, byteCount: identity.byteCount)
        }
    }

    private struct ContentTerminalKey: Hashable {
        let sessionID: UUID
        let contentIdentity: LANInboxContentIdentity
    }
}
