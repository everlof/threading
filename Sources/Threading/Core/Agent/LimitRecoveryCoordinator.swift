import Foundation

// MARK: - Limit Recovery Coordinator

/// Watches live terminal sessions for a usage-limit refusal and carries out the user's chosen
/// `LimitRecoveryPolicy` — the recovery half of `limit-recovery.md`, built on the detection
/// half (`ObservedUsageLimit` and its reader).
///
/// The poll is a `stat` per live session unless a transcript grew (`TranscriptFactReader`'s
/// gate), at `UsageLimitDefaults.pollInterval` — the interval that reader's own defaults
/// document for exactly this consumer. The reader calls back only when the answer *moves*, so
/// one refusal is handled once: the standing stop stays constant until the conversation speaks
/// again, and the next refusal is a new value.
///
/// Everything it does is journaled to `EventLog.Category.limitRecovery`, because a recovery is
/// invisible by construction — it acts precisely when nobody is watching — and "it did
/// nothing", "it read a screen that was not the chooser" and "the schedule was refused" are
/// unrelated failures that look identical without a record.
@MainActor
final class LimitRecoveryCoordinator {

    // MARK: - Properties

    static let shared = LimitRecoveryCoordinator()

    private var timer: Timer?

    /// Sessions whose refusal is mid-recovery, so a poll landing during the chooser dance
    /// cannot start a second one.
    private var recovering: Set<SessionID> = []

    /// The refusal currently standing over each flagged session, held only until the policy has
    /// decided what to do with it — the durable half is `LimitEscapeSuggestionStore`, which both
    /// this and the rendered-conversation surface feed.
    private var parked: [SessionID: UsageLimitStop] = [:]

    // MARK: - Initialization

    private init() {}

    // MARK: - Public Methods

    /// Starts the poll. Refuses under a hosted test bundle for `UsageWindowPoker`'s reason:
    /// a background process that types into the developer's own sessions is not a failure
    /// anyone should be able to reach by running the suite.
    func start() {
        guard NSClassFromString("XCTestCase") == nil, timer == nil else { return }

        timer = Timer.scheduledTimer(
            withTimeInterval: UsageLimitDefaults.pollInterval,
            repeats: true
        ) { _ in
            Task { @MainActor in
                LimitRecoveryCoordinator.shared.poll()
            }
        }
        ThreadingLogger.agent.debug("Limit recovery watching live sessions")
    }

    // MARK: - Private Methods — Detection

    private func poll() {
        for sessionID in AgentRuntime.shared.liveSessionIDs {
            guard let session = ProjectStore.shared.session(withID: sessionID),
                  let project = ProjectStore.shared.executionProject(forSessionID: sessionID)
            else { continue }

            // A runtime that records no refusal produces no source and no callback, so the
            // capability table decides here, not a branch.
            ObservedUsageLimit.revalidate(for: session, in: project) { [weak self] stop in
                self?.limitReadingMoved(sessionID, stop: stop)
            }
        }
    }

    private func limitReadingMoved(_ sessionID: SessionID, stop: UsageLimitStop?) {
        guard let stop else {
            // The conversation spoke again — the continuation landed, or the user did. Told to
            // the tracker rather than left to the turn-start hook: a session whose hooks never
            // arrived has no other way back, and the mark is the one thing on the row that
            // would otherwise outlive what it describes.
            recovering.remove(sessionID)
            parked.removeValue(forKey: sessionID)
            LimitEscapeSuggestionStore.shared.refusalCleared(for: sessionID)
            AgentRuntime.shared.limitRecoverySurface(for: sessionID)?
                .noteLimitCleared()
            ThreadingLogger.agent.debug(
                "Limit stop cleared for \(sessionID.uuidString, privacy: .public)"
            )
            return
        }
        guard !recovering.contains(sessionID) else { return }
        recovering.insert(sessionID)
        parked[sessionID] = stop

        EventLog.shared.record(.limitRecovery, "Usage-limit refusal read from a transcript", [
            "session": sessionID.uuidString,
            "message": stop.message,
            "resetHint": stop.resetHint ?? ""
        ])

        guard let terminal = AgentRuntime.shared.runningLimitRecoverySurface(for: sessionID) else {
            // Dormant by the time the poll saw it. Nothing to type into and nothing to park;
            // the refusal will still be the newest message if the session is resumed.
            EventLog.shared.record(.limitRecovery, "Refusal seen with no live process", [
                "session": sessionID.uuidString
            ])
            parked.removeValue(forKey: sessionID)
            recovering.remove(sessionID)
            return
        }

        // The chat's answer, then its checkout's, then Settings'. Resolved per session rather
        // than read globally because arming this is the narrow statement — see
        // `LimitRecoveryResolution`.
        let answer = LimitRecoveryResolution.answer(forSessionID: sessionID)

        switch answer.policy {
        case .flagOnly:
            terminal.noteLimitParked(recoveryArmed: false)
            EventLog.shared.record(.limitRecovery, "Session flagged, policy leaves it to the user", [
                "session": sessionID.uuidString,
                "scope": String(describing: answer.scope)
            ])
            offerEscape(for: sessionID)
            recovering.remove(sessionID)

        case .waitForReset:
            EventLog.shared.record(.limitRecovery, "Recovery armed by policy", [
                "session": sessionID.uuidString,
                "scope": String(describing: answer.scope)
            ])
            armWaitForReset(sessionID, terminal: terminal, trigger: .policy)
        }
    }

