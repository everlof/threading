import Foundation
import ThreadingRemoteKit

/// One network the remote-access listener may answer on.
///
/// The server is still one server, with one identity and one authorization path. A door is not a
/// second server: it is a decision about which of this Mac's addresses get an `NWListener` and
/// which get advertised. That distinction is the privacy guarantee. Binding every interface at
/// once would mean somebody who turned on tailnet access for its privacy was also listening on
/// hotel Wi-Fi, so the guarantee is enforced at bind time rather than by a later token check.
///
/// `loopback` is deliberately in the enum and deliberately not offered to the user: it is bound
/// whenever Remote Access is on, because the Hosted Direct bridge and Tailscale Serve both talk
/// plain HTTP to it, and there is nothing about `127.0.0.1` to disclose.
enum RemoteAccessDoor: String, CaseIterable, Sendable {
    /// `127.0.0.1`. This Mac only. Always bound, never advertised to another device.
    case loopback
    /// Routable addresses on networks this Mac is attached to.
    case lan
    /// The address this Mac holds on a VPN tunnel somebody else set up.
    case vpn
    /// The address this Mac holds on its tailnet.
    case tailscale

    /// The doors a person chooses between. Loopback is not one of them.
    static let selectable: [RemoteAccessDoor] = [.lan, .vpn, .tailscale]

    /// The doors this build can actually bind.
    ///
    /// `tailscale` joined the set once the listener had an identity of its own: a tailnet address
    /// is one of this Mac's addresses, so it is a bind rather than a `tailscale serve` handler,
    /// and it presents the same pinned certificate as every other routable door. `vpn` is
    /// classified from the interface list so the status model and the tests can talk about it,
    /// but it is not bindable yet and enabling it is honestly reported as `notAvailableYet`
    /// rather than silently treated as off.
    static let bindable: Set<RemoteAccessDoor> = [.loopback, .lan, .tailscale]

    var isSelectable: Bool { Self.selectable.contains(self) }

    var isBindable: Bool { Self.bindable.contains(self) }

    /// Whether a listener on this door must present a TLS identity.
    ///
    /// Loopback is the one exception and stays cleartext: `PeerTunnelNetworkBridge` opens plain
    /// TCP to it and Tailscale Serve proxies plain HTTP to it, and neither should have to learn
    /// about a certificate. If loopback ever gains TLS, Serve's target has to become
    /// `https+insecure://127.0.0.1:<port>` and the bridge has to speak TLS; that cost is the
    /// reason not to. Every routable door answers `true`, and a door that cannot get an identity
    /// binds nothing rather than falling back to cleartext.
    var requiresTLS: Bool { self != .loopback }

    /// Whether this door's addresses are advertised over Bonjour.
    ///
    /// Only the LAN door. Loopback reaches this Mac alone, so advertising it would broadcast a
    /// route nobody can take; a tailnet or VPN address is reached over a tunnel that multicast
    /// does not cross, so an advertisement there would be a broadcast to nobody while still being
    /// a broadcast. Same-network discovery is a convenience for the one door it can work on, and
    /// the advertised endpoint list is what makes the others work.
    var isAdvertisedOverBonjour: Bool { self == .lan }

    /// What this door reports when no interface currently carries an address it would bind.
    ///
    /// The tailnet has its own answer because the absence means something different and is fixed
    /// somewhere else: an `en0` with no address is a Mac off every network, while a `utun` with no
    /// `100.64.0.0/10` address is `tailscaled` not running or not signed in. Both are "nothing to
    /// bind", and a status line that said "no address on this network" about a tailnet would send
    /// somebody to their Wi-Fi settings.
    var absentInterfaceReason: RemoteDoorUnreachableReason {
        self == .tailscale ? .tailscaleNotConnected : .noInterface
    }

    /// The wire vocabulary an address on this door is advertised under.
    var endpointKind: String {
        switch self {
        case .loopback: return RemoteHostEndpointKind.loopback
        case .lan: return RemoteHostEndpointKind.lan
        case .vpn: return RemoteHostEndpointKind.vpn
        case .tailscale: return RemoteHostEndpointKind.tailscale
        }
    }
}

