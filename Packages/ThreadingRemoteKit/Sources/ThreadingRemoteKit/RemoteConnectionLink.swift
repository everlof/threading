import Foundation

/// A paired remote door, split into the origin used on the wire and the bearer kept out of
/// requests until the client deliberately authenticates.
///
/// Share links carry the bearer in the URL fragment. Fragments are not sent in HTTP requests,
/// proxy logs, or referrers, which lets the same link open in a browser and pair the iOS app
/// without leaking the capability during the initial page load.
public struct RemoteConnectionLink: Codable, Equatable, Hashable, Sendable {
    public let baseURL: URL
    public let token: String
    public let shareURL: URL
    /// The Mac's certificate fingerprint as it travels in a pairing code: the first 128 bits of
    /// the SHA-256, base32 upper case, exactly 26 characters. Nil for an origin whose TLS
    /// somebody else terminates, and for every link written before this existed.
    public let pinnedFingerprintCode: String?

    private enum CodingKeys: String, CodingKey {
        case baseURL
        case token
        case pinnedFingerprintCode
    }

    /// The fragment separator between the bearer and the fingerprint.
    ///
    /// `.` is unambiguous: pairing tokens are base32 `A-Z2-7`, bearers are base64url, and neither
    /// alphabet contains it. It is also one of QR's alphanumeric characters, so carrying it costs
    /// no mode switch.
    private static let fingerprintSeparator: Character = "."

    public init?(baseURL: URL, token: String, pinnedFingerprintCode: String? = nil) {
        let normalizedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let scheme = baseURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = baseURL.host?.lowercased(),
              !host.isEmpty,
              baseURL.user == nil,
              baseURL.password == nil,
              !normalizedToken.isEmpty,
              !normalizedToken.contains(Self.fingerprintSeparator) else {
            return nil
        }
        let normalizedCode: String?
        if let pinnedFingerprintCode {
            let candidate = pinnedFingerprintCode.trimmingCharacters(in: .whitespacesAndNewlines)
            // A fingerprint that is not a fingerprint is refused rather than dropped: pairing
            // without the pin would silently produce a client that trusts whatever answers.
            guard RemoteHostPin(pairingCode: candidate) != nil else { return nil }
            normalizedCode = candidate
        } else {
            normalizedCode = nil
        }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        components?.query = nil
        components?.path = "/"
        components?.scheme = scheme
        components?.host = Self.urlHost(host)
        guard let normalized = components?.url,
              let shareURL = Self.makeShareURL(
                  baseURL: normalized,
                  token: normalizedToken,
                  pinnedFingerprintCode: normalizedCode
              ) else {
            return nil
        }
        self.baseURL = normalized
        self.token = normalizedToken
        self.shareURL = shareURL
        self.pinnedFingerprintCode = normalizedCode
    }

    public init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(),
              !host.isEmpty,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              let fragment = url.fragment?.trimmingCharacters(in: .whitespacesAndNewlines),
              !fragment.isEmpty else {
            return nil
        }

        // Two forms, and both have to parse: `#<token>` is every code produced before the
        // listener had an identity to pin, and `#<token>.<fingerprint>` is what a pinned door
        // writes. The split is on the separator rather than on a length, so a code from a host
        // that changes either half still reads.
        let parts = fragment.split(separator: Self.fingerprintSeparator, omittingEmptySubsequences: false)
        let token: String
        let fingerprintCode: String?
        switch parts.count {
        case 1:
            token = String(parts[0])
            fingerprintCode = nil
        case 2:
            token = String(parts[0])
            fingerprintCode = String(parts[1])
        default:
            return nil
        }
        guard !token.isEmpty else { return nil }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        components?.path = "/"
        // Scheme and host are case-insensitive (RFC 3986 §3.1, §3.2.2), and the pairing code
        // deliberately writes them in upper case — see `scannablePayload`. Normalising here is
        // what makes that safe: every API URL is derived from `baseURL`, so an uppercase host
        // would otherwise reach the relay in a `Host:` header and an SNI name for the rest of
        // the session.
        components?.scheme = scheme
        components?.host = Self.urlHost(host)
        guard let baseURL = components?.url else { return nil }

