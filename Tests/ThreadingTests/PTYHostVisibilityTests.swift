import Foundation
import ThreadingDomain
import ThreadingPTYHostKit
import XCTest

@testable import Threading

/// What the app *says* about work that has no window.
///
/// Three surfaces and no fourth: the quit question, the launch band, and the Background Sessions
/// list. Each is built apart from being shown — a `QuitQuestion`, a `PTYHostLaunchNotice`, a
/// `PTYHostBackgroundSessionsState` — which is the seam that lets the wording be held to what the
/// action actually does without a modal, a window or a daemon anywhere.
@MainActor
final class PTYHostVisibilityTests: XCTestCase {

    // MARK: - The quit question

    /// With nothing host-backed, this is the question the app has always asked.
    ///
    /// True by construction rather than by two copies being kept in step: the three-answer
    /// builder *calls* the two-answer one, so the assertion is that it is the same value.
    func testTheQuitQuestionIsUnchangedWithNoBackgroundSessions() {
        let question = AppDelegate.quitConfirmation(
            runningSessionCount: 6,
            inFlightTurnCount: 2,
            backgroundSessionCount: 0
        )
        let today = AppDelegate.quitConfirmation(runningSessionCount: 6, inFlightTurnCount: 2)

        guard case .confirms(let request) = question else {
            return XCTFail("with no background host this is a confirmation, not a choice")
        }
        XCTAssertEqual(request.title, today.title)
        XCTAssertEqual(request.message, today.message)
        XCTAssertEqual(question.answers, [today.confirmTitle], "one way to go ahead")
        XCTAssertEqual(question.prompt, .quitWithRunningAgents)
    }

    /// With the daemon holding sessions, quitting stops being a confirmation and becomes a
    /// choice between two quits.
    func testTheQuitQuestionOffersLeavingThemRunningAndStoppingThem() {
        let question = AppDelegate.quitConfirmation(
            runningSessionCount: 0,
            inFlightTurnCount: 0,
            backgroundSessionCount: 3
        )

        guard case .chooses = question else {
            return XCTFail("a confirmation would decide the fate of work the user cannot see")
        }
        XCTAssertEqual(question.answers.count, 2, "two affirmatives, and Cancel behind them")
        XCTAssertTrue(question.answers[0].contains("Leave"), question.answers[0])
        XCTAssertTrue(question.answers[0].contains("3"), question.answers[0])
        XCTAssertTrue(question.answers[1].contains("Stop"), question.answers[1])
        XCTAssertTrue(question.title.contains("3"), question.title)
    }

    /// The recoverable answer leads, the destructive one follows, and anything else is Cancel.
    func testTheAnswersAreLeaveRunningThenStopThenCancel() {
        let question = AppDelegate.quitConfirmation(
            runningSessionCount: 1,
            inFlightTurnCount: 0,
            backgroundSessionCount: 2
        )

        XCTAssertEqual(question.answer(atIndex: 0), .leaveRunning)
        XCTAssertEqual(question.answer(atIndex: 1), .stopEverything)
        XCTAssertEqual(question.answer(atIndex: 2), .cancel)
        XCTAssertEqual(question.answer(atIndex: nil), .cancel, "Escape does not quit")
        XCTAssertTrue(QuitAnswer.leaveRunning.quits)
        XCTAssertTrue(QuitAnswer.stopEverything.quits)
        XCTAssertFalse(QuitAnswer.cancel.quits)
    }

    /// Sessions the daemon cannot host are counted separately and still described as closing,
    /// because that is what happens to them.
    func testSessionsTheHostCannotKeepAreCountedSeparatelyAndStillClose() {
        let question = AppDelegate.quitConfirmation(
            runningSessionCount: 2,
            inFlightTurnCount: 1,
            backgroundSessionCount: 3
        )

        XCTAssertTrue(
            question.message.contains("3 sessions keep working"),
            question.message
        )
        XCTAssertTrue(
            question.message.contains("2 other sessions close"),
            question.message
        )
        XCTAssertTrue(question.message.contains("resumed"), question.message)
        XCTAssertTrue(question.message.contains("turn in flight is lost"), question.message)
    }

    /// A turn being written in a session the daemon keeps is not lost by quitting, so the
    /// message says nothing about one.
    func testNothingIsSaidAboutLossWhenEverythingKeepsRunning() {
        let question = AppDelegate.quitConfirmation(
            runningSessionCount: 0,
            inFlightTurnCount: 0,
            backgroundSessionCount: 4
        )

        XCTAssertFalse(question.message.contains("close"), question.message)
        XCTAssertFalse(question.message.contains("lost"), question.message)
    }

