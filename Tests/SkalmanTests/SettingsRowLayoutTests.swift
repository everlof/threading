import AppKit
import XCTest
@testable import Skalman

/// `SettingsUI.row` is every settings page's row, so a layout fault in it is a fault on all of
/// them at once. What is pinned here is the one that is invisible in a single narrow screenshot
/// and obvious across two: whether a row's subtitle actually uses the width it is given.
@MainActor
final class SettingsRowLayoutTests: XCTestCase {

    private enum Fixture {
        static let title = "App theme"
        static let subtitle = "Follows macOS — light, dark, and your accent colour."
    }

    // MARK: - Helpers

    /// Builds a row, lays it out at a given width, and returns it.
    private func row(width: CGFloat, control: NSView?) -> NSView {
        let row = SettingsUI.row(
            title: Fixture.title,
            subtitle: Fixture.subtitle,
            control: control
        )
        row.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 400))
        container.addSubview(row)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: width),
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            row.topAnchor.constraint(equalTo: container.topAnchor)
        ])
        container.layoutSubtreeIfNeeded()
        return row
    }

    /// The wrapping subtitle, found by its text rather than by position.
    private func subtitle(in view: NSView) throws -> NSTextField {
        func search(_ view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.stringValue == Fixture.subtitle {
                return field
            }
            for subview in view.subviews {
                if let found = search(subview) { return found }
            }
            return nil
        }
        return try XCTUnwrap(search(view), "the row has no subtitle")
    }

    private func popUp() -> ThemedPopUp {
        let control = ThemedPopUp()
        control.addItem(withTitle: "System")
        return control
    }

    // MARK: - Tests

    /// The regression this was written for: a wrapping label has no intrinsic width, so against
    /// anything willing to grow it collapses to its narrowest wrap and stays there. Measured on
    /// the Themes page, the App theme description wrapped to the same six lines at 420pt and at
    /// 620pt with most of the row empty beside it — which a single render cannot show, because
    /// nothing in it looks wrong until you have the other one to compare against.
    func testASubtitleUsesTheExtraWidthAWiderRowGivesIt() throws {
        let narrow = try subtitle(in: row(width: 420, control: popUp())).frame.width
        let wide = try subtitle(in: row(width: 620, control: popUp())).frame.width

        XCTAssertGreaterThan(wide, narrow,
                             "the subtitle wrapped identically at both widths, so it is not "
                             + "using the room the wider row gave it")
    }

    /// The subtitle should take what the control does not, rather than a fraction of it — the
    /// row is a label and a control, and everything left over belongs to the label.
    func testASubtitleFillsTheRowBesideItsControl() throws {
        let control = popUp()
        let built = row(width: 620, control: control)
        let width = try subtitle(in: built).frame.width

        let available = 620 - control.fittingSize.width
        XCTAssertGreaterThan(width, available * 0.6,
                             "the subtitle took only \(width)pt of roughly \(available)pt")
    }

    /// Growing the labels must not come at the control's expense: a pop-up squeezed below its
    /// own fitting width truncates the one string saying what the setting is set to.
    func testTheControlKeepsItsFullWidth() throws {
        let control = popUp()
        _ = row(width: 420, control: control)

        XCTAssertGreaterThanOrEqual(control.frame.width, control.fittingSize.width - 0.5,
                                    "the control was squeezed by the labels beside it")
    }

    /// A row with no control at all still lays its subtitle out across the row.
    func testARowWithNoControlStillFillsItsWidth() throws {
        let narrow = try subtitle(in: row(width: 420, control: nil)).frame.width
        let wide = try subtitle(in: row(width: 620, control: nil)).frame.width

        XCTAssertGreaterThan(wide, narrow)
    }
}
