import Darwin
import Foundation
import GRDB
import KinlogueCore

// SAFETY: the lock protects tokens; scope creation/revocation and final publication share kernel admission.
private final class SQLiteLANScopes: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: Set<UUID> = []
    func create(epoch: UUID) -> LANInboxPublicationGuard {
        lock.withLock { let token = UUID(); tokens.insert(token); return LANInboxPublicationGuard(runtimeGeneration: epoch, token: token) }
    }
    func require(_ guardValue: LANInboxPublicationGuard, epoch: UUID) throws {
        try lock.withLock { guard guardValue.runtimeGeneration == epoch, tokens.contains(guardValue.token) else { throw LANInboxError.vaultUnavailable } }
    }
    func revoke(_ guardValue: LANInboxPublicationGuard, epoch: UUID) throws {
        try lock.withLock { guard guardValue.runtimeGeneration == epoch else { throw LANInboxError.vaultUnavailable }; tokens.remove(guardValue.token) }
    }
}

package final class SQLiteLANInboxStore: LANPendingItemStoring, Sendable {
    let store: SQLiteLibraryStore
    let epoch: UUID
    package let admissionPolicy: LANInboxAdmissionPolicy
    private let scopes: SQLiteLANScopes
    private let defaultScope: LANInboxPublicationGuard

    package init(store: SQLiteLibraryStore, admissionPolicy: LANInboxAdmissionPolicy? = nil) throws {
        self.store = store
        epoch = try store.readWithEpoch { _ in () }.1
        self.admissionPolicy = try admissionPolicy ?? LANInboxAdmissionPolicy()
        let scopes = SQLiteLANScopes()
        self.scopes = scopes
        defaultScope = scopes.create(epoch: epoch)
    }

    @concurrent
    package func initialize() async throws -> LANInboxSnapshot {
        try await LibraryStorageExecutor.run {
            try await prepare()
            return try await loadSnapshot()
        }
    }

    package func archiveRecoverySnapshot() async throws -> LANInboxSnapshot? { nil }

    @concurrent
    package func prepare() async throws {
        try await LibraryStorageExecutor.run {
            _ = try store.read(epoch: epoch) { _ in () }
            _ = try store.recoverLANUploads()
            try write { db in
                let ids = try Data.fetchAll(db, sql: "SELECT id FROM inbox_items WHERE state = 'preprocessing' LIMIT 5001")
                guard ids.count <= 5_000 else { throw LANInboxError.resourceLimitExceeded }
                var changed = false
                for bytes in ids {
                    guard let id = UUID(sqliteBytes: bytes) else { throw LANInboxError.invalidModel }
                    let item: LANInboxItem
                    do { item = try usableItem(id, db) }
                    catch let error as DatabaseError { throw error }
                    catch { continue }
                    let failed = try item.transitioning(to: .failed(blobID: item.blobID, issue: .storageFailure), expectedRevision: item.revision, expectedAttemptID: item.attemptID)
                    try SQLiteLANRows.saveItem(failed, db)
                    changed = true
                }
                if changed { try SQLiteLibraryState.advance(in: db) }
            }
        }
    }

    @concurrent
    package func inspect() async -> LANInboxAccessState {
        await LibraryStorageExecutor.run {
            do {
                let value = try store.read(epoch: epoch, SQLiteLibraryState.read)
                return .ready(try LANInboxRevision(generation: UInt64(value.generation) + 1, commitID: value.commitID, manifestDigest: value.contentHash))
            } catch SQLiteLibraryError.unsupportedFormat { return .unsupportedVersion }
            catch { return .damaged }
        }
    }

    @concurrent
    package func loadItems(ids: [UUID]) async throws -> [LANInboxItem] {
        try await LibraryStorageExecutor.run {
            guard ids.count <= LANArchiveIntent.maximumSourceCount, Set(ids).count == ids.count else { throw LANInboxError.resourceLimitExceeded }
            return try store.read(epoch: epoch) { db in try ids.map { try usableItem($0, db) } }
        }
    }
    @concurrent
    package func loadSnapshot() async throws -> LANInboxSnapshot { try await LibraryStorageExecutor.run { try store.read(epoch: epoch) { try SQLiteLANRows.snapshot($0, epoch: epoch) } } }
    @concurrent
    package func publicationGuard() async throws -> LANInboxPublicationGuard {
        try await LibraryStorageExecutor.run {
            try store.read(epoch: epoch) { _ in scopes.create(epoch: epoch) }
        }
    }
    @concurrent
    package func revokePublications(guardedBy value: LANInboxPublicationGuard) async throws {
        try await LibraryStorageExecutor.run {
            try store.read(epoch: epoch) { _ in try scopes.revoke(value, epoch: epoch) }
        }
    }
    @concurrent
    package func itemAdmissionGeneration() async throws -> UInt64 { try await LibraryStorageExecutor.run { UInt64(try store.read(epoch: epoch, SQLiteLibraryState.read).generation) + 1 } }

    @concurrent
    package func startItemUpload(transport: LANInboxTransportIdentity, metadata: LANInboxTransportMetadata, attemptRevision: UInt64,
        admissionGeneration: UInt64? = nil, publicationGuard: LANInboxPublicationGuard? = nil) async throws -> LANItemUploadStartOutcome {
        try await LibraryStorageExecutor.run {
            try Task.checkCancellation()
            let scope = publicationGuard ?? defaultScope
            try scopes.require(scope, epoch: epoch)
            let permit = try admissionPolicy.acquireUploadPermit()
            do {
                let prepared = try store.read(epoch: epoch) { db -> (LANInboxTransportReceipt?, UInt64) in
                    let current = UInt64(try SQLiteLibraryState.read(from: db).generation) + 1
                    if let receipt = try SQLiteLANRows.receipt(transport, db) {
                        guard receipt.matches(transport: transport, metadata: metadata) else { throw LANInboxError.receiptConflict }
                        return (receipt, current)
                    }
                    guard attemptRevision <= Int64.max else { throw LANInboxError.invalidRevision }
                    let admitted = admissionGeneration ?? current
                    guard admitted > 0, admitted <= current else { throw LANInboxError.invalidGeneration }
                    if let active = try Data.fetchOne(db, sql: "SELECT id FROM inbox_uploads WHERE session_id = ? AND remote_file_id = ?", arguments: [transport.sessionID.sqliteBytes, transport.remoteFileID.sqliteBytes]), let id = UUID(sqliteBytes: active) {
                        guard try SQLiteLANUpload.read(id, db).metadata == metadata else { throw LANInboxError.receiptConflict }
                        throw LANInboxError.mutationConflict
                    }
                    try Self.checkReceiptCapacity(session: transport.sessionID, db)
                    return (nil, admitted)
                }
                if let receipt = prepared.0 { permit.release(); return .terminal(receipt) }
                let requested = SQLiteLANUpload(id: UUID(), scopeID: scope.token, transport: transport, metadata: metadata,
                    attemptRevision: attemptRevision, admissionGeneration: prepared.1)
                let (upload, descriptor) = try store.beginLANUpload(requested, epoch: epoch) { try scopes.require(scope, epoch: epoch) }
                do {
                    let sink = try LANUploadSink(attemptID: upload.id, descriptor: descriptor, declaredByteCount: metadata.declaredByteCount,
                        uploadPermit: permit, cleanup: { [self] fd in try await LibraryStorageExecutor.run { try store.cancelLANUpload(upload, descriptor: fd) } },
                        publish: { [self] completed, fd in try await publish(upload, completed: completed, descriptor: fd, scope: scope) },
                        failureInjector: .none, descriptorDidClose: { [store] in store.finishOriginalOperation(upload.id) })
                    return .sink(sink)
                } catch {
                    // The sink initializer owns and closes the descriptor even on rejection.
                    try? store.cancelLANUpload(upload, descriptor: nil)
                    throw error
                }
            } catch { permit.release(); throw Self.mapped(error) }
        }
    }

    @concurrent
    private func publish(_ upload: SQLiteLANUpload, completed: LANUploadSink.CompletedUpload, descriptor: Int32, scope: LANInboxPublicationGuard) async throws {
        try await LibraryStorageExecutor.run {
            let content = try LANInboxContentIdentity(sha256Digest: completed.sha256Digest, byteCount: completed.byteCount)
            let canonical = try store.read(epoch: epoch) { try SQLiteLANRows.canonicalItem(content, $0) }
            var canonicalPin: SQLiteOriginalPin?
            if let canonical {
                let pin = try store.pinOriginal(canonical.blobID)
                canonicalPin = pin
                do { try pin.withVerifiedDescriptor { _ in () } }
                catch { pin.release(); throw error }
            }
            defer { canonicalPin?.release() }
            do {
                try store.commitLANUpload(upload, completed: completed, descriptor: descriptor, epoch: epoch) { db, original in
                    try scopes.require(scope, epoch: epoch)
                    guard try SQLiteLANRows.receipt(upload.transport, db) == nil else { throw LANInboxError.receiptConflict }
                    guard try SQLiteLANRows.canonicalItem(content, db) == canonical else { throw LANInboxError.staleRevision }
                    let terminal = try SQLiteLANRows.terminal(session: upload.transport.sessionID, content: content, db)
                    let outcome: LANInboxTransportOutcome
                    if let canonical { outcome = .merged(itemID: canonical.id) }
                    else if let terminal, terminal.applies(sessionID: upload.transport.sessionID, admissionGeneration: upload.admissionGeneration) {
                        switch terminal.kind { case .archived: outcome = .archived; case .deleted: outcome = .deleted }
                    } else {
                        guard try Int.fetchOne(db, sql: "SELECT count(*) FROM inbox_items")! < LANInboxSnapshot.maximumItemCount else { throw LANInboxError.resourceLimitExceeded }
                        let item = try LANInboxItem(originatingSessionID: upload.transport.sessionID, displayName: upload.metadata.displayName,
                            receivedAt: Date(), sequence: UInt64(SQLiteLibraryState.read(from: db).generation), contentIdentity: content, state: .stored(blobID: original.id))
                        try SQLiteLANRows.saveItem(item, db)
                        outcome = .published(itemID: item.id)
                    }
                    let receipt = try LANInboxTransportReceipt(transport: upload.transport, metadata: upload.metadata,
                        attemptRevision: upload.attemptRevision, contentIdentity: content, completedAt: Date(), outcome: outcome)
                    try SQLiteLANRows.saveReceipt(receipt, db)
                    try SQLiteLibraryState.advance(in: db)
                }
            } catch {
                // Reconcile a committed receipt before the sink attempts partial cleanup.
                if let receipt = try? store.read(epoch: epoch, { try SQLiteLANRows.receipt(upload.transport, $0) }),
                   receipt.matches(transport: upload.transport, metadata: upload.metadata), receipt.contentIdentity == content { return }
                throw Self.mapped(error)
            }
        }
    }

    @concurrent
    package func recordItemUploadCancellation(transport: LANInboxTransportIdentity, metadata: LANInboxTransportMetadata, attemptRevision: UInt64) async throws -> LANInboxTransportReceipt {
        try await LibraryStorageExecutor.run {
            try write { db in
                if let receipt = try SQLiteLANRows.receipt(transport, db) {
                    guard receipt.matches(transport: transport, metadata: metadata) else { throw LANInboxError.receiptConflict }; return receipt
                }
                guard try Int.fetchOne(db, sql: "SELECT count(*) FROM inbox_uploads WHERE session_id = ? AND remote_file_id = ?", arguments: [transport.sessionID.sqliteBytes, transport.remoteFileID.sqliteBytes]) == 0 else { throw LANInboxError.mutationConflict }
                try Self.checkReceiptCapacity(session: transport.sessionID, db)
                let receipt = try LANInboxTransportReceipt(transport: transport, metadata: metadata, attemptRevision: attemptRevision, contentIdentity: nil, completedAt: Date(), outcome: .cancelled)
                try SQLiteLANRows.saveReceipt(receipt, db)
                try SQLiteLibraryState.advance(in: db)
                return receipt
            }
        }
    }

    @concurrent
    package func endItemSession(sessionID: UUID) async throws {
        try await LibraryStorageExecutor.run {
            try write { db in
                guard try Int.fetchOne(db, sql: "SELECT count(*) FROM inbox_uploads WHERE session_id = ?", arguments: [sessionID.sqliteBytes]) == 0 else { throw LANInboxError.mutationConflict }
                let count = try Int.fetchOne(db, sql: "SELECT (SELECT count(*) FROM inbox_transport_receipts WHERE session_id = ?) + (SELECT count(*) FROM inbox_content_terminals WHERE session_id = ?)", arguments: [sessionID.sqliteBytes, sessionID.sqliteBytes])!
                guard count > 0 else { return }
                try db.execute(sql: "DELETE FROM inbox_transport_receipts WHERE session_id = ?", arguments: [sessionID.sqliteBytes])
                try db.execute(sql: "DELETE FROM inbox_content_terminals WHERE session_id = ?", arguments: [sessionID.sqliteBytes])
                try SQLiteLibraryState.advance(in: db)
            }
        }
    }

    @concurrent
    package func withVerifiedItemSourceContent<T: Sendable>(itemID: UUID, _ body: @escaping @Sendable (Int32) throws -> T) async throws -> T {
        try await LibraryStorageExecutor.run {
            let item = try store.read(epoch: epoch) { try usableItem(itemID, $0) }
            do {
                let pin = try store.pinOriginal(item.blobID)
                defer { pin.release() }
                let result = try pin.withVerifiedDescriptor(body)
                guard try store.read(epoch: epoch, { try usableItem(itemID, $0) }) == item else { throw LANInboxError.staleRevision }
                return result
            } catch SQLiteLibraryError.invalidOriginal {
                try? write { db in
                    // Persist the failure even after the pin quarantined this original in memory.
                    let current = try SQLiteLANRows.item(itemID, db)
                    guard current == item else { return }
                    let bad = try item.transitioning(to: .integrityFailed(blobID: item.blobID, issue: .integrityMismatch), expectedRevision: item.revision, expectedAttemptID: item.attemptID)
                    try SQLiteLANRows.saveItem(bad, db)
                    try SQLiteReportRows.deleteDocumentIfUnreferenced(item.derivedArtifact?.id, db)
                    try SQLiteLibraryState.advance(in: db)
                }
                throw LANInboxError.integrityCheckFailed
            }
        }
    }

    @concurrent
    package func reportAttachmentID(for item: LANInboxItem) async throws -> UUID {
        try await LibraryStorageExecutor.run {
            guard try store.read(epoch: epoch, { try usableItem(item.id, $0) }) == item else { throw LANInboxError.staleRevision }
            return item.blobID
        }
    }

    @concurrent
    package func markItemPreprocessingIssue(itemID: UUID, expectedRevision: UInt64, issue: LANInboxFileIssue) async throws -> LANInboxItem {
        try await LibraryStorageExecutor.run {
            guard issue == .unsupportedContent || issue == .preprocessingFailed else { throw LANInboxError.invalidState }
            return try write { db in
                let item = try usableItem(itemID, db)
                let state: LANInboxItemState = issue == .unsupportedContent ? .unsupported(blobID: item.blobID, issue: issue) : .failed(blobID: item.blobID, issue: issue)
                let next = try item.transitioning(to: state, expectedRevision: expectedRevision, expectedAttemptID: item.attemptID)
                try SQLiteLANRows.saveItem(next, db)
                try SQLiteReportRows.deleteDocumentIfUnreferenced(item.derivedArtifact?.id, db)
                try SQLiteLibraryState.advance(in: db)
                return next
            }
        }
    }

    @concurrent
    package func loadPreprocessedDocument(itemID: UUID, expectedRevision: UInt64) async throws -> LANPreprocessedSourceDocument {
        try await LibraryStorageExecutor.run {
            try store.read(epoch: epoch) { try Self.document(for: usableItem(itemID, $0), revision: expectedRevision, $0) }
        }
    }

    static func document(for item: LANInboxItem, revision: UInt64, _ db: Database) throws -> LANPreprocessedSourceDocument {
        guard item.revision == revision, let artifact = item.derivedArtifact else { throw LANInboxError.staleRevision }
        let data = try SQLiteReportRows.documentData(artifact.id, kind: "lanSource", db)
        guard data.count == artifact.byteCount, ContentDigest.sha256(data) == artifact.sha256Digest else { throw LANInboxError.integrityCheckFailed }
        let value = try CanonicalVaultJSON.decode(LANPreprocessedSourceDocument.self, from: data)
        guard value.source.attachmentID == item.blobID, value.source.displayName == item.displayName.rawValue,
              try SQLiteOriginal.read(item.blobID, from: db).contentType == value.contentTypeIdentifier else { throw LANInboxError.invalidReference }
        return value
    }

    @concurrent
    package func savePreprocessedDocument(itemID: UUID, expectedRevision: UInt64, document: LANPreprocessedSourceDocument) async throws -> LANInboxItem {
        try await LibraryStorageExecutor.run {
            let data = try CanonicalVaultJSON.encode(document)
            guard data.count <= LANPreprocessedSourceDocument.maximumEncodedByteCount else { throw LANItemPreprocessorError.sourceTooLarge }
            try Task.checkCancellation()
            return try write { db in
                let item = try usableItem(itemID, db)
                guard document.source.attachmentID == item.blobID, document.source.displayName == item.displayName.rawValue else { throw LANInboxError.invalidReference }
                let processing = try item.transitioning(to: .preprocessing(blobID: item.blobID, attemptID: UUID()), expectedRevision: expectedRevision, expectedAttemptID: item.attemptID)
                let artifact = try LANInboxDerivedArtifact(sha256Digest: ContentDigest.sha256(data), byteCount: data.count)
                let next = try processing.transitioning(to: .reviewable(blobID: item.blobID, derived: artifact), expectedRevision: processing.revision, expectedAttemptID: processing.attemptID)
                try SQLiteReportRows.requireExclusiveDocument(artifact.id, reportID: nil, draftID: nil, db)
                try SQLiteReportRows.put(db, table: "ocr_documents", columns: SQLiteReportRows.documentColumns, values: [artifact.id.sqliteBytes.databaseValue,
                    "lanSource".databaseValue, 1.databaseValue, .null, Int64(next.revision).databaseValue, data.databaseValue, artifact.sha256Digest.databaseValue])
                let old = try SQLiteOriginal.read(item.blobID, from: db)
                guard old.byteCount <= 100 * 1_024 * 1_024, document.source.pageCount <= 200,
                      document.contentTypeIdentifier.utf8.count <= 256 else { throw LANInboxError.resourceLimitExceeded }
                let classified = SQLiteOriginal(id: old.id, byteCount: old.byteCount, sha256: old.sha256, contentType: document.contentTypeIdentifier,
                    lifecycle: old.lifecycle, operationID: old.operationID, identity: old.identity)
                try db.execute(sql: "UPDATE originals SET content_type = ?, content_hash = ? WHERE id = ?", arguments: [classified.contentType, classified.contentHash, old.id.sqliteBytes])
                try SQLiteLANRows.saveItem(next, db)
                try SQLiteReportRows.deleteDocumentIfUnreferenced(item.derivedArtifact?.id, db)
                try SQLiteLibraryState.advance(in: db)
                return next
            }
        }
    }

    @concurrent
    package func deleteItem(itemID: UUID, expectedRevision: UInt64, activeSessionID: UUID?, admissionGenerationCutoff: UInt64? = nil) async throws -> LANInboxSnapshot {
        try await LibraryStorageExecutor.run {
            try await removeItem(itemID: itemID, expectedRevision: expectedRevision, activeSessionID: activeSessionID, admissionGenerationCutoff: admissionGenerationCutoff)
            return try await loadSnapshot()
        }
    }

    package func removeItem(itemID: UUID, expectedRevision: UInt64, activeSessionID: UUID?) async throws {
        try await removeItem(itemID: itemID, expectedRevision: expectedRevision, activeSessionID: activeSessionID, admissionGenerationCutoff: nil)
    }

    @concurrent
    private func removeItem(itemID: UUID, expectedRevision: UInt64, activeSessionID: UUID?, admissionGenerationCutoff: UInt64?) async throws {
        try await LibraryStorageExecutor.run {
            let originalID = try write { db in
                let item = try usableItem(itemID, db)
                guard item.revision == expectedRevision else { throw LANInboxError.staleRevision }
                let current = UInt64(try SQLiteLibraryState.read(from: db).generation) + 1
                let cutoff = admissionGenerationCutoff ?? current
                guard cutoff >= current else { throw LANInboxError.invalidGeneration }
                let affected = try Self.receipts(contents: [item.contentIdentity], db)
                if let activeSessionID { try Self.putTerminal(session: activeSessionID, content: item.contentIdentity, kind: .deleted(admissionGenerationCutoff: cutoff), db) }
                for receipt in affected {
                    if receipt.transport.sessionID == activeSessionID { try SQLiteLANRows.saveReceipt(Self.receipt(receipt, outcome: .deleted), db) }
                    else { try db.execute(sql: "DELETE FROM inbox_transport_receipts WHERE id = ?", arguments: [receipt.id.sqliteBytes]) }
                }
                try db.execute(sql: "DELETE FROM inbox_items WHERE id = ?", arguments: [itemID.sqliteBytes])
                try SQLiteReportRows.deleteDocumentIfUnreferenced(item.derivedArtifact?.id, db)
                try store.markUnreferencedOriginalsDeleting([item.blobID], in: db)
                try SQLiteLibraryState.advance(in: db)
                return item.blobID
            }
            try store.reclaimDeletingOriginal(originalID)
        }
    }

    @concurrent
    package func snapshotAndStorageSummary() async throws -> LANInboxSnapshotAndStorageSummary {
        try await LibraryStorageExecutor.run {
            let (screen, uploads, invalidUploads) = try store.read(epoch: epoch) { db in
                let screen = try SQLiteLANRows.screen(db, epoch: epoch, quarantinedItemIDs: store.quarantinedIDs(.inbox))
                let uploads = try Self.loadUploads(db)
                return (screen, uploads.values, uploads.invalidIDs)
            }
            let partials = try partialSummary(uploads: uploads, invalidUploads: invalidUploads)
            let usage = admissionPolicy.currentUsage
            return LANInboxSnapshotAndStorageSummary(snapshot: screen.snapshot, storage: try screen.snapshot.storageSummary(
                pendingUploadCount: usage.activeUploadCount, pendingByteCount: usage.totalPendingByteCount,
                partialObjectCount: partials.count, partialByteCount: partials.bytes, metadataByteCount: 0,
                cleanupDebtObjectCount: partials.debt, cleanupDebtByteCount: 0), damagedItemIDs: screen.damagedItemIDs,
                damagedReceiptIDs: screen.damagedReceiptIDs, damagedTerminalIDs: screen.damagedTerminalIDs, damagedUploadIDs: partials.damaged)
        }
    }

    private static func loadUploads(_ db: Database) throws -> (values: [SQLiteLANUpload], invalidIDs: [UUID]) {
        let rows = try SQLiteRows.fetchAll(db, sql: "SELECT \(SQLiteHotProjection.sql(SQLiteLANUpload.columns, bounds: ["display_name": 1_024, "media_type": 256])) FROM inbox_uploads LIMIT 5001")
        guard rows.count <= 5_000 else { throw LANInboxError.resourceLimitExceeded }
        var uploads: [SQLiteLANUpload] = [], invalid: [UUID] = []
        for row in rows {
            do {
                guard !(row["oversized"] as Bool) else { throw LANInboxError.resourceLimitExceeded }
                uploads.append(try SQLiteLANUpload.decode(row))
            } catch { invalid.append(try SQLiteReportRows.uuid(row, "id")) }
        }
        return (uploads, invalid)
    }

    private func partialSummary(uploads: [SQLiteLANUpload], invalidUploads: [UUID]) throws -> (count: Int, bytes: Int, debt: Int, damaged: [UUID]) {
        var damagedUploads = invalidUploads
        var partialBytes = 0, partialCount = 0, debtCount = damagedUploads.count
        for upload in uploads {
            try Task.checkCancellation()
            let id = upload.id
            do {
                var bytes = 0, count = 0
                for ext in ["upload", "data"] {
                    let url = store.originalsURL.appendingPathComponent(id.uuidString.lowercased() + "." + ext)
                    let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                    guard fd >= 0 else { continue }
                    defer { Darwin.close(fd) }
                    guard try SQLiteFileIdentity.regular(descriptor: fd) == upload.identity else { throw LANInboxError.integrityCheckFailed }
                    var info = stat()
                    guard fstat(fd, &info) == 0, let size = Int(exactly: info.st_size) else { throw LANInboxError.storageFailure }
                    let next = bytes.addingReportingOverflow(size)
                    guard !next.overflow else { throw LANInboxError.arithmeticOverflow }
                    bytes = next.partialValue; count += 1
                }
                let next = partialBytes.addingReportingOverflow(bytes)
                guard !next.overflow else { throw LANInboxError.arithmeticOverflow }
                partialBytes = next.partialValue; partialCount += count
                if count == 0 || !store.admission.withLock({ store.activeOriginals.contains(id) }) { debtCount += 1 }
            } catch {
                damagedUploads.append(id); debtCount += 1
            }
        }
        // Physical partial checks run outside admission; never publish across a replaced root or epoch.
        try store.read(epoch: epoch) { _ in () }
        return (partialCount, partialBytes, debtCount, damagedUploads)
    }

    @concurrent
    package func itemPage(cursor: LANInboxPageCursor? = nil, processing: Bool = false) async throws -> LANInboxPage {
        try await LibraryStorageExecutor.run {
            try store.read(epoch: epoch) { db in
                try SQLiteReadProgress.withGuard(db, check: { try Task.checkCancellation() }) {
                    try SQLiteLANRows.page(db, epoch: epoch, cursor: cursor, processing: processing, quarantinedItemIDs: store.quarantinedIDs(.inbox))
                }
            }
        }
    }

    @concurrent
    package func queueScreen(cursor: LANInboxPageCursor? = nil) async throws -> LANInboxQueueScreen {
        try await LibraryStorageExecutor.run {
            let (page, totals, uploads, invalidUploads, damagedReceipts, damagedTerminals) = try store.read(epoch: epoch) { db in
                try SQLiteReadProgress.withGuard(db, check: { try Task.checkCancellation() }) {
                    let page = try SQLiteLANRows.page(db, epoch: epoch, cursor: cursor, processing: false, quarantinedItemIDs: store.quarantinedIDs(.inbox))
                    let totals = try SQLiteLANRows.totals(db)
                    let uploads = try Self.loadUploads(db)
                    return (page, totals, uploads.values, uploads.invalidIDs, store.quarantinedIDs(.receipt).sorted { $0.uuidString < $1.uuidString },
                        store.quarantinedIDs(.terminal).sorted { $0.uuidString < $1.uuidString })
                }
            }
            let partials = try partialSummary(uploads: uploads, invalidUploads: invalidUploads)
            let usage = admissionPolicy.currentUsage
            return LANInboxQueueScreen(page: page, storage: try LANInboxStorageSummary(
                itemCount: totals.items, uniqueBlobCount: totals.items, sourceByteCount: totals.sourceBytes,
                derivedArtifactCount: totals.documents, derivedByteCount: totals.documentBytes,
                pendingUploadCount: usage.activeUploadCount, pendingByteCount: usage.totalPendingByteCount,
                partialObjectCount: partials.count, partialByteCount: partials.bytes, metadataByteCount: 0,
                cleanupDebtObjectCount: partials.debt), usesContentByteTotals: true, damagedUploadIDs: partials.damaged,
                damagedReceiptIDs: damagedReceipts, damagedTerminalIDs: damagedTerminals)
        }
    }

    func write<T: Sendable>(_ body: (Database) throws -> T) throws -> T {
        try store.write { db in guard store.openEpoch == epoch else { throw SQLiteLibraryError.staleRoot }; return try body(db) }
    }
    static func mapped(_ error: Error) -> Error { SQLiteLibraryStore.sanitized(error) }
    private static func checkReceiptCapacity(session: UUID, _ db: Database) throws {
        let total = try Int.fetchOne(db, sql: "SELECT (SELECT count(*) FROM inbox_transport_receipts) + (SELECT count(*) FROM inbox_uploads)")!
        let sessionCount = try Int.fetchOne(db, sql: "SELECT (SELECT count(*) FROM inbox_transport_receipts WHERE session_id = ?) + (SELECT count(*) FROM inbox_uploads WHERE session_id = ?)", arguments: [session.sqliteBytes, session.sqliteBytes])!
        guard total < LANInboxSnapshot.maximumTransportReceiptCount, sessionCount < LANInboxSnapshot.maximumTransportReceiptsPerSession else { throw LANInboxError.resourceLimitExceeded }
    }
    static func receipts(contents: Set<LANInboxContentIdentity>, _ db: Database) throws -> [LANInboxTransportReceipt] {
        var result: [LANInboxTransportReceipt] = []
        for content in contents {
            for row in try SQLiteRows.fetchAll(db, sql: "SELECT session_id,remote_file_id FROM inbox_transport_receipts WHERE content_sha256 = ? AND content_byte_count = ?", arguments: [content.sha256Digest, content.byteCount]) {
                let transport = try LANInboxTransportIdentity(sessionID: SQLiteReportRows.uuid(row, "session_id"), remoteFileID: SQLiteReportRows.uuid(row, "remote_file_id"))
                guard let receipt = try SQLiteLANRows.receipt(transport, db) else { throw LANInboxError.invalidReference }; result.append(receipt)
            }
        }
        return result
    }
    static func receipt(_ value: LANInboxTransportReceipt, outcome: LANInboxTransportOutcome) throws -> LANInboxTransportReceipt {
        try LANInboxTransportReceipt(id: value.id, transport: value.transport, metadata: value.metadata, attemptRevision: value.attemptRevision,
            contentIdentity: value.contentIdentity, completedAt: value.completedAt, outcome: outcome)
    }
    static func putTerminal(session: UUID, content: LANInboxContentIdentity, kind: LANInboxContentTerminalKind, _ db: Database) throws {
        let existing = try SQLiteLANRows.terminal(session: session, content: content, db)
        if existing == nil { guard try Int.fetchOne(db, sql: "SELECT count(*) FROM inbox_content_terminals")! < LANInboxSnapshot.maximumContentTerminalCount else { throw LANInboxError.resourceLimitExceeded } }
        try SQLiteLANRows.saveTerminal(LANInboxContentTerminal(id: existing?.id ?? UUID(), sessionID: session, contentIdentity: content, createdAt: Date(), kind: kind), db)
    }
}
