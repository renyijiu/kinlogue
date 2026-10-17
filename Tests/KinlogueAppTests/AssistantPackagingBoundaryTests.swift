import Foundation
import Testing

/// The member-chat bridge is checked as text and property lists: its signed behaviour runs only in
/// `scripts/verify-assistant-xpc.sh`, outside the test runner.
struct AssistantPackagingBoundaryTests {
    @Test
    func bridgeEntitlementsAreExactlyTheChosenSandboxExceptions() throws {
        let entitlements = try propertyList("packaging/KinlogueAssistantBridge.entitlements")

        #expect(Set(entitlements.keys) == [
            "com.apple.security.app-sandbox",
            "com.apple.security.network.client",
            "com.apple.security.network.server",
            "com.apple.security.temporary-exception.files.home-relative-path.read-write",
            "com.apple.security.temporary-exception.files.absolute-path.read-only",
        ])
        for flag in ["com.apple.security.app-sandbox", "com.apple.security.network.client", "com.apple.security.network.server"] {
            #expect(entitlements[flag] as? Bool == true)
        }
        // Only the CLI's own state folder is writable; installation roots are read-only.
        #expect(entitlements["com.apple.security.temporary-exception.files.home-relative-path.read-write"] as? [String]
            == ["/.codex/"])
        #expect(entitlements["com.apple.security.temporary-exception.files.absolute-path.read-only"] as? [String]
            == ["/opt/homebrew/", "/usr/local/"])

        // The main App gains nothing from the bridge.
        let app = try propertyList("packaging/Kinlogue.entitlements")
        #expect(app["com.apple.security.network.client"] == nil)
        #expect(!app.keys.contains { $0.contains("temporary-exception") })
    }

    @Test
    func bridgeInfoPlistIsAnXPCServiceWithAFixedIdentity() throws {
        let info = try propertyList("packaging/KinlogueAssistantBridge-Info.plist")
        let app = try propertyList("packaging/Info.plist")

        #expect(info["CFBundlePackageType"] as? String == "XPC!")
        #expect(info["CFBundleIdentifier"] as? String == "com.kinlogue.mac.assistant-bridge")
        #expect(info["CFBundleExecutable"] as? String == "KinlogueAssistantBridge")
        #expect(info["LSMinimumSystemVersion"] as? String == app["LSMinimumSystemVersion"] as? String)
        #expect(info["CFBundleShortVersionString"] as? String == app["CFBundleShortVersionString"] as? String)
        #expect(info["CFBundleVersion"] as? String == app["CFBundleVersion"] as? String)
    }

    @Test
    func releaseBuildsEmbedTheBridgeAndEveryReleaseGateChecksIt() throws {
        let builder = try text("scripts/build-app.sh")
        let releaseVerifier = try text("scripts/verify-app.sh")
        let distribution = try text("scripts/package-distribution.sh")
        let acceptance = try text("scripts/build-acceptance-app.sh")
        let assembler = try text("scripts/assemble-assistant-bridge.sh")
        let sandboxVerifier = try text("scripts/verify-assistant-xpc.sh")

        // Every build carries the bridge; there is no build without it to ship by mistake.
        #expect(!builder.contains("WITH_ASSISTANT_BRIDGE"))
        #expect(!builder.contains("--with-assistant-bridge"))
        #expect(builder.contains(#"-c release --product "$ASSISTANT_BRIDGE_PRODUCT" -j 2"#))
        #expect(builder.contains(#""$REPO_DIR/scripts/assemble-assistant-bridge.sh" \"#))

        for token in [
            #"ASSISTANT_BRIDGE_BUNDLE="$APP_BUNDLE/Contents/XPCServices/KinlogueAssistantBridge.xpc""#,
            #"[[ "$XPC_SERVICE_COUNT" -eq 2"#,
            #"EXPECTED_ASSISTANT_BRIDGE_IDENTIFIER="com.kinlogue.mac.assistant-bridge""#,
            "the signed assistant bridge entitlements differ from packaging/KinlogueAssistantBridge.entitlements",
            "the assistant bridge executable must contain only arm64",
            "the main executable contains the assistant CLI runner",
            "the assistant bridge must not link the SQLite storage kernel",
            "artifact.assistantBridgeExecutableSHA256",
            "artifact.assistantBridgeEntitlementsSHA256",
        ] {
            #expect(releaseVerifier.contains(token), "verify-app.sh must check: \(token)")
        }
        for token in [
            #"ASSISTANT_BRIDGE_BUNDLE="$APP_BUNDLE/Contents/XPCServices/KinlogueAssistantBridge.xpc""#,
            #"--entitlements "$REPO_DIR/packaging/KinlogueAssistantBridge.entitlements""#,
            "Identifier=com.kinlogue.mac.assistant-bridge",
        ] {
            #expect(distribution.contains(token), "package-distribution.sh must sign and check: \(token)")
        }
        #expect(acceptance.contains("the copied release bundle lost its assistant bridge"))
        #expect(acceptance.contains(#"/usr/bin/codesign --verify --strict "$TARGET_ASSISTANT_BRIDGE""#))

        for token in ["KinlogueAssistantBridge-Info.plist", "codesign --force --sign - --entitlements", "codesign --verify --strict"] {
            #expect(assembler.contains(token))
        }
        for token in [
            "packaging/KinlogueAssistantBridge.entitlements",
            "the signed bridge does not carry exactly the production entitlements",
            "is an unsupported location",
            "inside the sandbox",
            "finds its login inside the sandbox",
            "lists the models it shows",
            "through the supervisor",
            "npm-style wrapper",
            "cancelling the client's task stops the turn",
            "killing the bridge stops the CLI and its descendants",
            "no supervisor outlives the bridge",
        ] {
            #expect(sandboxVerifier.contains(token), "verify-assistant-xpc.sh must check: \(token)")
        }
    }
}

private func repository() -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}

private func text(_ path: String) throws -> String {
    try String(contentsOf: repository().appendingPathComponent(path), encoding: .utf8)
}

private func propertyList(_ path: String) throws -> [String: Any] {
    let data = try Data(contentsOf: repository().appendingPathComponent(path))
    return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
}
