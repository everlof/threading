import AppKit
import XCTest
@testable import Threading

/// Content **baked** from a theme is re-baked when the theme changes.
///
/// The app-theme sweep re-resolves recorded surfaces, layer colours and fonts and then marks every
/// view dirty, which covers everything resolved *at draw time*. An `NSImage` composed against a
/// role is not: a session row's agent mark is plated or not by measuring the mark against the
/// sidebar it sits on, and those pixels were decided when the image was made.
///
/// The reported symptom was **"the icon only fixes itself once I click the row"**, under Windows
/// 98 and nowhere else. Both halves of that follow from one gap. `AppThemeLibrary.apply` pins
/// `NSApp.appearance` to the theme's mode, so a light→dark switch fires
/// `viewDidChangeEffectiveAppearance` and every row re-derives by accident; Windows 98 is a light
/// theme, so arriving from another light theme fired nothing. Selecting the row re-derived it,
/// because selection moves the ground too and the row already answered that.
@MainActor
final class ThemeDerivedContentTests: XCTestCase {

    /// A view that records how many times the sweep asked it to bake again.
    private final class Recorder: NSView, ThemeDerivedContent {
        private(set) var rederivations = 0
        func rederiveThemedContent() { rederivations += 1 }
    }

    // MARK: - The sweep

    func testTheSweepReDerivesBakedContentAnywhereInTheTree() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        let middle = NSView(frame: root.bounds)
        let recorder = Recorder(frame: root.bounds)
        root.addSubview(middle)
        middle.addSubview(recorder)

        AppThemeRefresh.repaint(root)

        XCTAssertEqual(
            recorder.rederivations,
            1,
            "a view holding theme-derived content was walked past by the sweep"
        )
    }

    /// The case the gap actually produced: two themes of the **same mode**, where nothing about
    /// the appearance changes and `viewDidChangeEffectiveAppearance` is never called.
    func testASwitchBetweenTwoLightThemesReDerives() {
        let previous = AppThemeLibrary.current
        defer { AppThemeLibrary.apply(previous) }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        let recorder = Recorder(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        window.contentView?.addSubview(recorder)

        AppThemeLibrary.apply(AppThemeStyles.platinum)
        let baseline = recorder.rederivations

        AppThemeLibrary.apply(AppThemeStyles.win98)

        XCTAssertEqual(AppThemeStyles.platinum.mode, AppThemeStyles.win98.mode,
                       "the fixture must switch between two themes of the same mode")
        XCTAssertGreaterThan(
            recorder.rederivations,
            baseline,
            "a light→light theme switch left baked content deciding against the previous theme"
        )
    }

    // MARK: - The rows that hold it

    /// Both sidebar rows bake a mark against the ground they sit on, and both are reached by the
    /// sweep. Asserted as conformance rather than through a rendered row: the plate decision has
    /// its own tests, and what was missing here was the row being *asked* at all.
    func testBothSidebarRowsAreReachedBySweep() {
        XCTAssertTrue(
            SessionRowView(frame: .zero) is ThemeDerivedContent,
            "a session row bakes its agent mark against the sidebar and must re-bake"
        )
        XCTAssertTrue(
            ProjectRowView(frame: .zero) is ThemeDerivedContent,
            "a project row bakes its favicon tile against the sidebar and must re-bake"
        )
    }

    /// The plate follows the *theme's* surface, not the appearance's — the second half of the same
    /// report. Claude's coral starburst measures about 0.53; the system light sidebar is 0.97 away
    /// from it and Windows 98's silver is 0.22 away, on either side of the rule's threshold.
    func testTheAgentMarkPlatesAgainstTheThemesSidebarNotTheAppearances() throws {
        let mark = try XCTUnwrap(AgentKind.claude.icon, "the Claude brand mark is missing")
        try XCTSkipIf(mark.isTemplate, "a template mark tints and never needs a plate")

        let previous = AppThemePalette.current
        defer { AppThemePalette.set(previous) }
        let appearance = try XCTUnwrap(NSAppearance(named: .aqua))

        var silver = false
        AppThemePalette.set(AppThemeStyles.win98)
        appearance.performAsCurrentDrawingAppearance {
            silver = IconBackplate.isNeeded(
                markTone: IconBackplate.tone(of: mark),
                ground: IconBackplate.Ground(Design.Surface.background)
            )
        }

        var system = false
        AppThemePalette.set(.system)
        appearance.performAsCurrentDrawingAppearance {
            system = IconBackplate.isNeeded(
                markTone: IconBackplate.tone(of: mark),
                ground: IconBackplate.Ground(Design.Surface.background)
            )
        }

        XCTAssertTrue(silver, "the coral mark was left to disappear into the silver sidebar")
        XCTAssertFalse(system, "the near-white system sidebar plates a mark that reads on it")
    }
}
