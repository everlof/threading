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
        case .shell:
            return []
        }
    }

    // MARK: - Private Methods

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
