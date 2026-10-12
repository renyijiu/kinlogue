import Foundation
import KinlogueCore

package protocol LANUploadStoring: Sendable {
    func initialize() async throws -> LANInboxSnapshot
    func prepare() async throws
    func publicationGuard() async throws -> LANInboxPublicationGuard
    func revokePublications(guardedBy guardValue: LANInboxPublicationGuard) async throws
    func itemAdmissionGeneration() async throws -> UInt64
    func startItemUpload(transport: LANInboxTransportIdentity, metadata: LANInboxTransportMetadata,
                         attemptRevision: UInt64, admissionGeneration: UInt64?,
                         publicationGuard: LANInboxPublicationGuard?) async throws -> LANItemUploadStartOutcome
    func recordItemUploadCancellation(transport: LANInboxTransportIdentity, metadata: LANInboxTransportMetadata,
                                     attemptRevision: UInt64) async throws -> LANInboxTransportReceipt
    func endItemSession(sessionID: UUID) async throws
}

package protocol LANPendingItemStoring: LANInboxRepository, LANUploadStoring {
    func queueScreen(cursor: LANInboxPageCursor?) async throws -> LANInboxQueueScreen
    func itemPage(cursor: LANInboxPageCursor?, processing: Bool) async throws -> LANInboxPage
    func archiveRecoverySnapshot() async throws -> LANInboxSnapshot?
    func removeItem(itemID: UUID, expectedRevision: UInt64, activeSessionID: UUID?) async throws
    func loadItems(ids: [UUID]) async throws -> [LANInboxItem]
    func snapshotAndStorageSummary() async throws -> LANInboxSnapshotAndStorageSummary
    func deleteItem(itemID: UUID, expectedRevision: UInt64, activeSessionID: UUID?,
                    admissionGenerationCutoff: UInt64?) async throws -> LANInboxSnapshot
    func withVerifiedItemSourceContent<T: Sendable>(itemID: UUID, _ body: @escaping @Sendable (Int32) throws -> T) async throws -> T
    func markItemPreprocessingIssue(itemID: UUID, expectedRevision: UInt64, issue: LANInboxFileIssue) async throws -> LANInboxItem
    func reportAttachmentID(for item: LANInboxItem) async throws -> UUID
    func loadPreprocessedDocument(itemID: UUID, expectedRevision: UInt64) async throws -> LANPreprocessedSourceDocument
    func savePreprocessedDocument(itemID: UUID, expectedRevision: UInt64, document: LANPreprocessedSourceDocument) async throws -> LANInboxItem
}

extension PlaintextLANInboxStore: LANPendingItemStoring {
    package func loadItems(ids: [UUID]) async throws -> [LANInboxItem] {
        let snapshot = try await loadSnapshot()
        return try ids.map { id in guard let item = snapshot.item(id: id) else { throw LANInboxError.fileNotFound }; return item }
    }

    package func reportAttachmentID(for item: LANInboxItem) throws -> UUID {
        LANItemPreprocessor.attachmentID(digest: item.contentIdentity.sha256Digest, byteCount: item.contentIdentity.byteCount)
    }

    package func loadPreprocessedDocument(itemID: UUID, expectedRevision: UInt64) async throws -> LANPreprocessedSourceDocument {
        guard try await loadSnapshot().item(id: itemID)?.revision == expectedRevision else { throw LANInboxError.staleRevision }
        let value = try await withVerifiedItemDerivedContent(itemID: itemID) { descriptor in
            try CanonicalVaultJSON.decode(LANPreprocessedSourceDocument.self, from: BoundedRegularFileReader.read(
                descriptor: descriptor, maximumByteCount: LANPreprocessedSourceDocument.maximumEncodedByteCount,
                oversizeError: LANItemPreprocessorError.sourceTooLarge, checksCancellation: true))
        }
        guard try await loadSnapshot().item(id: itemID)?.revision == expectedRevision else { throw LANInboxError.staleRevision }
        return value
    }

    package func savePreprocessedDocument(itemID: UUID, expectedRevision: UInt64, document: LANPreprocessedSourceDocument) async throws -> LANInboxItem {
        let bytes = try CanonicalVaultJSON.encode(document)
        guard bytes.count <= LANPreprocessedSourceDocument.maximumEncodedByteCount else { throw LANItemPreprocessorError.sourceTooLarge }
        let sink = try await beginItemDerivedArtifact(itemID: itemID, expectedRevision: expectedRevision)
        do { try await sink.write(bytes).value; _ = try await sink.finish() }
        catch { await sink.abort(); throw error }
        guard let item = try await loadSnapshot().item(id: itemID) else { throw LANInboxError.fileNotFound }
        return item
    }
}

extension LANUploadStoring {
    package func prepare() async throws { _ = try await initialize() }
}
extension LANPendingItemStoring {
    package func archiveRecoverySnapshot() async throws -> LANInboxSnapshot? { try await loadSnapshot() }
    package func removeItem(itemID: UUID, expectedRevision: UInt64, activeSessionID: UUID?) async throws {
        _ = try await deleteItem(itemID: itemID, expectedRevision: expectedRevision, activeSessionID: activeSessionID, admissionGenerationCutoff: nil)
    }
}
extension PlaintextLANInboxStore {
    package func queueScreen(cursor: LANInboxPageCursor?) async throws -> LANInboxQueueScreen {
        let projection = try await snapshotAndStorageSummary()
        return LANInboxQueueScreen(page: try Self.page(projection.snapshot, cursor: cursor, processing: false, openEpoch: publicationGuard().runtimeGeneration), storage: projection.storage)
    }
    package func itemPage(cursor: LANInboxPageCursor?, processing: Bool) async throws -> LANInboxPage {
        try Self.page(await loadSnapshot(), cursor: cursor, processing: processing, openEpoch: publicationGuard().runtimeGeneration)
    }
    package static func page(_ snapshot: LANInboxSnapshot, cursor: LANInboxPageCursor?, processing: Bool, openEpoch: UUID) throws -> LANInboxPage {
        let revision = LibraryRevision(libraryID: snapshot.vaultID, openEpoch: openEpoch,
            generation: snapshot.generation, commitID: snapshot.commitID)
        if let cursor {
            guard cursor.processing == processing, cursor.revision.libraryID == revision.libraryID,
                  cursor.revision.openEpoch == revision.openEpoch,
                  processing || cursor.revision == revision else { throw LibraryReportError.staleCursor }
        }
        let remaining = snapshot.items.sorted { ($0.sequence, $0.id.uuidString) < ($1.sequence, $1.id.uuidString) }.filter {
            guard let cursor else { return true }
            return ($0.sequence, $0.id.uuidString) > (cursor.sequence, cursor.id.uuidString)
        }
        let items = Array(remaining.prefix(100))
        let next = remaining.count > 100 ? items.last.map { LANInboxPageCursor(revision: revision, sequence: $0.sequence, id: $0.id, processing: processing) } : nil
        return LANInboxPage(revision: revision, items: items, nextCursor: next)
    }
}
