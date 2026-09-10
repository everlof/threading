import Darwin
import Dispatch
import Foundation
import ThreadingPTYHostKit

// MARK: - Session

/// One hosted child: the `forkpty` process, its master descriptor, its raw output ring, its last
/// window size, its detach seed and — once it has one — its exit status.
///
/// That list is the whole of what the daemon owns per session, and the absences are as
/// deliberate as the members. There is no title, no working directory, no activity and no
/// project here: the daemon parses nothing, so it does not know them, and the app — which still
/// owns the emulator — already does.
///
/// Confined to the host queue.
final class PTYSession: @unchecked Sendable {

    // MARK: - Types

    /// What the last watcher handed over when it left. Three opaque values: the daemon cannot
    /// synthesise a screen because a repaint is derived from a live emulator and it has none, but
    /// the app is present at exactly the moment the last watcher leaves.
    struct DetachSeed {
        let screen: Data
        let modes: Data
        /// The ring's `totalBytesWritten` as of the last byte that watcher had applied.
        let ringOffset: UInt64
    }

    struct Exit {
        let status: Int32
        let signalled: Bool
        let at: Date
    }

    // MARK: - Properties

    let id: PTYHostSessionIdentity
    let pid: pid_t
    let executable: String
    let startedAt: Date
    let startTime: PTYHostProcessStartTime?

    /// How this child is wired up, and the one fact the rest of the daemon branches on.
    ///
    /// It is stored rather than derived because three behaviours turn on it and each is an
    /// absence rather than a variation: a `.pipes` session has no window size to set, no
    /// `tcgetpgrp` to answer, and no screen a watcher could have handed over — so `resize` is
    /// refused with a token, no `foreground` frame is ever pushed, and a rejoin is always a cut.
    let channel: PTYHostChannelKind

    /// The pseudo-terminal master for a `.pty` session, and `-1` for a `.pipes` session, which
    /// has three descriptors instead. Owned by `io` and closed with it.
    let master: Int32

    /// **Durable session state.** A `resize` sets it; an `attach` never does. A new watcher
    /// inherits the grid rather than imposing one, which is what makes "reattaching a Threading
    /// that has just restarted must not reflow an agent that kept working the whole time" true by
    /// construction. A session with no watcher keeps its last grid indefinitely: there is no Mac
    /// frame to restore it to.
    var grid: PTYHostGrid

    /// The raw byte stream, most recent first out. In this daemon the ring *is* the stream —
    /// every byte is appended before it is fanned out — which is what makes an exact rejoin
    /// possible at all.
    private(set) var ring: RemoteRingBuffer

    var seed: DetachSeed?
    private(set) var exit: Exit?

    /// Bound connections. Output fans out to all of them; a detached session has none, and then
    /// an arriving byte costs one ring append and nothing else.
    var watchers: [PTYHostConnection] = []

    /// When the last watcher left, or the spawn time if none ever attached. The aggregate ring
    /// cap shrinks the *oldest detached* session first, and this is the order.
    var detachedAt: Date?

    /// Set once `exited` has reached a bound connection. Until it has, the session is held: a
    /// watcher that reconnects a moment later is owed the ending, not "unknown session".
    var exitObserved = false

    /// True once every reader has reached end of file, so the last output has been fanned out.
    /// Set through `noteReaderFinished()`, never directly: a pipes session has two readers and
    /// "the output is over" is only true when both have ended.
    private(set) var masterFinished = false

    /// True once the `exited` frame has been written to every bound connection. The exit is
    /// reported once; a later attach is told separately, as part of its own `attached`.
    var exitDelivered = false

    /// The channel input is written on: the master for `.pty`, the child's standard input for
    /// `.pipes`. One name, because "where do this session's keystrokes go" is one question.
    var io: DispatchIO?

    /// A `.pipes` session's two read channels. A `.pty` session has none: its master is `io`,
    /// which reads and writes the same descriptor.
    var outputIO: DispatchIO?
    var errorIO: DispatchIO?

    /// How many of this session's readers have yet to reach end of file. One for a `.pty`
    /// master, two for a pipes child's stdout and stderr. The `exited` frame waits for it to
    /// reach zero, because a watcher told "it ended" before it is shown the ending has lost
    /// exactly the bytes it most wanted.
    var openReaders = 0

    var processSource: DispatchSourceProcess?
    var foregroundTimer: DispatchSourceTimer?
    /// Armed only after an explicit idle handoff. Attaching cancels it; a connection that merely
    /// disappears never invents an expiry for work whose state the daemon cannot know.
    var idleExpiryTimer: DispatchSourceTimer?
    var idleExpiresAt: Date?
    var lastForeground: pid_t?
    var pendingInputBytes = 0
    /// Set by `kill`, so an exit that follows is not reported as a surprise in the journal.
    var wasKilled = false

    // MARK: - Initialization

    init(
        id: PTYHostSessionIdentity,
        child: PTYSpawn.Child,
        executable: String,
        grid: PTYHostGrid,
        ringCapacity: Int = PTYHostDefaults.ringBytes,
        startedAt: Date = Date()
    ) {
        self.id = id
        channel = .pty
        pid = child.pid
        master = child.master
        startTime = child.startTime
        self.executable = executable
        self.grid = grid
        self.startedAt = startedAt
        ring = RemoteRingBuffer(capacity: ringCapacity)
        detachedAt = startedAt
        openReaders = 1
    }

