import Foundation

// MARK: - Session Activity

/// What a session is currently doing, as shown in the sidebar.
enum SessionActivity {
    /// No terminal allocated; the session can be resumed.
    case dormant

    /// Running but producing no output — an agent waiting at its prompt.
    case idle

    /// Producing output, i.e. the agent is working — or paused on work it left running, which
    /// will speak again with nobody having typed. Both are "not finished", and the sidebar has
    /// no reason to draw them apart: what the user needs to know is that nothing is owed yet.
    case working

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

    /// Whether a turn is unfinished: the agent is mid-answer, or stopped on a question it
    /// cannot get past.
    ///
    /// This is the line an interruption costs something across. A session that is `idle` or
    /// merely unread has already finished its turn and loses only its process, which resumes;
    /// these two lose the answer being written. Copy that counts "running agents" counts both
    /// sides of that line and reads as the worse one.
    ///
    /// A refused turn is *over*: the CLI is back at its prompt and the answer it was writing is
    /// already lost, so there is nothing left for an interruption to cost.
    var hasTurnInFlight: Bool {
        switch self {
        case .working, .awaitingUser:
            return true
        case .dormant, .idle, .needsAttention, .limitReached:
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
/// which output stops driving the state at all: the two disagree constantly and by design —
/// a working agent is quiet while it waits on the model, and noisy after its turn has ended
/// while the CLI redraws its footer. Falling back per-event would flicker between them.
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

    /// Whether the session is currently on screen, which decides if finishing work is
    /// worth flagging.
    var isVisible: Bool = false {
        didSet {
            // Being looked at is what ends an unattended launch: from here on the session is
            // an ordinary one, and its output means what output always means.
            if isVisible { launchedUnattended = false }

            // Looking at a session answers whatever it was asking for. What it goes back to is
            // the turn it is in rather than idle: an agent that asked mid-turn is still working,
            // and nothing else would have said so again until the user's next prompt.
            //
            // `openAsks` and `limitPark` are deliberately untouched. This rule is a guess — the
            // runtime's own "waiting" notice cannot say what it is waiting for, so being looked
            // at is the best evidence available that it was answered — and neither a named tool
            // call nor a refused request is a guess.
            //
            // The park in particular is not a question the user can answer by arriving. Both of
            // the CLI's own chooser options leave the account exactly as spent as it was, so a
            // glance that lowered the mark would show an ordinary idle row for a session that
            // still cannot run. What lowers it is the conversation running again, which the
            // transcript states outright.
            guard isVisible, awaitsUser else { return }
            awaitsUser = false
            settle()
        }
    }

    /// Whether this session has ever reported a turn boundary through a hook.
    ///
    /// Latched rather than per-event: once an agent has proved it reports, its silence is
    /// meaningful. Treating a missing report as "fall back to counting bytes" would hand the
    /// state straight back to the proxy this exists to replace.
    private(set) var reportsOwnActivity = false

    /// Whether this process has been heard from at all — its `SessionStart` hook, or any
    /// later lifecycle report. Deliberately weaker than `reportsOwnActivity`: hearing a
    /// SessionStart proves the CLI is up and the hook path works, without yet claiming turn
    /// boundaries will be declared — which is why it must not switch off the output
    /// heuristic. It exists for delivery: typing into a PTY whose `isRunning` flipped at
    /// spawn lands text in a login shell, and this is the earliest honest "the composer
    /// exists now". Without it, every session idle since an app relaunch read as
    /// still-booting forever, because SessionStart was the one report nothing latched.
    private(set) var hasHeardFromProcess = false

    /// Whether a turn is open: begun, and not yet reported finished.
    private var turnInFlight = false

    /// The provider's identity for the reported turn, where it supplies one.
    ///
    /// Codex's transcript fallback lands after a background file read. Matching that record to
    /// the open turn prevents an old interruption from closing a newer turn that began before
    /// the read returned to main.
    private var reportedTurnID: String?

    /// Whether the session is asking for something and cannot continue until it is answered.
    ///
    /// Held apart from the turn because the two are independent — the flag can be raised and
    /// lowered several times inside one turn.
    ///
    /// This is the *inferred* half of asking: it comes from a runtime's own notice, which cannot
    /// say what it is waiting for, so being looked at and fresh output are both allowed to lower
    /// it. `openAsks` is the half that is known outright and obeys neither.
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

    /// Whether the agent ended its turn on work it had just started, which will wake it again.
    ///
    /// A third fact rather than a longer turn, because the turn genuinely did end: the CLI is
    /// back at its prompt and will answer the user. What has *not* happened is the session
    /// finishing — a backgrounded shell re-enters the conversation on its own, and the agent
    /// speaks again with nobody having typed. Reported by `Stop`, and only ever true for a
    /// session that reports its own turns.
    private var pausedOnOwnWork = false

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
    /// session is first looked at, or when a turn genuinely begins.
    private var launchedUnattended = false

    private var bytesSinceQuiet = 0
    private var quietTimer: Timer?

    /// Output arriving before this instant is a redraw we provoked, not the agent working.
    private var suppressOutputUntil: Date?

    // MARK: - Public Methods

    /// Records a chunk of output.
    func recordOutput(byteCount: Int) {
        // A background relaunch's boot output is a repaint we provoked, exactly like a
        // resize — except its window ends when the session is seen, not on a timer.
        if launchedUnattended { return }

        if isSuppressed {
            // A redraw we caused. It must not start a session working, but it also must not
            // end one that already is — so an in-flight session keeps its timer alive. A
            // reporting session has no such timer, and starting one here would end a turn only
            // its own `Stop` may end.
            if !reportsOwnActivity, turnInFlight {
                restartQuietTimer()
            }
            return
        }

        bytesSinceQuiet += byteCount

        // Below the threshold this is most likely the terminal echoing typed characters.
        guard bytesSinceQuiet >= ActivityDefaults.workingByteThreshold else { return }

        // An agent that reports its own turns has already said what it is doing, and its output
        // may not start or end one. It answers exactly one question the reports leave open: a
        // burst *inside* a flagged turn means the user answered where they stood and the agent
        // carried on, which no hook fires for. Moving only towards working, and only inside a
        // turn the agent itself declared open, is what keeps this from re-opening the flicker
        // the latch exists to close.
        //
        // On screen only, for the same reason. Answering happens in the terminal being looked
        // at, so that is the one place output can mean "answered"; off screen the flag is the
        // only thing saying the session is waiting, and a stray redraw must not spend it.
        guard !reportsOwnActivity else {
            // Measured per burst here, unlike the heuristic below, so a prompt trickling a few
            // bytes at a time never adds up to an answer.
            bytesSinceQuiet = 0

            // A limit park is deliberately not lowered here. A burst in front of the user is
            // the CLI repainting around its chooser as readily as it is the agent carrying on,
            // and only one of those means the session can work again — the transcript says
            // which, so nothing has to be inferred from bytes.
            guard isVisible, turnInFlight, awaitsUser else { return }
            awaitsUser = false
            settle()
            return
        }

        turnInFlight = true
        awaitsUser = false
        settle()
        restartQuietTimer()
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

    private var isSuppressed: Bool {
        guard let suppressOutputUntil else { return false }
        return Date() < suppressOutputUntil
    }

    // MARK: - Reported Activity

    /// The agent reported that a turn began.
    ///
    /// A turn means someone is driving the session — a prompt typed through the remote
    /// mirror reaches an unattended terminal too — so the launch grace ends here as surely
    /// as it does on being looked at.
    func noteTurnStarted(turnID: String? = nil) {
        launchedUnattended = false
        adoptOwnReports()
        turnInFlight = true
        reportedTurnID = turnID
        awaitsUser = false
        // A new prompt is proof the user is past whatever the last turn was asking, so an ask
        // whose close never arrived ends here rather than outliving the turn it belonged to.
        openAsks.removeAll()
        // A turn beginning is the limit lifting, whoever typed it — the scheduled continuation
        // landing is exactly this edge.
        limitPark = .none
        settle()
    }

    /// The agent reported that its turn ended.
    ///
    /// Finishing while the session is on screen needs no flag; the user watched it happen.
    ///
    /// `backgroundWork` is the agent's own account of what it left running — a backgrounded
    /// shell, a delegated child, an MCP monitor — by identity and kind. A delegated child is
    /// work the turn handed off and has not heard back from; standing work is the turn's own if
    /// this turn started it, and parked if an earlier one did. Either way, claiming the session
    /// finished posts a notification for an answer nobody has given yet and drops the mark while
    /// the agent is about to speak again. `BackgroundWorkLedger` draws both lines.
    func noteTurnFinished(backgroundWork inFlight: [BackgroundTask] = []) {
        adoptOwnReports()
        finishReportedTurn(backgroundWork: inFlight)
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

        finishReportedTurn(backgroundWork: [])
        return true
    }

    private func finishReportedTurn(backgroundWork inFlight: [BackgroundTask]) {
        turnInFlight = false
        reportedTurnID = nil
        // The turn cannot have ended around an open question, so an ask still held here is one
        // whose close was lost. Believed over the ask, because `Stop` is the stronger statement:
        // the agent is back at its prompt, and a mark saying otherwise would never come down.
        openAsks.removeAll()
        pausedOnOwnWork = backgroundWork.turnEnded(leaving: inFlight)
        // Not merely unflagged — *nothing* is waiting to be read, so an off-screen session must
        // not take the unread mark either.
        awaitsUser = !isVisible && !pausedOnOwnWork
        settle()
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
    func noteAwaitingUser() {
        adoptOwnReports()
        // Claude raises `Notification` once its prompt has sat idle a while, and a session
        // relaunched in the background is precisely a prompt sitting idle: honouring it would
        // flag every restored session a minute after startup. A *real* ask arrives inside a
        // turn, and the turn's start already ended the grace.
        guard !launchedUnattended else { return }
        awaitsUser = true
        settle()
    }

    /// The agent called a tool whose result is the user's answer — see `TurnBlockingTools`.
    ///
    /// The turn is parked from here until that call ends, and unlike `noteAwaitingUser` this
    /// survives both being looked at and the terminal repainting. Those two lower the inferred
    /// flag because answering a CLI's own prompt happens in the terminal and raises no hook, so
    /// output is the only evidence there is that it was answered. Here the evidence exists: the
    /// call is open, and the hook that closes it is already registered.
    func noteBlockingAskOpened(id: String?) {
        adoptOwnReports()
        // Unlike the runtime's own notice, an unattended launch is no reason to ignore this: a
        // boot repaint cannot call a tool, so nothing about a relaunch produces one of these.
        openAsks.insert(askKey(id))
        settle()
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
        settle()
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
    /// chooser). The park clears on the next turn start, on the process ending or relaunching,
    /// or — unarmed only — on the user looking at it, the same guess `awaitsUser` makes.
    func noteLimitParked(recoveryArmed: Bool) {
        quietTimer?.invalidate()
        quietTimer = nil
        bytesSinceQuiet = 0
        turnInFlight = false
        awaitsUser = false
        openAsks.removeAll()
        limitPark = recoveryArmed ? .recovering : .flagged
        reportedTurnID = nil
        settle()
    }

    /// The session's own record no longer ends on a refusal: the conversation has spoken since,
    /// so whatever the limit was, it is not what this session is doing now.
    ///
    /// The only thing that lowers a park besides a turn starting and the process lifecycle, and
    /// it is not a guess: `ObservedUsageLimit` answers nil the moment a newer message record
    /// exists, which is the same evidence the park was raised on. Hooks cannot serve here —
    /// nothing fires for a refusal, and nothing fires for its lifting either.
    func noteLimitCleared() {
        guard limitPark != .none else { return }
        limitPark = .none
        settle()
    }

    /// An ask that named no call still has to pair with its close, and the same stand-in on both
    /// sides does that. Two unidentified asks overlapping would collapse into one — a shape that
    /// does not occur, since a question tool is answered through a modal the runtime shows one
    /// of at a time.
    private func askKey(_ id: String?) -> String {
        guard let id, !id.isEmpty else { return ActivityDefaults.unidentifiedAsk }
        return id
    }

    /// Records the process announcing itself — the `SessionStart` hook. Proof the CLI is up;
    /// not yet a turn boundary, so the output heuristic stays on.
    func noteSessionStarted() {
        hasHeardFromProcess = true
    }

    /// Switches this session off the output heuristic, the first time it reports anything.
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
    func recordBell() {
        quietTimer?.invalidate()
        quietTimer = nil
        bytesSinceQuiet = 0

        if !reportsOwnActivity {
            turnInFlight = false
        }
        // A bell rung during an unattended boot is part of the boot, not an ask: no prompt
        // has been submitted for the agent to be asking about.
        awaitsUser = !isVisible && !launchedUnattended
        settle()
    }

    /// Marks the session as having no terminal.
    func markDormant() {
        quietTimer?.invalidate()
        quietTimer = nil
        bytesSinceQuiet = 0
        isDormant = true
        turnInFlight = false
        reportedTurnID = nil
        awaitsUser = false
        openAsks.removeAll()
        pausedOnOwnWork = false
        limitPark = .none
        backgroundWork.forget()
        settle()
    }

    /// Marks a launch nobody made by hand, so its boot noise raises no flags.
    ///
    /// Called before the launch; `markRunning` deliberately leaves the mark alone, since it
    /// arrives a run-loop pass later. The grace ends at the first look or the first turn, so
    /// it needs no clearing on `markDormant` either — a session that died unseen keeps it,
    /// and both ends still apply to the next process.
    func noteUnattendedLaunch() {
        launchedUnattended = true
    }

    /// Marks the session as running again after being dormant.
    ///
    /// A new process has to earn the right to be believed all over again. The settings file
    /// carrying the hooks is written per launch and can fail — if it did, this session has no
    /// reports coming, and staying latched would leave it permanently idle.
    func markRunning() {
        bytesSinceQuiet = 0
        reportsOwnActivity = false
        hasHeardFromProcess = false
        isDormant = false
        turnInFlight = false
        reportedTurnID = nil
        awaitsUser = false
        openAsks.removeAll()
        pausedOnOwnWork = false
        limitPark = .none
        backgroundWork.forget()
        settle()
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
    private func settle() {
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
            activity = turnInFlight || pausedOnOwnWork ? .working : .idle
        }
    }

    /// Output has stopped once this fires, so the session has finished whatever it was doing.
    private func restartQuietTimer() {
        quietTimer?.invalidate()
        quietTimer = Timer.scheduledTimer(
            withTimeInterval: ActivityDefaults.quietInterval,
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
        reportedTurnID = nil

        // Finishing while the session is on screen needs no flag; the user saw it happen.
        awaitsUser = !isVisible
        settle()
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
