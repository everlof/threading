import Foundation
import os

/// One provider-native reasoning level an installed runtime says a model can use.
struct AgentReasoningLevel: Equatable {
    let effort: String
    let description: String

    /// Provider config values are stable machine identifiers; the UI uses familiar names while
    /// preserving an unfamiliar future value rather than dropping it.
    var displayName: String {
        switch effort {
        case "low": return L10n.string("Light")
        case "medium": return L10n.string("Medium")
        case "high": return L10n.string("High")
        case "xhigh": return L10n.string("Extra High")
        case "max": return L10n.string("Max")
        case "ultra": return L10n.string("Ultra")
        default:
            return effort
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
                .capitalized
        }
    }
}

/// The model a conversation runs when nothing pinned one, and where that name was read from.
///
/// `identifier` is nil when no source can name it — an account that configures no model whose
/// runtime has not announced one yet — which is the one case a caller must render as a generic
/// "Default model" rather than guessing the CLI's own fallback.
struct ResolvedDefaultModel: Equatable {

    /// Which source answered. Both mean "the CLI picks"; only one of them is a setting the user
    /// can go and look at, so they are qualified differently on screen.
    enum Source: Equatable {
        /// The `model` key in the account's own `settings.json` (Claude) or `config.toml`
        /// (Codex), or failing that its organisation's default.
        case accountConfiguration
        /// The id this session's runtime announced when it started.
        case reportedByRuntime
        /// What this account's runtime resolved an unpinned session to on an earlier run. A
        /// report about the past, not a setting, and qualified differently on screen for it.
        case rememberedFromEarlierRun
    }

    var identifier: String?
    var source: Source

    /// The model this may be *metered* by, which is narrower than the one it may be named after.
    ///
    /// A scoped window wrongly applied puts a session in the red over a model it is not running,
    /// so only sources that speak for the session itself qualify: what the runtime reported, and
    /// what the account is configured to run. An earlier run is a recollection — good enough to
    /// print beside "last used", not good enough to charge a Fable window against.
    var meteredIdentifier: String? {
        switch source {
        case .accountConfiguration, .reportedByRuntime: return identifier
        case .rememberedFromEarlierRun: return nil
        }
    }
}

/// One model the installed CLI says the current account can use.
struct AgentModelOption: Equatable {
    let identifier: String
    let displayName: String

    /// The catalog's request id for its Fast tier (`priority` today), when this model offers
    /// one. This is deliberately not inferred from the model name: Fast is a service tier,
    /// while Spark and other low-latency models are separate model choices.
    let fastServiceTier: String?

    /// The service tier Codex selects when no caller overrides it.
    let defaultServiceTier: String?

    /// The model's own fallback and the exact reasoning levels this account may select.
    ///
    /// These are catalog data, not a hard-coded enum: Sol and Terra currently expose Ultra,
    /// Luna stops at Max, and older models stop at Extra High.
    let defaultReasoningLevel: String?
    let reasoningLevels: [AgentReasoningLevel]

    init(
        identifier: String,
        displayName: String,
        fastServiceTier: String?,
        defaultServiceTier: String?,
        defaultReasoningLevel: String? = nil,
        reasoningLevels: [AgentReasoningLevel] = []
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.fastServiceTier = fastServiceTier
        self.defaultServiceTier = defaultServiceTier
        self.defaultReasoningLevel = defaultReasoningLevel
        self.reasoningLevels = reasoningLevels
    }

    var supportsFastMode: Bool { fastServiceTier != nil }

    func supports(reasoningEffort: String?) -> Bool {
        guard let reasoningEffort else { return true }
        return reasoningLevels.contains { $0.effort == reasoningEffort }
    }
}

/// The model choices offered when starting or reconfiguring a session.
///
/// Claude documents stable aliases. Codex publishes a per-account model catalog, which is a
/// better source than either a hard-coded list or the one model currently named in config:
/// it carries visibility, display names, and which models actually offer Fast mode.
enum AgentModels {
    /// Provider-owned cache/config files are local input, not trusted allocation sizes. The
    /// catalog is the only genuinely large document; scalar settings should stay tiny.
    private static let maximumProviderSettingsBytes = 1024 * 1024
    private static let maximumProviderCatalogBytes = 16 * 1024 * 1024

    /// The CLIs' own files, remembered per write rather than per call.
    ///
    /// Each of these was read, parsed and re-derived on every single call before. That is
    /// affordable from a menu and ruinous from the terminal-output path, which is where
    /// `AgentWorkloadMonitor` put `.claude.json`: see `ProviderSettingsFileCache` for the
    /// measurements and for why identity is checked rather than timed.
    private static let claudeStateCache = ProviderSettingsFileCache<ClaudeStateReading>()
    private static let claudeSettingsCache = ProviderSettingsFileCache<[String: String]>()
    private static let codexConfigCache = ProviderSettingsFileCache<[String: String]>()

    /// Drops every remembered provider file. Freshness never needs this — identity already
    /// guarantees it — but a test wants a defined starting point.
    static func forgetCachedProviderFiles() {
        claudeStateCache.invalidate()
        claudeSettingsCache.invalidate()
        codexConfigCache.invalidate()
    }

    // MARK: - Public Methods

