import Foundation
import os

// MARK: - Claude Settings

/// The values a Claude session inherits from settings files, resolved the way the CLI resolves
/// them.
///
/// Threading states no permission mode and no speed on the launch line unless something here
/// chose one, so what those chips name is decided by files this app used to call unreadable.
/// They are readable, and reading them is the whole difference between a chip that says
/// "Agent's Setting" and one that says which posture the session starts in.
///
/// **The layer order is the CLI's, and for these keys it is first-match-wins rather than a
/// merge**: a managed policy replaces the user's value outright, and the three writable layers
/// override one another most-specific-first. Threading's own per-session `--settings` file sits
/// above all of them, and is already accounted for before this is asked — it carries only what
/// the user chose here.
///
/// **`auto` is the one value whose source changes the answer.** Measured against CLI 2.1.228: a
/// repository-controllable layer may not grant it — *"settings defaultMode `auto` ignored — only
/// policy/user/flag settings may grant auto mode (projectSettings and localSettings are
/// repo-controllable)"* — and the CLI then falls through to its own fallback rather than to the
/// layer below. So an `auto` read out of a project or local file is not a value this app may
/// report, and neither is whatever the user's own file says underneath it.
///
/// **The unset case is deliberately not answered here.** With no layer stating
/// `permissions.defaultMode`, the CLI chooses between `default` and `auto` on a server-side gate
/// (`tengu_harbor_willow`, plus an interactive-session test that `--print` fails), which is not a
/// file and not ours to predict — on the machine this was written against, every one of forty
/// recent transcripts had resolved to `auto` while the CLI's own settings screen would have said
/// `default`. `ClaudeAccountLastRunPermissionMode` answers that case from evidence instead, which
/// is why callers label the two differently.
enum ClaudeSettings {

    // MARK: - Types

    /// Which file answered. Carried because one rule depends on it: only a layer a repository
    /// cannot write may grant `auto`.
    enum Source: Equatable, Sendable {
        case managed
        case local
        case project
        case user

        /// `policySettings` and `userSettings` in the CLI's own vocabulary. A `.claude` directory
        /// travels with a checkout, so a clone must not be able to hand itself a classifier.
        var mayGrantAutoPermissionMode: Bool {
            self == .managed || self == .user
        }
    }

    /// One settings file's facts, read once per version of that file.
    ///
    /// Every fact at once rather than one read per question: the three callers below ask on the
    /// same refresh, and a per-key read would parse the same 2 KB of JSON three times per
    /// streamed event.
    private struct Snapshot: Sendable, Equatable {
        var permissionMode: String?
        var fastMode: Bool?
        var statusLineCommand: String?

        static let empty = Snapshot()
    }

    /// What a file looked like when it was read. Modification date *and* size, because a
    /// settings file is small enough to be rewritten inside one timestamp tick.
    private struct Stamp: Equatable, Sendable {
        var modified: Date?
        var size: Int?

        static let missing = Stamp()
    }

    private struct CachedSnapshot: Sendable {
        let stamp: Stamp
        let snapshot: Snapshot
    }

    private struct Cache: Sendable {
        var snapshots: [String: CachedSnapshot] = [:]
    }

    // MARK: - Properties

    /// `refreshConversationControls()` runs on every streamed event, and each run asks for the
    /// mode and the speed. Uncached that is eight `stat`+parse pairs per event on the main
    /// thread; cached it is eight `stat`s, and only a file the user has actually edited is
    /// re-read.
    private static let cache = OSAllocatedUnfairLock(initialState: Cache())

    /// One account has four layers per project. The cap is a runaway bound, not a working set:
    /// a user with more open projects than this loses the memo wholesale rather than growing it
    /// without limit, and the next refresh rebuilds the handful it actually needs.
    private static let maximumCachedFiles = 64

    // MARK: - Public Methods

    /// The mode this account's own settings choose for a session Threading launches without
    /// stating one, or nil when no layer states one — and nil again for a value this app does
    /// not know, which is a newer CLI's seventh mode rather than a posture to guess at.
    static func permissionMode(account: AgentAccount, projectDirectory: String?) -> AgentPermissionMode? {
        for layer in layers(account: account, projectDirectory: projectDirectory) {
            guard let value = snapshot(at: layer.url).permissionMode else { continue }
            guard let mode = AgentPermissionMode(externalValue: value, for: .claude) else { return nil }

            // Not `continue`: the CLI drops the whole key rather than falling through, so a
            // user-level mode underneath a repository's `auto` does not apply either.
            if mode == .auto, !layer.source.mayGrantAutoPermissionMode { return nil }

            return mode
        }
        return nil
    }

