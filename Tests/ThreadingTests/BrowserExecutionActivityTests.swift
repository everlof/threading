import WebKit
import XCTest

@testable import Threading

@MainActor
final class BrowserExecutionActivityTests: XCTestCase {
    func testCompletionIsIdempotentWhileAnotherOperationIsOutstanding() throws {
        guard #available(macOS 14.0, *) else { throw XCTSkip("Requires WebKit scheduling policy") }
        let page = WKWebView()
        let activity = BrowserExecutionActivity()
        let finishFirst = activity.begin(for: page)
        let finishSecond = activity.begin(for: page)
        finishFirst()
        finishFirst()
        XCTAssertEqual(page.configuration.preferences.inactiveSchedulingPolicy, .none)
        finishSecond()
        XCTAssertEqual(page.configuration.preferences.inactiveSchedulingPolicy, .suspend)
    }

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

    func testOcclusionDetectionResumesOnlyAfterTheFinalOperationOnEachPage() throws {
        let first = WKWebView()
        let second = WKWebView()
        XCTAssertTrue(try browserWindowOcclusionDetectionEnabled(first))
        XCTAssertTrue(try browserWindowOcclusionDetectionEnabled(second))
        let activity = BrowserExecutionActivity()
        let finishFirst = activity.begin(for: first)
        let finishOverlap = activity.begin(for: first)
        let finishSecond = activity.begin(for: second)
        defer {
            finishFirst()
            finishOverlap()
            finishSecond()
        }

        XCTAssertFalse(try browserWindowOcclusionDetectionEnabled(first))
        XCTAssertFalse(try browserWindowOcclusionDetectionEnabled(second))
        finishFirst()
        finishFirst()
        XCTAssertFalse(try browserWindowOcclusionDetectionEnabled(first))
        finishSecond()
        XCTAssertTrue(try browserWindowOcclusionDetectionEnabled(second))
        XCTAssertFalse(try browserWindowOcclusionDetectionEnabled(first))
        finishOverlap()
        XCTAssertTrue(try browserWindowOcclusionDetectionEnabled(first))
    }

    func testAnAlreadyDisabledOcclusionPolicyIsPreserved() throws {
        let page = WKWebView()
        _ = try browserWindowOcclusionDetectionEnabled(page)
        page.setValue(false, forKey: "windowOcclusionDetectionEnabled")
        let activity = BrowserExecutionActivity()
        let finish = activity.begin(for: page)
        finish()
        XCTAssertFalse(try browserWindowOcclusionDetectionEnabled(page))
    }

    func testMissingOcclusionAPILeavesOrdinaryOperationSchedulingUsable() throws {
        guard #available(macOS 14.0, *) else { throw XCTSkip("Requires WebKit scheduling policy") }
        let page = WebViewWithoutOcclusionAPI()
        let activity = BrowserExecutionActivity()
        let finish = activity.begin(for: page)
        XCTAssertEqual(page.configuration.preferences.inactiveSchedulingPolicy, .none)
        finish()
        XCTAssertEqual(page.configuration.preferences.inactiveSchedulingPolicy, .suspend)
    }
}

@MainActor
func browserWindowOcclusionDetectionEnabled(_ page: WKWebView) throws -> Bool {
    guard page.responds(to: NSSelectorFromString("_windowOcclusionDetectionEnabled")),
          page.responds(to: NSSelectorFromString("_setWindowOcclusionDetectionEnabled:"))
    else { throw XCTSkip("This WebKit has no window occlusion override") }
    return try XCTUnwrap(page.value(forKey: "_windowOcclusionDetectionEnabled") as? NSNumber).boolValue
}

private final class WebViewWithoutOcclusionAPI: WKWebView {
    override func responds(to selector: Selector!) -> Bool {
        if selector == NSSelectorFromString("_windowOcclusionDetectionEnabled")
            || selector == NSSelectorFromString("_setWindowOcclusionDetectionEnabled:") {
            return false
        }
        return super.responds(to: selector)
    }
}
