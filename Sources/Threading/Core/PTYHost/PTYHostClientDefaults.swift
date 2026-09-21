import Dispatch
import Foundation
import ThreadingPTYHostKit

/// Portable client bounds; daemon registration and filesystem locations belong to the host.
enum PTYHostClientDefaults {
    /// How long a `connect()` to the rendezvous may take before the daemon counts as absent.
    ///
    /// Bounded because this runs on a session launch: a socket file left behind by a daemon that
    /// is gone, or one whose backlog is full, must refuse promptly rather than hold a launch
    /// open. A unix connect to a listening peer is immediate; anything else is already the
    /// unavailable case.
    static let connectTimeout: TimeInterval = 2

    /// How long the daemon has to answer `hello` before the link is abandoned.
    ///
    /// Longer than the connect deadline on purpose: a daemon that has just been started by
    /// `KeepAlive` may still be reading its `sessions.jsonl` and probing pids, which is bounded
    /// work but not instant work.
    static let helloTimeout: TimeInterval = 5

    /// The most unwritten bytes the client will hold for a daemon that has stopped reading.
    ///
    /// A queue that grows is the failure this bound exists to refuse. Input is small, but a
    /// `detach` carries a screen seed and a wedged daemon takes none of it, so "buffer whatever
    /// the caller hands over" is an unbounded allocation driven by an unresponsive peer. Four
    /// frames' worth of the 1 MiB wire maximum: large enough that no ordinary burst trips it,
    /// small enough that tripping it is a bug rather than a slow afternoon. Exceeding it closes
    /// the connection with `PTYHostClientError.writeQueueOverflow`; a selected background
    /// session reports that failure without changing process ownership.
    static let maximumQueuedWriteBytes = 4 * PTYHostFramingDefaults.maximumPayloadBytes

    /// One blocking read during the handshake, before the `DispatchIO` pump owns the descriptor.
    static let handshakeReadChunkBytes = 64 * 1024

    /// The client's serial queue. Every frame is decoded and delivered on it and never on main.
    static let clientQueueLabel = "codes.threading.ptyhost.client"

    /// A connected terminal is part of the visible interaction loop even though its bytes do
    /// not belong on main. In particular, a typed key is not visible until the child echoes it
    /// through this queue, so leaving the queue's QoS unspecified turns an explicit UI edge into
    /// work whose urgency depends on whichever thread happened to wake `DispatchIO`.
    static let clientQueueQoS = DispatchQoS.userInteractive
}
