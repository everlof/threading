import AppKit
import Foundation
import XCTest
@testable import Threading

/// The curfew engine's whole ladder, against a private durable store, a scratch preferences
/// suite, an injected clock and performers that record rather than act.
///
/// No process, no provider, no window and no wall-clock timer takes part. That matters more here
/// than for most fixtures: this is the class that presses Escape in somebody's terminal, so a
/// test able to reach a live session would be a test that typed into one.
@MainActor
final class SessionCurfewCenterTests: XCTestCase {

    // MARK: - Fixture

    /// One suite for the class, cleared at both ends. Never one per test method: a scratch
    /// domain per method accumulates in the developer's own preferences directory.
    private static let suiteName = "threading-curfew-center-tests"

    private var directory: URL!
    private var store: ProjectStore!
    private var messages: ScheduledMessageStore!
    private var defaults: UserDefaults!
    private var settings: CurfewSettings!
    private var events: NotificationCenter!
    private var workspaceEvents: NotificationCenter!
    private var center: SessionCurfewCenter!

    private var chatID: SessionID!
    private var terminalID: SessionID!

    private var calendar = Calendar(identifier: .gregorian)
    private var now: Date!

    private var activities: [SessionID: SessionActivity] = [:]
    private var watched: Set<SessionID> = []
    private var reportsTurns = true
    private var escapeCapable = true

    private var nativeInterrupts: [SessionID] = []
    private var terminalInterrupts: [SessionID] = []
    private var terminalInterruptLands = true
    private var stoppedAgents: [SessionID] = []
    private var gaveUpAlerts: [(session: SessionID, interrupts: Int, stopped: Bool)] = []
    private var withdrawnAlerts: [SessionID] = []
    private var announcedChanges: [SessionID] = []