    /// Whether these settings turn fast mode on, or nil when no layer states it.
    ///
    /// Nil is not Standard. `AgentModels.defaultFastMode` decides what unset means, because that
    /// is a fact about the mechanism — a live control-channel flag starts off — rather than about
    /// the file.
    static func fastMode(account: AgentAccount, projectDirectory: String?) -> Bool? {
        for layer in layers(account: account, projectDirectory: projectDirectory) {
            if let value = snapshot(at: layer.url).fastMode { return value }
        }
        return nil
    }

    /// The `statusLine` command that would run for this account in this project.
    ///
    /// Only `type: "command"` runs; any other shape draws nothing, so there is nothing to
    /// silence. See `ClaudeStatusLineSettings`, which owns what is done with it.
    static func statusLineCommand(account: AgentAccount, projectDirectory: String) -> String? {
        for layer in layers(account: account, projectDirectory: projectDirectory) {
            if let command = snapshot(at: layer.url).statusLineCommand { return command }
        }
        return nil
    }

    /// Drops the memo, so a test can watch the same path answer differently and a reset re-reads.
    static func forgetAll() {
        cache.withLock { $0.snapshots.removeAll() }
    }

    // MARK: - Private Methods

    private struct Layer {
        let source: Source
        let url: URL
    }

    /// The files the CLI reads, most specific first. A project-less caller — the composer before
    /// a project is chosen — gets the two layers that do not depend on one.
    private static func layers(account: AgentAccount, projectDirectory: String?) -> [Layer] {
        var layers = [
            Layer(source: .managed, url: URL(fileURLWithPath: ClaudeSettingsDefaults.managedSettingsPath))
        ]

        if let projectDirectory, !projectDirectory.isEmpty {
            let project = URL(fileURLWithPath: projectDirectory)
                .appendingPathComponent(ClaudeSettingsDefaults.projectSettingsDirectory)
            layers.append(Layer(
                source: .local,
                url: project.appendingPathComponent(ClaudeSettingsDefaults.localSettingsFile)
            ))
            layers.append(Layer(
                source: .project,
                url: project.appendingPathComponent(ClaudeSettingsDefaults.settingsFile)
            ))
        }

        layers.append(Layer(
            source: .user,
            url: URL(fileURLWithPath: account.configPath)
                .appendingPathComponent(ClaudeSettingsDefaults.settingsFile)
        ))
        return layers
    }

    /// What this file states, from the memo when the file has not changed since it was read.
    private static func snapshot(at url: URL) -> Snapshot {
        let stamp = stamp(of: url)
        let path = url.path

        if let cached = cache.withLock({ $0.snapshots[path] }), cached.stamp == stamp {
            return cached.snapshot
        }

        let snapshot = read(at: url)
        cache.withLock { state in
            if state.snapshots.count >= maximumCachedFiles { state.snapshots.removeAll() }
            state.snapshots[path] = CachedSnapshot(stamp: stamp, snapshot: snapshot)
        }
        return snapshot
    }

    /// An absent file is `.missing` rather than an error: three of the four layers are absent on
    /// an ordinary machine, and a miss is cached like any other reading.
    private static func stamp(of url: URL) -> Stamp {
        guard let values = try? url.resourceValues(
            forKeys: [.contentModificationDateKey, .fileSizeKey]
        ) else { return .missing }

        return Stamp(modified: values.contentModificationDate, size: values.fileSize)
    }

    /// Every fact this app reads out of one settings file. A file that will not parse states
    /// nothing — the CLI ignores an invalid settings file in `--print` mode too.
    private static func read(at url: URL) -> Snapshot {
        guard let data = try? BoundedFileReader.read(
            url,
            maximumBytes: ClaudeSettingsDefaults.maxSettingsBytes
        ), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .empty }

        var snapshot = Snapshot()

        let permissions = json[ClaudeSettingsDefaults.permissionsKey] as? [String: Any]
        if let mode = permissions?[ClaudeSettingsDefaults.defaultModeKey] as? String, !mode.isEmpty {
            snapshot.permissionMode = mode
        }

        snapshot.fastMode = json[AgentDefaults.claudeFastModeKey] as? Bool

        if let statusLine = json[ClaudeSettingsDefaults.statusLineKey] as? [String: Any],
           statusLine[ClaudeSettingsDefaults.typeKey] as? String == ClaudeSettingsDefaults.commandType,
           let command = statusLine[ClaudeSettingsDefaults.commandKey] as? String,
           !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            snapshot.statusLineCommand = command
        }

        return snapshot
    }
}
