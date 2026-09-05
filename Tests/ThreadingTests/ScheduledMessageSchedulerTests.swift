import AppKit
import XCTest

@testable import Threading

/// When a scheduled send is announced, when it is quietly held back, and — the case the whole
/// class exists for — what happens to a moment that passed while the app was not running.
///
/// The scheduler is driven with an injected clock, an injected store and two injected
/// notification centres, so none of this waits on a real timer or touches the running app's own
/// event traffic. The second centre is not a nicety: workspace sleep and wake notifications are
/// posted there and never on `.default`, and a scheduler wired to one centre would compile while
/// silently losing the inactivity boundary.
@MainActor
final class ScheduledMessageSchedulerTests: XCTestCase {

    // MARK: - Fixture

    private var directory: URL!
    private var center: NotificationCenter!
    private var workspaceCenter: NotificationCenter!
    private var store: ScheduledMessageStore!
    private var clock: Date!
    private var reportingSessions: Set<SessionID> = []
    private var activities: [SessionID: SessionActivity] = [:]
    private var missingSessions: Set<SessionID> = []

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
        activities = [:]
        missingSessions = []
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
            runtime: { [unowned self] id in
                .test(
                    activity: self.activities[id] ?? .idle,
                    reportsOwnTurns: self.reportingSessions.contains(id)
                )
            },
            sessionExists: { [unowned self] in !self.missingSessions.contains($0) }
        )
    }

    private func postRuntimeChange(_ sessionID: SessionID) {
        let current = SessionRuntimeSnapshot.test(
            activity: activities[sessionID] ?? .idle,
            reportsOwnTurns: reportingSessions.contains(sessionID)
        )
        center.post(SessionRuntimeDidChange(
            sessionID: sessionID,
            transition: SessionRuntimeTransition(previous: .dormant, current: current),
            cause: nil
        ))
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

    @discardableResult
    private func schedule(
        whenSessionFinishes watchedSessionID: SessionID,
        to targetSessionID: SessionID = SessionID()
    ) -> ScheduledMessage {
        let message = ScheduledMessage(
            createdAt: clock,
            whenSessionFinishes: watchedSessionID,
            target: .session(targetSessionID),
            text: "Carry on with the finished result"
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

    // MARK: - Another Conversation Finishing

    func testAnnouncesAFinishTriggeredSendOnTheAuthoritativeTurnEnd() {
        let watched = SessionID()
        reportingSessions.insert(watched)
        activities[watched] = .working
        let recorder = DueRecorder(center: center)
        let message = schedule(whenSessionFinishes: watched)
        let scheduler = makeScheduler()
        scheduler.start()

        XCTAssertTrue(recorder.ids.isEmpty)
        activities[watched] = .needsAttention
        postRuntimeChange(watched)

        XCTAssertEqual(recorder.ids, [message.id])
    }

    func testDoesNotReadAQuestionInsideTheTurnAsFinished() {
        let watched = SessionID()
        reportingSessions.insert(watched)
        activities[watched] = .working
        let recorder = DueRecorder(center: center)
        schedule(whenSessionFinishes: watched)
        let scheduler = makeScheduler()
        scheduler.start()

        activities[watched] = .awaitingUser
        postRuntimeChange(watched)

        XCTAssertTrue(recorder.ids.isEmpty)
    }

    func testDoesNotTriggerFromInferredTerminalQuietness() {
        let watched = SessionID()
        activities[watched] = .working
        let recorder = DueRecorder(center: center)
        schedule(whenSessionFinishes: watched)
        let scheduler = makeScheduler()
        scheduler.start()

        activities[watched] = .idle
        postRuntimeChange(watched)

        XCTAssertTrue(
            recorder.ids.isEmpty,
            "A terminal going quiet is not strong enough evidence for an unattended send"
        )
    }

    func testASettledSnapshotClosesThePickerRace() {
        let watched = SessionID()
        activities[watched] = .idle
        let recorder = DueRecorder(center: center)
        let message = schedule(whenSessionFinishes: watched)
        let scheduler = makeScheduler()
        scheduler.start()

        scheduler.evaluateCompletion(of: watched, acceptsSettledSnapshot: true)

        XCTAssertEqual(recorder.ids, [message.id])
    }

    func testRelaunchDoesNotPretendADormantSessionFinishedWhileThreadingWasClosed() {
        let watched = SessionID()
        reportingSessions.insert(watched)
        activities[watched] = .dormant
        let recorder = DueRecorder(center: center)
        let message = schedule(whenSessionFinishes: watched)

        makeScheduler().start()

        XCTAssertTrue(recorder.ids.isEmpty)
        XCTAssertEqual(store[message.id]?.state, .armed)
    }

    func testAnIdleNotificationAfterRelaunchIsNotInventedIntoAFinishEdge() {
        let watched = SessionID()
        reportingSessions.insert(watched)
        activities[watched] = .idle
        let recorder = DueRecorder(center: center)
        let message = schedule(whenSessionFinishes: watched)
        let scheduler = makeScheduler()
        scheduler.start()

        // SessionStart raises this even when the activity did not move. The scheduler did not
        // witness the old turn running, so an idle snapshot cannot prove that turn just ended.
        postRuntimeChange(watched)
        XCTAssertTrue(recorder.ids.isEmpty)
        XCTAssertEqual(store[message.id]?.state, .armed)

        // A later turn is observed on both sides of the boundary and can satisfy the condition.
        activities[watched] = .working
        postRuntimeChange(watched)
        activities[watched] = .idle
        postRuntimeChange(watched)

        XCTAssertEqual(recorder.ids, [message.id])
    }

    func testWaitingDeliveryStaysSatisfiedIfTheWatchedConversationStartsAgain() {
        let watched = SessionID()
        let target = SessionID()
        reportingSessions.formUnion([watched, target])
        activities[watched] = .working
        activities[target] = .working
        let recorder = DueRecorder(center: center)
        let message = schedule(whenSessionFinishes: watched, to: target)
        let scheduler = makeScheduler()
        scheduler.start()

        activities[watched] = .idle
        postRuntimeChange(watched)
        scheduler.noteWaiting(message.id)
        store.setState(.waiting("Waiting for the destination"), for: message.id)

        activities[watched] = .working
        activities[target] = .idle
        postRuntimeChange(target)

        XCTAssertEqual(
            recorder.ids,
            [message.id, message.id],
            "Once the finish happened, delivery waits only for its destination"
        )
    }

    func testADeletedWatchedConversationFailsWithoutDroppingTheMessage() {
        let watched = SessionID()
        missingSessions.insert(watched)
        let message = schedule(whenSessionFinishes: watched)
        let scheduler = makeScheduler()
        scheduler.start()

        scheduler.evaluateCompletion(of: watched, acceptsSettledSnapshot: true)

        guard case .failed = store[message.id]?.state else {
            return XCTFail("The message should remain for the user with a reason")
        }
    }

    func testFinishPickerOffersOnlyWorkingSessionsWithExactTurnBoundaries() {
        let exact = AgentSession(
            kind: .claude,
            title: "Exact working turn",
            accountHandle: .named("work")
        )
        let inferred = AgentSession(kind: .grok, title: "Only inferred")
        let idle = AgentSession(kind: .codex, title: "Already idle")
        var archived = AgentSession(kind: .claude, title: "Archived")
        archived.isArchived = true
        var project = Project(
            name: "Scheduler",
            folderURL: URL(fileURLWithPath: NSTemporaryDirectory())
        )
        project.sessions = [exact, inferred, idle, archived]

        let candidates = ScheduledFinishCandidates.make(
            projects: [project],
            runtime: { id in
                .test(
                    activity: id == idle.id ? .idle : .working,
                    reportsOwnTurns: id != inferred.id
                )
            }
        )

        XCTAssertEqual(candidates.map(\.id), [exact.id])
        XCTAssertEqual(candidates.first?.projectName, "Scheduler")
        XCTAssertEqual(candidates.first?.agentName, "Claude Code · work")
    }

    /// A candidate used to carry its provider as a raw `String` and re-derive it with
    /// `AgentKind(rawValue:) ?? .claude`. The type now holds an `AgentKind`, so a value that
    /// cannot name a provider is unrepresentable rather than silently becoming Claude.
    ///
    /// That guarantee is the compiler's, not this test's — and this test would have passed
    /// before the change too, because the one construction path fed `session.kind.rawValue`
    /// straight back in and always round-tripped. What it pins is the behaviour the fallback
    /// would have hidden had any other path ever produced an unrecognised string: every
    /// provider reports itself, for every case the enum has.
    func testFinishCandidateReportsItsOwnProviderRatherThanFallingBackToClaude() {
        var project = Project(
            name: "Providers",
            folderURL: URL(fileURLWithPath: NSTemporaryDirectory())
        )
        project.sessions = AgentKind.allCases.map {
            AgentSession(kind: $0, title: "Turn in flight on \($0.displayName)")
        }

        let candidates = ScheduledFinishCandidates.make(
            projects: [project],
            runtime: { _ in .test(activity: .working) }
        )

        // Driven from `allCases`, so a provider added later is covered without editing this.
        XCTAssertEqual(candidates.map(\.agentKind), AgentKind.allCases)
        for (session, candidate) in zip(project.sessions, candidates) {
            XCTAssertEqual(candidate.agentKind, session.kind)
        }
    }

    func testFinishPickerScansStoredSessionsAsValuesAndBuildsOnlyLiveCandidates() {
        var project = Project(
            name: "Stress",
            folderURL: URL(fileURLWithPath: NSTemporaryDirectory())
        )
        project.sessions = (0..<5_000).map {
            AgentSession(kind: .claude, title: "Conversation \($0)")
        }
        let working = Set(project.sessions.suffix(3).map(\.id))
        var runtimeReads = 0

        let candidates = ScheduledFinishCandidates.make(
            projects: [project],
            runtime: { id in
                runtimeReads += 1
                return .test(activity: working.contains(id) ? .working : .idle)
            }
        )

        XCTAssertEqual(runtimeReads, 5_000)
        XCTAssertEqual(candidates.map(\.id), Array(project.sessions.suffix(3).map(\.id)))
    }

    func testWakingFromSleepMarksTheMomentMissedInsteadOfSendingItLate() {
        let recorder = DueRecorder(center: center)
        let message = schedule(dueIn: 3_600)
        let scheduler = makeScheduler()
        scheduler.start()

        workspaceCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        clock = start.addingTimeInterval(7_200)
        // If activation is delivered before the wake edge, the sleep receipt must still prevent
        // an unattended late send.
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        XCTAssertTrue(recorder.ids.isEmpty)

        workspaceCenter.post(name: NSWorkspace.didWakeNotification, object: nil)

        XCTAssertTrue(recorder.ids.isEmpty, "A sleeping timer must never become a late send")
        XCTAssertEqual(recorder.missed, [[message.id]])
        XCTAssertEqual(store[message.id]?.state, .missed)
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

    func testAWaitingDeliveryAlsoBecomesMissedAcrossRelaunch() {
        let recorder = DueRecorder(center: center)
        let message = schedule(dueIn: 60)
        XCTAssertTrue(store.setState(.waiting("The destination was busy"), for: message.id))

        clock = start.addingTimeInterval(2 * 86_400)
        makeScheduler().start()

        XCTAssertEqual(recorder.missed, [[message.id]])
        XCTAssertTrue(recorder.ids.isEmpty)
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

        postRuntimeChange(session)

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

        postRuntimeChange(session)

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

    func testATimeZoneChangeReDerivesWhatTheUserActuallyAskedFor() throws {
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
            local.component(.hour, from: try XCTUnwrap(store[message.id]!.dueAt)),
            try XCTUnwrap(message.intendedWallClock).hour,
            "The record keeps what was said as well as when it resolved to; this is why"
        )
    }
}

/// The finish-trigger sheet is a real external-cardinality picker, not a menu with one view per
/// session. These tests hold its search/selection contract and exercise the same loaded view
/// through live theme changes, including the runtime theme-boundary audit.
@MainActor
final class ScheduledFinishPickerTests: XCTestCase {

    func testScheduledStartReceiptSaysItWillStartAutomatically() {
        let message = ScheduledMessage(
            whenSessionFinishes: SessionID(),
            target: .session(SessionID()),
            text: "Finish the release"
        )

        XCTAssertEqual(
            ScheduledTiming.automaticStartSentence(for: message),
            "Scheduled · starts automatically when “Conversation” finishes"
        )
    }

    func testScheduledConversationNamesAUsageResetAndItsExpectedMoment() {
        let now = Date(timeIntervalSince1970: 1_775_000_000)
        let dueAt = now.addingTimeInterval(3_600)
        let message = ScheduledMessage(
            dueAt: dueAt,
            target: .session(SessionID()),
            text: "Continue after reset",
            anchor: .usageWindowReset(windowID: "five-hour")
        )

        let sentence = ScheduledTiming.automaticStartCauseSentence(for: message, from: now)

        XCTAssertTrue(sentence.hasPrefix("Starts automatically after the usage window resets"))
        XCTAssertTrue(sentence.contains(UsageFormat.absolute(dueAt, from: now)))
        XCTAssertTrue(sentence.contains(UsageFormat.remaining(until: dueAt, from: now)))
    }

    func testScheduledConversationNamesTheFinishTriggerAsItsCause() {
        let message = ScheduledMessage(
            whenSessionFinishes: SessionID(),
            target: .session(SessionID()),
            text: "Review it"
        )

        XCTAssertEqual(
            ScheduledTiming.automaticStartCauseSentence(for: message),
            "Starts automatically when “Conversation” finishes"
        )
    }

    func testScheduleMenuOffersTheFinishPickerOnlyWhenItHasAReliableCandidate() throws {
        var choseFinish = false
        let enabled = ScheduleMenu.entries(canWaitForConversation: true) { choice in
            if case .whenConversationFinishes = choice { choseFinish = true }
        }
        let enabledItem = try XCTUnwrap(item(
            titled: L10n.string("When a conversation finishes…"),
            in: enabled
        ))
        XCTAssertTrue(enabledItem.isEnabled)
        enabledItem.onChoose?()
        XCTAssertTrue(choseFinish)

        let disabled = ScheduleMenu.entries(canWaitForConversation: false) { _ in }
        let disabledItem = try XCTUnwrap(item(
            titled: L10n.string("When a conversation finishes…"),
            in: disabled
        ))
        XCTAssertFalse(disabledItem.isEnabled)
        XCTAssertEqual(
            disabledItem.subtitle,
            L10n.string("No conversations with reliable finish signals are working.")
        )
    }

    func testSearchSelectsAndReturnsAWorkingConversation() {
        let build = candidate(title: "Build the release", project: "Threading", kind: .codex)
        let docs = candidate(title: "Rewrite the guide", project: "Website", kind: .claude)
        let picker = ScheduledFinishPickerViewController(candidates: [build, docs])
        picker.loadView()

        picker.updateSearchQuery("website")
        waitUntil { picker.visibleSessionIDs == [docs.id] }

        XCTAssertEqual(picker.selectedSessionIDForTesting, docs.id)
        XCTAssertTrue(picker.scheduleButtonIsEnabledForTesting)

        var picked: ScheduledFinishCandidate?
        picker.onPick = { picked = $0 }
        picker.confirm()
        XCTAssertEqual(picked, docs)
    }

    func testAnEmptySearchResultCannotScheduleTheWrongConversation() {
        let picker = ScheduledFinishPickerViewController(candidates: [
            candidate(title: "Build the release", project: "Threading", kind: .codex)
        ])
        picker.loadView()

        picker.updateSearchQuery("no such conversation")
        waitUntil { picker.visibleSessionIDs.isEmpty }

        XCTAssertNil(picker.selectedSessionIDForTesting)
        XCTAssertFalse(picker.scheduleButtonIsEnabledForTesting)
    }

    func testPickerPassesTheThemeBoundaryAndRendersDistinctLiveThemes() throws {
        let previous = AppThemeLibrary.current
        defer { AppThemeLibrary.apply(previous) }

        let picker = ScheduledFinishPickerViewController(candidates: [
            candidate(title: "Build the release", project: "Threading", kind: .codex),
            candidate(title: "Check localization", project: "Threading", kind: .claude),
            candidate(title: "Publish the guide", project: "Website", kind: .claude)
        ])
        picker.loadView()
        picker.view.layoutSubtreeIfNeeded()

        let table = try XCTUnwrap(
            descendants(of: picker.view).compactMap { $0 as? ThemedTableView }.first
        )
        XCTAssertEqual(table.accessibilityLabel(), L10n.string("Working conversations"))
        XCTAssertEqual(ThemeBoundaryAudit.violations(in: picker.view), [])

        let directory = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"]
            .flatMap { $0.isEmpty ? nil : $0 }
            .map {
            URL(fileURLWithPath: $0)
        } ?? URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ThreadingRenders", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let variants: [(String, AppTheme, NSAppearance.Name)] = [
            ("system-light", .system, .aqua),
            ("system-dark", .system, .darkAqua),
            ("cyberpunk", AppThemeStyles.cyberpunk, .darkAqua),
            ("swiss", AppThemeStyles.swissMinimalist, .aqua)
        ]
        var renders = Set<Data>()
        for (name, theme, appearance) in variants {
            // One loaded surface receives each change. Recreating it here would not prove the
            // sheet follows a live theme switch while it is open.
            AppThemeLibrary.apply(theme)
            picker.view.appearance = NSAppearance(named: appearance)
            picker.view.layoutSubtreeIfNeeded()
            let twoLines = Design.Typography.lineHeight(of: Design.Typography.body())
                + Design.Typography.lineHeight(of: Design.Typography.subheading())
                + Design.Spacing.hairline
                + 2 * Design.Spacing.small
            XCTAssertGreaterThanOrEqual(
                table.rowHeight,
                twoLines,
                "\(name): adjacent conversation rows overlap"
            )
            let data = try renderedPNG(of: picker.view)
            renders.insert(data)
            try data.write(to: directory.appendingPathComponent("scheduled-finish-\(name).png"))
        }

        XCTAssertEqual(renders.count, variants.count, "the open picker ignored a theme change")
    }

    private func candidate(
        title: String,
        project: String,
        kind: AgentKind
    ) -> ScheduledFinishCandidate {
        ScheduledFinishCandidate(
            id: SessionID(),
            title: title,
            projectName: project,
            agentName: kind.displayName,
            agentKind: kind
        )
    }

    private func waitUntil(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), "the detached picker filter did not publish its result")
    }

    private func descendants(of root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(descendants)
    }

    private func item(
        titled title: String,
        in entries: [ThemedMenuEntry]
    ) -> ThemedMenuItem? {
        entries.compactMap { entry in
            guard case .item(let item) = entry, item.title == title else { return nil }
            return item
        }.first
    }

    private func renderedPNG(of view: NSView) throws -> Data {
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }
}
