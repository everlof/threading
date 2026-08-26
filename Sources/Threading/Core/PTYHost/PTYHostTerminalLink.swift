import Darwin
import Dispatch
import Foundation
import ThreadingPTYHostKit

// MARK: - Defaults

/// Numbers the session half of the link owns.
///
/// Kept apart from `PTYHostDefaults`, which is about *reaching* the daemon — the rendezvous, the
/// bundle, the handshake deadlines. These are about one session's link once it has been reached.
enum PTYHostSessionDefaults {

    /// How long the **whole** quit path waits for its `detach` frames to leave.
    ///
    /// A `DispatchIO` write is reported complete later, and on this one path the close that
    /// follows the frame is the process exiting: a `detach` still queued when the app dies is a
    /// seed the next launch never gets, and its rejoin degrades from exact to a cut. A `kill`
    /// needs no equivalent, because the link stays open until the daemon answers `exited`.
    ///
    /// One shared deadline rather than one per session, so forty host-backed sessions cost the
    /// same wait as one — the ordinary case is a fraction of a millisecond, and the case this
    /// bounds is a daemon that has stopped reading, which the write-queue guard has already
    /// closed the connection for.
    static let detachDrainSeconds: TimeInterval = 1

    /// The history a reattach asks for: everything the ring can still prove.
    ///
    /// Nil rather than a number, because a stated budget is a statement about what the watcher
    /// can hold, and a Mac terminal that is about to render the session in full can hold all of
    /// it. `PTYHostAttach.normalizedReplayBudget` reads nil as "no statement".
    static let reattachReplayBudget: Int? = nil
}

// MARK: - Transport

/// The part of `PTYHostClient` a host-backed `TerminalSession` uses.
///
/// A protocol rather than the concrete client so the whole host-backed path — the spawn, the
/// keystroke, the resize, the exit, the foreground push — can be driven by a fake with no daemon,
/// no socket, no pty and no window. `PTYHostPipeLink` speaks the same protocol for a native
/// conversation, using the subset that means anything without a terminal: it never resizes, and
/// it is the only caller of `closeInput`, which is how every native transport says goodbye.
///
/// The fake is not only a testing convenience: everything below the protocol was already covered
/// by `PTYHostClientTests` and `PTYHostDaemonTests`, and what is worth asserting here is what the
/// *session* does with it.
///
/// Every member is already `PTYHostClient`'s, with the same name and signature, so the conformance
/// below is empty.
protocol PTYHostSessionTransport: AnyObject, Sendable {

    /// The queue every event is delivered on. Serial, and never main.
    var queue: DispatchQueue { get }

    func spawn(_ request: PTYHostSpawnRequest) throws
    func attach(_ request: PTYHostAttach) throws
    func resize(_ request: PTYHostResize) throws
    func detach(_ request: PTYHostDetach) throws
    func closeInput(_ request: PTYHostCloseInput) throws
    func kill(_ request: PTYHostKill) throws
    func sendInput(_ bytes: Data) throws

    /// Blocks until nothing queued is still unwritten, or the deadline passes. Answers whether
    /// the queue drained.
    func drainWrites(until deadline: Date) -> Bool

    func close()
}

extension PTYHostClient: PTYHostSessionTransport {}

/// How a host-backed session gets its connection.
///
/// A closure taking the events and answering a transport, because a `PTYHostClient` binds its
/// event handlers at construction and the handlers belong to the link that does not exist yet.
/// Injectable in `MCPBridgeDecision`'s shape: the launch names it, nothing recovers it from a
/// singleton, and a test hands over a fake.
typealias PTYHostTransportFactory =
    @Sendable (PTYHostClient.Events) throws -> any PTYHostSessionTransport

// MARK: - Feed segments

/// One run of bytes from the host and whether the emulator may answer what is in it.
///
/// The pair travels together rather than as two arguments because the coalescer must never merge
/// across the boundary: replayed history and live output can arrive in the same read, and feeding
/// them as one run would either answer history or swallow a live query. See
/// `EmojiFixedTerminalView.feedFromHost(_:answersQueries:)`.
struct PTYHostFeedSegment: Sendable {
    var bytes: [UInt8]
    let answersQueries: Bool
    /// Output in the attach handoff waits for the main-actor `attached` delivery to adopt the
    /// daemon's grid. Ordinary live output is false and parses on the transport queue.
    let requiresMainActorParse: Bool

