import Foundation

// MARK: - Hook Lifecycle Event

/// The turn boundaries an agent reports through its own hooks.
///
/// These exist because the alternative is inference. `SessionActivityTracker` derives the same
/// states from PTY output volume, which works for any program but is a proxy: it cannot tell
/// the agent thinking from the agent redrawing, and it needs a byte threshold and three quiet
/// periods to stay honest. A hook says so directly.
///
/// Only the events Threading acts on are registered. Every hook is a process spawned on the
/// agent's own turn boundary, so registering one that nothing consumes spends the user's
/// latency to learn nothing.
enum HookLifecycleEvent: String, CaseIterable {
    /// A prompt was submitted — the turn is starting.
    case turnStarted

    /// The agent finished its turn and is waiting.
    case turnFinished

    /// The agent is asking for something and cannot continue until it is answered.
    case awaitingUser

    /// A session began, which is where an agent-assigned identifier first becomes known.
    case sessionStarted

    /// A delegated child began running.
    case subagentStarted

    /// A delegated child stopped and may now name its durable transcript.
    case subagentStopped

    /// A tool whose whole result is the user's answer was called, so the turn is parked on them.
    ///
    /// Separate from `awaitingUser`, which is the runtime's own notion of waiting and is late:
    /// Claude raises one `Notification` *hook* for a permission prompt and for an idle prompt
    /// alike — `HookNotificationKind` is what tells those apart, out of the payload — and only
    /// six seconds after the *keyboard* goes quiet, so a user reading the question, or arrowing
    /// through its options, is never reported at all. This event is the tool call itself. It
    /// arrives before the question is drawn, it names the call that raised it, and only that
    /// call ending clears it.
    ///
    /// Which tools count is `TurnBlockingTools`, per runtime.
    case blockingAskOpened

    /// The tool that was asking returned, so the turn is running again.
    ///
    /// "Returned" covers answered, dismissed and interrupted alike — all three mean the thing
    /// the turn was stopped on is over.
    case blockingAskClosed

    /// How Claude's settings file registers this event.
    var claudeRegistration: HookRegistration {
        switch self {
        case .turnStarted: return HookRegistration(eventNames: ["UserPromptSubmit"])
        case .turnFinished: return HookRegistration(eventNames: ["Stop"])
        case .awaitingUser: return HookRegistration(eventNames: ["Notification"])
        case .sessionStarted: return HookRegistration(eventNames: ["SessionStart"])
        case .subagentStarted: return HookRegistration(eventNames: ["SubagentStart"])
        case .subagentStopped: return HookRegistration(eventNames: ["SubagentStop"])
        case .blockingAskOpened:
            return .matched(
                eventNames: ["PreToolUse"],
                tools: TurnBlockingTools.names(for: .claude)
            )
        case .blockingAskClosed:
            // Both names, because the ask ends both ways and only one of them is the happy one:
            // `PostToolUse` when the user answered, `PostToolUseFailure` when they pressed
            // Escape — which is reported as an interrupt and fires nothing else. A session
            // listening only for the first would keep the blocked mark for the rest of the turn
            // while the agent worked on. Both carry the `tool_use_id` of the call they are
            // about — measured on CLI 2.1.222, where answering a question produced a
            // `PostToolUse` bearing the same id as the `PreToolUse` that opened it.
            return .matched(
                eventNames: ["PostToolUse", "PostToolUseFailure"],
                tools: TurnBlockingTools.names(for: .claude)
            )
        }
    }

    /// How Codex's `hooks.json` registers this event.
    ///
    /// Codex 0.144.6 carries the same turn vocabulary as Claude apart from `Notification`, which
    /// it does not emit, and it exposes no tool whose result is the user's answer — so a Codex
    /// session reports its turn boundaries but never that it is waiting on the user.
    var codexRegistration: HookRegistration {
        switch self {
        case .turnStarted: return HookRegistration(eventNames: ["UserPromptSubmit"])
        case .turnFinished: return HookRegistration(eventNames: ["Stop"])
        case .sessionStarted: return HookRegistration(eventNames: ["SessionStart"])
        case .awaitingUser: return .unsupported
        case .subagentStarted: return HookRegistration(eventNames: ["SubagentStart"])
        case .subagentStopped: return HookRegistration(eventNames: ["SubagentStop"])
        case .blockingAskOpened, .blockingAskClosed:
            // Nothing to scope a hook to, so nothing is registered — and no hook name is
            // guessed here either, since an unverified one would install an entry the CLI
            // never fires. Wiring a future Codex is two edits: name its asking tool in
            // `TurnBlockingTools`, and return `.matched` with the hook names it reports the
            // call's start and end under. Everything downstream already reads both.
            return .unsupported
        }
    }
}

