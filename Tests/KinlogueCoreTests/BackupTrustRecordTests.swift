import Foundation
import Testing
@testable import KinlogueCore

@Test
func descriptorAuthorizationEnvelopeAndFooterAreStrictCanonicalRecords() throws {
    let descriptor = try sampleDescriptor()
    let authorization = try sampleAuthorization()
    let envelope = try BackupHPKEEnvelope(
        encapsulatedKey: Data(repeating: 0x41, count: 32),
        sealedKey: Data(repeating: 0x42, count: 48)
    )
    let commitment = try BackupCiphertextCommitment(
        digest: Data(repeating: 0x43, count: 32),
        ciphertextByteCount: 1_024
    )
    let footer = try BackupCheckpointFooter(
        descriptorDigest: Data(repeating: 0x44, count: 32),
        authorizationDigest: Data(repeating: 0x45, count: 32),
        prologueDigest: Data(repeating: 0x46, count: 32),
        envelopeDigest: Data(repeating: 0x47, count: 32),
        commitment: commitment,
        deviceSignature: Data(repeating: 0x48, count: 64)
    )

    #expect(try BackupSetDescriptor.decodeCanonical(descriptor.canonicalBytes) == descriptor)
    #expect(try BackupDeviceAuthorization.decodeCanonical(authorization.canonicalBytes) == authorization)
    #expect(try BackupHPKEEnvelope.decodeCanonical(envelope.canonicalBytes) == envelope)
    #expect(try BackupCheckpointFooter.decodeCanonical(footer.canonicalBytes) == footer)

    #expect(throws: BackupContractError.self) {
        _ = try BackupSetDescriptor.decodeCanonical(descriptor.canonicalBytes + Data([0]))
    }
    #expect(throws: BackupContractError.self) {
        _ = try BackupDeviceAuthorization.decodeCanonical(authorization.canonicalBytes + Data([0]))
    }
    #expect(throws: BackupContractError.self) {
        _ = try BackupHPKEEnvelope.decodeCanonical(envelope.canonicalBytes + Data([0]))
    }
    #expect(throws: BackupContractError.self) {
        _ = try BackupCheckpointFooter.decodeCanonical(footer.canonicalBytes + Data([0]))
    }
}

@Test
func trustRecordsRejectWrongSizesUnknownSuiteAndNonRandomIdentifiers() throws {
    #expect(throws: BackupContractError.self) {
        _ = try BackupSetID(bytes: Data(repeating: 0, count: 16))
    }
    #expect(throws: BackupContractError.self) {
        _ = try BackupDeviceID(bytes: Data(repeating: 1, count: 15))
    }
    #expect(throws: BackupContractError.self) {
        _ = try BackupSetDescriptor(
            setID: .init(bytes: Data(repeating: 1, count: 16)),
            recoverySigningPublicKey: Data(repeating: 2, count: 31),
            recoveryHPKEPublicKey: Data(repeating: 3, count: 32),
            rootSignature: Data(repeating: 4, count: 64)
        )
    }
    #expect(throws: BackupContractError.self) {
        _ = try BackupHPKEEnvelope(
            encapsulatedKey: Data(repeating: 1, count: BackupFormatLimits.maximumHPKEEncapsulatedKeyByteCount + 1),
            sealedKey: Data(repeating: 2, count: 48)
        )
    }

    let envelope = try BackupHPKEEnvelope(
        encapsulatedKey: Data(repeating: 1, count: 32),
        sealedKey: Data(repeating: 2, count: 48)
    )
    var maliciousLength = envelope.canonicalBytes
    maliciousLength.replaceSubrange(16..<24, with: Data(repeating: 0xFF, count: 8))
    #expect(throws: BackupContractError.self) {
        _ = try BackupHPKEEnvelope.decodeCanonical(maliciousLength)
    }

    var unknownSuite = try sampleDescriptor().canonicalBytes
    unknownSuite.replaceSubrange(14..<16, with: [0xFF, 0xFF])
    #expect(throws: BackupContractError.self) {
        _ = try BackupSetDescriptor.decodeCanonical(unknownSuite)
    }
}

