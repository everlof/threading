import AppKit

/// Restarts Threading, without letting the copy that is leaving write anything down.
///
/// Used by the reset actions, and only by them. The two halves are both deliberate:
///
/// - **A detached relauncher, not `openApplication`.** `SingleInstanceLock` is an `flock` held
///   for the process's lifetime, so a second instance started while this one is still exiting
///   sees the lock and refuses to launch. `/bin/sh` outlives us, waits, and opens the bundle
///   once the kernel has dropped the lock with the process.
/// - **`exit`, not `NSApp.terminate`.** Terminating runs the shutdown every store hangs its
///   final save on, and those stores hold in memory exactly the state the reset just moved
///   aside — the window layout, the projects, the session list. A polite quit would write all
///   of it straight back into a fresh directory and the reset would appear not to have worked.
///   Discarding is the whole point here, so this leaves without asking anyone to save.
enum AppRelaunch {

    /// Relaunches and leaves immediately, writing nothing. **Does not return.**
    static func discardingState() -> Never {
        spawnRelauncher(for: Bundle.main.bundleURL)
        exit(EXIT_SUCCESS)
    }

    /// Split out so a test can exercise the command that gets built without the process
    /// actually leaving.
    static func relaunchCommand(for bundle: URL) -> [String] {
        [
            "-c",
            "sleep \(AppRelaunchDefaults.settleSeconds); /usr/bin/open \"$0\"",
            bundle.path
        ]
    }

    private static func spawnRelauncher(for bundle: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: AppRelaunchDefaults.shellPath)
        process.arguments = relaunchCommand(for: bundle)
        try? process.run()
    }
}

// MARK: - Defaults

enum AppRelaunchDefaults {
    static let shellPath = "/bin/sh"

    /// Long enough for the kernel to drop the instance lock with the exiting process, short
    /// enough that the app appears to restart rather than to have quit.
    static let settleSeconds = 1
}