    /// Selectable models for an agent on a given account. Empty means "whatever the CLI
    /// defaults to", which the composer shows as the only option.
    static func available(for kind: AgentKind, account: AgentAccount?) -> [String] {
        options(for: kind, account: account).map(\.identifier)
    }

    static func options(for kind: AgentKind, account: AgentAccount?) -> [AgentModelOption] {
        switch kind {
        case .claude:
            // The documented aliases: they track the latest of each tier, so they stay right as
            // new versions ship and are what a user recognises. Anything the CLI has cached for
            // *this login* joins them, which is the only way a model no alias names —
            // `claude-fable-5[1m]` today, an org's grant tomorrow — reaches the menu at all.
            let aliases = AgentDefaults.claudeModels.map { identifier in
                claudeOption(
                    identifier: identifier,
                    displayName: ModelName.display(for: identifier)
                )
            }
            let known = Set(aliases.map(\.identifier))
            let cached = claudeAdditionalModels(account: account)
                .filter { !known.contains($0.identifier) }
            return byCapability(aliases + cached, aliases: known)
                .map { versioned($0, for: kind, account: account) }
        case .codex:
            let catalog = codexCatalog(account: account)
            if !catalog.isEmpty { return catalog }

            // The cache is populated by Codex itself and may not exist before its first run.
            // Retain the old honest fallback in that case: offer the configured model, never
            // invent identifiers that would fail only after the user sends a turn.
            return configuredCodexModel(account: account).map {
                [
                    AgentModelOption(
                        identifier: $0,
                        displayName: ModelName.display(for: $0),
                        fastServiceTier: nil,
                        defaultServiceTier: nil
                    )
                ]
            } ?? []
        case .grok, .openCode, .cursor:
            // These runtimes own their own catalogs. Grok's and OpenCode's TUIs publish live and
            // custom models; Cursor answers 34 of them inside its ACP `session/new` result, in
            // one of two mutually exclusive id spaces. An empty host catalog means the composer
            // leaves the model unset and the runtime chooses honestly.
            return []
        }
    }

    /// The catalogue rows offered by a new-session picker after the owner has hidden models.
    ///
    /// Visibility is per provider-qualified login. The account's inherited default always stays
    /// offered: hiding it would leave an "Auto" launch resolving to a model absent from the very
    /// picker that explains Auto. A caller may additionally preserve an explicit in-progress
    /// choice so changing visibility elsewhere never strands the current composer state.
    @MainActor
    static func visibleOptions(
        for kind: AgentKind,
        account: AgentAccount?,
        preserving modelIDs: Set<String> = []
    ) -> [AgentModelOption] {
        let inherited = defaultModel(for: kind, account: account)
        // A configured default may be a dated or long-context variant the provider's ordinary
        // picker catalogue omits. Include it through the same capability sorter as every other
        // row: prepending it in the presentation made the inherited model look like the most
        // capable choice even when a higher tier was available.
        let options = options(for: kind, account: account, including: inherited)
        let accountID = AccountID(
            provider: kind,
            handle: account?.handle ?? .standard
        )
        let hidden = AccountPreferencesStore.shared.hiddenModelIDs(for: accountID)
        guard !hidden.isEmpty else { return options }

        var preserved = modelIDs
        if let inherited {
            preserved.insert(inherited)
        }
        return applyingVisibility(to: options, hidden: hidden, preserving: preserved)
    }

    /// Pure projection shared by host and remote catalogue tests. Keeping the filter independent
    /// of discovery and defaults storage makes the important rule explicit: hidden rows leave in
    /// catalogue order, while inherited or in-progress rows survive even if their saved id says
    /// otherwise.
    static func applyingVisibility(
        to options: [AgentModelOption],
        hidden: Set<String>,
        preserving modelIDs: Set<String>
    ) -> [AgentModelOption] {
        guard !hidden.isEmpty else { return options }
        return options.filter {
            !hidden.contains($0.identifier) || modelIDs.contains($0.identifier)
        }
    }

    /// The catalog, with `identifier` in it whether or not the catalog knew about it.
    ///
    /// For the menu of a conversation that is *already pinned* to something: a session started
    /// on a model this login's catalog no longer lists — a dated id from a transcript, a grant
    /// since revoked — must still show its own model, or the menu would offer no row matching
    /// what is running and read as though nothing were selected.
    ///
    /// Added through the same ordering as everything else rather than pushed to the front, so a
    /// stranger lands in its tier instead of above the most capable model on offer.
    static func options(
        for kind: AgentKind,
        account: AgentAccount?,
        including identifier: String?
    ) -> [AgentModelOption] {
        let catalog = options(for: kind, account: account)
        guard let identifier,
              !identifier.isEmpty,
              !catalog.contains(where: { $0.identifier == identifier })
        else { return catalog }

        let pinned = option(identifier: identifier, for: kind, account: account)
            ?? AgentModelOption(
                identifier: identifier,
                displayName: ModelName.display(for: identifier),
                fastServiceTier: nil,
                defaultServiceTier: nil
            )
        return byCapability(catalog + [pinned], aliases: aliasIdentifiers(for: kind))
    }

