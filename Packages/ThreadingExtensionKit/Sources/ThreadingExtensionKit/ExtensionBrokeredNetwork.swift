import Foundation

/// The host-brokered network fetch.
///
/// A safe WebAssembly extension has no sockets; what it has is the right to *ask Threading* for
/// specific origins it declared up front. The manifest names each origin in `networkGrants`,
/// the install dialog shows the user exactly that list, and every fetch is checked against it.
/// A grant may also name a host-known credential provider (`"github"`), in which case Threading
/// attaches the user's best connected credential itself and reports which tier answered — the
/// token never crosses the extension boundary.
///
/// One combination is refused outright at inspection: a credentialed grant beside a companion
/// holding raw `network.client`. Brokered responses only ever land inside the sandboxed guest,
/// so they cannot leave the machine — unless the same extension also owns an unrestricted
/// socket, which is exactly the pairing this rule forbids.
public enum ExtensionBrokeredNetwork {
    public static let maximumGrants = 8
    public static let maximumURLLength = 2_048
    public static let maximumRequestHeaders = 16
    public static let maximumHeaderNameLength = 64
    public static let maximumHeaderValueLength = 1_024
    public static let maximumRequestBodyBytes = 256 * 1024
    public static let maximumResponseBodyBytes = 4 * 1024 * 1024
    /// v1 is deliberately read-only: a write API under a user credential is a different
    /// review conversation, and nothing shipping today needs one.
    public static let allowedMethods: Set<String> = ["GET", "HEAD"]
    /// Headers the broker owns or that would smuggle authority; requests naming one are
    /// refused rather than silently rewritten.
    public static let deniedRequestHeaders: Set<String> = [
        "authorization", "cookie", "host", "content-length", "proxy-authorization"
    ]
    /// Response headers that carry ambient authority rather than data.
    public static let deniedResponseHeaders: Set<String> = ["set-cookie"]
    /// Credential provider ids hosts may implement. Grants naming anything else are refused
    /// at package inspection, so an approval dialog never describes a provider that does not
    /// exist.
    public static let knownCredentialProviders: Set<String> = ["github"]
}

/// One declared origin in the manifest's `networkGrants`.
///
/// The scheme is always https and is therefore not declared. `host` is an exact DNS name —
/// no wildcard, no port, no path — because the grant is what the user approves, and "exactly
/// api.github.com" is approvable in a way patterns are not.
public struct ExtensionNetworkGrant: Codable, Equatable, Sendable {
    public let host: String
    public let methods: [String]
    /// A host-known credential provider id, or nil for anonymous fetches only.
    public let credential: String?

    public init(host: String, methods: [String], credential: String? = nil) {
        self.host = host
        self.methods = methods
        self.credential = credential
    }

    func validationIssues(path: String) -> [ExtensionValidationIssue] {
        var issues: [ExtensionValidationIssue] = []
        let allowedHostCharacters = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-"
        )
        if host.isEmpty
            || host.count > 253
            || host.hasPrefix(".")
            || host.hasSuffix(".")
            || host.contains("..")
            || !host.unicodeScalars.allSatisfy(allowedHostCharacters.contains) {
            issues.append(.init(
                path: "\(path).host",
                message: "must be a lowercase DNS name with no scheme, port, or path"
            ))
        }
        if methods.isEmpty {
            issues.append(.init(path: "\(path).methods", message: "must not be empty"))
        }
        for (index, method) in methods.enumerated()
        where !ExtensionBrokeredNetwork.allowedMethods.contains(method) {
            issues.append(.init(
                path: "\(path).methods[\(index)]",
                message: "v1 permits \(ExtensionBrokeredNetwork.allowedMethods.sorted().joined(separator: ", "))"
            ))
        }
        if let credential,
           !ExtensionBrokeredNetwork.knownCredentialProviders.contains(credential) {
            issues.append(.init(
                path: "\(path).credential",
                message: "unknown provider; v1 knows \(ExtensionBrokeredNetwork.knownCredentialProviders.sorted().joined(separator: ", "))"
            ))
        }
        return issues
    }
}

/// Which credential ultimately served a brokered fetch.
///
/// Carried so an extension can present an honest hint — a 404 under `anonymous` usually means
/// "connect the provider in Threading's Settings", while the same answer under `app` means the
/// resource genuinely is not reachable. Unknown future tiers decode as `nil` through
/// `credentialTier`; the raw string stays available.
public enum ExtensionBrokeredCredentialTier: String, Codable, Equatable, Sendable {
    /// The provider's own app connection, authorized by the user in Threading's Settings.
    case app
    /// A token borrowed from the provider's CLI login (for GitHub: `gh`).
    case ghCLI = "gh-cli"
    /// A token from the user's configured git credential helper.
    case gitCredential = "git-credential"
    /// No credential attached.
    case anonymous
}

/// The extension-to-host body for one brokered fetch.
public struct ExtensionBrokeredFetchRequest: Codable, Equatable, Sendable {
    public static let currentProtocolVersion = 1

