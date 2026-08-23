import Foundation

public enum DICOMImportPolicyError: Error, Equatable, Sendable {
    case resourceLimit
}

/// Fixed intake budgets for one DICOM examination. Construction is strict so
/// callers cannot silently relax the production contract with invalid values.
public struct DICOMImportPolicy: Equatable, Sendable {
    public static let `default` = try! Self(
        maximumTraversalDepth: 16,
        maximumDirectoryEntries: 10_000,
        maximumDICOMObjectCount: 2_000,
        maximumUniqueSourceBytes: 2 * 1_024 * 1_024 * 1_024,
        maximumObjectBytes: 100 * 1_024 * 1_024,
        maximumRows: 8_192,
        maximumColumns: 8_192,
        maximumDecodedSampleBytes: 128 * 1_024 * 1_024,
        maximumWorkers: 2,
        maximumSourceAndStagingDescriptors: 8,
        requiredFreeSpaceHeadroom: 256 * 1_024 * 1_024
    )

    public let maximumTraversalDepth: Int
    public let maximumDirectoryEntries: Int
    public let maximumDICOMObjectCount: Int
    public let maximumUniqueSourceBytes: Int
    public let maximumObjectBytes: Int
    public let maximumRows: Int
    public let maximumColumns: Int
    public let maximumDecodedSampleBytes: Int
    public let maximumWorkers: Int
    public let maximumSourceAndStagingDescriptors: Int
    public let requiredFreeSpaceHeadroom: Int

    public init(
        maximumTraversalDepth: Int,
        maximumDirectoryEntries: Int,
        maximumDICOMObjectCount: Int,
        maximumUniqueSourceBytes: Int,
        maximumObjectBytes: Int,
        maximumRows: Int,
        maximumColumns: Int,
        maximumDecodedSampleBytes: Int,
        maximumWorkers: Int,
        maximumSourceAndStagingDescriptors: Int,
        requiredFreeSpaceHeadroom: Int
    ) throws {
        guard maximumTraversalDepth >= 0,
              maximumDirectoryEntries > 0,
              maximumDICOMObjectCount > 0,
              maximumDICOMObjectCount <= DICOMStudy.maximumAttachmentCount,
              maximumUniqueSourceBytes > 0,
              maximumObjectBytes > 0,
              maximumObjectBytes <= maximumUniqueSourceBytes,
              maximumRows > 0, maximumRows <= 8_192,
              maximumColumns > 0, maximumColumns <= 8_192,
              maximumDecodedSampleBytes > 0,
              maximumWorkers == 2,
              maximumSourceAndStagingDescriptors == 8,
              requiredFreeSpaceHeadroom >= 0 else {
            throw DICOMImportPolicyError.resourceLimit
        }
        self.maximumTraversalDepth = maximumTraversalDepth
        self.maximumDirectoryEntries = maximumDirectoryEntries
        self.maximumDICOMObjectCount = maximumDICOMObjectCount
        self.maximumUniqueSourceBytes = maximumUniqueSourceBytes
        self.maximumObjectBytes = maximumObjectBytes
        self.maximumRows = maximumRows
        self.maximumColumns = maximumColumns
        self.maximumDecodedSampleBytes = maximumDecodedSampleBytes
        self.maximumWorkers = maximumWorkers
        self.maximumSourceAndStagingDescriptors = maximumSourceAndStagingDescriptors
        self.requiredFreeSpaceHeadroom = requiredFreeSpaceHeadroom
    }

    public func validateDICOMObjectCount(_ count: Int) throws {
        guard (1...maximumDICOMObjectCount).contains(count) else {
            throw DICOMImportPolicyError.resourceLimit
        }
    }

    public func requiredFreeBytes(forUniqueStagedBytes byteCount: Int) throws -> Int {
        try requiredAdditionalFreeBytes(
            forUniqueStagedBytes: byteCount,
            alreadyStagedBytes: 0
        )
    }

    public func requiredAdditionalFreeBytes(
        forUniqueStagedBytes byteCount: Int,
        alreadyStagedBytes: Int
    ) throws -> Int {
        guard byteCount >= 0, byteCount <= maximumUniqueSourceBytes,
              alreadyStagedBytes >= 0, alreadyStagedBytes <= byteCount else {
            throw DICOMImportPolicyError.resourceLimit
        }
        let doubled = byteCount.multipliedReportingOverflow(by: 2)
        guard !doubled.overflow else { throw DICOMImportPolicyError.resourceLimit }
        let remaining = doubled.partialValue.subtractingReportingOverflow(alreadyStagedBytes)
        guard !remaining.overflow else { throw DICOMImportPolicyError.resourceLimit }
        let total = remaining.partialValue.addingReportingOverflow(requiredFreeSpaceHeadroom)
        guard !total.overflow else { throw DICOMImportPolicyError.resourceLimit }
        return total.partialValue
    }
}