    /// What "leave it to the CLI" resolves to for one conversation, and which source answered.
    ///
    /// Two sources describe the same thing at different removes: the account's config file is
    /// our reading of what the CLI *would* pick, while the id the runtime announces on
    /// `initialised` is what it actually picked. The runtime's answer therefore outranks the
    /// file — but it speaks for the *default* only while the session has pinned nothing, since
    /// after an explicit switch it names that choice instead, and calling the user's own pick
    /// "the account default" would mislead in a way the generic string never did.
    ///
    /// Passed in rather than looked up so this stays pure: the caller knows its session, and
    /// the rule is worth testing without an account directory on disk.
    static func resolvedDefault(
        sessionModel: String?,
        reportedModel: String?,
        configuredModel: String?,
        rememberedModel: String? = nil
    ) -> ResolvedDefaultModel {
        if sessionModel == nil,
           let reportedModel,
           !reportedModel.isEmpty,
           reportedModel != configuredModel {
            return ResolvedDefaultModel(identifier: reportedModel, source: .reportedByRuntime)
        }
        if let configuredModel, !configuredModel.isEmpty {
            return ResolvedDefaultModel(identifier: configuredModel, source: .accountConfiguration)
        }
        // Last, and only as a report: what this login resolved to the last time it ran is
        // evidence rather than configuration, and the service can answer differently tomorrow.
        if let rememberedModel, !rememberedModel.isEmpty {
            return ResolvedDefaultModel(identifier: rememberedModel, source: .rememberedFromEarlierRun)
        }
        return ResolvedDefaultModel(identifier: nil, source: .accountConfiguration)
    }

    /// The model the CLI will use when Threading passes no `--model` flag at all.
    ///
    /// Claude and Codex record this per account, which is what lets the composer name the model
    /// instead of saying "Default" — the chip's whole job is to answer *which model will this
    /// session run on*, and "Default" makes the user go and look it up somewhere else.
    ///
    /// Nil when the account states nothing, where "Default" is the honest answer because the
    /// CLI's own fallback is not ours to predict.
    static func defaultModel(for kind: AgentKind, account: AgentAccount?) -> String? {
        switch kind {
        case .claude:
            return configuredClaudeModel(account: account)
        case .codex:
            return configuredCodexModel(account: account)
        case .grok, .openCode, .cursor:
            return nil
        }
    }

    /// The reasoning effort the CLI inherits for this account when Threading does not override
    /// it. Native sessions use the same launch configuration as terminal sessions, so reading
    /// the account file reports the setting that actually governs the turn.
    static func defaultEffort(for kind: AgentKind, account: AgentAccount?) -> String? {
        switch kind {
        case .claude:
            return configuredClaudeSetting(
                AgentDefaults.claudeEffortKey,
                account: account
            )
        case .codex:
            return configuredCodexValue(
                AgentDefaults.codexReasoningEffortKey,
                account: account
            )
        case .grok, .openCode, .cursor:
            return nil
        }
    }

    /// The effort a turn will actually request or inherit.
    ///
    /// An explicit session choice wins. The account config is next, but only when the selected
    /// model advertises it; changing from Ultra-capable Sol to Luna must not leave an impossible
    /// inherited Ultra label on screen. Without an account setting, the catalog's per-model
    /// default is authoritative.
    static func effectiveEffort(
        for session: AgentSession,
        model: String?,
        account: AgentAccount?
    ) -> String? {
        effectiveEffort(
            selected: session.reasoningEffort,
            kind: session.kind,
            model: model,
            account: account
        )
    }

    /// The effort a not-yet-created session will request or inherit.
    ///
    /// Kept beside the existing-session form so the opening composer and reply composer cannot
    /// disagree about an invalid inherited value after a model change.
    static func effectiveEffort(
        selected: String?,
        kind: AgentKind,
        model: String?,
        account: AgentAccount?
    ) -> String? {
        let option = option(identifier: model, for: kind, account: account)

        if let selected,
           option?.reasoningLevels.isEmpty != false
            || option?.supports(reasoningEffort: selected) == true {
            return selected
        }

        if let configured = defaultEffort(for: kind, account: account),
           option?.reasoningLevels.isEmpty != false
            || option?.supports(reasoningEffort: configured) == true {
            return configured
        }

        return option?.defaultReasoningLevel
    }

    /// The effective Fast setting inherited when a session has no explicit override.
    ///
    /// Two mechanisms, read from the two places their runtimes state them.
    ///
    /// Claude's is a live control-channel flag rather than a service tier, and it starts off —
    /// so unset is a *known* Standard rather than an unknown, and the only thing that can move
    /// it before launch is `fastMode` in a settings layer, which is the key Threading writes
    /// into its own per-session `--settings` file. Reading the account's layers as well is what
    /// keeps a login that turned fast mode on for itself from being reported as Standard.
    ///
    /// Codex's is a service tier, and an account naming a tier that is neither Fast nor Standard
    /// stays nil: that is a posture this control cannot show, and nil is how the caller knows.
    static func defaultFastMode(
        for kind: AgentKind,
        model: String?,
        account: AgentAccount?,
        projectDirectory: String? = nil
    ) -> Bool? {
        if kind.supports(.liveFastModeControl) {
            guard let account else { return false }
            return ClaudeSettings.fastMode(
                account: account,
                projectDirectory: projectDirectory
            ) ?? false
        }

        guard kind.supports(.serviceTierFastMode) else { return nil }

        if let configured = configuredCodexValue(
            AgentDefaults.codexServiceTierKey,
            account: account
        ) {
            switch configured {
            case AgentDefaults.codexFastServiceTierAlias,
                 AgentDefaults.codexFastServiceTier:
                return true
            case AgentDefaults.codexStandardServiceTier:
                return false
            default:
                // Flex and provider-defined tiers are neither Fast nor Standard. Do not
                // mislabel one merely because this UI currently offers those two choices.
                return nil
            }
        }

        guard let option = option(identifier: model, for: .codex, account: account),
              let defaultTier = option.defaultServiceTier
        else { return nil }
        return defaultTier == option.fastServiceTier
    }

