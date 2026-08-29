import Foundation

/// Best-known command names for the composer before an agent process exists.
///
/// This is presentation metadata, not an execution catalog. Terminal sessions hand the selected
/// text to the agent's own TUI, while native sessions replace these expectations with the live
/// provider catalog before resolving a command-shaped opening message. Account, project, plugin,
/// and skill commands therefore remain discoverable only after their provider has advertised
/// them; guessing those names here would make stale metadata look authoritative.
enum PreSessionComposerCatalog {
    static func capabilities(
        for kind: AgentKind,
        usesNativeUI: Bool
    ) -> [ComposerCapability] {
        switch kind {
        case .claude:
            claude(usesNativeUI: usesNativeUI)
        case .codex:
            codex(usesNativeUI: usesNativeUI)
        case .grok:
            acpExpectations(
                names: grokNames,
                aliases: ["exit": ["quit"]],
                describing: grokDescription(for:),
                policy: GrokACPComposerCatalog.policy,
                usesNativeUI: usesNativeUI
            )
        case .cursor:
            acpExpectations(
                names: cursorNames,
                aliases: [:],
                describing: cursorDescription(for:),
                policy: CursorACPComposerCatalog.policy,
                usesNativeUI: usesNativeUI
            )
        case .openCode:
            openCode()
        }
    }

    // MARK: - Claude

    /// Built-in expectations from Claude Code's documented and measured catalog as of
    /// 2026-08-27. The launch handshake remains the source of truth because installations may
    /// add commands and skills or change this set independently of Threading.
    private static func claude(usesNativeUI: Bool) -> [ComposerCapability] {
        let aliases: [String: [String]] = [
            "background": ["bg"],
            "bug": ["share"],
            "clear": ["reset", "new"],
            "code-review": ["review"],
            "desktop": ["app"],
            "doctor": ["checkup"],
            "exit": ["quit"],
            "loop": ["proactive"],
            "mobile": ["ios", "android"],
            "permissions": ["allowed-tools"],
            "remote-control": ["rc"],
            "resume": ["continue"],
            "rewind": ["checkpoint", "undo"],
            "schedule": ["routines"],
            "tasks": ["bashes"],
            "teleport": ["tp"],
            "usage": ["cost", "stats"]
        ]
        let aliasNames = Set(aliases.values.joined())
        let names = ClaudeComposerCommandPolicy.nativeUnsafeNames
            .union(ClaudeComposerCommandPolicy.turnNames)
            .union(ClaudeComposerCommandPolicy.sessionCommandNames)
            .subtracting(ClaudeComposerCommandPolicy.hiddenNames)
            .subtracting(aliasNames)

        let unavailableReason = L10n.string(
            "Available in Claude Terminal; not safe in native Chat yet"
        )
        return names.sorted().map { name in
            let commandAliases = aliases[name] ?? []
            let isUnsafe = ClaudeComposerCommandPolicy.nativeUnsafeNames.contains(name)
                || commandAliases.contains(where: ClaudeComposerCommandPolicy.nativeUnsafeNames.contains)
            return ComposerCapability(
                id: "pre-session.claude:\(name)",
                name: name,
                description: claudeDescription(for: name),
                aliases: commandAliases,
                kind: .command,
                trigger: .slash,
                presentation: ClaudeComposerCommandPolicy.presentation(
                    for: name,
                    isSkill: false
                ),
                availability: usesNativeUI && isUnsafe
                    ? .unavailable(reason: unavailableReason)
                    : .available
            )
        }
    }

