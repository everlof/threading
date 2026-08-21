import XCTest
@testable import Threading

/// The queue model, the turn-control boundary, and the wire shapes each provider answers with.
///
/// All pure: no transport is stood up, because every rule below is a property of the value types
/// rather than of a subprocess.
@MainActor
final class ConversationOutboxTests: XCTestCase {

    private func prompt(_ text: String) -> ConversationPrompt {
        ConversationPrompt(text: text)
    }

    // MARK: - Ordering

    func testAppendKeepsWritingOrder() {
        var outbox = ConversationOutbox()
        outbox.append(prompt("one"))
        outbox.append(prompt("two"))
        outbox.append(prompt("three"))

        XCTAssertEqual(outbox.items.map(\.summary), ["one", "two", "three"])
        XCTAssertTrue(outbox.items.allSatisfy { $0.state == .queued })
    }

    func testEmptyPromptIsRefused() {
        var outbox = ConversationOutbox()
        XCTAssertNil(outbox.append(prompt("   \n  ")))
        XCTAssertTrue(outbox.isEmpty)
    }

    func testQueueIsBounded() {
        var outbox = ConversationOutbox()
        for index in 0..<ConversationOutboxDefaults.maximumItems {
            XCTAssertNotNil(outbox.append(prompt("message \(index)")))
        }

        XCTAssertFalse(outbox.acceptsMore)
        // Refused rather than dropping the oldest: a queue that quietly forgets what somebody
        // typed is worse than one that says it is full.
        XCTAssertNil(outbox.append(prompt("one too many")))
        XCTAssertEqual(outbox.count, ConversationOutboxDefaults.maximumItems)
    }

    func testMovePendingReordersWithinTheWaitingRows() {
        var outbox = ConversationOutbox()
        outbox.append(prompt("one"))
        outbox.append(prompt("two"))
        outbox.append(prompt("three"))

        XCTAssertTrue(outbox.movePending(from: 2, to: 0))
        XCTAssertEqual(outbox.items.map(\.summary), ["three", "one", "two"])

        XCTAssertTrue(outbox.movePending(from: 0, to: 1))
        XCTAssertEqual(outbox.items.map(\.summary), ["one", "three", "two"])
    }

    /// A drag released below the last row means "last", not "error".
    func testMovePastTheEndClampsRatherThanFailing() {
        var outbox = ConversationOutbox()
        outbox.append(prompt("one"))
        outbox.append(prompt("two"))

        XCTAssertTrue(outbox.movePending(from: 0, to: 99))
        XCTAssertEqual(outbox.items.map(\.summary), ["two", "one"])
    }

    /// Reordering is stated in `pending` terms, so a row already handed over is neither moved
    /// nor jumped over — the indices the user is dragging are the ones they can see move.
    func testHandedOverRowsStayPutWhilePendingOnesReorder() {
        var outbox = ConversationOutbox()
        outbox.append(prompt("sent"))
        outbox.append(prompt("one"))
        outbox.append(prompt("two"))
        XCTAssertNotNil(outbox.handOverNext())

        XCTAssertTrue(outbox.movePending(from: 1, to: 0))
        XCTAssertEqual(outbox.items.map(\.summary), ["sent", "two", "one"])
        XCTAssertEqual(outbox.items.first?.state, .handedOver)
    }

    // MARK: - Ownership

    func testRemoveRefusesARowTheTransportAlreadyHas() {
        var outbox = ConversationOutbox()
        let id = outbox.append(prompt("one"))!
        XCTAssertNotNil(outbox.handOverNext())

        // Withdrawing a message a provider is already working on is `interrupt`, not a queue
        // gesture, so the queue declines rather than pretending.
        XCTAssertFalse(outbox.remove(id))
        XCTAssertEqual(outbox.count, 1)
    }

    func testReplaceKeepsIdentityAndPosition() {
        var outbox = ConversationOutbox()
        outbox.append(prompt("first"))
        let id = outbox.append(prompt("second"))!
        outbox.append(prompt("third"))

        XCTAssertTrue(outbox.replace(id, with: prompt("edited")))
        XCTAssertEqual(outbox.items.map(\.summary), ["first", "edited", "third"])
        XCTAssertEqual(outbox[id]?.id, id)
    }

    func testReplacingWithNothingRemovesTheRow() {
        var outbox = ConversationOutbox()
        let id = outbox.append(prompt("first"))!
        XCTAssertTrue(outbox.replace(id, with: prompt("")))
        XCTAssertTrue(outbox.isEmpty)
    }

    // MARK: - Lifecycle

    func testHandOverTakesOneAtATime() {
        var outbox = ConversationOutbox()
        outbox.append(prompt("one"))
        outbox.append(prompt("two"))

        let first = outbox.handOverNext()
        XCTAssertEqual(first?.summary, "one")
        XCTAssertEqual(first?.state, .handedOver)

        // Never concatenated: two messages written separately are two turns.
        let second = outbox.handOverNext()
        XCTAssertEqual(second?.summary, "two")
    }

