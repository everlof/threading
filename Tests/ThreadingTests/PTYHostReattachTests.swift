import Foundation
import ThreadingDomain
import ThreadingPTYHostKit
import XCTest
@testable import Threading

/// What a launch decides about the sessions `threading-ptyd` was still holding.
///
/// **No daemon, no socket, no store and no window.** The round trip is one injected value and the
/// classification is a pure function, which is the whole reason both are shaped that way: the
/// interesting claims here are about a *launch*, and a launch that had to be arranged with a real
/// daemon in a real state could only be asserted one way round.
@MainActor
final class PTYHostReattachTests: XCTestCase {

    // MARK: - Constants

    private enum Fixture {
        static let socket = "/tmp/ptyd-reattach-tests.sock"
        static let settle: TimeInterval = 0.5
    }

    // MARK: - Classification

    /// The four answers, and the reason there are four rather than two.
    func testTheDaemonsSessionsAreSortedIntoTakeBackEndedOrphanedAndLost() {
        let running = SessionID()
        let finished = SessionID()
        let deleted = SessionID()
        let lost = SessionID()

        let plan = PTYHostReattach.plan(
            holdings: PTYHostHoldings(
                socketPath: Fixture.socket,
                sessions: [
                    summary(running),
                    summary(finished, exit: 0),
                    summary(deleted)
                ],
                lost: [.agentSession(lost)]
            ),
            isKnown: { $0 != deleted }
        )

        XCTAssertEqual(plan.adopt.map(\.sessionID), [running])
        XCTAssertEqual(plan.ended.map(\.sessionID), [finished])
        XCTAssertEqual(plan.orphans, [.agentSession(deleted)])
        XCTAssertEqual(plan.lost, [lost])
    }

    /// A session that kept working and then finished is held too.
    ///
    /// The less obvious half. It was running at the last quit, so the record says relaunch it —
    /// and it ran, and it finished, and starting a second agent because a stale record said so
    /// would be relaunching a conversation that already had its turn.
    func testAnEndedSessionIsHeldBackFromTheRelaunchJustAsALiveOneIs() {
        let running = SessionID()
        let finished = SessionID()

        let plan = PTYHostReattach.plan(
            holdings: PTYHostHoldings(
                socketPath: Fixture.socket,
                sessions: [summary(running), summary(finished, exit: 3)]
            ),
            isKnown: { _ in true }
        )

        XCTAssertEqual(plan.heldSessionIDs, [running, finished])
    }

    /// A lost session is emphatically **not** held: the daemon cannot hand it back, so the
    /// ordinary relaunch is exactly right to resume it from its transcript.
    func testALostSessionIsLeftToTheOrdinaryRelaunch() {
        let lost = SessionID()

        let plan = PTYHostReattach.plan(
            holdings: PTYHostHoldings(
                socketPath: Fixture.socket,
                sessions: [],
                lost: [.agentSession(lost)]
            ),
            isKnown: { _ in true }
        )

        XCTAssertEqual(plan.lost, [lost])
        XCTAssertTrue(
            plan.heldSessionIDs.isEmpty,
            "a session the host cannot hand back must not be subtracted from the relaunch"
        )
    }

    /// Version 1 hosts agent sessions only, so anything else the daemon holds names no
    /// conversation and is ended rather than adopted.
    func testASurfaceVersionOneDoesNotHostIsTreatedAsAnOrphan() {
        let terminal = PTYHostSessionIdentity(.projectTerminal(TerminalID()))
        let plan = PTYHostReattach.plan(
            holdings: PTYHostHoldings(
                socketPath: Fixture.socket,
                sessions: [
                    PTYHostSessionSummary(
                        id: terminal,
                        pid: 4_242,
                        startedAt: Date(),
                        executable: "/bin/sh",
                        grid: PTYHostGrid(cols: 80, rows: 24),
                        isAttached: false
                    )
                ]
            ),
            isKnown: { _ in true }
        )

        XCTAssertEqual(plan.orphans, [terminal])
        XCTAssertTrue(plan.adopt.isEmpty)
    }

    // MARK: - The launch

    /// With the hidden key off the whole step is answered on the calling turn and nothing is
    /// opened — which is what keeps a launch with the feature off the launch it has always been.
    func testTheFeatureBeingOffAnswersSynchronouslyAndSurveysNothing() {
        var answered: Set<SessionID>?
        var surveyed = false

        PTYHostReattach.run(
            decision: decision(isEnabled: false),
            survey: PTYHostHoldingsSurvey { _ in
                surveyed = true
                return nil
            },
            adopt: { _, _ in
                XCTFail("nothing may be taken back when the host is not in use")
                return false
            },
            completion: { answered = $0 }
        )

        XCTAssertEqual(
            answered,
            [],
            "the relaunch has to be told to plan everything, on this turn, with no host in play"
        )
        XCTAssertFalse(surveyed, "the setting is decided before anything is opened")
    }

