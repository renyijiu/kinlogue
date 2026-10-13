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

public enum VaultReadSnapshotPolicy {
    public static let maximumObjectCount = 32
    public static let maximumRetainedByteCount = 128 * 1024 * 1024
}

public protocol VaultDestroyServicing: Sendable {
    func destroyCurrentVault() async throws
}
