import Foundation

/// What the "This network" card says about the announcement, and about waking.
///
/// A value for the same reason `RemoteAccessDoorsPresentation` is one: neither half can be
/// produced on the machine running a test. A hosted test must not register a Bonjour service at
/// all (`InertRemoteServiceAdvertiser`), and nothing a test can do makes a sleep proxy appear or
/// disappear on the developer's own network. The page renders this and nothing else, so the
/// states are photographable and the copy is assertable without a network under it.
struct RemoteDiscoveryPresentation: Equatable, Sendable {

    /// Whether the announcement is switched on.
    let isEnabled: Bool

    /// The opaque instance name currently registered, or nil when nothing is.
    ///
    /// The name rather than a Bool, and it is safe to print for the same reason it is safe to
    /// broadcast: it is derived from this Mac's id and contains neither the computer name nor
    /// the user's. Somebody deciding whether they want a broadcast at all is entitled to see
    /// exactly what is on the network.
    let announcedName: String?

    /// The two facts behind waking. Read through `wake`, never for a claim of its own.
    let wakeFacts: RemoteWakeOnDemandFacts

    /// Nothing announced and nothing read yet, which is the page before it has asked.
    static let idle = RemoteDiscoveryPresentation(
        isEnabled: false,
        announcedName: nil,
        wakeFacts: .unknown
    )

    /// The fact line under the switch, or nil when nothing is registered.
    var announcement: String? {
        announcedName.map { L10n.format("Announced as %@", $0) }
    }

    /// What the page may say about waking a sleeping Mac.
    ///
    /// One case per thing a reader can act on, rather than a string plus a Bool: "can wake" is a
    /// promise the network has to keep, and each of the other four names the exact thing that is
    /// missing. `RemoteWakeOnDemandFacts.canWakeThisMac` is the only source of the positive
    /// case, so unknown can never become yes by accident here either.
    enum Wake: Equatable, Sendable {
        /// Both facts hold: "Wake for network access" is on and a proxy answered.
        case canWake
        /// Nothing is registered, so there is no advertised service for a proxy to answer for.
        case notAnnounced
        /// The setting is off, so macOS never hands the registration to a proxy.
        case wakeForNetworkAccessOff
        /// The setting is on and no proxy answered, so nothing can answer for a sleeping Mac.
        case noSleepProxy
        /// The probe has not produced an answer for one of them yet.
        case notChecked

        var text: String {
            switch self {
            case .canWake:
                return L10n.string("Can wake this Mac from sleep")
            case .notAnnounced:
                return L10n.string("Waking needs an announcement on this network")
            case .wakeForNetworkAccessOff:
                return L10n.string(
                    "Wake for network access is off in System Settings ▸ Energy"
                )
            case .noSleepProxy:
                return L10n.string(
                    "No sleep proxy on this network; an Apple TV or HomePod provides one"
                )
            case .notChecked:
                return L10n.string("Not checked yet")
            }
        }

        /// Only the positive case is a positive tone. The four reasons are facts about the
        /// network rather than failures, so none of them is a warning either.
        var tone: RemoteDoorStatus.Tone {
            self == .canWake ? .ready : .off
        }
    }

    /// The wake line, resolved from the facts in the order a reader can act on.
    ///
    /// The setting comes before the proxy because it is the half a person can change: a Mac with
    /// the setting off and no proxy on the network is told about the switch it owns, not about
    /// the hardware it would also have to buy. Anything still unknown is "not checked yet",
    /// never a reason stated as though it had been looked at.
    var wake: Wake {
        // The registration is what a Sleep Proxy answers for, so with nothing on the network
        // there is nothing to wake this Mac however the two facts read. This is deliberately
        // ahead of `canWakeThisMac`: both facts can hold on a Mac announcing nothing, and the
        // page would then promise waking through a service that does not exist.
        guard announcedName != nil else { return .notAnnounced }
        if wakeFacts.canWakeThisMac { return .canWake }
        if wakeFacts.wakeForNetworkAccess == false { return .wakeForNetworkAccessOff }
        if wakeFacts.sleepProxyPresent == false { return .noSleepProxy }
        return .notChecked
    }
}
