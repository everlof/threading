import Foundation

/// One provider-native reasoning level an installed runtime says a model can use.
struct AgentReasoningLevel: Equatable, Codable, Sendable {
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
struct AgentModelOption: Equatable, Codable, Sendable {
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
