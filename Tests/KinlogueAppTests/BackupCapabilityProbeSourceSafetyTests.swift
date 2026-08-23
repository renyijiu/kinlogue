import Foundation
import Testing

struct BackupCapabilityProbeSourceSafetyTests {
    @Test
    func isolatedProbeAndProductionUseOnlyTheirRequiredBookmarkCapabilities() throws {
        let package = try contents("Package.swift")
        let fixtureTargetStart = try #require(package.range(
            of: #"name: "KinlogueStorageProcessFixture""#
        ))
        let fixtureTargetEnd = try #require(package.range(
            of: ".executableTarget(",
            range: fixtureTargetStart.upperBound..<package.endIndex
        ))
        let fixtureTarget = package[fixtureTargetStart.lowerBound..<fixtureTargetEnd.lowerBound]
        let probeEntitlements = try propertyList(
            "packaging/KinlogueBackupCapabilityProbe.entitlements"
        )
        let productionEntitlements = try propertyList("packaging/Kinlogue.entitlements")

        #expect(!fixtureTarget.contains(#".linkedFramework("Security")"#))
        #expect(fixtureTarget.contains(#".linkedFramework("CryptoKit")"#))
        #expect(fixtureTarget.contains(#".linkedFramework("AppKit")"#))
        #expect(Set(probeEntitlements.keys) == [
            "com.apple.security.app-sandbox",
            "com.apple.security.files.bookmarks.app-scope",
            "com.apple.security.files.user-selected.read-write",
        ])
        #expect(probeEntitlements.values.allSatisfy { ($0 as? Bool) == true })
        #expect(productionEntitlements[
            "com.apple.security.files.bookmarks.app-scope"
        ] as? Bool == true)
        #expect(productionEntitlements["com.apple.security.network.client"] == nil)
    }

    @Test
    func noKeychainIdentityCryptoAndBookmarkProbeFailClosed() throws {
        let source = try contents(
            "Sources/KinlogueStorageProcessFixture/BackupCapabilityProbe.swift"
        )
        for required in [
            "device-identity.json", "0o700", "0o600",
            "Curve25519.Signing.PrivateKey",
            "Curve25519.KeyAgreement.PrivateKey",
            "HPKE.Sender", "HPKE.Recipient",
            "crypto-public-writer", "crypto-public-decrypt", "crypto-seed-recover",
            "recoveryMaterialUnavailable", "seedOnlyRecovered",
            ".withSecurityScope",
            "bookmarkDataIsStale",
            ".withoutUI",
            "startAccessingSecurityScopedResource",
            "stopAccessingSecurityScopedResource",
            "selected-target-publication",
            ".kinlogue-backup-capability-u0",
            "targetAvailableCapacityByteCount",
            "privateRestoreAvailableCapacityByteCount",
            "setActivationPolicy(.regular)",
        ] {
            #expect(source.contains(required))
        }
        for forbidden in [
            "import Security", "Security.framework", "SecItem",
            "kSec", "Keychain",
            "NSHomeDirectory",
            "Documents",
            "Downloads",
            "setActivationPolicy(.accessory)",
        ] {
            #expect(!source.contains(forbidden))
        }
        #expect(!source.contains("publicOnlyCannotDecrypt: true"))
        #expect(!source.contains("publicOnlyCannotDecrypt: false"))
    }

    @Test
    func activationAndChunkProbePreservesThePlannedSafetyBoundaries() throws {
        let source = try contents(
            "Sources/KinlogueStorageProcessFixture/BackupCapabilityProbe.swift"
        )
        let transactionSource = try contents(
            "Sources/KinloguePlatform/Backup/PlaintextVaultRestoreTransaction.swift"
        )
        let compositionSource = try contents("Sources/KinlogueApp/App/AppComposition.swift")

        for required in [
            "BackupRestoreTransaction", ".activate(prepared:", ".reconcile()",
            "BackupRestoreVerifier",
            "activationSeedWriter", "createCommittedRoot",
            "PlaintextLANInboxStore", "snapshotAndStorageSummary",
            "strictValidateCommittedRoot", "@_spi(Testing) import KinloguePlatform",
            "64 * 1_024", "256 * 1_024", "1_024 * 1_024",
            "2 * 1_024 * 1_024 * 1_024",
            "peakRSSDeltaBytes", "cancellationLatencyMilliseconds",
            "selectedChunkByteCount", "goldenVectorSHA256",
            "named-dataset", "KLG-U0-DATASET-PROBE-1",
            "maximumSourceObjectCount", "maximumSourceByteCount",
            "backupBudgetMilliseconds", "restoreBudgetMilliseconds",
            "fileDescriptorHighWaterCount", "allocatedByteCount",
            "footerAuthenticated", "fullReaderVerified",
        ] {
            #expect(source.contains(required))
        }
        for duplicatedActivationAlgorithm in [
            "struct ActivationReceipt", "enum ActivationPhase",
            "rollbackActivatedRoot", "cleanupCommitted(",
            "KLG-U0-ACTIVATION-2",
        ] {
            #expect(!source.contains(duplicatedActivationAlgorithm))
        }
        #expect(transactionSource.contains(
            "@_spi(Testing) public enum BackupRestoreTransactionFault"
        ))
        #expect(transactionSource.contains("@_spi(Testing) public init("))
        #expect(!compositionSource.contains("failureInjector"))
        #expect(!source.contains("AppComposition"))
        #expect(!source.contains("root-state.json"))
        for forbidden in [
            "ftruncate(", "posix_fallocate(", "mmap(",
            "Data(repeating: 0, count: maximumSourceByteCount)",
            "Data(count: maximumSourceByteCount)",
        ] {
            #expect(!source.contains(forbidden))
        }
    }

    @Test
    func runnerChecksTheSignedArtifactAndKeepsMissingMatricesHonest() throws {
        let script = try contents("scripts/run-backup-capability-probe.sh")
        let probeSource = try contents(
            "Sources/KinlogueStorageProcessFixture/BackupCapabilityProbe.swift"
        )

        for required in [
            "codesign -d --entitlements", "TeamIdentifier",
            "KinlogueBackupCapabilityProbe.entitlements",
            "notExecuted", "blocked", "Developer ID",
            "--interactive-bookmark", "umask 077", "trap cleanup",
            "sourceTreeDirty", "identityPermissionFailure", "macOS14",
            "macOS15", "macOS26",
            "EXPECTED_GOLDEN_VECTOR_SHA256",
            "real_writer_activation_case", "holdCatalogCommit", "rootReplaced",
            "after-intent", "after-writer-reset", "after-old-root-move",
            "after-new-root-activation", "after-validation", "after-commit",
            "semanticValidated", "expected_root_state",
            #"activation_case existing after-intent old"#,
            #"activation_case existing after-writer-reset old"#,
            #"activation_case existing after-old-root-move old"#,
            #"activation_case existing after-new-root-activation new"#,
            #"activation_case existing after-validation new"#,
            #"activation_case existing after-commit new"#,
            #"activation_case absent after-intent absent"#,
            #"activation_case absent after-writer-reset absent"#,
            #"activation_case absent after-new-root-activation new"#,
            #"activation_case absent after-validation new"#,
            #"activation_case absent after-commit new"#,
            #"$(json_bool "$verify_out" receiptPresent)" == false"#,
            #"$(json_bool "$verify_out" stagingPresent)" == false"#,
            #"$(json_bool "$verify_out" rollbackPresent)" == false"#,
            "PUBLIC_ONLY_STATUS", "SEED_ONLY_STATUS",
            "REPOSITORY_PUBLICATION_STATUS", "CAPACITY_STATUS",
            "IDENTITY_MECHANICS_STATUS", "CRYPTO_MECHANICS_STATUS",
            "REPOSITORY_MECHANICS_STATUS", "CAPACITY_PREFLIGHT_STATUS",
            "ACTIVATION_MECHANICS_STATUS", "MANDATORY_U0_STATUSES",
            "FINAL_SIGNED_ENTITLEMENTS", "PROBE_TIMEOUT_SECONDS",
            "IDENTITY_ADVERSARIAL_STATUS", "--case-id parent-replacement",
            "--case-id leaf-replacement",
            "REPOSITORY_ADVERSARIAL_STATUS", "--case-id final-replacement",
            #"for owned_app in "$INSTALLED_APP" "$PREVIOUS_APP" "$UPGRADE_APP""#,
            #"all_statuses_passed "${MANDATORY_U0_STATUSES[@]}""#,
            "crypto-public-writer", "crypto-public-decrypt", "crypto-seed-recover",
            "selected-target-publication", "ordinaryDirectoryTarget",
            "ordinaryDirectoryCapacityPreflight",
            "selectedTargetAvailableCapacityByteCount",
            "appPrivateRestoreAvailableCapacityByteCount",
            "FILE_PROVIDER_STATUS=\"notExecuted\"",
            "named-dataset", "NAMED_DATASET_TIMEOUT_SECONDS",
            "EXPECTED_NAMED_DATASET_SOURCE_SHA256",
            "namedWorstCaseDataset", "backupWallClockBudget",
            "restoreWallClockBudget", "namedDatasetPeakRSSDeltaBytes",
            "namedDatasetFileDescriptorHighWaterCount",
            #""$NAMED_DATASET_STATUS" == passed"#,
        ] {
            #expect(script.contains(required))
        }
        let exactUpgrade = try #require(script.range(
            of: #"UPGRADE_APP="$INSTALLED_APP.upgrade""#
        ))
        let exitTrap = try #require(script.range(of: "trap cleanup EXIT"))
        #expect(exactUpgrade.lowerBound < exitTrap.lowerBound)
        #expect(!script.contains(
            #"-replace "macOS$OS_MAJOR" -string passed"#
        ))
        #expect(!script.contains(
            #"-replace "macOS$OS_MAJOR" -string "$OVERALL_STATUS""#
        ))
        #expect(!script.contains("$HOME"))
        #expect(!script.contains("~/"))
        #expect(!script.contains("legacy Keychain"))
        #expect(!script.contains("local status"))
        #expect(!script.contains(#"$root_state" == "old" || "$root_state" == "new"#))
        #expect(!script.contains(#"$root_state" == "absent" || "$root_state" == "new"#))
        #expect(!script.contains("Backup capability report: $FINAL_REPORT"))
        #expect(script.contains(#"CAPACITY_STATUS="blocked""#))
        #expect(!probeSource.contains("fsync(descriptor) == 0 ||"))
    }

    private func contents(_ path: String) throws -> String {
        try String(
            contentsOf: repositoryURL.appendingPathComponent(path),
            encoding: .utf8
        )
    }

    private func propertyList(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: repositoryURL.appendingPathComponent(path))
        return try #require(
            PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
        )
    }

    private var repositoryURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
