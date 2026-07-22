import Foundation

// MARK: - Permission Request

/// A tool call awaiting a decision.
struct PermissionRequest {
    let sessionID: SessionID
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
        case "Write", "Edit", "NotebookEdit", "Read", "NotebookRead":
            return (input["file_path"] as? String).map { abbreviate($0) } ?? ""
        case "WebFetch":
            return input["url"] as? String ?? ""
        case "WebSearch", "Grep", "Glob":
            // `Grep` and `Glob` name themselves by what they looked for, optionally where.
            let subject = (input["query"] ?? input["pattern"]) as? String ?? ""
            guard let path = (input["path"] as? String).map({ abbreviate($0) }), !path.isEmpty else {
                return subject
            }
            return subject.isEmpty ? path : "\(subject)  in \(path)"
        case "Plan":
            // Codex's `update_plan` carries the whole list. The step in progress is the one
            // worth a row; the rest is a checklist nobody reads collapsed.
            return currentPlanStep ?? "\(planSteps.count) steps"
        default:
            // Tools without a rule of their own are the *common* case, not the exception —
            // there are always more tools than rules, and every MCP server adds more. This
            // branch used to dump the arguments as JSON, which is precisely what the rest of
            // this property exists to avoid: rendering real conversations showed `Read`,
            // `Agent`, `Workflow`, `Artifact` and half a dozen Codex tools all identifying
            // themselves with a wall of braces.
            //
            // Nearly every tool carries one field that reads as its subject. Take that.
            return subject ?? ""
        }
    }

    /// The file a call would change, when it names one. Not for display — it is what says
    /// which language a rendered diff is in.
    var filePath: String? {
        for key in ["file_path", "notebook_path", "path"] {
            if let path = input[key] as? String, !path.isEmpty { return path }
        }
        return nil
    }

    /// Argument names that describe what a call is *for*, most specific first. A tool that
    /// carries any of them is better named by it than by its schema.
    private static let subjectKeys = [
        "command", "cmd", "file_path", "path", "notebook_path", "url", "query", "pattern",
        "question", "description", "message", "prompt", "title", "name", "input"
    ]

    private var subject: String? {
        Self.subject(in: input) ?? nestedSubject
    }

    /// Some tools carry their subject one level down — `AskUserQuestion` puts it in
    /// `questions[0].question`, and a plan in `plan[0].step`. Looking one level in costs
    /// nothing and is the difference between a row that says what was asked and one that
    /// says nothing.
    private var nestedSubject: String? {
        for value in input.values {
            if let first = (value as? [[String: Any]])?.first,
               let found = Self.subject(in: first) {
                return found
            }
            if let nested = value as? [String: Any], let found = Self.subject(in: nested) {
                return found
            }
        }
        return nil
    }

    private static func subject(in input: [String: Any]) -> String? {
        for key in subjectKeys {
            guard let text = input[key] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            return text
        }
        return nil
    }

    /// Codex's plan items, each `{"step": …, "status": …}`.
    private var planSteps: [[String: Any]] {
        input["plan"] as? [[String: Any]] ?? []
    }

    /// The step being worked on, else the first one not yet done.
    private var currentPlanStep: String? {
        let step = planSteps.first { $0["status"] as? String == "in_progress" }
            ?? planSteps.first { ($0["status"] as? String) != "completed" }
        return (step?["step"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The same subject on one line, for a collapsed tool row.
    ///
    /// `summary` is deliberately whole: an approval card is answered on what the command
    /// actually does, and truncating it there is how people learn to click Allow without
    /// reading. A *row* has no such duty and one line of height — and a multi-line heredoc or
    /// `cd … && …` command rendered into it made a collapsed row four lines tall, defeating the
    /// point of collapsing it. Found by rendering real transcripts, not by reading this file.
    var oneLineSummary: String {
        let lines = summary.split(separator: "\n", omittingEmptySubsequences: true)
        guard let first = lines.first else { return "" }

        // The continuation marker matters: without it a two-line command reads as though the
        // first line were the whole of it.
        return lines.count > 1 ? first + " …" : String(first)
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
@MainActor
enum PermissionBroker {

    // MARK: - Properties

    /// Asks the user. Set by the window controller, which owns the sheet.
    ///
    /// Nil means nothing can present, so requests are denied rather than hanging: a session
    /// whose window has gone away must not leave the CLI blocked forever.
    static var present: ((PermissionRequest, @escaping (PermissionDecision) -> Void) -> Void)?

    /// Tools the user chose to stop being asked about, per session.
    private static var alwaysAllowed: [SessionID: Set<String>] = [:]

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
    static func allowAlways(toolName: String, for sessionID: SessionID) {
        alwaysAllowed[sessionID, default: []].insert(toolName)
    }

    /// Forgets a session's standing approvals, so a resumed conversation starts asking again.
    static func discard(sessionID: SessionID) {
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