    /// "1 sessions" is the kind of thing nobody notices until it ships, and one chat working
    /// while you reach for Cmd+Q is the common case.
    func testTheQuitChoiceReadsProperlyForOneOfEachThing() {
        let question = AppDelegate.quitConfirmation(
            runningSessionCount: 1,
            inFlightTurnCount: 1,
            backgroundSessionCount: 1
        )

        XCTAssertTrue(question.title.contains("one session"), question.title)
        XCTAssertFalse(question.title.contains("1 "), question.title)
        XCTAssertEqual(question.answers[0], "Leave One Running")
        XCTAssertEqual(question.answers[1], "Stop It and Quit")
        XCTAssertTrue(question.message.contains("One session keeps working"), question.message)
        XCTAssertTrue(question.message.contains("One other session closes"), question.message)
        XCTAssertTrue(question.message.contains("The turn in flight is lost"), question.message)
    }

    /// A choice cannot be suppressible: a remembered answer has to be *an* answer, and a box
    /// beside three of them says nothing about which one it would repeat.
    func testTheQuitChoiceIsNeverSuppressibleAndItsSiblingStillIs() {
        XCTAssertNil(ConfirmationPrompt.quitWithBackgroundSessions.suppression)
        XCTAssertFalse(
            ConfirmationPrompt.quitWithBackgroundSessions.defaultsToCancel,
            "Return stays on the affirmative, and the affirmative here destroys nothing"
        )
        XCTAssertNotNil(
            ConfirmationPrompt.quitWithRunningAgents.suppression,
            "the two-answer question is one answer worth remembering, and stays suppressible"
        )
    }

    // MARK: - The launch band

    /// The band appears only when the daemon kept something running, and states a fact when
    /// this launch has already taken it all back.
    func testTheLaunchBandStatesWhatSurvivedAndOffersNothingWhenItIsAllBack() {
        XCTAssertNil(
            PTYHostLaunchNotice.forLaunch(.empty, pending: 0),
            "a launch with nothing to report says nothing"
        )

        let notice = try? XCTUnwrap(PTYHostLaunchNotice.forLaunch(
            plan(adopt: 3),
            pending: 0
        ))
        XCTAssertEqual(notice, .keptRunning(count: 3, pending: 0))
        XCTAssertEqual(notice?.message, "3 sessions kept running while Threading was closed.")
        XCTAssertNil(notice?.actionTitle, "after the reattach there is nothing left to press")
        XCTAssertEqual(notice?.isAttention, false)
    }

    /// A terminal this launch could not rebuild is what puts `Reattach` on the band.
    func testTheLaunchBandOffersReattachOnlyForWhatIsStillOutstanding() {
        let notice = PTYHostLaunchNotice.keptRunning(count: 3, pending: 1)

        XCTAssertEqual(notice.actionTitle, "Reattach")
        XCTAssertEqual(notice.count, 3)
    }

    /// The band names what **came back**, not what the daemon was holding.
    ///
    /// Measured on 2026-08-26: the daemon held 32 terminals, 31 were taken back, and the band read
    /// "32 sessions kept running while Threading was closed." with `Reattach` beside it — a
    /// sentence that overstated the recovery next to a button whose subject the sentence never
    /// mentioned. Both halves are the same mistake: `count` was the total rather than the outcome.
    func testTheBandNamesWhatCameBackRatherThanWhatTheDaemonHeld() throws {
        let notice = try XCTUnwrap(PTYHostLaunchNotice.forLaunch(plan(adopt: 32), pending: 1))

        XCTAssertEqual(notice, .keptRunning(count: 31, pending: 1))
        XCTAssertEqual(
            notice.message,
            "31 sessions kept running while Threading was closed. "
                + "One session could not be taken back."
        )
        XCTAssertEqual(notice.actionTitle, "Reattach")
    }

    /// A launch that recovered nothing says only the half that is true, and still offers the way
    /// back: a sentence claiming zero sessions kept running would be the same overstatement in
    /// the other direction.
    func testABandWithNothingRecoveredNamesOnlyWhatIsOutstanding() throws {
        let notice = try XCTUnwrap(PTYHostLaunchNotice.forLaunch(plan(adopt: 2), pending: 2))

        XCTAssertEqual(notice, .keptRunning(count: 0, pending: 2))
        XCTAssertEqual(notice.message, "2 sessions could not be taken back.")
        XCTAssertEqual(notice.actionTitle, "Reattach")
    }

    /// A conversation the daemon kept working counts as having kept running, even though it is
    /// not taken back: it did keep running, and what it wrote is in the transcript.
    func testAConversationTheHostKeptWorkingCountsOnTheBand() {
        let notice = PTYHostLaunchNotice.forLaunch(plan(adopt: 1, resume: 2), pending: 0)

        XCTAssertEqual(notice, .keptRunning(count: 3, pending: 0))
    }