// MARK: - Hook Registration

/// How one lifecycle event is registered with one runtime: the hook names that report it, and
/// the tools those hooks are limited to.
///
/// Plural names because a single fact can arrive under more than one hook — an ask ends whether
/// its tool returned or was interrupted, and the two are different events to the CLI. Kept as a
/// value rather than a bare string so the matcher travels with the names it belongs to: they are
/// only correct together, and a hook name that reaches an installer without its matcher is
/// exactly the registration that must never be written.
struct HookRegistration: Equatable {

    // MARK: - Properties

    /// The runtime's own names for the hooks that report this event. Empty means the runtime
    /// cannot report it, and nothing is installed.
    let eventNames: [String]

    /// The tool-name pattern the hooks are limited to, or nil when the event fires on its own
    /// boundary rather than on a tool.
    let toolMatcher: String?

    /// Whether there is anything to install.
    var isSupported: Bool { !eventNames.isEmpty }

    // MARK: - Initialization

    init(eventNames: [String], toolMatcher: String? = nil) {
        self.eventNames = eventNames
        self.toolMatcher = toolMatcher
    }

    // MARK: - Public Methods

    /// A registration scoped to particular tools, or nothing at all when the runtime names none.
    ///
    /// The refusal is the point. A tool-scoped event says something about the tools it names —
    /// "the turn is parked on the user" — and registering it unmatched would say that about
    /// every `Read` and every `Bash` in the session. An empty list is how a runtime with no such
    /// tool declines, and this is what keeps that from silently becoming "hook everything".
    static func matched(eventNames: [String], tools: [String]) -> HookRegistration {
        guard !tools.isEmpty else { return .unsupported }
        return HookRegistration(
            eventNames: eventNames,
            toolMatcher: tools.joined(separator: HookRegistrationDefaults.matcherSeparator)
        )
    }

    /// The runtime has no hook for this event.
    static let unsupported = HookRegistration(eventNames: [])
}

// MARK: - Hook Registration Defaults

enum HookRegistrationDefaults {
    /// Both CLIs match a hook's `matcher` against the tool name as a regular expression, so
    /// alternation is how a list of tools becomes one entry.
    static let matcherSeparator = "|"

    /// The key a matcher is written under, which both CLIs spell the same way.
    static let matcherKey = "matcher"
}

// MARK: - Hook Notification Kind

/// Why a runtime raised its own "waiting" notice, on the one axis that decides whether the
/// notice is evidence of anything: whether somebody is actually being asked.
///
/// Claude raises the same `Notification` hook for a permission prompt and for a prompt that has
/// merely sat idle, and for years the event name was all Threading read — so the two were the
/// same fact here. They are not the same fact in the payload: `notification_type` names which,
/// and `idle_prompt` is the CLI saying outright that *nothing* is being asked. That distinction
/// is the whole reason this type exists; see `SessionActivityTracker.noteAwaitingUser`.
enum HookNotificationKind: Equatable, Sendable {

    /// The prompt has sat idle with nobody typing at it. Measured on CLI 2.1.238: raised once
    /// `messageIdleNotifThresholdMs` (60s) passes, carrying "Claude is waiting for your input".
    ///
    /// It names no question, because there is none — which is exactly why a session that is
    /// waiting on its own delegated work is the shape that raises it.
    case idlePrompt

    /// Anything else, **including a notice that named no type at all**.
    ///
    /// A permission prompt, a background child asking for input, a runtime that predates the
    /// field, a type a later CLI invents: all of them read as a notice worth flagging, which is
    /// what every notice read as before the field was parsed. Suppression is opt-in by exact
    /// name, so the failure direction of an unknown type is the loud one.
    case unspecified

    /// Reads the kind out of the type a runtime reported.
    ///
    /// One recognised spelling, deliberately. `BackgroundWorkKind` reads two because both of
    /// Claude's surfaces report background work; only the hook reports this.
    init(reportedType: String?) {
        switch reportedType {
        case "idle_prompt":
            self = .idlePrompt
        default:
            self = .unspecified
        }
    }
}

// MARK: - Hook Lifecycle Report

/// One lifecycle event, as it arrived from a hook.
struct HookLifecycleReport {
    let sessionID: SessionID
    let event: HookLifecycleEvent

    /// The agent's own identifier for the conversation, when it named one.
    ///
    /// For Claude this is the id Threading minted and already knows. For Codex it is the id the
    /// CLI assigns itself, which is otherwise only recoverable by scanning rollout files.
    ///
    /// Typed at the boundary rather than downstream: this is `TranscriptID`'s domain exactly —
    /// a runtime's own name for a conversation — and `AgentRuntime` used to re-wrap the raw
    /// string *and* re-check it for emptiness before storing it. An id present but empty is a
    /// payload that named nothing, so it is dropped here and the read site keeps one question
    /// instead of two.
    let agentSessionID: TranscriptID?