        if let fingerprintCode, RemoteHostPin(pairingCode: fingerprintCode) == nil { return nil }
        guard let shareURL = Self.makeShareURL(
            baseURL: baseURL,
            token: token,
            pinnedFingerprintCode: fingerprintCode
        ) else { return nil }
        self.baseURL = baseURL
        self.token = token
        self.shareURL = shareURL
        self.pinnedFingerprintCode = fingerprintCode
    }

    public init?(string: String) {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        self.init(url: url)
    }

    /// An IPv6 literal has to keep its brackets.
    ///
    /// `URL.host` hands back `::1` with the brackets stripped, and `URLComponents` refuses to
    /// build a URL from that, so normalising the case of a host — which is what makes the QR
    /// payload cheap — silently turned every IPv6 origin into no link at all. A LAN door
    /// advertises whatever addresses the Mac holds, and on a dual-stack network half of those
    /// are IPv6.
    private static func urlHost(_ host: String) -> String {
        guard host.contains(":"), !host.hasPrefix("[") else { return host }
        return "[\(host)]"
    }

    private static func makeShareURL(
        baseURL: URL,
        token: String,
        pinnedFingerprintCode: String?
    ) -> URL? {
        guard var components = URLComponents(
            url: baseURL,
            resolvingAgainstBaseURL: false
        ) else { return nil }
        components.fragment = Self.fragment(token: token, pinnedFingerprintCode: pinnedFingerprintCode)
        return components.url
    }

    private static func fragment(token: String, pinnedFingerprintCode: String?) -> String {
        guard let pinnedFingerprintCode else { return token }
        return "\(token)\(fingerprintSeparator)\(pinnedFingerprintCode)"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedBaseURL = try container.decode(URL.self, forKey: .baseURL)
        let decodedToken = try container.decode(String.self, forKey: .token)
        let decodedCode = try container.decodeIfPresent(String.self, forKey: .pinnedFingerprintCode)
        guard let validated = Self(
            baseURL: decodedBaseURL,
            token: decodedToken,
            pinnedFingerprintCode: decodedCode
        ) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Remote connection link has an invalid origin or bearer token."
            ))
        }
        self = validated
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encode(token, forKey: .token)
        try container.encodeIfPresent(pinnedFingerprintCode, forKey: .pinnedFingerprintCode)
    }

    /// The same credential, written for a QR code.
    ///
    /// QR has an *alphanumeric* encoding mode worth 5.5 bits per character against byte mode's
    /// 8, but its charset is only `0-9 A-Z` and nine punctuation marks — no lower case. Scheme
    /// and host are case-insensitive, so writing them upper case moves the longest run of the
    /// payload into that mode for free. `RemoteConnectionLink(string:)` lower-cases them again
    /// on the way back in, which is what keeps it free.
    ///
    /// Measured against a median 52-character `trycloudflare.com` host, at correction level M:
    /// 41 modules for the lower-case form with a 43-character base64url token, 37 once this is
    /// combined with a base32 pairing token. The token has to hold up its end — a base64url one
    /// is mixed-case and forces a byte-mode segment of its own, which is why shortening the
    /// token and upper-casing the origin only pay off together.
    ///
    /// The `#` cannot be avoided: it is absent from the alphanumeric charset, so it costs a
    /// mode switch either way. Keeping the bearer in the fragment — where no HTTP request,
    /// proxy log, or referrer carries it — is worth far more than the ~33 bits that costs.
    /// A pinned door adds `.<fingerprint>` to the fragment. Both halves are base32 upper case
    /// and the separator is alphanumeric-mode too, so the addition costs 26 characters in the
    /// same segment rather than a mode switch. An older client reads the whole fragment as one
    /// bearer, is refused with a 401, and says so; it cannot silently connect unpinned.
    public var scannablePayload: String {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.scheme = baseURL.scheme?.uppercased()
        components?.host = baseURL.host.map { Self.urlHost($0.uppercased()) }
        components?.fragment = Self.fragment(
            token: token,
            pinnedFingerprintCode: pinnedFingerprintCode
        )
        return components?.url?.absoluteString ?? shareURL.absoluteString
    }

    public var meURL: URL {
        baseURL.appendingPathComponent("api/me")
    }

    public var usageURL: URL {
        baseURL.appendingPathComponent("api/usage")
    }

    public func usageURL(cursor: String?, limit: Int? = nil) -> URL {
        var components = URLComponents(url: usageURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            cursor.map { URLQueryItem(name: "cursor", value: $0) },
            limit.map { URLQueryItem(name: "limit", value: String($0)) },
        ].compactMap { $0 }
        return components?.url ?? usageURL
    }

    public func usageLimitURL(seriesID: String, days: Int) -> URL {
        let endpoint = usageURL.appendingPathComponent("limit")
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "series", value: seriesID),
            URLQueryItem(name: "days", value: String(days)),
        ]
        return components?.url ?? endpoint
    }

    public var appThemeURL: URL {
        baseURL.appendingPathComponent("api/theme")
    }

    public var createSessionURL: URL {
        baseURL.appendingPathComponent("api/session")
    }

    public var notificationRegistrationURL: URL {
        baseURL.appendingPathComponent("api/notifications")
    }

    public var diagnosticUploadURL: URL {
        baseURL.appendingPathComponent("api/diagnostics")
    }

    public var mobileDiagnosticsCaptureUploadURL: URL {
        baseURL.appendingPathComponent("api/local-diagnostics/capture")
    }

    public var invitationAcceptanceURL: URL {
        baseURL.appendingPathComponent("api/invitations/accept")
    }

    public var hostedDeviceCredentialURL: URL {
        baseURL.appendingPathComponent("api/hosted-device-credential")
    }

    public func resumeURL(sessionID: String) -> URL {
        baseURL
            .appendingPathComponent("api/session")
            .appendingPathComponent(sessionID)
            .appendingPathComponent("resume")
    }

    public func resumeTerminalURL(terminalID: String) -> URL {
        terminalActionURL(terminalID: terminalID, action: "resume")
    }

    public func terminalShareURL(terminalID: String) -> URL {
        terminalActionURL(terminalID: terminalID, action: "share")
    }

    public func terminalUnshareURL(terminalID: String) -> URL {
        terminalActionURL(terminalID: terminalID, action: "unshare")
    }

    public func sessionThemeURL(sessionID: String) -> URL {
        baseURL
            .appendingPathComponent("api/session")
            .appendingPathComponent(sessionID)
            .appendingPathComponent("theme")
    }

    public func renameSessionURL(sessionID: String) -> URL {
        sessionActionURL(sessionID: sessionID, action: "rename")
    }

    public func pinnedSessionURL(sessionID: String) -> URL {
        sessionActionURL(sessionID: sessionID, action: "pinned")
    }

    public func archivedSessionURL(sessionID: String) -> URL {
        sessionActionURL(sessionID: sessionID, action: "archived")
    }

    public func snoozedSessionURL(sessionID: String) -> URL {
        sessionActionURL(sessionID: sessionID, action: "snoozed")
    }

    public func sessionSurfaceURL(sessionID: String) -> URL {
        sessionActionURL(sessionID: sessionID, action: "surface")
    }

    public func sessionAccountURL(sessionID: String) -> URL {
        sessionActionURL(sessionID: sessionID, action: "account")
    }

    public func sessionLimitRecoveryURL(sessionID: String) -> URL {
        sessionActionURL(sessionID: sessionID, action: "limit-recovery")
    }

    public func sessionShareURL(sessionID: String) -> URL {
        sessionActionURL(sessionID: sessionID, action: "share")
    }

    public func sessionUnshareURL(sessionID: String) -> URL {
        sessionActionURL(sessionID: sessionID, action: "unshare")
    }

    public func gitReviewURL(sessionID: String, mode: RemoteGitReviewMode) -> URL {
        sessionActionURL(sessionID: sessionID, action: "git-review")
            .appendingPathComponent(mode.rawValue)
    }

    public func repositoryFilesURL(sessionID: String) -> URL {
        sessionActionURL(sessionID: sessionID, action: "repository-files")
    }

    public func repositoryFileURL(sessionID: String, path: String) -> URL? {
        var components = URLComponents(
            url: sessionActionURL(sessionID: sessionID, action: "repository-file"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "path", value: path)]
        return components?.url
    }

    public func attachmentsURL(sessionID: String) -> URL {
        sessionActionURL(sessionID: sessionID, action: "attachments")
    }

    public func attachmentURL(sessionID: String, id: String) -> URL? {
        var components = URLComponents(
            url: sessionActionURL(sessionID: sessionID, action: "attachment"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "id", value: id)]
        return components?.url
    }

    /// Where a composing client hands over file bytes before naming them in a prompt.
    public func attachmentUploadURL(sessionID: String) -> URL {
        sessionActionURL(sessionID: sessionID, action: "attachment-upload")
    }

    public func workspaceURL(sessionID: String) -> URL {
        sessionActionURL(sessionID: sessionID, action: "workspace")
    }

    public func browserPreviewURL(sessionID: String, tabID: String) -> URL? {
        var components = URLComponents(
            url: sessionActionURL(sessionID: sessionID, action: "browser-preview"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "tab", value: tabID)]
        return components?.url
    }

    public func extensionPanelURL(
        sessionID: String,
        extensionIdentifier: String,
        panelID: String
    ) -> URL? {
        var components = URLComponents(
            url: sessionActionURL(sessionID: sessionID, action: "extension-panel"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "extension", value: extensionIdentifier),
            URLQueryItem(name: "panel", value: panelID),
        ]
        return components?.url
    }

    public func extensionPanelResourceURL(
        sessionID: String,
        extensionIdentifier: String,
        panelID: String,
        path: String
    ) -> URL? {
        var components = URLComponents(
            url: sessionActionURL(sessionID: sessionID, action: "extension-panel-resource"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "extension", value: extensionIdentifier),
            URLQueryItem(name: "panel", value: panelID),
            URLQueryItem(name: "path", value: path),
        ]
        return components?.url
    }

    public var eventsWebSocketURL: URL? {
        webSocketURL(pathComponents: ["ws", "events"])
    }

    public func webSocketURL(sessionID: String) -> URL? {
        webSocketURL(pathComponents: ["ws", "session", sessionID])
    }

    public func terminalWebSocketURL(terminalID: String) -> URL? {
        webSocketURL(pathComponents: ["ws", "terminal", terminalID])
    }

    private func sessionActionURL(sessionID: String, action: String) -> URL {
        baseURL
            .appendingPathComponent("api/session")
            .appendingPathComponent(sessionID)
            .appendingPathComponent(action)
    }

    private func terminalActionURL(terminalID: String, action: String) -> URL {
        baseURL
            .appendingPathComponent("api/terminal")
            .appendingPathComponent(terminalID)
            .appendingPathComponent(action)
    }

    private func webSocketURL(pathComponents: [String]) -> URL? {
        let url = pathComponents.reduce(baseURL) { partial, component in
            partial.appendingPathComponent(component)
        }
        var components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        )
        components?.scheme = baseURL.scheme?.lowercased() == "https" ? "wss" : "ws"
        return components?.url
    }
}