    /// One line per built-in, so the completion row answers "what does this do" rather
    /// than repeating its own name. Wording follows Claude Code 2.1.251's own catalog,
    /// read on 2026-08-29; the launch handshake replaces all of it with whatever the
    /// installation actually advertises, including its skills and project commands.
    private static func claudeDescription(for name: String) -> String {
        switch name {
        case "add-dir": L10n.string("Add another working directory to the session")
        case "advisor": L10n.string("Let Claude consult a stronger model at key moments")
        case "agents": L10n.string("Create and manage subagents")
        case "autofix-pr": L10n.string("Watch the current pull request and fix what breaks")
        case "background": L10n.string("Send this session to the background and free the terminal")
        case "batch":
            L10n.string("Plan a large change, then run it across isolated worktree agents")
        case "branch": L10n.string("Branch the conversation from this point")
        case "btw": L10n.string("Ask a quick side question without interrupting the main thread")
        case "bug": L10n.string("Report a bug or share this conversation")
        case "cd": L10n.string("Move this session to another working directory")
        case "chrome": L10n.string("Open the Claude in Chrome settings")
        case "claude-api": L10n.string("Reference for the Claude API and the Anthropic SDKs")
        case "clear": L10n.string("Start over with empty context; this session stays resumable")
        case "code-review":
            L10n.string("Review the current diff or a pull request for bugs and cleanups")
        case "color": L10n.string("Set the prompt bar color for this session")
        case "compact": L10n.string("Free up context by summarizing the conversation so far")
        case "config": L10n.string("Set one setting by key")
        case "context": L10n.string("Show what is using the context window")
        case "copy": L10n.string("Copy Claude's last response to the clipboard")
        case "dataviz": L10n.string("Guidance for charts and dashboards that read as one system")
        case "debug": L10n.string("Turn on debug logging and help diagnose the problem")
        case "deep-research":
            L10n.string("Fan out web searches, verify the claims, write a cited report")
        case "design": L10n.string("Grant or revoke Claude's access to your Design projects")
        case "design-consent": L10n.string("Grant Claude access to your Design projects")
        case "design-revoke": L10n.string("Revoke Claude's access to your Design projects")
        case "design-sync": L10n.string("Push a React design system to claude.ai/design")
        case "desktop": L10n.string("Continue this session in Claude Desktop")
        case "diff": L10n.string("View uncommitted changes and per-turn diffs")
        case "doctor": L10n.string("Health-check the Claude Code setup and fix what is broken")
        case "effort": L10n.string("Set the effort level for model usage")
        case "exit": L10n.string("Leave the CLI")
        case "export": L10n.string("Export this conversation to a file or the clipboard")
        case "extra-usage": L10n.string("Renamed to /usage-credits")
        case "fast": L10n.string("Turn fast mode on or off")
        case "feedback": L10n.string("Send feedback to Anthropic or report a bug")
        case "fewer-permission-prompts":
            L10n.string("Allowlist the read-only calls that keep prompting you")
        case "focus": L10n.string("Show just your prompt, the summary and the response")
        case "fork":
            L10n.string("Copy this conversation into a background session and keep working here")
        case "goal": L10n.string("Set a goal Claude checks before it stops")
        case "heapdump": L10n.string("Dump the JS heap to the desktop")
        case "help": L10n.string("Show help and the available commands")
        case "hooks": L10n.string("View the hook configuration for tool events")
        case "ide": L10n.string("Manage the IDE integrations and show their status")
        case "init": L10n.string("Write a CLAUDE.md documenting this codebase")
        case "insights": L10n.string("Report on how your Claude Code sessions have gone")
        case "install-github-app": L10n.string("Set up Claude GitHub Actions for a repository")
        case "install-slack-app": L10n.string("Install the Claude Slack app")
        case "keybindings": L10n.string("Open your keyboard shortcuts file")
        case "login": L10n.string("Sign in with your Anthropic account")
        case "logout": L10n.string("Sign out of your Anthropic account")
        case "loop": L10n.string("Run a prompt or command again on an interval")
        case "mcp": L10n.string("Manage the MCP servers")
        case "memory": L10n.string("Edit the CLAUDE.md files and memory settings")
        case "mobile": L10n.string("Show the QR code for the Claude mobile app")
        case "model": L10n.string("Choose or inspect the active model")
        case "passes": L10n.string("Share a free week of Claude Code with friends")
        case "permissions": L10n.string("Manage the allow and deny rules for tools")
        case "plan": L10n.string("Enter plan mode, or view this session's plan")
        case "plugin": L10n.string("Manage the Claude Code plugins")
        case "powerup": L10n.string("Learn Claude Code features through short interactive lessons")
        case "privacy-settings": L10n.string("View and update your privacy settings")
        case "radio": L10n.string("Listen to Claude FM")
        case "recap": L10n.string("Write a one-line recap of the session now")
        case "release-notes": L10n.string("View the release notes")
        case "reload-plugins": L10n.string("Activate the pending plugin changes in this session")
        case "reload-skills": L10n.string("Pick up skills added or changed on disk")
        case "remote-control": L10n.string("Control this session from your phone or claude.ai/code")
        case "remote-env": L10n.string("Choose the default environment for cloud agents")
        case "rename": L10n.string("Rename this conversation")
        case "resume": L10n.string("Resume an earlier conversation")
        case "rewind":
            L10n.string("Restore the code, the conversation, or both to an earlier point")
        case "run": L10n.string("Launch and drive this project's app to see a change working")
        case "run-skill-generator":
            L10n.string("Write the per-project skill that says how to run this app")
        case "sandbox": L10n.string("Configure the sandbox for shell commands")
        case "schedule": L10n.string("Create and manage scheduled cloud agents")
        case "scroll-speed": L10n.string("Adjust the mouse wheel scroll speed")
        case "security-review":
            L10n.string("Review the branch's pending changes for security problems")
        case "settings": L10n.string("Open the settings")
        case "simplify": L10n.string("Clean the changed code up for reuse and simplicity")
        case "skills": L10n.string("List the available skills")
        case "status": L10n.string("Show the version, model, account and tool status")
        case "statusline": L10n.string("Set up the status line")
        case "stickers": L10n.string("Order Claude Code stickers")
        case "stop": L10n.string("Stop this background session and keep its transcript")
        case "subtask": L10n.string("Send a subagent off with your full context")
        case "tasks": L10n.string("View and manage everything running in the background")
        case "team-onboarding":
            L10n.string("Write a guide that helps teammates ramp on Claude Code")
        case "teleport": L10n.string("Send this session to the cloud, or bring one back")
        case "tui": L10n.string("Choose the terminal UI renderer")
        case "ultrareview": L10n.string("Find and verify bugs in your branch, in the cloud")
        case "upgrade": L10n.string("Upgrade to Max for higher limits and more Opus")
        case "usage": L10n.string("Show session cost, plan usage and what is filling your limits")
        case "usage-credits": L10n.string("Configure usage credits, or ask your admin for them")
        case "verify": L10n.string("Exercise a change end to end and observe what it really does")
        case "web-setup": L10n.string("Set up Claude Code on the web with your GitHub account")
        case "workflows": L10n.string("Browse the running and completed workflows")
        default: L10n.string("Availability is checked when Claude Code starts")
        }
    }

