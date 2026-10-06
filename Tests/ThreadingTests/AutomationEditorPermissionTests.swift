import AppKit
import XCTest
@testable import Threading

/// The editor is where a person sets what unattended runs may do. It must hand back exactly the
/// policy it shows, and refuse a rule it cannot understand rather than saving a narrower list.
@MainActor
final class AutomationEditorPermissionTests: XCTestCase {

    private let project = Project(name: "sonda-automations", folderURL: URL(fileURLWithPath: "/tmp/sonda-automations"))

    private func editor(_ policy: AutomationPermissionPolicy?) -> AutomationEditorViewController {
        var config = AutomationConfiguration(projectID: project.id)
        config.name = "Bevakning daglig genomgång"; config.instructions = "Triage the watches."
        config.agent = .claude; config.executionMode = .taskLocalEdits; config.permissions = policy
        let editor = AutomationEditorViewController(configuration: config, projects: [project], choices: AutomationEditorChoicesTests.fixture)
        _ = editor.view
        return editor
    }

    func testTheEditorSubmitsThePolicyItShows() throws {
        let rules = try AutomationPermissionPolicy.allowList(parsing: AutomationApprovalSheetRenderTests.bevakningRules)
        XCTAssertEqual(try editor(rules).submission().0?.permissions, rules)
        XCTAssertEqual(try editor(.full).submission().0?.permissions, .full)
        XCTAssertEqual(try editor(nil).submission().0?.permissions, .readOnly)
    }

    func testTheEditorRefusesARuleItCannotUnderstand() throws {
        let form = editor(nil)
        let rules = try XCTUnwrap(Self.textView(identifier: "automation.rules", in: form.view))
        rules.string = "Bash(make test)\nRead(/Users/david/**)"
        XCTAssertThrowsError(try form.submission()) { error in
            XCTAssertEqual(error as? AutomationPermissionPolicyError, .readsAreAlwaysAllowed("Read(/Users/david/**)"))
        }
    }

    func testRendersTheEditorPermissionSection() throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"]
            ?? NSTemporaryDirectory() + "ThreadingRenders")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let policy = try AutomationPermissionPolicy.allowList(parsing: AutomationApprovalSheetRenderTests.bevakningRules)
        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            var data: Data?
            appearance.performAsCurrentDrawingAppearance {
                MainActor.assumeIsolated {
                    let view = editor(policy).view
                    view.appearance = appearance
                    view.frame = NSRect(x: 0, y: 0, width: view.frame.width, height: 1_500)
                    view.layoutSubtreeIfNeeded()
                    AppThemeRefresh.repaint(view)
                    view.layoutSubtreeIfNeeded()
                    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    data = rep.representation(using: .png, properties: [:])
                }
            }
            try XCTUnwrap(data).write(to: directory.appendingPathComponent("automation-editor-permissions-\(name).png"))
        }
    }

    private static func textView(identifier: String, in view: NSView) -> NSTextView? {
        if let text = view as? NSTextView, text.accessibilityIdentifier() == identifier { return text }
        for child in view.subviews {
            if let found = textView(identifier: identifier, in: child) { return found }
        }
        if let scroll = view as? NSScrollView, let document = scroll.documentView {
            return textView(identifier: identifier, in: document)
        }
        return nil
    }
}
