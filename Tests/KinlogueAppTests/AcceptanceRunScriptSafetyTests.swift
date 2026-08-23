import Darwin
import Foundation
import Testing

struct AcceptanceRunScriptSafetyTests {
    @Test
    func installedAcceptanceOwnsAndRemovesGeneratedDICOMInput() throws {
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        let generator = try #require(script.range(of: "generate_dicom_acceptance_fixture"))
        let importPhase = try #require(script.range(of: "run_dicom_phase dicom-import"))
        let restartPhase = try #require(script.range(of: "run_dicom_phase dicom-restart"))
        let deletePhase = try #require(script.range(of: "run_dicom_phase dicom-delete"))
        let postDICOMRestart = try #require(
            script.range(of: "post-dicom-restart")
        )
        let cleanup = try #require(script.range(of: "cleanup_owned_dicom_input || fail"))

        #expect(generator.lowerBound < importPhase.lowerBound)
        #expect(importPhase.lowerBound < restartPhase.lowerBound)
        #expect(restartPhase.lowerBound < deletePhase.lowerBound)
        #expect(deletePhase.lowerBound < postDICOMRestart.lowerBound)
        #expect(deletePhase.lowerBound < cleanup.lowerBound)
        #expect(script.contains("KLA_DICOM_IMPORT_COMPLETE"))
        #expect(script.contains("KLA_DICOM_RESTART_COMPLETE"))
        #expect(script.contains("KLA_DICOM_DELETE_COMPLETE"))
        #expect(script.contains("KLA_DICOM_FAILED"))
        #expect(script.contains("maximumConcurrentWorkers"))
        #expect(script.contains("foregroundP95Milliseconds"))
        #expect(script.contains("cachedWindowP95Milliseconds"))
        #expect(script.contains("rssCloseWithinLimit"))
        #expect(script.contains("wait_for_installed_bundle 18000"))
        #expect(script.contains("installedDICOM.foregroundP95Milliseconds"))
        #expect(script.contains("dicomForegroundP95Milliseconds"))
        #expect(script.contains("dicomMaximumLiveDescriptors"))
        #expect(script.contains("dicomPeakAddedDiskBytes"))
        #expect(script.contains(#"FAILURE_STAGE="$phase-timeout""#))
        #expect(script.contains(#"failureStep "$output_file""#))
    }

    @Test
    func installedAcceptanceLaunchesTheOwnedBundleThroughLaunchServices() throws {
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        #expect(script.contains("/usr/bin/open -n -W -g"))
        #expect(script.contains(
            #"--stdout "$output_file" --stderr "$error_file""#
        ))
        #expect(script.contains(
            #"start_installed_bundle "$FORCED_OUT" "$FORCED_ERR""#
        ))
        #expect(script.contains("refresh_active_acceptance_pid"))
        #expect(script.contains(#"FAILURE_STAGE="forced-termination-ready""#))
        #expect(script.contains(#"FAILURE_STAGE="forced-termination-kill""#))
        #expect(script.contains(#"FAILURE_STAGE="forced-termination-launcher-wait""#))
        #expect(!script.split(separator: "\n").contains(where: {
            $0.trimmingCharacters(in: .whitespaces)
                .hasPrefix(#""$ACCEPTANCE_EXECUTABLE""#)
        }))
    }

    @Test
    func installedAcceptanceFailsClosedWithoutProductionLANEvidence() throws {
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        let validatorStart = try #require(
            script.range(of: "validate_lan_receiver_event() {")
        )
        let validatorEnd = try #require(
            script.range(of: "\n}\n", range: validatorStart.upperBound..<script.endIndex)
        )
        let validator = String(
            script[validatorStart.lowerBound..<validatorEnd.upperBound]
        )
        let runnerStart = try #require(
            script.range(of: "run_lan_receiver_phase() {")
        )
        let runnerEnd = try #require(
            script.range(of: "\n}\n", range: runnerStart.upperBound..<script.endIndex)
        )
        let runner = String(script[runnerStart.lowerBound..<runnerEnd.upperBound])
        let receiverFieldsStart = try #require(
            script.range(of: "typeset -ar LAN_RECEIVER_BOOLEAN_FIELDS=(")
        )
        let receiverFieldsEnd = try #require(
            script.range(
                of: "\n)",
                range: receiverFieldsStart.upperBound..<script.endIndex
            )
        )
        let receiverFields = String(
            script[receiverFieldsStart.lowerBound..<receiverFieldsEnd.upperBound]
        )
        let requiredBooleanFields = [
            "listenerAbsentBeforeStart",
            "listenerActiveAfterStart",
            "channelClosedAfterStop",
            "listenerAbsentAfterStop",
            "oldSessionRejected",
            "pairingRejected",
            "authenticationRejected",
            "hostRejected",
            "originRejected",
            "framingRejected",
            "uniqueFilesStored",
            "streamingUploadVerified",
            "interruptedUploadCleanupVerified",
        ]

        #expect(script.contains(
            "run_lan_receiver_phase lan-receiver KLA_LAN_RECEIVER_COMPLETE"
        ))
        #expect(script.contains(
            "run_lan_receiver_phase lan-receiver-restart KLA_LAN_RESTART_COMPLETE"
        ))
        #expect(script.contains("KLA_LAN_RECEIVER_COMPLETE"))
        #expect(script.contains("KLA_LAN_RESTART_COMPLETE"))
        #expect(script.contains("KLA_LAN_RECEIVER_FAILED"))
        #expect(script.contains("^[A-Za-z0-9._-]{1,96}$"))
        let failureEventCheck = try #require(
            runner.range(of: "KLA_LAN_RECEIVER_FAILED")
        )
        let launcherStatusGate = try #require(
            runner.range(
                of: #"[[ "$phase_status" -eq 0 ]]"#,
                range: failureEventCheck.upperBound..<runner.endIndex
            )
        )
        #expect(failureEventCheck.lowerBound < launcherStatusGate.lowerBound)
        #expect(script.contains("productionExecutableProbeExecuted\":true"))
        #expect(script.contains("acceptanceHarnessNetworkClientEntitlement\":true"))
        #expect(script.contains("gates.productionExecutableProbe"))
        #expect(script.contains(#"-string passed "$VERIFICATION_CANDIDATE""#))
        #expect(validator.contains("executableSHA256"))
        #expect(validator.contains("$ACCEPTANCE_EXECUTABLE_HASH"))
        #expect(validator.contains(#"json_value $field "$file""#))
        #expect(validator.contains(#"${LAN_RECEIVER_BOOLEAN_FIELDS[@]}"#))
        #expect(validator.contains(#"${LAN_RESTART_BOOLEAN_FIELDS[@]}"#))
        for field in requiredBooleanFields {
            #expect(
                receiverFields.contains(field),
                "missing fail-closed validation for \(field)"
            )
        }
        #expect(script.contains("completedFilesAfterProcessRestart"))
        #expect(script.contains("listenerAbsentAfterRestartStop"))
    }

    @Test
    func successReportPublicationRequiresStrictTemporaryCleanup() throws {
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        let cleanup = try #require(script.range(of: "cleanup_temp || fail\n"))
        let publication = try #require(script.range(
            of: #"/bin/mv -- "$ACCEPTANCE_CANDIDATE" "$REPORT_PATH" || fail"#
        ))

        #expect(cleanup.lowerBound < publication.lowerBound)
        #expect(script.contains(
            #"/bin/mv -- "$candidate" "$quarantine" >/dev/null 2>&1 || return 1"#
        ))
        #expect(script.contains(
            #"[[ "$cleanup_failed" == false ]]"#
        ))
    }

    @Test
    func successFinalizationFailsClosedWhenTempQuarantineExists() throws {
        let token = "f00000000000000000000008"
        let bootstrapURL = URL(
            fileURLWithPath: "/tmp/kinlogue-acceptance.fault.\(token)",
            isDirectory: true
        )
        let quarantineURL = URL(
            fileURLWithPath: bootstrapURL.path + ".removal",
            isDirectory: true
        )
        let sentinelURL = quarantineURL.appendingPathComponent("sentinel")
        try #require(!entryExists(bootstrapURL))
        try #require(!entryExists(quarantineURL))
        defer {
            try? FileManager.default.removeItem(at: bootstrapURL)
            try? FileManager.default.removeItem(at: quarantineURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [scriptURL.path]
        var environment = ProcessInfo.processInfo.environment
        environment["KINLOGUE_ACCEPTANCE_INTERNAL_FAULT_TEST"] =
            "success-cleanup-failure"
        environment["KINLOGUE_ACCEPTANCE_INTERNAL_TEST_TOKEN"] = token
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let error = stderr.fileHandleForReading.readDataToEndOfFile()
        let event = try #require(
            JSONSerialization.jsonObject(with: output) as? [String: Any]
        )

        #expect(process.terminationStatus == 1)
        #expect(error.isEmpty)
        #expect(event["code"] as? String == "KLA_RUN_FAILED")
        #expect(event["ok"] as? Bool == false)
        #expect(entryExists(sentinelURL))
    }

    @Test
    func descriptorBoundDeletionLeavesAReplacementQuarantineUntouched() throws {
        let token = "f00000000000000000000007"
        let bootstrapURL = URL(
            fileURLWithPath: "/tmp/kinlogue-acceptance.fault.\(token)",
            isDirectory: true
        )
        let quarantineURL = URL(
            fileURLWithPath: bootstrapURL.path + ".removal",
            isDirectory: true
        )
        let displacedURL = URL(
            fileURLWithPath: bootstrapURL.path + ".displaced",
            isDirectory: true
        )
        let readyURL = URL(fileURLWithPath: bootstrapURL.path + ".race-ready")
        let continueURL = URL(
            fileURLWithPath: bootstrapURL.path + ".race-continue"
        )
        let replacementSentinelURL = quarantineURL
            .appendingPathComponent("replacement/sentinel")
        let allURLs = [
            bootstrapURL,
            quarantineURL,
            displacedURL,
            readyURL,
            continueURL,
        ]
        for url in allURLs {
            try #require(
                !entryExists(url),
                "race test requires an initially clean target"
            )
        }
        defer {
            for url in allURLs {
                try? FileManager.default.removeItem(at: url)
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [scriptURL.path]
        var environment = ProcessInfo.processInfo.environment
        environment["KINLOGUE_ACCEPTANCE_INTERNAL_FAULT_TEST"] =
            "quarantine-replacement-race"
        environment["KINLOGUE_ACCEPTANCE_INTERNAL_TEST_TOKEN"] = token
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        defer {
            if process.isRunning {
                _ = kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }
        let readyDeadline = Date().addingTimeInterval(5)
        while !entryExists(readyURL), Date() < readyDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(entryExists(readyURL), "bound deletion did not reach its race checkpoint")
        let originalIdentity = try directoryIdentity(quarantineURL)

        try FileManager.default.moveItem(at: quarantineURL, to: displacedURL)
        try FileManager.default.createDirectory(
            at: replacementSentinelURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("replacement-must-survive".utf8).write(
            to: replacementSentinelURL,
            options: .withoutOverwriting
        )
        #expect(FileManager.default.createFile(atPath: continueURL.path, contents: Data()))

        process.waitUntilExit()
        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()

        #expect(process.terminationReason == .exit)
        #expect(process.terminationStatus == 1)
        #expect(stderrData.isEmpty)
        let event = try #require(
            JSONSerialization.jsonObject(with: stdoutData) as? [String: Any]
        )
        #expect(event["code"] as? String == "KLA_RUN_FAILED")
        #expect(event["ok"] as? Bool == false)
        #expect(try Data(contentsOf: replacementSentinelURL)
            == Data("replacement-must-survive".utf8))
        #expect(try directoryIdentity(displacedURL) == originalIdentity)
        #expect(try FileManager.default.contentsOfDirectory(
            atPath: displacedURL.path
        ).isEmpty)
    }

    @Test(arguments: AcceptanceRunFaultCase.allCases)
    func failureFinalizerAndTempHandoffAreCrashRetrySafe(
        _ fault: AcceptanceRunFaultCase
    ) throws {
        let repositoryURL = self.repositoryURL
        let bootstrapURL = URL(
            fileURLWithPath: "/tmp/kinlogue-acceptance.fault.\(fault.token)",
            isDirectory: true
        )
        let canonicalURL = URL(
            fileURLWithPath: "/tmp/kinlogue-acceptance.\(fault.token)",
            isDirectory: true
        )
        let removalURLs = [
            URL(fileURLWithPath: bootstrapURL.path + ".removal"),
            URL(fileURLWithPath: canonicalURL.path + ".removal"),
        ]
        let buildStageURL = repositoryURL
            .appendingPathComponent("dist/acceptance/.run-build.\(fault.token)")
        let buildStageRemovalURL = URL(
            fileURLWithPath: buildStageURL.path + ".removal"
        )
        for url in [bootstrapURL, canonicalURL, buildStageURL]
            + removalURLs + [buildStageRemovalURL] {
            #expect(!entryExists(url), "fault test requires an initially clean target")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [scriptURL.path]
        var environment = ProcessInfo.processInfo.environment
        environment["KINLOGUE_ACCEPTANCE_INTERNAL_FAULT_TEST"] = fault.rawValue
        environment["KINLOGUE_ACCEPTANCE_INTERNAL_TEST_TOKEN"] = fault.token
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        var trackedChildPID: pid_t?
        if fault == .buildDuringSignal {
            let readyURL = buildStageURL.appendingPathComponent("child-ready")
            let childPIDURL = buildStageURL.appendingPathComponent("child.pid")
            let deadline = Date().addingTimeInterval(5)
            while !entryExists(readyURL), Date() < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            #expect(entryExists(readyURL), "tracked build child did not become ready")
            if let data = FileManager.default.contents(atPath: childPIDURL.path),
               let value = Int32(
                   String(decoding: data, as: UTF8.self)
                       .trimmingCharacters(in: .whitespacesAndNewlines)
               ) {
                trackedChildPID = value
            }
            #expect(trackedChildPID != nil)
            #expect(kill(process.processIdentifier, SIGTERM) == 0)
            let exitDeadline = Date().addingTimeInterval(5)
            while process.isRunning, Date() < exitDeadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            let exceededSignalDeadline = process.isRunning
            if exceededSignalDeadline {
                if let trackedChildPID {
                    _ = kill(trackedChildPID, SIGKILL)
                }
                _ = kill(process.processIdentifier, SIGKILL)
            }
            #expect(!exceededSignalDeadline, "signal finalization exceeded five seconds")
        }
        process.waitUntilExit()
        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()

        #expect(process.terminationReason == .exit)
        #expect(process.terminationStatus == fault.expectedExitStatus)
        #expect(stderrData.isEmpty)
        let line = String(decoding: stdoutData, as: UTF8.self)
        #expect(line.filter { $0 == "\n" }.count == 1)
        let object = try #require(
            JSONSerialization.jsonObject(with: stdoutData) as? [String: Any]
        )
        #expect(object["code"] as? String == "KLA_RUN_FAILED")
        #expect(object["ok"] as? Bool == false)
        #expect(Set(object.keys) == [
            "attachmentCount",
            "code",
            "dicomCachedWindowP95Milliseconds",
            "dicomForegroundP95Milliseconds",
            "dicomManagedFullReadBytes",
            "dicomMaximumConcurrentWorkers",
            "dicomMaximumLiveDescriptors",
            "dicomMaximumManagedFullReadsPerObject",
            "dicomMaximumQueueDepth",
            "dicomMaximumWritesPerObject",
            "dicomPeakAddedDiskBytes",
            "dicomRSSPeakDeltaBytes",
            "dicomSourceBytesRead",
            "dicomStagingBytesWritten",
            "failureStage",
            "memberCount",
            "ok",
            "recordCount",
            "scanCode",
            "scanCount",
            "scanSHA256",
            "summarySHA256",
            "tokenSetSHA256",
        ])

        for url in [bootstrapURL, canonicalURL, buildStageURL]
            + removalURLs + [buildStageRemovalURL] {
            #expect(!entryExists(url), "failure finalization must remove every owned temp name")
        }
        if let trackedChildPID {
            errno = 0
            #expect(kill(trackedChildPID, 0) == -1)
            #expect(errno == ESRCH)
        }
    }

    private func entryExists(_ url: URL) -> Bool {
        var metadata = stat()
        return lstat(url.path, &metadata) == 0
    }

    private func directoryIdentity(_ url: URL) throws -> (dev_t, ino_t) {
        var metadata = stat()
        try #require(lstat(url.path, &metadata) == 0)
        try #require((metadata.st_mode & S_IFMT) == S_IFDIR)
        return (metadata.st_dev, metadata.st_ino)
    }

    private var repositoryURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var scriptURL: URL {
        repositoryURL.appendingPathComponent("scripts/run-acceptance.sh")
    }
}