    /// A daemon that does not answer holds nothing, so the relaunch plans exactly what it plans
    /// today. The degraded path is the whole of the availability contract.
    func testAnUnavailableHostHoldsNothingAndTheRelaunchPlanIsUnchanged() throws {
        var answered: Set<SessionID>?
        PTYHostReattach.run(
            decision: decision(isEnabled: true),
            survey: .answering(nil),
            adopt: { _, _ in
                XCTFail("there is no host to take anything back from")
                return false
            },
            completion: { answered = $0 }
        )
        XCTAssertTrue(
            settle(until: { answered != nil }),
            "the relaunch must be told something even when nothing answered"
        )
        let heldByHost = try XCTUnwrap(answered)
        XCTAssertTrue(heldByHost.isEmpty)

        // And the plan built from that answer is byte-for-byte the plan built without one.
        let running = session("running", lastActiveAt: Date(timeIntervalSince1970: 300))
        let idle = session("idle", lastActiveAt: Date(timeIntervalSince1970: 200))
        let today = StartupSessionRelaunch.plan(
            policy: .runningAtLastQuit,
            recorded: [running.id],
            sessions: [running, idle]
        )
        let degraded = StartupSessionRelaunch.plan(
            policy: .runningAtLastQuit,
            recorded: [running.id],
            sessions: [running, idle],
            heldByHost: heldByHost
        )

        XCTAssertEqual(degraded, today)
        XCTAssertEqual(degraded.sessionIDs, [running.id])
    }

    // MARK: - The relaunch plan

    /// The launch set is empty when the daemon holds everything the record named.
    ///
    /// Relaunching one of these would put a second agent on a conversation whose first has been
    /// working the whole time, which is the failure this ordering exists to prevent.
    func testTheRelaunchPlansNothingWhenTheHostHoldsEverythingItWouldHaveLaunched() {
        let first = session("first", lastActiveAt: Date(timeIntervalSince1970: 300))
        let second = session("second", lastActiveAt: Date(timeIntervalSince1970: 200))

        let plan = StartupSessionRelaunch.plan(
            policy: .runningAtLastQuit,
            recorded: [first.id, second.id],
            sessions: [first, second],
            heldByHost: [first.id, second.id]
        )

        XCTAssertTrue(plan.sessionIDs.isEmpty)
        XCTAssertEqual(plan.outcomes[first.id], .reattached)
        XCTAssertEqual(plan.outcomes[second.id], .reattached)
    }

    /// Held outranks every policy, including the one that says to launch nothing: the answer on
    /// the row is still "it never stopped" rather than "restore is off".
    func testHeldOutranksThePolicyThatWouldHaveLaunchedNothing() {
        let held = session("held", lastActiveAt: Date(timeIntervalSince1970: 300))
        let dormant = session("dormant", lastActiveAt: Date(timeIntervalSince1970: 200))

        let plan = StartupSessionRelaunch.plan(
            policy: .nothing,
            recorded: [],
            sessions: [held, dormant],
            heldByHost: [held.id]
        )

        XCTAssertEqual(plan.outcomes[held.id], .reattached)
        XCTAssertEqual(plan.outcomes[dormant.id], .restoreDisabled)
    }

    /// Only the held ids leave the launch set; everything else is planned exactly as before.
    func testOnlyTheHeldSessionsLeaveTheLaunchSet() {
        let held = session("held", lastActiveAt: Date(timeIntervalSince1970: 300))
        let relaunched = session("relaunched", lastActiveAt: Date(timeIntervalSince1970: 200))

        let plan = StartupSessionRelaunch.plan(
            policy: .runningAtLastQuit,
            recorded: [held.id, relaunched.id],
            sessions: [held, relaunched],
            heldByHost: [held.id]
        )

        XCTAssertEqual(plan.sessionIDs, [relaunched.id])
        XCTAssertEqual(plan.outcomes[relaunched.id], .restored)
    }

    // MARK: - What the row says

    /// "It never went away" and "it came back" are different answers, and only one of them is
    /// about a setting.
    func testTheReattachedRowExplainsItselfWithoutBlamingLaunchRestore() throws {
        let reason = try XCTUnwrap(
            SessionPopoverDefaults.dormancyReason(for: .reattached)
        )

        XCTAssertTrue(reason.contains("background"), reason)
        XCTAssertFalse(
            reason.contains(SessionPopoverDefaults.restoreSettingHint),
            "launch restore had no say in this one, so pointing at it would point at nothing"
        )
        XCTAssertNotEqual(
            reason,
            SessionPopoverDefaults.dormancyReason(for: .notRunningAtLastQuit)
        )
    }

    // MARK: - Helpers

    private func decision(isEnabled: Bool) -> PTYHostDecision {
        PTYHostDecision(
            isEnabled: isEnabled,
            helperURL: URL(fileURLWithPath: "/nonexistent/threading-ptyd"),
            socketPath: Fixture.socket,
            socketPathBytes: Fixture.socket.utf8.count,
            build: "test"
        )
    }

    private func summary(_ sessionID: SessionID, exit: Int32? = nil) -> PTYHostSessionSummary {
        PTYHostSessionSummary(
            id: .agentSession(sessionID),
            pid: 4_242,
            startedAt: Date(timeIntervalSince1970: 1_000),
            executable: "/bin/sh",
            grid: PTYHostGrid(cols: 100, rows: 40),
            isAttached: false,
            exit: exit
        )
    }

    private func session(_ title: String, lastActiveAt: Date) -> AgentSession {
        var session = AgentSession(kind: .claude, title: title)
        session.lastActiveAt = lastActiveAt
        return session
    }

    private func settle(until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(Fixture.settle)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        return condition()
    }
}
