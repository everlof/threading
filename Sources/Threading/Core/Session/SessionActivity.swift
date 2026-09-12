import Foundation
import OSLog

// MARK: - Session Activity

/// What a session is currently doing, as shown in the sidebar.
enum SessionActivity: Equatable, Sendable {
    /// No terminal allocated; the session can be resumed.
    case dormant

    /// Running but producing no output — an agent waiting at its prompt.
    case idle

    /// Producing output, i.e. the agent has an open turn.
    case working

    /// The prompt can accept another message, while work left by an earlier turn can still
    /// re-enter the conversation without anybody typing.
    case readyWithBackgroundWork

    /// Asked something mid-turn and cannot go on until it is answered.
    ///
    /// Separate from `needsAttention` because the two cost the user different things: this one
    /// is a turn stopped dead waiting on them, where a finished turn is only unread. They are
    /// the same fact — the session wants you — at opposite ends of urgency, and a sidebar that
    /// drew them alike could not say which of ten sessions was actually blocked.
    case awaitingUser

    /// Finished working while the session was not on screen.
    case needsAttention

    /// The provider refused the turn because the account's usage limit is spent, and nothing
    /// will happen here until the window resets or the conversation moves to another login.
    ///
    /// Its own state rather than a shade of `needsAttention`, because the two answer different
    /// questions. Every other state here says what the session is doing; this one says why it is
    /// doing nothing, and it is the only one the user cannot resolve by looking. It was found by
    /// wearing the alternative: a session refused at 10:45 went on drawing a spinner until the
    /// user noticed at 11:04 and asked what had happened.
    case limitReached

    /// The name this state is written under in the log.
    ///
    /// Stated rather than reflected: a diagnostic trail is read months later beside the code
    /// that wrote it, and `String(describing:)` would silently rename every past line the day
    /// a case is renamed.
    var logName: String {
        switch self {
        case .dormant: return "dormant"
        case .idle: return "idle"
        case .working: return "working"
        case .readyWithBackgroundWork: return "readyWithBackgroundWork"
        case .awaitingUser: return "awaitingUser"
        case .needsAttention: return "needsAttention"
        case .limitReached: return "limitReached"
        }
    }
}

enum SessionProcessState: Equatable, Sendable {
    case dormant
    case starting
    case ready
}

enum SessionTurnAuthority: Equatable, Sendable {
    case inferred
    case reported
}

enum SessionTurnState: Equatable, Sendable {
    case none
    case inFlight(SessionTurnAuthority)

    var isInFlight: Bool {
        if case .inFlight = self { return true }
        return false
    }
}

enum SessionContinuationState: String, Equatable, Sendable {
    case none
    case delegated
    case standing

    var isActive: Bool { self != .none }
}

enum SessionRuntimeBlocker: Equatable, Sendable {
    case none
    case awaitingUser
    case usageLimit
}

/// Operational truth kept apart from the reader-specific activity projected into UI.
struct SessionRuntimeSnapshot: Equatable, Sendable {
    let process: SessionProcessState
    let turn: SessionTurnState
    let continuation: SessionContinuationState
    let blocker: SessionRuntimeBlocker
    let activity: SessionActivity
    let reportsOwnTurns: Bool

    static let dormant = SessionRuntimeSnapshot(
        process: .dormant,
        turn: .none,
        continuation: .none,
        blocker: .none,
        activity: .dormant,
        reportsOwnTurns: false
    )

    var hasOpenTurn: Bool { turn.isInFlight }
    var hasPendingOutcome: Bool { hasOpenTurn || continuation.isActive }
    var isPromptReady: Bool {
        process == .ready && !hasOpenTurn && blocker == .none
    }
    var canInterrupt: Bool { process == .ready && hasOpenTurn }
    var hasWorkAtRisk: Bool { hasPendingOutcome }
}

struct SessionRuntimeTransition: Equatable, Sendable {
    let previous: SessionRuntimeSnapshot
    let current: SessionRuntimeSnapshot

    var beganTurn: Bool { !previous.hasOpenTurn && current.hasOpenTurn }
    var endedTurn: Bool { previous.hasOpenTurn && !current.hasOpenTurn }
    var beganPendingOutcome: Bool {
        !previous.hasPendingOutcome && current.hasPendingOutcome
    }
    var completedPendingOutcome: Bool {
        previous.hasPendingOutcome && !current.hasPendingOutcome
    }
    var becamePromptReady: Bool { !previous.isPromptReady && current.isPromptReady }
    var becamePromptUnavailable: Bool { previous.isPromptReady && !current.isPromptReady }
}

/// O(1) transition memory for adapters that receive snapshots rather than lifecycle reports.
struct SessionRuntimeTransitionLedger {
    private var lastSnapshot: [SessionID: SessionRuntimeSnapshot] = [:]

    mutating func observe(
        _ snapshot: SessionRuntimeSnapshot,
        for sessionID: SessionID
    ) -> SessionRuntimeTransition {
        let previous = lastSnapshot.updateValue(snapshot, forKey: sessionID) ?? .dormant
        return SessionRuntimeTransition(previous: previous, current: snapshot)
    }

    mutating func remove(_ sessionID: SessionID) {
        lastSnapshot.removeValue(forKey: sessionID)
    }
}

// MARK: - Session Activity Cause

/// What moved a fact, for the one line the tracker leaves behind when the state changes.
///
/// Named for the **input** rather than the outcome, because the outcome is already in the state
/// and the input is the thing that cannot be recovered afterwards. `needsAttention` has three
/// ways in — a turn that ended off screen, a runtime's own idle-prompt notice, a bell — and they
/// are fixed in three different places. Without this the row says a session wants you and the
/// log says nothing at all about which of the three put it there, which is exactly the question
/// somebody asks the first time a mark appears while they are looking straight at the session.
enum SessionActivityCause: String {
    /// The session came on screen or left it.
    case seen

    /// The user submitted terminal input while a reported turn was waiting on them.
    case userInput

    /// Output crossed the byte threshold, on a session with no hooks of its own.
    case output

    /// The quiet timer expired: an inferred turn ended because nothing was written for a while.
    case quiet

    case turnStarted
    case turnFinished

    /// A Codex turn the CLI opened for itself, read off its rollout because no hook reports it.
    case turnStartedFromTranscript

    /// A Codex turn closed by its rollout's own completion record, for the turn whose `Stop`
    /// did not arrive.
    case turnFinishedFromTranscript

    /// A Codex turn closed by its rollout rather than by the `Stop` that never came.
    case turnInterrupted

    /// A turn the provider refused for something other than the account's allowance.
    case turnRefused

    /// The runtime's own "I am waiting" notice — Claude's `Notification` hook. The only cause
    /// that raises the unread mark on a session that is **on screen**.
    case awaitingUserReported

    case blockingAskOpened
    case blockingAskClosed
    case limitParked
    case limitCleared

    /// The terminal bell, which agents ring to ask for attention.
    case bell

    /// The session lost its process, or gained one.
    case dormant
    case running
    case sessionStarted

    /// The runtime's own transcript was adopted as a turn-boundary source — Codex's rollout,
    /// once a validated one is being observed.
    case transcriptAdopted

    /// Whether the agent said this, as against Threading inferring it from bytes, timers or the
    /// session's own transcript.
    ///
    /// The line that decides what is worth a log entry when the state does **not** move: a hook
    /// arriving and changing nothing is the case that is impossible to reconstruct later (it
    /// leaves no mark on the row, no notification, nothing), while output that changes nothing
    /// is the normal condition of a working session and would bury the trail it belongs to.
    var isReported: Bool {
        switch self {
        case .turnStarted, .turnFinished, .turnInterrupted, .awaitingUserReported,
             .blockingAskOpened, .blockingAskClosed:
            return true
        // The two rollout boundaries are Threading reading a file, not the agent speaking —
        // the same side of this line as `turnRefused`, which is read the same way.
        case .seen, .userInput, .output, .quiet, .turnStartedFromTranscript,
             .turnFinishedFromTranscript, .turnRefused, .limitParked, .limitCleared, .bell,
             .dormant, .running, .sessionStarted, .transcriptAdopted:
            return false
        }
    }
}

// MARK: - Session Activity Tracker

