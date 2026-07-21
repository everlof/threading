import Foundation

// MARK: - Permission Request

/// A tool call awaiting a decision.
struct PermissionRequest {
    let sessionID: UUID
    let toolName: String
    let input: [String: Any]

    /// A one-line description of what the tool would actually do, for the approval sheet.
    ///
    /// Every tool names its subject differently, and a sheet showing raw JSON asks the user
    /// to parse a schema before deciding — which is how people learn to click Allow without
    /// reading.
    var summary: String {
        switch toolName {
        case "Bash":
            return input["command"] as? String ?? ""
        case "Write", "Edit", "NotebookEdit":
            return (input["file_path"] as? String).map { abbreviate($0) } ?? ""
        case "WebFetch":
            return input["url"] as? String ?? ""
        case "WebSearch":
            return input["query"] as? String ?? ""
        default:
            // Unknown tool: show its arguments rather than nothing, compactly.
            guard let data = try? JSONSerialization.data(withJSONObject: input),
                  let text = String(data: data, encoding: .utf8) else { return "" }
            return text.count > 200 ? String(text.prefix(200)) + "…" : text
        }
    }

    private func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

// MARK: - Permission Decision

enum PermissionDecision {
    case allow(reason: String)
    case deny(reason: String)

    /// The `PreToolUse` hook's reply shape. Returning this on stdout is what actually lets
    /// the tool through — a hook that exits silently leaves the call to the normal permission
    /// flow, which in a headless run means blocked.
    var hookResponse: [String: Any] {
        let decision: String
        let reason: String

        switch self {
        case .allow(let text): (decision, reason) = ("allow", text)
        case .deny(let text): (decision, reason) = ("deny", text)
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

// MARK: - Permission Broker

/// Decides whether a headless session's tool call may proceed.
///
/// A headless Claude has nowhere to ask, so it blocks anything that would normally prompt.
/// A `PreToolUse` hook is pointed at Skalman's own HTTP listener instead: the hook holds the
/// tool call open while the app asks the user, then carries the answer back. That restores
/// the terminal's behaviour rather than trading it for a blanket `bypassPermissions`.
enum PermissionBroker {

    // MARK: - Properties

    /// Asks the user. Set by the window controller, which owns the sheet.
    ///
    /// Nil means nothing can present, so requests are denied rather than hanging: a session
    /// whose window has gone away must not leave the CLI blocked forever.
    static var present: ((PermissionRequest, @escaping (PermissionDecision) -> Void) -> Void)?

    /// Tools the user chose to stop being asked about, per session.
    private static var alwaysAllowed: [UUID: Set<String>] = [:]

    // MARK: - Public Methods

    /// Resolves one hook request, calling back with the decision.
    ///
    /// Runs on the main queue: it reaches the model layer and may put a sheet on screen.
    static func decide(
        _ request: PermissionRequest,
        completion: @escaping (PermissionDecision) -> Void
    ) {
        if PermissionPolicy.isAutoAllowed(request.toolName) {
            completion(.allow(reason: "Read-only tool, allowed automatically by Skalman."))
            return
        }

        if alwaysAllowed[request.sessionID]?.contains(request.toolName) == true {
            completion(.allow(reason: "Allowed for this session by the user."))
            return
        }

        guard let present else {
            completion(.deny(reason: "Skalman has no window available to ask for permission."))
            return
        }

        present(request, completion)
    }

    /// Records that a tool should stop prompting for the rest of a session.
    static func allowAlways(toolName: String, for sessionID: UUID) {
        alwaysAllowed[sessionID, default: []].insert(toolName)
    }

    /// Forgets a session's standing approvals, so a resumed conversation starts asking again.
    static func discard(sessionID: UUID) {
        alwaysAllowed.removeValue(forKey: sessionID)
    }
}

// MARK: - Permission Policy

/// Which tools are worth interrupting the user for.
///
/// The hook fires for *every* tool, including ones the terminal never prompts about. Deciding
/// here rather than in the hook's matcher keeps the generated settings file static and puts
/// the policy somewhere it can be reasoned about.
enum PermissionPolicy {

    /// Tools that only read, and so are allowed without asking.
    ///
    /// Deliberately a short allowlist rather than a denylist: a tool absent from this set is
    /// treated as consequential, so a new tool in a future release prompts rather than
    /// slipping through unasked.
    private static let readOnlyTools: Set<String> = [
        "Read", "Glob", "Grep", "NotebookRead", "TodoWrite", "TodoRead", "Task", "ToolSearch"
    ]

    static func isAutoAllowed(_ toolName: String) -> Bool {
        if readOnlyTools.contains(toolName) { return true }

        // Skalman's own display tools draw in a panel the user is already looking at, and
        // are allowlisted for terminal sessions for the same reason.
        return toolName.hasPrefix("mcp__\(MCPDefaults.serverName)__")
    }
}
