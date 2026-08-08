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
        /// Scopes of the ad-hoc endpoints — synthetic sessions belonging to helper runs, not
        /// to `ProjectStore`. Membership here is also what exempts an id from `retainOnly`.
        var adHocScopesBySession: [SessionID: [String]] = [:]
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

    /// Mints an endpoint for a short-lived helper run, restricted to the named tools.
    ///
    /// The returned id is synthetic — it exists in this registry and nowhere else. The server
    /// consults its scope for `tools/list`, admission and instructions, so the helper is
    /// advertised exactly the tools it was launched for and nothing of the session surface.
    /// Ad-hoc ids survive `retainOnly` (they are not `ProjectStore`'s to retain) and are
    /// instead revoked explicitly by `endAdHoc` when the run finishes.
    static func beginAdHoc(allowedTools: [String]) -> SessionID {
        let sessionID = SessionID()
        storage.withLock { storage in
            storage.adHocScopesBySession[sessionID] = allowedTools
            let token = UUID().uuidString.lowercased()
            storage.tokensBySession[sessionID] = token
            storage.sessionsByToken[token] = sessionID
        }
        return sessionID
    }

    /// The tool scope of an ad-hoc endpoint, or nil for an ordinary session.
    static func adHocScope(for sessionID: SessionID) -> [String]? {
        storage.withLock { $0.adHocScopesBySession[sessionID] }
    }

    /// Revokes an ad-hoc endpoint and removes any launch files written for it.
    static func endAdHoc(_ sessionID: SessionID) {
        let wasAdHoc: Bool = storage.withLock { storage in
            guard storage.adHocScopesBySession.removeValue(forKey: sessionID) != nil else {
                return false
            }
            if let token = storage.tokensBySession.removeValue(forKey: sessionID) {
                storage.sessionsByToken.removeValue(forKey: token)
            }
            return true
        }
        guard wasAdHoc else { return }

        for directory in MCPDefaults.cleanupDirectories {
            try? FileManager.default.removeItem(at: supportFile(sessionID, in: directory))
        }
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
            ThreadingLogger.mcp.error("Failed to write MCP config for \(sessionID): \(error)")
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
    /// `brokersPermissions` and `reportsLifecycle` are deliberately separate. A terminal
    /// session asks the user through the CLI's own prompt and must not be intercepted; a
    /// headless one has nowhere to ask and would silently block instead. Lifecycle hooks are
    /// observational and user-optional on either surface. When both are false and none of the
    /// settings-layer overrides is present, no settings file is written at all.
    ///
    /// `remoteControl` is not a hook at all: it is Claude's own `remoteControlAtStartup`,
    /// carried here because this is already the settings file the session launches with, and a
    /// settings file outranks the CLI's global config. Nil writes no key, which is how a
    /// session defers to `claude /config` rather than overriding it. Because both Claude launch
    /// paths rewrite this file, the choice is re-applied on every resume rather than only on the
    /// launch that made it.
    ///
    /// `fastMode` follows the same precedence rule. It is present for both terminal and Native
    /// Claude launches when Threading chose Standard or Fast, and absent when speed belongs to
    /// the account's own settings.
    static func writeHookSettings(
        for sessionID: SessionID,
        brokersPermissions: Bool,
        reportsLifecycle: Bool,
        remoteControl: Bool? = nil,
        fastMode: Bool? = nil,
        statusLineOverride: String? = nil,
        listenerPort: UInt16? = MCPServer.shared.port
    ) -> String? {
        let port = listenerPort
        let needsListener = brokersPermissions || reportsLifecycle

        if needsListener, port == nil {
            // Silent otherwise, and total: no port means no hooks, so the session falls back to
            // inferring its state from output and — if it is a rendered one — to having its
            // tools blocked outright with no card to approve them.
            ThreadingLogger.mcp.error("No MCP port; \(sessionID) launches without hooks")
            EventLog.shared.record(.hooks, "Launched without hooks, MCP listener has no port", [
                "session": sessionID.uuidString,
                "brokersPermissions": brokersPermissions ? "yes" : "no",
                "reportsLifecycle": reportsLifecycle ? "yes" : "no"
            ])

            // A settings file is still written when the session has a launch override to state.
            // Losing the hooks costs accurate activity; dropping one of these would silently
            // undo a choice the user made, which is a different order of wrong and must not
            // depend on whether an unrelated listener came up.
            if remoteControl == nil, fastMode == nil, statusLineOverride == nil {
                removeSettingsFile(for: sessionID)
                return nil
            }
        }

        // This is what makes terminal opt-out complete rather than an empty hooks dictionary
        // still carried through `--settings`.
        if !needsListener, remoteControl == nil, fastMode == nil, statusLineOverride == nil {
            removeSettingsFile(for: sessionID)
            return nil
        }

        var hooks: [String: Any] = [:]

        if needsListener, let port {
            let base = "http://\(MCPDefaults.host):\(port)"
            let token = token(for: sessionID)

            appendHooks(
                to: &hooks,
                base: base,
                token: token,
                brokersPermissions: brokersPermissions,
                reportsLifecycle: reportsLifecycle
            )
        }

        var settings: [String: Any] = [:]
        if !hooks.isEmpty {
            settings["hooks"] = hooks
        }
        if let remoteControl {
            settings[AgentDefaults.claudeRemoteControlKey] = remoteControl
        }
        if let fastMode {
            settings[AgentDefaults.claudeFastModeKey] = fastMode
        }
        if let statusLineOverride {
            // Must stay `type: "command"`: the CLI schema-validates this file and rejects it
            // *whole* on any other shape — taking the permission hooks above down with it.
            settings[ClaudeSettingsDefaults.statusLineKey] = [
                ClaudeSettingsDefaults.typeKey: ClaudeSettingsDefaults.commandType,
                ClaudeSettingsDefaults.commandKey: statusLineOverride
            ]
        }

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
            ThreadingLogger.mcp.error("Failed to write hook settings for \(sessionID): \(error)")
            return nil
        }
    }

    /// The `curl` entries themselves, split out so the settings file can still be written when
    /// there is no listener to point them at.
    private static func appendHooks(
        to hooks: inout [String: Any],
        base: String,
        token: String,
        brokersPermissions: Bool,
        reportsLifecycle: Bool
    ) {
        // Accumulated per hook name rather than assigned, because one name can carry entries
        // from both halves of this function: `PreToolUse` is how a native session brokers
        // permission *and* how a terminal session learns that a question tool opened. Assigning
        // would silently drop whichever was written first.
        var groups: [String: [[String: Any]]] = [:]

        if brokersPermissions {
            let url = "\(base)\(MCPDefaults.permissionPathPrefix)\(token)"
            let command = "curl -s --max-time \(Int(MCPDefaults.permissionTimeout))"
                + " -H 'Content-Type: application/json' --data-binary @- \(url)"

            // No matcher: every tool is offered, and `PermissionPolicy` decides which are
            // worth interrupting for. Policy in Swift beats policy in a glob.
            groups["PreToolUse", default: []].append(group(command: command, matcher: nil))
        }

        if reportsLifecycle {
            for event in HookLifecycleEvent.allCases {
                let registration = event.claudeRegistration
                guard registration.isSupported else { continue }

                let url = "\(base)\(MCPDefaults.lifecyclePathPrefix)\(token)"
                    + "?\(MCPDefaults.lifecycleEventParameter)=\(event.rawValue)"

                // Output is discarded and failure is swallowed, which is load-bearing rather
                // than tidy. Claude feeds a `UserPromptSubmit` hook's stdout back to the model
                // as extra context, treats a non-zero `Stop` hook as a reason to keep going, and
                // reads a `PreToolUse` hook's exit status as a permission decision — so a
                // lifecycle report that leaked any of them would change the conversation it is
                // only supposed to observe. This is what keeps the ask hooks *observational*:
                // they sit on the same event a broker would, and say nothing back.
                let timeout = event == .turnStarted
                    ? MCPDefaults.turnStartLifecycleTimeout
                    : MCPDefaults.lifecycleTimeout
                let command = "curl -s --max-time \(Int(timeout))"
                    + " -H 'Content-Type: application/json' --data-binary @- \(url)"
                    + " >/dev/null 2>&1 || true"

                for name in registration.eventNames {
                    groups[name, default: []].append(
                        group(command: command, matcher: registration.toolMatcher)
                    )
                }
            }
        }

        for (name, entries) in groups {
            hooks[name] = entries
        }
    }

    /// One `hooks` entry: the command, and the tools it is limited to when it is limited at all.
    private static func group(command: String, matcher: String?) -> [String: Any] {
        var group: [String: Any] = [
            "hooks": [["type": "command", "command": command]]
        ]
        if let matcher {
            group[HookRegistrationDefaults.matcherKey] = matcher
        }
        return group
    }

    /// Revokes the endpoints of every session not in the given set.
    ///
    /// Called when sessions are deleted, so a token cannot outlive the session it addressed
    /// and go on reaching a panel for something the user removed.
    @MainActor
    static func retainOnly(sessionIDs: Set<SessionID>) {
        let removedSessionIDs = storage.withLock { storage in
            // Ad-hoc endpoints are not in `ProjectStore`, so the sweep must not read their
            // absence from the retained set as deletion — a helper mid-run would lose its
            // endpoint because an unrelated session was removed.
            let removed = storage.tokensBySession.keys.filter {
                !sessionIDs.contains($0) && storage.adHocScopesBySession[$0] == nil
            }

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

    /// Opting out must leave neither a launch argument nor an older token-bearing file behind.
    /// Keep the in-memory token until ordinary session cleanup so changing the preference cannot
    /// invalidate hooks belonging to a process that is still winding down.
    private static func removeSettingsFile(for sessionID: SessionID) {
        let file = settingsFile(for: sessionID)
        guard FileManager.default.fileExists(atPath: file.path) else { return }

        do {
            try FileManager.default.removeItem(at: file)
        } catch {
            ThreadingLogger.mcp.error(
                "Failed to remove disabled hook settings for \(sessionID): \(error)"
            )
        }
    }

    private static func supportFile(_ sessionID: SessionID, in directory: String) -> URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]

        return appSupport
            .appendingPathComponent("Threading", isDirectory: true)
            .appendingPathComponent(directory, isDirectory: true)
            .appendingPathComponent(sessionID.uuidString)
            .appendingPathExtension(MCPDefaults.configFileExtension)
    }
}