    // MARK: - Public Methods — Arming By Hand

    /// Arms stop-and-wait for a refusal that is **already** standing, because somebody pressed
    /// for it on the strip.
    ///
    /// The same routine the policy runs, and deliberately not a second implementation of it: the
    /// chooser is answered by label, the plan is made before anything is typed, and the
    /// continuation rides `ScheduledMessage`. Three things differ, each because a press is
    /// watched where a policy is not — see `armWaitForReset(_:terminal:trigger:)`.
    ///
    /// Reachable for a rendered conversation too, which the *policy* never is: that surface has
    /// no chooser to answer, so the keystrokes are skipped and only the schedule is made.
    func armWaitForReset(for sessionID: SessionID) {
        guard LimitEscapeSuggestionStore.shared.hasStandingRefusal(for: sessionID) else {
            EventLog.shared.record(.limitRecovery, "Wait-for-reset pressed with no refusal standing", [
                "session": sessionID.uuidString
            ])
            return
        }
        // A recovery already in flight owns this refusal; a second arm would type twice.
        guard !recovering.contains(sessionID) else { return }
        recovering.insert(sessionID)

        LimitEscapeSuggestionStore.shared.setBusy(.waitForReset, for: sessionID)
        EventLog.shared.record(.limitRecovery, "Wait-for-reset pressed", [
            "session": sessionID.uuidString
        ])

        // A rendered conversation is asked of the model rather than probed for: it has no
        // terminal to read a chooser off, and the surface says so without anything being drawn.
        let usesNativeUI = ProjectStore.shared.session(withID: sessionID)?.usesNativeUI ?? false
        let terminal = usesNativeUI
            ? nil
            : AgentRuntime.shared.runningLimitRecoverySurface(for: sessionID)

        armWaitForReset(sessionID, terminal: terminal, trigger: .press)
    }

    // MARK: - Private Methods — Wait For Reset

    /// Who asked for the recovery, which decides only how a *refusal to act* is reported.
    ///
    /// A policy acts when nobody is watching, so it degrades to `flagOnly` and says why in the
    /// journal — that is the whole of `limit-recovery.md`'s "wrong in one direction only" rule.
    /// A press is watched, and somebody is owed an answer on the strip they pressed.
    private enum RecoveryTrigger {
        case policy
        case press
    }

