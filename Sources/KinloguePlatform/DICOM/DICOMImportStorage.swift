import Foundation
import KinlogueCore

enum DICOMImportSession: Sendable {
    case legacy(DICOMVaultImportSession)
    case sqlite(SQLiteDICOMImportSession)
    var vaultID: UUID { switch self { case .legacy(let value): value.vaultID; case .sqlite(let value): value.libraryID } }
    var stagingOwnership: VaultDICOMStagingOwnership { switch self { case .legacy(let value): value.stagingOwnership; case .sqlite(let value): value.ownership } }
}

enum DICOMImportCommit: Sendable { case accepted(UUID), duplicateExisting(UUID) }

protocol DICOMImportStoring: Sendable {
    func beginImport(operationID: UUID, staging: VaultDICOMStudyStaging) async throws -> DICOMImportSession
    func commitImport(_ proposal: DICOMIndexedStudyProposal, session: DICOMImportSession,
                      staging: VaultDICOMStudyStaging, metrics: DICOMImportMetricsRecorder?) async throws -> DICOMImportCommit
    func abortImport(_ session: DICOMImportSession) async throws
    func committedImport(_ proposal: DICOMIndexedStudyProposal, session: DICOMImportSession) async throws -> DICOMImportCommit?
}

extension DICOMStudyHeader {
    func legacyStudy(indexObjectID: UUID) throws -> DICOMStudy {
        try DICOMStudy(id: id, state: state, fingerprint: fingerprint, indexObjectID: indexObjectID,
                       attachmentIDs: attachmentIDs, confirmedMemberID: confirmedMemberID, effectiveDate: effectiveDate)
    }
}

extension PlaintextVault: DICOMImportStoring {
    func beginImport(operationID: UUID, staging: VaultDICOMStudyStaging) async throws -> DICOMImportSession {
        .legacy(try await beginDICOMImport(operationID: operationID, staging: staging))
    }
    func commitImport(_ proposal: DICOMIndexedStudyProposal, session: DICOMImportSession,
                      staging: VaultDICOMStudyStaging, metrics: DICOMImportMetricsRecorder?) async throws -> DICOMImportCommit {
        guard case let .legacy(session) = session else { throw DICOMImportError.integrityFailure }
        switch try await commitStagedDICOMStudy(proposal, session: session, staging: staging, metrics: metrics) {
        case .accepted(_, _, let id): return .accepted(id)
        case .duplicateExisting(_, _, let id): return .duplicateExisting(id)
        }
    }
    func abortImport(_ session: DICOMImportSession) async throws {
        guard case let .legacy(session) = session else { throw DICOMImportError.integrityFailure }
        try await abortDICOMImport(session)
    }
    func committedImport(_ proposal: DICOMIndexedStudyProposal, session: DICOMImportSession) async throws -> DICOMImportCommit? {
        guard case let .legacy(session) = session else { throw DICOMImportError.integrityFailure }
        let catalog: VaultCatalog
        do { catalog = try await loadDICOMImportTerminalCatalog(session) }
        catch { catalog = try await loadCatalog() }
        let expected = try proposal.study.legacyStudy(indexObjectID: session.indexObjectID)
        return catalog.dicomStudies.contains { DICOMImportWorkflow.matchesCommittedGraph($0, proposal: expected) }
            ? .accepted(expected.id) : nil
    }
}
