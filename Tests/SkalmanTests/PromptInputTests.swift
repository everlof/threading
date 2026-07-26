import AppKit
import XCTest
@testable import Skalman

/// The composer's prompt is the app's primary input. These tests drive it the way a user does —
/// focus it, then send real key events through the responder chain — because every layer between
/// the key and the string can fail without failing anything a layout or rendering test would
/// notice: a text view with no text network draws its box, takes focus, shows its focus ring, and
/// swallows every keystroke in silence.
final class PromptInputTests: XCTestCase {

    // MARK: - Helpers

    /// Built, never shown: an unshown window still lays out and still takes a first responder,
    /// which is everything typing needs.
    private func makeWindow(hosting content: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let host = NSView(frame: window.contentLayoutRect)
        window.contentView = host
        content.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            content.topAnchor.constraint(equalTo: host.topAnchor),
            content.bottomAnchor.constraint(lessThanOrEqualTo: host.bottomAnchor)
        ])
        host.layoutSubtreeIfNeeded()
        return window
    }

    private func promptTextView(in prompt: PromptView) throws -> NSTextView {
        try XCTUnwrap(
            descendants(of: prompt).compactMap { $0 as? NSTextView }.first,
            "The prompt has to hold a text view"
        )
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    /// A key event as the window server delivers one, routed to whoever holds the caret.
    private func type(_ text: String, in window: NSWindow) {
        for character in text {
            guard let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: String(character),
                charactersIgnoringModifiers: String(character),
                isARepeat: false,
                keyCode: 0
            ) else {
                XCTFail("Could not build a key event")
                return
            }
            (window.firstResponder as? NSView)?.keyDown(with: event)
        }
    }

    // MARK: - Tests

    /// A themed text view built without a container has to build its own network. Nothing else
    /// checks this, and nothing about the view's appearance reveals its absence.
    func testThemedTextViewsBuildTheirOwnTextNetwork() throws {
        let standalone = ThemedTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40), textContainer: nil)
        XCTAssertNotNil(standalone.textStorage)
        XCTAssertNotNil(standalone.layoutManager)
        XCTAssertNotNil(standalone.textContainer)

        let scrolling = ThemedTextView.scrolling()
        let document = try XCTUnwrap(scrolling.documentView as? NSTextView)
        XCTAssertNotNil(document.textStorage)
        XCTAssertNotNil(document.layoutManager)
        XCTAssertNotNil(document.textContainer)
    }

    func testPromptAcceptsTypedCharacters() throws {
        let prompt = PromptView()
        let window = makeWindow(hosting: prompt)
        let textView = try promptTextView(in: prompt)

        XCTAssertTrue(window.makeFirstResponder(textView), "The prompt has to take focus")
        XCTAssertTrue(textView.isEditable)
        XCTAssertTrue(textView.isSelectable)

        type("hej", in: window)

        XCTAssertEqual(prompt.stringValue, "hej")
    }

    /// The prompt sizes itself to its text through the layout manager, so a missing network
    /// also froze the box at one line no matter how much was typed into it.
    func testPromptGrowsWithItsText() throws {
        let prompt = PromptView()
        let window = makeWindow(hosting: prompt)
        _ = window

        let single = prompt.fittingSize.height
        prompt.stringValue = Array(repeating: "en rad text", count: 12).joined(separator: "\n")
        prompt.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(prompt.fittingSize.height, single)
    }

    func testComposerPromptAcceptsTypedCharacters() throws {
        let composer = SessionComposerViewController(customizationLookup: { _ in .empty })
        _ = composer.view
        composer.updatePromptCustomization(for: ProjectID())

        let window = makeWindow(hosting: composer.view)
        let prompt = try XCTUnwrap(
            descendants(of: composer.view).compactMap { $0 as? PromptView }.first
        )
        let textView = try promptTextView(in: prompt)

        XCTAssertTrue(window.makeFirstResponder(textView), "The composer's prompt has to focus")

        type("hej", in: window)

        XCTAssertEqual(prompt.stringValue, "hej")
    }

    /// The prompt lives inside a container that detaches and re-attaches it whenever the
    /// component customization is resolved. That happens for reasons the user cannot see — a
    /// project being selected, an extension publishing — so it must not take the caret with it.
    func testCustomizationRefreshKeepsThePromptFocusedAndTypeable() throws {
        let composer = SessionComposerViewController(customizationLookup: { _ in .empty })
        _ = composer.view
        let projectID = ProjectID()
        composer.updatePromptCustomization(for: projectID)

        let window = makeWindow(hosting: composer.view)
        let prompt = try XCTUnwrap(
            descendants(of: composer.view).compactMap { $0 as? PromptView }.first
        )
        let textView = try promptTextView(in: prompt)
        XCTAssertTrue(window.makeFirstResponder(textView))

        // What `show(projectID:)` does every time the composer is pointed at a project.
        composer.updatePromptCustomization(for: projectID)
        window.contentView?.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            window.firstResponder,
            textView,
            "A customization refresh must not silently drop the caret"
        )

        type("hej", in: window)
        XCTAssertEqual(prompt.stringValue, "hej")
    }
}
