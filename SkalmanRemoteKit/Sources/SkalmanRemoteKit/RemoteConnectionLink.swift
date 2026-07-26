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

    public func attachmentURL(sessionID: String, path: String) -> URL? {
        var components = URLComponents(
            url: sessionActionURL(sessionID: sessionID, action: "attachment"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "path", value: path)]
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
