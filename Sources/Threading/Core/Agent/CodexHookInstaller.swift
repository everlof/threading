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
///   other way to tell an entry to update from an entry to leave alone.
/// - **Rewrite only on a real change.** Codex pins a trusted hook by hashing its text, so an
///   identical rewrite is not merely wasteful — a changed file is an untrusted file, and the
///   hooks would silently stop running until the user reviewed them again.
///
/// That last rule is what the environment variables in the command are for. A URL carrying
/// today's port would change every launch and invalidate the trust every launch.
enum CodexHookInstaller {

    // MARK: - Public Methods

    /// Ensures the account's `hooks.json` carries Threading's current entries.
    ///
    /// Returns whether the file was written. A `false` return is the ordinary case on every
    /// launch after the first, and is what keeps the user's trust decision valid.
    @discardableResult
    static func install(inCodexHome codexHome: String) -> Bool {
        let file = hooksFile(inCodexHome: codexHome)

        let existing = (try? Data(contentsOf: file))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]

        let merged = merging(into: existing)

        guard !isEquivalent(merged, existing) else {
            ThreadingLogger.agent.debug("Codex hooks already current in \(codexHome, privacy: .public)")
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
            try data.write(to: file, options: .atomic)

            // Durable, because of what a rewrite *costs*: Codex pins a trusted hook by hashing
            // its text, so this line is the moment the user's approval stopped applying and
            // their hooks went quiet. It is the answer to "these worked yesterday".
            ThreadingLogger.agent.info("Installed Codex hooks in \(codexHome, privacy: .public)")
            EventLog.shared.record(.hooks, "Rewrote Codex hooks, trust must be renewed", [
                "codexHome": codexHome,
                "existed": existing.isEmpty ? "no" : "yes"
            ])
            return true
        } catch {
            ThreadingLogger.agent.error("Failed to install Codex hooks: \(error.localizedDescription)")
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

        guard let data = try? Data(contentsOf: file),
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

        guard let encoded, (try? encoded.write(to: file, options: .atomic)) != nil else {
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
        let url = "http://\(MCPDefaults.host):$\(MCPDefaults.portEnvironmentKey)"
            + "\(MCPDefaults.lifecyclePathPrefix)$\(MCPDefaults.sessionTokenEnvironmentKey)"
            + "?\(MCPDefaults.lifecycleEventParameter)=\(event.rawValue)"

        // Output is discarded and failure swallowed for the same reason as Claude's: a
        // lifecycle report must not be able to say anything back to the model.
        let timeout = event == .turnStarted
            ? MCPDefaults.turnStartLifecycleTimeout
            : MCPDefaults.lifecycleTimeout
        return "\(Key.payloadVariable)=$(cat);"
            + " [ -n \"$\(MCPDefaults.sessionTokenEnvironmentKey)\" ] &&"
            + " printf '%s' \"$\(Key.payloadVariable)\" |"
            + " curl -s --max-time \(Int(timeout))"
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
        let url = "http://\(MCPDefaults.host):$\(MCPDefaults.portEnvironmentKey)"
            + "\(MCPDefaults.permissionPathPrefix)$\(MCPDefaults.sessionTokenEnvironmentKey)"

        return "\(Key.payloadVariable)=$(cat);"
            + " [ -n \"$\(MCPDefaults.brokerEnvironmentKey)\" ] &&"
            + " printf '%s' \"$\(Key.payloadVariable)\" |"
            + " curl -s --max-time \(Int(MCPDefaults.permissionTimeout))"
            + " -H 'Content-Type: application/json' --data-binary @- \"\(url)\";"
            + " true \(MCPDefaults.hookMarker)"
    }

    static func hooksFile(inCodexHome codexHome: String) -> URL {
        URL(fileURLWithPath: codexHome).appendingPathComponent(Key.fileName)
    }

    // MARK: - Private Methods

    /// Builds the merged document: every foreign entry kept, every Threading entry rewritten.
    private static func merging(into existing: [String: Any]) -> [String: Any] {
        var hooks = existing[Key.hooks] as? [String: Any] ?? [:]

        for event in HookLifecycleEvent.allCases {
            guard let name = event.codexEventName else { continue }
            let timeout = event == .turnStarted
                ? MCPDefaults.turnStartLifecycleTimeout
                : MCPDefaults.lifecycleTimeout
            hooks[name] = foreignEntries(in: hooks[name]) + [
                entry(command: command(for: event), timeout: timeout)
            ]
        }

        // Written unconditionally, and inert until a launch exports the broker variable. The
        // alternative — installing it only for native sessions — would rewrite the file every
        // time a session changed surface, and each rewrite costs the user's trust decision.
        hooks[Key.preToolUse] = foreignEntries(in: hooks[Key.preToolUse]) + [
            entry(command: permissionCommand(), timeout: MCPDefaults.permissionTimeout)
        ]

        var merged = existing
        merged[Key.hooks] = hooks
        return merged
    }

    private static func entry(command: String, timeout: TimeInterval) -> [String: Any] {
        [Key.hooks: [[
            Key.type: Key.commandType,
            Key.command: command,
            Key.timeout: Int(timeout)
        ]]]
    }

    /// The entries of one event that are not ours, in their original order.
    private static func foreignEntries(in value: Any?) -> [Any] {
        guard let entries = value as? [Any] else { return [] }
        return entries.filter { !isThreadingEntry($0) }
    }

    private static func isThreadingEntry(_ entry: Any) -> Bool {
        guard let entry = entry as? [String: Any],
              let hooks = entry[Key.hooks] as? [Any] else {
            return false
        }

        return hooks.contains { hook in
            guard let hook = hook as? [String: Any],
                  let command = hook[Key.command] as? String else {
                return false
            }
            return command.contains(MCPDefaults.hookMarker)
        }
    }

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
    }
}
