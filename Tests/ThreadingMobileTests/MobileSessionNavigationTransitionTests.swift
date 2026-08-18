import ThreadingRemoteKit
import XCTest
@testable import ThreadingMobile

final class MobileSessionNavigationTransitionTests: XCTestCase {
    func testTerminalSessionNavigationCommitsFinalGeometryImmediately() {
        XCTAssertEqual(
            MobileSessionNavigationTransition.forSurface(.terminal),
            .immediate
        )
    }

    func testNativeConversationKeepsTheStandardNavigationTransition() {
        XCTAssertEqual(
            MobileSessionNavigationTransition.forSurface(.conversation),
            .standard
        )
    }
}

/// Opening a session is one code path, whether the row was tapped or the chat was just started
/// from the New Session sheet. Starting one and being left on the list was the bug: the created
/// session was thrown away and only the sheet was dismissed.
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

        XCTAssertEqual(model.navigationPath, ["session-1"])
    }

    func testPushingATerminalSessionAlsoOpensIt() {
        let model = makeModel()

        MobileSessionNavigationTransition.push(session(surface: .terminal), onto: model)

        XCTAssertEqual(model.navigationPath, ["session-1"])
    }

    /// The session already on top is the one being looked at. A notification, a restored route
    /// and a freshly started chat can all name it within the same moment, and pushing a second
    /// copy would make Back return to the same screen.
    func testPushingTheSessionAlreadyOnTopDoesNotStackASecondCopy() {
        let model = makeModel()
        let opened = session(surface: .conversation)

        MobileSessionNavigationTransition.push(opened, onto: model)
        MobileSessionNavigationTransition.push(opened, onto: model)

        XCTAssertEqual(model.navigationPath, ["session-1"])
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
            state: "idle",
            projectName: "AnotherTerminal"
        )
    }
}
