import Darwin
import Foundation

// MARK: - Single Instance Owner Card

/// Who holds the lock, written into the lock file the moment it is taken.
///
/// `flock` answers exactly one question — "is somebody else running" — and the lockout this
/// exists for needed three more: *which* process, *which copy* of the app, and whether that pid
/// still means the same process. A wedged Threading held the lock with no window and no remote,
/// and every fresh launch could do nothing but put up an alert and quit.
///
/// **Information, never authority.** The lock is what enforces single instance; a missing, torn
/// or unreadable card only ever costs the losing launch its extra choices. It never costs the
/// refusal, and it can never grant one.
///
/// The bundle path is the app's own, and is the whole reason a loser can say "a copy in
/// DerivedData is holding this" rather than "something is". Nothing else about the user is here.
struct SingleInstanceOwnerCard: Codable, Equatable, Sendable {
    let pid: Int32
    /// The kernel's own start timestamp, so a recycled pid cannot be mistaken for the owner.
    /// The same identity pair `OrphanedAgentChildSweep` acts on, for the same reason.
    let startTime: ProcessStartTime
    let bundlePath: String
    let version: String
    let writtenAt: String
}

// MARK: - Single Instance Lock

/// Refuses to run a second Threading against the same state.
///
/// Two live instances share the store last-writer-wins: whichever saves last silently
/// clobbers the other's changes — and saves fire on every selection change, so the clobber
/// is a matter of seconds. This is how three projects lost their icon records during a
/// relaunch handoff. The lock is `flock`-based on purpose: advisory, released by the kernel
/// the instant the process dies (no stale-lock cleanup), and independent of bundle
/// identity, which an unbundled `swift build` binary does not have.
@MainActor
enum SingleInstanceLock {

    /// Held open for the process's lifetime; the kernel drops the lock with it.
    private static var descriptor: Int32 = -1

    /// The descriptor the lock is held on, or `-1`. Readable so a test can assert the
    /// close-on-exec flag on it: that flag is the whole fix for the inherited-lock lockout, and
    /// nothing else about the app's behaviour would change if it were dropped again.
    static var heldDescriptor: Int32 { descriptor }

    // MARK: - Locations

