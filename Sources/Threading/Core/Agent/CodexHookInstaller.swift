import Foundation

// MARK: - Codex Hook Installer

/// Installs Threading's lifecycle hooks into a Codex account's `hooks.json`.
///
/// Claude takes its hooks as a `--settings` file written per launch and thrown away, so nothing
/// of ours outlives the session. Codex has no equivalent flag: it reads one `hooks.json` from
/// the account's config directory, which is a file the *user* owns and may already be using —
/// this machine's own carries another tool's entries. Three rules follow from that, and each is
/// the difference between adding a feature and damaging someone's setup:
///
/// - **Merge, never replace.** Other tools' entries are read back and written out untouched.
/// - **Mark what is ours** (`MCPDefaults.hookMarker`), because on the next install there is no
///   other way to tell an entry to update from an entry to leave alone. The marker from before
///   the product rename is ours too. Its known commands stay byte-for-byte intact because a
///   Threading launch exports their `SKALMAN_*` aliases; an unknown old command is replaced.
/// - **Rewrite only on a real change.** Codex pins a trusted hook by hashing its text, so an
///   identical rewrite is not merely wasteful — a changed file is an untrusted file, and the
///   hooks would silently stop running until the user reviewed them again.
///
/// That last rule is what the session token's environment variable is for. A URL carrying a
/// per-session token would change every launch and invalidate the trust every launch.
///
/// **The rendezvous is now a literal, and that is a one-time trust renewal.** These commands
/// used to interpolate `$THREADING_MCP_PORT` for the same stability reason, because a loopback
/// port is minted per launch. The unix socket is a fixed path under this user's Application
/// Support, so it is written into the file directly — after which the text stops changing
/// again. A user upgrading past this change has to approve their Codex hooks once more; the
/// `EventLog` line at the rewrite says so.
enum CodexHookInstaller {
    static let maximumHooksBytes = 4 * 1024 * 1024

    // MARK: - Public Methods

    /// Ensures the account's `hooks.json` carries Threading's current entries.
    ///
    /// Returns whether the file was written. A `false` return is the ordinary case on every
    /// launch after the first, and is what keeps the user's trust decision valid.
    @discardableResult
    static func install(inCodexHome codexHome: String) -> Bool {
        let file = hooksFile(inCodexHome: codexHome)

        let existingData: Data?
        let existing: [String: Any]
        if FileManager.default.fileExists(atPath: file.path) {
            guard let data = try? BoundedFileReader.read(
                file,
                maximumBytes: maximumHooksBytes
            ), let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                ThreadingLogger.agent.error(
                    "Refusing to replace unreadable Codex hooks in \(codexHome, privacy: .private(mask: .hash))"
                )
                return false
            }
            existingData = data
            existing = document
        } else {
            existingData = nil
            existing = [:]
        }

        let merged = merging(into: existing)

        guard !isEquivalent(merged, existing) else {
            ThreadingLogger.agent.debug("Codex hooks already current in \(codexHome, privacy: .private(mask: .hash))")
            return false
        }

        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONSerialization.data(
                withJSONObject: merged,
                options: [.prettyPrinted, .sortedKeys]
            )
            // This is a shared user-owned file. If Codex or another tool rewrote it after our
            // merge read, retry on the next launch instead of atomically clobbering newer hooks.
            if let existingData {
                guard try BoundedFileReader.read(
                    file,
                    maximumBytes: maximumHooksBytes
                ) == existingData else { return false }
            } else {
                guard !FileManager.default.fileExists(atPath: file.path) else { return false }
            }
            try data.write(to: file, options: .atomic)

