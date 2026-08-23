import CryptoKit
import Darwin
import Foundation
import KinlogueCore
import KinlogueDICOMIPC
import UniformTypeIdentifiers

struct PlaintextVaultObjectMetadata: Codable, Equatable, Sendable {
    let reference: VaultObjectReference
    let byteCount: Int
    let sha256Digest: Data
}

struct PlaintextVaultManifest: Codable, Equatable, Sendable {
    let magic: String
    let formatVersion: Int
    let commitID: UUID
    let catalogSHA256: Data
    let catalog: VaultCatalog
    let objects: [PlaintextVaultObjectMetadata]
}

private struct PlaintextVaultCatalogVersionProbe: Decodable {
    struct Catalog: Decodable { let formatVersion: Int }
    let catalog: Catalog
}

private struct PlaintextVaultManifestResolution {
    let manifest: PlaintextVaultManifest
    let retainedDICOMIndex: DICOMStudyIndex?
}

struct PlaintextVaultManifestIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let byteCount: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64

    init(_ metadata: stat) {
        device = UInt64(metadata.st_dev)
        inode = UInt64(metadata.st_ino)
        byteCount = Int64(metadata.st_size)
        modifiedSeconds = Int64(metadata.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(metadata.st_mtimespec.tv_nsec)
        changedSeconds = Int64(metadata.st_ctimespec.tv_sec)
        changedNanoseconds = Int64(metadata.st_ctimespec.tv_nsec)
    }
}

enum PlaintextVaultResourcePolicy {
    static let maximumManifestByteCount = 64 * 1024 * 1024
    static let maximumObjectCount = 20_000
    static let maximumDICOMObjectCount = VaultCatalog.maximumRetainedDICOMObjectCount
    static let maximumDICOMSeriesCount = DICOMStudyIndex.maximumSeriesCount

    static func validateManifestByteCount(_ count: Int) throws {
        guard count >= 0, count <= maximumManifestByteCount else {
            throw VaultError.resourceLimitExceeded
        }
    }

    static func validateDICOMRetainedObjectCount(_ count: Int) throws {
        guard count >= 0, count <= maximumDICOMObjectCount else {
            throw VaultError.resourceLimitExceeded
        }
    }

    static func addingDICOMSeriesCount(_ count: Int, adding additionalCount: Int) throws -> Int {
        guard count >= 0, additionalCount >= 0 else {
            throw VaultError.resourceLimitExceeded
        }
        let (next, overflow) = count.addingReportingOverflow(additionalCount)
        guard !overflow, next <= maximumDICOMSeriesCount else {
            throw VaultError.resourceLimitExceeded
        }
        return next
    }

    static func maximumByteCount(for kind: VaultObjectKind) -> Int {
        switch kind {
        case .attachment: 100 * 1024 * 1024
        case .thumbnail: 32 * 1024 * 1024
        case .catalog, .record, .ocr: 16 * 1024 * 1024
        case .descriptor: 128 * 1024
        }
    }
}

public enum PlaintextVaultTransactionFault: Equatable, Sendable {
    case afterInitializationReceipt
    case afterInitializationManifestCommit
    case afterObjects
    case afterManifestCommit
    case afterDICOMJournalRecord
    case afterDICOMAttachmentPromotion
    case afterDICOMIndexPromotion
    case afterDeletionReceipt
    case afterDeletionRename
    case afterDeletionQuarantineRemoval
}

public enum VaultDICOMStudyCommitOutcome: Equatable, Sendable {
    case accepted(VaultCatalog, VaultRevision, DICOMStudy.ID)
    case duplicateExisting(VaultCatalog, VaultRevision, DICOMStudy.ID)
}

// SAFETY: Session metadata is immutable; the lease is internally lock-protected
// and all commit/abort operations validate it inside the `PlaintextVault` actor.
final class DICOMVaultImportSession: @unchecked Sendable {
    let operationID: UUID
    let vaultID: UUID
    let revision: VaultRevision
    let stagingOwnership: VaultDICOMStagingOwnership
    fileprivate let lease: VaultMutationLease

    fileprivate init(
        operationID: UUID,
        vaultID: UUID,
        revision: VaultRevision,
        stagingOwnership: VaultDICOMStagingOwnership,
        lease: VaultMutationLease
    ) {
        self.operationID = operationID
        self.vaultID = vaultID
        self.revision = revision
        self.stagingOwnership = stagingOwnership
        self.lease = lease
    }

    fileprivate func release() { lease.release() }
}