    /// The plan is computed before anything is typed, the chooser is answered before anything
    /// is scheduled, and every exit that is not "armed" flags the session instead — a policy
    /// whose precondition fails degrades to `flagOnly`, it never improvises.
    ///
    /// A nil terminal is the chooser-less case: a rendered conversation, or a terminal whose
    /// process is already gone. Nothing to type into is not a failure — the schedule is the part
    /// that matters, and delivery has its own rules about finding a prompt.
    private func armWaitForReset(
        _ sessionID: SessionID,
        terminal: (any AgentTerminalLimitRecoverySurface)?,
        trigger: RecoveryTrigger
    ) {
        guard let plan = continuationPlan(for: sessionID) else {
            standDown(
                sessionID,
                terminal: terminal,
                trigger: trigger,
                because: "no usage reading to schedule against",
                sentence: LimitRecoveryStrings.noReadingProblem
            )
            return
        }

        // A continuation already waiting for this session means a previous arm is still in
        // flight — a re-armed reset, an undelivered send. A second one would type twice.
        guard !Self.hasOwedContinuation(for: sessionID) else {
            terminal?.noteLimitParked(recoveryArmed: true)
            EventLog.shared.record(.limitRecovery, "Continuation already scheduled, re-armed the park", [
                "session": sessionID.uuidString
            ])
            // The press is answered by the offer going away: the send it asked for is already
            // filed, and the scheduled-message strip is the surface that names it.
            if trigger == .press { LimitEscapeSuggestionStore.shared.clear(sessionID) }
            recovering.remove(sessionID)
            return
        }

        guard let terminal else {
            EventLog.shared.record(.limitRecovery, "No terminal to answer, scheduling the continuation", [
                "session": sessionID.uuidString
            ])
            scheduleContinuation(plan, sessionID: sessionID, terminal: nil, trigger: trigger)
            return
        }

        answerChooser(terminal, sessionID: sessionID, attempt: 0) { [weak self] result in
            guard let self else { return }

            switch result {
            case .answered(let keystrokes):
                EventLog.shared.record(.limitRecovery, "Limit chooser answered with stop-and-wait", [
                    "session": sessionID.uuidString,
                    "keystrokes": keystrokes
                ])
                self.scheduleContinuation(
                    plan, sessionID: sessionID, terminal: terminal, trigger: trigger
                )

            case .noticeOnly:
                // The refusal's other shape: the sentence printed inline and the CLI already
                // back at its prompt. Nothing to answer is not a failure — the keystrokes are
                // skipped and the continuation is scheduled all the same.
                EventLog.shared.record(.limitRecovery, "No chooser to answer, the CLI printed the notice", [
                    "session": sessionID.uuidString
                ])
                self.scheduleContinuation(
                    plan, sessionID: sessionID, terminal: terminal, trigger: trigger
                )

            case .unreadable(let reason, let screen):
                self.standDown(
                    sessionID,
                    terminal: terminal,
                    trigger: trigger,
                    because: reason,
                    sentence: LimitRecoveryStrings.unreadableScreenProblem,
                    screen: screen
                )
            }
        }
    }

    /// Whether a window-anchored continuation is already owed for this session.
    ///
    /// One predicate, two readers: the arm refuses to file a second send, and the strip stops
    /// offering what is already filed. They were separate once and that is exactly how a button
    /// comes to offer something the code behind it declines to do.
    static func hasOwedContinuation(for sessionID: SessionID) -> Bool {
        ScheduledMessageStore.shared.messages(for: sessionID)
            .contains { $0.state.isOwed && $0.anchor?.usageWindowID != nil }
    }

    /// Which window stops this session and when it lifts — the same window the toolbar pill
    /// gauges, read from the cache the same way.
    private struct ContinuationPlan {
        let windowID: String
        let windowName: String
        let dueAt: Date
    }

    private func continuationPlan(for sessionID: SessionID) -> ContinuationPlan? {
        guard let session = ProjectStore.shared.session(withID: sessionID),
              let account = AgentAccountDiscovery.account(for: session.kind, handle: session.accountHandle)
        else { return nil }

        let model = session.model ?? AgentModels.defaultModel(for: session.kind, account: account)
        // The reading may be stale — the refusal is fresher than any poll — so ask for a
        // refresh regardless of the answer; a plan made now is checked again at delivery by
        // the scheduled send's own stand-aside rule.
        AccountUsageService.shared.refresh(account)

        guard let usage = AccountUsageService.shared.usage(for: account),
              let window = usage.bindingWindow(metering: model),
              let resetsAt = window.resetsAt, resetsAt > Date()
        else { return nil }

        return ContinuationPlan(
            windowID: window.id,
            windowName: window.compactName,
            dueAt: resetsAt.addingTimeInterval(PresetDefaults.resetPadding)
        )
    }

