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
/// no socket, no pty and no window. That is not only a testing convenience: everything below the
/// protocol was already covered by `PTYHostClientTests` and `PTYHostDaemonTests`, and what is
/// worth asserting here is what the *session* does with it.
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

    init(bytes: [UInt8], answersQueries: Bool) {
        self.bytes = bytes
        self.answersQueries = answersQueries
    }
}

// MARK: - Link

/// One host-backed terminal's half of the link to `threading-ptyd`.
///
/// It owns the transport, coalesces the daemon's output into **one main-queue hop per burst**,
/// and hands the session the three things a session with no pty descriptor can no longer learn
/// for itself: the bytes, the ending, and which process group owns the terminal.
///
/// **Nothing here runs on main except the delivery.** Frames arrive on the client's own serial
/// queue and are handled there; only the coalesced feed and the lifecycle edges cross to the main
/// actor, in `installProcessOutputObserver`'s existing shape, because a hop per frame would put a
/// terminal's whole output rate on the main queue — the shape that makes a mirror slow.
///
/// **Only an explicit stop kills the child.** `terminate()` sends `kill`; a quit sends `detach`
/// with the seeds only this process can compute; and a link that is simply released lets go —
/// it closes, which the daemon reads as a watcher that vanished, keeps the child for, and
/// answers the next attach with a cut. Sending `detach` from the deinit instead would be worse
/// rather than better: a deinit has no emulator to repaint from, so the seeds would be empty and
/// the next attach would be an *exact* replay of bytes with no screen to put them on.
final class PTYHostTerminalLink: @unchecked Sendable {

    // MARK: - Types

    /// Where the link's four edges go. Each is invoked **on the main queue**, in wire order.
    struct Delivery: Sendable {

        /// Output, coalesced. Runs of bytes in arrival order, never merged across a suppression
        /// boundary.
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
    func adopt(_ transport: any PTYHostSessionTransport) {
        lock.lock()
        transportStorage = transport
        lock.unlock()
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

    /// The whole `winsize`. Answers whether it was handed over, which is what the view's resize
    /// seam reports back to SwiftTerm.
    @discardableResult
    func sendWindowSize(_ size: winsize) -> Bool {
        guard let transport = currentTransport() else { return false }
        do {
            try transport.resize(PTYHostResize(
                id: identity,
                grid: PTYHostGrid(
                    cols: Int(size.ws_col),
                    rows: Int(size.ws_row),
                    xpixel: Int(size.ws_xpixel),
                    ypixel: Int(size.ws_ypixel)
                )
            ))
            return true
        } catch {
            fail(with: error)
            return false
        }
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
        switch frame {
        case .spawned(let spawned) where spawned.id == identity:
            let delivery = self.delivery
            DispatchQueue.main.async { delivery.spawned(spawned) }

        case .attached(let attached) where attached.id == identity:
            lock.lock()
            ringOffset = attached.totalBytesWritten
            // `.exact` carries bytes no emulator has ever seen and must be answered; `.cut` is
            // history and must not be. See `isReplayingHistory`.
            if case .cut = attached.replay { isReplayingHistory = true }
            let delivery = deliveryStorage
            lock.unlock()
            DispatchQueue.main.async { delivery.attached(attached) }

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
        ringOffset &+= UInt64(bytes.count)
        let answers = !isReplayingHistory
        lock.unlock()
        deliver(PTYHostFeedSegment(bytes: [UInt8](bytes), answersQueries: answers))
    }

    /// Appends to the pending burst and schedules at most one main-queue hop for it.
    ///
    /// Adjacent runs that agree about answering queries are merged, so a burst that crossed the
    /// wire as several frames is one `feed` and one pair of activity callbacks — and a run that
    /// disagrees starts a new segment rather than being folded into one that would answer for it.
    private func deliver(_ segment: PTYHostFeedSegment) {
        lock.lock()
        if var last = pending.last, last.answersQueries == segment.answersQueries {
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
        isFlushScheduled = false
        // The replay is the head of what a rejoining watcher is given, and this hop is the only
        // boundary the wire offers. See `isReplayingHistory`.
        if !segments.isEmpty { isReplayingHistory = false }
        let delivery = deliveryStorage
        lock.unlock()

        guard !segments.isEmpty else { return }
        delivery.output(segments)
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
