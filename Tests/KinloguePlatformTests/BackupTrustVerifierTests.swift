import Foundation
import KinlogueCore
import Testing
@testable import KinloguePlatform

@Test
func writerFacingSignerDoesNotExposeRecoveryPrivateMaterial() throws {
    let material = try BackupKeyHierarchy.makeEnrollment()
    let signer = try BackupDeviceSigner(
        descriptor: material.descriptor,
        authorization: material.authorization,
        deviceSigningSeed: material.deviceSigningSeed
    )
    let labels = Set(Mirror(reflecting: signer).children.compactMap(\.label))
    #expect(!labels.contains("recoverySeed"))
    #expect(!labels.contains("recoveryHPKEPrivateKey"))
    #expect(!labels.contains("recoverySigningPrivateKey"))
}

@Test
func nonceCounterIsBigEndianAndRejectsOverflow() throws {
    #expect(try BackupCrypto.nonce(prefix: Data([1, 2, 3, 4]), counter: 0).bytes == Data([1, 2, 3, 4, 0, 0, 0, 0, 0, 0, 0, 0]))
    #expect(try BackupCrypto.nonce(prefix: Data([1, 2, 3, 4]), counter: UInt64.max).bytes == Data([1, 2, 3, 4, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]))
    #expect(throws: BackupContainerError.counterOverflow) {
        _ = try BackupCrypto.payloadCounter(frameIndex: UInt64.max)
    }
}
