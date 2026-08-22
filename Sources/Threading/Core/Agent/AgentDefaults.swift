import Foundation

// MARK: - Agent Defaults

enum AgentDefaults {
    static let defaultKind: AgentKind = .claude
    static let untitledSessionName = "New Session"

    /// Name a side chat carries until a prompt or the agent names it.
    static let sideChatTitle = "Side Chat"

    static let claudeExecutable = "claude"
    static let codexExecutable = "codex"
    static let grokExecutable = "grok"
    static let openCodeExecutable = "opencode"

    /// Cursor installs two names for one binary — `agent` and `cursor-agent`. The unambiguous
    /// one is spawned: `agent` is a plausible name for something else on a user's PATH.
    static let cursorExecutable = "cursor-agent"

    /// The hidden subcommand that starts Cursor's Agent Client Protocol server. It takes no
    /// options of its own; everything configurable is a global placed before it.
    static let cursorACPSubcommand = "acp"

    /// Keeps `cursor-agent` from opening the user's browser.
    ///
    /// Measured: ACP `authenticate` answers with a `cursor.com/loginDeepControl?…` URL wrapped
    /// in an `-32602` error, and it gets there by *trying to launch a browser first*. A native
    /// app cannot have a CLI it hosts throwing the user into Safari mid-conversation, so the
    /// child is spawned with a browser that does nothing and with the CLI's own opt-out set.
    /// `/usr/bin/true` rather than an empty value: `BROWSER=""` reads as unset.
    static let cursorLaunchEnvironment = [
        "BROWSER": "/usr/bin/true",
        "NO_OPEN_BROWSER": "1"
    ]

    static let claudeModelFlag = "--model"
    static let codexModelFlag = "--model"
    static let grokModelFlag = "--model"
    static let openCodeModelFlag = "--model"

    /// Runs enabled hooks without the review Codex otherwise requires.
    ///
    /// Named here rather than written inline because of what it does: it un-gates every hook in
    /// the account's config directory for that invocation, not only the ones Threading installed.
    /// It is passed solely when `AppSettings.bypassesCodexHookTrust` is on.
    static let codexBypassHookTrustFlag = "--dangerously-bypass-hook-trust"

    /// How a launch states its permission posture. Claude and Grok name one mode; Codex splits
    /// the same idea across when-to-ask, what-may-happen-without-asking and who reviews a
    /// boundary crossing. `AgentPermissionMode` owns which values travel together.
    static let claudePermissionModeFlag = "--permission-mode"
    static let codexApprovalFlag = "--ask-for-approval"
    static let codexSandboxFlag = "--sandbox"
    static let codexConfigFlag = "--config"
    static let grokPermissionModeFlag = "--permission-mode"

    /// What Claude and Grok call Manual in their own vocabulary. It is Claude's *internal* name
    /// — `manual` is the external one its `--help` documents and the one `AgentPermissionMode`
    /// persists — but it is the spelling both CLIs hand back: Claude's control channel answers
    /// `{"mode":"default"}` to a `manual` request, and its transcript's `permission-mode`
    /// records carry it too. So it is written out, not accepted.
    static let agentInternalManualMode = "default"

    /// The same three axes as the flags above, spelled the way `config.toml` states them. A
    /// session Threading launches without a mode inherits whatever these say, which is what
    /// lets its chip name a posture instead of naming where the answer lives.
    static let codexApprovalPolicyKey = "approval_policy"
    static let codexSandboxModeKey = "sandbox_mode"
    static let codexApprovalsReviewerKey = "approvals_reviewer"

    static let codexApprovalUntrusted = "untrusted"
    static let codexApprovalOnRequest = "on-request"
    static let codexApprovalNever = "never"

    static let codexSandboxReadOnly = "read-only"
    static let codexSandboxWorkspaceWrite = "workspace-write"
    static let codexSandboxFullAccess = "danger-full-access"

    static let codexApprovalsReviewerUser = "user"
    static let codexApprovalsReviewerAutoReview = "auto_review"

