import Foundation

/// Stable codes for why a backup did not finish. They are persisted and localized, and never
/// carry a path, a name or health content.
public enum BackupFailure: String, Codable, CaseIterable, Error, Hashable, Sendable {
    case notConfigured
    /// The folder is not reachable right now (disk not connected, network share offline).
    case folderUnavailable
    /// The folder's access grant no longer works or it was replaced; choose it again.
    case folderNeedsReselection
    case capacityInsufficient
    case resourceLimitExceeded
    case sourceChanged
    case libraryUnreadable
    case verificationFailed
    case publicationIndeterminate
    case operationInProgress

    /// Worth an automatic retry: the cause is expected to go away by itself.
    public var isRecoverable: Bool {
        self == .sourceChanged || self == .folderUnavailable
    }
}
