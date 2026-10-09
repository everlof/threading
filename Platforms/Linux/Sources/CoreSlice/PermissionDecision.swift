import Foundation

// MARK: - Permission Decision

enum PermissionDecision: Sendable {
    case allow(reason: String)
    case deny(reason: String)

    /// Threading has no objection and no question: the runtime's own permission flow decides,
    /// as it would in its terminal. Only ever the answer to a `.toolHook` request — a runtime
    /// that asked for itself has already deferred to us, and needs a yes or a no.
    case deferToAgent(reason: String)

    /// The `PreToolUse` hook's reply shape, or nil to print nothing.
    ///
    /// Returning a decision on stdout is what lets the tool through — a hook that exits silently
    /// leaves the call to the runtime's normal permission flow, which in a headless Claude run
    /// under Manual means blocked. That silence is exactly what `deferToAgent` wants: under Auto
    /// the normal flow is Claude's own classifier, and Codex runs its approval policy after the
    /// hook whatever the hook says. Nothing rather than `{}`, because nothing is the reply every
    /// terminal Codex session already gets from the shared `hooks.json` entry.
    var hookResponse: [String: Any]? {
        let decision: String
        let reason: String

        switch self {
        case .allow(let text): (decision, reason) = ("allow", text)
        case .deny(let text): (decision, reason) = ("deny", text)
        case .deferToAgent: return nil
        }

        return [
            "hookSpecificOutput": [
                "hookEventName": "PreToolUse",
                "permissionDecision": decision,
                "permissionDecisionReason": reason
            ]
        ]
    }
}