    /// A loss outranks a survival, because only one band fits and only one of the two names work
    /// that is not coming back on its own.
    func testALossOutranksASurvival() {
        let sessionID = SessionID()
        let notice = PTYHostLaunchNotice.forLaunch(
            plan(adopt: 2, lost: [sessionID]),
            pending: 0
        )

        XCTAssertEqual(notice, .lost([sessionID]))
        XCTAssertEqual(notice?.isAttention, true)
        XCTAssertEqual(notice?.actionTitle, "Resume")
        XCTAssertEqual(
            notice?.message,
            "One session was lost when the background session host restarted. Its conversation "
                + "can be resumed."
        )
    }

    func testALossCarriesTheDaemonIncidentIntoTheLaunchNotice() throws {
        let sessionID = SessionID()
        let incidentID = UUID()
        let detectedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let notice = try XCTUnwrap(PTYHostLaunchNotice.forLaunch(
            plan(lost: [sessionID]),
            pending: 0,
            loss: PTYHostLost(
                ids: [.agentSession(sessionID)],
                since: Date(timeIntervalSince1970: 1_700_000_000),
                incidentID: incidentID,
                detectedAt: detectedAt
            )
        ))

        XCTAssertEqual(
            notice,
            .lostIncident(
                ids: [sessionID],
                key: "incident:\(incidentID.uuidString)",
                detectedAt: detectedAt
            )
        )
    }

    /// One band per launch. A later survey is answering a question the user just asked rather
    /// than announcing one.
    func testTheBandIsOfferedOncePerLaunch() {
        var presented: [PTYHostLaunchNotice] = []
        var reattached = 0
        let center = PTYHostLaunchNoticeCenter(
            actions: PTYHostLaunchNoticeCenter.Actions(
                present: { notice, answer in
                    presented.append(notice)
                    answer()
                },
                reattach: { reattached += 1 },
                resume: { _ in }
            )
        )

        XCTAssertTrue(center.offer(.keptRunning(count: 2, pending: 1)))
        XCTAssertFalse(center.offer(.keptRunning(count: 2, pending: 1)))
        XCTAssertFalse(center.offer(nil))
        XCTAssertEqual(presented.count, 1)
        XCTAssertEqual(reattached, 1, "the band's one answer is the reattach")
        XCTAssertTrue(center.hasOffered)
    }

    /// The lost band's answer resumes exactly the conversations the daemon could not hand back.
    func testTheLostBandResumesTheConversationsItNames() {
        let ids = [SessionID(), SessionID()]
        var resumed: [SessionID] = []
        let center = PTYHostLaunchNoticeCenter(
            actions: PTYHostLaunchNoticeCenter.Actions(
                present: { _, answer in answer() },
                reattach: { XCTFail("a lost session cannot be reattached") },
                resume: { resumed = $0 }
            )
        )

        XCTAssertTrue(center.offer(.lost(ids)))
        XCTAssertEqual(resumed, ids)
    }

    /// The daemon reports one recovered loss on every connection for its lifetime. Remembering
    /// the incident across app launches makes that one warning rather than one warning per open.
    func testTheSameLossIncidentIsOfferedOnlyOnceAcrossLaunches() throws {
        let suiteName = "PTYHostLaunchNoticeCenterTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var presented: [PTYHostLaunchNotice] = []
        let actions = PTYHostLaunchNoticeCenter.Actions(
            present: { notice, _ in presented.append(notice) },
            reattach: {},
            resume: { _ in }
        )
        let first = PTYHostLaunchNotice.lostIncident(
            ids: [SessionID()],
            key: "incident:first",
            detectedAt: nil
        )

        XCTAssertTrue(PTYHostLaunchNoticeCenter(actions: actions, defaults: defaults).offer(first))
        XCTAssertFalse(PTYHostLaunchNoticeCenter(actions: actions, defaults: defaults).offer(first))
        XCTAssertTrue(PTYHostLaunchNoticeCenter(actions: actions, defaults: defaults).offer(
            .lostIncident(ids: [SessionID()], key: "incident:second", detectedAt: nil)
        ))
        XCTAssertEqual(presented.count, 2)
    }

    // MARK: - The Background Sessions list