/// Derives a session's activity, from the agent's own hooks where it reports them and from its
/// terminal output where it does not.
///
/// Output is the general signal: an idle agent writes nothing to its PTY, so output means work,
/// and that holds for any program rather than one specific agent. It is a proxy, though, and
/// needs a byte threshold plus three quiet periods to stay honest — it cannot tell a session
/// thinking from a session repainting.
///
/// An agent with lifecycle hooks says so outright, and `noteTurnStarted`/`noteTurnFinished` are
/// believed over anything inferred. The first such report latches `reportsOwnActivity`, after
/// which output stops *ending* a turn: the two disagree constantly and by design — a working
/// agent is quiet while it waits on the model, and noisy after its turn has ended while the CLI
/// redraws its footer. Falling back per-event would flicker between them.
///
/// Output stops *opening* one on the narrower fact that the runtime has declared a start
/// (`reportsTurnStarts`), because a `Stop` proves only that it declares endings — and a runtime
/// that opens its own turns, as Codex does in goal mode, declares no start for them at all. See
/// `outputMayOpenTurn`.
///
/// Shells never report, so they keep the heuristic in full.
///
/// **The turn and the question are separate facts**, and collapsing them into the single enum
/// this reports was a bug the sidebar wore for a whole run: an agent asks for a permission
/// *inside* a turn it goes on to finish, so `awaitingUser` must not end the turn, and answering
/// it must return to `working` rather than to `idle`. Before that split, the only transition
/// back into `working` was the *next* `UserPromptSubmit` — so one mid-turn question, one bell,
/// or one glance at a flagged session blanked the row for the rest of the turn while the agent
/// went on working. Measured against a session still appending to its own transcript with no
/// indicator beside it.
@MainActor
final class SessionActivityTracker {

    // MARK: - Properties

    private(set) var activity: SessionActivity = .idle {
        didSet {
            guard activity != oldValue else { return }
            onChange?(activity)
        }
    }

    /// Called whenever the activity changes.
    var onChange: ((SessionActivity) -> Void)?

    /// Operational changes, including turn boundaries hidden by a continuous presentation.
    var onRuntimeChange: ((SessionRuntimeSnapshot) -> Void)?

    private var lastPublishedRuntimeSnapshot: SessionRuntimeSnapshot = .dormant

    /// Called once for each new attention episode, independently of who is looking.
    /// Read state belongs to participant identities rather than this process-local tracker.
    var onAttention: (() -> Void)?

    /// Which session this is, for the log. Optional because the tracker is constructed before
    /// its owner knows — and because a fixture has no session at all.
    var sessionID: SessionID?

    /// What moved the state last. Kept as a value as well as logged, so the rule can be
    /// asserted in a test rather than only read in `log show`.
    private(set) var lastCause: SessionActivityCause?

    /// Whether the session is currently on screen, which decides if finishing work is
    /// worth flagging.
    var isVisible: Bool = false {
        didSet {
            guard isVisible else { return }

            // The person looked at this episode, so later inferred output is allowed to describe
            // new work again. This is independent of whether `awaitsUser` needs clearing: a bell
            // inside an open turn remains blocked, but its interruption episode was still seen.
            attentionEpisodeOpen = false

            // Looking at a finished session spends its unread mark. It does not answer a
            // question inside an open turn: presentation is not interaction, and treating it as
            // one both cleared real prompts early and admitted a restored TUI's later repaint as
            // fresh work. Submitted terminal input owns that edge below.
            //
            // `turnInFlight` is the distinction: after a turn finished, the same flag is its
            // unread result and being seen spends it. `openAsks` and `limitPark` are deliberately
            // untouched; their explicit close/recovery boundaries remain their owners.
            guard awaitsUser, !turnInFlight else { return }
            awaitsUser = false
            settle(.seen)
        }
    }

    /// Whether this session has ever reported a turn boundary through a hook.
    ///
    /// Latched rather than per-event: once an agent has proved it reports, its silence is
    /// meaningful. Treating a missing report as "fall back to counting bytes" would hand the
    /// state straight back to the proxy this exists to replace.
    private(set) var reportsOwnActivity = false

    /// Whether the runtime has ever declared a turn **beginning**.
    ///
    /// `reportsOwnActivity` is the right latch for *believing* a report and the wrong one for
    /// switching off the half of the heuristic that opens a turn: a `Stop` proves the runtime
    /// declares endings and says nothing about starts, so a session whose first report is one
    /// has been given no beginning to be silent about. See `outputMayOpenTurn`.
    private(set) var reportsTurnStarts = false

    /// Whether the runtime has ever declared a turn **ending** — `Stop`, or one of the two
    /// transcript readers standing in for it.
    ///
    /// The other half of the same split, and what decides whether silence ends a turn. A
    /// runtime that declared one ending will declare the next, so its quiet stretches are the
    /// agent thinking rather than the turn being over.
    private(set) var reportsTurnEnds = false

    /// Whether this process has been heard from at all — its `SessionStart` hook, or any
    /// later lifecycle report. It exists for delivery: typing into a PTY whose `isRunning`
    /// flipped at spawn lands text in a login shell, and this is the earliest honest "the
    /// composer exists now". Without it, every session idle since an app relaunch read as
    /// still-booting forever, because SessionStart was the one report nothing latched.
    ///
    /// It used to be deliberately weaker than `reportsOwnActivity`, on the reasoning that a
    /// start announcement does not claim turn boundaries will be declared. That exception was
    /// measured to cost more than it protected — see `noteSessionStarted` — and the two now
    /// latch together; this one stays a separate fact because delivery asks a narrower
    /// question than activity does.
    private(set) var hasHeardFromProcess = false

    /// Whether a turn is open: begun, and not yet reported finished.
    private var turnInFlight = false

    /// Whether the open turn was **declared** — by a hook, or by the runtime's own rollout —
    /// rather than inferred from output.
    ///
    /// It decides one thing: whether silence may end this turn. A declared turn will be
    /// declared over, so a gap in its output is the agent waiting on the model; an inferred
    /// turn has nothing coming and the quiet timer is the only ending it will ever get. The
    /// two are not a property of the *session* — a Codex session's first goal-continuation
    /// burst opens a turn by inference half a second before its rollout names it — so this
    /// belongs to the turn and is re-decided every time one opens.
    private var turnWasDeclared = false

    /// The provider's identity for the reported turn, where it supplies one.
    ///
    /// Codex's transcript fallback lands after a background file read. Matching that record to
    /// the open turn prevents an old interruption from closing a newer turn that began before
    /// the read returned to main.
    private var reportedTurnID: String?

    /// A Codex finish may grant output one bounded chance to stand in for a rollout start when
    /// no validated rollout is available. The grant exists only during that finish's continuation
    /// grace and is consumed by the first inferred turn.
    private var outputInferredContinuationAvailable = false

    /// Distinguishes that granted continuation from an ordinary inferred turn after the runtime
    /// has begun reporting. Its output may keep the quiet timer alive; unrelated reported output
    /// may not revive inference.
    private var outputInferredContinuationInFlight = false

    /// The last turn this tracker watched end, kept after its own `reportedTurnID` is cleared.
    ///
    /// The rollout's ending record and its `Stop` hook land milliseconds apart, so a background
    /// scan can be taken before the ending was written and delivered after it was acted on.
    /// Without this, that scan would re-open the finished turn from its `task_started`.
    private var lastEndedTurnID: String?

    /// How many turns this session has begun.
    ///
    /// The same guard `reportedTurnID` provides, for a runtime that names no turn: Claude's
    /// `UserPromptSubmit` payload carries a session and a prompt and no turn identity at all, so
    /// a fallback read for one turn has nothing of the provider's to match against. A caller that
    /// starts an asynchronous read records this and hands it back, and a result that outlived its
    /// turn is refused — which is the whole rule either way, since a fallback admitted after the
    /// turn it was read for has ended is a fallback that stops the wrong work.
    ///
    /// Monotonic and never reset. Relaunching clears `turnInFlight`, which already refuses a
    /// stale result; restarting the count as well would let one collide with a live turn.
    private(set) var turnGeneration = 0

    /// The inferred attention flag: a possible response request inside an open turn, or an
    /// unread result after the turn ends. Only the first is an operational blocker.
    ///
    /// Held apart from the turn because the two are independent — the flag can be raised and
    /// lowered several times inside one turn.
    ///
    /// This is the *inferred* half of asking: it comes from a runtime's own notice, which cannot
    /// say what it is waiting for, so submitted input and a substantial on-screen output burst
    /// are both allowed to lower it. `openAsks` is the half known outright and obeys neither.
    private var awaitsUser = false

    /// Ask-shaped tool calls that have opened and not yet closed, keyed by the call.
    ///
    /// The fact `awaitsUser` cannot carry. A tool whose result *is* the user's answer has
    /// stopped the turn for as long as it is open, and nothing about the terminal changes that:
    /// the question is drawn by the same process that would be "producing output", and the user
    /// arrowing through its options repaints the whole box. Both of those lower `awaitsUser`,
    /// correctly, and both would be wrong here — so this is settled ahead of it and cleared only
    /// by the call ending.
    ///
    /// Keyed rather than counted so a close pairs with its own open. Out-of-order or duplicated
    /// hooks then converge: inserting an id twice is one entry, and removing an id that was
    /// never inserted is nothing at all, where a counter would drift a session permanently into
    /// or out of the mark.
    private var openAsks: Set<String> = []

