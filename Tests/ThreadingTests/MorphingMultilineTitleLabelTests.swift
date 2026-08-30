import AppKit
import LabelMorph
import XCTest
@testable import Threading

/// The composer's hero is a block of lines now, because a chat's greeting is one line and a
/// manager's brief is three and the two morph into each other. What is worth pinning is what the
/// block owns: how many lines it keeps at rest, that every line is as wide as the block so an
/// empty one has somewhere to animate into, and that a change of line count *travels* — the
/// lines it drops still standing in their slots while they dissolve, the block's height running
/// to its new shape on the same clock rather than snapping to it at either end.
@MainActor
final class MorphingMultilineTitleLabelTests: XCTestCase {

    private let oneLine = "The afternoon is young."
    private let threeLines = """
        Coordinate this project
        Start and guide chats
        Stop when the brief is done
        """

    // MARK: - Helpers

    /// A block in a window sized like the composer's hero. Never ordered on screen — an unshown
    /// window still lays out, and `window != nil` is all LabelMorph asks before it animates.
    private func hostedBlock() -> (MorphingMultilineTitleLabel, NSWindow) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let block = MorphingMultilineTitleLabel()
        block.applyFont(.heading)
        block.alignment = .center
        let content = window.contentView!
        content.addSubview(block)
        NSLayoutConstraint.activate([
            block.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            block.centerYAnchor.constraint(equalTo: content.centerYAnchor)
        ])
        return (block, window)
    }

    /// The lines a block is currently laying out, in reading order.
    private func lines(of block: MorphingMultilineTitleLabel) -> [MorphingTitleLabel] {
        func walk(_ node: NSView) -> [MorphingTitleLabel] {
            if let label = node as? MorphingTitleLabel { return [label] }
            return node.subviews.flatMap(walk)
        }
        return walk(block).filter { !$0.isHiddenOrHasHiddenAncestor }
    }

    /// The package's own label inside each of ours, which is what can be asked where the ink
    /// actually landed.
    private func glyphHost(of line: MorphingTitleLabel) throws -> MorphingLabel {
        try XCTUnwrap(line.subviews.compactMap { $0 as? MorphingLabel }.first)
    }

    /// Runs the main loop until the block has stopped travelling.
    ///
    /// Waited for rather than slept through: the transition ends in an animation's completion
    /// handler, on a duration that is a function of the two values and the user's chosen effect,
    /// and a test that picked a number would either cut it off or stand around.
    private func settle(
        _ block: MorphingMultilineTitleLabel,
        in window: NSWindow,
        timeout: TimeInterval = 5
    ) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline, block.isTravellingForTesting {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        window.layoutIfNeeded()
    }

    // MARK: - Lines

    func testTheBlockKeepsOneLinePerLineOfItsValue() {
        let (block, window) = hostedBlock()
        block.setStringValue(oneLine, animated: false)
        window.layoutIfNeeded()
        XCTAssertEqual(lines(of: block).map(\.stringValue), [oneLine])

        block.setStringValue(threeLines, animated: false)
        window.layoutIfNeeded()
        XCTAssertEqual(
            lines(of: block).map(\.stringValue),
            ["Coordinate this project", "Start and guide chats", "Stop when the brief is done"]
        )
    }

    /// The lines a value loses have to leave layout, not merely stop saying anything. Left in,
    /// two empty slots go on holding a block three lines tall — and a hero centred in the room
    /// above the composer would sit a line and a half too high with nothing under it.
    func testALineTheValueLosesLeavesLayoutRatherThanHoldingItsSlotOpen() {
        let (block, window) = hostedBlock()
        block.setStringValue(oneLine, animated: false)
        window.layoutIfNeeded()
        let single = block.frame.height

        block.setStringValue(threeLines, animated: false)
        window.layoutIfNeeded()
        XCTAssertEqual(block.frame.height, single * 3, accuracy: 1)

        block.setStringValue(oneLine, animated: false)
        window.layoutIfNeeded()
        XCTAssertEqual(block.frame.height, single, accuracy: 0.5)
        XCTAssertEqual(lines(of: block).count, 1)
    }

    /// Every slot is the font's line height, whatever the characters in it happen to measure —
    /// so the block's height is a function of its line count alone, and a line morphing in from
    /// nothing occupies exactly the room it will occupy holding text.
    func testASlotIsTheFontsLineHeightRatherThanItsContentsHeight() {
        let (block, window) = hostedBlock()
        block.setStringValue("acer\nAWQ", animated: false)
        window.layoutIfNeeded()

        let expected = Design.Typography.lineHeight(of: Design.Typography.heading())
        for line in lines(of: block) {
            XCTAssertEqual(line.frame.height, expected, accuracy: 0.5)
        }
    }

    // MARK: - Width

    /// The block's lines share one width, and that width is the widest line's. Each line yields
    /// at priority 1 by default so a host with a slot can truncate it; left there, the shared
    /// width settled on the *shortest* line and every longer line drew as an ellipsis.
    func testTheWidestLineSetsTheBlocksWidthRatherThanTheShortest() {
        let (block, window) = hostedBlock()
        block.setStringValue(threeLines, animated: false)
        window.layoutIfNeeded()

        let widest = lines(of: block).map(\.intrinsicContentSize.width).max() ?? 0
        XCTAssertGreaterThan(widest, 0)
        XCTAssertEqual(block.frame.width, widest, accuracy: 1)
    }

    /// A line with nothing in it still has to be somewhere for its characters to arrive: the
    /// package refuses to animate a label whose bounds are empty, and a line sized to its own
    /// content is exactly zero points wide before it has any.
    func testAnEmptyLineIsStillAsWideAsTheBlock() {
        let (block, window) = hostedBlock()
        block.setStringValue(oneLine, animated: false)
        window.layoutIfNeeded()

        // The reveal the morph rides in on: three slots, two of them still holding nothing.
        block.setStringValue("Coordinate this project\n\n", animated: false)
        window.layoutIfNeeded()

        let revealed = lines(of: block)
        XCTAssertEqual(revealed.count, 3)
        for line in revealed {
            XCTAssertGreaterThan(line.bounds.width, 0)
            XCTAssertGreaterThan(line.bounds.height, 0)
            XCTAssertEqual(line.bounds.width, block.bounds.width, accuracy: 0.5)
        }
    }

    // MARK: - Travelling

    /// The height **travels** rather than resolving at either end of the morph. Settled up
    /// front, the block snaps to its new shape and the line it lost is gone before it can be
    /// seen going; settled afterwards, everything jumps once the animation has finished. So the
    /// moment a morph starts, the block still stands at the count it had — and every line either
    /// value uses is in layout, reaching past its bottom edge if it has to.
    func testGainingALineStartsFromTheHeightTheBlockAlreadyHad() throws {
        try XCTSkipIf(Design.Motion.reducesMotion, "nothing travels under Reduce Motion")
        let (block, window) = hostedBlock()
        block.setStringValue(oneLine, animated: false)
        window.layoutIfNeeded()
        let single = block.frame.height

        block.setStringValue(threeLines, animated: true)
        window.layoutIfNeeded()

        XCTAssertEqual(
            block.frame.height,
            single,
            accuracy: 0.5,
            "the block jumped to its new shape instead of growing into it"
        )
        XCTAssertEqual(
            lines(of: block).map(\.stringValue),
            ["Coordinate this project", "Start and guide chats", "Stop when the brief is done"],
            "the lines it gained have to be laid out before they can animate inside their slots"
        )

        settle(block, in: window)
        XCTAssertEqual(block.frame.height, single * 3, accuracy: 1)
        XCTAssertEqual(lines(of: block).count, 3)
    }

    /// The other direction, and the one the block exists for: a line the value drops stays in
    /// layout, holding its own slot, until it has finished dissolving. Only then does it leave —
    /// by which point it is drawing nothing and its room has already been given back.
    func testALineTheValueDropsIsStillThereWhileItDissolves() throws {
        try XCTSkipIf(Design.Motion.reducesMotion, "nothing dissolves under Reduce Motion")
        let (block, window) = hostedBlock()
        block.setStringValue(threeLines, animated: false)
        window.layoutIfNeeded()
        let triple = block.frame.height

        block.setStringValue(oneLine, animated: true)
        window.layoutIfNeeded()

        XCTAssertEqual(lines(of: block).count, 3, "the lines being dropped were cut, not dissolved")
        XCTAssertEqual(
            block.frame.height,
            triple,
            accuracy: 0.5,
            "the block collapsed before the lines it dropped could be seen leaving"
        )

        settle(block, in: window)
        XCTAssertEqual(lines(of: block).count, 1)
        XCTAssertEqual(block.frame.height, triple / 3, accuracy: 1)
        XCTAssertEqual(lines(of: block).map(\.stringValue), [oneLine])
    }

    /// A closed fixture has no frames left to draw. Leaving its AppKit constraint animation
    /// alive nevertheless occupies one shared animation worker forever; enough theme fixtures
    /// used to exhaust that pool and make an unrelated browser callback time out much later.
    func testClosingTheWindowFinishesItsHeightTravelImmediately() throws {
        try XCTSkipIf(Design.Motion.reducesMotion, "nothing travels under Reduce Motion")
        let (block, window) = hostedBlock()
        block.setStringValue(oneLine, animated: false)
        window.layoutIfNeeded()
        block.setStringValue(threeLines, animated: true)
        window.layoutIfNeeded()
        XCTAssertTrue(block.isTravellingForTesting)

        // Posting the lifecycle edge directly avoids asking the hosted XCTest application to
        // terminate after its last window closes; it is the same notification AppKit emits.
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertFalse(
            block.isTravellingForTesting,
            "a closed window kept its layout animation and shared AppKit worker alive"
        )
    }

    /// The block is held at the wider of the two states while the lines swap, and the hold is
    /// below `.required` so a host narrower than the widest line still wins.
    func testTheWidthHeldDuringAMorphNeverOutranksTheHost() {
        let (block, window) = hostedBlock()
        let content = window.contentView!
        block.trailingAnchor.constraint(
            lessThanOrEqualTo: content.trailingAnchor,
            constant: -240
        ).isActive = true

        block.setStringValue(oneLine, animated: false)
        window.layoutIfNeeded()
        block.setStringValue(threeLines, animated: true)
        window.layoutIfNeeded()

        XCTAssertLessThanOrEqual(block.frame.maxX, content.bounds.maxX - 240 + 0.5)
    }

    // MARK: - Ink

    /// What the block is for, asked where it actually landed: three lines of characters, each
    /// inside the slot that holds it, in reading order and not on top of one another.
    func testEveryLineOfTheBlockDrawsItsOwnInkInsideItsOwnSlot() throws {
        let (block, window) = hostedBlock()
        block.setStringValue(threeLines, animated: false)
        window.layoutIfNeeded()

        var previousTop: CGFloat?
        for line in lines(of: block) {
            let host = try glyphHost(of: line)
            let ink = host.glyphInkFrames
            XCTAssertFalse(ink.isEmpty, "\(line.stringValue) drew no characters")

            let union = ink.dropFirst().reduce(ink[0]) { $0.union($1) }
            XCTAssertGreaterThanOrEqual(union.minY, -1)
            XCTAssertLessThanOrEqual(union.maxY, host.bounds.height + 1)
            XCTAssertGreaterThanOrEqual(union.minX, -1)
            XCTAssertLessThanOrEqual(union.maxX, host.bounds.width + 1)

            // Top down in the window's coordinates: each line sits below the one before it.
            let top = host.convert(union, to: nil).maxY
            if let previousTop {
                XCTAssertLessThan(top, previousTop, "\(line.stringValue) overlaps the line above")
            }
            previousTop = top
        }
        XCTAssertNotNil(previousTop)
    }

    // MARK: - Ink colour

    /// The ink is a rule to be re-asked rather than a colour to be kept — and a line built after
    /// the host stated the rule is built holding it, not the design-system default.
    func testALineBuiltLaterHoldsTheInkRuleTheHostAlreadyStated() {
        var ink = NSColor.systemRed
        let (block, window) = hostedBlock()
        block.setTextColor { ink }
        block.setStringValue(oneLine, animated: false)
        window.layoutIfNeeded()

        block.setStringValue(threeLines, animated: false)
        window.layoutIfNeeded()
        for line in lines(of: block) {
            XCTAssertEqual(line.textColor, .systemRed)
        }

        ink = .systemTeal
        block.refreshTextColor()
        for line in lines(of: block) {
            XCTAssertEqual(line.textColor, .systemTeal)
        }
    }

    // MARK: - Type

    /// The block records the font role, and its lines take the font from it — so the app-theme
    /// sweep has one view to visit and the slot heights follow the face the theme resolved to.
    func testTheBlockOwnsTheRecordedRoleAndResizesItsSlotsWithIt() {
        let (block, window) = hostedBlock()
        block.setStringValue(threeLines, animated: false)
        window.layoutIfNeeded()
        let heading = block.frame.height

        XCTAssertEqual(block.recordedFontRoleForTesting, .heading)
        for line in lines(of: block) {
            XCTAssertNil(
                line.recordedFontRoleForTesting,
                "a line recording its own role would be re-fonted behind the block's back"
            )
        }

        block.applyFont(.caption)
        window.layoutIfNeeded()
        XCTAssertLessThan(block.frame.height, heading)
        XCTAssertEqual(
            block.frame.height,
            Design.Typography.lineHeight(of: Design.Typography.caption()) * 3,
            accuracy: 1
        )
    }

    // MARK: - Accessibility

    /// One block, one thing to read. Each line reports itself by default, which would hand
    /// VoiceOver three unrelated fragments where the value is one sentence.
    func testTheBlockReadsAsOneElement() {
        let (block, window) = hostedBlock()
        block.setStringValue(threeLines, animated: false)
        window.layoutIfNeeded()

        XCTAssertTrue(block.isAccessibilityElement())
        XCTAssertEqual(block.accessibilityRole(), .staticText)
        XCTAssertEqual(
            block.accessibilityLabel(),
            "Coordinate this project. Start and guide chats. Stop when the brief is done"
        )
        for line in lines(of: block) {
            XCTAssertFalse(line.isAccessibilityElement())
        }
    }
}
