/// The provider-neutral presentation of a model's reasoning-effort catalog.
///
/// The selected model is the authority for whether this control exists and which values it may
/// send. Claude builds those options from its documented session-level `--effort` contract;
/// Codex reads them per model from the account's own cache. A runtime or model with no published
/// levels produces no rows and therefore no control.
enum ReasoningEffortPresentation {
    static let symbol = "brain"

    static func option(
        kind: AgentKind,
        model: String?,
        account: AgentAccount?
    ) -> AgentModelOption? {
        guard let option = AgentModels.option(
                identifier: model,
                for: kind,
                account: account
              ),
              !option.reasoningLevels.isEmpty
        else { return nil }
        return option
    }

    static func title(
        selected: String?,
        kind: AgentKind,
        model: String?,
        account: AgentAccount?
    ) -> String {
        let option = option(kind: kind, model: model, account: account)
        let effective = AgentModels.effectiveEffort(
            selected: selected,
            kind: kind,
            model: model,
            account: account
        )
        guard let effective else { return defaultTitle }
        return option?.reasoningLevels.first { $0.effort == effective }?.displayName
            ?? AgentReasoningLevel(effort: effective, description: "").displayName
    }

    static func rows(
        selected: String?,
        kind: AgentKind,
        model: String?,
        account: AgentAccount?
    ) -> [ThemedMenuEntry] {
        guard let option = option(kind: kind, model: model, account: account) else { return [] }

        let configured = AgentModels.defaultEffort(for: kind, account: account)
        let inherited: String?
        let inheritedSuffix: String
        if let configured, option.supports(reasoningEffort: configured) {
            inherited = configured
            inheritedSuffix = accountDefaultSuffix
        } else {
            inherited = option.defaultReasoningLevel
            inheritedSuffix = modelDefaultSuffix
        }

        let inheritedLevel = option.reasoningLevels.first { $0.effort == inherited }
        var entries: [ThemedMenuEntry] = [
            .item(ThemedMenuItem(
                title: inherited.map {
                    "\(displayName($0, option: option))\(inheritedSuffix)"
                } ?? defaultTitle,
                subtitle: nonempty(inheritedLevel?.description),
                representedValue: nil,
                isSelected: selected == nil || !option.supports(reasoningEffort: selected)
            ))
        ]

        entries += option.reasoningLevels.map { level in
            .item(ThemedMenuItem(
                title: level.displayName,
                subtitle: nonempty(level.description),
                representedValue: level.effort,
                isSelected: level.effort == selected
            ))
        }
        return entries
    }

    private static var defaultTitle: String { L10n.string("Default effort") }
    private static var accountDefaultSuffix: String { L10n.string("  (account default)") }
    private static var modelDefaultSuffix: String { L10n.string("  (model default)") }

    private static func displayName(
        _ effort: String,
        option: AgentModelOption
    ) -> String {
        option.reasoningLevels.first { $0.effort == effort }?.displayName
            ?? AgentReasoningLevel(effort: effort, description: "").displayName
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
