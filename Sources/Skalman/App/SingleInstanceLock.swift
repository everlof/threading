import Foundation

// MARK: - Single Instance Lock

/// Refuses to run a second Skalman against the same state.
///
/// Two live instances share `projects.json` last-writer-wins: whichever saves last silently
/// clobbers the other's changes — and saves fire on every selection change, so the clobber
/// is a matter of seconds. This is how three projects lost their icon records during a
/// relaunch handoff. The lock is `flock`-based on purpose: advisory, released by the kernel
/// the instant the process dies (no stale-lock cleanup), and independent of bundle
/// identity, which an unbundled `swift build` binary does not have.
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

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let path = directory.appendingPathComponent(SingleInstanceDefaults.lockFileName).path
        descriptor = open(path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else { return true }

        return flock(descriptor, LOCK_EX | LOCK_NB) == 0
    }
}

// MARK: - Single Instance Defaults

enum SingleInstanceDefaults {
    /// Matches `StateManager`'s directory, since the state file is what the lock guards.
    static let applicationDirectoryName = "Skalman"
    static let lockFileName = "skalman.lock"
}
