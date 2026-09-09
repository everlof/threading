import XCTest

@testable import ThreadingRemoteKit

/// The route vocabulary is the wire, so these tests spell the bytes out rather than deriving
/// them from the enums they are checking — a test that builds its expectation from `rawValue`
/// would agree with any rename, which is the failure this vocabulary exists to prevent.
///
/// Every mapping goes through an exhaustive `switch`, so a new case is a compile error here
/// rather than an untested route.
final class RemoteRouteVocabularyTests: XCTestCase {
    private let origin = "https://quiet-river.trycloudflare.com"

    private func makeLink() throws -> RemoteConnectionLink {
        try XCTUnwrap(RemoteConnectionLink(string: "\(origin)/#private-token"))
    }

    // MARK: - The strings themselves

    func testEveryRESTRouteKeepsItsWireSpelling() {
        for route in RemoteRoute.allCases {
            let expected: String
            switch route {
            case .me: expected = "api/me"
            case .search: expected = "api/search"
            case .usage: expected = "api/usage"
            case .usageCapacity: expected = "api/usage/capacity"
            case .usageLimit: expected = "api/usage/limit"
            case .usageReset: expected = "api/usage/reset"
            case .session: expected = "api/session"
            case .terminal: expected = "api/terminal"
            case .theme: expected = "api/theme"
            case .notifications: expected = "api/notifications"
            case .diagnostics: expected = "api/diagnostics"
            case .localDiagnosticsCapture: expected = "api/local-diagnostics/capture"
            case .invitationAcceptance: expected = "api/invitations/accept"
            case .hostedDeviceCredential: expected = "api/hosted-device-credential"
            case .settings: expected = "api/settings"
            }
            XCTAssertEqual(route.rawValue, expected)
            // The host matches a rooted path; the client appends an unrooted one. Both come
            // from the same case, so they cannot drift apart.
            XCTAssertEqual(route.absolutePath, "/" + expected)
            XCTAssertEqual(route.prefix, "/" + expected + "/")
        }
        XCTAssertEqual(RemoteRoute.allCases.count, 15)
    }

    func testEverySocketRouteKeepsItsWireSpelling() {
        for route in RemoteSocketRoute.allCases {
            let expected: String
            let expectedComponents: [String]
            switch route {
            case .events:
                expected = "ws/events"
                expectedComponents = ["ws", "events"]
            case .session:
                expected = "ws/session"
                expectedComponents = ["ws", "session"]
            case .terminal:
                expected = "ws/terminal"
                expectedComponents = ["ws", "terminal"]
            }
            XCTAssertEqual(route.rawValue, expected)
            XCTAssertEqual(route.absolutePath, "/" + expected)
            XCTAssertEqual(route.prefix, "/" + expected + "/")
            XCTAssertEqual(route.pathComponents, expectedComponents)
        }
        XCTAssertEqual(RemoteSocketRoute.allCases.count, 3)
    }

    func testHeaderNamesAreTheLowercasedFormBothEndsCompare() {
        for header in RemoteHeader.allCases {
            let expected: String
            switch header {
            case .device: expected = "x-threading-device"
            case .client: expected = "x-threading-client"
            case .requestID: expected = "x-threading-request-id"
            case .protocolVersion: expected = "x-threading-protocol"
            case .protocolMinimum: expected = "x-threading-protocol-min"
            }
            XCTAssertEqual(header.rawValue, expected)
            XCTAssertEqual(header.rawValue, header.rawValue.lowercased())
        }
        XCTAssertEqual(RemoteHeader.allCases.count, 5)
    }

    func testClientKindsAreTheNormalizedValuesTheHostComparesAgainst() {
        for kind in RemoteClientKind.allCases {
            let expected: String
            switch kind {
            case .iOS: expected = "threading-ios"
            case .web: expected = "threading-web"
            }
            XCTAssertEqual(kind.rawValue, expected)
            XCTAssertEqual(kind.rawValue, kind.rawValue.lowercased())
        }
        XCTAssertEqual(RemoteClientKind.allCases.count, 2)
    }

    // MARK: - What the client builds from them

