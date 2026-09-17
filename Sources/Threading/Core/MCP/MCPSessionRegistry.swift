import Foundation
import os

/// Maps the MCP endpoints handed to agents back to the sessions that own them.
///
/// Each session gets a private URL whose path carries an unguessable token, so a tool call
/// arriving over either endpoint identifies its session by construction. Nothing has to be
/// inferred from the process, and two sessions of the same project cannot be confused for each
/// other.
///
/// The token is the only thing guarding the endpoint. That is sufficient because both listeners
/// are local — a loopback port and an owner-only unix socket — so reaching either already
/// requires local code execution. It is also why the token must not be derived from the session
/// identifier, which is written to disk in readable places.
///
/// **The token is durable.** It used to be minted into an in-memory dictionary and documented as
/// stable for the app's lifetime, which made a session's whole bridge a property of one launch:
/// a hook arriving after a restart, or during one before the listener was up, carried a token
/// nothing recognised and was dropped. It is now persisted (`MCPSessionTokenStore`), minted once
/// per session and rotated only when the session is deleted. Ad-hoc endpoints are the deliberate
/// exception — a helper run *is* one run, so its token is never written down.
enum MCPSessionRegistry {

    // MARK: - Properties

    private struct Storage {
        var tokensBySession: [SessionID: String] = [:]
        var sessionsByToken: [String: SessionID] = [:]
        /// Scopes of the ad-hoc endpoints — synthetic sessions belonging to helper runs, not
        /// to `ProjectStore`. Membership here is also what exempts an id from `retainOnly`.
        var adHocScopesBySession: [SessionID: [String]] = [:]

        /// The durable half. Loaded on first access rather than at launch, so a process that
        /// never mints or resolves a token never reads the file.
        var tokenStore = MCPSessionTokenStore()
        var hasLoadedDurableTokens = false
        /// Ordering tag for the writer, so a snapshot taken earlier cannot land later.
        var durableGeneration: UInt64 = 0
    }

    /// Launch and deletion happen on main while requests resolve tokens on the MCP queue.
    /// Both maps form one bidirectional invariant, so they share a single lock and mutation.
    private static let storage = OSAllocatedUnfairLock(initialState: Storage())

    // MARK: - Public Methods

    /// The token for a session, minted on first use and durable from then on.
    static func token(for sessionID: SessionID) -> String {
        var deferred = DeferredWork()

        let token = storage.withLock { storage -> String in
            loadDurableTokensIfNeeded(&storage, deferring: &deferred)

            if let existing = storage.tokensBySession[sessionID] { return existing }

            let token = UUID().uuidString.lowercased()
            storage.tokensBySession[sessionID] = token
            storage.sessionsByToken[token] = sessionID
            deferred.snapshot = durableSnapshot(&storage)
            return token
        }

        deferred.perform()
        return token
    }

    /// The session a request path belongs to, or nil if the token is unknown.
    ///
    /// Loads the durable tokens too, because this is the side a hook arrives on: a report that
    /// reaches the listener before anything in this launch has minted a token still has to route.
    static func session(forToken token: String) -> SessionID? {
        var deferred = DeferredWork()

        let sessionID = storage.withLock { storage -> SessionID? in
            loadDurableTokensIfNeeded(&storage, deferring: &deferred)
            return storage.sessionsByToken[token]
        }

        deferred.perform()
        return sessionID
    }

    /// Mints an endpoint for a short-lived helper run, restricted to the named tools.
    ///
    /// The returned id is synthetic — it exists in this registry and nowhere else. The server
    /// consults its scope for `tools/list`, admission and instructions, so the helper is
    /// advertised exactly the tools it was launched for and nothing of the session surface.
    /// Ad-hoc ids survive `retainOnly` (they are not `ProjectStore`'s to retain) and are
    /// instead revoked explicitly by `endAdHoc` when the run finishes.
    ///
    /// Its token is deliberately **not** persisted: the scope exists for the length of one
    /// helper run, so a token surviving a restart would outlive everything that could honour it.
    /// The scope and the token are inserted under one lock acquisition, so no snapshot can ever
    /// observe the token before the ad-hoc marking that excludes it from the file.
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
    static func endpointURL(for sessionID: SessionID, port: UInt16?) -> String? {
        guard let port else { return nil }

        return "http://\(MCPDefaults.host):\(port)\(MCPDefaults.pathPrefix)\(token(for: sessionID))"
    }

