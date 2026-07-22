import Foundation

// MARK: - Permission Request

/// A tool call awaiting a decision.
struct PermissionRequest {
    let sessionID: SessionID
    let tool: ToolIdentity
    let input: [String: Any]

    var toolName: String { tool.rawName }

    init(sessionID: SessionID, tool: ToolIdentity, input: [String: Any]) {
        self.sessionID = sessionID
        self.tool = tool
        self.input = input
    }

    init(sessionID: SessionID, toolName: String, input: [String: Any]) {
        self.init(sessionID: sessionID, tool: ToolIdentity(toolName), input: input)
    }

    /// A one-line description of what the tool would actually do, for the approval sheet.
    ///
    /// Every tool names its subject differently, and a sheet showing raw JSON asks the user
    /// to parse a schema before deciding — which is how people learn to click Allow without
    /// reading.
    var summary: String {
        // Each rule below names its *preferred* argument and then falls back to the generic
        // search. The fallback is not belt-and-braces: `ToolIdentity` now maps Codex's tools
        // onto these same identities, and Codex does not always spell the argument the way the
        // rule does — an `exec` call whose command arrived under another key used to find its
        // subject through the generic path and lost it the moment it became `.bash`.
        switch tool {
        case .bash:
            return input["command"] as? String ?? subject ?? ""
        case .write, .edit, .notebookEdit, .read, .notebookRead:
            return (input["file_path"] as? String).map { abbreviate($0) } ?? subject ?? ""
        case .webFetch:
            return input["url"] as? String ?? subject ?? ""
        case .webSearch, .grep, .glob:
            // `Grep` and `Glob` name themselves by what they looked for, optionally where.
            // Named `term` rather than `subject` so it does not shadow the generic search
            // below, which is what answers when a provider spells neither of these keys.
            let term = (input["query"] ?? input["pattern"]) as? String ?? ""
            let path = (input["path"] as? String).map { abbreviate($0) } ?? ""

            switch (term.isEmpty, path.isEmpty) {
            case (false, false): return "\(term)  in \(path)"
            case (false, true): return term
            case (true, false): return path
            case (true, true): return subject ?? ""
            }
        case .plan:
            // Codex's `update_plan` carries the whole list. The step in progress is the one
            // worth a row; the rest is a checklist nobody reads collapsed.
            return currentPlanStep ?? "\(planSteps.count) steps"
        case .multiEdit, .task, .todoWrite, .todoRead, .toolSearch, .mcp, .unknown:
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

    /// The command a shell call would run, under either provider's name for it.
    ///
    /// Not for display — `summary` handles that. This is what `ShellCommandPolicy` reads, so it
    /// returns nil rather than a placeholder when no command can be found: an unreadable call
    /// must fall through to asking the user, never to a policy decision made on nothing.
    var shellCommand: String? {
        for key in ["command", "cmd"] {
            if let text = input[key] as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
        }
        return nil
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
    private static var alwaysAllowed: [SessionID: Set<ToolIdentity>] = [:]

    // MARK: - Public Methods

    /// Resolves one hook request, calling back with the decision.
    ///
    /// Runs on the main queue: it reaches the model layer and may put a sheet on screen.
    static func decide(
        _ request: PermissionRequest,
        completion: @escaping (PermissionDecision) -> Void
    ) {
        if PermissionPolicy.isAutoAllowed(request.tool) {
            completion(.allow(reason: "Read-only tool, allowed automatically by Skalman."))
            return
        }

        // A shell call is judged by what it runs, because one tool name covers both reading and
        // writing — and under Codex it is how files are read at all.
        if request.tool == .bash,
           let command = request.shellCommand,
           ShellCommandPolicy.isReadOnly(command) {
            completion(.allow(reason: "Read-only command, allowed automatically by Skalman."))
            return
        }

        if alwaysAllowed[request.sessionID]?.contains(request.tool) == true {
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
        alwaysAllowed[sessionID, default: []].insert(ToolIdentity(toolName))
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

    static func isAutoAllowed(_ toolName: String) -> Bool {
        isAutoAllowed(ToolIdentity(toolName))
    }

    /// Deliberately exhaustive rather than a denylist: adding a known identity forces an
    /// explicit policy choice, while `.unknown` remains consequential and prompts.
    static func isAutoAllowed(_ tool: ToolIdentity) -> Bool {
        switch tool {
        case .read, .glob, .grep, .notebookRead,
             .todoWrite, .todoRead, .task, .toolSearch:
            return true

        case .mcp(let name):
            // Skalman's own display tools draw in a panel the user is already looking at, and
            // are allowlisted for terminal sessions for the same reason.
            return name.hasPrefix("mcp__\(MCPDefaults.serverName)__")

        case .bash, .write, .edit, .multiEdit, .notebookEdit,
             .webFetch, .webSearch, .plan, .unknown:
            return false
        }
    }
}
