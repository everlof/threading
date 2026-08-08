import AppKit
import XCTest

@testable import Threading

/// When a scheduled send is announced, when it is quietly held back, and — the case the whole
/// class exists for — what happens to a moment that passed while the app was not running.
///
/// The scheduler is driven with an injected clock, an injected store and two injected
/// notification centres, so none of this waits on a real timer or touches the running app's own
/// event traffic. The second centre is not a nicety: `NSWorkspace.didWakeNotification` is posted
/// on the workspace's centre and never on `.default`, and a scheduler wired to one centre would
/// compile and silently never wake up.
@MainActor
final class ScheduledMessageSchedulerTests: XCTestCase {

    // MARK: - Fixture

    private var directory: URL!
    private var center: NotificationCenter!
    private var workspaceCenter: NotificationCenter!
    private var store: ScheduledMessageStore!
    private var clock: Date!
    private var reportingSessions: Set<SessionID> = []

    private let start = Date(timeIntervalSince1970: 1_775_000_000)

    override func setUp() {
        super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("scheduler-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        center = NotificationCenter()
        workspaceCenter = NotificationCenter()
        store = ScheduledMessageStore(directory: directory, center: center)
        clock = start
        reportingSessions = []
    }

    override func tearDown() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        store = nil
        center = nil
        workspaceCenter = nil
        super.tearDown()
    }

    private func makeScheduler() -> ScheduledMessageScheduler {
        ScheduledMessageScheduler(
            store: store,
            center: center,
            workspaceCenter: workspaceCenter,
            now: { [unowned self] in self.clock },
            reportsOwnTurns: { [unowned self] in self.reportingSessions.contains($0) }
        )
    }

    /// Collects the ids the scheduler announces as due.
    @MainActor
    private final class DueRecorder {
        var ids: [ScheduledMessageID] = []
        var missed: [[ScheduledMessageID]] = []
        private var observations: AppEventObservations?

        init(center: NotificationCenter) {
            let observations = AppEventObservations(center: center)
            observations.observe(ScheduledMessageDidBecomeDue.self) { [weak self] event in
                self?.ids.append(event.id)
            }
            observations.observe(ScheduledMessagesWereMissed.self) { [weak self] event in
                self?.missed.append(event.ids)
            }
            self.observations = observations
        }
    }

    @discardableResult
    private func schedule(
        dueIn seconds: TimeInterval,
        to sessionID: SessionID = SessionID(),
        anchor: ScheduledMessage.Anchor = .wallClock
    ) -> ScheduledMessage {
        let message = ScheduledMessage(
            dueAt: clock.addingTimeInterval(seconds),
            target: .session(sessionID),
            text: "Carry on with the importer",
            anchor: anchor
        )
        store.add(message, now: clock)
        return message
    }

    // MARK: - Announcing

    func testAnnouncesASendWhoseMomentHasArrived() {
        let recorder = DueRecorder(center: center)
        let message = schedule(dueIn: 60)
        let scheduler = makeScheduler()
        scheduler.start()

        XCTAssertTrue(recorder.ids.isEmpty, "Not due yet")

        clock = start.addingTimeInterval(120)
        scheduler.evaluate()

        XCTAssertEqual(recorder.ids, [message.id])
    }

    func testDoesNotAnnounceSomethingStillInTheFuture() {
        let recorder = DueRecorder(center: center)
        schedule(dueIn: 3_600)
        let scheduler = makeScheduler()
        scheduler.start()

        clock = start.addingTimeInterval(600)
        scheduler.evaluate()

        XCTAssertTrue(recorder.ids.isEmpty)
    }

    func testWakingFromSleepIsWhatCatchesATimerThatSleptThroughItsMoment() {
        let recorder = DueRecorder(center: center)
        let message = schedule(dueIn: 3_600)
        let scheduler = makeScheduler()
        scheduler.start()

        // The machine slept through the timer and woke an hour late. Nothing fired it; the wake
        // is the only thing that will.
        clock = start.addingTimeInterval(7_200)
        workspaceCenter.post(name: NSWorkspace.didWakeNotification, object: nil)

        XCTAssertEqual(
            recorder.ids,
            [message.id],
            """
            If this fails, the scheduler is observing the default centre for a notification only \
            NSWorkspace's own centre posts — which compiles, runs, and never fires.
            """
        )
    }

    func testBecomingActiveAlsoReEvaluates() {
        let recorder = DueRecorder(center: center)
        let message = schedule(dueIn: 60)
        let scheduler = makeScheduler()
        scheduler.start()

        clock = start.addingTimeInterval(120)
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)