    init(bytes: [UInt8], answersQueries: Bool, requiresMainActorParse: Bool) {
        self.bytes = bytes
        self.answersQueries = answersQueries
        self.requiresMainActorParse = requiresMainActorParse
    }
}

// MARK: - Link

/// One host-backed terminal's half of the link to `threading-ptyd`.
///
/// It owns the transport, parses steady-state output on that transport's interactive queue,
/// coalesces its UI reporting into **one main-queue hop per burst**, and hands the session the
/// three things a session with no pty descriptor can no longer learn for itself: the bytes, the
/// ending, and which process group owns the terminal.
///
/// **Parsing does not wait for main.** Frames arrive on the client's own serial queue and steady-
/// state bytes enter SwiftTerm there, like the local-process IO path. Only coalesced activity/raw-
/// output callbacks and lifecycle edges cross to the main actor. The first attach run is the one
/// exception: it follows the main-actor delivery that adopts the daemon's authoritative grid.
///
/// **Only an explicit stop kills the child.** `terminate()` sends `kill`; a quit sends `detach`
/// with the seeds only this process can compute; and a link that is simply released lets go —
/// it closes, which the daemon reads as a watcher that vanished, keeps the child for, and
/// answers the next attach with a cut. Sending `detach` from the deinit instead would be worse
/// rather than better: a deinit has no emulator to repaint from, so the seeds would be empty and
/// the next attach would be an *exact* replay of bytes with no screen to put them on.
final class PTYHostTerminalLink: @unchecked Sendable {

    // MARK: - Types

    /// Where the link's edges go. `parseOutput` runs on the transport queue; every other closure
    /// is invoked on the main queue, in wire order.
    struct Delivery: Sendable {

        /// Parses ordinary live output synchronously on the transport queue. This is the hosted
        /// equivalent of SwiftTerm's local-process IO parser and deliberately happens before the
        /// coalesced main-actor reporting below.
        var parseOutput: @Sendable (PTYHostFeedSegment) -> Void = { _ in }

        /// Main-actor output reporting, coalesced. Runs of bytes stay in arrival order and are
        /// never merged across a suppression boundary. A segment whose authoritative attach
        /// grid has not landed yet is also parsed here, after `attached` adopted that grid.
        var output: @Sendable ([PTYHostFeedSegment]) -> Void = { _ in }

        /// The child exists: its pid and the kernel start time that is the other half of its
        /// identity.
        var spawned: @Sendable (PTYHostSpawned) -> Void = { _ in }

        /// The daemon handed this session's child back: its pid, the grid it has been holding,
        /// and what the raw bytes that follow are. Delivered **before** the replay, so the
        /// emulator can adopt the grid the bytes were written at.
        var attached: @Sendable (PTYHostAttached) -> Void = { _ in }

        /// A different process group owns the terminal now.
        var foreground: @Sendable (Int32) -> Void = { _ in }

        /// The child ended, or the link did. `exitCode` follows `LocalProcess`'s own convention:
        /// the status for an ordinary exit, and **nil** for a signalled child or for a link that
        /// failed, which is exactly what `processTerminated(source:exitCode:)` means by nil.
        /// `cause` is a structural token for the journal, or nil for an ordinary exit.
        var ended: @Sendable (_ exitCode: Int32?, _ cause: String?) -> Void = { _, _ in }

        /// The child never started, and no child of this session ever will on this link.
        ///
        /// Deliberately not `ended`: an agent that was refused a pty did not exit, and reporting
        /// it as an exit would put a launch failure on a conversation that has not been launched
        /// yet. The caller's answer is the same one every other unavailability gets — run this
        /// launch in-process.
        var refused: @Sendable (PTYHostSpawnRefusal) -> Void = { _ in }
    }

    // MARK: - Properties

    let identity: PTYHostSessionIdentity

    private let lock = NSLock()
    private var transportStorage: (any PTYHostSessionTransport)?
    private var deliveryStorage = Delivery()
    private var pending: [PTYHostFeedSegment] = []
    private var isFlushScheduled = false
    /// True once an ending has been delivered or the child has been handed over, so the deinit
    /// below knows there is nothing left to let go of and a second ending is never reported.
    private var hasEnded = false

