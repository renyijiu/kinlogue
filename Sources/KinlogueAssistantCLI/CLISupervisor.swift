import Darwin
import Foundation

/// The process-group leader between the bridge and the CLI. The bridge starts its own executable
/// as `<self> --supervise <bridge pid> <variable names> <cli> <arguments…>`; the supervisor starts
/// the CLI with the same descriptors and only the named variables, exits with the CLI's status, and
/// kills the whole group if the bridge dies first. Without it, a killed bridge would leave the CLI
/// and anything it started running.
///
/// The CLI's variables arrive under `environmentPrefix` and the names are passed, because the
/// supervisor's own environment is not the bridge's: Foundation adds variables such as
/// `__CF_USER_TEXT_ENCODING`, and App Sandbox points `HOME` and `TMPDIR` at the container.
public enum CLISupervisor {
    public static let flag = "--supervise"
    /// The CLI's variables travel to the supervisor under this prefix. App Sandbox resets the
    /// sandboxed supervisor's own `HOME` and `TMPDIR` to its container when it starts, so the
    /// supervisor must not hand its own values on.
    public static let environmentPrefix = "KINLOGUE_CLI_ENV_"

    /// The supervisor's environment for a CLI that should get `environment`.
    public static func supervisorEnvironment(for environment: [String: String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: environment.map { (environmentPrefix + $0.key, $0.value) })
    }
    /// The supervisor's status when it could not start the CLI at all.
    public static let couldNotStartStatus: Int32 = 127

    public static func run(arguments: [String]) -> Never {
        guard arguments.count >= 5, arguments[1] == flag,
              let parent = pid_t(arguments[2]), parent > 1, getppid() == parent else {
            exit(126)
        }
        let names = Set(arguments[3].split(separator: ",").map(String.init))
        let command = Array(arguments[4...])
        let argv = command.map { strdup($0) } + [nil]
        let own = ProcessInfo.processInfo.environment
        let envp = names.sorted().compactMap { name in
            own[environmentPrefix + name].map { strdup("\(name)=\($0)") }
        } + [nil]
        var child: pid_t = 0
        let result = argv.withUnsafeBufferPointer { argvBuffer in
            envp.withUnsafeBufferPointer { envpBuffer in
                posix_spawn(&child, command[0], nil, nil, argvBuffer.baseAddress!, envpBuffer.baseAddress!)
            }
        }
        argv.forEach { free($0) }
        envp.forEach { free($0) }
        guard result == 0, child > 1 else { exit(couldNotStartStatus) }

        while true {
            if getppid() != parent {
                _ = kill(-getpgrp(), SIGKILL)
                _exit(125)
            }
            var status: Int32 = 0
            let waited = waitpid(child, &status, WNOHANG)
            if waited == child {
                exit(status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f))
            }
            if waited < 0 && errno == ECHILD { exit(0) }
            usleep(20_000)
        }
    }
}
