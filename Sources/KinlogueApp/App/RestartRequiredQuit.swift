import AppKit

/// Quits from a sheet whose only way forward is a restart.
@MainActor
enum RestartRequiredQuit {
    /// AppKit refuses to terminate while a modal sheet is attached, and does so without asking
    /// anyone: `terminate` just returns. The restore sheet stays up on purpose in the states that
    /// ask for a restart, so its quit button did nothing. Lifting the windows' veto lets the
    /// ordinary termination run. `exit` is reached only if termination is refused all the same;
    /// by then the library's services are revoked and the next launch settles what is on disk.
    static func perform(
        windows: [NSWindow] = NSApplication.shared.windows,
        terminate: () -> Void = { NSApplication.shared.terminate(nil) },
        exit: (Int32) -> Void = { Darwin.exit($0) }
    ) {
        for window in windows { window.preventsApplicationTerminationWhenModal = false }
        terminate()
        exit(EXIT_SUCCESS)
    }
}