    /// Where this watcher is in the daemon's byte stream, in the daemon's own `totalBytesWritten`
    /// units — the number `detach` hands back and `.exact` is decided from.
    ///
    /// A spawned link starts at zero and every byte it is given is a ring byte, so its count is
    /// the daemon's exactly. An **attached** link starts at the `attached` frame's count and then
    /// counts the replay along with the live output, because the wire carries no marker saying
    /// where the replay ended: the screen and mode seeds are bytes the daemon stores and forwards
    /// but never wrote to the ring, and their lengths are not on the wire. So after a replay this
    /// is an *upper* bound rather than the exact value, and that is the safe direction:
    /// `RemoteRingBuffer.snapshot(from:)` refuses an offset ahead of its own count by design, so
    /// the attach after a reattach is answered with a cut rather than with duplicated bytes.
    /// Closing that gap needs one field on `attached` naming the replay's length; it is written
    /// down in `pty-host.md` rather than guessed at here.
    private var ringOffset: UInt64 = 0

    /// The emulator's window size and the daemon's, reconciled.
    ///
    /// The whole of the grid contract lives in this one value, because the two numbers it holds
    /// are only meaningful next to each other. See `converge()`.
    private struct GridReconciliation {

        /// The last full `winsize` the view asked to deliver, whether or not it has left yet.
        ///
        /// Recorded **before** delivery is attempted, always: a send that could not happen is a
        /// grid this terminal still wants, and dropping it is what left the child on an old one.
        var wanted: PTYHostGrid?

        /// The grid the daemon has confirmed it is holding — the spawn's own grid, an
        /// `attached` frame's, or a `resized` acknowledgement's.
        var acknowledged: PTYHostGrid?

        /// The last grid successfully handed to the transport, and the guard against a storm: a
        /// grid that was written and not acknowledged is not written again, so a daemon that
        /// clamps one, or an older one that answers nothing at all, costs one frame and not a
        /// loop.
        var delivered: PTYHostGrid?

        /// True once a delivery threw. The retry is what the convergence points are for, and
        /// this is also what makes the journal line the rare event rather than a per-resize one.
        var didFail = false

        /// True once the daemon has confirmed the session exists — `spawned` or `attached`.
        /// Before that there is nothing on the other end to resize, and the app does not yet
        /// know the grid it would be reconciling against.
        var isConfirmed = false

        /// One line per link, not one per reconciliation.
        var hasJournalledReconciliation = false
    }

    private var grids = GridReconciliation()

    /// True while the bytes arriving are a `.cut` replay, which the emulator must not answer.
    ///
    /// Cleared by the first flush, which is the only boundary the wire gives: the daemon queues
    /// the whole replay from its serial queue before it binds the connection, so the replay is
    /// the head of what arrives, and the coalescer turns everything read before the first
    /// main-queue hop into one run. Erring towards suppressing one live reply for one main-queue
    /// turn is the right direction — answering history is the failure P1 names, and a stale `DA`
    /// reply reaching a program that already had one is worse than silence.
    ///
    /// `.exact` needs none of this: those bytes have never reached an emulator, so they are
    /// answered exactly as live output is.
    private var isReplayingHistory = false

    /// True from `attached` through the main-actor handoff. The `attached` delivery was enqueued
    /// first and adopts the daemon's grid; parsing the initial run and the finite backlog that
    /// arrived during it on that same queue keeps wire order on the grid the bytes were written
    /// at. Every ordinary spawned/live run stays on the transport queue.
    private var isAwaitingFirstAttachFlush = false

    /// Published only while main parses the finite backlog that arrived during the first attach
    /// delivery. The transport queue waits here before accepting the next frame, preserving wire
    /// order without making an unbounded live stream part of the main-actor drain.
    private var attachParseBarrier: DispatchGroup?

    // MARK: - Initialization

    init(identity: PTYHostSessionIdentity) {
        self.identity = identity
    }

    deinit {
        lock.lock()
        let transport = transportStorage
        transportStorage = nil
        lock.unlock()

        // Letting go, never killing. The child is the daemon's and outlives this process, so a
        // watcher that stopped watching is a close — which the daemon reads as a detach without
        // seeds, keeps the child for, and answers the next attach with a cut. An explicit stop
        // is `terminate()` and sends `kill`; a quit is `detach` and hands the seeds over.
        transport?.close()
    }

    // MARK: - Public Methods

    var delivery: Delivery {
        get {
            lock.lock()
            defer { lock.unlock() }
            return deliveryStorage
        }
        set {
            lock.lock()
            deliveryStorage = newValue
            lock.unlock()
        }
    }