/// One address currently held by one interface.
///
/// A value, not a live query: the listener set is rebuilt from a fresh enumeration whenever the
/// network path changes, so nothing here has to stay true for the life of the process.
struct RemoteNetworkAddress: Equatable, Hashable, Sendable, Comparable {
    let interfaceName: String
    /// The numeric address, without a zone identifier.
    let address: String
    let isIPv6: Bool

    init(interfaceName: String, address: String, isIPv6: Bool? = nil) {
        self.interfaceName = interfaceName
        self.address = address
        self.isIPv6 = isIPv6 ?? address.contains(":")
    }

    /// The address as it appears inside a URL. IPv6 literals are bracketed.
    var urlHost: String { isIPv6 ? "[\(address)]" : address }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.interfaceName != rhs.interfaceName { return lhs.interfaceName < rhs.interfaceName }
        return lhs.address < rhs.address
    }
}

/// Which door an interface's addresses belong to.
///
/// Classification is per interface rather than per address, because that is how the answer is
/// actually decided: a `utun` carrying a `100.64.0.0/10` address is Tailscale's tunnel, and the
/// IPv6 address sitting beside it on the same interface is Tailscale's too. Doing it per address
/// would need a hard-coded Tailscale IPv6 prefix; doing it per interface does not.
enum RemoteDoorClassification {

    /// Groups a flat address list into doors, dropping everything no door wants.
    ///
    /// Pure on purpose: the enumeration is the part that touches the system, and the rule is the
    /// part worth testing. Addresses come back sorted so a rebuild that changes nothing produces
    /// an identical plan.
    static func doors(
        for addresses: [RemoteNetworkAddress]
    ) -> [RemoteAccessDoor: [RemoteNetworkAddress]] {
        var byInterface: [String: [RemoteNetworkAddress]] = [:]
        for address in addresses {
            byInterface[address.interfaceName, default: []].append(address)
        }

        var result: [RemoteAccessDoor: [RemoteNetworkAddress]] = [:]
        for (interfaceName, interfaceAddresses) in byInterface {
            guard let door = door(forInterface: interfaceName, addresses: interfaceAddresses)
            else { continue }
            let usable = interfaceAddresses.filter(isRoutable)
            guard !usable.isEmpty else { continue }
            result[door, default: []].append(contentsOf: usable)
        }
        for door in result.keys {
            result[door]?.sort()
        }
        return result
    }

    /// The door an interface belongs to, or nil when no door wants it.
    static func door(
        forInterface interfaceName: String,
        addresses: [RemoteNetworkAddress]
    ) -> RemoteAccessDoor? {
        guard !RemoteInterfaceDefaults.excludedInterfaceNames.contains(interfaceName) else {
            return nil
        }
        if interfaceName.hasPrefix(RemoteInterfaceDefaults.loopbackInterfacePrefix) { return nil }
        if interfaceName.hasPrefix(RemoteInterfaceDefaults.lanInterfacePrefix) { return .lan }
        if interfaceName.hasPrefix(RemoteInterfaceDefaults.tunnelInterfacePrefix) {
            return addresses.contains(where: isTailscaleCarrierGradeNAT) ? .tailscale : .vpn
        }
        return nil
    }

    /// Whether an address is worth binding at all.
    ///
    /// Link-local addresses are excluded on both families: an IPv4 `169.254.x` address means DHCP
    /// did not answer, and an IPv6 `fe80::` address needs a zone identifier no client will carry.
    ///
    /// Loopback is not filtered here. Which interface is the loopback is a fact the kernel already
    /// states — `RemoteNetworkInterfaces` drops `IFF_LOOPBACK` and the door rule above drops
    /// anything named `lo*` — and repeating it as an address literal would be a third opinion
    /// about the same question.
    static func isRoutable(_ address: RemoteNetworkAddress) -> Bool {
        let lowered = address.address.lowercased()
        if address.isIPv6 {
            return !RemoteInterfaceDefaults.ipv6LinkLocalPrefixes.contains(where: lowered.hasPrefix)
        }
        return !lowered.hasPrefix(RemoteInterfaceDefaults.ipv4LinkLocalPrefix)
    }

