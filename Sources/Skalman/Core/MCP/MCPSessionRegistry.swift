import Foundation
import os

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

    private struct Storage {
        var tokensBySession: [SessionID: String] = [:]
        var sessionsByToken: [String: SessionID] = [:]
    }

    /// Launch and deletion happen on main while requests resolve tokens on the MCP queue.
    /// Both maps form one bidirectional invariant, so they share a single lock and mutation.
    private static let storage = OSAllocatedUnfairLock(initialState: Storage())

    // MARK: - Public Methods

    /// The token for a session, minted on first use and stable for the app's lifetime.
    static func token(for sessionID: SessionID) -> String {
        storage.withLock { storage in
            if let existing = storage.tokensBySession[sessionID] { return existing }

            let token = UUID().uuidString.lowercased()
            storage.tokensBySession[sessionID] = token
            storage.sessionsByToken[token] = sessionID
            return token
        }
    }

    /// The session a request path belongs to, or nil if the token is unknown.
    static func session(forToken token: String) -> SessionID? {
        storage.withLock { $0.sessionsByToken[token] }
    }

    /// The Streamable HTTP endpoint for a session.
    ///
    /// Codex accepts this URL directly as a one-off `mcp_servers` config override. Claude's
    /// CLI expects the same URL inside a JSON file, which `writeConfiguration` creates below.
    /// Returns nil when the server is not listening, which leaves the launch to proceed
    /// without MCP rather than failing outright.
    static func endpointURL(for sessionID: SessionID) -> String? {
        guard let port = MCPServer.shared.port else { return nil }

        return "http://\(MCPDefaults.host):\(port)\(MCPDefaults.pathPrefix)\(token(for: sessionID))"
    }

    /// Writes the Claude `--mcp-config` file for a session and returns its path.
    ///
    /// Returns nil when the server is not listening, which leaves the launch to proceed
    /// without MCP rather than failing outright.
    static func writeConfiguration(for sessionID: SessionID) -> String? {
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

    /// Writes the `--settings` file wiring a Claude session's hooks back to this app, and
    /// returns its path.
    ///
    /// Each hook is a bare `curl`: it reads the event from stdin, posts it, and writes whatever
    /// comes back to stdout, which is exactly the contract a command hook expects. No helper
    /// script has to be installed or kept in step with the app.
    ///
    /// `brokersPermissions` separates the two surfaces. A terminal session asks the user
    /// through the CLI's own prompt and must not be intercepted; a headless one has nowhere to
    /// ask and would silently block instead. Lifecycle hooks are written either way, because
    /// knowing when a turn starts and ends is worth as much to a terminal session as to a
    /// rendered one — more, since a terminal has no stream to infer it from.
    static func writeHookSettings(
        for sessionID: SessionID,
        brokersPermissions: Bool
    ) -> String? {
        guard let port = MCPServer.shared.port else { return nil }

        let base = "http://\(MCPDefaults.host):\(port)"
        let token = token(for: sessionID)

        var hooks: [String: Any] = [:]

        if brokersPermissions {
            let url = "\(base)\(MCPDefaults.permissionPathPrefix)\(token)"
            let command = "curl -s --max-time \(Int(MCPDefaults.permissionTimeout))"
                + " -H 'Content-Type: application/json' --data-binary @- \(url)"

            // No matcher: every tool is offered, and `PermissionPolicy` decides which are
            // worth interrupting for. Policy in Swift beats policy in a glob.
            hooks["PreToolUse"] = [["hooks": [["type": "command", "command": command]]]]
        }

        for event in HookLifecycleEvent.allCases {
            let url = "\(base)\(MCPDefaults.lifecyclePathPrefix)\(token)"
                + "?\(MCPDefaults.lifecycleEventParameter)=\(event.rawValue)"

            // Output is discarded and failure is swallowed, which is load-bearing rather than
            // tidy. Claude feeds a `UserPromptSubmit` hook's stdout back to the model as extra
            // context and treats a non-zero `Stop` hook as a reason to keep going — so a
            // lifecycle report that leaked either would change the conversation it is only
            // supposed to observe.
            let command = "curl -s --max-time \(Int(MCPDefaults.lifecycleTimeout))"
                + " -H 'Content-Type: application/json' --data-binary @- \(url)"
                + " >/dev/null 2>&1 || true"

            hooks[event.claudeEventName] = [
                ["hooks": [["type": "command", "command": command]]]
            ]
        }

        let settings: [String: Any] = ["hooks": hooks]

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
            SkalmanLogger.mcp.error("Failed to write hook settings for \(sessionID): \(error)")
            return nil
        }
    }

    /// Revokes the endpoints of every session not in the given set.
    ///
    /// Called when sessions are deleted, so a token cannot outlive the session it addressed
    /// and go on reaching a panel for something the user removed.
    @MainActor
    static func retainOnly(sessionIDs: Set<SessionID>) {
        let removedSessionIDs = storage.withLock { storage in
            let removed = storage.tokensBySession.keys.filter { !sessionIDs.contains($0) }

            for sessionID in removed {
                guard let token = storage.tokensBySession.removeValue(forKey: sessionID) else {
                    continue
                }
                storage.sessionsByToken.removeValue(forKey: token)
            }

            return removed
        }

        // Disk cleanup and permission cancellation can call into other subsystems. Keeping them
        // outside the registry lock prevents unrelated work from extending the critical section.
        for sessionID in removedSessionIDs {
            for directory in MCPDefaults.cleanupDirectories {
                try? FileManager.default.removeItem(at: supportFile(sessionID, in: directory))
            }

            PermissionBroker.discard(sessionID: sessionID)
        }
    }

    // MARK: - Private Methods

    private static func configurationFile(for sessionID: SessionID) -> URL {
        supportFile(sessionID, in: MCPDefaults.configDirectoryName)
    }

    private static func settingsFile(for sessionID: SessionID) -> URL {
        supportFile(sessionID, in: MCPDefaults.settingsDirectoryName)
    }

    private static func supportFile(_ sessionID: SessionID, in directory: String) -> URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]

        return appSupport
            .appendingPathComponent("Skalman", isDirectory: true)
            .appendingPathComponent(directory, isDirectory: true)
            .appendingPathComponent(sessionID.uuidString)
            .appendingPathExtension(MCPDefaults.configFileExtension)
    }
}
