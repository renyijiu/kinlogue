import Foundation
import KinlogueCore

public struct VaultStagedAttachment: Equatable, Sendable {
    public let reference: VaultObjectReference
    public let relativePath: String
    public let byteCount: Int
    public let sha256Digest: Data

    public init(
        reference: VaultObjectReference,
        relativePath: String,
        byteCount: Int,
        sha256Digest: Data
    ) throws {
        guard reference.kind == .attachment,
              byteCount >= 0,
              sha256Digest.count == 32,
              !relativePath.isEmpty else {
            throw VaultError.invalidCatalog
        }
        self.reference = reference
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.sha256Digest = sha256Digest
    }
}

public struct VaultStagedReportSelection: Equatable, Sendable {
    public let intentID: LANArchiveIntent.ID
    public let attachments: [VaultStagedAttachment]

    public init(
        intentID: LANArchiveIntent.ID,
        attachments: [VaultStagedAttachment]
    ) throws {
        guard Set(attachments.map(\.reference)).count == attachments.count else {
            throw VaultError.invalidCatalog
        }
        self.intentID = intentID
        self.attachments = attachments
    }
}

public enum VaultStagedReportCommitOutcome: Equatable, Sendable {
    case accepted(VaultCatalog, VaultRevision)
    case duplicateSkipped(LANReportDuplicateDestination, VaultRevision)
}

/// File-backed bridge from verified canonical inbox items to Vault-owned
/// staging. Originals are copied through descriptors and never collected as a
/// multi-file in-memory payload.
public actor VaultReportSelectionStaging {
    private let inbox: PlaintextLANInboxStore
    private let files: AtomicFileStore

    public init(rootURL: URL, inbox: PlaintextLANInboxStore) throws {
        self.inbox = inbox
        files = try AtomicFileStore(rootURL: rootURL)
    }

    public func stage(_ intent: LANArchiveIntent) async throws -> VaultStagedReportSelection {
        let snapshot = try await inbox.loadSnapshot()
        guard snapshot.archiveIntents.contains(intent) else {
            throw LANInboxError.staleRevision
        }
        let itemsByID = Dictionary(uniqueKeysWithValues: snapshot.items.map {
            ($0.id, $0)
        })
        var stagedByAttachmentID: [Attachment.ID: VaultStagedAttachment] = [:]
        for source in intent.orderedSources {
            guard let item = itemsByID[source.itemID],
                  item.revision == source.itemRevision,
                  item.contentIdentity == source.contentIdentity else {
                throw LANInboxError.staleRevision
            }
            if let existing = stagedByAttachmentID[source.attachmentID] {
                guard existing.byteCount == source.contentIdentity.byteCount,
                      existing.sha256Digest == source.contentIdentity.sha256Digest else {
                    throw LANInboxError.invalidReference
                }
                continue
            }
            let relativePath = PlaintextVault.stagingPath(
                intentID: intent.id,
                attachmentID: source.attachmentID
            )
            let stagingFiles = files
            try await inbox.withVerifiedItemSourceContent(itemID: item.id) { descriptor in
                try stagingFiles.writeImmutable(
                    copyingFrom: descriptor,
                    expectedByteCount: source.contentIdentity.byteCount,
                    expectedSHA256: source.contentIdentity.sha256Digest,
                    relativePath: relativePath
                )
            }
            stagedByAttachmentID[source.attachmentID] = try VaultStagedAttachment(
                reference: VaultObjectReference(
                    id: source.attachmentID,
                    kind: .attachment
                ),
                relativePath: relativePath,
                byteCount: source.contentIdentity.byteCount,
                sha256Digest: source.contentIdentity.sha256Digest
            )
        }
        return try VaultStagedReportSelection(
            intentID: intent.id,
            attachments: stagedByAttachmentID.values.sorted {
                $0.reference.id.uuidString.lowercased()
                    < $1.reference.id.uuidString.lowercased()
            }
        )
    }

    public func cleanup(_ staged: VaultStagedReportSelection) throws {
        try cleanup(
            intentID: staged.intentID,
            attachmentIDs: staged.attachments.map(\.reference.id)
        )
    }

    public func cleanup(_ intent: LANArchiveIntent) throws {
        try cleanup(
            intentID: intent.id,
            attachmentIDs: intent.orderedSources.map(\.attachmentID)
        )
    }

    private func cleanup(intentID: UUID, attachmentIDs: [UUID]) throws {
        var firstError: (any Error)?
        for attachmentID in Set(attachmentIDs).sorted(by: uuidPrecedes) {
            do {
                try files.remove(
                    relativePath: PlaintextVault.stagingPath(
                        intentID: intentID,
                        attachmentID: attachmentID
                    )
                )
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        for directory in [Self.directoryPath(intentID: intentID), "lan-submission-staging"] {
            do {
                try files.removeEmptyDirectory(relativePath: directory)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }

    private nonisolated static func directoryPath(intentID: UUID) -> String {
        "lan-submission-staging/\(intentID.uuidString.lowercased())"
    }

    private nonisolated func uuidPrecedes(_ lhs: UUID, _ rhs: UUID) -> Bool {
        lhs.uuidString.lowercased() < rhs.uuidString.lowercased()
    }
}
