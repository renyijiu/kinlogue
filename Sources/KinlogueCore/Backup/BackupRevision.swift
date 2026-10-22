import Foundation

public enum BackupContractError: Error, Equatable, Sendable {
    case invalidMagic
    case unsupportedVersion
    case unsupportedSuite
    case unsupportedRole
    case invalidIdentifier
    case invalidField
    case invalidLength
    case duplicateEntry
    case nonCanonicalOrdering
    case arithmeticOverflow
    case resourceLimit
    case trailingBytes
}

public struct BackupRevision: Hashable, Sendable {
    public let generation: UInt64
    public let commitID: UUID
    public let manifestDigest: Data

    public init(generation: UInt64, commitID: UUID, manifestDigest: Data) throws {
        guard generation > 0, manifestDigest.count == 32 else {
            throw BackupContractError.invalidField
        }
        self.generation = generation
        self.commitID = commitID
        self.manifestDigest = manifestDigest
    }
}

public struct BackupRevisionPair: Hashable, Sendable {
    public let vault: BackupRevision
    public let lanInbox: BackupRevision

    public init(vault: BackupRevision, lanInbox: BackupRevision) throws {
        self.vault = vault
        self.lanInbox = lanInbox
    }

    public init(vault: VaultRevision, lanInbox: LANInboxRevision) throws {
        try self.init(
            vault: .init(
                generation: vault.generation,
                commitID: vault.commitID,
                manifestDigest: vault.catalogDigest
            ),
            lanInbox: .init(
                generation: lanInbox.generation,
                commitID: lanInbox.commitID,
                manifestDigest: lanInbox.manifestDigest
            )
        )
    }
}
