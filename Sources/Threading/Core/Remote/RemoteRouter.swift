import Foundation
import ThreadingRemoteKit

/// Classifies a remote request into a static asset, a WebSocket upgrade, an API call, or a
/// 404 — the `ExtensionHostService.route` shape: a **known-route allowlist first**, so an
/// unrecognised path is refused before any auth or dispatch logic runs.
///
/// The router itself serves only the self-contained web client (no data, no auth). Auth and the
/// `/api/me` main-queue hop are the server's job, because they need the store and the session
/// list; the router just says what kind of request this is.
struct RemoteRouter {

    let bundle: Bundle

    init(bundle: Bundle = .main) { self.bundle = bundle }

    // MARK: - Static assets

    /// The one page and its assets, keyed by request path. An allowlist rather than a directory
    /// walk: only these files are ever served, so a path-traversal attempt matches nothing.
    private struct Asset {
        let file: String
        let contentType: String
        let isDocument: Bool
    }

    private static let assets: [String: Asset] = [
        "/": Asset(file: "index.html", contentType: "text/html; charset=utf-8", isDocument: true),
        "/app.js": Asset(file: "app.js", contentType: "text/javascript; charset=utf-8", isDocument: false),
        "/app.css": Asset(file: "app.css", contentType: "text/css; charset=utf-8", isDocument: false),
        "/xterm.js": Asset(file: "xterm.js", contentType: "text/javascript; charset=utf-8", isDocument: false),
        "/xterm.css": Asset(file: "xterm.css", contentType: "text/css; charset=utf-8", isDocument: false),
    ]

    static let clientDirectory = "RemoteClient"

    /// A hardened static response for a known asset path, or nil if the path is not an asset.
    func staticResponse(forPath path: String) -> HTTPResponse? {
        guard let asset = Self.assets[path] else { return nil }
        guard let url = bundle.url(
            forResource: asset.file,
            withExtension: nil,
            subdirectory: Self.clientDirectory
        ), let data = try? Data(contentsOf: url) else {
            ThreadingLogger.remote.fault(
                "Remote client asset missing from the bundle: \(asset.file, privacy: .public)"
            )
            return Self.harden(HTTPResponse.status(404, "Not Found"), isDocument: false)
        }

        let response = HTTPResponse(status: 200, reason: "OK", contentType: asset.contentType, body: data)
        return Self.harden(response, isDocument: asset.isDocument)
    }

    // MARK: - Path classification

    /// Strips the query and fragment, leaving just the path for allowlist matching.
    static func normalizedPath(_ raw: String) -> String {
        var path = raw
        if let hash = path.firstIndex(of: "#") { path = String(path[path.startIndex..<hash]) }
        if let query = path.firstIndex(of: "?") { path = String(path[path.startIndex..<query]) }
        return path.isEmpty ? "/" : path
    }

    /// The session id for a `/ws/session/<id>` upgrade path, else nil.
    static func webSocketSessionID(forPath path: String) -> String? {
        let prefix = "/ws/session/"
        guard path.hasPrefix(prefix) else { return nil }
        let id = String(path.dropFirst(prefix.count))
        return id.isEmpty ? nil : id
    }

    /// The terminal id for a `/ws/terminal/<id>` upgrade path, else nil.
    static func webSocketTerminalID(forPath path: String) -> String? {
        let prefix = "/ws/terminal/"
        guard path.hasPrefix(prefix) else { return nil }
        let id = String(path.dropFirst(prefix.count))
        return id.isEmpty || id.contains("/") ? nil : id
    }

    static let apiSessionsPath = "/api/me"
    static let usagePath = "/api/usage"
    static let usageLimitPath = "/api/usage/limit"
    static let createSessionPath = "/api/session"
    static let notificationRegistrationPath = "/api/notifications"
    static let diagnosticUploadPath = "/api/diagnostics"
    static let invitationAcceptancePath = "/api/invitations/accept"
    static let hostedDeviceCredentialPath = "/api/hosted-device-credential"
    static let appThemePath = "/api/theme"
    private static let appSettingPrefix = "/api/settings/"
    static let themeEventsPath = "/ws/events"
    /// Stored in `RemoteConnection.routedSessionID` to avoid a second upgrade-state field.
    static let themeEventsRouteID = "__theme_events__"

    /// The session id in `/api/session/<id>/resume`, else nil.
    static func resumeSessionID(forPath path: String) -> String? {
        let prefix = "/api/session/"
        let suffix = "/resume"
        guard path.hasPrefix(prefix), path.hasSuffix(suffix) else { return nil }
        let id = path.dropFirst(prefix.count).dropLast(suffix.count)
        return id.isEmpty || id.contains("/") ? nil : String(id)
    }

