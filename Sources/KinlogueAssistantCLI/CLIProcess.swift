import Darwin
import Foundation
import os

public struct CLIProcessLimits: Equatable, Sendable {
    /// The first stdout byte must arrive within this many seconds; nil waits for the total timeout.
    public var startTimeout: TimeInterval? = 10
    public var totalTimeout: TimeInterval = 180
    public var maximumLineBytes = 256 * 1_024
    /// stdout and stderr together.
    public var maximumOutputBytes = 2 * 1_024 * 1_024
    /// Time between SIGTERM and SIGKILL when the process group is stopped.
    public var terminationGrace: TimeInterval = 2

    public init() {}
}

public enum CLIProcessEnding: Equatable, Sendable {
    case exited(Int32)
    case signaled(Int32)
    case timedOut
    case cancelled
    case outputTooLarge
    /// The line handler threw; the process group was stopped.
    case lineHandlerStopped
    case launchFailed
}

public struct CLIProcessResult: Sendable {
    public let ending: CLIProcessEnding
    /// stdout, kept only when asked for, for short outputs such as `--version`.
    public let output: Data
    /// The last bytes of stderr. They stay inside the bridge: they are parsed, never shown or logged.
    public let errorTail: String
}

/// Requests that a running process be stopped. The runner checks it between reads.
public final class CLICancellation: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)

    public init() {}

    public func cancel() { state.withLock { $0 = true } }

    public var isCancelled: Bool { state.withLock { $0 } }
}

/// Runs one CLI command in its own process group with bounded output and time. The input goes to
/// stdin; arguments and environment are exactly what the caller passes. With a supervisor, the
/// supervisor leads the group and kills it if this process dies (see `CLISupervisor`).
public enum CLIProcess {
    static let errorTailBytes = 4 * 1_024
    static let pollMilliseconds: Int32 = 50

    public static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String,
        input: Data,
        supervisor: URL?,
        limits: CLIProcessLimits,
        cancellation: CLICancellation?,
        retainOutput: Bool = false,
        onLine: (Data) throws -> Void
    ) -> CLIProcessResult {
        let argv = supervisor.map {
            [$0.path, CLISupervisor.flag, String(getpid()), environment.keys.sorted().joined(separator: ","), executable.path]
        } ?? [executable.path]
        guard let child = Spawned(
            path: (supervisor ?? executable).path,
            arguments: argv + arguments,
            environment: supervisor == nil ? environment : CLISupervisor.supervisorEnvironment(for: environment),
            workingDirectory: workingDirectory
        ) else {
            return CLIProcessResult(ending: .launchFailed, output: Data(), errorTail: "")
        }
        defer { child.closeDescriptors() }

        let started = ProcessInfo.processInfo.systemUptime
        var stdinOffset = 0
        var stdinOpen = true
        var outputOpen = true
        var errorOpen = true
        var sawOutput = false
        var outputBytes = 0
        var line = Data()
        var retained = Data()
        var errorTail = Data()
        var ending: CLIProcessEnding?
        var status: Int32?
        var exitedAt: TimeInterval?
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)

        if input.isEmpty { child.closeInput(); stdinOpen = false }

        loop: while true {
            let now = ProcessInfo.processInfo.systemUptime
            if cancellation?.isCancelled == true {
                ending = .cancelled
            } else if now - started > limits.totalTimeout {
                ending = .timedOut
            } else if let startTimeout = limits.startTimeout, !sawOutput, now - started > startTimeout {
                ending = .timedOut
            }
            if ending != nil { break }

            if status == nil, let reaped = child.reap(blocking: false) {
                status = reaped
                exitedAt = now
            }
            if status != nil, !outputOpen, !errorOpen { break }
            // A descendant that keeps the pipes open after the CLI exits does not hold the turn.
            if let exitedAt, now - exitedAt > 0.5 { break }

            var descriptors: [pollfd] = []
            if stdinOpen { descriptors.append(pollfd(fd: child.input, events: Int16(POLLOUT), revents: 0)) }
            if outputOpen { descriptors.append(pollfd(fd: child.output, events: Int16(POLLIN), revents: 0)) }
            if errorOpen { descriptors.append(pollfd(fd: child.error, events: Int16(POLLIN), revents: 0)) }
            guard !descriptors.isEmpty else {
                usleep(UInt32(pollMilliseconds) * 1_000)
                continue
            }
            guard poll(&descriptors, nfds_t(descriptors.count), pollMilliseconds) >= 0 || errno == EINTR else {
                ending = .launchFailed
                break
            }

            for descriptor in descriptors where descriptor.revents != 0 {
                if descriptor.fd == child.input {
                    let written = input.withUnsafeBytes { bytes in
                        write(child.input, bytes.baseAddress!.advanced(by: stdinOffset), min(64 * 1_024, bytes.count - stdinOffset))
                    }
                    if written > 0 { stdinOffset += written }
                    if (written < 0 && errno != EAGAIN && errno != EINTR) || stdinOffset == input.count {
                        child.closeInput()
                        stdinOpen = false
                    }
                    continue
                }
                let count = read(descriptor.fd, &buffer, buffer.count)
                if count < 0 { if errno == EAGAIN || errno == EINTR { continue } }
                if count <= 0 {
                    if descriptor.fd == child.output { outputOpen = false } else { errorOpen = false }
                    continue
                }
                outputBytes += count
                if outputBytes > limits.maximumOutputBytes {
                    ending = .outputTooLarge
                    break loop
                }
                if descriptor.fd == child.error {
                    errorTail.append(contentsOf: buffer[0..<count])
                    if errorTail.count > errorTailBytes { errorTail.removeFirst(errorTail.count - errorTailBytes) }
                    continue
                }
                sawOutput = true
                if retainOutput { retained.append(contentsOf: buffer[0..<count]) }
                line.append(contentsOf: buffer[0..<count])
                while let newline = line.firstIndex(of: 0x0A) {
                    let complete = line[line.startIndex..<newline]
                    line.removeSubrange(line.startIndex...newline)
                    do {
                        try onLine(Data(complete))
                    } catch {
                        ending = .lineHandlerStopped
                        break loop
                    }
                }
                if line.count > limits.maximumLineBytes {
                    ending = .outputTooLarge
                    break loop
                }
            }
        }

        if ending == nil, !line.isEmpty {
            do { try onLine(line) } catch { ending = .lineHandlerStopped }
        }
        if status == nil { status = child.stop(grace: limits.terminationGrace) }
        // Sweep anything the CLI left behind in its group, even after a normal exit.
        child.killGroup()

        let final: CLIProcessEnding
        if let ending {
            final = ending
        } else if let status, status & 0x7f == 0 {
            final = .exited((status >> 8) & 0xff)
        } else {
            final = .signaled((status ?? 0) & 0x7f)
        }
        return CLIProcessResult(ending: final, output: retained, errorTail: String(decoding: errorTail, as: UTF8.self))
    }
}

