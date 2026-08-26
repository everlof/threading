import Foundation

/// The PTY-host protocol version, and the rule for deciding whether the app and the daemon can
/// talk at all.
///
/// This is `RemoteProtocol`'s rule, deliberately copied rather than shared: the two protocols
/// version independently — a remote-access frame change must not retire a working daemon, and a
/// daemon frame change must not tell every installed iPhone to update.
///
/// **The protocol pair is the gate; the generation string is not.** `hello` retains the wire key
/// `build` for compatibility, but its value is reported, journalled, and used only to replace an
/// old compatible daemon gracefully. A different generation remains admissible while it holds
/// work; a same-generation process with an incompatible protocol is still refused. macOS keeps a
/// running executable's text pages valid after the file underneath is replaced, so a daemon can
/// keep serving the code it started with until a safe retirement point.
///
/// **Bump policy, verbatim from `RemoteProtocol`**: additive changes bump nothing, a breaking
/// change bumps `current` while still speaking the old version, and `minimumSupported` rises
/// only in its own later release, once the older peer is genuinely no longer supported. A frame
/// added to `PTYHostFrame` is additive — the discriminator makes it so — and therefore bumps
/// nothing. `PTYHostProtocolTests` pins both numbers so a bump fails a test once, deliberately.
public enum PTYHostProtocol {
    /// The wire version this build speaks.
    public static let current = 1
    /// The oldest peer version this build still understands.
    public static let minimumSupported = 1
}

/// The outcome of comparing a peer's version pair against this build. It names *which* side is
/// behind, because that decides what happens next: an app that is behind falls back to
/// in-process PTYs and says so, and a daemon that is behind is sent `retire`.
public enum PTYHostCompatibility: String, Codable, Equatable, Sendable {
    case compatible
    /// The peer is older than we support.
    case peerTooOld
    /// We are older than the peer supports.
    case selfTooOld

    /// Evaluated from the perspective of *this* build against a peer's declared pair.
    public static func evaluate(peerVersion: Int, peerMinimum: Int) -> PTYHostCompatibility {
        if peerVersion < PTYHostProtocol.minimumSupported { return .peerTooOld }
        if PTYHostProtocol.current < peerMinimum { return .selfTooOld }
        return .compatible
    }

    public static func evaluate(peer: PTYHostHello) -> PTYHostCompatibility {
        evaluate(peerVersion: peer.protocolVersion, peerMinimum: peer.minimumSupported)
    }
}

/// Which side a `PTYHostCompatibility` mismatch says has to move, so neither end re-derives the
/// direction from the raw numbers and gets it backwards.
///
/// `RemoteUpdateTarget`'s `client`/`host` pair does not fit: both processes here ship inside the
/// same bundle, and the answer is which of the two is the stale one.
public enum PTYHostUpdateTarget: String, Codable, Equatable, Sendable {
    /// The connecting Threading build is behind. It stops using the host and runs in-process.
    case app
    /// The running daemon is behind. It is sent `retire`, unlinks its socket and drains.
    case daemon
}

/// Which of the two processes a statement is about. Only ever used to keep "who is behind"
/// from being derived backwards — see `PTYHostCompatibility.updateTarget(evaluatedBy:)`.
public enum PTYHostSide: String, Codable, Equatable, Sendable {
    case app
    case daemon

    var peer: PTYHostSide { self == .app ? .daemon : .app }
}

extension PTYHostCompatibility {
    /// Where the fix lives, or nil when nothing is wrong.
    ///
    /// The evaluator has to be named. `peerTooOld` means "the other one is behind", and the
    /// other one is the app when the daemon evaluates and the daemon when the app evaluates —
    /// so a fixed mapping would be right on one side and exactly backwards on the other. Only
    /// the daemon sends `helloRefused`, but the app runs the same evaluation to decide whether
    /// to fall back to in-process PTYs, and both go through this one function.
    public func updateTarget(evaluatedBy side: PTYHostSide) -> PTYHostUpdateTarget? {
        switch self {
        case .compatible:
            return nil
        case .peerTooOld:
            return side.peer == .app ? .app : .daemon
        case .selfTooOld:
            return side == .app ? .app : .daemon
        }
    }
}
