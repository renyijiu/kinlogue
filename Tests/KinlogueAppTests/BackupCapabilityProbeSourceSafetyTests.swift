import Foundation
import Testing

/// The installed-build restore probe is checked as text, because it only runs from a signed,
/// installed bundle in a login session.
struct BackupCapabilityProbeSourceSafetyTests {
    @Test
    func theProbeIsSandboxedAndNothingElse() throws {
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

        // A restore inside the container needs no file access outside it and no extra framework.
        #expect(Set(probeEntitlements.keys) == ["com.apple.security.app-sandbox"])
        #expect(probeEntitlements.values.allSatisfy { ($0 as? Bool) == true })
        #expect(!fixtureTarget.contains("linkedFramework"))
    }

    @Test
    func theProbeReachesNeitherTheKeychainNorTheUsersFolders() throws {
        let source = try contents(
            "Sources/KinlogueStorageProcessFixture/BackupCapabilityProbe.swift"
        )
        for forbidden in [
            "import Security", "Security.framework", "SecItem", "kSec", "Keychain",
            "import AppKit", "import CryptoKit",
            "NSHomeDirectory", "Documents", "Downloads",
            "NSOpenPanel", "startAccessingSecurityScopedResource",
        ] {
            #expect(!source.contains(forbidden))
        }
        for required in ["0o700", "0o600", "O_NOFOLLOW", "validateOwnedDirectory"] {
            #expect(source.contains(required))
        }
    }

    @Test
    func theProbeRunsTheProductionRestoreAndDeclaresNoneOfItsOwn() throws {
        let source = try contents(
            "Sources/KinlogueStorageProcessFixture/BackupCapabilityProbe.swift"
        )
        let transactionSource = try contents(
            "Sources/KinloguePlatform/Backup/BackupRestoreTransaction.swift"
        )
        let compositionSource = try contents("Sources/KinlogueApp/App/AppComposition.swift")
        let startupSource = try contents("Sources/KinlogueApp/App/SQLiteAppStartup.swift")

        for required in [
            "BackupRestoreTransaction", ".activate(prepared:", ".reconcile()",
            "BackupRestoreVerifier", "reconcileAbandonedPreflights",
            "createCommittedRoot", "SQLiteLibraryOwner",
            "SQLiteLANInboxStore", "validateStrict",
            "strictValidateCommittedRoot", "@_spi(Testing) import KinloguePlatform",
            "Darwin.kill(getpid(), SIGKILL)",
        ] {
            #expect(source.contains(required))
        }
        for duplicatedActivationAlgorithm in [
            "struct ActivationReceipt", "enum ActivationPhase",
            "rollbackActivatedRoot", "cleanupCommitted(",
            "KLG-U0-ACTIVATION-2", "renameatx_np(parent",
        ] {
            #expect(!source.contains(duplicatedActivationAlgorithm))
        }
        // The groups that carried synthetic formats of their own are gone.
        for removedOperation in [
            "identity-create", "crypto-public-writer", "repository-publication",
            "selected-target-publication", "bookmark-create", "named-dataset", "\"chunk\"",
        ] {
            #expect(!source.contains(removedOperation))
        }
        #expect(transactionSource.contains(
            "@_spi(Testing) public enum BackupRestoreTransactionFault"
        ))
        #expect(transactionSource.contains(
            "package init(owner: SQLiteLibraryOwner, failureInjector: FailureInjector? = nil)"
        ))
        #expect(startupSource.contains("BackupRestoreTransaction(owner: owner)"))
        #expect(!compositionSource.contains("failureInjector"))
        #expect(!startupSource.contains("failureInjector"))
        #expect(!source.contains("AppComposition"))
        #expect(!source.contains("root-state.json"))
        #expect(!source.contains("fsync(descriptor) == 0 ||"))
    }

    @Test
    func runnerChecksTheSignedArtifactAndEveryRestoreCase() throws {
        let script = try contents("scripts/run-backup-capability-probe.sh")

        for required in [
            "codesign -d --entitlements", "TeamIdentifier",
            "KinlogueBackupCapabilityProbe.entitlements",
            "the signed artifact has an unexpected entitlement",
            "installing changed the signed entitlement set",
            "notExecuted", "blocked", "Developer ID",
            "umask 077", "trap cleanup EXIT", "sourceTreeDirty",
            "PROBE_TIMEOUT_SECONDS", "FIXTURE_TIMEOUT_SECONDS",
            "occupied_library_activation_case", "openSQLite", "libraryOccupied",
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
            "activation-truncate-receipt", #"!= "receiptInvalid""#,
            #"[[ "$ACTIVATION_STATUS" == passed ]] || exit 2"#,
        ] {
            #expect(script.contains(required))
        }
        // Every way a case can go wrong lowers the one status the report carries.
        #expect(script.components(separatedBy: #"ACTIVATION_STATUS="blocked""#).count - 1 == 14)
        #expect(script.components(separatedBy: #"ACTIVATION_STATUS="passed""#).count - 1 == 1)
        // The installed bundle is removed only at its exact run-specific path.
        #expect(script.contains(#""$INSTALLED_APP" == "$USER_APPLICATIONS_DIRECTORY/$APP_BASENAME""#))
        let installedPath = try #require(script.range(
            of: #"INSTALLED_APP="$USER_APPLICATIONS_DIRECTORY/$APP_BASENAME""#
        ))
        let exitTrap = try #require(script.range(of: "trap cleanup EXIT"))
        #expect(installedPath.lowerBound < exitTrap.lowerBound)
        for forbidden in [
            "$HOME", "~/", "legacy Keychain", "local status",
            #"$root_state" == "old" || "$root_state" == "new"#,
            #"$root_state" == "absent" || "$root_state" == "new"#,
            "Backup capability report: $FINAL_REPORT",
            "--interactive-bookmark", "identity-create", "crypto-public-writer",
            "repository-publication", "selected-target-publication", "bookmark-",
            "named-dataset", "MECHANICS",
        ] {
            #expect(!script.contains(forbidden))
        }
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