    /// The command line that spawns this session's stdio bridge, or nil to use HTTP.
    ///
    /// Three conditions, and every one of them is a fallback rather than a failure. The setting
    /// has to be on — the bridge is opt-in for the length of rollout step 2. The helper has to be
    /// there and executable, because a `command` naming a file that will not run produces a CLI
    /// that reports a broken MCP server rather than a session that quietly uses the port. And the
    /// rendezvous has to be bindable: a socket that can never bind is a bridge that can never
    /// connect, so a home directory long enough to overflow `sun_path` must fall back to HTTP
    /// rather than ship a tool channel that refuses every call for the life of the session.
    ///
    /// `decision` is one injectable value rather than three parameters so a test can force each
    /// of those three answers without touching the developer's defaults or bundle.
    static func bridgeInvocation(
        for sessionID: SessionID,
        decision: MCPBridgeDecision
    ) -> MCPBridgeInvocation? {
        guard decision.isEnabled else { return nil }

        guard let socketPath = decision.socketPath else {
            ThreadingLogger.mcp.error(
                """
                The MCP stdio bridge is enabled but the rendezvous cannot be bound; this \
                launch uses the loopback endpoint instead
                """
            )
            return nil
        }

        guard FileManager.default.isExecutableFile(atPath: decision.helperURL.path) else {
            ThreadingLogger.mcp.error(
                """
                The MCP stdio bridge is enabled but \
                \(MCPBridgeDefaults.helperName, privacy: .public) is not executable in this \
                bundle; this launch uses the loopback endpoint instead
                """
            )
            return nil
        }

        return MCPBridgeInvocation(
            command: decision.helperURL.path,
            arguments: [
                MCPBridgeDefaults.socketArgument, socketPath,
                MCPBridgeDefaults.tokenArgument, token(for: sessionID),
                MCPBridgeDefaults.cacheArgument, bridgeCacheFile(for: sessionID).path
            ]
        )
    }

    /// How this launch reaches the MCP server: the helper it spawns, or the URL it resolves.
    ///
    /// One decision for all three transports. Claude writes it into a JSON file, Codex into
    /// per-run TOML overrides and ACP into its `mcpServers` array — but which of the two forms
    /// they are rendering is settled here, once, so the three cannot disagree about whether this
    /// session has a bridge.
    ///
    /// Nil is "no MCP for this launch": the stdio form needs no port, so this only happens when
    /// the bridge is unavailable *and* the listener has none.
    static func binding(
        for sessionID: SessionID,
        decision: MCPBridgeDecision
    ) -> MCPServerBinding? {
        if let invocation = bridgeInvocation(for: sessionID, decision: decision) {
            return .stdio(invocation)
        }
        guard let url = endpointURL(for: sessionID, port: decision.httpPort) else { return nil }
        return .http(url: url)
    }

