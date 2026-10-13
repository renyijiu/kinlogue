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
