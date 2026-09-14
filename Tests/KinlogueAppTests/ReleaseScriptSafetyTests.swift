import Foundation
import Testing

struct ReleaseScriptSafetyTests {
    @Test
    func distributionSigningCoversNestedCodeAndRejectsInvalidHelperSignatures() throws {
        let script = try contents("scripts/package-distribution.sh")
        let verifierStart = try #require(script.range(of: "verify_distribution_signature() {"))
        let verifierEnd = try #require(script.range(of: "\ncleanup() {"))
        let signingStart = try #require(script.range(of: #"DICOM_HELPER_BUNDLE="$APP_BUNDLE/Contents/XPCServices/"#))
        let signingEnd = try #require(script.range(of: "\nNOTARY_ARCHIVE="))
        let production = String(script[verifierStart.lowerBound..<verifierEnd.lowerBound])
            + "\n" + String(script[signingStart.lowerBound..<signingEnd.lowerBound])

        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("kinlogue-signing-fixture-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: root) }
        let app = root.appendingPathComponent("Kinlogue.app")
        let helper = app.appendingPathComponent("Contents/XPCServices/KinlogueDICOMDecoderHelper.xpc")
        for (bundle, executable) in [(app, "Kinlogue"), (helper, "KinlogueDICOMDecoderHelper")] {
            let executableURL = bundle.appendingPathComponent("Contents/MacOS/\(executable)")
            try fileManager.createDirectory(
                at: executableURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data("synthetic".utf8).write(to: executableURL)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executableURL.path)
            try Data("synthetic".utf8).write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        }
        for resource in ["DICOMDecoder_DicomCore.bundle", "ZIPFoundation_ZIPFoundation.bundle"] {
            try fileManager.createDirectory(
                at: helper.appendingPathComponent("Contents/Resources/\(resource)"),
                withIntermediateDirectories: true
            )
        }
        let fixture = #"""
        set -euo pipefail
        fail() { print -u2 -- "$1"; exit 1; }
        fixture_codesign() {
          local target="${@[-1]}"
          local fault=""
          [[ "$target" == *.xpc ]] && fault="$SIGNATURE_FAULT"
          if [[ "$target" == *.bundle && "$SIGNATURE_FAULT" == resource-* ]]; then
            fault="${SIGNATURE_FAULT#resource-}"
          fi
          if [[ "$1" == --force ]]; then
            [[ " $* " != *' --deep '* && " $* " == *' --timestamp '* ]]
            if [[ "$target" == *.xpc ]]; then
              [[ " $* " == *' --options runtime '* && " $* " == *'/KinlogueDICOMDecoderHelper.entitlements '* ]]
            elif [[ "$target" == *.app ]]; then
              [[ " $* " == *' --options runtime '* && " $* " == *'/Kinlogue.entitlements '* ]]
            else
              [[ " $* " != *' --entitlements '* ]]
            fi
            print -r -- "SIGNED:${target:t}"
          elif [[ "$1" == --verify ]]; then
            [[ "$fault" != invalid ]] || return 1
          elif [[ " $* " == *' --entitlements '* ]]; then
            if [[ "$target" == *.xpc && "$fault" != entitlements ]]; then
              /bin/cat "$REPO_DIR/packaging/KinlogueDICOMDecoderHelper.entitlements"
            else
              /bin/cat "$REPO_DIR/packaging/Kinlogue.entitlements"
            fi
          else
            [[ "$fault" == adhoc ]] || print -u2 -- "Authority=$KINLOGUE_CODESIGN_IDENTITY"
            if [[ "$fault" == team ]]; then
              print -u2 'TeamIdentifier=DIFFERENT0'
            else
              print -u2 -- "TeamIdentifier=$KINLOGUE_DEVELOPER_TEAM_ID"
            fi
            [[ "$fault" == timestamp ]] || print -u2 'Timestamp=Synthetic timestamp'
            [[ "$fault" == runtime ]] || print -u2 'CodeDirectory v=20500 size=1 flags=0x10000(runtime)'
            if [[ "$fault" == identifier ]]; then
              print -u2 'Identifier=unexpected.helper'
            elif [[ "$target" == *.xpc ]]; then
              print -u2 'Identifier=com.kinlogue.mac.dicom-decoder'
            else
              print -u2 'Identifier=com.kinlogue.mac'
            fi
          fi
          return 0
        }
        """# + "\n" + production.replacingOccurrences(of: "/usr/bin/codesign", with: "fixture_codesign")
        var environment = ProcessInfo.processInfo.environment
        environment["APP_BUNDLE"] = app.path
        environment["REPO_DIR"] = repositoryURL.path
        environment["NOTARY_TEMP_DIRECTORY"] = root.path
        environment["KINLOGUE_CODESIGN_IDENTITY"] = "Developer ID Application: Synthetic Fixture"
        environment["KINLOGUE_DEVELOPER_TEAM_ID"] = "SYNTHETIC0"
        environment["KINLOGUE_SIGNING_KEYCHAIN_PATH"] = root.appendingPathComponent("unused.keychain").path
        for fault in [
            "", "invalid", "adhoc", "team", "timestamp", "runtime", "identifier", "entitlements",
            "resource-adhoc", "resource-team", "resource-timestamp",
        ] {
            environment["SIGNATURE_FAULT"] = fault
            let result = try run(URL(fileURLWithPath: "/bin/zsh"), ["-c", fixture], environment: environment)
            if fault.isEmpty {
                #expect(result.status == 0, Comment(rawValue: result.output))
                #expect(result.output.split(separator: "\n").filter { $0.hasPrefix("SIGNED:") } == [
                    "SIGNED:DICOMDecoder_DicomCore.bundle", "SIGNED:ZIPFoundation_ZIPFoundation.bundle",
                    "SIGNED:KinlogueDICOMDecoderHelper.xpc", "SIGNED:Kinlogue.app",
                ])
            } else {
                #expect(result.status != 0, "accepted invalid nested signature: \(fault)")
            }
        }
    }

    @Test
    func packagingMetadataDoesNotClaimUnobservedWorkflowGates() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinlogue-metadata-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["scripts/package-adhoc-candidate.sh", "scripts/package-distribution.sh"] {
            let script = try contents(path)
            let start = try #require(script.range(of: "/usr/bin/plutil -insert compatibility -dictionary"))
            let end = try #require(script.range(of: "/usr/bin/plutil -insert compatibility.installedAcceptance"))
            let fragment = "set -euo pipefail\n/usr/bin/plutil -create xml1 \"$METADATA_PLIST\"\n"
                + String(script[start.lowerBound..<end.lowerBound])
                + "\n/usr/bin/plutil -extract compatibility.workflowReleaseGates raw \"$METADATA_PLIST\""
            var environment = ProcessInfo.processInfo.environment
            environment["METADATA_PLIST"] = root.appendingPathComponent("metadata.plist").path
            let result = try run(URL(fileURLWithPath: "/bin/zsh"), ["-c", fragment], environment: environment)
            #expect(result.status == 0, Comment(rawValue: result.output))
            #expect(result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "notExecuted")
        }
    }

    @Test
    func zipSafetyGateBehaviorallyAcceptsOnlyRegularCaseUniqueAppEntries() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("kinlogue-zip-safety-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: root) }

        let verifier = repositoryURL.appendingPathComponent("scripts/verify-app-zip-safety.sh")

        let validRoot = root.appendingPathComponent("valid")
        let validContents = validRoot.appendingPathComponent("Kinlogue.app/Contents")
        try fileManager.createDirectory(at: validContents, withIntermediateDirectories: true)
        try Data("synthetic".utf8).write(to: validContents.appendingPathComponent("Info.plist"))
        let validArchive = root.appendingPathComponent("valid.zip")
        #expect(try zip(validArchive, entries: ["Kinlogue.app"], from: validRoot).status == 0)
        #expect(try run(verifier, [validArchive.path]).status == 0)

        let linkRoot = root.appendingPathComponent("link")
        let linkContents = linkRoot.appendingPathComponent("Kinlogue.app/Contents")
        try fileManager.createDirectory(at: linkContents, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(
            at: linkContents.appendingPathComponent("escape"),
            withDestinationURL: URL(fileURLWithPath: "/private/tmp")
        )
        let linkArchive = root.appendingPathComponent("link.zip")
        #expect(try zip(linkArchive, entries: ["Kinlogue.app"], from: linkRoot, preserveLinks: true).status == 0)
        #expect(try run(verifier, [linkArchive.path]).status != 0)

        let conflictArchive = root.appendingPathComponent("conflict.zip")
        try writeStoredZIP(
            entries: [
                "Kinlogue.app/",
                "Kinlogue.app/Contents/Note",
                "Kinlogue.app/Contents/note",
            ],
            to: conflictArchive
        )
        #expect(try run(verifier, [conflictArchive.path]).status != 0)

        let ancestorArchive = root.appendingPathComponent("ancestor.zip")
        try writeStoredZIP(
            entries: [
                "Kinlogue.app/",
                "Kinlogue.app/Contents",
                "Kinlogue.app/Contents/Info.plist",
            ],
            to: ancestorArchive
        )
        #expect(try run(verifier, [ancestorArchive.path]).status != 0)

        let traversalRoot = root.appendingPathComponent("traversal")
        let traversalChild = traversalRoot.appendingPathComponent("child")
        try fileManager.createDirectory(at: traversalChild, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: traversalRoot.appendingPathComponent("outside"))
        let traversalArchive = root.appendingPathComponent("traversal.zip")
        #expect(try zip(traversalArchive, entries: ["../outside"], from: traversalChild).status == 0)
        #expect(try run(verifier, [traversalArchive.path]).status != 0)
    }

    @Test
    func releaseScriptsPinAnIsolatedResolvedOnlyXcodeBuild() throws {
        let build = try contents("scripts/build-app.sh")
        let verify = try contents("scripts/verify-app.sh")

        for required in [
            "--isolated-swiftpm-root",
            "--scratch-path",
            "--disable-dependency-cache",
            "--only-use-versions-from-resolved-file",
            "--manifest-cache none",
        ] {
            #expect(build.contains(required))
        }
        #expect(verify.contains("verify_swiftnio_checkout"))
        #expect(verify.contains("0b18836bd8b0162e7e17a995a3fbee20ed8f3b2b"))
        #expect(verify.contains("export DEVELOPER_DIR"))
        #expect(verify.contains("schemaVersion -integer 4"))
        #expect(verify.contains("gates.installedAcceptance"))
    }

    @Test
    func fullProductionVerifierRequiresCleanSourceBeforeReleaseWork() throws {
        let script = try contents("scripts/verify-app.sh")

        #expect(script.contains("REQUIRE_CLEAN_SOURCE=true"))
        #expect(script.contains("REQUIRE_CLEAN_SOURCE_EXPLICIT=false"))

        let argumentParsing = try #require(script.range(
            of: #"while [[ "$#" -gt 0 ]]; do"#
        ))
        let reportInvalidation = try #require(script.range(
            of: "\ninvalidate_verification_report\n",
            range: argumentParsing.upperBound..<script.endIndex
        ))
        let developerOnlyBranch = try #require(script.range(
            of: #"if [[ "$LAN_PREREQUISITES_ONLY" == true ]]; then"#,
            range: reportInvalidation.upperBound..<script.endIndex
        ))
        let cleanSourceGate = try #require(script.range(
            of: #"if [[ "$REQUIRE_CLEAN_SOURCE" == true \"#,
            range: developerOnlyBranch.upperBound..<script.endIndex
        ))
        let isolatedRootCreation = try #require(script.range(
            of: "\ncreate_isolated_swiftpm_root\n",
            range: cleanSourceGate.upperBound..<script.endIndex
        ))
        let releasePrerequisites = try #require(script.range(
            of: #"verify_release_prerequisites "$REPO_DIR" "$ISOLATED_SWIFTPM_ROOT" true"#,
            range: isolatedRootCreation.upperBound..<script.endIndex
        ))
        let reportPublication = try #require(script.range(
            of: #"/bin/mv -f -- "$REPORT_TEMP_FILE" "$REPORT_PATH""#,
            range: releasePrerequisites.upperBound..<script.endIndex
        ))

        #expect(reportInvalidation.lowerBound < developerOnlyBranch.lowerBound)
        #expect(developerOnlyBranch.lowerBound < cleanSourceGate.lowerBound)
        #expect(cleanSourceGate.lowerBound < isolatedRootCreation.lowerBound)
        #expect(isolatedRootCreation.lowerBound < releasePrerequisites.lowerBound)
        #expect(developerOnlyBranch.lowerBound < reportPublication.lowerBound)
    }

    @Test
    func fullProductionVerifierUsesFreshResolvedOnlyDependenciesBeforeAndAfterBuild() throws {
        let script = try contents("scripts/verify-app.sh")

        #expect(script.contains(
            #"/private/tmp/kinlogue-swiftpm-release.XXXXXX"#
        ))
        #expect(script.contains(
            #""$(/usr/bin/stat -f '%Lp' "$ISOLATED_SWIFTPM_ROOT")" == 700"#
        ))
        #expect(!script.contains(#"RESOLUTION_MODE="normalDevelopment""#))
        #expect(!script.contains("DEPENDENCY_CACHE_ENABLED=true"))

        let releasePrerequisites = try #require(script.range(
            of: #"verify_release_prerequisites "$REPO_DIR" "$ISOLATED_SWIFTPM_ROOT" true"#
        ))
        let releaseBuild = try #require(script.range(
            of: #""$REPO_DIR/scripts/build-app.sh""#,
            range: releasePrerequisites.upperBound..<script.endIndex
        ))
        let isolatedBuildArgument = try #require(script.range(
            of: #"--isolated-swiftpm-root "$ISOLATED_SWIFTPM_ROOT""#,
            range: releaseBuild.upperBound..<script.endIndex
        ))
        let postBuildCheckoutGate = try #require(script.range(
            of: #"verify_swiftnio_checkout "$ISOLATED_SWIFTPM_ROOT/scratch""#,
            range: isolatedBuildArgument.upperBound..<script.endIndex
        ))

        #expect(releasePrerequisites.lowerBound < releaseBuild.lowerBound)
        #expect(releaseBuild.lowerBound < isolatedBuildArgument.lowerBound)
        #expect(isolatedBuildArgument.lowerBound < postBuildCheckoutGate.lowerBound)
    }

    @Test
    func releaseScriptsIgnoreInheritedPathExecutables() throws {
        let build = try contents("scripts/build-app.sh")
        let verify = try contents("scripts/verify-app.sh")

        #expect(build.contains(
            #"export PATH="$XCODE_TOOLCHAIN_BIN:/usr/bin:/bin:/usr/sbin:/sbin""#
        ))
        #expect(!build.contains(#"$XCODE_TOOLCHAIN_BIN:$PATH"#))
        for requiredCommand in [
            "/bin/mkdir",
            "/bin/rm",
            "/bin/cp",
            "/bin/chmod",
            "/usr/bin/codesign",
        ] {
            #expect(build.contains(requiredCommand))
        }

        #expect(verify.contains(
            #"export PATH="$XCODE_TOOLCHAIN_BIN:/usr/bin:/bin:/usr/sbin:/sbin""#
        ))
        #expect(!verify.contains(#"$XCODE_TOOLCHAIN_BIN:$PATH"#))
        #expect(!verify.contains("if rg "))
        #expect(verify.contains("/usr/bin/grep -r -n -E"))
        #expect(verify.contains("/usr/bin/grep -n -E"))

        let privacyGuard = try contents("scripts/privacy-guard.sh")
        #expect(privacyGuard.contains(
            #"export PATH="/usr/bin:/bin:/usr/sbin:/sbin""#
        ))
        #expect(privacyGuard.contains("/usr/bin/find"))
        #expect(privacyGuard.contains("/usr/bin/grep -F -l"))
        #expect(!privacyGuard.contains("if rg "))

        let privacyHistoryGuard = try contents("scripts/privacy-history-guard.sh")
        #expect(privacyHistoryGuard.contains(
            #"export PATH="/usr/bin:/bin:/usr/sbin:/sbin""#
        ))
        #expect(privacyHistoryGuard.contains("/usr/bin/git rev-list"))
        #expect(privacyHistoryGuard.contains("/usr/bin/git cat-file --batch"))
        #expect(!privacyHistoryGuard.contains("if rg "))

        for scriptPath in ["scripts/verify-app-zip-safety.sh"] {
            #expect(try contents(scriptPath).contains(
                #"export PATH="/usr/bin:/bin:/usr/sbin:/sbin""#
            ))
        }

        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("kinlogue-path-poison-\(UUID().uuidString)")
        let poisonDirectory = root.appendingPathComponent("bin")
        let marker = root.appendingPathComponent("ambient-command-executed")
        try fileManager.createDirectory(
            at: poisonDirectory,
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: root) }

        let fakeScript = """
        #!/bin/zsh
        /usr/bin/touch "$KINLOGUE_PATH_POISON_MARKER"
        exit 99
        """
        for executableName in [
            "rg", "grep", "codesign", "mkdir", "rm", "cp", "chmod",
            "find", "mktemp", "stat", "plutil", "pwd", "xcrun",
        ] {
            let executable = poisonDirectory.appendingPathComponent(executableName)
            try fakeScript.write(to: executable, atomically: true, encoding: .utf8)
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: executable.path
            )
        }

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(poisonDirectory.path):\(environment["PATH"] ?? "")"
        environment["KINLOGUE_PATH_POISON_MARKER"] = marker.path
        environment.removeValue(forKey: "KINLOGUE_FORBIDDEN_VALUES")

        let repository = repositoryURL
        let privacyProbe = try run(
            repository.appendingPathComponent("scripts/privacy-guard.sh"),
            [],
            environment: environment
        )
        #expect(privacyProbe.status == 0)
        #expect(privacyProbe.output.contains("Privacy guard passed"))

        let buildProbe = try run(
            repository.appendingPathComponent("scripts/build-app.sh"),
            [
                "--isolated-swiftpm-root",
                root.appendingPathComponent("missing-swiftpm-root").path,
            ],
            environment: environment
        )
        #expect(buildProbe.status != 0)
        #expect(buildProbe.output.contains(
            "isolated SwiftPM root must be an existing real absolute directory"
        ))

        let verifyProbe = try run(
            repository.appendingPathComponent("scripts/verify-app.sh"),
            ["--lan-prerequisites-only", "--require-clean-source"],
            environment: environment
        )
        #expect(verifyProbe.status != 0)
        #expect(verifyProbe.output.contains("cannot be combined with release gates"))

        #expect(!fileManager.fileExists(atPath: marker.path))
    }

    @Test
    func privacyGuardRejectsReportLikeFilesOutsideExactAssetAllowlist() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("kinlogue-privacy-guard-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: root) }

        try makeMinimalPrivacyGuardRepository(at: root)
        let script = root.appendingPathComponent("scripts/privacy-guard.sh")
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "KINLOGUE_FORBIDDEN_VALUES")

        let fixtureDirectory = root.appendingPathComponent("Tests/Fixtures")
        try fileManager.createDirectory(
            at: fixtureDirectory,
            withIntermediateDirectories: true
        )
        for fileExtension in ["pdf", "png", "jpg", "jpeg", "heic", "tif", "tiff"] {
            let fixture = fixtureDirectory
                .appendingPathComponent("synthetic-report.\(fileExtension)")
            try Data("synthetic report fixture".utf8).write(to: fixture)
            let result = try run(script, [], environment: environment)
            #expect(result.status != 0, "expected .\(fileExtension) to be rejected")
            #expect(result.output.contains("checked-in report-like PDF or image"))
            try fileManager.removeItem(at: fixture)
        }

        let documentationAssets = root.appendingPathComponent("docs/assets")
        try fileManager.createDirectory(
            at: documentationAssets,
            withIntermediateDirectories: true
        )
        let reviewedScreenshot = documentationAssets
            .appendingPathComponent("kinlogue-overview.jpg")
        try fileManager.copyItem(
            at: repositoryURL.appendingPathComponent(
                "docs/assets/kinlogue-overview.jpg"
            ),
            to: reviewedScreenshot
        )
        let reviewed = try run(script, [], environment: environment)
        #expect(reviewed.status == 0)
        #expect(reviewed.output.contains("Privacy guard passed"))

        try Data("tampered screenshot".utf8).write(to: reviewedScreenshot)
        let tampered = try run(script, [], environment: environment)
        #expect(tampered.status != 0)
        #expect(tampered.output.contains("checked-in report-like PDF or image"))
        try fileManager.removeItem(at: reviewedScreenshot)

        let packaging = root.appendingPathComponent("packaging")
        try fileManager.createDirectory(at: packaging, withIntermediateDirectories: true)
        try Data("synthetic application icon".utf8).write(
            to: packaging.appendingPathComponent("AppIcon.png")
        )
        let allowed = try run(script, [], environment: environment)
        #expect(allowed.status == 0)
        #expect(allowed.output.contains("Privacy guard passed"))

        try Data("unreviewed synthetic asset".utf8).write(
            to: packaging.appendingPathComponent("Unreviewed.png")
        )
        let unreviewed = try run(script, [], environment: environment)
        #expect(unreviewed.status != 0)
        #expect(unreviewed.output.contains("checked-in report-like PDF or image"))
    }

    @Test
    func privacyHistoryGuardRejectsAForbiddenValueAfterItWasCommittedAndDeleted() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("kinlogue-privacy-history-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: root) }

        try makeMinimalPrivacyHistoryRepository(at: root)
        let script = root.appendingPathComponent("scripts/privacy-history-guard.sh")
        let forbiddenValue = "KINLOGUE_HISTORY_TEST_\(UUID().uuidString)"
        var environment = ProcessInfo.processInfo.environment
        environment["KINLOGUE_FORBIDDEN_VALUES"] = forbiddenValue

        let clean = try run(script, ["--ref", "HEAD"], environment: environment)
        #expect(clean.status == 0)
        #expect(clean.output.contains("Privacy history guard passed"))

        let transient = root.appendingPathComponent("synthetic-private-note.txt")
        try forbiddenValue.write(to: transient, atomically: true, encoding: .utf8)
        try commitThenDelete("synthetic-private-note.txt", in: root)
        #expect(!fileManager.fileExists(atPath: transient.path))

        let historical = try run(script, ["--ref", "HEAD"], environment: environment)
        #expect(historical.status != 0)
        #expect(historical.output.contains("forbidden value found in reachable history"))
        #expect(!historical.output.contains(forbiddenValue))
    }

    @Test
    func privacyHistoryGuardRejectsUnapprovedMediaAtAllowedPathAfterRestore() throws {
        for mediaPath in ["packaging/AppIcon.png", "docs/assets/kinlogue-overview.jpg"] {
            try assertPrivacyHistoryRejectsRestoredMedia(at: mediaPath)
        }
    }

    private func assertPrivacyHistoryRejectsRestoredMedia(at mediaPath: String) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("kinlogue-privacy-history-media-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: root) }

        try makeMinimalPrivacyHistoryRepository(at: root)
        let packaging = root.appendingPathComponent(mediaPath).deletingLastPathComponent()
        try fileManager.createDirectory(at: packaging, withIntermediateDirectories: true)
        let icon = root.appendingPathComponent(mediaPath)
        let approvedIcon = repositoryURL.appendingPathComponent(mediaPath)
        try fileManager.copyItem(at: approvedIcon, to: icon)
        #expect(try git(["add", mediaPath], in: root).status == 0)
        #expect(try git(["commit", "-m", "Add approved application icon"], in: root).status == 0)

        let script = root.appendingPathComponent("scripts/privacy-history-guard.sh")
        let clean = try run(script, ["--ref", "HEAD"])
        #expect(clean.status == 0)
        #expect(clean.output.contains("Privacy history guard passed"))

        let differentPNG = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        try differentPNG.write(to: icon, options: .atomic)
        #expect(try git(["add", mediaPath], in: root).status == 0)
        #expect(try git(["commit", "-m", "Replace icon with unapproved media"], in: root).status == 0)
        try Data(contentsOf: approvedIcon).write(to: icon, options: .atomic)
        #expect(try git(["add", mediaPath], in: root).status == 0)
        #expect(try git(["commit", "-m", "Restore approved application icon"], in: root).status == 0)

        let historical = try run(script, ["--ref", "HEAD"])
        #expect(historical.status != 0)
        #expect(historical.output.contains("unapproved repository media"))
        #expect(!historical.output.contains(mediaPath))
    }

    @Test
    func privacyHistoryGuardRejectsUnapprovedMediaAtIconsetPath() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("kinlogue-privacy-history-iconset-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: root) }

        try makeMinimalPrivacyHistoryRepository(at: root)
        let iconset = root.appendingPathComponent("packaging/Kinlogue.iconset")
        try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
        let differentPNG = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        try differentPNG.write(
            to: iconset.appendingPathComponent("icon_16x16.png"),
            options: .atomic
        )
        #expect(try git(["add", "packaging/Kinlogue.iconset/icon_16x16.png"], in: root).status == 0)
        #expect(try git(["commit", "-m", "Add unapproved iconset media"], in: root).status == 0)

        let result = try run(
            root.appendingPathComponent("scripts/privacy-history-guard.sh"),
            ["--ref", "HEAD"]
        )
        #expect(result.status != 0)
        #expect(result.output.contains("unapproved repository media"))
        #expect(!result.output.contains("icon_16x16.png"))
    }

    @Test
    func privacyHistoryGuardFailsClosedForInvalidApprovedMediaDigestManifest() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("kinlogue-privacy-history-media-manifest-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: root) }

        try makeMinimalPrivacyHistoryRepository(at: root)
        try "not-a-digest  packaging/AppIcon.png\n".write(
            to: root.appendingPathComponent("scripts/privacy-history-media-digests.txt"),
            atomically: true,
            encoding: .utf8
        )

        let result = try run(
            root.appendingPathComponent("scripts/privacy-history-guard.sh"),
            ["--ref", "HEAD"]
        )
        #expect(result.status != 0)
        #expect(result.output.contains("approved media digest manifest"))

        try fileManager.removeItem(
            at: root.appendingPathComponent("scripts/privacy-history-media-digests.txt")
        )
        let missing = try run(
            root.appendingPathComponent("scripts/privacy-history-guard.sh"),
            ["--ref", "HEAD"]
        )
        #expect(missing.status != 0)
        #expect(missing.output.contains("approved media digest manifest"))

        let manifest = try contents("scripts/privacy-history-media-digests.txt")
        let manifestURL = root.appendingPathComponent(
            "scripts/privacy-history-media-digests.txt"
        )
        let firstLine = try #require(manifest.split(separator: "\n").first)
        try (manifest + String(firstLine) + "\n").write(
            to: manifestURL,
            atomically: true,
            encoding: .utf8
        )
        let duplicate = try run(
            root.appendingPathComponent("scripts/privacy-history-guard.sh"),
            ["--ref", "HEAD"]
        )
        #expect(duplicate.status != 0)
        #expect(duplicate.output.contains("duplicate path"))

        try (manifest + String(repeating: "0", count: 64)
            + "  packaging/Unexpected.png\n").write(
            to: manifestURL,
            atomically: true,
            encoding: .utf8
        )
        let unexpected = try run(
            root.appendingPathComponent("scripts/privacy-history-guard.sh"),
            ["--ref", "HEAD"]
        )
        #expect(unexpected.status != 0)
        #expect(unexpected.output.contains("unexpected path"))

        let incomplete = manifest.split(separator: "\n").dropLast().joined(separator: "\n")
            + "\n"
        try incomplete.write(to: manifestURL, atomically: true, encoding: .utf8)
        let incompleteResult = try run(
            root.appendingPathComponent("scripts/privacy-history-guard.sh"),
            ["--ref", "HEAD"]
        )
        #expect(incompleteResult.status != 0)
        #expect(incompleteResult.output.contains("manifest is incomplete"))
    }

    @Test
    func privacyHistoryGuardRejectsDeletedMedicalFilesAndCommonCredentials() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("kinlogue-privacy-history-rules-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: root) }

        let medicalRepository = root.appendingPathComponent("medical")
        try makeMinimalPrivacyHistoryRepository(at: medicalRepository)
        let medicalFile = medicalRepository.appendingPathComponent("synthetic-study.dcm")
        try Data("synthetic medical fixture".utf8).write(to: medicalFile)
        try commitThenDelete("synthetic-study.dcm", in: medicalRepository)
        let medicalResult = try run(
            medicalRepository.appendingPathComponent("scripts/privacy-history-guard.sh"),
            ["--ref", "HEAD"]
        )
        #expect(medicalResult.status != 0)
        #expect(medicalResult.output.contains("prohibited medical"))

        let credentialRepository = root.appendingPathComponent("credential")
        try makeMinimalPrivacyHistoryRepository(at: credentialRepository)
        let credential = "A" + "KIA" + String(repeating: "0", count: 16)
        let credentialFile = credentialRepository.appendingPathComponent("synthetic-note.txt")
        try credential.write(to: credentialFile, atomically: true, encoding: .utf8)
        try commitThenDelete("synthetic-note.txt", in: credentialRepository)
        let credentialResult = try run(
            credentialRepository.appendingPathComponent("scripts/privacy-history-guard.sh"),
            ["--ref", "HEAD"]
        )
        #expect(credentialResult.status != 0)
        #expect(credentialResult.output.contains("common credential pattern"))
        #expect(!credentialResult.output.contains(credential))
    }

    @Test
    func privacyHistoryGuardRejectsDeletedSecretBearingPathsButAllowsExactEnvExample() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("kinlogue-privacy-history-secret-paths-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: root) }

        let binaryCanary = "SYNTHETIC_BINARY_KEY_\(UUID().uuidString)"
        var binaryKey = Data([0x30, 0x82, 0x01, 0x00, 0x02, 0x01, 0x00])
        binaryKey.append(contentsOf: binaryCanary.utf8)
        let fixtures: [(repository: String, path: String, contents: Data, canary: String)] = [
            (
                "dotenv",
                "configuration/.env",
                Data("SYNTHETIC_ARBITRARY_ENV_SECRET_\(UUID().uuidString)".utf8),
                "SYNTHETIC_ARBITRARY_ENV_SECRET"
            ),
            ("dotenv-suffix", "configuration/.env.example.local", Data("synthetic".utf8), "synthetic"),
            ("p8", "credentials/AuthKey_Synthetic.p8", binaryKey, binaryCanary),
            ("key", "credentials/synthetic-private.key", binaryKey, binaryCanary),
        ]
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "KINLOGUE_FORBIDDEN_VALUES")

        for fixture in fixtures {
            let repository = root.appendingPathComponent(fixture.repository)
            try makeMinimalPrivacyHistoryRepository(at: repository)
            let file = repository.appendingPathComponent(fixture.path)
            try fileManager.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fixture.contents.write(to: file)
            try commitThenDelete(fixture.path, in: repository)

            let result = try run(
                repository.appendingPathComponent("scripts/privacy-history-guard.sh"),
                ["--ref", "HEAD"],
                environment: environment
            )
            #expect(result.status != 0, "expected \(fixture.path) to be rejected")
            #expect(result.output.contains("prohibited medical"))
            #expect(!result.output.contains(fixture.canary))
        }

        let exampleRepository = root.appendingPathComponent("dotenv-example")
        try makeMinimalPrivacyHistoryRepository(at: exampleRepository)
        let example = exampleRepository.appendingPathComponent("configuration/.env.example")
        try fileManager.createDirectory(
            at: example.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("SYNTHETIC_SETTING=replace-me\n".utf8).write(to: example)
        try commitThenDelete("configuration/.env.example", in: exampleRepository)

        let allowed = try run(
            exampleRepository.appendingPathComponent("scripts/privacy-history-guard.sh"),
            ["--ref", "HEAD"],
            environment: environment
        )
        #expect(allowed.status == 0)
        #expect(allowed.output.contains("Privacy history guard passed"))
    }

    @Test
    func privacyHistoryGuardRejectsADeletedKinlogueRecoveryCodeWithoutExternalCanaries() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("kinlogue-privacy-history-recovery-code-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: root) }

        try makeMinimalPrivacyHistoryRepository(at: root)
        let recoveryCode = (["KLG1"] + Array(repeating: "01234567", count: 9))
            .joined(separator: "-")
        let note = root.appendingPathComponent("synthetic-recovery-note.txt")
        try recoveryCode.write(to: note, atomically: true, encoding: .utf8)
        try commitThenDelete("synthetic-recovery-note.txt", in: root)
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "KINLOGUE_FORBIDDEN_VALUES")

        let result = try run(
            root.appendingPathComponent("scripts/privacy-history-guard.sh"),
            ["--ref", "HEAD"],
            environment: environment
        )
        #expect(result.status != 0)
        #expect(result.output.contains("common credential pattern"))
        #expect(!result.output.contains(recoveryCode))
    }

    private func makeMinimalPrivacyGuardRepository(at root: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        for disclosure in ["README.md", "PRIVACY.md"] {
            try fileManager.copyItem(
                at: repositoryURL.appendingPathComponent(disclosure),
                to: root.appendingPathComponent(disclosure)
            )
        }
        let scripts = root.appendingPathComponent("scripts")
        try fileManager.createDirectory(at: scripts, withIntermediateDirectories: true)
        try fileManager.copyItem(
            at: repositoryURL.appendingPathComponent("scripts/privacy-guard.sh"),
            to: scripts.appendingPathComponent("privacy-guard.sh")
        )
        for relativeDirectory in [
            "Sources/KinlogueDICOMTestSupport",
            "Sources/KinlogueDICOMAcceptanceFixtureGenerator",
        ] {
            let directory = root.appendingPathComponent(relativeDirectory)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try "// Synthetic fixture generator placeholder.\n".write(
                to: directory.appendingPathComponent("Fixture.swift"),
                atomically: true,
                encoding: .utf8
            )
        }
    }

    private func makeMinimalPrivacyHistoryRepository(at root: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let scripts = root.appendingPathComponent("scripts")
        try fileManager.createDirectory(at: scripts, withIntermediateDirectories: true)
        try fileManager.copyItem(
            at: repositoryURL.appendingPathComponent("scripts/privacy-history-guard.sh"),
            to: scripts.appendingPathComponent("privacy-history-guard.sh")
        )
        try fileManager.copyItem(
            at: repositoryURL.appendingPathComponent("scripts/privacy-history-media-digests.txt"),
            to: scripts.appendingPathComponent("privacy-history-media-digests.txt")
        )
        try "Synthetic clean repository.\n".write(
            to: root.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        #expect(try git(["init", "-b", "main"], in: root).status == 0)
        #expect(try git([
            "add",
            "README.md",
            "scripts/privacy-history-guard.sh",
            "scripts/privacy-history-media-digests.txt",
        ], in: root).status == 0)
        #expect(try git(["commit", "-m", "Create synthetic repository"], in: root).status == 0)
    }

    private func git(_ arguments: [String], in repository: URL) throws -> CommandResult {
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_AUTHOR_NAME"] = "Kinlogue Synthetic Test"
        environment["GIT_AUTHOR_EMAIL"] = "synthetic@example.invalid"
        environment["GIT_COMMITTER_NAME"] = "Kinlogue Synthetic Test"
        environment["GIT_COMMITTER_EMAIL"] = "synthetic@example.invalid"
        return try run(
            URL(fileURLWithPath: "/usr/bin/git"),
            arguments,
            currentDirectory: repository,
            environment: environment
        )
    }

    private func commitThenDelete(_ relativePath: String, in repository: URL) throws {
        let file = repository.appendingPathComponent(relativePath)
        #expect(try git(["add", relativePath], in: repository).status == 0)
        #expect(try git(["commit", "-m", "Add synthetic transient file"], in: repository).status == 0)
        try FileManager.default.removeItem(at: file)
        #expect(try git(["add", "-u"], in: repository).status == 0)
        #expect(try git(["commit", "-m", "Delete synthetic transient file"], in: repository).status == 0)
    }

    private func contents(_ relativePath: String) throws -> String {
        return try String(
            contentsOf: repositoryURL.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private var repositoryURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func zip(
        _ archive: URL,
        entries: [String],
        from directory: URL,
        preserveLinks: Bool = false
    ) throws -> CommandResult {
        var arguments = ["-q", "-r"]
        if preserveLinks {
            arguments.append("-y")
        }
        arguments.append(archive.path)
        arguments.append(contentsOf: entries)
        return try run(
            URL(fileURLWithPath: "/usr/bin/zip"),
            arguments,
            currentDirectory: directory
        )
    }

    private func run(
        _ executable: URL,
        _ arguments: [String],
        currentDirectory: URL? = nil,
        environment: [String: String]? = nil
    ) throws -> CommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        if let environment {
            process.environment = environment
        }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return CommandResult(
            status: process.terminationStatus,
            output: String(decoding: data, as: UTF8.self)
        )
    }

    private func writeStoredZIP(entries: [String], to destination: URL) throws {
        var localRecords = Data()
        var centralDirectory = Data()

        for entry in entries {
            let name = Data(entry.utf8)
            let isDirectory = entry.hasSuffix("/")
            let localOffset = UInt32(localRecords.count)
            appendLittleEndian(UInt32(0x0403_4b50), to: &localRecords)
            appendLittleEndian(UInt16(20), to: &localRecords)
            appendLittleEndian(UInt16(0), to: &localRecords)
            appendLittleEndian(UInt16(0), to: &localRecords)
            appendLittleEndian(UInt16(0), to: &localRecords)
            appendLittleEndian(UInt16(0), to: &localRecords)
            appendLittleEndian(UInt32(0), to: &localRecords)
            appendLittleEndian(UInt32(0), to: &localRecords)
            appendLittleEndian(UInt32(0), to: &localRecords)
            appendLittleEndian(UInt16(name.count), to: &localRecords)
            appendLittleEndian(UInt16(0), to: &localRecords)
            localRecords.append(name)

            appendLittleEndian(UInt32(0x0201_4b50), to: &centralDirectory)
            appendLittleEndian(UInt16(0x031e), to: &centralDirectory)
            appendLittleEndian(UInt16(20), to: &centralDirectory)
            appendLittleEndian(UInt16(0), to: &centralDirectory)
            appendLittleEndian(UInt16(0), to: &centralDirectory)
            appendLittleEndian(UInt16(0), to: &centralDirectory)
            appendLittleEndian(UInt16(0), to: &centralDirectory)
            appendLittleEndian(UInt32(0), to: &centralDirectory)
            appendLittleEndian(UInt32(0), to: &centralDirectory)
            appendLittleEndian(UInt32(0), to: &centralDirectory)
            appendLittleEndian(UInt16(name.count), to: &centralDirectory)
            appendLittleEndian(UInt16(0), to: &centralDirectory)
            appendLittleEndian(UInt16(0), to: &centralDirectory)
            appendLittleEndian(UInt16(0), to: &centralDirectory)
            appendLittleEndian(UInt16(0), to: &centralDirectory)
            let unixMode = isDirectory ? 0o040755 : 0o100644
            appendLittleEndian(UInt32(unixMode << 16), to: &centralDirectory)
            appendLittleEndian(localOffset, to: &centralDirectory)
            centralDirectory.append(name)
        }

        var archive = localRecords
        let centralOffset = UInt32(archive.count)
        archive.append(centralDirectory)
        appendLittleEndian(UInt32(0x0605_4b50), to: &archive)
        appendLittleEndian(UInt16(0), to: &archive)
        appendLittleEndian(UInt16(0), to: &archive)
        appendLittleEndian(UInt16(entries.count), to: &archive)
        appendLittleEndian(UInt16(entries.count), to: &archive)
        appendLittleEndian(UInt32(centralDirectory.count), to: &archive)
        appendLittleEndian(centralOffset, to: &archive)
        appendLittleEndian(UInt16(0), to: &archive)
        try archive.write(to: destination, options: .atomic)
    }

    private func appendLittleEndian<T: FixedWidthInteger>(
        _ value: T,
        to data: inout Data
    ) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            data.append(contentsOf: bytes)
        }
    }
}

private struct CommandResult {
    let status: Int32
    let output: String
}
