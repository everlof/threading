import Foundation

// MARK: - Launch Restoration Plan

/// How much of the workspace a launch may bring back without being asked.
///
/// Two of the three restoration paths run *because the app started*, which is the wrong reason
/// when the last start ended by dying: the previously selected session reopens and every
/// detached browser window is ordered back on screen — potentially reopening the exact thing
/// that took the app down, and doing it silently. So an unclean previous exit holds those two
/// back and offers them instead.
///
/// The third path — relaunching the sessions that were running at the last quit — is
/// deliberately **not** part of this decision. It is already crash-safe by construction: the
/// record is consumed on read by the launch that then crashed, so after a crash there is
/// nothing left to relaunch. See [`sessions.md`](../../../../docs/architecture/sessions.md).
enum LaunchRestorationPlan: Equatable {

    /// Everything the settings ask for, in the order they have always run in.
    case restoresEverything

    /// The previous launch did not come back. The selected session and the detached browser
    /// windows wait for the user to ask for them; `crashReport` is the `.ips` the notice can
    /// point at, when macOS filed one.
    case holdsBackWorkspace(crashReport: URL?)

    init(previousLaunch outcome: EventLog.PreviousLaunchOutcome) {
        switch outcome {
        case .clean, .unknown:
            // *Unknown* restores. It means "this app has never run here", which is a first
            // launch with nothing to restore rather than a crash worth mentioning.
            self = .restoresEverything
        case .intentional(.reset):
            // A restart the user asked for. It leaves without the quit path — the reset flows
            // have to — so the marker survives it and it used to be indistinguishable from a
            // crash: Reset Settings held the workspace back and put a crash notice up over a
            // window the user had just pressed a button to get back. Nothing about a deliberate
            // restart says the workspace is dangerous to reopen.
            self = .restoresEverything
        case .intentional(.recoveryRelaunch):
            // Also deliberate, and the opposite answer. The two facts the case above balances
            // point the same way for a reset and opposite ways here: the restart was asked for,
            // and the reason it was asked for is that the app has been dying. So the launch comes
            // up normally with the workspace one press away rather than reopening, under the
            // user, whatever took it down. No `.ips` travels with it — the report, if there was
            // one, belonged to a launch two ago and the recovery surface already offered it.
            self = .holdsBackWorkspace(crashReport: nil)
        case .unclean(let crashReport):
            self = .holdsBackWorkspace(crashReport: crashReport)
        }
    }

    var restoresSelectedSession: Bool { self == .restoresEverything }

    var restoresDetachedBrowserWindows: Bool { self == .restoresEverything }
}

// MARK: - Unclean Exit Escalation

/// How much the unclean-exit notice has to say.
///
/// A narrow view of `CrashLoopDecision` rather than the decision itself, deliberately: the
/// presenter's job is to pick a sentence, and handing it the whole decision would hand it cases
/// it must not act on — Recovery Mode is Phase 2's to offer, and a band that started offering it
/// early would be offering something that does not exist yet.
enum UncleanExitEscalation: Equatable {

    /// One unexpected exit, or none worth mentioning. The notice says what it always has.
    case none

    /// More than one, close enough together to be the same problem.
    case repeatedUnexpectedExits

    init(decision: CrashLoopDecision) {
        switch decision {
        case .launchNormally, .noteFirstUnexpectedExit:
            self = .none
        case .recommendRecoveryMode, .recommendStoppingAutomaticWork:
            self = .repeatedUnexpectedExits
        }
    }
}

// MARK: - Launch Restoration

/// Runs a launch's restoration, and keeps whatever it held back within reach.
///
/// A separate object from the delegate's gate rather than a second one beside it: the gate
/// (`AppDelegate.restoreSelectedSessionIfReady`) still decides *when* — the MCP listener is up
/// and the walkthrough is not deferring the main window — and this decides *how much*. The
/// actions are closures so the decision can be tested without a window, an MCP server, or a
/// store.
///
/// The offer is one-shot. A launch that has already put the notice up is settled: a later run —
/// the walkthrough re-run from Settings ▸ Advanced finishes and asks again — restores in full
/// rather than holding the same workspace back a second time with nothing on screen to say so.
@MainActor
final class LaunchRestoration {

    // MARK: - Types

    /// The three restore paths, plus the way the held-back two are offered back.
    struct Actions {
        var restoreSelectedSession: () -> Void
        var relaunchSessionsFromLastQuit: () -> Void
        var restoreDetachedBrowserWindows: () -> Void

        /// Puts the notice on screen. The closure it is handed performs exactly what was held
        /// back; the presenter decides where the notice lives and when it goes away.
        var presentNotice: (
            _ crashReport: URL?,
            _ escalation: UncleanExitEscalation,
            _ restore: @escaping () -> Void
        ) -> Void
    }

    // MARK: - Properties

    private let actions: Actions

    /// Whether this launch has already offered its held-back workspace. See the type's note.
    private(set) var hasOfferedNotice = false

    // MARK: - Initialization

    init(actions: Actions) {
        self.actions = actions
    }

    // MARK: - Public Methods

    /// Performs the launch's restoration under `outcome`, and offers back whatever it withheld.
    ///
    /// Returns the plan it used, so the caller can record how far the launch got without
    /// re-deriving a decision this object has already made.
    @discardableResult
    func run(
        previousLaunch outcome: EventLog.PreviousLaunchOutcome,
        escalation: UncleanExitEscalation = .none
    ) -> LaunchRestorationPlan {
        let plan: LaunchRestorationPlan = hasOfferedNotice
            ? .restoresEverything
            : LaunchRestorationPlan(previousLaunch: outcome)

        if plan.restoresSelectedSession {
            actions.restoreSelectedSession()
        }
        // Always, and untouched: the record is consumed even when the setting is off, so
        // enabling it later cannot act on a list from some earlier quit.
        actions.relaunchSessionsFromLastQuit()
        if plan.restoresDetachedBrowserWindows {
            actions.restoreDetachedBrowserWindows()
        }

        guard case .holdsBackWorkspace(let crashReport) = plan else { return plan }
        hasOfferedNotice = true
        actions.presentNotice(crashReport, escalation) { [weak self] in
            self?.restoreHeldBackWorkspace()
        }
        return plan
    }

    /// Performs exactly the two calls `run` skipped, in the order it would have made them —
    /// the selected session first, so the detached windows it would bring back with it are not
    /// built twice (`restoreDetachedBrowserWindows` skips ids it already holds).
    func restoreHeldBackWorkspace() {
        actions.restoreSelectedSession()
        actions.restoreDetachedBrowserWindows()
    }
}
