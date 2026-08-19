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
    /// The browser convenience under the tailnet way in. Not a way in of its own: no phone uses
    /// it, and it never speaks for this Mac in the status row.
    let tailscaleServeIsOn: Bool
    /// Threading Direct is future work and appears only once this Mac is signed in, so a person
    /// who has not signed in is not offered a way in that cannot carry anything yet.
    let showsThreadingDirect: Bool
    let statuses: [RemoteAccessWayIn: RemoteDoorStatus]
    /// What Serve is doing, and the admin-console page that fixes it when it cannot publish.
    let serveStatus: RemoteDoorStatus?
    let serveRemedy: RemotePairingRemedy?
    /// The tailnet way in's readiness rows.
    let tailnetReadiness: RemoteTailnetReadinessPresentation
    let identity: RemoteIdentityCardPresentation

    init(
        isRemoteAccessOn: Bool,
        thisNetworkIsOn: Bool,
        tailscaleIsOn: Bool,
        tailscaleServeIsOn: Bool = false,
        showsThreadingDirect: Bool,
        statuses: [RemoteAccessWayIn: RemoteDoorStatus],
        serveStatus: RemoteDoorStatus? = nil,
        serveRemedy: RemotePairingRemedy? = nil,
        tailnetReadiness: RemoteTailnetReadinessPresentation = .idle,
        identity: RemoteIdentityCardPresentation
    ) {
        self.isRemoteAccessOn = isRemoteAccessOn
        self.thisNetworkIsOn = thisNetworkIsOn
        self.tailscaleIsOn = tailscaleIsOn
        self.tailscaleServeIsOn = tailscaleServeIsOn
        self.showsThreadingDirect = showsThreadingDirect
        self.statuses = statuses
        self.serveStatus = serveStatus
        self.serveRemedy = serveRemedy
        self.tailnetReadiness = tailnetReadiness
        self.identity = identity
    }

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

    /// `alsoReachableAt` carries the addresses that are not bindings: a name that resolves to one
    /// of them, which is a route a phone can take and a listener the Mac never bound separately.
    private static func bound(
        _ bindings: [RemoteListenerBinding],
        firewall: RemoteFirewallHint,
        alsoReachableAt names: [String] = []
    ) -> RemoteDoorStatus {
        guard let first = bindings.first else {
            return RemoteDoorStatus(
                text: L10n.string("Not currently reachable: no address on this network."),
                tone: .attention
            )
        }
        let primary = address(first)
        let text = L10n.format("Reachable at %@", primary)
        let others = bindings.dropFirst().map(address) + names
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
        case .tailscaleNotConnected:
            return tailscaleNotConnected(.unknown)
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

    /// The `tailscale` door's line, from the listener that carries it.
    ///
    /// It reads like the LAN door's line because it is the same kind of fact: a listener on one
    /// of this Mac's own addresses, or the specific reason there is none. What differs is what
    /// "no address" means. A `utun` with no `100.64.0.0/10` address is `tailscaled` not running,
    /// not signed in, or not installed at all, and only the CLI can say which — so the facts
    /// refine the sentence rather than deciding the state, and a bound door never consults them.
    ///
    /// No firewall hint: the Application Firewall filters incoming connections on the interfaces
    /// a person joins, and a tailnet arrives inside a tunnel `tailscaled` itself opened.
    static func tailscale(
        isEnabled: Bool,
        state: RemoteAccessDoorState,
        facts: TailscaleHostFacts,
        magicDNSName: String? = nil,
        fallbackRange: ClosedRange<UInt16> = RemoteAccessDefaults.listenerPortFallbackRange
    ) -> RemoteDoorStatus {
        guard isEnabled else { return tailscaleOff() }
        switch state {
        case .off:
            return tailscaleOff()
        case .binding:
            return RemoteDoorStatus(
                text: L10n.string("Binding to this Mac’s tailnet address…"),
                tone: .working,
                isBusy: true
            )
        case .bound(let bindings):
            let names = magicDNSName.flatMap { name in
                bindings.first.map { "\(name):\($0.port)" }
            }
            return bound(bindings, firewall: .unknown, alsoReachableAt: names.map { [$0] } ?? [])
        case .notReachable(.tailscaleNotConnected), .notReachable(.noInterface):
            return tailscaleNotConnected(facts)
        case .notReachable(let reason):
            return unreachable(
                reason,
                preferredPort: RemoteAccessDefaults.defaultListenerPort,
                fallbackRange: fallbackRange
            )
        }
    }

    private static func tailscaleOff() -> RemoteDoorStatus {
        RemoteDoorStatus(
            text: L10n.string("Off. Threading is not published on your tailnet."),
            tone: .off
        )
    }

    /// The tailnet has no address on this Mac, said as precisely as the CLI allows.
    ///
    /// The remedy never says "then retry": nothing here is retried by a button. The listener set
    /// rebuilds when the interface list changes, so the door comes back on its own the moment
    /// `tailscaled` has an address again, and the copy says so rather than sending somebody to
    /// press something.
    private static func tailscaleNotConnected(_ facts: TailscaleHostFacts) -> RemoteDoorStatus {
        switch facts.state {
        case .notInstalled:
            return RemoteDoorStatus(
                text: L10n.string("Not currently reachable: Tailscale is not installed on this Mac."),
                hint: L10n.string(
                    "Install Tailscale and sign in on this Mac. The door comes back on its own."
                ),
                tone: .attention
            )
        case .signedOut:
            return RemoteDoorStatus(
                text: L10n.string(
                    "Not currently reachable: this Mac is not signed in to Tailscale."
                ),
                hint: L10n.string(
                    "Sign in to Tailscale on this Mac. The door comes back on its own."
                ),
                tone: .attention
            )
        case .stopped, .running, .unknown:
            return RemoteDoorStatus(
                text: L10n.string("Not currently reachable: Tailscale is not connected."),
                hint: L10n.string(
                    "Turn on Tailscale on this Mac. The door comes back on its own."
                ),
                tone: .attention
            )
        }
    }

    // MARK: - Open in a browser on your tailnet

    /// The Serve sub-option's own line.
    ///
    /// Deliberately not a way in: nothing a phone does depends on it, and it is never in the
    /// status row's list. It is a browser convenience with a certificate cost, so its line states
    /// what it is publishing and, when it cannot, which admin-console setting is missing.
    static func tailscaleServe(
        isEnabled: Bool,
        transport: RemoteTransportState,
        readiness: TailscaleReadiness
    ) -> RemoteDoorStatus {
        guard isEnabled else {
            return RemoteDoorStatus(
                text: L10n.string(
                    "Off. A browser on your tailnet gets a certificate warning."
                ),
                tone: .off
            )
        }
        switch transport {
        case .connected(let origin):
            return RemoteDoorStatus(
                text: L10n.format("Serving at %@", origin.remoteDisplayOrigin),
                tone: .ready,
                boundAddress: origin.remoteDisplayOrigin
            )
        case .stopped, .starting:
            guard let statement = readiness.startupStatement else {
                return RemoteDoorStatus(
                    text: L10n.string("Publishing on your tailnet…"),
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

    /// The admin-console page that fixes a Serve failure, when the CLI named one.
    static func serveRemedy(_ readiness: TailscaleReadiness) -> RemotePairingRemedy? {
        guard case .actionRequired(let issue, let actionURL) = readiness,
              let actionURL,
              let title = issue.remedyActionTitle else { return nil }
        return RemotePairingRemedy(title: title, url: actionURL)
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

    /// The same, with the scheme, for the one line a person is meant to open in a browser.
    /// `https://mac.tail1234.ts.net:8443/` reads as `https://mac.tail1234.ts.net:8443`.
    var remoteDisplayOrigin: String {
        guard let scheme else { return remoteDisplayHost }
        return "\(scheme)://\(remoteDisplayHost)"
    }
}

/// The three rows of the tailnet way in's readiness card.
///
/// It is a value rather than a `switch` inside the view controller because every state in it
/// takes a live tailnet to reach: a Mac with no `tailscale` binary, one that is signed out, one
/// whose `tailscaled` is not running, and one whose door is bound. The page renders this and
/// nothing else, so all four can be asserted and photographed.
///
/// The rows are the *door's*, and the door is a listener: two facts the `tailscale` CLI owns,
/// then what the listener bound. Serve's failures are not here at all — they belong to the
/// browser sub-option that asked for Serve.
struct RemoteTailnetReadinessPresentation: Equatable, Sendable {

    struct Row: Equatable, Sendable {
        enum Mark: Equatable, Sendable {
            /// Not answered yet, and not being waited on either.
            case pending
            /// In flight. The only mark that spins.
            case working
            case met
            case attention
        }

        let step: TailscaleReadinessStep
        let title: String
        let detail: String
        let mark: Mark
    }

    let rows: [Row]

    /// Nothing asked and nothing waiting, which is what the card holds before the page has read
    /// the coordinator.
    static let idle = RemoteTailnetReadinessPresentation(
        rows: TailscaleReadinessStep.allCases.map {
            Row(step: $0, title: "", detail: "", mark: .pending)
        }
    )

    func row(_ step: TailscaleReadinessStep) -> Row? { rows.first { $0.step == step } }

    /// Resolves the card from the CLI facts and the door.
    ///
    /// A bound door is proof of both CLI facts, whatever the probe managed to say: an address in
    /// `100.64.0.0/10` on a `utun` exists only because `tailscaled` is installed, signed in and
    /// running. So the listener outranks the probe rather than the other way round, and a probe
    /// that could not run leaves the rows waiting instead of accusing the Mac of anything.
    static func resolve(
        isEnabled: Bool,
        facts: TailscaleHostFacts,
        doorState: RemoteAccessDoorState,
        doorStatus: RemoteDoorStatus
    ) -> RemoteTailnetReadinessPresentation {
        let isBound = !doorState.bindings.isEmpty
        let issue = isBound ? nil : facts.issue

        var rows: [Row] = []
        rows.append(installedRow(isEnabled: isEnabled, isBound: isBound, issue: issue))
        rows.append(
            signedInRow(isEnabled: isEnabled, isBound: isBound, facts: facts, issue: issue)
        )
        rows.append(addressRow(isEnabled: isEnabled, state: doorState, status: doorStatus))
        return RemoteTailnetReadinessPresentation(rows: rows)
    }

    private static func installedRow(
        isEnabled: Bool,
        isBound: Bool,
        issue: TailscaleReadinessIssue?
    ) -> Row {
        let title = L10n.string("Tailscale installed")
        guard isEnabled else {
            return Row(
                step: .installed,
                title: title,
                detail: L10n.string("Checked when the tailnet way in is on."),
                mark: .pending
            )
        }
        if issue == .notInstalled {
            return Row(
                step: .installed,
                title: title,
                detail: L10n.string(
                    "Install Tailscale and sign in on this Mac. The door comes back on its own."
                ),
                mark: .attention
            )
        }
        if isBound || issue != nil {
            return Row(
                step: .installed,
                title: title,
                detail: L10n.string("Tailscale is installed."),
                mark: .met
            )
        }
        return Row(
            step: .installed,
            title: title,
            detail: L10n.string("Looking for Tailscale…"),
            mark: .working
        )
    }

    private static func signedInRow(
        isEnabled: Bool,
        isBound: Bool,
        facts: TailscaleHostFacts,
        issue: TailscaleReadinessIssue?
    ) -> Row {
        let title = L10n.string("Signed in and running")
        guard isEnabled else {
            return Row(
                step: .signedIn,
                title: title,
                detail: L10n.string("Waiting for the installation check."),
                mark: .pending
            )
        }
        if isBound || facts.state == .running {
            return Row(
                step: .signedIn,
                title: title,
                detail: L10n.string("This Mac is connected to your tailnet."),
                mark: .met
            )
        }
        switch issue {
        case .notInstalled:
            return Row(
                step: .signedIn,
                title: title,
                detail: L10n.string("Waiting for Tailscale."),
                mark: .pending
            )
        case .some(let issue):
            return Row(step: .signedIn, title: title, detail: issue.rowDetail, mark: .attention)
        case .none:
            return Row(
                step: .signedIn,
                title: title,
                detail: L10n.string("Checking your tailnet status…"),
                mark: .working
            )
        }
    }

    private static func addressRow(
        isEnabled: Bool,
        state: RemoteAccessDoorState,
        status: RemoteDoorStatus
    ) -> Row {
        let title = L10n.string("This Mac’s tailnet address")
        guard isEnabled else {
            return Row(
                step: .tailnetAddress,
                title: title,
                detail: L10n.string("Waiting for Tailscale."),
                mark: .pending
            )
        }
        switch state {
        case .bound:
            return Row(step: .tailnetAddress, title: title, detail: status.sentence, mark: .met)
        case .binding:
            return Row(
                step: .tailnetAddress,
                title: title,
                detail: L10n.string("Binding to this Mac’s tailnet address…"),
                mark: .working
            )
        case .notReachable:
            // The door's own sentence, so the row and the status line cannot drift apart.
            return Row(
                step: .tailnetAddress,
                title: title,
                detail: status.text,
                mark: .attention
            )
        case .off:
            return Row(
                step: .tailnetAddress,
                title: title,
                detail: L10n.string("Waiting for Tailscale."),
                mark: .pending
            )
        }
    }
}
