import XCTest
@testable import Threading

/// What a launch is allowed to bring back, and what it has to ask for first.
///
/// The behaviour these pin is invisible in the app until something has already gone wrong, and
/// the way it used to fail was silent in both directions: after a crash the previously selected
/// session reopened itself — possibly the one that took the app down — and every detached browser
/// window came back with it, with nothing on screen to say either had happened.
///
/// The actions are closures, so the decision is testable without a window, an MCP listener or a
/// store. What is asserted is *which* of them ran and in what order, because the order is the
/// contract: the selected session comes back before the browser windows it would bring with it.
@MainActor
final class LaunchRestorationTests: XCTestCase {

    // MARK: - Fixture

    private enum Call: String {
        case selectedSession
        case relaunch
        case browserWindows
    }

    /// Records the restore paths in the order they ran, and keeps the offer the notice was
    /// handed so a test can press Restore the way the band does.
    private final class Recorder {

        var calls: [Call] = []
        var noticeCount = 0
        var defersRelaunch = false
        var finishRelaunch: (() -> Void)?
        /// Double-optional on purpose: the outer says whether a notice was offered at all, the
        /// inner whether macOS had filed a report to point at.
        var offeredCrashReport: URL??
        var offeredEscalation: UncleanExitEscalation?
        var restoreOffer: (() -> Void)?

        var actions: LaunchRestoration.Actions {
            LaunchRestoration.Actions(
                restoreSelectedSession: { self.calls.append(.selectedSession) },
                relaunchSessionsFromLastQuit: { completion in
                    self.calls.append(.relaunch)
                    if self.defersRelaunch { self.finishRelaunch = completion } else { completion() }
                },
                restoreDetachedBrowserWindows: { self.calls.append(.browserWindows) },
                presentNotice: { crashReport, escalation, restore in
                    self.noticeCount += 1
                    self.offeredCrashReport = crashReport
                    self.offeredEscalation = escalation
                    self.restoreOffer = restore
                }
            )
        }
    }

    private func restoration() -> (LaunchRestoration, Recorder) {
        let recorder = Recorder()
        return (LaunchRestoration(actions: recorder.actions), recorder)
    }

    func testSelectionWaitsForTheAsynchronousHostSurvey() throws {
        let (restoration, recorder) = restoration()
        recorder.defersRelaunch = true
        restoration.run(previousLaunch: .clean)
        XCTAssertEqual(recorder.calls, [.relaunch])
        try XCTUnwrap(recorder.finishRelaunch)()
        XCTAssertEqual(recorder.calls, [.relaunch, .selectedSession, .browserWindows])
    }

    func testRestoreOfferAlsoWaitsForHostOwnership() throws {
        let (restoration, recorder) = restoration()
        recorder.defersRelaunch = true
        restoration.run(previousLaunch: .unclean(crashReport: nil))
        try XCTUnwrap(recorder.restoreOffer)()
        XCTAssertEqual(recorder.calls, [.relaunch])
        try XCTUnwrap(recorder.finishRelaunch)()
        XCTAssertEqual(recorder.calls, [.relaunch, .selectedSession, .browserWindows])
    }

    // MARK: - The Plan

    func testACleanOrUnknownPreviousLaunchRestoresEverything() {
        XCTAssertEqual(LaunchRestorationPlan(previousLaunch: .clean), .restoresEverything)
        XCTAssertEqual(LaunchRestorationPlan(previousLaunch: .unknown), .restoresEverything)
    }

    /// *Unknown* is a machine the app has never run on, not a suspicious one: a first launch has
    /// nothing to restore and nothing to report, so it must not be the case that puts a band
    /// about a crash across a brand new window.
    func testAFirstLaunchOnAMachineIsNotTreatedAsACrash() {
        let (restoration, recorder) = restoration()
        restoration.run(previousLaunch: .unknown)

        XCTAssertEqual(recorder.noticeCount, 0)
        XCTAssertEqual(recorder.calls, [.relaunch, .selectedSession, .browserWindows])
    }

    func testAnUncleanPreviousLaunchHoldsBackBothWorkspacePaths() {
        let plan = LaunchRestorationPlan(previousLaunch: .unclean(crashReport: nil))

        XCTAssertFalse(plan.restoresSelectedSession)
        XCTAssertFalse(plan.restoresDetachedBrowserWindows)
    }

