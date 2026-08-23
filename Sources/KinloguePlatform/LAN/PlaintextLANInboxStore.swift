import CryptoKit
import Darwin
import Foundation
import KinlogueCore

public enum PlaintextLANInboxStoreFault: Equatable, Sendable {
    case beforeManifestWrite
    case afterManifestCommit
    case afterPartialCreateFileSyncBeforeDirectorySync
    case beforeBlobPublish
    case afterBlobRenameBeforeBlobDirectorySync
    case afterBlobDirectorySyncBeforePartialDirectorySync
    case afterBlobPublish
    case beforeDerivedPublish
    case afterDerivedRenameBeforeDerivedDirectorySync
    case afterDerivedDirectorySyncBeforePartialDirectorySync
    case afterDerivedPublish
    case afterPartialUnlinkBeforeDirectorySync
    case beforePhysicalCleanup
}

public enum LANInboxPartialActivityProbeStep: Equatable, Sendable {
    case open
    case metadata
    case lock
}

public enum LANItemUploadStartOutcome: Sendable {
    case sink(LANUploadSink)
    case terminal(LANInboxTransportReceipt)
}

public enum LANArchivePreparationOutcome: Equatable, Sendable {
    case active(LANArchiveIntent)
    case completed(LANArchiveTerminal)
}

public struct LANInboxSnapshotAndStorageSummary: Sendable {
    public let snapshot: LANInboxSnapshot
    public let storage: LANInboxStorageSummary

    public init(snapshot: LANInboxSnapshot, storage: LANInboxStorageSummary) {
        self.snapshot = snapshot
        self.storage = storage
    }
}

public struct LANInboxPublicationGuard: Equatable, Sendable {
    public let runtimeGeneration: UUID
    fileprivate let token: UUID

    fileprivate init(runtimeGeneration: UUID, token: UUID) {
        self.runtimeGeneration = runtimeGeneration
        self.token = token
    }
}

private struct LANInboxManifestEnvelope: Codable {
    let magic: String
    let schemaVersion: Int
    let payloadSHA256: Data
    let payload: Data
}

private enum LANInboxManifestCodec {
    static let magic = "KLGINBOX2"
    static let schemaVersion = 1
    static let maximumByteCount = 64 * 1_024 * 1_024

    static func encode<Payload: Encodable>(_ payload: Payload) throws -> Data {
        let payloadData: Data
        do {
            payloadData = try CanonicalVaultJSON.encode(payload)
        } catch {
            throw VaultError.invalidCatalog
        }
        guard payloadData.count <= maximumByteCount else {
            throw VaultError.resourceLimitExceeded
        }
        let envelope = LANInboxManifestEnvelope(
            magic: magic,
            schemaVersion: schemaVersion,
            payloadSHA256: ContentDigest.sha256(payloadData),
            payload: payloadData
        )
        let encoded: Data
        do {
            encoded = try CanonicalVaultJSON.encode(envelope)
        } catch {
            throw VaultError.invalidCatalog
        }
        guard encoded.count <= maximumByteCount else {
            throw VaultError.resourceLimitExceeded
        }
        return encoded
    }

    static func decode<Payload: Codable>(
        _ type: Payload.Type,
        from data: Data
    ) throws -> Payload {
        guard data.count <= maximumByteCount else {
            throw VaultError.resourceLimitExceeded
        }
        let envelope: LANInboxManifestEnvelope
        do {
            envelope = try CanonicalVaultJSON.decode(
                LANInboxManifestEnvelope.self,
                from: data
            )
        } catch {
            throw VaultError.invalidCatalog
        }
        guard envelope.magic == magic else {
            if envelope.magic == "KLGINBOX1" {
                throw VaultError.unsupportedVersion(envelope.schemaVersion)
            }
            throw VaultError.invalidCatalog
        }
        guard envelope.schemaVersion == schemaVersion else {
            throw VaultError.unsupportedVersion(envelope.schemaVersion)
        }
        guard envelope.payloadSHA256.count == SHA256.byteCount,
              envelope.payload.count <= maximumByteCount,
              ContentDigest.sha256(envelope.payload) == envelope.payloadSHA256 else {
            throw VaultError.invalidDigest
        }
        let payload: Payload
        do {
            payload = try CanonicalVaultJSON.decode(type, from: envelope.payload)
        } catch {
            throw VaultError.invalidCatalog
        }
        do {
            guard try CanonicalVaultJSON.encode(payload) == envelope.payload,
                  try CanonicalVaultJSON.encode(envelope) == data else {
                throw VaultError.invalidCatalog
            }
        } catch let error as VaultError {
            throw error
        } catch {
            throw VaultError.invalidCatalog
        }
        return payload
    }
}

private struct LANInboxContentReference: Hashable, Sendable {
    let relativePath: String
    let sha256Digest: Data
    let byteCount: Int
}

private struct LANInboxOpenedContent: Sendable {
    let reference: LANInboxContentReference
    let descriptor: Int32
    let identity: LANInboxRegularFileIdentity
}

private struct LANInboxItemSourceVerificationEvidence: Sendable {
    let root: VaultRootGeneration
    let item: LANInboxItem
    let blob: LANInboxBlob
    let openedContent: LANInboxOpenedContent
}

private struct LANInboxItemDerivedVerificationEvidence: Sendable {
    let root: VaultRootGeneration
    let item: LANInboxItem
    let artifact: LANInboxDerivedArtifact
    let openedContent: LANInboxOpenedContent
}

private struct LANInboxActiveItemUpload: Sendable {
    let metadata: LANInboxTransportMetadata
    let attemptRevision: UInt64
    let attemptID: UUID
    let admissionGeneration: UInt64
}