    /// Why the agent's turn ended on work that will wake it again, if it did.
    ///
    /// The *kind* is kept and not just the fact, because the two kinds carry different
    /// guarantees about ever ending, and one rule needs that difference —
    /// `honoursAwaitingUserNotice`. It is read straight off the `Stop` payload rather than
    /// inferred; `BackgroundWorkLedger` owns the separate question of whether there is a pause
    /// at all.
    enum TurnPause {
        /// The turn ended having handed nothing off, or having left only work an earlier turn
        /// already parked. Whatever happens next is the user's move.
        case none

        /// A subagent or a workflow is still running. **Bounded by construction**: it ends, and
        /// its result re-enters this conversation without anybody typing. So the row will
        /// correct itself, and a notice claiming the session wants the user meanwhile is wrong
        /// about a fact this side already holds.
        case delegated

        /// A running shell, or a monitor this turn started. It may stand for hours and nothing in the
        /// payload says which — an `npm test` and an `npm run dev` are the same entry — so
        /// nothing here may assume it will ever end.
        case standing

        var logName: String {
            switch self {
            case .none: return "none"
            case .delegated: return "delegated"
            case .standing: return "standing"
            }
        }
    }

    /// What the agent left running when its turn ended, if anything is holding the session open.
    ///
    /// A third fact rather than a longer turn, because the turn genuinely did end: the CLI is
    /// back at its prompt and will answer the user. What has *not* happened is the session
    /// finishing — a backgrounded shell re-enters the conversation on its own, and the agent
    /// speaks again with nobody having typed. Reported by `Stop`, and only ever set for a
    /// session that reports its own turns.
    private var pause: TurnPause = .none

    /// Whether the turn is paused at all, which is all `settle()` has ever needed to know.
    private var pausedOnOwnWork: Bool { pause != .none }

    var runtimeSnapshot: SessionRuntimeSnapshot {
        let process: SessionProcessState = if isDormant {
            .dormant
        } else if hasHeardFromProcess {
            .ready
        } else {
            .starting
        }
        let continuation: SessionContinuationState = switch pause {
        case .none: .none
        case .delegated: .delegated
        case .standing: .standing
        }
        // After a turn ends, `awaitsUser` is an unread result, not an unanswered question.
        // Keep the same distinction as settle(): only an open turn can be inferred blocked;
        // an explicit ask owns its lifetime independently of the reported turn boundaries.
        let blocker: SessionRuntimeBlocker = if !openAsks.isEmpty || (turnInFlight && awaitsUser) {
            .awaitingUser
        } else if limitPark == .flagged {
            .usageLimit
        } else {
            .none
        }
        return SessionRuntimeSnapshot(
            process: process,
            turn: turnInFlight ? .inFlight(turnWasDeclared ? .reported : .inferred) : .none,
            continuation: continuation,
            blocker: blocker,
            activity: activity,
            reportsOwnTurns: reportsOwnActivity
        )
    }

    /// Claude commonly reports `Stop` and a later idle-prompt `Notification` for one result.
    /// They are one unread episode; new work opens the next one.
    private var attentionEpisodeOpen = false

    /// Tells work this turn started from work parked in an earlier one — see
    /// `BackgroundWorkLedger`, which is where that judgement and its reasoning live.
    private var backgroundWork = BackgroundWorkLedger()

    /// How the provider's rate limit has parked this session, if it has.
    ///
    /// A fifth fact, for `pausedOnOwnWork`'s reason: the refused turn genuinely ended (the
    /// transcript writes its `turn_duration`), but `Stop` never fires for it — measured in
    /// [`limit-recovery.md`](../../../docs/architecture/limit-recovery.md) — so without this
    /// the session strands `working` on a turn nothing will ever close. It is not an
    /// `openAsks` entry because nothing ever closes the CLI's chooser: answering it raises no
    /// hook, and the mark would never come down. And it is not `awaitsUser` inside an open
    /// turn, because being looked at would return a latched session — which has no quiet
    /// timer left — to `working` forever.
    enum LimitPark {
        /// No limit in force.
        case none

        /// The limit hit and nothing is handling it. Reads `limitReached`: not a question the
        /// user can answer, not a turn to be interrupted, and not work — a session that stopped
        /// for a reason it has to be told, since nothing on the row could otherwise say why an
        /// agent went quiet mid-plan.
        case flagged

        /// The limit hit and a continuation is armed. The process is sitting at its prompt
        /// with nothing owed and the composer's strip already names the arranged send, so the
        /// session reads `idle`: no beam, no mark, no notification. The mark exists to explain
        /// an *unexplained* stop, and this one is accounted for.
        case recovering

        var logName: String {
            switch self {
            case .none: return "none"
            case .flagged: return "flagged"
            case .recovering: return "recovering"
            }
        }
    }

    private var limitPark: LimitPark = .none

    /// Whether the session owns no process at all, which outranks both of the above.
    private var isDormant = false

    /// Whether the session was launched with nobody looking — a startup relaunch, not a click.
    ///
    /// Every launch before this one was made by selecting the session, so the tracker could
    /// assume boot output happens on screen, where it opens no flag. A relaunch in the
    /// background breaks that: the resume's TUI repaint is a burst over the byte threshold, it
    /// goes quiet, and the session lands on `needsAttention` — one unread mark and one silent
    /// notification per restored session, for work nobody did. While this is set, nothing the
    /// process emits on its own raises a flag or opens an inferred turn; it clears when the
    /// session receives user input, or when a turn genuinely begins.
    private var launchedUnattended = false

    private var bytesSinceQuiet = 0
    private var quietTimer: Timer?
    private let quietInterval: TimeInterval

    /// A reported Codex `Stop` whose next protocol fact may be an automatic goal continuation.
    ///
    /// The turn's internal facts are already closed while this is present, but the published
    /// activity remains `working`. A new turn cancels the pending finish without an intermediate
    /// row edge; expiry commits the ordinary idle/unread answer exactly once.
    private struct PendingReportedTurnFinish {
        let cause: SessionActivityCause
    }

    private var pendingReportedTurnFinish: PendingReportedTurnFinish?
    private var pendingReportedTurnFinishTimer: Timer?

    /// Read by the Codex rollout observer so output can prompt an early, non-postponing boundary
    /// scan while the published activity is being held continuous.
    var hasPendingReportedTurnFinish: Bool {
        pendingReportedTurnFinish != nil
    }

    /// Output arriving before this instant is a redraw we provoked, not the agent working.
    private var suppressOutputUntil: Date?

    init(quietInterval: TimeInterval = ActivityDefaults.quietInterval) {
        self.quietInterval = quietInterval
    }

    // MARK: - Public Methods

