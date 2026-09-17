import Dispatch
import Foundation
import ThreadingPTYHostKit

// MARK: - Defaults

/// Every constant `threading-ptyd` has, in one namespace.
///
/// The daemon links `ThreadingPTYHostKit` and nothing else, so anything the wire already decides
/// — the frame bound, the replay budget range, the ring size — is read from the package rather
/// than restated here. What is left is the daemon's own behaviour: how much it will buffer for a
/// watcher, how long it holds an exited session, and how quickly it escalates a kill.
///
/// There is no path here on purpose. The socket and the state directory are both arguments,
/// because the app decides where they live (`MCPBridgeLocation` makes the same decision for the
/// bridge) and a daemon that derived either would be a second place for that decision to be
/// wrong.
enum PTYHostDefaults {

    // MARK: - Scheduling

    /// The daemon is on the causal path from a typed key to its echoed cell, but the same queue
    /// also records output for detached agents that have no visible deadline. User-initiated is
    /// the deliberate middle: never background/utility scheduling, without assigning a whole
    /// unattended agent's byte stream animation priority. The attached app-side queue owns the
    /// final, user-interactive leg.
    static let eventQueueQoS = DispatchQoS.userInitiated

    // MARK: - Listener

    /// Pending connections the kernel will hold. Watchers are counted in ones — the app, a test,
    /// later the phone's mirror — so this is generous rather than tuned.
    static let socketBacklog: Int32 = 16

    /// The rendezvous is owner-only, like the directory holding it. The `0700` directory is the
    /// authorization boundary for this protocol; the socket mode restates it for anything that
    /// ever moves the file.
    static let socketPermissions: mode_t = 0o600

    /// The state directory, created and then re-applied, because it may already exist from a run
    /// that used the default mask.
    static let directoryPermissions = 0o700
    static let filePermissions: mode_t = 0o600

    // MARK: - Bytes

    /// One read of a PTY master, and therefore the largest `output` frame the daemon emits.
    ///
    /// Well under the package's 1 MiB frame bound: a repaint arrives as several frames rather
    /// than one enormous one, so a slow watcher is never waiting on a megabyte it cannot use yet.
    static let readChunkBytes = 64 * 1024

    /// Per-session ring capacity — the package's number, which is the remote mirror's number.
    static let ringBytes = PTYHostReplayDefaults.ringBufferBytes

    /// The floor a ring is shrunk to when the aggregate cap is exceeded. Below this a replay is
    /// a few lines of a wide grid, which is worse than saying `.cut` honestly.
    static let minimumRingBytes = 32 * 1024

    /// **The aggregate bound.** A per-session cap is not an aggregate one: 64 detached sessions
    /// at 512 KiB is 32 MiB of resident ring in a process the user can see in Activity Monitor.
    /// Past this the oldest *detached* session's ring is halved towards `minimumRingBytes`, and
    /// every shrink is journalled — a loss of history nobody was told about is the failure this
    /// avoids.
    static let aggregateRingBytes = 32 * 1024 * 1024

    /// A test and stress seam, never a user setting: the aggregate budget in bytes.
    ///
    /// The cap is reached at 64 simultaneous sessions, which no test should have to spawn to
    /// prove the policy. Read once at startup, clamped, and journalled when it is honoured, so a
    /// daemon running with a lowered budget says so in its own log rather than looking broken.
    static let ringBudgetEnvironmentKey = "THREADING_PTY_HOST_RING_BUDGET"

    /// What one watcher may fall behind by before it is dropped.
    ///
    /// **The PTY read never blocks on a watcher.** A connection that cannot keep up is closed and
    /// journalled, because the alternative — waiting for it — stops the child that is producing
    /// the bytes, and a stalled agent is a worse outcome than a terminal that has to reattach.
    /// Four mebibytes is eight full rings: a watcher that far behind is not slow, it is gone.
    static let maximumPendingWriteBytes = 4 * 1024 * 1024

    /// What may be queued towards one child's master before input is dropped and journalled.
    /// Keystrokes are bytes; a paste is kilobytes; a megabyte outstanding means the child has
    /// stopped reading, and growing a buffer for it would only move the failure.
    static let maximumPendingInputBytes = 1 * 1024 * 1024

    /// The bound on one `journalTail` answer, whatever the caller asked for.
    static let maximumJournalTailBytes = 256 * 1024

    // MARK: - Timing

    /// How long `kill(escalate:)` waits after `SIGTERM` before `SIGKILL`.
    static let killEscalationGrace: TimeInterval = 2

    /// How long an `exited` frame waits for the master to finish draining.
    ///
    /// The child's last write is often still in the pty buffer when the kernel reports the exit,
    /// and a watcher that is told "it ended" before it is shown the ending has lost the output it
    /// most wanted. The wait ends early — as soon as the master reaches end of file — and is
    /// bounded because a surviving grandchild can hold the slave open indefinitely.
    static let exitDrainGrace: TimeInterval = 0.5

    /// How long an exited session is held once its exit has been delivered.
    ///
    /// Held at all so a watcher that reconnects a moment later still learns how the session
    /// ended rather than being told the id is unknown. Bounded because the record is the last
    /// thing anybody wants and the ring behind it is half a mebibyte.
    static let exitedRetention: TimeInterval = 5

    /// The ceiling on holding an exit **nobody** has collected. A session that exits while the
    /// app is closed is kept for this long, then released and journalled.
    static let unobservedExitRetention: TimeInterval = 30 * 60

