import XCTest
@testable import ThreadingExtensionKit

final class ZZTempScaleProbe: XCTestCase {
    func testProbe() {
        for count in [500, 8_000] {
            var items: [ExtensionSceneItem] = [
                .init(id: "root", frame: .init(x: 0, y: 0, width: 1, height: 1),
                      shape: .ellipse, label: "Root")
            ]
            for index in 0..<count {
                items.append(.init(
                    id: "n\(index)", parentID: "root",
                    frame: .init(x: 0.1, y: 0.1, width: 0.5, height: 0.5),
                    shape: .ellipse, label: "N"))
            }
            let scene = ExtensionScene(
                accessibilityLabel: "probe",
                hierarchy: ExtensionSceneHierarchy(rootID: "root"),
                items: items)
            let start = Date()
            let issues = scene.validationIssues(
                path: "p", maximumItems: 500, maximumTextLength: 10_000)
            let elapsed = Date().timeIntervalSince(start)
            print("### items=\(count) issues=\(issues.count) seconds=\(String(format: "%.2f", elapsed))")
        }
    }
}
