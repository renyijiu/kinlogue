import Darwin
import Foundation
import Testing

@Suite(.serialized)
struct BackupCapabilityActivationProbeTests {
    private static let expectedGoldenVectorSHA256 =
        "25d744f5f364f17b6985f761a89fd3b21ad5b25895a3c231037115f9dafd6bbd"

    @Test
    func privateIdentityIsCanonicalPrivateAndStableAcrossUpgrade() async throws {
        try await withCapabilityDirectory { directory in
            let created = try decode(
                IdentityVerification.self,
                from: runProbe(["identity-create"], workingDirectory: directory)
            )
            #expect(created.status == "passed")
            #expect(created.generation == 1)
            #expect(created.parentMode == 0o700)
            #expect(created.recordMode == 0o600)
            let seed = directory.appendingPathComponent("synthetic-recovery-seed.bin")
            let seedAttributes = try FileManager.default.attributesOfItem(atPath: seed.path)
            #expect((seedAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            #expect((seedAttributes[.size] as? NSNumber)?.intValue == 32)

            let relaunched = try decode(
                IdentityVerification.self,
                from: runProbe(["identity-read"], workingDirectory: directory)
            )
            #expect(relaunched.generation == 1)
            #expect(relaunched.publicIdentity == created.publicIdentity)
            #expect(relaunched.descriptorDigest == created.descriptorDigest)

            let upgraded = try decode(
                IdentityVerification.self,
                from: runProbe(["identity-upgrade"], workingDirectory: directory)
            )
            #expect(upgraded.generation == 2)
            #expect(upgraded.publicIdentity == created.publicIdentity)
            #expect(upgraded.descriptorDigest == created.descriptorDigest)

            let identity = directory.appendingPathComponent("device-identity.json")
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: identity.path
            )
            let rejected = try runProbeExpectingFailure(
                ["identity-read"],
                workingDirectory: directory
            )
            #expect(try decode(ProbeFailure.self, from: rejected).code
                == "identityPermissionFailure")
        }
    }

    @Test
    func privateIdentityRejectsMissingCorruptLinksAndParentPermissionChanges() async throws {
        try await withCapabilityDirectory { directory in
            let missing = try runProbeExpectingFailure(
                ["identity-read"],
                workingDirectory: directory
            )
            #expect(try decode(ProbeFailure.self, from: missing).code == "identityInvalid")
        }

        try await withCapabilityDirectory { directory in
            try runProbe(["identity-create"], workingDirectory: directory)
            let identity = directory.appendingPathComponent("device-identity.json")
            try overwrite(identity, with: Data("truncated".utf8))
            let corrupt = try runProbeExpectingFailure(
                ["identity-read"],
                workingDirectory: directory
            )
            #expect(try decode(ProbeFailure.self, from: corrupt).code == "identityInvalid")
        }

        try await withCapabilityDirectory { directory in
            try runProbe(["identity-create"], workingDirectory: directory)
            let identity = directory.appendingPathComponent("device-identity.json")
            try FileManager.default.linkItem(
                at: identity,
                to: directory.appendingPathComponent("second-link")
            )
            let linked = try runProbeExpectingFailure(
                ["identity-read"],
                workingDirectory: directory
            )
            #expect(try decode(ProbeFailure.self, from: linked).code == "identityInvalid")
        }

        try await withCapabilityDirectory { directory in
            try runProbe(["identity-create"], workingDirectory: directory)
            let identity = directory.appendingPathComponent("device-identity.json")
            let target = directory.appendingPathComponent("identity-target")
            try FileManager.default.moveItem(at: identity, to: target)
            try FileManager.default.createSymbolicLink(at: identity, withDestinationURL: target)
            let linked = try runProbeExpectingFailure(
                ["identity-read"],
                workingDirectory: directory
            )
            #expect(try decode(ProbeFailure.self, from: linked).code == "identityInvalid")
        }

        try await withCapabilityDirectory { directory in
            try runProbe(["identity-create"], workingDirectory: directory)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: directory.path
            )
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: directory.path
                )
            }
            let permission = try runProbeExpectingFailure(
                ["identity-read"],
                workingDirectory: directory
            )
            #expect(try decode(ProbeFailure.self, from: permission).code
                == "identityPermissionFailure")
        }

        try await withCapabilityDirectory { directory in
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: directory.path
            )
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: directory.path
                )
            }
            let permission = try runProbeExpectingFailure(
                ["identity-create"],
                workingDirectory: directory
            )
            #expect(try decode(ProbeFailure.self, from: permission).code
                == "identityPermissionFailure")
            #expect(!FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("device-identity.json").path
            ))
        }

        try await withCapabilityDirectory { directory in
            try runProbe(["identity-create"], workingDirectory: directory)
            let identity = directory.appendingPathComponent("device-identity.json")
            let source = try Data(contentsOf: identity)
            var object = try #require(
                JSONSerialization.jsonObject(with: source) as? [String: Any]
            )
            object["descriptorPublicKey"] = Data(repeating: 0x5a, count: 32)
                .base64EncodedString()
            let substituted = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
            try overwrite(identity, with: substituted)
            let mismatch = try runProbeExpectingFailure(
                ["identity-read"],
                workingDirectory: directory
            )
            #expect(try decode(ProbeFailure.self, from: mismatch).code
                == "identityInvalid")
        }

        for kind in ["directory", "fifo"] {
            try await withCapabilityDirectory { directory in
                try runProbe(["identity-create"], workingDirectory: directory)
                let identity = directory.appendingPathComponent("device-identity.json")
                try FileManager.default.removeItem(at: identity)
                if kind == "directory" {
                    try FileManager.default.createDirectory(at: identity, withIntermediateDirectories: false)
                } else {
                    #expect(mkfifo(identity.path, mode_t(0o600)) == 0)
                }
                let rejected = try runProbeExpectingFailure(
                    ["identity-read"],
                    workingDirectory: directory
                )
                #expect(try decode(ProbeFailure.self, from: rejected).code == "identityInvalid")
            }
        }
    }

    @Test
    func identityDescriptorRootRejectsDeterministicParentAndLeafReplacement() async throws {
        for operationAndCase in [
            ("identity-read", "parent-replacement"),
            ("identity-read", "leaf-replacement"),
            ("identity-upgrade", "leaf-replacement"),
        ] {
            try await withCapabilityDirectory { directory in
                let created = try decode(
                    IdentityVerification.self,
                    from: runProbe(["identity-create"], workingDirectory: directory)
                )
                let rejected = try runProbeExpectingFailure(
                    [operationAndCase.0, "--case-id", operationAndCase.1],
                    workingDirectory: directory
                )
                #expect(try decode(ProbeFailure.self, from: rejected).code == "identityInvalid")

                let unchanged = try decode(
                    IdentityVerification.self,
                    from: runProbe(["identity-read"], workingDirectory: directory)
                )
                #expect(unchanged.generation == created.generation)
                #expect(unchanged.publicIdentity == created.publicIdentity)
                #expect(unchanged.descriptorDigest == created.descriptorDigest)
            }
        }
    }

    @Test
    func privateIdentityRejectsDescriptorRootSignatureAndAuthorizationSubstitution() async throws {
        try await expectIdentityMutationRejected { object in
            var descriptor = try #require(object["descriptor"] as? [String: Any])
            descriptor["recipientPublicKey"] = Data(repeating: 0x31, count: 32)
                .base64EncodedString()
            object["descriptor"] = descriptor
        }
        try await expectIdentityMutationRejected { object in
            var descriptor = try #require(object["descriptor"] as? [String: Any])
            descriptor["signingPublicKey"] = Data(repeating: 0x32, count: 32)
                .base64EncodedString()
            object["descriptor"] = descriptor
        }
        try await expectIdentityMutationRejected { object in
            let encodedSignature = try #require(object["descriptorSignature"] as? String)
            var signature = try #require(Data(base64Encoded: encodedSignature))
            signature[0] ^= 0x01
            object["descriptorSignature"] = signature.base64EncodedString()
        }
        try await expectIdentityMutationRejected { object in
            var authorization = try #require(object["authorization"] as? [String: Any])
            authorization["devicePublicKey"] = Data(repeating: 0x33, count: 32)
                .base64EncodedString()
            object["authorization"] = authorization
        }
    }

    @Test
    func isolatedPublicWriterCannotDecryptAndSeedOnlyProcessRecovers() async throws {
        try await withCapabilityDirectory { enrollmentDirectory in
            try await withCapabilityDirectory { writerDirectory in
                try await withCapabilityDirectory { recoveryDirectory in
                    try runProbe(["identity-create"], workingDirectory: enrollmentDirectory)
                    try copyPrivateFile(
                        named: "device-identity.json",
                        from: enrollmentDirectory,
                        to: writerDirectory
                    )

                    let writerOutput = try runProbe(
                        ["crypto-public-writer"],
                        workingDirectory: writerDirectory
                    )
                    let writer = try decode(PublicWriterVerification.self, from: writerOutput)
                    #expect(writer.status == "passed")
                    #expect(writer.publicOnlyEncrypted)
                    #expect(!writer.profileContainedRecoveryMaterial)
                    #expect(!FileManager.default.fileExists(
                        atPath: writerDirectory
                            .appendingPathComponent("synthetic-recovery-seed.bin").path
                    ))

                    let deniedOutput = try runProbeExpectingFailure(
                        ["crypto-public-decrypt"],
                        workingDirectory: writerDirectory
                    )
                    let denied = try decode(ProbeFailure.self, from: deniedOutput)
                    #expect(denied.code == "recoveryMaterialUnavailable")

                    try copyPrivateFile(
                        named: "synthetic-recovery-seed.bin",
                        from: enrollmentDirectory,
                        to: recoveryDirectory
                    )
                    try copyPrivateFile(
                        named: "synthetic-checkpoint.json",
                        from: writerDirectory,
                        to: recoveryDirectory
                    )
                    let recoveryOutput = try runProbe(
                        ["crypto-seed-recover"],
                        workingDirectory: recoveryDirectory
                    )
                    let recovered = try decode(
                        SeedOnlyRecoveryVerification.self,
                        from: recoveryOutput
                    )
                    #expect(recovered.status == "passed")
                    #expect(recovered.seedOnlyRecovered)
                    #expect(recovered.rootSignatureVerified)
                    #expect(recovered.deviceSignatureVerified)
                    #expect(recovered.reenrollmentVerified)
                    #expect(recovered.checkpointDigest == writer.checkpointDigest)
                    #expect(!FileManager.default.fileExists(
                        atPath: recoveryDirectory
                            .appendingPathComponent("device-identity.json").path
                    ))
                    #expect(!FileManager.default.fileExists(
                        atPath: recoveryDirectory
                            .appendingPathComponent("directory.bookmark").path
                    ))

                    let artifact = try Data(contentsOf: writerDirectory.appendingPathComponent(
                        "synthetic-checkpoint.json"
                    ))
                    let artifactAttributes = try FileManager.default.attributesOfItem(
                        atPath: writerDirectory.appendingPathComponent(
                            "synthetic-checkpoint.json"
                        ).path
                    )
                    #expect((artifactAttributes[.posixPermissions] as? NSNumber)?.intValue
                        == 0o600)
                    let object = try #require(
                        JSONSerialization.jsonObject(with: artifact) as? [String: Any]
                    )
                    let keys = recursiveJSONKeys(object)
                    for forbidden in [
                        "recoverySeed", "recoveryCode", "signingPrivateKey",
                        "recipientPrivateKey", "deviceSigningSeed", "dek", "plaintext",
                    ] {
                        #expect(!keys.contains(forbidden))
                    }
                    let writerProfile = try #require(
                        JSONSerialization.jsonObject(
                            with: Data(contentsOf: writerDirectory.appendingPathComponent(
                                "device-identity.json"
                            ))
                        ) as? [String: Any]
                    )
                    let writerProfileKeys = recursiveJSONKeys(writerProfile)
                    for forbidden in [
                        "recoverySeed", "recoveryCode", "signingPrivateKey",
                        "recipientPrivateKey", "dek", "plaintext",
                    ] {
                        #expect(!writerProfileKeys.contains(forbidden))
                    }
                    #expect(!writerOutput.contains(enrollmentDirectory.path))
                    #expect(!writerOutput.contains(writerDirectory.path))
                    #expect(!recoveryOutput.contains(recoveryDirectory.path))
                }
            }
        }
    }

    @Test
    func seedOnlyRecoveryRejectsCorruptAndTruncatedCheckpointArtifacts() async throws {
        try await withCapabilityDirectory { enrollmentDirectory in
            try await withCapabilityDirectory { writerDirectory in
                try await withCapabilityDirectory { recoveryDirectory in
                    try runProbe(["identity-create"], workingDirectory: enrollmentDirectory)
                    try copyPrivateFile(
                        named: "device-identity.json",
                        from: enrollmentDirectory,
                        to: writerDirectory
                    )
                    try runProbe(["crypto-public-writer"], workingDirectory: writerDirectory)
                    try copyPrivateFile(
                        named: "synthetic-recovery-seed.bin",
                        from: enrollmentDirectory,
                        to: recoveryDirectory
                    )
                    try copyPrivateFile(
                        named: "synthetic-checkpoint.json",
                        from: writerDirectory,
                        to: recoveryDirectory
                    )
                    let checkpoint = recoveryDirectory.appendingPathComponent(
                        "synthetic-checkpoint.json"
                    )
                    let original = try Data(contentsOf: checkpoint)
                    var object = try #require(
                        JSONSerialization.jsonObject(with: original) as? [String: Any]
                    )
                    let encodedCiphertext = try #require(object["ciphertext"] as? String)
                    var ciphertext = try #require(Data(base64Encoded: encodedCiphertext))
                    ciphertext[0] ^= 0x01
                    object["ciphertext"] = ciphertext.base64EncodedString()
                    try overwrite(
                        checkpoint,
                        with: try JSONSerialization.data(
                            withJSONObject: object,
                            options: [.sortedKeys, .withoutEscapingSlashes]
                        )
                    )
                    let corrupt = try runProbeExpectingFailure(
                        ["crypto-seed-recover"],
                        workingDirectory: recoveryDirectory
                    )
                    #expect(try decode(ProbeFailure.self, from: corrupt).code
                        == "cryptoProfileInvalid")

                    try overwrite(checkpoint, with: original.prefix(32))
                    let truncated = try runProbeExpectingFailure(
                        ["crypto-seed-recover"],
                        workingDirectory: recoveryDirectory
                    )
                    #expect(try decode(ProbeFailure.self, from: truncated).code
                        == "cryptoProfileInvalid")
                }
            }
        }
    }

    @Test
    func repositoryPublishesOpaqueFinalWithoutOverwriteAndFreezesCapacityFormula() async throws {
        try await withCapabilityDirectory { directory in
            let output = try runProbe(
                ["repository-publication"],
                workingDirectory: directory
            )
            let verified = try decode(RepositoryVerification.self, from: output)
            #expect(verified.status == "passed")
            #expect(verified.nonSuccessWorkName)
            #expect(verified.exclusiveNonOverwrite)
            #expect(verified.finalIdentityReadBack)
            #expect(verified.parentSynced)
            #expect(verified.plaintextCanaryAbsent)
            #expect(verified.maximumSourceObjectCount == 20_000)
            #expect(verified.maximumSourceByteCount == 2_147_483_648)
            #expect(verified.targetRequiredByteCount > verified.maximumSourceByteCount)
            #expect(verified.privateRestoreRequiredByteCount
                > verified.targetRequiredByteCount)
            #expect(!output.contains(directory.path))
        }
    }

    @Test
    func repositoryDescriptorRootRejectsHostileParentsAndLeavesWithoutEscaping() async throws {
        for caseID in ["parent-replacement", "final-replacement"] {
            try await withCapabilityDirectory { directory in
                let outside = directory.appendingPathComponent("outside-sentinel")
                let expected = Data("outside-must-not-change".utf8)
                try expected.write(to: outside, options: .withoutOverwriting)
                let rejected = try runProbeExpectingFailure(
                    ["repository-publication", "--case-id", caseID],
                    workingDirectory: directory
                )
                #expect(try decode(ProbeFailure.self, from: rejected).code == "repositoryInvalid")
                #expect(try Data(contentsOf: outside) == expected)
                if caseID == "parent-replacement" {
                    #expect(!FileManager.default.fileExists(
                        atPath: directory
                            .appendingPathComponent("repository", isDirectory: true)
                            .appendingPathComponent("u0-checkpoint.kinloguebackup").path
                    ))
                }
            }
        }

        for kind in ["symlink", "directory", "fifo", "hardlink", "regular"] {
            try await withCapabilityDirectory { directory in
                let repository = directory.appendingPathComponent("repository", isDirectory: true)
                try FileManager.default.createDirectory(
                    at: repository,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
                let outside = directory.appendingPathComponent("outside-sentinel")
                let expected = Data("outside-must-not-change".utf8)
                try expected.write(to: outside, options: .withoutOverwriting)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: outside.path
                )
                let final = repository.appendingPathComponent("u0-checkpoint.kinloguebackup")
                switch kind {
                case "symlink":
                    try FileManager.default.createSymbolicLink(at: final, withDestinationURL: outside)
                case "directory":
                    try FileManager.default.createDirectory(at: final, withIntermediateDirectories: false)
                case "fifo":
                    #expect(mkfifo(final.path, mode_t(0o600)) == 0)
                case "hardlink":
                    try FileManager.default.linkItem(at: outside, to: final)
                default:
                    try expected.write(to: final, options: .withoutOverwriting)
                    try FileManager.default.setAttributes(
                        [.posixPermissions: 0o600],
                        ofItemAtPath: final.path
                    )
                }

                let rejected = try runProbeExpectingFailure(
                    ["repository-publication"],
                    workingDirectory: directory
                )
                #expect(try decode(ProbeFailure.self, from: rejected).code == "repositoryInvalid")
                #expect(try Data(contentsOf: outside) == expected)
                #expect(FileManager.default.fileExists(atPath: final.path))
            }
        }
    }

    @Test
    func selectedOrdinaryDirectoryPublishesAcrossRelaunchWithSeparateCapacities() async throws {
        try await withCapabilityDirectory { appPrivateDirectory in
            try await withCapabilityDirectory { selectedDirectory in
                let unrelated = selectedDirectory.appendingPathComponent("unrelated-user-file")
                let unrelatedBytes = Data("must-remain-untouched".utf8)
                try unrelatedBytes.write(to: unrelated, options: .withoutOverwriting)

                let baselineOutput = try runProbe(
                    [
                        "selected-target-publication", "--case-id", "baseline",
                        "--candidate-directory", selectedDirectory.path,
                    ],
                    workingDirectory: appPrivateDirectory
                )
                let baseline = try decode(
                    SelectedTargetRepositoryVerification.self,
                    from: baselineOutput
                )
                #expect(baseline.status == "passed")
                #expect(baseline.targetCategory == "ordinaryDirectory")
                #expect(baseline.testBookmarkSeam)
                #expect(!baseline.securityScopeStarted)
                #expect(!baseline.coordinatedPublication)
                #expect(baseline.selectedIdentityMatched)
                #expect(baseline.repositoryIdentityMatched)
                #expect(baseline.exclusiveNonOverwrite)
                #expect(baseline.finalIdentityReadBack)
                #expect(baseline.parentSynced)
                #expect(baseline.plaintextCanaryAbsent)
                #expect(baseline.targetAvailableCapacitySufficient)
                #expect(baseline.privateRestoreAvailableCapacitySufficient)
                #expect(baseline.targetAvailableCapacityByteCount > 0)
                #expect(baseline.privateRestoreAvailableCapacityByteCount > 0)

                let relaunchedOutput = try runProbe(
                    [
                        "selected-target-publication", "--case-id", "upgrade",
                        "--candidate-directory", selectedDirectory.path,
                    ],
                    workingDirectory: appPrivateDirectory
                )
                let relaunched = try decode(
                    SelectedTargetRepositoryVerification.self,
                    from: relaunchedOutput
                )
                #expect(relaunched.status == "passed")
                #expect(relaunched.repositoryIdentityMatched)

                let repository = selectedDirectory.appendingPathComponent(
                    ".kinlogue-backup-capability-u0",
                    isDirectory: true
                )
                #expect(FileManager.default.fileExists(
                    atPath: repository.appendingPathComponent(
                        "u0-baseline.kinloguebackup"
                    ).path
                ))
                #expect(FileManager.default.fileExists(
                    atPath: repository.appendingPathComponent(
                        "u0-upgrade.kinloguebackup"
                    ).path
                ))
                #expect(try Data(contentsOf: unrelated) == unrelatedBytes)
                #expect(!baselineOutput.contains(selectedDirectory.path))
                #expect(!baselineOutput.contains(appPrivateDirectory.path))
                #expect(!relaunchedOutput.contains(selectedDirectory.path))

                let persistedState = try String(
                    contentsOf: appPrivateDirectory.appendingPathComponent(
                        "directory.bookmark"
                    ),
                    encoding: .utf8
                )
                #expect(!persistedState.contains(selectedDirectory.path))
            }
        }
    }

    @Test
    func selectedOrdinaryDirectoryRejectsReplacementsAndHostileLeavesWithoutEscaping() async throws {
        try await withCapabilityDirectory { appPrivateDirectory in
            try await withCapabilityDirectory { selectedDirectory in
                try runProbe(
                    [
                        "selected-target-publication", "--case-id", "initial",
                        "--candidate-directory", selectedDirectory.path,
                    ],
                    workingDirectory: appPrivateDirectory
                )
                let repository = selectedDirectory.appendingPathComponent(
                    ".kinlogue-backup-capability-u0",
                    isDirectory: true
                )
                let unrelated = selectedDirectory.appendingPathComponent("unrelated-user-file")
                let unrelatedBytes = Data("must-remain-untouched".utf8)
                try unrelatedBytes.write(to: unrelated, options: .withoutOverwriting)

                for caseID in ["parent-replacement", "final-replacement"] {
                    let rejected = try runProbeExpectingFailure(
                        [
                            "selected-target-publication", "--case-id", caseID,
                            "--candidate-directory", selectedDirectory.path,
                        ],
                        workingDirectory: appPrivateDirectory
                    )
                    #expect(try decode(ProbeFailure.self, from: rejected).code
                        == "repositoryInvalid")
                    #expect(try Data(contentsOf: unrelated) == unrelatedBytes)
                    #expect(!FileManager.default.fileExists(
                        atPath: repository.appendingPathComponent(
                            ".u0-\(caseID).opaque-work"
                        ).path
                    ))
                }

                let heldRepository = selectedDirectory.appendingPathComponent(
                    ".kinlogue-backup-capability-u0-held",
                    isDirectory: true
                )
                try FileManager.default.moveItem(at: repository, to: heldRepository)
                try FileManager.default.createDirectory(
                    at: repository,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
                let replacedRepository = try runProbeExpectingFailure(
                    [
                        "selected-target-publication", "--case-id", "repository-replaced",
                        "--candidate-directory", selectedDirectory.path,
                    ],
                    workingDirectory: appPrivateDirectory
                )
                #expect(try decode(ProbeFailure.self, from: replacedRepository).code
                    == "repositoryInvalid")
                #expect(try FileManager.default.contentsOfDirectory(
                    atPath: repository.path
                ).isEmpty)
                try FileManager.default.removeItem(at: repository)
                try FileManager.default.moveItem(at: heldRepository, to: repository)

                let heldSelected = selectedDirectory.deletingLastPathComponent()
                    .appendingPathComponent(
                        "\(selectedDirectory.lastPathComponent)-held",
                        isDirectory: true
                    )
                try FileManager.default.moveItem(at: selectedDirectory, to: heldSelected)
                try FileManager.default.createDirectory(
                    at: selectedDirectory,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
                let replacedSelected = try runProbeExpectingFailure(
                    [
                        "selected-target-publication", "--case-id", "selected-replaced",
                        "--candidate-directory", selectedDirectory.path,
                    ],
                    workingDirectory: appPrivateDirectory
                )
                #expect(try decode(ProbeFailure.self, from: replacedSelected).code
                    == "bookmarkInvalid")
                #expect(try FileManager.default.contentsOfDirectory(
                    atPath: selectedDirectory.path
                ).isEmpty)
                try FileManager.default.removeItem(at: selectedDirectory)
                try FileManager.default.moveItem(at: heldSelected, to: selectedDirectory)
            }
        }

        for kind in ["symlink", "directory", "fifo", "hardlink", "regular"] {
            try await withCapabilityDirectory { appPrivateDirectory in
                try await withCapabilityDirectory { selectedDirectory in
                    try runProbe(
                        [
                            "selected-target-publication", "--case-id", "initial",
                            "--candidate-directory", selectedDirectory.path,
                        ],
                        workingDirectory: appPrivateDirectory
                    )
                    let repository = selectedDirectory.appendingPathComponent(
                        ".kinlogue-backup-capability-u0",
                        isDirectory: true
                    )
                    let unrelated = selectedDirectory.appendingPathComponent("unrelated-user-file")
                    let unrelatedBytes = Data("must-remain-untouched".utf8)
                    try unrelatedBytes.write(to: unrelated, options: .withoutOverwriting)
                    try FileManager.default.setAttributes(
                        [.posixPermissions: 0o600],
                        ofItemAtPath: unrelated.path
                    )
                    let final = repository.appendingPathComponent(
                        "u0-hostile.kinloguebackup"
                    )
                    switch kind {
                    case "symlink":
                        try FileManager.default.createSymbolicLink(
                            at: final,
                            withDestinationURL: unrelated
                        )
                    case "directory":
                        try FileManager.default.createDirectory(
                            at: final,
                            withIntermediateDirectories: false
                        )
                    case "fifo":
                        #expect(mkfifo(final.path, mode_t(0o600)) == 0)
                    case "hardlink":
                        try FileManager.default.linkItem(at: unrelated, to: final)
                    default:
                        try unrelatedBytes.write(to: final, options: .withoutOverwriting)
                        try FileManager.default.setAttributes(
                            [.posixPermissions: 0o600],
                            ofItemAtPath: final.path
                        )
                    }

                    let rejected = try runProbeExpectingFailure(
                        [
                            "selected-target-publication", "--case-id", "hostile",
                            "--candidate-directory", selectedDirectory.path,
                        ],
                        workingDirectory: appPrivateDirectory
                    )
                    #expect(try decode(ProbeFailure.self, from: rejected).code
                        == "repositoryInvalid")
                    #expect(try Data(contentsOf: unrelated) == unrelatedBytes)
                    #expect(FileManager.default.fileExists(atPath: final.path))
                }
            }
        }
    }

    @Test
    func activationWaitsForRealWriterAndRejectsItsPostSwapCommit() async throws {
        try await withCapabilityDirectory { directory in
            let caseID = "real-writer"
            try runProbe(
                [
                    "activation-seed-writer", "--scenario", "existing",
                    "--case-id", caseID,
                ],
                workingDirectory: directory
            )
            let current = directory
                .appendingPathComponent("activation-\(caseID)", isDirectory: true)
                .appendingPathComponent("Vault", isDirectory: true)

            try await withStorageProcessFixture(processCount: 1) { processes in
                let writer = processes[0]
                try writer.send(.init(operation: "loadCatalog", rootURL: current))
                #expect(try await writer.nextResponse().event == "catalogLoaded")
                try writer.send(.init(operation: "holdCatalogCommit", variant: 1))
                #expect(try await writer.nextResponse().event == "leaseHeld")

                let activation = try startProbe(
                    [
                        "activation-execute", "--scenario", "existing",
                        "--case-id", caseID, "--fault", "none",
                    ],
                    workingDirectory: directory
                )
                try await Task.sleep(for: .milliseconds(250))
                #expect(activation.isRunning)
                #expect(FileManager.default.fileExists(
                    atPath: current.appendingPathComponent("library.json").path
                ))

                try writer.send(.init(operation: "release"))
                #expect(try await writer.nextResponse().event == "catalogCommitted")
                let activated = try activation.finish(timeout: .seconds(10))
                #expect(activated.terminationReason == .exit)
                #expect(activated.terminationStatus == 0, "\(activated.standardOutput)")

                let before = try FileManager.default.contentsOfDirectory(atPath: current.path)
                #expect(Set(before).isSuperset(of: ["library.json", "objects", "lan-inbox"]))
                #expect(!before.contains("root-state.json"))
                try writer.send(.init(operation: "commitLoadedCatalog", variant: 2))
                let rejected = try await writer.nextResponse()
                #expect(rejected.event == "operationFailed")
                #expect(rejected.code == "rootReplaced")
                #expect(try FileManager.default.contentsOfDirectory(atPath: current.path) == before)

                let output = try runProbe(
                    ["activation-verify", "--case-id", caseID],
                    workingDirectory: directory
                )
                let verified = try decode(ActivationVerification.self, from: output)
                #expect(verified.rootState == "new")
                #expect(!verified.mixedState)
                #expect(!verified.receiptPresent)
                #expect(!verified.stagingPresent)
                #expect(!verified.rollbackPresent)
                #expect(verified.semanticValidated)
                #expect(verified.vaultGeneration > 1)
                #expect(verified.inboxGeneration > 1)
                #expect(verified.vaultObjectCount == 1)
                #expect(verified.inboxItemCount == 1)
                #expect(verified.inboxBlobCount == 1)
                #expect(verified.inboxTerminalCount == 1)
            }
        }
    }

    @Test
    func productionFaultsWithExistingRootReconcileToTheirExactTerminalRoot() async throws {
        try await verifyActivationFaults(
            scenario: "existing",
            expectedRootStates: [
                "after-intent": "old",
                "after-writer-reset": "old",
                "after-old-root-move": "old",
                "after-new-root-activation": "new",
                "after-validation": "new",
                "after-commit": "new",
            ]
        )
    }

    @Test
    func productionFaultsWithAbsentRootReconcileToTheirExactTerminalRoot() async throws {
        try await verifyActivationFaults(
            scenario: "absent",
            expectedRootStates: [
                "after-intent": "absent",
                "after-writer-reset": "absent",
                "after-new-root-activation": "new",
                "after-validation": "new",
                "after-commit": "new",
            ]
        )
    }

    @Test
    func truncatedProductionReceiptFailsClosed() async throws {
        try await withCapabilityDirectory { directory in
            try runProbe(
                ["activation-seed", "--scenario", "existing"],
                workingDirectory: directory
            )
            _ = try run(
                [
                    "activation-execute", "--scenario", "existing",
                    "--fault", "after-intent",
                ],
                workingDirectory: directory
            )
            try runProbe(
                ["activation-truncate-receipt"],
                workingDirectory: directory
            )
            let rejected = try runProbeExpectingFailure(
                ["activation-reconcile"],
                workingDirectory: directory
            )
            #expect(try decode(ProbeFailure.self, from: rejected).code == "receiptInvalid")
            let verified = try runProbe(
                ["activation-verify"],
                workingDirectory: directory
            )
            #expect(try decode(ActivationVerification.self, from: verified).rootState == "old")
        }

    }

    @Test
    func chunkProbeKeepsAllocationBoundedByChunkNotTotalStream() async throws {
        try await withCapabilityDirectory { directory in
            let result = try runProbe(
                ["chunk", "--stream-byte-count", "8388608"],
                workingDirectory: directory,
                timeout: .seconds(30)
            )
            let decoded = try decode(ChunkVerification.self, from: result)
            #expect(decoded.passed)
            #expect(decoded.selectedChunkByteCount == 262_144)
            #expect(decoded.goldenVectorSHA256 == Self.expectedGoldenVectorSHA256)
            #expect(decoded.totalStreamByteCount == 8_388_608)
            #expect(decoded.metrics.count == 3)
            #expect(decoded.metrics.allSatisfy { metric in
                metric.processedByteCount == decoded.totalStreamByteCount
                    && metric.cancellationObserved
                    && metric.cancellationProcessedByteCount == 2 * metric.chunkByteCount
                    && metric.cancellationLatencyMilliseconds <= 1_000
            })
            #expect(!result.contains(directory.path))
        }
    }

    @Test
    func namedDatasetStreamsEncryptsPublishesAndFullyReadsBoundedRecords() async throws {
        try await withCapabilityDirectory { directory in
            let output = try runProbe(
                [
                    "named-dataset", "--object-count", "32",
                    "--stream-byte-count", "8388608",
                ],
                workingDirectory: directory,
                timeout: .seconds(60)
            )
            let verified = try decode(NamedDatasetVerification.self, from: output)
            #expect(verified.passed)
            #expect(verified.format == "KLG-U0-DATASET-PROBE-1")
            #expect(verified.objectCount == 32)
            #expect(verified.plaintextByteCount == 8_388_608)
            #expect(verified.frameCount == 32)
            #expect(verified.selectedChunkByteCount == 262_144)
            #expect(verified.fileByteCount > verified.plaintextByteCount)
            #expect(verified.allocatedByteCount >= verified.plaintextByteCount)
            #expect(verified.backupDurationMilliseconds <= verified.backupBudgetMilliseconds)
            #expect(verified.restoreDurationMilliseconds <= verified.restoreBudgetMilliseconds)
            #expect(verified.peakRSSDeltaBytes <= verified.peakRSSDeltaBudgetBytes)
            #expect(verified.fileDescriptorHighWaterCount <= verified.fileDescriptorBudgetCount)
            #expect(verified.sourceSHA256.count == 64)
            #expect(verified.backupSHA256.count == 64)
            #expect(verified.fullReaderVerified)
            #expect(verified.footerAuthenticated)
            #expect(verified.nonSparse)
            #expect(verified.exclusiveNonOverwrite)
            #expect(verified.cleaned)
            #expect(!resultPathExists(directory, leaf: ".u0-named-dataset.opaque-work"))
            #expect(!resultPathExists(directory, leaf: "u0-named-worst-case.kinloguebackup"))
            #expect(!output.contains(directory.path))

            let secondOutput = try runProbe(
                [
                    "named-dataset", "--object-count", "32",
                    "--stream-byte-count", "8388608",
                ],
                workingDirectory: directory,
                timeout: .seconds(60)
            )
            let second = try decode(NamedDatasetVerification.self, from: secondOutput)
            #expect(second.sourceSHA256 == verified.sourceSHA256)
            #expect(second.backupSHA256 != verified.backupSHA256)
        }
    }

    @Test
    func namedDatasetRejectsCorruptionTruncationCancellationAndDiskFailureWithoutPartials() async throws {
        for caseID in ["corrupt", "truncated", "cancel", "injected-disk-full"] {
            try await withCapabilityDirectory { directory in
                let output = try runProbeExpectingFailure(
                    [
                        "named-dataset", "--object-count", "16",
                        "--stream-byte-count", "2097152", "--case-id", caseID,
                    ],
                    workingDirectory: directory
                )
                let failure = try decode(ProbeFailure.self, from: output)
                #expect(["datasetInvalid", "datasetCancelled", "capacityInsufficient"]
                    .contains(failure.code))
                #expect(!resultPathExists(directory, leaf: ".u0-named-dataset.opaque-work"))
                #expect(!resultPathExists(directory, leaf: "u0-named-worst-case.kinloguebackup"))
                #expect(!output.contains(directory.path))
            }
        }
    }

    @Test
    func namedDatasetNeverOverwritesAnExistingFinalLeaf() async throws {
        try await withCapabilityDirectory { directory in
            let repository = directory.appendingPathComponent("repository", isDirectory: true)
            try FileManager.default.createDirectory(
                at: repository,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let final = repository.appendingPathComponent(
                "u0-named-worst-case.kinloguebackup",
                isDirectory: false
            )
            let sentinel = Data("existing-final-sentinel".utf8)
            try sentinel.write(to: final, options: .withoutOverwriting)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: final.path
            )

            let output = try runProbeExpectingFailure(
                [
                    "named-dataset", "--object-count", "16",
                    "--stream-byte-count", "2097152",
                ],
                workingDirectory: directory
            )
            #expect(try decode(ProbeFailure.self, from: output).code == "datasetInvalid")
            #expect(try Data(contentsOf: final) == sentinel)
            #expect(!resultPathExists(directory, leaf: ".u0-named-dataset.opaque-work"))
        }
    }

    private func resultPathExists(_ directory: URL, leaf: String) -> Bool {
        FileManager.default.fileExists(
            atPath: directory
                .appendingPathComponent("repository", isDirectory: true)
                .appendingPathComponent(leaf, isDirectory: false)
                .path
        )
    }

    private func verifyActivationFaults(
        scenario: String,
        expectedRootStates: [String: String]
    ) async throws {
        for (fault, expectedRootState) in expectedRootStates.sorted(by: { $0.key < $1.key }) {
            try await withCapabilityDirectory { directory in
                try runProbe(
                    ["activation-seed", "--scenario", scenario],
                    workingDirectory: directory
                )
                let crashed = try run(
                    [
                        "activation-execute", "--scenario", scenario,
                        "--fault", fault,
                    ],
                    workingDirectory: directory
                )
                #expect(crashed.terminationReason == .uncaughtSignal)
                #expect(crashed.terminationStatus == SIGKILL)

                try runProbe(["activation-reconcile"], workingDirectory: directory)
                let output = try runProbe(
                    ["activation-verify"],
                    workingDirectory: directory
                )
                let verified = try decode(ActivationVerification.self, from: output)
                #expect(verified.rootState == expectedRootState)
                #expect(!verified.mixedState)
                #expect(!verified.receiptPresent)
                #expect(!verified.stagingPresent)
                #expect(!verified.rollbackPresent)
            }
        }
    }

    private func withCapabilityDirectory(
        _ body: (URL) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent(
                "kinlogue-backup-capability-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }

    @discardableResult
    private func runProbe(
        _ arguments: [String],
        workingDirectory: URL,
        timeout: Duration = .seconds(10)
    ) throws -> String {
        let result = try run(
            arguments,
            workingDirectory: workingDirectory,
            timeout: timeout
        )
        guard result.terminationReason == .exit,
              result.terminationStatus == 0 else {
            throw CapabilityHarnessError.unexpectedExit
        }
        return result.standardOutput
    }

    private func runProbeExpectingFailure(
        _ arguments: [String],
        workingDirectory: URL
    ) throws -> String {
        let result = try run(arguments, workingDirectory: workingDirectory)
        guard result.terminationReason == .exit,
              result.terminationStatus != 0 else {
            throw CapabilityHarnessError.unexpectedExit
        }
        return result.standardOutput
    }

    private func run(
        _ arguments: [String],
        workingDirectory: URL,
        timeout: Duration = .seconds(10)
    ) throws -> CapabilityProcessResult {
        try startProbe(arguments, workingDirectory: workingDirectory).finish(timeout: timeout)
    }

    private func startProbe(
        _ arguments: [String],
        workingDirectory: URL
    ) throws -> CapabilityRunningProcess {
        let executable = try StorageProcessFixture.fixtureExecutableURL(
            testBundleURL: Bundle(for: StorageProcessFixture.self).bundleURL
        )
        let process = Process()
        let standardOutput = Pipe()
        process.executableURL = executable
        process.arguments = [
            "--backup-capability",
            "--working-directory", workingDirectory.path,
        ] + arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = standardOutput
        process.standardError = FileHandle.nullDevice
        try process.run()
        return CapabilityRunningProcess(process: process, standardOutput: standardOutput)
    }

    private func decode<Value: Decodable>(
        _ type: Value.Type,
        from output: String
    ) throws -> Value {
        try JSONDecoder().decode(Value.self, from: Data(output.utf8))
    }

    private func overwrite(_ url: URL, with data: Data) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
    }

    private func copyPrivateFile(named name: String, from source: URL, to destination: URL) throws {
        let destinationURL = destination.appendingPathComponent(name)
        try FileManager.default.copyItem(
            at: source.appendingPathComponent(name),
            to: destinationURL
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destinationURL.path
        )
    }

    private func expectIdentityMutationRejected(
        _ mutate: (inout [String: Any]) throws -> Void
    ) async throws {
        try await withCapabilityDirectory { directory in
            try runProbe(["identity-create"], workingDirectory: directory)
            let identity = directory.appendingPathComponent("device-identity.json")
            var object = try #require(
                JSONSerialization.jsonObject(with: Data(contentsOf: identity))
                    as? [String: Any]
            )
            try mutate(&object)
            try overwrite(
                identity,
                with: try JSONSerialization.data(
                    withJSONObject: object,
                    options: [.sortedKeys, .withoutEscapingSlashes]
                )
            )
            let rejected = try runProbeExpectingFailure(
                ["identity-read"],
                workingDirectory: directory
            )
            #expect(try decode(ProbeFailure.self, from: rejected).code == "identityInvalid")
        }
    }

    private func recursiveJSONKeys(_ object: Any) -> Set<String> {
        if let dictionary = object as? [String: Any] {
            return dictionary.reduce(into: Set(dictionary.keys)) { result, entry in
                result.formUnion(recursiveJSONKeys(entry.value))
            }
        }
        if let array = object as? [Any] {
            return array.reduce(into: Set<String>()) { result, value in
                result.formUnion(recursiveJSONKeys(value))
            }
        }
        return []
    }
}

