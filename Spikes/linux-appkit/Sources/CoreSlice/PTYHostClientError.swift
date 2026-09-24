import Foundation
import ThreadingPTYHostKit

// MARK: - Errors

/// Why a link to the background PTY host could not be made, or could not be kept.
///
/// Structural tokens rather than sentences, and typed rather than a `Bool` or an `NSError`,
/// because every one names a different cause: some mean the daemon is unavailable, two expose a
/// caller bug, and the rest mean the peer is not a daemon this app can talk to. The launch layer
/// preserves that distinction when it surfaces a selected host's refusal.
enum PTYHostClientError: Error, Equatable, Sendable {

    /// The rendezvous path does not fit `sockaddr_un.sun_path`.
    case pathTooLong(bytes: Int)
    case socketUnavailable(errno: Int32)
    case connectFailed(errno: Int32)
    case connectTimedOut
    /// The daemon did not say `hello` inside `PTYHostDefaults.helloTimeout`.
    case handshakeTimedOut
    /// Aggregate pre-hello delivery buffer exceeded its bounded wire-byte budget.
    case handshakeBufferOverflow(bufferedBytes: Int)
    /// The peer closed before the handshake finished.
    case closedEarly
    case readFailed(errno: Int32)
    case writeFailed(errno: Int32)

    /// The version gate refused, from **this app's** perspective — `selfTooOld` means the app is
    /// behind, whichever side did the evaluating. See `PTYHostClient.connect()`.
    case incompatible(PTYHostCompatibility)

    /// The stream stopped being a conversation. Terminal: there is no resynchronisation point in
    /// a length-prefixed stream.
    case framing(PTYHostFramingRefusal)

    /// A frame this build would have sent is larger than the wire allows.
    case oversizeFrame

    /// The daemon stopped reading and the unwritten bytes reached
    /// `PTYHostDefaults.maximumQueuedWriteBytes`. The connection is closed rather than grown.
    case writeQueueOverflow(queuedBytes: Int)

    /// A send before `connect()` returned, or after the link closed.
    case notReady

    /// A second `spawn` or `attach` on a connection that is already bound to a session.
    case alreadyBound(PTYHostSessionIdentity)

    /// Raw input on a connection that has not been bound to a session. Input carries no id, so
    /// there is nothing else to say who it is for.
    case notBound

    /// A frame naming a session this connection is not bound to.
    case sessionMismatch(bound: PTYHostSessionIdentity, frame: PTYHostSessionIdentity)

    /// The journal token. A cause, never a path.
    var token: String {
        switch self {
        case .pathTooLong: return "pathTooLong"
        case .socketUnavailable: return "socketUnavailable"
        case .connectFailed: return "connectFailed"
        case .connectTimedOut: return "connectTimedOut"
        case .handshakeTimedOut: return "handshakeTimedOut"
        case .handshakeBufferOverflow: return "handshakeBufferOverflow"
        case .closedEarly: return "closedEarly"
        case .readFailed: return "readFailed"
        case .writeFailed: return "writeFailed"
        case .incompatible(let compatibility): return "incompatible.\(compatibility.rawValue)"
        case .framing(let refusal):
            switch refusal {
            case .oversizePayload: return "framing.oversizePayload"
            case .unknownKind: return "framing.unknownKind"
            }
        case .oversizeFrame: return "oversizeFrame"
        case .writeQueueOverflow: return "writeQueueOverflow"
        case .notReady: return "notReady"
        case .alreadyBound: return "alreadyBound"
        case .notBound: return "notBound"
        case .sessionMismatch: return "sessionMismatch"
        }
    }
}
