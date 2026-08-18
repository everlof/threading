import Foundation

/// A fix the unavailable panel can offer beside Retry: a title and the page it opens.
///
/// It is a value rather than a URL alone because the panel has to be able to say *nothing* —
/// most failures have no admin page to visit, and a button labelled from a missing title is how
/// a dead-ended panel gets one anyway.
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
enum RemotePairingCardState: Equatable {
    /// The paired-device Keychain item could not be read, so no credential may be issued.
    case keychainUnavailable
    /// A scannable payload exists; the card shows the code.
    case ready(payload: String)
    /// Remote Access is on and no way in is switched on, so nothing routable is being started.
    /// A dead end rather than a wait: the card says which switch produces a code.
    case noWayIn
    /// The selected connection reported a reason it cannot carry traffic, and the fix for it
    /// when the readiness model knows one.
    case connectionUnavailable(reason: String, remedy: RemotePairingRemedy?)
    /// The connection is still coming up. The only state that legitimately shows a spinner, and
    /// it says what it is waiting for whenever the transport can name that.
    case preparing(detail: String?)
    /// The connection is up but no pairing payload could be built from it.
    case codeUnavailable

    /// `hasWayIn` defaults to true so the callers that are only asking about a transport — the
    /// readiness tests, and every state that predates the door switches — keep reading the same.
    static func resolve(
        ownerDevicePersistenceError: String?,
        pairingCodePayload: String?,
        transport: RemoteTransportState,
        tailscaleReadiness: TailscaleReadiness? = nil,
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
        switch transport {
        case .unavailable(let reason):
            guard case .actionRequired(let issue, let actionURL) = tailscaleReadiness else {
                // Relay states its own sentence, remedy included, and has no page to open.
                return .connectionUnavailable(reason: reason, remedy: nil)
            }
            return .connectionUnavailable(
                reason: issue.explanation,
                remedy: remedy(for: issue, actionURL: actionURL)
            )
        case .stopped, .starting:
            return .preparing(detail: tailscaleReadiness?.startupStatement?.detail)
        case .connected:
            return .codeUnavailable
        }
    }

    private static func remedy(
        for issue: TailscaleReadinessIssue,
        actionURL: URL?
    ) -> RemotePairingRemedy? {
        guard let actionURL, let title = issue.remedyActionTitle else { return nil }
        return RemotePairingRemedy(title: title, url: actionURL)
    }
}
