import Foundation

// MARK: - Agent Launch Flag

/// One `--flag value` pair on a launch line, before it is quoted into a `ShellCommand`.
///
/// A plain value so a mode's translation into a runtime's own vocabulary can be asserted
/// directly, without building a command or reading one back out of a quoted string.
struct AgentLaunchFlag: Equatable {
    let name: String
    let value: String
}

// MARK: - Agent Permission Mode

/// How much a session may do before it has to ask.
///
/// One vocabulary for the supported CLIs — **Claude's**, because it is the richer one and,
/// together with Grok, names a single mode rather than a pair of axes. Raw values are Claude's own external
/// flag values, so `rawValue` is what `--permission-mode` takes and a case rename would be a
/// silent reset wherever this is persisted.
///
/// The six and what they *mean* are read from the CLI itself (2.1.220) rather than assumed —
/// its fallback-decision table is one function, and it is not the table you would guess:
///
/// ```js
/// if (mode === "auto")              return "classify";
/// if (mode === "bypassPermissions") return "allow";
/// if (mode === "dontAsk")           return "deny";
///                                   return "ask";
/// ```
///
/// **`dontAsk` denies — it does not approve.** It is the mode that promises never to interrupt
/// you, and it keeps that promise by refusing the tool call and telling the model, not by
/// waving it through. Grouping it with `bypassPermissions` as "the dangerous two" is the
/// obvious mistake; they are opposites that happen to share a symbol in Claude's own UI.
///
/// Codex has no single mode. The same idea is two axes there — when to ask
/// (`--ask-for-approval`) and what may happen without asking (`--sandbox`) — so each case
/// carries the pair it translates to. The six land on six *distinct* Codex configurations,
/// which is what makes one shared vocabulary honest rather than a menu with duplicate items.
enum AgentPermissionMode: String, Codable, CaseIterable, Sendable {
    /// Ask before anything. Claude's internal name for this one is `default`; `manual` is the
    /// external name its own `--help` documents, and the raw value has to be the external one.
    case manual

    case plan
    case acceptEdits
    case auto
    case dontAsk
    case bypassPermissions

    // MARK: - Display

    /// Claude's own display titles, taken from the CLI's mode table so Threading's menu and the
    /// agent's own status line say the same words.
    var displayName: String {
        switch self {
        case .manual: L10n.string("Manual")
        case .plan: L10n.string("Plan")
        case .acceptEdits: L10n.string("Accept Edits")
        case .auto: L10n.string("Auto")
        case .dontAsk: L10n.string("Don't Ask")
        case .bypassPermissions: L10n.string("Bypass Permissions")
        }
    }

    /// One line describing what the mode does, for the menu item's help text.
    var menuDescription: String {
        switch self {
        case .manual:
            L10n.string("Asks before making any change.")
        case .plan:
            L10n.string("Reads and proposes. Changes nothing.")
        case .acceptEdits:
            L10n.string("Edits files without asking. Commands still ask.")
        case .auto:
            L10n.string("Decides for itself when to ask.")
        case .dontAsk:
            L10n.string("Never interrupts — refuses anything that would need approval.")
        case .bypassPermissions:
            L10n.string("No permission checks at all.")
        }
    }

    /// What this mode costs on the agent it is about to run, where that is worth saying before
    /// the choice is made rather than after. Nil where the translation is faithful.
    ///
    /// Codex has no *plan* concept — nothing tells it to produce a plan rather than act — so
    /// Plan there is only the enforceable half of the idea: it cannot write.
    func caveat(for kind: AgentKind) -> String? {
        switch (self, kind) {
        case (.plan, .codex):
            L10n.string("Codex has no plan mode; this stops it writing, but does not ask it to plan.")
        default:
            nil
        }
    }

    // MARK: - Launch Flags

    /// What this mode becomes on one runtime's launch line, in the order the line states it.
    ///
    /// The dispatch lives here rather than in the launcher because everything it chooses
    /// between lives here. It used to be a `switch session.kind` in `AgentLauncher` selecting
    /// among the value properties below, which meant the two had to agree and nothing said so:
    /// a sixth runtime could be given its value property and no launcher branch, or a branch
    /// naming the wrong axis, and both compile. Now the compiler requires the case, and the
    /// case is next to the values it returns.
    ///
    /// Empty for a runtime whose policy Threading does not translate. `AgentLauncher` asks
    /// `AgentKind.supportsPermissionModes` before calling this, so empty is the belt-and-braces
    /// answer rather than the working path.
    func launchFlags(for kind: AgentKind) -> [AgentLaunchFlag] {
        switch kind {
        case .claude:
            return [
                AgentLaunchFlag(
                    name: AgentDefaults.claudePermissionModeFlag,
                    value: claudeFlagValue
                )
            ]

        case .grok:
            return [
                AgentLaunchFlag(
                    name: AgentDefaults.grokPermissionModeFlag,
                    value: grokFlagValue
                )
            ]

        case .codex:
            // Both axes, always together: Codex defaults them independently, so stating one
            // and leaving the other produces a posture that is neither the mode asked for nor
            // the CLI's own.
            return [
                AgentLaunchFlag(
                    name: AgentDefaults.codexApprovalFlag,
                    value: codexApprovalPolicy
                ),
                AgentLaunchFlag(
                    name: AgentDefaults.codexSandboxFlag,
                    value: codexSandboxMode
                )
            ]

        case .openCode:
            // OpenCode owns a richer per-tool policy in `opencode.json`, and its `--auto` is
            // not equivalent to any one of these six. Presenting a false mapping would be
            // worse than leaving that policy where the user set it.
            return []

        case .cursor:
            // Cursor's `agent`/`plan`/`ask` are execution modes, a different axis from these
            // six, and its ACP subcommand takes no flags at all. It claims no
            // `.permissionModes`, so this is the belt-and-braces answer.
            return []
        }
    }

