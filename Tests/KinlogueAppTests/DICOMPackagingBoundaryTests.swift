import Foundation
import Testing

struct DICOMPackagingBoundaryTests {
    @Test
    func manifestPinsDICOMSwiftAndKeepsDicomCoreInTheHelper() throws {
        let manifest = try text("Package.swift")

        #expect(manifest.contains("https://github.com/ThalesMMS/DICOM-Swift.git"))
        #expect(manifest.contains("exact: \"1.3.3\""))
        #expect(manifest.contains("name: \"KinlogueDICOMIPC\""))
        #expect(manifest.contains("name: \"KinlogueDICOMDecoderHelper\""))
        #expect(manifest.contains("name: \"KinlogueDICOMTestSupport\""))
        #expect(manifest.contains(
            "name: \"KinlogueDICOMTestSupport\",\n"
                + "            dependencies: [\"KinlogueDICOMIPC\"]"
        ))

        let helperStart = try #require(
            manifest.range(of: "name: \"KinlogueDICOMDecoderHelper\"")
        )
        let helperTail = manifest[helperStart.lowerBound...]
        #expect(helperTail.contains(".product(name: \"DicomCore\", package: \"DICOM-Swift\")"))

        for path in [
            "Sources/KinlogueCore",
            "Sources/KinloguePlatform",
            "Sources/KinlogueApp",
        ] {
            for source in try swiftSources(path) {
                let contents = try String(contentsOf: source, encoding: .utf8)
                #expect(!contents.contains("import DicomCore"))
                #expect(!contents.contains("@testable import DicomCore"))
            }
        }
    }

    @Test
    func helperHasASeparateDescriptorOnlySandboxContract() throws {
        let info = try text("packaging/KinlogueDICOMDecoderHelper-Info.plist")
        let entitlements = try text("packaging/KinlogueDICOMDecoderHelper.entitlements")
        let ipcSources = try combinedSwiftSources("Sources/KinlogueDICOMIPC")

        #expect(info.contains("<string>XPC!</string>"))
        #expect(info.contains("com.kinlogue.mac.dicom-decoder"))
        #expect(entitlements.contains("com.apple.security.app-sandbox"))
        #expect(!entitlements.contains("com.apple.security.network.client"))
        #expect(!entitlements.contains("com.apple.security.network.server"))
        #expect(!entitlements.contains("com.apple.security.inherit"))
        #expect(!entitlements.contains("com.apple.security.files"))
        #expect(ipcSources.contains("FileHandle"))
        #expect(ipcSources.contains("setClasses"))
        #expect(ipcSources.contains("FileHandle.self"))
        #expect(!ipcSources.contains("URL"))
        #expect(!ipcSources.contains("path"))
    }

    @Test
    func releaseScriptsEmbedSignAndVerifyExactlyOneXPCService() throws {
        let builder = try text("scripts/build-app.sh")
        let verifier = try text("scripts/verify-app.sh")

        for token in [
            "Contents/XPCServices",
            "KinlogueDICOMDecoderHelper.xpc",
            "KinlogueDICOMDecoderHelper.entitlements",
            "ZIP_FOUNDATION_RESOURCE_BUNDLE_NAME",
            "PrivacyInfo.xcprivacy",
            "codesign --force --sign -",
        ] {
            #expect(builder.contains(token))
        }
        for token in [
            "EXPECTED_DICOM_HELPER_BUNDLE",
            "Contents/XPCServices",
            "com.apple.security.network.client",
            "com.apple.security.network.server",
            "com.apple.security.inherit",
            "DicomCore",
            "THIRD_PARTY_NOTICES.md",
            "EXPECTED_ZIP_FOUNDATION_RESOURCE_BUNDLE",
            "main App ZIPFoundation privacy manifest",
        ] {
            #expect(verifier.contains(token))
        }
    }

    @Test
    func checkedInXcodeProjectBuildsTheNonPublishedHelperAsAnXPCService() throws {
        let manifest = try text("Package.swift")
        let productsStart = try #require(manifest.range(of: "products: ["))
        let dependenciesStart = try #require(manifest.range(of: "dependencies: ["))
        let publishedProducts = manifest[
            productsStart.upperBound..<dependenciesStart.lowerBound
        ]
        #expect(!publishedProducts.contains("KinlogueDICOMDecoderHelper"))

        let project = try text(
            "packaging/KinlogueDICOMDecoderHelper.xcodeproj/project.pbxproj"
        )
        let projectResolved = try text(
            "packaging/KinlogueDICOMDecoderHelper.xcodeproj/"
                + "project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
        )
        #expect(project.contains("com.apple.product-type.xpc-service"))
        #expect(project.contains("kind = exactVersion; version = 1.3.3"))
        #expect(project.contains("DICOMIPC.swift in Sources"))
        #expect(project.contains("KinlogueDICOMDecoderHelper.swift in Sources"))
        #expect(project.contains("DicomCore in Frameworks"))
        #expect(projectResolved.contains("9ae0851e134af274651b646519b8a7aaeee05f05"))
        #expect(projectResolved.contains("6a52f3251125d74daf04fcbd5e6f08a75d074382"))
        #expect(projectResolved.contains("22787ffb59de99e5dc1fbfe80b19c97a904ad48d"))

        let builder = try text("scripts/build-app.sh")
        #expect(builder.contains("KinlogueDICOMDecoderHelper.xcodeproj"))
        #expect(builder.contains("xcodebuild"))
        #expect(builder.contains("-onlyUsePackageVersionsFromResolvedFile"))
        #expect(!builder.contains("DICOM_CORE_RESOURCE_BUNDLE_NAME"))
        #expect(builder.contains("ZIP_FOUNDATION_RESOURCE_BUNDLE_NAME"))
    }

    @Test
    func generatedFixtureProbeExercisesTheStrictlySignedEmbeddedXPC() throws {
        let probe = try text("scripts/verify-dicom-xpc.sh")
        let helper = try text(
            "Sources/KinlogueDICOMDecoderHelper/KinlogueDICOMDecoderHelper.swift"
        )
        let probeSource = try text(
            "Sources/KinlogueDICOMXPCProbe/KinlogueDICOMXPCProbe.swift"
        )
        let adapter = try text(
            "Sources/KinloguePlatform/DICOM/DICOMDecoderAdapter.swift"
        )

        for token in [
            "KinlogueDICOMXPCProbe",
            "KinlogueDICOMDecoderHelper.xpc",
            "Contents/XPCServices",
            "codesign --verify --strict",
            "KLD_DICOM_XPC_OK",
            "KLD_DICOM_XPC_CRASH_CONTAINED",
            "KLD_DICOM_XPC_WATCHDOG_CONTAINED",
            "open -n -W",
            "lsof -nP",
            "log show",
            "OTHER_SWIFT_FLAGS=-DKINLOGUE_DICOM_XPC_TEST_HANG",
            "--use-verified-app",
            "artifact.bundleSHA256",
        ] {
            #expect(probe.contains(token))
        }
        #expect(!probe.contains("--deep"))
        #expect(helper.contains("DICOMDecoderProcessLifecycle.beginRequest()"))
        #expect(helper.contains("Darwin._exit(124)"))
        #expect(!helper.contains("Darwin._exit(0)"))
        #expect(!helper.contains("replyDeliveryGrace"))
        #expect(probeSource.contains("verifyWarmHelperAcrossIdleGap"))
        #expect(probeSource.contains("KLDProbeCrashControlDirectory"))
        #expect(probeSource.contains(
            "components[3].hasPrefix(\"kinlogue-dicom-xpc-probe.\")"
        ))
        #expect(probeSource.contains("crash-ready"))
        #expect(probeSource.contains("crash-armed"))
        #expect(probeSource.contains("crash-request-started"))
        #expect(!probeSource.contains("for _ in 0..<512"))
        #expect(helper.contains("validateNativePixelElement"))
        #expect(probe.contains("helper_belongs_to_host"))
        #expect(probe.contains("print_probe_diagnostics"))
        #expect(probe.contains("/bin/kill -STOP"))
        #expect(probe.contains("STOPPED_HELPER_PID"))
        #expect(probe.contains("%u:%Lp:%l"))
        #expect(probe.contains("set -o noclobber; umask 077"))
        #expect(probe.contains("KLDProbeCrashControlDirectory"))
        #expect(probe.contains("-D KINLOGUE_DICOM_XPC_CRASH_PROBE"))
        #expect(adapter.contains("#if KINLOGUE_DICOM_XPC_CRASH_PROBE"))
        #expect(adapter.contains("reusableConnection"))
        #expect(adapter.contains("requestSubmissionCount"))
        #expect(adapter.contains("requestSubmitted?(occurrence)"))
        #expect(adapter.contains("private static func makeConnection() -> NSXPCConnection"))
        #expect(probe.contains("refusing to interrupt an existing DICOM Helper"))
        #expect(probe.contains("stop_helper_processes \"$host_app\""))
        #expect(!probe.contains("stop_helper_processes ||"))
    }

    @Test
    func installedAcceptanceGeneratorIsNonPublishedAndExcludedFromProduction() throws {
        let manifest = try text("Package.swift")
        let productsStart = try #require(manifest.range(of: "products: ["))
        let dependenciesStart = try #require(manifest.range(of: "dependencies: ["))
        let products = manifest[productsStart.upperBound..<dependenciesStart.lowerBound]
        let verifier = try text("scripts/verify-app.sh")
        let runner = try text("scripts/run-acceptance.sh")
        let acceptanceBuilder = try text("scripts/build-acceptance-app.sh")
        let privacy = try text("scripts/privacy-guard.sh")

        #expect(manifest.contains("name: \"KinlogueDICOMAcceptanceFixtureGenerator\""))
        #expect(!products.contains("KinlogueDICOMAcceptanceFixtureGenerator"))
        #expect(verifier.contains("KinlogueDICOMAcceptanceFixtureGenerator"))
        #expect(runner.contains("KinlogueDICOMAcceptanceFixtureGenerator"))
        #expect(runner.contains("DICOMInput"))
        #expect(privacy.contains("Sources/KinlogueDICOMAcceptanceFixtureGenerator"))
        #expect(!acceptanceBuilder.contains("--force --deep --sign"))
        #expect(acceptanceBuilder.contains("codesign --verify --strict \"$TARGET_DICOM_HELPER\""))
    }

    @Test
    func helperRejectsNonLinearVOIWithoutEnumeratingAllTags() throws {
        let helper = try text(
            "Sources/KinlogueDICOMDecoderHelper/KinlogueDICOMDecoderHelper.swift"
        )
        let fixture = try text(
            "Sources/KinlogueDICOMTestSupport/GeneratedDICOMFixture.swift"
        )
        let probe = try text(
            "Sources/KinlogueDICOMXPCProbe/KinlogueDICOMXPCProbe.swift"
        )

        #expect(helper.contains("decoder.info(for: 0x00281056)"))
        #expect(helper.contains("supportsLinearVOILUTFunction"))
        #expect(!helper.contains("getAllTags"))
        #expect(fixture.contains("voiLUTFunction: String? = nil"))
        #expect(probe.contains("voiLUTFunction: \"SIGMOID\""))
        #expect(probe.contains("error == .unsupportedObject"))
    }

    private func text(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repository.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func combinedSwiftSources(_ relativePath: String) throws -> String {
        try swiftSources(relativePath)
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
    }

    private func swiftSources(_ relativePath: String) throws -> [URL] {
        let root = repository.appendingPathComponent(relativePath)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return try enumerator.compactMap { value in
            guard let url = value as? URL, url.pathExtension == "swift" else { return nil }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
            return url
        }
    }

    private var repository: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