    /// The terminal id in `/api/terminal/<id>/resume`, else nil.
    static func resumeTerminalID(forPath path: String) -> String? {
        terminalID(forPath: path, action: "resume")
    }

    static func shareTerminalID(forPath path: String) -> String? {
        terminalID(forPath: path, action: "share")
    }

    static func unshareTerminalID(forPath path: String) -> String? {
        terminalID(forPath: path, action: "unshare")
    }

    /// The session id in `/api/session/<id>/theme`, else nil.
    static func themeSessionID(forPath path: String) -> String? {
        let prefix = "/api/session/"
        let suffix = "/theme"
        guard path.hasPrefix(prefix), path.hasSuffix(suffix) else { return nil }
        let id = path.dropFirst(prefix.count).dropLast(suffix.count)
        return id.isEmpty || id.contains("/") ? nil : String(id)
    }

    /// The stable setting identity in `/api/settings/<identity>`, else nil. The identity is
    /// still authorized by its descriptor; this only keeps the route allowlist structural.
    static func appSettingIdentity(forPath path: String) -> String? {
        guard path.hasPrefix(appSettingPrefix) else { return nil }
        let identity = path.dropFirst(appSettingPrefix.count)
        return identity.isEmpty || identity.contains("/") ? nil : String(identity)
    }

    static func renameSessionID(forPath path: String) -> String? {
        sessionID(forPath: path, action: "rename")
    }

    static func pinnedSessionID(forPath path: String) -> String? {
        sessionID(forPath: path, action: "pinned")
    }

    static func archivedSessionID(forPath path: String) -> String? {
        sessionID(forPath: path, action: "archived")
    }

    static func snoozedSessionID(forPath path: String) -> String? {
        sessionID(forPath: path, action: "snoozed")
    }

    static func surfaceSessionID(forPath path: String) -> String? {
        sessionID(forPath: path, action: "surface")
    }

    static func accountSessionID(forPath path: String) -> String? {
        sessionID(forPath: path, action: "account")
    }

    static func limitRecoverySessionID(forPath path: String) -> String? {
        sessionID(forPath: path, action: "limit-recovery")
    }

    static func shareSessionID(forPath path: String) -> String? {
        sessionID(forPath: path, action: "share")
    }

    static func unshareSessionID(forPath path: String) -> String? {
        sessionID(forPath: path, action: "unshare")
    }

    struct GitReviewRoute: Equatable {
        let sessionID: String
        let mode: RemoteGitReviewMode
    }

    static func gitReviewRoute(forPath path: String) -> GitReviewRoute? {
        let prefix = "/api/session/"
        let marker = "/git-review/"
        guard path.hasPrefix(prefix),
              let markerRange = path.range(of: marker, options: .backwards) else {
            return nil
        }
        let id = String(path[path.index(path.startIndex, offsetBy: prefix.count)..<markerRange.lowerBound])
        let rawMode = String(path[markerRange.upperBound...])
        guard !id.isEmpty, !id.contains("/"),
              !rawMode.isEmpty, !rawMode.contains("/"),
              let mode = RemoteGitReviewMode(rawValue: rawMode) else {
            return nil
        }
        return GitReviewRoute(sessionID: id, mode: mode)
    }

    static func repositoryFilesSessionID(forPath path: String) -> String? {
        sessionID(forPath: path, action: "repository-files")
    }

    static func repositoryFileSessionID(forPath path: String) -> String? {
        sessionID(forPath: path, action: "repository-file")
    }

    static func attachmentsSessionID(forPath path: String) -> String? {
        sessionID(forPath: path, action: "attachments")
    }

    static func attachmentSessionID(forPath path: String) -> String? {
        sessionID(forPath: path, action: "attachment")
    }

    static func attachmentUploadSessionID(forPath path: String) -> String? {
        sessionID(forPath: path, action: "attachment-upload")
    }

    static func workspaceSessionID(forPath path: String) -> String? {
        sessionID(forPath: path, action: "workspace")
    }

    static func browserPreviewSessionID(forPath path: String) -> String? {
        sessionID(forPath: path, action: "browser-preview")
    }

    static func extensionPanelSessionID(forPath path: String) -> String? {
        sessionID(forPath: path, action: "extension-panel")
    }

    static func extensionPanelResourceSessionID(forPath path: String) -> String? {
        sessionID(forPath: path, action: "extension-panel-resource")
    }