    // MARK: - Codex

    private static func codex(usesNativeUI: Bool) -> [ComposerCapability] {
        CodexComposerCatalog.builtIns.map { capability in
            ComposerCapability(
                id: "pre-session.\(capability.id)",
                name: capability.name,
                displayName: capability.displayName,
                description: capability.description,
                argumentHint: capability.argumentHint,
                aliases: capability.aliases,
                kind: capability.kind,
                isAvailableInSkillCatalog: false,
                trigger: capability.trigger,
                presentation: capability.presentation,
                availability: usesNativeUI ? capability.availability : .available
            )
        }
    }

    // MARK: - ACP

    private static func acpExpectations(
        names: Set<String>,
        aliases: [String: [String]],
        describing: (String) -> String,
        policy: ACPCommandCatalogPolicy,
        usesNativeUI: Bool
    ) -> [ComposerCapability] {
        let aliasNames = Set(aliases.values.joined())
        return names.subtracting(aliasNames).sorted().map { name in
            ComposerCapability(
                id: "pre-session.\(policy.identifierPrefix)\(name)",
                name: name,
                description: describing(name),
                aliases: aliases[name] ?? [],
                kind: .command,
                trigger: .slash,
                presentation: policy.sessionCommandNames.contains(name) ? .command : .turn,
                availability: usesNativeUI && policy.hostOnlyNames.contains(name)
                    ? .unavailable(reason: policy.hostOnlyReason)
                    : .available
            )
        }
    }

    /// `hostOnlyNames` is a *denylist* over whatever the live catalog advertises, so it may name
    /// a command the current CLI no longer has — harmless as a refusal, wrong as an expectation.
    /// `/permissions` is one: Grok 1.0.5 advertises neither the name nor a doc entry for it and
    /// offers `/always-approve` instead, so a pre-session row would promise a command that does
    /// not exist. It stays on the denylist in case a later Grok reintroduces it.
    private static let grokNames = GrokACPComposerCatalog.policy.hostOnlyNames
        .union(GrokACPComposerCatalog.policy.sessionCommandNames)
        .subtracting(grokNamesAbsentFromTheCLI)

    private static let grokNamesAbsentFromTheCLI: Set<String> = ["permissions"]

    /// Wording from Grok 1.0.5's own catalog: the four session commands as its ACP `initialize`
    /// reports them, the rest as its slash table words them. Grok replaces all of it with the
    /// live catalog once the handshake lands.
    private static func grokDescription(for name: String) -> String {
        switch name {
        case "always-approve":
            L10n.string("Toggle always-approve mode and skip the permission prompts")
        case "clear", "new": L10n.string("Start a new session")
        case "compact": L10n.string("Compress the history to save context window")
        case "context": L10n.string("Show context window usage and session stats")
        case "exit": L10n.string("Quit the application")
        case "feedback": L10n.string("Send feedback about the current session")
        case "fork": L10n.string("Branch the current session into a peer agent")
        case "login": L10n.string("Log in or re-authenticate with your account")
        case "logout": L10n.string("Log out and return to the login screen")
        case "model": L10n.string("Switch the active model")
        case "resume": L10n.string("Resume a previous session")
        case "session-info": L10n.string("Show the session's model, turns and context usage")
        default: L10n.string("Availability is checked when the agent starts")
        }
    }

