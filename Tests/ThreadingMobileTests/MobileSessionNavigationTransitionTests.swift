import ThreadingRemoteKit
import SwiftUI
import UIKit
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

        model.noteDraftStarted(draft, creation: creation(surface: .conversation))

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
        model.noteDraftStarted(
            draft,
            creation: MobileCreatedSession(
                session: started,
                openingStrategy: .awaitCreatedSession
            )
        )

        MobileSessionNavigationTransition.push(started, onto: model)

        XCTAssertEqual(model.navigationPath, [.draft(draft)])
    }

    /// Two drafts are two screens even when they start the same chat: each resolves on its own.
    func testADifferentDraftDoesNotInheritAnotherDraftsSession() {
        let model = makeModel()
        let started = MobileSessionDraft()
        model.noteDraftStarted(started, creation: creation(surface: .terminal))

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

        model.noteDraftStarted(draft, creation: creation(surface: .conversation))

        XCTAssertEqual(continuity.lastRoute?.sessionID, "session-1")
        XCTAssertEqual(continuity.lastRoute?.hostID, model.activeHostID)
    }

    /// The draft fades over the session for 0.35 seconds. Both children are mounted during that
    /// interval, but only the destination may contribute navigation chrome; otherwise SwiftUI
    /// places the draft's usage disc beside the session's identical disc until the fade retires.
    func testStartingADraftImmediatelyHandsTheNavigationBarToTheSession() throws {
        let model = makeModel()
        model.startDemo()
        let draft = MobileSessionDraft()
        let continuity = MobileSessionContinuityStore(defaults: defaults)
        let keyboards = MobileTerminalKeyboardStore()
        let notifications = RemoteNotificationManager()
        let screen = NavigationStack {
            SessionDraftView(draft: draft)
        }
        .environmentObject(model)
        .environmentObject(continuity)
        .environmentObject(keyboards)
        .environmentObject(notifications)
        .mobileTheme(RemoteThemePalette(nil))
        let controller = UIHostingController(rootView: screen)
        let window = hostedWindow(rootViewController: controller)
        defer { window.isHidden = true }

        XCTAssertEqual(
            accessibilityViews(labelled: MobileL10n.string("Agent and account"), in: window).count,
            1
        )
        XCTAssertTrue(
            accessibilityViews(labelled: MobileL10n.string("Session actions"), in: window).isEmpty
        )

        let session = try XCTUnwrap(model.me?.sessions.first)
        model.noteDraftStarted(
            draft,
            creation: MobileCreatedSession(
                session: session,
                openingStrategy: .awaitCreatedSession
            )
        )
        settle(window, for: 0.1)

        XCTAssertTrue(
            accessibilityViews(
                labelled: MobileL10n.string("Agent and account"),
                in: window
            ).isEmpty,
            "the fading draft still owns a toolbar item"
        )
        XCTAssertEqual(
            accessibilityViews(labelled: MobileL10n.string("Session actions"), in: window).count,
            1,
            "the draft and session contributed two usage controls during their overlap"
        )
        let overlapFrame = render(window)
        attach(overlapFrame, named: "draft-session-navbar-overlap")
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

    private func creation(surface: RemoteSessionSurface) -> MobileCreatedSession {
        MobileCreatedSession(
            session: session(surface: surface),
            openingStrategy: .awaitCreatedSession
        )
    }

    private func hostedWindow(rootViewController: UIViewController) -> UIWindow {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: .zero)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = rootViewController
        window.makeKeyAndVisible()
        settle(window)
        return window
    }

    private func settle(_ window: UIWindow, for interval: TimeInterval = 0.1) {
        RunLoop.current.run(until: Date().addingTimeInterval(interval))
        window.layoutIfNeeded()
    }

    private func accessibilityViews(labelled label: String, in view: UIView) -> [UIView] {
        var result = view.accessibilityLabel == label ? [view] : []
        result.append(
            contentsOf: view.subviews.flatMap { self.accessibilityViews(labelled: label, in: $0) }
        )
        return result
    }

    private func render(_ window: UIWindow) -> UIImage {
        UIGraphicsImageRenderer(bounds: window.bounds).image { context in
            window.layer.render(in: context.cgContext)
        }
    }

    private func attach(_ image: UIImage, named name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

}

/// The draft's model and effort are one line of text, while speed owns its neighbouring menu.
/// What the shared line says is decided here rather than in the view.
final class SessionDraftChoiceTests: XCTestCase {
    func testTheRunSummaryNamesTheModelAndOnlyTheChoicesMade() {
        XCTAssertEqual(
            SessionDraftRunSummary.text(model: "GPT-5.6 Sol", effort: "High"),
            "GPT-5.6 Sol · High"
        )
        XCTAssertEqual(
            SessionDraftRunSummary.text(model: "GPT-5.6 Sol", effort: nil),
            "GPT-5.6 Sol"
        )
        XCTAssertEqual(
            SessionDraftRunSummary.text(model: "Opus", effort: "Max"),
            "Opus · Max"
        )
    }

    func testTheRunSummaryWithNoModelSaysSoInsteadOfGoingBlank() {
        XCTAssertEqual(
            SessionDraftRunSummary.text(model: nil, effort: nil),
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
