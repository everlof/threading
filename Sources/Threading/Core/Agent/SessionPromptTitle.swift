import Foundation

/// The user's task alone supplies a provisional chat name, before standing opening text is added.
enum SessionPromptTitle {
    static let maximumCharacters = 80
    static let injectedPrefixes = [
        "<local-command-caveat>",
        "<command-name>",
        "<environment_context>",
        "<user_instructions>",
        "<recommended_plugins>",
        "<INSTRUCTIONS>",
        "# AGENTS.md",
        "Caveat:",
        "The following is the Codex agent history"
    ]

    static func from(_ prompt: String) -> String? {
        let task = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty,
              !injectedPrefixes.contains(where: { task.hasPrefix($0) }) else { return nil }
        // CRLF can be one grapheme cluster; splitting on a literal LF keeps the whole paste.
        let firstLine = task.split(whereSeparator: \.isNewline).first.map(String.init) ?? task
        return String(firstLine.prefix(maximumCharacters))
            .trimmingCharacters(in: .whitespaces)
    }
}