    /// The handlers a transport is built with. Every one of them runs on the transport's queue.
    func events() -> PTYHostClient.Events {
        PTYHostClient.Events(
            frame: { [weak self] frame in self?.received(frame) },
            output: { [weak self] bytes in self?.received(output: bytes) },
            closed: { [weak self] error in self?.linkClosed(error) }
        )
    }

    /// Adopts the transport this link speaks over. Called once, before the spawn.
    ///
    /// The first of the three convergence points: a transport becoming current is the moment a
    /// grid that had nowhere to go acquires somewhere to go. It sends nothing on an ordinary
    /// launch, where nothing has been asked for yet and no session exists to resize.
    func adopt(_ transport: any PTYHostSessionTransport) {
        lock.lock()
        transportStorage = transport
        lock.unlock()
        converge()
    }

    /// Starts the child. Throwing means nothing was sent, so the caller may still run in-process.
    ///
    /// A spawned session's ring starts empty, so this watcher is at offset zero and every byte it
    /// is given afterwards is a byte the daemon wrote — which is what makes its `detach` offset
    /// exact rather than an upper bound.
    func spawn(_ request: PTYHostSpawnRequest) throws {
        guard let transport = currentTransport() else { throw PTYHostClientError.notReady }
        lock.lock()
        ringOffset = 0
        // The spawn's own grid is the grid the child's terminal is forked with — the daemon
        // takes it verbatim and cannot substitute one — so it is this session's first
        // acknowledged grid, and the view's first `sizeChanged` is measured against it rather
        // than against nothing.
        if case .pty(let grid) = request.channel {
            grids.wanted = grid
            grids.acknowledged = grid
        }
        lock.unlock()
        try transport.spawn(request)
    }

    /// Takes a session the daemon is already holding. Throwing means nothing was sent.
    ///
    /// The answer is an `attached` frame carrying the pid, the grid the daemon has been holding
    /// and what the raw bytes that follow are — and **it never resizes**: the watcher inherits
    /// the grid rather than imposing one, which is what keeps an agent that kept working through
    /// a restart from being reflowed by the app that came back to it.
    func attach(_ request: PTYHostAttach) throws {
        guard let transport = currentTransport() else { throw PTYHostClientError.notReady }
        try transport.attach(request)
    }

    /// Hands the child back to the daemon instead of ending it, and lets go of the link.
    ///
    /// The seeds are the app's to compute — the daemon has no emulator, and a repaint is derived
    /// from one — and the offset is where this watcher had got to, which is the whole mechanism
    /// behind the next launch's exact replay. Answers whether the frame was sent.
    ///
    /// **Blocking, and bounded by `deadline`.** This is the quit path: `DispatchIO` reports a
    /// write as complete later, and the close that follows here is the process exiting, so a
    /// detach that has not left yet is a seed the next launch never sees.
    @discardableResult
    func detach(screenSeed: Data, modeSeed: Data, by deadline: Date) -> Bool {
        lock.lock()
        guard !hasEnded, let transport = transportStorage else {
            lock.unlock()
            return false
        }
        hasEnded = true
        let offset = ringOffset
        transportStorage = nil
        lock.unlock()

        do {
            try transport.detach(PTYHostDetach(
                id: identity,
                screenSeed: screenSeed,
                modeSeed: modeSeed,
                ringOffset: offset
            ))
        } catch {
            let cause = (error as? PTYHostClientError)?.token ?? "unknown"
            ThreadingLogger.ptyHost.error(
                "PTY host detach could not be sent: \(cause, privacy: .public)"
            )
            transport.close()
            return false
        }

        _ = transport.drainWrites(until: deadline)
        transport.close()
        return true
    }

    /// Keystrokes, paste and the emulator's own answers.
    func sendInput(_ bytes: Data) {
        guard let transport = currentTransport() else { return }
        do {
            try transport.sendInput(bytes)
        } catch {
            fail(with: error)
        }
    }