    /// A child on three pipes.
    ///
    /// The grid is zeroes rather than a plausible 80×24: a pipes child has no terminal, and a
    /// summary reporting a window size it does not have is a fact somebody will act on.
    init(
        id: PTYHostSessionIdentity,
        child: PTYSpawn.PipeChild,
        executable: String,
        ringCapacity: Int = PTYHostDefaults.ringBytes,
        startedAt: Date = Date()
    ) {
        self.id = id
        channel = .pipes
        pid = child.pid
        master = -1
        startTime = child.startTime
        self.executable = executable
        grid = PTYHostGrid(cols: 0, rows: 0)
        self.startedAt = startedAt
        ring = RemoteRingBuffer(capacity: ringCapacity)
        detachedAt = startedAt
        openReaders = 2
    }

    // MARK: - Public Methods

    var isAttached: Bool { !watchers.isEmpty }

    var summary: PTYHostSessionSummary {
        PTYHostSessionSummary(
            id: id,
            pid: pid,
            startedAt: startedAt,
            executable: executable,
            grid: grid,
            isAttached: isAttached,
            exit: exit?.status,
            channel: channel
        )
    }

    /// Appends output to the ring. Always, and always *before* fan-out: the ring is the stream,
    /// and a byte that reached a watcher without reaching the ring is a byte a rejoin cannot
    /// account for.
    func append(_ data: Data) {
        ring.append(data)
    }

    /// One reader reached end of file. The output is over when the last of them has.
    func noteReaderFinished() {
        openReaders = max(0, openReaders - 1)
        if openReaders == 0 { masterFinished = true }
    }

    func noteExit(status: Int32, signalled: Bool, at moment: Date = Date()) {
        guard exit == nil else { return }
        exit = Exit(status: status, signalled: signalled, at: moment)
    }

    /// Shrinks the ring, keeping the newest bytes and the monotonic write count.
    ///
    /// Only ever called on a detached session, and only by the aggregate cap. Preserving
    /// `totalBytesWritten` is what keeps a later `.exact` decision honest: the count is the
    /// watcher's whole notion of where it was, and a ring that reset it would answer "you are
    /// zero bytes behind" to a watcher that had missed everything.
    func shrinkRing(to capacity: Int) {
        ring = ring.resized(to: capacity)
    }

    var ringCapacity: Int { ring.capacity }

    /// What a joining watcher is owed, in the order it is owed it.
    ///
    /// - **exact**: the stored screen seed, then exactly the bytes written since the offset it
    ///   was taken at, then the stored mode seed. No cut marker, no loss, no repaint gamble.
    /// - **cut**: `CAN` then the ring tail, bounded by the watcher's stated budget. `CAN` first,
    ///   because cutting the head off the ring means the replay can now begin inside an escape
    ///   sequence too. A stored mode seed still goes last if there is one.
    /// - **none**: there is no history.
    ///
    /// **Modes are always the last word**, in both branches: the ring is replayed history, and
    /// history holds modes that stopped being true.
    func replay(budget: Int?) -> (kind: PTYHostReplay, payloads: [Data]) {
        if channel == .pipes { return pipeReplay(budget: budget) }

        if let seed, let slice = ring.snapshot(from: seed.ringOffset) {
            let payloads = [seed.screen, slice, seed.modes].filter { !$0.isEmpty }
            return (.exact(fromOffset: seed.ringOffset), payloads)
        }

        let tail = ring.snapshot()
        guard !tail.isEmpty else {
            // No history at all. A stored mode seed without a screen to put it on is not a
            // replay; the app re-derives from live output.
            return (.none, [])
        }

        var cut = Data([PTYHostDefaults.cancelByte])
        if let budget, budget < tail.count {
            cut.append(tail.suffix(budget))
        } else {
            cut.append(tail)
        }
        var payloads = [cut]
        if let modes = seed?.modes, !modes.isEmpty { payloads.append(modes) }
        return (.cut, payloads)
    }

    // MARK: - Private Methods

    /// What a watcher rejoining a `.pipes` session is owed: `CAN`, then whole lines.
    ///
    /// **Always a cut, never an exact rejoin**, and that is a property of the channel rather than
    /// of what happened to be stored. An exact replay is only meaningful with a screen seed to
    /// put the bytes on, and a pipes session has no emulator anywhere to compute one — its
    /// `detach` carries empty seeds by construction. Answering `.exact` off an empty screen would
    /// be an exact replay of bytes with nothing to render them into, which is worse than saying
    /// honestly that history was cut.
    ///
    /// **And the tail starts at a line boundary.** The stream is newline-delimited JSON that the
    /// app parses a line at a time, so a tail beginning mid-line hands a fresh parser one
    /// guaranteed malformed line — and, worse, one that looks like a provider protocol error
    /// rather than like a cut. Everything before the first newline goes; the `CAN` is then alone
    /// on the first line and every line after it is whole. The budget is applied first, because
    /// bounding the answer and then finding a boundary inside it is the order that keeps both
    /// promises.
    private func pipeReplay(budget: Int?) -> (kind: PTYHostReplay, payloads: [Data]) {
        let tail = ring.snapshot()
        guard !tail.isEmpty else { return (.none, []) }

        let bounded: Data
        if let budget, budget < tail.count {
            bounded = Data(tail.suffix(budget))
        } else {
            bounded = tail
        }

        var cut = Data([PTYHostDefaults.cancelByte])
        if let newline = bounded.firstIndex(of: PTYHostDefaults.newlineByte) {
            // From the newline itself, so the marker keeps a line of its own and the first byte
            // after it starts a line.
            cut.append(contentsOf: bounded[newline...])
        }
        return (.cut, [cut])
    }
}
