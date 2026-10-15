import Darwin
import Foundation

/// The process-group leader between the bridge and the CLI. The bridge starts its own executable
/// as `<self> --supervise <bridge pid> <variable names> <cli> <arguments…>`; the supervisor starts
/// the CLI with the same descriptors and only the named variables, exits with the CLI's status, and
/// kills the whole group if the bridge dies first. Without it, a killed bridge would leave the CLI
/// and anything it started running.
///
/// The names are passed because Foundation adds variables of its own, such as
/// `__CF_USER_TEXT_ENCODING`, to the supervisor's environment at launch.
public enum CLISupervisor {
    public static let flag = "--supervise"

    public static func run(arguments: [String]) -> Never {
        guard arguments.count >= 5, arguments[1] == flag,
              let parent = pid_t(arguments[2]), parent > 1, getppid() == parent else {
            exit(126)
        }
        let names = Set(arguments[3].split(separator: ",").map(String.init))
        let command = Array(arguments[4...])
        let argv = command.map { strdup($0) } + [nil]
        let envp = ProcessInfo.processInfo.environment
            .filter { names.contains($0.key) }
            .map { strdup("\($0.key)=\($0.value)") } + [nil]
        var child: pid_t = 0
        let result = argv.withUnsafeBufferPointer { argvBuffer in
            envp.withUnsafeBufferPointer { envpBuffer in
                posix_spawn(&child, command[0], nil, nil, argvBuffer.baseAddress!, envpBuffer.baseAddress!)
            }
        }
        argv.forEach { free($0) }
        envp.forEach { free($0) }
        guard result == 0, child > 1 else { exit(127) }

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