    /// The whole `winsize`, recorded as this terminal's wanted grid and delivered when it can be.
    ///
    /// **Answers whether the link will get this grid to the child**, which is what
    /// `LocalProcessTerminalView.sizeChanged` needs in order to decide whether the resize
    /// happened: false only when there is no link left — no transport, or an ending already
    /// reported — because then nothing will ever converge. A grid that is recorded but not yet
    /// on the wire answers true, because the link guarantees it arrives: it is sent at the next
    /// convergence point, and the daemon's `resized` is what says it landed.
    ///
    /// That is the seam's whole difference from the in-process path, where the same call is a
    /// synchronous `ioctl` on a descriptor this process holds and cannot fail after the emulator
    /// has already resized. Here it is a write on a socket, and a write that did not happen must
    /// not become a grid nobody remembers — a child left on an old grid while the emulator moved
    /// on wraps the agent's own lines mid-word.
    @discardableResult
    func sendWindowSize(_ size: winsize) -> Bool {
        lock.lock()
        guard !hasEnded, transportStorage != nil else {
            lock.unlock()
            return false
        }
        grids.wanted = Self.grid(of: size)
        lock.unlock()

        converge()
        return true
    }

    /// Sends one `resize` for the wanted grid when the daemon is not already holding it.
    ///
    /// The three convergence points are `adopt(_:)`, `spawned`/`attached`, and an
    /// acknowledgement that reports a grid other than the wanted one; a burst of output or any
    /// other frame converges too when a previous send failed, because bytes arriving are the
    /// only evidence this side has that the transport is current again.
    ///
    /// Both guards are load-bearing. `wanted != acknowledged` is what makes a reattach at the
    /// daemon's own grid send nothing — adopting a grid is not a window having changed, and
    /// telling the daemon the size it has just told us would raise `SIGWINCH` on an agent that
    /// has been working at that size all along. `wanted != delivered` is what keeps a grid the
    /// daemon answers differently — one it clamped, or one an older daemon never answers at all
    /// — to a single frame instead of a loop.
    private func converge() {
        lock.lock()
        guard !hasEnded,
              let transport = transportStorage,
              grids.isConfirmed,
              let wanted = grids.wanted,
              wanted != grids.acknowledged,
              wanted != grids.delivered
        else {
            lock.unlock()
            return
        }
        // Claimed before the write, not after it: the lock is never held across a call out of
        // this type, and two convergence points can run at once — the view's own resize on main
        // and a frame on the transport's queue. The claim is what makes one grid one frame.
        let previous = grids.delivered
        grids.delivered = wanted
        let shouldJournal = grids.didFail && !grids.hasJournalledReconciliation
        if shouldJournal { grids.hasJournalledReconciliation = true }
        lock.unlock()

        do {
            try transport.resize(PTYHostResize(id: identity, grid: wanted))
        } catch {
            lock.lock()
            grids.delivered = previous
            grids.didFail = true
            if shouldJournal { grids.hasJournalledReconciliation = false }
            lock.unlock()
            let cause = (error as? PTYHostClientError)?.token ?? "unknown"
            // Not an ending. A resize is fire-and-forget by design, and the two errors this can
            // be — a queue past its bound, a transport no longer ready — both close the
            // connection themselves, so the ending arrives through `linkClosed` if there is one
            // to report. Treating a dropped window size as a dead terminal would end a session
            // over a frame the next convergence point can send again.
            ThreadingLogger.ptyHost.error(
                "PTY host resize could not be sent: \(cause, privacy: .public)"
            )
            return
        }

        lock.lock()
        grids.didFail = false
        lock.unlock()

        guard shouldJournal else { return }
        // Once per link, and only after a send that failed: the ordinary resize is not an event,
        // and a line per resize would be a terminal's whole layout history in the journal.
        EventLog.shared.record(
            .session,
            "PTY host window size reconciled after a failed send",
            [
                "session": identity.identity.historyFileStem,
                "cols": String(wanted.cols),
                "rows": String(wanted.rows)
            ]
        )
    }

    private static func grid(of size: winsize) -> PTYHostGrid {
        PTYHostGrid(
            cols: Int(size.ws_col),
            rows: Int(size.ws_row),
            xpixel: Int(size.ws_xpixel),
            ypixel: Int(size.ws_ypixel)
        )
    }

    /// Ends the child. The link stays open afterwards so the daemon's `exited` still arrives —
    /// a watcher is owed the ending, and the ending is what drives the session's own teardown.
    func kill(escalate: Bool = true) {
        guard let transport = currentTransport() else { return }
        do {
            try transport.kill(PTYHostKill(id: identity, escalate: escalate))
        } catch {
            fail(with: error)
        }
    }

    // MARK: - Private Methods — Frames