/// A local, deliberately unencrypted vault for the first distributable MVP.
///
/// `library.json` is the sole commit point. Object files are immutable and are
/// published before that manifest, so interruption exposes either a complete
/// old generation or a complete new generation. SHA-256 values detect damage;
/// they do not authenticate files and do not prevent rollback or disclosure.
public actor PlaintextVault: VaultStore {
    static let manifestMagic = "KLGPLAINTEXT1"
    static let currentFormatVersion = 1
    private static let maximumManifestByteCount =
        PlaintextVaultResourcePolicy.maximumManifestByteCount
    private static let maximumObjectCount = PlaintextVaultResourcePolicy.maximumObjectCount

    private let layout: PlaintextVaultLayout
    private let files: AtomicFileStore
    private let initializationTransaction: PlaintextVaultInitializationTransaction
    private let deletionTransaction: PlaintextVaultDeletionTransaction
    private let mutationCoordinator: VaultMutationCoordinator
    private let dicomImportJournal: VaultDICOMImportJournal
    private let transactionFailureInjector: (@Sendable (PlaintextVaultTransactionFault) -> Bool)?
    private let manifestResolutionObserver: @Sendable () -> Void

    nonisolated var backupRootURL: URL { layout.rootURL }

    public init(
        rootURL: URL,
        fileFailureInjector: (@Sendable (AtomicFileStoreFaultPoint) -> Bool)? = nil,
        transactionFailureInjector: (@Sendable (PlaintextVaultTransactionFault) -> Bool)? = nil
    ) throws {
        try self.init(
            rootURL: rootURL,
            fileFailureInjector: fileFailureInjector,
            transactionFailureInjector: transactionFailureInjector,
            manifestResolutionObserver: {}
        )
    }

    init(
        rootURL: URL,
        fileFailureInjector: (@Sendable (AtomicFileStoreFaultPoint) -> Bool)? = nil,
        transactionFailureInjector: (@Sendable (PlaintextVaultTransactionFault) -> Bool)? = nil,
        manifestResolutionObserver: @escaping @Sendable () -> Void
    ) throws {
        let layout = try PlaintextVaultLayout(rootURL: rootURL)
        self.layout = layout
        files = try AtomicFileStore(
            rootURL: layout.rootURL,
            failureInjector: fileFailureInjector
        )
        initializationTransaction = try PlaintextVaultInitializationTransaction(
            rootURL: layout.rootURL,
            failureInjector: transactionFailureInjector
        )
        deletionTransaction = try PlaintextVaultDeletionTransaction(
            rootURL: layout.rootURL,
            failureInjector: transactionFailureInjector
        )
        mutationCoordinator = VaultMutationCoordinator.shared(for: layout.rootURL)
        dicomImportJournal = try VaultDICOMImportJournal(rootURL: layout.rootURL)
        self.transactionFailureInjector = transactionFailureInjector
        self.manifestResolutionObserver = manifestResolutionObserver
    }

    public func inspect() async -> VaultAccessState {
        let lease: VaultMutationLease
        do {
            lease = try await mutationCoordinator.acquire()
        } catch is CancellationError {
            return .operationInProgress
        } catch VaultError.mutationConflict {
            return .operationInProgress
        } catch {
            return .damaged
        }
        defer { lease.release() }

        do {
            try prepareForVaultAccess()
            switch try files.rootState() {
            case .absent, .empty:
                return .absent
            case .nonempty:
                guard files.exists(relativePath: layout.manifestPath) else {
                    return .damaged
                }
            }
            let manifest = try resolveManifest(
                cleanupOrphans: true,
                verifyAllObjects: true
            )
            return .ready(try head(for: manifest))
        } catch VaultError.legacyEncryptedVault {
            return .legacyEncrypted
        } catch VaultError.unsupportedVersion {
            return .unsupportedVersion
        } catch {
            return .damaged
        }
    }

    public func loadValidatedCatalog() async throws -> VaultCatalog {
        let lease = try await mutationCoordinator.acquire()
        defer { lease.release() }

        try prepareForVaultAccess()
        switch try files.rootState() {
        case .absent, .empty:
            throw VaultError.vaultMissing
        case .nonempty:
            guard files.exists(relativePath: layout.manifestPath) else {
                throw VaultError.partialInitialization
            }
        }
        return try resolveManifest(
            cleanupOrphans: true,
            verifyAllObjects: true
        ).catalog
    }

    public func initialize() async throws -> VaultCatalog {
        let lease = try await mutationCoordinator.acquire()
        defer { lease.release() }

        try prepareForVaultAccess()
        guard !files.exists(relativePath: layout.manifestPath) else {
            throw VaultError.mutationConflict
        }
        guard try files.rootState() != .nonempty else {
            throw VaultError.partialInitialization
        }

        let catalog = try VaultCatalog(vaultID: UUID(), generation: 1)
        let manifest = try makeManifest(catalog: catalog, objects: [])
        let manifestData = try encodeCheckedManifest(manifest)
        try initializationTransaction.begin(expectedManifestData: manifestData)
        try files.replaceAtomically(manifestData, relativePath: layout.manifestPath)
        try initializationTransaction.finishAfterManifestCommit()
        return catalog
    }

    public func loadCatalog() async throws -> VaultCatalog {
        let lease = try await mutationCoordinator.acquire()
        defer { lease.release() }
        try prepareForVaultAccess()
        return try resolveManifest(cleanupOrphans: true).catalog
    }

    public func loadCatalogHead() async throws -> (VaultCatalog, VaultRevision) {
        let lease = try await mutationCoordinator.acquire()
        defer { lease.release() }
        try prepareForVaultAccess()
        let manifest = try resolveManifest(cleanupOrphans: true)
        return (manifest.catalog, try head(for: manifest))
    }

    func prepareOriginalArchiveExport(
        undatedToken: String
    ) async throws -> PlaintextOriginalArchiveSnapshot {
        let lease = try await mutationCoordinator.acquire()
        defer { lease.release() }
        try prepareForVaultAccess()
        let manifest = try resolveManifest(cleanupOrphans: false)
        let reportAttachmentIDs = Set(
            manifest.catalog.records
                .filter { $0.importState == .confirmed }
                .flatMap { $0.sources.elements.map(\.attachmentID) }
        )
        let dicomAttachmentIDs = Set(
            manifest.catalog.dicomStudies
                .filter { $0.state == .confirmed }
                .flatMap(\.attachmentIDs)
        )
        let eligibleAttachmentIDs = reportAttachmentIDs.union(dicomAttachmentIDs)
        let preferredExtensions: [Attachment.ID: String] = Dictionary(uniqueKeysWithValues:
            manifest.catalog.attachments.compactMap { attachment -> (Attachment.ID, String)? in
                guard eligibleAttachmentIDs.contains(attachment.id) else { return nil }
                let fileExtension: String
                if dicomAttachmentIDs.contains(attachment.id) {
                    fileExtension = "dcm"
                } else {
                    fileExtension = UTType(attachment.contentTypeIdentifier)?
                        .preferredFilenameExtension ?? "bin"
                }
                return (attachment.id, fileExtension)
            }
        )
        let plan = try OriginalArchivePlan.make(
            catalog: manifest.catalog,
            preferredExtensions: preferredExtensions,
            undatedToken: undatedToken
        )
        let plannedAttachmentIDs: Set<Attachment.ID> = Set(
            plan.entries.map { $0.attachmentID }
        )
        let metadataByAttachmentID = Dictionary(uniqueKeysWithValues:
            manifest.objects.compactMap { metadata in
                metadata.reference.kind == .attachment
                    && plannedAttachmentIDs.contains(metadata.reference.id)
                    ? (metadata.reference.id, metadata)
                    : nil
            }
        )
        for entry in plan.entries {
            guard let metadata = metadataByAttachmentID[entry.attachmentID],
                  metadata.byteCount == entry.byteCount,
                  metadata.sha256Digest == entry.sha256Digest else {
                throw PlaintextOriginalArchiveExportError.sourceIntegrityFailure
            }
        }
        return PlaintextOriginalArchiveSnapshot(
            plan: plan,
            revision: try head(for: manifest),
            manifestIdentity: try manifestIdentity(),
            metadataByAttachmentID: metadataByAttachmentID,
            vaultRootURL: layout.rootURL
        )
    }

    func openOriginalArchiveSource(
        for entry: OriginalArchiveEntry,
        snapshot: PlaintextOriginalArchiveSnapshot
    ) async throws -> PlaintextOriginalArchiveSource {
        let lease = try await mutationCoordinator.acquire()
        defer { lease.release() }
        try Task.checkCancellation()
        guard !files.exists(relativePath: layout.legacyEncryptedMarkerPath),
              (try? manifestIdentity()) == snapshot.manifestIdentity else {
            throw PlaintextOriginalArchiveExportError.vaultChanged
        }
        let reference = VaultObjectReference(id: entry.attachmentID, kind: .attachment)
        guard let expectedMetadata = snapshot.metadataByAttachmentID[entry.attachmentID],
              expectedMetadata.reference == reference,
              expectedMetadata.byteCount == entry.byteCount,
              expectedMetadata.sha256Digest == entry.sha256Digest else {
            throw PlaintextOriginalArchiveExportError.vaultChanged
        }

        var duplicatedDescriptor: Int32 = -1
        try files.withRegularFileDescriptor(relativePath: layout.objectPath(reference)) { descriptor in
            var openedMetadata = stat()
            guard fstat(descriptor, &openedMetadata) == 0,
                  (openedMetadata.st_mode & S_IFMT) == S_IFREG,
                  openedMetadata.st_size == expectedMetadata.byteCount else {
                throw PlaintextOriginalArchiveExportError.sourceIntegrityFailure
            }
            duplicatedDescriptor = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
            guard duplicatedDescriptor >= 0 else {
                throw PlaintextOriginalArchiveExportError.ioFailure(errno)
            }
            var duplicatedMetadata = stat()
            guard fstat(duplicatedDescriptor, &duplicatedMetadata) == 0,
                  duplicatedMetadata.st_dev == openedMetadata.st_dev,
                  duplicatedMetadata.st_ino == openedMetadata.st_ino,
                  duplicatedMetadata.st_size == openedMetadata.st_size,
                  (duplicatedMetadata.st_mode & S_IFMT) == S_IFREG else {
                Darwin.close(duplicatedDescriptor)
                duplicatedDescriptor = -1
                throw PlaintextOriginalArchiveExportError.sourceIntegrityFailure
            }
        }
        guard duplicatedDescriptor >= 0 else {
            throw PlaintextOriginalArchiveExportError.sourceIntegrityFailure
        }
        return PlaintextOriginalArchiveSource(
            descriptor: duplicatedDescriptor,
            byteCount: expectedMetadata.byteCount,
            sha256Digest: expectedMetadata.sha256Digest
        )
    }

    func validateOriginalArchiveRevision(
        _ snapshot: PlaintextOriginalArchiveSnapshot
    ) async throws {
        let lease = try await mutationCoordinator.acquire()
        defer { lease.release() }
        try prepareForVaultAccess()
        let manifest = try resolveManifest(cleanupOrphans: false)
        guard try head(for: manifest) == snapshot.revision else {
            throw PlaintextOriginalArchiveExportError.vaultChanged
        }
    }

    public func readObject(_ reference: VaultObjectReference) async throws -> Data {
        let lease = try await mutationCoordinator.acquire()
        defer { lease.release() }
        try prepareForVaultAccess()
        let manifest = try resolveManifest(cleanupOrphans: true)
        guard let metadata = manifest.objects.first(where: { $0.reference == reference }) else {
            throw VaultError.objectMissing
        }
        return try readAndValidateObject(metadata)
    }

    public func readSnapshot(
        selecting references: @Sendable (VaultCatalog) throws
            -> [VaultObjectReference]
    ) async throws -> VaultReadSnapshot {
        let lease = try await mutationCoordinator.acquire()
        defer { lease.release() }
        try prepareForVaultAccess()
        let manifest = try resolveManifest(cleanupOrphans: true)
        let selected = try references(manifest.catalog)
        guard selected.count <= VaultReadSnapshotPolicy.maximumObjectCount,
              Set(selected).count == selected.count else {
            throw VaultError.resourceLimitExceeded
        }
        let selectedReferences = Set(selected)
        var metadataByReference: [VaultObjectReference: PlaintextVaultObjectMetadata] = [:]
        metadataByReference.reserveCapacity(selected.count)
        for metadata in manifest.objects where selectedReferences.contains(metadata.reference) {
            metadataByReference[metadata.reference] = metadata
        }
        let selectedMetadata = try selected.map { reference in
            guard let metadata = metadataByReference[reference] else {
                throw VaultError.objectMissing
            }
            return metadata
        }
        let retainedByteCount = try selectedMetadata.reduce(into: 0) { total, metadata in
            let next = total.addingReportingOverflow(metadata.byteCount)
            guard !next.overflow,
                  next.partialValue <= VaultReadSnapshotPolicy.maximumRetainedByteCount else {
                throw VaultError.resourceLimitExceeded
            }
            total = next.partialValue
        }
        var objects: [VaultObjectReference: Data] = [:]
        objects.reserveCapacity(selectedMetadata.count)
        for metadata in selectedMetadata {
            objects[metadata.reference] = try readAndValidateObject(metadata)
        }
        let snapshot = try VaultReadSnapshot(catalog: manifest.catalog, objects: objects)
        guard snapshot.retainedByteCount == retainedByteCount else {
            throw VaultError.integrityCheckFailed
        }
        return snapshot
    }

    func openVerifiedDICOMSeries(
        studyID: DICOMStudy.ID,
        seriesID: DICOMStudyIndex.Series.ID
    ) async throws -> DICOMSliceSeriesSession {
        let lease = try await mutationCoordinator.acquire()
        defer { lease.release() }
        try prepareForVaultAccess()
        let resolution = try resolveManifest(
            cleanupOrphans: false,
            retainingDICOMIndexFor: studyID
        )
        let manifest = resolution.manifest
        guard manifest.catalog.dicomStudies.contains(where: { $0.id == studyID }) else {
            throw DICOMSliceServiceError.studyUnavailable
        }
        guard let index = resolution.retainedDICOMIndex else {
            throw DICOMSliceServiceError.integrityFailure
        }
        guard let series = index.series.first(where: { $0.id == seriesID }) else {
            throw DICOMSliceServiceError.seriesUnavailable
        }
        let instancesByID = Dictionary(uniqueKeysWithValues: index.instances.map { ($0.id, $0) })
        let metadataByReference = Dictionary(
            uniqueKeysWithValues: manifest.objects.map { ($0.reference, $0) }
        )
        let descriptors = try series.instanceIDs.map { instanceID in
            guard let instance = instancesByID[instanceID],
                  instance.seriesID == seriesID,
                  let metadata = metadataByReference[VaultObjectReference(
                    id: instance.attachmentID,
                    kind: .attachment
                  )] else {
                throw DICOMSliceServiceError.integrityFailure
            }
            return try DICOMSliceInstanceDescriptor(
                id: instance.id,
                attachmentID: instance.attachmentID,
                contentDigest: metadata.sha256Digest,
                objectByteCount: metadata.byteCount,
                attributes: instance.attributes
            )
        }
        let token = try DICOMVaultSessionToken(
            vaultID: manifest.catalog.vaultID,
            revision: head(for: manifest)
        )
        return try DICOMSliceSeriesSession(
            token: token,
            studyID: studyID,
            seriesID: seriesID,
            orderingProvenance: series.orderingProvenance,
            instances: descriptors
        )
    }

    func decodeVerifiedDICOMInstance(
        _ requested: DICOMSliceInstanceDescriptor,
        in session: DICOMSliceSeriesSession,
        decoder: any DICOMFrameDecoding
    ) async throws -> DICOMVerifiedDecodedFrame {
        let lease = try await mutationCoordinator.acquire()
        defer { lease.release() }
        try prepareForVaultAccess()
        let resolution = try resolveManifest(
            cleanupOrphans: false,
            retainingDICOMIndexFor: session.studyID
        )
        let manifest = resolution.manifest
        let currentToken = try DICOMVaultSessionToken(
            vaultID: manifest.catalog.vaultID,
            revision: head(for: manifest)
        )
        guard currentToken == session.token,
              manifest.catalog.dicomStudies.contains(where: {
                $0.id == session.studyID
              }) else {
            throw DICOMSliceServiceError.staleSession
        }
        guard let index = resolution.retainedDICOMIndex else {
            throw DICOMSliceServiceError.integrityFailure
        }
        guard let series = index.series.first(where: { $0.id == session.seriesID }),
              series.instanceIDs.contains(requested.id),
              let instance = index.instances.first(where: { $0.id == requested.id }),
              instance.seriesID == session.seriesID,
              instance.attachmentID == requested.attachmentID,
              instance.attributes == requested.attributes else {
            throw DICOMSliceServiceError.integrityFailure
        }
        let reference = VaultObjectReference(id: instance.attachmentID, kind: .attachment)
        guard let metadata = manifest.objects.first(where: { $0.reference == reference }),
              metadata.byteCount == requested.objectByteCount,
              metadata.sha256Digest == requested.contentDigest else {
            throw DICOMSliceServiceError.integrityFailure
        }
        let lifecycle = try dicomSliceLifecycleTicket()

        let frame = try await files.withRegularFileDescriptor(
            relativePath: layout.objectPath(reference)
        ) { descriptor in
            var before = stat()
            guard fstat(descriptor, &before) == 0,
                  (before.st_mode & S_IFMT) == S_IFREG,
                  before.st_size == metadata.byteCount,
                  try Self.hashDICOMDescriptor(
                    descriptor,
                    expectedByteCount: metadata.byteCount
                  ) == metadata.sha256Digest else {
                throw DICOMSliceServiceError.integrityFailure
            }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
            let frame = try await decoder.decode(
                descriptor: handle,
                declaredByteCount: metadata.byteCount
            )
            var after = stat()
            guard fstat(descriptor, &after) == 0,
                  before.st_dev == after.st_dev,
                  before.st_ino == after.st_ino,
                  before.st_size == after.st_size,
                  try Self.hashDICOMDescriptor(
                    descriptor,
                    expectedByteCount: metadata.byteCount
                  ) == metadata.sha256Digest else {
                throw DICOMSliceServiceError.integrityFailure
            }
            do { try frame.validate() }
            catch { throw DICOMSliceServiceError.integrityFailure }
            guard try DICOMImageAttributesMapper.attributes(for: frame)
                    == requested.attributes else {
                throw DICOMSliceServiceError.integrityFailure
            }
            return frame
        }
        return DICOMVerifiedDecodedFrame(frame: frame, lifecycle: lifecycle)
    }

    private struct DICOMManifestIdentity: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
        let byteCount: Int64
        let generation: UInt32
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
    }

    private func dicomSliceLifecycleTicket() throws -> DICOMSliceLifecycleTicket {
        let coordinator = mutationCoordinator
        let generation = coordinator.dicomSliceLifecycleSnapshot()
        let manifestURL = layout.rootURL.appendingPathComponent(layout.manifestPath)
        let manifestIdentity = try Self.dicomManifestIdentity(at: manifestURL)
        return DICOMSliceLifecycleTicket {
            guard coordinator.isDICOMSliceLifecycleCurrent(generation),
                  (try? Self.dicomManifestIdentity(at: manifestURL)) == manifestIdentity else {
                throw DICOMSliceServiceError.staleSession
            }
        }
    }

    private nonisolated static func dicomManifestIdentity(
        at url: URL
    ) throws -> DICOMManifestIdentity {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG else {
            throw DICOMSliceServiceError.staleSession
        }
        return DICOMManifestIdentity(
            device: UInt64(truncatingIfNeeded: metadata.st_dev),
            inode: UInt64(truncatingIfNeeded: metadata.st_ino),
            byteCount: Int64(metadata.st_size),
            generation: metadata.st_gen,
            modifiedSeconds: Int64(metadata.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(metadata.st_mtimespec.tv_nsec)
        )
    }

    public func commit(_ request: VaultCommitRequest) async throws -> VaultCatalog {
        let lease = try await mutationCoordinator.acquire()
        defer { lease.release() }

        try prepareForVaultAccess()
        let current = try resolveManifest(cleanupOrphans: true)
        guard request.expectedGeneration == current.catalog.generation else {
            throw VaultError.mutationConflict
        }
        let nextGeneration = try VaultGeneration.successor(of: current.catalog.generation)
        guard request.catalog.generation == nextGeneration else {
            throw VaultError.mutationConflict
        }

        let catalog = try request.catalog.validated()
        guard catalog.vaultID == current.catalog.vaultID else {
            throw VaultError.vaultIDMismatch
        }
        try validateDICOMStudyEvolution(
            from: current.catalog,
            to: catalog,
            removedStudyIDs: request.removedDICOMStudyIDs
        )
        guard request.writes.allSatisfy({
            $0.reference.kind != .catalog && $0.reference.kind != .descriptor
        }) else {
            throw VaultError.invalidCatalog
        }

        let orderedReferences = catalog.reachableObjectReferences
        guard orderedReferences.count <= Self.maximumObjectCount else {
            throw VaultError.resourceLimitExceeded
        }
        let reachableReferences = Set(orderedReferences)
        let writtenReferences = Set(request.writes.map(\.reference))
        guard writtenReferences.isSubset(of: reachableReferences) else {
            throw VaultError.invalidCatalog
        }
        let introducedReferences = reachableReferences.subtracting(
            Set(current.catalog.reachableObjectReferences)
        )
        guard introducedReferences.isSubset(of: writtenReferences) else {
            throw VaultError.invalidCatalog
        }

        try validateAttachmentWrites(request.writes, catalog: catalog)
        let currentMetadata = Dictionary(
            uniqueKeysWithValues: current.objects.map { ($0.reference, $0) }
        )
        let writes = Dictionary(
            uniqueKeysWithValues: request.writes.map { ($0.reference, $0) }
        )
        let metadata = try orderedReferences.map { reference in
            if let write = writes[reference] {
                guard write.plaintext.count <= maximumByteCount(for: reference.kind) else {
                    throw VaultError.resourceLimitExceeded
                }
                return PlaintextVaultObjectMetadata(
                    reference: reference,
                    byteCount: write.plaintext.count,
                    sha256Digest: ContentDigest.sha256(write.plaintext)
                )
            }
            guard let metadata = currentMetadata[reference] else {
                throw VaultError.invalidCatalog
            }
            return metadata
        }
        try validateObjectMetadata(metadata, for: catalog)
        let manifest = try makeManifest(catalog: catalog, objects: metadata)
        let manifestData = try encodeCheckedManifest(manifest)
        try validateDICOMIndexes(
            catalog: catalog,
            metadata: metadata,
            writes: writes
        )

        for write in request.writes {
            try writeObjectIdempotently(write)
        }
        try failIfRequested(.afterObjects)

        try files.replaceAtomically(manifestData, relativePath: layout.manifestPath)
        try failIfRequested(.afterManifestCommit)
        try? retireOrphanedObjects(
            retaining: Set(metadata.map(\.reference)),
            tolerateRemovalFailures: true
        )
        return catalog
    }

    /// File-backed commit for one explicitly ordered Mac report selection.
    /// The preallocated draft identity makes response-loss retries idempotent;
    /// exact source matches return the existing report without mutation.
    public func commitStagedReportSelection(
        _ staged: VaultStagedReportSelection,
        intent: LANArchiveIntent,
        expectedGeneration: UInt64,
        catalog proposedCatalog: VaultCatalog,
        documentWrite: VaultObjectWrite
    ) async throws -> VaultStagedReportCommitOutcome {
        let lease = try await mutationCoordinator.acquire()
        defer { lease.release() }

        try prepareForVaultAccess()
        let current = try resolveManifest(cleanupOrphans: true)
        guard staged.intentID == intent.id else { throw VaultError.invalidCatalog }
        let currentRevision = try head(for: current)
        if let ownDraft = current.catalog.importDrafts.first(where: {
            $0.id == intent.draftID
        }) {
            guard ownDraft.state == .needsReview,
                  ownDraft.memberID == intent.memberID,
                  ownDraft.documentObjectID == intent.documentObjectID,
                  ownDraft.sources.elements.map(\.id)
                    == intent.orderedSources.map(\.reportSourceID),
                  ownDraft.sources.attachmentIDs
                    == intent.orderedSources.map(\.attachmentID),
                  (try ReportFingerprint(
                    sources: ownDraft.sources,
                    attachments: current.catalog.attachments
                  )) == intent.fingerprint else {
                throw VaultError.objectAlreadyExists
            }
            return .accepted(current.catalog, currentRevision)
        }
        if let duplicate = DuplicateDetector.find(
            fingerprint: intent.fingerprint,
            attachments: current.catalog.attachments,
            records: current.catalog.records,
            drafts: current.catalog.importDrafts
        ) {
            let destination: LANReportDuplicateDestination
            switch duplicate {
            case let .record(id):
                destination = .init(kind: .healthRecord, id: id)
            case let .draft(id):
                destination = .init(kind: .importDraft, id: id)
            }
            return .duplicateSkipped(destination, currentRevision)
        }
        guard expectedGeneration == current.catalog.generation else {
            throw VaultError.mutationConflict
        }
        let nextGeneration = try VaultGeneration.successor(of: current.catalog.generation)
        guard proposedCatalog.generation == nextGeneration else {
            throw VaultError.mutationConflict
        }
        let catalog = try proposedCatalog.validated()
        guard catalog.vaultID == current.catalog.vaultID,
              documentWrite.reference.kind == .ocr,
              documentWrite.plaintext.count <= maximumByteCount(for: .ocr) else {
            throw VaultError.invalidCatalog
        }
        try validateDICOMStudyEvolution(from: current.catalog, to: catalog)

        let orderedReferences = catalog.reachableObjectReferences
        guard orderedReferences.count <= Self.maximumObjectCount else {
            throw VaultError.resourceLimitExceeded
        }
        let reachableReferences = Set(orderedReferences)
        let stagedReferences = Set(staged.attachments.map(\.reference))
        let providedReferences = stagedReferences.union([documentWrite.reference])
        guard providedReferences.isSubset(of: reachableReferences) else {
            throw VaultError.invalidCatalog
        }
        let introduced = reachableReferences.subtracting(
            Set(current.catalog.reachableObjectReferences)
        )
        guard introduced.isSubset(of: providedReferences) else {
            throw VaultError.invalidCatalog
        }

        let attachmentsByID = Dictionary(
            uniqueKeysWithValues: catalog.attachments.map { ($0.id, $0) }
        )
        for stagedAttachment in staged.attachments {
            guard stagedAttachment.relativePath == Self.stagingPath(
                intentID: staged.intentID,
                attachmentID: stagedAttachment.reference.id
            ),
            let attachment = attachmentsByID[stagedAttachment.reference.id],
            attachment.byteCount == stagedAttachment.byteCount,
            attachment.sha256Digest == stagedAttachment.sha256Digest,
            stagedAttachment.byteCount <= maximumByteCount(for: .attachment) else {
                throw VaultError.integrityCheckFailed
            }
        }

        let currentMetadata = Dictionary(
            uniqueKeysWithValues: current.objects.map { ($0.reference, $0) }
        )
        let stagedByReference = Dictionary(
            uniqueKeysWithValues: staged.attachments.map { ($0.reference, $0) }
        )
        let documentMetadata = PlaintextVaultObjectMetadata(
            reference: documentWrite.reference,
            byteCount: documentWrite.plaintext.count,
            sha256Digest: ContentDigest.sha256(documentWrite.plaintext)
        )
        let metadata = try orderedReferences.map { reference in
            if let stagedAttachment = stagedByReference[reference] {
                return PlaintextVaultObjectMetadata(
                    reference: reference,
                    byteCount: stagedAttachment.byteCount,
                    sha256Digest: stagedAttachment.sha256Digest
                )
            }
            if reference == documentWrite.reference { return documentMetadata }
            guard let existing = currentMetadata[reference] else {
                throw VaultError.invalidCatalog
            }
            return existing
        }
        try validateObjectMetadata(metadata, for: catalog)
        let manifest = try makeManifest(catalog: catalog, objects: metadata)
        let manifestData = try encodeCheckedManifest(manifest)
        try validateDICOMIndexes(
            catalog: catalog,
            metadata: metadata,
            writes: [documentWrite.reference: documentWrite]
        )

        for stagedAttachment in staged.attachments {
            try files.withRegularFileDescriptor(
                relativePath: stagedAttachment.relativePath
            ) { descriptor in
                try files.writeImmutable(
                    copyingFrom: descriptor,
                    expectedByteCount: stagedAttachment.byteCount,
                    expectedSHA256: stagedAttachment.sha256Digest,
                    relativePath: layout.objectPath(stagedAttachment.reference)
                )
            }
        }
        try writeObjectIdempotently(documentWrite)
        try failIfRequested(.afterObjects)

        try files.replaceAtomically(manifestData, relativePath: layout.manifestPath)
        try failIfRequested(.afterManifestCommit)
        try? retireOrphanedObjects(
            retaining: Set(metadata.map(\.reference)),
            tolerateRemovalFailures: true
        )
        return .accepted(catalog, try head(for: manifest))
    }

    /// Starts durable ownership before the first staged byte and retains the
    /// process-wide mutation lease through scanning, indexing and publication.
    func beginDICOMImport(
        operationID: UUID,
        staging: VaultDICOMStudyStaging
    ) async throws -> DICOMVaultImportSession {
        let lease = try await mutationCoordinator.acquire()
        do {
            try prepareForVaultAccess()
            let current = try resolveManifest(
                cleanupOrphans: true,
                reconcileDICOMImports: false
            )
            let reconciliation = try dicomImportJournal.reconcile(
                vaultID: current.catalog.vaultID,
                retaining: Set(current.objects.map(\.reference))
            )
            guard reconciliation.retryOperationCount == 0 else {
                throw DICOMImportError.integrityFailure
            }
            let revision = try head(for: current)
            do {
                try dicomImportJournal.begin(
                    operationID: operationID,
                    vaultID: current.catalog.vaultID
                )
                let ownership = try staging.prepare(operationID: operationID)
                try dicomImportJournal.bindStagingOwnership(
                    ownership,
                    operationID: operationID
                )
                return DICOMVaultImportSession(
                    operationID: operationID,
                    vaultID: current.catalog.vaultID,
                    revision: revision,
                    stagingOwnership: ownership,
                    lease: lease
                )
            } catch {
                _ = try? dicomImportJournal.reconcile(
                    vaultID: current.catalog.vaultID,
                    retaining: Set(current.objects.map(\.reference))
                )
                throw error
            }
        } catch {
            lease.release()
            throw error
        }
    }

    func abortDICOMImport(_ session: DICOMVaultImportSession) async throws {
        defer { session.release() }
        try mutationCoordinator.withValidatedLease(session.lease) {
            try prepareForVaultAccess()
            let current = try resolveManifest(
                cleanupOrphans: false,
                reconcileDICOMImports: false
            )
            guard current.catalog.vaultID == session.vaultID else {
                throw VaultError.vaultIDMismatch
            }
            let reconciliation = try dicomImportJournal.reconcile(
                vaultID: current.catalog.vaultID,
                retaining: Set(current.objects.map(\.reference))
            )
            guard reconciliation.retryOperationCount == 0 else {
                throw DICOMImportError.integrityFailure
            }
        }
    }

    /// Reads the structurally validated manifest while the import still owns
    /// the mutation lease. Journal reconciliation is intentionally skipped so
    /// a retryable cleanup debt cannot hide an already published study graph.
    func loadDICOMImportTerminalCatalog(
        _ session: DICOMVaultImportSession
    ) async throws -> VaultCatalog {
        try mutationCoordinator.withValidatedLease(session.lease) {}
        try prepareForVaultAccess()
        let current = try resolveManifest(
            cleanupOrphans: false,
            reconcileDICOMImports: false
        )
        guard current.catalog.vaultID == session.vaultID else {
            throw VaultError.vaultIDMismatch
        }
        return current.catalog
    }

    /// Atomically publishes one fully indexed DICOM examination. The final
    /// coordinated read rechecks idempotence, capacity and graph closure; every
    /// promoted object enters the durable opaque journal before its write.
    func commitStagedDICOMStudy(
        _ proposal: DICOMIndexedStudyProposal,
        session: DICOMVaultImportSession,
        staging: VaultDICOMStudyStaging,
        metrics: DICOMImportMetricsRecorder? = nil
    ) async throws -> VaultDICOMStudyCommitOutcome {
        try mutationCoordinator.withValidatedLease(session.lease) {}
        try prepareForVaultAccess()
        let current = try resolveManifest(
            cleanupOrphans: false,
            reconcileDICOMImports: false
        )
        let revision = try head(for: current)
        guard revision == session.revision,
              current.catalog.vaultID == session.vaultID else {
            throw VaultError.mutationConflict
        }
        if let existing = current.catalog.dicomStudies.first(where: {
            $0.fingerprint == proposal.study.fingerprint
        }) {
            _ = try? dicomImportJournal.reconcile(
                vaultID: current.catalog.vaultID,
                retaining: Set(current.objects.map(\.reference))
            )
            session.release()
            return .duplicateExisting(current.catalog, revision, existing.id)
        }
        guard current.catalog.generation < UInt64.max,
              proposal.objects.allSatisfy({
                $0.staged.ownership == session.stagingOwnership
              }),
              Set(proposal.objects.map(\.attachment.id)) == Set(proposal.study.attachmentIDs),
              proposal.index.studyID == proposal.study.id else {
            throw VaultError.mutationConflict
        }

        let uniqueBytes = proposal.objects.reduce(0) { partial, object in
            partial + object.attachment.byteCount
        }
        try staging.validateCapacity(uniqueStagedBytes: uniqueBytes)
        let catalog = try VaultCatalog(
            vaultID: current.catalog.vaultID,
            generation: try VaultGeneration.successor(of: current.catalog.generation),
            members: current.catalog.members,
            records: current.catalog.records,
            attachments: current.catalog.attachments + proposal.objects.map(\.attachment),
            importDrafts: current.catalog.importDrafts,
            dicomStudies: current.catalog.dicomStudies + [proposal.study]
        ).validated()
        try validateDICOMStudyEvolution(from: current.catalog, to: catalog)

        let indexData: Data
        do { indexData = try CanonicalVaultJSON.encode(proposal.index) }
        catch { throw VaultError.invalidCatalog }
        guard indexData.count <= maximumByteCount(for: .record) else {
            throw VaultError.resourceLimitExceeded
        }
        let indexReference = VaultObjectReference(id: proposal.study.indexObjectID, kind: .record)
        let indexWrite = VaultObjectWrite(reference: indexReference, plaintext: indexData)
        let currentMetadata = Dictionary(uniqueKeysWithValues: current.objects.map {
            ($0.reference, $0)
        })
        let objectByReference = Dictionary(uniqueKeysWithValues: proposal.objects.map {
            (VaultObjectReference(id: $0.attachment.id, kind: .attachment), $0)
        })
        let orderedReferences = catalog.reachableObjectReferences
        guard orderedReferences.count <= Self.maximumObjectCount else {
            throw VaultError.resourceLimitExceeded
        }
        let metadata = try orderedReferences.map { reference in
            if let object = objectByReference[reference] {
                return PlaintextVaultObjectMetadata(
                    reference: reference,
                    byteCount: object.attachment.byteCount,
                    sha256Digest: object.attachment.sha256Digest
                )
            }
            if reference == indexReference {
                return PlaintextVaultObjectMetadata(
                    reference: reference,
                    byteCount: indexData.count,
                    sha256Digest: ContentDigest.sha256(indexData)
                )
            }
            guard let existing = currentMetadata[reference] else {
                throw VaultError.invalidCatalog
            }
            return existing
        }
        try validateObjectMetadata(metadata, for: catalog)
        try validateDICOMIndexes(
            catalog: catalog,
            metadata: metadata,
            writes: [indexReference: indexWrite]
        )
        let manifest = try makeManifest(catalog: catalog, objects: metadata)
        let manifestData = try encodeCheckedManifest(manifest)

        try dicomImportJournal.verifyOwnership(
            operationID: session.operationID,
            vaultID: current.catalog.vaultID,
            ownership: session.stagingOwnership
        )
        let orderedObjects = proposal.objects.sorted(by: {
            $0.attachment.id.uuidString.lowercased() < $1.attachment.id.uuidString.lowercased()
        })
        try dicomImportJournal.recordPromotions(
            orderedObjects.map {
                VaultObjectReference(id: $0.attachment.id, kind: .attachment)
            } + [indexReference],
            operationID: session.operationID
        )
        try failIfRequested(.afterDICOMJournalRecord)
        for object in orderedObjects {
            let reference = VaultObjectReference(id: object.attachment.id, kind: .attachment)
            await metrics?.recordStagingDescriptorsOpened(4)
            do {
                try staging.withRawDescriptor(object.staged) { descriptor in
                    try files.writeImmutable(
                        copyingFrom: descriptor,
                        expectedByteCount: object.attachment.byteCount,
                        expectedSHA256: object.attachment.sha256Digest,
                        relativePath: layout.objectPath(reference)
                    )
                }
            } catch {
                await metrics?.recordStagingDescriptorsClosed(4)
                throw error
            }
            await metrics?.recordStagingDescriptorsClosed(4)
            await metrics?.recordAttachmentPromotion(
                digest: object.attachment.sha256Digest,
                byteCount: object.attachment.byteCount
            )
            try failIfRequested(.afterDICOMAttachmentPromotion)
        }
        try writeObjectIdempotently(indexWrite)
        await metrics?.recordIndexPromotion(byteCount: indexData.count)
        try failIfRequested(.afterDICOMIndexPromotion)
        try failIfRequested(.afterObjects)

        try files.replaceAtomically(manifestData, relativePath: layout.manifestPath)
        try failIfRequested(.afterManifestCommit)
        _ = try? dicomImportJournal.reconcile(
            vaultID: catalog.vaultID,
            retaining: Set(metadata.map(\.reference))
        )
        try? retireOrphanedObjects(
            retaining: Set(metadata.map(\.reference)),
            tolerateRemovalFailures: true
        )
        session.release()
        return .accepted(catalog, try head(for: manifest), proposal.study.id)
    }

    public func destroy() async throws {
        mutationCoordinator.invalidateDICOMSliceLifecycle()
        let lease = try await mutationCoordinator.acquire()
        defer { lease.release() }

        try prepareForVaultAccess()
        switch try files.rootState() {
        case .absent:
            return
        case .empty:
            break
        case .nonempty:
            guard files.exists(relativePath: layout.manifestPath) else {
                throw VaultError.partialInitialization
            }
            _ = try resolveManifest(cleanupOrphans: false, verifyAllObjects: true)
        }
        if files.exists(relativePath: layout.legacyEncryptedMarkerPath) {
            throw VaultError.legacyEncryptedVault
        }
        guard try files.rootState() != .absent else { return }
        try deletionTransaction.begin()
    }

    private func resolveManifest(
        cleanupOrphans: Bool,
        verifyAllObjects: Bool = false,
        reconcileDICOMImports: Bool = true,
        cleanupTemporaryFiles: Bool = true
    ) throws -> PlaintextVaultManifest {
        try resolveManifestResolution(
            cleanupOrphans: cleanupOrphans,
            verifyAllObjects: verifyAllObjects,
            reconcileDICOMImports: reconcileDICOMImports,
            cleanupTemporaryFiles: cleanupTemporaryFiles,
            retainingDICOMIndexFor: nil
        ).manifest
    }

    private func resolveManifest(
        cleanupOrphans: Bool,
        retainingDICOMIndexFor studyID: DICOMStudy.ID
    ) throws -> PlaintextVaultManifestResolution {
        try resolveManifestResolution(
            cleanupOrphans: cleanupOrphans,
            verifyAllObjects: false,
            reconcileDICOMImports: true,
            cleanupTemporaryFiles: true,
            retainingDICOMIndexFor: studyID
        )
    }

    private func resolveManifestResolution(
        cleanupOrphans: Bool,
        verifyAllObjects: Bool,
        reconcileDICOMImports: Bool,
        cleanupTemporaryFiles: Bool,
        retainingDICOMIndexFor requestedStudyID: DICOMStudy.ID?
    ) throws -> PlaintextVaultManifestResolution {
        manifestResolutionObserver()
        if files.exists(relativePath: layout.legacyEncryptedMarkerPath) {
            throw VaultError.legacyEncryptedVault
        }
        guard files.exists(relativePath: layout.manifestPath) else {
            throw VaultError.vaultMissing
        }
        let manifestData = try files.read(
            relativePath: layout.manifestPath,
            maximumByteCount: Self.maximumManifestByteCount
        )
        let probe: PlaintextVaultCatalogVersionProbe
        do {
            probe = try CanonicalVaultJSON.decode(
                PlaintextVaultCatalogVersionProbe.self,
                from: manifestData
            )
        } catch {
            throw VaultError.invalidCatalog
        }
        guard probe.catalog.formatVersion == VaultCatalog.currentFormatVersion else {
            throw VaultError.unsupportedVersion(probe.catalog.formatVersion)
        }
        let manifest = try decode(PlaintextVaultManifest.self, from: manifestData)
        let catalog = try Self.validatedCatalog(in: manifest)
        guard manifest.objects.count <= Self.maximumObjectCount else {
            throw VaultError.resourceLimitExceeded
        }
        let sortedObjects = manifest.objects.sorted(by: Self.metadataPrecedes)
        guard manifest.objects == sortedObjects,
              Set(manifest.objects.map(\.reference)).count == manifest.objects.count,
              Set(manifest.objects.map(\.reference))
                == Set(catalog.reachableObjectReferences) else {
            throw VaultError.invalidCatalog
        }
        try validateObjectMetadata(manifest.objects, for: catalog)
        try validateObjectPresence(manifest.objects)
        let retainedDICOMIndex = try validateDICOMIndexes(
            catalog: catalog,
            metadata: manifest.objects,
            writes: [:],
            retainingIndexFor: requestedStudyID
        )
        if verifyAllObjects {
            try validateObjects(manifest.objects)
            try validateOCRProvenance(in: manifest)
        }
        if reconcileDICOMImports {
            _ = try? dicomImportJournal.reconcile(
                vaultID: catalog.vaultID,
                retaining: Set(manifest.objects.map(\.reference))
            )
        }
        if cleanupTemporaryFiles {
            try cleanupRecognizedTemporaryFiles()
        }
        if cleanupOrphans {
            try retireOrphanedObjects(
                retaining: Set(manifest.objects.map(\.reference)),
                tolerateRemovalFailures: true
            )
        }
        return PlaintextVaultManifestResolution(
            manifest: manifest,
            retainedDICOMIndex: retainedDICOMIndex
        )
    }

    private func makeManifest(
        catalog: VaultCatalog,
        objects: [PlaintextVaultObjectMetadata]
    ) throws -> PlaintextVaultManifest {
        let sortedObjects = objects.sorted(by: Self.metadataPrecedes)
        return PlaintextVaultManifest(
            magic: Self.manifestMagic,
            formatVersion: Self.currentFormatVersion,
            commitID: UUID(),
            catalogSHA256: ContentDigest.sha256(try encode(catalog)),
            catalog: catalog,
            objects: sortedObjects
        )
    }

    private func head(for manifest: PlaintextVaultManifest) throws -> VaultRevision {
        try VaultRevision(
            generation: manifest.catalog.generation,
            commitID: manifest.commitID,
            catalogDigest: manifest.catalogSHA256
        )
    }

    private func manifestIdentity() throws -> PlaintextVaultManifestIdentity {
        try files.withRegularFileDescriptor(relativePath: layout.manifestPath) { descriptor in
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0,
                  (metadata.st_mode & S_IFMT) == S_IFREG else {
                throw VaultError.ioFailure(errno)
            }
            return PlaintextVaultManifestIdentity(metadata)
        }
    }

    private func validateObjects(_ metadata: [PlaintextVaultObjectMetadata]) throws {
        for entry in metadata {
            _ = try readAndValidateObject(entry)
        }
    }

    private func validateOCRProvenance(in manifest: PlaintextVaultManifest) throws {
        let sourcesByDocumentID = Dictionary(uniqueKeysWithValues:
            manifest.catalog.importDrafts.compactMap { draft in
                draft.documentObjectID.map { ($0, draft.sources) }
            } + manifest.catalog.records.compactMap { record in
                record.ocrDocumentObjectID.map { ($0, record.sources) }
            }
        )
        for (documentID, sources) in sourcesByDocumentID {
            guard let metadata = manifest.objects.first(where: {
                $0.reference == VaultObjectReference(id: documentID, kind: .ocr)
            }) else { throw VaultError.objectMissing }
            do {
                let document = try CanonicalVaultJSON.decode(
                    ImportDraftDocument.self,
                    from: readAndValidateObject(metadata)
                )
                _ = try document.attributedAndValidated(for: sources)
            } catch let error as VaultError {
                throw error
            } catch {
                throw VaultError.invalidCatalog
            }
        }
    }

    private func validateObjectPresence(_ metadata: [PlaintextVaultObjectMetadata]) throws {
        for entry in metadata {
            try files.validateRegularFile(
                relativePath: layout.objectPath(entry.reference),
                expectedByteCount: entry.byteCount
            )
        }
    }

    private func validateObjectMetadata(
        _ metadata: [PlaintextVaultObjectMetadata],
        for catalog: VaultCatalog
    ) throws {
        let attachments = Dictionary(uniqueKeysWithValues: catalog.attachments.map { ($0.id, $0) })
        for entry in metadata {
            guard entry.byteCount >= 0,
                  entry.byteCount <= maximumByteCount(for: entry.reference.kind),
                  entry.sha256Digest.count == 32 else {
                throw VaultError.resourceLimitExceeded
            }
            if entry.reference.kind == .attachment {
                guard let attachment = attachments[entry.reference.id],
                      entry.byteCount == attachment.byteCount,
                      entry.sha256Digest == attachment.sha256Digest else {
                    throw VaultError.integrityCheckFailed
                }
            }
        }
    }

    /// The catalog is the reachability authority, but the separately stored
    /// index is the order authority. Reopen and commit both prove their graph
    /// closes before a DICOM study can be exposed or new objects are written.
    @discardableResult
    private func validateDICOMIndexes(
        catalog: VaultCatalog,
        metadata: [PlaintextVaultObjectMetadata],
        writes: [VaultObjectReference: VaultObjectWrite],
        retainingIndexFor requestedStudyID: DICOMStudy.ID? = nil
    ) throws -> DICOMStudyIndex? {
        let metadataByReference = Dictionary(
            uniqueKeysWithValues: metadata.map { ($0.reference, $0) }
        )
        let retainedAttachmentIDs = Set(catalog.dicomStudies.flatMap(\.attachmentIDs))
        try PlaintextVaultResourcePolicy.validateDICOMRetainedObjectCount(
            retainedAttachmentIDs.count
        )
        var seriesCount = 0
        var studyUIDDigests = Set<DICOMStudyIndex.UIDDigest>()
        var retainedIndex: DICOMStudyIndex?
        for study in catalog.dicomStudies {
            let reference = VaultObjectReference(id: study.indexObjectID, kind: .record)
            let data: Data
            if let write = writes[reference] {
                guard write.plaintext.count <= PlaintextVaultResourcePolicy.maximumByteCount(
                    for: .record
                ) else { throw VaultError.resourceLimitExceeded }
                data = write.plaintext
            } else {
                guard let entry = metadataByReference[reference] else {
                    throw VaultError.invalidCatalog
                }
                data = try readAndValidateObject(entry)
            }
            let index = try decode(DICOMStudyIndex.self, from: data)
            do { try DICOMSeriesGeometry.validatePersistedGeometryOrder(index) }
            catch { throw VaultError.invalidCatalog }
            guard studyUIDDigests.insert(index.studyUIDDigest).inserted else {
                throw VaultError.invalidCatalog
            }
            do {
                try index.validate(
                    studyID: study.id,
                    attachmentIDs: Set(study.attachmentIDs)
                )
            } catch {
                throw VaultError.invalidCatalog
            }
            seriesCount = try PlaintextVaultResourcePolicy.addingDICOMSeriesCount(
                seriesCount,
                adding: index.series.count
            )
            if study.id == requestedStudyID { retainedIndex = index }
        }
        return retainedIndex
    }

    private func validateDICOMStudyEvolution(
        from current: VaultCatalog,
        to proposed: VaultCatalog,
        removedStudyIDs: Set<DICOMStudy.ID> = []
    ) throws {
        let currentByID = Dictionary(uniqueKeysWithValues: current.dicomStudies.map {
            ($0.id, $0)
        })
        let proposedIDs = Set(proposed.dicomStudies.map(\.id))
        let removedIDs = Set(currentByID.keys).subtracting(proposedIDs)
        guard removedIDs == removedStudyIDs,
              proposedIDs.isDisjoint(with: removedStudyIDs) else {
            throw VaultError.invalidCatalog
        }
        for study in proposed.dicomStudies {
            guard let prior = currentByID[study.id] else { continue }
            guard prior.fingerprint == study.fingerprint,
                  prior.indexObjectID == study.indexObjectID,
                  prior.attachmentIDs == study.attachmentIDs,
                  !(prior.state == .confirmed && study.state != .confirmed) else {
                throw VaultError.invalidCatalog
            }
        }
    }

    private func readAndValidateObject(_ metadata: PlaintextVaultObjectMetadata) throws -> Data {
        guard metadata.byteCount >= 0,
              metadata.byteCount <= maximumByteCount(for: metadata.reference.kind),
              metadata.sha256Digest.count == 32 else {
            throw VaultError.resourceLimitExceeded
        }
        let data = try files.read(
            relativePath: layout.objectPath(metadata.reference),
            maximumByteCount: metadata.byteCount
        )
        guard data.count == metadata.byteCount,
              ContentDigest.sha256(data) == metadata.sha256Digest else {
            throw VaultError.invalidDigest
        }
        return data
    }

    private nonisolated static func hashDICOMDescriptor(
        _ descriptor: Int32,
        expectedByteCount: Int
    ) throws -> Data {
        guard expectedByteCount > 0 else {
            throw DICOMSliceServiceError.integrityFailure
        }
        var hasher = SHA256()
        var offset = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while offset < expectedByteCount {
            let amount = min(buffer.count, expectedByteCount - offset)
            let readCount = buffer.withUnsafeMutableBytes { bytes in
                pread(descriptor, bytes.baseAddress, amount, off_t(offset))
            }
            if readCount < 0, errno == EINTR { continue }
            guard readCount > 0 else {
                throw DICOMSliceServiceError.integrityFailure
            }
            buffer.withUnsafeBytes { bytes in
                hasher.update(bufferPointer: UnsafeRawBufferPointer(
                    start: bytes.baseAddress,
                    count: readCount
                ))
            }
            offset += readCount
        }
        var extra: UInt8 = 0
        guard pread(descriptor, &extra, 1, off_t(expectedByteCount)) == 0 else {
            throw DICOMSliceServiceError.integrityFailure
        }
        return Data(hasher.finalize())
    }

    private func writeObjectIdempotently(_ write: VaultObjectWrite) throws {
        let path = layout.objectPath(write.reference)
        if files.exists(relativePath: path) {
            let existing = try files.read(
                relativePath: path,
                maximumByteCount: maximumByteCount(for: write.reference.kind)
            )
            guard existing == write.plaintext else {
                throw VaultError.objectAlreadyExists
            }
            return
        }
        guard write.plaintext.count <= maximumByteCount(for: write.reference.kind) else {
            throw VaultError.resourceLimitExceeded
        }
        try files.writeImmutable(write.plaintext, relativePath: path)
    }

    private func validateAttachmentWrites(
        _ writes: [VaultObjectWrite],
        catalog: VaultCatalog
    ) throws {
        let attachments = Dictionary(uniqueKeysWithValues: catalog.attachments.map { ($0.id, $0) })
        for write in writes where write.reference.kind == .attachment {
            guard let attachment = attachments[write.reference.id],
                  write.plaintext.count == attachment.byteCount,
                  ContentDigest.sha256(write.plaintext) == attachment.sha256Digest else {
                throw VaultError.integrityCheckFailed
            }
        }
    }

    private func retireOrphanedObjects(
        retaining references: Set<VaultObjectReference>,
        tolerateRemovalFailures: Bool
    ) throws {
        let retainedPaths = Set(references.map(layout.objectPath))
        let managedPaths = try files.listRegularFiles(relativeDirectory: "objects")
            .filter { layout.objectReference(at: $0) != nil }
            .sorted()
        for path in managedPaths where !retainedPaths.contains(path) {
            do {
                try files.remove(relativePath: path)
            } catch {
                if !tolerateRemovalFailures { throw error }
            }
        }
    }

    private func prepareForVaultAccess() throws {
        _ = try deletionTransaction.reconcile()
        if files.exists(relativePath: layout.legacyEncryptedMarkerPath) {
            throw VaultError.legacyEncryptedVault
        }
        _ = try initializationTransaction.reconcile()
        if files.exists(relativePath: layout.legacyEncryptedMarkerPath) {
            throw VaultError.legacyEncryptedVault
        }
    }

    /// Temporary names are reclaimed only after a valid manifest and its
    /// complete object graph have identified this directory as our vault.
    /// A name alone is never enough authority to mutate an unknown layout.
    private func cleanupRecognizedTemporaryFiles() throws {
        try files.removeRecognizedTemporaryFiles(relativeDirectory: "")
        for kind in VaultObjectKind.allCases {
            try files.removeRecognizedTemporaryFiles(
                relativeDirectory: "objects/\(kind.storageComponent)"
            )
        }
    }

    private func encodeCheckedManifest(_ manifest: PlaintextVaultManifest) throws -> Data {
        guard manifest.objects.count <= Self.maximumObjectCount else {
            throw VaultError.resourceLimitExceeded
        }
        let data = try encode(manifest)
        try PlaintextVaultResourcePolicy.validateManifestByteCount(data.count)
        return data
    }

    static func metadataPrecedes(
        _ lhs: PlaintextVaultObjectMetadata,
        _ rhs: PlaintextVaultObjectMetadata
    ) -> Bool {
        if lhs.reference.kind.rawValue != rhs.reference.kind.rawValue {
            return lhs.reference.kind.rawValue < rhs.reference.kind.rawValue
        }
        return lhs.reference.id.uuidString.lowercased()
            < rhs.reference.id.uuidString.lowercased()
    }

    static func stagingPath(
        intentID: LANArchiveIntent.ID,
        attachmentID: Attachment.ID
    ) -> String {
        "lan-submission-staging/\(intentID.uuidString.lowercased())/"
            + "\(attachmentID.uuidString.lowercased()).data"
    }

    /// Validates the catalog-bearing portion of a manifest without opening
    /// any referenced object. Root-scoped stores use this same check while
    /// binding their independent state to the current vault generation.
    static func validatedCatalog(in manifest: PlaintextVaultManifest) throws -> VaultCatalog {
        guard manifest.magic == manifestMagic else {
            throw VaultError.partialInitialization
        }
        guard manifest.formatVersion == currentFormatVersion else {
            throw VaultError.unsupportedVersion(manifest.formatVersion)
        }
        let catalog = try manifest.catalog.validated()
        let canonicalCatalog: Data
        do {
            canonicalCatalog = try CanonicalVaultJSON.encode(catalog)
        } catch {
            throw VaultError.invalidCatalog
        }
        guard manifest.catalogSHA256.count == 32,
              ContentDigest.sha256(canonicalCatalog) == manifest.catalogSHA256 else {
            throw VaultError.invalidDigest
        }
        return catalog
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        do {
            return try CanonicalVaultJSON.encode(value)
        } catch {
            throw VaultError.invalidCatalog
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try CanonicalVaultJSON.decode(type, from: data)
        } catch {
            throw VaultError.invalidCatalog
        }
    }

    private func maximumByteCount(for kind: VaultObjectKind) -> Int {
        PlaintextVaultResourcePolicy.maximumByteCount(for: kind)
    }

    private func failIfRequested(_ point: PlaintextVaultTransactionFault) throws {
        if transactionFailureInjector?(point) == true {
            throw VaultError.injectedFailure
        }
    }

    func backupSnapshot(
        using lease: VaultMutationLease
    ) throws -> PlaintextVaultBackupSnapshot {
        try mutationCoordinator.withValidatedLease(lease) {
            try prepareForVaultAccess()
            let manifest = try resolveManifest(cleanupOrphans: true)
            let manifestBytes = try files.read(
                relativePath: layout.manifestPath,
                maximumByteCount: Self.maximumManifestByteCount
            )
            guard try encodeCheckedManifest(manifest) == manifestBytes else {
                throw VaultError.invalidCatalog
            }
            let root = try VaultRootBinding(rootURL: layout.rootURL).probe()
            guard root.vaultID == manifest.catalog.vaultID else {
                throw VaultError.invalidCatalog
            }
            return PlaintextVaultBackupSnapshot(
                root: root,
                manifestIdentity: try manifestIdentity(),
                revision: try head(for: manifest),
                files: [PlaintextLibraryBackupFile(
                    kind: .vaultCatalog,
                    relativePath: layout.manifestPath,
                    byteCount: UInt64(manifestBytes.count),
                    digest: ContentDigest.sha256(manifestBytes)
                )] + manifest.objects.map { metadata in
                    PlaintextLibraryBackupFile(
                        kind: .vaultObject,
                        relativePath: layout.objectPath(metadata.reference),
                        byteCount: UInt64(metadata.byteCount),
                        digest: metadata.sha256Digest
                    )
                }
            )
        }
    }

    func validateBackupSnapshot(
        _ snapshot: PlaintextVaultBackupSnapshot,
        using lease: VaultMutationLease
    ) throws {
        try mutationCoordinator.withValidatedLease(lease) {
            let currentRoot = try VaultRootBinding(rootURL: layout.rootURL).probe()
            guard currentRoot == snapshot.root,
                  try manifestIdentity() == snapshot.manifestIdentity else {
                throw VaultError.mutationConflict
            }
        }
    }

    /// Restore validation is intentionally read-only: it neither consumes
    /// initialization/deletion receipts nor repairs journals, temporary files,
    /// or orphaned objects. A checkpoint missing any committed object cannot
    /// become valid through the ordinary startup reconciliation path.
    func strictRestoreValidation() async throws -> PlaintextVaultRestoreValidation {
        let lease = try await mutationCoordinator.acquire()
        defer { lease.release() }
        return try strictRestoreValidation(using: lease)
    }

    func strictRestoreValidation(
        using lease: VaultMutationLease
    ) throws -> PlaintextVaultRestoreValidation {
        try mutationCoordinator.withValidatedLease(lease) {}
        guard try files.rootState() == .nonempty else { throw VaultError.vaultMissing }
        let manifest = try resolveManifest(
            cleanupOrphans: false,
            verifyAllObjects: true,
            reconcileDICOMImports: false,
            cleanupTemporaryFiles: false
        )
        let manifestBytes = try files.read(
            relativePath: layout.manifestPath,
            maximumByteCount: Self.maximumManifestByteCount
        )
        guard try encodeCheckedManifest(manifest) == manifestBytes else {
            throw VaultError.invalidCatalog
        }
        let root = try VaultRootBinding(rootURL: layout.rootURL).probe()
        guard root.vaultID == manifest.catalog.vaultID else {
            throw VaultError.invalidCatalog
        }
        try mutationCoordinator.withValidatedLease(lease) {}
        return PlaintextVaultRestoreValidation(
            vaultID: manifest.catalog.vaultID,
            revision: try head(for: manifest),
            memberCount: manifest.catalog.members.count,
            recordCount: manifest.catalog.records.count
        )
    }
}

struct PlaintextVaultRestoreValidation: Sendable {
    let vaultID: UUID
    let revision: VaultRevision
    let memberCount: Int
    let recordCount: Int
}