    /// The prompt text, on `turnStarted` only.
    let prompt: String?

    /// The tool call an ask-shaped event describes, by the identity the runtime gave it.
    ///
    /// `tool_use_id` where the runtime supplies one — Claude carries the same one on all three
    /// tool hooks, which is what lets an ask be closed by the call that opened it rather than by
    /// the next tool of the same name. The tool's own name is the fallback, and pairs correctly
    /// for a runtime that asks one question at a time.
    let toolCallID: String?

    /// Provider-issued child identity and metadata on subagent events.
    let subagentID: String?
    let subagentType: String?
    let subagentTranscriptPath: String?
    let lastAssistantMessage: String?
    let turnID: String?

    /// The root conversation transcript reported on ordinary lifecycle events.
    ///
    /// Separate from `subagentTranscriptPath`: Codex's missing interrupt boundary is recovered
    /// from this file, while a child's path belongs only to its navigator row.
    let transcriptPath: String?

    /// The directory the agent says it is working in, as of this event.
    ///
    /// The runtime's own answer, and the only sound one. A session's *owned* checkout is where
    /// Threading launches it; where it is executing is a different fact, and an agent that runs
    /// `cd elsewhere && …` per tool call moves the second without moving the first. Neither
    /// OSC 7 nor the PTY root process's cwd sees that — both were measured still naming the
    /// launch directory for a chat whose own status line named a sibling worktree — so this
    /// field is what `SessionExecutionLocus` reconciles against ownership.
    ///
    /// Present on every event both hook-capable runtimes emit; nil for a runtime that reports
    /// no lifecycle at all, and nil while the user has lifecycle reporting turned off. Nil is
    /// "unknown", never "unchanged" — see `AgentCapabilities.lifecycleReportedWorkingDirectory`.
    let workingDirectory: String?

    /// The agent's own work still in flight as its turn ends, by the identifier it gave each.
    ///
    /// Claude states this on `Stop` as `background_tasks`, and its own description of the field
    /// is the reason this is read at all: it exists to let a hook tell "session is done" from
    /// "session is paused waiting for background work to wake it". A backgrounded shell, a
    /// detached subagent or an MCP monitor will re-enter the conversation on its own, without
    /// the user, so the `Stop` that precedes it is not the end of anything.
    ///
    /// Identity and kind rather than a count: `BackgroundWorkLedger` has to tell delegated work
    /// from standing work, and standing work this turn started from standing work carried over
    /// from an earlier one. A count answers neither.
    ///
    /// Empty where the key is absent, which is every event but `Stop`/`SubagentStop`, and every
    /// Codex report — 0.144.6 has no equivalent, so those sessions keep the old behaviour.
    let backgroundWork: [BackgroundTask]

    /// Why the runtime says it is waiting — meaningful on `awaitingUser`, the only event that
    /// carries one.
    ///
    /// `.unspecified` on every other event, and on an `awaitingUser` whose payload named no
    /// type. Those are the same fact downstream, since only an exactly recognised kind is ever
    /// treated as anything less than a notice worth flagging.
    let notification: HookNotificationKind

    /// Which checkout ownership `workingDirectory` was reported under, as
    /// `SessionExecutionLocusTracker.ownershipEpoch(forSessionID:)` counted it when the report
    /// arrived — or nil for a report nobody stamped, which is read as current.
    ///
    /// A `var` rather than part of the payload because the payload knows nothing about it: the
    /// listener stamps the value on the main actor before any checkout fence runs, and the
    /// tracker compares it afterwards. The Stop hook's report crosses exactly that fence.
    var capturedOwnershipEpoch: UInt64?