    /// Writes the Claude `--mcp-config` file for a session and returns its path.
    ///
    /// Returns nil when there is nothing to write it about — which, once a bridge invocation is
    /// available, no longer includes "the server is not listening". That independence is the
    /// whole point of the shim: the stdio form names a helper rather than an address, so a
    /// session can be launched before the listener is up, or while the app is closed, and still
    /// hold a working tool channel. Without one it falls back to the HTTP form exactly as
    /// before, nil when there is no port, leaving the launch to proceed without MCP rather than
    /// failing outright.
    static func writeConfiguration(
        for sessionID: SessionID,
        decision: MCPBridgeDecision
    ) -> String? {
        guard let binding = binding(for: sessionID, decision: decision) else { return nil }

        let configuration: [String: Any] = [
            "mcpServers": [
                MCPDefaults.serverName: binding.claudeServerObject
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
            ThreadingLogger.mcp.error(
                "Failed to write MCP config for \(sessionID, privacy: .public): \(error, privacy: .private(mask: .hash))"
            )
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
    ///
    /// Hook commands read both routes from the launch environment. This file therefore stays
    /// independent of listener timing, while a failed socket can retry the same payload over the
    /// loopback port selected for that launch.
    static func writeHookSettings(
        for sessionID: SessionID,
        brokersPermissions: Bool,
        reportsLifecycle: Bool,
        remoteControl: Bool? = nil,
        fastMode: Bool? = nil,
        statusLineOverride: String? = nil
    ) -> String? {
        // This is what makes terminal opt-out complete rather than an empty hooks dictionary
        // still carried through `--settings`.
        guard let settings = hookSettings(
            for: sessionID,
            brokersPermissions: brokersPermissions,
            reportsLifecycle: reportsLifecycle,
            remoteControl: remoteControl,
            fastMode: fastMode,
            statusLineOverride: statusLineOverride
        ) else {
            removeSettingsFile(for: sessionID)
            return nil
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
            ThreadingLogger.mcp.error(
                "Failed to write hook settings for \(sessionID, privacy: .public): \(error, privacy: .private(mask: .hash))"
            )
            return nil
        }
    }

    /// The settings `writeHookSettings` writes, or nil when there is nothing to state. Separate
    /// so a launch on a remote execution host can carry the same object to a file written *there*:
    /// the hook commands name no path on this Mac — both routes come from the launch environment —
    /// so they read the same on either machine.
    static func hookSettings(
        for sessionID: SessionID,
        brokersPermissions: Bool,
        reportsLifecycle: Bool,
        remoteControl: Bool? = nil,
        fastMode: Bool? = nil,
        statusLineOverride: String? = nil
    ) -> [String: Any]? {
        let needsListener = brokersPermissions || reportsLifecycle

        if !needsListener, remoteControl == nil, fastMode == nil, statusLineOverride == nil {
            return nil
        }

        var hooks: [String: Any] = [:]

        if needsListener {
            appendHooks(
                to: &hooks,
                token: token(for: sessionID),
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
        return settings
    }

    /// The `curl` entries themselves, split out so the settings file can still be written for a
    /// session that asked for no hooks but has another launch override to state.
    ///
    /// They prefer the owner-only unix socket and retry the same buffered payload over the
    /// loopback port when it cannot be reached. The shared builder owns that route for both
    /// provider hook formats.
    private static func appendHooks(
        to hooks: inout [String: Any],
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
            let payload = "threading_hook_payload"

            // The broker's builder, not the plain POST one: an unreachable app answers this
            // hook with a typed deny rather than with silence. Only this command gets it. The
            // lifecycle commands below end in `>/dev/null 2>&1 || true` precisely so they can
            // never speak, and a fallback that printed there would be read as context or as a
            // reason to keep going.
            let command = "\(payload)=$(cat); " + MCPDefaults.hookBrokerCommand(
                payloadVariable: payload,
                endpointSuffix: "\(MCPDefaults.permissionPathPrefix)\(token)"
            )

            // No matcher: every tool is offered, and `PermissionPolicy` decides which are
            // worth interrupting for. Policy in Swift beats policy in a glob.
            groups["PreToolUse", default: []].append(group(command: command, matcher: nil))
        }

        if reportsLifecycle {
            for event in HookLifecycleEvent.allCases {
                let registration = event.claudeRegistration
                guard registration.isSupported else { continue }

                // Output is discarded and failure is swallowed, which is load-bearing rather
                // than tidy. Claude feeds a `UserPromptSubmit` hook's stdout back to the model
                // as extra context, treats a non-zero `Stop` hook as a reason to keep going, and
                // reads a `PreToolUse` hook's exit status as a permission decision — so a
                // lifecycle report that leaked any of them would change the conversation it is
                // only supposed to observe. This is what keeps the ask hooks *observational*:
                // they sit on the same event a broker would, and say nothing back.
                let timeout = MCPDefaults.lifecycleTimeout(for: event)
                let payload = "threading_hook_payload"
                let command = "\(payload)=$(cat); " + MCPDefaults.hookPostCommand(
                    payloadVariable: payload,
                    endpointSuffix: "\(MCPDefaults.lifecyclePathPrefix)\(token)"
                        + "?\(MCPDefaults.lifecycleEventParameter)=\(event.rawValue)",
                    timeout: timeout
                )
                    + " >/dev/null 2>&1 || true"

                for name in registration.eventNames {
                    groups[name, default: []].append(
                        group(command: command, matcher: registration.toolMatcher)
                    )
                }
            }

            for phase in HookRunProgressPhase.allCases {
                let registration = phase.claudeRegistration
                guard registration.isSupported else { continue }
                let payload = "threading_hook_payload"
                let command = "\(payload)=$(cat); " + MCPDefaults.hookPostCommand(
                    payloadVariable: payload,
                    endpointSuffix: "\(MCPDefaults.runProgressPathPrefix)\(token)"
                        + "?\(MCPDefaults.runProgressPhaseParameter)=\(phase.rawValue)",
                    timeout: MCPDefaults.runProgressTimeout
                ) + " >/dev/null 2>&1 || true"

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
    /// and go on reaching a panel for something the user removed. It is also what bounds the
    /// durable file: the sweep runs with the live session set and the resulting snapshot
    /// *replaces* the file, so a deleted session's row goes with its endpoint.
    @MainActor
    static func retainOnly(sessionIDs: Set<SessionID>) {
        var deferred = DeferredWork()

        let removedSessionIDs = storage.withLock { storage -> [SessionID] in
            loadDurableTokensIfNeeded(&storage, deferring: &deferred)

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

            // Taken unconditionally: a sweep that removed nothing may still be the first thing
            // to load a file whose rows this launch has never rewritten, and the file has to
            // stop naming a session even when that session never minted a token here.
            deferred.snapshot = durableSnapshot(&storage)
            return removed
        }

        deferred.perform()

        // Disk cleanup and permission cancellation can call into other subsystems. Keeping them
        // outside the registry lock prevents unrelated work from extending the critical section.
        for sessionID in removedSessionIDs {
            removeSupportFilesAndPermissions(for: sessionID)
        }
    }

    /// Revokes one permanently deleted session without filtering the complete endpoint map.
    @MainActor
    static func remove(sessionID: SessionID) {
        remove(sessionIDs: [sessionID])
    }

    /// Revokes a removed project's endpoints with one durable token snapshot.
    @MainActor
    static func remove(sessionIDs: Set<SessionID>) {
        guard !sessionIDs.isEmpty else { return }
        var deferred = DeferredWork()

        let removed = storage.withLock { storage -> [SessionID] in
            loadDurableTokensIfNeeded(&storage, deferring: &deferred)

            let ordinary = sessionIDs.filter { storage.adHocScopesBySession[$0] == nil }
            guard !ordinary.isEmpty else { return [] }
            for sessionID in ordinary {
                if let token = storage.tokensBySession.removeValue(forKey: sessionID) {
                    storage.sessionsByToken.removeValue(forKey: token)
                }
            }
            // Taken even when this launch never minted for the session: the row may have come
            // from the file, and a deleted session must not stay addressable across a restart.
            deferred.snapshot = durableSnapshot(&storage)
            return Array(ordinary)
        }

        deferred.perform()
        for sessionID in removed {
            removeSupportFilesAndPermissions(for: sessionID)
        }
    }

    /// Blocks until every durable token write has landed.
    ///
    /// For tests, which have to observe the file a mint or a revocation produced. The app never
    /// waits: an unwritten token is still in memory, and only the next launch reads the file.
    static func waitForPendingTokenWrites() {
        MCPSessionTokenWriter.waitForPendingWrites()
    }

    /// Points the registry at `file` and forgets everything the previous one loaded.
    ///
    /// This is a test's synthetic restart, and the registry is a global by construction — a
    /// token has to resolve from the MCP queue with no session object in hand — so there is
    /// nowhere else to inject it. Production never calls this; the app's file is
    /// `MCPBridgeLocation.tokenFile`, which already redirects under a hosted test bundle.
    static func reload(from file: URL = MCPBridgeLocation.tokenFile) {
        MCPSessionTokenWriter.waitForPendingWrites()
        storage.withLock { storage in
            storage.tokensBySession.removeAll()
            storage.sessionsByToken.removeAll()
            storage.adHocScopesBySession.removeAll()
            storage.tokenStore = MCPSessionTokenStore(file: file)
            storage.hasLoadedDurableTokens = false
        }
    }

    @MainActor
    private static func removeSupportFilesAndPermissions(for sessionID: SessionID) {
        let files = MCPDefaults.cleanupDirectories.map { supportFile(sessionID, in: $0) }
        Task.detached(priority: .utility) {
            for file in files {
                try? FileManager().removeItem(at: file)
            }
        }
        PermissionBroker.discard(sessionID: sessionID)
    }

    // MARK: - Durable Tokens

    /// Work a locked section produced but must not do while holding the lock.
    ///
    /// `EventLog.record` takes its own queue synchronously and a token write touches the
    /// filesystem; neither belongs inside an unfair lock, where it would extend a critical
    /// section every hook and every tool call passes through.
    private struct DeferredWork {
        var journal: [MCPSessionTokenStore.Diagnostic] = []
        var snapshot: MCPSessionTokenSnapshot?

        func perform() {
            for entry in journal {
                EventLog.shared.record(.hooks, entry.message, entry.detail)
            }
            if let snapshot {
                MCPSessionTokenWriter.write(snapshot)
            }
        }
    }

    /// Reads the durable tokens once per launch, into both directions of the map.
    ///
    /// A stored row that has no in-memory counterpart is exactly the case this exists for: the
    /// hook of a session this launch has not touched yet still resolves. A row whose token is
    /// already claimed in memory is left alone, since the live mapping is the newer fact.
    ///
    /// One bounded read, once. It happens under the registry's lock because the alternative — a
    /// window where two callers both see an unloaded map — is a second token minted for a
    /// session that already had one, which is the exact defect the file removes.
    private static func loadDurableTokensIfNeeded(
        _ storage: inout Storage,
        deferring deferred: inout DeferredWork
    ) {
        guard !storage.hasLoadedDurableTokens else { return }
        storage.hasLoadedDurableTokens = true

        let (tokens, diagnostic) = storage.tokenStore.load()
        if let diagnostic { deferred.journal.append(diagnostic) }

        for (sessionID, token) in tokens {
            guard storage.tokensBySession[sessionID] == nil,
                  storage.sessionsByToken[token] == nil else {
                continue
            }
            storage.tokensBySession[sessionID] = token
            storage.sessionsByToken[token] = sessionID
        }
    }

    /// The durable set as it stands, tagged so the writer can drop a stale one.
    ///
    /// Ad-hoc endpoints are filtered out here rather than at the write, so there is exactly one
    /// place that decides what is durable.
    private static func durableSnapshot(_ storage: inout Storage) -> MCPSessionTokenSnapshot {
        storage.durableGeneration += 1
        let tokens = storage.tokensBySession.filter {
            storage.adHocScopesBySession[$0.key] == nil
        }
        return MCPSessionTokenSnapshot(
            generation: storage.durableGeneration,
            tokens: tokens,
            store: storage.tokenStore
        )
    }

    // MARK: - Private Methods

    private static func configurationFile(for sessionID: SessionID) -> URL {
        supportFile(sessionID, in: MCPDefaults.configDirectoryName)
    }

    private static func settingsFile(for sessionID: SessionID) -> URL {
        supportFile(sessionID, in: MCPDefaults.settingsDirectoryName)
    }

    /// The catalogue cache the session's bridge keeps, named by the app rather than by the
    /// helper. The helper has no path policy of its own, so socket, token and cache stay one
    /// decision made beside the session's other per-session files — and one that every existing
    /// revocation sweep already knows how to undo.
    private static func bridgeCacheFile(for sessionID: SessionID) -> URL {
        supportFile(sessionID, in: MCPDefaults.bridgeCacheDirectoryName)
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
                "Failed to remove disabled hook settings for \(sessionID, privacy: .public): \(error, privacy: .private(mask: .hash))"
            )
        }
    }

    /// The per-session config and settings files, under the same root as the bridge's own state.
    ///
    /// Identical to `~/Library/Application Support/Threading/<directory>/<id>.json` in the app.
    /// Under a hosted test bundle it follows `StateManager`'s scratch redirect for the reason
    /// that redirect exists: these tests run inside the shipping app, and every fixture session
    /// used to leave a token-bearing file in the developer's own Application Support.
    private static func supportFile(_ sessionID: SessionID, in directory: String) -> URL {
        MCPBridgeLocation.supportRoot
            .appendingPathComponent(directory, isDirectory: true)
            .appendingPathComponent(sessionID.uuidString)
            .appendingPathExtension(MCPDefaults.configFileExtension)
    }
}
