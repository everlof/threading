import Foundation

/// The model choices offered when starting a session.
///
/// Claude documents stable aliases, so those are listed directly. Codex publishes no such
/// list, so its options are read from the account's own configuration rather than guessed —
/// an invented model name would fail only at launch, long after the choice was made.
enum AgentModels {

    // MARK: - Public Methods

    /// Selectable models for an agent on a given account. Empty means "whatever the CLI
    /// defaults to", which the composer shows as the only option.
    static func available(for kind: AgentKind, account: AgentAccount?) -> [String] {
        switch kind {
        case .claude:
            return AgentDefaults.claudeModels
        case .codex:
            return configuredCodexModel(account: account).map { [$0] } ?? []
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

    // MARK: - Private Methods

    /// Reads `"model"` from the account's `settings.json`.
    ///
    /// The default account's settings live in `~/.claude`; an alternate account's live in the
    /// config directory it is routed to, which is exactly what `configPath` holds — so one
    /// path serves both and an account on a different model reports it.
    private static func configuredClaudeModel(account: AgentAccount?) -> String? {
        guard let account else { return nil }

        let url = URL(fileURLWithPath: account.configPath)
            .appendingPathComponent(AgentDefaults.claudeSettingsFile)

        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = json[AgentDefaults.claudeModelKey] as? String,
              !model.isEmpty
        else { return nil }

        return model
    }

    /// Reads `model = "…"` from the account's `config.toml`.
    ///
    /// Parsed with a narrow regex rather than a TOML library: one scalar key is wanted, and a
    /// dependency for it would outweigh the feature.
    private static func configuredCodexModel(account: AgentAccount?) -> String? {
        guard let account else { return nil }

        let configURL = URL(fileURLWithPath: account.configPath)
            .appendingPathComponent(AgentDefaults.codexConfigFile)

        guard let contents = try? String(contentsOf: configURL, encoding: .utf8) else { return nil }

        for line in contents.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Only a top-level assignment counts; keys under a [table] belong to something else.
            guard trimmed.hasPrefix(AgentDefaults.codexModelKey) else { continue }

            let parts = trimmed.split(separator: "=", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces) == AgentDefaults.codexModelKey
            else { continue }

            let value = parts[1]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))

            return value.isEmpty ? nil : value
        }

        return nil
    }
}