    /// Whether a Fast control belongs on screen for this runtime and model at all.
    ///
    /// The two mechanisms answer from different places — a service tier asks the account's
    /// catalog, while a live control channel has no per-account signal to ask and so falls back
    /// to the model family. Both are consulted here rather than in the view, which should only
    /// be deciding whether to show a chip.
    ///
    /// A nil model means "let the account choose", not "there is no model" — the reading
    /// `supports(reasoningEffort:)` already makes. It is resolved here, once, because every
    /// caller that sends nil to mean the configured default (a phone's draft, a report chat, the
    /// Mac composer) shows that default's own Fast control, and the answer has to be that
    /// model's. A create request from the phone was refused with *Unsupported Speed* for exactly
    /// this: the catalogue had said its default model runs Fast, the request left the model to
    /// the account, and the gate answered for a model called nil. Only an account naming no
    /// model at all is genuinely unknown, and unknown stays "no control" rather than a guess.
    ///
    /// The control-channel branch is still Claude's measured family test, because Claude is the
    /// only runtime with that mechanism and no second one has been measured. A runtime granted
    /// `.liveFastModeControl` needs its own answer written here, not inherited from this one.
    static func supportsFastMode(
        kind: AgentKind,
        model: String?,
        account: AgentAccount?
    ) -> Bool {
        let resolvedModel = model ?? defaultModel(for: kind, account: account)
        if kind.supports(.liveFastModeControl) {
            return claudeSupportsFastMode(resolvedModel)
        }
        guard kind.supports(.serviceTierFastMode) else { return false }
        return option(identifier: resolvedModel, for: kind, account: account)?
            .supportsFastMode == true
    }

    /// Whether an explicit reasoning effort can be admitted for a new session.
    ///
    /// A nil model means "let the account choose", not "there is no model". Resolve that
    /// account default before checking its provider-owned effort catalogue so every creation
    /// path accepts the same model/effort pair.
    static func supports(
        reasoningEffort: String?,
        kind: AgentKind,
        model: String?,
        account: AgentAccount?,
        options knownOptions: [AgentModelOption]? = nil
    ) -> Bool {
        guard let reasoningEffort else { return true }
        let resolvedModel = model ?? defaultModel(for: kind, account: account)
        let modelOptions = knownOptions ?? options(for: kind, account: account)
        return option(
            identifier: resolvedModel,
            for: kind,
            account: account,
            among: modelOptions
        )?.supports(reasoningEffort: reasoningEffort) == true
    }

    /// The Fast setting a conversation will actually run with, or nil where "whatever the
    /// account defaults to" is the only honest answer.
    ///
    /// Three sources in the order the user set them, the same shape as `effectiveEffort`: the
    /// conversation's own choice, the app-wide startup policy, and what the runtime's own
    /// configuration says — which for a live control-channel flag includes what *unset* means,
    /// because a flag that starts off is a known Standard. Only an unreadable service tier stays
    /// nil, and it stays nil rather than claiming Standard.
    static func effectiveFastMode(
        for session: AgentSession,
        model: String?,
        account: AgentAccount?,
        projectDirectory: String? = nil,
        startupSpeed: AgentStartupSpeed = .agentSetting
    ) -> Bool? {
        effectiveFastMode(
            selected: session.fastMode,
            kind: session.kind,
            model: model,
            account: account,
            projectDirectory: projectDirectory,
            startupSpeed: startupSpeed
        )
    }

    /// The same resolution for a conversation that does not exist yet, kept beside the
    /// existing-session form for the reason `effectiveEffort`'s pair is: the opening composer
    /// and the reply composer must not disagree about what "leave it alone" resolves to.
    static func effectiveFastMode(
        selected: Bool?,
        kind: AgentKind,
        model: String?,
        account: AgentAccount?,
        projectDirectory: String? = nil,
        startupSpeed: AgentStartupSpeed = .agentSetting
    ) -> Bool? {
        if let selected { return selected }
        if let appDefault = startupSpeed.fastModeOverride { return appDefault }
        return defaultFastMode(
            for: kind,
            model: model,
            account: account,
            projectDirectory: projectDirectory
        )
    }