    func testSettledItemsLeaveTheQueue() {
        var outbox = ConversationOutbox()
        let id = outbox.append(prompt("one"))!
        outbox.mark(id, as: .started)
        XCTAssertEqual(outbox[id]?.state, .started)

        // The conversation itself is the record of a message that was worked on; leaving a
        // completed row under the composer would be a second copy of it.
        outbox.mark(id, as: .completed)
        XCTAssertTrue(outbox.isEmpty)
    }

    func testReclaimReturnsAMessageToTheFrontOfTheWaitingRows() {
        var outbox = ConversationOutbox()
        let sent = outbox.append(prompt("interrupted"))!
        outbox.append(prompt("waiting"))
        XCTAssertNotNil(outbox.handOverNext())

        outbox.reclaim(sent)

        XCTAssertEqual(outbox.items.map(\.summary), ["interrupted", "waiting"])
        XCTAssertTrue(outbox.items.allSatisfy { $0.state.isPending })
    }

    // MARK: - Origin

    /// The queue is the user's by default. Nothing else may appear in it by accident, because
    /// the hold downstream reads this field to decide what it still lets through.
    func testAnAppendedMessageIsTheUsersUnlessSaidOtherwise() {
        var outbox = ConversationOutbox()
        let id = outbox.append(prompt("mine"))!
        XCTAssertEqual(outbox[id]?.origin, .user)
    }

    /// A curfew's wrap-up is the one item a held outbox still hands over, so the origin has to
    /// survive the hand-over rather than only the append: the drain reads it off the item it is
    /// about to give the transport, not off the call that queued it.
    func testACurfewWrapUpKeepsItsOriginThroughTheHandOver() {
        var outbox = ConversationOutbox()
        outbox.append(prompt("mine"))
        let windDown = outbox.append(prompt("wrap up and commit"), origin: .curfewWindDown)!

        XCTAssertEqual(outbox[windDown]?.origin, .curfewWindDown)
        XCTAssertEqual(outbox.pending.map(\.origin), [.user, .curfewWindDown])

        XCTAssertEqual(outbox.handOverNext()?.origin, .user)
        let handed = outbox.handOverNext()
        XCTAssertEqual(handed?.id, windDown)
        XCTAssertEqual(handed?.origin, .curfewWindDown)
        XCTAssertEqual(handed?.state, .handedOver)
    }

    /// The held drain has to read the next item's origin *before* deciding whether it may hand
    /// anything over, so peeking has to answer exactly what `handOverNext()` would take — and
    /// leave it untouched, because a row put back after being taken is indistinguishable in the
    /// rail from one a transport refused.
    func testPeekingNamesTheNextItemWithoutTakingIt() {
        var outbox = ConversationOutbox()
        XCTAssertNil(outbox.nextPending)

        let first = outbox.append(prompt("mine"))!
        outbox.append(prompt("and this"), origin: .curfewWindDown)

        XCTAssertEqual(outbox.nextPending?.id, first)
        XCTAssertEqual(outbox.nextPending?.state, .queued)
        XCTAssertEqual(outbox.nextPending?.origin, .user)
        // Asking twice is still asking: nothing was consumed.
        XCTAssertEqual(outbox.handOverNext()?.id, first)

        // Handed-over rows are history; the peek moves past them to what is still owed.
        XCTAssertEqual(outbox.nextPending?.origin, .curfewWindDown)
        XCTAssertEqual(outbox.nextPending?.id, outbox.handOverNext()?.id)
        XCTAssertNil(outbox.nextPending)
    }

    // MARK: - Turn Outcome

    func testStoppedIsNotAnError() {
        // The whole reason the flag became an enum: every provider reports a user stop through
        // its error channel, and a stopped turn is not a failure to report.
        XCTAssertFalse(TurnOutcome.stopped.isError)
        XCTAssertTrue(TurnOutcome.failed.isError)
        XCTAssertFalse(TurnOutcome.completed.isError)

        XCTAssertTrue(TurnOutcome.stopped.isIncomplete)
        XCTAssertTrue(TurnOutcome.failed.isIncomplete)
        XCTAssertFalse(TurnOutcome.completed.isIncomplete)
    }

    func testCodexTurnStatusMapsToTheThreeOutcomes() {
        XCTAssertEqual(TurnOutcome(codexTurnStatus: "completed"), .completed)
        XCTAssertEqual(TurnOutcome(codexTurnStatus: "failed"), .failed)
        XCTAssertEqual(TurnOutcome(codexTurnStatus: "interrupted"), .stopped)
        // An unknown status completes rather than being invented into a failure the user would
        // then have to explain.
        XCTAssertEqual(TurnOutcome(codexTurnStatus: "somethingNew"), .completed)
        XCTAssertEqual(TurnOutcome(codexTurnStatus: nil), .completed)
    }

