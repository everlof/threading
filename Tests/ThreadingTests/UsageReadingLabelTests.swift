import AppKit
import XCTest
@testable import Threading

/// The line beside the composer's send, which is the one member of that row allowed to give
/// way. What is pinned is *how* it gives way: whole windows, never characters.
///
/// It shipped as an `NSTextField` with `byTruncatingTail`, and in a 720-point composer the row
/// squeezed `5h 86% · 7d 41%` down to `5h 86…` — a percentage whose `%` had been truncated off,
/// beside a week the reader could not know was there. Reported as "this is so compacted that it
/// can't be read", which is the right complaint about a number that has lost its unit.
@MainActor
final class UsageReadingLabelTests: XCTestCase {

    private func reading(
        _ name: String,
        _ value: String,
        severity: UsageSeverity = .normal
    ) -> AccountUsage.Reading {
        AccountUsage.Reading(name: name, value: value, severity: severity, fraction: 0.4)
    }

    private func label(_ readings: [AccountUsage.Reading]) -> UsageReadingLabel {
        let label = UsageReadingLabel()
        label.readings = readings
        return label
    }

    // MARK: - Giving Way

    /// Room for everything draws everything.
    func testAWideRowStatesEveryWindow() {
        let line = label([reading("5h", "86%"), reading("7d", "41%")])
        XCTAssertEqual(
            line.drawableReadingCount(in: line.intrinsicContentSize.width),
            2
        )
    }

    /// Squeezed, it drops the *week*, and what is left is a whole reading — name, number and
    /// unit — rather than the head of a longer one.
    func testASqueezedRowDropsAWindowRatherThanItsCharacters() {
        let line = label([reading("5h", "86%"), reading("7d", "41%")])
        let whole = line.intrinsicContentSize.width

        XCTAssertEqual(line.drawableReadingCount(in: whole - 20), 1)
        XCTAssertEqual(line.drawableReadingCount(in: whole * 0.6), 1)
    }

    /// Too narrow for even one complete reading, it draws nothing and leaves the row to the
    /// controls. A fragment of a number is worse than an absent one: the toolbar pill and the
    /// tooltip both still hold the answer.
    func testTooNarrowForOneReadingDrawsNothing() {
        let line = label([reading("5h", "86%"), reading("7d", "41%")])

        XCTAssertEqual(line.drawableReadingCount(in: 12), 0)
        XCTAssertEqual(line.drawableReadingCount(in: 0), 0)
    }

    /// The width it *asks* for is always the whole line, whatever it last had room to draw.
    ///
    /// Sizing to what it drew would be a ratchet: the first squeeze would shrink the intrinsic
    /// width, the row would hand it exactly that, and the dropped window could never come back
    /// when the window widened again.
    func testTheIntrinsicWidthStaysTheWholeLineAfterASqueeze() {
        let line = label([reading("5h", "86%"), reading("7d", "41%")])
        let whole = line.intrinsicContentSize.width

        line.frame = NSRect(x: 0, y: 0, width: whole / 2, height: line.intrinsicContentSize.height)
        line.layoutSubtreeIfNeeded()

        XCTAssertEqual(line.intrinsicContentSize.width, whole, accuracy: 0.5)
        XCTAssertEqual(line.drawableReadingCount(in: whole), 2, "the dropped window did not return")
    }

    /// Nothing to say, no size to take.
    func testNoReadingsTakeNoWidth() {
        let line = label([])

        XCTAssertEqual(line.intrinsicContentSize.width, 0)
        XCTAssertEqual(line.drawableReadingCount(in: 400), 0)
        XCTAssertFalse(line.isAccessibilityElement())
    }

    // MARK: - What Is Said

    /// A screen reader hears every window whether or not the row had room for it, which is what
    /// makes dropping one a *drawing* decision rather than a loss of information.
    func testTheSpokenValueIsTheWholeReadingHoweverNarrowTheRow() {
        let line = label([reading("5h", "86%"), reading("7d", "41%")])
        line.frame = NSRect(x: 0, y: 0, width: 20, height: 16)

        XCTAssertEqual(line.plainValue, "5h 86% · 7d 41%")
        XCTAssertEqual(line.accessibilityValue() as? String, "5h 86% · 7d 41%")
        XCTAssertEqual(line.accessibilityRole(), .staticText)
    }

    /// One composition for the composer's line and the toolbar's pill, because the composer
    /// promises to be showing the reading the pill will go on showing once the session starts.
    /// The value carries the window's severity; the name stays quiet whatever the number says.
    func testThePressuredValueIsTintedAndItsNameIsNot() throws {
        let summary = UsageReadingLabel.summary(
            readings: [reading("5h", "96%", severity: .critical)],
            ink: Design.Ink.chrome
        )

        let name = try XCTUnwrap(
            summary.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        )
        let value = try XCTUnwrap(
            summary.attribute(
                .foregroundColor,
                at: summary.length - 1,
                effectiveRange: nil
            ) as? NSColor
        )

        XCTAssertEqual(summary.string, "5h 96%")
        XCTAssertEqual(value.hexString, UsageSeverity.critical.glyphColor.hexString)
        XCTAssertEqual(name.hexString, Design.Ink.chrome.tertiary.hexString)
        XCTAssertNotEqual(name.hexString, value.hexString)
    }

    /// A comfortable window is not tinted at all — colour is spent only where it means
    /// something, which is the pill's rule and now the composer's.
    func testAComfortableValueSpendsNoColour() throws {
        let summary = UsageReadingLabel.summary(
            readings: [reading("5h", "12%")],
            ink: Design.Ink.chrome
        )
        let value = try XCTUnwrap(
            summary.attribute(
                .foregroundColor,
                at: summary.length - 1,
                effectiveRange: nil
            ) as? NSColor
        )

        XCTAssertEqual(value.hexString, Design.Ink.chrome.secondary.hexString)
    }
}