    /// Whether a Claude model can run in fast mode.
    ///
    /// Fast mode is a live control-channel flag, not a launch flag or a service tier, so it is
    /// not carried on `AgentModelOption` the way Codex's Fast tier is — and there is no live
    /// per-account signal for it either: the stream-json `init` reports `fast_mode_state`
    /// (on/off) but not which models *can* run it. It is an Opus-family capability (measured
    /// against CLI 2.1.218: Opus 4.7/4.8). Matching the family rather than pinning dated ids
    /// keeps this correct as new Opus versions ship, and the CLI is the final arbiter — an
    /// unsupported request is rejected and surfaced — so erring toward offering the control costs
    /// a rejection, not a wrong result. A nil model is treated as incapable, hiding the control
    /// rather than guessing: `supportsFastMode(kind:model:account:)` has already replaced an
    /// omitted model with the account's configured one by the time it asks, so nil here means
    /// the login names no model at all and the CLI's fallback is not ours to predict.
    static func claudeSupportsFastMode(_ model: String?) -> Bool {
        model?.localizedCaseInsensitiveContains(AgentDefaults.claudeFastModeFamily) == true
    }

    static func option(
        identifier: String?,
        for kind: AgentKind,
        account: AgentAccount?
    ) -> AgentModelOption? {
        option(
            identifier: identifier,
            for: kind,
            account: account,
            among: options(for: kind, account: account)
        )
    }

    /// The name a chip or a status line gives `identifier` on this login.
    ///
    /// `ModelName.display` reads the id alone, and an alias's id says no version. This is the
    /// same reading the catalogue's rows get: the alias named after what the login last
    /// watched it resolve to, so the chip that says "Opus 5" and the row that says "Opus 5" are
    /// one answer. Without a login — or a runtime whose models are not aliases — it is the
    /// plain reading.
    static func displayName(for identifier: String, account: AgentAccount?) -> String {
        guard let account,
              account.provider.supports(.modelAliasResolution),
              let resolved = ModelAliasResolutionStore.shared.resolvedModel(
                forLaunched: identifier,
                in: account.id
              ),
              let versioned = ModelName.versionedDisplay(for: identifier, resolvedAs: resolved)
        else { return ModelName.display(for: identifier) }
        return versioned
    }

    private static func option(
        identifier: String?,
        for kind: AgentKind,
        account: AgentAccount?,
        among options: [AgentModelOption]
    ) -> AgentModelOption? {
        guard let identifier, !identifier.isEmpty else { return nil }
        if let known = options.first(where: {
            $0.identifier == identifier
        }) {
            return known
        }

        switch kind {
        case .claude:
            // Settings and transcripts may name a dated or long-context variant that is not a
            // picker row. Claude's effort contract is session-wide, so the resolved model still
            // has real metadata even when its identifier came from outside the host catalog.
            return versioned(
                claudeOption(
                    identifier: identifier,
                    displayName: ModelName.display(for: identifier)
                ),
                for: kind,
                account: account
            )
        case .codex, .grok, .openCode, .cursor:
            return nil
        }
    }

    // MARK: - Private Methods

    /// The menu's order: most capable tier first, and inside a tier the alias before the
    /// variants it stands for.
    ///
    /// The list used to be "whatever `claudeModels` was written in, then whatever the CLI cached
    /// after it", which is two orderings glued together and neither of them the one being read
    /// for. A model picker is a ladder — the question at it is "how much model do I want for
    /// this" — so the row a user reaches for first should be the most capable one the login can
    /// run, and the rest should descend from there. `ModelName.Tier` holds that ranking, checked
    /// against the published tiers rather than invented here.
    ///
    /// The alias leads its tier because it tracks that tier's latest: `Fable` before
    /// `Fable 5 · 1M` states the ordinary choice first and the long-context variant as the
    /// deliberate one. A model in no tier keeps its place at the end, in the order its source
    /// listed it — see `ModelName.tier(of:)` for why it is not guessed into one.
    ///
    /// Sorted on an explicit index rather than by `sort`'s own doing: `sort(by:)` is not stable,
    /// so equal keys would otherwise be free to shuffle between two calls and a menu could
    /// reorder itself between openings with nothing having changed.
    private static func byCapability(
        _ options: [AgentModelOption],
        aliases: Set<String>
    ) -> [AgentModelOption] {
        options.enumerated()
            .map { (key: capabilityKey($0.element, at: $0.offset, aliases: aliases), option: $0.element) }
            .sorted { $0.key < $1.key }
            .map(\.option)
    }

    /// The identifiers that stand for a whole tier rather than one version of it. A switch, not
    /// a capability: this is the same per-runtime catalog knowledge the rest of this file holds,
    /// and the compiler makes a sixth runtime a build error here.
    private static func aliasIdentifiers(for kind: AgentKind) -> Set<String> {
        switch kind {
        case .claude: return Set(AgentDefaults.claudeModels)
        // Codex publishes dated slugs and no aliases; Grok, OpenCode and Cursor publish no host
        // catalog at all. Nothing to lift, so every model sorts on its tier and source order.
        case .codex, .grok, .openCode, .cursor: return []
        }
    }

    private static func capabilityKey(
        _ option: AgentModelOption,
        at offset: Int,
        aliases: Set<String>
    ) -> (tier: Int, variant: Int, offset: Int) {
        (
            // An unranked model sorts past every ranked one, whatever tiers exist.
            ModelName.tier(of: option.identifier)?.rawValue ?? ModelName.Tier.allCases.count,
            aliases.contains(option.identifier) ? 0 : 1,
            offset
        )
    }