    func testACPStopReasonDistinguishesCancelledFromRefused() {
        XCTAssertEqual(TurnOutcome(acpStopReason: "cancelled"), .stopped)
        XCTAssertEqual(TurnOutcome(acpStopReason: "refusal"), .failed)
        XCTAssertEqual(TurnOutcome(acpStopReason: "end_turn"), .completed)
    }

    func testAuditNameIsStableAcrossRenames() {
        // Stored records are keyed on these, so they are stated rather than derived from the
        // case names.
        XCTAssertEqual(TurnOutcome.completed.auditName, "completed")
        XCTAssertEqual(TurnOutcome.failed.auditName, "failed")
        XCTAssertEqual(TurnOutcome.stopped.auditName, "stopped")
    }

    func testStoppedTurnFilesAsInterruptedRatherThanFailed() {
        XCTAssertEqual(ExecutionAuditRecord.Phase(turnOutcome: .stopped), .interrupted)
        XCTAssertEqual(ExecutionAuditRecord.Phase(turnOutcome: .failed), .failed)
        XCTAssertEqual(ExecutionAuditRecord.Phase(turnOutcome: .completed), .completed)
    }

    // MARK: - Claude Wire

    func testClaudeLifecycleRecordReadsTheIdentifierWeMinted() {
        let id = ConversationMessageID()
        let line = """
        {"type":"command_lifecycle","command_uuid":"\(id.wireValue)","state":"started",\
        "uuid":"11111111-1111-1111-1111-111111111111","session_id":"abc"}
        """

        let record = ClaudeMessageLifecycleRecord.parse(line)
        XCTAssertEqual(record?.id, id)
        XCTAssertEqual(record?.state, .started)
    }

    /// The CLI's `queued` means "the provider has it and has not begun", which is this side's
    /// `handedOver` — the queue's own `queued` means "still ours".
    func testClaudeQueuedStateIsHandedOverHere() {
        let id = ConversationMessageID()
        let line = """
        {"type":"command_lifecycle","command_uuid":"\(id.wireValue)","state":"queued"}
        """
        XCTAssertEqual(ClaudeMessageLifecycleRecord.parse(line)?.state, .handedOver)
    }

    func testUnknownLifecycleStateIsDroppedRatherThanGuessed() {
        let id = ConversationMessageID()
        let line = """
        {"type":"command_lifecycle","command_uuid":"\(id.wireValue)","state":"reticulating"}
        """
        XCTAssertNil(ClaudeMessageLifecycleRecord.parse(line))
    }

    func testOrdinaryStreamLinesAreNotLifecycleRecords() {
        XCTAssertNil(ClaudeMessageLifecycleRecord.parse(
            #"{"type":"assistant","message":{"role":"assistant","content":[]}}"#
        ))
        XCTAssertNil(ClaudeMessageLifecycleRecord.parse("not json at all"))
    }

    func testInterruptControlRequestWireShape() throws {
        let data = try XCTUnwrap(ClaudeControlRequest.line(
            subtype: ClaudeControlRequest.interrupt,
            requestID: "threading-ctrl-1",
            body: [:]
        ))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(object["type"] as? String, "control_request")
        XCTAssertEqual(object["request_id"] as? String, "threading-ctrl-1")
        let request = try XCTUnwrap(object["request"] as? [String: Any])
        XCTAssertEqual(request["subtype"] as? String, "interrupt")
    }

    func testCancelAsyncMessageCarriesTheUUID() throws {
        let id = ConversationMessageID()
        let data = try XCTUnwrap(ClaudeControlRequest.line(
            subtype: ClaudeControlRequest.cancelAsyncMessage,
            requestID: "threading-ctrl-2",
            body: ["uuid": id.wireValue]
        ))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let request = try XCTUnwrap(object["request"] as? [String: Any])

        XCTAssertEqual(request["subtype"] as? String, "cancel_async_message")
        XCTAssertEqual(request["uuid"] as? String, id.wireValue)
    }

    // MARK: - Receipts

    /// Two cases rather than an array plus a flag: an empty list from a build that reports
    /// nothing must not read as "nothing survived".
    func testAcknowledgedIsNotAnEmptyReport() {
        XCTAssertNotEqual(InterruptReceipt.acknowledged, .reported(stillQueued: []))
        XCTAssertTrue(InterruptReceipt.acknowledged.didStop)
        XCTAssertTrue(InterruptReceipt.reported(stillQueued: []).didStop)
        XCTAssertFalse(InterruptReceipt.failed(reason: "no").didStop)
    }

    func testSteerAvailabilityStatesTheReason() {
        XCTAssertTrue(SteerAvailability.available.isAvailable)
        XCTAssertFalse(SteerAvailability.unavailable(.unsupported).isAvailable)
        XCTAssertNotEqual(
            SteerAvailability.unavailable(.unsupported),
            .unavailable(.turnKindRefusesSteering)
        )
    }
}
