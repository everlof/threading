import CryptoKit
import Foundation

// MARK: - Claude Status Line Coverage

/// What an account's Claude `statusLine` already draws, so the session's status card can show
/// the facts it leaves out instead of repeating the ones it shows.
///
/// This answers a question that only exists for **terminal** sessions. Claude renders a status
/// line from its interactive TUI; a native conversation runs `--print --output-format
/// stream-json`, where the CLI skips the command entirely. So a native pane has no line to
/// complement and asks nothing here — `GitStatusOverlayView` shows every fact it knows.
///
/// **Coverage cannot be read off the configuration.** The command is the user's own program with
/// the user's own authority: the status line on the machine this was written against shells out
/// to `git -C "$cwd" diff --numstat` and to `curl`, and it ignored the line counts and rate
/// limits handed to it in favour of what it found itself. Its output is therefore not a function
/// of its input, and running it is the only honest way to learn what it prints.
///
/// Two rules follow from that, and both are load-bearing.
///
/// The payload is **entirely real** — every field either carries a true value or is omitted, and
/// none is invented. A status line is commonly a bridge that *caches* what Claude pushes into it:
/// the one here writes `~/Library/Application Support/Claudex/ClaudeStatus/<profile>.json`, which
/// is the file `ClaudeUsageCache` reads back for the account's usage. A probe that fabricated
/// `rate_limits` to see whether they were echoed would have poisoned Threading's own usage source
/// with its own fiction. Passing only truth makes the run indistinguishable from Claude's.
///
/// That rule was checked against the bridge rather than assumed: its `writeCache` opens with
/// `guard let rateLimits = status.rateLimits, rateLimits.containsValue else { return }`, so a
/// payload carrying no `rate_limits` leaves the usage cache untouched. It does append a
/// `<profile>.heartbeat.json` entry recording `rate_limits_present: false` — a different file,
/// which nothing here reads, and the only trace this leaves.
///
/// Coverage is decided by **matching values we already know**, not by parsing the line. If the
/// output contains "Opus 5" then the model is covered; a script that abbreviates it to something
/// unrecognised reads as *not* covered, and the card shows the model a second time. Duplicating a
/// fact is the safe direction for a guess — hiding one the user asked to see is not.
enum ClaudeStatusLineCoverage {

    // MARK: - Types

    /// Which facts an account's status line already puts on screen.
    struct Coverage: Equatable, Codable {
        /// False when the account configures no status line at all — `~/.claude-science` here.
        /// Then nothing is covered, which is also where every failure mode lands.
        var isConfigured = false
        var model = false
        var effort = false
        var fastMode = false
        var branch = false
        var changes = false

        /// The answer for an account with no status line, and the answer on any failure.
        static let none = Coverage()

        /// Whether the card has to add anything at all.
        var coversEverything: Bool {
            model && effort && fastMode && branch && changes
        }
    }

    /// The true facts about one session, used both to build the payload and to recognise the
    /// values in the output. Every field is optional because "we do not know" and "it is not
    /// set" both have to stay distinguishable from a fabricated default.
    struct Facts {
        var modelIdentifier: String?
        var modelDisplayName: String?
        var effort: String?
        var fastMode: Bool?
        var branch: String?
        var linesAdded: Int?
        var linesRemoved: Int?
        var contextTokens: Int?
        var contextWindow: Int?
        var sessionID: String?
        var transcriptPath: String?
        var outputStyle: String?
        var cliVersion: String?
        var worktreeName: String?

        /// The directory the session runs in. Not optional: the command is run *in* it, and a
        /// status line that reads git from `$cwd` needs the real one to answer as it would for
        /// Claude.
        var workingDirectory: String
        var projectDirectory: String
    }

    // MARK: - Public Methods

    /// The coverage already learned for a resolved command, or nil when it has not been run yet.
    ///
    /// Keyed by the command and the CLI version rather than by the account: coverage is a
    /// property of the program, and two accounts pointing at one script share the answer. The
    /// version participates because a newer CLI can add a field the script starts printing.
    static func cached(command: String, cliVersion: String?) -> Coverage? {
        guard let stored = cache[fingerprint(command: command, cliVersion: cliVersion)],
              let data = stored.data(using: .utf8),
              let coverage = try? JSONDecoder().decode(Coverage.self, from: data)
        else { return nil }

        return coverage
    }