enum AcceptanceRunFaultCase: String, CaseIterable, Sendable {
    case doubleSignalFinalizer = "double-signal-finalizer"
    case handoffBeforeRename = "handoff-before-rename"
    case handoffAfterRenameBeforePrimary = "handoff-after-rename-before-primary"
    case handoffAfterPrimaryBeforeAlternate = "handoff-after-primary-before-alternate"
    case stagedAfterRegistration = "staged-after-registration"
    case buildDuringSignal = "build-during-signal"

    var token: String {
        switch self {
        case .doubleSignalFinalizer:
            "f00000000000000000000001"
        case .handoffBeforeRename:
            "f00000000000000000000002"
        case .handoffAfterRenameBeforePrimary:
            "f00000000000000000000003"
        case .handoffAfterPrimaryBeforeAlternate:
            "f00000000000000000000004"
        case .stagedAfterRegistration:
            "f00000000000000000000005"
        case .buildDuringSignal:
            "f00000000000000000000006"
        }
    }

    var expectedExitStatus: Int32 {
        switch self {
        case .doubleSignalFinalizer:
            1
        case .handoffBeforeRename, .handoffAfterRenameBeforePrimary,
             .handoffAfterPrimaryBeforeAlternate, .stagedAfterRegistration:
            143
        case .buildDuringSignal:
            143
        }
    }
}
