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

    /// Whether a turn is unfinished: the agent is mid-answer, or stopped on a question it
    /// cannot get past.
    ///
    /// This is the line an interruption costs something across. A session that is `idle` or
    /// merely unread has already finished its turn and loses only its process, which resumes;
    /// these two lose the answer being written. Copy that counts "running agents" counts both
    /// sides of that line and reads as the worse one.
    var hasTurnInFlight: Bool {
        switch self {
        case .working, .awaitingUser:
            return true
        case .dormant, .idle, .needsAttention:
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
            // Looking at a session answers whatever it was asking for. What it goes back to is
            // the turn it is in rather than idle: an agent that asked mid-turn is still working,
            // and nothing else would have said so again until the user's next prompt.
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

    /// Whether a turn is open: begun, and not yet reported finished.
    private var turnInFlight = false

    /// Whether the session is asking for something and cannot continue until it is answered.
    ///
    /// Held apart from the turn because the two are independent — the flag can be raised and
    /// lowered several times inside one turn.
    private var awaitsUser = false

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

    /// Whether the session owns no process at all, which outranks both of the above.
    private var isDormant = false

    private var bytesSinceQuiet = 0
    private var quietTimer: Timer?

    /// Output arriving before this instant is a redraw we provoked, not the agent working.
    private var suppressOutputUntil: Date?

    // MARK: - Public Methods

    /// Records a chunk of output.
    func recordOutput(byteCount: Int) {
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

    /// Notes that a scroll was forwarded to the process as mouse input.
    ///
    /// A program tracking the mouse answers each wheel report by repainting its content —
    /// output we caused, exactly like a resize. Each event extends the window, so it covers
    /// a whole momentum gesture and ends soon after the last one.
    func noteScrollForwarded() {
        suppressOutputUntil = Date().addingTimeInterval(ActivityDefaults.scrollQuietPeriod)
    }

    private var isSuppressed: Bool {
        guard let suppressOutputUntil else { return false }
        return Date() < suppressOutputUntil
    }

    // MARK: - Reported Activity

    /// The agent reported that a turn began.
    func noteTurnStarted() {
        adoptOwnReports()
        turnInFlight = true
        awaitsUser = false
        settle()
    }

    /// The agent reported that its turn ended.
    ///
    /// Finishing while the session is on screen needs no flag; the user watched it happen.
    ///
    /// `backgroundWork` is the agent's own account of what it left running — a backgrounded
    /// shell, a detached child, an MCP monitor — by identity. Work this turn started is work
    /// the turn is waiting on, so it has not finished anything: claiming otherwise posts a
    /// notification for an answer that has not been given yet, and drops the session's mark
    /// while the agent is about to speak again. Work carried over from an earlier turn is
    /// parked, and this turn really did end. `BackgroundWorkLedger` draws that line.
    func noteTurnFinished(backgroundWork inFlight: [String] = []) {
        adoptOwnReports()
        turnInFlight = false
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
        awaitsUser = true
        settle()
    }

    /// Switches this session off the output heuristic, the first time it reports anything.
    private func adoptOwnReports() {
        guard !reportsOwnActivity else { return }

        reportsOwnActivity = true
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
        awaitsUser = !isVisible
        settle()
    }

    /// Marks the session as having no terminal.
    func markDormant() {
        quietTimer?.invalidate()
        quietTimer = nil
        bytesSinceQuiet = 0
        isDormant = true
        turnInFlight = false
        awaitsUser = false
        pausedOnOwnWork = false
        backgroundWork.forget()
        settle()
    }

    /// Marks the session as running again after being dormant.
    ///
    /// A new process has to earn the right to be believed all over again. The settings file
    /// carrying the hooks is written per launch and can fail — if it did, this session has no
    /// reports coming, and staying latched would leave it permanently idle.
    func markRunning() {
        bytesSinceQuiet = 0
        reportsOwnActivity = false
        isDormant = false
        turnInFlight = false
        awaitsUser = false
        pausedOnOwnWork = false
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
    private func settle() {
        if isDormant {
            activity = .dormant
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

    /// How long a forwarded scroll's repaint is ignored, extended by each wheel event.
    static let scrollQuietPeriod: TimeInterval = 0.5
}
