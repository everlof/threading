import Foundation

// MARK: - Single Instance Lock

/// Refuses to run a second Threading against the same state.
///
/// Two live instances share `projects.json` last-writer-wins: whichever saves last silently
/// clobbers the other's changes — and saves fire on every selection change, so the clobber
/// is a matter of seconds. This is how three projects lost their icon records during a
/// relaunch handoff. The lock is `flock`-based on purpose: advisory, released by the kernel
/// the instant the process dies (no stale-lock cleanup), and independent of bundle
/// identity, which an unbundled `swift build` binary does not have.
@MainActor
enum SingleInstanceLock {

    /// Held open for the process's lifetime; the kernel drops the lock with it.
    private static var descriptor: Int32 = -1

    /// Takes the lock, or reports that another instance already holds it.
    ///
    /// Fails **open**: if the lock file cannot even be created, launching wins over
    /// enforcing — a permissions oddity should not brick the app.
    static func acquire() -> Bool {
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent(SingleInstanceDefaults.applicationDirectoryName)

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            ThreadingLogger.app.error(
                "Single-instance lock directory preparation failed; launch is continuing without a guaranteed lock: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
        }

        let path = directory.appendingPathComponent(SingleInstanceDefaults.lockFileName).path
        descriptor = open(path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else {
            let code = errno
            ThreadingLogger.app.error(
                "Single-instance lock file could not be opened; launch is continuing without a lock (errno=\(code, privacy: .public))"
            )
            return true
        }

        guard flock(descriptor, LOCK_EX | LOCK_NB) != 0 else {
            ThreadingLogger.app.info("Single-instance state lock acquired")
            return true
        }

        let code = errno
        close(descriptor)
        descriptor = -1

        if code == EWOULDBLOCK || code == EAGAIN {
            ThreadingLogger.app.notice(
                "Duplicate launch refused because the state lock is already held"
            )
            return false
        }

        ThreadingLogger.app.error(
            "Single-instance state lock failed; launch is continuing without a lock (errno=\(code, privacy: .public))"
        )
        return true
    }
}

// MARK: - Single Instance Defaults

enum SingleInstanceDefaults {
    /// Matches `StateManager`'s directory, since the state file is what the lock guards.
    static let applicationDirectoryName = "Threading"
    static let lockFileName = "threading.lock"
}