    /// Whether an address sits in `100.64.0.0/10`, which is what makes a tunnel Tailscale's.
    static func isTailscaleCarrierGradeNAT(_ address: RemoteNetworkAddress) -> Bool {
        guard !address.isIPv6 else { return false }
        let parts = address.address.split(separator: ".")
        guard parts.count == 4,
              let first = UInt8(parts[0]),
              let second = UInt8(parts[1]),
              first == RemoteInterfaceDefaults.tailscaleCGNATFirstOctet else { return false }
        return RemoteInterfaceDefaults.tailscaleCGNATSecondOctets.contains(second)
    }
}

/// Reads this Mac's current addresses.
///
/// Injected as a closure so the classifier and the listener set can both be exercised against a
/// stated interface list rather than whatever the developer's Wi-Fi happens to be doing.
typealias RemoteNetworkAddressSource = @Sendable () -> [RemoteNetworkAddress]

enum RemoteNetworkInterfaces {

    /// Every up-and-running non-loopback address this Mac currently holds.
    ///
    /// `getifaddrs` is a single bounded syscall over a list whose length is the number of
    /// configured interfaces, so it is cheap enough for a path-change callback. The loopback
    /// flag is honoured here rather than in the classifier: the door rules are a statement about
    /// interface names, and the kernel already knows which interface is the loopback.
    static let current: RemoteNetworkAddressSource = {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var addresses: [RemoteNetworkAddress] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            cursor = entry.pointee.ifa_next
            guard let socketAddress = entry.pointee.ifa_addr else { continue }
            let flags = entry.pointee.ifa_flags
            guard flags & UInt32(IFF_UP) != 0,
                  flags & UInt32(IFF_RUNNING) != 0,
                  flags & UInt32(IFF_LOOPBACK) == 0 else { continue }

            let family = socketAddress.pointee.sa_family
            guard family == UInt8(AF_INET) || family == UInt8(AF_INET6) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                socketAddress,
                socklen_t(socketAddress.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 else { continue }

            let numeric = String(cString: host)
            // A link-local IPv6 address arrives as `fe80::1%en0`. The zone is dropped rather
            // than kept because those addresses are refused by the classifier anyway.
            let bare = numeric.split(separator: "%", maxSplits: 1).first.map(String.init) ?? numeric
            addresses.append(RemoteNetworkAddress(
                interfaceName: String(cString: entry.pointee.ifa_name),
                address: bare,
                isIPv6: family == UInt8(AF_INET6)
            ))
        }
        return addresses.sorted()
    }
}

/// One address the listener set is answering on.
struct RemoteListenerBinding: Equatable, Hashable, Sendable {
    let door: RemoteAccessDoor
    let address: RemoteNetworkAddress
    let port: UInt16

    /// The origin a client would use: `https` on every routable door, and `http` on loopback,
    /// which is the one door that stays cleartext.
    ///
    /// The host is the bracketed form: `URLComponents` returns nil for a bare IPv6 literal, so an
    /// unbracketed address would advertise nothing at all rather than advertise something wrong.
    var origin: URL? {
        var components = URLComponents()
        components.scheme = door.requiresTLS
            ? RemoteAccessDefaults.tlsScheme
            : RemoteAccessDefaults.cleartextScheme
        components.host = address.urlHost
        components.port = Int(port)
        components.path = "/"
        return components.url
    }
}