    static func queryValue(named name: String, in rawPath: String) -> String? {
        guard var components = URLComponents(string: rawPath) else { return nil }
        // A request target is commonly relative, while URLComponents is most predictable
        // against an absolute URL. Retry with a throwaway origin if needed.
        if components.queryItems == nil {
            components = URLComponents(string: "http://localhost" + rawPath) ?? components
        }
        return components.queryItems?.first(where: { $0.name == name })?.value
    }

    private static func sessionID(forPath path: String, action: String) -> String? {
        let prefix = "/api/session/"
        let suffix = "/\(action)"
        guard path.hasPrefix(prefix), path.hasSuffix(suffix) else { return nil }
        let id = path.dropFirst(prefix.count).dropLast(suffix.count)
        return id.isEmpty || id.contains("/") ? nil : String(id)
    }

    private static func terminalID(forPath path: String, action: String) -> String? {
        let prefix = "/api/terminal/"
        let suffix = "/\(action)"
        guard path.hasPrefix(prefix), path.hasSuffix(suffix) else { return nil }
        let id = path.dropFirst(prefix.count).dropLast(suffix.count)
        return id.isEmpty || id.contains("/") ? nil : String(id)
    }

    // MARK: - Hardening

    /// The bearer token from an `Authorization: Bearer …` header, or nil.
    static func bearerToken(from request: HTTPRequest) -> String? {
        guard let header = request.header("authorization"),
              let separator = header.firstIndex(of: " "),
              String(header[..<separator]).caseInsensitiveCompare("Bearer") == .orderedSame else {
            return nil
        }
        let token = String(header[header.index(after: separator)...])
            .trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : token
    }

    static let deviceHeader = "x-threading-device"
    static let clientHeader = "x-threading-client"
    static let requestIDHeader = "x-threading-request-id"

    /// Headers a client uses to declare the protocol version pair it speaks, so the server can
    /// answer a mismatch with a clear "please update" rather than a broken response.
    static let protocolHeader = "x-threading-protocol"
    static let protocolMinimumHeader = "x-threading-protocol-min"

    /// Applies the headers that matter for a server behind a public tunnel: no sniffing, no
    /// framing, no referrer leakage, and — for the page itself — a restrictive CSP that keeps
    /// scripts to same-origin files (no inline script) while allowing the styles xterm.js sets.
    static func harden(_ response: HTTPResponse, isDocument: Bool) -> HTTPResponse {
        var headers = response.extraHeaders
        headers["X-Content-Type-Options"] = "nosniff"
        headers["X-Frame-Options"] = "DENY"
        headers["Referrer-Policy"] = "no-referrer"
        // Session titles and project names are private, and the client has unversioned asset
        // URLs. Never leave either in a shared browser cache; a reload must also fetch the
        // client that matches the server's protocol.
        headers["Cache-Control"] = "no-store"
        if isDocument {
            headers["Content-Security-Policy"] = [
                "default-src 'self'",
                "script-src 'self'",
                "style-src 'self' 'unsafe-inline'",
                "connect-src 'self'",
                "img-src 'self' data:",
                "base-uri 'none'",
                "frame-ancestors 'none'",
            ].joined(separator: "; ")
        }
        var hardened = response
        hardened.extraHeaders = headers
        return hardened
    }

    static func json<Value: Encodable>(
        _ value: Value,
        status: Int = 200,
        reason: String = "OK",
        maximumBytes: Int? = nil
    ) -> HTTPResponse {
        let body: Data
        do {
            body = try JSONEncoder().encode(value)
        } catch {
            ThreadingLogger.remote.error(
                "Remote JSON response encoding failed: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            return harden(
                HTTPResponse(
                    status: 500,
                    reason: "Internal Server Error",
                    contentType: "application/json",
                    body: Data(#"{"error":"Response encoding failed."}"#.utf8)
                ),
                isDocument: false
            )
        }
        if let maximumBytes, body.count > maximumBytes {
            ThreadingLogger.remote.error(
                "Remote JSON response exceeded its encoded ceiling bytes=\(body.count, privacy: .public) maximum=\(maximumBytes, privacy: .public)"
            )
            return error(503, "Response Too Large")
        }
        return harden(
            HTTPResponse(status: status, reason: reason, contentType: "application/json", body: body),
            isDocument: false
        )
    }

    static func data(_ body: Data, contentType: String) -> HTTPResponse {
        var response = HTTPResponse(
            status: 200,
            reason: "OK",
            contentType: contentType,
            body: body
        )
        // A visual file can be much larger than the live WebSocket backlog ceiling. Send it as
        // one bounded HTTP response and retire this connection after the body is processed.
        response.closesConnection = true
        return harden(response, isDocument: false)
    }

    static func error(_ status: Int, _ reason: String) -> HTTPResponse {
        harden(HTTPResponse.status(status, reason), isDocument: false)
    }
}
