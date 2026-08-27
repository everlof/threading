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
                policy: GrokACPComposerCatalog.policy,
                usesNativeUI: usesNativeUI
            )
        case .cursor:
            acpExpectations(
                names: cursorNames,
                aliases: [:],
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

    private static func claudeDescription(for name: String) -> String {
        switch name {
        case "loop": L10n.string("Run a prompt repeatedly while the session stays open")
        case "compact": L10n.string("Compact the conversation context")
        case "context": L10n.string("Show current context usage")
        case "model": L10n.string("Choose or inspect the active model")
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
        policy: ACPCommandCatalogPolicy,
        usesNativeUI: Bool
    ) -> [ComposerCapability] {
        let aliasNames = Set(aliases.values.joined())
        return names.subtracting(aliasNames).sorted().map { name in
            ComposerCapability(
                id: "pre-session.\(policy.identifierPrefix)\(name)",
                name: name,
                description: L10n.string("Availability is checked when the agent starts"),
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

    private static let grokNames = GrokACPComposerCatalog.policy.hostOnlyNames
        .union(GrokACPComposerCatalog.policy.sessionCommandNames)

    /// Cursor built-ins measured separately from the account/project commands in the pushed
    /// catalog. The live update augments and replaces these after launch.
    private static let cursorNames: Set<String> = [
        "copy-request-id", "create-hook", "create-rule", "create-skill",
        "create-subagent", "loop", "migrate-to-skills", "rename-chat", "sdk", "shell",
        "split-to-prs", "statusline", "update-cli-config"
    ]

    // MARK: - OpenCode

    /// OpenCode has only a terminal surface, so its TUI remains the execution authority.
    /// Snapshot: OpenCode TUI documentation, 2026-08-27. Configured commands are intentionally
    /// absent because they can override built-ins and are loaded by OpenCode itself at launch.
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
                description: L10n.string("Handled by OpenCode's terminal after launch"),
                aliases: aliases,
                kind: .command,
                trigger: .slash,
                presentation: .command
            )
        }
    }
}