/// Why an enabled door has nothing listening for it.
///
/// A code rather than a sentence, for the same reason `TailscaleReadinessIssue` is one: the
/// status line a person reads is localised, and a diagnostic report has to group by cause.
enum RemoteDoorUnreachableReason: String, Equatable, Sendable {
    /// No interface currently carries an address this door would bind.
    case noInterface
    /// The tailnet door's own shape of `noInterface`: no `utun` holds a `100.64.0.0/10` address,
    /// which is what this Mac not being on its tailnet looks like from the interface list.
    case tailscaleNotConnected
    /// Something else holds the listener's port on this door's addresses.
    case portInUse
    /// This build classifies the door but does not bind it yet.
    case notAvailableYet
    /// This Mac has no certificate to present, so nothing routable may be bound at all. The
    /// identity's own state says which of missing, unreadable or unwritable it is.
    case identityUnavailable

    /// Which reason a door reports when its addresses disagree. A missing identity outranks
    /// everything, because no address can answer without one; something sitting on the port is
    /// the next most actionable, and it outranks an address that simply is not here.
    ///
    /// The two "nothing to bind" reasons are adjacent and never compete: a door produces the one
    /// its own interfaces mean (`RemoteAccessDoor.absentInterfaceReason`), so they are separate
    /// answers to the same question rather than two rankings of it.
    static let reportingPriority: [RemoteDoorUnreachableReason] = [
        .identityUnavailable, .portInUse, .noInterface, .tailscaleNotConnected, .notAvailableYet
    ]
}

/// What one door is doing right now.
enum RemoteAccessDoorState: Equatable, Sendable {
    /// Not selected. Nothing is bound for it, which is the shipped default for every door.
    case off
    /// Selected, and its listeners have not answered yet.
    case binding
    /// Selected and answering at these addresses.
    case bound([RemoteListenerBinding])
    /// Selected, and nothing is listening for it right now.
    case notReachable(RemoteDoorUnreachableReason)

    var bindings: [RemoteListenerBinding] {
        guard case .bound(let bindings) = self else { return [] }
        return bindings
    }

    /// The token a diagnostic groups by. Never an address.
    var diagnosticResult: String {
        switch self {
        case .off: return "off"
        case .binding: return "binding"
        case .bound: return "bound"
        case .notReachable: return "unreachable"
        }
    }
}

/// A best-effort reading of the macOS Application Firewall.
///
/// It is a hint and the status model must treat it as one. The Mac cannot observe whether an
/// incoming connection would be allowed by probing itself: traffic from this Mac to its own LAN
/// address is local and the Application Firewall does not filter it. The real signal is a phone
/// reporting whether it connected, which is why nothing here may produce a "reachable" claim.
struct RemoteFirewallHint: Equatable, Sendable {
    enum GlobalState: String, Equatable, Sendable {
        case on
        case off
        case unknown
    }

    enum ApplicationState: String, Equatable, Sendable {
        case allowed
        case blocked
        case unknown
    }

    let globalState: GlobalState
    let applicationState: ApplicationState

    static let unknown = RemoteFirewallHint(globalState: .unknown, applicationState: .unknown)

    /// Whether the firewall is the first thing to suspect when a phone cannot connect.
    var mayBlockIncomingConnections: Bool {
        globalState == .on && applicationState != .allowed
    }
}

/// What the whole listener set is doing, as the later settings screen will render it.
struct RemoteListenerStatus: Equatable, Sendable {
    /// The port actually taken, which every consumer of the listener uses.
    let port: UInt16?
    let doors: [RemoteAccessDoor: RemoteAccessDoorState]
    let firewall: RemoteFirewallHint

    static let idle = RemoteListenerStatus(port: nil, doors: [:], firewall: .unknown)

    func state(of door: RemoteAccessDoor) -> RemoteAccessDoorState { doors[door] ?? .off }

    /// Every address currently answering, in a stable order.
    var bindings: [RemoteListenerBinding] {
        RemoteAccessDoor.allCases
            .flatMap { state(of: $0).bindings }
    }
}

/// Why the listener could not start at all.
///
/// A named state rather than a silent ephemeral port. Falling back to `port: .any` is the bug
/// this whole step exists to remove: the address changed on every launch and every paired phone
/// had to be re-scanned.
enum RemoteListenerFailure: String, Equatable, Sendable {
    /// Every port in the configured range is taken on loopback.
    case portRangeInUse
    /// The loopback listener could not be constructed or reported a failure that is not a
    /// collision.
    case loopbackUnavailable

