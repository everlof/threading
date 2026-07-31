import Foundation

/// Which interface a listening socket is bound to.
///
/// This is the fact a port number alone cannot state, and it is the one worth showing: `3000`
/// on `127.0.0.1` is a private dev server, while the same `3000` on `0.0.0.0` is answering on
/// every interface the machine has — the same number, two very different exposures.
enum PortInterface: Equatable, Sendable {

    /// Bound to every interface — `0.0.0.0` or `::`.
    case allInterfaces

    /// Bound to loopback only — `127.0.0.1` or `::1`.
    case localhost

    /// Bound to one specific address, which is neither loopback nor the wildcard.
    case address(String)

    // MARK: - Initialization

    init(address: String) {
        let bare = PortInterface.unmapped(address)

        if PortInterface.wildcardAddresses.contains(bare) {
            self = .allInterfaces
        } else if bare == PortInterface.loopbackIPv6 || bare.hasPrefix(PortInterface.loopbackIPv4Prefix) {
            self = .localhost
        } else {
            self = .address(address)
        }
    }

    // MARK: - Properties

    var displayName: String {
        switch self {
        case .allInterfaces: return L10n.string("all interfaces")
        case .localhost: return "localhost"
        case .address(let address): return address
        }
    }

    /// Whether `http://localhost:<port>` reaches this socket. True for loopback and for a socket
    /// bound to every interface; false for one pinned to a specific outside address, where
    /// offering to open it would hand the user a link that cannot connect.
    var isReachableViaLocalhost: Bool {
        switch self {
        case .allInterfaces, .localhost: return true
        case .address: return false
        }
    }

    /// How widely the socket is exposed, used to pick a winner when one server reports the same
    /// port on more than one address — the broadest binding is the honest thing to show.
    var breadth: Int {
        switch self {
        case .allInterfaces: return 2
        case .address: return 1
        case .localhost: return 0
        }
    }

    // MARK: - Private Methods

    /// An IPv4-mapped IPv6 address (`::ffff:127.0.0.1`) describes an IPv4 endpoint, so it is
    /// classified by the address it carries rather than by its notation.
    private static func unmapped(_ address: String) -> String {
        guard address.hasPrefix(mappedIPv4Prefix) else { return address }
        return String(address.dropFirst(mappedIPv4Prefix.count))
    }

    // MARK: - Constants

    private static let wildcardAddresses: Set<String> = ["0.0.0.0", "::"]
    private static let loopbackIPv6 = "::1"
    private static let loopbackIPv4Prefix = "127."
    private static let mappedIPv4Prefix = "::ffff:"
}

/// One TCP socket a process is listening on.
struct ListeningPort: Equatable, Sendable {

    // MARK: - Properties

    let port: UInt16
    let pid: pid_t

    /// The owning process's short name, as `ps` would show it — `node`, `workerd`, `python3`.
    let command: String

    /// The literal bind address: `0.0.0.0`, `127.0.0.1`, `::1`, `192.168.1.20`.
    let address: String

    let isIPv6: Bool

    // MARK: - Computed Properties

    var interface: PortInterface {
        PortInterface(address: address)
    }

    /// The URL to open when the row is clicked, for a socket localhost can actually reach.
    var localURL: URL? {
        guard interface.isReachableViaLocalhost else { return nil }
        return URL(string: "http://localhost:\(port)")
    }
}
