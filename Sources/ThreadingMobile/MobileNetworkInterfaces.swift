import Darwin
import Foundation
import Network

/// One address-bearing interface of this iPhone, the way the connection panel prints it.
///
/// The kind is read off the BSD name because iOS has no public API that says which interface is
/// the Wi-Fi radio: `en0` is the Wi-Fi interface on every iPhone and iPad, `pdp_ip*` is the
/// cellular data context, `utun*`/`ipsec*`/`ppp*` are tunnels, and a further `en*` is an Ethernet
/// or USB adapter. Anything else (`lo0`, `awdl0`, `llw0`, `ap1`, `anpi*`, `bridge*`) is either
/// loopback or a link the phone uses among its own peers, and is not an address a Mac is reached
/// through, so it is not shown.
struct MobileNetworkInterface: Equatable, Hashable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case wifi
        case cellular
        case vpn
        case wired

        /// The order the panel lists interfaces in: the ones a Mac is usually reached over first.
        var order: Int { Self.allCases.firstIndex(of: self) ?? Self.allCases.count }
    }

    let name: String
    let kind: Kind
    let ipv4: [String]
    let ipv6: [String]

    var addresses: [String] { ipv4 + ipv6 }
}

/// The current network path, reduced to the facts the panel states.
///
/// A value rather than `NWPath` so it can cross from the monitor's queue to the main actor and
/// so a fixture can state one without a monitor.
struct MobileNetworkPathSummary: Equatable, Sendable {
    enum Status: Sendable {
        case satisfied
        case unsatisfied
        case requiresConnection
    }

    let status: Status
    let usesWiFi: Bool
    let usesCellular: Bool
    let usesWired: Bool
    let isExpensive: Bool
    let isConstrained: Bool

    init(
        status: Status,
        usesWiFi: Bool = false,
        usesCellular: Bool = false,
        usesWired: Bool = false,
        isExpensive: Bool = false,
        isConstrained: Bool = false
    ) {
        self.status = status
        self.usesWiFi = usesWiFi
        self.usesCellular = usesCellular
        self.usesWired = usesWired
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
    }

    init(_ path: NWPath) {
        let status: Status
        switch path.status {
        case .satisfied: status = .satisfied
        case .requiresConnection: status = .requiresConnection
        case .unsatisfied: status = .unsatisfied
        @unknown default: status = .unsatisfied
        }
        self.init(
            status: status,
            usesWiFi: path.usesInterfaceType(.wifi),
            usesCellular: path.usesInterfaceType(.cellular),
            usesWired: path.usesInterfaceType(.wiredEthernet),
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained
        )
    }
}

enum MobileNetworkInterfaces {
    /// A phone has a handful of address-bearing interfaces. The accumulator keeps at most this
    /// many candidates per kind while it walks the kernel list, then returns this many overall.
    /// Keeping a per-kind ceiling means late Wi-Fi or cellular entries can still displace an
    /// earlier tunnel without allowing an unusual configuration to grow memory with its input.
    static let maximumInterfaces = 6
    /// IPv6 hands an interface several addresses at once (a stable one plus privacy temporaries);
    /// a person needs the first few to recognise the network, not every one.
    static let maximumAddressesPerFamily = 3

    /// One address as `getifaddrs` reported it, kept apart from the classification so the
    /// classification can be tested without a socket in sight.
    struct Address: Equatable, Sendable {
        enum Family: Sendable {
            case ipv4
            case ipv6
        }

        let interfaceName: String
        let family: Family
        let value: String
    }

    static func kind(forInterfaceNamed name: String) -> MobileNetworkInterface.Kind? {
        let lowered = name.lowercased()
        if lowered.hasPrefix("pdp_ip") { return .cellular }
        if lowered.hasPrefix("utun") || lowered.hasPrefix("ipsec") || lowered.hasPrefix("ppp") {
            return .vpn
        }
        if lowered == "en0" { return .wifi }
        if lowered.hasPrefix("en"), lowered.dropFirst(2).allSatisfy(\.isNumber) { return .wired }
        return nil
    }

    /// Link-local IPv6 is per link and present on every interface; it says nothing about which
    /// network the phone is on, so the panel leaves it out. The IPv4 self-assigned range is kept:
    /// a `169.254.` address is exactly the fact worth seeing when DHCP has failed.
    static func isLinkLocal(_ address: Address) -> Bool {
        address.family == .ipv6 && address.value.lowercased().hasPrefix("fe80:")
    }

