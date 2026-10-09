import Foundation

/// An independent phone browser may reach only the local web origin the owner opened.
/// This is deliberately not a general network proxy or an export of Mac website data.
public struct RemoteBrowserLocalOrigin: Equatable, Sendable {
    public let host: String
    public let port: UInt16
    public let scheme: String

    public init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let rawHost = url.host?.lowercased(), Self.isLoopback(rawHost),
              url.user == nil, url.password == nil,
              let port = UInt16(exactly: url.port ?? (scheme == "https" ? 443 : 80)), port > 0
        else { return nil }
        self.host = rawHost
        self.port = port
        self.scheme = scheme
    }

    public static func isLoopback(_ host: String) -> Bool {
        let host = host.lowercased()
        if host == "localhost" || host.hasSuffix(".localhost") || host == "::1" || host == "[::1]" {
            return true
        }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.first == "127" && parts.allSatisfy {
            !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } && UInt8($0) != nil
        }
    }

    public var authority: String {
        let name = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return "\(name):\(port)"
    }
    public var key: String { "\(scheme)://\(authority)" }
    public var connectHost: String {
        if host == "::1" || host == "[::1]" { return "::1" }
        return host == "localhost" || host.hasSuffix(".localhost") ? "localhost" : host
    }

    public func accepts(authority: String) -> Bool {
        authority.lowercased() == self.authority
    }
}

public struct RemoteBrowserTunnelRequest: Codable, Sendable {
    public let tabID: String
    public let closingToken: String?
    public let expectedOrigin: String?

    public init(tabID: String, closingToken: String? = nil, expectedOrigin: String? = nil) {
        self.tabID = tabID
        self.closingToken = closingToken
        self.expectedOrigin = expectedOrigin
    }
}

public struct RemoteBrowserTunnelDTO: Codable, Sendable {
    public let url: URL
    public let token: String
    public let expiresAt: Date

    public init(url: URL, token: String, expiresAt: Date) {
        self.url = url
        self.token = token
        self.expiresAt = expiresAt
    }
}
