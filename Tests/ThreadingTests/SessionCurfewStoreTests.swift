import Foundation
import XCTest

@testable import Threading

/// Where a curfew is *kept*: the two records that carry it, the store writes that change it, and
/// the readers that ask those records which one governs a conversation.
///
/// Against a private `ProjectStore` over a scratch directory, never `ProjectStore.shared`: this
/// suite is hosted in the app, so the singleton here is the developer's own database.
@MainActor
final class SessionCurfewStoreTests: XCTestCase {

    // MARK: - Fixture

    private var directory: URL!
    private var stateManager: StateManager!
    private var store: ProjectStore!
    private var projectID: ProjectID!
    private var sessionID: SessionID!

    /// The standing preferences, put back in teardown. `CurfewSettings` is `PreferenceStore`-
    /// backed, so a test bundle writes to a scratch suite rather than to the copy of Threading
    /// the developer is running — but a test that left quiet hours switched on in this process
    /// would still be deciding what the next class in the run resolves.
    private var standingPreferences: CurfewPreferences!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-curfew-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        stateManager = StateManager(appSupportDirectory: directory)
        store = ProjectStore(stateManager: stateManager, refusesWrites: false)
        let project = try XCTUnwrap(
            store.addProject(folderURL: directory.appendingPathComponent("checkout"))
        )
        projectID = project.id
        sessionID = try XCTUnwrap(store.addSession(to: project.id, kind: .claude)).id
        standingPreferences = CurfewSettings.shared.preferences
    }

    override func tearDownWithError() throws {
        CurfewSettings.shared.preferences = standingPreferences
        standingPreferences = nil
        store = nil
        stateManager = nil
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        try super.tearDownWithError()
    }

    private let deadline = Date(timeIntervalSince1970: 2_000_000_000)

    private func heldState(at moment: Date) -> SessionCurfewState {
        var state = SessionCurfewState(deadline: moment, origin: .session)
        state.record(.held, at: moment)
        return state
    }

    // MARK: - The Session Setter

    func testTheSessionSetterAppliesOnceAndReportsAnAnswerThatAlreadyStands() throws {
        XCTAssertEqual(store.setCurfewRule(.until(deadline), forSessionID: sessionID), .applied)
        XCTAssertEqual(store.session(withID: sessionID)?.curfewRule, .until(deadline))

        XCTAssertEqual(store.setCurfewRule(.until(deadline), forSessionID: sessionID), .unchanged)

        XCTAssertEqual(store.setCurfewRule(.exempt, forSessionID: sessionID), .applied)
        XCTAssertEqual(store.session(withID: sessionID)?.curfewRule, .exempt)

        XCTAssertEqual(store.setCurfewRule(nil, forSessionID: sessionID), .applied)
        XCTAssertNil(store.session(withID: sessionID)?.curfewRule)
        XCTAssertEqual(store.setCurfewRule(nil, forSessionID: sessionID), .unchanged)

        XCTAssertEqual(store.setCurfewRule(.exempt, forSessionID: SessionID()), .targetNotFound)
    }

    /// A fence set before a relaunch is the whole point of storing a moment rather than a
    /// duration: the user is asleep across it.
    func testARuleAndItsReceiptsSurviveReopeningTheStore() throws {
        XCTAssertEqual(store.setCurfewRule(.until(deadline), forSessionID: sessionID), .applied)
        let state = heldState(at: deadline)
        XCTAssertEqual(store.updateCurfewState(state, forSessionID: sessionID), .applied)

        let reopened = ProjectStore(stateManager: stateManager, refusesWrites: false)
        let restored = try XCTUnwrap(reopened.session(withID: sessionID))
        XCTAssertEqual(restored.curfewRule, .until(deadline))
        XCTAssertEqual(restored.curfewState, state)
    }

    /// The deadline is the instance's identity. Moving it makes a new curfew, which owes its
    /// wrap-up again and starts its interrupt budget at zero — so the receipts describing the
    /// old one go in the same write rather than reading as work this curfew already did.
    func testAMovedDeadlineClearsTheReceiptsAndAnUnchangedRuleLeavesThem() throws {
        XCTAssertEqual(store.setCurfewRule(.until(deadline), forSessionID: sessionID), .applied)
        XCTAssertEqual(
            store.updateCurfewState(heldState(at: deadline), forSessionID: sessionID),
            .applied
        )

        XCTAssertEqual(store.setCurfewRule(.until(deadline), forSessionID: sessionID), .unchanged)
        XCTAssertEqual(store.session(withID: sessionID)?.curfewState, heldState(at: deadline))

        let moved = deadline.addingTimeInterval(3_600)
        XCTAssertEqual(store.setCurfewRule(.until(moved), forSessionID: sessionID), .applied)
        XCTAssertEqual(store.session(withID: sessionID)?.curfewRule, .until(moved))
        XCTAssertNil(
            store.session(withID: sessionID)?.curfewState,
            "receipts under a deadline nobody set describe a different curfew"
        )
    }

    func testClearingTheRuleClearsTheReceiptsThatDescribedIt() throws {
        XCTAssertEqual(store.setCurfewRule(.until(deadline), forSessionID: sessionID), .applied)
        XCTAssertEqual(
            store.updateCurfewState(heldState(at: deadline), forSessionID: sessionID),
            .applied
        )

        XCTAssertEqual(store.setCurfewRule(nil, forSessionID: sessionID), .applied)
        XCTAssertNil(store.session(withID: sessionID)?.curfewState)
    }

    // MARK: - The Project Setter

    /// A checkout can exempt its chats and cannot end them: a wall-clock moment stored one scope
    /// out would keep ending chats created weeks later at a time nobody chose.
    func testTheProjectScopeRefusesADeadlineAndAcceptsAnExemption() throws {
        XCTAssertEqual(
            store.setCurfewRule(.until(deadline), forProjectID: projectID),
            .unsupportedValue
        )
        XCTAssertNil(store.project(withID: projectID)?.curfewRule)

        XCTAssertEqual(store.setCurfewRule(.exempt, forProjectID: projectID), .applied)
        XCTAssertEqual(store.project(withID: projectID)?.curfewRule, .exempt)
        XCTAssertEqual(store.setCurfewRule(.exempt, forProjectID: projectID), .unchanged)

        XCTAssertEqual(store.setCurfewRule(nil, forProjectID: projectID), .applied)
        XCTAssertNil(store.project(withID: projectID)?.curfewRule)

        XCTAssertEqual(store.setCurfewRule(.exempt, forProjectID: ProjectID()), .targetNotFound)
    }

    // MARK: - The State Setter

    func testTheStateSetterWritesTheReceiptsAndLeavesTheRuleAlone() throws {
        XCTAssertEqual(store.setCurfewRule(.until(deadline), forSessionID: sessionID), .applied)

        var state = heldState(at: deadline)
        XCTAssertEqual(store.updateCurfewState(state, forSessionID: sessionID), .applied)
        XCTAssertEqual(store.session(withID: sessionID)?.curfewState, state)
        XCTAssertEqual(
            store.session(withID: sessionID)?.curfewRule,
            .until(deadline),
            "the rule is the user's answer; the state is what followed from it"
        )

        XCTAssertEqual(store.updateCurfewState(state, forSessionID: sessionID), .unchanged)

        state.interruptCount = 1
        state.record(.interrupted, at: deadline.addingTimeInterval(300))
        XCTAssertEqual(store.updateCurfewState(state, forSessionID: sessionID), .applied)
        XCTAssertEqual(store.session(withID: sessionID)?.curfewState?.interruptCount, 1)

        XCTAssertEqual(store.updateCurfewState(nil, forSessionID: sessionID), .applied)
        XCTAssertNil(store.session(withID: sessionID)?.curfewState)
        XCTAssertEqual(store.updateCurfewState(nil, forSessionID: sessionID), .unchanged)

        XCTAssertEqual(store.updateCurfewState(state, forSessionID: SessionID()), .targetNotFound)
    }

    /// A refused write is a typed refusal and leaves the standing answer, because the caller's
    /// next step — announcing the fence, arming the engine — cannot be taken back.
    func testARefusedWriteSaysSoAndLeavesTheStandingAnswer() throws {
        XCTAssertEqual(store.setCurfewRule(.exempt, forSessionID: sessionID), .applied)

        let recovery = ProjectStore(stateManager: stateManager, refusesWrites: true)
        XCTAssertEqual(
            recovery.setCurfewRule(.until(deadline), forSessionID: sessionID),
            .persistenceRefused
        )
        XCTAssertEqual(recovery.session(withID: sessionID)?.curfewRule, .exempt)

        XCTAssertEqual(
            recovery.updateCurfewState(heldState(at: deadline), forSessionID: sessionID),
            .persistenceRefused
        )
        XCTAssertNil(recovery.session(withID: sessionID)?.curfewState)

        XCTAssertEqual(
            recovery.setCurfewRule(.exempt, forProjectID: projectID),
            .persistenceRefused
        )
        XCTAssertNil(recovery.project(withID: projectID)?.curfewRule)
    }

    // MARK: - The Records On Disk

    func testASessionRecordWithNoCurfewKeysReadsAsNeverChose() throws {
        let session = AgentSession(kind: .claude, title: "Chat")
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try JSONEncoder().encode(session))
                as? [String: Any]
        )
        XCTAssertNil(json["curfewRule"], "an install that never set one writes no key")
        XCTAssertNil(json["curfewState"])

        json.removeValue(forKey: "curfewRule")
        json.removeValue(forKey: "curfewState")
        let decoded = try JSONDecoder().decode(
            AgentSession.self,
            from: try JSONSerialization.data(withJSONObject: json)
        )
        XCTAssertNil(decoded.curfewRule)
        XCTAssertNil(decoded.curfewState)
    }

    func testBothFieldsRoundTripThroughASessionRecord() throws {
        var session = AgentSession(kind: .claude, title: "Chat")
        session.curfewRule = .until(deadline)
        session.curfewState = heldState(at: deadline)

        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try JSONEncoder().encode(session))
                as? [String: Any]
        )
        let rule = try XCTUnwrap(json["curfewRule"] as? [String: Any])
        XCTAssertEqual(rule["kind"] as? String, "until")

        let decoded = try JSONDecoder().decode(
            AgentSession.self,
            from: try JSONSerialization.data(withJSONObject: json)
        )
        XCTAssertEqual(decoded.curfewRule, .until(deadline))
        XCTAssertEqual(decoded.curfewState, heldState(at: deadline))
    }

    /// A rule kind a later build invented costs the setting and nothing else: the chain then
    /// falls through to the checkout and the standing window, which is the conservative
    /// direction — a session that cannot read its own curfew inherits one.
    func testARuleKindThisBuildCannotReadCostsTheSettingAndNotTheRecord() throws {
        var session = AgentSession(kind: .claude, title: "Chat")
        session.curfewRule = .until(deadline)

        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try JSONEncoder().encode(session))
                as? [String: Any]
        )
        json["curfewRule"] = ["kind": "somethingALaterBuildInvented", "deadline": 0]

        let decoded = try JSONDecoder().decode(
            AgentSession.self,
            from: try JSONSerialization.data(withJSONObject: json)
        )
        XCTAssertNil(decoded.curfewRule)
        XCTAssertEqual(decoded.title, "Chat")
        XCTAssertEqual(decoded.id, session.id)
    }

    /// The state is a log of what already happened. A malformed one is worth losing on its own
    /// rather than taking the session's title, its resume state and its account with it.
    func testAMalformedStateCostsTheStateAndNotTheSession() throws {
        var session = AgentSession(kind: .claude, title: "Chat")
        session.curfewRule = .until(deadline)
        session.curfewState = heldState(at: deadline)

        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try JSONEncoder().encode(session))
                as? [String: Any]
        )
        // No `deadline`, which is the one field a state cannot be read without.
        json["curfewState"] = ["interruptCount": 2]

        let decoded = try JSONDecoder().decode(
            AgentSession.self,
            from: try JSONSerialization.data(withJSONObject: json)
        )
        XCTAssertNil(decoded.curfewState, "a deadline-less state is unreadable")
        XCTAssertEqual(decoded.curfewRule, .until(deadline), "the fence itself still stands")
        XCTAssertEqual(decoded.title, "Chat")
    }

    /// A checkout's answer is one of two values, and a record carrying the third — hand-edited,
    /// or written by a build that allowed it — decodes rather than costing the checkout and
    /// every session inside it. `CurfewResolution` falls through it to the standing window.
    func testACheckoutToleratesADeadlineOnDiskThatItWouldNeverWrite() throws {
        var project = Project(name: "Checkout", folderURL: URL(fileURLWithPath: "/tmp/checkout"))
        project.curfewRule = .exempt

        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try JSONEncoder().encode(project))
                as? [String: Any]
        )
        XCTAssertEqual((json["curfewRule"] as? [String: Any])?["kind"] as? String, "exempt")

        json["curfewRule"] = [
            "kind": "until",
            "deadline": deadline.timeIntervalSinceReferenceDate,
        ]
        let decoded = try JSONDecoder().decode(
            Project.self,
            from: try JSONSerialization.data(withJSONObject: json)
        )
        XCTAssertEqual(decoded.curfewRule, .until(deadline))
        XCTAssertEqual(decoded.name, "Checkout")

        let withoutOne = try JSONDecoder().decode(
            Project.self,
            from: try JSONSerialization.data(
                withJSONObject: {
                    var stripped = json
                    stripped.removeValue(forKey: "curfewRule")
                    return stripped
                }()
            )
        )
        XCTAssertNil(withoutOne.curfewRule)
    }

    // MARK: - Reading The Records

    func testASessionsOwnExemptionAnswersFromItsOwnScope() throws {
        CurfewSettings.shared.preferences = preferences(quietHoursEnabled: true)
        XCTAssertEqual(store.setCurfewRule(.exempt, forSessionID: sessionID), .applied)

        let answer = CurfewResolution.answer(
            forSessionID: sessionID,
            in: store,
            now: try today(hour: 5)
        )
        XCTAssertEqual(answer.scope, .session)
        XCTAssertNil(answer.curfew)
    }

    func testACheckoutsExemptionAnswersForAChatThatNeverSaidAnything() throws {
        CurfewSettings.shared.preferences = preferences(quietHoursEnabled: true)
        XCTAssertEqual(store.setCurfewRule(.exempt, forProjectID: projectID), .applied)

        let answer = CurfewResolution.answer(
            forSessionID: sessionID,
            in: store,
            now: try today(hour: 5)
        )
        XCTAssertEqual(answer.scope, .project)
        XCTAssertNil(answer.curfew)

        let projectAnswer = CurfewResolution.answer(
            forProjectID: projectID,
            in: store,
            now: try today(hour: 5)
        )
        XCTAssertEqual(projectAnswer.scope, .project)
        XCTAssertNil(projectAnswer.curfew)
    }

    func testWithNobodyAnsweringTheStandingWindowDoes() throws {
        CurfewSettings.shared.preferences = preferences(quietHoursEnabled: true)
        let now = try today(hour: 5)

        let answer = CurfewResolution.answer(forSessionID: sessionID, in: store, now: now)
        XCTAssertEqual(answer.scope, .app)
        let curfew = try XCTUnwrap(answer.curfew)
        XCTAssertEqual(curfew.deadline, try today(hour: 4))
        XCTAssertEqual(curfew.endsAt, try today(hour: 8))

        CurfewSettings.shared.preferences = preferences(quietHoursEnabled: false)
        XCTAssertNil(
            CurfewResolution.answer(forSessionID: sessionID, in: store, now: now).curfew,
            "a window that is switched off is no curfew at all"
        )
    }

    /// What the menu names beside its Inherit row: the answer with this record's own level
    /// removed, so a chat that ended itself at 22:00 still reads "otherwise 04:00".
    func testWhatARecordWouldFollowIgnoresItsOwnAnswer() throws {
        CurfewSettings.shared.preferences = preferences(quietHoursEnabled: true)
        let now = try today(hour: 5)
        XCTAssertEqual(store.setCurfewRule(.exempt, forSessionID: sessionID), .applied)

        let inherited = try XCTUnwrap(
            CurfewResolution.inherited(beyondSessionID: sessionID, in: store, now: now)
        )
        XCTAssertEqual(inherited.deadline, try today(hour: 4))

        XCTAssertEqual(store.setCurfewRule(.exempt, forProjectID: projectID), .applied)
        XCTAssertNil(
            CurfewResolution.inherited(beyondSessionID: sessionID, in: store, now: now),
            "an exempt checkout is what its chats would follow"
        )
        XCTAssertEqual(
            try XCTUnwrap(
                CurfewResolution.inherited(beyondProjectID: projectID, now: now)
            ).deadline,
            try today(hour: 4),
            "one scope out there is only the standing window left"
        )
    }

    // MARK: - Reader Fixtures

    private func preferences(quietHoursEnabled: Bool) -> CurfewPreferences {
        CurfewPreferences(
            quietHours: QuietHours(
                isEnabled: quietHoursEnabled,
                startMinute: CurfewDefaults.quietHoursStartMinute,
                endMinute: CurfewDefaults.quietHoursEndMinute
            )
        )
    }

    /// The readers resolve against `Calendar.current`, so the expectations are composed with it
    /// too — the reader's own time zone is part of the answer.
    private func today(hour: Int) throws -> Date {
        try XCTUnwrap(
            Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date())
        )
    }
}
