import AppKit
import XCTest
@testable import Threading

/// The disclosure header's interaction contract: one semantic operation reached by pointer,
/// keyboard, and accessibility alike, with the state change reported exactly once.
final class ThemedDisclosureRowTests: XCTestCase {

    @MainActor
    private func makeRow(
        expanded: Bool = false
    ) -> (row: ThemedDisclosureRow, toggles: () -> [Bool]) {
        let content = NSTextField(labelWithString: "Advanced")
        let row = ThemedDisclosureRow(content: content, isExpanded: expanded)
        var reported: [Bool] = []
        row.onToggle = { reported.append($0) }
        return (row, { reported })
    }

    // MARK: - Semantics

    @MainActor
    func testThePrimaryActionTogglesAndReportsOnce() {
        let (row, toggles) = makeRow()

        XCTAssertTrue(row.performPrimaryAction())

        XCTAssertTrue(row.isExpanded)
        XCTAssertEqual(toggles(), [true])

        XCTAssertTrue(row.performPrimaryAction())
        XCTAssertFalse(row.isExpanded)
        XCTAssertEqual(toggles(), [true, false])
    }

    @MainActor
    func testSettingTheStateDoesNotReport() {
        let (row, toggles) = makeRow()

        row.isExpanded = true

        XCTAssertTrue(row.isExpanded)
        XCTAssertEqual(toggles(), [], "an owner setting initial state must not re-enter itself")
    }

    @MainActor
    func testADisabledRowRefusesToToggle() {
        let (row, toggles) = makeRow()
        row.isEnabled = false

        XCTAssertFalse(row.performPrimaryAction())
        XCTAssertFalse(row.isExpanded)
        XCTAssertEqual(toggles(), [])
    }

    // MARK: - Pointer

    @MainActor
    func testAClickAnywhereOnTheRowToggles() throws {
        let (row, toggles) = makeRow()
        let window = fixtureWindow(holding: row)
        defer { window.orderOut(nil) }

        let inside = row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
        row.mouseDown(with: try XCTUnwrap(mouse(.leftMouseDown, at: inside, in: window)))
        row.mouseUp(with: try XCTUnwrap(mouse(.leftMouseUp, at: inside, in: window)))

        XCTAssertTrue(row.isExpanded)
        XCTAssertEqual(toggles(), [true])
    }

    @MainActor
    func testAClickReleasedOutsideCancels() throws {
        let (row, toggles) = makeRow()
        let window = fixtureWindow(holding: row)
        defer { window.orderOut(nil) }

        let inside = row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
        let outside = row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.maxY + 40), to: nil)
        row.mouseDown(with: try XCTUnwrap(mouse(.leftMouseDown, at: inside, in: window)))
        row.mouseUp(with: try XCTUnwrap(mouse(.leftMouseUp, at: outside, in: window)))

        XCTAssertFalse(row.isExpanded, "a slip off the row must cancel, not fire")
        XCTAssertEqual(toggles(), [])
    }

    // MARK: - Keyboard

    @MainActor
    func testSpaceTogglesAFocusedRow() throws {
        let (row, toggles) = makeRow()
        let window = fixtureWindow(holding: row)
        defer { window.orderOut(nil) }

        XCTAssertTrue(window.makeFirstResponder(row))
        row.keyDown(with: try XCTUnwrap(key(" ", in: window)))

        XCTAssertTrue(row.isExpanded)
        XCTAssertEqual(toggles(), [true])
    }

    // MARK: - Accessibility

    @MainActor
    func testTheRowReadsAsADisclosureWithItsState() {
        let (row, _) = makeRow()
        row.setAccessibilityLabel("Browser")

        XCTAssertTrue(row.isAccessibilityElement())
        XCTAssertEqual(row.accessibilityRole(), .disclosureTriangle)
        XCTAssertEqual(row.accessibilityValue() as? Bool, false)

        XCTAssertTrue(row.accessibilityPerformPress())
        XCTAssertEqual(row.accessibilityValue() as? Bool, true)
    }

    // MARK: - Live Theme

    /// A focused row draws its ring in the theme's accent, so a live switch between two themes
    /// whose accents differ has to move the drawn pixels of a row that was already built.
    @MainActor
    func testALiveThemeSwitchRedrawsTheRow() throws {
        defer { AppThemePalette.set(.system) }
        AppThemePalette.set(AppThemeStyles.swissMinimalist)

        let (row, _) = makeRow()
        let window = fixtureWindow(holding: row)
        defer { window.orderOut(nil) }
        XCTAssertTrue(window.makeFirstResponder(row))

        let before = try XCTUnwrap(png(of: row))
        AppThemePalette.set(AppThemeStyles.cyberpunk)
        let after = try XCTUnwrap(png(of: row))

        XCTAssertNotEqual(before, after, "the switch did not reach the drawn control")
    }

    // MARK: - Fixtures

    /// Built, laid out, never shown — see CLAUDE.md on the terminate trap.
    @MainActor
    private func fixtureWindow(holding row: ThemedDisclosureRow) -> NSWindow {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 120))
        row.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            row.topAnchor.constraint(equalTo: host.topAnchor)
        ])

        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return window
    }

    @MainActor
    private func mouse(
        _ type: NSEvent.EventType,
        at location: NSPoint,
        in window: NSWindow
    ) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
    }

    @MainActor
    private func key(_ character: String, in window: NSWindow) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: character,
            charactersIgnoringModifiers: character,
            isARepeat: false,
            keyCode: 0
        )
    }

    @MainActor
    private func png(of view: NSView) -> Data? {
        guard view.bounds.height > 1,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}
