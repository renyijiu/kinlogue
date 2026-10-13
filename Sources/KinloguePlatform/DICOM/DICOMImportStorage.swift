import Foundation
import KinlogueCore

/// What one import owns between staging and its commit.
typealias DICOMImportSession = SQLiteDICOMImportSession

enum DICOMImportCommit: Sendable { case accepted(UUID), duplicateExisting(UUID) }

protocol DICOMImportStoring: Sendable {
    func beginImport(operationID: UUID, staging: DICOMStudyStaging) async throws -> DICOMImportSession
    func commitImport(_ proposal: DICOMIndexedStudyProposal, session: DICOMImportSession,
                      staging: DICOMStudyStaging, metrics: DICOMImportMetricsRecorder?) async throws -> DICOMImportCommit
    func abortImport(_ session: DICOMImportSession) async throws
    func committedImport(_ proposal: DICOMIndexedStudyProposal, session: DICOMImportSession) async throws -> DICOMImportCommit?
}
