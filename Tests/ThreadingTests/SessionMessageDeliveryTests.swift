import XCTest

@testable import Threading

/// What a session's surface will and will not take, and — the reason this file exists — the
/// difference between a conversation that *exists* and one that is *running*.
///
/// `TerminalContainerViewController` deliberately keeps a `ConversationViewController` after its
/// agent exits, so `AgentRuntime.conversation(for:)` answers for sessions with no process.
/// `SessionMessageDelivery` used to take that answer as a live surface: `submit` fell through
/// `stream.canSend` into `enqueue`, which accepted the text, and the call reported `.sentNow` for
/// a message no transport had. The text then died in an outbox the next resume discards.
///
/// These are hostile to write any other way — the states are held by a singleton runtime — so the
/// fixture builds a real conversation through the same door the app uses and simply never
/// launches it, which is exactly the shape of a session whose agent has exited.
@MainActor
final class SessionMessageDeliveryTests: XCTestCase {

    // MARK: - Fixture

    private var sessionID: SessionID?

    override func tearDown() {
        if let sessionID {
            AgentRuntime.shared.discard(sessionID: sessionID)
        }
        sessionID = nil
        super.tearDown()
    }

    /// A cached conversation that was never launched: `stream.isRunning` is false, which is the
    /// state a session is in from the moment its agent exits until the view is replaced.
    @discardableResult
    private func makeUnlaunchedConversation() -> SessionID {
        let session = AgentSession(kind: .claude, title: "Exited conversation")
        var project = Project(
            name: "Delivery",
            folderURL: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        )
        project.sessions = [session]

        AgentRuntime.shared.makeConversation(for: session, in: project)
        sessionID = session.id
        return session.id
    }

    // MARK: - The Regression

    func testAKeptButExitedConversationIsNotALiveSurface() {
        let id = makeUnlaunchedConversation()

        XCTAssertEqual(
            SessionMessageDelivery.deliver("Pick this up again", to: id),
            .noLiveSurface,
            """
            A conversation whose agent is not running must refuse. Answering .sentNow here is \
            how send_to_session lost messages: the caller is told it arrived, and the text is \
            discarded with the outbox on the next resume.
            """
        )
    }

    func testAKeptButExitedConversationReportsItselfDormant() {
        let id = makeUnlaunchedConversation()

        XCTAssertEqual(
            SessionMessageDelivery.surface(for: id),
            .dormant,
            """
            list_sessions must not advertise a chat surface that deliver() will refuse — the \
            two answers come from the same fact and have to agree.
            """
        )
    }

    // MARK: - The Ordinary Answers

    func testASessionWithNoSurfaceAtAllIsDormant() {
        let orphan = SessionID()

        XCTAssertEqual(SessionMessageDelivery.surface(for: orphan), .dormant)
        XCTAssertEqual(SessionMessageDelivery.deliver("Anyone there?", to: orphan), .noLiveSurface)
    }

    func testRefusingLeavesNothingBehindToDeliverLater() {
        let id = makeUnlaunchedConversation()
        _ = SessionMessageDelivery.deliver("Queued into the void", to: id)

        guard let conversation = AgentRuntime.shared.conversation(for: id) else {
            return XCTFail("The conversation should still be cached — refusing is not discarding")
        }
        XCTAssertTrue(
            conversation.outbox.isEmpty,
            """
            A refused delivery must not park the text in the conversation's queue. That queue \
            belongs to a live transport; filling it from a refusal is the silent loss this \
            whole check exists to stop.
            """
        )
    }

    // MARK: - The Rules, Against Fakes

    // The cases above hold the live lookups; these hold the rules themselves, through the
    // injectable core — the outcome must be the surface's own answer, never inferred from
    // beside it, which is the family both shipped bugs belonged to.

    private final class FakeChat: AppMessageReceiving {
        var isRunning: Bool
        var acceptance: AppMessageAcceptance
        var steerAnswer: AppMessageSteerResult
        var accepted: [ConversationPrompt] = []
        var acceptedOrigins: [ConversationOutbox.Item.Origin] = []
        var acceptedAttachmentIDs: [[String]] = []
        var steered: [ConversationPrompt] = []

        init(
            isRunning: Bool = true,
            acceptance: AppMessageAcceptance = .handedToTurn,
            steerAnswer: AppMessageSteerResult = .steered
        ) {
            self.isRunning = isRunning
            self.acceptance = acceptance
            self.steerAnswer = steerAnswer
        }

        func acceptAppMessage(
            _ prompt: ConversationPrompt,
            origin: ConversationOutbox.Item.Origin,
            attachmentIDs: [String]
        ) -> AppMessageAcceptance {
            accepted.append(prompt)
            acceptedOrigins.append(origin)
            acceptedAttachmentIDs.append(attachmentIDs)
            return acceptance
        }

        func steerAppMessage(_ prompt: ConversationPrompt) -> AppMessageSteerResult {
            steered.append(prompt)
            return steerAnswer
        }
    }