    /// Records a chunk of output and returns the accepted burst size when that output is strong
    /// enough to drive a provider-neutral activity presentation.
    ///
    /// `nil` is as important as the byte count: unattended launch paint, resize/pointer paint,
    /// echoed input below the working threshold, and output from an otherwise idle reporting
    /// session are not agent activity. The caller may animate only a non-nil answer.
    @discardableResult
    func recordOutput(byteCount: Int) -> Int? {
        // A background relaunch's boot output is a repaint we provoked, exactly like a
        // resize — except its window ends when the session is seen, not on a timer.
        if launchedUnattended { return nil }

        if isSuppressed {
            // A redraw we caused. It must not start a session working, but it also must not
            // end one that already is — so an in-flight session keeps its timer alive. A
            // reporting session has no such timer, and starting one here would end a turn only
            // its own `Stop` may end.
            if !reportsOwnActivity, turnInFlight {
                restartQuietTimer()
            }
            return nil
        }

        bytesSinceQuiet += byteCount

        // Below the threshold this is most likely the terminal echoing typed characters.
        guard bytesSinceQuiet >= ActivityDefaults.workingByteThreshold else { return nil }
        let acceptedByteCount = bytesSinceQuiet

        // Sustaining an inferred turn and opening a new one are different permissions. The old
        // combined gate made a one-time Codex continuation fallback permanent, so each idle TUI
        // repaint opened and quietly completed another fake turn.
        if turnInFlight, !turnWasDeclared,
           !reportsOwnActivity || outputInferredContinuationInFlight {
            bytesSinceQuiet = 0
            awaitsUser = false
            settle(.output)
            restartQuietTimer()
            return activity == .working ? acceptedByteCount : nil
        }

        // An agent that reports its own turn *starts* has already said what it is doing, and its
        // output may not start or end one. It answers exactly one question the reports leave
        // open: a burst *inside* a flagged turn means the user answered where they stood and the
        // agent carried on, which no hook fires for. Moving only towards working, and only
        // inside a turn the agent itself declared open, is what keeps this from re-opening the
        // flicker the latch exists to close.
        //
        // On screen only, for the same reason. Answering happens in the terminal being looked
        // at, so that is the one place output can mean "answered"; off screen the flag is the
        // only thing saying the session is waiting, and a stray redraw must not spend it.
        guard outputMayOpenTurn else {
            // Measured per burst here, unlike the heuristic below, so a prompt trickling a few
            // bytes at a time never adds up to an answer.
            bytesSinceQuiet = 0

            // A limit park is deliberately not lowered here. A burst in front of the user is
            // the CLI repainting around its chooser as readily as it is the agent carrying on,
            // and only one of those means the session can work again — the transcript says
            // which, so nothing has to be inferred from bytes.
            if isVisible, turnInFlight, awaitsUser {
                awaitsUser = false
                settle(.output)
            }
            return activity == .working ? acceptedByteCount : nil
        }

        // Once an off-screen inferred result has raised its hand, more bytes do not prove that a
        // new turn began. Full-screen CLIs repaint their idle prompt periodically, and treating
        // every repaint as a turn produced an unbounded working/quiet loop plus all of the Git,
        // transcript and project work attached to those fake edges. The episode is re-armed only
        // by a real interaction (`noteUserInput` or being viewed), an authoritative start, or a
        // process boundary. A runtime that has reported an ending keeps the Codex continuation
        // fallback: its next self-opened turn may have output before the rollout names it.
        if !turnInFlight, attentionEpisodeOpen, !reportsOwnActivity, !isVisible {
            bytesSinceQuiet = 0
            return nil
        }

        if !turnInFlight {
            let isGrantedReportedContinuation = outputInferredContinuationAvailable
            cancelPendingReportedTurnFinish()
            turnWasDeclared = false
            outputInferredContinuationInFlight = isGrantedReportedContinuation
        }
        turnInFlight = true
        awaitsUser = false
        settle(.output)
        // Nothing is coming to say this one is over, so silence has to. A turn the runtime
        // later declares cancels this timer where it adopts it.
        if !turnWasDeclared { restartQuietTimer() }
        return acceptedByteCount
    }

    /// Whether output is still allowed to open a turn.
    ///
    /// Three cases:
    ///
    /// - **Nothing reports here.** Shells, Grok, OpenCode: the heuristic is all there is.
    /// - **Codex reported an ending but has no rollout source.** The specific finish grants one
    ///   output-inferred continuation for its bounded reconciliation window. The grant is not a
    ///   permanent consequence of having reported some ending: a finished TUI can repaint its
    ///   idle screen forever, and each repaint used to become another fake turn and notification.
    /// - **The runtime declared a start.** Believed outright, exactly as before.
    ///
    private var outputMayOpenTurn: Bool {
        guard !reportsTurnStarts else { return false }
        if !reportsOwnActivity { return true }
        return outputInferredContinuationAvailable && pendingReportedTurnFinish != nil
    }

    /// Notes that the terminal was resized.
    ///
    /// Resizing sends `SIGWINCH`, and full-screen terminal apps answer it by repainting
    /// everything — a burst of output indistinguishable from real work. Ignoring output
    /// briefly afterwards keeps a window drag from looking like the agent is busy.
    func noteTerminalResized() {
        suppressOutputUntil = Date().addingTimeInterval(ActivityDefaults.resizeQuietPeriod)
    }

    /// Notes that a mouse report — a wheel tick or a pointer move — was forwarded to the
    /// process.
    ///
    /// A program tracking the mouse answers each report by repainting its content — output we
    /// caused, exactly like a resize. Each event extends the window, so it covers a whole
    /// momentum gesture or pointer sweep and ends soon after the last one.
    ///
    /// **Motion is the loud half, not the wheel.** Claude Code turns on any-event tracking
    /// (`\u{1b}[?1003h`), so merely moving the pointer across the terminal reports every cell
    /// the pointer crosses, and the CLI answers each one by redrawing the row under it —
    /// far over the byte threshold for a sweep of a few cells. Without this the session went
    /// `working` while the user moved the mouse over a finished turn, and a reporting session
    /// took it the other way: a burst inside a flagged turn is read as the user having
    /// answered where they stood, which a hover highlight is not.
    func noteMouseReportForwarded() {
        suppressOutputUntil = Date().addingTimeInterval(ActivityDefaults.pointerQuietPeriod)
    }

    /// Records input a person sent to the terminal, locally or through a remote controller.
    ///
    /// Presentation cannot end an unattended launch: selecting or remotely opening a restored
    /// session provokes resize and TUI paint without starting any work. Actual input can, so the
    /// next output is once again allowed to drive runtimes that do not report their own turns.
    ///
    /// A submitted line is also the direct boundary missing from a reported permission prompt.
    /// Claude reports that it is waiting, but reports no complementary "permission answered"
    /// event; a long, silent tool can therefore be running while the row remains blocked. A
    /// submitted line is the provider-neutral fact that the terminal answer was committed. It
    /// lowers only the inferred waiting flag — an ask-shaped tool call remains held by its
    /// explicit close hook. Editing and bracketed paste still end launch grace, but do not claim
    /// that a question has been answered.
    func noteUserInput(submitsLine: Bool) {
        launchedUnattended = false

        // A committed line is a genuine new interaction even when the previous inferred result
        // is still unread on this Mac. It earns one new output/quiet episode; editing alone does
        // not, because a periodic repaint can follow cursor movement without a submitted turn.
        if submitsLine {
            attentionEpisodeOpen = false
        }

        guard submitsLine, awaitsUser, turnInFlight, openAsks.isEmpty else { return }
        awaitsUser = false
        settle(.userInput)
    }

    private var isSuppressed: Bool {
        guard let suppressOutputUntil else { return false }
        return Date() < suppressOutputUntil
    }

    // MARK: - Reported Activity

    /// The agent reported that a turn began.
    ///
    /// A turn means someone is driving the session — a prompt typed through the remote
    /// mirror reaches an unattended terminal too — so the launch grace ends here.
    func noteTurnStarted(turnID: String? = nil) {
        launchedUnattended = false
        adoptOwnReports()
        reportsTurnStarts = true
        cancelPendingReportedTurnFinish()
        beginDeclaredTurn(turnID: turnID, cause: .turnStarted)
    }

    /// Admits a turn the runtime opened **without declaring it**, read off the session's own
    /// rollout. See `CodexTranscriptTurnBoundary`.
    ///
    /// Codex in goal mode continues a thread by itself: `Stop` fires, and about 250 ms later a
    /// new turn begins from an internal message that submits no user prompt, so no
    /// `UserPromptSubmit` follows and there is no other turn-start hook in the CLI's vocabulary.
    /// Nothing here could see that turn, and the row read `idle` for the seventy minutes one of
    /// them ran while the pane painted "Working" — which is the report this exists for.
    ///
    /// The same fallback contract as the two boundary readers that end turns: it cannot latch an
    /// inferred session, it does not claim the runtime *declares* starts (`reportsTurnStarts`
    /// stays false, so the next such turn is read the same way), and it cannot re-open the turn
    /// it has already watched end. A turn output opened half a second earlier is **adopted**
    /// rather than restarted: it is the same turn, and naming it is what lets the interruption
    /// reader match it by id later.
    @discardableResult
    func noteTurnStartedFromTranscript(turnID: String) -> Bool {
        guard reportsOwnActivity, turnID != lastEndedTurnID else { return false }

        if turnInFlight {
            guard reportedTurnID == nil else { return false }
            reportedTurnID = turnID
            // Declared now, so the quiet timer that was standing in for its ending stands down.
            turnWasDeclared = true
            outputInferredContinuationInFlight = false
            quietTimer?.invalidate()
            quietTimer = nil
            settle(.turnStartedFromTranscript)
            return true
        }

        cancelPendingReportedTurnFinish()
        beginDeclaredTurn(turnID: turnID, cause: .turnStartedFromTranscript)
        return true
    }