    /// Reads `"model"` from the account's `settings.json`, then the organisation's default.
    ///
    /// The default account's settings live in `~/.claude`; an alternate account's live in the
    /// config directory it is routed to, which is exactly what `configPath` holds — so one
    /// path serves both and an account on a different model reports it.
    ///
    /// The org default is consulted only when the user's own file is silent, and never the other
    /// way round: a login that states a model has already overridden its organisation, and
    /// reporting the org's choice there would name a model the session will not run.
    private static func configuredClaudeModel(account: AgentAccount?) -> String? {
        configuredClaudeSetting(AgentDefaults.claudeModelKey, account: account)
            ?? organisationClaudeModel(account: account)
    }

    /// Reads the organisation's default model out of the CLI's own state file.
    ///
    /// Null on every personal login measured, so this is a lead for managed accounts rather than
    /// a fix for ordinary ones. **The value's shape is unverified** — it was null wherever it
    /// could be observed — so a bare string and the two plausible object shapes are all accepted
    /// and anything else reads as absent. Being wrong here costs a miss, never a wrong name.
    private static func organisationClaudeModel(account: AgentAccount?) -> String? {
        claudeStateReading(account: account)?.organisationDefaultModel
    }

    /// The organisation default as it reads in one parsed state file.
    private static func organisationModel(inClaudeState state: [String: Any]) -> String? {
        guard let value = state[AgentDefaults.claudeOrgDefaultModelKey] else { return nil }

        if let identifier = value as? String {
            return identifier.isEmpty ? nil : identifier
        }
        guard let nested = value as? [String: Any] else { return nil }
        for key in AgentDefaults.claudeOrgDefaultNestedKeys {
            if let identifier = nested[key] as? String, !identifier.isEmpty {
                return identifier
            }
        }
        return nil
    }

    /// The models this login may select beyond the documented aliases.
    ///
    /// The CLI's own name for a model is used only where `ModelName` cannot read the id — it
    /// returns an unknown identifier verbatim, and a raw `claude-…-5[1m]` in a menu is worse
    /// than the service's own word for it. Where both know the model, ours wins so one model
    /// reads the same on the chip, the pill and this row. See `cachedModelName`.
    ///
    /// The list is read per entry. It is a menu of independent choices, and the `compactMap`
    /// below already drops an entry with no usable `value` while keeping its neighbours — so
    /// refusing the container for one unreadable element emptied the *whole* extra-model menu
    /// instead of shortening it, and a model the login really offers simply became unpickable.
    private static func claudeAdditionalModels(account: AgentAccount?) -> [AgentModelOption] {
        claudeStateReading(account: account)?.additionalModels ?? []
    }

    /// The extra models as they read in one parsed state file.
    private static func additionalModels(inClaudeState state: [String: Any]) -> [AgentModelOption] {
        guard let entries = WireList.objects(
            state[AgentDefaults.claudeAdditionalModelsKey],
            site: WireListSite.claudeAdditionalModels,
            log: ThreadingLogger.agent
        ) else { return [] }

        return entries.compactMap { entry in
            guard let identifier = entry["value"] as? String, !identifier.isEmpty else {
                return nil
            }
            return claudeOption(
                identifier: identifier,
                displayName: cachedModelName(identifier: identifier, entry: entry)
            )
        }
    }