    /// **A restart the user asked for.** The reset flows leave without the quit path — they have
    /// to, or a polite quit writes the state they just moved aside straight back — so the marker
    /// survives them. Reset Settings does not move the support directory, so its marker was read
    /// as a crash and the next launch held the workspace back and put a notice up over a window
    /// the user had pressed a button to get back.
    func testADeliberateRestartRestoresEverythingAndSaysNothing() {
        let plan = LaunchRestorationPlan(previousLaunch: .intentional(reason: .reset))
        XCTAssertEqual(plan, .restoresEverything)

        let (restoration, recorder) = restoration()
        restoration.run(previousLaunch: .intentional(reason: .reset))

        XCTAssertEqual(recorder.noticeCount, 0)
        XCTAssertEqual(recorder.calls, [.relaunch, .selectedSession, .browserWindows])
    }

    // MARK: - Escalation

    /// One crash and a loop are the same held-back workspace and a different sentence. Recovery
    /// Mode is not offered here: a band hinting at a mode the build does not have would be worse
    /// than one that says nothing.
    func testTheNoticeIsToldWhetherThisIsTheSecondCrashOrTheFirst() {
        let (restoration, recorder) = restoration()
        restoration.run(
            previousLaunch: .unclean(crashReport: nil),
            escalation: .repeatedUnexpectedExits
        )

        XCTAssertEqual(recorder.offeredEscalation, .repeatedUnexpectedExits)
    }

    func testAnUnescalatedCrashOffersTheOrdinaryNotice() {
        let (restoration, recorder) = restoration()
        restoration.run(previousLaunch: .unclean(crashReport: nil))

        XCTAssertEqual(recorder.offeredEscalation, UncleanExitEscalation.none)
    }

    func testOnlyARecommendationEscalatesTheWording() {
        XCTAssertEqual(
            UncleanExitEscalation(decision: .launchNormally(.available)), .none
        )
        XCTAssertEqual(
            UncleanExitEscalation(decision: .noteFirstUnexpectedExit(lastCheckpoint: nil)),
            .none
        )
        XCTAssertEqual(
            UncleanExitEscalation(
                decision: .recommendRecoveryMode(consecutive: 2, lastCheckpoint: nil)
            ),
            .repeatedUnexpectedExits
        )
        XCTAssertEqual(
            UncleanExitEscalation(decision: .recommendStoppingAutomaticWork(consecutive: 3)),
            .repeatedUnexpectedExits
        )
    }

    /// Two sentences, both plain, and the escalated one names no count: a band that says "2 of 3"
    /// is asking the user to keep score of their own crashes.
    @MainActor
    func testTheEscalatedWordingIsItsOwnSentence() {
        let ordinary = MainWindowController.uncleanExitMessage(escalation: .none)
        let escalated = MainWindowController.uncleanExitMessage(
            escalation: .repeatedUnexpectedExits
        )

        XCTAssertNotEqual(ordinary, escalated)
        XCTAssertTrue(escalated.contains("more than once"))
        for message in [ordinary, escalated] {
            XCTAssertFalse(message.contains("—"), "an em dash reads as filler in a notice")
        }
    }

    // MARK: - The Run

    func testACleanPreviousLaunchRestoresInTheOrderItAlwaysHas() {
        let (restoration, recorder) = restoration()
        restoration.run(previousLaunch: .clean)

        XCTAssertEqual(recorder.calls, [.relaunch, .selectedSession, .browserWindows])
        XCTAssertEqual(recorder.noticeCount, 0)
        XCTAssertFalse(restoration.hasOfferedNotice)
    }

    func testAnUncleanPreviousLaunchOpensNothingAndOffersInstead() {
        let (restoration, recorder) = restoration()
        restoration.run(previousLaunch: .unclean(crashReport: nil))

        XCTAssertEqual(
            recorder.calls, [.relaunch],
            "an unclean exit still opened part of the workspace it was meant to hold"
        )
        XCTAssertEqual(recorder.noticeCount, 1)
        XCTAssertTrue(restoration.hasOfferedNotice)
    }

    /// The relaunch is deliberately outside the decision: the record it reads is consumed by the
    /// launch that then died, so after a crash there is nothing left in it to fire. Suppressing
    /// it here would instead hold back the ordinary case — a clean quit with sessions running —
    /// which is not what the notice is about.
    func testTheRelaunchFromTheLastQuitRunsWhateverTheOutcomeWas() {
        for outcome in [
            EventLog.PreviousLaunchOutcome.clean,
            .unknown,
            .intentional(reason: .reset),
            .unclean(crashReport: nil)
        ] {
            let (restoration, recorder) = restoration()
            restoration.run(previousLaunch: outcome)
            XCTAssertTrue(
                recorder.calls.contains(.relaunch),
                "\(outcome) skipped the relaunch, whose record must be spent every launch"
            )
        }
    }

