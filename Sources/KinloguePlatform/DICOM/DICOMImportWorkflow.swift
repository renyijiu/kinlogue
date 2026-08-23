import Foundation
import KinlogueCore

public struct DICOMImportResult: Equatable, Sendable {
    public let studyID: DICOMStudy.ID
    public let wasExisting: Bool
    public let viewableInstanceCount: Int
    public let inertObjectCount: Int
    public let ignoredNonDICOMCount: Int
    public let ignoredDuplicateCount: Int
}

/// Orchestrates scan → opaque staging → staged-byte indexing → one manifest
/// publication. It never hands a user source URL to the decoder or persists it.
public actor DICOMImportWorkflow {
    public private(set) var state: DICOMImportState = .ready

    private let rootURL: URL
    private let vault: PlaintextVault
    private let decoder: any DICOMFrameDecoding
    private let policy: DICOMImportPolicy
    private let metrics: DICOMImportMetricsRecorder?
    private let scannerControl: (any DICOMFolderScannerControl)?
    private let availableCapacityProvider: VaultDICOMStudyStaging.AvailableCapacityProvider
    private var currentTask: Task<DICOMImportResult, Error>?
    private var currentOperationID: UUID?

    public init(
        rootURL: URL,
        vault: PlaintextVault,
        decoder: any DICOMFrameDecoding = DICOMDecoderAdapter(),
        policy: DICOMImportPolicy = .default,
        metrics: DICOMImportMetricsRecorder? = nil
    ) throws {
        try self.init(
            rootURL: rootURL,
            vault: vault,
            decoder: decoder,
            policy: policy,
            metrics: metrics,
            scannerControl: nil,
            availableCapacityProvider: VaultDICOMStudyStaging.systemAvailableCapacity
        )
    }

    init(
        rootURL: URL,
        vault: PlaintextVault,
        decoder: any DICOMFrameDecoding,
        policy: DICOMImportPolicy = .default,
        metrics: DICOMImportMetricsRecorder?,
        scannerControl: (any DICOMFolderScannerControl)?,
        availableCapacityProvider: @escaping VaultDICOMStudyStaging.AvailableCapacityProvider =
            VaultDICOMStudyStaging.systemAvailableCapacity
    ) throws {
        self.rootURL = try PlaintextVaultLayout(rootURL: rootURL).rootURL
        self.vault = vault
        self.decoder = decoder
        self.policy = policy
        self.metrics = metrics
        self.scannerControl = scannerControl
        self.availableCapacityProvider = availableCapacityProvider
    }

    public func importDirectory(
        _ directoryURL: URL,
        securityScope: DICOMSecurityScopeRequirement = .required
    ) async throws -> DICOMImportResult {
        guard currentTask == nil else { throw DICOMImportError.publicationConflict }
        if state == .completed || state == .failed || state == .cancelled {
            transition(to: .ready)
        }
        transition(to: .scanning)
        let rootURL = self.rootURL
        let vault = self.vault
        let decoder = self.decoder
        let policy = self.policy
        let metrics = self.metrics
        let scannerControl = self.scannerControl
        let availableCapacityProvider = self.availableCapacityProvider
        let operationID = UUID()
        let operation = Task<DICOMImportResult, Error> { [self] in
            try await Self.performImport(
                operationID: operationID,
                directoryURL: directoryURL,
                securityScope: securityScope,
                rootURL: rootURL,
                vault: vault,
                decoder: decoder,
                policy: policy,
                metrics: metrics,
                scannerControl: scannerControl,
                availableCapacityProvider: availableCapacityProvider,
                reportPhase: { phase in await self.advance(to: phase) }
            )
        }
        currentTask = operation
        currentOperationID = operationID
        do {
            let result = try await operation.value
            finishSuccess(operationID: operationID)
            return result
        } catch {
            let terminalError = Self.normalizedTerminalError(error)
            finishFailure(operationID: operationID, error: terminalError)
            throw terminalError
        }
    }

    public func cancelCurrentImport() async throws -> DICOMImportResult? {
        guard let currentTask, let currentOperationID else { return nil }
        if state != .cancelling { transition(to: .cancelling) }
        currentTask.cancel()
        do {
            let result = try await currentTask.value
            finishSuccess(operationID: currentOperationID)
            return result
        } catch {
            let terminalError = Self.normalizedTerminalError(error)
            finishFailure(operationID: currentOperationID, error: terminalError)
            if terminalError as? DICOMImportError == .cancelled { return nil }
            throw terminalError
        }
    }

    public func reset() throws {
        guard currentTask == nil, state == .completed || state == .failed || state == .cancelled else {
            throw DICOMImportStateError.invalidTransition
        }
        transition(to: .ready)
    }

    private func advance(to next: DICOMImportState) {
        guard state != .cancelling, state != .cancelled, state != .failed else { return }
        transition(to: next)
    }

    private func transition(to next: DICOMImportState) {
        do {
            state = try state.transitioning(to: next)
        } catch {
            preconditionFailure("Invalid DICOM import state transition")
        }
    }

    private func finishSuccess(operationID: UUID) {
        guard currentOperationID == operationID else { return }
        transition(to: .completed)
        currentTask = nil
        currentOperationID = nil
    }

    private func finishFailure(operationID: UUID, error: Error) {
        guard currentOperationID == operationID else { return }
        if error as? DICOMImportError == .cancelled {
            if state != .cancelling { transition(to: .cancelling) }
            transition(to: .cancelled)
        } else {
            transition(to: .failed)
        }
        currentTask = nil
        currentOperationID = nil
    }

    private nonisolated static func normalizedTerminalError(_ error: Error) -> Error {
        error is CancellationError ? DICOMImportError.cancelled : error
    }

    private nonisolated static func performImport(
        operationID: UUID,
        directoryURL: URL,
        securityScope: DICOMSecurityScopeRequirement,
        rootURL: URL,
        vault: PlaintextVault,
        decoder: any DICOMFrameDecoding,
        policy: DICOMImportPolicy,
        metrics: DICOMImportMetricsRecorder?,
        scannerControl: (any DICOMFolderScannerControl)?,
        availableCapacityProvider: @escaping VaultDICOMStudyStaging.AvailableCapacityProvider,
        reportPhase: @escaping @Sendable (DICOMImportState) async -> Void
    ) async throws -> DICOMImportResult {
        let staging = try VaultDICOMStudyStaging(
            rootURL: rootURL,
            policy: policy,
            availableCapacityProvider: availableCapacityProvider
        )
        let session: DICOMVaultImportSession
        do {
            session = try await vault.beginDICOMImport(
                operationID: operationID,
                staging: staging
            )
        } catch {
            if Task.isCancelled { throw DICOMImportError.cancelled }
            throw error
        }
        var sessionIsActive = true
        do {
            let scan = try await DICOMFolderScanner(
                policy: policy,
                metrics: metrics,
                control: scannerControl
            ).scan(
                directoryURL: directoryURL,
                operationID: operationID,
                securityScope: securityScope,
                staging: staging,
                ownership: session.stagingOwnership,
                willBeginStaging: { await reportPhase(.staging) }
            )
            if Task.isCancelled { throw DICOMImportError.cancelled }
            await reportPhase(.indexing)
            let proposal = try await DICOMStudyIndexer(
                decoder: decoder,
                policy: policy,
                metrics: metrics
            ).index(
                stagedObjects: scan.stagedObjects,
                vaultID: session.vaultID,
                staging: staging
            )
            let proposedResult = DICOMImportResult(
                studyID: proposal.study.id,
                wasExisting: false,
                viewableInstanceCount: proposal.index.instances.count,
                inertObjectCount: proposal.index.retainedObjects.filter {
                    $0.kind == .inertAttachment
                }.count,
                ignoredNonDICOMCount: scan.ignoredNonDICOMCount,
                ignoredDuplicateCount: scan.ignoredDuplicateCount
                    + proposal.ignoredDuplicateCount
            )
            if Task.isCancelled { throw DICOMImportError.cancelled }
            await reportPhase(.committing)
            let outcome: VaultDICOMStudyCommitOutcome
            do {
                outcome = try await vault.commitStagedDICOMStudy(
                    proposal,
                    session: session,
                    staging: staging,
                    metrics: metrics
                )
            } catch {
                let commitError = error
                let terminalCatalog = try? await vault.loadDICOMImportTerminalCatalog(session)
                var reconciliationError: Error?
                do {
                    try await vault.abortDICOMImport(session)
                } catch {
                    reconciliationError = error
                }
                sessionIsActive = false
                let recoveredCatalog: VaultCatalog?
                if let terminalCatalog {
                    recoveredCatalog = terminalCatalog
                } else {
                    recoveredCatalog = try? await vault.loadCatalog()
                }
                if let catalog = recoveredCatalog,
                   catalog.dicomStudies.contains(where: {
                       Self.matchesCommittedGraph($0, proposal: proposal.study)
                   }) {
                    return proposedResult
                }
                if let reconciliationError { throw reconciliationError }
                throw commitError
            }
            sessionIsActive = false
            switch outcome {
            case .accepted(_, _, let id):
                guard id == proposedResult.studyID else {
                    throw DICOMImportError.integrityFailure
                }
                return proposedResult
            case .duplicateExisting(_, _, let id):
                return DICOMImportResult(
                    studyID: id,
                    wasExisting: true,
                    viewableInstanceCount: proposedResult.viewableInstanceCount,
                    inertObjectCount: proposedResult.inertObjectCount,
                    ignoredNonDICOMCount: proposedResult.ignoredNonDICOMCount,
                    ignoredDuplicateCount: proposedResult.ignoredDuplicateCount
                )
            }
        } catch {
            let operationError = error
            let wasCancelled = operationError is CancellationError
                || operationError as? DICOMImportError == .cancelled
            if sessionIsActive {
                do {
                    try await vault.abortDICOMImport(session)
                } catch {
                    throw error
                }
            }
            if wasCancelled { throw DICOMImportError.cancelled }
            throw operationError
        }
    }

    nonisolated static func matchesCommittedGraph(
        _ committed: DICOMStudy,
        proposal: DICOMStudy
    ) -> Bool {
        committed.id == proposal.id
            && committed.fingerprint == proposal.fingerprint
            && committed.indexObjectID == proposal.indexObjectID
            && committed.attachmentIDs == proposal.attachmentIDs
    }
}
