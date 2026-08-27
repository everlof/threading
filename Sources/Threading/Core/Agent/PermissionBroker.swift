import Foundation

// MARK: - Permission Request

/// A tool call awaiting a decision.
struct PermissionRequest: Sendable {
    let sessionID: SessionID
    let tool: ToolIdentity
    let input: [String: JSONValue]

    var toolName: String { tool.rawName }

    /// Compatibility projection for the AppKit diff/rendering helpers that still consume
    /// Foundation JSON. Permission policy itself never crosses that untyped boundary.
    @MainActor
    var foundationInput: [String: Any] {
        input.mapValues(\.foundationValue)
    }

    init(sessionID: SessionID, tool: ToolIdentity, input: [String: JSONValue]) {
        self.sessionID = sessionID
        self.tool = tool
        self.input = input
    }

    init(sessionID: SessionID, toolName: String, input: [String: JSONValue]) {
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

// MARK: - Permission Decision

enum PermissionDecision: Sendable {
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
/// A `PreToolUse` hook is pointed at Threading's own HTTP listener instead: the hook holds the
/// tool call open while the app asks the user, then carries the answer back. That restores
/// the terminal's behaviour rather than trading it for a blanket `bypassPermissions`.
@MainActor
enum PermissionBroker {

    // MARK: - Properties

    /// Asks the user. Set by the window controller, which owns the sheet.
    ///
    /// Nil means nothing can present, so requests are denied rather than hanging: a session
    /// whose window has gone away must not leave the CLI blocked forever.
    static var present: (
        (
            PermissionRequest,
            @escaping @MainActor @Sendable (PermissionDecision) -> Void
        ) -> Void
    )?

    /// Says what macOS is about to ask for and who caused it, before the call that raises the
    /// system prompt runs. Set alongside `present` by the same window controller.
    ///
    /// Nil is not a denial: an unexplained system prompt is what happens today, and losing the
    /// explanation must not also lose the tool call.
    static var explainSystemGrant: (
        (
            SystemPrivacyPermission,
            PermissionRequest,
            @escaping @MainActor @Sendable (Bool) -> Void
        ) -> Void
    )?

    /// Reads a grant without requesting it. Injected so a test states the machine's answer
    /// instead of inheriting whatever this Mac has approved in System Settings.
    static var systemGrantStatus: (SystemPrivacyPermission) -> SystemPrivacyStatus? = { permission in
        SystemPrivacyStatusReader().immediateStatus(of: permission)
    }

    /// Tools the user chose to stop being asked about, per session.
    private static var alwaysAllowed: [SessionID: Set<ToolIdentity>] = [:]

    /// Grants the user has already been briefed on and waved through.
    ///
    /// App-wide and for the life of the process, because the grant is app-wide: macOS asks
    /// Threading once, not once per session. The set only matters in one case — the user let
    /// the command run and then pressed Deny on the *system* prompt. macOS remembers that and
    /// never asks again, so without this the next `screencapture` would be briefed forever for
    /// a dialog that can no longer appear. Every other outcome is settled by the status read:
    /// an approved grant reads `.allowed` and forecasts nothing, and a briefing the user
    /// declined leaves the tool unrun, so there is nothing yet to have been asked about.
    private static var briefedGrants: Set<SystemPrivacyPermission> = []

    // MARK: - Public Methods

    /// Resolves one hook request, calling back with the decision.
    ///
    /// Runs on the main queue: it reaches the model layer and may put a sheet on screen.
    static func decide(
        _ request: PermissionRequest,
        completion: @escaping @MainActor @Sendable (PermissionDecision) -> Void
    ) {
        ExecutionAuditStore.shared.recordPermissionRequest(request)
        let auditedCompletion: @MainActor @Sendable (PermissionDecision) -> Void = { decision in
            ExecutionAuditStore.shared.recordPermissionDecision(decision, for: request)
            completion(decision)
        }

        // Ahead of every other rule, including the modes that promise not to interrupt. What
        // follows is not one of Threading's permission questions — it is the only warning the
        // user will get that *macOS* is about to put a dialog on their screen naming Threading
        // for something an agent did. No mode Threading offers can promise the system stays
        // quiet, so none of them is a reason to let that dialog arrive unexplained.
        if let grant = foreseenSystemGrant(for: request) {
            brief(grant, before: request, completion: auditedCompletion)
            return
        }

        decideIgnoringSystemGrant(request, completion: auditedCompletion)
    }

    // MARK: - System Grants

    /// The macOS grant this call is about to be stopped by, when there is one worth naming.
    ///
    /// Three conditions, and each removes a way of being annoying: the command has to be one
    /// that needs a grant, the grant has to be one Threading can *read* — so the system prompt
    /// is certain rather than guessed at — and it has to not have been raised already. A
    /// session that refuses everything is excluded too: its call is about to be denied, and
    /// explaining a dialog that will never appear is the interruption this exists to prevent.
    private static func foreseenSystemGrant(
        for request: PermissionRequest
    ) -> SystemPrivacyPermission? {
        guard let grant = SystemGrantForecast.grant(for: request),
              !briefedGrants.contains(grant),
              systemGrantStatus(grant) == .notAllowed,
              briefingApplies(in: permissionMode(for: request.sessionID)) else { return nil }
        return grant
    }

    /// Whether a session's mode leaves anything for a briefing to be about.
    ///
    /// Only `dontAsk` is excluded, and the reason is not politeness. Approving a briefing *is*
    /// the tool's approval, so briefing a `dontAsk` session would turn the one mode that
    /// promises to refuse rather than interrupt into an allow — the mode inverted by the
    /// feature meant to warn about a dialog its call was never going to reach. Every other mode
    /// is briefed, including `bypassPermissions`: no mode Threading offers can promise macOS
    /// stays quiet, so none of them is a reason to let a system dialog arrive unexplained.
    ///
    /// Pure, so the matrix is testable without a store or a sheet.
    static func briefingApplies(in mode: AgentPermissionMode?) -> Bool {
        mode != .dontAsk
    }

    /// Explains the coming system prompt, then lets the call through or refuses it.
    ///
    /// Approving here *is* the tool's approval — the card already showed the command, the
    /// session and the agent, which is strictly more than the ordinary permission card shows.
    /// A second sheet immediately behind the first would be the app asking twice about one
    /// decision, which is how people learn to click through both.
    ///
    /// It is not a standing approval: `allowAlways` is a choice the user makes in words, and
    /// nothing here offers it.
    private static func brief(
        _ grant: SystemPrivacyPermission,
        before request: PermissionRequest,
        completion: @escaping @MainActor @Sendable (PermissionDecision) -> Void
    ) {
        guard let explainSystemGrant else {
            // Nothing to explain with. The prompt arrives unexplained, as it does today — which
            // is worse than the sheet and far better than the call vanishing.
            decideIgnoringSystemGrant(request, completion: completion)
            return
        }

        // The reasons are the model's, not the user's, and stay in English alongside the rest
        // of this file's — they are read by an agent deciding what to do next, not shown in the
        // interface. Naming the grant is what lets it stop retrying and say why.
        explainSystemGrant(grant, request) { proceed in
            guard proceed else {
                completion(.deny(reason:
                    "The user declined to let this raise the macOS "
                        + "\(grant.englishName) permission prompt."))
                return
            }
            briefedGrants.insert(grant)
            completion(.allow(reason:
                "Approved in Threading, which told the user macOS will ask for "
                    + "\(grant.englishName) next."))
        }
    }

    /// The ordinary decision, with the forecast already spent. Split out so `decide` cannot
    /// re-enter its own first branch and brief the same call forever.
    private static func decideIgnoringSystemGrant(
        _ request: PermissionRequest,
        completion: @escaping @MainActor @Sendable (PermissionDecision) -> Void
    ) {
        if let decision = automaticDecision(for: request) {
            completion(decision)
            return
        }

        guard let present else {
            completion(.deny(reason: "Threading has no window available to ask for permission."))
            return
        }

        present(request, completion)
    }

    /// The ordinary policy that can change while a request waits behind another approval.
    /// Kept separate from system-grant briefing so the UI queue can safely re-check it without
    /// forecasting or presenting the macOS dialog twice.
    static func automaticDecision(for request: PermissionRequest) -> PermissionDecision? {
        if PermissionPolicy.isAutoAllowed(request.tool) {
            return .allow(reason: "Read-only tool, allowed automatically by Threading.")
        }

        // A shell call is judged by what it runs, because one tool name covers both reading and
        // writing — and under Codex it is how files are read at all.
        if request.tool == .bash,
           let command = request.shellCommand,
           ShellCommandPolicy.isReadOnly(command) {
            return .allow(reason: "Read-only command, allowed automatically by Threading.")
        }

        if alwaysAllowed[request.sessionID]?.contains(request.tool) == true {
            return .allow(reason: "Allowed for this session by the user.")
        }

        // The session's permission mode, honoured here because the CLI does not honour it *for*
        // us: measured against 2.1.220, `PreToolUse` fires under `bypassPermissions` and
        // `dontAsk` exactly as it does under `manual`. Without this, a natively rendered session
        // in Bypass would still be stopped by Threading's own sheet — the app contradicting the
        // mode the user picked in it.
        if let mode = permissionMode(for: request.sessionID),
           let standing = PermissionPolicy.standingDecision(for: request.tool, in: mode) {
            return standing
        }
        return nil
    }

    /// Forgets which grants have been briefed. For tests, which must not inherit a set left
    /// standing by whichever test ran before them.
    static func discardSystemGrantBriefings() {
        briefedGrants.removeAll()
    }

    // MARK: - Private Methods

    /// The mode this session is running under, resolved the same way its launch resolved it.
    ///
    /// Read from the store rather than remembered at launch, so a mode changed mid-session
    /// applies to the next tool call. That is a deliberate difference from the *flags*, which
    /// only a relaunch can restate: this layer is Threading's own and has no such excuse.
    private static func permissionMode(for sessionID: SessionID) -> AgentPermissionMode? {
        guard let session = ProjectStore.shared.session(withID: sessionID) else { return nil }
        return AgentLauncher.permissionMode(for: session)
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

    /// What the session's mode already decides, or nil to ask.
    ///
    /// Only the modes that *promise* something are answered here. `manual` asks by definition;
    /// `plan` and `auto` are enforced inside the CLI — plan by refusing to act, auto by its own
    /// classifier — and neither promises Threading's sheet will stay down, so asking remains both
    /// honest and the conservative side to be wrong on.
    ///
    /// `dontAsk` denies rather than allows. That is the mode's actual meaning in the CLI, whose
    /// fallback table reads `dontAsk → deny`: it promises never to interrupt, and keeps the
    /// promise by refusing and telling the model — not by waving the call through.
    static func standingDecision(
        for tool: ToolIdentity,
        in mode: AgentPermissionMode
    ) -> PermissionDecision? {
        switch mode {
        case .bypassPermissions:
            return .allow(reason: "Bypass Permissions: this chat runs without permission checks.")

        case .dontAsk:
            return .deny(reason: "Don't Ask: this chat refuses anything that would need approval.")

        case .acceptEdits:
            // The edit half of the mode's name. A command is not an edit, and this is the whole
            // distinction between Accept Edits and the modes either side of it.
            return isFileEdit(tool)
                ? .allow(reason: "Accept Edits: file changes are allowed without asking.")
                : nil

        case .manual, .plan, .auto:
            return nil
        }
    }

    /// Whether the tool changes files, as opposed to running something.
    private static func isFileEdit(_ tool: ToolIdentity) -> Bool {
        switch tool {
        case .write, .edit, .multiEdit, .notebookEdit:
            return true
        default:
            return false
        }
    }

    /// Deliberately exhaustive rather than a denylist: adding a known identity forces an
    /// explicit policy choice, while `.unknown` remains consequential and prompts.
    static func isAutoAllowed(_ tool: ToolIdentity) -> Bool {
        switch tool {
        case .read, .glob, .grep, .notebookRead,
             .todoWrite, .todoRead, .taskCreate, .taskUpdate, .taskList, .taskGet,
             .task, .toolSearch:
            return true

        case .mcp(let name):
            // Threading's own display tools draw in a panel the user is already looking at, and
            // are allowlisted for terminal sessions for the same reason. Compare the complete
            // built-in identity: MCP server names may themselves contain the `__` delimiter, so
            // the server-name prefix is not an identity boundary.
            return MCPDefaults.isBuiltInAllowedToolName(name)

        case .bash, .write, .edit, .multiEdit, .notebookEdit,
             .webFetch, .webSearch, .plan, .unknown:
            return false
        }
    }
}