    private func currentTransport() -> (any PTYHostSessionTransport)? {
        lock.lock()
        defer { lock.unlock() }
        return transportStorage
    }

    private func received(_ frame: PTYHostFrame) {
        // A frame arriving is the same evidence a burst of output is: the transport is current,
        // so a window size a previous send could not deliver can be delivered now. Read first
        // and acted on before the switch, so a `resized` that follows a failed retry is still
        // the acknowledgement of the frame this sends.
        lock.lock()
        let shouldConverge = grids.didFail
        lock.unlock()
        if shouldConverge { converge() }

        switch frame {
        case .spawned(let spawned) where spawned.id == identity:
            lock.lock()
            grids.isConfirmed = true
            let delivery = deliveryStorage
            lock.unlock()
            // The session exists now, so a window size the view produced while the spawn was
            // still in flight has somewhere to go. The view lays out during a launch, which
            // makes this the ordinary case rather than a corner one.
            converge()
            DispatchQueue.main.async { delivery.spawned(spawned) }

        case .attached(let attached) where attached.id == identity:
            lock.lock()
            ringOffset = attached.totalBytesWritten
            isAwaitingFirstAttachFlush = true
            // `.exact` carries bytes no emulator has ever seen and must be answered; `.cut` is
            // history and must not be. See `isReplayingHistory`.
            if case .cut = attached.replay { isReplayingHistory = true }
            // The daemon's own grid, which this watcher adopts rather than replaces. The
            // whole grid is authoritative here, pixels included. The view adopted the summary's
            // cell dimensions before asking, and that programmatic resize can report its local
            // pixel extent back before this frame arrives. Replacing `wanted` closes that echo:
            // an attach itself never resizes; the next genuine window change records a new grid.
            grids.acknowledged = attached.grid
            grids.wanted = attached.grid
            grids.delivered = nil
            grids.isConfirmed = true
            let delivery = deliveryStorage
            lock.unlock()
            DispatchQueue.main.async { delivery.attached(attached) }

        case .resized(let resized) where resized.id == identity:
            lock.lock()
            grids.acknowledged = resized.grid
            lock.unlock()
            // Ordinarily the end of the exchange: the daemon is holding what was asked for.
            // A grid that is not the wanted one is the third convergence point.
            converge()

        case .spawnRefused(let refusal) where refusal.id == identity:
            refused(refusal.reason)

        case .exited(let exited) where exited.id == identity:
            // `LocalProcess`'s own convention, so both paths mean the same thing by nil: a
            // signalled child has no exit code to report.
            end(exitCode: exited.signalled ? nil : exited.status, cause: nil)

        case .foreground(let foreground) where foreground.id == identity:
            let delivery = self.delivery
            DispatchQueue.main.async { delivery.foreground(foreground.processGroup) }

        case .error(let failure):
            // Both halves are structural tokens by the frame's own contract — a `PTYHostError`
            // case and a bounded machine qualifier — so both are public. The qualifier is bound
            // to a local first because the privacy lint reads the interpolated *expression*, and
            // `detail` is a word it is right to be suspicious of everywhere else.
            let qualifier = failure.detail ?? "-"
            ThreadingLogger.ptyHost.error(
                """
                PTY host reported \(failure.code.rawValue, privacy: .public) for a session: \
                \(qualifier, privacy: .public)
                """
            )

        default:
            break
        }
    }

    private func received(output bytes: Data) {
        guard !bytes.isEmpty else { return }
        lock.lock()
        if let barrier = attachParseBarrier {
            lock.unlock()
            barrier.wait()
            received(output: bytes)
            return
        }
        ringOffset &+= UInt64(bytes.count)
        let answers = !isReplayingHistory
        let requiresMainActorParse = isAwaitingFirstAttachFlush
        let delivery = deliveryStorage
        // One comparison per burst, and only after a send that failed. Bytes arriving are this
        // side's only evidence that a transport which refused a write is current again — there
        // is no frame for "ready", and a timer would be a guess.
        let shouldConverge = grids.didFail
        lock.unlock()
        if shouldConverge { converge() }
        let segment = PTYHostFeedSegment(
            bytes: [UInt8](bytes),
            answersQueries: answers,
            requiresMainActorParse: requiresMainActorParse
        )
        if !requiresMainActorParse { delivery.parseOutput(segment) }
        deliver(segment)
    }

