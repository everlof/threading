#if DEBUG
import Foundation
import ThreadingRemoteKit

/// A deliberately narrow launch door for the simulator's real-wire terminal lab.
///
/// It accepts only cleartext loopback because the opt-in hosted XCTest listens only on the Mac
/// running this simulator. A LAN address, public host, HTTPS origin, query, or missing bearer is
/// rejected so this debug convenience cannot become a general pairing bypass.
struct MobileTerminalWireFixtureConfiguration: Equatable {
    static let environmentKey = "THREADING_MOBILE_TERMINAL_WIRE_URL"

    let link: RemoteConnectionLink

    static var current: MobileTerminalWireFixtureConfiguration? {
        resolve(environment: ProcessInfo.processInfo.environment)
    }

    static func resolve(
        environment: [String: String]
    ) -> MobileTerminalWireFixtureConfiguration? {
        guard let raw = environment[environmentKey],
              let url = URL(string: raw),
              url.scheme?.lowercased() == "http",
              let host = url.host?.lowercased(),
              host == "127.0.0.1" || host == "localhost" || host == "::1",
              let link = RemoteConnectionLink(url: url) else {
            return nil
        }
        return MobileTerminalWireFixtureConfiguration(link: link)
    }
}
#endif
