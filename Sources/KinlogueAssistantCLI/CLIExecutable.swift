import Darwin
import Foundation

/// Finds and checks the user's `codex`. A path is never trusted as given: it must be named
/// `codex` and resolve to a regular executable owned by the user or root that no one else can write.
public enum CLIExecutable {
    public static let name = "codex"

    /// The fixed places the bridge looks, in order.
    public static func candidatePaths(home: String) -> [String] {
        [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            home + "/.local/bin/codex",
            home + "/.npm-global/bin/codex",
            home + "/.bun/bin/codex",
            home + "/.volta/bin/codex",
        ]
    }

    public enum Inspection: Equatable, Sendable {
        case usable(resolved: String)
        case missing
        /// Not named codex, not a regular file, not executable, or writable by others.
        case rejected
        /// The file is there but this process may not reach or run it: a location outside the
        /// bridge's sandbox exceptions.
        case outsideAllowedLocations
    }

    /// The resolved path, or nil when `path` does not pass the checks.
    public static func validated(_ path: String) -> String? {
        guard case let .usable(resolved) = inspect(path) else { return nil }
        return resolved
    }

    public static func inspect(_ path: String) -> Inspection {
        guard path.hasPrefix("/"), (path as NSString).lastPathComponent == name else { return .rejected }
        guard let resolved = realpath(path, nil) else { return denied(errno) ? .outsideAllowedLocations : .missing }
        defer { free(resolved) }
        let real = String(cString: resolved)
        var info = stat()
        guard stat(real, &info) == 0 else { return denied(errno) ? .outsideAllowedLocations : .missing }
        guard info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid() || info.st_uid == 0,
              info.st_mode & (S_IWGRP | S_IWOTH) == 0,
              info.st_mode & S_IXUSR != 0 else { return .rejected }
        // The sandbox lets the bridge see the file but refuses to run it outside its exceptions.
        guard access(real, X_OK) == 0 else { return denied(errno) ? .outsideAllowedLocations : .rejected }
        return .usable(resolved: real)
    }

    private static func denied(_ code: Int32) -> Bool {
        code == EPERM || code == EACCES
    }

    /// The path that was asked for and the file it resolves to. The resolved file is what runs; the
    /// requested folder is where an npm-style wrapper finds its interpreter.
    public struct Located: Equatable, Sendable {
        public let requested: String
        public let resolved: String
    }

    public static func locate(explicit: String?, candidates: [String]) -> Located? {
        for path in explicit.map({ [$0] }) ?? candidates {
            if let resolved = validated(path) { return Located(requested: path, resolved: resolved) }
        }
        return nil
    }

}
