import CryptoKit
import Foundation
import KinlogueCore
import Testing
@testable import KinloguePlatform

@Test
func recoveryCodeRoundTripsAFullEntropySeedAndRejectsChecksumChanges() throws {
    let seed = Data((0..<32).map(UInt8.init))
    let code = try BackupRecoveryCode.encode(seed: seed)

    #expect(code.hasPrefix("KLG1-"))
    #expect(try BackupRecoveryCode.decode(code) == seed)

    var changed = code
    let final = changed.index(before: changed.endIndex)
    changed.replaceSubrange(final...final, with: changed[final] == "A" ? "B" : "A")
    #expect(throws: BackupKeyHierarchyError.invalidRecoveryCode) {
        _ = try BackupRecoveryCode.decode(changed)
    }
    #expect(throws: BackupKeyHierarchyError.invalidRecoverySeed) {
        _ = try BackupRecoveryCode.encode(seed: Data(repeating: 1, count: 31))
    }
}

@Test
func recoveryRootsAreDeterministicDomainSeparatedAndCanValidateEnrollment() throws {
    let seed = Data((1...32).map(UInt8.init))
    let setID = try BackupSetID(bytes: Data((33...48).map(UInt8.init)))
    let material = try BackupKeyHierarchy.makeEnrollment(
        recoverySeed: seed,
        setID: setID,
        deviceSigningSeed: Data((65...96).map(UInt8.init)),
        deviceID: .init(bytes: Data((97...112).map(UInt8.init))),
        authorizationID: .init(bytes: Data((113...128).map(UInt8.init))),
        writerEpoch: .init(bytes: Data((129...144).map(UInt8.init))),
        sequenceFloor: 7
    )
    let repeated = try BackupKeyHierarchy.makeEnrollment(
        recoverySeed: seed,
        setID: setID,
        deviceSigningSeed: material.deviceSigningSeed,
        deviceID: material.authorization.deviceID,
        authorizationID: material.authorization.authorizationID,
        writerEpoch: material.writerEpoch,
        sequenceFloor: 7
    )

    #expect(material.descriptor.recoverySigningPublicKey
        == repeated.descriptor.recoverySigningPublicKey)
    #expect(material.descriptor.recoveryHPKEPublicKey
        == repeated.descriptor.recoveryHPKEPublicKey)
    #expect(material.descriptor.recoverySigningPublicKey.hexString
        == "b67d77ebc3e8405ce2e4969d65c492aacc352ee6d69c98856d1c734c4daecc18")
    #expect(material.descriptor.recoveryHPKEPublicKey.hexString
        == "14e1f523717b952601e334837038f41f323e3b3c3b1e4656c166764bab956a19")
    #expect(material.authorization.deviceSigningPublicKey
        == repeated.authorization.deviceSigningPublicKey)
    #expect(material.descriptor.recoverySigningPublicKey
        != material.descriptor.recoveryHPKEPublicKey)
    try BackupKeyHierarchy.validateEnrollment(
        descriptor: material.descriptor,
        authorization: material.authorization,
        deviceSigningSeed: material.deviceSigningSeed
    )

    let wrongSeed = Data(repeating: 0xE1, count: 32)
    #expect(throws: BackupKeyHierarchyError.descriptorMismatch) {
        try BackupKeyHierarchy.validateRecoverySeed(wrongSeed, descriptor: material.descriptor)
    }
}

private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

@Test
func localWriterCanSignButCarriesNoRecoveryPrivateMaterial() throws {
    let material = try BackupKeyHierarchy.makeEnrollment()
    let signer = try BackupDeviceSigner(
        descriptor: material.descriptor,
        authorization: material.authorization,
        deviceSigningSeed: material.deviceSigningSeed
    )
    let message = Data("public commitment".utf8)
    let signature = try signer.signature(for: message)
    let publicKey = try Curve25519.Signing.PublicKey(
        rawRepresentation: material.authorization.deviceSigningPublicKey
    )

    #expect(publicKey.isValidSignature(signature, for: message))
    #expect(Mirror(reflecting: signer).children.allSatisfy {
        $0.label != "recoverySeed" && $0.label != "recoverySigningPrivateKey"
            && $0.label != "recoveryHPKEPrivateKey"
    })
}