    /// Appends to the pending burst and schedules at most one main-queue hop for it.
    ///
    /// Adjacent runs that agree about answering queries are merged, so frames that were already
    /// parsed on the transport queue share one main-actor activity/raw-output report. A run that
    /// disagrees starts a new segment rather than being folded into one that would answer for it.
    private func deliver(_ segment: PTYHostFeedSegment) {
        lock.lock()
        if var last = pending.last,
           last.answersQueries == segment.answersQueries,
           last.requiresMainActorParse == segment.requiresMainActorParse {
            last.bytes.append(contentsOf: segment.bytes)
            pending[pending.count - 1] = last
        } else {
            pending.append(segment)
        }
        let shouldSchedule = !isFlushScheduled
        isFlushScheduled = true
        lock.unlock()

        guard shouldSchedule else { return }
        DispatchQueue.main.async { [weak self] in self?.flush() }
    }

    private func flush() {
        lock.lock()
        let segments = pending
        pending.removeAll(keepingCapacity: true)
        guard !segments.isEmpty else {
            isFlushScheduled = false
            lock.unlock()
            return
        }

        let isDrainingAttachHandoff = isAwaitingFirstAttachFlush
        // The replay is the head of what a rejoining watcher is given, and this first drain is
        // the only boundary the wire offers. Bytes arriving while it parses are live for query-
        // suppression purposes, but still stay on main until the finite handoff below completes.
        // See `isReplayingHistory`.
        isReplayingHistory = false
        if !isDrainingAttachHandoff { isFlushScheduled = false }
        let delivery = deliveryStorage
        lock.unlock()

        delivery.output(segments)
        guard isDrainingAttachHandoff else { return }

        // A frame can arrive while the first delivery holds SwiftTerm's parser lock. Take that
        // finite backlog, then publish a barrier before releasing the attach gate: the client's
        // serial transport queue waits at `received(output:)` while main parses the backlog, so
        // a later live frame cannot overtake it. This is one bounded second drain, not a loop that
        // could keep main busy forever when a child emits continuously.
        lock.lock()
        let backlog = pending
        pending.removeAll(keepingCapacity: true)
        isAwaitingFirstAttachFlush = false
        isFlushScheduled = false
        let barrier: DispatchGroup?
        if backlog.isEmpty {
            barrier = nil
        } else {
            let group = DispatchGroup()
            group.enter()
            attachParseBarrier = group
            barrier = group
        }
        let backlogDelivery = deliveryStorage
        lock.unlock()

        if !backlog.isEmpty { backlogDelivery.output(backlog) }

        lock.lock()
        attachParseBarrier = nil
        lock.unlock()
        barrier?.leave()
    }

    // MARK: - Private Methods — Endings

    private func linkClosed(_ error: PTYHostClientError?) {
        // The child is the daemon's and outlives this connection, so a link that dropped is not
        // an exit. It is still the end of *this* terminal: nothing can be rendered or typed any
        // more, and the reattach that would recover it is the next slice.
        end(exitCode: nil, cause: error?.token ?? "closed")
    }

    private func fail(with error: Error) {
        let cause = (error as? PTYHostClientError)?.token ?? "unknown"
        ThreadingLogger.ptyHost.error(
            "PTY host link failed: \(cause, privacy: .public)"
        )
        end(exitCode: nil, cause: cause)
    }

    /// Takes the one ending this link is allowed to report, or nil if it is already spoken for.
    private func claimEnding() -> Delivery? {
        lock.lock()
        defer { lock.unlock() }
        guard !hasEnded else { return nil }
        hasEnded = true
        return deliveryStorage
    }

    /// Reports the ending exactly once, after whatever output preceded it.
    private func end(exitCode: Int32?, cause: String?) {
        guard let delivery = claimEnding() else { return }
        // Ordered behind the pending feed rather than raced against it: `DispatchQueue.main` is
        // serial, and the flush was submitted first, so a watcher is shown the ending after the
        // bytes that led to it.
        DispatchQueue.main.async { [weak self] in
            self?.flush()
            delivery.ended(exitCode, cause)
        }
    }

    /// Reports a spawn the daemon would not perform. Counts as this link's ending — there is no
    /// child, so the deinit below has nothing to kill.
    private func refused(_ reason: PTYHostSpawnRefusal) {
        guard let delivery = claimEnding() else { return }
        DispatchQueue.main.async { [weak self] in
            self?.flush()
            delivery.refused(reason)
        }
    }
}
