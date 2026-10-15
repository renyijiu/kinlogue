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

    /// The resolved path, or nil when `path` does not pass the checks.
    public static func validated(_ path: String) -> String? {
        guard path.hasPrefix("/"), (path as NSString).lastPathComponent == name,
              let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        let real = String(cString: resolved)
        var info = stat()
        guard stat(real, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid() || info.st_uid == 0,
              info.st_mode & (S_IWGRP | S_IWOTH) == 0,
              access(real, X_OK) == 0 else { return nil }
        return real
    }

    public static func discover(explicit: String?, candidates: [String]) -> String? {
        if let explicit { return validated(explicit) }
        return candidates.lazy.compactMap(validated).first
    }
}
