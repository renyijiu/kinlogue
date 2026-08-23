import Foundation
import Testing
@testable import KinlogueCore

@Test
func vaultRevisionRequiresASHA256Digest() throws {
    #expect(throws: VaultError.invalidDigest) {
        _ = try VaultRevision(
            generation: 1,
            commitID: UUID(),
            catalogDigest: Data(repeating: 0, count: 31)
        )
    }
}

@Test
func catalogValidationRunsAfterDecoding() throws {
    let vaultID = UUID()
    let member = try FamilyMember(displayName: "Synthetic")
    let attachment = try Attachment(
        contentTypeIdentifier: "public.data",
        byteCount: 8,
        sha256Digest: Data(repeating: 7, count: 32)
    )
    let record = try HealthRecord(
        memberID: member.id,
        attachmentID: attachment.id,
        importState: .confirmed
    )
    let catalog = try VaultCatalog(
        vaultID: vaultID,
        generation: 3,
        members: [member],
        records: [record],
        attachments: [attachment]
    )

    #expect(try catalog.validated() == catalog)
}

@Test
func commitRequestRejectsAStaleCatalogGeneration() throws {
    let catalog = try VaultCatalog(vaultID: UUID(), generation: 4)

    #expect(throws: VaultError.invalidGeneration) {
        _ = try VaultCommitRequest(
            expectedGeneration: 4,
            catalog: catalog,
            writes: []
        )
    }
}

@Test
func vaultGenerationSuccessorRejectsExhaustionWithoutTrapping() throws {
    #expect(try VaultGeneration.successor(of: UInt64.max - 1) == UInt64.max)
    #expect(throws: VaultError.invalidGeneration) {
        _ = try VaultGeneration.successor(of: UInt64.max)
    }
}
