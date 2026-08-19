import Foundation

/// One way a phone reaches this Mac, as the Remote Access page presents it.
///
/// A door is a bind decision (`RemoteAccessDoor`); a way in is what the person reading the page
/// is choosing between. The two are deliberately not the same enum: "Through a VPN" is not a
/// switch at all — it is the `lan` door reached from a tunnel — and "Threading Direct" is a
/// service rather than an interface. Keeping the page's vocabulary here means the copy can be
/// asserted without building a view.
enum RemoteAccessWayIn: String, CaseIterable, Sendable {
    /// The `lan` door: the addresses this Mac holds on the networks it is attached to.
    case thisNetwork
    /// The same door, reached over a VPN into this network. A note, never a switch.
    case throughAVPN
    /// The `tailscale` door.
    case tailscale
    /// The hosted rendezvous. Shown only once this Mac is signed in.
    case threadingDirect

    var title: String {
        switch self {
        case .thisNetwork: return L10n.string("This network")
        case .throughAVPN: return L10n.string("Through a VPN")
        case .tailscale: return L10n.string("Tailscale")
        case .threadingDirect: return L10n.string("Threading Direct")
        }
    }

    /// The one sentence that says what this way in is for.
    var promise: String {
        switch self {
        case .thisNetwork:
            return L10n.string(
                "Your phone reaches this Mac when both are on the same Wi-Fi."
            )
        case .throughAVPN:
            return L10n.string(
                "The same connection works over a VPN into this network, including UniFi "
                    + "Teleport and WireGuard. Connect the VPN on your phone first."
            )
        case .tailscale:
            return L10n.string(
                "Reach this Mac from anywhere on your tailnet. Needs Tailscale installed and "
                    + "signed in on both devices."
            )
        case .threadingDirect:
            return L10n.string(
                "Reach this Mac from anywhere, with no VPN. Threading connects the two devices "
                    + "directly when it can, and falls back to a relay when your network will "
                    + "not allow a direct connection."
            )
        }
    }

    /// The four questions, answered. Never optional: a way in whose four lines are embarrassing
    /// is one to fix or remove, not to describe vaguely.
    var disclosure: RemoteDoorDisclosure {
        switch self {
        case .thisNetwork:
            return RemoteDoorDisclosure(
                whoCanReachIt: L10n.string("anyone on this network who has your pairing code"),
                whoCanSeeTheTraffic: L10n.string("nobody outside this network"),
                afterARestart: L10n.string("the address stays the same"),
                awayFromHome: L10n.string("no")
            )
        case .throughAVPN:
            return RemoteDoorDisclosure(
                whoCanReachIt: L10n.string("anyone on the VPN who has your pairing code"),
                whoCanSeeTheTraffic: L10n.string("whoever operates the VPN, which is you"),
                afterARestart: L10n.string("the address stays the same"),
                awayFromHome: L10n.string("yes, while the VPN is connected")
            )
        case .tailscale:
            return RemoteDoorDisclosure(
                whoCanReachIt: L10n.string("devices your tailnet ACLs allow"),
                whoCanSeeTheTraffic: L10n.string(
                    "nobody reads it. Tailscale may relay it encrypted when a direct connection "
                        + "is not possible"
                ),
                afterARestart: L10n.string("the address stays the same"),
                awayFromHome: L10n.string("yes")
            )
        case .threadingDirect:
            return RemoteDoorDisclosure(
                whoCanReachIt: L10n.string("your signed-in devices"),
                whoCanSeeTheTraffic: L10n.string(
                    "nobody. A fallback relay carries encrypted data it cannot read"
                ),
                afterARestart: L10n.string("the address stays the same"),
                awayFromHome: L10n.string("yes")
            )
        }
    }

    /// The one thing this way in has to say that is not an answer to the four questions.
    var note: String? {
        switch self {
        case .thisNetwork, .threadingDirect:
            return nil
        case .throughAVPN:
            return L10n.string(
                "Your phone can run only one VPN at a time, so this and Tailscale cannot both be "
                    + "connected."
            )
        case .tailscale:
            return L10n.string(
                "Turning this on does not put Threading on any other network. Each way in above "
                    + "is separate."
            )
        }
    }

