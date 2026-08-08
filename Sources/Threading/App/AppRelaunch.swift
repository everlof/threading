import AppKit

/// Restarts Threading, without letting the copy that is leaving write anything down.
///
/// Used by the reset actions and by the recovery surface's "Try Normal Launch Once". The two
/// halves are both deliberate, and both apply verbatim to the third caller — recovery skipped
/// starting subsystems, so starting them mid-process is the in-place-reset problem below in its
/// other direction, and there is nothing it would want saved on the way out:
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
    ///
    /// The reason travels with the exit rather than being inferred at the next launch, because
    /// the next launch treats the two differently: a reset restores its workspace, and a recovery
    /// relaunch holds it back.
    static func discardingState(reason: IntentionalExitReason = .reset) -> Never {
        spawnRelauncher(for: Bundle.main.bundleURL)
        recordIntentionalExit(reason: reason)
        exit(EXIT_SUCCESS)
    }

    /// Says, on the way out, that this was on purpose.
    ///
    /// **Here rather than at the two reset call sites.** This is the only path in the app that
    /// leaves without the quit path, so it is the only place the fact exists; a caller that had
    /// to remember would eventually be a caller that did not, and the cost of forgetting is the
    /// next launch calling a user-requested restart a crash — holding their workspace back and
    /// putting a crash notice over the window they just asked for. Reset Settings did exactly
    /// that: it leaves the support directory alone, so the launch marker survived the restart.
    ///
    /// **Immediately before `exit`**, and after the relauncher is already spawned, because
    /// everything between the stamp and the exit is a window in which a genuine crash would be
    /// reported as a deliberate restart. Two statements is as small as that window gets.
    ///
    /// Split out from the exit so a test can exercise it — the reason `relaunchCommand(for:)` is
    /// also split out — since nothing can call a function that never returns and then assert.
    static func recordIntentionalExit(reason: IntentionalExitReason = .reset) {
        EventLog.shared.recordIntentionalExit(reason)
        LaunchLedger.shared.endLaunch(.intentional(reason))
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
