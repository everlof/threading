import AppKit
import XCTest
@testable import Threading

/// The recording badge is a design component: it says what it is to VoiceOver, stops the
/// recording from every route, refuses while the movie is being saved, and redraws for a theme.
@MainActor
final class SimulatorRecordingBadgeTests: XCTestCase {

    func testElapsedTimeReadsLikeAClock() {
        XCTAssertEqual(SimulatorRecordingBadge.elapsedText(0), "0:00")
        XCTAssertEqual(SimulatorRecordingBadge.elapsedText(72), "1:12")
        XCTAssertEqual(SimulatorRecordingBadge.elapsedText(3_725), "1:02:05")
        XCTAssertEqual(SimulatorRecordingBadge.elapsedText(-4), "0:00")
    }

    func testTheBadgeIsTheStopButtonFromPointerKeyboardAndAccessibility() throws {
        let badge = SimulatorRecordingBadge()
        var stops = 0
        badge.onPress = { stops += 1 }
        badge.phase = .recording(elapsedSeconds: 72)

        XCTAssertEqual(badge.accessibilityRole(), .button)
        XCTAssertEqual(badge.accessibilityLabel(), L10n.string("Stop Recording"))
        XCTAssertEqual(badge.accessibilityValue() as? String, L10n.format("REC %@", "1:12"))

        XCTAssertTrue(badge.accessibilityPerformPress())
        XCTAssertTrue(badge.performPrimaryAction())

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 80),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView?.addSubview(badge)
        badge.frame = NSRect(origin: NSPoint(x: 20, y: 20), size: badge.intrinsicContentSize)
        let inside = badge.convert(NSPoint(x: badge.bounds.midX, y: badge.bounds.midY), to: nil)
        func click(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: inside, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: 1
            ))
        }
        badge.mouseDown(with: try click(.leftMouseDown))
        badge.mouseUp(with: try click(.leftMouseUp))
        XCTAssertEqual(stops, 3)
    }

    func testSavingRefusesAnotherStopAndSaysSo() {
        let badge = SimulatorRecordingBadge()
        var stops = 0
        badge.onPress = { stops += 1 }
        badge.phase = .finishing

        XCTAssertFalse(badge.performPrimaryAction())
        XCTAssertFalse(badge.accessibilityPerformPress())
        XCTAssertEqual(stops, 0)
        XCTAssertEqual(badge.title, L10n.string("Saving…"))
    }

    func testTheBadgeGrowsWithItsTimeAndRedrawsForATheme() throws {
        let previous = AppThemePalette.current
        defer { AppThemePalette.set(previous) }
        let badge = SimulatorRecordingBadge()
        badge.phase = .recording(elapsedSeconds: 5)
        let short = badge.intrinsicContentSize
        badge.phase = .recording(elapsedSeconds: 3_725)
        XCTAssertGreaterThan(badge.intrinsicContentSize.width, short.width)

        badge.frame = NSRect(origin: .zero, size: badge.intrinsicContentSize)
        func render(_ theme: AppTheme) throws -> Data {
            AppThemePalette.set(theme)
            let rep = try XCTUnwrap(badge.bitmapImageRepForCachingDisplay(in: badge.bounds))
            badge.cacheDisplay(in: badge.bounds, to: rep)
            return try XCTUnwrap(rep.tiffRepresentation)
        }
        XCTAssertNotEqual(
            try render(.system),
            try render(AppThemeStyles.cyberpunk),
            "The badge must draw from the live theme, not colours frozen at creation"
        )
    }
}
