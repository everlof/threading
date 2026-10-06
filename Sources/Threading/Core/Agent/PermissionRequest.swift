import Foundation

// MARK: - Permission Request

/// A tool call awaiting a decision.
struct PermissionRequest: Sendable {

    /// Who put the question, which decides whether Threading is the only one who can answer it.
    enum Origin: Sendable, Equatable {
        /// The runtime's own permission flow asked: a Codex app-server approval request or an ACP
        /// `session/request_permission`. The runtime has already applied its mode and decided a
        /// person should answer, so the answer has to be allow or deny.
        case runtimeRequest

        /// Threading's `PreToolUse` hook asked, before the runtime's own permission flow ran.
        /// The hook fires for every tool call in every mode, so it can also stay out of the way
        /// and leave the call to that flow (`PermissionDecision.deferToAgent`).
        ///
        /// `reportedMode` is the payload's own `permission_mode`, in the runtime's spelling: the
        /// mode the running *process* is in. That is not always the session's record — a mode
        /// chosen from the sidebar applies at the next launch — and only the process's mode says
        /// what its permission flow will do with a call the hook leaves to it.
        case toolHook(reportedMode: String?)
    }

    let sessionID: SessionID
    let tool: ToolIdentity
    let input: [String: JSONValue]
    let origin: Origin

    var toolName: String { tool.rawName }

    /// Compatibility projection for the AppKit diff/rendering helpers that still consume
    /// Foundation JSON. Permission policy itself never crosses that untyped boundary.
    @MainActor
    var foundationInput: [String: Any] {
        input.mapValues(\.foundationValue)
    }

    /// `origin` defaults to the runtime having asked, which is the conservative reading: such a
    /// request is never left to the runtime, so forgetting to say it came from the hook costs a
    /// question rather than an unasked-for action.
    init(
        sessionID: SessionID,
        tool: ToolIdentity,
        input: [String: JSONValue],
        origin: Origin = .runtimeRequest
    ) {
        self.sessionID = sessionID
        self.tool = tool
        self.input = input
        self.origin = origin
    }

    init(
        sessionID: SessionID,
        toolName: String,
        input: [String: JSONValue],
        origin: Origin = .runtimeRequest
    ) {
        self.init(sessionID: sessionID, tool: ToolIdentity(toolName), input: input, origin: origin)
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
            return input["command"]?.stringValue ?? subject ?? ""
        case .write, .edit, .notebookEdit, .read, .notebookRead:
            return input["file_path"]?.stringValue.map { abbreviate($0) } ?? subject ?? ""
        case .webFetch:
            return input["url"]?.stringValue ?? subject ?? ""
        case .webSearch, .grep, .glob:
            // `Grep` and `Glob` name themselves by what they looked for, optionally where.
            // Named `term` rather than `subject` so it does not shadow the generic search
            // below, which is what answers when a provider spells neither of these keys.
            let term = (input["query"] ?? input["pattern"])?.stringValue ?? ""
            let path = input["path"]?.stringValue.map { abbreviate($0) } ?? ""

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
        case .taskCreate:
            return input["subject"]?.stringValue ?? subject ?? ""
        case .taskUpdate:
            let id = (input["taskId"] ?? input["task_id"] ?? input["id"])?.stringValue
            let status = input["status"]?.stringValue
            return [id.map { "#\($0)" }, status]
                .compactMap { $0 }
                .joined(separator: " · ")
        case .taskList:
            return "Task list"
        case .taskGet:
            let id = (input["taskId"] ?? input["task_id"] ?? input["id"])?.stringValue
            return id.map { "#\($0)" } ?? subject ?? ""
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
            if let text = input[key]?.stringValue,
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
            if let path = input[key]?.stringValue, !path.isEmpty { return path }
        }
        return nil
    }

    /// Argument names that describe what a call is *for*, most specific first. A tool that
    /// carries any of them is better named by it than by its schema.
    private static let subjectKeys = [
        "command", "cmd", "file_path", "path", "notebook_path", "url", "query", "pattern",
        "question", "description", "subject", "activeForm", "message", "prompt", "title",
        "name", "input"
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
            if case .array(let values) = value,
               let first = values.first?.objectValue,
               let found = Self.subject(in: first) {
                return found
            }
            if let nested = value.objectValue, let found = Self.subject(in: nested) {
                return found
            }
        }
        return nil
    }

    private static func subject(in input: [String: JSONValue]) -> String? {
        for key in subjectKeys {
            guard let text = input[key]?.stringValue,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            return text
        }
        return nil
    }

    /// Codex's plan items, each `{"step": …, "status": …}`.
    private var planSteps: [[String: JSONValue]] {
        guard case .array(let values) = input["plan"] else { return [] }
        return values.compactMap(\.objectValue)
    }

    /// The step being worked on, else the first one not yet done.
    private var currentPlanStep: String? {
        let step = planSteps.first { $0["status"]?.stringValue == "in_progress" }
            ?? planSteps.first { $0["status"]?.stringValue != "completed" }
        return step?["step"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
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