    /// `tcgetpgrp` is also polled on a timer, because a program can take the terminal without
    /// writing a byte — `less` on a file it has already buffered does exactly that. Only while a
    /// watcher is attached: a detached session has nobody to tell.
    static let foregroundPollInterval: TimeInterval = 1

    /// How long a closing connection is given to hand its last frame to the kernel.
    ///
    /// Almost every close follows an `error` frame explaining it, and a peer that has stopped
    /// reading must not be able to hold a descriptor open by never draining it.
    static let closeFlushTimeout: TimeInterval = 2

    /// How long a retiring daemon lets its last writes reach the socket before `exit(0)`.
    ///
    /// Writes are asynchronous, so exiting the instant the last session is released can truncate
    /// the `exited` frame that said so. Short enough to be invisible to the launchd restart that
    /// follows, long enough for a queued frame on a local socket.
    static let retireFlushDelay: TimeInterval = 0.1

    /// How long the exit reaper waits before asking `waitpid` again, and how many times.
    ///
    /// `NOTE_EXIT` fires when the child becomes a zombie, so the first non-blocking `waitpid`
    /// answers in practice. The retries exist so that the one case where it does not cannot be
    /// answered by blocking the queue every other session is being served on.
    static let reapRetryInterval: TimeInterval = 0.005
    static let reapAttempts = 20

    /// How often a child is polled for its exit when no exit event could be armed for it. Slow
    /// enough to cost nothing, quick enough that an ending is still reported within a moment.
    static let exitPollInterval: TimeInterval = 0.25

    // MARK: - The state file

    /// The append-only record of every lifecycle edge, and the whole of what a restarted daemon
    /// knows about the one before it.
    static let stateFileName = "sessions.jsonl"

    /// Bumped when a record's shape changes. Read leniently: an unreadable line is skipped and
    /// counted, never a reason to refuse the file, because the file's whole purpose is to be
    /// readable after a crash wrote half a line.
    static let stateRecordVersion = 1

    // MARK: - The journal

    static let journalFilePrefix = "ptyd-"
    static let journalFileSuffix = ".jsonl"

    /// Days of the daemon's own journal kept. Its own directory, its own pruning: the app's
    /// journal directory prunes *any* `.jsonl` it finds past its retention window, and two
    /// processes appending to one file has damaged a journal here before.
    static let journalRetentionDays = 7

    /// A journal line carries tokens and numbers. This bounds the one field that is a path.
    static let maximumJournalDetailBytes = 512

    // MARK: - Child exit statuses the daemon itself produces

    /// The child could not enter the requested working directory. Reported as an ordinary exit
    /// status because by then the fork has happened and there is no refusal left to send.
    static let childDirectoryFailureStatus: Int32 = 126
    /// `execve` returned, which it only does by failing.
    static let childExecFailureStatus: Int32 = 127

    // MARK: - Exit codes

    /// `EX_USAGE`. The app builds this command line, so a malformed one is a bug in the app and
    /// must be loud rather than degrade into a daemon listening nowhere.
    static let usageExitCode: Int32 = 64
    /// `EX_UNAVAILABLE`. The socket could not be bound or the state directory could not be
    /// prepared — nothing this process can do about it, and staying up would be a listener
    /// nobody can reach.
    static let startupFailureExitCode: Int32 = 69
    static let successExitCode: Int32 = 0

    // MARK: - Wire

    /// `CAN`, the cut marker that precedes a truncated replay. First, because cutting the head
    /// off the ring means the replay can now begin inside an escape sequence too.
    static let cancelByte: UInt8 = 0x18

    /// The line terminator a `.pipes` replay is trimmed to.
    ///
    /// A pipes session carries a newline-delimited stream that the app parses a line at a time,
    /// so a cut tail beginning mid-line would hand a rejoining parser one guaranteed malformed
    /// line. Everything before the first newline goes, which leaves the `CAN` alone on the first
    /// line and every line after it whole. Finding a byte is not parsing a stream: the daemon
    /// still has no idea what any of them mean.
    static let newlineByte: UInt8 = 0x0A

    // MARK: - The pipe channel

    /// The three descriptor numbers a `.pipes` child is given.
    static let childStandardInput: Int32 = 0
    static let childStandardOutput: Int32 = 1
    static let childStandardError: Int32 = 2

    /// `posix_spawnattr_setpgroup`'s "lead your own group" value, so `kill(-pid, …)` reaches the
    /// CLI and everything it started rather than only the CLI.
    static let leadOwnGroup: pid_t = 0

    // MARK: - Linux process identity

    /// `/proc/<pid>/stat` field 22 is the start time, in clock ticks since boot (`proc(5)`).
    static let procStartTimeField = 22
    /// Fields are counted from after the parenthesised command name, which is field 2.
    static let procFirstFieldAfterName = 3
    /// The `/proc/stat` line holding the boot time in seconds since the epoch.
    static let procBootTimeKey = "btime "
    /// One `read(2)` of a `/proc` file.
    static let procReadChunkBytes = 4096
    /// A ceiling on how much of a `/proc` file is read. `btime` comes after the per-CPU lines
    /// and the `intr` line, which has a count for every interrupt number and reaches tens of
    /// kilobytes on a large machine; a mebibyte clears that with room and still bounds the read.
    static let procReadLimitBytes = 1024 * 1024
}