    public let protocolVersion: Int
    public let method: String
    public let url: String
    public let headers: [String: String]
    public let bodyBase64: String?

    public init(
        protocolVersion: Int = Self.currentProtocolVersion,
        method: String,
        url: String,
        headers: [String: String] = [:],
        bodyBase64: String? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.method = method
        self.url = url
        self.headers = headers
        self.bodyBase64 = bodyBase64
    }

    public func validate() throws {
        var issues: [ExtensionValidationIssue] = []
        if protocolVersion != Self.currentProtocolVersion {
            issues.append(.init(
                path: "protocolVersion",
                message: "expected \(Self.currentProtocolVersion), got \(protocolVersion)"
            ))
        }
        if !ExtensionBrokeredNetwork.allowedMethods.contains(method) {
            issues.append(.init(
                path: "method",
                message: "v1 permits \(ExtensionBrokeredNetwork.allowedMethods.sorted().joined(separator: ", "))"
            ))
        }
        if url.count > ExtensionBrokeredNetwork.maximumURLLength {
            issues.append(.init(path: "url", message: "is too long"))
        } else if let components = URLComponents(string: url) {
            if components.scheme != "https" {
                issues.append(.init(path: "url", message: "must be https"))
            }
            if (components.host ?? "").isEmpty {
                issues.append(.init(path: "url", message: "must name a host"))
            }
            if components.port != nil {
                issues.append(.init(path: "url", message: "must not name a port"))
            }
            if components.user != nil || components.password != nil {
                issues.append(.init(path: "url", message: "must not carry user info"))
            }
        } else {
            issues.append(.init(path: "url", message: "is not a valid URL"))
        }
        if headers.count > ExtensionBrokeredNetwork.maximumRequestHeaders {
            issues.append(.init(path: "headers", message: "too many headers"))
        }
        for (name, value) in headers {
            let lowered = name.lowercased()
            if ExtensionBrokeredNetwork.deniedRequestHeaders.contains(lowered) {
                issues.append(.init(
                    path: "headers.\(name)",
                    message: "is owned by the broker"
                ))
            }
            if name.isEmpty
                || name.count > ExtensionBrokeredNetwork.maximumHeaderNameLength
                || value.count > ExtensionBrokeredNetwork.maximumHeaderValueLength {
                issues.append(.init(path: "headers.\(name)", message: "is out of bounds"))
            }
        }
        if let bodyBase64 {
            guard let data = Data(base64Encoded: bodyBase64) else {
                issues.append(.init(path: "bodyBase64", message: "is not base64"))
                throw ExtensionValidationError(issues: issues)
            }
            if data.count > ExtensionBrokeredNetwork.maximumRequestBodyBytes {
                issues.append(.init(path: "bodyBase64", message: "exceeds the request cap"))
            }
        }
        if !issues.isEmpty {
            throw ExtensionValidationError(issues: issues)
        }
    }
}

/// A completed HTTP exchange, whatever its status. GitHub's 404 is an answer, not a broker
/// failure — interpreting statuses is the extension's business.
public struct ExtensionBrokeredFetchResponse: Codable, Equatable, Sendable {
    public let status: Int
    public let headers: [String: String]
    public let bodyBase64: String
    /// Raw on the wire so a newer host's tier does not turn the response undecodable.
    public let credential: String

    public var body: Data? {
        Data(base64Encoded: bodyBase64)
    }

    public var credentialTier: ExtensionBrokeredCredentialTier? {
        ExtensionBrokeredCredentialTier(rawValue: credential)
    }

    public init(status: Int, headers: [String: String], bodyBase64: String, credential: String) {
        self.status = status
        self.headers = headers
        self.bodyBase64 = bodyBase64
        self.credential = credential
    }
}

/// The transport itself failed — DNS, timeout, connection refused. Distinct from an HTTP
/// answer with a sad status, and from the host rejecting the request as outside its grants.
public struct ExtensionBrokeredFetchFailure: Error, Codable, Equatable, Sendable, LocalizedError {
    public let message: String
    public let credential: String

    public var credentialTier: ExtensionBrokeredCredentialTier? {
        ExtensionBrokeredCredentialTier(rawValue: credential)
    }

    public var errorDescription: String? { message }

    public init(message: String, credential: String) {
        self.message = message
        self.credential = credential
    }
}

/// The host-to-extension envelope: exactly one of `response` and `failure` is present.
public struct ExtensionBrokeredFetchResult: Codable, Equatable, Sendable {
    public static let currentProtocolVersion = 1

    public let protocolVersion: Int
    public let response: ExtensionBrokeredFetchResponse?
    public let failure: ExtensionBrokeredFetchFailure?

    public init(
        protocolVersion: Int = Self.currentProtocolVersion,
        response: ExtensionBrokeredFetchResponse? = nil,
        failure: ExtensionBrokeredFetchFailure? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.response = response
        self.failure = failure
    }
}