    private func scheduleContinuation(
        _ plan: ContinuationPlan,
        sessionID: SessionID,
        terminal: (any AgentTerminalLimitRecoverySurface)?,
        trigger: RecoveryTrigger
    ) {
        let message = ScheduledMessage(
            dueAt: plan.dueAt,
            target: .session(sessionID),
            text: LimitRecoveryDefaults.continuationText,
            anchor: .usageWindowReset(windowID: plan.windowID)
        )

        switch ScheduledMessageStore.shared.add(message) {
        case .success:
            terminal?.noteLimitParked(recoveryArmed: true)
            EventLog.shared.record(.limitRecovery, "Continuation scheduled for the window reset", [
                "session": sessionID.uuidString,
                "window": plan.windowName,
                "dueAt": ISO8601DateFormatter().string(from: plan.dueAt)
            ])
            ThreadingLogger.agent.info(
                """
                Limit recovery armed for \(sessionID.uuidString, privacy: .public), \
                continuing in \(max(0, Int(plan.dueAt.timeIntervalSinceNow)), privacy: .public) seconds
                """
            )
            // The offer has been taken, so it stops standing there: from here the pending send
            // is the fact, and the composer's scheduled-message strip is what names it. Two
            // strips saying the same thing is the duplication this subsystem avoids by design.
            LimitEscapeSuggestionStore.shared.clear(sessionID)
            recovering.remove(sessionID)

        case .failure(let refusal):
            standDown(
                sessionID,
                terminal: terminal,
                trigger: trigger,
                because: "the schedule was refused: \(refusal)",
                sentence: ScheduledRefusalText.sentence(for: refusal)
            )
        }
    }

    // MARK: - Private Methods — The Chooser

    private enum ChooserResult {
        case answered(keystrokes: String)

        /// The chooser-less form: the refusal printed inline, the CLI at its prompt, nothing
        /// to type now. Delivery still types later, at the reset, exactly as it would have.
        case noticeOnly

        case unreadable(reason: String, screen: String)
    }

    /// Return is only ever sent at a marker verified on the stop-and-wait row. When the digit
    /// has to move the marker first, the screen is read *again* before Return — so a CLI that
    /// ignored the digit can never have Return land on "Upgrade your plan".
    private func answerChooser(
        _ terminal: any AgentTerminalLimitRecoverySurface,
        sessionID: SessionID,
        attempt: Int,
        completion: @escaping @MainActor (ChooserResult) -> Void
    ) {
        let lines = terminal.visibleTerminalScreenLines()

        switch LimitChooserReading.read(screenLines: lines) {
        case .chooser(let chooser) where chooser.markerOnOption:
            terminal.insertTerminalText(TerminalDefaults.submitSequence)
            completion(.answered(keystrokes: "return"))

        case .chooser(let chooser):
            terminal.insertTerminalText(String(chooser.optionDigit))
            DispatchQueue.main.asyncAfter(deadline: .now() + LimitRecoveryDefaults.keystrokeDelay) {
                self.confirmAfterDigit(terminal, digit: chooser.optionDigit, completion: completion)
            }

        case .notice:
            completion(.noticeOnly)

        case .absent(let reason):
            // The record lands an instant before the chooser is drawn, so a few quiet retries
            // are the difference between reading the chooser and reading the paint before it.
            guard attempt < LimitRecoveryDefaults.chooserReadAttempts else {
                completion(.unreadable(reason: reason, screen: Self.screenSample(lines)))
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + LimitRecoveryDefaults.chooserReadDelay) {
                self.answerChooser(
                    terminal, sessionID: sessionID, attempt: attempt + 1, completion: completion
                )
            }
        }
    }

    private func confirmAfterDigit(
        _ terminal: any AgentTerminalLimitRecoverySurface,
        digit: Character,
        completion: @escaping @MainActor (ChooserResult) -> Void
    ) {
        let lines = terminal.visibleTerminalScreenLines()

        switch LimitChooserReading.read(screenLines: lines) {
        case .absent, .notice:
            // The chooser is gone: the digit alone confirmed, which some selectors do. The
            // notice case is the same fact — the sentence the CLI leaves behind can outlive
            // the chooser it stood beside.
            completion(.answered(keystrokes: "digit \(digit)"))

        case .chooser(let chooser) where chooser.markerOnOption:
            terminal.insertTerminalText(TerminalDefaults.submitSequence)
            completion(.answered(keystrokes: "digit \(digit), return"))

        case .chooser:
            completion(.unreadable(
                reason: "the digit did not move the marker to the stop-and-wait row",
                screen: Self.screenSample(lines)
            ))
        }
    }

    // MARK: - Private Methods — Failure

