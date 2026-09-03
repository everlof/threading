import XCTest
import ThreadingDomain
@testable import Threading

/// A plugin is told where it is through a `[String: String]`, which means the names are the
/// contract and a typo is a silently absent value rather than a compile error. These assert the
/// mapping directly, with no bundle and no window.
final class NativePluginPlacementTests: XCTestCase {

    func testEveryNamedValueReachesThePlugin() {
        let session = SessionID()
        let project = ProjectID()
        let placement = NativePluginPlacement(
            sessionID: session,
            projectID: project,
            projectName: "Threading",
            checkoutPath: "/Users/someone/repo/Threading"
        )

        XCTAssertEqual(placement.arguments, [
            "sessionID": session.uuidString,
            "projectID": project.uuidString,
            "projectName": "Threading",
            "checkoutPath": "/Users/someone/repo/Threading",
        ])
    }

    /// An absent value must be an absent *key*, not an empty string.
    ///
    /// A plugin reads these with `argument(_:)`, which returns `String?`, so the natural shape is
    /// `if let path = context.argument("checkoutPath")`. Handing over `""` passes that test and
    /// then reaches a path API, every one of which treats the empty string as somewhere — the
    /// current directory, or the root. The difference only shows up on a session with no project,
    /// which is exactly the case nobody builds a fixture for.
    func testAnUnknownValueIsAnAbsentKeyRatherThanAnEmptyString() {
        let placement = NativePluginPlacement(
            sessionID: nil,
            projectID: nil,
            projectName: "",
            checkoutPath: ""
        )
        XCTAssertTrue(placement.arguments.isEmpty, "got \(placement.arguments)")

        let partial = NativePluginPlacement(sessionID: SessionID(), checkoutPath: nil)
        XCTAssertNil(partial.arguments["checkoutPath"])
        XCTAssertNil(partial.arguments["projectID"])
        XCTAssertNotNil(partial.arguments["sessionID"])
    }

    /// A pane with no owning session still has to produce a context, because a plugin that only
    /// draws is a complete plugin and must not be refused a pane for having no project.
    func testAPlacementWithNothingKnownIsValidRatherThanEmptyOfMeaning() {
        XCTAssertEqual(NativePluginPlacement().arguments, [:])
    }

    /// The spelling is the contract, so it is asserted rather than assumed. A rename here is a
    /// breaking change for every installed plugin and should fail a test, not a user's pane.
    func testTheArgumentNamesAreTheOnesPluginsCompileAgainst() {
        XCTAssertEqual(NativePluginPlacement.Key.sessionID, "sessionID")
        XCTAssertEqual(NativePluginPlacement.Key.projectID, "projectID")
        XCTAssertEqual(NativePluginPlacement.Key.projectName, "projectName")
        XCTAssertEqual(NativePluginPlacement.Key.checkoutPath, "checkoutPath")
    }
}