    /// Whether this way in has a switch of its own. "Through a VPN" follows "This network" and
    /// Threading Direct follows sign-in.
    var hasSwitch: Bool { self == .thisNetwork || self == .tailscale }

    /// The stable component every accessibility identifier on this way in's rows is built from.
    /// Not copy: never localized, never shown.
    var identifierComponent: String {
        switch self {
        case .thisNetwork: return "this-network"
        case .throughAVPN: return "through-a-vpn"
        case .tailscale: return "tailscale"
        case .threadingDirect: return "threading-direct"
        }
    }
}

/// The whole "ways in" half of the Remote Access page, as one value.
///
/// The page renders it and nothing else, which is what lets every state in it be photographed:
/// a bound LAN address, a Mac with no interface, a firewall that may be swallowing connections,
/// a tailnet a minute into its first certificate, and no way in at all.
struct RemoteAccessDoorsPresentation: Equatable, Sendable {
    /// The master switch. Held here as well so the page renders from one value rather than
    /// reading a setting for one control and a presentation for the rest.
    let isRemoteAccessOn: Bool
    let thisNetworkIsOn: Bool
    let tailscaleIsOn: Bool
    /// Threading Direct is future work and appears only once this Mac is signed in, so a person
    /// who has not signed in is not offered a way in that cannot carry anything yet.
    let showsThreadingDirect: Bool
    let statuses: [RemoteAccessWayIn: RemoteDoorStatus]
    let identity: RemoteIdentityCardPresentation

    /// Everything off and nothing signed in, which is what the page shows before it has asked
    /// the coordinator anything.
    static let idle = RemoteAccessDoorsPresentation(
        isRemoteAccessOn: false,
        thisNetworkIsOn: false,
        tailscaleIsOn: false,
        showsThreadingDirect: false,
        statuses: [:],
        identity: RemoteIdentityCardPresentation(
            pairingCode: nil,
            nextPairingCode: nil,
            failure: nil
        )
    )

    func status(of wayIn: RemoteAccessWayIn) -> RemoteDoorStatus? { statuses[wayIn] }

    /// The lines the page's own status row is resolved from: the ways in that are on offer, in
    /// the order they are listed.
    var offeredStatuses: [RemoteDoorStatus] {
        RemoteAccessWayIn.allCases
            .filter { $0 != .throughAVPN }
            .filter { $0 != .threadingDirect || showsThreadingDirect }
            .compactMap { statuses[$0] }
    }
}

/// The four questions every way in answers, in the same order and the same words.
struct RemoteDoorDisclosure: Equatable, Sendable {
    let whoCanReachIt: String
    let whoCanSeeTheTraffic: String
    let afterARestart: String
    let awayFromHome: String

    /// One printed line: the question, then the answer to it.
    struct Line: Equatable, Sendable {
        let question: String
        let answer: String
    }

    var lines: [Line] {
        [
            Line(question: L10n.string("Who can reach it"), answer: whoCanReachIt),
            Line(question: L10n.string("Who can see the traffic"), answer: whoCanSeeTheTraffic),
            Line(question: L10n.string("After a restart"), answer: afterARestart),
            Line(question: L10n.string("Away from home"), answer: awayFromHome)
        ]
    }
}

/// What one way in is doing right now, as one status line.
///
/// A fact, never a mood: an address and a port, or the specific reason there is none. `hint`
/// carries the remedy when the fact alone does not say what to do about it, so a reason and its
/// fix are never in two different places on the page.
struct RemoteDoorStatus: Equatable, Sendable {

    enum Tone: Equatable, Sendable {
        /// Not selected, or Remote Access is off. Nothing is bound and nothing is wrong.
        case off
        /// Coming up. The only tone that spins.
        case working
        /// Bound, at an address this status line names.
        case ready
        /// Selected and not carrying traffic.
        case attention
    }

    let text: String
    let hint: String?
    let tone: Tone
    let isBusy: Bool
    /// The address a listener is actually answering on, when there is one.
    ///
    /// Deliberately separate from the tone. A bound address with the firewall in doubt is not a
    /// green state — the Mac cannot observe whether an incoming connection is allowed, because a
    /// probe from this Mac to its own LAN address is local traffic the Application Firewall does
    /// not filter — but it is still an address, and a page that forgot that would tell somebody
    /// nothing is bound while a listener sits on it.
    let boundAddress: String?

