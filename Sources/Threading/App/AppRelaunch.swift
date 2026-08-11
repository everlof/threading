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

    /// A helper process that has proved it can start, but cannot relaunch the app until
    /// `commit` sends one line over its private pipe.
    ///
    /// Preparation belongs before a reset's first mutation. If anything after it throws, this
    /// object closes the pipe without a line and terminates the helper; the shell's guarded
    /// `read` therefore cannot turn a failed reset into an unrelated relaunch a minute later.
    @MainActor
    final class PreparedRelaunch {
        private let process: Process
        private let signal: FileHandle
        private var isCommitted = false

        fileprivate init(process: Process, signal: FileHandle) {
            self.process = process
            self.signal = signal
        }

        deinit {
            guard !isCommitted else { return }
            try? signal.close()
            if process.isRunning {
                process.terminate()
            }
        }

        /// Releases the already-running helper, records why this launch ended, and exits.
        ///
        /// The signal is sent first. If the helper died in the preparation-to-commit window,
        /// this throws while the current process is still alive and does not stamp a restart
        /// that will never happen.
        func commit(reason: IntentionalExitReason) throws -> Never {
            guard process.isRunning else {
                ThreadingLogger.app.error("Relaunch helper exited before commit")
                throw AppRelaunchError.helperExitedBeforeCommit
            }
            do {
                try signal.write(contentsOf: AppRelaunchDefaults.commitSignal)
            } catch {
                ThreadingLogger.app.error(
                    "Relaunch helper signaling failed: \(error.localizedDescription, privacy: .private(mask: .hash))"
                )
                throw error
            }
            isCommitted = true
            try? signal.close()

            ThreadingLogger.app.notice(
                "Relaunch committed reason=\(reason.rawValue, privacy: .public)"
            )
            recordIntentionalExit(reason: reason)
            exit(EXIT_SUCCESS)
        }
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
    /// Split out from `PreparedRelaunch.commit` so a test can exercise it — the reason
    /// `relaunchCommand(for:)` is also split out — since nothing can call a function that never
    /// returns and then assert.
    static func recordIntentionalExit(reason: IntentionalExitReason = .reset) {
        EventLog.shared.recordIntentionalExit(reason)
        LaunchLedger.shared.endLaunch(.intentional(reason))
    }

    /// Split out so a test can exercise the command that gets built without the process
    /// actually leaving.
    static func relaunchCommand(for bundle: URL) -> [String] {
        [
            "-c",
            "if IFS= read -r signal; then "
                + "sleep \(AppRelaunchDefaults.settleSeconds); /usr/bin/open \"$0\"; fi",
            bundle.path
        ]
    }

    /// Starts the relaunch helper and holds it behind a private commit pipe.
    ///
    /// `executableURL` is injectable only so the failure boundary can be tested without
    /// replacing `/bin/sh` on the machine running the suite.
    @MainActor
    static func prepare(
        for bundle: URL = Bundle.main.bundleURL,
        executableURL: URL = URL(fileURLWithPath: AppRelaunchDefaults.shellPath)
    ) throws -> PreparedRelaunch {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executableURL
        process.arguments = relaunchCommand(for: bundle)
        process.standardInput = pipe
        do {
            try process.run()
        } catch {
            ThreadingLogger.app.error(
                "Relaunch helper start failed executable=\(executableURL.path, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            throw error
        }
        ThreadingLogger.app.info(
            "Relaunch helper prepared process=\(process.processIdentifier, privacy: .public)"
        )
        return PreparedRelaunch(process: process, signal: pipe.fileHandleForWriting)
    }
}

enum AppRelaunchError: LocalizedError {
    case helperExitedBeforeCommit

    var errorDescription: String? {
        switch self {
        case .helperExitedBeforeCommit:
            return "The relaunch helper exited before Threading was ready to restart."
        }
    }
}

// MARK: - Defaults

enum AppRelaunchDefaults {
    static let shellPath = "/bin/sh"
    static let commitSignal = Data([0x0A])

    /// Long enough for the kernel to drop the instance lock with the exiting process, short
    /// enough that the app appears to restart rather than to have quit.
    static let settleSeconds = 1
}