    private final class TypedText {
        var texts: [String] = []
    }

    private func terminal(
        midTurn: Bool = false,
        verifiedBoot: Bool = true,
        requiresVerifiedBoot: Bool = true,
        confirmsAcceptance: Bool = true,
        deliveryInFlight: Bool = false,
        into typed: TypedText
    ) -> SessionMessageDelivery.TerminalTarget {
        SessionMessageDelivery.TerminalTarget(
            isMidTurn: midTurn,
            hasVerifiedBoot: verifiedBoot,
            requiresVerifiedBoot: requiresVerifiedBoot,
            hasDeliveryInFlight: deliveryInFlight,
            type: { typed.texts.append($0) },
            awaitAcceptance: { $0(confirmsAcceptance) }
        )
    }

    /// A PTY takes one message at a time. The text is pasted at once and the Return follows a
    /// beat later, so a second delivery inside that window would paste onto the same composer
    /// line and the CLI would receive both as one prompt — while the second caller was told its
    /// own message had been sent. Two watches settling on one edge is enough to reach it.
    func testATerminalMidDeliveryRefusesASecondMessageRatherThanSharingTheLine() {
        let typed = TypedText()
        let outcome = SessionMessageDelivery.deliver(
            ConversationPrompt(text: "Second"),
            chat: nil,
            terminal: terminal(deliveryInFlight: true, into: typed)
        )

        XCTAssertEqual(outcome, .busyTerminal)
        XCTAssertTrue(typed.texts.isEmpty, "the second message must not join the first one's line")
    }

    // MARK: - The Receipt

    func testATypedDeliveryIsOnlySentOnceTheSessionConfirmsATurnBegan() {
        let typed = TypedText()
        var outcome: SessionMessageDelivery.Outcome?
        SessionMessageDelivery.deliver(
            ConversationPrompt(text: "Hi"),
            chat: nil,
            terminal: terminal(confirmsAcceptance: true, into: typed)
        ) { outcome = $0 }

        XCTAssertEqual(outcome, .sentNow)
        XCTAssertEqual(typed.texts, ["Hi"])
    }

    func testAnUnconfirmedTypedDeliverySaysSoInsteadOfClaimingSuccess() {
        let typed = TypedText()
        var outcome: SessionMessageDelivery.Outcome?
        SessionMessageDelivery.deliver(
            ConversationPrompt(text: "Hi"),
            chat: nil,
            terminal: terminal(confirmsAcceptance: false, into: typed)
        ) { outcome = $0 }

        XCTAssertEqual(
            outcome, .typedUnconfirmed,
            """
            The first live delivery was typed into a session mid-/compact and discarded by \
            the redraw while the caller was told it was sent. "We pressed Return" is a fact \
            about our keystrokes; only the session's own turn report proves arrival.
            """
        )
        XCTAssertEqual(typed.texts, ["Hi"], "The text was typed; what is missing is the receipt")
    }

    func testAChatDeliveryNeedsNoReceipt() {
        let chat = FakeChat(acceptance: .handedToTurn)
        var outcome: SessionMessageDelivery.Outcome?
        SessionMessageDelivery.deliver(
            ConversationPrompt(text: "Hi"),
            chat: chat,
            terminal: nil
        ) { outcome = $0 }

        XCTAssertEqual(outcome, .sentNow, "A chat acceptance is already the surface's own answer")
    }

    func testChatOutcomesAreTheSurfacesOwnAnswer() {
        let expectations: [(AppMessageAcceptance, SessionMessageDelivery.Outcome)] = [
            (.handedToTurn, .sentNow),
            (.queuedBehindTurn, .queuedBehindTurn),
            (.refused(.queueFull), .notTaken),
            (.refused(.inputHeldRemotely), .notTaken),
        ]
        for (acceptance, expected) in expectations {
            let chat = FakeChat(acceptance: acceptance)
            let outcome = SessionMessageDelivery.deliver(
                ConversationPrompt(text: "Hi"),
                chat: chat,
                terminal: nil
            )
            XCTAssertEqual(outcome, expected, "\(acceptance) must surface as \(expected)")
            XCTAssertEqual(chat.accepted.count, 1)
        }
    }

    func testAChatDeliveryCarriesAttachmentIdentityToItsQueueOwner() {
        let chat = FakeChat(acceptance: .queuedBehindTurn)

        let outcome = SessionMessageDelivery.deliver(
            ConversationPrompt(text: "Review the screenshots"),
            chat: chat,
            terminal: nil,
            attachmentIDs: ["shot-one", "shot-two"]
        )

        XCTAssertEqual(outcome, .queuedBehindTurn)
        XCTAssertEqual(chat.acceptedAttachmentIDs, [["shot-one", "shot-two"]])
    }

    func testADeadChatIsNeverHandedTheMessage() {
        let chat = FakeChat(isRunning: false)
        let outcome = SessionMessageDelivery.deliver(
            ConversationPrompt(text: "Hi"),
            chat: chat,
            terminal: nil
        )
        XCTAssertEqual(outcome, .noLiveSurface)
        XCTAssertTrue(chat.accepted.isEmpty)
    }