@Test
func transcriptFramingSeparatesRolesAndAmbiguousFieldConcatenations() throws {
    let first = try BackupCanonicalTranscript(role: .hpkeInfo, fields: [Data("ab".utf8), Data("c".utf8)])
    let ambiguousWithoutLengths = try BackupCanonicalTranscript(role: .hpkeInfo, fields: [Data("a".utf8), Data("bc".utf8)])
    let otherRole = try BackupCanonicalTranscript(role: .frameAdditionalAuthenticatedData, fields: first.fields)

    #expect(first.canonicalBytes != ambiguousWithoutLengths.canonicalBytes)
    #expect(first.canonicalBytes != otherRole.canonicalBytes)
    #expect(try BackupCanonicalTranscript.decodeCanonical(first.canonicalBytes) == first)
    #expect(throws: BackupContractError.self) {
        _ = try BackupCanonicalTranscript.decodeCanonical(Data(first.canonicalBytes.dropLast()))
    }
    #expect(throws: BackupContractError.self) {
        _ = try BackupCanonicalTranscript.decodeCanonical(first.canonicalBytes + Data([0]))
    }

    var unknownRole = first.canonicalBytes
    let roleOffset = 8 + 8 + BackupCanonicalTranscript.productIdentifier.utf8.count
        + 8 + BackupCanonicalTranscript.protocolIdentifier.utf8.count + 6
    unknownRole.replaceSubrange(roleOffset..<(roleOffset + 2), with: [0xFF, 0xFF])
    #expect(throws: BackupContractError.self) {
        _ = try BackupCanonicalTranscript.decodeCanonical(unknownRole)
    }
}

@Test
func trustSignatureTranscriptsAreDomainSeparatedAndExcludeSignatureBytes() throws {
    let descriptor = try sampleDescriptor()
    let authorization = try sampleAuthorization()
    let otherSetAuthorization = try sampleAuthorization(setByte: 0x29)
    let commitment = try BackupCiphertextCommitment(
        digest: Data(repeating: 0x51, count: 32),
        ciphertextByteCount: 99
    )
    let footer = try BackupCheckpointFooter(
        descriptorDigest: Data(repeating: 0x52, count: 32),
        authorizationDigest: Data(repeating: 0x53, count: 32),
        prologueDigest: Data(repeating: 0x54, count: 32),
        envelopeDigest: Data(repeating: 0x55, count: 32),
        commitment: commitment,
        deviceSignature: Data(repeating: 0x56, count: 64)
    )

    #expect(descriptor.signatureTranscript.role == .backupSetDescriptorSignature)
    #expect(authorization.signatureTranscript.role == .deviceAuthorizationSignature)
    #expect(footer.signatureTranscript.role == .checkpointCommitSignature)
    #expect(descriptor.signatureTranscript.canonicalBytes != authorization.signatureTranscript.canonicalBytes)
    #expect(authorization.signatureTranscript.canonicalBytes != footer.signatureTranscript.canonicalBytes)
    #expect(authorization.signatureTranscript.canonicalBytes != otherSetAuthorization.signatureTranscript.canonicalBytes)
}

@Test
func automationDefaultsOffAndErrorsRemainSemantic() throws {
    let configuration = BackupAutomationConfiguration()
    #expect(configuration.isAutomaticBackupEnabled == false)
    #expect(configuration.retentionCount.value == 5)
    #expect(BackupCloudPropagationStatus.unknown.rawValue == "unknown")
    #expect(BackupSemanticError.repositoryOffline.rawValue == "repositoryOffline")
}

private func sampleDescriptor() throws -> BackupSetDescriptor {
    try BackupSetDescriptor(
        setID: .init(bytes: Data(repeating: 0x11, count: 16)),
        recoverySigningPublicKey: Data(repeating: 0x12, count: 32),
        recoveryHPKEPublicKey: Data(repeating: 0x13, count: 32),
        rootSignature: Data(repeating: 0x14, count: 64)
    )
}

private func sampleAuthorization(setByte: UInt8 = 0x22) throws -> BackupDeviceAuthorization {
    try BackupDeviceAuthorization(
        descriptorDigest: Data(repeating: 0x21, count: 32),
        setID: .init(bytes: Data(repeating: setByte, count: 16)),
        authorizationID: .init(bytes: Data(repeating: 0x23, count: 16)),
        deviceID: .init(bytes: Data(repeating: 0x24, count: 16)),
        deviceSigningPublicKey: Data(repeating: 0x25, count: 32),
        sequenceFloor: 7,
        rootSignature: Data(repeating: 0x26, count: 64)
    )
}
