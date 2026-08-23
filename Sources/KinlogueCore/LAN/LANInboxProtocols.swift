import Foundation

public enum LANInboxError: Error, Equatable, Sendable {
    case invalidModel
    case unsupportedVersion
    case invalidDisplayName
    case invalidDigest
    case invalidByteCount
    case invalidState
    case invalidReference
    case duplicateIdentifier
    case invalidRevision
    case staleRevision
    case invalidGeneration
    case arithmeticOverflow
    case resourceLimitExceeded
    case vaultUnavailable
    case vaultIDMismatch
    case integrityCheckFailed
    case mutationConflict
    case fileNotFound
    case receiptConflict
    case storageFailure
}

public enum LANInboxAccessState: Equatable, Sendable {
    case absent
    case operationInProgress
    case damaged
    case unsupportedVersion
    case ready(LANInboxRevision)
}

public protocol LANInboxRepository: Sendable {
    func inspect() async -> LANInboxAccessState
    func loadSnapshot() async throws -> LANInboxSnapshot
}
