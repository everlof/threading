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

    /// How long a `kill` is given to reach the daemon before the connection is closed anyway.
    ///
    /// A close is asynchronous and `DispatchIO.close(flags: .stop)` abandons what has not been
    /// written, so closing in the same turn as the `kill` can discard the very frame that ends
    /// the child. The ordinary path never needs this — the daemon answers `exited` and the link
    /// closes on that — so this is the deadline for the case where it does not.
    static let killDrainSeconds: TimeInterval = 3
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
    func resize(_ request: PTYHostResize) throws
    func kill(_ request: PTYHostKill) throws
    func sendInput(_ bytes: Data) throws
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
/// **A link that is released kills its child.** Detach and reattach are the next slice; until they
/// land, a session that goes away must not leave an agent running in a process nothing references.
/// When `detach` replaces this, the deinit below becomes the failure path rather than the ordinary
/// one.
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
    /// True once an ending has been delivered, so the deinit below knows there is no child left
    /// to kill and a second ending is never reported.
    private var hasEnded = false

    // MARK: - Initialization

    init(identity: PTYHostSessionIdentity) {
        self.identity = identity
    }

    deinit {
        lock.lock()
        let transport = transportStorage
        let ended = hasEnded
        transportStorage = nil
        lock.unlock()

        guard let transport else { return }
        guard !ended else {
            transport.close()
            return
        }
        // Nothing references this session's terminal any more, and until the detach slice lands
        // there is no way to hand it over. Ending it is the honest answer: an agent still working
        // in a session no surface can reach is worse than one that stopped.
        try? transport.kill(PTYHostKill(id: identity, escalate: true))
        transport.queue.asyncAfter(deadline: .now() + PTYHostSessionDefaults.killDrainSeconds) {
            transport.close()
        }
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
    func spawn(_ request: PTYHostSpawnRequest) throws {
        guard let transport = currentTransport() else { throw PTYHostClientError.notReady }
        try transport.spawn(request)
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
        deliver(PTYHostFeedSegment(bytes: [UInt8](bytes), answersQueries: true))
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
