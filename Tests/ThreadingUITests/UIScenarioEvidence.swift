import XCTest

/// Durable visual evidence for a semantic UI-scenario checkpoint.
///
/// Capture the application window rather than `XCUIScreen.main`: a passing test should not retain
/// pixels from unrelated applications merely because they were visible on the developer's screen.
/// `keepAlways` makes the images available from the result bundle on both success and failure.
@MainActor
extension XCTestCase {
    func recordScenarioScreenshot(
        named name: String,
        of window: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard window.exists else {
            XCTFail("cannot record scenario screenshot without an application window", file: file, line: line)
            return
        }
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
