import Foundation

// MARK: - Limit Recovery Coordinator

/// Watches live terminal sessions for a usage-limit refusal and carries out the user's chosen
/// `LimitRecoveryPolicy` — the recovery half of `limit-recovery.md`, built on the detection
/// half (`ObservedUsageLimit` and its reader).
///
/// The poll is a `stat` per live session unless a transcript grew (`TranscriptFactReader`'s
/// gate), at `UsageLimitDefaults.pollInterval` — the interval that reader's own defaults
/// document for exactly this consumer. The reader calls back only when the answer *moves*, so
/// one refusal is handled once: the standing stop stays constant until the provider produces a
/// newer outcome, and the next refusal is a new value even when its sentence is unchanged.
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

    /// The recovery attempt that owns each session's refusal.
    ///
    /// Identity matters because usage refreshes and chooser reads are asynchronous. Clearing a
    /// refusal and then seeing a newer one must make every callback from the older attempt a
    /// no-op rather than letting stale state schedule or type into the new turn.
    private var recovering: [SessionID: UUID] = [:]

    /// The refusal currently standing over each flagged session, held only until the policy has
    /// decided what to do with it — the durable half is `LimitEscapeSuggestionStore`, which both
    /// this and the rendered-conversation surface feed.
    private var parked: [SessionID: UsageLimitStop] = [:]

    /// How much login-hopping each session has done unattended. The floor under the two policies
    /// that move a conversation, and the guard the interactive escape deliberately does without —
    /// see `LimitRecoveryBudget`.
    private var budget = LimitRecoveryBudget()

    // MARK: - Initialization

    private init() {}

    private func beginRecovery(for sessionID: SessionID) -> UUID? {
        guard recovering[sessionID] == nil else { return nil }
        let attemptID = UUID()
        recovering[sessionID] = attemptID
        return attemptID
    }

    private func ownsRecovery(_ attemptID: UUID, for sessionID: SessionID) -> Bool {
        recovering[sessionID] == attemptID
    }

    private func finishRecovery(_ attemptID: UUID, for sessionID: SessionID) {
        guard ownsRecovery(attemptID, for: sessionID) else { return }
        recovering.removeValue(forKey: sessionID)
    }

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
            // The provider produced a newer outcome — the continuation landed, or the user's
            // retry was accepted. Tell that to the tracker rather than leaving it to the
            // turn-start hook: a session whose hooks never arrived has no other way back, and
            // the mark is the one thing on the row that
            // would otherwise outlive what it describes.
            recovering.removeValue(forKey: sessionID)
            parked.removeValue(forKey: sessionID)
            let obsolete = ScheduledMessageStore.shared.messages(for: sessionID)
                .filter { $0.isOwedLimitRecoveryContinuation }
            if !obsolete.isEmpty {
                let cancelled = ScheduledMessageStore.shared
                    .cancelLimitRecoveryContinuations(for: sessionID)
                EventLog.shared.record(.limitRecovery, cancelled
                    ? "Cleared refusal cancelled its obsolete continuation"
                    : "Cleared refusal could not cancel its obsolete continuation", [
                    "session": sessionID.uuidString,
                    "count": String(obsolete.count)
                ])
            }
            LimitEscapeSuggestionStore.shared.refusalCleared(for: sessionID)
            AgentRuntime.shared.limitRecoverySurface(for: sessionID)?
                .noteLimitCleared()
            ThreadingLogger.agent.debug(
                "Limit stop cleared for \(sessionID.uuidString, privacy: .public)"
            )
            return
        }
        if recovering[sessionID] != nil {
            guard parked[sessionID] != stop else { return }
            // A new refusal supersedes the asynchronous recovery of the old one. Its callbacks
            // carry the old attempt id and will refuse themselves below.
            recovering.removeValue(forKey: sessionID)
            EventLog.shared.record(.limitRecovery, "New refusal superseded an in-flight recovery", [
                "session": sessionID.uuidString,
                "record": stop.recordID ?? ""
            ])
        }
        guard let attemptID = beginRecovery(for: sessionID) else { return }
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
            finishRecovery(attemptID, for: sessionID)
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
            finishRecovery(attemptID, for: sessionID)

        case .waitForReset:
            EventLog.shared.record(.limitRecovery, "Recovery armed by policy", [
                "session": sessionID.uuidString,
                "scope": String(describing: answer.scope)
            ])
            armWaitForReset(
                sessionID,
                terminal: terminal,
                trigger: .policy,
                attemptID: attemptID
            )

        case .resumeOnBestAccount, .resumeVia:
            EventLog.shared.record(.limitRecovery, "Account recovery armed by policy", [
                "session": sessionID.uuidString,
                "scope": String(describing: answer.scope),
                "policy": answer.policy.rawValue
            ])
            armAccountResume(
                sessionID,
                terminal: terminal,
                policy: answer.policy,
                attemptID: attemptID
            )
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
        guard let attemptID = beginRecovery(for: sessionID) else { return }

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

        armWaitForReset(
            sessionID,
            terminal: terminal,
            trigger: .press,
            attemptID: attemptID
        )
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

        /// A policy that moves the conversation to another login. Unattended like `policy`, and
        /// yet it reports its failures the way a press does: `armAccountResume` publishes the
        /// standing refusal *before* it tries anything, so the offer is already on screen and
        /// recomputing it would clear the dismissal and wipe the sentence being written. Named
        /// separately all the same, because "nobody pressed this" is what the journal needs to
        /// say when somebody asks weeks later why their conversation moved.
        case policyAccountResume
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
        trigger: RecoveryTrigger,
        attemptID: UUID
    ) {
        guard ownsRecovery(attemptID, for: sessionID) else { return }
        // The transcript has already ended the refused turn. Keep the row truthful while the
        // fresh usage read and chooser verification are in flight; a failure below converts
        // this quiet recovering park into the visible flagged one.
        terminal?.noteLimitParked(recoveryArmed: true)
        let refusalRecordID = parked[sessionID]?.recordID

        // Seeing the same standing refusal again after a relaunch must not answer its chooser or
        // file a second send. Identity makes this precise: a newer refusal with the same words is
        // not covered by the old continuation and proceeds to a fresh plan below.
        let existing = ScheduledMessageStore.shared.messages(for: sessionID)
        if Self.recoveryContinuationAlreadyArmed(
            in: existing,
            forRefusalRecordID: refusalRecordID
        ) {
            terminal?.noteLimitParked(recoveryArmed: true)
            EventLog.shared.record(.limitRecovery, "Continuation for this refusal already scheduled", [
                "session": sessionID.uuidString,
                "record": refusalRecordID ?? ""
            ])
            if trigger == .press { LimitEscapeSuggestionStore.shared.clear(sessionID) }
            finishRecovery(attemptID, for: sessionID)
            return
        }

        // The refusal is newer than any usage poll. Do not read the cache on the line after
        // starting an asynchronous refresh: wait for the freshest reading pacing permits, then
        // choose the window from that settled snapshot.
        continuationPlan(for: sessionID) { [weak self] plan in
            guard let self, self.ownsRecovery(attemptID, for: sessionID) else { return }
            guard let plan else {
                self.standDown(
                    sessionID,
                    terminal: terminal,
                    trigger: trigger,
                    attemptID: attemptID,
                    because: "no current usage reading to schedule against",
                    sentence: LimitRecoveryStrings.noReadingProblem
                )
                return
            }

            self.continueArmingWaitForReset(
                sessionID,
                terminal: terminal,
                trigger: trigger,
                attemptID: attemptID,
                refusalRecordID: refusalRecordID,
                plan: plan
            )
        }
    }

    private func continueArmingWaitForReset(
        _ sessionID: SessionID,
        terminal: (any AgentTerminalLimitRecoverySurface)?,
        trigger: RecoveryTrigger,
        attemptID: UUID,
        refusalRecordID: String?,
        plan: ContinuationPlan
    ) {
        guard ownsRecovery(attemptID, for: sessionID) else { return }

        guard let terminal else {
            EventLog.shared.record(.limitRecovery, "No terminal to answer, scheduling the continuation", [
                "session": sessionID.uuidString
            ])
            scheduleContinuation(
                plan,
                sessionID: sessionID,
                terminal: nil,
                trigger: trigger,
                attemptID: attemptID,
                refusalRecordID: refusalRecordID
            )
            return
        }

        answerChooser(terminal, sessionID: sessionID, attempt: 0) { [weak self] result in
            guard let self, self.ownsRecovery(attemptID, for: sessionID) else { return }

            switch result {
            case .answered(let keystrokes):
                EventLog.shared.record(.limitRecovery, "Limit chooser answered with stop-and-wait", [
                    "session": sessionID.uuidString,
                    "keystrokes": keystrokes
                ])
                self.scheduleContinuation(
                    plan,
                    sessionID: sessionID,
                    terminal: terminal,
                    trigger: trigger,
                    attemptID: attemptID,
                    refusalRecordID: refusalRecordID
                )

            case .noticeOnly:
                // The refusal's other shape: the sentence printed inline and the CLI already
                // back at its prompt. Nothing to answer is not a failure — the keystrokes are
                // skipped and the continuation is scheduled all the same.
                EventLog.shared.record(.limitRecovery, "No chooser to answer, the CLI printed the notice", [
                    "session": sessionID.uuidString
                ])
                self.scheduleContinuation(
                    plan,
                    sessionID: sessionID,
                    terminal: terminal,
                    trigger: trigger,
                    attemptID: attemptID,
                    refusalRecordID: refusalRecordID
                )

            case .unreadable(let reason, let screen):
                self.standDown(
                    sessionID,
                    terminal: terminal,
                    trigger: trigger,
                    attemptID: attemptID,
                    because: reason,
                    sentence: LimitRecoveryStrings.unreadableScreenProblem,
                    screen: screen
                )
            }
        }
    }

    /// Whether a limit-recovery continuation is already owed for this session.
    ///
    /// One predicate, two readers: the arm refuses to file a second send, and the strip stops
    /// offering what is already filed. They were separate once and that is exactly how a button
    /// comes to offer something the code behind it declines to do.
    static func hasOwedContinuation(for sessionID: SessionID) -> Bool {
        ScheduledMessageStore.shared.messages(for: sessionID)
            .contains { $0.isOwedLimitRecoveryContinuation }
    }

    /// Whether one refusal already owns a durable continuation.
    ///
    /// Kept pure so the identity contract is testable without touching the developer's shared
    /// scheduled-message store. A runtime without record identities may have only one standing
    /// refusal, so its existing recovery is the conservative match.
    static func recoveryContinuationAlreadyArmed(
        in messages: [ScheduledMessage],
        forRefusalRecordID recordID: String?
    ) -> Bool {
        messages.contains { message in
            guard message.isOwedLimitRecoveryContinuation else { return false }
            guard let recordID else { return message.limitRecoveryRecordID == nil }
            return message.limitRecoveryRecordID == recordID
        }
    }

    /// Which window stops this session and when it lifts — the same window the toolbar pill
    /// gauges, read from the cache the same way.
    private struct ContinuationPlan {
        let windowID: String
        let windowName: String
        let dueAt: Date
    }

    private func continuationPlan(
        for sessionID: SessionID,
        completion: @escaping @MainActor (ContinuationPlan?) -> Void
    ) {
        guard let session = ProjectStore.shared.session(withID: sessionID),
              let account = AgentAccountDiscovery.account(for: session.kind, handle: session.accountHandle)
        else { return completion(nil) }

        let model = session.model ?? AgentModels.defaultModel(for: session.kind, account: account)
        AccountUsageService.shared.refresh(account, force: true) {
            let now = Date()
            guard let usage = Self.settledUsageForRecovery(
                from: AccountUsageService.shared.reading(for: account)
            ),
                  let window = usage.bindingWindow(at: now, metering: model),
                  let resetsAt = window.resetsAt, resetsAt > now
            else { return completion(nil) }

            EventLog.shared.record(.limitRecovery, "Fresh usage reading selected the recovery window", [
                "session": sessionID.uuidString,
                "window": window.compactName,
                "observedAt": ISO8601DateFormatter().string(from: usage.observedAt),
                "fraction": window.fraction.map { String($0) } ?? ""
            ])
            completion(ContinuationPlan(
                windowID: window.id,
                windowName: window.compactName,
                dueAt: resetsAt.addingTimeInterval(PresetDefaults.resetPadding)
            ))
        }
    }

    /// A failed refresh deliberately leaves the last good value available for display, but that
    /// stale value is not safe to schedule from. Recovery either receives the current reading or
    /// stands down; it never converts a fetch failure into a confidently wrong reset window.
    static func settledUsageForRecovery(from reading: AccountUsageReading) -> AccountUsage? {
        guard case .current(let usage) = reading else { return nil }
        return usage
    }

    private func scheduleContinuation(
        _ plan: ContinuationPlan,
        sessionID: SessionID,
        terminal: (any AgentTerminalLimitRecoverySurface)?,
        trigger: RecoveryTrigger,
        attemptID: UUID,
        refusalRecordID: String?
    ) {
        guard ownsRecovery(attemptID, for: sessionID) else { return }

        let owed = ScheduledMessageStore.shared.messages(for: sessionID)
            .filter { $0.isOwedLimitRecoveryContinuation }
        guard owed.count <= 1 else {
            standDown(
                sessionID,
                terminal: terminal,
                trigger: trigger,
                attemptID: attemptID,
                because: "multiple automatic continuations were owed for one session",
                sentence: LimitRecoveryStrings.conflictingSchedulesProblem
            )
            return
        }

        let previous = owed.first
        let message = ScheduledMessage(
            id: previous?.id ?? ScheduledMessageID(),
            createdAt: previous?.createdAt ?? Date(),
            dueAt: plan.dueAt,
            target: .session(sessionID),
            text: LimitRecoveryDefaults.continuationText,
            anchor: .usageWindowReset(windowID: plan.windowID),
            purpose: .limitRecovery,
            limitRecoveryRecordID: refusalRecordID
        )

        let result: Result<ScheduledMessage, ScheduledMessageStore.Refusal>
        if let previous {
            result = ScheduledMessageStore.shared.replace(previous.id, with: message)
                ? .success(message)
                : .failure(.writesBlocked)
        } else {
            result = ScheduledMessageStore.shared.add(message)
        }

        switch result {
        case .success:
            terminal?.noteLimitParked(recoveryArmed: true)
            EventLog.shared.record(.limitRecovery, previous == nil
                ? "Continuation scheduled for the window reset"
                : "Obsolete recovery continuation replaced", [
                "session": sessionID.uuidString,
                "window": plan.windowName,
                "dueAt": ISO8601DateFormatter().string(from: plan.dueAt),
                "previousWindow": previous?.anchor?.usageWindowID ?? "",
                "previousRecord": previous?.limitRecoveryRecordID ?? "",
                "record": refusalRecordID ?? ""
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
            finishRecovery(attemptID, for: sessionID)

        case .failure(let refusal):
            standDown(
                sessionID,
                terminal: terminal,
                trigger: trigger,
                attemptID: attemptID,
                because: "the schedule was refused: \(refusal)",
                sentence: ScheduledRefusalText.sentence(for: refusal)
            )
        }
    }

    // MARK: - Private Methods — Moving To Another Login

    /// Carries out `resumeOnBestAccount` or `resumeVia(_:)`: choose a login with room, then hand
    /// the move to the one routine that performs it.
    ///
    /// **The chooser is never answered here, and that is not an oversight.** The refused turn is
    /// already over when the CLI draws it (`limit-recovery.md`'s second measured fact), and this
    /// policy stops the process anyway — `SessionMigration.move` tears the PTY down before it
    /// copies the transcript, so typing into that screen first would be keystrokes into a terminal
    /// about to be discarded.
    ///
    /// **The offer is published before anything is attempted**, rather than only where a recovery
    /// fails. Two things follow: a failure has a strip to write its reason on, and the session is
    /// left exactly where `flagOnly` would leave it — flagged, with the interactive escape standing
    /// over it, so the answer to "the policy could not do it" is a button the user can press.
    private func armAccountResume(
        _ sessionID: SessionID,
        terminal: any AgentTerminalLimitRecoverySurface,
        policy: LimitRecoveryPolicy,
        attemptID: UUID
    ) {
        guard ownsRecovery(attemptID, for: sessionID) else { return }
        offerEscape(for: sessionID)

        guard budget.admitMigration(for: sessionID) else {
            standDown(
                sessionID,
                terminal: terminal,
                trigger: .policyAccountResume,
                attemptID: attemptID,
                because: "the unattended migration budget for this session is spent",
                sentence: LimitRecoveryStrings.budgetSpentProblem
            )
            return
        }

        // Parked as *recovering* for the seconds the readings take to land, not as flagged: the
        // triangle explains a session nothing is doing anything about, and a row that flashed it
        // while a migration was being decided would be answering its own question wrong. A stand
        // down below lowers it, which is the state the triangle is for.
        terminal.noteLimitParked(recoveryArmed: true)

        resolveResumeTarget(for: sessionID, policy: policy) { [weak self] result in
            guard let self, self.ownsRecovery(attemptID, for: sessionID) else { return }

            switch result {
            case .success(let account):
                EventLog.shared.record(.limitRecovery, "Automatic migration chosen, requesting the move", [
                    "session": sessionID.uuidString,
                    "account": account.id.description,
                    "policy": policy.rawValue
                ])
                // Announced rather than called, for `LimitEscapeRequested`'s reason: migrating a
                // conversation and putting its pane back is `SessionCoordinator`'s work, and Core
                // holds no controller to ask. The same routine the press runs answers it.
                NotificationCenter.default.post(LimitAccountResumeRequested(
                    sessionID: sessionID,
                    accountID: account.id
                ))
                self.parked.removeValue(forKey: sessionID)
                self.finishRecovery(attemptID, for: sessionID)

            case .failure(let refusal):
                self.standDown(
                    sessionID,
                    terminal: terminal,
                    trigger: .policyAccountResume,
                    attemptID: attemptID,
                    because: refusal.reason,
                    sentence: refusal.sentence
                )
            }
        }
    }

    /// Why a policy could not name a login to carry on under.
    ///
    /// Two words for each: the journal's, which names the defect for whoever reads it weeks later,
    /// and the strip's, which names the situation for whoever finds the session. The same split
    /// `LimitRecoveryStrings` already keeps, for the same reason — "no candidate survived
    /// eligibility" is a diagnosis, not an explanation.
    private enum ResumeTargetRefusal: Error {
        case sessionGone
        case noOtherLogin
        case pinnedLoginGone(AccountID)
        case pinnedLoginHasNoRoom(name: String, reading: String?)

        /// Nothing qualified. The hold is carried when one of the user's *own* limits is what
        /// refused a candidate, because a login fenced off by its owner must never be reported as
        /// spent — that reads as the provider's doing and points the user at the wrong thing. It
        /// is the reason `LimitEscapeRanking.exclusions` exists.
        case noLoginWithRoom(heldByOwnLimit: CustomLimitHold?)

        var reason: String {
            switch self {
            case .sessionGone:
                return "the session was gone by the time the readings landed"
            case .noOtherLogin:
                return "the runtime routes no other login to move to"
            case .pinnedLoginGone(let accountID):
                return "the pinned login \(accountID.rawValue) is not among this session's destinations"
            case .pinnedLoginHasNoRoom(_, let reading):
                return "the pinned login has no room on a fresh reading: \(reading ?? "no windows")"
            case .noLoginWithRoom(let hold) where hold != nil:
                return "no login has a fresh reading with room, and one is held by the user's own limit"
            case .noLoginWithRoom:
                return "no login has a fresh reading with room"
            }
        }

        var sentence: String {
            switch self {
            case .sessionGone, .noOtherLogin:
                return LimitRecoveryStrings.noOtherLoginProblem
            case .pinnedLoginGone:
                return LimitRecoveryStrings.pinnedLoginGoneProblem
            case .pinnedLoginHasNoRoom(let name, _):
                // The wording the pressed escape already uses when its target turns out to be
                // spent. One sentence for one fact, whoever discovered it.
                return L10n.format("%@ is close to its own limit now.", name)
            case .noLoginWithRoom(let hold):
                // The user's own line gets its own words, in full: "excluded by your limit" is a
                // different fact from "spent", and the one thing that must not happen is a fence
                // the user drew being reported as the provider refusing.
                return hold.map(CustomLimitReceipt.holdReason) ?? LimitRecoveryStrings.noLoginWithRoomProblem
            }
        }
    }

    /// Picks the login this policy names, on readings fetched *now*.
    ///
    /// **Forced, and bounded by the number of logins.** `warmCandidateReadings` asks politely at
    /// detection and may not have landed, and a cached figure deciding where somebody's
    /// conversation goes is the one thing `limit-recovery.md` names as a guard on this feature.
    /// Every pacing rule in `AccountUsageService` still applies, receipt included, so a refusal
    /// cannot become a way to spend a usage endpoint's rate limit faster.
    ///
    /// Choosing is all this does. The press path re-checks the chosen login against the reading
    /// it has by then, which is the guard staying where it already lives rather than being
    /// written twice.
    private func resolveResumeTarget(
        for sessionID: SessionID,
        policy: LimitRecoveryPolicy,
        completion: @escaping @MainActor (Result<AgentAccount, ResumeTargetRefusal>) -> Void
    ) {
        guard let session = ProjectStore.shared.session(withID: sessionID) else {
            return completion(.failure(.sessionGone))
        }

        let model = LimitEscapeSuggestion.effectiveModel(for: session)
        // Capability-gated already, which is why nothing here names a provider: a runtime that
        // routes no accounts offers no destinations and the policy simply cannot apply.
        let destinations = SessionMigration.destinations(for: session)
        guard !destinations.isEmpty else { return completion(.failure(.noOtherLogin)) }

        let candidates: [AgentAccount]
        if let pinned = policy.pinnedAccountID {
            guard let match = destinations.first(where: { $0.id == pinned }) else {
                return completion(.failure(.pinnedLoginGone(pinned)))
            }
            candidates = [match]
        } else {
            candidates = destinations
        }

        var remaining = candidates.count
        for account in candidates {
            AccountUsageService.shared.refresh(account, force: true) {
                remaining -= 1
                guard remaining == 0 else { return }

                let values = candidates.map {
                    LimitEscapeRanking.Candidate(
                        accountID: $0.id,
                        usage: AccountUsageService.shared.usage(for: $0),
                        limits: CustomLimitSettings.shared.rules(for: $0.id)
                    )
                }

                // A login the user fenced off is refused by the ranking like any other, and named
                // here so the refusal can say *whose* line stopped it.
                let heldByOwnLimit = LimitEscapeRanking.exclusions(values).first?.hold

                if policy.pinnedAccountID != nil {
                    guard let candidate = values.first, let account = candidates.first else {
                        return completion(.failure(.noLoginWithRoom(heldByOwnLimit: heldByOwnLimit)))
                    }
                    // Degraded, and deliberately **not** escalated to whichever login now ranks
                    // best: a pinned answer names one login, and choosing a different one on the
                    // user's behalf is the escalation `limit-recovery.md` refuses. The strip
                    // offers the ranked login instead, for a press.
                    guard LimitEscapeRanking.hasHeadroom(candidate, metering: model) else {
                        // A pin the user's own limit is holding says so in that limit's words,
                        // rather than reporting their own fence back to them as a spent account.
                        guard heldByOwnLimit == nil else {
                            return completion(.failure(.noLoginWithRoom(
                                heldByOwnLimit: heldByOwnLimit
                            )))
                        }
                        return completion(.failure(.pinnedLoginHasNoRoom(
                            name: AccountName.display(for: account),
                            reading: candidate.usage?.compactSummary(metering: model)
                        )))
                    }
                    return completion(.success(account))
                }

                guard let best = LimitEscapeRanking.best(among: values, metering: model),
                      let account = candidates.first(where: { $0.id == best.accountID })
                else {
                    return completion(.failure(.noLoginWithRoom(heldByOwnLimit: heldByOwnLimit)))
                }

                completion(.success(account))
            }
        }
    }

    // MARK: - Public Methods — The Move Reporting Back

    /// The migration a policy asked for did not go through.
    ///
    /// Called by the routine that performs it, because the park is Core's fact and the move is
    /// not: a session left `recovering` after a failed migration reads as an idle process sitting
    /// at its prompt, when what it actually is is a session still refused with nothing coming to
    /// fix it. The strip's sentence is written by the caller, which is the surface that knows
    /// which of the three ways it failed.
    ///
    /// The **allocated** surface rather than the running one: `SessionMigration.move` discards the
    /// process before it copies anything, so by the time a move fails there may be no PTY left —
    /// the same reason that lookup exists for a transcript-derived park.
    func noteAutomaticResumeFailed(for sessionID: SessionID, reason: String) {
        AgentRuntime.shared.limitRecoverySurface(for: sessionID)?
            .noteLimitParked(recoveryArmed: false)
        EventLog.shared.record(.limitRecovery, "Automatic migration failed, session flagged", [
            "session": sessionID.uuidString,
            "reason": reason
        ])
        ThreadingLogger.agent.error(
            """
            Automatic limit migration failed for \(sessionID.uuidString, privacy: .public): \
            \(reason, privacy: .private(mask: .hash))
            """
        )
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
        attemptID: UUID,
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

        case .press, .policyAccountResume:
            // Never `offerEscape` here: recomputing the suggestion would file a *new* refusal
            // over the standing one, which clears the dismissal and wipes the very sentence
            // being written. The offer is already on screen; it is told why instead.
            LimitEscapeSuggestionStore.shared.note(problem: sentence, for: sessionID)
        }
        finishRecovery(attemptID, for: sessionID)
    }

    // MARK: - Private Methods — The Interactive Escape

    /// Publishes the one-tap offer for a session left flagged.
    ///
    /// Called from both places `noteLimitParked(recoveryArmed: false)` lands, and from nowhere
    /// else: an armed recovery already has a plan and does not need a second one offered over it.
    ///
    /// The offer needs no settings opt-in, which is the whole difference between it and the
    /// `resumeVia` policy that performs the same move: `limit-recovery.md` makes automatic recovery
    /// something the user arms because it "types into the user's session with nobody watching",
    /// and here the press is the watching.
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

    /// How many times an unattended policy may move one conversation between logins, and over
    /// how long. A backstop rather than a quota — see `LimitRecoveryBudget` for why it is a
    /// rolling window and not a lifetime count.
    static let automaticMigrationAllowance = 3
    static let automaticMigrationWindow: TimeInterval = 3600

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

    /// More than one app-owned continuation means the durable invariant was already broken. Do
    /// not guess which record owns the session; name the repair the user must make.
    static var conflictingSchedulesProblem: String {
        L10n.string("This conversation has conflicting automatic recovery schedules.")
    }

    /// The unattended migrations ran out. Phrased as what happened rather than as a limit the user
    /// has never heard of: the number is a backstop against a defect, not a setting, and the
    /// answer in front of them is the button beside the sentence.
    static var budgetSpentProblem: String {
        L10n.string("This conversation has already moved between logins several times just now.")
    }

    /// The chat names a login that is no longer one of its destinations — signed out, disabled, or
    /// the chat has since moved to it.
    static var pinnedLoginGoneProblem: String {
        L10n.string("The login this chat was set to continue on is not available.")
    }

    /// Nothing was eligible. Says "right now" because it is a reading, not a verdict: a login whose
    /// window turns over becomes an offer the moment its next reading lands.
    static var noLoginWithRoomProblem: String {
        L10n.string("No other login has room right now.")
    }

    /// There is no second login at all — one account, or a runtime that routes none.
    static var noOtherLoginProblem: String {
        L10n.string("There is no other login to move this conversation to.")
    }
}