    /// The state every declared start moves, whether a hook or the rollout declared it.
    private func beginDeclaredTurn(turnID: String?, cause: SessionActivityCause) {
        attentionEpisodeOpen = false
        turnInFlight = true
        turnWasDeclared = true
        outputInferredContinuationInFlight = false
        quietTimer?.invalidate()
        quietTimer = nil
        bytesSinceQuiet = 0
        turnGeneration += 1
        reportedTurnID = turnID
        awaitsUser = false
        // A new prompt is proof the user is past whatever the last turn was asking, so an ask
        // whose close never arrived ends here rather than outliving the turn it belonged to.
        openAsks.removeAll()
        // Do not lower `limitPark` here. `UserPromptSubmit` proves that the CLI accepted a local
        // prompt, not that the provider accepted the request: `/loop` and a scheduled recovery
        // both raise this hook before an account that is still spent writes another refusal.
        // The transcript that raised the park is the authority that lowers it.
        settle(cause)
    }

    /// The agent reported that its turn ended.
    ///
    /// Finishing while the session is on screen needs no flag; the user watched it happen.
    ///
    /// `backgroundWork` is the agent's own account of what it left running — a backgrounded
    /// shell, a delegated child, an MCP monitor — by identity and kind. Shells and delegated
    /// children remain pending until their results arrive; other standing work is the turn's
    /// own if this turn started it, and parked if an earlier one did. Claiming the session
    /// finished posts a notification for an answer nobody has given yet and drops the mark while
    /// the agent is about to speak again. `BackgroundWorkLedger` draws both lines.
    func noteTurnFinished(
        backgroundWork inFlight: [BackgroundTask] = [],
        continuationGrace: TimeInterval? = nil,
        allowsOutputInferredContinuation: Bool = false
    ) {
        // A resumed CLI can already be mid-turn when Threading relaunches, so its start hook
        // belonged to the previous app process. In that case `Stop` is the first boundary the
        // new tracker sees. It is still proof that the unattended boot repaint is over: leaving
        // the grace armed here discards every byte from a goal turn Codex opens immediately
        // afterwards, and the row stays idle while the terminal says "Working".
        let resumedWithoutObservedStart = launchedUnattended
        launchedUnattended = false
        adoptOwnReports()
        finishReportedTurn(
            backgroundWork: inFlight,
            cause: .turnFinished,
            continuationGrace: continuationGrace,
            reconcileUnobservedContinuation: resumedWithoutObservedStart,
            allowsOutputInferredContinuation: allowsOutputInferredContinuation
        )
    }

    /// Ends the active Codex turn when its rollout records the interrupt that `Stop` omitted.
    ///
    /// This is a fallback for a session already driven by reports, not a second activity source:
    /// it cannot latch an inferred session, cannot end an idle one, and cannot end a differently
    /// identified turn. Once admitted it settles exactly like `Stop`, including the visible vs.
    /// off-screen unread distinction, so the sidebar and control plane cross the same edge.
    @discardableResult
    func noteTurnInterrupted(turnID: String) -> Bool {
        guard reportsOwnActivity, turnInFlight,
              let reportedTurnID, reportedTurnID == turnID else {
            return false
        }

        finishReportedTurn(backgroundWork: [], cause: .turnInterrupted)
        return true
    }

    /// Ends the active Codex turn when its rollout records the completion its `Stop` did not.
    ///
    /// `Stop` fires about three milliseconds *before* Codex appends `task_complete`, so this is
    /// refused as a no-op on every ordinary turn — the hook has already closed it. What it is
    /// for is the turn whose `Stop` never arrived, which is the only way a turn this file
    /// admitted from the rollout could otherwise stay `working` for ever: a declared turn arms
    /// no quiet timer, so a declared start deserves a declared end that does not depend on one
    /// hook surviving.
    ///
    /// Same fallback contract as the interruption beside it, including the id match.
    @discardableResult
    func noteTurnFinishedFromTranscript(
        turnID: String,
        continuationGrace: TimeInterval? = nil
    ) -> Bool {
        guard reportsOwnActivity, turnInFlight,
              let reportedTurnID, reportedTurnID == turnID else {
            return false
        }

        finishReportedTurn(
            backgroundWork: [],
            cause: .turnFinishedFromTranscript,
            continuationGrace: continuationGrace
        )
        return true
    }

    /// Ends the active turn when the session's own transcript records the user interrupting it —
    /// Claude's half of the boundary Codex reports above. See `ClaudeTranscriptInterruption`.
    ///
    /// It takes a turn generation rather than a turn id because Claude names no turn: its
    /// `UserPromptSubmit` payload carries a session and a prompt and nothing to match a later
    /// read against, so the count of turns begun is the identity — the same stand-in
    /// `noteTurnRefused` uses, and for the same reason.
    ///
    /// The fallback contract is otherwise identical: it cannot latch an inferred session, cannot
    /// end an idle one, and cannot end a turn other than the one it was read for. It settles
    /// exactly like `Stop`, because an interrupted turn genuinely ended and the CLI is back at
    /// its prompt.
    @discardableResult
    func noteTurnInterrupted(turn generation: Int) -> Bool {
        guard reportsOwnActivity, turnInFlight, generation == turnGeneration else {
            return false
        }

        finishReportedTurn(backgroundWork: [], cause: .turnInterrupted)
        return true
    }

    /// Ends the active turn when the session's own transcript records a request the provider
    /// refused for something other than the account's allowance — an expired login, a dropped
    /// connection. See `ClaudeTranscriptTurnRefusal`, which is where that record and the
    /// measurement behind it live.
    ///
    /// The same fallback contract as `noteTurnInterrupted`: it cannot latch an inferred session,
    /// cannot end an idle one, and cannot end a turn other than the one it was read for. It
    /// settles exactly like `Stop`, because that is what it is standing in for — the failed turn
    /// genuinely ended, the CLI is back at its prompt, and the session is finished rather than
    /// stopped on anything. A refusal seen off screen therefore takes the unread mark, which is
    /// the only thing that will tell the user their login expired an hour ago.
    ///
    /// Deliberately **not** `limitReached`: nothing here says the account is spent, and a row
    /// claiming so would send the user to a usage dashboard to explain a login.
    @discardableResult
    func noteTurnRefused(turn generation: Int) -> Bool {
        guard reportsOwnActivity, turnInFlight, generation == turnGeneration else {
            return false
        }

        finishReportedTurn(backgroundWork: [], cause: .turnRefused)
        return true
    }

    /// The three ways a reported turn ends share every line of this but the one they are told
    /// apart by in the log: `Stop`, a rollout's interrupt, a refusal read off the transcript.
    private func finishReportedTurn(
        backgroundWork inFlight: [BackgroundTask],
        cause: SessionActivityCause,
        continuationGrace: TimeInterval? = nil,
        reconcileUnobservedContinuation: Bool = false,
        allowsOutputInferredContinuation: Bool = false
    ) {
        cancelPendingReportedTurnFinish()
        outputInferredContinuationInFlight = false
        reportsTurnEnds = true
        turnInFlight = false
        turnWasDeclared = false
        // Remembered past the turn it belonged to, so a rollout read taken before this ending
        // was written cannot re-open the turn it has just watched end. The scan is off-main and
        // the two records are milliseconds apart, which is exactly the width of that race.
        lastEndedTurnID = reportedTurnID ?? lastEndedTurnID
        reportedTurnID = nil
        // The turn cannot have ended around an open question, so an ask still held here is one
        // whose close was lost. Believed over the ask, because `Stop` is the stronger statement:
        // the agent is back at its prompt, and a mark saying otherwise would never come down.
        openAsks.removeAll()
        // The ledger answers whether this boundary pauses at all — it is the half that has to
        // remember earlier turns — and the payload answers which kind, since delegated work is
        // exactly what it says it is. Called once: `turnEnded` moves the ledger on.
        if backgroundWork.turnEnded(leaving: inFlight) {
            pause = inFlight.contains { $0.kind == .delegated } ? .delegated : .standing
        } else {
            pause = .none
        }

        // A Codex `Stop` is not always the user-visible end of work. Goal mode writes the next
        // `task_started` shortly afterwards but has no start hook, so publishing the ordinary
        // unread state here produces a one-frame amber badge before the rollout corrects it.
        // Keep only a genuinely working, unpaused state provisional. An ending-only runtime
        // without a rollout source gets the same bounded window even when no start was observed:
        // that is the exact hole the one-shot output fallback fills. Every other idle state has
        // a stronger reason to settle immediately, and callers opt in only for Codex terminals.
        if let continuationGrace,
           continuationGrace > 0,
           (activity == .working
               || ((reconcileUnobservedContinuation || allowsOutputInferredContinuation)
                   && activity == .idle)),
           !pausedOnOwnWork {
            pendingReportedTurnFinish = PendingReportedTurnFinish(cause: cause)
            outputInferredContinuationAvailable = allowsOutputInferredContinuation
            pendingReportedTurnFinishTimer = Timer.scheduledTimer(
                withTimeInterval: continuationGrace,
                repeats: false
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.commitPendingReportedTurnFinish()
                }
            }
            return
        }

