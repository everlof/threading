import Foundation

/// The visible name a durable rename records as history. Both hosts use the same row-title
/// precedence; a placeholder is never treated as a name the user might search for later.
enum SessionHistoryTitle {
    static func name(for session: AgentSession, usesAgentTitle: Bool) -> String {
        let name = AgentSessionRowPresentation(
            session: session, usesAgentTitle: usesAgentTitle, untitledTitle: ""
        ).title
        guard session.customTitle != nil || !isPlaceholder(
            name, kind: session.kind, accountDisplayName: nil
        ) else { return "" }
        return name
    }

    static func isPlaceholder(_ title: String, kind: AgentKind,
                              accountDisplayName: String?) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        var bases: Set<String> = [
            kind.displayName.lowercased(),
            AgentDefaults.untitledSessionName.lowercased(),
            AgentDefaults.sideChatTitle.lowercased()
        ]
        if let accountDisplayName, !accountDisplayName.isEmpty {
            bases.insert(accountDisplayName.lowercased())
        }
        return bases.contains(strippingCounter(trimmed).lowercased())
    }

    private static func strippingCounter(_ title: String) -> String {
        guard let lastSpace = title.lastIndex(of: " "),
              Int(title[title.index(after: lastSpace)...]) != nil else { return title }
        return String(title[..<lastSpace])
    }
}