    /// Cursor built-ins measured separately from the account/project commands in the pushed
    /// catalog. The live update augments and replaces these after launch.
    private static let cursorNames: Set<String> = [
        "copy-request-id", "create-hook", "create-rule", "create-skill",
        "create-subagent", "loop", "migrate-to-skills", "rename-chat", "sdk", "shell",
        "split-to-prs", "statusline", "update-cli-config"
    ]

    /// Shortened from the `available_commands_update` Cursor pushed on 2026-08-29, keeping only
    /// the built-ins named above: the rest of that catalog is this account's own commands and
    /// cannot be predicted before launch.
    private static func cursorDescription(for name: String) -> String {
        switch name {
        case "copy-request-id": L10n.string("Copy the last request ID to the clipboard")
        case "create-hook": L10n.string("Create a Cursor hook that runs around agent events")
        case "create-rule": L10n.string("Create a Cursor rule for persistent guidance")
        case "create-skill": L10n.string("Create a Cursor Agent Skill")
        case "create-subagent": L10n.string("Create a subagent for a specialized task")
        case "loop": L10n.string("Run a prompt or skill on a recurring interval")
        case "migrate-to-skills":
            L10n.string("Convert Cursor rules and commands into Agent Skills")
        case "rename-chat": L10n.string("Rename the current chat to match its focus")
        case "sdk": L10n.string("Guidance for building on the Cursor SDK")
        case "shell": L10n.string("Run the rest of the line as a literal shell command")
        case "split-to-prs": L10n.string("Split the current work into small reviewable PRs")
        case "statusline": L10n.string("Configure a custom status line in the CLI")
        case "update-cli-config": L10n.string("View and change the Cursor CLI configuration")
        default: L10n.string("Availability is checked when the agent starts")
        }
    }

    // MARK: - OpenCode

    /// OpenCode has only a terminal surface, so its TUI remains the execution authority.
    /// Snapshot: OpenCode's own command registry, read on 2026-08-29. Configured commands are
    /// intentionally absent because they can override built-ins and are loaded by OpenCode
    /// itself at launch.
    private static func openCode() -> [ComposerCapability] {
        let entries: [(String, [String])] = [
            ("compact", ["summarize"]),
            ("connect", []),
            ("details", []),
            ("editor", []),
            ("exit", ["quit", "q"]),
            ("export", []),
            ("help", []),
            ("init", []),
            ("models", []),
            ("new", ["clear"]),
            ("redo", []),
            ("sessions", []),
            ("share", []),
            ("themes", []),
            ("thinking", []),
            ("undo", []),
            ("unshare", [])
        ]
        return entries.map { name, aliases in
            ComposerCapability(
                id: "pre-session.opencode:\(name)",
                name: name,
                description: openCodeDescription(for: name),
                aliases: aliases,
                kind: .command,
                trigger: .slash,
                presentation: .command
            )
        }
    }

    /// Wording from OpenCode's own command registry rather than from its docs, so a row says
    /// what this build does.
    private static func openCodeDescription(for name: String) -> String {
        switch name {
        case "compact": L10n.string("Summarize the session to reduce context size")
        case "connect": L10n.string("Connect a model provider")
        case "details": L10n.string("Show or hide the tool details")
        case "editor": L10n.string("Open the external editor")
        case "exit": L10n.string("Leave OpenCode")
        case "export": L10n.string("Export the session transcript")
        case "help": L10n.string("Open the help dialog")
        case "init": L10n.string("Write an AGENTS.md for this repository")
        case "models": L10n.string("List the available models")
        case "new": L10n.string("Create a new session")
        case "redo": L10n.string("Redo the last undone message")
        case "sessions": L10n.string("List all sessions")
        case "share": L10n.string("Share this session and copy its link")
        case "themes": L10n.string("List the available themes")
        case "thinking": L10n.string("Show or hide the thinking blocks")
        case "undo": L10n.string("Undo the last message")
        case "unshare": L10n.string("Stop sharing this session")
        default: L10n.string("Handled by OpenCode's terminal after launch")
        }
    }
}
