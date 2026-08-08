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

    public init?(baseURL: URL, token: String) {
        guard let scheme = baseURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              baseURL.user == nil,
              baseURL.password == nil,
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        components?.query = nil
        components?.path = "/"
        components?.scheme = scheme
        let host = components?.host?.lowercased()
        components?.host = host
        guard let normalized = components?.url else { return nil }
        self.baseURL = normalized
        self.token = token
    }

    public init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.user == nil,
              url.password == nil,
              url.query == nil,
              let token = url.fragment?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            return nil
        }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        components?.path = "/"
        // Scheme and host are case-insensitive (RFC 3986 §3.1, §3.2.2), and the pairing code
        // deliberately writes them in upper case — see `scannablePayload`. Normalising here is
        // what makes that safe: every API URL is derived from `baseURL`, so an uppercase host
        // would otherwise reach the relay in a `Host:` header and an SNI name for the rest of
        // the session.
        components?.scheme = scheme
        let normalizedHost = components?.host?.lowercased()
        components?.host = normalizedHost
        guard let baseURL = components?.url else { return nil }

        self.baseURL = baseURL
        self.token = token
    }

    public init?(string: String) {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        self.init(url: url)
    }

    public var shareURL: URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.fragment = token
        return components.url!
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
    public var scannablePayload: String {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.scheme = baseURL.scheme?.uppercased()
        components?.host = baseURL.host?.uppercased()
        components?.fragment = token
        return components?.url?.absoluteString ?? shareURL.absoluteString
    }

    public var meURL: URL {
        baseURL.appendingPathComponent("api/me")
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

    public var invitationAcceptanceURL: URL {
        baseURL.appendingPathComponent("api/invitations/accept")
    }

    public func resumeURL(sessionID: String) -> URL {
        baseURL
            .appendingPathComponent("api/session")
            .appendingPathComponent(sessionID)
            .appendingPathComponent("resume")
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

    public func sessionSurfaceURL(sessionID: String) -> URL {
        sessionActionURL(sessionID: sessionID, action: "surface")
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

    private func sessionActionURL(sessionID: String, action: String) -> URL {
        baseURL
            .appendingPathComponent("api/session")
            .appendingPathComponent(sessionID)
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
