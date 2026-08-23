import Foundation

public enum BackupCheckpointOrigin: String, CaseIterable, Hashable, Sendable {
    case manual
    case automatic
}

public struct BackupAutomationConfiguration: Hashable, Sendable {
    public let isAutomaticBackupEnabled: Bool
    public let retentionCount: BackupRetentionCount

    public init(
        isAutomaticBackupEnabled: Bool = false,
        retentionCount: BackupRetentionCount = .default
    ) {
        self.isAutomaticBackupEnabled = isAutomaticBackupEnabled
        self.retentionCount = retentionCount
    }
}

public enum BackupCloudPropagationStatus: String, CaseIterable, Hashable, Sendable {
    /// A verified local checkpoint never implies provider upload or another-device durability.
    case unknown
}

public enum BackupLocalCheckpointState: String, CaseIterable, Hashable, Sendable {
    case unavailable
    case verified
    case overdue
}

public enum BackupOperationKind: String, CaseIterable, Hashable, Sendable {
    case manualBackup
    case automaticBackup
    case recoveryCodeVerification
    case restore
    case retention
}

public enum BackupOperationPhase: String, CaseIterable, Hashable, Sendable {
    case idle
    case preflighting
    case readingSource
    case writingEncryptedCheckpoint
    case verifyingWork
    case committingPublication
    case verifyingFinal
    case completed
    case cancelled
    case failed
}

/// Stable error codes for state restoration and localization. These values never
/// carry a path, key, digest, recovery code, or health-record content.
public enum BackupSemanticError: String, CaseIterable, Error, Hashable, Sendable {
    case notConfigured
    case repositoryOffline
    case bookmarkNeedsReselection
    case identityNeedsEnrollment
    case repositoryIdentityConflict
    case repositoryHistoryFork
    case unsupportedFormat
    case authenticationFailed
    case sourceChanged
    case capacityInsufficient
    case resourceLimitExceeded
    case publicationIndeterminate
    case verificationFailed
    case retentionDeferred
    case operationInProgress
}

public enum BackupPublicVerificationRejection: String, CaseIterable, Hashable, Sendable {
    case corruptRecord
    case invalidMagic
    case unsupportedVersion
    case unsupportedSuite
    case descriptorInvalid
    case authorizationInvalid
    case signatureInvalid
    case footerInvalid
    case commitmentMismatch
    case differentBackupSet
}

public enum BackupPublicVerificationIndeterminate: String, CaseIterable, Hashable, Sendable {
    case unknownFile
    case workFile
    case placeholderUnavailable
    case materializationFailed
    case identityChanged
}

public enum BackupPublicVerification: Hashable, Sendable {
    /// The Platform verifier has validated the recovery-root descriptor, device
    /// authorization, checkpoint signature, complete footer, and exact byte
    /// commitment. This does not claim HPKE/AEAD or graph verification.
    case verified(BackupPublicCheckpoint)
    case rejected(BackupPublicVerificationRejection)
    case indeterminate(BackupPublicVerificationIndeterminate)
}

public enum BackupHistoryForkReason: String, CaseIterable, Hashable, Sendable {
    case duplicateCheckpointIdentity
    case sequenceRegression
    case sameSequenceDifferentCommitment
    case overlappingAuthorization
    case hiddenHistoryRevealed
    case unknownAuthorization
}

public enum BackupRepositoryHistory: Hashable, Sendable {
    case linear
    case fork(BackupHistoryForkReason)
}

public enum BackupObservationContinuity: String, CaseIterable, Hashable, Sendable {
    case proven
    case unknown
    case reset
}
