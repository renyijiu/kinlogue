import Foundation

public enum VaultObjectKind: UInt8, Codable, CaseIterable, Hashable, Sendable {
    case catalog = 1
    case record = 2
    case attachment = 3
    case ocr = 4
    case thumbnail = 5
    case descriptor = 6
}

public struct VaultObjectReference: Codable, Hashable, Sendable {
    public let id: UUID
    public let kind: VaultObjectKind

    public init(id: UUID, kind: VaultObjectKind) {
        self.id = id
        self.kind = kind
    }
}

public struct VaultRevision: Codable, Equatable, Sendable {
    public let generation: UInt64
    public let commitID: UUID
    public let catalogDigest: Data

    public init(
        generation: UInt64,
        commitID: UUID,
        catalogDigest: Data
    ) throws {
        guard catalogDigest.count == 32 else {
            throw VaultError.invalidDigest
        }
        self.generation = generation
        self.commitID = commitID
        self.catalogDigest = catalogDigest
    }
}

public enum VaultAccessState: Equatable, Sendable {
    case absent
    case operationInProgress
    /// An earlier encrypted Kinlogue vault was found at this location.
    /// PlaintextVault deliberately never overwrites or migrates it implicitly.
    case legacyEncrypted
    case damaged
    case unsupportedVersion
    case ready(VaultRevision)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

public struct VaultObjectWrite: Equatable, Sendable {
    public let reference: VaultObjectReference
    public let plaintext: Data

    public init(reference: VaultObjectReference, plaintext: Data) {
        self.reference = reference
        self.plaintext = plaintext
    }
}

public enum VaultReadSnapshotPolicy {
    public static let maximumObjectCount = 32
    public static let maximumRetainedByteCount = 128 * 1024 * 1024
}

public struct VaultReadSnapshot: Sendable {
    public let catalog: VaultCatalog
    public let objects: [VaultObjectReference: Data]
    public let retainedByteCount: Int

    public init(
        catalog: VaultCatalog,
        objects: [VaultObjectReference: Data]
    ) throws {
        guard objects.count <= VaultReadSnapshotPolicy.maximumObjectCount else {
            throw VaultError.resourceLimitExceeded
        }
        var retainedByteCount = 0
        for data in objects.values {
            let next = retainedByteCount.addingReportingOverflow(data.count)
            guard !next.overflow,
                  next.partialValue <= VaultReadSnapshotPolicy.maximumRetainedByteCount else {
                throw VaultError.resourceLimitExceeded
            }
            retainedByteCount = next.partialValue
        }
        self.catalog = catalog
        self.objects = objects
        self.retainedByteCount = retainedByteCount
    }

    public func data(for reference: VaultObjectReference) throws -> Data {
        guard let data = objects[reference] else { throw VaultError.objectMissing }
        return data
    }
}

public struct VaultCommitRequest: Equatable, Sendable {
    public let expectedGeneration: UInt64
    public let catalog: VaultCatalog
    public let writes: [VaultObjectWrite]
    public let removedDICOMStudyIDs: Set<DICOMStudy.ID>

    public init(
        expectedGeneration: UInt64,
        catalog: VaultCatalog,
        writes: [VaultObjectWrite],
        removedDICOMStudyIDs: Set<DICOMStudy.ID> = []
    ) throws {
        let successor = try VaultGeneration.successor(of: expectedGeneration)
        guard catalog.generation == successor else {
            throw VaultError.invalidGeneration
        }
        let references = writes.map(\.reference)
        guard Set(references).count == references.count else {
            throw VaultError.invalidCatalog
        }
        self.expectedGeneration = expectedGeneration
        self.catalog = catalog
        self.writes = writes
        self.removedDICOMStudyIDs = removedDICOMStudyIDs
    }
}

public enum VaultGeneration {
    public static func successor(of generation: UInt64) throws -> UInt64 {
        let successor = generation.addingReportingOverflow(1)
        guard !successor.overflow else { throw VaultError.invalidGeneration }
        return successor.partialValue
    }
}

public protocol VaultStore: Sendable {
    func inspect() async -> VaultAccessState
    /// Opens a ready Vault with full object verification and returns the
    /// catalog validated by that same pass.
    func loadValidatedCatalog() async throws -> VaultCatalog
    func initialize() async throws -> VaultCatalog
    func loadCatalog() async throws -> VaultCatalog
    func readObject(_ reference: VaultObjectReference) async throws -> Data
    /// Resolves one catalog generation, invokes `references` synchronously once,
    /// and returns only object bytes validated against that same generation.
    func readSnapshot(
        selecting references: @Sendable (VaultCatalog) throws
            -> [VaultObjectReference]
    ) async throws -> VaultReadSnapshot
    func commit(_ request: VaultCommitRequest) async throws -> VaultCatalog
    func destroy() async throws
}

public protocol VaultDestroyServicing: Sendable {
    func destroyCurrentVault() async throws
}

public extension VaultCatalog {
    func validated() throws -> Self {
        do {
            return try Self(
                formatVersion: formatVersion,
                vaultID: vaultID,
                generation: generation,
                members: members,
                records: records,
                attachments: attachments,
                importDrafts: importDrafts,
                dicomStudies: dicomStudies
            )
        } catch {
            throw VaultError.invalidCatalog
        }
    }
}
