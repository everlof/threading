import Foundation

/// Maps the MCP endpoints handed to agents back to the sessions that own them.
///
/// Each session gets a private URL whose path carries an unguessable token, so a tool call
/// arriving over the socket identifies its session by construction. Nothing has to be inferred
/// from the process, and two sessions of the same project cannot be confused for each other.
///
/// The token is the only thing guarding the endpoint. That is sufficient because the listener
/// binds loopback, so reaching it already requires local code execution — but it is why the
/// token must not be derived from the session identifier, which is written to disk in
/// `projects.json`.
enum MCPSessionRegistry {

    // MARK: - Properties

    private static var tokensBySession: [UUID: String] = [:]
    private static var sessionsByToken: [String: UUID] = [:]

    // MARK: - Public Methods

    /// The token for a session, minted on first use and stable for the app's lifetime.
    static func token(for sessionID: UUID) -> String {
        if let existing = tokensBySession[sessionID] { return existing }

        let token = UUID().uuidString.lowercased()
        tokensBySession[sessionID] = token
        sessionsByToken[token] = sessionID
        return token
    }

    /// The session a request path belongs to, or nil if the token is unknown.
    static func session(forToken token: String) -> UUID? {
        sessionsByToken[token]
    }

    /// The Streamable HTTP endpoint for a session.
    ///
    /// Codex accepts this URL directly as a one-off `mcp_servers` config override. Claude's
    /// CLI expects the same URL inside a JSON file, which `writeConfiguration` creates below.
    /// Returns nil when the server is not listening, which leaves the launch to proceed
    /// without MCP rather than failing outright.
    static func endpointURL(for sessionID: UUID) -> String? {
        guard let port = MCPServer.shared.port else { return nil }

        return "http://\(MCPDefaults.host):\(port)\(MCPDefaults.pathPrefix)\(token(for: sessionID))"
    }

    /// Writes the Claude `--mcp-config` file for a session and returns its path.
    ///
    /// Returns nil when the server is not listening, which leaves the launch to proceed
    /// without MCP rather than failing outright.
    static func writeConfiguration(for sessionID: UUID) -> String? {
        guard let url = endpointURL(for: sessionID) else { return nil }

        let configuration: [String: Any] = [
            "mcpServers": [
                MCPDefaults.serverName: [
                    "type": "http",
                    "url": url
                ]
            ]
        ]

        let file = configurationFile(for: sessionID)

        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONSerialization.data(withJSONObject: configuration, options: [])
            try data.write(to: file, options: .atomic)
            return file.path
        } catch {
            SkalmanLogger.mcp.error("Failed to write MCP config for \(sessionID): \(error)")
            return nil
        }
    }

    /// Writes the `--settings` file that routes a headless session's tool calls back here for
    /// approval, and returns its path.
    ///
    /// The hook is a bare `curl`: it reads the request from stdin, posts it, and writes the
    /// reply to stdout, which is exactly the contract a `PreToolUse` command hook expects. No
    /// helper script has to be installed or kept in step with the app.
    ///
    /// `--max-time` is generous because the pause is a human reading a dialog. When it does
    /// expire, curl writes nothing, and a hook that says nothing leaves the tool blocked —
    /// the safe direction to fail.
    static func writePermissionSettings(for sessionID: UUID) -> String? {
        guard let port = MCPServer.shared.port else { return nil }

        let url = "http://\(MCPDefaults.host):\(port)"
            + "\(MCPDefaults.permissionPathPrefix)\(token(for: sessionID))"

        let command = "curl -s --max-time \(Int(MCPDefaults.permissionTimeout))"
            + " -H 'Content-Type: application/json' --data-binary @- \(url)"

        let settings: [String: Any] = [
            "hooks": [
                "PreToolUse": [
                    // No matcher: every tool is offered, and `PermissionPolicy` decides which
                    // are worth interrupting for. Policy in Swift beats policy in a glob.
                    ["hooks": [["type": "command", "command": command]]]
                ]
            ]
        ]

        let file = settingsFile(for: sessionID)

        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONSerialization.data(withJSONObject: settings, options: [])
            try data.write(to: file, options: .atomic)
            return file.path
        } catch {
            SkalmanLogger.mcp.error("Failed to write permission settings for \(sessionID): \(error)")
            return nil
        }
    }

    /// Revokes the endpoints of every session not in the given set.
    ///
    /// Called when sessions are deleted, so a token cannot outlive the session it addressed
    /// and go on reaching a panel for something the user removed.
    static func retainOnly(sessionIDs: Set<UUID>) {
        for (sessionID, token) in tokensBySession where !sessionIDs.contains(sessionID) {
            tokensBySession.removeValue(forKey: sessionID)
            sessionsByToken.removeValue(forKey: token)

            for directory in MCPDefaults.cleanupDirectories {
                try? FileManager.default.removeItem(at: supportFile(sessionID, in: directory))
            }

            PermissionBroker.discard(sessionID: sessionID)
        }
    }

    // MARK: - Private Methods

    private static func configurationFile(for sessionID: UUID) -> URL {
        supportFile(sessionID, in: MCPDefaults.configDirectoryName)
    }

    private static func settingsFile(for sessionID: UUID) -> URL {
        supportFile(sessionID, in: MCPDefaults.settingsDirectoryName)
    }

    private static func supportFile(_ sessionID: UUID, in directory: String) -> URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]

        return appSupport
            .appendingPathComponent("Skalman", isDirectory: true)
            .appendingPathComponent(directory, isDirectory: true)
            .appendingPathComponent(sessionID.uuidString)
            .appendingPathExtension(MCPDefaults.configFileExtension)
    }
}
