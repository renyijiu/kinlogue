import Foundation
import Testing
@testable import KinlogueCore

@Test
func dicomImportPolicyFreezesTheFolderAndResourceBudgets() throws {
    let policy = DICOMImportPolicy.default

    #expect(policy.maximumTraversalDepth == 16)
    #expect(policy.maximumDirectoryEntries == 10_000)
    #expect(policy.maximumDICOMObjectCount == 2_000)
    #expect(policy.maximumUniqueSourceBytes == 2 * 1_024 * 1_024 * 1_024)
    #expect(policy.maximumObjectBytes == 100 * 1_024 * 1_024)
    #expect(policy.maximumWorkers == 2)
    #expect(policy.maximumSourceAndStagingDescriptors == 8)
    #expect(policy.requiredFreeSpaceHeadroom == 256 * 1_024 * 1_024)

    #expect(try policy.requiredFreeBytes(forUniqueStagedBytes: 32) == 256 * 1_024 * 1_024 + 64)
    #expect(
        try policy.requiredAdditionalFreeBytes(
            forUniqueStagedBytes: 32,
            alreadyStagedBytes: 32
        ) == 256 * 1_024 * 1_024 + 32
    )
    #expect(throws: DICOMImportPolicyError.resourceLimit) {
        try policy.requiredAdditionalFreeBytes(
            forUniqueStagedBytes: 32,
            alreadyStagedBytes: 33
        )
    }
    #expect(throws: DICOMImportPolicyError.resourceLimit) {
        try policy.validateDICOMObjectCount(2_001)
    }
}

@Test
func dicomImportCapacityArithmeticFailsClosedOnOverflow() throws {
    let policy = try DICOMImportPolicy(
        maximumTraversalDepth: 16,
        maximumDirectoryEntries: 10_000,
        maximumDICOMObjectCount: 2_000,
        maximumUniqueSourceBytes: Int.max,
        maximumObjectBytes: 1,
        maximumRows: 8_192,
        maximumColumns: 8_192,
        maximumDecodedSampleBytes: 128 * 1_024 * 1_024,
        maximumWorkers: 2,
        maximumSourceAndStagingDescriptors: 8,
        requiredFreeSpaceHeadroom: 0
    )

    #expect(throws: DICOMImportPolicyError.resourceLimit) {
        try policy.requiredAdditionalFreeBytes(
            forUniqueStagedBytes: Int.max,
            alreadyStagedBytes: 0
        )
    }
}

@Test
func dicomImportStateAllowsOnlyForwardTerminalTransitions() throws {
    var state = DICOMImportState.ready
    state = try state.transitioning(to: .scanning)
    state = try state.transitioning(to: .staging)
    state = try state.transitioning(to: .indexing)
    state = try state.transitioning(to: .committing)
    state = try state.transitioning(to: .completed)
    #expect(state == .completed)

    #expect(throws: DICOMImportStateError.invalidTransition) {
        _ = try state.transitioning(to: .scanning)
    }
    #expect(try DICOMImportState.indexing.transitioning(to: .cancelling) == .cancelling)
    #expect(try DICOMImportState.cancelling.transitioning(to: .cancelled) == .cancelled)
    #expect(try DICOMImportState.cancelling.transitioning(to: .completed) == .completed)
    #expect(try DICOMImportState.cancelling.transitioning(to: .failed) == .failed)
    #expect(try DICOMImportState.cancelled.transitioning(to: .ready) == .ready)
}