    /// What a person reads. The raw value stays the token a diagnostic groups by, and the two
    /// must not be the same string: "portRangeInUse" was reaching the settings page verbatim,
    /// inside a sentence about a listener, with nothing in it a person could act on.
    var statement: String {
        switch self {
        case .portRangeInUse:
            return L10n.format(
                "Ports %1$@ to %2$@ are all in use on this Mac. Quit whatever is holding them, "
                    + "then turn Remote Access on again.",
                String(RemoteAccessDefaults.listenerPortFallbackRange.lowerBound),
                String(RemoteAccessDefaults.listenerPortFallbackRange.upperBound)
            )
        case .loopbackUnavailable:
            return L10n.string(
                "Threading could not open its listener on this Mac. Turn Remote Access on again, "
                    + "and report it if it keeps failing."
            )
        }
    }
}

enum RemoteListenerStartOutcome: Equatable, Sendable {
    case listening(port: UInt16)
    case failed(RemoteListenerFailure)

    var port: UInt16? {
        guard case .listening(let port) = self else { return nil }
        return port
    }
}

/// What the server is asked to bind.
struct RemoteListenerConfiguration: Equatable, Sendable {
    /// The port to try first. Sticky across restarts, which is what lets a phone reconnect.
    var preferredPort: UInt16
    /// The routable doors to bind. Loopback is not in here: it is always bound.
    var doors: Set<RemoteAccessDoor>
    /// Where the port may land when the preferred one is taken. Part of the bind description
    /// rather than a constant read inside the listener, because a client has to walk the same
    /// list and a test has to be able to state a range nothing else on the machine is using.
    var fallbackRange: ClosedRange<UInt16>
    /// Whether the LAN door is advertised over Bonjour so a paired phone can find this Mac
    /// without being told an address.
    ///
    /// On by default and separately switchable, because an advertisement is a broadcast: it is
    /// visible to everyone on the network, and some people will want the door open without the
    /// announcement. Turning it off costs nothing but the convenience — the advertised endpoint
    /// list still carries every address, which is the same path a VPN or tailnet already uses.
    var isDiscoveryEnabled: Bool

    init(
        preferredPort: UInt16 = RemoteAccessDefaults.defaultListenerPort,
        doors: Set<RemoteAccessDoor> = [],
        fallbackRange: ClosedRange<UInt16> = RemoteAccessDefaults.listenerPortFallbackRange,
        isDiscoveryEnabled: Bool = true
    ) {
        self.preferredPort = preferredPort
        self.doors = doors
        self.fallbackRange = fallbackRange
        self.isDiscoveryEnabled = isDiscoveryEnabled
    }

    /// The ports the listener tries, in order.
    var portCandidates: [UInt16] {
        RemoteListenerPortPlan.candidates(preferred: preferredPort, range: fallbackRange)
    }

    /// Only the doors this build binds, with loopback added. A door the user selected that this
    /// build cannot bind is reported as `notAvailableYet`, never quietly bound.
    var bindableDoors: Set<RemoteAccessDoor> {
        doors.intersection(RemoteAccessDoor.bindable).union([.loopback])
    }
}

/// The order the listener tries ports in.
///
/// Deterministic, and short enough that a client can walk the same list. The configured port
/// comes first, then the shipped range, so a person who moved the port off the default still
/// lands somewhere both ends can predict rather than on an ephemeral port nobody can guess.
enum RemoteListenerPortPlan {
    static func candidates(
        preferred: UInt16,
        range: ClosedRange<UInt16> = RemoteAccessDefaults.listenerPortFallbackRange
    ) -> [UInt16] {
        var seen: Set<UInt16> = []
        var candidates: [UInt16] = []
        for port in [preferred] + Array(range) {
            guard port >= RemoteAccessDefaults.minimumListenerPort else { continue }
            guard seen.insert(port).inserted else { continue }
            candidates.append(port)
        }
        return candidates
    }
}
