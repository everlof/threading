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
            AgentRuntime.shared.controller(for: sessionID)?
                .activityTracker.noteLimitCleared()
            ThreadingLogger.agent.debug(
                "Limit stop cleared for \(sessionID.uuidString, privacy: .public)"
            )
            return
        }
        guard !recovering.contains(sessionID) else { return }
        recovering.insert(sessionID)

        EventLog.shared.record(.limitRecovery, "Usage-limit refusal read from a transcript", [
            "session": sessionID.uuidString,
            "message": stop.message,
            "resetHint": stop.resetHint ?? ""
        ])

        guard let controller = AgentRuntime.shared.controller(for: sessionID),
              controller.isRunning else {
            // Dormant by the time the poll saw it. Nothing to type into and nothing to park;
            // the refusal will still be the newest message if the session is resumed.
            EventLog.shared.record(.limitRecovery, "Refusal seen with no live process", [
                "session": sessionID.uuidString
            ])
            recovering.remove(sessionID)
            return
        }

        switch LimitRecoveryPolicy.current {
        case .flagOnly:
            controller.activityTracker.noteLimitParked(recoveryArmed: false)
            EventLog.shared.record(.limitRecovery, "Session flagged, policy leaves it to the user", [
                "session": sessionID.uuidString
            ])
            recovering.remove(sessionID)

        case .waitForReset:
            armWaitForReset(sessionID, controller: controller)
        }
    }

    // MARK: - Private Methods — Wait For Reset

    /// The plan is computed before anything is typed, the chooser is answered before anything
    /// is scheduled, and every exit that is not "armed" flags the session instead — a policy
    /// whose precondition fails degrades to `flagOnly`, it never improvises.
    private func armWaitForReset(_ sessionID: SessionID, controller: AgentSessionViewController) {
        guard let plan = continuationPlan(for: sessionID) else {
            flag(sessionID, controller: controller, because: "no usage reading to schedule against")
            return
        }

        // A continuation already waiting for this session means a previous arm is still in
        // flight — a re-armed reset, an undelivered send. A second one would type twice.
        let pending = ScheduledMessageStore.shared.messages(for: sessionID)
            .contains { $0.state.isOwed && $0.anchor.usageWindowID != nil }
        guard !pending else {
            controller.activityTracker.noteLimitParked(recoveryArmed: true)
            EventLog.shared.record(.limitRecovery, "Continuation already scheduled, re-armed the park", [
                "session": sessionID.uuidString
            ])
            recovering.remove(sessionID)
            return
        }

        answerChooser(controller, sessionID: sessionID, attempt: 0) { [weak self] result in
            guard let self else { return }

            switch result {
            case .answered(let keystrokes):
                EventLog.shared.record(.limitRecovery, "Limit chooser answered with stop-and-wait", [
                    "session": sessionID.uuidString,
                    "keystrokes": keystrokes
                ])
                self.scheduleContinuation(plan, sessionID: sessionID, controller: controller)

            case .noticeOnly:
                // The refusal's other shape: the sentence printed inline and the CLI already
                // back at its prompt. Nothing to answer is not a failure — the keystrokes are
                // skipped and the continuation is scheduled all the same.
                EventLog.shared.record(.limitRecovery, "No chooser to answer, the CLI printed the notice", [
                    "session": sessionID.uuidString
                ])
                self.scheduleContinuation(plan, sessionID: sessionID, controller: controller)

            case .unreadable(let reason, let screen):
                self.flag(sessionID, controller: controller, because: reason, screen: screen)
            }
        }
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
        controller: AgentSessionViewController
    ) {
        let message = ScheduledMessage(
            dueAt: plan.dueAt,
            target: .session(sessionID),
            text: LimitRecoveryDefaults.continuationText,
            anchor: .usageWindowReset(windowID: plan.windowID)
        )

        switch ScheduledMessageStore.shared.add(message) {
        case .success:
            controller.activityTracker.noteLimitParked(recoveryArmed: true)
            EventLog.shared.record(.limitRecovery, "Continuation scheduled for the window reset", [
                "session": sessionID.uuidString,
                "window": plan.windowName,
                "dueAt": ISO8601DateFormatter().string(from: plan.dueAt)
            ])
            ThreadingLogger.agent.info(
                """
                Limit recovery armed for \(sessionID.uuidString, privacy: .public), \
                continuing at \(plan.dueAt.description, privacy: .public)
                """
            )
            recovering.remove(sessionID)

        case .failure(let refusal):
            flag(sessionID, controller: controller, because: "the schedule was refused: \(refusal)")
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
        _ controller: AgentSessionViewController,
        sessionID: SessionID,
        attempt: Int,
        completion: @escaping @MainActor (ChooserResult) -> Void
    ) {
        let lines = controller.session.visibleScreenLines()

        switch LimitChooserReading.read(screenLines: lines) {
        case .chooser(let chooser) where chooser.markerOnOption:
            controller.session.insertText(TerminalDefaults.submitSequence)
            completion(.answered(keystrokes: "return"))

        case .chooser(let chooser):
            controller.session.insertText(String(chooser.optionDigit))
            DispatchQueue.main.asyncAfter(deadline: .now() + LimitRecoveryDefaults.keystrokeDelay) {
                self.confirmAfterDigit(controller, digit: chooser.optionDigit, completion: completion)
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
                    controller, sessionID: sessionID, attempt: attempt + 1, completion: completion
                )
            }
        }
    }

    private func confirmAfterDigit(
        _ controller: AgentSessionViewController,
        digit: Character,
        completion: @escaping @MainActor (ChooserResult) -> Void
    ) {
        let lines = controller.session.visibleScreenLines()

        switch LimitChooserReading.read(screenLines: lines) {
        case .absent, .notice:
            // The chooser is gone: the digit alone confirmed, which some selectors do. The
            // notice case is the same fact — the sentence the CLI leaves behind can outlive
            // the chooser it stood beside.
            completion(.answered(keystrokes: "digit \(digit)"))

        case .chooser(let chooser) where chooser.markerOnOption:
            controller.session.insertText(TerminalDefaults.submitSequence)
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
    private func flag(
        _ sessionID: SessionID,
        controller: AgentSessionViewController,
        because reason: String,
        screen: String? = nil
    ) {
        controller.activityTracker.noteLimitParked(recoveryArmed: false)

        var detail = ["session": sessionID.uuidString, "reason": reason]
        if let screen { detail["screen"] = screen }
        EventLog.shared.record(.limitRecovery, "Recovery stood down, session flagged", detail)
        ThreadingLogger.agent.error(
            """
            Limit recovery stood down for \(sessionID.uuidString, privacy: .public): \
            \(reason, privacy: .public)
            """
        )
        recovering.remove(sessionID)
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