    /// The daemon answers in its own vocabulary; the row is the app's join of that with a
    /// conversation the person reading the page is actually looking for.
    func testAHeldSessionIsDescribedInTheAppsOwnWords() {
        let sessionID = SessionID()
        let rows = PTYHostHeldSession.rows(for: [
            summary(sessionID: sessionID),
            summary(sessionID: SessionID(), executable: "/opt/homebrew/bin/codex")
        ]) { id in
            id == sessionID ? (name: "Fix the sidebar", project: "Threading", agent: "Claude")
                : nil
        }

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].name, "Fix the sidebar")
        XCTAssertEqual(rows[0].project, "Threading")
        XCTAssertEqual(rows[0].agent, "Claude")
        XCTAssertEqual(
            rows[1].name,
            "codex",
            "a child whose conversation is gone is still identifiable by what it is running"
        )
        XCTAssertNil(rows[1].project)
    }

    /// An ended child is a row that cannot be stopped, because there is nothing left to stop.
    func testAnEndedChildIsMarkedAsSuch() {
        let rows = PTYHostHeldSession.rows(for: [summary(exit: 0)]) { _ in nil }

        XCTAssertTrue(rows[0].hasExited)
    }

    /// Every unavailability blocks a selected host-backed launch and none of them is silent: a
    /// `Bool` here is how a feature that quietly stopped working becomes unexplainable.
    func testEveryUnavailabilityHasASentenceAndOnlyOneHasAnAction() {
        for reason in PTYHostUnavailability.allTokens {
            let status = PTYHostBackgroundSessionsStatus.unavailable(reason)
            XCTAssertFalse(status.sentence.isEmpty, "\(reason) says nothing")
            XCTAssertNil(status.heldSessionCount, "nothing answered, so nothing is held")
            XCTAssertEqual(
                status.offersLoginItems,
                reason == .requiresApproval,
                "only approval has a fix the app cannot perform itself"
            )
        }
    }

    /// The counts the section leads with, singular and plural, and the surveying state that is
    /// neither.
    func testTheStatusLineSaysWhatTheHostIsHolding() {
        XCTAssertEqual(PTYHostBackgroundSessionsStatus.holding(0).heldSessionCount, 0)
        XCTAssertTrue(
            PTYHostBackgroundSessionsStatus.holding(0).sentence.contains("no sessions")
        )
        XCTAssertTrue(
            PTYHostBackgroundSessionsStatus.holding(1).sentence.contains("one session")
        )
        XCTAssertTrue(
            PTYHostBackgroundSessionsStatus.holding(4).sentence.contains("4 sessions")
        )
        XCTAssertNil(PTYHostBackgroundSessionsStatus.surveying.heldSessionCount)
    }

    /// `unregister()` kills the running helper, so turning the key off must not be a way to end
    /// somebody's turn: the registration stays while the daemon holds anything.
    func testTurningTheHostOffLeavesTheRegistrationWhileItHoldsSessions() {
        XCTAssertEqual(
            PTYHostRegistration.removalDecision(heldSessions: nil),
            .leaveUnanswered
        )
        XCTAssertEqual(PTYHostRegistration.removalDecision(heldSessions: 0), .unregister)
        XCTAssertEqual(
            PTYHostRegistration.removalDecision(heldSessions: 2),
            .leave(heldSessions: 2)
        )
    }

    /// Stop ends an agent, and the sheet says which one and what it costs.
    func testStoppingASessionNamesItAndSaysWhatIsLost() {
        let request = AdvancedPreferencesViewController.stopConfirmation(
            sessionName: "Fix the sidebar"
        )

        XCTAssertTrue(request.title.contains("Fix the sidebar"), request.title)
        XCTAssertTrue(request.message.contains("resumed"), request.message)
        XCTAssertEqual(request.prompt, .stopSessionProcess)
        XCTAssertTrue(
            ConfirmationPrompt.stopSessionProcess.defaultsToCancel,
            "the way back is the user's own next message, so Return sits on Cancel"
        )
    }

    // MARK: - Private Methods

    private func plan(
        adopt: Int = 0,
        resume: Int = 0,
        lost: [SessionID] = []
    ) -> PTYHostReattachPlan {
        PTYHostReattachPlan(
            adopt: (0..<adopt).map { _ in summary(sessionID: SessionID()) },
            resume: (0..<resume).map { _ in summary(sessionID: SessionID()) },
            ended: [],
            orphans: [],
            lost: lost
        )
    }

    private func summary(
        sessionID: SessionID = SessionID(),
        executable: String = "/usr/local/bin/claude",
        exit: Int32? = nil
    ) -> PTYHostSessionSummary {
        PTYHostSessionSummary(
            id: PTYHostSessionIdentity(.agentSession(sessionID)),
            pid: 1234,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            executable: executable,
            grid: PTYHostGrid(cols: 80, rows: 24),
            isAttached: false,
            exit: exit
        )
    }
}

// MARK: - Every reason, named once

extension PTYHostUnavailability {

    /// One of each case, so a new reason without a sentence fails a test rather than drawing an
    /// empty status line. `CaseIterable` is unavailable because two of them carry a value.
    static var allTokens: [PTYHostUnavailability] {
        [
            .disabled,
            .requiresApproval,
            .notRegistered,
            .notFound,
            .notRunning,
            .registrationRefreshing,
            .protocolMismatch(.peerTooOld),
            .helperMissing,
            .socketPathTooLong(bytes: 120)
        ]
    }
}