/// Crash-recoverable item-only LAN pending queue.
///
/// The independent manifest is the sole logical commit point. Every mutation
/// reloads it under the vault-wide process and filesystem lease; display names
/// remain metadata and never participate in a path.
public actor PlaintextLANInboxStore: LANInboxRepository {
    public typealias Clock = @Sendable () -> Date
    public typealias IDGenerator = @Sendable () -> UUID
    public typealias FailureInjector = @Sendable (PlaintextLANInboxStoreFault) -> Bool
    public typealias PartialActivityProbeFailureInjector = @Sendable (
        LANInboxPartialActivityProbeStep
    ) -> Int32?
    public typealias PublicationVerificationWillHash = @Sendable () -> Void
    public typealias DerivedVerificationWillHash = @Sendable () -> Void
    public typealias SourceVerificationWillHash = @Sendable () -> Void
    public typealias SourceVerificationDidOpen = @Sendable () -> Void
    public typealias ScreenProjectionWillRebuild = @Sendable () -> Void

    private let layout: LANInboxLayout
    private let directories: LANInboxManagedDirectories
    private let files: AtomicFileStore
    private let rootBinding: VaultRootBinding
    private let mutationCoordinator: VaultMutationCoordinator
    private let admissionPolicy: LANInboxAdmissionPolicy
    private let derivedWriteAdmission: LANPendingWriteAdmission
    private let runtimeGeneration: UUID
    private let publicationGuardToken: UUID
    private let now: Clock
    private let makeID: IDGenerator
    private let failureInjector: FailureInjector?
    private let partialActivityProbeFailureInjector: PartialActivityProbeFailureInjector?
    private let publicationVerificationWillHash: PublicationVerificationWillHash?
    private let derivedVerificationWillHash: DerivedVerificationWillHash?
    private let sourceVerificationWillHash: SourceVerificationWillHash?
    private let sourceVerificationDidOpen: SourceVerificationDidOpen?
    private let screenProjectionWillRebuild: ScreenProjectionWillRebuild?
    private var boundRootGeneration: VaultRootGeneration?
    private var publicationsRevoked = false
    private var activeItemUploads: [LANInboxTransportIdentity: LANInboxActiveItemUpload] = [:]
    private var screenProjectionCache: ScreenProjectionCache?

    nonisolated var backupRootURL: URL { layout.rootURL }

    public init(
        rootURL: URL,
        runtimeGeneration: UUID = UUID(),
        admissionLimits: LANInboxAdmissionPolicy.Limits = .production,
        now: @escaping Clock = { Date() },
        makeID: @escaping IDGenerator = { UUID() },
        fileFailureInjector: (@Sendable (AtomicFileStoreFaultPoint) -> Bool)? = nil,
        failureInjector: FailureInjector? = nil,
        partialActivityProbeFailureInjector: PartialActivityProbeFailureInjector? = nil,
        publicationVerificationWillHash: PublicationVerificationWillHash? = nil,
        derivedVerificationWillHash: DerivedVerificationWillHash? = nil,
        sourceVerificationWillHash: SourceVerificationWillHash? = nil,
        sourceVerificationDidOpen: SourceVerificationDidOpen? = nil,
        screenProjectionWillRebuild: ScreenProjectionWillRebuild? = nil
    ) throws {
        let layout = try LANInboxLayout(rootURL: rootURL)
        self.layout = layout
        directories = LANInboxManagedDirectories(
            layout: layout,
            failureInjector: failureInjector
        )
        files = try AtomicFileStore(
            rootURL: layout.rootURL,
            failureInjector: fileFailureInjector
        )
        rootBinding = try VaultRootBinding(rootURL: layout.rootURL)
        mutationCoordinator = VaultMutationCoordinator.shared(for: layout.rootURL)
        admissionPolicy = try LANInboxAdmissionPolicy(limits: admissionLimits)
        derivedWriteAdmission = try LANPendingWriteAdmission(limits: .derivedProduction)
        self.runtimeGeneration = runtimeGeneration
        publicationGuardToken = UUID()
        self.now = now
        self.makeID = makeID
        self.failureInjector = failureInjector
        self.partialActivityProbeFailureInjector = partialActivityProbeFailureInjector
        self.publicationVerificationWillHash = publicationVerificationWillHash
        self.derivedVerificationWillHash = derivedVerificationWillHash
        self.sourceVerificationWillHash = sourceVerificationWillHash
        self.sourceVerificationDidOpen = sourceVerificationDidOpen
        self.screenProjectionWillRebuild = screenProjectionWillRebuild
    }

    public func publicationGuard() throws -> LANInboxPublicationGuard {
        try activePublicationGuard(requested: nil)
    }

    public func revokePublications(
        guardedBy guardValue: LANInboxPublicationGuard
    ) throws {
        try validatePublicationGuardIdentity(guardValue)
        publicationsRevoked = true
    }

    public func initialize() async throws -> LANInboxSnapshot {
        do {
            let lease = try await mutationCoordinator.acquire()
            defer { lease.release() }
            let root = try probeAndBind(reconcileTransactions: true, lease: lease)
            if files.exists(relativePath: layout.manifestPath) {
                return try reconcile(
                    loadValidatedSnapshot(expectedRoot: root).snapshot,
                    expectedRoot: root
                )
            }
            try validateAbsentScaffolding()
            try directories.prepare()
            let snapshot = try LANInboxSnapshot(
                vaultID: root.vaultID,
                generation: 1,
                commitID: makeID(),
                lastWriterRuntimeGeneration: runtimeGeneration
            )
            _ = try publish(snapshot, expectedRoot: root)
            return snapshot
        } catch {
            throw mapError(error)
        }
    }

    public func inspect() async -> LANInboxAccessState {
        let lease: VaultMutationLease
        do {
            lease = try await mutationCoordinator.acquire()
        } catch is CancellationError {
            return .operationInProgress
        } catch {
            return .damaged
        }
        defer { lease.release() }
        do {
            let root = try probeAndBind(reconcileTransactions: true, lease: lease)
            guard files.exists(relativePath: layout.manifestPath) else {
                try validateAbsentScaffolding()
                return .absent
            }
            return .ready(try revision(
                for: loadValidatedSnapshot(expectedRoot: root).snapshot
            ))
        } catch VaultError.unsupportedVersion {
            return .unsupportedVersion
        } catch LANInboxError.unsupportedVersion {
            return .unsupportedVersion
        } catch {
            return .damaged
        }
    }

    public func loadSnapshot() async throws -> LANInboxSnapshot {
        do {
            let lease = try await mutationCoordinator.acquire()
            defer { lease.release() }
            let root = try probeAndBind(reconcileTransactions: true, lease: lease)
            guard files.exists(relativePath: layout.manifestPath) else {
                try validateAbsentScaffolding()
                throw LANInboxError.vaultUnavailable
            }
            return try reconcile(
                loadValidatedSnapshot(expectedRoot: root).snapshot,
                expectedRoot: root
            )
        } catch {
            throw mapError(error)
        }
    }

    public func storageSummary() async throws -> LANInboxStorageSummary {
        do {
            let lease = try await mutationCoordinator.acquire()
            defer { lease.release() }
            let root = try probeAndBind(reconcileTransactions: false)
            let projection = try cachedScreenProjection(expectedRoot: root)
            let loaded = projection.loaded
            let accounting = projection.accounting
            let usage = admissionPolicy.currentUsage
            return try loaded.snapshot.storageSummary(
                pendingUploadCount: usage.activeUploadCount,
                pendingByteCount: usage.totalPendingByteCount,
                partialObjectCount: accounting.partialCount,
                partialByteCount: accounting.partialBytes,
                reclaimableOrphanObjectCount: accounting.orphanCount,
                reclaimableOrphanByteCount: accounting.orphanBytes,
                manifestByteCount: loaded.manifestByteCount,
                metadataByteCount: 0,
                cleanupDebtObjectCount: accounting.cleanupDebtCount,
                cleanupDebtByteCount: accounting.cleanupDebtBytes
            )
        } catch {
            throw mapError(error)
        }
    }

    /// Produces the Mac queue projection under one mutation lease and one
    /// physical inventory. Startup reconciliation is owned by `initialize()`;
    /// passive UI refreshes remain read-only.
    public func snapshotAndStorageSummary() async throws
        -> LANInboxSnapshotAndStorageSummary
    {
        do {
            let lease = try await mutationCoordinator.acquire()
            defer { lease.release() }
            let root = try probeAndBind(reconcileTransactions: false)
            let projection = try cachedScreenProjection(expectedRoot: root)
            let loaded = projection.loaded
            let accounting = projection.accounting
            let usage = admissionPolicy.currentUsage
            let storage = try loaded.snapshot.storageSummary(
                pendingUploadCount: usage.activeUploadCount,
                pendingByteCount: usage.totalPendingByteCount,
                partialObjectCount: accounting.partialCount,
                partialByteCount: accounting.partialBytes,
                reclaimableOrphanObjectCount: accounting.orphanCount,
                reclaimableOrphanByteCount: accounting.orphanBytes,
                manifestByteCount: loaded.manifestByteCount,
                metadataByteCount: 0,
                cleanupDebtObjectCount: accounting.cleanupDebtCount,
                cleanupDebtByteCount: accounting.cleanupDebtBytes
            )
            return LANInboxSnapshotAndStorageSummary(
                snapshot: loaded.snapshot,
                storage: storage
            )
        } catch {
            throw mapError(error)
        }
    }

    public func itemAdmissionGeneration() async throws -> UInt64 {
        do {
            let lease = try await mutationCoordinator.acquire()
            defer { lease.release() }
            let root = try probeAndBind(reconcileTransactions: false)
            return try loadValidatedSnapshot(expectedRoot: root).snapshot.generation
        } catch {
            throw mapError(error)
        }
    }

    public func startItemUpload(
        transport: LANInboxTransportIdentity,
        metadata: LANInboxTransportMetadata,
        attemptRevision: UInt64,
        admissionGeneration requestedAdmissionGeneration: UInt64? = nil,
        publicationGuard requestedPublicationGuard: LANInboxPublicationGuard? = nil
    ) async throws -> LANItemUploadStartOutcome {
        let publicationGuard = try activePublicationGuard(requested: requestedPublicationGuard)
        let permit: LANInboxAdmissionPolicy.UploadPermit
        do {
            permit = try admissionPolicy.acquireUploadPermit()
        } catch {
            throw mapError(error)
        }
        let lease: VaultMutationLease
        do {
            lease = try await mutationCoordinator.acquire()
        } catch {
            permit.release()
            throw mapError(error)
        }

        var sink: LANUploadSink?
        do {
            _ = try activePublicationGuard(requested: publicationGuard)
            let root = try probeAndBind(reconcileTransactions: false)
            let current = try loadValidatedSnapshot(expectedRoot: root).snapshot
            if let receipt = current.transportReceipt(transport: transport) {
                guard receipt.matches(transport: transport, metadata: metadata) else {
                    throw LANInboxError.receiptConflict
                }
                lease.release()
                permit.release()
                return .terminal(receipt)
            }
            if let active = activeItemUploads[transport] {
                guard active.metadata == metadata else {
                    throw LANInboxError.receiptConflict
                }
                throw LANInboxError.mutationConflict
            }
            let admissionGeneration = requestedAdmissionGeneration ?? current.generation
            guard admissionGeneration > 0,
                  admissionGeneration <= current.generation else {
                throw LANInboxError.invalidGeneration
            }
            let sessionReceiptIDs = Set(current.transportReceipts.lazy
                .filter { $0.transport.sessionID == transport.sessionID }
                .map { $0.transport.remoteFileID })
            let sessionActiveIDs = Set(activeItemUploads.keys.lazy
                .filter { $0.sessionID == transport.sessionID }
                .map(\.remoteFileID))
            guard sessionReceiptIDs.union(sessionActiveIDs).count
                < LANInboxSnapshot.maximumTransportReceiptsPerSession else {
                throw LANInboxError.resourceLimitExceeded
            }

            try directories.prepare()
            let attemptID = makeID()
            let opened = try directories.openNewPartial(
                rootPath: layout.rootURL.path,
                attemptID: attemptID
            )
            let context = opened.context
            let createdSink = try LANUploadSink(
                attemptID: attemptID,
                descriptor: opened.descriptor,
                declaredByteCount: metadata.declaredByteCount,
                uploadPermit: permit,
                cleanup: { [weak self, context] descriptor in
                    guard let self else { throw LANInboxError.storageFailure }
                    let mayUnlink = await self.interruptItemUpload(
                        transport: transport,
                        attemptID: attemptID
                    )
                    if mayUnlink { try context.cleanup(partialDescriptor: descriptor) }
                },
                publish: { [weak self, context] completed, descriptor in
                    guard let self else { throw LANInboxError.storageFailure }
                    try await self.publishCompletedItemUpload(
                        transport: transport,
                        metadata: metadata,
                        attemptRevision: attemptRevision,
                        admissionGeneration: admissionGeneration,
                        expectedPublicationGuard: publicationGuard,
                        completed: completed,
                        descriptor: descriptor,
                        context: context
                    )
                }
            )
            sink = createdSink
            activeItemUploads[transport] = LANInboxActiveItemUpload(
                metadata: metadata,
                attemptRevision: attemptRevision,
                attemptID: attemptID,
                admissionGeneration: admissionGeneration
            )
            lease.release()
            return .sink(createdSink)
        } catch {
            lease.release()
            if let sink { await sink.cancel() } else { permit.release() }
            throw mapError(error)
        }
    }

    public func recordItemUploadCancellation(
        transport: LANInboxTransportIdentity,
        metadata: LANInboxTransportMetadata,
        attemptRevision: UInt64
    ) async throws -> LANInboxTransportReceipt {
        do {
            let lease = try await mutationCoordinator.acquire()
            defer { lease.release() }
            let root = try probeAndBind(reconcileTransactions: false)
            let current = try loadValidatedSnapshot(expectedRoot: root).snapshot
            if let existing = current.transportReceipt(transport: transport) {
                guard existing.matches(transport: transport, metadata: metadata) else {
                    throw LANInboxError.receiptConflict
                }
                return existing
            }
            guard activeItemUploads[transport] == nil else {
                throw LANInboxError.mutationConflict
            }
            let receipt = try LANInboxTransportReceipt(
                id: makeID(),
                transport: transport,
                metadata: metadata,
                attemptRevision: attemptRevision,
                contentIdentity: nil,
                completedAt: now(),
                outcome: .cancelled
            )
            let desired = try nextSnapshot(
                from: current,
                transportReceipts: current.transportReceipts + [receipt]
            )
            _ = try publish(desired, expectedRoot: root)
            return receipt
        } catch {
            throw mapError(error)
        }
    }

    public func endItemSession(sessionID: UUID) async throws {
        do {
            let lease = try await mutationCoordinator.acquire()
            defer { lease.release() }
            guard !activeItemUploads.keys.contains(where: {
                $0.sessionID == sessionID
            }) else {
                throw LANInboxError.mutationConflict
            }
            let root = try probeAndBind(reconcileTransactions: false)
            let current = try loadValidatedSnapshot(expectedRoot: root).snapshot
            let receipts = current.transportReceipts.filter {
                $0.transport.sessionID != sessionID
            }
            let terminals = current.contentTerminals.filter { $0.sessionID != sessionID }
            guard receipts != current.transportReceipts
                    || terminals != current.contentTerminals else { return }
            _ = try publish(try nextSnapshot(
                from: current,
                transportReceipts: receipts,
                contentTerminals: terminals
            ), expectedRoot: root)
        } catch {
            throw mapError(error)
        }
    }

    public func deleteItem(
        itemID: LANInboxItem.ID,
        expectedRevision: UInt64,
        activeSessionID: UUID?,
        admissionGenerationCutoff: UInt64? = nil
    ) async throws -> LANInboxSnapshot {
        do {
            let lease = try await mutationCoordinator.acquire()
            defer { lease.release() }
            let root = try probeAndBind(reconcileTransactions: false)
            let current = try loadValidatedSnapshot(expectedRoot: root).snapshot
            guard let item = current.item(id: itemID) else {
                throw LANInboxError.fileNotFound
            }
            guard item.revision == expectedRevision else {
                throw LANInboxError.staleRevision
            }
            guard !current.archiveIntents.contains(where: {
                $0.orderedSources.contains { $0.itemID == itemID }
            }) else {
                throw LANInboxError.mutationConflict
            }
            let cutoff = admissionGenerationCutoff ?? current.generation
            guard cutoff >= current.generation else {
                throw LANInboxError.invalidGeneration
            }

            var terminals = current.contentTerminals
            if let activeSessionID {
                let terminal = try LANInboxContentTerminal(
                    id: terminals.first(where: {
                        $0.sessionID == activeSessionID
                            && $0.contentIdentity == item.contentIdentity
                    })?.id ?? makeID(),
                    sessionID: activeSessionID,
                    contentIdentity: item.contentIdentity,
                    createdAt: now(),
                    kind: .deleted(admissionGenerationCutoff: cutoff)
                )
                terminals.removeAll {
                    $0.sessionID == activeSessionID
                        && $0.contentIdentity == item.contentIdentity
                }
                terminals.append(terminal)
            }
            let receipts = try current.transportReceipts.compactMap { receipt in
                guard receipt.contentIdentity == item.contentIdentity else {
                    return receipt
                }
                guard let activeSessionID,
                      receipt.transport.sessionID == activeSessionID else {
                    return nil
                }
                return try LANInboxTransportReceipt(
                    id: receipt.id,
                    transport: receipt.transport,
                    metadata: receipt.metadata,
                    attemptRevision: receipt.attemptRevision,
                    contentIdentity: receipt.contentIdentity,
                    completedAt: receipt.completedAt,
                    outcome: .deleted
                )
            }
            let items = current.items.filter { $0.id != itemID }
            let desired = try nextSnapshot(
                from: current,
                items: items,
                transportReceipts: receipts,
                contentTerminals: terminals,
                blobs: blobsReachable(from: items, available: current.blobs)
            )
            _ = try publish(desired, expectedRoot: root)
            cleanupUnreferencedObjects(authoritative: desired, expectedRoot: root)
            return desired
        } catch {
            throw mapError(error)
        }
    }

    public func prepareArchive(
        _ requestedIntent: LANArchiveIntent
    ) async throws -> LANArchivePreparationOutcome {
        do {
            let lease = try await mutationCoordinator.acquire()
            defer { lease.release() }
            let root = try probeAndBind(reconcileTransactions: false)
            let current = try loadValidatedSnapshot(expectedRoot: root).snapshot
            guard requestedIntent.vaultID == current.vaultID else {
                throw LANInboxError.invalidReference
            }
            if let terminal = current.archiveTerminal(intentID: requestedIntent.id) {
                guard terminal.intent == requestedIntent else {
                    throw LANInboxError.receiptConflict
                }
                return .completed(terminal)
            }
            if let existing = current.archiveIntent(id: requestedIntent.id) {
                guard existing == requestedIntent else {
                    throw LANInboxError.receiptConflict
                }
                return .active(existing)
            }
            let itemsByID = Dictionary(uniqueKeysWithValues: current.items.map { ($0.id, $0) })
            for source in requestedIntent.orderedSources {
                guard let item = itemsByID[source.itemID],
                      item.isReviewable,
                      item.revision == source.itemRevision,
                      item.contentIdentity == source.contentIdentity else {
                    throw LANInboxError.staleRevision
                }
            }
            let requestedIDs = Set(requestedIntent.orderedSources.map(\.itemID))
            guard !current.archiveIntents.contains(where: { intent in
                !requestedIDs.isDisjoint(with: intent.orderedSources.map(\.itemID))
            }) else {
                throw LANInboxError.mutationConflict
            }
            _ = try publish(try nextSnapshot(
                from: current,
                archiveIntents: current.archiveIntents + [requestedIntent]
            ), expectedRoot: root)
            return .active(requestedIntent)
        } catch {
            throw mapError(error)
        }
    }

    public func cancelArchive(intentID: LANArchiveIntent.ID) async throws {
        do {
            let lease = try await mutationCoordinator.acquire()
            defer { lease.release() }
            let root = try probeAndBind(reconcileTransactions: false)
            let current = try loadValidatedSnapshot(expectedRoot: root).snapshot
            guard current.archiveIntent(id: intentID) != nil else {
                if current.archiveTerminal(intentID: intentID) != nil { return }
                throw LANInboxError.invalidReference
            }
            _ = try publish(try nextSnapshot(
                from: current,
                archiveIntents: current.archiveIntents.filter { $0.id != intentID }
            ), expectedRoot: root)
        } catch {
            throw mapError(error)
        }
    }

    public func recordArchiveOutcome(
        intentID: LANArchiveIntent.ID,
        outcome: LANArchiveOutcome,
        vaultRevision: VaultRevision,
        activeSessionID: UUID? = nil
    ) async throws -> LANArchiveTerminal {
        do {
            let lease = try await mutationCoordinator.acquire()
            defer { lease.release() }
            let root = try probeAndBind(reconcileTransactions: false)
            let current = try loadValidatedSnapshot(expectedRoot: root).snapshot
            if let terminal = current.archiveTerminal(intentID: intentID) {
                guard terminal.receipt.outcome == outcome else {
                    throw LANInboxError.receiptConflict
                }
                return terminal
            }
            guard let intent = current.archiveIntent(id: intentID) else {
                throw LANInboxError.mutationConflict
            }

            let authoritative = try loadAuthoritativeCatalog(expectedRoot: root)
            let observedRevision = try VaultRevision(
                generation: authoritative.catalog.generation,
                commitID: authoritative.manifest.commitID,
                catalogDigest: authoritative.manifest.catalogSHA256
            )
            guard observedRevision == vaultRevision else {
                throw LANInboxError.staleRevision
            }
            switch outcome {
            case let .accepted(draftID):
                guard draftID == intent.draftID,
                      let draft = authoritative.catalog.importDrafts.first(where: {
                          $0.id == draftID
                      }),
                      draft.state == .needsReview,
                      draft.memberID == intent.memberID,
                      (try ReportFingerprint(
                          sources: draft.sources,
                          attachments: authoritative.catalog.attachments
                      )) == intent.fingerprint else {
                    throw LANInboxError.invalidReference
                }
            case let .duplicateSkipped(candidate):
                guard let duplicate = DuplicateDetector.find(
                    fingerprint: intent.fingerprint,
                    attachments: authoritative.catalog.attachments,
                    records: authoritative.catalog.records,
                    drafts: authoritative.catalog.importDrafts
                ) else {
                    throw LANInboxError.invalidReference
                }
                let observed = switch duplicate {
                case let .record(id): LANReportDuplicateDestination(kind: .healthRecord, id: id)
                case let .draft(id): LANReportDuplicateDestination(kind: .importDraft, id: id)
                }
                guard candidate == observed else {
                    throw LANInboxError.invalidReference
                }
            }

            let resolvedItemIDs = Set(intent.orderedSources.map(\.itemID))
            let resolvedIdentities = Set(intent.orderedSources.map(\.contentIdentity))
            let currentItemsByID = Dictionary(uniqueKeysWithValues: current.items.map {
                ($0.id, $0)
            })
            for source in intent.orderedSources {
                guard let item = currentItemsByID[source.itemID],
                      item.revision == source.itemRevision,
                      item.contentIdentity == source.contentIdentity else {
                    throw LANInboxError.staleRevision
                }
            }

            var archiveTerminals = current.archiveTerminals
            let receipt = try LANArchiveReceipt(
                id: makeID(),
                intentID: intent.id,
                completedAt: now(),
                vaultRevision: vaultRevision,
                outcome: outcome
            )
            archiveTerminals.append(try LANArchiveTerminal(
                intent: intent,
                receipt: receipt
            ))

            var sessions = Set<UUID>(current.transportReceipts.compactMap { receipt in
                guard let identity = receipt.contentIdentity,
                      resolvedIdentities.contains(identity) else { return nil }
                return receipt.transport.sessionID
            })
            if let activeSessionID { sessions.insert(activeSessionID) }
            var contentTerminals = current.contentTerminals.filter { terminal in
                !(sessions.contains(terminal.sessionID)
                    && resolvedIdentities.contains(terminal.contentIdentity))
            }
            for sessionID in sessions {
                for identity in resolvedIdentities {
                    contentTerminals.append(try LANInboxContentTerminal(
                        id: makeID(),
                        sessionID: sessionID,
                        contentIdentity: identity,
                        createdAt: now(),
                        kind: .archived
                    ))
                }
            }
            let receipts = try current.transportReceipts.map { receipt in
                guard let identity = receipt.contentIdentity,
                      resolvedIdentities.contains(identity) else { return receipt }
                return try LANInboxTransportReceipt(
                    id: receipt.id,
                    transport: receipt.transport,
                    metadata: receipt.metadata,
                    attemptRevision: receipt.attemptRevision,
                    contentIdentity: identity,
                    completedAt: receipt.completedAt,
                    outcome: .archived
                )
            }
            let items = current.items.filter { !resolvedItemIDs.contains($0.id) }
            let intents = current.archiveIntents.filter { $0.id != intent.id }
            let desired = try nextSnapshot(
                from: current,
                items: items,
                transportReceipts: receipts,
                contentTerminals: contentTerminals,
                archiveIntents: intents,
                archiveTerminals: archiveTerminals,
                blobs: blobsReachable(from: items, available: current.blobs)
            )
            _ = try publish(desired, expectedRoot: root)
            cleanupUnreferencedObjects(authoritative: desired, expectedRoot: root)
            guard let terminal = desired.archiveTerminal(intentID: intentID) else {
                throw LANInboxError.invalidReference
            }
            return terminal
        } catch {
            throw mapError(error)
        }
    }

    func acknowledgeArchiveTerminals(
        _ completed: [LANArchiveTerminal]
    ) async throws {
        guard !completed.isEmpty else { return }
        do {
            let acknowledgements = Set(completed.map {
                LANArchiveTerminalAcknowledgement(
                    intentID: $0.intent.id,
                    receiptID: $0.receipt.id
                )
            })
            let lease = try await mutationCoordinator.acquire()
            defer { lease.release() }
            let root = try probeAndBind(reconcileTransactions: false)
            let current = try loadValidatedSnapshot(expectedRoot: root).snapshot
            let retained = current.archiveTerminals.filter {
                !acknowledgements.contains(LANArchiveTerminalAcknowledgement(
                    intentID: $0.intent.id,
                    receiptID: $0.receipt.id
                ))
            }
            guard retained.count != current.archiveTerminals.count else { return }
            _ = try publish(try nextSnapshot(
                from: current,
                archiveTerminals: retained
            ), expectedRoot: root)
        } catch {
            throw mapError(error)
        }
    }

    func withVerifiedItemSourceContent<Result: Sendable>(
        itemID: LANInboxItem.ID,
        _ body: @escaping @Sendable (Int32) throws -> Result
    ) async throws -> Result {
        do {
            let publicationGuard = try activePublicationGuard(requested: nil)
            let evidence: LANInboxItemSourceVerificationEvidence
            let initialLease = try await mutationCoordinator.acquire()
            do {
                _ = try activePublicationGuard(requested: publicationGuard)
                let root = try probeAndBind(reconcileTransactions: false)
                let current = try loadValidatedSnapshot(expectedRoot: root).snapshot
                guard let item = current.item(id: itemID),
                      let blob = current.blobs.first(where: { $0.id == item.blobID }) else {
                    throw LANInboxError.fileNotFound
                }
                let opened = try openContentReferences(
                    [contentReference(for: blob)],
                    expectedRoot: root
                )
                guard let content = opened.first, opened.count == 1 else {
                    closeOpenedContent(opened)
                    throw LANInboxError.invalidReference
                }
                evidence = LANInboxItemSourceVerificationEvidence(
                    root: root,
                    item: item,
                    blob: blob,
                    openedContent: content
                )
                initialLease.release()
                sourceVerificationDidOpen?()
            } catch {
                initialLease.release()
                throw error
            }
            defer { closeOpenedContent([evidence.openedContent]) }
            do {
                try await LANInboxIntegrityIO.verify(
                    [evidence.openedContent],
                    willHash: sourceVerificationWillHash
                )
            } catch {
                if isNamedObjectIntegrityFailure(error) {
                    _ = try await persistItemIntegrityFailureIfCurrent(
                        evidence,
                        publicationGuard: publicationGuard
                    )
                    throw LANInboxError.integrityCheckFailed
                }
                throw error
            }
            let finalLease = try await mutationCoordinator.acquire()
            do {
                _ = try activePublicationGuard(requested: publicationGuard)
                let root = try probeAndBind(reconcileTransactions: false)
                guard root == evidence.root else { throw LANInboxError.vaultUnavailable }
                let current = try loadValidatedSnapshot(expectedRoot: root).snapshot
                guard current.item(id: itemID) == evidence.item,
                      current.blobs.first(where: { $0.id == evidence.blob.id })
                        == evidence.blob else {
                    throw LANInboxError.staleRevision
                }
                try validateOpenedContentStillNamed(
                    [evidence.openedContent],
                    expectedRoot: root
                )
                finalLease.release()
            } catch {
                finalLease.release()
                throw error
            }
            return try await LANInboxIntegrityIO.consume(
                descriptor: evidence.openedContent.descriptor,
                body: body
            )
        } catch {
            throw mapError(error)
        }
    }

    public func beginItemDerivedArtifact(
        itemID: LANInboxItem.ID,
        expectedRevision: UInt64,
        publicationGuard requestedPublicationGuard: LANInboxPublicationGuard? = nil
    ) async throws -> LANDerivedArtifactSink {
        let publicationGuard = try activePublicationGuard(requested: requestedPublicationGuard)
        _ = try await withVerifiedItemSourceContent(itemID: itemID) { _ in () }
        let lease = try await mutationCoordinator.acquire()
        var sink: LANDerivedArtifactSink?
        do {
            _ = try activePublicationGuard(requested: publicationGuard)
            let root = try probeAndBind(reconcileTransactions: false)
            let current = try loadValidatedSnapshot(expectedRoot: root).snapshot
            guard let index = current.items.firstIndex(where: { $0.id == itemID }) else {
                throw LANInboxError.fileNotFound
            }
            let item = current.items[index]
            guard item.revision == expectedRevision else {
                throw LANInboxError.staleRevision
            }
            switch item.state {
            case .stored, .failed, .reviewable, .unsupported:
                break
            case .preprocessing, .integrityFailed:
                throw LANInboxError.invalidState
            }
            try directories.prepare()
            let attemptID = makeID()
            let opened = try directories.openNewPartial(
                rootPath: layout.rootURL.path,
                attemptID: attemptID
            )
            let context = opened.context
            let processing = try item.transitioning(
                to: .preprocessing(blobID: item.blobID, attemptID: attemptID),
                expectedRevision: item.revision,
                expectedAttemptID: item.attemptID
            )
            let pendingWriteOwner = derivedWriteAdmission.acquireOwner()
            let createdSink = try LANDerivedArtifactSink(
                attemptID: attemptID,
                descriptor: opened.descriptor,
                abort: { [weak self, context] descriptor in
                    guard let self else { throw LANInboxError.storageFailure }
                    let mayUnlink = try await self.failItemDerivedArtifact(
                        itemID: itemID,
                        attemptID: attemptID,
                        blobID: item.blobID
                    )
                    if mayUnlink { try context.cleanup(partialDescriptor: descriptor) }
                },
                finalize: { [weak self, context] completed, descriptor in
                    guard let self else { throw LANInboxError.storageFailure }
                    try await self.publishCompletedItemDerivedArtifact(
                        itemID: itemID,
                        blobID: item.blobID,
                        expectedRevision: processing.revision,
                        expectedPublicationGuard: publicationGuard,
                        completed: completed,
                        descriptor: descriptor,
                        context: context
                    )
                },
                pendingWriteOwner: pendingWriteOwner
            )
            sink = createdSink
            var items = current.items
            items[index] = processing
            let desired = try nextSnapshot(from: current, items: items)
            _ = try publish(desired, expectedRoot: root)
            cleanupUnreferencedObjects(authoritative: desired, expectedRoot: root)
            lease.release()
            return createdSink
        } catch {
            lease.release()
            if let sink { await sink.abort() }
            throw mapError(error)
        }
    }

    @discardableResult
    public func markItemPreprocessingIssue(
        itemID: LANInboxItem.ID,
        expectedRevision: UInt64,
        issue: LANInboxFileIssue
    ) async throws -> LANInboxItem {
        guard issue == .unsupportedContent || issue == .preprocessingFailed else {
            throw LANInboxError.invalidState
        }
        do {
            let lease = try await mutationCoordinator.acquire()
            defer { lease.release() }
            let root = try probeAndBind(reconcileTransactions: false)
            let current = try loadValidatedSnapshot(expectedRoot: root).snapshot
            guard let index = current.items.firstIndex(where: { $0.id == itemID }) else {
                throw LANInboxError.fileNotFound
            }
            let item = current.items[index]
            guard item.revision == expectedRevision else {
                throw LANInboxError.staleRevision
            }
            if item.issue == issue { return item }
            let destination: LANInboxItemState = issue == .unsupportedContent
                ? .unsupported(blobID: item.blobID, issue: issue)
                : .failed(blobID: item.blobID, issue: issue)
            let updated = try item.transitioning(
                to: destination,
                expectedRevision: item.revision,
                expectedAttemptID: item.attemptID
            )
            var items = current.items
            items[index] = updated
            let desired = try nextSnapshot(from: current, items: items)
            _ = try publish(desired, expectedRoot: root)
            cleanupUnreferencedObjects(authoritative: desired, expectedRoot: root)
            return updated
        } catch {
            throw mapError(error)
        }
    }

    func withVerifiedItemDerivedContent<Result: Sendable>(
        itemID: LANInboxItem.ID,
        _ body: @escaping @Sendable (Int32) throws -> Result
    ) async throws -> Result {
        do {
            let publicationGuard = try activePublicationGuard(requested: nil)
            let evidence: LANInboxItemDerivedVerificationEvidence
            let initialLease = try await mutationCoordinator.acquire()
            do {
                _ = try activePublicationGuard(requested: publicationGuard)
                let root = try probeAndBind(reconcileTransactions: false)
                let current = try loadValidatedSnapshot(expectedRoot: root).snapshot
                guard let item = current.item(id: itemID),
                      let artifact = item.derivedArtifact else {
                    throw LANInboxError.invalidReference
                }
                let opened = try openContentReferences(
                    [contentReference(for: artifact)],
                    expectedRoot: root
                )
                guard let content = opened.first, opened.count == 1 else {
                    closeOpenedContent(opened)
                    throw LANInboxError.invalidReference
                }
                evidence = LANInboxItemDerivedVerificationEvidence(
                    root: root,
                    item: item,
                    artifact: artifact,
                    openedContent: content
                )
                initialLease.release()
            } catch {
                initialLease.release()
                throw error
            }
            defer { closeOpenedContent([evidence.openedContent]) }
            do {
                try await LANInboxIntegrityIO.verify(
                    [evidence.openedContent],
                    willHash: derivedVerificationWillHash
                )
            } catch {
                if isNamedObjectIntegrityFailure(error) {
                    _ = try await persistItemDerivedIntegrityFailureIfCurrent(
                        evidence,
                        publicationGuard: publicationGuard
                    )
                    throw LANInboxError.integrityCheckFailed
                }
                throw error
            }
            let finalLease = try await mutationCoordinator.acquire()
            do {
                _ = try activePublicationGuard(requested: publicationGuard)
                let root = try probeAndBind(reconcileTransactions: false)
                guard root == evidence.root else { throw LANInboxError.vaultUnavailable }
                let current = try loadValidatedSnapshot(expectedRoot: root).snapshot
                guard current.item(id: itemID) == evidence.item else {
                    throw LANInboxError.staleRevision
                }
                try validateOpenedContentStillNamed(
                    [evidence.openedContent],
                    expectedRoot: root
                )
                finalLease.release()
            } catch {
                finalLease.release()
                throw error
            }
            return try await LANInboxIntegrityIO.consume(
                descriptor: evidence.openedContent.descriptor,
                body: body
            )
        } catch {
            throw mapError(error)
        }
    }

    private func interruptItemUpload(
        transport: LANInboxTransportIdentity,
        attemptID: UUID
    ) -> Bool {
        guard activeItemUploads[transport]?.attemptID == attemptID else { return false }
        activeItemUploads.removeValue(forKey: transport)
        return true
    }

    private func publishCompletedItemUpload(
        transport: LANInboxTransportIdentity,
        metadata: LANInboxTransportMetadata,
        attemptRevision: UInt64,
        admissionGeneration: UInt64,
        expectedPublicationGuard: LANInboxPublicationGuard,
        completed: LANUploadSink.CompletedUpload,
        descriptor: Int32,
        context: LANInboxPartialContext
    ) async throws {
        do {
            try await LANInboxIntegrityIO.verify(
                descriptor: descriptor,
                expectedByteCount: completed.byteCount,
                expectedSHA256: completed.sha256Digest,
                willHash: publicationVerificationWillHash
            )
            var reusableEvidence = try await verifiedReusableBlob(
                sha256Digest: completed.sha256Digest,
                byteCount: completed.byteCount
            )
            defer { if let reusableEvidence { Darwin.close(reusableEvidence.descriptor) } }

            while true {
                let lease = try await mutationCoordinator.acquire()
                do {
                    _ = try activePublicationGuard(requested: expectedPublicationGuard)
                    let root = try probeAndBind(reconcileTransactions: false)
                    let current = try loadValidatedSnapshot(expectedRoot: root).snapshot
                    if let existing = current.transportReceipt(transport: transport) {
                        guard existing.matches(transport: transport, metadata: metadata) else {
                            throw LANInboxError.receiptConflict
                        }
                        activeItemUploads.removeValue(forKey: transport)
                        lease.release()
                        try context.cleanup(partialDescriptor: descriptor)
                        return
                    }
                    guard let active = activeItemUploads[transport],
                          active.metadata == metadata,
                          active.attemptRevision == attemptRevision,
                          active.attemptID == completed.attemptID,
                          active.admissionGeneration == admissionGeneration else {
                        throw LANInboxError.staleRevision
                    }

                    let identity = try LANInboxContentIdentity(
                        sha256Digest: completed.sha256Digest,
                        byteCount: completed.byteCount
                    )
                    let canonicalItem = current.item(contentIdentity: identity)
                    let terminal = canonicalItem == nil ? current.contentTerminal(
                        sessionID: transport.sessionID,
                        contentIdentity: identity,
                        admissionGeneration: admissionGeneration
                    ) : nil
                    let reusableBlob = current.blobs.first {
                        $0.sha256Digest == identity.sha256Digest
                            && $0.byteCount == identity.byteCount
                    }
                    if let reusableBlob, terminal == nil {
                        let reference = contentReference(for: reusableBlob)
                        guard let evidence = reusableEvidence,
                              evidence.reference == reference else {
                            lease.release()
                            if let reusableEvidence { Darwin.close(reusableEvidence.descriptor) }
                            reusableEvidence = nil
                            reusableEvidence = try await verifiedReusableBlob(
                                sha256Digest: identity.sha256Digest,
                                byteCount: identity.byteCount
                            )
                            continue
                        }
                        try validateOpenedContentStillNamed([evidence], expectedRoot: root)
                    }

                    var items = current.items
                    var blobs = current.blobs
                    let outcome: LANInboxTransportOutcome
                    var publishedNewBlob = false
                    if let canonicalItem {
                        outcome = .merged(itemID: canonicalItem.id)
                    } else if let terminal {
                        outcome = switch terminal.kind {
                        case .archived: .archived
                        case .deleted: .deleted
                        }
                    } else {
                        guard current.items.count < LANInboxSnapshot.maximumItemCount else {
                            throw LANInboxError.resourceLimitExceeded
                        }
                        let blob: LANInboxBlob
                        if let reusableBlob {
                            blob = reusableBlob
                        } else {
                            try failIfRequested(.beforeBlobPublish)
                            blob = try LANInboxBlob(
                                id: makeID(),
                                sha256Digest: identity.sha256Digest,
                                byteCount: identity.byteCount
                            )
                            try context.publish(partialDescriptor: descriptor, blobID: blob.id)
                            blobs.append(blob)
                            publishedNewBlob = true
                            try failIfRequested(.afterBlobPublish)
                        }
                        let sequence: UInt64
                        if let maximum = current.items.map(\.sequence).max() {
                            let next = maximum.addingReportingOverflow(1)
                            guard !next.overflow else { throw LANInboxError.invalidRevision }
                            sequence = next.partialValue
                        } else {
                            sequence = 0
                        }
                        let item = try LANInboxItem(
                            id: makeID(),
                            originatingSessionID: transport.sessionID,
                            displayName: metadata.displayName,
                            receivedAt: now(),
                            sequence: sequence,
                            contentIdentity: identity,
                            state: .stored(blobID: blob.id)
                        )
                        items.append(item)
                        outcome = .published(itemID: item.id)
                    }
                    let receipt = try LANInboxTransportReceipt(
                        id: makeID(),
                        transport: transport,
                        metadata: metadata,
                        attemptRevision: attemptRevision,
                        contentIdentity: identity,
                        completedAt: now(),
                        outcome: outcome
                    )
                    let desired = try nextSnapshot(
                        from: current,
                        items: items,
                        transportReceipts: current.transportReceipts + [receipt],
                        blobs: blobs
                    )
                    _ = try publish(desired, expectedRoot: root)
                    activeItemUploads.removeValue(forKey: transport)
                    lease.release()
                    if publishedNewBlob {
                        context.releaseRegistry()
                    } else {
                        try context.cleanup(partialDescriptor: descriptor)
                    }
                    return
                } catch {
                    lease.release()
                    throw error
                }
            }
        } catch {
            throw mapError(error)
        }
    }

    private func persistItemIntegrityFailureIfCurrent(
        _ evidence: LANInboxItemSourceVerificationEvidence,
        publicationGuard: LANInboxPublicationGuard
    ) async throws -> Bool {
        let lease = try await mutationCoordinator.acquire()
        defer { lease.release() }
        _ = try activePublicationGuard(requested: publicationGuard)
        let root = try probeAndBind(reconcileTransactions: false)
        guard root == evidence.root else { return false }
        let current = try loadValidatedSnapshot(expectedRoot: root).snapshot
        guard let index = current.items.firstIndex(where: {
            $0.id == evidence.item.id && $0 == evidence.item
        }), current.blobs.first(where: { $0.id == evidence.blob.id }) == evidence.blob else {
            return false
        }
        let item = current.items[index]
        let updated = try item.transitioning(
            to: .integrityFailed(blobID: item.blobID, issue: .integrityMismatch),
            expectedRevision: item.revision,
            expectedAttemptID: item.attemptID
        )
        var items = current.items
        items[index] = updated
        let desired = try nextSnapshot(from: current, items: items)
        _ = try publish(desired, expectedRoot: root)
        return true
    }

    private func persistItemDerivedIntegrityFailureIfCurrent(
        _ evidence: LANInboxItemDerivedVerificationEvidence,
        publicationGuard: LANInboxPublicationGuard
    ) async throws -> Bool {
        let lease = try await mutationCoordinator.acquire()
        defer { lease.release() }
        _ = try activePublicationGuard(requested: publicationGuard)
        let root = try probeAndBind(reconcileTransactions: false)
        guard root == evidence.root else { return false }
        let current = try loadValidatedSnapshot(expectedRoot: root).snapshot
        guard let index = current.items.firstIndex(where: {
            $0.id == evidence.item.id && $0 == evidence.item
        }), current.items[index].derivedArtifact == evidence.artifact else {
            return false
        }
        let item = current.items[index]
        let updated = try item.transitioning(
            to: .integrityFailed(blobID: item.blobID, issue: .integrityMismatch),
            expectedRevision: item.revision,
            expectedAttemptID: item.attemptID
        )
        var items = current.items
        items[index] = updated
        let desired = try nextSnapshot(from: current, items: items)
        _ = try publish(desired, expectedRoot: root)
        cleanupUnreferencedObjects(authoritative: desired, expectedRoot: root)
        return true
    }

    private func publishCompletedItemDerivedArtifact(
        itemID: LANInboxItem.ID,
        blobID: LANInboxBlob.ID,
        expectedRevision: UInt64,
        expectedPublicationGuard: LANInboxPublicationGuard,
        completed: LANDerivedArtifactSink.CompletedArtifact,
        descriptor: Int32,
        context: LANInboxPartialContext
    ) async throws {
        do {
            try await LANInboxIntegrityIO.verify(
                descriptor: descriptor,
                expectedByteCount: completed.byteCount,
                expectedSHA256: completed.sha256Digest,
                willHash: derivedVerificationWillHash
            )
            let lease = try await mutationCoordinator.acquire()
            do {
                _ = try activePublicationGuard(requested: expectedPublicationGuard)
                let root = try probeAndBind(reconcileTransactions: false)
                let current = try loadValidatedSnapshot(expectedRoot: root).snapshot
                guard let index = current.items.firstIndex(where: { $0.id == itemID }) else {
                    throw LANInboxError.fileNotFound
                }
                let item = current.items[index]
                guard item.revision == expectedRevision,
                      case let .preprocessing(currentBlobID, attemptID) = item.state,
                      currentBlobID == blobID,
                      attemptID == completed.attemptID else {
                    throw LANInboxError.staleRevision
                }
                let artifact = try LANInboxDerivedArtifact(
                    id: makeID(),
                    sha256Digest: completed.sha256Digest,
                    byteCount: completed.byteCount
                )
                try failIfRequested(.beforeDerivedPublish)
                try context.publishDerived(
                    partialDescriptor: descriptor,
                    artifactID: artifact.id
                )
                try failIfRequested(.afterDerivedPublish)
                let updated = try item.transitioning(
                    to: .reviewable(blobID: blobID, derived: artifact),
                    expectedRevision: item.revision,
                    expectedAttemptID: completed.attemptID
                )
                var items = current.items
                items[index] = updated
                let desired = try nextSnapshot(from: current, items: items)
                _ = try activePublicationGuard(requested: expectedPublicationGuard)
                _ = try publish(desired, expectedRoot: root)
                cleanupUnreferencedObjects(authoritative: desired, expectedRoot: root)
                lease.release()
                context.releaseRegistry()
            } catch {
                lease.release()
                throw error
            }
        } catch {
            throw mapError(error)
        }
    }

    private func failItemDerivedArtifact(
        itemID: LANInboxItem.ID,
        attemptID: UUID,
        blobID: LANInboxBlob.ID
    ) async throws -> Bool {
        do {
            let lease = try await mutationCoordinator.acquire()
            defer { lease.release() }
            let root = try probeAndBind(reconcileTransactions: false)
            let current = try loadValidatedSnapshot(expectedRoot: root).snapshot
            guard let index = current.items.firstIndex(where: { $0.id == itemID }),
                  case let .preprocessing(currentBlobID, currentAttemptID)
                    = current.items[index].state,
                  currentBlobID == blobID,
                  currentAttemptID == attemptID else {
                return !current.items.contains { $0.attemptID == attemptID }
            }
            let item = current.items[index]
            let updated = try item.transitioning(
                to: .failed(blobID: blobID, issue: .preprocessingFailed),
                expectedRevision: item.revision,
                expectedAttemptID: attemptID
            )
            var items = current.items
            items[index] = updated
            let desired = try nextSnapshot(from: current, items: items)
            _ = try publish(desired, expectedRoot: root)
            cleanupUnreferencedObjects(authoritative: desired, expectedRoot: root)
            return true
        } catch {
            throw mapError(error)
        }
    }

    private func blobsReachable(
        from items: [LANInboxItem],
        available: [LANInboxBlob]
    ) -> [LANInboxBlob] {
        let ids = Set(items.map(\.blobID))
        return available.filter { ids.contains($0.id) }
    }

    private func contentReference(for blob: LANInboxBlob) -> LANInboxContentReference {
        LANInboxContentReference(
            relativePath: layout.blobPath(blob.id),
            sha256Digest: blob.sha256Digest,
            byteCount: blob.byteCount
        )
    }

    private func contentReference(
        for artifact: LANInboxDerivedArtifact
    ) -> LANInboxContentReference {
        LANInboxContentReference(
            relativePath: layout.derivedPath(artifact.id),
            sha256Digest: artifact.sha256Digest,
            byteCount: artifact.byteCount
        )
    }

    private func sortedContentReferences(
        _ references: [LANInboxContentReference]
    ) -> [LANInboxContentReference] {
        references.sorted {
            if $0.relativePath != $1.relativePath { return $0.relativePath < $1.relativePath }
            if $0.byteCount != $1.byteCount { return $0.byteCount < $1.byteCount }
            return $0.sha256Digest.lexicographicallyPrecedes($1.sha256Digest)
        }
    }

    private func openContentReferences(
        _ references: [LANInboxContentReference],
        expectedRoot: VaultRootGeneration
    ) throws -> [LANInboxOpenedContent] {
        guard rootBinding.matches(expectedRoot) else {
            throw LANInboxError.vaultUnavailable
        }
        let uniqueReferences = sortedContentReferences(Array(Set(references)))
        var opened: [LANInboxOpenedContent] = []
        do {
            for reference in uniqueReferences {
                let descriptor = Darwin.open(
                    layout.rootURL.appendingPathComponent(reference.relativePath).path,
                    O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                )
                guard descriptor >= 0 else {
                    if errno == ENOENT { throw VaultError.objectMissing }
                    throw VaultError.ioFailure(errno)
                }
                do {
                    let identity = try regularFileIdentity(descriptor)
                    guard identity.byteCount == reference.byteCount else {
                        throw VaultError.integrityCheckFailed
                    }
                    opened.append(LANInboxOpenedContent(
                        reference: reference,
                        descriptor: descriptor,
                        identity: identity
                    ))
                } catch {
                    Darwin.close(descriptor)
                    throw error
                }
            }
            guard rootBinding.matches(expectedRoot) else {
                throw LANInboxError.vaultUnavailable
            }
            return opened
        } catch {
            closeOpenedContent(opened)
            throw error
        }
    }

    private func validateOpenedContentStillNamed(
        _ opened: [LANInboxOpenedContent],
        expectedRoot: VaultRootGeneration
    ) throws {
        guard rootBinding.matches(expectedRoot) else {
            throw LANInboxError.vaultUnavailable
        }
        for content in opened {
            guard try regularFileIdentity(content.descriptor) == content.identity else {
                throw VaultError.integrityCheckFailed
            }
            let descriptor = Darwin.open(
                layout.rootURL.appendingPathComponent(content.reference.relativePath).path,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
            guard descriptor >= 0 else {
                if errno == ENOENT { throw VaultError.objectMissing }
                throw VaultError.ioFailure(errno)
            }
            do {
                guard try regularFileIdentity(descriptor) == content.identity else {
                    throw VaultError.integrityCheckFailed
                }
                Darwin.close(descriptor)
            } catch {
                Darwin.close(descriptor)
                throw error
            }
        }
        guard rootBinding.matches(expectedRoot) else {
            throw LANInboxError.vaultUnavailable
        }
    }

    private func closeOpenedContent(_ opened: [LANInboxOpenedContent]) {
        for content in opened { Darwin.close(content.descriptor) }
    }

    private func verifiedReusableBlob(
        sha256Digest: Data,
        byteCount: Int
    ) async throws -> LANInboxOpenedContent? {
        let lease = try await mutationCoordinator.acquire()
        let opened: [LANInboxOpenedContent]
        do {
            let root = try probeAndBind(reconcileTransactions: false)
            let current = try loadValidatedSnapshot(expectedRoot: root).snapshot
            guard let blob = current.blobs.first(where: {
                $0.sha256Digest == sha256Digest && $0.byteCount == byteCount
            }) else {
                lease.release()
                return nil
            }
            opened = try openContentReferences(
                [contentReference(for: blob)],
                expectedRoot: root
            )
            lease.release()
        } catch {
            lease.release()
            throw error
        }
        guard let content = opened.first, opened.count == 1 else {
            closeOpenedContent(opened)
            throw LANInboxError.invalidReference
        }
        do {
            try await LANInboxIntegrityIO.verify([content])
            return content
        } catch {
            closeOpenedContent([content])
            throw error
        }
    }

    private func loadAuthoritativeCatalog(
        expectedRoot: VaultRootGeneration
    ) throws -> (manifest: PlaintextVaultManifest, catalog: VaultCatalog) {
        guard rootBinding.matches(expectedRoot) else {
            throw LANInboxError.vaultUnavailable
        }
        let data = try files.read(
            relativePath: "library.json",
            maximumByteCount: PlaintextVaultResourcePolicy.maximumManifestByteCount
        )
        let manifest: PlaintextVaultManifest
        do {
            manifest = try CanonicalVaultJSON.decode(
                PlaintextVaultManifest.self,
                from: data
            )
        } catch {
            throw VaultError.invalidCatalog
        }
        let catalog = try PlaintextVault.validatedCatalog(in: manifest)
        guard catalog.vaultID == expectedRoot.vaultID,
              manifest.objects.count <= PlaintextVaultResourcePolicy.maximumObjectCount,
              manifest.objects == manifest.objects.sorted(by: PlaintextVault.metadataPrecedes),
              Set(manifest.objects.map(\.reference)).count == manifest.objects.count,
              Set(manifest.objects.map(\.reference))
                == Set(catalog.reachableObjectReferences) else {
            throw VaultError.invalidCatalog
        }
        let attachmentsByID = Dictionary(
            uniqueKeysWithValues: catalog.attachments.map { ($0.id, $0) }
        )
        let vaultLayout = try PlaintextVaultLayout(rootURL: layout.rootURL)
        for metadata in manifest.objects {
            guard metadata.byteCount >= 0,
                  metadata.byteCount <= PlaintextVaultResourcePolicy.maximumByteCount(
                    for: metadata.reference.kind
                  ),
                  metadata.sha256Digest.count == SHA256.byteCount else {
                throw VaultError.invalidCatalog
            }
            if metadata.reference.kind == .attachment {
                guard let attachment = attachmentsByID[metadata.reference.id],
                      attachment.byteCount == metadata.byteCount,
                      attachment.sha256Digest == metadata.sha256Digest else {
                    throw VaultError.invalidCatalog
                }
            }
            let descriptor = Darwin.open(
                layout.rootURL
                    .appendingPathComponent(vaultLayout.objectPath(metadata.reference))
                    .path,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
            guard descriptor >= 0 else {
                if errno == ENOENT { throw VaultError.objectMissing }
                throw VaultError.ioFailure(errno)
            }
            let identity: LANInboxRegularFileIdentity
            do {
                identity = try regularFileIdentity(descriptor)
            } catch {
                Darwin.close(descriptor)
                throw error
            }
            Darwin.close(descriptor)
            guard identity.byteCount == metadata.byteCount else {
                throw VaultError.integrityCheckFailed
            }
        }
        guard rootBinding.matches(expectedRoot) else {
            throw LANInboxError.vaultUnavailable
        }
        return (manifest, catalog)
    }

    private struct LoadedSnapshot {
        let snapshot: LANInboxSnapshot
        let manifestByteCount: Int
    }

    private struct InventoryObject {
        let id: UUID
        let path: String
        let byteCount: Int
    }

    private struct Inventory {
        let manifestByteCount: Int
        let blobs: [InventoryObject]
        let partials: [InventoryObject]
        let derived: [InventoryObject]
        let atomicTemporaryPaths: [String]
    }

    private struct PhysicalAccounting {
        let partialCount: Int
        let partialBytes: Int
        let orphanCount: Int
        let orphanBytes: Int
        let cleanupDebtCount: Int
        let cleanupDebtBytes: Int
    }

    private struct ScreenProjectionCache {
        let root: VaultRootGeneration
        let manifestIdentity: LANInboxRegularFileIdentity
        let physicalIdentity: PhysicalProjectionIdentity
        let loaded: LoadedSnapshot
        let accounting: PhysicalAccounting
    }

    private struct DirectoryMutationIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        let statusChangeSeconds: Int64
        let statusChangeNanoseconds: Int64
    }

    private struct PartialMutationIdentity: Equatable {
        let id: UUID
        let file: LANInboxRegularFileIdentity
    }

    private struct PhysicalProjectionIdentity: Equatable {
        let inboxDirectory: DirectoryMutationIdentity
        let blobDirectory: DirectoryMutationIdentity
        let partialDirectory: DirectoryMutationIdentity
        let derivedDirectory: DirectoryMutationIdentity
        let partials: [PartialMutationIdentity]
    }

    private func probeAndBind(
        reconcileTransactions: Bool,
        lease: VaultMutationLease? = nil
    ) throws -> VaultRootGeneration {
        let current: VaultRootGeneration
        if reconcileTransactions {
            guard let lease else { throw LANInboxError.invalidState }
            current = try rootBinding.probe(reconcilingTransactionsWith: lease)
        } else {
            current = try rootBinding.probe()
        }
        if let boundRootGeneration, boundRootGeneration != current {
            throw LANInboxError.vaultUnavailable
        }
        if boundRootGeneration == nil { boundRootGeneration = current }
        return current
    }

    private func loadValidatedSnapshot(
        expectedRoot: VaultRootGeneration
    ) throws -> LoadedSnapshot {
        guard rootBinding.matches(expectedRoot) else {
            throw LANInboxError.vaultUnavailable
        }
        let data = try files.read(
            relativePath: layout.manifestPath,
            maximumByteCount: LANInboxManifestCodec.maximumByteCount
        )
        let snapshot = try LANInboxManifestCodec.decode(LANInboxSnapshot.self, from: data)
        guard snapshot.vaultID == expectedRoot.vaultID else {
            throw LANInboxError.vaultIDMismatch
        }
        let inventory = try exactInventory()
        guard inventory.manifestByteCount == data.count else {
            throw VaultError.invalidDigest
        }
        try validateReferencedObjects(in: snapshot)
        return LoadedSnapshot(snapshot: snapshot, manifestByteCount: data.count)
    }

    private func cachedScreenProjection(
        expectedRoot: VaultRootGeneration
    ) throws -> ScreenProjectionCache {
        let manifestIdentity = try currentManifestIdentity()
        let physicalIdentity = try currentPhysicalProjectionIdentity()
        if let cached = screenProjectionCache,
           cached.root == expectedRoot,
           cached.manifestIdentity == manifestIdentity,
           cached.physicalIdentity == physicalIdentity {
            return cached
        }
        screenProjectionWillRebuild?()
        let loaded = try loadValidatedSnapshot(expectedRoot: expectedRoot)
        let accounting = try physicalAccounting(
            authoritative: loaded.snapshot,
            manifestByteCount: loaded.manifestByteCount
        )
        let cached = ScreenProjectionCache(
            root: expectedRoot,
            manifestIdentity: manifestIdentity,
            physicalIdentity: physicalIdentity,
            loaded: loaded,
            accounting: accounting
        )
        screenProjectionCache = cached
        return cached
    }

    private func currentManifestIdentity() throws -> LANInboxRegularFileIdentity {
        let descriptor = Darwin.open(
            layout.manifestURL.path,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            if errno == ENOENT { throw LANInboxError.vaultUnavailable }
            throw VaultError.ioFailure(errno)
        }
        defer { Darwin.close(descriptor) }
        return try regularFileIdentity(descriptor)
    }

    private func currentPhysicalProjectionIdentity() throws
        -> PhysicalProjectionIdentity
    {
        do {
            return try makePhysicalProjectionIdentity()
        } catch VaultError.ioFailure(let code) where code == ENOENT {
            return try makePhysicalProjectionIdentity()
        }
    }

    private func makePhysicalProjectionIdentity() throws
        -> PhysicalProjectionIdentity
    {
        let partialNames = try FileManager.default.contentsOfDirectory(
            atPath: layout.partialsDirectoryURL.path
        ).sorted()
        let partials = try partialNames.map { name in
            let path = "lan-inbox/partials/\(name)"
            guard let id = layout.partialID(at: path) else {
                throw VaultError.invalidPath
            }
            let descriptor = Darwin.open(
                layout.partialsDirectoryURL.appendingPathComponent(name).path,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
            guard descriptor >= 0 else { throw VaultError.ioFailure(errno) }
            defer { Darwin.close(descriptor) }
            return PartialMutationIdentity(
                id: id,
                file: try regularFileIdentity(descriptor)
            )
        }
        return try PhysicalProjectionIdentity(
            inboxDirectory: directoryMutationIdentity(layout.inboxDirectoryURL),
            blobDirectory: directoryMutationIdentity(layout.blobsDirectoryURL),
            partialDirectory: directoryMutationIdentity(layout.partialsDirectoryURL),
            derivedDirectory: directoryMutationIdentity(layout.derivedDirectoryURL),
            partials: partials
        )
    }

    private func directoryMutationIdentity(
        _ url: URL
    ) throws -> DirectoryMutationIdentity {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC | O_DIRECTORY
        )
        guard descriptor >= 0 else { throw VaultError.ioFailure(errno) }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw VaultError.ioFailure(errno)
        }
        guard (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == geteuid(),
              (metadata.st_mode & 0o777) == S_IRWXU,
              let device = UInt64(exactly: metadata.st_dev),
              let inode = UInt64(exactly: metadata.st_ino) else {
            throw VaultError.invalidPath
        }
        return DirectoryMutationIdentity(
            device: device,
            inode: inode,
            modificationSeconds: Int64(metadata.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(metadata.st_mtimespec.tv_nsec),
            statusChangeSeconds: Int64(metadata.st_ctimespec.tv_sec),
            statusChangeNanoseconds: Int64(metadata.st_ctimespec.tv_nsec)
        )
    }

    private func validateReferencedObjects(in snapshot: LANInboxSnapshot) throws {
        for blob in snapshot.blobs {
            let descriptor = try directories.openBlob(blob.id)
            let byteCount: Int
            do {
                byteCount = try regularFileIdentity(descriptor).byteCount
            } catch {
                Darwin.close(descriptor)
                throw error
            }
            Darwin.close(descriptor)
            guard byteCount == blob.byteCount else {
                throw LANInboxError.integrityCheckFailed
            }
        }
        var artifacts: [UUID: LANInboxDerivedArtifact] = [:]
        for artifact in snapshot.items.compactMap(\.derivedArtifact) {
            if let existing = artifacts[artifact.id], existing != artifact {
                throw LANInboxError.invalidReference
            }
            artifacts[artifact.id] = artifact
        }
        for artifact in artifacts.values {
            let descriptor = Darwin.open(
                layout.derivedURL(artifact.id).path,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
            guard descriptor >= 0 else {
                if errno == ENOENT { throw LANInboxError.integrityCheckFailed }
                throw VaultError.ioFailure(errno)
            }
            let byteCount: Int
            do {
                byteCount = try regularFileIdentity(descriptor).byteCount
            } catch {
                Darwin.close(descriptor)
                throw error
            }
            Darwin.close(descriptor)
            guard byteCount == artifact.byteCount else {
                throw LANInboxError.integrityCheckFailed
            }
        }
    }

    @discardableResult
    private func publish(
        _ snapshot: LANInboxSnapshot,
        expectedRoot: VaultRootGeneration
    ) throws -> Data {
        screenProjectionCache = nil
        let desiredData = try LANInboxManifestCodec.encode(snapshot)
        try failIfRequested(.beforeManifestWrite)
        guard rootBinding.matches(expectedRoot) else {
            throw LANInboxError.vaultUnavailable
        }
        do {
            try files.replaceAtomically(desiredData, relativePath: layout.manifestPath)
            try failIfRequested(.afterManifestCommit)
            return desiredData
        } catch {
            guard rootBinding.matches(expectedRoot),
                  let current = try? files.read(
                    relativePath: layout.manifestPath,
                    maximumByteCount: LANInboxManifestCodec.maximumByteCount
                  ),
                  current == desiredData else {
                throw error
            }
            try directories.syncInboxDirectory()
            return desiredData
        }
    }

    private func revision(for snapshot: LANInboxSnapshot) throws -> LANInboxRevision {
        try LANInboxRevision(
            generation: snapshot.generation,
            commitID: snapshot.commitID,
            manifestDigest: ContentDigest.sha256(try CanonicalVaultJSON.encode(snapshot))
        )
    }

    private func reconcile(
        _ snapshot: LANInboxSnapshot,
        expectedRoot: VaultRootGeneration
    ) throws -> LANInboxSnapshot {
        var items = snapshot.items
        var stalePartialIDs: Set<UUID> = []
        var didChange = false
        for index in items.indices {
            let item = items[index]
            guard let attemptID = item.attemptID,
                  try !isActivePartial(attemptID) else { continue }
            guard case .preprocessing = item.state else { continue }
            items[index] = try item.transitioning(
                to: .failed(blobID: item.blobID, issue: .storageFailure),
                expectedRevision: item.revision,
                expectedAttemptID: attemptID
            )
            stalePartialIDs.insert(attemptID)
            didChange = true
        }
        let authoritative: LANInboxSnapshot
        if didChange {
            authoritative = try nextSnapshot(from: snapshot, items: items)
            _ = try publish(authoritative, expectedRoot: expectedRoot)
        } else {
            authoritative = snapshot
        }
        cleanupPartials(stalePartialIDs, expectedRoot: expectedRoot)
        cleanupUnreferencedObjects(authoritative: authoritative, expectedRoot: expectedRoot)
        return authoritative
    }

    private func isActivePartial(_ attemptID: UUID) throws -> Bool {
        if LANInboxActivePartialRegistry.shared.contains(
            rootPath: layout.rootURL.path,
            attemptID: attemptID
        ) { return true }
        try failPartialActivityProbeIfRequested(.open)
        let descriptor = Darwin.open(
            layout.partialURL(attemptID).path,
            O_RDWR | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            if errno == ENOENT { return false }
            throw VaultError.ioFailure(errno)
        }
        defer { Darwin.close(descriptor) }
        try failPartialActivityProbeIfRequested(.metadata)
        _ = try regularFileIdentity(descriptor)
        try failPartialActivityProbeIfRequested(.lock)
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            guard flock(descriptor, LOCK_UN) == 0 else {
                throw VaultError.ioFailure(errno)
            }
            return false
        }
        if errno == EWOULDBLOCK || errno == EAGAIN { return true }
        throw VaultError.ioFailure(errno)
    }

    private func cleanupPartials(
        _ ids: Set<UUID>,
        expectedRoot: VaultRootGeneration
    ) {
        screenProjectionCache = nil
        guard rootBinding.matches(expectedRoot),
              failureInjector?(.beforePhysicalCleanup) != true else { return }
        for id in ids.sorted(by: uuidPrecedes) {
            try? files.remove(relativePath: layout.partialPath(id))
        }
    }

    private func cleanupUnreferencedObjects(
        authoritative snapshot: LANInboxSnapshot,
        expectedRoot: VaultRootGeneration
    ) {
        screenProjectionCache = nil
        guard rootBinding.matches(expectedRoot),
              failureInjector?(.beforePhysicalCleanup) != true else { return }
        let retainedBlobs = Set(snapshot.blobs.map(\.id))
        let retainedDerived = Set(snapshot.items.compactMap(\.derivedArtifact).map(\.id))
        let activePartials = Set(snapshot.items.compactMap(\.attemptID))
        guard let inventory = try? exactInventory() else { return }
        for object in inventory.blobs where !retainedBlobs.contains(object.id) {
            try? files.remove(relativePath: object.path)
        }
        for object in inventory.derived where !retainedDerived.contains(object.id) {
            try? files.remove(relativePath: object.path)
        }
        for object in inventory.partials where !activePartials.contains(object.id) {
            guard let active = try? isActivePartial(object.id), !active else { continue }
            try? files.remove(relativePath: object.path)
        }
        for path in inventory.atomicTemporaryPaths {
            try? files.remove(relativePath: path)
        }
    }

    private func physicalAccounting(
        authoritative snapshot: LANInboxSnapshot,
        manifestByteCount: Int
    ) throws -> PhysicalAccounting {
        _ = manifestByteCount
        let retainedBlobs = Set(snapshot.blobs.map(\.id))
        let retainedDerived = Set(snapshot.items.compactMap(\.derivedArtifact).map(\.id))
        let activePartials = Set(snapshot.items.compactMap(\.attemptID))
        let inventory = try exactInventory()
        var partialBytes = 0
        var orphanCount = 0
        var orphanBytes = 0
        for object in inventory.partials {
            partialBytes = try checkedSum(partialBytes, object.byteCount)
        }
        for object in inventory.blobs where !retainedBlobs.contains(object.id) {
            orphanCount += 1
            orphanBytes = try checkedSum(orphanBytes, object.byteCount)
        }
        for object in inventory.derived where !retainedDerived.contains(object.id) {
            orphanCount += 1
            orphanBytes = try checkedSum(orphanBytes, object.byteCount)
        }
        var inactivePartialCount = 0
        var inactivePartialBytes = 0
        for object in inventory.partials where !activePartials.contains(object.id) {
            if try !isActivePartial(object.id) {
                inactivePartialCount += 1
                inactivePartialBytes = try checkedSum(inactivePartialBytes, object.byteCount)
            }
        }
        return PhysicalAccounting(
            partialCount: inventory.partials.count,
            partialBytes: partialBytes,
            orphanCount: orphanCount,
            orphanBytes: orphanBytes,
            cleanupDebtCount: try checkedSum(orphanCount, inactivePartialCount),
            cleanupDebtBytes: try checkedSum(orphanBytes, inactivePartialBytes)
        )
    }

    private func exactInventory() throws -> Inventory {
        let rootEntries = try FileManager.default.contentsOfDirectory(
            atPath: layout.inboxDirectoryURL.path
        )
        var manifestByteCount: Int?
        var temporaryPaths: [String] = []
        let requiredDirectories: Set<String> = ["blobs", "partials", "derived"]
        var seenDirectories: Set<String> = []
        for name in rootEntries {
            let url = layout.inboxDirectoryURL.appendingPathComponent(name)
            var metadata = stat()
            guard url.path.withCString({ lstat($0, &metadata) }) == 0 else {
                throw VaultError.ioFailure(errno)
            }
            if name == "inbox.json" {
                let descriptor = Darwin.open(
                    url.path,
                    O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                )
                guard descriptor >= 0 else { throw VaultError.ioFailure(errno) }
                defer { Darwin.close(descriptor) }
                manifestByteCount = try regularFileIdentity(descriptor).byteCount
            } else if requiredDirectories.contains(name) {
                guard (metadata.st_mode & S_IFMT) == S_IFDIR,
                      metadata.st_uid == geteuid(),
                      (metadata.st_mode & 0o777) == S_IRWXU else {
                    throw VaultError.invalidPath
                }
                seenDirectories.insert(name)
            } else if PlaintextVaultLayout.isAtomicTemporaryFilename(name) {
                let descriptor = Darwin.open(
                    url.path,
                    O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                )
                guard descriptor >= 0 else { throw VaultError.ioFailure(errno) }
                defer { Darwin.close(descriptor) }
                _ = try regularFileIdentity(descriptor)
                temporaryPaths.append("lan-inbox/\(name)")
            } else {
                throw VaultError.invalidPath
            }
        }
        guard let manifestByteCount,
              seenDirectories == requiredDirectories else {
            throw VaultError.partialInitialization
        }

        func inventoryObjects(
            directory: String,
            identify: (String) -> UUID?
        ) throws -> [InventoryObject] {
            let directoryURL = layout.inboxDirectoryURL
                .appendingPathComponent(directory, isDirectory: true)
            let names = try FileManager.default.contentsOfDirectory(atPath: directoryURL.path)
            return try names.map { name in
                let path = "lan-inbox/\(directory)/\(name)"
                guard let id = identify(path) else { throw VaultError.invalidPath }
                let descriptor = Darwin.open(
                    directoryURL.appendingPathComponent(name).path,
                    O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                )
                guard descriptor >= 0 else { throw VaultError.ioFailure(errno) }
                defer { Darwin.close(descriptor) }
                return InventoryObject(
                    id: id,
                    path: path,
                    byteCount: try regularFileIdentity(descriptor).byteCount
                )
            }.sorted { $0.path < $1.path }
        }

        return try Inventory(
            manifestByteCount: manifestByteCount,
            blobs: inventoryObjects(directory: "blobs", identify: layout.blobID),
            partials: inventoryObjects(directory: "partials", identify: layout.partialID),
            derived: inventoryObjects(directory: "derived", identify: layout.derivedID),
            atomicTemporaryPaths: temporaryPaths.sorted()
        )
    }

    private func validateAbsentScaffolding() throws {
        let inboxURL = layout.inboxDirectoryURL
        var metadata = stat()
        let result = inboxURL.path.withCString { lstat($0, &metadata) }
        guard result == 0 else {
            if errno == ENOENT { return }
            throw VaultError.ioFailure(errno)
        }
        guard (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == geteuid(),
              (metadata.st_mode & 0o777) == S_IRWXU else {
            throw VaultError.invalidPath
        }
        let allowedDirectories: Set<String> = ["blobs", "partials", "derived"]
        let entries = try FileManager.default.contentsOfDirectory(atPath: inboxURL.path)
        for entry in entries {
            let url = inboxURL.appendingPathComponent(entry)
            var entryMetadata = stat()
            guard url.path.withCString({ lstat($0, &entryMetadata) }) == 0 else {
                throw VaultError.ioFailure(errno)
            }
            if allowedDirectories.contains(entry) {
                guard (entryMetadata.st_mode & S_IFMT) == S_IFDIR,
                      entryMetadata.st_uid == geteuid(),
                      (entryMetadata.st_mode & 0o777) == S_IRWXU,
                      try FileManager.default.contentsOfDirectory(atPath: url.path).isEmpty else {
                    throw VaultError.partialInitialization
                }
            } else if PlaintextVaultLayout.isAtomicTemporaryFilename(entry) {
                let descriptor = Darwin.open(
                    url.path,
                    O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                )
                guard descriptor >= 0 else { throw VaultError.ioFailure(errno) }
                defer { Darwin.close(descriptor) }
                _ = try regularFileIdentity(descriptor)
            } else {
                throw VaultError.partialInitialization
            }
        }
    }

    private func checkedSum(_ lhs: Int, _ rhs: Int) throws -> Int {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else { throw LANInboxError.arithmeticOverflow }
        return result.partialValue
    }

    private func nextSnapshot(
        from current: LANInboxSnapshot,
        items: [LANInboxItem]? = nil,
        transportReceipts: [LANInboxTransportReceipt]? = nil,
        contentTerminals: [LANInboxContentTerminal]? = nil,
        archiveIntents: [LANArchiveIntent]? = nil,
        archiveTerminals: [LANArchiveTerminal]? = nil,
        blobs: [LANInboxBlob]? = nil
    ) throws -> LANInboxSnapshot {
        let next = current.generation.addingReportingOverflow(1)
        guard !next.overflow else { throw LANInboxError.invalidGeneration }
        return try current.replacing(
            generation: next.partialValue,
            commitID: makeID(),
            lastWriterRuntimeGeneration: runtimeGeneration,
            items: items,
            transportReceipts: transportReceipts,
            contentTerminals: contentTerminals,
            archiveIntents: archiveIntents,
            archiveTerminals: archiveTerminals,
            blobs: blobs
        )
    }

    private func uuidPrecedes(_ lhs: UUID, _ rhs: UUID) -> Bool {
        lhs.uuidString.lowercased() < rhs.uuidString.lowercased()
    }

    private func failIfRequested(_ point: PlaintextLANInboxStoreFault) throws {
        if failureInjector?(point) == true { throw VaultError.injectedFailure }
    }

    private func activePublicationGuard(
        requested: LANInboxPublicationGuard?
    ) throws -> LANInboxPublicationGuard {
        let resolved = requested ?? LANInboxPublicationGuard(
            runtimeGeneration: runtimeGeneration,
            token: publicationGuardToken
        )
        try validatePublicationGuardIdentity(resolved)
        guard !publicationsRevoked else { throw LANInboxError.invalidState }
        return resolved
    }

    private func validatePublicationGuardIdentity(
        _ guardValue: LANInboxPublicationGuard
    ) throws {
        guard guardValue.runtimeGeneration == runtimeGeneration,
              guardValue.token == publicationGuardToken else {
            throw LANInboxError.staleRevision
        }
    }

    private func failPartialActivityProbeIfRequested(
        _ step: LANInboxPartialActivityProbeStep
    ) throws {
        if let errorNumber = partialActivityProbeFailureInjector?(step) {
            throw VaultError.ioFailure(errorNumber)
        }
    }

    func backupSnapshot(
        using lease: VaultMutationLease
    ) throws -> PlaintextLANInboxBackupSnapshot {
        // `probe(reconcilingTransactionsWith:)` performs the lease validation
        // itself; wrapping it in another lease callback would recursively lock
        // the same non-recursive capability object.
        let root = try probeAndBind(reconcileTransactions: true, lease: lease)
        guard files.exists(relativePath: layout.manifestPath) else {
            throw LANInboxError.vaultUnavailable
        }
        let initial = try loadValidatedSnapshot(expectedRoot: root).snapshot
        _ = try reconcile(initial, expectedRoot: root)
        let loaded = try loadValidatedSnapshot(expectedRoot: root)
        let manifestBytes = try files.read(
            relativePath: layout.manifestPath,
            maximumByteCount: LANInboxManifestCodec.maximumByteCount
        )
        guard try LANInboxManifestCodec.decode(
            LANInboxSnapshot.self,
            from: manifestBytes
        ) == loaded.snapshot else {
            throw VaultError.invalidCatalog
        }
        let identity = try currentManifestIdentity()
        var entries = [PlaintextLibraryBackupFile(
            kind: .lanInboxManifest,
            relativePath: layout.manifestPath,
            byteCount: UInt64(manifestBytes.count),
            digest: ContentDigest.sha256(manifestBytes)
        )] + loaded.snapshot.blobs.map { blob in
            PlaintextLibraryBackupFile(
                kind: .lanInboxBlob,
                relativePath: layout.blobPath(blob.id),
                byteCount: UInt64(blob.byteCount),
                digest: blob.sha256Digest
            )
        }
        let derived = Dictionary(
            loaded.snapshot.items.compactMap(\.derivedArtifact).map { ($0.id, $0) },
            uniquingKeysWith: { existing, _ in existing }
        ).values
        entries.append(contentsOf: derived.map { artifact in
            PlaintextLibraryBackupFile(
                kind: .lanInboxDerivedArtifact,
                relativePath: layout.derivedPath(artifact.id),
                byteCount: UInt64(artifact.byteCount),
                digest: artifact.sha256Digest
            )
        })
        try mutationCoordinator.withValidatedLease(lease) {}
        return PlaintextLANInboxBackupSnapshot(
            root: root,
            manifestIdentity: .init(
                device: identity.device,
                inode: identity.inode,
                byteCount: UInt64(identity.byteCount)
            ),
            revision: try revision(for: loaded.snapshot),
            files: entries.sorted { $0.relativePath < $1.relativePath }
        )
    }

    func validateBackupSnapshot(
        _ snapshot: PlaintextLANInboxBackupSnapshot,
        using lease: VaultMutationLease
    ) throws {
        try mutationCoordinator.withValidatedLease(lease) {}
        let currentRoot = try probeAndBind(reconcileTransactions: false)
        let identity = try currentManifestIdentity()
        let publicIdentity = BackupPublishedFileIdentity(
            device: identity.device,
            inode: identity.inode,
            byteCount: UInt64(identity.byteCount)
        )
        guard currentRoot == snapshot.root,
              publicIdentity == snapshot.manifestIdentity else {
            throw LANInboxError.staleRevision
        }
        try mutationCoordinator.withValidatedLease(lease) {}
    }

    /// Read-only restore gate. This deliberately skips startup reconciliation
    /// and validates every committed blob/derived object against its digest.
    /// Durable `.preprocessing` state is accepted without its transient partial
    /// file; the normal post-restart transition is owned by startup after the
    /// whole restored root has been activated.
    func strictRestoreValidation() async throws -> PlaintextLANInboxRestoreValidation {
        let lease = try await mutationCoordinator.acquire()
        defer { lease.release() }
        return try await strictRestoreValidation(using: lease)
    }

    func strictRestoreValidation(
        using lease: VaultMutationLease
    ) async throws -> PlaintextLANInboxRestoreValidation {
        try mutationCoordinator.withValidatedLease(lease) {}
        let root = try probeAndBind(reconcileTransactions: false)
        guard files.exists(relativePath: layout.manifestPath) else {
            throw LANInboxError.vaultUnavailable
        }
        let loaded = try loadValidatedSnapshot(expectedRoot: root)
        var references = loaded.snapshot.blobs.map(contentReference)
        let derived = Dictionary(
            loaded.snapshot.items.compactMap(\.derivedArtifact).map { ($0.id, $0) },
            uniquingKeysWith: { existing, _ in existing }
        ).values
        references.append(contentsOf: derived.map(contentReference))
        for reference in sortedContentReferences(Array(Set(references))) {
            let opened = try openContentReferences([reference], expectedRoot: root)
            do {
                try await LANInboxIntegrityIO.verify(opened)
                try validateOpenedContentStillNamed(opened, expectedRoot: root)
                closeOpenedContent(opened)
            } catch {
                closeOpenedContent(opened)
                throw error
            }
        }
        guard rootBinding.matches(root) else { throw LANInboxError.vaultUnavailable }
        try mutationCoordinator.withValidatedLease(lease) {}
        return PlaintextLANInboxRestoreValidation(
            vaultID: loaded.snapshot.vaultID,
            revision: try revision(for: loaded.snapshot),
            itemCount: loaded.snapshot.items.count
        )
    }

    private func mapError(_ error: Error) -> Error {
        if error is CancellationError { return error }
        if let error = error as? LANInboxError { return error }
        if error is ImportedFileValidationError || error is LANItemPreprocessorError {
            return error
        }
        guard let error = error as? VaultError else {
            return LANInboxError.storageFailure
        }
        switch error {
        case .unsupportedVersion:
            return LANInboxError.unsupportedVersion
        case .vaultMissing, .partialInitialization, .legacyEncryptedVault:
            return LANInboxError.vaultUnavailable
        case .vaultIDMismatch:
            return LANInboxError.vaultIDMismatch
        case .mutationConflict, .objectAlreadyExists:
            return LANInboxError.mutationConflict
        case .resourceLimitExceeded:
            return LANInboxError.resourceLimitExceeded
        case .invalidDigest, .integrityCheckFailed, .objectMissing, .invalidPath:
            return LANInboxError.integrityCheckFailed
        case .invalidGeneration:
            return LANInboxError.invalidGeneration
        case .invalidCatalog, .ioFailure, .injectedFailure:
            return LANInboxError.storageFailure
        }
    }
}

struct PlaintextLANInboxRestoreValidation: Sendable {
    let vaultID: UUID
    let revision: LANInboxRevision
    let itemCount: Int
}

private struct LANArchiveTerminalAcknowledgement: Hashable, Sendable {
    let intentID: LANArchiveIntent.ID
    let receiptID: LANArchiveReceipt.ID
}

// SAFETY: `lock` protects the complete active-partial key set.
private final class LANInboxActivePartialRegistry: @unchecked Sendable {
    static let shared = LANInboxActivePartialRegistry()

    private struct Key: Hashable {
        let rootPath: String
        let attemptID: UUID
    }

    private let lock = NSLock()
    private var active: Set<Key> = []

    func insert(rootPath: String, attemptID: UUID) throws {
        let key = Key(rootPath: rootPath, attemptID: attemptID)
        let inserted = lock.withLock { active.insert(key).inserted }
        guard inserted else { throw VaultError.mutationConflict }
    }

    func remove(rootPath: String, attemptID: UUID) {
        let key = Key(rootPath: rootPath, attemptID: attemptID)
        _ = lock.withLock { active.remove(key) }
    }

    func contains(rootPath: String, attemptID: UUID) -> Bool {
        lock.withLock { active.contains(Key(rootPath: rootPath, attemptID: attemptID)) }
    }
}

// SAFETY: Descriptor operations are serialized by their owning sink workflow;
// `lock` makes shared registry release idempotent and closures retain the context.
private final class LANInboxPartialContext: @unchecked Sendable {
    let rootPath: String
    let attemptID: UUID

    private let partialDirectoryDescriptor: Int32
    private let blobDirectoryDescriptor: Int32
    private let derivedDirectoryDescriptor: Int32
    private let partialName: String
    private let failureInjector: (@Sendable (PlaintextLANInboxStoreFault) -> Bool)?
    private let lock = NSLock()
    private var didReleaseRegistry = false

    init(
        rootPath: String,
        attemptID: UUID,
        partialDirectoryDescriptor: Int32,
        blobDirectoryDescriptor: Int32,
        derivedDirectoryDescriptor: Int32,
        failureInjector: (@Sendable (PlaintextLANInboxStoreFault) -> Bool)?
    ) throws {
        guard partialDirectoryDescriptor >= 0,
              blobDirectoryDescriptor >= 0,
              derivedDirectoryDescriptor >= 0 else {
            throw VaultError.invalidPath
        }
        self.rootPath = rootPath
        self.attemptID = attemptID
        self.partialDirectoryDescriptor = partialDirectoryDescriptor
        self.blobDirectoryDescriptor = blobDirectoryDescriptor
        self.derivedDirectoryDescriptor = derivedDirectoryDescriptor
        partialName = "\(attemptID.uuidString.lowercased()).partial"
        self.failureInjector = failureInjector
        try LANInboxActivePartialRegistry.shared.insert(
            rootPath: rootPath,
            attemptID: attemptID
        )
    }

    deinit {
        releaseRegistry()
        Darwin.close(partialDirectoryDescriptor)
        Darwin.close(blobDirectoryDescriptor)
        Darwin.close(derivedDirectoryDescriptor)
    }

    func cleanup(partialDescriptor: Int32) throws {
        defer { releaseRegistry() }
        guard try Self.namedEntry(
            partialName,
            in: partialDirectoryDescriptor,
            matches: partialDescriptor
        ) else { return }
        guard unlinkat(partialDirectoryDescriptor, partialName, 0) == 0 else {
            if errno == ENOENT { return }
            throw VaultError.ioFailure(errno)
        }
        try failIfRequested(.afterPartialUnlinkBeforeDirectorySync)
        try Self.syncDirectory(partialDirectoryDescriptor)
    }

    func publish(partialDescriptor: Int32, blobID: UUID) throws {
        try publish(
            partialDescriptor: partialDescriptor,
            destinationDirectoryDescriptor: blobDirectoryDescriptor,
            destinationName: "\(blobID.uuidString.lowercased()).blob",
            renameFault: .afterBlobRenameBeforeBlobDirectorySync,
            directoryFault: .afterBlobDirectorySyncBeforePartialDirectorySync
        )
    }

    func publishDerived(partialDescriptor: Int32, artifactID: UUID) throws {
        try publish(
            partialDescriptor: partialDescriptor,
            destinationDirectoryDescriptor: derivedDirectoryDescriptor,
            destinationName: "\(artifactID.uuidString.lowercased()).data",
            renameFault: .afterDerivedRenameBeforeDerivedDirectorySync,
            directoryFault: .afterDerivedDirectorySyncBeforePartialDirectorySync
        )
    }

    func releaseRegistry() {
        let needsRelease = lock.withLock { () -> Bool in
            guard !didReleaseRegistry else { return false }
            didReleaseRegistry = true
            return true
        }
        if needsRelease {
            LANInboxActivePartialRegistry.shared.remove(
                rootPath: rootPath,
                attemptID: attemptID
            )
        }
    }

    private func publish(
        partialDescriptor: Int32,
        destinationDirectoryDescriptor: Int32,
        destinationName: String,
        renameFault: PlaintextLANInboxStoreFault,
        directoryFault: PlaintextLANInboxStoreFault
    ) throws {
        guard try Self.namedEntry(
            partialName,
            in: partialDirectoryDescriptor,
            matches: partialDescriptor
        ) else { throw VaultError.objectMissing }
        var destination = stat()
        let result = destinationName.withCString {
            fstatat(destinationDirectoryDescriptor, $0, &destination, AT_SYMLINK_NOFOLLOW)
        }
        guard result != 0 else { throw VaultError.objectAlreadyExists }
        guard errno == ENOENT else { throw VaultError.ioFailure(errno) }
        guard renameat(
            partialDirectoryDescriptor,
            partialName,
            destinationDirectoryDescriptor,
            destinationName
        ) == 0 else { throw VaultError.ioFailure(errno) }
        try failIfRequested(renameFault)
        try Self.syncDirectory(destinationDirectoryDescriptor)
        try failIfRequested(directoryFault)
        try Self.syncDirectory(partialDirectoryDescriptor)
    }

    private static func namedEntry(
        _ name: String,
        in directoryDescriptor: Int32,
        matches descriptor: Int32
    ) throws -> Bool {
        let openIdentity = try regularFileIdentity(descriptor)
        var namedMetadata = stat()
        let result = name.withCString {
            fstatat(directoryDescriptor, $0, &namedMetadata, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0 else {
            if errno == ENOENT { return false }
            throw VaultError.ioFailure(errno)
        }
        guard (namedMetadata.st_mode & S_IFMT) == S_IFREG,
              namedMetadata.st_uid == geteuid(),
              namedMetadata.st_nlink == 1,
              UInt64(exactly: namedMetadata.st_dev) == openIdentity.device,
              UInt64(exactly: namedMetadata.st_ino) == openIdentity.inode else {
            throw VaultError.invalidPath
        }
        return true
    }

    private static func syncDirectory(_ descriptor: Int32) throws {
        guard fsync(descriptor) == 0 || errno == EINVAL || errno == ENOTSUP else {
            throw VaultError.ioFailure(errno)
        }
    }

    private func failIfRequested(_ point: PlaintextLANInboxStoreFault) throws {
        if failureInjector?(point) == true { throw VaultError.injectedFailure }
    }

}

private struct LANInboxOpenedPartial {
    let descriptor: Int32
    let context: LANInboxPartialContext
}

private struct LANInboxManagedDirectories {
    private let rootURL: URL
    private let inboxURL: URL
    private let blobsURL: URL
    private let partialsURL: URL
    private let derivedURL: URL
    private let failureInjector: (@Sendable (PlaintextLANInboxStoreFault) -> Bool)?

    init(
        layout: LANInboxLayout,
        failureInjector: (@Sendable (PlaintextLANInboxStoreFault) -> Bool)?
    ) {
        rootURL = layout.rootURL
        inboxURL = layout.inboxDirectoryURL
        blobsURL = layout.blobsDirectoryURL
        partialsURL = layout.partialsDirectoryURL
        derivedURL = layout.derivedDirectoryURL
        self.failureInjector = failureInjector
    }

    func prepare() throws {
        try Self.validateDirectory(rootURL, requireManagedMode: false)
        try createIfNeeded(inboxURL, parent: rootURL)
        try createIfNeeded(blobsURL, parent: inboxURL)
        try createIfNeeded(partialsURL, parent: inboxURL)
        try createIfNeeded(derivedURL, parent: inboxURL)
    }

    func openNewPartial(rootPath: String, attemptID: UUID) throws -> LANInboxOpenedPartial {
        let partialDirectoryDescriptor = try Self.openDirectory(partialsURL)
        var blobDirectoryDescriptor: Int32 = -1
        var derivedDirectoryDescriptor: Int32 = -1
        var partialDescriptor: Int32 = -1
        do {
            blobDirectoryDescriptor = try Self.openDirectory(blobsURL)
            derivedDirectoryDescriptor = try Self.openDirectory(derivedURL)
            let name = "\(attemptID.uuidString.lowercased()).partial"
            partialDescriptor = name.withCString {
                openat(
                    partialDirectoryDescriptor,
                    $0,
                    O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                    S_IRUSR | S_IWUSR
                )
            }
            guard partialDescriptor >= 0 else {
                if errno == EEXIST { throw VaultError.objectAlreadyExists }
                throw VaultError.ioFailure(errno)
            }
            guard try regularFileIdentity(partialDescriptor).byteCount == 0,
                  flock(partialDescriptor, LOCK_EX | LOCK_NB) == 0 else {
                throw VaultError.invalidPath
            }
            try Self.syncFile(partialDescriptor)
            try failIfRequested(.afterPartialCreateFileSyncBeforeDirectorySync)
            try Self.syncDirectory(partialDirectoryDescriptor)
            let context = try LANInboxPartialContext(
                rootPath: rootPath,
                attemptID: attemptID,
                partialDirectoryDescriptor: partialDirectoryDescriptor,
                blobDirectoryDescriptor: blobDirectoryDescriptor,
                derivedDirectoryDescriptor: derivedDirectoryDescriptor,
                failureInjector: failureInjector
            )
            return LANInboxOpenedPartial(descriptor: partialDescriptor, context: context)
        } catch {
            if partialDescriptor >= 0 {
                _ = flock(partialDescriptor, LOCK_UN)
                Darwin.close(partialDescriptor)
                let name = "\(attemptID.uuidString.lowercased()).partial"
                _ = name.withCString { unlinkat(partialDirectoryDescriptor, $0, 0) }
                try? Self.syncDirectory(partialDirectoryDescriptor)
            }
            if blobDirectoryDescriptor >= 0 { Darwin.close(blobDirectoryDescriptor) }
            if derivedDirectoryDescriptor >= 0 { Darwin.close(derivedDirectoryDescriptor) }
            Darwin.close(partialDirectoryDescriptor)
            throw error
        }
    }

    func openBlob(_ id: UUID) throws -> Int32 {
        let directoryDescriptor = try Self.openDirectory(blobsURL)
        defer { Darwin.close(directoryDescriptor) }
        let name = "\(id.uuidString.lowercased()).blob"
        let descriptor = name.withCString {
            openat(
                directoryDescriptor,
                $0,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { throw VaultError.objectMissing }
            throw VaultError.ioFailure(errno)
        }
        do {
            _ = try regularFileIdentity(descriptor)
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    func syncInboxDirectory() throws {
        let descriptor = try Self.openDirectory(inboxURL)
        defer { Darwin.close(descriptor) }
        try Self.syncDirectory(descriptor)
    }

    private func createIfNeeded(_ url: URL, parent: URL) throws {
        var metadata = stat()
        let result = url.path.withCString { lstat($0, &metadata) }
        if result == 0 {
            try Self.validateDirectory(url, requireManagedMode: true)
            return
        }
        guard errno == ENOENT else { throw VaultError.ioFailure(errno) }
        try Self.validateDirectory(parent, requireManagedMode: parent != rootURL)
        guard url.path.withCString({ mkdir($0, S_IRWXU) }) == 0 else {
            if errno == EEXIST {
                try Self.validateDirectory(url, requireManagedMode: true)
                return
            }
            throw VaultError.ioFailure(errno)
        }
        try Self.validateDirectory(url, requireManagedMode: true)
        let descriptor = try Self.openDirectory(url)
        defer { Darwin.close(descriptor) }
        try Self.syncDirectory(descriptor)
        let parentDescriptor = try Self.openDirectory(parent)
        defer { Darwin.close(parentDescriptor) }
        try Self.syncDirectory(parentDescriptor)
    }

    private static func validateDirectory(
        _ url: URL,
        requireManagedMode: Bool
    ) throws {
        var metadata = stat()
        guard url.path.withCString({ lstat($0, &metadata) }) == 0 else {
            if errno == ENOENT { throw VaultError.vaultMissing }
            throw VaultError.ioFailure(errno)
        }
        guard (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == geteuid(),
              !requireManagedMode || (metadata.st_mode & 0o777) == S_IRWXU else {
            throw VaultError.invalidPath
        }
    }

    private static func openDirectory(_ url: URL) throws -> Int32 {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            if errno == ENOENT { throw VaultError.vaultMissing }
            throw VaultError.ioFailure(errno)
        }
        do {
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0,
                  (metadata.st_mode & S_IFMT) == S_IFDIR,
                  metadata.st_uid == geteuid(),
                  (metadata.st_mode & 0o777) == S_IRWXU else {
                throw VaultError.invalidPath
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func syncFile(_ descriptor: Int32) throws {
        if fcntl(descriptor, F_FULLFSYNC) != 0, fsync(descriptor) != 0 {
            throw VaultError.ioFailure(errno)
        }
    }

    private static func syncDirectory(_ descriptor: Int32) throws {
        guard fsync(descriptor) == 0 || errno == EINVAL || errno == ENOTSUP else {
            throw VaultError.ioFailure(errno)
        }
    }

    private func failIfRequested(_ point: PlaintextLANInboxStoreFault) throws {
        if failureInjector?(point) == true { throw VaultError.injectedFailure }
    }
}

private struct LANInboxRegularFileIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let byteCount: Int
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let statusChangeSeconds: Int64
    let statusChangeNanoseconds: Int64
}

private func regularFileIdentity(_ descriptor: Int32) throws -> LANInboxRegularFileIdentity {
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0 else {
        throw VaultError.ioFailure(errno)
    }
    guard (metadata.st_mode & S_IFMT) == S_IFREG,
          metadata.st_uid == geteuid(),
          metadata.st_nlink == 1,
          metadata.st_size >= 0,
          (metadata.st_mode & 0o777) == (S_IRUSR | S_IWUSR),
          let device = UInt64(exactly: metadata.st_dev),
          let inode = UInt64(exactly: metadata.st_ino),
          let byteCount = Int(exactly: metadata.st_size) else {
        throw VaultError.invalidPath
    }
    return LANInboxRegularFileIdentity(
        device: device,
        inode: inode,
        byteCount: byteCount,
        modificationSeconds: Int64(metadata.st_mtimespec.tv_sec),
        modificationNanoseconds: Int64(metadata.st_mtimespec.tv_nsec),
        statusChangeSeconds: Int64(metadata.st_ctimespec.tv_sec),
        statusChangeNanoseconds: Int64(metadata.st_ctimespec.tv_nsec)
    )
}

private func verifyContent(
    descriptor: Int32,
    expectedByteCount: Int,
    expectedSHA256: Data
) throws {
    guard expectedByteCount >= 0,
          expectedSHA256.count == SHA256.byteCount else {
        throw VaultError.integrityCheckFailed
    }
    let before = try regularFileIdentity(descriptor)
    guard before.byteCount == expectedByteCount,
          lseek(descriptor, 0, SEEK_SET) == 0 else {
        throw VaultError.integrityCheckFailed
    }
    var hasher = SHA256()
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while true {
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        if count < 0 {
            if errno == EINTR { continue }
            throw VaultError.ioFailure(errno)
        }
        if count == 0 { break }
        buffer.withUnsafeBytes { bytes in
            hasher.update(bufferPointer: UnsafeRawBufferPointer(
                rebasing: bytes.prefix(count)
            ))
        }
    }
    let after = try regularFileIdentity(descriptor)
    guard before == after,
          Data(hasher.finalize()) == expectedSHA256,
          lseek(descriptor, 0, SEEK_SET) == 0 else {
        throw VaultError.integrityCheckFailed
    }
}

private enum LANInboxIntegrityIO {
    private static let queue = DispatchQueue(label: "com.kinlogue.lan-inbox.integrity")

    static func verify(
        _ opened: [LANInboxOpenedContent],
        willHash: (@Sendable () -> Void)? = nil
    ) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    willHash?()
                    for content in opened {
                        guard try regularFileIdentity(content.descriptor) == content.identity else {
                            throw VaultError.integrityCheckFailed
                        }
                        try verifyContent(
                            descriptor: content.descriptor,
                            expectedByteCount: content.reference.byteCount,
                            expectedSHA256: content.reference.sha256Digest
                        )
                        guard try regularFileIdentity(content.descriptor) == content.identity else {
                            throw VaultError.integrityCheckFailed
                        }
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        try Task.checkCancellation()
    }

    static func verify(
        descriptor: Int32,
        expectedByteCount: Int,
        expectedSHA256: Data,
        willHash: (@Sendable () -> Void)? = nil
    ) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    willHash?()
                    try verifyContent(
                        descriptor: descriptor,
                        expectedByteCount: expectedByteCount,
                        expectedSHA256: expectedSHA256
                    )
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        try Task.checkCancellation()
    }

    static func consume<Result: Sendable>(
        descriptor: Int32,
        body: @escaping @Sendable (Int32) throws -> Result
    ) async throws -> Result {
        try Task.checkCancellation()
        let result = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    guard lseek(descriptor, 0, SEEK_SET) == 0 else {
                        throw VaultError.integrityCheckFailed
                    }
                    continuation.resume(returning: try body(descriptor))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        try Task.checkCancellation()
        return result
    }
}

private func isIntegrityMismatch(_ error: Error) -> Bool {
    if let error = error as? LANInboxError {
        return error == .integrityCheckFailed
    }
    guard let error = error as? VaultError else { return false }
    if case .integrityCheckFailed = error { return true }
    return false
}

private func isNamedObjectIntegrityFailure(_ error: Error) -> Bool {
    if isIntegrityMismatch(error) { return true }
    guard let error = error as? VaultError else { return false }
    switch error {
    case .objectMissing, .invalidPath:
        return true
    default:
        return false
    }
}