private struct ActivationVerification: Decodable {
    let rootState: String
    let mixedState: Bool
    let receiptPresent: Bool
    let stagingPresent: Bool
    let rollbackPresent: Bool
    let semanticValidated: Bool
    let vaultGeneration: UInt64
    let inboxGeneration: UInt64
    let vaultObjectCount: Int
    let inboxItemCount: Int
    let inboxBlobCount: Int
    let inboxTerminalCount: Int
}

private struct ProbeFailure: Decodable {
    let code: String
}

private struct IdentityVerification: Decodable {
    let status: String
    let generation: Int
    let parentMode: Int
    let recordMode: Int
    let publicIdentity: String
    let descriptorDigest: String
}

private struct PublicWriterVerification: Decodable {
    let status: String
    let publicOnlyEncrypted: Bool
    let profileContainedRecoveryMaterial: Bool
    let checkpointDigest: String
}

private struct SeedOnlyRecoveryVerification: Decodable {
    let status: String
    let seedOnlyRecovered: Bool
    let rootSignatureVerified: Bool
    let deviceSignatureVerified: Bool
    let reenrollmentVerified: Bool
    let checkpointDigest: String
}

private struct RepositoryVerification: Decodable {
    let status: String
    let nonSuccessWorkName: Bool
    let exclusiveNonOverwrite: Bool
    let finalIdentityReadBack: Bool
    let parentSynced: Bool
    let plaintextCanaryAbsent: Bool
    let maximumSourceObjectCount: Int
    let maximumSourceByteCount: Int64
    let targetRequiredByteCount: Int64
    let privateRestoreRequiredByteCount: Int64
}