    override func setUpWithError() throws {
        try super.setUpWithError()

        UserDefaults.standard.removePersistentDomain(forName: Self.suiteName)
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-curfew-center-\(UUID().uuidString)")

        store = ProjectStore(stateManager: StateManager(appSupportDirectory: directory))
        let project = try XCTUnwrap(
            store.addProject(folderURL: directory.appendingPathComponent("checkout"))
        )
        chatID = try XCTUnwrap(
            store.addSession(to: project.id, kind: .claude, usesNativeUI: true)?.id
        )
        terminalID = try XCTUnwrap(
            store.addSession(to: project.id, kind: .claude, usesNativeUI: false)?.id
        )

        events = NotificationCenter()
        workspaceEvents = NotificationCenter()
        messages = ScheduledMessageStore(
            directory: directory.appendingPathComponent("scheduled"),
            center: events
        )
        defaults = try XCTUnwrap(UserDefaults(suiteName: Self.suiteName))
        settings = CurfewSettings(defaults: defaults)

        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Stockholm"))
        now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2033, month: 5, day: 18, hour: 22, minute: 0
        )))

        center = makeCenter()
    }

    override func tearDown() {
        center = nil
        store = nil
        messages = nil
        settings = nil
        events = nil
        workspaceEvents = nil
        UserDefaults.standard.removePersistentDomain(forName: Self.suiteName)
        defaults = nil
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        super.tearDown()
    }

    /// `typesIntoLiveSessions: false` is what makes this a fixture rather than the app's own
    /// centre — see `testStartRefusesUnderAHostedTestBundle`.
    private func makeCenter(typesIntoLiveSessions: Bool = false) -> SessionCurfewCenter {
        SessionCurfewCenter(
            projectStore: store,
            scheduledMessages: messages,
            settings: settings,
            now: { [weak self] in self?.now ?? .distantPast },
            calendar: calendar,
            activity: { [weak self] in self?.activities[$0] ?? .dormant },
            reportsOwnTurns: { [weak self] _ in self?.reportsTurns ?? false },
            supportsEscape: { [weak self] _ in self?.escapeCapable ?? false },
            isWatched: { [weak self] in self?.watched.contains($0) ?? false },
            notificationCenter: events,
            workspaceCenter: workspaceEvents,
            eventLog: EventLog(directory: directory.appendingPathComponent("events")),
            performers: recordingPerformers(),
            typesIntoLiveSessions: typesIntoLiveSessions
        )
    }

    private func recordingPerformers() -> SessionCurfewCenter.Performers {
        SessionCurfewCenter.Performers(
            interruptNative: { [weak self] in self?.nativeInterrupts.append($0) },
            interruptTerminal: { [weak self] sessionID in
                guard let self else { return false }
                self.terminalInterrupts.append(sessionID)
                return self.terminalInterruptLands
            },
            stopAgent: { [weak self] in self?.stoppedAgents.append($0) },
            postGaveUpAlert: { [weak self] sessionID, interrupts, stopped in
                self?.gaveUpAlerts.append((sessionID, interrupts, stopped))
            },
            withdrawGaveUpAlert: { [weak self] in self?.withdrawnAlerts.append($0) }
        )
    }

    private func setPreferences(
        windDownMargin: TimeInterval? = CurfewDefaults.windDownMargin,
        grace: TimeInterval? = CurfewDefaults.grace,
        quietHours: QuietHours = .default,
        stopsAgentOnGiveUp: Bool = false
    ) {
        settings.preferences = CurfewPreferences(
            windDownMargin: windDownMargin,
            grace: grace,
            windDownText: CurfewDefaults.windDownText,
            quietHours: quietHours,
            stopsAgentOnGiveUp: stopsAgentOnGiveUp
        )
    }

    private func state(of sessionID: SessionID) -> SessionCurfewState? {
        center.state(for: sessionID)
    }

    /// A moment on a given day in the fixture's own zone, for the standing-window cases.
    private func moment(day: Int, hour: Int, minute: Int = 0) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2033, month: 5, day: day, hour: hour, minute: minute
        )))
    }

    /// The system notifications arrive through `OperationQueue.main`; a short turn of the loop
    /// makes the test independent of whether that delivery is inlined on the posting thread.
    private func settle() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }

    // MARK: - The Wrap-Up

    func testWrapUpIsFiledOnlyWhileATurnIsInFlight() throws {
        setPreferences()
        let deadline = now.addingTimeInterval(3_600)
        center.setCurfew(.until(deadline), forSessionID: chatID)

        activities[chatID] = .working
        now = deadline.addingTimeInterval(-CurfewDefaults.windDownMargin)
        center.evaluateAll()

        let filed = messages.messages(for: chatID)
        XCTAssertEqual(filed.count, 1, "the wrap-up was not filed")
        XCTAssertEqual(filed.first?.purpose, .curfewWindDown)
        XCTAssertTrue(
            try XCTUnwrap(filed.first).text.contains(ScheduledTimePresets.time(deadline)),
            "the placeholder was not replaced with the curfew's own time"
        )
        XCTAssertEqual(state(of: chatID)?.windDownMessageID, filed.first?.id)

        // Idempotent: a second pass at the same moment must not file a second copy.
        center.evaluateAll()
        XCTAssertEqual(messages.messages(for: chatID).count, 1)
    }

    func testAnIdleSessionHasNothingToWrapUp() {
        setPreferences()
        let deadline = now.addingTimeInterval(3_600)
        center.setCurfew(.until(deadline), forSessionID: chatID)

        activities[chatID] = .idle
        now = deadline.addingTimeInterval(-CurfewDefaults.windDownMargin)
        center.evaluateAll()

        XCTAssertTrue(messages.messages(for: chatID).isEmpty, "an idle session was typed into")
        XCTAssertEqual(state(of: chatID)?.has(.windDownSkippedIdle), true)
    }

    func testAWrapUpPastItsWindowFailsWithTheCurfewsOwnSentence() throws {
        setPreferences()
        let deadline = now.addingTimeInterval(3_600)
        center.setCurfew(.until(deadline), forSessionID: chatID)

        activities[chatID] = .working
        now = deadline.addingTimeInterval(-CurfewDefaults.windDownMargin)
        center.evaluateAll()
        let filed = try XCTUnwrap(messages.messages(for: chatID).first)

        activities[chatID] = .idle
        now = deadline.addingTimeInterval(CurfewDefaults.grace + CurfewDefaults.windDownMargin)
        center.evaluateAll()

        XCTAssertEqual(
            messages[filed.id]?.state,
            .failed(CurfewReceiptWords.windDownFailureReason)
        )
        let receipt = try XCTUnwrap(
            state(of: chatID)?.receipts.last { $0.event == .windDownFailed }
        )
        XCTAssertEqual(receipt.detail, CurfewReceiptWords.windDownFailureReason)
    }

    // MARK: - The Hold

    func testHoldIsRecordedAtTheDeadlineAndAnnouncedOnce() {
        setPreferences(windDownMargin: nil, grace: nil)
        let deadline = now.addingTimeInterval(3_600)
        center.setCurfew(.until(deadline), forSessionID: chatID)

        let token = events.observe(CurfewDidChange.self) { [weak self] event in
            self?.announcedChanges.append(event.sessionID)
        }
        defer { events.removeObserver(token) }

        now = deadline
        center.evaluateAll()

        XCTAssertEqual(state(of: chatID)?.has(.held), true)
        XCTAssertEqual(state(of: chatID)?.momentOf(.held), deadline)
        XCTAssertEqual(announcedChanges, [chatID])

        center.evaluateAll()
        XCTAssertEqual(
            announcedChanges,
            [chatID],
            "the hold announced itself again on a settled instance"
        )
    }

    // MARK: - The Interrupt

    func testTheFirstInterruptFiresAtTheGraceOnANativeConversation() throws {
        setPreferences(windDownMargin: nil)
        let deadline = now.addingTimeInterval(3_600)
        center.setCurfew(.until(deadline), forSessionID: chatID)

        activities[chatID] = .working
        now = deadline.addingTimeInterval(CurfewDefaults.grace)
        center.evaluateAll()

        XCTAssertEqual(nativeInterrupts, [chatID])
        XCTAssertTrue(terminalInterrupts.isEmpty)
        XCTAssertEqual(state(of: chatID)?.interruptCount, 1)
        let receipt = try XCTUnwrap(
            state(of: chatID)?.receipts.last { $0.event == .interrupted }
        )
        XCTAssertEqual(receipt.detail, "1/\(CurfewDefaults.maximumInterrupts)")
        XCTAssertEqual(state(of: chatID)?.lastInterruptAt, now)
    }

    func testEscapeNeedsBothTheCapabilityAndAReportedTurn() {
        setPreferences(windDownMargin: nil)
        let deadline = now.addingTimeInterval(3_600)
        center.setCurfew(.until(deadline), forSessionID: terminalID)

        activities[terminalID] = .working
        now = deadline.addingTimeInterval(CurfewDefaults.grace)

        escapeCapable = true
        reportsTurns = false
        center.evaluateAll()
        XCTAssertTrue(terminalInterrupts.isEmpty, "Escape was typed at a runtime that reports no turns")
        XCTAssertEqual(state(of: terminalID)?.interruptCount ?? 0, 0)

        escapeCapable = false
        reportsTurns = true
        center.evaluateAll()
        XCTAssertTrue(terminalInterrupts.isEmpty, "Escape was typed at a CLI that does not take it")

        escapeCapable = true
        center.evaluateAll()
        XCTAssertEqual(terminalInterrupts, [terminalID])
        XCTAssertEqual(state(of: terminalID)?.interruptCount, 1)
    }

    func testATurnStartedInFrontOfTheUserIsNotInterruptedAgain() {
        setPreferences(windDownMargin: nil)
        center.start()
        let deadline = now.addingTimeInterval(3_600)
        center.setCurfew(.until(deadline), forSessionID: chatID)

        now = deadline.addingTimeInterval(CurfewDefaults.grace)
        activities[chatID] = .working
        events.post(SessionActivityDidChange(sessionID: chatID))
        XCTAssertEqual(nativeInterrupts.count, 1, "the first press did not land")

        // The turn ends, and the next one begins while the user is looking at it.
        activities[chatID] = .idle
        events.post(SessionActivityDidChange(sessionID: chatID))
        now = now.addingTimeInterval(CurfewDefaults.reinterruptSpacing + 10)
        watched.insert(chatID)
        activities[chatID] = .working
        events.post(SessionActivityDidChange(sessionID: chatID))
        XCTAssertEqual(nativeInterrupts.count, 1, "a turn the user started was interrupted")

        // And the one after that begins with nobody watching.
        activities[chatID] = .idle
        events.post(SessionActivityDidChange(sessionID: chatID))
        watched.removeAll()
        now = now.addingTimeInterval(CurfewDefaults.reinterruptSpacing + 10)
        activities[chatID] = .working
        events.post(SessionActivityDidChange(sessionID: chatID))
        XCTAssertEqual(nativeInterrupts.count, 2)
    }

    func testInterruptsAreSpaced() {
        setPreferences(windDownMargin: nil)
        let deadline = now.addingTimeInterval(3_600)
        center.setCurfew(.until(deadline), forSessionID: chatID)

        activities[chatID] = .working
        now = deadline.addingTimeInterval(CurfewDefaults.grace)
        center.evaluateAll()
        XCTAssertEqual(nativeInterrupts.count, 1)

        now = now.addingTimeInterval(CurfewDefaults.reinterruptSpacing - 1)
        center.evaluateAll()
        XCTAssertEqual(nativeInterrupts.count, 1, "a second press landed inside the spacing")

        now = now.addingTimeInterval(2)
        center.evaluateAll()
        XCTAssertEqual(nativeInterrupts.count, 2)
    }

    // MARK: - Giving Up

    /// Spends the whole budget and then reaches the occasion after it.
    private func exhaustTheBudget(after deadline: Date) {
        activities[chatID] = .working
        now = deadline.addingTimeInterval(CurfewDefaults.grace)
        center.evaluateAll()
        for _ in 1 ..< (CurfewDefaults.maximumInterrupts + 1) {
            now = now.addingTimeInterval(CurfewDefaults.reinterruptSpacing + 1)
            center.evaluateAll()
        }
    }

    func testGivingUpNotifiesAndLeavesTheAgentAlone() {
        setPreferences(windDownMargin: nil)
        let deadline = now.addingTimeInterval(3_600)
        center.setCurfew(.until(deadline), forSessionID: chatID)

        exhaustTheBudget(after: deadline)

        XCTAssertEqual(nativeInterrupts.count, CurfewDefaults.maximumInterrupts)
        XCTAssertEqual(state(of: chatID)?.interruptCount, CurfewDefaults.maximumInterrupts)
        XCTAssertNotNil(state(of: chatID)?.gaveUpAt)
        XCTAssertEqual(state(of: chatID)?.has(.gaveUp), true)
        XCTAssertEqual(state(of: chatID)?.has(.stoppedAgent), false)
        XCTAssertTrue(stoppedAgents.isEmpty, "the default ladder ended somebody's agent")
        XCTAssertEqual(gaveUpAlerts.count, 1)
        XCTAssertEqual(gaveUpAlerts.first?.interrupts, CurfewDefaults.maximumInterrupts)
        XCTAssertEqual(gaveUpAlerts.first?.stopped, false)
    }

    func testGivingUpStopsTheAgentWhenSettingsSaySo() {
        setPreferences(windDownMargin: nil, stopsAgentOnGiveUp: true)
        let deadline = now.addingTimeInterval(3_600)
        center.setCurfew(.until(deadline), forSessionID: chatID)

        exhaustTheBudget(after: deadline)

        XCTAssertEqual(stoppedAgents, [chatID])
        XCTAssertEqual(state(of: chatID)?.has(.stoppedAgent), true)
        XCTAssertEqual(gaveUpAlerts.first?.stopped, true)

        // Once, and no more: the give-up is the end of the ladder.
        now = now.addingTimeInterval(CurfewDefaults.reinterruptSpacing + 1)
        center.evaluateAll()
        XCTAssertEqual(stoppedAgents, [chatID])
        XCTAssertEqual(gaveUpAlerts.count, 1)
    }

    // MARK: - Lifting

    func testLiftingACurfewSetOnTheSessionRemovesItsRule() {
        setPreferences(windDownMargin: nil, grace: nil)
        let deadline = now.addingTimeInterval(3_600)
        center.setCurfew(.until(deadline), forSessionID: chatID)

        now = deadline
        center.evaluateAll()
        XCTAssertEqual(state(of: chatID)?.has(.held), true)

        center.lift(sessionID: chatID)

        XCTAssertNil(store.session(withID: chatID)?.curfewRule, "the rule outlived the lift")
        XCTAssertEqual(state(of: chatID)?.has(.lifted), true)
        XCTAssertEqual(withdrawnAlerts, [chatID])

        now = deadline.addingTimeInterval(3_600)
        center.evaluateAll()
        XCTAssertEqual(
            state(of: chatID)?.receipts.filter { $0.event == .held }.count,
            1,
            "a lifted curfew held the session again"
        )
    }

    func testLiftingQuietHoursScopesToTonightsWindow() throws {
        let hours = QuietHours(isEnabled: true, startMinute: 4 * 60, endMinute: 8 * 60)
        setPreferences(windDownMargin: nil, grace: nil, quietHours: hours)

        now = try moment(day: 19, hour: 4, minute: 30)
        center.evaluateAll()
        let tonight = try moment(day: 19, hour: 4)
        XCTAssertEqual(state(of: chatID)?.deadline, tonight)
        XCTAssertEqual(state(of: chatID)?.has(.held), true)

        center.lift(sessionID: chatID)
        XCTAssertNotNil(state(of: chatID)?.liftedAt)

        now = try moment(day: 19, hour: 5)
        center.evaluateAll()
        XCTAssertEqual(
            state(of: chatID)?.receipts.filter { $0.event == .held }.count,
            1,
            "the lift did not hold for the rest of the window"
        )

        now = try moment(day: 20, hour: 4, minute: 30)
        center.evaluateAll()
        XCTAssertEqual(state(of: chatID)?.deadline, try moment(day: 20, hour: 4))
        XCTAssertEqual(
            state(of: chatID)?.has(.held),
            true,
            "the next night inherited last night's lift"
        )
        XCTAssertNil(state(of: chatID)?.liftedAt)
    }

    // MARK: - Relaunch

    func testRelaunchMaterializesTheHoldAndFailsTheWrapUpWithoutTypingAnything() throws {
        setPreferences()
        let deadline = now.addingTimeInterval(3_600)
        center.setCurfew(.until(deadline), forSessionID: chatID)

        // Threading is not running across the whole ladder, so every session is dormant.
        center = nil
        activities.removeAll()
        now = deadline.addingTimeInterval(3_600)

        let relaunched = makeCenter()
        center = relaunched
        relaunched.rebuildAndMaterialize()

        XCTAssertEqual(state(of: chatID)?.momentOf(.held), deadline, "the hold was dated the launch")
        let failure = try XCTUnwrap(
            state(of: chatID)?.receipts.last { $0.event == .windDownFailed }
        )
        XCTAssertEqual(failure.detail, CurfewReceiptWords.notRunningFailureReason)
        XCTAssertTrue(nativeInterrupts.isEmpty, "a relaunch typed into a session")
        XCTAssertTrue(terminalInterrupts.isEmpty, "a relaunch typed into a terminal")
        XCTAssertTrue(messages.messages(for: chatID).isEmpty, "a wrap-up was filed at launch")
    }

    // MARK: - Triggers

    func testWakingFromSleepReevaluatesOnTheWorkspaceCentre() {
        setPreferences(windDownMargin: nil, grace: nil)
        center.start()
        let deadline = now.addingTimeInterval(3_600)
        center.setCurfew(.until(deadline), forSessionID: chatID)

        now = deadline
        workspaceEvents.post(name: NSWorkspace.didWakeNotification, object: nil)
        settle()

        XCTAssertEqual(
            state(of: chatID)?.has(.held),
            true,
            "the wake was observed on the wrong notification centre"
        )
    }

    func testATimeZoneChangeReresolvesTheStandingWindow() throws {
        let hours = QuietHours(isEnabled: true, startMinute: 4 * 60, endMinute: 8 * 60)
        setPreferences(windDownMargin: nil, grace: nil, quietHours: hours)
        center.start()

        now = try moment(day: 19, hour: 4, minute: 30)
        events.post(name: NSNotification.Name.NSSystemTimeZoneDidChange, object: nil)
        settle()

        XCTAssertEqual(state(of: chatID)?.deadline, try moment(day: 19, hour: 4))
        XCTAssertEqual(state(of: chatID)?.has(.held), true)
    }

    // MARK: - The Test-Bundle Lock

    /// The live centre refuses to start inside a hosted test bundle, for
    /// `LimitRecoveryCoordinator`'s reason with sharper teeth: it types. A fixture — one built
    /// with dependencies of its own — starts normally, which is what every case above relies on.
    func testStartRefusesUnderAHostedTestBundle() {
        let live = makeCenter(typesIntoLiveSessions: true)
        live.start()
        XCTAssertFalse(live.isStarted)

        let fixture = makeCenter()
        fixture.start()
        XCTAssertTrue(fixture.isStarted)
    }

    // MARK: - The Stored Switch

    func testPreferencesWrittenBeforeTheStopSwitchReadAsNotify() throws {
        let encoded = try JSONEncoder().encode(CurfewPreferences.default)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "stopsAgentOnGiveUp")

        let older = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(CurfewPreferences.self, from: older)

        XCTAssertFalse(decoded.stopsAgentOnGiveUp)
        XCTAssertEqual(decoded.windDownMargin, CurfewDefaults.windDownMargin)
        XCTAssertEqual(decoded.grace, CurfewDefaults.grace)
        XCTAssertEqual(decoded.windDownText, CurfewDefaults.windDownText)
    }
}
