import Foundation
import Testing

struct LANPackagingBoundaryTests {
    @Test
    func productionPackagingDeclaresOnlyTheTemporaryLANServerCapability() throws {
        let info = try contents("packaging/Info.plist")
        let entitlements = try contents("packaging/Kinlogue.entitlements")
        let acceptanceEntitlements = try contents(
            "packaging/KinlogueAcceptance.entitlements"
        )

        #expect(info.contains("<key>NSLocalNetworkUsageDescription</key>"))
        for privateMarker in [
            "KinlogueCatalogReadVersions",
            "KinlogueCatalogWriteVersion",
            "KinlogueDICOMOrderingPolicyVersion",
            "KinlogueReleaseRole",
            "KinlogueLANReceiverEnabled",
            "KinlogueVaultEnvelopeVersion",
        ] {
            #expect(!info.contains("<key>\(privateMarker)</key>"))
        }
        #expect(entitlements.contains("<key>com.apple.security.network.server</key>"))
        #expect(entitlements.contains("<key>com.apple.security.files.bookmarks.app-scope</key>"))
        #expect(!entitlements.contains("com.apple.security.network.client"))
        #expect(acceptanceEntitlements.contains("com.apple.security.network.client"))
        #expect(acceptanceEntitlements.contains("com.apple.security.network.server"))
        #expect(acceptanceEntitlements.contains("com.apple.security.files.bookmarks.app-scope"))
        #expect(!info.contains("NSBonjourServices"))
        #expect(!info.contains("NSAppTransportSecurity"))
    }

    @Test
    func prerequisiteVerifierUsesStructuredPackageMetadata() throws {
        let verifier = try contents("scripts/verify-app.sh")

        #expect(verifier.contains("\"$SWIFT_EXECUTABLE\" package"))
        #expect(!verifier.contains("\nswift package"))
        #expect(verifier.contains("dump-package"))
        #expect(verifier.contains("show-dependencies"))
        #expect(verifier.contains("plutil -extract"))
        #expect(verifier.contains(#"escaped_key_path=${key//./\\.}"#))
        #expect(verifier.contains("verify-package-graph.sh"))
        #expect(
            verifier.contains(
                "/bin/zsh \"$package_graph_verifier\" \"$manifest_json\""
            )
        )
        #expect(!verifier.contains("grep -Fq 'exact: \"2.101.3\"'"))
    }

    @Test
    func productionVerifierRejectsForbiddenFinalBundleCapabilitiesFailClosed() throws {
        let verifier = try contents("scripts/verify-app.sh")

        #expect(verifier.contains("extraction_status"))
        #expect(verifier.contains(
            "No value at that key path or invalid key path"
        ))
        #expect(verifier.contains("could not be inspected safely"))
        #expect(verifier.contains(
            #"require_plist_key_absent NSBonjourServices "$info""#
        ))
        #expect(verifier.contains(
            #"require_plist_key_absent NSAppTransportSecurity "$info""#
        ))

        let releaseBuild = try #require(verifier.range(
            of: #""$REPO_DIR/scripts/build-app.sh""#
        ))
        let finalPlistLint = try #require(verifier.range(
            of: #"/usr/bin/plutil -lint "$INFO_PLIST""#,
            range: releaseBuild.upperBound..<verifier.endIndex
        ))
        let bonjourGate = try #require(verifier.range(
            of: #"require_plist_key_absent NSBonjourServices "$INFO_PLIST""#,
            range: finalPlistLint.upperBound..<verifier.endIndex
        ))
        let transportSecurityGate = try #require(verifier.range(
            of: #"require_plist_key_absent NSAppTransportSecurity "$INFO_PLIST""#,
            range: bonjourGate.upperBound..<verifier.endIndex
        ))

        #expect(releaseBuild.lowerBound < finalPlistLint.lowerBound)
        #expect(finalPlistLint.lowerBound < bonjourGate.lowerBound)
        #expect(bonjourGate.lowerBound < transportSecurityGate.lowerBound)
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