    // MARK: - Claude

    /// The value for `--permission-mode`, which is the raw value by construction.
    var claudeFlagValue: String { rawValue }

    // MARK: - Grok

    /// Grok exposes the same six permission modes. Its manual/default mode is the one spelling
    /// that differs; every other external value is identical to Claude's.
    var grokFlagValue: String {
        self == .manual ? AgentDefaults.agentInternalManualMode : rawValue
    }

    // MARK: - Reading a Runtime's Own Value

    /// The mode a runtime's own value names, or nil when it names none of the six.
    ///
    /// The inverse of the flag values above, and placed beside them for the reason
    /// `launchFlags(for:)` is: the two directions have to agree about every spelling, and one
    /// that differs in only one direction is the bug this adjacency exists to prevent.
    ///
    /// Both `manual` and `default` read as Manual. The second is the spelling the CLIs hand
    /// *back* — see `AgentDefaults.agentInternalManualMode` — so a reader that took only the
    /// external one would report "unknown" for the most common posture there is.
    ///
    /// Codex answers nil by construction rather than by omission: its posture is two axes, so
    /// no single value it emits can name one of these, and a reader would have to be given the
    /// pair — which is `init?(codexApprovalPolicy:sandboxMode:)` below. OpenCode has no shared
    /// vocabulary to read at all.
    ///
    /// Unrecognised is nil rather than a fallback. A newer CLI writing a seventh mode, or a
    /// record this app has never seen, has to read as "we do not know" and leave the surfaces
    /// that ask silent — naming the wrong posture is worse than naming none, and the whole
    /// point of reading an observed value is that it is not a guess.
    init?(externalValue: String, for kind: AgentKind) {
        switch kind {
        case .claude, .grok:
            if let mode = AgentPermissionMode(rawValue: externalValue) {
                self = mode
            } else if externalValue == AgentDefaults.agentInternalManualMode {
                self = .manual
            } else {
                return nil
            }

        case .codex, .openCode, .cursor:
            return nil
        }
    }

    // MARK: - Codex

    /// When Codex must stop and ask.
    ///
    /// `never` is not "approve everything": Codex returns the failure to the model instead of
    /// asking, which is why it serves both `dontAsk` and `bypassPermissions` — what separates
    /// those two is the sandbox below, not this.
    var codexApprovalPolicy: String {
        switch self {
        case .manual, .acceptEdits: AgentDefaults.codexApprovalUntrusted
        case .auto: AgentDefaults.codexApprovalOnRequest
        case .plan, .dontAsk, .bypassPermissions: AgentDefaults.codexApprovalNever
        }
    }

    /// What Codex may do without asking.
    ///
    /// This is the axis that carries most of the meaning: `manual` and `acceptEdits` share an
    /// approval policy and differ only here — read-only must ask to change anything, while
    /// workspace-write may edit inside the project and still escalates for the rest.
    var codexSandboxMode: String {
        switch self {
        case .manual, .plan: AgentDefaults.codexSandboxReadOnly
        case .acceptEdits, .auto, .dontAsk: AgentDefaults.codexSandboxWorkspaceWrite
        case .bypassPermissions: AgentDefaults.codexSandboxFullAccess
        }
    }

    /// The mode a Codex configuration's two axes name together, or nil when they name none of
    /// the six.
    ///
    /// The inverse of the pair above, and exact rather than nearest: the six land on six
    /// *distinct* configurations, so a pair either is one of them or is a posture this
    /// vocabulary cannot state — `on-request` with `read-only`, say, which is neither Auto nor
    /// Plan. Naming the closest one would be the guess this whole file avoids.
    ///
    /// Both axes are required. Codex defaults them independently and this app does not read that
    /// pair of defaults out of the CLI, so a config that states one and leaves the other is a
    /// posture Threading does not know rather than one it may complete.
    init?(codexApprovalPolicy: String?, sandboxMode: String?) {
        guard let codexApprovalPolicy, let sandboxMode else { return nil }

        guard let mode = AgentPermissionMode.allCases.first(where: {
            $0.codexApprovalPolicy == codexApprovalPolicy && $0.codexSandboxMode == sandboxMode
        }) else { return nil }

        self = mode
    }
}
