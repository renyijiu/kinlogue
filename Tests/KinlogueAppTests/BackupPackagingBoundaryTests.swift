import Foundation
import Testing

struct BackupPackagingBoundaryTests {
    @Test
    func everyProductionAndAcceptanceArtifactAllowsOnlyPersistentFolderBookmarks() throws {
        let verifier = try contents("scripts/verify-app.sh")
        let adHocPackager = try contents("scripts/package-adhoc-candidate.sh")
        let distributionPackager = try contents("scripts/package-distribution.sh")
        let acceptanceBuilder = try contents("scripts/build-acceptance-app.sh")

        for script in [verifier, adHocPackager, distributionPackager] {
            #expect(script.contains("com.apple.security.files.bookmarks.app-scope"))
        }
        #expect(acceptanceBuilder.contains(
            #"com\.apple\.security\.files\.bookmarks\.app-scope"#
        ))
        #expect(verifier.contains("com.apple.security.network.client"))
        #expect(verifier.contains("noSecurityFrameworkDependency"))
        #expect(verifier.contains("noKeychainRuntime"))
    }

    @Test
    func verificationReportSeparatesPlaintextVaultFromEncryptedLocalCheckpoints() throws {
        let verifier = try contents("scripts/verify-app.sh")
        let acceptance = try contents("scripts/run-acceptance.sh")

        for script in [verifier, acceptance] {
            #expect(script.contains("storage.confidentiality"))
            #expect(script.contains("storage.applicationLayerEncryption"))
            #expect(script.contains("storage.backupContainerEncryption"))
            #expect(script.contains("storage.backupRecoveryPrivateKeyPersisted"))
            #expect(script.contains("storage.backupDeviceIdentityCanDecrypt"))
            #expect(script.contains("storage.keychainDependency"))
            #expect(script.contains("storage.cloudSync"))
            #expect(script.contains("storage.builtInBackupRestore"))
        }
        #expect(verifier.contains(
            #"storage.backupContainerEncryption -string "hpke-x25519-chacha20poly1305+aes-256-gcm""#
        ))
        #expect(verifier.contains("storage.builtInBackupRestore -bool true"))
        #expect(verifier.contains("storage.cloudSync -bool false"))
        #expect(verifier.contains("storage.keychainDependency -bool false"))
        let builtInCheck = try #require(acceptance.range(
            of: #"storage.builtInBackupRestore raw -expect bool"#
        ))
        let builtInTail = acceptance[builtInCheck.lowerBound...].prefix(240)
        #expect(builtInTail.contains(#"== "true""#))
    }

    @Test
    func productionSourceAuditAllowsTheNewCodecButStillRejectsKeychainAndLegacyVaultCrypto() throws {
        let verifier = try contents("scripts/verify-app.sh")

        #expect(!verifier.contains("VaultBackupService|VaultRestoreService"))
        #expect(verifier.contains("KeychainVaultKeyStore"))
        #expect(verifier.contains("EncryptedVault"))
        #expect(verifier.contains("SecItem"))
        #expect(verifier.contains("import[[:space:]]+Security"))
        #expect(verifier.contains("NO_KEYCHAIN_RUNTIME_PATTERN"))
    }

    private func contents(_ relativePath: String) throws -> String {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repository.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
