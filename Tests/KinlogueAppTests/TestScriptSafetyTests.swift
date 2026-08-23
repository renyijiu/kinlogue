import Foundation
import Testing

@Suite(.serialized)
struct TestScriptSafetyTests {
    @Test
    func fullTestRunIncludesAnIsolatedRealSocketRSSGate() throws {
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        #expect(script.contains("KINLOGUE_ENFORCE_ISOLATED_LAN_RSS=1"))
        #expect(script.contains("SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=1"))
        #expect(script.contains(
            "--filter productionFileQueueStaysBoundedWithTwoStreamsSlowPeersAndDisconnect"
        ))
        #expect(script.contains(
            "--skip productionFileQueueStaysBoundedWithTwoStreamsSlowPeersAndDisconnect"
        ))
        #expect(script.contains("if [[ \"$argument\" == \"--filter\""))
        #expect(script.contains("KINLOGUE_PRIMARY_TEST_TIMEOUT_SECONDS"))
        #expect(script.contains("KINLOGUE_ISOLATED_TEST_TIMEOUT_SECONDS"))
        #expect(script.components(separatedBy: "scripts/run-with-deadline.sh").count == 3)
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
}
