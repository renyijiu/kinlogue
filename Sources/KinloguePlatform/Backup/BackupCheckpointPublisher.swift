import Foundation

/// Allocates the next authoritative repository sequence and completes the
/// encrypted publication while one repository-scoped process lease is held.
/// The writer records its durable configuration witness before this method
/// releases the lease, so another process cannot publish from the same scan.
// SAFETY: Collaborators and the optional Testing SPI hook are immutable
// Sendable values; mutable repository, writer, and configuration state remains
// behind their locks or structured lease.
public final class BackupCheckpointPublisher: @unchecked Sendable {
    private let repository: BackupRepository
    private let writer: EncryptedCheckpointWriter
    private let configurationStore: BackupLocalConfigurationStore
    private let criticalSectionHook: @Sendable () async throws -> Void

    public init(
        repository: BackupRepository,
        writer: EncryptedCheckpointWriter,
        configurationStore: BackupLocalConfigurationStore
    ) {
        self.repository = repository
        self.writer = writer
        self.configurationStore = configurationStore
        criticalSectionHook = {}
    }

    @_spi(KinlogueStorageProcessFixture)
    public init(
        repository: BackupRepository,
        writer: EncryptedCheckpointWriter,
        configurationStore: BackupLocalConfigurationStore,
        criticalSectionHook: @escaping @Sendable () async throws -> Void
    ) {
        self.repository = repository
        self.writer = writer
        self.configurationStore = configurationStore
        self.criticalSectionHook = criticalSectionHook
    }

    public func publishNext(
        configuration: BackupLocalConfiguration
    ) async throws -> EncryptedCheckpointWriteResult {
        let repository = self.repository
        let lease = try await repository.acquireMutationLease()
        defer { lease.release() }
        let scan = try repository.scan(holding: lease)
        guard case .linear = scan.history else {
            throw BackupRepositoryError.historyFork
        }
        try await criticalSectionHook()
        guard let current = try await configurationStore.load(),
              current.phase == .enabled,
              current.writerIdentity == configuration.writerIdentity else {
            throw BackupRepositoryError.identityChanged
        }
        let witnessedMaximum = current.verificationWitnesses.lazy
            .filter { witness in
                witness.writerEpoch == current.writerEpoch
                    && witness.setID == current.descriptor.setID
                    && witness.deviceID == current.authorization.deviceID
                    && witness.authorizationID == current.authorization.authorizationID
            }
            .map(\.sequence)
            .max()
        let durableHighWater = [scan.maximumSequence, witnessedMaximum]
            .compactMap { $0 }
            .max()
        guard durableHighWater != UInt64.max else {
            throw BackupRepositoryError.resourceLimit
        }
        let sequence = max(
            current.authorization.sequenceFloor,
            durableHighWater.map { $0 + 1 }
                ?? current.authorization.sequenceFloor
        )
        return try await writer.write(
            repositoryURL: repository.repositoryURL,
            configuration: current,
            sequence: sequence,
            publicationFenceValidator: {
                try repository.validateMutationLease(lease)
            }
        )
    }
}