    /// Builds a report from a hook's JSON payload, or nil if it names no event.
    init?(sessionID: SessionID, event: HookLifecycleEvent?, payload: [String: Any]) {
        guard let event else { return nil }

        self.sessionID = sessionID
        self.event = event
        self.capturedOwnershipEpoch = nil
        self.agentSessionID = (payload["session_id"] as? String)
            .flatMap { $0.isEmpty ? nil : TranscriptID($0) }
        self.prompt = payload["prompt"] as? String
        self.toolCallID = Self.text(payload["tool_use_id"]) ?? Self.text(payload["tool_name"])
        self.subagentID = payload["agent_id"] as? String
        self.subagentType = payload["agent_type"] as? String
        self.subagentTranscriptPath = payload["agent_transcript_path"] as? String
        self.lastAssistantMessage = payload["last_assistant_message"] as? String
        self.turnID = payload["turn_id"] as? String
        self.transcriptPath = Self.text(payload["transcript_path"])
        self.workingDirectory = Self.text(payload["cwd"])
        // Only the identity and the kind are taken: the rest of each entry describes work this
        // side never renders. An entry whose id is missing falls back to its position, which is
        // stable across boundaries for as long as the entry is — so unreadable work still reads
        // as carried over rather than as new on every turn. A missing type reads `.standing`,
        // which is the direction that changes nothing.
        //
        // Read per entry for the same reason the members are read per member: this list is what
        // says work is *carried over*, so losing all of it to one unreadable neighbour makes
        // every surviving task read as new again on the next turn — the exact effect the id
        // fallback above exists to prevent. The wire's own offset is kept rather than the offset
        // left after compaction, so an entry named by its position is not renamed the moment a
        // neighbour breaks.
        let tasks = WireList.indexed(
            payload["background_tasks"],
            site: WireListSite.hookBackgroundTasks,
            log: ThreadingLogger.agent
        ) ?? []
        self.backgroundWork = tasks.map { index, task in
            BackgroundTask(
                id: task["id"] as? String ?? "#\(index)",
                kind: BackgroundWorkKind(reportedType: task["type"] as? String)
            )
        }
        // Read on every event rather than only on `awaitingUser`: a payload that names a type
        // means the same thing whatever hook carried it, and a read gated on the event would
        // have to be kept in step with the event list forever.
        self.notification = HookNotificationKind(
            reportedType: Self.text(payload["notification_type"])
        )
    }

    /// A payload string, or nil when the key is absent *or* present and empty.
    ///
    /// The two are the same fact — the hook named nothing — and separating them downstream only
    /// gives every read site the chance to disagree about which counts.
    private static func text(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    // MARK: - Child Admission

    /// Whether a `SubagentStart`/`SubagentStop` report describes a real delegated child, rather
    /// than the parent reporting its own turn — see `SubagentChildAdmission` for that shape and
    /// the measurements behind the rule.
    ///
    /// A child already tracked is always admitted, so one accepted at Start still receives its
    /// Stop even if that report carries less than the first did.
    func describesChildAgent(
        isAlreadyTracked: Bool,
        transcriptExists: (String) -> Bool = {
            FileManager.default.fileExists(atPath: $0)
        }
    ) -> Bool {
        isAlreadyTracked || SubagentChildAdmission.namesAChild(
            role: subagentType,
            path: subagentTranscriptPath,
            transcriptExists: transcriptExists
        )
    }
}

// MARK: - Hook Lifecycle Relay

/// Delivers lifecycle reports from the listener to whatever is tracking the session.
///
/// A relay rather than a direct call because the reports arrive off the network, in a type that
/// knows nothing about AppKit, while every consumer of them is main-actor state. This is the
/// same shape `PermissionBroker.present` uses, and for the same reason.
@MainActor
enum HookLifecycleRelay {

    // MARK: - Properties

    /// Set by whatever owns the running sessions. Nil means the reports are dropped, which is
    /// correct: a report about a session nothing is showing changes nothing.
    static var observe: ((HookLifecycleReport) -> Void)?

    // MARK: - Public Methods

    /// Records one report and passes it on.
    ///
    /// Journalling happens here rather than in the observer so it survives a session that has
    /// no live controller — the prompt is the one thing a terminal session holds nowhere else
    /// until the CLI writes its transcript, which is exactly the window a crash lands in.
    static func deliver(_ report: HookLifecycleReport) {
        // Live view only. These arrive on every turn boundary of every session, so they belong
        // in the ring buffer `log stream` reads, not in a journal kept for two weeks.
        ThreadingLogger.agent.debug(
            """
            Lifecycle \(report.event.rawValue, privacy: .public) \
            for \(report.sessionID.uuidString, privacy: .public)
            """
        )

        if report.event == .turnStarted, let prompt = report.prompt, !prompt.isEmpty {
            EventLog.shared.record(.session, "Prompt submitted", [
                "session": report.sessionID.uuidString,
                "prompt": prompt
            ])
        }

        guard let observe else {
            // Before the relay is installed, or after it is torn down. Worth a record: it means
            // reports are arriving and being discarded, which from the sidebar is
            // indistinguishable from an agent that never reported at all.
            ThreadingLogger.agent.warning("Lifecycle report with no observer installed")
            EventLog.shared.record(.hooks, "Lifecycle report dropped, no observer", [
                "session": report.sessionID.uuidString,
                "event": report.event.rawValue
            ])
            return
        }

        observe(report)
    }
}
