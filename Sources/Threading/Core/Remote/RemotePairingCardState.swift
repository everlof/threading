import Foundation

/// A fix a failing row can offer beside its sentence: a title and the page it opens.
///
/// It is a value rather than a URL alone because a row has to be able to say *nothing* — most
/// failures have no admin page to visit, and a button labelled from a missing title is how a
/// dead-ended row gets one anyway. Today the one thing that offers a page is Tailscale Serve,
/// whose failures are all fixed in the tailnet's admin console.
struct RemotePairingRemedy: Equatable {
    let title: String
    let url: URL
}

/// What the "Set Up Your iPhone" card is saying, decided from facts rather than read off the
/// transport state alone.
///
/// The card used to fold `.stopped`, `.starting` **and** `.connected` into one "Preparing your
/// pairing code / Connecting…" branch. That presented a dead end as progress: a connected
/// transport with no pairing payload is not a step on the way to a code, it is a code that could
/// not be built, and the card sat on a disabled button waiting for something that was never going
/// to arrive. Keeping the decision here means the settings page renders it and tests assert it,
/// instead of the distinction living only inside a `switch` in a view controller.
///
/// Two of the cases carry their own sentence for the same reason. "Private connection
/// unavailable. You can still test the browser on this Mac, or retry the selected connection."
/// shipped while the only explanation the app had — "Enable Tailscale Serve for this tailnet" —
/// sat in a readiness row three rows further up, and "Preparing your pairing code" shipped while
/// `tailscale serve` was a minute into its first certificate. A panel states the reason it is
/// showing; it never points at another part of the page.
///
/// **The card reads a way in, not a transport.** Every route an owner device can take is now a
/// listener on one of this Mac's own addresses, so what the card is waiting for, or failing on,
/// is a door — and a door's status line already carries the fact and its remedy as words. That
/// is also why nothing here opens an admin console any more: the one thing that offers a page is
/// Tailscale Serve, and a browser convenience is not what a pairing code is waiting for.
enum RemotePairingCardState: Equatable {
    /// The paired-device Keychain item could not be read, so no credential may be issued.
    case keychainUnavailable
    /// A scannable payload exists; the card shows the code.
    case ready(payload: String)
    /// Remote Access is on and no way in is switched on, so nothing routable is being started.
    /// A dead end rather than a wait: the card says which switch produces a code.
    case noWayIn
    /// The way in closest to carrying a code reported a reason it cannot, with its remedy in the
    /// same sentence.
    case connectionUnavailable(reason: String)
    /// The connection is still coming up. The only state that legitimately shows a spinner, and
    /// it says what it is waiting for whenever the transport can name that.
    case preparing(detail: String?)
    /// The connection is up but no pairing payload could be built from it.
    case codeUnavailable

    /// Resolves the card from the way in that is closest to carrying a code.
    ///
    /// `wayIn` is the most advanced of the switched-on ways in: one that is answering, else one
    /// that is coming up, else one that has failed. Nil is a page that has been told about no way
    /// in at all, which is a wait rather than an answer.
    static func resolve(
        ownerDevicePersistenceError: String?,
        pairingCodePayload: String?,
        wayIn: RemoteDoorStatus?,
        hasWayIn: Bool = true
    ) -> RemotePairingCardState {
        if ownerDevicePersistenceError != nil {
            return .keychainUnavailable
        }
        if let pairingCodePayload {
            return .ready(payload: pairingCodePayload)
        }
        // Checked after the payload: a code that exists is proof something is reachable, and it
        // is the answer the person came for either way.
        if !hasWayIn {
            return .noWayIn
        }
        guard let wayIn else { return .preparing(detail: nil) }
        switch wayIn.tone {
        case .ready:
            // Something is answering at an address and no code could be built from it. That is a
            // dead end, not a step on the way to one.
            return .codeUnavailable
        case .working:
            return .preparing(detail: wayIn.text)
        case .attention:
            return .connectionUnavailable(reason: wayIn.sentence)
        case .off:
            return .preparing(detail: nil)
        }
    }

    /// The way in a card speaks for: the one closest to carrying a code.
    ///
    /// Deliberately not "the first one listed". A network door that is still binding says more
    /// than a tailnet door that is off, and a door that is answering outranks both — the card is
    /// about whether a code can exist, not about the order the page happens to draw switches in.
    static func mostAdvanced(of statuses: [RemoteDoorStatus]) -> RemoteDoorStatus? {
        func rank(_ status: RemoteDoorStatus) -> Int {
            switch status.tone {
            case .ready: return 0
            case .working: return 1
            case .attention: return 2
            case .off: return 3
            }
        }
        return statuses.min { rank($0) < rank($1) }
    }
}
