import Foundation
import Testing

@Suite(.serialized)
struct TestScriptSafetyTests {
    @Test
    func fullTestRunIncludesIsolatedInstalledLANAndRealSocketRSSGates() throws {
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        #expect(script.contains("KINLOGUE_ENFORCE_ISOLATED_LAN_RSS=1"))
        #expect(script.contains("KINLOGUE_BUILD_JOBS"))
        #expect(script.contains("KINLOGUE_PRIMARY_TEST_PARTITION"))
        #expect(script.contains("-j \"$KINLOGUE_BUILD_JOBS\""))
        #expect(!script.contains("--parallel"))
        #expect(!script.contains("--num-workers"))
        #expect(!script.contains("KINLOGUE_TEST_WORKERS"))
        #expect(script.components(separatedBy: "--no-parallel").count == 10)
        #expect(!script.contains("SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH"))
        #expect(script.contains("--filter KinlogueCoreTests"))
        #expect(script.contains("primary-test-shards.rb"))
        #expect(script.contains("run-test-shard.rb"))
        #expect(script.contains("swift test \"${SWIFT_TEST_ARGUMENTS[@]}\""))
        #expect(script.contains("list > \"$PRIMARY_TEST_LIST\""))
        let dedicatedBundleBuild = try #require(script.range(of: "--build-tests"))
        #expect(script.contains("/usr/bin/xcrun xctest"))
        let dedicatedDerivedGate = try #require(script.range(of:
            "-XCTest \"$derived_xctest_case\""
        ))
        #expect(script.contains(
            "LANDerivedArtifactSinkTests/testProductionAdmissionUsesTheDocumentedStoreAndOwnerBounds"
        ))
        #expect(script.contains(
            "LANDerivedArtifactSinkTests/testRejectsNonPrivateOrHardLinkedDescriptorsAtOwnershipTransfer"
        ))
        #expect(script.contains(
            "Executed 1 test, with 0 failures (0 unexpected)"
        ))
        #expect(!script.contains(
            "Executed 13 tests, with 0 failures (0 unexpected)"
        ))
        #expect(script.contains("--disable-swift-testing --enable-xctest"))
        #expect(script.contains("--show-bin-path"))
        #expect(script.contains("KinloguePackageTests.xctest"))
        let inventoryBuild = try #require(script.range(of: "list > \"$PRIMARY_TEST_LIST\""))
        #expect(dedicatedBundleBuild.lowerBound < dedicatedDerivedGate.lowerBound)
        #expect(dedicatedDerivedGate.lowerBound < inventoryBuild.lowerBound)
        #expect(script.contains(
            "PRIMARY_PARTITION_INDEX\" -eq $((PRIMARY_PARTITION_COUNT - 1))"
        ))
        #expect(script.contains("--skip-build"))
        #expect(script.contains("--filter KinlogueStorageProcessTests"))
        #expect(script.contains(
            "--filter differentlyCasedVaultAliasesShareStableAndLegacyLockIdentity"
        ))
        #expect(script.contains("--filter AcceptanceScanScriptTests"))
        #expect(script.contains("--skip AcceptanceScanScriptTests"))
        let acceptanceScanGate = try #require(
            script.range(of: "--filter AcceptanceScanScriptTests")
        )
        let primaryShardLoop = try #require(script.range(of: "while IFS=$'\\t' read"))
        #expect(acceptanceScanGate.lowerBound < primaryShardLoop.lowerBound)
        #expect(script.contains("--filter DICOMImportWorkflowIntegrationTests"))
        #expect(script.contains("--skip DICOMImportWorkflowIntegrationTests"))
        #expect(script.contains(
            "--filter installedLANProbeUsesProductionHTTPAndPersistsAcrossProcessPhases"
        ))
        #expect(script.contains(
            "--skip installedLANProbeUsesProductionHTTPAndPersistsAcrossProcessPhases"
        ))
        #expect(script.contains(
            "--filter productionFileQueueStaysBoundedWithTwoStreamsSlowPeersAndDisconnect"
        ))
        #expect(script.contains(
            "--skip productionFileQueueStaysBoundedWithTwoStreamsSlowPeersAndDisconnect"
        ))
        #expect(script.contains("if [[ \"$argument\" == \"--filter\""))
        #expect(script.contains("KINLOGUE_PRIMARY_TEST_TIMEOUT_SECONDS"))
        #expect(script.contains("KINLOGUE_ISOLATED_TEST_TIMEOUT_SECONDS"))
        #expect(script.contains("SHARD_SUPERVISOR_TIMEOUT_SECONDS"))
        #expect(script.contains(
            "KINLOGUE_TEST_SUMMARY_MAX_SECONDS=\"$SHARD_SUPERVISOR_TIMEOUT_SECONDS\""
        ))
        #expect(script.components(separatedBy: "scripts/run-with-deadline.sh").count == 14)
    }

    @Test
    func primaryShardPlannerPartitionsEveryNonIsolatedSpecifierExactlyOnce() throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kinlogue-primary-shards-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: fixture) }
        let specifiers = [
            "KinlogueCoreTests.coreRule()",
            "KinloguePlatformTests.BackupSuite/first()",
            "KinloguePlatformTests.BackupSuite/second()",
            "KinloguePlatformTests.platformRule()",
            "KinloguePlatformTests.DICOMImportWorkflowIntegrationTests/isolatedDICOM()",
            "KinloguePlatformTests.LANRealSocketBackpressureTests/ordinarySocketRule()",
            "KinloguePlatformTests.LANRealSocketBackpressureTests/productionFileQueueStaysBoundedWithTwoStreamsSlowPeersAndDisconnect()",
            "KinlogueAppTests.AppSuite/first()",
            "KinlogueAppTests.AppSuite/second()",
            "KinlogueAppTests.appRule()",
            "KinlogueAppTests.AcceptanceScanScriptTests/isolatedScan()",
            "KinlogueAppTests.SyntheticAcceptanceRunnerTests/ordinaryRunnerRule()",
            "KinlogueAppTests.SyntheticAcceptanceRunnerTests/installedLANProbeUsesProductionHTTPAndPersistsAcrossProcessPhases()",
            "KinlogueStorageProcessTests.StorageSuite/isolatedStorage()",
            "KinloguePlatformTests.differentlyCasedVaultAliasesShareStableAndLegacyLockIdentity()",
            "KinloguePlatformTests.LANDeliveryPrerequisiteTests/first()",
            "KinloguePlatformTests.LANDeliveryPrerequisiteTests/second()",
            "KinloguePlatformTests.LANDerivedArtifactSinkTests/first()",
            "KinloguePlatformTests.LANDerivedArtifactSinkTests/second()",
        ]
        try (specifiers.joined(separator: "\n") + "\n").write(
            to: fixture,
            atomically: true,
            encoding: .utf8
        )

        let complete = try runPrimaryShardPlanner(fixture: fixture)
        let firstPartition = try runPrimaryShardPlanner(
            fixture: fixture,
            partitionIndex: 0,
            partitionCount: 3
        )
        let secondPartition = try runPrimaryShardPlanner(
            fixture: fixture,
            partitionIndex: 1,
            partitionCount: 3
        )
        let dedicatedPartition = try runPrimaryShardPlanner(
            fixture: fixture,
            partitionIndex: 2,
            partitionCount: 3
        )
        #expect(complete.status == 0, Comment(rawValue: complete.output))
        #expect(firstPartition.status == 0, Comment(rawValue: firstPartition.output))
        #expect(secondPartition.status == 0, Comment(rawValue: secondPartition.output))
        #expect(dedicatedPartition.status == 0, Comment(rawValue: dedicatedPartition.output))
        let text = complete.output

        let patterns = text.split(separator: "\n").compactMap { line -> String? in
            let fields = line.split(separator: "\t", maxSplits: 2).map(String.init)
            return fields.count == 3 ? fields[2] : nil
        }
        #expect(patterns.count == text.split(separator: "\n").count)
        let primarySpecifiers = [
            specifiers[1], specifiers[2], specifiers[3], specifiers[5], specifiers[7],
            specifiers[8], specifiers[9], specifiers[11],
            specifiers[15], specifiers[16],
        ]
        let excludedSpecifiers = [
            specifiers[0], specifiers[4], specifiers[6], specifiers[10], specifiers[12],
            specifiers[13], specifiers[14], specifiers[17], specifiers[18],
        ]
        #expect(patterns.count == 3)
        let firstPatterns = shardPatterns(in: firstPartition.output)
        let secondPatterns = shardPatterns(in: secondPartition.output)
        let dedicatedPatterns = shardPatterns(in: dedicatedPartition.output)
        #expect(firstPatterns.count + secondPatterns.count == 3)
        #expect(abs(firstPatterns.count - secondPatterns.count) <= 1)
        #expect(dedicatedPatterns.count == 1)
        #expect(dedicatedPatterns[0].contains("LANDerivedArtifactSinkTests"))
        #expect(!dedicatedPatterns[0].contains("LANDeliveryPrerequisiteTests"))
        #expect(Set(firstPatterns).isDisjoint(with: Set(secondPatterns)))
        #expect(Set(firstPatterns + secondPatterns).isDisjoint(with: Set(dedicatedPatterns)))
        #expect(Set(firstPatterns + secondPatterns) == Set(patterns))
        #expect(Set(firstPatterns + secondPatterns + dedicatedPatterns).count == 4)
        #expect(patterns.allSatisfy {
            !($0.contains("LANDeliveryPrerequisiteTests") &&
                $0.contains("LANDerivedArtifactSinkTests"))
        })
        for specifier in primarySpecifiers {
            let runtimeID = runtimeIdentifier(for: specifier)
            #expect(patterns.filter { matches($0, runtimeID) }.count == 1)
        }
        for specifier in excludedSpecifiers {
            let runtimeID = runtimeIdentifier(for: specifier)
            #expect(patterns.allSatisfy { !matches($0, runtimeID) })
        }
    }

    @Test
    func shardSummarySupervisorCleansTheOwnedSessionWithoutMaskingFailures() throws {
        let successful = try runShardSupervisor(
            expectedTests: 1,
            expectedSuites: 0,
            rubyProgram: """
            Process.spawn("/bin/sleep", "60", pgroup: true)
            puts "✔ Test run with 1 test in 0 suites passed after 0.001 seconds."
            STDOUT.flush
            sleep 60
            """
        )
        #expect(successful.status == 0, Comment(rawValue: successful.output))
        #expect(successful.output.contains("KLT_TEST_SUMMARY_TEARDOWN tests=1 suites=0"))

        let decoratedSummary = try runShardSupervisor(
            expectedTests: 1,
            expectedSuites: 0,
            rubyProgram: """
            puts "\u{001B}[32m✔ Test run with\u{001B}[0m \u{001B}[1m1\u{001B}[0m test in 0 suites passed after 0.001 seconds."
            STDOUT.flush
            sleep 60
            """
        )
        #expect(decoratedSummary.status == 0, Comment(rawValue: decoratedSummary.output))

        let failedAfterSummary = try runShardSupervisor(
            expectedTests: 1,
            expectedSuites: 0,
            rubyProgram: """
            puts "✔ Test run with 1 test in 0 suites passed after 0.001 seconds."
            exit 42
            """
        )
        #expect(failedAfterSummary.status == 42)

        let mismatched = try runProcess(
            executable: shardSupervisorURL,
            arguments: [
                "2", "0", "/usr/bin/ruby", "-e",
                "puts '✔ Test run with 1 test in 0 suites passed after 0.001 seconds.'; STDOUT.flush; sleep 60",
            ],
            environment: [
                "KINLOGUE_TEST_SUMMARY_GRACE_SECONDS": "1",
                "KINLOGUE_TEST_SUMMARY_MAX_SECONDS": "1",
            ]
        )
        #expect(mismatched.status == 124, Comment(rawValue: mismatched.output))
    }

    @Test
    func shardSummarySupervisorTerminatesATrackedDescendantThatCreatesANewSession() throws {
        let childPIDURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kinlogue-shard-resession-child-\(UUID().uuidString)"
        )
        var childPID: Int32?
        defer {
            try? FileManager.default.removeItem(at: childPIDURL)
            if let childPID, processExists(childPID) {
                signal("KILL", pid: childPID)
            }
        }

        let fixture = #"""
        child_pid_file = ARGV.fetch(0)
        child_pid = Process.spawn(
          "/usr/bin/ruby", "-e", <<~'RUBY', child_pid_file,
            Process.setsid
            Signal.trap("TERM", "IGNORE")
            File.write(ARGV.fetch(0), Process.pid.to_s)
            loop { sleep 1 }
          RUBY
          out: "/dev/null", err: "/dev/null"
        )
        sleep 0.01 until File.exist?(child_pid_file)
        sleep 0.2
        puts "✔ Test run with 1 test in 0 suites passed after 0.001 seconds."
        STDOUT.flush
        """#
        let result = try runProcess(
            executable: shardSupervisorURL,
            arguments: [
                "1", "0", "/usr/bin/ruby", "-e", fixture, childPIDURL.path,
            ],
            environment: [
                "KINLOGUE_TEST_SUMMARY_GRACE_SECONDS": "1",
                "KINLOGUE_TEST_SUMMARY_MAX_SECONDS": "3",
            ]
        )
        let childPIDText = try String(contentsOf: childPIDURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsedChildPID = Int32(childPIDText, radix: 10) else {
            Issue.record("Shard fixture wrote an invalid re-sessioned child PID")
            return
        }
        childPID = parsedChildPID

        #expect(result.status == 0, Comment(rawValue: result.output))
        #expect(result.output.contains("KLT_TEST_SUMMARY_TEARDOWN tests=1 suites=0"))
        let deadline = Date().addingTimeInterval(2)
        while processExists(parsedChildPID), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        #expect(!processExists(parsedChildPID))
    }

    @Test
    func shardSummarySupervisorTimeoutTerminatesATrackedResessionedDescendant() throws {
        let childPIDURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kinlogue-shard-timeout-resession-child-\(UUID().uuidString)"
        )
        var childPID: Int32?
        defer {
            try? FileManager.default.removeItem(at: childPIDURL)
            if let childPID, processExists(childPID) {
                signal("KILL", pid: childPID)
            }
        }

        let fixture = #"""
        child_pid_file = ARGV.fetch(0)
        Process.spawn(
          "/usr/bin/ruby", "-e", <<~'RUBY', child_pid_file,
            Process.setsid
            Signal.trap("TERM", "IGNORE")
            File.write(ARGV.fetch(0), Process.pid.to_s)
            loop { sleep 1 }
          RUBY
          out: "/dev/null", err: "/dev/null"
        )
        sleep 0.01 until File.exist?(child_pid_file)
        sleep 60
        """#
        let result = try runProcess(
            executable: shardSupervisorURL,
            arguments: [
                "1", "0", "/usr/bin/ruby", "-e", fixture, childPIDURL.path,
            ],
            environment: [
                "KINLOGUE_TEST_SUMMARY_GRACE_SECONDS": "1",
                "KINLOGUE_TEST_SUMMARY_MAX_SECONDS": "1",
            ]
        )
        let childPIDText = try String(contentsOf: childPIDURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsedChildPID = Int32(childPIDText, radix: 10) else {
            Issue.record("Shard timeout fixture wrote an invalid re-sessioned child PID")
            return
        }
        childPID = parsedChildPID

        #expect(result.status == 124, Comment(rawValue: result.output))
        let deadline = Date().addingTimeInterval(2)
        while processExists(parsedChildPID), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        #expect(!processExists(parsedChildPID))
    }

    @Test
    func commandDeadlineTerminatesAStalledOwnedProcess() throws {
        let process = Process()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [deadlineScriptURL.path, "1", "/bin/sleep", "10"]
        process.standardError = standardError

        let startedAt = Date()
        try process.run()
        process.waitUntilExit()
        let elapsed = Date().timeIntervalSince(startedAt)
        let error = standardError.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(decoding: error, as: UTF8.self)

        #expect(process.terminationStatus == 124)
        #expect(elapsed < 5)
        #expect(errorText.contains("KLT_COMMAND_TIMEOUT seconds=1"))
    }

    @Test
    func commandDeadlineKillsAReparentedDescendantThatIgnoresTerm() throws {
        let childPIDURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kinlogue-deadline-child-\(UUID().uuidString)"
        )
        var childPID: Int32?
        defer {
            try? FileManager.default.removeItem(at: childPIDURL)
            if let childPID, processExists(childPID) {
                signal("KILL", pid: childPID)
            }
        }

        let fixture = #"""
        child_pid_file="$1"
        /bin/zsh -c 'trap "" TERM; while true; do /bin/sleep 1; done' &
        child_pid=$!
        print -r -- "$child_pid" > "$child_pid_file"
        trap 'exit 0' TERM
        wait "$child_pid"
        """#
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            deadlineScriptURL.path,
            "1",
            "/bin/zsh",
            "-c",
            fixture,
            "kinlogue-deadline-fixture",
            childPIDURL.path,
        ]
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()
        let childPIDText = try String(contentsOf: childPIDURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsedChildPID = Int32(childPIDText, radix: 10) else {
            Issue.record("Deadline fixture wrote an invalid child PID")
            return
        }
        childPID = parsedChildPID

        #expect(process.terminationStatus == 124)
        let deadline = Date().addingTimeInterval(2)
        while processExists(try #require(childPID)), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        #expect(!processExists(try #require(childPID)))
    }

    @Test
    func commandDeadlineKillsAChildForkedByTheRootTermHandler() throws {
        let childPIDURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kinlogue-deadline-late-child-\(UUID().uuidString)"
        )
        var childPID: Int32?
        defer {
            try? FileManager.default.removeItem(at: childPIDURL)
            if let childPID, processExists(childPID) {
                signal("KILL", pid: childPID)
            }
        }

        let fixture = #"""
        child_pid_file="$1"
        spawn_late_child() {
          /bin/zsh -c 'trap "" TERM; while true; do /bin/sleep 1; done' &
          print -r -- "$!" > "$child_pid_file"
          exit 0
        }
        trap spawn_late_child TERM
        while true; do /bin/sleep 1; done
        """#
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            deadlineScriptURL.path,
            "1",
            "/bin/zsh",
            "-c",
            fixture,
            "kinlogue-deadline-late-fork-fixture",
            childPIDURL.path,
        ]
        process.standardError = Pipe()

        let startedAt = Date()
        try process.run()
        process.waitUntilExit()
        let elapsed = Date().timeIntervalSince(startedAt)
        let childPIDText = try String(contentsOf: childPIDURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsedChildPID = Int32(childPIDText, radix: 10) else {
            Issue.record("Deadline fixture wrote an invalid late child PID")
            return
        }
        childPID = parsedChildPID

        #expect(process.terminationStatus == 124)
        #expect(elapsed < 10)
        let deadline = Date().addingTimeInterval(2)
        while processExists(try #require(childPID)), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        #expect(!processExists(try #require(childPID)))
    }

    @Test
    func commandDeadlineKillsADescendantThatCreatesItsOwnProcessGroup() throws {
        let childPIDURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kinlogue-deadline-child-group-\(UUID().uuidString)"
        )
        var childPID: Int32?
        defer {
            try? FileManager.default.removeItem(at: childPIDURL)
            if let childPID, processExists(childPID) {
                signal("KILL", pid: childPID)
            }
        }

        let fixture = #"""
        child_pid_file="$1"
        /usr/bin/ruby -e '
          Process.setpgrp
          Signal.trap("TERM", "IGNORE")
          File.write(ARGV.fetch(0), Process.pid.to_s)
          loop { sleep 1 }
        ' "$child_pid_file" &
        wait
        """#
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            deadlineScriptURL.path,
            "1",
            "/bin/zsh",
            "-c",
            fixture,
            "kinlogue-deadline-child-group-fixture",
            childPIDURL.path,
        ]
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()
        let childPIDText = try String(contentsOf: childPIDURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsedChildPID = Int32(childPIDText, radix: 10) else {
            Issue.record("Deadline fixture wrote an invalid process-group child PID")
            return
        }
        childPID = parsedChildPID

        #expect(process.terminationStatus == 124)
        let deadline = Date().addingTimeInterval(2)
        while processExists(parsedChildPID), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        #expect(!processExists(parsedChildPID))
    }

    @Test
    func commandDeadlineDoesNotSignalAnUnrelatedProcess() throws {
        let unrelated = Process()
        unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep")
        unrelated.arguments = ["20"]
        try unrelated.run()
        defer {
            if unrelated.isRunning { unrelated.terminate() }
            unrelated.waitUntilExit()
        }

        let deadline = Process()
        deadline.executableURL = URL(fileURLWithPath: "/bin/zsh")
        deadline.arguments = [deadlineScriptURL.path, "1", "/bin/sleep", "10"]
        deadline.standardError = Pipe()
        try deadline.run()
        deadline.waitUntilExit()

        #expect(deadline.terminationStatus == 124)
        #expect(unrelated.isRunning)
    }

    @Test
    func commandDeadlineRejectsAnInvalidDurationBeforeLaunching() throws {
        let markerURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kinlogue-deadline-marker-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: markerURL) }

        let process = Process()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            deadlineScriptURL.path,
            "0",
            "/usr/bin/touch",
            markerURL.path,
        ]
        process.standardError = standardError

        try process.run()
        process.waitUntilExit()
        let error = standardError.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(decoding: error, as: UTF8.self)

        #expect(process.terminationStatus == 64)
        #expect(errorText.contains("deadline must be an integer from 1 through 86400 seconds"))
        #expect(!FileManager.default.fileExists(atPath: markerURL.path))

        let script = try String(contentsOf: deadlineScriptURL, encoding: .utf8)

        #expect(script.contains("Process.setsid"))
        #expect(script.contains("Process.getsid"))
        #expect(script.contains("COMMAND_PGID=$COMMAND_PID"))
        #expect(script.contains("COMMAND_SESSION_ID=$COMMAND_PID"))
        #expect(script.contains("signal_owned_session TERM"))
        #expect(script.contains("signal_owned_session KILL"))
        #expect(script.contains("reap_owned_root_if_exited"))
        #expect(!script.contains("collect_process_tree"))
        #expect(script.contains("exit 124"))
    }

    private func processExists(_ pid: Int32) -> Bool {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/bin/kill")
        probe.arguments = ["-0", String(pid)]
        probe.standardOutput = FileHandle.nullDevice
        probe.standardError = FileHandle.nullDevice
        do {
            try probe.run()
            probe.waitUntilExit()
            return probe.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func signal(_ name: String, pid: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/kill")
        process.arguments = ["-\(name)", String(pid)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    private func matches(_ pattern: String, _ value: String) -> Bool {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.firstMatch(in: value, range: range) != nil
    }

    private func runtimeIdentifier(for listedSpecifier: String) -> String {
        let withoutSignature: Substring
        if let openingParenthesis = listedSpecifier.firstIndex(of: "(") {
            withoutSignature = listedSpecifier[..<openingParenthesis]
        } else {
            withoutSignature = listedSpecifier[...]
        }
        return String(withoutSignature)
    }

    private func runShardSupervisor(
        expectedTests: Int,
        expectedSuites: Int,
        rubyProgram: String
    ) throws -> (status: Int32, output: String) {
        try runProcess(
            executable: shardSupervisorURL,
            arguments: [
                String(expectedTests), String(expectedSuites), "/usr/bin/ruby", "-e", rubyProgram,
            ],
            environment: [
                "KINLOGUE_TEST_SUMMARY_GRACE_SECONDS": "1",
                "KINLOGUE_TEST_SUMMARY_MAX_SECONDS": "3",
            ]
        )
    }

    private func runPrimaryShardPlanner(
        fixture: URL,
        partitionIndex: Int? = nil,
        partitionCount: Int? = nil
    ) throws -> (status: Int32, output: String) {
        var arguments = [primaryShardPlannerURL.path, fixture.path]
        if let partitionIndex, let partitionCount {
            arguments.append(contentsOf: [String(partitionIndex), String(partitionCount)])
        }
        return try runProcess(
            executable: URL(fileURLWithPath: "/usr/bin/ruby"),
            arguments: arguments,
            environment: [:]
        )
    }

    private func shardPatterns(in text: String) -> [String] {
        text.split(separator: "\n").compactMap { line -> String? in
            let fields = line.split(separator: "\t", maxSplits: 2).map(String.init)
            return fields.count == 3 ? fields[2] : nil
        }
    }

    private func runProcess(
        executable: URL,
        arguments: [String],
        environment: [String: String]
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }

    private var scriptURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/test.sh")
    }

    private var deadlineScriptURL: URL {
        scriptURL.deletingLastPathComponent().appendingPathComponent("run-with-deadline.sh")
    }

    private var primaryShardPlannerURL: URL {
        scriptURL.deletingLastPathComponent().appendingPathComponent("primary-test-shards.rb")
    }

    private var shardSupervisorURL: URL {
        scriptURL.deletingLastPathComponent().appendingPathComponent("run-test-shard.rb")
    }
}