    init(
        text: String,
        hint: String? = nil,
        tone: Tone,
        isBusy: Bool = false,
        boundAddress: String? = nil
    ) {
        self.text = text
        self.hint = hint
        self.tone = tone
        self.isBusy = isBusy
        self.boundAddress = boundAddress
    }

    /// Whether this line is claiming a peer can get through. Only ever true beside an address.
    var isReady: Bool { tone == .ready }

    /// The line as one sentence, with its remedy after it. Both halves are already whole
    /// sentences; this only stops them running together.
    var sentence: String {
        guard let hint else { return Self.terminated(text) }
        return Self.terminated(text) + " " + hint
    }

    private static func terminated(_ text: String) -> String {
        guard let last = text.last, !".!?…:".contains(last) else { return text }
        return text + "."
    }

    static func remoteAccessOff() -> RemoteDoorStatus {
        RemoteDoorStatus(text: L10n.string("Remote Access is off."), tone: .off)
    }

    // MARK: - This network

    /// The `lan` door's line.
    ///
    /// `bindings` arrive in the order the pairing code would pick, so the address named first is
    /// the one on the QR code.
    static func thisNetwork(
        isEnabled: Bool,
        state: RemoteAccessDoorState,
        firewall: RemoteFirewallHint,
        preferredPort: UInt16,
        fallbackRange: ClosedRange<UInt16> = RemoteAccessDefaults.listenerPortFallbackRange
    ) -> RemoteDoorStatus {
        guard isEnabled else {
            return RemoteDoorStatus(
                text: L10n.string("Off. Nothing on this network can reach this Mac."),
                tone: .off
            )
        }
        switch state {
        case .off:
            return RemoteDoorStatus(
                text: L10n.string("Off. Nothing on this network can reach this Mac."),
                tone: .off
            )
        case .binding:
            return RemoteDoorStatus(
                text: L10n.string("Binding to this Mac’s addresses on this network…"),
                tone: .working,
                isBusy: true
            )
        case .bound(let bindings):
            return bound(bindings, firewall: firewall)
        case .notReachable(let reason):
            return unreachable(
                reason,
                preferredPort: preferredPort,
                fallbackRange: fallbackRange
            )
        }
    }

    private static func bound(
        _ bindings: [RemoteListenerBinding],
        firewall: RemoteFirewallHint
    ) -> RemoteDoorStatus {
        guard let first = bindings.first else {
            return RemoteDoorStatus(
                text: L10n.string("Not currently reachable: no address on this network."),
                tone: .attention
            )
        }
        let primary = address(first)
        let text = L10n.format("Reachable at %@", primary)
        let others = bindings.dropFirst().map(address)
        let hint = others.isEmpty
            ? nil
            : L10n.format(
                "Also reachable at %@.",
                ListFormatter.localizedString(byJoining: Array(others))
            )
        // A hint the person can act on outranks one they only have to know: the firewall is the
        // first thing to suspect when a phone cannot connect to an address that is bound.
        if firewall.mayBlockIncomingConnections {
            return RemoteDoorStatus(
                text: text,
                hint: firewallHint,
                tone: .attention,
                boundAddress: primary
            )
        }
        return RemoteDoorStatus(text: text, hint: hint, tone: .ready, boundAddress: primary)
    }

    private static func unreachable(
        _ reason: RemoteDoorUnreachableReason,
        preferredPort: UInt16,
        fallbackRange: ClosedRange<UInt16>
    ) -> RemoteDoorStatus {
        switch reason {
        case .noInterface:
            return RemoteDoorStatus(
                text: L10n.string("Not currently reachable: no address on this network."),
                hint: L10n.string(
                    "Connect this Mac to Wi-Fi or Ethernet. The door comes back on its own."
                ),
                tone: .attention
            )
        case .portInUse:
            return RemoteDoorStatus(
                text: L10n.format(
                    "Not currently reachable: ports %1$@ to %2$@ are all in use.",
                    String(fallbackRange.lowerBound),
                    String(fallbackRange.upperBound)
                ),
                hint: L10n.string(
                    "Quit whatever is holding them, then turn Remote Access off and on again."
                ),
                tone: .attention
            )
        case .identityUnavailable:
            return RemoteDoorStatus(
                text: L10n.string(
                    "Not currently reachable: this Mac has no certificate to present."
                ),
                hint: L10n.string(
                    "Reset this Mac’s identity below. Every paired device has to scan again."
                ),
                tone: .attention
            )
        case .notAvailableYet:
            return RemoteDoorStatus(
                text: L10n.string("Not available in this version of Threading."),
                tone: .attention
            )
        }
    }