    func testTheReportIsCarriedToTheNoticeThatPointsAtIt() throws {
        let report = URL(fileURLWithPath: "/tmp/Threading-2026-08-07-120000.ips")
        let (restoration, recorder) = restoration()
        restoration.run(previousLaunch: .unclean(crashReport: report))

        XCTAssertEqual(try XCTUnwrap(recorder.offeredCrashReport), report)
    }

    /// A kill, a power cut, or a report the system has not filed: the notice is still offered,
    /// with nothing to reveal.
    func testACrashWithNoFiledReportStillOffersTheWorkspaceBack() throws {
        let (restoration, recorder) = restoration()
        restoration.run(previousLaunch: .unclean(crashReport: nil))

        XCTAssertEqual(recorder.noticeCount, 1)
        XCTAssertNil(try XCTUnwrap(recorder.offeredCrashReport))
    }

    // MARK: - The Offer

    func testRestoringPerformsExactlyWhatWasHeldBackAndInTheSameOrder() throws {
        let (restoration, recorder) = restoration()
        restoration.run(previousLaunch: .unclean(crashReport: nil))
        recorder.calls.removeAll()

        try XCTUnwrap(recorder.restoreOffer)()

        XCTAssertEqual(
            recorder.calls, [.selectedSession, .browserWindows],
            "Restore must be the suppressed restoration and nothing else"
        )
    }

    /// The band hands back the same two calls whether it is pressed through the offer it was
    /// given or asked for directly, so a second way in cannot drift from the first.
    func testTheHeldBackWorkspaceIsTheSameWhicheverWayItIsAskedFor() {
        let (restoration, recorder) = restoration()
        restoration.run(previousLaunch: .unclean(crashReport: nil))
        recorder.calls.removeAll()

        restoration.restoreHeldBackWorkspace()

        XCTAssertEqual(recorder.calls, [.selectedSession, .browserWindows])
    }

    /// Restoring must not spend the relaunch record a second time. It was consumed on the run
    /// that put the notice up, and a second read of a store that has already been emptied is the
    /// kind of call that quietly starts working again if the store ever stops emptying.
    func testRestoringDoesNotRunTheRelaunchAgain() {
        let (restoration, recorder) = restoration()
        restoration.run(previousLaunch: .unclean(crashReport: nil))
        recorder.calls.removeAll()

        restoration.restoreHeldBackWorkspace()

        XCTAssertFalse(recorder.calls.contains(.relaunch))
    }

    // MARK: - One Shot

    /// The gate can fire twice in one launch — the walkthrough re-run from Settings ▸ Advanced
    /// finishes and asks again. A launch that has already had its say restores in full rather
    /// than holding the same workspace back a second time with nothing on screen about it.
    func testASecondRunInTheSameLaunchRestoresRatherThanHoldingBackAgain() {
        let (restoration, recorder) = restoration()
        restoration.run(previousLaunch: .unclean(crashReport: nil))
        recorder.calls.removeAll()

        restoration.run(previousLaunch: .unclean(crashReport: nil))

        XCTAssertEqual(recorder.noticeCount, 1, "the notice was offered twice for one crash")
        XCTAssertEqual(recorder.calls, [.relaunch, .selectedSession, .browserWindows])
    }

    /// Nothing is written down to make the offer one-shot. The marker it is read from is
    /// consumed on read, so a second launch after the same crash reports `clean` and this object
    /// is built fresh — the flag only has to survive the launch it belongs to.
    func testTheOfferIsHeldForTheLaunchRatherThanForTheCrash() {
        let (first, firstRecorder) = restoration()
        first.run(previousLaunch: .unclean(crashReport: nil))
        XCTAssertEqual(firstRecorder.noticeCount, 1)

        let (second, secondRecorder) = restoration()
        second.run(previousLaunch: .clean)
        XCTAssertEqual(secondRecorder.noticeCount, 0)
        XCTAssertEqual(
            secondRecorder.calls, [.relaunch, .selectedSession, .browserWindows]
        )
    }
}