    /// Model choices offered for Claude: the aliases its `--help` documents, which track the
    /// latest of each family rather than pinning a dated name.
    ///
    /// All four the CLI accepts, matching the families its own picker lists at the top level
    /// (measured against 2.1.221). `haiku` was missing here for as long as this list existed,
    /// so the fastest model was the one model Threading could not select at all.
    ///
    /// The picker's second tier — dated versions such as Opus 4.6 under "More models" — is
    /// deliberately *not* mirrored. Those ids live only inside the CLI binary, with no local
    /// listing to read and no per-account access filter, so a copy here would be a hand-kept
    /// list that goes stale every release while claiming to be the catalog. An account granted
    /// anything beyond these four surfaces it through `claudeAdditionalModelsKey` instead.
    ///
    /// Written most capable first, which is the order `AgentModels.byCapability` puts them in
    /// anyway. Kept honest here so the constant is not read as a ranking that disagrees with the
    /// menu it feeds.
    static let claudeModels = ["fable", "opus", "sonnet", "haiku"]

    /// Fast mode is an Opus-family capability (measured against CLI 2.1.218). Matching the family
    /// name rather than pinning dated ids keeps the check correct as new Opus versions ship — the
    /// `opus` alias and every full Opus identifier share it.
    static let claudeFastModeFamily = "opus"

    /// Where Claude records the model an account runs on, so the composer can name it rather
    /// than calling it "Default".
    static let claudeSettingsFile = "settings.json"
    static let claudeModelKey = "model"
    static let claudeEffortKey = "effortLevel"
    static let claudeEffortFlag = "--effort"

    /// Claude's persisted speed switch. Threading writes it only into the per-session
    /// `--settings` layer, so choosing a startup speed never edits the account's own file.
    static let claudeFastModeKey = "fastMode"

    /// The session-level values the installed CLI documents for `--effort` (2.1.222).
    /// Unlike Codex, Claude does not publish per-model subsets, so these apply to every model
    /// the same CLI exposes. The string identifiers stay provider-native all the way to launch.
    static let claudeReasoningEfforts = ["low", "medium", "high", "xhigh", "max"]

    /// The CLI's own per-account state file, beside `settings.json` in the same config directory.
    ///
    /// `settings.json` is what the *user* wrote; this is what the CLI cached from the service, so
    /// it answers two questions the settings file cannot: which models beyond the documented
    /// aliases this login may select, and which model its organisation defaults to. Both keys are
    /// undocumented and frequently absent — they were null on two of four logins when this was
    /// measured — so every read of them is strictly additive and a miss changes nothing.
    static let claudeStateFile = ".claude.json"

    /// Models this login can use beyond `claudeModels`, each `{value, label, description}`.
    /// Observed carrying `claude-fable-5[1m]`, which no alias names.
    static let claudeAdditionalModelsKey = "additionalModelOptionsCache"

    /// The model a managed organisation defaults its logins to. Null on personal accounts, which
    /// is why it sits *below* the user's own `settings.json` rather than replacing it.
    static let claudeOrgDefaultModelKey = "orgModelDefaultCache"

    /// The keys an org default has been seen to hide behind when it is an object rather than a
    /// bare string. Tried in order; an unrecognised shape reads as absent.
    static let claudeOrgDefaultNestedKeys = ["model", "value"]

    /// Claude's own switch for its Remote Control bridge, written into the per-session
    /// `--settings` file rather than the account's config: a settings file is read ahead of the
    /// CLI's global config (measured against 2.1.220 — `claude doctor` validates the key from a
    /// `--settings` path), so Threading can override `/config` for one conversation without
    /// touching a file the user owns. There is no launch flag for the off direction:
    /// `--remote-control` only opts in.
    static let claudeRemoteControlKey = "remoteControlAtStartup"

    /// Codex writes the model catalog it receives for each account beside config.toml.
    static let codexConfigFile = "config.toml"
    static let codexModelsCacheFile = "models_cache.json"
    static let codexModelKey = "model"
    static let codexVisibleModel = "list"

    /// One-run override keys and values.
    static let codexCheckForUpdateOnStartupKey = "check_for_update_on_startup"
    static let codexNoAlternateScreenFlag = "--no-alt-screen"
    static let codexReasoningEffortKey = "model_reasoning_effort"
    static let codexResearchReasoningEffort = "low"