            // Durable, because of what a rewrite *costs*: Codex pins a trusted hook by hashing
            // its text, so this line is the moment the user's approval stopped applying and
            // their hooks went quiet. It is the answer to "these worked yesterday".
            ThreadingLogger.agent.info("Installed Codex hooks in \(codexHome, privacy: .private(mask: .hash))")
            EventLog.shared.record(.hooks, "Rewrote Codex hooks, trust must be renewed", [
                "codexHome": codexHome,
                "existed": existing.isEmpty ? "no" : "yes"
            ])
            return true
        } catch {
            ThreadingLogger.agent.error(
                "Failed to install Codex hooks: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            EventLog.shared.record(.hooks, "Failed to install Codex hooks", [
                "codexHome": codexHome,
                "error": error.localizedDescription
            ])
            return false
        }
    }

    /// Removes Threading's entries from an account's `hooks.json`, leaving every other tool's.
    @discardableResult
    static func uninstall(fromCodexHome codexHome: String) -> Bool {
        let file = hooksFile(inCodexHome: codexHome)

        guard let data = try? BoundedFileReader.read(
            file,
            maximumBytes: maximumHooksBytes
        ),
              let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return false
        }

        var hooks = existing[Key.hooks] as? [String: Any] ?? [:]

        for (event, value) in hooks {
            let kept = foreignEntries(in: value)
            if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = kept }
        }

        var updated = existing
        updated[Key.hooks] = hooks

        guard !isEquivalent(updated, existing) else { return false }

        let encoded = try? JSONSerialization.data(
            withJSONObject: updated,
            options: [.prettyPrinted, .sortedKeys]
        )

        guard let encoded,
              (try? BoundedFileReader.read(file, maximumBytes: maximumHooksBytes)) == data,
              (try? encoded.write(to: file, options: .atomic)) != nil else {
            return false
        }

        return true
    }

    /// The command one lifecycle hook runs.
    ///
    /// Guarded on the token rather than left to fail: this file is read by *every* Codex run
    /// under the account, including the ones the user starts themselves in a terminal. Those
    /// carry no token, and without the guard each would spawn a curl per turn to build a URL
    /// that cannot resolve.
    ///
    /// **Stdin is read before the guard, always.** Codex writes the event to the hook's stdin,
    /// so a guard that skips the read leaves the CLI writing into a pipe nobody drains — and it
    /// is the *unrouted* sessions, the user's own, that would take that cost. Reading first also
    /// keeps the two paths identical in what they consume.
    static func command(for event: HookLifecycleEvent) -> String {
        let url = "\(MCPDefaults.socketURLBase)"
            + "\(MCPDefaults.lifecyclePathPrefix)$\(MCPDefaults.sessionTokenEnvironmentKey)"
            + "?\(MCPDefaults.lifecycleEventParameter)=\(event.rawValue)"

        // Output is discarded and failure swallowed for the same reason as Claude's: a
        // lifecycle report must not be able to say anything back to the model.
        let timeout = MCPDefaults.lifecycleTimeout(for: event)
        return "\(Key.payloadVariable)=$(cat);"
            + " [ -n \"$\(MCPDefaults.sessionTokenEnvironmentKey)\" ] &&"
            + " printf '%s' \"$\(Key.payloadVariable)\" |"
            + " curl -s --max-time \(Int(timeout))"
            + " \(socketTransport)"
            + " -H 'Content-Type: application/json' --data-binary @- \"\(url)\""
            + " >/dev/null 2>&1; true \(MCPDefaults.hookMarker)"
    }

    /// The command the `PreToolUse` hook runs, which asks Threading whether a tool may proceed.
    ///
    /// Unlike the lifecycle hooks this one **blocks and speaks**: curl's stdout is the hook's
    /// stdout, and that is the decision. Measured on Codex 0.144.6 — a `deny` reply stops the
    /// tool outright (`PreToolUse Blocked`) and the reason reaches the model.
    ///
    /// It is guarded on a *second* variable, not the session token. `hooks.json` is shared by
    /// every session under the account, but brokering suits only the sessions Threading renders
    /// itself: a terminal session raises Codex's own approval prompt, which the user can see and
    /// answer. Exporting the variable for one surface and not the other is what scopes a shared
    /// file to a single surface. Saying nothing leaves Codex's normal flow untouched.
    static func permissionCommand() -> String {
        let url = "\(MCPDefaults.socketURLBase)"
            + "\(MCPDefaults.permissionPathPrefix)$\(MCPDefaults.sessionTokenEnvironmentKey)"

        return "\(Key.payloadVariable)=$(cat);"
            + " [ -n \"$\(MCPDefaults.brokerEnvironmentKey)\" ] &&"
            + " printf '%s' \"$\(Key.payloadVariable)\" |"
            + " curl -s --max-time \(Int(MCPDefaults.permissionTimeout))"
            + " \(socketTransport)"
            + " -H 'Content-Type: application/json' --data-binary @- \"\(url)\";"
            + " true \(MCPDefaults.hookMarker)"
    }

    /// The `--unix-socket` word both commands carry.
    ///
    /// Quoted, because the path contains `Application Support`. This is the only part of the
    /// text that is not fixed at compile time, and it is fixed for a given user — which is what
    /// keeps `hooks.json` stable across launches.
    private static var socketTransport: String {
        "--unix-socket \(MCPBridgeLocation.shellQuoted(MCPBridgeLocation.socketPath))"
    }

    static func hooksFile(inCodexHome codexHome: String) -> URL {
        URL(fileURLWithPath: codexHome).appendingPathComponent(Key.fileName)
    }

    // MARK: - Private Methods

    /// Builds the merged document: every foreign entry kept, every current Threading entry
    /// rewritten, and every known-compatible pre-rename entry retained byte-for-byte.
    private static func merging(into existing: [String: Any]) -> [String: Any] {
        var hooks = existing[Key.hooks] as? [String: Any] ?? [:]

        var compatibleLegacyCommands: [String: Set<String>] = [:]
        for event in HookLifecycleEvent.allCases {
            let registration = event.codexRegistration
            guard registration.isSupported else { continue }
            for name in registration.eventNames {
                compatibleLegacyCommands[name, default: []].insert(
                    legacyCommand(for: event)
                )
            }
        }
        compatibleLegacyCommands[Key.preToolUse, default: []].insert(
            legacyPermissionCommand()
        )

        // Entries accumulate per hook name: one event can register under two names, and two
        // events can share one — so each name is rebuilt from the foreign entries once and
        // appended to, rather than replaced per event.
        var installed: [String: [Any]] = [:]

        for event in HookLifecycleEvent.allCases {
            let registration = event.codexRegistration
            guard registration.isSupported else { continue }

            let timeout = MCPDefaults.lifecycleTimeout(for: event)
            let compatibleCommand = legacyCommand(for: event)

            for name in registration.eventNames {
                let retained = entriesRetainedDuringInstall(
                    in: hooks[name],
                    compatibleLegacyCommands: compatibleLegacyCommands[name] ?? []
                )
                if installed[name] == nil { installed[name] = retained }

                guard !containsCommand(compatibleCommand, in: hooks[name]) else { continue }
                installed[name, default: []].append(entry(
                    command: command(for: event),
                    timeout: timeout,
                    matcher: registration.toolMatcher
                ))
            }
        }

        // Written unconditionally, and inert until a launch exports the broker variable. The
        // alternative — installing it only for native sessions — would rewrite the file every
        // time a session changed surface, and each rewrite costs the user's trust decision.
        //
        // Through the same accumulator as the lifecycle entries, so that a runtime whose ask
        // hooks land on `PreToolUse` keeps both: this line used to assign, which would have
        // dropped them.
        let retainedPermissionEntries = entriesRetainedDuringInstall(
            in: hooks[Key.preToolUse],
            compatibleLegacyCommands: compatibleLegacyCommands[Key.preToolUse] ?? []
        )
        if installed[Key.preToolUse] == nil {
            installed[Key.preToolUse] = retainedPermissionEntries
        }
        if !containsCommand(legacyPermissionCommand(), in: hooks[Key.preToolUse]) {
            installed[Key.preToolUse, default: []].append(
                entry(command: permissionCommand(), timeout: MCPDefaults.permissionTimeout)
            )
        }

        for (name, entries) in installed {
            hooks[name] = entries
        }

        var merged = existing
        merged[Key.hooks] = hooks
        return merged
    }

    private static func entry(
        command: String,
        timeout: TimeInterval,
        matcher: String? = nil
    ) -> [String: Any] {
        var entry: [String: Any] = [Key.hooks: [[
            Key.type: Key.commandType,
            Key.command: command,
            Key.timeout: Int(timeout)
        ]]]
        if let matcher {
            entry[HookRegistrationDefaults.matcherKey] = matcher
        }
        return entry
    }

    /// The entries of one event that are not ours, in their original order.
    private static func foreignEntries(in value: Any?) -> [Any] {
        guard let entries = value as? [Any] else { return [] }
        return entries.filter { !isThreadingEntry($0) }
    }

    /// The entries retained while installing, including exact commands written before the
    /// rename. Their text is already trusted by Codex and remains runnable because launches
    /// export the old routing aliases. Anything else carrying our old marker is stale and gets
    /// replaced by the current command.
    private static func entriesRetainedDuringInstall(
        in value: Any?,
        compatibleLegacyCommands: Set<String>
    ) -> [Any] {
        guard let entries = value as? [Any] else { return [] }
        return entries.filter { entry in
            guard isThreadingEntry(entry) else { return true }
            let commands = commands(in: entry)
            return commands.count == 1 && compatibleLegacyCommands.contains(commands[0])
        }
    }

    private static func containsCommand(_ command: String, in value: Any?) -> Bool {
        guard let entries = value as? [Any] else { return false }
        return entries.contains { commands(in: $0).contains(command) }
    }

    private static func commands(in entry: Any) -> [String] {
        guard let entry = entry as? [String: Any],
              let hooks = entry[Key.hooks] as? [Any] else {
            return []
        }

        return hooks.compactMap { hook in
            (hook as? [String: Any])?[Key.command] as? String
        }
    }

    private static func isThreadingEntry(_ entry: Any) -> Bool {
        commands(in: entry).contains { command in
            ownedMarkers.contains { command.contains($0) }
        }
    }

    /// The exact command the pre-rename installer wrote. This is compatibility recognition,
    /// not a second current generator: equality is what lets us preserve the old hook's trust
    /// hash without treating an arbitrary old marked command as safe or current.
    private static func legacyCommand(for event: HookLifecycleEvent) -> String {
        let url = "http://\(MCPDefaults.host):$\(MCPDefaults.legacyPortEnvironmentKey)"
            + "\(MCPDefaults.lifecyclePathPrefix)"
            + "$\(MCPDefaults.legacySessionTokenEnvironmentKey)"
            + "?\(MCPDefaults.lifecycleEventParameter)=\(event.rawValue)"

        return "\(Key.legacyPayloadVariable)=$(cat);"
            + " [ -n \"$\(MCPDefaults.legacySessionTokenEnvironmentKey)\" ] &&"
            + " printf '%s' \"$\(Key.legacyPayloadVariable)\" |"
            + " curl -s --max-time \(Int(MCPDefaults.lifecycleTimeout))"
            + " -H 'Content-Type: application/json' --data-binary @- \"\(url)\""
            + " >/dev/null 2>&1; true \(Key.legacyHookMarker)"
    }

    private static func legacyPermissionCommand() -> String {
        let url = "http://\(MCPDefaults.host):$\(MCPDefaults.legacyPortEnvironmentKey)"
            + "\(MCPDefaults.permissionPathPrefix)"
            + "$\(MCPDefaults.legacySessionTokenEnvironmentKey)"

        return "\(Key.legacyPayloadVariable)=$(cat);"
            + " [ -n \"$\(MCPDefaults.legacyBrokerEnvironmentKey)\" ] &&"
            + " printf '%s' \"$\(Key.legacyPayloadVariable)\" |"
            + " curl -s --max-time \(Int(MCPDefaults.permissionTimeout))"
            + " -H 'Content-Type: application/json' --data-binary @- \"\(url)\";"
            + " true \(Key.legacyHookMarker)"
    }

    /// Every marker this product has written into the user's shared Codex configuration.
    ///
    /// The rename changed both the marker and the environment-variable vocabulary. Admission by
    /// either exact marker keeps update and uninstall narrow: commands from other tools remain
    /// foreign even if they happen to mention the old app name elsewhere. Compatibility of an
    /// old command is the stricter exact-text check above; the marker alone only proves ownership.
    private static let ownedMarkers = [
        MCPDefaults.hookMarker,
        Key.legacyHookMarker
    ]

    /// Compares two documents by their serialized form.
    ///
    /// `NSDictionary` equality would do, but sorted-key JSON is what actually gets written and
    /// so is what Codex hashes — comparing anything else risks calling a file unchanged that
    /// lands on disk differently.
    private static func isEquivalent(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
        let options: JSONSerialization.WritingOptions = [.sortedKeys]
        let left = try? JSONSerialization.data(withJSONObject: lhs, options: options)
        let right = try? JSONSerialization.data(withJSONObject: rhs, options: options)
        return left == right
    }

    private enum Key {
        static let fileName = "hooks.json"
        static let hooks = "hooks"
        static let type = "type"
        static let commandType = "command"
        static let command = "command"
        static let timeout = "timeout"
        static let preToolUse = "PreToolUse"

        /// Holds the event while the guard is evaluated, so stdin is drained either way.
        static let payloadVariable = "threading_payload"
        static let legacyPayloadVariable = "skalman_payload"
        static let legacyHookMarker = "# skalman-lifecycle"
    }
}
