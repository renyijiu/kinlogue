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

/// Orchestrates scan → opaque staging → staged-byte indexing → one graph
/// publication. It never hands a user source URL to the decoder or persists it.
public actor DICOMImportWorkflow {
    public private(set) var state: DICOMImportState = .ready

    private let rootURL: URL
    private let vault: any DICOMImportStoring
    private let decoder: any DICOMFrameDecoding
    private let policy: DICOMImportPolicy
    private let metrics: DICOMImportMetricsRecorder?
    private let scannerControl: (any DICOMFolderScannerControl)?
    private let availableCapacityProvider: VaultDICOMStudyStaging.AvailableCapacityProvider
    private var currentTask: Task<DICOMImportResult, Error>?
    private var currentOperationID: UUID?

    init(
        rootURL: URL,
        vault: any DICOMImportStoring,
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

    package init(repository: SQLiteDICOMRepository, decoder: any DICOMFrameDecoding = DICOMDecoderAdapter(),
                 policy: DICOMImportPolicy = .default, metrics: DICOMImportMetricsRecorder? = nil) throws {
        try self.init(rootURL: repository.store.rootURL, vault: repository, decoder: decoder,
                      policy: policy, metrics: metrics, scannerControl: nil)
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
        vault: any DICOMImportStoring,
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
        let session: DICOMImportSession
        do {
            session = try await vault.beginImport(
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
                ownership: session.ownership,
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
                vaultID: session.libraryID,
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
            let outcome: DICOMImportCommit
            do {
                outcome = try await vault.commitImport(
                    proposal,
                    session: session,
                    staging: staging,
                    metrics: metrics
                )
            } catch {
                let commitError = error
                let terminal = try? await vault.committedImport(proposal, session: session)
                var reconciliationError: Error?
                do { try await vault.abortImport(session) } catch { reconciliationError = error }
                sessionIsActive = false
                let recovered: DICOMImportCommit?
                if let terminal { recovered = terminal }
                else { recovered = try? await vault.committedImport(proposal, session: session) }
                if let recovered {
                    switch recovered {
                    case .accepted: return proposedResult
                    case .duplicateExisting(let id):
                        return DICOMImportResult(studyID: id, wasExisting: true,
                            viewableInstanceCount: proposedResult.viewableInstanceCount,
                            inertObjectCount: proposedResult.inertObjectCount,
                            ignoredNonDICOMCount: proposedResult.ignoredNonDICOMCount,
                            ignoredDuplicateCount: proposedResult.ignoredDuplicateCount)
                    }
                }
                if let reconciliationError { throw reconciliationError }
                throw commitError
            }
            sessionIsActive = false
            switch outcome {
            case .accepted(let id):
                guard id == proposedResult.studyID else {
                    throw DICOMImportError.integrityFailure
                }
                return proposedResult
            case .duplicateExisting(let id):
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
                    try await vault.abortImport(session)
                } catch {
                    throw error
                }
            }
            if wasCancelled { throw DICOMImportError.cancelled }
            throw operationError
        }
    }

}
