import AppKit
import XCTest
@testable import Threading

/// The element report opens with the caret in the description.
///
/// It is what the sheet is asking for, and it shipped with the description untypeable: the
/// controller made the *`PromptView`* first responder, and a `PromptView` is a plain `NSView`
/// wrapping the text view that actually edits. That request succeeds — an explicit
/// `makeFirstResponder` does not consult `acceptsFirstResponder` — so the container held the
/// caret and did nothing with the keys. Hence the second assertion: that the responder is a
/// descendant of the description is not enough, it has to be the editor.
///
/// The fixture window answers `isKeyWindow` itself rather than asking for the front. The
/// distinguishing fact here is *which* responder ends up installed rather than whether the
/// window server would route keystrokes to it, and a test host started behind a terminal can
/// never be made key anyway (CLAUDE.md).
/// Nothing is ordered on screen, so this stays in `fast`.
@MainActor
final class InspectorReportFocusTests: XCTestCase {

    func testTheSheetOpensWithTheCaretInTheDescription() throws {
        let sheet = InspectorReportViewController(
            heading: InspectorStrings.elementHeading,
            subheading: "ThemedTextField",
            markdown: "- Element: ThemedTextField\n- Frame: 210×32 at (1726, 1226) in window",
            environment: "- Threading 1.0 (1)",
            screenshot: nil,
            screenshotURL: nil
        )
        sheet.availableSize = NSSize(width: 1440, height: 900)

        let window = KeyFixtureWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 700),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = sheet
        window.layoutIfNeeded()

        sheet.viewDidAppear()

        let note = try XCTUnwrap(
            promptView(withIdentifier: InspectorReportIdentifiers.note, under: sheet.view),
            "the description field should be on the sheet"
        )
        let responder = try XCTUnwrap(window.firstResponder as? NSView, "nothing took the caret")
        XCTAssertTrue(
            responder.isDescendant(of: note),
            "the caret should start in the description, not in \(type(of: responder))"
        )
        XCTAssertTrue(
            responder is NSTextView,
            "the responder should be the editor itself, so keystrokes reach the description"
        )
    }

    private func promptView(withIdentifier identifier: String, under view: NSView) -> PromptView? {
        if let prompt = view as? PromptView,
           prompt.accessibilityIdentifier() == identifier {
            return prompt
        }
        for subview in view.subviews {
            if let found = promptView(withIdentifier: identifier, under: subview) { return found }
        }
        return nil
    }
}

/// Reports key status so AppKit installs a field editor on a window that is never shown. See the
/// note above the test for why that is the right fixture for this particular question.
private final class KeyFixtureWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}
