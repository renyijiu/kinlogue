import Foundation
import Testing

struct GitHubActionsWorkflowTests {
    @Test
    func publicRepositoryGovernanceProtectsMedicalDataAndScansSwift() throws {
        let security = try contents("SECURITY.md")
        let contributing = try contents("CONTRIBUTING.md")
        let pullRequestTemplate = try contents(".github/PULL_REQUEST_TEMPLATE.md")
        let bugTemplate = try contents(".github/ISSUE_TEMPLATE/bug_report.yml")
        let issueTemplateConfig = try contents(".github/ISSUE_TEMPLATE/config.yml")
        let dependabot = try contents(".github/dependabot.yml")
        let codeQL = try contents(".github/workflows/codeql.yml")
        let ignoreRules = try contents(".gitignore")

        for policy in [security, contributing, pullRequestTemplate, bugTemplate] {
            #expect(policy.localizedCaseInsensitiveContains("real medical"))
            #expect(policy.localizedCaseInsensitiveContains("synthetic"))
        }
        #expect(security.localizedCaseInsensitiveContains("private vulnerability reporting"))
        #expect(issueTemplateConfig.contains(
            "https://github.com/renyijiu/kinlogue/security/advisories/new"
        ))
        #expect(!issueTemplateConfig.contains("renyijiu/kinlogue-public"))
        #expect(dependabot.contains("package-ecosystem: swift"))
        #expect(dependabot.contains("package-ecosystem: github-actions"))

        #expect(codeQL.contains("runs-on: macos-26"))
        #expect(codeQL.contains("security-events: write"))
        #expect(codeQL.contains("languages: swift"))
        #expect(codeQL.contains("build-mode: manual"))
        #expect(codeQL.contains("swift build --disable-sandbox"))
        #expect(!codeQL.contains("pull_request_target"))
        try expectExternalActionsPinned(in: codeQL)

        for ignoredSecretOrArtifact in [
            ".env",
            "*.pem",
            "*.key",
            "*.p12",
            "*.kinloguebackup",
            "*.xcarchive",
            "DerivedData/",
        ] {
            #expect(ignoreRules.contains(ignoredSecretOrArtifact))
        }
        for forbiddenMedicalIgnore in ["*.dcm", "*.dicom", "*.nii", "*.pdf"] {
            #expect(!ignoreRules.contains(forbiddenMedicalIgnore))
        }
    }

    @Test
    func ciUsesRepositoryGatesWithReadOnlyPermissionsAndPinnedActions() throws {
        let workflow = try contents(".github/workflows/ci.yml")
        let ripgrepInstaller = try contents("scripts/install-ci-ripgrep.sh")

        #expect(workflow.contains("pull_request:"))
        #expect(workflow.contains("push:"))
        #expect(workflow.contains("runs-on: macos-26"))
        #expect(workflow.components(separatedBy: "runs-on: macos-26").count - 1 == 3)
        #expect(!workflow.contains("runs-on: macos-15"))
        #expect(workflow.contains("timeout-minutes: 30"))
        #expect(!workflow.contains("timeout-minutes: 90"))
        #expect(workflow.contains("KINLOGUE_BUILD_JOBS: \"2\""))
        #expect(!workflow.contains("SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH"))
        #expect(workflow.contains("KINLOGUE_PRIMARY_TEST_TIMEOUT_SECONDS: \"1200\""))
        #expect(workflow.contains("KINLOGUE_ISOLATED_TEST_TIMEOUT_SECONDS: \"180\""))
        #expect(workflow.contains("KINLOGUE_PRIMARY_TEST_PARTITION: \"0/3\""))
        #expect(workflow.contains("KINLOGUE_PRIMARY_TEST_PARTITION: \"1/3\""))
        #expect(workflow.contains("KINLOGUE_PRIMARY_TEST_PARTITION: \"2/3\""))
        #expect(workflow.contains("name: Complementary test partition"))
        #expect(workflow.contains("name: Dedicated LAN derived-artifact tests"))
        #expect(workflow.contains("scripts/install-ci-ripgrep.sh"))
        #expect(workflow.contains("$GITHUB_WORKSPACE/.build/ci-tools/bin"))
        #expect(workflow.contains(">> \"$GITHUB_PATH\""))
        #expect(workflow.contains("permissions:\n  contents: read"))
        #expect(workflow.contains("scripts/lint.sh"))
        #expect(workflow.contains("scripts/privacy-guard.sh"))
        #expect(workflow.contains("scripts/test.sh"))
        #expect(workflow.components(separatedBy: "run: scripts/test.sh").count - 1 == 3)
        #expect(workflow.contains("scripts/verify-app.sh"))
        #expect(workflow.contains(
            "scripts/verify-dicom-xpc.sh --use-verified-app"
        ))
        #expect(!workflow.contains("pull_request_target"))
        #expect(!workflow.contains("brew install"))
        #expect(ripgrepInstaller.contains("RIPGREP_VERSION=\"14.1.1\""))
        #expect(ripgrepInstaller.contains(
            "24ad76777745fbff131c8fbc466742b011f925bfa4fffa2ded6def23b5b937be"
        ))
        #expect(ripgrepInstaller.contains("aarch64-apple-darwin.tar.gz"))
        #expect(ripgrepInstaller.contains("--proto '=https'"))
        #expect(ripgrepInstaller.contains("/usr/bin/shasum -a 256"))
        #expect(!ripgrepInstaller.contains("brew install"))

        let installer = try #require(workflow.range(
            of: "scripts/install-ci-ripgrep.sh"
        ))
        let lint = try #require(workflow.range(
            of: "scripts/lint.sh",
            range: installer.upperBound..<workflow.endIndex
        ))
        #expect(installer.lowerBound < lint.lowerBound)
        try expectExternalActionsPinned(in: workflow)
    }

    @Test
    func releasePublishesAnAdHocPrereleaseWithoutAppleCredentials() throws {
        let workflow = try contents(".github/workflows/release.yml")
        let packageJob = try job(named: "package", in: workflow)
        let publishJob = try job(named: "publish", in: workflow)
        let releaseInputValidation = try executableStep(
            named: "Validate release inputs",
            in: packageJob
        )
        let releaseGates = try executableStep(named: "Run release gates", in: packageJob)
        let cleanSourceVerification = try executableStep(
            named: "Prepare clean-source candidate input",
            in: packageJob
        )
        let packaging = try executableStep(named: "Package ad-hoc candidate", in: packageJob)
        let dicomRuntimeVerification = try executableStep(
            named: "Verify the DICOM decoder XPC runtime boundary",
            in: packageJob
        )
        let publicationValidation = try executableStep(
            named: "Validate publication inputs",
            in: publishJob
        )
        let publication = try executableStep(named: "Publish GitHub prerelease", in: publishJob)

        #expect(workflow.contains("tags:"))
        #expect(workflow.contains("workflow_dispatch:"))
        #expect(workflow.components(separatedBy: "runs-on: macos-26").count - 1 == 2)
        #expect(!workflow.contains("runs-on: macos-15"))
        #expect(packageJob.contains("    permissions:\n      contents: read\n"))
        #expect(!packageJob.contains("contents: write"))
        #expect(!packageJob.contains("id-token: write"))
        #expect(!packageJob.contains("attestations: write"))
        #expect(packageJob.contains("scripts/package-adhoc-candidate.sh"))
        #expect(packageJob.contains("scripts/install-ci-ripgrep.sh"))
        #expect(packageJob.contains("$GITHUB_WORKSPACE/.build/ci-tools/bin"))
        #expect(packageJob.contains(">> \"$GITHUB_PATH\""))
        #expect(!packageJob.contains("gh release create"))
        #expect(publishJob.contains("needs: package"))
        #expect(publishJob.contains(
            "    permissions:\n" +
                "      contents: write\n" +
                "      id-token: write\n" +
                "      attestations: write\n" +
                "      artifact-metadata: write\n"
        ))
        #expect(publishJob.contains("actions/download-artifact@"))
        #expect(!publishJob.contains("actions/checkout@"))
        #expect(!publishJob.contains("scripts/"))
        #expect(!publishJob.contains("packaging/"))
        #expect(publication.contains("GH_REPO: ${{ github.repository }}"))
        #expect(publication.contains("-F draft=true"))
        #expect(publication.contains("-F prerelease=true"))
        #expect(publication.contains("-F draft=false"))
        #expect(publication.contains(#"gh release upload "$RELEASE_TAG""#))
        #expect(!publication.contains("gh release create"))
        #expect(!publication.contains("gh release delete"))
        #expect(!publication.contains("git push"))
        #expect(!publication.contains("git tag"))
        #expect(workflow.contains("persist-credentials: false"))
        #expect(workflow.contains("fetch-depth: 0"))
        #expect(!workflow.contains("pull_request_target"))
        #expect(!workflow.contains("environment: release"))
        #expect(!workflow.contains("${{ secrets."))
        #expect(!workflow.contains("APPLE_DEVELOPER_ID"))
        #expect(!workflow.contains("APPLE_NOTARY"))
        #expect(releaseInputValidation.contains("CFBundleShortVersionString"))
        #expect(releaseGates.contains("scripts/lint.sh"))
        #expect(releaseGates.contains("scripts/privacy-history-guard.sh"))
        #expect(releaseGates.contains("scripts/privacy-guard.sh"))
        #expect(cleanSourceVerification.contains(
            "run: scripts/verify-app.sh --require-clean-source"
        ))
        #expect(dicomRuntimeVerification.contains(
            "run: scripts/verify-dicom-xpc.sh --use-verified-app"
        ))
        #expect(packaging.contains(#"run: scripts/package-adhoc-candidate.sh "$RELEASE_TAG""#))
        #expect(publicationValidation.contains(#"[[ "${#entries[@]}" -eq 6 ]]"#))

        let inputValidationRange = try #require(packageJob.range(of: releaseInputValidation))
        let installerRange = try #require(packageJob.range(
            of: "scripts/install-ci-ripgrep.sh"
        ))
        let releaseGatesRange = try #require(packageJob.range(of: releaseGates))
        let cleanSourceRange = try #require(packageJob.range(of: cleanSourceVerification))
        let dicomRuntimeRange = try #require(packageJob.range(of: dicomRuntimeVerification))
        let packagingRange = try #require(packageJob.range(of: packaging))
        let uploadRange = try #require(packageJob.range(of: "      - name: Upload workflow evidence"))
        #expect(inputValidationRange.lowerBound < installerRange.lowerBound)
        #expect(installerRange.lowerBound < releaseGatesRange.lowerBound)
        #expect(releaseGatesRange.lowerBound < cleanSourceRange.lowerBound)
        #expect(cleanSourceRange.lowerBound < dicomRuntimeRange.lowerBound)
        #expect(dicomRuntimeRange.lowerBound < packagingRange.lowerBound)
        #expect(packagingRange.lowerBound < uploadRange.lowerBound)

        let downloadRange = try #require(publishJob.range(of: "      - name: Download verified candidate"))
        let publicationValidationRange = try #require(publishJob.range(of: publicationValidation))
        let attestationRange = try #require(publishJob.range(of: "      - name: Attest the candidate ZIP"))
        let publicationRange = try #require(publishJob.range(of: publication))
        #expect(downloadRange.lowerBound < publicationValidationRange.lowerBound)
        #expect(publicationValidationRange.lowerBound < attestationRange.lowerBound)
        #expect(attestationRange.lowerBound < publicationRange.lowerBound)

        let existingReleaseGuard = try #require(publication.range(of: "existing_release_id="))
        let remoteTagLookup = try #require(publication.range(of: "git/ref/tags/$RELEASE_TAG"))
        let remoteRevisionCheck = try #require(publication.range(
            of: #"[[ "$remote_object_sha" == "$SOURCE_REVISION" ]]"#
        ))
        let cleanupTrap = try #require(publication.range(of: "trap cleanup_new_draft EXIT"))
        let createDraft = try #require(publication.range(of: "gh api --method POST"))
        let uploadAssets = try #require(publication.range(of: "gh release upload"))
        let prepareUploadedAssetCheck = try #require(publication.range(
            of: "version=\"${RELEASE_TAG#v}\"",
            range: uploadAssets.upperBound..<publication.endIndex
        ))
        let verifyUploadedAssets = try #require(publication.range(of: "actual_uploaded_names="))
        let publishDraft = try #require(publication.range(of: "gh api --method PATCH"))
        let disarmCleanup = try #require(publication.range(
            of: "draft_release_id=\"\"",
            range: publishDraft.upperBound..<publication.endIndex
        ))
        #expect(existingReleaseGuard.lowerBound < cleanupTrap.lowerBound)
        #expect(cleanupTrap.lowerBound < remoteTagLookup.lowerBound)
        #expect(remoteTagLookup.lowerBound < remoteRevisionCheck.lowerBound)
        #expect(remoteRevisionCheck.lowerBound < createDraft.lowerBound)
        #expect(createDraft.lowerBound < uploadAssets.lowerBound)
        let uploadLines = publication[
            uploadAssets.lowerBound..<prepareUploadedAssetCheck.lowerBound
        ]
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        #expect(uploadLines == [
            "gh release upload \"$RELEASE_TAG\" \\",
            "\"$RELEASE_ARTIFACT\" \\",
            "\"$RELEASE_ARTIFACT.sha256\" \\",
            "\"$CANDIDATE_DIRECTORY/SHA256SUMS\" \\",
            "\"$CANDIDATE_DIRECTORY/INSTALL.md\" \\",
            "\"$CANDIDATE_DIRECTORY/release-metadata.json\" \\",
            "\"$CANDIDATE_DIRECTORY/pre-distribution-verification-report.json\"",
        ])
        #expect(!publication.contains("--clobber"))
        #expect(uploadAssets.lowerBound < verifyUploadedAssets.lowerBound)
        #expect(verifyUploadedAssets.lowerBound < publishDraft.lowerBound)
        #expect(publishDraft.lowerBound < disarmCleanup.lowerBound)
        #expect(publication.contains("gh api --method DELETE"))
        #expect(publication.contains(
            #""repos/$GH_REPO/releases/$draft_release_id" --silent"#
        ))
        #expect(publication.contains(
            #"[[ "$current_release" == "$expected_release" ]]"#
        ))
        try expectExternalActionsPinned(in: workflow)
    }

    @Test
    func releaseValidatesExactTagAndDownloadedArtifactBeforePrivilegeUse() throws {
        let workflow = try contents(".github/workflows/release.yml")
        let packageJob = try job(named: "package", in: workflow)
        let publishJob = try job(named: "publish", in: workflow)
        let releaseInputValidation = try executableStep(
            named: "Validate release inputs",
            in: packageJob
        )
        let publicationValidation = try executableStep(
            named: "Validate publication inputs",
            in: publishJob
        )
        let publication = try executableStep(named: "Publish GitHub prerelease", in: publishJob)

        #expect(releaseInputValidation.contains(
            #"[[ "$RELEASE_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]"#
        ))
        #expect(releaseInputValidation.contains("CFBundleShortVersionString"))
        #expect(releaseInputValidation.contains(
            #"[[ "$RELEASE_TAG" == "v$short_version" ]]"#
        ))
        #expect(releaseInputValidation.contains(
            #"git rev-parse --verify "$RELEASE_TAG^{commit}""#
        ))
        #expect(releaseInputValidation.contains(
            #"[[ "$tag_revision" == "$source_revision" ]]"#
        ))

        for expectedName in [
            #"$artifact_name"#,
            #"$artifact_name.sha256"#,
            "INSTALL.md",
            "SHA256SUMS",
            "pre-distribution-verification-report.json",
            "release-metadata.json",
        ] {
            #expect(publicationValidation.contains(expectedName))
            #expect(publication.contains(expectedName))
        }
        #expect(publicationValidation.contains(#"[[ "${#entries[@]}" -eq 6 ]]"#))
        #expect(publicationValidation.contains(#"[[ -f "$entry" && ! -L "$entry" ]]"#))
        #expect(publicationValidation.contains("/usr/bin/shasum -a 256 -c SHA256SUMS"))
        #expect(publicationValidation.contains("metadata_value releaseTag"))
        #expect(publicationValidation.contains("metadata_value sourceRevision"))
        #expect(publicationValidation.contains("metadata_value artifact.file"))
        #expect(publicationValidation.contains("metadata_value artifact.sha256"))
        #expect(publicationValidation.contains(
            #"[[ "$SOURCE_REVISION" == "$GITHUB_SHA" ]]"#
        ))
        #expect(publication.contains("GH_REPO: ${{ github.repository }}"))
        #expect(publication.contains("git/ref/tags/$RELEASE_TAG"))
        #expect(publication.contains("git/tags/$remote_object_sha"))
        #expect(publication.contains(#"[[ "$remote_object_type" == commit ]]"#))
        #expect(publication.contains(
            #"[[ "$remote_object_sha" == "$SOURCE_REVISION" ]]"#
        ))

        let adHocScript = try contents("scripts/package-adhoc-candidate.sh")
        let distributionScript = try contents("scripts/package-distribution.sh")
        let exactVersionPattern = #"'^v[0-9]+\.[0-9]+\.[0-9]+$'"#
        #expect(adHocScript.contains(exactVersionPattern))
        #expect(distributionScript.contains(exactVersionPattern))
        #expect(!adHocScript.contains("[.-][0-9A-Za-z.-]+"))
        #expect(!distributionScript.contains("[.-][0-9A-Za-z.-]+"))
    }

    @Test
    func workflowSectionHelpersDoNotAcceptGuardsFromOtherJobsOrSteps() throws {
        let workflow = """
        jobs:
          package:
            steps:
              - name: Decoy validation
                run: echo remote-tag-check
          publish:
            steps:
              - name: Decoy publication
                run: echo draft-cleanup
              - name: Publish GitHub prerelease
                run: echo transactional-publication
        """

        let publishJob = try job(named: "publish", in: workflow)
        let publication = try executableStep(named: "Publish GitHub prerelease", in: publishJob)

        #expect(!publishJob.contains("remote-tag-check"))
        #expect(!publication.contains("draft-cleanup"))
        #expect(publication.contains("transactional-publication"))
    }

    @Test
    func adHocCandidatePackagingReverifiesFinalZIPAndLabelsItsTrustBoundary() throws {
        let script = try contents("scripts/package-adhoc-candidate.sh")

        let verification = try #require(script.range(of: "source.cleanRequired"))
        let signatureCheck = try #require(script.range(
            of: #"verify_adhoc_signature "$APP_BUNDLE" live"#,
            range: verification.upperBound..<script.endIndex
        ))
        let packaging = try #require(script.range(
            of: #"/usr/bin/ditto -c -k --keepParent"#,
            range: signatureCheck.upperBound..<script.endIndex
        ))
        let zipSafety = try #require(script.range(
            of: #"verify-app-zip-safety.sh"#,
            range: packaging.upperBound..<script.endIndex
        ))
        let extraction = try #require(script.range(
            of: #"/usr/bin/ditto -x -k"#,
            range: zipSafety.upperBound..<script.endIndex
        ))
        let extractedVerification = try #require(script.range(
            of: #"verify_adhoc_signature "$EXTRACTED_APP""#,
            range: extraction.upperBound..<script.endIndex
        ))
        let artifactHashing = try #require(script.range(
            of: "ARTIFACT_SHA256=",
            range: extractedVerification.upperBound..<script.endIndex
        ))

        #expect(script.contains("publicPrereleaseUnnotarized"))
        #expect(script.contains("signing.kind"))
        #expect(script.contains("AdHoc"))
        #expect(script.contains("notarization.status"))
        #expect(script.contains("NotAvailable"))
        #expect(script.contains("manualGatekeeperOverrideRequired"))
        #expect(script.contains("arm64-adhoc.zip"))
        #expect(script.contains("Signature=adhoc"))
        #expect(script.contains("exact production allow-list"))
        #expect(script.contains("source.dirty"))
        #expect(script.contains("source.revision"))
        #expect(script.contains("artifact.bundleSHA256"))
        #expect(script.range(of: #"\bxattr\b"#, options: .regularExpression) == nil)
        #expect(script.range(
            of: #"\bspctl\b[^\n]*--master-disable"#,
            options: .regularExpression
        ) == nil)
        #expect(!script.contains("notarytool"))
        #expect(verification.lowerBound < signatureCheck.lowerBound)
        #expect(signatureCheck.lowerBound < packaging.lowerBound)
        #expect(packaging.lowerBound < zipSafety.lowerBound)
        #expect(zipSafety.lowerBound < extraction.lowerBound)
        #expect(extraction.lowerBound < extractedVerification.lowerBound)
        #expect(extractedVerification.lowerBound < artifactHashing.lowerBound)
    }

    @Test
    func lintGateChecksSourceHygieneCompilerWarningsAndPackageGraph() throws {
        let script = try contents("scripts/lint.sh")

        #expect(script.contains("set -euo pipefail"))
        #expect(script.contains("-warnings-as-errors"))
        #expect(script.contains("--only-use-versions-from-resolved-file"))
        #expect(script.contains("verify-package-graph.sh"))
        #expect(script.contains("verify-docs.sh"))
        #expect(script.contains("trailing whitespace"))
        #expect(script.contains("tab indentation"))
        #expect(script.contains("CRLF"))
        #expect(!script.contains("brew install"))
        #expect(!script.contains("curl "))
    }

    @Test
    func documentationLintChecksWikiFactsAndConcurrencySafetyWithoutAppleCredentials() throws {
        let script = try contents("scripts/verify-docs.sh")

        #expect(script.contains("missing local Markdown link"))
        #expect(script.contains("unreachable documentation page"))
        #expect(script.contains("CFBundleShortVersionString"))
        #expect(script.contains("KINLOGUE_TEST_RESULT_FILE"))
        #expect(script.contains("release facts do not match observed test result"))
        #expect(script.contains("@unchecked Sendable"))
        #expect(script.contains("nonisolated(unsafe)"))
        #expect(script.contains("SAFETY:"))
        #expect(!script.contains("APPLE_DEVELOPER_ID"))
        #expect(!script.contains("notarytool"))
    }

    @Test
    func documentationLintFailsClosedForFactSafetyLinkAndSymlinkDrift() throws {
        let cleanFixture = try makeDocumentationFixture()
        defer { try? FileManager.default.removeItem(at: cleanFixture.container) }
        let cleanResult = try runDocumentationVerifier(repositoryRoot: cleanFixture.root)
        #expect(cleanResult.status == 0, Comment(rawValue: cleanResult.output))

        let passedFixture = try makeDocumentationFixture(gateStatus: "passed")
        defer { try? FileManager.default.removeItem(at: passedFixture.container) }
        let passedWithoutEvidence = try runDocumentationVerifier(
            repositoryRoot: passedFixture.root
        )
        #expect(passedWithoutEvidence.status == 0, Comment(rawValue: passedWithoutEvidence.output))

        let evidenceModeWithoutEvidence = try runDocumentationVerifier(
            repositoryRoot: passedFixture.root,
            requiresTestEvidence: true
        )
        #expect(evidenceModeWithoutEvidence.status != 0)
        #expect(evidenceModeWithoutEvidence.output.contains(
            "test-evidence mode requires an observed full test result"
        ))

        let passedWithEvidence = try runDocumentationVerifier(
            repositoryRoot: passedFixture.root,
            observedTestResult: "Test run with 863 tests in 80 suites passed\n",
            requiresTestEvidence: true
        )
        #expect(passedWithEvidence.status == 0, Comment(rawValue: passedWithEvidence.output))

        let passedWithShardedEvidence = try runDocumentationVerifier(
            repositoryRoot: passedFixture.root,
            observedTestResult: """
            Test run with 100 tests in 1 suite passed
            Test run with 300 tests in 29 suites passed
            Test run with 463 tests in 50 suites passed
            """,
            requiresTestEvidence: true
        )
        #expect(
            passedWithShardedEvidence.status == 0,
            Comment(rawValue: passedWithShardedEvidence.output)
        )

        let wrongObservedCount = try runDocumentationVerifier(
            repositoryRoot: passedFixture.root,
            observedTestResult: "Test run with 864 tests in 80 suites passed\n",
            requiresTestEvidence: true
        )
        #expect(wrongObservedCount.status != 0)
        #expect(wrongObservedCount.output.contains(
            "release facts do not match observed test result: 864 tests / 80 suites"
        ))

        for fault in DocumentationVerifierFault.allCases {
            let fixture = try makeDocumentationFixture()
            defer { try? FileManager.default.removeItem(at: fixture.container) }
            try apply(fault, to: fixture)

            let result = try runDocumentationVerifier(repositoryRoot: fixture.root)
            #expect(result.status != 0, "verifier accepted \(fault)")
            #expect(
                result.output.contains(fault.expectedDiagnostic),
                Comment(rawValue: result.output)
            )
        }
    }

    @Test
    func distributionPackagingVerifiesBeforeSigningAndNotarizesBeforePublication() throws {
        let script = try contents("scripts/package-distribution.sh")

        let verification = try #require(script.range(of: "source.cleanRequired"))
        let signing = try #require(script.range(
            of: #"/usr/bin/codesign --force --sign"#,
            range: verification.upperBound..<script.endIndex
        ))
        let notarization = try #require(script.range(
            of: #"notarytool submit"#,
            range: signing.upperBound..<script.endIndex
        ))
        let stapling = try #require(script.range(
            of: #"stapler staple"#,
            range: notarization.upperBound..<script.endIndex
        ))
        let packaging = try #require(script.range(
            of: #"verify-app-zip-safety.sh"#,
            range: stapling.upperBound..<script.endIndex
        ))
        let extraction = try #require(script.range(
            of: #"/usr/bin/ditto -x -k"#,
            range: packaging.upperBound..<script.endIndex
        ))
        let extractedVerification = try #require(script.range(
            of: #"verify_distribution_signature "$EXTRACTED_APP""#,
            range: extraction.upperBound..<script.endIndex
        ))
        let artifactHashing = try #require(script.range(
            of: "ARTIFACT_SHA256=",
            range: extractedVerification.upperBound..<script.endIndex
        ))

        #expect(script.contains("--options runtime"))
        #expect(script.contains("--timestamp"))
        #expect(script.contains("notarytool submit"))
        #expect(script.contains("--wait"))
        #expect(script.contains("stapler validate"))
        #expect(script.contains("spctl --assess"))
        #expect(script.contains("PENDING_FORMAL_RELEASE_GATE"))
        #expect(!script.contains("rollback."))
        #expect(script.contains("compatibility.workflowReleaseGates"))
        #expect(script.contains("compatibility.installedAcceptance"))
        #expect(!script.contains("compatibility.currentMacAutomation"))
        #expect(script.contains("source.dirty"))
        #expect(script.contains("source.revision"))
        #expect(script.contains("artifact.bundleSHA256"))
        #expect(script.contains("bundle_hash"))
        #expect(script.contains(#"-x "$executable""#))
        #expect(script.contains("exact production allow-list"))
        #expect(script.contains("/usr/bin/ditto -c -k --keepParent"))
        #expect(!script.contains("--sequesterRsrc"))
        #expect(!script.contains("--noextattr"))
        #expect(!script.contains("scripts/verify-app.sh"))
        #expect(!script.contains("codesign --force --deep"))
        #expect(verification.lowerBound < signing.lowerBound)
        #expect(signing.lowerBound < notarization.lowerBound)
        #expect(notarization.lowerBound < stapling.lowerBound)
        #expect(stapling.lowerBound < packaging.lowerBound)
        #expect(packaging.lowerBound < extraction.lowerBound)
        #expect(extraction.lowerBound < extractedVerification.lowerBound)
        #expect(extractedVerification.lowerBound < artifactHashing.lowerBound)
    }

    private func expectExternalActionsPinned(in workflow: String) throws {
        let expression = try NSRegularExpression(
            pattern: #"uses:\s+([^\s@]+)@([^\s#]+)"#
        )
        let matches = expression.matches(
            in: workflow,
            range: NSRange(workflow.startIndex..., in: workflow)
        )
        #expect(!matches.isEmpty)

        for match in matches {
            let actionRange = try #require(Range(match.range(at: 1), in: workflow))
            let revisionRange = try #require(Range(match.range(at: 2), in: workflow))
            let action = String(workflow[actionRange])
            let revision = String(workflow[revisionRange])
            if action.hasPrefix("./") {
                continue
            }
            #expect(revision.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil)
        }
    }

    private func job(named name: String, in workflow: String) throws -> String {
        let marker = "  \(name):\n"
        let start = try #require(workflow.range(of: marker))
        let expression = try NSRegularExpression(
            pattern: #"(?m)^  [A-Za-z0-9_-]+:\s*$"#
        )
        let searchRange = NSRange(start.upperBound..<workflow.endIndex, in: workflow)
        let end = expression.firstMatch(in: workflow, range: searchRange)
            .flatMap { Range($0.range, in: workflow) }?
            .lowerBound ?? workflow.endIndex
        return String(workflow[start.lowerBound..<end])
    }

    private func executableStep(named name: String, in job: String) throws -> String {
        let marker = "      - name: \(name)\n"
        let start = try #require(job.range(of: marker))
        let next = job.range(
            of: "\n      - ",
            range: start.upperBound..<job.endIndex
        )?.lowerBound ?? job.endIndex
        let step = String(job[start.lowerBound..<next])
        _ = try #require(step.range(of: "\n        run:"))
        return step
    }

    private func contents(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repository.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func makeDocumentationFixture(
        gateStatus: String = "not-verified"
    ) throws -> DocumentationFixture {
        let fileManager = FileManager.default
        let container = fileManager.temporaryDirectory.appendingPathComponent(
            "KinlogueDocsVerifier-\(UUID().uuidString)",
            isDirectory: true
        )
        let root = container.appendingPathComponent("repo", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        func write(_ relativePath: String, _ content: String) throws {
            let destination = root.appendingPathComponent(relativePath)
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try content.write(to: destination, atomically: true, encoding: .utf8)
        }

        let sourceInfoPlist = repository.appendingPathComponent("packaging/Info.plist")
        let infoPlist = root.appendingPathComponent("packaging/Info.plist")
        try fileManager.createDirectory(
            at: infoPlist.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.copyItem(at: sourceInfoPlist, to: infoPlist)
        let plistData = try Data(contentsOf: infoPlist)
        guard let plist = try PropertyListSerialization.propertyList(
            from: plistData,
            format: nil
        ) as? [String: Any],
              let shortVersion = plist["CFBundleShortVersionString"] as? String,
              let buildVersion = plist["CFBundleVersion"] as? String,
              let minimumSystem = plist["LSMinimumSystemVersion"] as? String else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        let factMarker = "<!-- release-facts: short=\(shortVersion) "
            + "build=\(buildVersion) minimum-macos=\(minimumSystem) "
            + "tests=863 suites=80 automated-gates=\(gateStatus) "
            + "overall=pendingManual -->"

        try write("AGENTS.md", "# Agent contract\n\n[Docs](docs/index.md)\n")
        try write("PRIVACY.md", "# Privacy\n\n[Docs](docs/index.md)\n")
        try write(
            "README.md",
            """
            # Kinlogue

            [Docs](docs/index.md)
            [Testing](docs/testing-and-release.md)
            [Current release](docs/acceptance/current-release.md)
            [DICOM](docs/acceptance/dicom-mri-viewer-matrix.md)
            [LAN](docs/acceptance/lan-upload-matrix.md)
            """
        )
        try write(
            "docs/index.md",
            """
            # Documentation

            - [Overview](project-overview.md)
            - [Testing](testing-and-release.md)
            - [Current release](acceptance/current-release.md)
            - [Architecture](architecture.md)
            - [Concurrency](concurrency-safety-audit.md)
            - [Plan](plans/implemented.md)
            - [DICOM acceptance](acceptance/dicom-mri-viewer-matrix.md)
            - [LAN acceptance](acceptance/lan-upload-matrix.md)
            """
        )
        try write(
            "docs/project-overview.md",
            "# Overview\n\n[Current release](acceptance/current-release.md)\n"
        )
        try write(
            "docs/testing-and-release.md",
            "# Testing\n\n[Current release](acceptance/current-release.md)\n"
        )
        try write("docs/architecture.md", "# Architecture\n")
        try write(
            "docs/concurrency-safety-audit.md",
            "# Concurrency\n\n<!-- concurrency-inventory: unchecked=1 files=1 "
                + "dicom=0 core=0 unsafe=0 -->\n"
        )
        try write(
            "docs/plans/implemented.md",
            "---\nstatus: implemented\n---\n\n# Implemented plan\n"
        )
        try write("docs/acceptance/dicom-mri-viewer-matrix.md", "# DICOM\n")
        try write(
            "docs/acceptance/current-release.md",
            "# Current release\n\n\(factMarker)\n\n863 tests / 80 suites\n"
        )
        try write(
            "docs/acceptance/lan-upload-matrix.md",
            "# LAN\n"
        )
        try write(
            "Sources/Fixture/Fixture.swift",
            "// SAFETY: Immutable fixture state is safe to share.\n"
                + "final class Fixture: @unchecked Sendable {}\n"
        )
        return DocumentationFixture(container: container, root: root, factMarker: factMarker)
    }

    private func apply(
        _ fault: DocumentationVerifierFault,
        to fixture: DocumentationFixture
    ) throws {
        let fileManager = FileManager.default
        switch fault {
        case .brokenLink:
            try append(
                "\n[Missing](missing.md)\n",
                to: fixture.root.appendingPathComponent("docs/index.md")
            )
        case .staleFacts:
            let currentRelease = fixture.root.appendingPathComponent(
                "docs/acceptance/current-release.md"
            )
            let content = try String(contentsOf: currentRelease, encoding: .utf8)
            try content.replacingOccurrences(
                of: fixture.factMarker,
                with: "<!-- release-facts: stale -->"
            ).write(to: currentRelease, atomically: true, encoding: .utf8)
        case .missingSafety:
            try "final class Fixture: @unchecked Sendable {}\n".write(
                to: fixture.root.appendingPathComponent("Sources/Fixture/Fixture.swift"),
                atomically: true,
                encoding: .utf8
            )
        case .symlinkEscape:
            let outside = fixture.container.appendingPathComponent("outside.md")
            try "# Outside\n".write(to: outside, atomically: true, encoding: .utf8)
            try fileManager.createSymbolicLink(
                at: fixture.root.appendingPathComponent("docs/external.md"),
                withDestinationURL: outside
            )
            try append(
                "\n[External](external.md)\n",
                to: fixture.root.appendingPathComponent("docs/index.md")
            )
        }
    }

    private func append(_ suffix: String, to url: URL) throws {
        let content = try String(contentsOf: url, encoding: .utf8)
        try (content + suffix).write(to: url, atomically: true, encoding: .utf8)
    }

    private func runDocumentationVerifier(
        repositoryRoot: URL,
        observedTestResult: String? = nil,
        requiresTestEvidence: Bool = false
    ) throws
        -> DocumentationVerifierResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = repository.appendingPathComponent("scripts/verify-docs.sh")
        var environment = ProcessInfo.processInfo.environment
        environment["KINLOGUE_DOCS_REPO_DIR"] = repositoryRoot.path
        environment["KINLOGUE_REQUIRE_TEST_EVIDENCE"] = requiresTestEvidence ? "1" : "0"
        if let observedTestResult {
            let resultURL = repositoryRoot.appendingPathComponent("observed-test-result.log")
            try observedTestResult.write(to: resultURL, atomically: true, encoding: .utf8)
            environment["KINLOGUE_TEST_RESULT_FILE"] = resultURL.path
        } else {
            environment.removeValue(forKey: "KINLOGUE_TEST_RESULT_FILE")
        }
        process.environment = environment
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        return .init(status: process.terminationStatus, output: output)
    }

    private var repository: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private struct DocumentationFixture {
        let container: URL
        let root: URL
        let factMarker: String
    }

    private struct DocumentationVerifierResult {
        let status: Int32
        let output: String
    }

    private enum DocumentationVerifierFault: String, CaseIterable {
        case brokenLink
        case staleFacts
        case missingSafety
        case symlinkEscape

        var expectedDiagnostic: String {
            switch self {
            case .brokenLink: "missing local Markdown link"
            case .staleFacts: "must contain exactly one current release-facts marker"
            case .missingSafety: "missing nearby SAFETY: invariant"
            case .symlinkEscape: "escapes the repository through symlink"
            }
        }
    }
}