    /// Every path that cannot recover leaves the session exactly where `flagOnly` would: marked
    /// as stopped on the user, with the reason — and the screen, where one was read — in the
    /// journal, because a refusal to act and a failure to act must be tellable apart weeks
    /// later.
    ///
    /// The `sentence` is the same fact in the user's words, and it is used only when somebody
    /// pressed for this. An unattended policy has nobody to tell and says its piece in the
    /// journal; a press is owed an answer on the strip it came from, and silence there reads as
    /// a button that does nothing.
    private func standDown(
        _ sessionID: SessionID,
        terminal: (any AgentTerminalLimitRecoverySurface)?,
        trigger: RecoveryTrigger,
        because reason: String,
        sentence: String,
        screen: String? = nil
    ) {
        terminal?.noteLimitParked(recoveryArmed: false)

        var detail = ["session": sessionID.uuidString, "reason": reason]
        if let screen { detail["screen"] = screen }
        detail["trigger"] = String(describing: trigger)
        EventLog.shared.record(.limitRecovery, "Recovery stood down, session flagged", detail)
        ThreadingLogger.agent.error(
            """
            Limit recovery stood down for \(sessionID.uuidString, privacy: .public): \
            \(reason, privacy: .private(mask: .hash))
            """
        )

        switch trigger {
        case .policy:
            // A session left flagged is exactly the session the interactive offer is for,
            // whichever policy put it there. This is the second of the two places
            // `recoveryArmed: false` lands, and both make the same offer.
            offerEscape(for: sessionID)

        case .press:
            // Never `offerEscape` here: recomputing the suggestion would file a *new* refusal
            // over the standing one, which clears the dismissal and wipes the very sentence
            // being written. The offer is already on screen; it is told why instead.
            LimitEscapeSuggestionStore.shared.note(problem: sentence, for: sessionID)
        }
        recovering.remove(sessionID)
    }

    // MARK: - Private Methods — The Interactive Escape

    /// Publishes the one-tap offer for a session left flagged.
    ///
    /// Called from both places `noteLimitParked(recoveryArmed: false)` lands, and from nowhere
    /// else: an armed recovery already has a plan and does not need a second one offered over it.
    ///
    /// The offer needs no settings opt-in, which is the whole difference between it and the
    /// unbuilt `resumeVia` policy: `limit-recovery.md` refuses automatic recovery because it
    /// "types into the user's session with nobody watching", and here the press is the watching.
    private func offerEscape(for sessionID: SessionID) {
        guard let stop = parked[sessionID] else { return }
        LimitEscapeSuggestionStore.shared.refusalStands(stop, for: sessionID)
    }

    /// The screen's tail, for the journal — enough rows to see what stood where the chooser
    /// was expected, bounded so a full-screen TUI does not write a kilobyte per refusal.
    private static func screenSample(_ lines: [String]) -> String {
        lines.suffix(LimitRecoveryDefaults.screenSampleRows)
            .filter { !$0.isEmpty }
            .joined(separator: LimitRecoveryDefaults.screenSampleSeparator)
            .prefix(LimitRecoveryDefaults.screenSampleLimit)
            .description
    }
}

// MARK: - Limit Recovery Defaults

enum LimitRecoveryDefaults {
    /// What the continuation says — the word the user types by hand today.
    static let continuationText = "continue"

    /// How many times the screen is re-read waiting for the chooser to be drawn, and the pause
    /// between reads. Together they cover the gap between the transcript record landing and
    /// the TUI painting over it, with room for a slow frame.
    static let chooserReadAttempts = 6
    static let chooserReadDelay: TimeInterval = 0.5

    /// The pause between the digit and the verifying re-read. The same beat the app's other
    /// typed submissions keep between text and Return, for the same paste-heuristic reason.
    static let keystrokeDelay: TimeInterval = 0.35

    /// How much screen a journal entry keeps when the chooser could not be read.
    static let screenSampleRows = 14
    static let screenSampleLimit = 600
    static let screenSampleSeparator = " ⏎ "
}

// MARK: - Strings

/// What a stood-down recovery says to somebody who asked for it by hand.
///
/// Separate from the journal's reasons on purpose: those name the defect for whoever reads the
/// log weeks later, while these name the situation for the person looking at the strip now. The
/// two should not be the same string — "no usage reading to schedule against" is a diagnosis,
/// not an explanation.
enum LimitRecoveryStrings {

    /// No reading means no reset instant, and a continuation with no due date is not a plan.
    static var noReadingProblem: String {
        L10n.string("There is no usage reading yet to schedule against.")
    }

    /// The chooser was expected and something else was on screen. Deliberately vague about what:
    /// the screen is in the journal, and a sentence quoting a half-drawn TUI helps nobody.
    static var unreadableScreenProblem: String {
        L10n.string("The session is not showing the limit prompt.")
    }
}