    /// The model a headless Claude research run asks for. `sonnet`, and measured rather than
    /// assumed (August 2026, five intent queries incl. one in Swedish, plus the full
    /// MCP round-trip): sonnet matched haiku's wall clock or beat it (5–10s against 7–16s),
    /// answered with every plausible page where haiku often named one, honoured the JSON-only
    /// reply contract that haiku wrapped in a code fence, and cost ~7¢ against ~4¢ per search
    /// — nothing, for a button clicked occasionally. Codex research states no model at all —
    /// its knob is reasoning effort above, because a model name would have to come from the
    /// account's own catalog.
    static let claudeResearchModel = "sonnet"

    /// The model a usage-window poke asks for: the cheapest one there is.
    ///
    /// The opposite trade to `claudeResearchModel`, and for the opposite reason. A research run
    /// is read for its answer, so quality is worth four cents; a poke's answer is discarded
    /// unread and the *only* thing it buys is the window's opening timestamp. Every token it
    /// spends comes out of the weekly limit the poke exists to spend more carefully, so the run
    /// asks the smallest model for the smallest reply it can.
    static let claudePokeModel = "haiku"

    /// What a poke says. One token in, one token out.
    ///
    /// Deliberately not a question: anything Claude might want to *do* about it costs tool calls
    /// and turns. The reply is never read.
    static let usageWindowPokePrompt = "Reply with the single character: ."

    /// Research runs work in a neutral scratch directory, which is not a repository. Codex
    /// refuses to run outside one unless told this is deliberate.
    static let codexSkipGitRepoCheckFlag = "--skip-git-repo-check"
    static let codexServiceTierKey = "service_tier"
    static let codexStandardServiceTier = "default"
    static let codexFastServiceTier = "priority"
    static let codexFastServiceTierAlias = "fast"
    static let codexFastModeFeatureKey = "features.fast_mode"
    static let codexFastModeName = "Fast"

    /// Where Claude records transcripts, relative to an account's config directory.
    static let claudeProjectsSubdirectory = "projects"
    static let claudeSubagentsSubdirectory = "subagents"
    static let transcriptExtension = "jsonl"

    /// Claude names a project's directory after its absolute path, keeping only the characters
    /// below and writing this separator in place of every other one. `ClaudeTranscript` owns the
    /// encoding; these are the two values it is written from.
    static let projectSlugSeparator = "-"
    static let projectSlugPreservedCharacters =
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
}

// MARK: - Agent Environment

/// Everything an agent runner exports about **its own run**, which must not be inherited by the
/// sessions Threading launches.
///
/// A session started from inside another agent's shell would otherwise be handed that
/// conversation's identifiers and treat itself as a nested child of it — and, worse than
/// identity, the *posture* that run was given. `open` forwards its caller's environment through
/// LaunchServices, so a Threading opened from a Codex tool call carried
/// `CODEX_SANDBOX_NETWORK_DISABLED=1` and `CODEX_PERMISSION_PROFILE=:workspace` into every
/// session under it: an agent told the network is off, by a sandbox that ended hours ago.
///
/// Named by family rather than variable by variable, because the failure is silent and the
/// families keep growing — `CODEX_THREAD` was listed and `CODEX_CI` was not, which is the kind of
/// gap nothing reports.
enum AgentEnvironment {
    /// The families. Each is a runner describing a run, never a machine describing itself.
    static let inheritedIdentityPrefixes = [
        "CLAUDE_",
        "CLAUDECODE",
        "CODEX_",
        "GROK_",
        "OPENCODE_",
        "AI_AGENT"
    ]

    /// The exception inside those families: where an account's config lives is a *place*, not a
    /// run, and it is how a launch reaches a login other than the default. `AgentKind` owns the
    /// names, so a new runtime cannot be added and forgotten here — and a runtime that keeps its
    /// login somewhere other than a directory contributes none.
    static var accountConfigKeys: Set<String> {
        Set(AgentKind.allCases.compactMap(\.accountEnvironmentKey))
    }

    static func isInheritedAgentIdentity(_ key: String) -> Bool {
        guard !accountConfigKeys.contains(key) else { return false }
        return inheritedIdentityPrefixes.contains { key.hasPrefix($0) }
    }

    /// The app's environment with inherited agent identity removed, for launches that do not
    /// go through a PTY. `TerminalSession` builds on the same rule and adds terminal-specific
    /// variables a headless run has no use for.
    static func launchEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment

        for key in environment.keys where isInheritedAgentIdentity(key) {
            environment.removeValue(forKey: key)
        }

        return environment
    }
}
