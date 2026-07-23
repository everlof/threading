import Foundation

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

    var supportsFastMode: Bool { fastServiceTier != nil }
}

/// The model choices offered when starting or reconfiguring a session.
///
/// Claude documents stable aliases. Codex publishes a per-account model catalog, which is a
/// better source than either a hard-coded list or the one model currently named in config:
/// it carries visibility, display names, and which models actually offer Fast mode.
enum AgentModels {

    // MARK: - Public Methods

    /// Selectable models for an agent on a given account. Empty means "whatever the CLI
    /// defaults to", which the composer shows as the only option.
    static func available(for kind: AgentKind, account: AgentAccount?) -> [String] {
        options(for: kind, account: account).map(\.identifier)
    }

    static func options(for kind: AgentKind, account: AgentAccount?) -> [AgentModelOption] {
        switch kind {
        case .claude:
            return AgentDefaults.claudeModels.map {
                AgentModelOption(
                    identifier: $0,
                    displayName: ModelName.display(for: $0),
                    fastServiceTier: nil,
                    defaultServiceTier: nil
                )
            }
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
        }
    }

    /// The model the CLI will use when Skalman passes no `--model` flag at all.
    ///
    /// Both agents record this per account, which is what lets the composer name the model
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
        }
    }

    /// The reasoning effort the CLI inherits for this account when Skalman does not override
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
        }
    }

    /// The effective Fast setting inherited when a session has no explicit override.
    ///
    /// Only Codex is mapped here. Claude's persistent print transport changes its own live
    /// fast-mode state through a control request, so its account-default semantics belong to
    /// that transport rather than being guessed from undocumented settings keys.
    static func defaultFastMode(
        for kind: AgentKind,
        model: String?,
        account: AgentAccount?
    ) -> Bool? {
        guard kind == .codex else { return nil }

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

    /// Whether a Claude model can run in fast mode.
    ///
    /// Fast mode is a live control-channel flag, not a launch flag or a service tier, so it is
    /// not carried on `AgentModelOption` the way Codex's Fast tier is — and there is no live
    /// per-account signal for it either: the stream-json `init` reports `fast_mode_state`
    /// (on/off) but not which models *can* run it. It is an Opus-family capability (measured
    /// against CLI 2.1.218: Opus 4.7/4.8). Matching the family rather than pinning dated ids
    /// keeps this correct as new Opus versions ship, and the CLI is the final arbiter — an
    /// unsupported request is rejected and surfaced — so erring toward offering the control costs
    /// a rejection, not a wrong result. A nil model (the CLI's unnamed default) is treated as
    /// incapable, hiding the control rather than guessing.
    static func claudeSupportsFastMode(_ model: String?) -> Bool {
        model?.localizedCaseInsensitiveContains(AgentDefaults.claudeFastModeFamily) == true
    }

    static func option(
        identifier: String?,
        for kind: AgentKind,
        account: AgentAccount?
    ) -> AgentModelOption? {
        guard let identifier, !identifier.isEmpty else { return nil }
        return options(for: kind, account: account).first { $0.identifier == identifier }
    }

    // MARK: - Private Methods

    /// Reads `"model"` from the account's `settings.json`.
    ///
    /// The default account's settings live in `~/.claude`; an alternate account's live in the
    /// config directory it is routed to, which is exactly what `configPath` holds — so one
    /// path serves both and an account on a different model reports it.
    private static func configuredClaudeModel(account: AgentAccount?) -> String? {
        configuredClaudeSetting(AgentDefaults.claudeModelKey, account: account)
    }

    private static func configuredClaudeSetting(
        _ key: String,
        account: AgentAccount?
    ) -> String? {
        guard let account else { return nil }

        let url = URL(fileURLWithPath: account.configPath)
            .appendingPathComponent(AgentDefaults.claudeSettingsFile)

        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = json[key] as? String,
              !value.isEmpty
        else { return nil }

        return value
    }

    /// Reads `model = "…"` from the account's `config.toml`.
    ///
    /// Parsed with a narrow regex rather than a TOML library: one scalar key is wanted, and a
    /// dependency for it would outweigh the feature.
    private static func configuredCodexModel(account: AgentAccount?) -> String? {
        configuredCodexValue(AgentDefaults.codexModelKey, account: account)
    }

    private static func configuredCodexValue(
        _ key: String,
        account: AgentAccount?
    ) -> String? {
        guard let account else { return nil }

        let configURL = URL(fileURLWithPath: account.configPath)
            .appendingPathComponent(AgentDefaults.codexConfigFile)

        guard let contents = try? String(contentsOf: configURL, encoding: .utf8) else { return nil }

        for line in contents.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Only a top-level assignment counts; keys under a [table] belong to something else.
            guard trimmed.hasPrefix(key) else { continue }

            let parts = trimmed.split(separator: "=", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces) == key
            else { continue }

            let value = parts[1]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))

            return value.isEmpty ? nil : value
        }

        return nil
    }

    /// Reads the cache Codex writes after resolving the account's live model catalog.
    ///
    /// Hidden/internal models stay hidden. A future catalog can rename the fast service-tier
    /// id without a Skalman release because the id is carried through as data.
    private static func codexCatalog(account: AgentAccount?) -> [AgentModelOption] {
        guard let account else { return [] }

        let url = URL(fileURLWithPath: account.configPath)
            .appendingPathComponent(AgentDefaults.codexModelsCacheFile)
        guard let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(CodexModelsCache.self, from: data)
        else { return [] }

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
                    defaultServiceTier: model.defaultServiceTier
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

        private enum CodingKeys: String, CodingKey {
            case slug, visibility
            case displayName = "display_name"
            case additionalSpeedTiers = "additional_speed_tiers"
            case serviceTiers = "service_tiers"
            case defaultServiceTier = "default_service_tier"
        }
    }

    struct ServiceTier: Decodable {
        let id: String
        let name: String
    }
}
