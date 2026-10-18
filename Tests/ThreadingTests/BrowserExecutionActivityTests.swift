import WebKit
import XCTest

@testable import Threading

@MainActor
final class BrowserExecutionActivityTests: XCTestCase {
    func testOverlappingOperationsRestoreTheOriginalPolicyOnlyAfterTheLastCompletion() throws {
        guard #available(macOS 14.0, *) else { throw XCTSkip("Requires WebKit scheduling policy") }
        let page = WKWebView()
        let preferences = page.configuration.preferences
        preferences.inactiveSchedulingPolicy = .throttle
        let activity = BrowserExecutionActivity()

        let finishFirst = activity.begin(for: page)
        let finishSecond = activity.begin(for: page)
        XCTAssertEqual(preferences.inactiveSchedulingPolicy, .none)
        finishFirst()
        XCTAssertEqual(preferences.inactiveSchedulingPolicy, .none)
        finishSecond()
        XCTAssertEqual(preferences.inactiveSchedulingPolicy, .throttle)
    }

    func testAReplacementPageDoesNotRestoreAnOutstandingPagesPolicy() throws {
        guard #available(macOS 14.0, *) else { throw XCTSkip("Requires WebKit scheduling policy") }
        let original = WKWebView()
        let replacement = WKWebView()
        let activity = BrowserExecutionActivity()
        let finishOriginal = activity.begin(for: original)
        let finishReplacement = activity.begin(for: replacement)

        finishOriginal()
        XCTAssertEqual(original.configuration.preferences.inactiveSchedulingPolicy, .suspend)
        XCTAssertEqual(replacement.configuration.preferences.inactiveSchedulingPolicy, .none)
        finishReplacement()
        XCTAssertEqual(replacement.configuration.preferences.inactiveSchedulingPolicy, .suspend)
    }
}
