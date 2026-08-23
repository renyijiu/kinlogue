import Darwin
import Foundation
import KinlogueCore

@_spi(Testing) public enum BackupRestoreTransactionFault: Equatable, Sendable {
    case afterIntent
    case afterWriterReset
    case afterOldRootMove
    case afterNewRootActivation
    case afterValidation
    case afterCommit
}

public enum BackupRestoreReconciliationOutcome: Equatable, Sendable {
    case noTransaction
    case committed
    case rolledBack
}

public struct BackupRestoreActivationResult: Equatable, Sendable {
    public let summary: BackupRestoreSummary
    public let requiresApplicationRestart: Bool

    public init(summary: BackupRestoreSummary, requiresApplicationRestart: Bool = true) {
        self.summary = summary
        self.requiresApplicationRestart = requiresApplicationRestart
    }
}

private enum BackupRestoreScenario: String, Codable {
    case existingRoot
    case absentRoot
}

private enum BackupRestoreTransactionPhase: String, Codable {
    case intent
    case writerRevoked
    case prepared
    case activated
    case validated
    case committed
    case rollbackPrepared
    case rolledBack
}

private struct BackupRestoreTransactionReceipt: Codable {
    static let magic = "KLGRESTORETX1"
    let magic: String
    let version: Int
    let operationID: UUID
    let epoch: UInt64
    let scenario: BackupRestoreScenario
    var phase: BackupRestoreTransactionPhase
    let activeRootNameDigest: Data
    let checkpointID: Data
    let preflightReceiptName: String
    let stagingName: String
    let rollbackName: String
    let oldRootIdentity: BackupRestoreDirectoryIdentity?
    let stagingIdentity: BackupRestoreDirectoryIdentity
    let vaultGeneration: UInt64
    let vaultCommitID: UUID
    let vaultManifestDigest: Data
    let inboxGeneration: UInt64
    let inboxCommitID: UUID
    let inboxManifestDigest: Data
}

private struct BackupRestoreEpochRecord: Codable {
    static let magic = "KLGRESTOREEPOCH1"
    let magic: String
    let version: Int
    let value: UInt64
}

/// Whole-root activation transaction. App lifecycle revocation and the U5
/// operation coordinator are the caller's front half; this type owns the
/// stable cross-process Vault lease and all durable filesystem phases.
// SAFETY: Stored transaction authority is immutable and every activate or
// reconcile mutation is serialized by the shared cross-process Vault lease.
public final class BackupRestoreTransaction: @unchecked Sendable {
    public typealias WriterReset = @Sendable () async throws -> Void
    @_spi(Testing) public typealias FailureInjector =
        @Sendable (BackupRestoreTransactionFault) -> Bool

    private let activeRootURL: URL
    private let stableParentURL: URL
    private let activeRootName: String
    private let transactionReceiptName: String
    private let rollbackName: String
    private let epochName: String
    private let failureInjector: FailureInjector?
    private let mutationCoordinator: VaultMutationCoordinator

    public convenience init(activeRootURL: URL) throws {
        try self.init(activeRootURL: activeRootURL, failureInjector: nil)
    }