    /// Bounded state shared by the testable array path and the live `getifaddrs` walk.
    ///
    /// The kernel list still has to be traversed to find a preferred interface that appears
    /// late, but retained state is capped at four kinds × `maximumInterfaces`, with only the
    /// first `maximumAddressesPerFamily` unique addresses for each candidate.
    private struct InterfaceAccumulator {
        private var kinds: [String: MobileNetworkInterface.Kind] = [:]
        private var ipv4: [String: [String]] = [:]
        private var ipv6: [String: [String]] = [:]

        mutating func add(_ address: Address) {
            guard !MobileNetworkInterfaces.isLinkLocal(address),
                  let kind = MobileNetworkInterfaces.kind(
                    forInterfaceNamed: address.interfaceName
                  ) else { return }
            let name = address.interfaceName
            if kinds[name] == nil {
                let retainedForKind = kinds.compactMap { entry in
                    entry.value == kind ? entry.key : nil
                }
                if retainedForKind.count >= MobileNetworkInterfaces.maximumInterfaces {
                    guard let worst = retainedForKind.max(), name < worst else { return }
                    kinds.removeValue(forKey: worst)
                    ipv4.removeValue(forKey: worst)
                    ipv6.removeValue(forKey: worst)
                }
                kinds[name] = kind
            }

            switch address.family {
            case .ipv4:
                Self.append(address.value, to: &ipv4[name, default: []])
            case .ipv6:
                Self.append(address.value, to: &ipv6[name, default: []])
            }
        }

        func result() -> [MobileNetworkInterface] {
            kinds.map { name, kind in
                MobileNetworkInterface(
                    name: name,
                    kind: kind,
                    ipv4: ipv4[name] ?? [],
                    ipv6: ipv6[name] ?? []
                )
            }
            .sorted { lhs, rhs in
                if lhs.kind.order != rhs.kind.order { return lhs.kind.order < rhs.kind.order }
                return lhs.name < rhs.name
            }
            .prefix(MobileNetworkInterfaces.maximumInterfaces)
            .map { $0 }
        }

        private static func append(_ value: String, to values: inout [String]) {
            guard values.count < MobileNetworkInterfaces.maximumAddressesPerFamily,
                  !values.contains(value) else { return }
            values.append(value)
        }
    }

    /// Groups reported addresses into the interfaces the panel shows, in the panel's order.
    static func interfaces(from addresses: [Address]) -> [MobileNetworkInterface] {
        var accumulator = InterfaceAccumulator()
        for address in addresses { accumulator.add(address) }
        return accumulator.result()
    }

    /// The interfaces this device has addresses on right now.
    ///
    /// One syscall and a bounded walk. Call it off the main actor all the same: it is a kernel
    /// round trip, and the only caller is a path-change handler that already runs on its own
    /// queue.
    static func current() -> [MobileNetworkInterface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var accumulator = InterfaceAccumulator()
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            cursor = entry.pointee.ifa_next
            guard (Int32(entry.pointee.ifa_flags) & IFF_UP) != 0,
                  let socketAddress = entry.pointee.ifa_addr else { continue }
            let family: Address.Family
            switch Int32(socketAddress.pointee.sa_family) {
            case AF_INET: family = .ipv4
            case AF_INET6: family = .ipv6
            default: continue
            }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                socketAddress,
                socklen_t(socketAddress.pointee.sa_len),
                &buffer,
                socklen_t(buffer.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 else { continue }
            var value = String(cString: buffer)
            // A scoped IPv6 address arrives as `fe80::1%en0`; the interface is already the key.
            if let scope = value.firstIndex(of: "%") {
                value = String(value[..<scope])
            }
            accumulator.add(Address(
                interfaceName: String(cString: entry.pointee.ifa_name),
                family: family,
                value: value
            ))
        }
        return accumulator.result()
    }
}

/// Watches the network path for as long as a connection panel is on screen.
///
/// One `NWPathMonitor`, started when the panel appears and cancelled when it goes, and the
/// interface walk runs in the path handler and nowhere else: the network changing is the only
/// event that can change the answer, so that is the only time the syscall is made.
@MainActor
final class MobileNetworkPathObserver: ObservableObject {
    @Published private(set) var path: MobileNetworkPathSummary?
    @Published private(set) var interfaces: [MobileNetworkInterface] = []

    private var monitor: NWPathMonitor?
    private let queue = DispatchQueue(label: "threading.mobile.network-path", qos: .utility)

    /// Observes until the task is cancelled, which is what `.task` does when the panel goes away.
    func run() async {
        start()
        defer { stop() }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3_600))
        }
    }

    func start() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let summary = MobileNetworkPathSummary(path)
            let interfaces = MobileNetworkInterfaces.current()
            Task { @MainActor [weak self] in
                self?.path = summary
                self?.interfaces = interfaces
            }
        }
        self.monitor = monitor
        monitor.start(queue: queue)
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
    }
}
