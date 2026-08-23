import Darwin
import Foundation
import KinlogueCore

public struct DICOMImportReconciliationResult: Equatable, Sendable {
    public let reconciledOperationCount: Int
    public let removedObjectCount: Int
    public let preservedReachableObjectCount: Int
    public let retryOperationCount: Int
}

/// Durable opaque ownership ledger for objects promoted before the manifest.
/// It contains only operation/object IDs and managed relative staging paths.
public struct VaultDICOMImportJournal: Sendable {
    private static let maximumJournalBytes = 2 * 1_024 * 1_024
    private let rootURL: URL
    private let files: AtomicFileStore
    private let layout: PlaintextVaultLayout

    public init(rootURL: URL) throws {
        layout = try PlaintextVaultLayout(rootURL: rootURL)
        self.rootURL = layout.rootURL
        files = try AtomicFileStore(rootURL: layout.rootURL)
    }

    func begin(operationID: UUID, vaultID: UUID) throws {
        guard !files.exists(relativePath: journalPath(operationID)) else {
            throw DICOMImportError.integrityFailure
        }
        try write(Receipt(
            version: 2,
            operationID: operationID,
            vaultID: vaultID,
            stagingOwnership: nil,
            promotedReferences: []
        ))
    }

    func bindStagingOwnership(
        _ ownership: VaultDICOMStagingOwnership,
        operationID: UUID
    ) throws {
        guard ownership.operationID == operationID else {
            throw DICOMImportError.integrityFailure
        }
        var receipt = try read(operationID: operationID)
        guard receipt.stagingOwnership == nil || receipt.stagingOwnership == ownership else {
            throw DICOMImportError.integrityFailure
        }
        receipt.stagingOwnership = ownership
        try write(receipt)
    }

    func verifyOwnership(
        operationID: UUID,
        vaultID: UUID,
        ownership: VaultDICOMStagingOwnership
    ) throws {
        let receipt = try read(operationID: operationID)
        guard receipt.vaultID == vaultID, receipt.stagingOwnership == ownership else {
            throw DICOMImportError.integrityFailure
        }
    }

    func recordPromotions(
        _ references: [VaultObjectReference],
        operationID: UUID
    ) throws {
        guard Set(references).count == references.count,
              references.allSatisfy({
                  $0.kind == .attachment || $0.kind == .record
              }) else {
            throw DICOMImportError.integrityFailure
        }
        var receipt = try read(operationID: operationID)
        receipt.promotedReferences = Array(
            Set(receipt.promotedReferences).union(references)
        ).sorted(by: referencePrecedes)
        try write(receipt)
    }

    @discardableResult
    func reconcile(
        vaultID: UUID,
        retaining reachable: Set<VaultObjectReference>
    ) throws -> DICOMImportReconciliationResult {
        let directory = layout.dicomImportJournalDirectoryPath
        let journalPaths = try files.listRegularFiles(relativeDirectory: directory)
            .filter { $0.hasPrefix("\(directory)/") && $0.hasSuffix(".json") }
            .sorted()
        var reconciled = 0, removed = 0, preserved = 0, retries = 0
        let staging = try VaultDICOMStudyStaging(rootURL: rootURL)
        for path in journalPaths {
            guard let operationID = operationID(fromJournalPath: path) else {
                throw DICOMImportError.integrityFailure
            }
            do {
                let receipt = try read(operationID: operationID)
                guard receipt.vaultID == vaultID else { throw DICOMImportError.integrityFailure }
                for reference in receipt.promotedReferences {
                    if reachable.contains(reference) {
                        preserved += 1
                    } else {
                        try files.remove(relativePath: layout.objectPath(reference))
                        removed += 1
                    }
                }
                if let ownership = receipt.stagingOwnership {
                    try staging.removeOwnedOperation(ownership: ownership, allowMissing: true)
                } else {
                    try staging.removeUnboundEmptyOperation(operationID: operationID)
                }
                try files.remove(relativePath: path)
                reconciled += 1
            } catch {
                retries += 1
            }
        }
        try? files.removeEmptyDirectory(relativePath: layout.dicomImportStagingDirectoryPath)
        try? files.removeEmptyDirectory(relativePath: directory)
        return .init(
            reconciledOperationCount: reconciled,
            removedObjectCount: removed,
            preservedReachableObjectCount: preserved,
            retryOperationCount: retries
        )
    }

    public func pendingOperationCount() throws -> Int {
        try files.listRegularFiles(relativeDirectory: layout.dicomImportJournalDirectoryPath)
            .filter { operationID(fromJournalPath: $0) != nil }.count
    }

    private func read(operationID: UUID) throws -> Receipt {
        let data = try files.read(
            relativePath: journalPath(operationID),
            maximumByteCount: Self.maximumJournalBytes
        )
        do {
            let receipt = try CanonicalVaultJSON.decode(Receipt.self, from: data)
            guard receipt.version == 2, receipt.operationID == operationID,
                  receipt.stagingOwnership?.operationID == operationID || receipt.stagingOwnership == nil,
                  Set(receipt.promotedReferences).count == receipt.promotedReferences.count,
                  receipt.promotedReferences.allSatisfy({
                    $0.kind == .attachment || $0.kind == .record
                  }) else {
                throw DICOMImportError.integrityFailure
            }
            return receipt
        } catch let error as DICOMImportError {
            throw error
        } catch {
            throw DICOMImportError.integrityFailure
        }
    }

    private func write(_ receipt: Receipt) throws {
        let data = try CanonicalVaultJSON.encode(receipt)
        guard data.count <= Self.maximumJournalBytes else { throw DICOMImportError.resourceLimit }
        try files.replaceAtomically(data, relativePath: journalPath(receipt.operationID))
        try files.withRegularFileDescriptor(relativePath: journalPath(receipt.operationID)) {
            guard fchmod($0, S_IRUSR | S_IWUSR) == 0 else {
                throw DICOMImportError.integrityFailure
            }
        }
    }

    private func journalPath(_ operationID: UUID) -> String {
        layout.dicomImportJournalPath(operationID: operationID)
    }

    private func operationID(fromJournalPath path: String) -> UUID? {
        let prefix = "\(layout.dicomImportJournalDirectoryPath)/", suffix = ".json"
        guard path.hasPrefix(prefix), path.hasSuffix(suffix) else { return nil }
        return UUID(uuidString: String(path.dropFirst(prefix.count).dropLast(suffix.count)))
    }

    private func referencePrecedes(_ lhs: VaultObjectReference, _ rhs: VaultObjectReference) -> Bool {
        if lhs.kind.rawValue != rhs.kind.rawValue { return lhs.kind.rawValue < rhs.kind.rawValue }
        return lhs.id.uuidString.lowercased() < rhs.id.uuidString.lowercased()
    }

    private struct Receipt: Codable, Sendable {
        let version: Int
        let operationID: UUID
        let vaultID: UUID
        var stagingOwnership: VaultDICOMStagingOwnership?
        var promotedReferences: [VaultObjectReference]
    }
}