    @_spi(Testing) public init(
        activeRootURL: URL,
        failureInjector: FailureInjector?
    ) throws {
        let root = activeRootURL.standardizedFileURL
        let parent = root.deletingLastPathComponent()
        guard root.isFileURL,
              !root.lastPathComponent.isEmpty,
              !root.lastPathComponent.hasPrefix(".") else {
            throw BackupRestoreError.activationConflict
        }
        let parentDescriptor = try BackupRestoreFilesystem.openStrictDirectory(parent)
        Darwin.close(parentDescriptor)
        let suffix = ContentDigest.sha256(Data(root.lastPathComponent.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        self.activeRootURL = root
        stableParentURL = parent
        activeRootName = root.lastPathComponent
        transactionReceiptName = ".kinlogue-restore-transaction-\(suffix).json"
        rollbackName = ".kinlogue-restore-rollback-\(suffix)"
        epochName = ".kinlogue-library-transaction-epoch-\(suffix).json"
        self.failureInjector = failureInjector
        mutationCoordinator = VaultMutationCoordinator.shared(for: root)
    }

    public func activate(
        prepared: BackupPreparedRestore,
        resetWriter: @escaping WriterReset
    ) async throws -> BackupRestoreActivationResult {
        guard prepared.activeRootName == activeRootName,
              prepared.stagingURL.deletingLastPathComponent() == stableParentURL,
              prepared.preflightReceiptURL.deletingLastPathComponent() == stableParentURL else {
            throw BackupRestoreError.receiptInvalid
        }
        let lease = try await mutationCoordinator.acquire()
        defer { lease.release() }
        let parentDescriptor = try BackupRestoreFilesystem.openStrictDirectory(stableParentURL)
        defer { Darwin.close(parentDescriptor) }
        guard try !namedNodeExists(transactionReceiptName, at: parentDescriptor),
              try BackupRestoreFilesystem.directoryIdentityIfPresent(
                named: rollbackName,
                parentDescriptor: parentDescriptor
              ) == nil else {
            throw BackupRestoreError.activationConflict
        }
        try validatePreflight(prepared, parentDescriptor: parentDescriptor)
        let currentIdentity = try BackupRestoreFilesystem.directoryIdentityIfPresent(
            named: activeRootName,
            parentDescriptor: parentDescriptor
        )
        guard currentIdentity?.device == prepared.stagingIdentity.device
                || currentIdentity == nil else {
            // Existing and staging roots must be on the same volume.
            throw BackupRestoreError.activationConflict
        }
        let epoch = try advanceEpoch(parentDescriptor: parentDescriptor)
        var receipt = BackupRestoreTransactionReceipt(
            magic: BackupRestoreTransactionReceipt.magic,
            version: 1,
            operationID: prepared.operationID,
            epoch: epoch,
            scenario: currentIdentity == nil ? .absentRoot : .existingRoot,
            phase: .intent,
            activeRootNameDigest: ContentDigest.sha256(Data(activeRootName.utf8)),
            checkpointID: prepared.summary.checkpointID.bytes,
            preflightReceiptName: prepared.preflightReceiptURL.lastPathComponent,
            stagingName: prepared.stagingURL.lastPathComponent,
            rollbackName: rollbackName,
            oldRootIdentity: currentIdentity,
            stagingIdentity: prepared.stagingIdentity,
            vaultGeneration: prepared.summary.revisionPair.vault.generation,
            vaultCommitID: prepared.summary.revisionPair.vault.commitID,
            vaultManifestDigest: prepared.summary.revisionPair.vault.manifestDigest,
            inboxGeneration: prepared.summary.revisionPair.lanInbox.generation,
            inboxCommitID: prepared.summary.revisionPair.lanInbox.commitID,
            inboxManifestDigest: prepared.summary.revisionPair.lanInbox.manifestDigest
        )
        try writeInitialReceipt(receipt, parentDescriptor: parentDescriptor)
        try failIfRequested(.afterIntent)

        try await resetWriter()
        receipt.phase = .writerRevoked
        try replaceReceipt(receipt, parentDescriptor: parentDescriptor)
        try failIfRequested(.afterWriterReset)

        receipt.phase = .prepared
        try replaceReceipt(receipt, parentDescriptor: parentDescriptor)
        if let currentIdentity {
            try renameDirectory(
                from: activeRootName,
                expected: currentIdentity,
                to: rollbackName,
                parentDescriptor: parentDescriptor
            )
            try failIfRequested(.afterOldRootMove)
        }
        try renameDirectory(
            from: prepared.stagingURL.lastPathComponent,
            expected: prepared.stagingIdentity,
            to: activeRootName,
            parentDescriptor: parentDescriptor
        )
        try failIfRequested(.afterNewRootActivation)

        receipt.phase = .activated
        try replaceReceipt(receipt, parentDescriptor: parentDescriptor)
        do {
            try await validateActivatedRoot(receipt: receipt, lease: lease)
        } catch {
            try rollback(&receipt, parentDescriptor: parentDescriptor)
            throw BackupRestoreError.graphInvalid
        }
        receipt.phase = .validated
        try replaceReceipt(receipt, parentDescriptor: parentDescriptor)
        try failIfRequested(.afterValidation)
        receipt.phase = .committed
        try replaceReceipt(receipt, parentDescriptor: parentDescriptor)
        try failIfRequested(.afterCommit)
        // Rollback and receipts deliberately survive until the next successful
        // strict startup reconciliation. Services must not be hot-rebound.
        return BackupRestoreActivationResult(summary: prepared.summary)
    }

    public func reconcile() async throws -> BackupRestoreReconciliationOutcome {
        let lease = try await mutationCoordinator.acquire()
        defer { lease.release() }
        let parentDescriptor = try BackupRestoreFilesystem.openStrictDirectory(stableParentURL)
        defer { Darwin.close(parentDescriptor) }
        guard try namedNodeExists(transactionReceiptName, at: parentDescriptor) else {
            return .noTransaction
        }
        var receipt = try readReceipt(parentDescriptor: parentDescriptor)
        try validateReceiptShape(receipt)

        switch receipt.phase {
        case .intent, .writerRevoked:
            try rollback(&receipt, parentDescriptor: parentDescriptor)
            return .rolledBack
        case .prepared:
            let active = try BackupRestoreFilesystem.directoryIdentityIfPresent(
                named: activeRootName,
                parentDescriptor: parentDescriptor
            )
            let rollbackIdentity = try BackupRestoreFilesystem.directoryIdentityIfPresent(
                named: rollbackName,
                parentDescriptor: parentDescriptor
            )
            if active == receipt.stagingIdentity {
                receipt.phase = .activated
                try replaceReceipt(receipt, parentDescriptor: parentDescriptor)
                return try await finishActivatedReconciliation(
                    &receipt,
                    lease: lease,
                    parentDescriptor: parentDescriptor
                )
            }
            if rollbackIdentity == receipt.oldRootIdentity, active == nil {
                try rollback(&receipt, parentDescriptor: parentDescriptor)
                return .rolledBack
            }
            if active == receipt.oldRootIdentity, rollbackIdentity == nil {
                try rollback(&receipt, parentDescriptor: parentDescriptor)
                return .rolledBack
            }
            throw BackupRestoreError.receiptInvalid
        case .activated:
            return try await finishActivatedReconciliation(
                &receipt,
                lease: lease,
                parentDescriptor: parentDescriptor
            )
        case .validated:
            try await validateActivatedRoot(receipt: receipt, lease: lease)
            receipt.phase = .committed
            try replaceReceipt(receipt, parentDescriptor: parentDescriptor)
            try cleanupCommitted(receipt, parentDescriptor: parentDescriptor)
            return .committed
        case .committed:
            try await validateActivatedRoot(receipt: receipt, lease: lease)
            try cleanupCommitted(receipt, parentDescriptor: parentDescriptor)
            return .committed
        case .rollbackPrepared:
            try finishRollback(&receipt, parentDescriptor: parentDescriptor)
            return .rolledBack
        case .rolledBack:
            try cleanupRolledBack(receipt, parentDescriptor: parentDescriptor)
            return .rolledBack
        }
    }

    func rollbackIdentityForTesting() throws -> BackupRestoreDirectoryIdentity? {
        let parent = try BackupRestoreFilesystem.openStrictDirectory(stableParentURL)
        defer { Darwin.close(parent) }
        return try BackupRestoreFilesystem.directoryIdentityIfPresent(
            named: rollbackName,
            parentDescriptor: parent
        )
    }

    private func finishActivatedReconciliation(
        _ receipt: inout BackupRestoreTransactionReceipt,
        lease: VaultMutationLease,
        parentDescriptor: Int32
    ) async throws -> BackupRestoreReconciliationOutcome {
        do {
            try await validateActivatedRoot(receipt: receipt, lease: lease)
            receipt.phase = .validated
            try replaceReceipt(receipt, parentDescriptor: parentDescriptor)
            receipt.phase = .committed
            try replaceReceipt(receipt, parentDescriptor: parentDescriptor)
            try cleanupCommitted(receipt, parentDescriptor: parentDescriptor)
            return .committed
        } catch {
            try rollback(&receipt, parentDescriptor: parentDescriptor)
            return .rolledBack
        }
    }

    private func validateActivatedRoot(
        receipt: BackupRestoreTransactionReceipt,
        lease: VaultMutationLease
    ) async throws {
        let parent = try BackupRestoreFilesystem.openStrictDirectory(stableParentURL)
        defer { Darwin.close(parent) }
        guard try BackupRestoreFilesystem.directoryIdentityIfPresent(
            named: activeRootName,
            parentDescriptor: parent
        ) == receipt.stagingIdentity else {
            throw BackupRestoreError.activationConflict
        }
        let vault = try PlaintextVault(rootURL: activeRootURL)
        let inbox = try PlaintextLANInboxStore(rootURL: activeRootURL)
        let vaultValidation = try await vault.strictRestoreValidation(using: lease)
        let inboxValidation = try await inbox.strictRestoreValidation(using: lease)
        let pair = try BackupRevisionPair(
            vault: vaultValidation.revision,
            lanInbox: inboxValidation.revision
        )
        guard vaultValidation.vaultID == inboxValidation.vaultID,
              pair.vault.generation == receipt.vaultGeneration,
              pair.vault.commitID == receipt.vaultCommitID,
              pair.vault.manifestDigest == receipt.vaultManifestDigest,
              pair.lanInbox.generation == receipt.inboxGeneration,
              pair.lanInbox.commitID == receipt.inboxCommitID,
              pair.lanInbox.manifestDigest == receipt.inboxManifestDigest else {
            throw BackupRestoreError.graphInvalid
        }
    }

    private func rollback(
        _ receipt: inout BackupRestoreTransactionReceipt,
        parentDescriptor: Int32
    ) throws {
        receipt.phase = .rollbackPrepared
        try replaceReceipt(receipt, parentDescriptor: parentDescriptor)
        try finishRollback(&receipt, parentDescriptor: parentDescriptor)
    }

    private func finishRollback(
        _ receipt: inout BackupRestoreTransactionReceipt,
        parentDescriptor: Int32
    ) throws {
        let active = try BackupRestoreFilesystem.directoryIdentityIfPresent(
            named: activeRootName,
            parentDescriptor: parentDescriptor
        )
        let rollback = try BackupRestoreFilesystem.directoryIdentityIfPresent(
            named: rollbackName,
            parentDescriptor: parentDescriptor
        )
        let staging = try BackupRestoreFilesystem.directoryIdentityIfPresent(
            named: receipt.stagingName,
            parentDescriptor: parentDescriptor
        )

        if active == receipt.stagingIdentity {
            guard staging == nil else { throw BackupRestoreError.receiptInvalid }
            try renameDirectory(
                from: activeRootName,
                expected: receipt.stagingIdentity,
                to: receipt.stagingName,
                parentDescriptor: parentDescriptor
            )
        } else if active != nil, active != receipt.oldRootIdentity {
            throw BackupRestoreError.receiptInvalid
        }

        if let old = receipt.oldRootIdentity {
            let current = try BackupRestoreFilesystem.directoryIdentityIfPresent(
                named: activeRootName,
                parentDescriptor: parentDescriptor
            )
            if current == nil {
                guard rollback == old else { throw BackupRestoreError.receiptInvalid }
                try renameDirectory(
                    from: rollbackName,
                    expected: old,
                    to: activeRootName,
                    parentDescriptor: parentDescriptor
                )
            } else {
                guard current == old, rollback == nil else {
                    throw BackupRestoreError.receiptInvalid
                }
            }
        } else {
            guard try BackupRestoreFilesystem.directoryIdentityIfPresent(
                named: activeRootName,
                parentDescriptor: parentDescriptor
            ) == nil,
            rollback == nil else { throw BackupRestoreError.receiptInvalid }
        }
        receipt.phase = .rolledBack
        try replaceReceipt(receipt, parentDescriptor: parentDescriptor)
        try cleanupRolledBack(receipt, parentDescriptor: parentDescriptor)
    }

    private func cleanupCommitted(
        _ receipt: BackupRestoreTransactionReceipt,
        parentDescriptor: Int32
    ) throws {
        if let old = receipt.oldRootIdentity {
            try BackupRestoreFilesystem.removeDirectoryTree(
                named: rollbackName,
                expectedIdentity: old,
                parentDescriptor: parentDescriptor
            )
        }
        try removePreflight(receipt, parentDescriptor: parentDescriptor)
        try BackupRestoreFilesystem.removeRegularFile(
            named: transactionReceiptName,
            parentDescriptor: parentDescriptor
        )
        try BackupRestoreFilesystem.sync(parentDescriptor)
    }

    private func cleanupRolledBack(
        _ receipt: BackupRestoreTransactionReceipt,
        parentDescriptor: Int32
    ) throws {
        if try BackupRestoreFilesystem.directoryIdentityIfPresent(
            named: receipt.stagingName,
            parentDescriptor: parentDescriptor
        ) == receipt.stagingIdentity {
            try BackupRestoreFilesystem.removeDirectoryTree(
                named: receipt.stagingName,
                expectedIdentity: receipt.stagingIdentity,
                parentDescriptor: parentDescriptor
            )
        }
        try removePreflight(receipt, parentDescriptor: parentDescriptor)
        try BackupRestoreFilesystem.removeRegularFile(
            named: transactionReceiptName,
            parentDescriptor: parentDescriptor
        )
        try BackupRestoreFilesystem.sync(parentDescriptor)
    }

    private func removePreflight(
        _ receipt: BackupRestoreTransactionReceipt,
        parentDescriptor: Int32
    ) throws {
        try BackupRestoreFilesystem.removeRegularFile(
            named: receipt.preflightReceiptName,
            parentDescriptor: parentDescriptor
        )
    }

    private func validatePreflight(
        _ prepared: BackupPreparedRestore,
        parentDescriptor: Int32
    ) throws {
        let data = try readBoundedRegularFile(
            named: prepared.preflightReceiptURL.lastPathComponent,
            maximumByteCount: 16 * 1_024,
            parentDescriptor: parentDescriptor
        )
        let receipt: BackupRestorePreflightReceipt
        do {
            receipt = try CanonicalVaultJSON.decode(BackupRestorePreflightReceipt.self, from: data)
            guard try CanonicalVaultJSON.encode(receipt) == data else {
                throw BackupRestoreError.receiptInvalid
            }
        } catch {
            throw BackupRestoreError.receiptInvalid
        }
        guard receipt.magic == BackupRestorePreflightReceipt.magic,
              receipt.version == 1,
              receipt.operationID == prepared.operationID,
              receipt.activeRootNameDigest == ContentDigest.sha256(Data(activeRootName.utf8)),
              receipt.checkpointID == prepared.summary.checkpointID.bytes,
              receipt.stagingName == prepared.stagingURL.lastPathComponent,
              receipt.stagingIdentity == prepared.stagingIdentity,
              try BackupRestoreFilesystem.directoryIdentity(
                named: receipt.stagingName,
                parentDescriptor: parentDescriptor
              ) == receipt.stagingIdentity else {
            throw BackupRestoreError.receiptInvalid
        }
    }

    private func validateReceiptShape(_ receipt: BackupRestoreTransactionReceipt) throws {
        guard receipt.magic == BackupRestoreTransactionReceipt.magic,
              receipt.version == 1,
              receipt.epoch > 0,
              receipt.activeRootNameDigest == ContentDigest.sha256(Data(activeRootName.utf8)),
              receipt.checkpointID.count == 16,
              receipt.rollbackName == rollbackName,
              receipt.stagingName.hasPrefix(".kinlogue-restore-"),
              receipt.stagingName.hasSuffix(".staging"),
              receipt.preflightReceiptName.hasPrefix(".kinlogue-restore-"),
              receipt.preflightReceiptName.hasSuffix(".preflight.json"),
              receipt.vaultGeneration > 0,
              receipt.vaultManifestDigest.count == 32,
              receipt.inboxGeneration > 0,
              receipt.inboxManifestDigest.count == 32 else {
            throw BackupRestoreError.receiptInvalid
        }
    }

    private func renameDirectory(
        from source: String,
        expected: BackupRestoreDirectoryIdentity,
        to destination: String,
        parentDescriptor: Int32
    ) throws {
        guard try BackupRestoreFilesystem.directoryIdentity(
            named: source,
            parentDescriptor: parentDescriptor
        ) == expected,
        try BackupRestoreFilesystem.directoryIdentityIfPresent(
            named: destination,
            parentDescriptor: parentDescriptor
        ) == nil else { throw BackupRestoreError.activationConflict }
        let result = source.withCString { sourcePointer in
            destination.withCString { destinationPointer in
                renameatx_np(
                    parentDescriptor,
                    sourcePointer,
                    parentDescriptor,
                    destinationPointer,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard result == 0,
              try BackupRestoreFilesystem.directoryIdentity(
                named: destination,
                parentDescriptor: parentDescriptor
              ) == expected else {
            throw BackupRestoreError.activationConflict
        }
        try BackupRestoreFilesystem.sync(parentDescriptor)
    }

    private func advanceEpoch(parentDescriptor: Int32) throws -> UInt64 {
        let previous: UInt64
        if try namedNodeExists(epochName, at: parentDescriptor) {
            let data = try readBoundedRegularFile(
                named: epochName,
                maximumByteCount: 4 * 1_024,
                parentDescriptor: parentDescriptor
            )
            let record = try CanonicalVaultJSON.decode(BackupRestoreEpochRecord.self, from: data)
            guard try CanonicalVaultJSON.encode(record) == data,
                  record.magic == BackupRestoreEpochRecord.magic,
                  record.version == 1 else { throw BackupRestoreError.receiptInvalid }
            previous = record.value
        } else {
            previous = 0
        }
        guard previous < UInt64.max else { throw BackupRestoreError.activationConflict }
        let next = previous + 1
        let record = BackupRestoreEpochRecord(
            magic: BackupRestoreEpochRecord.magic,
            version: 1,
            value: next
        )
        try replaceNamedFile(
            try CanonicalVaultJSON.encode(record),
            named: epochName,
            parentDescriptor: parentDescriptor,
            exclusive: previous == 0
        )
        return next
    }

    private func writeInitialReceipt(
        _ receipt: BackupRestoreTransactionReceipt,
        parentDescriptor: Int32
    ) throws {
        try BackupRestoreFilesystem.writeExclusiveFile(
            try CanonicalVaultJSON.encode(receipt),
            named: transactionReceiptName,
            parentDescriptor: parentDescriptor
        )
        try BackupRestoreFilesystem.sync(parentDescriptor)
    }

    private func replaceReceipt(
        _ receipt: BackupRestoreTransactionReceipt,
        parentDescriptor: Int32
    ) throws {
        try validateReceiptShape(receipt)
        try replaceNamedFile(
            try CanonicalVaultJSON.encode(receipt),
            named: transactionReceiptName,
            parentDescriptor: parentDescriptor,
            exclusive: false
        )
    }

    private func readReceipt(parentDescriptor: Int32) throws -> BackupRestoreTransactionReceipt {
        let data = try readBoundedRegularFile(
            named: transactionReceiptName,
            maximumByteCount: 32 * 1_024,
            parentDescriptor: parentDescriptor
        )
        let receipt: BackupRestoreTransactionReceipt
        do {
            receipt = try CanonicalVaultJSON.decode(BackupRestoreTransactionReceipt.self, from: data)
            guard try CanonicalVaultJSON.encode(receipt) == data else {
                throw BackupRestoreError.receiptInvalid
            }
        } catch { throw BackupRestoreError.receiptInvalid }
        return receipt
    }

    private func replaceNamedFile(
        _ data: Data,
        named name: String,
        parentDescriptor: Int32,
        exclusive: Bool
    ) throws {
        if exclusive {
            try BackupRestoreFilesystem.writeExclusiveFile(
                data,
                named: name,
                parentDescriptor: parentDescriptor
            )
            try BackupRestoreFilesystem.sync(parentDescriptor)
            return
        }
        _ = try readBoundedRegularFile(
            named: name,
            maximumByteCount: 32 * 1_024,
            parentDescriptor: parentDescriptor
        )
        let temporary = ".kinlogue-restore-receipt-\(UUID().uuidString.lowercased()).tmp"
        try BackupRestoreFilesystem.writeExclusiveFile(
            data,
            named: temporary,
            parentDescriptor: parentDescriptor
        )
        let result = temporary.withCString { temporaryPointer in
            name.withCString { namePointer in
                renameat(parentDescriptor, temporaryPointer, parentDescriptor, namePointer)
            }
        }
        guard result == 0 else {
            try? BackupRestoreFilesystem.removeRegularFile(
                named: temporary,
                parentDescriptor: parentDescriptor
            )
            throw BackupRestoreError.ioFailure(errno)
        }
        try BackupRestoreFilesystem.sync(parentDescriptor)
    }

    private func readBoundedRegularFile(
        named name: String,
        maximumByteCount: Int,
        parentDescriptor: Int32
    ) throws -> Data {
        let descriptor = name.withCString {
            openat(parentDescriptor, $0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw BackupRestoreError.receiptInvalid }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_nlink == 1,
              metadata.st_size >= 0,
              metadata.st_size <= maximumByteCount else {
            throw BackupRestoreError.receiptInvalid
        }
        var data = Data()
        data.reserveCapacity(Int(metadata.st_size))
        var buffer = [UInt8](repeating: 0, count: 4 * 1_024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw BackupRestoreError.ioFailure(errno) }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= maximumByteCount else {
                throw BackupRestoreError.receiptInvalid
            }
        }
        var final = stat()
        guard fstat(descriptor, &final) == 0,
              final.st_dev == metadata.st_dev,
              final.st_ino == metadata.st_ino,
              final.st_size == metadata.st_size else {
            throw BackupRestoreError.receiptInvalid
        }
        return data
    }

    private func namedNodeExists(_ name: String, at parentDescriptor: Int32) throws -> Bool {
        var metadata = stat()
        guard name.withCString({
            fstatat(parentDescriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
        }) == 0 else {
            if errno == ENOENT { return false }
            throw BackupRestoreError.ioFailure(errno)
        }
        return true
    }

    private func failIfRequested(_ point: BackupRestoreTransactionFault) throws {
        if failureInjector?(point) == true { throw BackupRestoreError.injectedFailure }
    }
}
