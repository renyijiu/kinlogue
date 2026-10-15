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
    func releaseBuildsLeaveTheBridgeOutUnlessAskedAndTheVerifierCoversTheSandbox() throws {
        let builder = try text("scripts/build-app.sh")
        let releaseVerifier = try text("scripts/verify-app.sh")
        let assembler = try text("scripts/assemble-assistant-bridge.sh")
        let sandboxVerifier = try text("scripts/verify-assistant-xpc.sh")

        #expect(builder.contains("WITH_ASSISTANT_BRIDGE=false"))
        let optIn = try #require(builder.range(of: #"if [[ "$WITH_ASSISTANT_BRIDGE" == true ]]; then"#, options: .backwards))
        let assembly = try #require(builder.range(of: "scripts/assemble-assistant-bridge.sh"))
        #expect(optIn.lowerBound < assembly.lowerBound)
        #expect(!releaseVerifier.contains("--with-assistant-bridge"))
        #expect(!releaseVerifier.contains("KinlogueAssistantBridge"))

        for token in ["KinlogueAssistantBridge-Info.plist", "codesign --force --sign - --entitlements", "codesign --verify --strict"] {
            #expect(assembler.contains(token))
        }
        for token in [
            "packaging/KinlogueAssistantBridge.entitlements",
            "the signed bridge does not carry exactly the production entitlements",
            "is an unsupported location",
            "inside the sandbox",
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
