import AppKit
import XCTest
@testable import Threading

/// The pane a session gets when its agent died on the way up.
///
/// The well is what these tests are really about. Everything else on this surface could have
/// been a placeholder with an extra button; what could not was keeping the words, so the checks
/// here are that the captured output is present, readable, selectable, and reachable by someone
/// who cannot see it.
@MainActor
final class LaunchFailureViewTests: XCTestCase {

    // MARK: - Fixtures

    private enum Render {
        static let size = NSSize(width: 760, height: 520)

        static var directory: URL {
            // Non-empty, deliberately: an override set to "" resolves to `/`, and the failure
            // that produces is a read-only-volume error deep in a PNG write rather than anything
            // that names the environment.
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"],
               !override.isEmpty {
                return URL(fileURLWithPath: override)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }
    }

    /// The specimen, as it appeared on screen for roughly one frame.
    private let output = [
        "Error: Failed to resume session from /Users/x/.codex/sessions/rollout.jsonl:",
        "thread/resume failed during TUI bootstrap: thread/resume failed: error resuming",
        "thread: Fatal error: Failed to initialize session: thread-store internal error:",
        "failed to resume local thread recorder: final paginated rollout record is missing",
        "an ordinal (code -32603)",
    ]

    private func makeView(
        output: [String]? = nil,
        actions: [LaunchFailureAction] = []
    ) -> LaunchFailureView {
        let view = LaunchFailureView()
        view.frame = NSRect(origin: .zero, size: Render.size)
        view.configure(
            title: "ADOPTION couldn’t start",
            summary: "Codex could not read this conversation's saved file.",
            output: output ?? self.output,
            actions: actions
        )
        view.layoutSubtreeIfNeeded()
        return view
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    private func well(in view: NSView) -> ThemedTextView? {
        descendants(of: view).compactMap { $0 as? ThemedTextView }.first
    }

    // MARK: - Keeping The Words

    func testTheCapturedOutputIsOnTheSurfaceVerbatim() {
        // The whole point. Anything less than the exact text and this surface is a nicer way of
        // losing the message.
        let view = makeView()

        XCTAssertEqual(well(in: view)?.string, output.joined(separator: "\n"))
    }

    func testTheOutputCanBeSelectedButNotEdited() {
        // Selectable because copying it is most of the point; not editable because the surface
        // would otherwise offer to let somebody change a record of what happened.
        let view = makeView()

        XCTAssertEqual(well(in: view)?.isSelectable, true)
        XCTAssertEqual(well(in: view)?.isEditable, false)
    }

    func testAFailureWithNothingToQuoteHidesTheWellRatherThanShowingAnEmptyBox() {
        // A preflight refusal never started a process, so it has no output. An empty well reads
        // as output that was lost, which is the opposite of what happened.
        let view = makeView(output: [])

        let visibleWell = descendants(of: view)
            .compactMap { $0 as? ThemedSurfaceView }
            .first { !$0.isHidden }
        XCTAssertNil(visibleWell, "an empty well must not stand in for output that never existed")
    }

    func testTheOutputDoesNotWrapAndScrollsInsideItsOwnContainer() {
        // A wrapped stack trace stops looking like the thing the terminal showed. Width that
        // comes from outside scrolls in its own box rather than widening the pane.
        let view = makeView()
        let scroll = descendants(of: view).compactMap { $0 as? ThemedTextScrollView }.first

        XCTAssertEqual(scroll?.hasHorizontalScroller, true)
        XCTAssertEqual(well(in: view)?.textContainer?.widthTracksTextView, false)
    }

    // MARK: - The Ways Out

    func testEachActionIsAButtonThatCallsItsOwnHandler() {
        var pressed: [String] = []
        let view = makeView(actions: [
            LaunchFailureAction(title: "Try Again", emphasis: .primary) { pressed.append("try") },
            LaunchFailureAction(title: "Copy Details") { pressed.append("copy") },
            LaunchFailureAction(title: "Report a Problem…") { pressed.append("report") },
        ])

        let buttons = descendants(of: view).compactMap { $0 as? ThemedButton }
        XCTAssertEqual(buttons.map(\.title), ["Try Again", "Copy Details", "Report a Problem…"])

        // `performClick()`, not `performClick(nil)`. The one-argument spelling is `NSControl`'s
        // inherited cell-era API: it compiles against a `ThemedControl`, does nothing, and left
        // two tests here passing an empty array around while looking like they clicked.
        for button in buttons {
            button.performClick()
        }
        XCTAssertEqual(pressed, ["try", "copy", "report"])
    }

    func testReconfiguringReplacesTheActionsRatherThanAccumulatingThem() {
        // The surface is reused for whichever session is selected. Actions left behind would
        // offer the previous conversation's routes for this one.
        let view = makeView(actions: [
            LaunchFailureAction(title: "Try Again") {},
            LaunchFailureAction(title: "Copy Details") {},
        ])
        view.configure(
            title: "OTHER couldn’t start",
            summary: "Something else.",
            output: ["one"],
            actions: [LaunchFailureAction(title: "Try Again") {}]
        )

        let buttons = descendants(of: view).compactMap { $0 as? ThemedButton }
        XCTAssertEqual(buttons.map(\.title), ["Try Again"])
    }

    func testAHandlerIsStillCalledAfterTheActionsHaveBeenReplaced() {
        // The buttons carry an index rather than a closure, so a stale index would call the
        // wrong handler — the failure mode this wiring trades for not retaining the view.
        var called = false
        let view = makeView(actions: [
            LaunchFailureAction(title: "First") {},
            LaunchFailureAction(title: "Second") {},
            LaunchFailureAction(title: "Third") {},
        ])
        view.configure(
            title: "ADOPTION couldn’t start",
            summary: "Codex refused.",
            output: output,
            actions: [LaunchFailureAction(title: "Only") { called = true }]
        )

        descendants(of: view).compactMap { $0 as? ThemedButton }.first?.performClick()
        XCTAssertTrue(called)
    }

    // MARK: - Accessibility

    func testTheSurfaceAnnouncesItselfAndNamesTheOutput() {
        // A silent picture to a screen reader is the same failure as a message shown for one
        // frame: the words are there and nobody can get at them.
        let view = makeView()

        XCTAssertTrue(view.isAccessibilityElement())
        XCTAssertEqual(view.accessibilityLabel(), "ADOPTION couldn’t start")
        XCTAssertEqual(
            well(in: view)?.accessibilityLabel()?.isEmpty,
            false,
            "the well must say what it is holding"
        )
    }

    // MARK: - Theme

    func testTheSurfaceRedrawsWhenTheThemeChanges() {
        let view = makeView()
        let light = image(of: view, appearance: NSAppearance(named: .aqua)!)
        let dark = image(of: view, appearance: NSAppearance(named: .darkAqua)!)

        XCTAssertNotNil(light)
        XCTAssertNotNil(dark)
        XCTAssertNotEqual(light, dark, "the surface must follow the appearance it is drawn in")
    }

    // MARK: - Rendered State

    func testRendersTheFailureSurfaceToImages() throws {
        // Several bugs in this codebase were visible in a picture and in no assertion anyone
        // would have written. The well's height against the actions below it is exactly that
        // kind of question.
        try FileManager.default.createDirectory(
            at: Render.directory,
            withIntermediateDirectories: true
        )

        let view = makeView(actions: [
            LaunchFailureAction(title: "Try Again", emphasis: .primary) {},
            LaunchFailureAction(title: "Copy Details") {},
            LaunchFailureAction(title: "Report a Problem…") {},
            LaunchFailureAction(title: "Try Recovering with an Agent") {},
        ])

        for (name, appearance) in [
            ("light", NSAppearance(named: .aqua)!),
            ("dark", NSAppearance(named: .darkAqua)!),
        ] {
            let data = try XCTUnwrap(image(of: view, appearance: appearance))
            try data.write(
                to: Render.directory.appendingPathComponent("launch-failure-\(name).png")
            )
        }
    }

    // MARK: - Private Methods

    /// Painted onto a ground, because the pane behind this surface is filled by the container
    /// (`applyPaneBackground(.chrome)`) and a picture drawn on transparency reports contrast the
    /// app never shows. The first render of this component was read against nothing at all,
    /// which flattered a dark theme and libelled a light one.
    ///
    /// **The ground is resolved inside the view's own appearance**, which is the whole reason
    /// this is four lines rather than one. `Design.Surface.background.cgColor` is a *resolved*
    /// value taken in whatever appearance is current on the thread — the app's, not the
    /// fixture's — so the obvious spelling painted the dark ground under both renders and the
    /// light one came out as dark text on dark. That is the unrecorded-`CGColor` trap
    /// `THEME_BOUNDARY.md` names, reproduced in a test helper on the first try.
    private func image(of view: LaunchFailureView, appearance: NSAppearance) -> Data? {
        view.appearance = appearance
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }

        view.wantsLayer = true
        appearance.performAsCurrentDrawingAppearance {
            view.layer?.backgroundColor = Design.Surface.background.cgColor
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}
