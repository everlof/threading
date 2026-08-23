import ThreadingRemoteKit
import XCTest
@testable import ThreadingMobile

/// Opening a session is one code path, whether the row was tapped or the chat was just started
/// from a draft. Starting one and being left on the list was the bug: the created session was
/// thrown away and only the sheet was dismissed.
@MainActor
final class MobileSessionOpeningTests: XCTestCase {
    private static let suiteName = "MobileSessionOpeningTests"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: Self.suiteName)
        defaults.removePersistentDomain(forName: Self.suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: Self.suiteName)
        defaults = nil
        super.tearDown()
    }

    func testPushingAConversationPutsItOnTheNavigationStack() {
        let model = makeModel()

        MobileSessionNavigationTransition.push(session(surface: .conversation), onto: model)

        XCTAssertEqual(model.navigationPath, [.session("session-1")])
    }

    func testPushingATerminalSessionAlsoOpensIt() {
        let model = makeModel()

        MobileSessionNavigationTransition.push(session(surface: .terminal), onto: model)

        XCTAssertEqual(model.navigationPath, [.session("session-1")])
    }

    /// The session already on top is the one being looked at. A notification, a restored route
    /// and a freshly started chat can all name it within the same moment, and pushing a second
    /// copy would make Back return to the same screen.
    func testPushingTheSessionAlreadyOnTopDoesNotStackASecondCopy() {
        let model = makeModel()
        let opened = session(surface: .conversation)

        MobileSessionNavigationTransition.push(opened, onto: model)
        MobileSessionNavigationTransition.push(opened, onto: model)

        XCTAssertEqual(model.navigationPath, [.session("session-1")])
    }

    func testOpeningAChatFromAProjectKeepsTheProjectAsTheBackDestination() {
        let model = makeModel()
        model.navigationPath = [.project("AnotherTerminal")]

        MobileSessionNavigationTransition.push(
            session(surface: .conversation),
            onto: model
        )

        XCTAssertEqual(
            model.navigationPath,
            [.project("AnotherTerminal"), .session("session-1")]
        )
    }

    // MARK: - Drafts

    /// Starting a chat is navigation: the draft is a screen on the stack, pushed from the list
    /// it was asked for in, so Back from the chat it becomes returns there.
    func testStartingADraftPushesItOntoTheStackFromTheProjectItWasAskedIn() {
        let model = makeModel()
        model.navigationPath = [.project("AnotherTerminal")]

        MobileSessionNavigationTransition.draft(in: "AnotherTerminal", onto: model)

        guard case .draft(let draft)? = model.navigationPath.last else {
            return XCTFail("expected a draft route on top, got \(model.navigationPath)")
        }
        XCTAssertEqual(draft.projectName, "AnotherTerminal")
        XCTAssertEqual(model.navigationPath.count, 2)
        XCTAssertEqual(model.navigationPath.first, .project("AnotherTerminal"))
    }

    /// The draft route names no session by itself; once Start is answered, the model resolves
    /// it to the chat it became, and the path has not moved.
    func testADraftResolvesToTheSessionItStartedWithoutMovingThePath() {
        let model = makeModel()
        let draft = MobileSessionDraft()
        model.navigationPath = [.draft(draft)]
        XCTAssertNil(model.openSessionID)
        XCTAssertNil(model.sessionID(for: .draft(draft)))

        model.noteDraftStarted(draft, session: session(surface: .conversation))

        XCTAssertEqual(model.navigationPath, [.draft(draft)])
        XCTAssertEqual(model.sessionID(for: .draft(draft)), "session-1")
        XCTAssertEqual(model.openSessionID, "session-1")
    }

    /// The chat a draft just started is the chat on top. A notification for it, or a row tap
    /// after the list refreshed behind the screen, must not stack a second copy over it.
    func testPushingTheSessionADraftStartedDoesNotStackASecondCopy() {
        let model = makeModel()
        let draft = MobileSessionDraft()
        let started = session(surface: .conversation)
        model.navigationPath = [.draft(draft)]
        model.noteDraftStarted(draft, session: started)

        MobileSessionNavigationTransition.push(started, onto: model)

        XCTAssertEqual(model.navigationPath, [.draft(draft)])
    }

    /// Two drafts are two screens even when they start the same chat: each resolves on its own.
    func testADifferentDraftDoesNotInheritAnotherDraftsSession() {
        let model = makeModel()
        let started = MobileSessionDraft()
        model.noteDraftStarted(started, session: session(surface: .terminal))

        XCTAssertNil(model.sessionID(for: .draft(MobileSessionDraft())))
        XCTAssertNil(model.sessionID(for: .project("AnotherTerminal")))
        XCTAssertNil(model.sessionID(for: .terminal("terminal-1")))
        XCTAssertNil(model.sessionID(for: nil))
    }

    /// Continuity reopens the last chat on the next launch. A chat that began as a draft is
    /// recorded the moment Start is answered, although the path itself did not change.
    func testAStartedDraftIsRecordedAsTheLastRouteForContinuity() {
        let continuity = MobileSessionContinuityStore(defaults: defaults)
        let model = RemoteAppModel(continuity: continuity)
        model.startDemo()
        let draft = MobileSessionDraft()
        model.navigationPath = [.draft(draft)]
        XCTAssertNil(continuity.lastRoute)

        model.noteDraftStarted(draft, session: session(surface: .conversation))

        XCTAssertEqual(continuity.lastRoute?.sessionID, "session-1")
        XCTAssertEqual(continuity.lastRoute?.hostID, model.activeHostID)
    }

    private func makeModel() -> RemoteAppModel {
        RemoteAppModel(continuity: MobileSessionContinuityStore(defaults: defaults))
    }

    private func session(surface: RemoteSessionSurface) -> RemoteSessionSummaryDTO {
        RemoteSessionSummaryDTO(
            id: "session-1",
            title: "Teach this screen a new trick",
            agentKind: "claude",
            surface: surface,
            state: .idle,
            projectName: "AnotherTerminal"
        )
    }
}

/// The draft's run settings are one line of text, and what it says is decided here rather than
/// in the view: the model, then only the choices that depart from its defaults.
final class SessionDraftChoiceTests: XCTestCase {
    func testTheRunSummaryNamesTheModelAndOnlyTheChoicesMade() {
        XCTAssertEqual(
            SessionDraftRunSummary.text(model: "GPT-5.6 Sol", effort: "High", speed: nil),
            "GPT-5.6 Sol · High"
        )
        XCTAssertEqual(
            SessionDraftRunSummary.text(model: "GPT-5.6 Sol", effort: nil, speed: nil),
            "GPT-5.6 Sol"
        )
        XCTAssertEqual(
            SessionDraftRunSummary.text(model: "Opus", effort: "Max", speed: "Fast"),
            "Opus · Max · Fast"
        )
    }

    func testTheRunSummaryWithNoModelSaysSoInsteadOfGoingBlank() {
        XCTAssertEqual(
            SessionDraftRunSummary.text(model: nil, effort: nil, speed: nil),
            MobileL10n.string("Default model")
        )
    }

    /// An agent asks for nothing on the wire — what every request meant before the role existed
    /// — and a manager asks by the Mac's word for it.
    func testOnlyAManagerIsNamedOnTheWire() {
        XCTAssertNil(SessionDraftRole.agent.wireValue)
        XCTAssertEqual(SessionDraftRole.manager.wireValue, RemoteSessionRole.manager)
        XCTAssertEqual(SessionDraftRole.allCases, [.agent, .manager])
    }
}