    /// The macOS Application Firewall is a hint and stays one. Nothing here may say a phone will
    /// get through; it says what to check when one does not.
    static let firewallHint = L10n.string(
        "The macOS firewall may be blocking Threading; allow it in System Settings ▸ Network ▸ "
            + "Firewall."
    )

    private static func address(_ binding: RemoteListenerBinding) -> String {
        // The port is an address, not a quantity: formatted through the locale it grows a
        // grouping separator, so it is joined as a string.
        "\(binding.address.urlHost):\(binding.port)"
    }

    // MARK: - Tailscale

    /// The `tailscale` door's line, from the transport it is made of today.
    ///
    /// The readiness model already owns the sentences for a tailnet that is not ready, and it
    /// owns them in two halves, so the failure and its remedy land on the same line rather than
    /// in a readiness row elsewhere on the page.
    static func tailscale(
        isEnabled: Bool,
        transport: RemoteTransportState,
        readiness: TailscaleReadiness
    ) -> RemoteDoorStatus {
        guard isEnabled else {
            return RemoteDoorStatus(
                text: L10n.string("Off. Threading is not published on your tailnet."),
                tone: .off
            )
        }
        switch transport {
        case .connected(let origin):
            return RemoteDoorStatus(
                text: L10n.format("Reachable at %@", origin.remoteDisplayHost),
                tone: .ready,
                boundAddress: origin.remoteDisplayHost
            )
        case .stopped, .starting:
            guard let statement = readiness.startupStatement else {
                return RemoteDoorStatus(
                    text: L10n.string("Starting on your tailnet…"),
                    tone: .working,
                    isBusy: true
                )
            }
            return RemoteDoorStatus(text: statement.detail, tone: .working, isBusy: true)
        case .unavailable(let reason):
            guard case .actionRequired(let issue, _) = readiness else {
                return RemoteDoorStatus(text: reason, tone: .attention)
            }
            return RemoteDoorStatus(
                text: issue.failureStatement,
                hint: issue.remedyStatement,
                tone: .attention
            )
        }
    }

    // MARK: - Threading Direct

    /// The hosted door's line. Shown only while this Mac is signed in, so the signed-out states
    /// are the ones the Hosted Direct row above already speaks for.
    static func threadingDirect(_ state: RemoteHostedServiceState) -> RemoteDoorStatus {
        switch state {
        case .ready:
            return RemoteDoorStatus(
                text: L10n.string("Ready. Your signed-in devices can reach this Mac."),
                tone: .ready
            )
        case .connecting:
            return RemoteDoorStatus(
                text: L10n.string("Connecting to Threading’s service…"),
                tone: .working,
                isBusy: true
            )
        case .unavailable:
            return RemoteDoorStatus(
                text: L10n.string("Threading’s service is temporarily unavailable."),
                hint: L10n.string("Nothing to do. It reconnects on its own."),
                tone: .attention
            )
        case .stopped, .signInRequired, .notConfigured:
            return RemoteDoorStatus(
                text: L10n.string("Not carrying traffic."),
                tone: .off
            )
        }
    }
}

extension URL {
    /// How an origin is written in a status line: the host, and the port when it is not the
    /// scheme's own. `https://mac.tail1234.ts.net:8443/` reads as `mac.tail1234.ts.net:8443`.
    var remoteDisplayHost: String {
        guard let host else { return absoluteString }
        guard let port, port != RemoteAccessDefaults.defaultTLSPort else { return host }
        return "\(host):\(port)"
    }
}