    /// The directory the lock and the heartbeat share, derived here rather than through
    /// `AppDataLocations`: the lock is deliberately bundle-independent, and that type reads the
    /// bundle identifier for its other half.
    nonisolated static var directoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(SingleInstanceDefaults.applicationDirectoryName)
    }

    nonisolated static var lockFileURL: URL {
        directoryURL.appendingPathComponent(SingleInstanceDefaults.lockFileName)
    }

    // MARK: - Public Methods

    /// Takes the lock, or reports that another instance already holds it.
    ///
    /// Fails **open**: if the lock file cannot even be created, launching wins over
    /// enforcing — a permissions oddity should not brick the app.
    static func acquire() -> Bool {
        acquire(at: lockFileURL)
    }

    /// The whole mechanism against an explicit path.
    ///
    /// Separate so a test can exercise the `flock`, the card and the reader against a temporary
    /// file instead of against the lock the user's own Threading is holding. It writes the
    /// process-wide descriptor either way, which is safe because a hosted test bundle never
    /// reaches the real `acquire()` — `applicationDidFinishLaunching` returns above it.
    static func acquire(at url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            ThreadingLogger.app.error(
                "Single-instance lock directory preparation failed; launch is continuing without a guaranteed lock: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
        }

        // **`O_CLOEXEC` is load-bearing, and its absence is what locked a user out overnight.**
        //
        // An `flock` lives on the open file description and is held while *any* duplicate of that
        // descriptor exists. Without close-on-exec, every child this process spawns inherits one:
        // `forkpty` duplicates the whole table, and `exec` keeps whatever is not marked. Measured
        // on a live instance, ten `claude`/`node` children each held fd 6 on the lock file. So
        // when the app died, its orphaned agent children went on holding its lock — for hours —
        // and every relaunch was refused with no Threading running to switch to.
        //
        // The triage below is the answer to a *wedged* owner. This flag is the answer to a dead
        // one, and the two are different failures.
        descriptor = open(
            url.path,
            O_CREAT | O_RDWR | O_CLOEXEC,
            SingleInstanceDefaults.lockFileMode
        )
        guard descriptor >= 0 else {
            let code = errno
            ThreadingLogger.app.error(
                "Single-instance lock file could not be opened; launch is continuing without a lock (errno=\(code, privacy: .public))"
            )
            return true
        }

        guard flock(descriptor, LOCK_EX | LOCK_NB) != 0 else {
            ThreadingLogger.app.info("Single-instance state lock acquired")
            writeOwnerCard(into: descriptor)
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

    /// Who the lock file says is holding it, or `nil` for anything that cannot be believed.
    ///
    /// Opened **read-only and without `flock`**, so asking costs the owner nothing and the
    /// question can be put by the very process the owner has locked out. Bounded, and every
    /// failure — absent, empty, truncated mid-write, garbage from an older format — answers the
    /// same `nil`, which the triage reads as "say nothing, do nothing".
    static func readOwnerCard(at url: URL = lockFileURL) -> SingleInstanceOwnerCard? {
        guard let data = try? BoundedFileReader.read(
            url,
            maximumBytes: SingleInstanceDefaults.maximumOwnerCardBytes
        ), !data.isEmpty else { return nil }

        return try? JSONDecoder().decode(SingleInstanceOwnerCard.self, from: data)
    }

    /// Drops the held descriptor, and with it the lock.
    ///
    /// Nothing in the app calls this — the lock is held for the process's lifetime on purpose,
    /// and released by the kernel. It exists so a test that took a lock at a temporary path can
    /// give it back instead of leaking a descriptor per case.
    static func relinquish() {
        guard descriptor >= 0 else { return }
        close(descriptor)
        descriptor = -1
    }

    // MARK: - Private Methods

    /// Stamps the card into the descriptor the lock is already held on.
    ///
    /// `ftruncate` first, because a shorter card written over a longer one would otherwise leave
    /// the tail of the old one behind and read back as garbage. Every failure here is logged and
    /// swallowed: the acquire has already succeeded, and the lock is the load-bearing half.
    ///
    /// Reachable from the test bundle rather than private, because "a card that cannot be
    /// written does not fail the acquire" is the property that matters most here and there is no
    /// way to make `ftruncate` refuse an `O_RDWR` descriptor from outside.
    static func writeOwnerCard(into descriptor: Int32) {
        let pid = ProcessInfo.processInfo.processIdentifier
        guard let startTime = ProcessUtility.startTime(forPid: pid) else {
            ThreadingLogger.app.error(
                "Single-instance owner card skipped: the kernel would not report this process's start time"
            )
            return
        }

        let card = SingleInstanceOwnerCard(
            pid: pid,
            startTime: startTime,
            bundlePath: Bundle.main.bundlePath,
            version: versionString,
            writtenAt: timestamp()
        )

        guard let data = try? JSONEncoder().encode(card) else {
            ThreadingLogger.app.error("Single-instance owner card could not be encoded")
            return
        }

        guard ftruncate(descriptor, 0) == 0, lseek(descriptor, 0, SEEK_SET) == 0 else {
            let code = errno
            ThreadingLogger.app.error(
                "Single-instance owner card could not be truncated (errno=\(code, privacy: .public))"
            )
            return
        }

        let written = data.withUnsafeBytes { buffer in
            write(descriptor, buffer.baseAddress, buffer.count)
        }
        if written != data.count {
            let code = errno
            ThreadingLogger.app.error(
                "Single-instance owner card was written short (errno=\(code, privacy: .public))"
            )
        }
    }

    /// Built per call rather than held: this runs once per launch, and a formatter is not
    /// `Sendable`, so a shared one would have to be excused from concurrency checking to save
    /// nothing.
    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }

    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

// MARK: - Single Instance Defaults

enum SingleInstanceDefaults {
    /// Matches `StateManager`'s directory, since the state file is what the lock guards.
    static let applicationDirectoryName = "Threading"
    static let lockFileName = "threading.lock"

    /// Beside the lock, because the two are read together and reset together.
    static let heartbeatFileName = "threading.heartbeat"

    static let lockFileMode: mode_t = 0o644

    /// A refusal boundary rather than an expected size: a real card is a few hundred bytes, and
    /// anything past this is not one.
    static let maximumOwnerCardBytes = 4 * 1_024

    /// How often the owner says its main thread is still turning.
    static let heartbeatInterval: TimeInterval = 5
    static let heartbeatLeewaySeconds = 1

    /// How old a heartbeat has to be before a takeover is even *offered*. Six missed ticks: long
    /// enough that a busy launch, a slow disk or a debugger pause cannot reach it, short enough
    /// that a locked-out user is not waiting on it.
    static let staleThreshold: TimeInterval = 30

    static let takeoverMessage = "Took over the single-instance lock from an unresponsive instance"

    /// What the takeover record carries, spelled once so the journal and its test agree.
    static let ownerPIDField = "ownerPID"
    static let ownerPathField = "ownerPath"
    static let stalenessField = "stalenessSeconds"
    static let escalatedField = "escalatedToKill"
    static let endedChildrenField = "endedChildren"
}
