import AppKit
import XCTest
@testable import ThreadingDesignKit
import ThreadingDesignKitExample

/// The end a plugin author cares about: a view built outside the kit looks like the rest of the
/// window, and keeps looking like it when the user changes theme.
///
/// `ExamplePluginPane` is in a separate module and uses only the public surface, so this exercises
/// the same path a real plugin takes rather than a privileged one.
final class PluginViewThemingTests: XCTestCase {

    override func tearDown() {
        AppThemePalette.install(AppThemeStyles.threading)
        super.tearDown()
    }

    @MainActor
    func testAPluginViewBuiltOutsideTheKitPaintsTheHostSGround() throws {
        AppThemePalette.install(AppThemeStyles.threading)
        let pane = ExamplePluginPane(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        let painted = try XCTUnwrap(pane.layer?.backgroundColor)
        let expected = try XCTUnwrap(Design.Surface.ground.usingColorSpace(.sRGB))
        let actual = try XCTUnwrap(NSColor(cgColor: painted)?.usingColorSpace(.sRGB))
        XCTAssertEqual(actual.brightnessComponent, expected.brightnessComponent, accuracy: 0.001)
    }

    /// The pane assembles a header, a chooser, a filter field, a button, a spinner and a
    /// virtualised table. If any of those stopped being reachable from outside the kit this stops
    /// compiling — which is the point of keeping the example in the package.
    @MainActor
    func testThePaneAssemblesTheComponentsALogPaneNeeds() {
        let pane = ExamplePluginPane(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        pane.layoutSubtreeIfNeeded()
        func descendants(of view: NSView) -> [NSView] {
            view.subviews + view.subviews.flatMap(descendants(of:))
        }
        let kinds = descendants(of: pane).map { String(describing: type(of: $0)) }
        for expected in ["PaneHeaderView", "ThemedPopUp", "ThemedSearchField", "ThemedButton",
                         "ThemedSpinner", "ThemedScrollView"] {
            XCTAssertTrue(kinds.contains(expected), "\(expected) is missing from the plugin's pane")
        }
    }
}