    /// Resolves the account's status line and learns what it covers, off the main thread.
    ///
    /// `completion` fires only when the answer changed something a caller would redraw for, so a
    /// card can reload rather than poll. An account with no status line answers `.none`
    /// immediately and never spawns anything.
    @MainActor
    static func resolve(
        account: AgentAccount?,
        facts: Facts,
        completion: @escaping @MainActor @Sendable (Coverage) -> Void
    ) {
        guard let account else { return completion(.none) }

        guard let command = resolvedCommand(account: account, projectDirectory: facts.projectDirectory)
        else { return completion(.none) }

        if let known = cached(command: command, cliVersion: facts.cliVersion) {
            return completion(known)
        }

        // Read on the main actor and carried in: the shell path comes from the profile store,
        // which the background work must not reach into. Same rule as `AccountEmailProbe`.
        let shell = AgentLauncher.loginShellPath
        let fingerprint = fingerprint(command: command, cliVersion: facts.cliVersion)

        DispatchQueue.global(qos: .utility).async {
            let coverage = measure(
                command: command,
                account: account,
                facts: facts,
                shell: shell
            )

            DispatchQueue.main.async {
                cache[fingerprint] = encode(coverage)
                completion(coverage)
            }
        }
    }

    // MARK: - Settings Resolution

    /// The exact silencing wrapper the launcher writes when the user suppresses the line: the
    /// account's own command still runs — these commands are commonly bridges whose side
    /// effects matter, Claudex's usage cache being the live example — but nothing reaches the
    /// terminal. A brace group so a command that is itself a pipeline or list wraps whole,
    /// and stderr silenced too: a suppressed line must not degrade into a stray error line.
    ///
    /// Verified against the real bridge (2026-07-31): wrapped, it still rewrote its heartbeat
    /// while printing nothing. `type: "none"` was tried first and is a trap — the CLI schema-
    /// rejects the whole settings file, which would take the permission hooks down with it.
    static func silencedCommand(wrapping command: String) -> String {
        "{ \(command) ; } >/dev/null 2>&1"
    }

    /// The `statusLine` command that would run for this account in this project.
    ///
    /// The CLI's own order, which is *not* a merge for this key: a managed policy replaces the
    /// user's value outright (`policySettings.statusLine` is read *instead of* it), while the
    /// three writable layers override one another most-specific-first. Only `type: "command"`
    /// runs; any other shape draws nothing and so covers nothing.
    ///
    /// Internal rather than private since the launcher resolves the same answer to build the
    /// suppression wrapper — one resolution, two consumers, no drift.
    static func resolvedCommand(account: AgentAccount, projectDirectory: String) -> String? {
        if let managed = statusLine(inSettingsAt: URL(fileURLWithPath: ClaudeSettingsDefaults.managedSettingsPath)) {
            return managed
        }

        let project = URL(fileURLWithPath: projectDirectory)
            .appendingPathComponent(ClaudeSettingsDefaults.projectSettingsDirectory)

        let layers = [
            project.appendingPathComponent(ClaudeSettingsDefaults.localSettingsFile),
            project.appendingPathComponent(ClaudeSettingsDefaults.settingsFile),
            URL(fileURLWithPath: account.configPath)
                .appendingPathComponent(ClaudeSettingsDefaults.settingsFile)
        ]

        for layer in layers {
            if let command = statusLine(inSettingsAt: layer) { return command }
        }

        return nil
    }

    private static func statusLine(inSettingsAt url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              data.count <= ClaudeSettingsDefaults.maxSettingsBytes,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let statusLine = json[ClaudeSettingsDefaults.statusLineKey] as? [String: Any],
              statusLine[ClaudeSettingsDefaults.typeKey] as? String == ClaudeSettingsDefaults.commandType,
              let command = statusLine[ClaudeSettingsDefaults.commandKey] as? String,
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }

        return command
    }

    // MARK: - Private Methods — Measurement

    /// Runs the command exactly as Claude would and reads which known values came back.
    private static func measure(
        command: String,
        account: AgentAccount,
        facts: Facts,
        shell: String
    ) -> Coverage {
        guard let output = run(command: command, account: account, facts: facts, shell: shell)
        else { return Coverage(isConfigured: true) }

        return coverage(inOutput: output, facts: facts)
    }

    /// What the status line printed, with SGR sequences removed.
    ///
    /// Claude's own handling, reproduced: stdout trimmed, split on newlines, blank lines dropped
    /// and the rest rejoined — a status line may be several lines and every non-empty one shows.
    /// Colour is then stripped, because a truecolor escape around a model name must not stop the
    /// name from being recognised.
    private static func run(
        command: String,
        account: AgentAccount,
        facts: Facts,
        shell: String
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.currentDirectoryURL = URL(fileURLWithPath: facts.workingDirectory)

        // The account is selected the way a launch selects one, so the command sees the config
        // directory it would see under Claude — the bridge here keys its cache off exactly that.
        let redirect = account.isDefault
            ? "env -u \(AgentKind.claude.accountEnvironmentKey)"
            : "env \(AgentKind.claude.accountEnvironmentKey)='\(account.configPath)'"

        process.arguments = ["-l", "-c", "\(redirect) \(command)"]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        guard let payload = payload(facts: facts, account: account) else { return nil }

        let input = Pipe()
        process.standardInput = input

        do {
            try process.run()
        } catch {
            ThreadingLogger.agent.error(
                "Could not run the status line to read its coverage: \(error.localizedDescription)"
            )
            return nil
        }

        // Written and closed before the pipe is drained: the command reads stdin to EOF — the
        // one here opens with `input=$(cat)` — and never writes a byte until it has it.
        input.fileHandleForWriting.write(payload)
        try? input.fileHandleForWriting.close()

        // Read before waiting: a full pipe buffer with nobody draining it deadlocks the child.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8)
        else { return nil }

        let lines = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        return lines.isEmpty ? nil : strippingANSI(lines.joined(separator: "\n"))
    }

    /// Removes CSI sequences, which is every colour a status line uses.
    ///
    /// Deliberately not a terminal parser: nothing here renders the line, so the only job is to
    /// stop `ESC[38;2;0;153;255m` from splitting "Opus 5" away from a match.
    static func strippingANSI(_ text: String) -> String {
        var result = ""
        var remainder = Substring(text)

        while let escape = remainder.firstIndex(of: "\u{1B}") {
            result += remainder[remainder.startIndex..<escape]
            var index = remainder.index(after: escape)

            // CSI: ESC [ parameters, then one final byte in @–~.
            guard index < remainder.endIndex, remainder[index] == "[" else {
                remainder = remainder[index...]
                continue
            }

            index = remainder.index(after: index)
            while index < remainder.endIndex, !("@"..."~").contains(remainder[index]) {
                index = remainder.index(after: index)
            }

            remainder = index < remainder.endIndex ? remainder[remainder.index(after: index)...] : ""
        }

        return result + remainder
    }

    /// Which known values the line already shows.
    ///
    /// Every test is a search for a value Threading holds anyway, so a match means the user is
    /// looking at that fact right now. The model is matched on its display name *and* its
    /// identifier, because a script may print either.
    static func coverage(inOutput output: String, facts: Facts) -> Coverage {
        var coverage = Coverage(isConfigured: true)
        let haystack = output.lowercased()

        func mentions(_ value: String?) -> Bool {
            guard let value, value.count >= CoverageDefaults.minimumMatchLength else { return false }
            return haystack.contains(value.lowercased())
        }

        coverage.model = mentions(facts.modelDisplayName) || mentions(facts.modelIdentifier)
        coverage.effort = mentions(facts.effort)
        coverage.branch = mentions(facts.branch) || mentions(facts.worktreeName)

        // Fast mode has no value to look for when it is off — an absent word is what "off" and
        // "not shown" both look like — so only the on state can be recognised.
        if facts.fastMode == true {
            coverage.fastMode = CoverageDefaults.fastModeWords.contains { haystack.contains($0) }
        }

        // The counts are matched as the pair a numstat summary prints, either order of sign, so
        // a bare "12" somewhere in a token total cannot pass for a diff stat.
        if let added = facts.linesAdded, let removed = facts.linesRemoved, added + removed > 0 {
            coverage.changes = haystack.contains("+\(added)") && haystack.contains("\(removed)")
        }

        return coverage
    }

    // MARK: - Private Methods — Payload

    /// The stdin document, carrying only what is true.
    ///
    /// The shape is Claude 2.1.220's own (`session_id`, `model`, `workspace`, `context_window`,
    /// …). Two families are deliberately **absent** rather than zeroed: `cost`, whose totals are
    /// the CLI's own accumulators and which Threading cannot observe, and `rate_limits`, which a
    /// caching bridge would write to disk as ours. A script reading either gets its own `// 0`
    /// fallback, which is its choice to make; it does not get our invention.
    private static func payload(facts: Facts, account: AgentAccount) -> Data? {
        var model: [String: Any] = [:]
        if let identifier = facts.modelIdentifier { model[PayloadKeys.id] = identifier }
        if let name = facts.modelDisplayName { model[PayloadKeys.displayName] = name }

        var workspace: [String: Any] = [
            PayloadKeys.currentDirectory: facts.workingDirectory,
            PayloadKeys.projectDirectory: facts.projectDirectory,
            PayloadKeys.addedDirectories: []
        ]
        if let worktree = facts.worktreeName { workspace[PayloadKeys.gitWorktree] = worktree }

        var document: [String: Any] = [
            PayloadKeys.currentWorkingDirectory: facts.workingDirectory,
            PayloadKeys.workspace: workspace
        ]

        if !model.isEmpty { document[PayloadKeys.model] = model }
        if let session = facts.sessionID { document[PayloadKeys.sessionID] = session }
        if let transcript = facts.transcriptPath { document[PayloadKeys.transcriptPath] = transcript }
        if let version = facts.cliVersion { document[PayloadKeys.version] = version }
        if let style = facts.outputStyle {
            document[PayloadKeys.outputStyle] = [PayloadKeys.name: style]
        }
        if let fastMode = facts.fastMode { document[PayloadKeys.fastMode] = fastMode }
        if let effort = facts.effort {
            document[PayloadKeys.effort] = [PayloadKeys.level: effort]
        }

        if let tokens = facts.contextTokens, let window = facts.contextWindow, window > 0 {
            let used = Double(tokens) / Double(window) * 100
            document[PayloadKeys.contextWindow] = [
                PayloadKeys.contextWindowSize: window,
                PayloadKeys.totalInputTokens: tokens,
                PayloadKeys.usedPercentage: used,
                PayloadKeys.remainingPercentage: max(0, 100 - used)
            ]
            document[PayloadKeys.exceeds200k] = tokens > CoverageDefaults.largeContextThreshold
        }

        return try? JSONSerialization.data(withJSONObject: document)
    }

    // MARK: - Private Methods — Cache

    /// Learned coverage, keyed by command fingerprint. On `.standard` rather than
    /// `PreferenceStore`: this records what a program does, not a choice the user made, so a
    /// test that fills it is not rewriting the developer's preferences.
    private static var cache: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: CoverageDefaults.cacheKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: CoverageDefaults.cacheKey) }
    }

    private static func encode(_ coverage: Coverage) -> String {
        guard let data = try? JSONEncoder().encode(coverage) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func fingerprint(command: String, cliVersion: String?) -> String {
        let material = "\(command)\u{0}\(cliVersion ?? "")\u{0}\(CoverageDefaults.payloadSchemaVersion)"
        return SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Forgets what has been learned. For tests, and for a settings change that should re-ask.
    static func forgetAll() {
        UserDefaults.standard.removeObject(forKey: CoverageDefaults.cacheKey)
    }
}

// MARK: - Defaults

enum ClaudeSettingsDefaults {
    /// The enterprise layer, which *replaces* the user's `statusLine` rather than merging with it.
    static let managedSettingsPath = "/Library/Application Support/ClaudeCode/managed-settings.json"
    static let projectSettingsDirectory = ".claude"
    static let settingsFile = "settings.json"
    static let localSettingsFile = "settings.local.json"
    static let statusLineKey = "statusLine"
    static let typeKey = "type"
    static let commandKey = "command"
    /// The only shape that draws anything; a `statusLine` of any other type covers nothing.
    static let commandType = "command"
    static let maxSettingsBytes = 1 << 20
}

enum CoverageDefaults {
    static let cacheKey = "claudeStatusLineCoverage"
    /// Bumped when the payload gains a field, since a script may start printing it.
    static let payloadSchemaVersion = 1
    /// Below this a "match" is noise: a one- or two-character effort or branch name would be
    /// found inside some unrelated number.
    static let minimumMatchLength = 3
    static let fastModeWords = ["fast", "⚡"]
    static let largeContextThreshold = 200_000
}

private enum PayloadKeys {
    static let sessionID = "session_id"
    static let transcriptPath = "transcript_path"
    static let currentWorkingDirectory = "cwd"
    static let model = "model"
    static let id = "id"
    static let displayName = "display_name"
    static let workspace = "workspace"
    static let currentDirectory = "current_dir"
    static let projectDirectory = "project_dir"
    static let addedDirectories = "added_dirs"
    static let gitWorktree = "git_worktree"
    static let version = "version"
    static let outputStyle = "output_style"
    static let name = "name"
    static let fastMode = "fast_mode"
    static let effort = "effort"
    static let level = "level"
    static let contextWindow = "context_window"
    static let contextWindowSize = "context_window_size"
    static let totalInputTokens = "total_input_tokens"
    static let usedPercentage = "used_percentage"
    static let remainingPercentage = "remaining_percentage"
    static let exceeds200k = "exceeds_200k_tokens"
}
