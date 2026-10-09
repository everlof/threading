import Dispatch
import Foundation
import ThreadingPTYClient
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

    /// One retry for a compatible daemon from before atomic same-identity replacement existed.
    /// The bound covers its two-second escalation and five-second observed-exit retention, plus
    /// scheduling margin. Current daemons queue the replacement directly and never pay it.
    static let legacyReplacementRetryDelay: TimeInterval = 7.5
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