private struct SelectedTargetRepositoryVerification: Decodable {
    let status: String
    let targetCategory: String
    let testBookmarkSeam: Bool
    let securityScopeStarted: Bool
    let coordinatedPublication: Bool
    let selectedIdentityMatched: Bool
    let repositoryIdentityMatched: Bool
    let exclusiveNonOverwrite: Bool
    let finalIdentityReadBack: Bool
    let parentSynced: Bool
    let plaintextCanaryAbsent: Bool
    let targetAvailableCapacityByteCount: Int64
    let privateRestoreAvailableCapacityByteCount: Int64
    let targetAvailableCapacitySufficient: Bool
    let privateRestoreAvailableCapacitySufficient: Bool
}

private struct ChunkVerification: Decodable {
    let passed: Bool
    let selectedChunkByteCount: Int
    let totalStreamByteCount: Int
    let goldenVectorSHA256: String
    let metrics: [ChunkMetricVerification]
}

private struct ChunkMetricVerification: Decodable {
    let chunkByteCount: Int
    let cancellationLatencyMilliseconds: Int
    let cancellationObserved: Bool
    let cancellationProcessedByteCount: Int
    let processedByteCount: Int
}

private struct NamedDatasetVerification: Decodable {
    let passed: Bool
    let format: String
    let objectCount: Int
    let frameCount: Int
    let plaintextByteCount: Int64
    let fileByteCount: Int64
    let allocatedByteCount: Int64
    let selectedChunkByteCount: Int
    let backupDurationMilliseconds: Int
    let restoreDurationMilliseconds: Int
    let backupBudgetMilliseconds: Int
    let restoreBudgetMilliseconds: Int
    let peakRSSDeltaBytes: UInt64
    let peakRSSDeltaBudgetBytes: UInt64
    let fileDescriptorHighWaterCount: Int
    let fileDescriptorBudgetCount: Int
    let sourceSHA256: String
    let backupSHA256: String
    let fullReaderVerified: Bool
    let footerAuthenticated: Bool
    let nonSparse: Bool
    let exclusiveNonOverwrite: Bool
    let cleaned: Bool
}

private struct CapabilityProcessResult {
    let terminationReason: Process.TerminationReason
    let terminationStatus: Int32
    let standardOutput: String
}

private final class CapabilityRunningProcess: @unchecked Sendable {
    private let process: Process
    private let standardOutput: Pipe

    init(process: Process, standardOutput: Pipe) {
        self.process = process
        self.standardOutput = standardOutput
    }

    var isRunning: Bool { process.isRunning }

    func finish(timeout: Duration) throws -> CapabilityProcessResult {
        let deadline = ContinuousClock.now + timeout
        while process.isRunning, ContinuousClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            throw CapabilityHarnessError.timedOut
        }
        return CapabilityProcessResult(
            terminationReason: process.terminationReason,
            terminationStatus: process.terminationStatus,
            standardOutput: String(
                decoding: standardOutput.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
        )
    }
}

private enum CapabilityHarnessError: Error {
    case timedOut
    case unexpectedExit
}