    /// One assertion per REST route, from the case rather than from a list, so a route that
    /// gains a case without a client URL is noticed.
    func testEveryRESTRouteBuildsTheURLTheHostAlreadyServes() throws {
        let link = try makeLink()
        for route in RemoteRoute.allCases {
            let built: URL?
            let expected: String?
            switch route {
            case .me:
                built = link.meURL
                expected = "\(origin)/api/me"
            case .search:
                built = link.searchURL
                expected = "\(origin)/api/search"
            case .usage:
                built = link.usageURL
                expected = "\(origin)/api/usage"
            case .usageCapacity:
                built = link.usageCapacityURL
                expected = "\(origin)/api/usage/capacity"
            case .usageLimit:
                built = link.usageLimitURL(seriesID: "codex|personal|weekly", days: 30)
                expected = "\(origin)/api/usage/limit?series=codex%7Cpersonal%7Cweekly&days=30"
            case .usageReset:
                built = link.usageResetURL(seriesID: "codex|personal|weekly")
                expected = "\(origin)/api/usage/reset?series=codex%7Cpersonal%7Cweekly"
            case .session:
                built = link.createSessionURL
                expected = "\(origin)/api/session"
            case .terminal:
                built = link.resumeTerminalURL(terminalID: "terminal-1")
                expected = "\(origin)/api/terminal/terminal-1/resume"
            case .theme:
                built = link.appThemeURL
                expected = "\(origin)/api/theme"
            case .notifications:
                built = link.notificationRegistrationURL
                expected = "\(origin)/api/notifications"
            case .diagnostics:
                built = link.diagnosticUploadURL
                expected = "\(origin)/api/diagnostics"
            case .localDiagnosticsCapture:
                built = link.mobileDiagnosticsCaptureUploadURL
                expected = "\(origin)/api/local-diagnostics/capture"
            case .invitationAcceptance:
                built = link.invitationAcceptanceURL
                expected = "\(origin)/api/invitations/accept"
            case .hostedDeviceCredential:
                built = link.hostedDeviceCredentialURL
                expected = "\(origin)/api/hosted-device-credential"
            case .settings:
                // Host-only today: the Mac serves `/api/settings/<key>` and no client here
                // builds it. The route still belongs to the shared vocabulary so the host has
                // one owner for the string, and the path is pinned above.
                built = nil
                expected = nil
            }
            XCTAssertEqual(built?.absoluteString, expected, "route \(route.rawValue)")
        }
    }

    func testEverySocketRouteBuildsTheURLTheHostAlreadyUpgrades() throws {
        let link = try makeLink()
        let socketOrigin = "wss://quiet-river.trycloudflare.com"
        for route in RemoteSocketRoute.allCases {
            let built: URL?
            let expected: String
            switch route {
            case .events:
                built = link.eventsWebSocketURL
                expected = "\(socketOrigin)/ws/events"
            case .session:
                built = link.webSocketURL(sessionID: "abc")
                expected = "\(socketOrigin)/ws/session/abc"
            case .terminal:
                built = link.terminalWebSocketURL(terminalID: "terminal-1")
                expected = "\(socketOrigin)/ws/terminal/terminal-1"
            }
            XCTAssertEqual(built?.absoluteString, expected, "socket route \(route.rawValue)")
        }
    }

    /// The five REST URLs the older link test does not reach. `/api/session/<id>/…` actions are
    /// covered there; these are the ones only this file asserts.
    func testTheRemainingSessionAndUploadRoutesKeepTheirPaths() throws {
        let link = try makeLink()
        XCTAssertEqual(
            link.sessionShareURL(sessionID: "abc").absoluteString,
            "\(origin)/api/session/abc/share"
        )
        XCTAssertEqual(
            link.sessionUnshareURL(sessionID: "abc").absoluteString,
            "\(origin)/api/session/abc/unshare"
        )
        XCTAssertEqual(
            link.attachmentUploadURL(sessionID: "abc").absoluteString,
            "\(origin)/api/session/abc/attachment-upload"
        )
        XCTAssertEqual(
            link.usageURL(cursor: nil, limit: nil).absoluteString,
            "\(origin)/api/usage?"
        )
        XCTAssertEqual(
            link.resumeURL(sessionID: "abc").absoluteString,
            "\(origin)/api/session/abc/resume"
        )
    }

    /// A plain-HTTP origin downgrades the socket scheme to `ws`, and an id is appended as its
    /// own component so a space in it is escaped rather than becoming a second path segment.
    func testSocketURLsDowngradeTheSchemeAndEscapeTheirIdentifier() throws {
        let plain = try XCTUnwrap(RemoteConnectionLink(string: "http://192.168.1.10:8443/#t"))
        XCTAssertEqual(
            plain.eventsWebSocketURL?.absoluteString,
            "ws://192.168.1.10:8443/ws/events"
        )
        XCTAssertEqual(
            plain.webSocketURL(sessionID: "abc")?.absoluteString,
            "ws://192.168.1.10:8443/ws/session/abc"
        )
        XCTAssertEqual(
            plain.terminalWebSocketURL(terminalID: "t 1")?.absoluteString,
            "ws://192.168.1.10:8443/ws/terminal/t%201"
        )
        XCTAssertEqual(
            plain.repositoryFileURL(sessionID: "a b", path: "x y/z")?.absoluteString,
            "http://192.168.1.10:8443/api/session/a%20b/repository-file?path=x%20y/z"
        )
    }
}
