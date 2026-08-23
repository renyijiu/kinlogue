import Foundation

/// Transient import progress. None of these phases is persisted in a
/// `DICOMStudy`; catalog publication creates a complete `.needsReview` study.
public enum DICOMImportState: String, Equatable, Sendable {
    case ready
    case scanning
    case staging
    case indexing
    case committing
    case cancelling
    case cancelled
    case completed
    case failed

    public func transitioning(to next: Self) throws -> Self {
        let allowed: Bool = switch (self, next) {
        case (.ready, .scanning),
             (.scanning, .staging),
             (.staging, .indexing),
             (.indexing, .committing),
             (.committing, .completed),
             (.cancelling, .cancelled),
             (.cancelling, .failed),
             // A cancellation request can race a manifest commit that has
             // already crossed its non-reversible point.
             (.cancelling, .completed),
             (.completed, .ready),
             (.failed, .ready),
             (.cancelled, .ready):
            true
        case (.scanning, .cancelling),
             (.staging, .cancelling),
             (.indexing, .cancelling),
             (.committing, .cancelling),
             (.scanning, .failed),
             (.staging, .failed),
             (.indexing, .failed),
             (.committing, .failed):
            true
        default:
            false
        }
        guard allowed else { throw DICOMImportStateError.invalidTransition }
        return next
    }
}

public enum DICOMImportStateError: Error, Equatable, Sendable {
    case invalidTransition
}

/// Stable, aggregate-only import failures. Associated source paths, file names,
/// raw UIDs and dependency errors are intentionally excluded.
public enum DICOMImportError: Error, Equatable, Sendable {
    case accessDenied
    case invalidDirectory
    case noDICOMObjects
    case invalidPart10
    case mixedStudy
    case unsupportedImage
    case corruptImage
    case sopInstanceConflict
    case resourceLimit
    case insufficientCapacity
    case sourceChanged
    case integrityFailure
    case decoderUnavailable
    case cancelled
    case publicationConflict
}
