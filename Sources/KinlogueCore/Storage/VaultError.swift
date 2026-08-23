import Foundation

public enum VaultError: Error, Equatable, Sendable {
    case invalidDigest
    case invalidGeneration
    case unsupportedVersion(Int)
    case integrityCheckFailed
    case invalidCatalog
    case invalidPath
    case resourceLimitExceeded
    case objectAlreadyExists
    case objectMissing
    case vaultMissing
    case partialInitialization
    case legacyEncryptedVault
    case vaultIDMismatch
    case mutationConflict
    case ioFailure(Int32)
    case injectedFailure
}
