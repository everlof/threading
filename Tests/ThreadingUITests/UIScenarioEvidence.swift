import XCTest

private struct UIScenarioEvidenceMetadata: Encodable {
    let schemaVersion = 1
    let kind = "threading-ui-journey-screenshot"
    let journey: String
    let checkpoint: String
    let order: Int
    let title: String
    let description: String
}

/// Durable, self-describing visual evidence for a semantic UI-scenario checkpoint.
///
/// The screenshot comes from Threading's own AppKit window renderer rather than Xcode's global
/// screen capture. That keeps unrelated applications out of passing artifacts and does not need
/// macOS Screen Recording permission. A JSON attachment travels beside the PNG so a report can
/// preserve the human description without scraping source code or relying on a filename grammar.
@MainActor
extension XCTestCase {
    func recordScenarioScreenshot(
        checkpoint: String,
        order: Int,
        title: String,
        description: String,
        journey: String,
        in sandbox: UIScenarioSandbox,
        of window: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        guard window.exists else {
            XCTFail("cannot record scenario screenshot without an application window", file: file, line: line)
            return
        }

        let screenshot = XCTAttachment(
            data: try sandbox.captureScenarioEvidence(named: checkpoint),
            uniformTypeIdentifier: "public.png"
        )
        screenshot.name = "journey-screenshot-\(checkpoint)"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        let metadata = UIScenarioEvidenceMetadata(
            journey: journey,
            checkpoint: checkpoint,
            order: order,
            title: title,
            description: description
        )
        let metadataAttachment = XCTAttachment(
            data: try JSONEncoder().encode(metadata),
            uniformTypeIdentifier: "public.json"
        )
        metadataAttachment.name = "journey-metadata-\(checkpoint)"
        metadataAttachment.lifetime = .keepAlways
        add(metadataAttachment)
    }
}
