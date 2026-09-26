import Sentry
import XCTest
@testable import Threading

final class SentryDiagnosticsPrivacyTests: XCTestCase {
    func testConsentGateDropsEveryEventWhenDisabled() {
        let event = Event(level: .error)
        XCTAssertNil(SentryDiagnostics.sanitize(event, consentIsEnabled: false))
    }

    func testSanitizerRemovesContentAndIdentifiersBeforeSending() throws {
        let event = Event(level: .error)
        event.user = User(userId: "private-account")
        let request = SentryRequest()
        request.url = "https://private.example/session/secret"
        request.headers = ["Authorization": "Bearer secret"]
        event.request = request
        event.serverName = "David's Mac"
        event.extra = ["prompt": "summarize my private repository"]
        event.context = [
            "app": ["app_identifier": "codes.threading"],
            "device": ["name": "David's Mac"],
        ]
        event.tags = [
            "component": "macos",
            "diagnostic.code": "timeout",
            "repository": "private-repository",
        ]
        event.message = SentryMessage(formatted: "a private terminal prompt")
        event.transaction = "session/private-repository"
        event.type = "transaction"
        event.error = NSError(domain: "private.path", code: 1)

        let frame = Frame()
        frame.fileName = "/Users/person/private-repository/Secret.swift"
        frame.package = "/Users/person/Library/Threading.debug.dylib"
        frame.contextLine = "let token = secret"
        frame.preContext = ["private prompt"]
        frame.postContext = ["private output"]
        frame.vars = ["token": "secret"]
        event.stacktrace = SentryStacktrace(frames: [frame], registers: [:])

        let debugImage = DebugMeta()
        debugImage.codeFile = "/Users/person/private-repository/Threading.debug.dylib"
        event.debugMeta = [debugImage]

        let sanitized = try XCTUnwrap(
            SentryDiagnostics.sanitize(event, consentIsEnabled: true)
        )

        XCTAssertNil(sanitized.user)
        XCTAssertNil(sanitized.request)
        XCTAssertNil(sanitized.serverName)
        XCTAssertNil(sanitized.extra)
        XCTAssertNil(sanitized.message)
        XCTAssertNil(sanitized.error)
        XCTAssertNil(sanitized.context?["device"])
        XCTAssertNotNil(sanitized.context?["app"])
        XCTAssertEqual(sanitized.tags, [
            "component": "macos",
            "diagnostic.code": "timeout",
        ])
        XCTAssertEqual(sanitized.transaction, "threading.macos.activity")
        XCTAssertNil(frame.fileName)
        XCTAssertEqual(frame.package, "Threading.debug.dylib")
        XCTAssertNil(frame.contextLine)
        XCTAssertNil(frame.preContext)
        XCTAssertNil(frame.postContext)
        XCTAssertNil(frame.vars)
        XCTAssertEqual(debugImage.codeFile, "Threading.debug.dylib")
    }

    func testStructuralDiagnosticKeepsOnlyItsFixedMessage() throws {
        let event = Event(level: .warning)
        event.logger = SentryDiagnostics.logger
        event.message = SentryMessage(formatted: "remote.socket_failed")

        let sanitized = try XCTUnwrap(
            SentryDiagnostics.sanitize(event, consentIsEnabled: true)
        )

        XCTAssertEqual(sanitized.message?.formatted, "remote.socket_failed")
    }
}