    func testATerminalMidTurnRefusesWithoutTyping() {
        let typed = TypedText()
        let outcome = SessionMessageDelivery.deliver(
            ConversationPrompt(text: "Hi"),
            chat: nil,
            terminal: terminal(midTurn: true, into: typed)
        )
        XCTAssertEqual(outcome, .busyTerminal)
        XCTAssertTrue(typed.texts.isEmpty)
    }

    func testABootingTerminalRefusesUntilItsOwnReportsProveTheCLIIsUp() {
        let typed = TypedText()
        let outcome = SessionMessageDelivery.deliver(
            ConversationPrompt(text: "Hi"),
            chat: nil,
            terminal: terminal(verifiedBoot: false, requiresVerifiedBoot: true, into: typed)
        )
        XCTAssertEqual(
            outcome, .busyTerminal,
            """
            isRunning flips at PTY spawn, seconds before the CLI's composer exists; until the \
            session's own lifecycle reports arrive, typed text lands in a login shell.
            """
        )
        XCTAssertTrue(typed.texts.isEmpty)
    }

    func testTheBootLatchHearsSessionStartAndResetsPerProcess() {
        let tracker = SessionActivityTracker()
        XCTAssertFalse(tracker.hasHeardFromProcess)

        tracker.noteSessionStarted()
        XCTAssertTrue(
            tracker.hasHeardFromProcess,
            "SessionStart is the earliest proof the CLI is up — dropped, every session idle since an app relaunch read as still-booting"
        )
        XCTAssertFalse(
            tracker.reportsOwnActivity,
            "Hearing a boot must not switch off the output heuristic; only turn reports may"
        )

        tracker.markRunning()
        XCTAssertFalse(tracker.hasHeardFromProcess, "A new process proves itself over again")

        tracker.noteTurnStarted()
        XCTAssertTrue(tracker.hasHeardFromProcess, "Any turn report implies the process is up")
    }

    func testARuntimeThatCannotVerifyItsBootIsTakenAtItsWord() {
        let typed = TypedText()
        let outcome = SessionMessageDelivery.deliver(
            ConversationPrompt(text: "Hi"),
            chat: nil,
            terminal: terminal(verifiedBoot: false, requiresVerifiedBoot: false, into: typed)
        )
        XCTAssertEqual(outcome, .sentNow)
        XCTAssertEqual(typed.texts, ["Hi"], "A runtime with no bridge must not be refused forever")
    }

    // MARK: - Steering

    func testASteerPassesTheTransportsAnswerThroughUnflattened() {
        let expectations: [(AppMessageSteerResult, SessionMessageDelivery.SteerOutcome)] = [
            (.steered, .steered),
            (.refused(.noActiveTurn), .refused(.noActiveTurn)),
            (.refused(.turnKindRefusesSteering), .refused(.turnKindRefusesSteering)),
            (.refused(.unsupported), .refused(.unsupported)),
            (.inputHeldRemotely, .notTaken),
        ]
        for (answer, expected) in expectations {
            let chat = FakeChat(steerAnswer: answer)
            XCTAssertEqual(
                SessionMessageDelivery.steer(ConversationPrompt(text: "Also run the tests"), chat: chat),
                expected,
                "\(answer) must surface as \(expected) — never downgraded to a queue"
            )
        }
    }

    func testASteerNeedsALiveChatNotATerminalOrAGhost() {
        XCTAssertEqual(
            SessionMessageDelivery.steer(ConversationPrompt(text: "Hi"), chat: nil),
            .targetNotLiveChat
        )
        let dead = FakeChat(isRunning: false)
        XCTAssertEqual(
            SessionMessageDelivery.steer(ConversationPrompt(text: "Hi"), chat: dead),
            .targetNotLiveChat
        )
        XCTAssertTrue(dead.steered.isEmpty, "A dead conversation must never be handed the steer")
    }

    /// One turn report is evidence for **one** message. Resolving every outstanding waiter for
    /// a session handed the same receipt to each of them: two deliveries outstanding, one
    /// `UserPromptSubmit` arrives, and both callers hear `.sentNow` while the CLI accepted one.
    func testOneTurnReportResolvesOneReceiptNotEveryOutstandingOne() {
        let runtime = AgentRuntime.shared
        let session = SessionID()
        var answers: [Bool] = []

        runtime.awaitReportedTurnStart(sessionID: session, timeout: 60) { answers.append($0) }
        runtime.awaitReportedTurnStart(sessionID: session, timeout: 60) { answers.append($0) }

        guard let report = HookLifecycleReport(
            sessionID: session,
            event: .turnStarted,
            payload: [:]
        ) else {
            return XCTFail("Expected a turn-started report")
        }
        runtime.applyLifecycle(report)

        XCTAssertEqual(answers, [true], "the second waiter must not spend the first one's receipt")
    }
}
