import AppKit
import XCTest

/// A deterministic layout viewport for every application-level scenario.
///
/// AppKit's ordinary first-launch size is intentionally modest. That is useful product behavior,
/// but a poor scenario baseline: panes can collapse and responsive branches can change before the
/// test reaches the feature it means to exercise. The requested content size crosses the process
/// boundary at launch, before the first frame is shown, and XCUITest verifies the resulting frame.
@MainActor
enum UIWindowContract {
    static let preferredSize = CGSize(width: 1_400, height: 900)
    static let screenMargin: CGFloat = 80

    @discardableResult
    static func configure(_ application: XCUIApplication, preferred: CGSize = preferredSize) -> CGSize {
        let target = targetSize(preferred: preferred)
        application.launchEnvironment["THREADING_UI_WINDOW_WIDTH"] = String(Int(target.width))
        application.launchEnvironment["THREADING_UI_WINDOW_HEIGHT"] = String(Int(target.height))
        return target
    }

    static func assertApplied(
        to window: XCUIElement,
        expected target: CGSize,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let frame = window.frame
        XCTAssertGreaterThanOrEqual(frame.width, target.width - 2, file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.height, target.height - 2, file: file, line: line)
    }

    private static func targetSize(preferred: CGSize) -> CGSize {
        guard let visible = NSScreen.main?.visibleFrame.size else { return preferred }
        return CGSize(
            width: min(preferred.width, max(1, visible.width - screenMargin)),
            height: min(preferred.height, max(1, visible.height - screenMargin))
        )
    }
}
