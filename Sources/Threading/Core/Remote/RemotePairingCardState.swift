import Foundation

/// What the "Set Up Your iPhone" card is saying, decided from facts rather than read off the
/// transport state alone.
///
/// The card used to fold `.stopped`, `.starting` **and** `.connected` into one "Preparing your
/// pairing code / Connecting…" branch. That presented a dead end as progress: a connected
/// transport with no pairing payload is not a step on the way to a code, it is a code that could
/// not be built, and the card sat on a disabled button waiting for something that was never going
/// to arrive. Keeping the decision here means the settings page renders it and tests assert it,
/// instead of the distinction living only inside a `switch` in a view controller.
enum RemotePairingCardState: Equatable {
    /// The paired-device Keychain item could not be read, so no credential may be issued.
    case keychainUnavailable
    /// A scannable payload exists; the card shows the code.
    case ready(payload: String)
    /// The selected connection reported a reason it cannot carry traffic.
    case connectionUnavailable
    /// The connection is still coming up. The only state that legitimately shows a spinner.
    case preparing
    /// The connection is up but no pairing payload could be built from it.
    case codeUnavailable

    static func resolve(
        ownerDevicePersistenceError: String?,
        pairingCodePayload: String?,
        transport: RemoteTransportState
    ) -> RemotePairingCardState {
        if ownerDevicePersistenceError != nil {
            return .keychainUnavailable
        }
        if let pairingCodePayload {
            return .ready(payload: pairingCodePayload)
        }
        switch transport {
        case .unavailable:
            return .connectionUnavailable
        case .stopped, .starting:
            return .preparing
        case .connected:
            return .codeUnavailable
        }
    }
}