/// One spawned process group: the child leads a new group, and the parent keeps non-blocking pipe
/// ends for its stdin, stdout and stderr.
private final class Spawned {
    let pid: pid_t
    private(set) var input: Int32
    let output: Int32
    let error: Int32
    private var reaped = false

    init?(path: String, arguments: [String], environment: [String: String], workingDirectory: String) {
        var stdinPipe: [Int32] = [-1, -1], stdoutPipe: [Int32] = [-1, -1], stderrPipe: [Int32] = [-1, -1]
        guard pipe(&stdinPipe) == 0 else { return nil }
        guard pipe(&stdoutPipe) == 0 else { Self.close(stdinPipe); return nil }
        guard pipe(&stderrPipe) == 0 else { Self.close(stdinPipe + stdoutPipe); return nil }
        let all = stdinPipe + stdoutPipe + stderrPipe

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        guard posix_spawn_file_actions_adddup2(&actions, stdinPipe[0], STDIN_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, stderrPipe[1], STDERR_FILENO) == 0,
              posix_spawn_file_actions_addchdir(&actions, workingDirectory) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0 else {
            Self.close(all)
            return nil
        }
        let argv = arguments.map { strdup($0) } + [nil]
        let envp = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var spawned: pid_t = 0
        let result = argv.withUnsafeBufferPointer { argvBuffer in
            envp.withUnsafeBufferPointer { envpBuffer in
                posix_spawn(&spawned, path, &actions, &attributes, argvBuffer.baseAddress!, envpBuffer.baseAddress!)
            }
        }
        Self.close([stdinPipe[0], stdoutPipe[1], stderrPipe[1]])
        guard result == 0, spawned > 1 else {
            Self.close([stdinPipe[1], stdoutPipe[0], stderrPipe[0]])
            return nil
        }
        pid = spawned
        input = stdinPipe[1]
        output = stdoutPipe[0]
        error = stderrPipe[0]
        for descriptor in [input, output, error] {
            _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        }
        _ = fcntl(input, F_SETNOSIGPIPE, 1)
    }

    func closeInput() {
        guard input >= 0 else { return }
        Darwin.close(input)
        input = -1
    }

    func closeDescriptors() {
        closeInput()
        Darwin.close(output)
        Darwin.close(error)
    }

    /// The raw wait status once the direct child has exited.
    func reap(blocking: Bool) -> Int32? {
        guard !reaped else { return nil }
        var status: Int32 = 0
        let result = waitpid(pid, &status, blocking ? 0 : WNOHANG)
        if result == pid {
            reaped = true
            return status
        }
        if result < 0 && errno == ECHILD { reaped = true }
        return nil
    }

    /// SIGTERM to the group, SIGKILL after the grace period, then waits for the direct child.
    func stop(grace: TimeInterval) -> Int32? {
        _ = kill(-pid, SIGTERM)
        let deadline = ProcessInfo.processInfo.systemUptime + grace
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let status = reap(blocking: false) { return status }
            if reaped { return nil }
            usleep(10_000)
        }
        _ = kill(-pid, SIGKILL)
        return reap(blocking: true)
    }

    func killGroup() {
        _ = kill(-pid, SIGKILL)
    }

    private static func close(_ descriptors: [Int32]) {
        descriptors.filter { $0 >= 0 }.forEach { Darwin.close($0) }
    }
}