        XCTAssertEqual(recorder.ids, [message.id])
    }

    // MARK: - The App Was Not Running

    func testAMomentThatPassedWhileQuitIsReportedAndNeverAnnouncedAsDue() {
        let recorder = DueRecorder(center: center)
        let message = schedule(dueIn: 60)

        // The app quits and comes back two days later.
        clock = start.addingTimeInterval(2 * 86_400)
        let scheduler = makeScheduler()
        scheduler.start()

        XCTAssertEqual(recorder.missed, [[message.id]])
        XCTAssertTrue(
            recorder.ids.isEmpty,
            """
            There is no grace window. The app does not send what the clock passed while it was \
            not watching — it asks. Announcing this as due would deliver it.
            """
        )
        XCTAssertEqual(store[message.id]?.state, .missed)
    }

    func testNothingIsReportedWhenNothingWasMissed() {
        let recorder = DueRecorder(center: center)
        schedule(dueIn: 3_600)

        makeScheduler().start()

        XCTAssertTrue(recorder.missed.isEmpty)
    }

    // MARK: - A Surface That Could Not Take It

    func testASendWaitingOnABusySessionIsOfferedAgainWhenTheSessionSettles() {
        let session = SessionID()
        reportingSessions.insert(session)
        let recorder = DueRecorder(center: center)
        let message = schedule(dueIn: 60, to: session)
        let scheduler = makeScheduler()
        scheduler.start()

        clock = start.addingTimeInterval(120)
        scheduler.evaluate()
        // The performer found the terminal mid-turn.
        scheduler.noteWaiting(message.id)
        store.relinquish(message.id, waitingBecause: "Waiting for the session to be free")

        center.post(SessionActivityDidChange(sessionID: session))

        XCTAssertEqual(
            recorder.ids,
            [message.id, message.id],
            "A send held back by a busy turn is still owed, and the settle is when it is paid"
        )
    }

    func testASendIsNotRetriedAgainstASessionThatCannotReportItsOwnTurns() {
        let session = SessionID()
        // Deliberately absent from `reportingSessions`: Grok, OpenCode, or Claude with lifecycle
        // hooks switched off.
        let recorder = DueRecorder(center: center)
        let message = schedule(dueIn: 60, to: session)
        let scheduler = makeScheduler()
        scheduler.start()

        clock = start.addingTimeInterval(120)
        scheduler.evaluate()
        scheduler.noteWaiting(message.id)
        store.relinquish(message.id, waitingBecause: "Waiting for the session to be free")

        center.post(SessionActivityDidChange(sessionID: session))

        XCTAssertEqual(
            recorder.ids,
            [message.id],
            """
            Announced once, never again. Where an agent does not report its own turns the idle \
            edge is a guess, and typing into a TUI on a guess is what this rule refuses.
            """
        )
    }

    func testPatienceRunsOutRatherThanLastingForever() {
        let session = SessionID()
        reportingSessions.insert(session)
        let message = schedule(dueIn: 60, to: session)
        let scheduler = makeScheduler()
        scheduler.start()

        clock = start.addingTimeInterval(120)
        scheduler.evaluate()
        scheduler.noteWaiting(message.id)
        store.relinquish(message.id, waitingBecause: "Waiting for the session to be free")

        clock = start.addingTimeInterval(
            120 + ScheduledMessageDefaults.waitingRetryWindow + 60
        )
        scheduler.evaluate()

        guard case .failed = store[message.id]?.state else {
            return XCTFail("A send that waited out its window must say so, not keep waiting")
        }
    }

    // MARK: - The Clock Itself Moving

    func testATimeZoneChangeReDerivesWhatTheUserActuallyAskedFor() {
        let calendar = Calendar(identifier: .gregorian)
        var stockholm = calendar
        stockholm.timeZone = TimeZone(identifier: "Europe/Stockholm")!
        let nineTomorrow = stockholm.date(
            byAdding: .day,
            value: 1,
            to: stockholm.startOfDay(for: start)
        )!.addingTimeInterval(9 * 3_600)

        let message = ScheduledMessage(
            dueAt: nineTomorrow,
            timeZone: TimeZone(identifier: "Europe/Stockholm")!,
            calendar: calendar,
            target: .session(SessionID()),
            text: "Nine tomorrow, wherever I am"
        )
        store.add(message, now: clock)

        let scheduler = makeScheduler()
        scheduler.start()
        center.post(name: NSNotification.Name.NSSystemTimeZoneDidChange, object: nil)

        // Whatever the machine's zone is, the stored components are what the moment is rebuilt
        // from — so the hour the user chose survives the journey.
        var local = Calendar.current
        local.timeZone = .current
        XCTAssertEqual(
            local.component(.hour, from: store[message.id]!.dueAt),
            message.intendedWallClock.hour,
            "The record keeps what was said as well as when it resolved to; this is why"
        )
    }
}