        commitReportedTurnFinish(cause: cause)
    }

    /// Publishes a finish after its continuation window closed without another turn beginning.
    private func commitPendingReportedTurnFinish() {
        guard let pendingReportedTurnFinish else { return }
        self.pendingReportedTurnFinish = nil
        outputInferredContinuationAvailable = false
        pendingReportedTurnFinishTimer?.invalidate()
        pendingReportedTurnFinishTimer = nil
        commitReportedTurnFinish(cause: pendingReportedTurnFinish.cause)
    }

    /// Drops a provisional finish because a newer turn or process boundary superseded it.
    private func cancelPendingReportedTurnFinish() {
        pendingReportedTurnFinishTimer?.invalidate()
        pendingReportedTurnFinishTimer = nil
        pendingReportedTurnFinish = nil
        outputInferredContinuationAvailable = false
    }

    /// The ordinary visible/off-screen finish rule, shared by immediate and deferred endings.
    private func commitReportedTurnFinish(cause: SessionActivityCause) {
        // Not merely unflagged — *nothing* is waiting to be read, so an off-screen session must
        // not take the unread mark either.
        awaitsUser = !isVisible && !pausedOnOwnWork
        settle(cause)
        if !pausedOnOwnWork { raiseAttention() }
    }

    /// The agent reported that it is waiting on the user.
    ///
    /// Unlike finishing, this flags even a visible session: the agent is blocked until someone
    /// answers, and a session the user is looking at but not attending to is exactly the case
    /// worth marking.
    ///
    /// It deliberately leaves the turn alone. Claude raises this for a permission prompt as
    /// readily as for a finished turn, and treating the two the same is what left a working
    /// session showing nothing at all: the question was answered, the agent went on, and the
    /// state had no way back to `working` until the next prompt.
    ///
    /// The notice is `.unspecified` by default, which is the reading that changes nothing: a
    /// runtime that names no type, or names one this build has never heard of, still flags.
    func noteAwaitingUser(_ notice: HookNotificationKind = .unspecified) {
        commitPendingReportedTurnFinish()
        // First, and unconditionally: the report proves the hooks reached this session whether
        // or not the notice it carried is worth anything.
        adoptOwnReports()
        let honoured = honoursAwaitingUserNotice(notice)
        if honoured { awaitsUser = true }
        // Settled either way, so a refused notice still leaves a line. "Why did no mark appear"
        // is a question asked in the past tense as often as its opposite, and `record` already
        // keeps a reported cause that moved nothing for exactly that reason — the alternative
        // is a hook that arrives, changes nothing, and is invisible to whoever asks later.
        settle(.awaitingUserReported)
        if honoured, !turnInFlight { raiseAttention() }
    }

    /// Whether a runtime's own "waiting" notice is evidence that anyone is being waited *for*.
    ///
    /// Two cases where it is not, and both are the same mistake — reading "this prompt is idle"
    /// as "the user is needed":
    ///
    /// - An **unattended launch**. A session relaunched in the background is precisely a prompt
    ///   sitting idle, so honouring the notice flagged every restored session a minute after
    ///   startup. A real ask arrives inside a turn, and the turn's start already ended the grace.
    /// - A session **paused on work it left running**. The agent's turn ended while background
    ///   work remained, so its prompt is idle *because* of that work — and 60s later
    ///   (`messageIdleNotifThresholdMs`) the CLI says so, which used to overwrite the one fact
    ///   that knew better. Measured on CLI 2.1.238 in a session whose child ran for 18 minutes:
    ///   the row went `working -> needsAttention` a minute after each turn, came back to
    ///   `working` the moment it was looked at (`cause=seen`, `paused` set on both edges), and
    ///   dropped again on the next quiet stretch. The pause is not a guess — the `Stop` payload
    ///   named the child — and a notice that names no question cannot outrank it.
    ///
    /// Two narrowings, and both are the same instinct: refuse a notice only where refusing it
    /// cannot lose anything.
    ///
    /// - **Only while a continuation is explicitly reported.** Delegated and standing work have
    ///   different lifetimes, but neither turns an idle prompt into evidence that the user is
    ///   needed. The prompt remains ready and the continuation remains visible as its own fact.
    /// - **`.idlePrompt` only, not every notice.** The two failures are not symmetrical: a
    ///   spurious mark is noise, while a swallowed permission prompt is a session waiting for an
    ///   answer nobody knows it wants. A terminal session has no other signal for one —
    ///   `blockingAskOpened` is scoped to the tools that ask outright, and a `Bash` approval is
    ///   not among them — so suppression is opt-in by exact name, and everything else,
    ///   including a type this build has never heard of, stays loud.
    ///
    /// Asked by `AgentRuntime` too, before it records the notice as a reason to wake a snoozed
    /// session: one rule, so a notice cannot be too weak for the sidebar and loud enough to end
    /// a snooze at the same time. That reading also matches what `SessionSnoozeCenter.record`
    /// already says it is for — a *new* edge, not old state a relaunch happened to re-read.
    func honoursAwaitingUserNotice(_ notice: HookNotificationKind) -> Bool {
        if launchedUnattended { return false }
        if notice == .idlePrompt, pausedOnOwnWork { return false }
        return true
    }

    /// The agent called a tool whose result is the user's answer — see `TurnBlockingTools`.
    ///
    /// The turn is parked from here until that call ends, and unlike `noteAwaitingUser` this
    /// survives both being looked at and the terminal repainting. Those two lower the inferred
    /// flag because answering a CLI's own prompt happens in the terminal and raises no hook, so
    /// output is the only evidence there is that it was answered. Here the evidence exists: the
    /// call is open, and the hook that closes it is already registered.
    func noteBlockingAskOpened(id: String?) {
        cancelPendingReportedTurnFinish()
        adoptOwnReports()
        // Unlike the runtime's own notice, an unattended launch is no reason to ignore this: a
        // boot repaint cannot call a tool, so nothing about a relaunch produces one of these.
        openAsks.insert(askKey(id))
        settle(.blockingAskOpened)
    }

    /// The asking tool returned — answered, dismissed or interrupted.
    ///
    /// `awaitsUser` is cleared with it: a runtime raising its own notice *about this question*
    /// is the ordinary case (Claude does, six seconds after the keyboard goes quiet in front of
    /// it), and leaving that behind would move the session from blocked straight to blocked.
    func noteBlockingAskClosed(id: String?) {
        adoptOwnReports()
        openAsks.remove(askKey(id))
        awaitsUser = false
        settle(.blockingAskClosed)
    }

    /// The provider refused the turn over a rate limit — read from the session's own
    /// transcript, because `Stop` does not fire for a refused turn (measured in
    /// `limit-recovery.md`) and without this the session strands `working` forever.
    ///
    /// Ends the stranded turn on the transcript's authority: the file's `turn_duration` is the
    /// boundary the missing hook never delivered. Deliberately does **not** latch
    /// `reportsOwnActivity` — this is Threading's own reading, not the agent reporting — and
    /// clears the ask set the way `noteTurnFinished` does, since a turn cannot have ended
    /// around an open question.
    ///
    /// `recoveryArmed` says whether something is handling it: armed reads `idle` (nothing owed,
    /// nothing running), unarmed flags the loud mark (a turn stopped dead on the CLI's
    /// chooser). The park clears when the transcript no longer ends on the refusal, or when the
    /// process ends or relaunches. A local turn start is not provider acceptance: a loop can
    /// submit and be refused again while the account is still spent.
    func noteLimitParked(recoveryArmed: Bool) {
        cancelPendingReportedTurnFinish()
        quietTimer?.invalidate()
        quietTimer = nil
        bytesSinceQuiet = 0
        outputInferredContinuationInFlight = false
        turnInFlight = false
        awaitsUser = false
        openAsks.removeAll()
        limitPark = recoveryArmed ? .recovering : .flagged
        reportedTurnID = nil
        settle(.limitParked)
    }

    /// The session's own record no longer ends on a refusal: the conversation has spoken since,
    /// so whatever the limit was, it is not what this session is doing now.
    ///
    /// The only thing that lowers a park besides the process lifecycle, and it is not a guess:
    /// `ObservedUsageLimit` answers nil the moment a newer assistant outcome exists, which is
    /// the same provider-side evidence the park was raised on. Hooks cannot serve here —
    /// `UserPromptSubmit` fires before the provider decides, while nothing fires for either a
    /// refusal or its lifting.
    func noteLimitCleared() {
        guard limitPark != .none else { return }
        limitPark = .none
        settle(.limitCleared)
    }

    /// An ask that named no call still has to pair with its close, and the same stand-in on both
    /// sides does that. Two unidentified asks overlapping would collapse into one — a shape that
    /// does not occur, since a question tool is answered through a modal the runtime shows one
    /// of at a time.
    private func askKey(_ id: String?) -> String {
        guard let id, !id.isEmpty else { return ActivityDefaults.unidentifiedAsk }
        return id
    }

    /// Records the process announcing itself — the `SessionStart` hook.
    ///
    /// Proof that this process's hooks reach Threading, which is the very fact the output
    /// heuristic exists to stand in for — so it latches reporting like any other report, and
    /// from here on turn boundaries come from hooks and the provider's own transcript while
    /// bytes may neither open nor end a turn. Both providers register their turn hooks in the
    /// same file as this one, so its arrival proves theirs can arrive too; the idle-prompt
    /// `Notification` already latched on the same grounds while claiming nothing more.
    ///
    /// Measured on 10 September 2026 on a Codex chat resumed with no prompt: its idle screen
    /// repainted the input box and status line faster than the 0.8-second quiet timer, and
    /// nothing had latched because no turn had been reported since the resume. Off screen the
    /// attention episode refused to reopen a turn from those repaints, so the row sat unread;
    /// the moment the chat was selected the episode re-armed, one burst opened an inferred
    /// turn, and the quiet timer never fired again. The row spun for as long as the chat stayed
    /// selected, over a CLI sitting at its prompt, and every other resumed Codex chat did the
    /// same once looked at.
    ///
    /// A turn output inferred before this arrived is boot paint, not work: a process that has
    /// just announced its start has nothing in flight. It is closed without raising attention,
    /// because nobody's result is waiting to be read. A turn the rollout declared is kept — the
    /// reader that admitted it is stronger evidence than a start announcement is.
    ///
    /// The launch grace is left alone. It ends at the first input or the first turn, and a
    /// start announcement is neither; a relaunched session must still not flag its own boot.
    func noteSessionStarted() {
        hasHeardFromProcess = true
        adoptOwnReports()
        if turnInFlight, !turnWasDeclared {
            turnInFlight = false
            outputInferredContinuationInFlight = false
            reportedTurnID = nil
            awaitsUser = false
        }
        settle(.sessionStarted)
    }

    /// Records that the runtime's own transcript is now a turn-boundary source — a validated
    /// Codex rollout under observation.
    ///
    /// Codex writes `task_started`, `task_complete` and `turn_aborted` for every turn whether or
    /// not any hook reports it, so once that rollout is being read, bytes have nothing to say
    /// that the rollout will not say better. Reporting latches as it does for a hook. That is
    /// also what lets the reader's first read do its job: `noteTurnStartedFromTranscript`
    /// refuses a session that has not latched, and a reattach clears every latch.
    ///
    /// Measured on 10 September 2026: an app restart took 17 sessions back from the PTY host,
    /// which restarts no CLI and so fires no `SessionStart`. The idle Codex chats among them
    /// repainted their prompts, inference opened a turn on the first burst after the replay,
    /// and their rows spun over idle programs while their rollouts ended in `task_complete`.
    ///
    /// A turn output inferred before the rollout was adopted is closed without flagging, for
    /// the reason `noteSessionStarted` closes one: the reader's first read reopens it as a
    /// declared turn if the rollout says it is running, and otherwise it was a repaint. A
    /// continuation the one-shot grant opened is kept, because that grant is the runtime's own
    /// reported finish speaking and the rollout is about to name it.
    func noteTranscriptBoundarySourceAdopted() {
        adoptOwnReports()
        if turnInFlight, !turnWasDeclared, !outputInferredContinuationInFlight {
            turnInFlight = false
            reportedTurnID = nil
            awaitsUser = false
        }
        // A reported finish inside its continuation grace is deliberately provisional: settling
        // here would publish the idle state early and let the finish follow with a badge the
        // grace exists to avoid. The commit or the continuation settles it soon enough.
        guard pendingReportedTurnFinish == nil else { return }
        settle(.transcriptAdopted)
    }

    /// Records that this session reports, the first time it reports anything.
    ///
    /// It stops output from *ending* a turn immediately, because a report is a boundary and a
    /// guess must not overrule one. What output may still *open* is a narrower question the
    /// first report cannot answer on its own: see `outputMayOpenTurn`.
    private func adoptOwnReports() {
        guard !reportsOwnActivity else { return }

        reportsOwnActivity = true
        hasHeardFromProcess = true
        quietTimer?.invalidate()
        quietTimer = nil
        bytesSinceQuiet = 0
    }

    /// Records a terminal bell, which agents ring to ask for attention.
    ///
    /// A bell asks; it does not say the turn is over. A reported turn is ended by its own
    /// `Stop`, so inside one the bell only raises the flag. Where nothing reports, the bell is
    /// the only boundary there is, so it still ends the inferred turn.
    ///
    /// Returns **why** it rang, so the one place that rings can say so. The four causes come
    /// out of the same three facts the flag above is set from, and they are returned as
    /// `SoundEvent` rather than an enum of this file's own: they are the same four cases, and a
    /// parallel type mapped one-to-one is the thing that drifts.
    ///
    /// - Parameters:
    ///   - attributesOtherPrograms: whether anybody has asked to hear another program's bell
    ///     apart from the agent's. False — the default — skips `otherProgramHoldsPTY` entirely,
    ///     because without an entry of its own that cause resolves to the same sound as
    ///     `bellAgentAsking` and the question would buy a distinction nobody could hear.
    ///   - otherProgramHoldsPTY: asked **fresh**, at the bell. The cached foreground reading
    ///     that names a terminal is taken once a second and can be a full second stale, which
    ///     is not an answer about the byte that just arrived.
    @discardableResult
    func recordBell(
        attributesOtherPrograms: Bool = false,
        otherProgramHoldsPTY: () -> Bool = { false }
    ) -> SoundEvent {
        cancelPendingReportedTurnFinish()
        quietTimer?.invalidate()
        quietTimer = nil
        bytesSinceQuiet = 0

        if !reportsOwnActivity {
            turnInFlight = false
        }
        // A bell rung during an unattended boot is part of the boot, not an ask: no prompt
        // has been submitted for the agent to be asking about.
        awaitsUser = !isVisible && !launchedUnattended
        let cause = bellCause(
            attributesOtherPrograms: attributesOtherPrograms,
            otherProgramHoldsPTY: otherProgramHoldsPTY
        )
        settle(.bell)
        if !launchedUnattended { raiseAttention() }
        return cause
    }

    /// The causes overlap — another program can ring in a visible session, or during an
    /// unattended launch — so the classification is ordered rather than exclusive:
    /// `launch → agentVisible → otherProgram → agentAsking`.
    ///
    /// Visibility outranks attribution because the sound's job is telling you what you cannot
    /// see: while you are watching, who rang matters less than that you saw it; while you are
    /// away, attribution is the whole question.
    private func bellCause(
        attributesOtherPrograms: Bool,
        otherProgramHoldsPTY: () -> Bool
    ) -> SoundEvent {
        if launchedUnattended { return .bellLaunch }
        if isVisible { return .bellAgentVisible }
        if attributesOtherPrograms, otherProgramHoldsPTY() { return .bellOtherProgram }
        return .bellAgentAsking
    }

    /// Marks the session as having no terminal.
    func markDormant() {
        cancelPendingReportedTurnFinish()
        quietTimer?.invalidate()
        quietTimer = nil
        bytesSinceQuiet = 0
        isDormant = true
        turnInFlight = false
        turnWasDeclared = false
        outputInferredContinuationInFlight = false
        reportedTurnID = nil
        awaitsUser = false
        openAsks.removeAll()
        pause = .none
        attentionEpisodeOpen = false
        limitPark = .none
        backgroundWork.forget()
        settle(.dormant)
    }

    /// Marks a launch nobody made by hand, so its boot noise raises no flags.
    ///
    /// Called before the launch; `markRunning` deliberately leaves the mark alone, since it
    /// arrives a run-loop pass later. The grace ends at the first input or the first turn, so
    /// it needs no clearing on `markDormant` either — a session that died unseen keeps it,
    /// and both ends still apply to the next process.
    func noteUnattendedLaunch() {
        launchedUnattended = true
    }

    /// Ends the launch grace at a boundary the caller can prove, rather than at the first input.
    ///
    /// A **reattach** needs the grace for exactly as long as the replay: those bytes are a
    /// repaint of a screen that was already there, and reading them as work would mark every
    /// recovered session unread. Everything after the replay is the child working *now*, and it
    /// is the only activity signal a reattached session has — a turn that began before the
    /// relaunch raised its `turnStarted` hook into a socket nobody was listening on, so no
    /// report is coming to say the session is busy and no report will clear the grace either.
    /// Without this the row sat at idle while the TUI painted "Working" beside it.
    ///
    /// Deliberately narrower than `noteUnattendedLaunch`'s other two ends: it clears the launch
    /// mark and nothing else, so the attention rules that mark spans stay exactly as they were
    /// for a launch nobody has proved is over.
    func endUnattendedLaunchGrace() {
        launchedUnattended = false
    }

    /// Marks the session as running again after being dormant.
    ///
    /// A new process has to earn the right to be believed all over again. The settings file
    /// carrying the hooks is written per launch and can fail — if it did, this session has no
    /// reports coming, and staying latched would leave it permanently idle.
    func markRunning() {
        cancelPendingReportedTurnFinish()
        bytesSinceQuiet = 0
        // Resize and pointer suppression belongs to the process that could have answered the
        // event. A freshly launched process did not receive an earlier terminal resize, so
        // carrying that deadline across the launch would discard its first legitimate output.
        suppressOutputUntil = nil
        reportsOwnActivity = false
        reportsTurnStarts = false
        reportsTurnEnds = false
        hasHeardFromProcess = false
        attentionEpisodeOpen = false
        isDormant = false
        turnInFlight = false
        turnWasDeclared = false
        outputInferredContinuationInFlight = false
        reportedTurnID = nil
        // A new process writes a new rollout with new turn ids; the old one's last turn is not
        // an answer about any of them.
        lastEndedTurnID = nil
        awaitsUser = false
        openAsks.removeAll()
        pause = .none
        limitPark = .none
        backgroundWork.forget()
        settle(.running)
    }

    // MARK: - Private Methods

    /// Reports the one state the four facts add up to.
    ///
    /// Stated in one place so every caller moves a fact rather than the answer: the bug this
    /// replaced came from call sites each assigning the state they thought followed.
    /// The turn is what separates blocked from merely unread: a session asking inside an open
    /// turn is holding one up, while the same flag with the turn closed is a finished session
    /// nobody has looked at. That is also why `awaitingUser` after a `Stop` — Claude notifies
    /// once its prompt has been idle a while — lands on `needsAttention` and not on the louder
    /// mark: nothing is waiting on the user there, the turn is simply over.
    ///
    /// Work the agent left running keeps the session out of `idle` without opening a turn.
    /// Those are not the same fact, and reusing the turn for it would have made Claude's
    /// idle-prompt notice — which arrives with no turn to hold up — read as a blocked one.
    ///
    /// An open ask outranks everything but dormancy, and does not consult the turn. A tool call
    /// that has not returned *is* a turn stopped on the user however the turn's own boundaries
    /// were reported, and a session with no terminal has no ask left to hold — `markDormant`
    /// clears them, so the first branch cannot be reached with one open.
    /// A limit park sits between the asks and the inferred flag. Flagged is `limitReached`
    /// however the turn's boundaries read: the account is spent, and no amount of turn
    /// bookkeeping changes what the row has to say. An armed recovery is `idle`, and both
    /// outrank `pausedOnOwnWork` deliberately — work the refused turn left running cannot wake
    /// a limited agent, and `working` would be a lie the sidebar holds for hours.
    private func settle(_ cause: SessionActivityCause) {
        let previous = activity
        lastCause = cause

        if isDormant {
            activity = .dormant
        } else if !openAsks.isEmpty {
            activity = .awaitingUser
        } else if limitPark == .flagged {
            activity = .limitReached
        } else if limitPark == .recovering {
            activity = .idle
        } else if awaitsUser {
            activity = turnInFlight ? .awaitingUser : .needsAttention
        } else {
            activity = turnInFlight ? .working
                : pausedOnOwnWork ? .readyWithBackgroundWork : .idle
        }

        record(cause, from: previous)
        publishRuntimeChangeIfNeeded()
    }

    private func publishRuntimeChangeIfNeeded() {
        let snapshot = runtimeSnapshot
        guard snapshot != lastPublishedRuntimeSnapshot else { return }
        lastPublishedRuntimeSnapshot = snapshot
        onRuntimeChange?(snapshot)
    }

    /// The trail a row's state leaves behind.
    ///
    /// Every fact the branch above reads goes on the line, not only the two that moved. The
    /// question this answers is never "what is the state" — the sidebar already says that — but
    /// "why is it that", and the answer is always some combination of the facts *and* the cause:
    /// a `turnFinished` with `visible=false` is an unread mark for a turn nobody watched, the
    /// same cause with `visible=true` is a session going quietly back to idle, and neither can
    /// be told from the other by its outcome alone.
    ///
    /// Written under `session` at **`info`**, which is the whole point of it: `debug` is not
    /// retained. `HookLifecycleRelay.deliver` has recorded every arriving hook at `debug` since
    /// the feature shipped, and that line is invisible to anyone asking afterwards what happened
    /// — the level has to be turned on first (`log config --mode "level:debug" --subsystem
    /// codes.threading`, or a live `log stream --level debug`), which nobody does before the
    /// thing they wanted to explain. A trail for a question asked in the past tense has to be
    /// kept in the past tense.
    ///
    /// Nothing here is user content: enum tokens, booleans, counts and an opaque session id,
    /// every one of them `.public` — a `String` interpolation defaults to private and the whole
    /// line would come back as `<mask.hash: …>`, which is how this subsystem's existing traces
    /// read in `log show` today.
    private func record(_ cause: SessionActivityCause, from previous: SessionActivity) {
        guard activity != previous else {
            // A reported cause that moved nothing leaves no trace anywhere else: no mark, no
            // notification, no row change. It is also a real answer — "the mark was already up
            // when the second notice arrived" is what a row stuck flagged looks like from here.
            // Inferred causes are excluded because a working session settles on every burst of
            // output, and per-turn hooks would drown in it.
            if cause.isReported {
                ThreadingLogger.session.info(
                    """
                    Activity held at \(self.activity.logName, privacy: .public) \
                    cause=\(cause.rawValue, privacy: .public) \
                    session=\(self.sessionID?.uuidString ?? "unowned", privacy: .public) \
                    visible=\(self.isVisible, privacy: .public)
                    """
                )
            }
            return
        }

        ThreadingLogger.session.info(
            """
            Activity \(previous.logName, privacy: .public) -> \
            \(self.activity.logName, privacy: .public) \
            cause=\(cause.rawValue, privacy: .public) \
            session=\(self.sessionID?.uuidString ?? "unowned", privacy: .public) \
            visible=\(self.isVisible, privacy: .public) \
            turn=\(self.turnInFlight, privacy: .public) \
            declared=\(self.turnWasDeclared, privacy: .public) \
            awaits=\(self.awaitsUser, privacy: .public) \
            asks=\(self.openAsks.count, privacy: .public) \
            park=\(self.limitPark.logName, privacy: .public) \
            paused=\(self.pause.logName, privacy: .public) \
            reports=\(self.reportsOwnActivity, privacy: .public) \
            starts=\(self.reportsTurnStarts, privacy: .public) \
            ends=\(self.reportsTurnEnds, privacy: .public) \
            unattended=\(self.launchedUnattended, privacy: .public)
            """
        )
    }

    /// Output has stopped once this fires, so the session has finished whatever it was doing.
    private func restartQuietTimer() {
        quietTimer?.invalidate()
        quietTimer = Timer.scheduledTimer(
            withTimeInterval: quietInterval,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.finishWorking()
            }
        }
    }

    private func finishWorking() {
        quietTimer = nil
        bytesSinceQuiet = 0

        guard turnInFlight else { return }
        turnInFlight = false
        outputInferredContinuationInFlight = false
        reportedTurnID = nil

        // Finishing while the session is on screen needs no flag; the user saw it happen.
        awaitsUser = !isVisible
        settle(.quiet)
        raiseAttention()
    }

    private func raiseAttention() {
        guard !attentionEpisodeOpen else { return }
        attentionEpisodeOpen = true
        onAttention?()
    }
}

// MARK: - Activity Defaults

enum ActivityDefaults {
    /// Output below this size in a quiet period reads as echoed input rather than work.
    static let workingByteThreshold = 200

    /// How long output must stop before a session counts as finished.
    static let quietInterval: TimeInterval = 0.8

    /// How long a resize's repaint is ignored. Each resize during a drag extends it, so the
    /// window only covers the final repaint once the drag ends.
    static let resizeQuietPeriod: TimeInterval = 0.75

    /// How long a forwarded mouse report's repaint is ignored, extended by each wheel tick or
    /// pointer move.
    static let pointerQuietPeriod: TimeInterval = 0.5

    /// Stands in for the tool call of an ask whose hook named none, so its open and its close
    /// still pair up.
    static let unidentifiedAsk = "unidentified-ask"
}
