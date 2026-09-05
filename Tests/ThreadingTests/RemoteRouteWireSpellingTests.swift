import XCTest
@testable import Threading
import ThreadingRemoteKit

/// The host's route and header constants are now derived from `ThreadingRemoteKit`'s
/// `RemoteRoute` / `RemoteSocketRoute` / `RemoteHeader` / `RemoteClientKind` rather than spelled
/// in `RemoteRouter`. That removes the drift between the two ends of the wire, but it also means
/// a rename in the package would silently move every path the host matches.
///
/// So these assertions spell the bytes out. They deliberately do **not** read `rawValue` on the
/// enum being checked — an expectation derived from the same source agrees with any rename, which
/// is exactly the failure this file exists to catch. A shipped client speaks these exact strings;
/// changing one is a protocol change, not a refactor, and this test is where that has to be
/// acknowledged.
final class RemoteRouteWireSpellingTests: XCTestCase {

    // MARK: - REST paths

    func testRESTPathConstantsKeepTheirWireSpelling() {
        XCTAssertEqual(RemoteRouter.apiSessionsPath, "/api/me")
        XCTAssertEqual(RemoteRouter.usagePath, "/api/usage")
        XCTAssertEqual(RemoteRouter.usageLimitPath, "/api/usage/limit")
        XCTAssertEqual(RemoteRouter.usageResetPath, "/api/usage/reset")
        XCTAssertEqual(RemoteRouter.createSessionPath, "/api/session")
        XCTAssertEqual(RemoteRouter.notificationRegistrationPath, "/api/notifications")
        XCTAssertEqual(RemoteRouter.diagnosticUploadPath, "/api/diagnostics")
        XCTAssertEqual(RemoteRouter.mobileDiagnosticsCaptureUploadPath, "/api/local-diagnostics/capture")
        XCTAssertEqual(RemoteRouter.invitationAcceptancePath, "/api/invitations/accept")
        XCTAssertEqual(RemoteRouter.hostedDeviceCredentialPath, "/api/hosted-device-credential")
        XCTAssertEqual(RemoteRouter.appThemePath, "/api/theme")
        XCTAssertEqual(RemoteRouter.themeEventsPath, "/ws/events")
    }

    // MARK: - Prefixes, asserted through the parser that owns them

    /// `appSettingPrefix` is private, so its spelling is pinned by the one path that has to match
    /// it. A prefix that moved would return nil here.
    func testSettingsPrefixKeepsItsWireSpelling() {
        XCTAssertEqual(RemoteRouter.appSettingIdentity(forPath: "/api/settings/remote.access"), "remote.access")
        XCTAssertNil(RemoteRouter.appSettingIdentity(forPath: "/api/setting/remote.access"))
        XCTAssertNil(RemoteRouter.appSettingIdentity(forPath: "/api/settings/"))
        XCTAssertNil(RemoteRouter.appSettingIdentity(forPath: "/api/settings/a/b"))
    }

    func testSessionPrefixKeepsItsWireSpelling() {
        XCTAssertEqual(RemoteRouter.resumeSessionID(forPath: "/api/session/S1/resume"), "S1")
        XCTAssertEqual(RemoteRouter.renameSessionID(forPath: "/api/session/S1/rename"), "S1")
        XCTAssertEqual(RemoteRouter.themeSessionID(forPath: "/api/session/S1/theme"), "S1")
        XCTAssertNil(RemoteRouter.resumeSessionID(forPath: "/api/sessions/S1/resume"))
        XCTAssertNil(RemoteRouter.resumeSessionID(forPath: "/session/S1/resume"))
    }

    func testTerminalPrefixKeepsItsWireSpelling() {
        XCTAssertEqual(RemoteRouter.resumeTerminalID(forPath: "/api/terminal/T1/resume"), "T1")
        XCTAssertEqual(RemoteRouter.shareTerminalID(forPath: "/api/terminal/T1/share"), "T1")
        XCTAssertEqual(RemoteRouter.unshareTerminalID(forPath: "/api/terminal/T1/unshare"), "T1")
        XCTAssertNil(RemoteRouter.resumeTerminalID(forPath: "/api/terminals/T1/resume"))
    }

    func testGitReviewRouteKeepsItsWireSpelling() {
        XCTAssertEqual(
            RemoteRouter.gitReviewRoute(forPath: "/api/session/S1/git-review/staged"),
            RemoteRouter.GitReviewRoute(sessionID: "S1", mode: .staged)
        )
        XCTAssertNil(RemoteRouter.gitReviewRoute(forPath: "/api/sessions/S1/git-review/staged"))
    }

    func testWebSocketPrefixesKeepTheirWireSpelling() {
        XCTAssertEqual(RemoteRouter.webSocketSessionID(forPath: "/ws/session/S1"), "S1")
        XCTAssertNil(RemoteRouter.webSocketSessionID(forPath: "/ws/sessions/S1"))
        XCTAssertNil(RemoteRouter.webSocketSessionID(forPath: "/ws/session/"))

        XCTAssertEqual(RemoteRouter.webSocketTerminalID(forPath: "/ws/terminal/T1"), "T1")
        XCTAssertNil(RemoteRouter.webSocketTerminalID(forPath: "/ws/terminals/T1"))
        XCTAssertNil(RemoteRouter.webSocketTerminalID(forPath: "/ws/terminal/"))
    }

    // MARK: - Headers

    func testHeaderConstantsKeepTheirWireSpelling() {
        XCTAssertEqual(RemoteRouter.deviceHeader, "x-threading-device")
        XCTAssertEqual(RemoteRouter.clientHeader, "x-threading-client")
        XCTAssertEqual(RemoteRouter.requestIDHeader, "x-threading-request-id")
        XCTAssertEqual(RemoteRouter.protocolHeader, "x-threading-protocol")
        XCTAssertEqual(RemoteRouter.protocolMinimumHeader, "x-threading-protocol-min")
    }

    // MARK: - Client kinds

    /// The values the server compares `x-threading-client` against, after lowercasing. A shipped
    /// iPhone sends `Threading-iOS`; the host must keep recognising it.
    func testClientKindValuesKeepTheirWireSpelling() {
        XCTAssertEqual(RemoteClientKind.iOS.rawValue, "threading-ios")
        XCTAssertEqual(RemoteClientKind.web.rawValue, "threading-web")
        XCTAssertEqual("Threading-iOS".lowercased(), RemoteClientKind.iOS.rawValue)
    }
}