    /// Ours where the id can be read, so one model reads the same on the chip, the pill and
    /// the row; the service's own words where it cannot.
    ///
    /// The description is preferred to the label because it says more: the CLI caches
    /// `claude-fable-5-1[1m]` with the label "Fable" and the description "Fable 5.1 · Most
    /// capable…", and a row that borrowed the label would drop the version that is the whole
    /// difference between this entry and the alias above it. Only a description in the CLI's
    /// `<name> · <blurb>` shape is read; one without the separator is a blurb alone.
    private static func cachedModelName(identifier: String, entry: [String: Any]) -> String {
        if ModelName.read(identifier) != nil {
            return ModelName.display(for: identifier)
        }
        let described: String? = (entry["description"] as? String).flatMap { description in
            let parts = description.components(
                separatedBy: AgentDefaults.claudeModelDescriptionSeparator
            )
            return parts.count > 1 ? parts[0] : nil
        }
        let name = [described, entry["label"] as? String]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && $0.utf8.count <= AgentDefaults.claudeModelLabelMaximumBytes }
        guard let name else { return ModelName.display(for: identifier) }
        return ModelName.display(serviceLabel: name, for: identifier)
    }

    /// The alias row named after what this login watched it resolve to, or the row as it was.
    ///
    /// The identifier is untouched — the alias is what launches, and that is what keeps the row
    /// following the CLI's latest — and only the name changes, so hiding, sorting and selection
    /// all keep working on the same id. A login that has never launched the alias, a runtime
    /// whose catalogue has no aliases, and an id that names its own version all come back as
    /// they went in.
    private static func versioned(
        _ option: AgentModelOption,
        for kind: AgentKind,
        account: AgentAccount?
    ) -> AgentModelOption {
        guard kind.supports(.modelAliasResolution),
              let account,
              let resolved = ModelAliasResolutionStore.shared.resolvedModel(
                forLaunched: option.identifier,
                in: account.id
              ),
              let name = ModelName.versionedDisplay(for: option.identifier, resolvedAs: resolved)
        else { return option }
        return AgentModelOption(
            identifier: option.identifier,
            displayName: name,
            fastServiceTier: option.fastServiceTier,
            defaultServiceTier: option.defaultServiceTier,
            defaultReasoningLevel: option.defaultReasoningLevel,
            reasoningLevels: option.reasoningLevels
        )
    }

    /// Claude documents one session-level effort set rather than per-model subsets. Attaching
    /// those levels while the provider-specific option is built keeps presentation data-driven:
    /// views still ask the selected model, never the runtime's name.
    private static func claudeOption(
        identifier: String,
        displayName: String
    ) -> AgentModelOption {
        AgentModelOption(
            identifier: identifier,
            displayName: displayName,
            fastServiceTier: nil,
            defaultServiceTier: nil,
            reasoningLevels: AgentDefaults.claudeReasoningEfforts.map {
                AgentReasoningLevel(effort: $0, description: "")
            }
        )
    }

    /// Everything this app reads out of the Claude CLI's own state file.
    ///
    /// Both facts are derived together because both come out of one ~90 KB parse, and that parse
    /// is essentially the entire cost of asking. Deriving them apart would read and parse the
    /// same write of the same file twice to answer two questions about it.
    private struct ClaudeStateReading: Sendable {
        let organisationDefaultModel: String?
        let additionalModels: [AgentModelOption]
    }

    /// The CLI's cached per-account state as this app reads it, or nil when it has never written
    /// one. Re-derived only when the file itself moves.
    private static func claudeStateReading(account: AgentAccount?) -> ClaudeStateReading? {
        guard let account else { return nil }

        let url = URL(fileURLWithPath: account.configPath)
            .appendingPathComponent(AgentDefaults.claudeStateFile)

        return claudeStateCache.value(at: url) { url in
            guard let data = try? BoundedFileReader.read(
                url,
                maximumBytes: maximumProviderSettingsBytes
            ),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }

            return ClaudeStateReading(
                organisationDefaultModel: organisationModel(inClaudeState: json),
                additionalModels: additionalModels(inClaudeState: json)
            )
        }
    }

    private static func configuredClaudeSetting(
        _ key: String,
        account: AgentAccount?
    ) -> String? {
        guard let account else { return nil }

        let url = URL(fileURLWithPath: account.configPath)
            .appendingPathComponent(AgentDefaults.claudeSettingsFile)

        let settings = claudeSettingsCache.value(at: url) { url in
            guard let data = try? BoundedFileReader.read(
                url,
                maximumBytes: maximumProviderSettingsBytes
            ),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }

            // Only the top-level strings. Every caller wants one scalar setting, and keeping
            // just those makes the remembered value `Sendable` instead of a boxed `Any` shared
            // between threads. A non-string value is simply absent, exactly as `as? String`
            // failing made it absent before.
            return json.compactMapValues { $0 as? String }
        }

        guard let value = settings?[key], !value.isEmpty else { return nil }
        return value
    }

    /// Reads `model = "…"` from the account's `config.toml`.
    ///
    /// Parsed with a narrow regex rather than a TOML library: one scalar key is wanted, and a
    /// dependency for it would outweigh the feature.
    private static func configuredCodexModel(account: AgentAccount?) -> String? {
        configuredCodexValue(AgentDefaults.codexModelKey, account: account)
    }

    /// One top-level scalar out of the account's `config.toml`.
    ///
    /// Shared beyond this type because Codex states its permission posture in the same file:
    /// `ResolvedPermissionMode` reads `approval_policy`, `sandbox_mode` and
    /// `approvals_reviewer` through it rather than opening the same file with a second parser
    /// that could disagree about quoting.
    static func configuredCodexValue(
        _ key: String,
        account: AgentAccount?
    ) -> String? {
        guard let account else { return nil }

        let configURL = URL(fileURLWithPath: account.configPath)
            .appendingPathComponent(AgentDefaults.codexConfigFile)

        let assignments = codexConfigCache.value(at: configURL) { url in
            guard let data = try? BoundedFileReader.read(
                url,
                maximumBytes: maximumProviderSettingsBytes
            ), let contents = String(data: data, encoding: .utf8) else { return nil }

            return codexAssignments(in: contents)
        }

        guard let value = assignments?[key], !value.isEmpty else { return nil }
        return value
    }

    /// Every `key = value` in one `config.toml`, the first assignment of a key winning.
    ///
    /// Reading the whole file into a dictionary rather than scanning it once per key is what
    /// lets one parse answer every caller: `ResolvedPermissionMode` alone asks it three
    /// questions in a row, and each used to re-read and re-split the file.
    ///
    /// First-wins reproduces the previous per-key scan, which returned at its first match — and
    /// returned nil when that match was empty rather than looking for a later one. So an empty
    /// value is kept here and refused at the lookup, not skipped while collecting.
    private static func codexAssignments(in contents: String) -> [String: String] {
        var assignments: [String: String] = [:]

        for line in contents.split(separator: "\n") {
            // A `[table]` header carries no `=` and drops out here. Keys *under* one are still
            // collected, exactly as the previous scan matched them wherever they appeared.
            let parts = line.trimmingCharacters(in: .whitespaces).split(
                separator: "=",
                maxSplits: 1
            )
            guard parts.count == 2 else { continue }

            let key = parts[0].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, assignments[key] == nil else { continue }

            assignments[key] = parts[1]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }

        return assignments
    }

    /// The catalogue as last decoded for one login, with the file identity it was read from.
    private struct RememberedCodexCatalog: Sendable {
        var identity: ProviderSettingsFileIdentity
        var options: [AgentModelOption]
    }

    /// Codex rewrites `models_cache.json` in place — truncate, then write — so for about a
    /// millisecond every half-minute (measured on 2026-08-29 with a dozen resident TUIs) the
    /// file is empty. Decoded then, it yields no catalogue, and the configured-model fallback
    /// offers that model with no Fast tier and no effort levels: a phone create landing in that
    /// moment is refused for a speed or effort the catalogue itself advertised. The last
    /// catalogue a login proved it had is the answer across that moment. One entry per account
    /// directory, re-read only when the file's identity moves — which also stops a catalogue
    /// build decoding the same 200 KB once per model option.
    private static let rememberedCodexCatalogs = OSAllocatedUnfairLock(
        initialState: [String: RememberedCodexCatalog]()
    )

    /// A rewrite of a 200 KB cache is over in milliseconds. Keeping the last complete reading
    /// for a few seconds covers truncate-and-rewrite without turning a permanently malformed or
    /// removed cache into an indefinitely stale catalogue.
    private static let codexCatalogRewriteGrace: TimeInterval = 5

    /// Reads the cache Codex writes after resolving the account's live model catalog.
    ///
    /// Hidden/internal models stay hidden. A future catalog can rename the fast service-tier
    /// id without a Threading release because the id is carried through as data.
    private static func codexCatalog(account: AgentAccount?) -> [AgentModelOption] {
        guard let account else { return [] }

        let url = URL(fileURLWithPath: account.configPath)
            .appendingPathComponent(AgentDefaults.codexModelsCacheFile)
        let key = url.path
        let identity = ProviderSettingsFileIdentity(of: url)
        let remembered = rememberedCodexCatalogs.withLock { $0[key] }
        if let remembered, let identity, remembered.identity == identity {
            return remembered.options
        }
        guard let identity else {
            // A missing cache is an account with no live catalogue, not a rewrite observed in
            // progress. Reusing a former login's entry here could offer models that no longer
            // exist after sign-out and recreation at the same path.
            return []
        }
        guard let decoded = decodeCodexCatalog(at: url) else {
            let observedAt = Date()
            guard let remembered,
                  let modified = identity.modified,
                  observedAt.timeIntervalSince(modified) >= -1,
                  observedAt.timeIntervalSince(modified) <= codexCatalogRewriteGrace else {
                return []
            }
            return remembered.options
        }
        rememberedCodexCatalogs.withLock {
            $0[key] = RememberedCodexCatalog(identity: identity, options: decoded)
        }
        return decoded
    }

    /// One read of the file, or nil when it cannot be read or decoded whole.
    private static func decodeCodexCatalog(at url: URL) -> [AgentModelOption]? {
        guard let data = try? BoundedFileReader.read(
            url,
            maximumBytes: maximumProviderCatalogBytes
        ),
              let cache = try? JSONDecoder().decode(CodexModelsCache.self, from: data)
        else { return nil }

        return cache.models
            .filter { $0.visibility == AgentDefaults.codexVisibleModel }
            .map { model in
                let fastTier = model.serviceTiers?.first {
                    $0.name.caseInsensitiveCompare(AgentDefaults.codexFastModeName) == .orderedSame
                }?.id ?? (
                    model.additionalSpeedTiers?.contains(
                        AgentDefaults.codexFastServiceTierAlias
                    ) == true
                        ? AgentDefaults.codexFastServiceTier
                        : nil
                )

                return AgentModelOption(
                    identifier: model.slug,
                    displayName: model.displayName,
                    fastServiceTier: fastTier,
                    defaultServiceTier: model.defaultServiceTier,
                    defaultReasoningLevel: model.defaultReasoningLevel,
                    reasoningLevels: model.supportedReasoningLevels?.map {
                        AgentReasoningLevel(
                            effort: $0.effort,
                            description: $0.description
                        )
                    } ?? []
                )
            }
    }
}

private struct CodexModelsCache: Decodable {
    let models: [Model]

    struct Model: Decodable {
        let slug: String
        let displayName: String
        let visibility: String?
        let additionalSpeedTiers: [String]?
        let serviceTiers: [ServiceTier]?
        let defaultServiceTier: String?
        let defaultReasoningLevel: String?
        let supportedReasoningLevels: [ReasoningLevel]?

        private enum CodingKeys: String, CodingKey {
            case slug, visibility
            case displayName = "display_name"
            case additionalSpeedTiers = "additional_speed_tiers"
            case serviceTiers = "service_tiers"
            case defaultServiceTier = "default_service_tier"
            case defaultReasoningLevel = "default_reasoning_level"
            case supportedReasoningLevels = "supported_reasoning_levels"
        }
    }

    struct ServiceTier: Decodable {
        let id: String
        let name: String
    }

    struct ReasoningLevel: Decodable {
        let effort: String
        let description: String
    }
}
