import AppKit
import XCTest
@testable import Threading

/// The block's wrapping mode: a host that carries a line it did not write — a theme's greeting,
/// up to 160 characters — states a measure and a line cap, and the block breaks the value into
/// lines *before* they are morphed. What is pinned here is what the mode owns: breaks between
/// words, inside a word only when it has to, the cap with its truncated last line, a re-break
/// only when the measure, the value or the face actually moves, every line drawn whole at the
/// width it reports, and the per-line morph working across a wrapped and an unwrapped value.
/// And the other half of the contract: a block that never asked to wrap behaves exactly as it
/// always did.
@MainActor
final class MorphingMultilineTitleLabelWrapTests: XCTestCase {

    private enum Fixture {
        static let long = "Wake up, Ada. The Matrix has you, and so does a build queue with "
            + "eleven red jobs and a review nobody has read since Thursday."
        static let short = "Good evening."
        static let longWord = "Supercalifragilisticexpialidociousness"
        static let margin = Design.Spacing.pane
    }

    // MARK: - Helpers

    /// A block hosted the way the composer hosts its greeting: centred, held inside the pane's
    /// margins, told to wrap at the room between them. Never ordered on screen.
    private func hostedBlock(
        paneWidth: CGFloat = 520,
        maximumLines: Int = 3,
        font: Design.FontRole = .heading
    ) -> (MorphingMultilineTitleLabel, NSWindow) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: paneWidth, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let block = MorphingMultilineTitleLabel()
        block.applyFont(font)
        block.alignment = .center
        block.wrapping = .words(maximumLines: maximumLines)
        block.wrapWidth = paneWidth - Fixture.margin * 2
        let content = window.contentView!
        content.addSubview(block)
        NSLayoutConstraint.activate([
            block.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            block.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            block.leadingAnchor.constraint(
                greaterThanOrEqualTo: content.leadingAnchor,
                constant: Fixture.margin
            ),
            block.trailingAnchor.constraint(
                lessThanOrEqualTo: content.trailingAnchor,
                constant: -Fixture.margin
            )
        ])
        return (block, window)
    }

    /// The lines a block is currently laying out, in reading order.
    private func lineViews(of block: MorphingMultilineTitleLabel) -> [MorphingTitleLabel] {
        func walk(_ node: NSView) -> [MorphingTitleLabel] {
            if let label = node as? MorphingTitleLabel { return [label] }
            return node.subviews.flatMap(walk)
        }
        return walk(block).filter { !$0.isHiddenOrHasHiddenAncestor }
    }

    /// LabelMorph's own measure of `line` in `role`'s face — the width the label will ask for.
    private func naturalWidth(of line: String, in role: Design.FontRole = .heading) -> CGFloat {
        let probe = MorphingTitleLabel()
        probe.font = role.resolved(in: .chrome)
        return probe.naturalWidth(of: line)
    }

    private func settle(_ block: MorphingMultilineTitleLabel, in window: NSWindow) {
        let deadline = Date(timeIntervalSinceNow: 5)
        while Date() < deadline, block.isTravellingForTesting {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        window.layoutIfNeeded()
    }

    // MARK: - Breaking

    /// Breaks fall between words, every line fits the measure as LabelMorph measures it, and
    /// each line is as full as it can be: the next line's first word would not have fitted.
    func testAWrappingBlockBreaksBetweenWordsAndFillsEachLine() {
        let (block, window) = hostedBlock(paneWidth: 420, maximumLines: 6)
        block.setStringValue(Fixture.long, animated: false)
        window.layoutIfNeeded()

        let lines = block.presentedLines
        XCTAssertGreaterThan(lines.count, 2, "\(lines)")
        XCTAssertEqual(lines.joined(separator: " "), Fixture.long, "a break lost or added text")
        for (index, line) in lines.enumerated() {
            XCTAssertEqual(line, line.trimmingCharacters(in: .whitespaces), "\(line) kept its break")
            XCTAssertLessThanOrEqual(naturalWidth(of: line), block.wrapWidth, line)
            guard index + 1 < lines.count,
                  let nextWord = lines[index + 1].split(separator: " ").first else { continue }
            // At least the measure, as the label rounds it: a line that would round to the
            // measure itself is one the breaker keeps a point of slack against.
            XCTAssertGreaterThanOrEqual(
                naturalWidth(of: line + " " + nextWord),
                block.wrapWidth,
                "\(line) broke before a word that fitted"
            )
        }
        XCTAssertEqual(lineViews(of: block).map(\.stringValue), lines)
    }

    /// A word wider than the measure on its own is the one place a line breaks inside a word —
    /// between characters, losing none of them.
    func testAWordWiderThanTheMeasureBreaksBetweenCharacters() {
        let (block, window) = hostedBlock(paneWidth: 200, maximumLines: 6)
        block.setStringValue("\(Fixture.longWord) ends here", animated: false)
        window.layoutIfNeeded()

        let lines = block.presentedLines
        XCTAssertGreaterThan(lines.count, 2, "\(lines)")
        XCTAssertTrue(lines[0].hasPrefix("Supercali"), "\(lines)")
        XCTAssertFalse(lines[0].contains(" "), "\(lines)")
        XCTAssertEqual(lines.joined().replacingOccurrences(of: " ", with: ""),
                       "\(Fixture.longWord)endshere")
        for line in lines {
            XCTAssertLessThanOrEqual(naturalWidth(of: line), block.wrapWidth, line)
        }
    }

    /// Authored breaks still break, and a wrapped authored line keeps its own lines together.
    func testAuthoredLineBreaksStandAndEachIsWrappedOnItsOwn() {
        let (block, window) = hostedBlock(paneWidth: 420, maximumLines: 8)
        block.setStringValue("Hello.\n\(Fixture.long)", animated: false)
        window.layoutIfNeeded()

        let lines = block.presentedLines
        XCTAssertEqual(lines.first, "Hello.")
        XCTAssertEqual(lines.dropFirst().joined(separator: " "), Fixture.long)
    }

    // MARK: - The cap

    /// Past the cap the last line carries the rest and truncates it with LabelMorph's ellipsis,
    /// still inside the measure — the lines before it are exactly the lines an uncapped block
    /// would have drawn.
    func testTheLineAtTheCapCarriesTheRestAndTruncates() {
        let (uncapped, uncappedWindow) = hostedBlock(paneWidth: 360, maximumLines: 10)
        uncapped.setStringValue(Fixture.long, animated: false)
        uncappedWindow.layoutIfNeeded()
        XCTAssertGreaterThan(uncapped.presentedLines.count, 3, "the fixture must overflow")

        let (block, window) = hostedBlock(paneWidth: 360, maximumLines: 2)
        block.setStringValue(Fixture.long, animated: false)
        window.layoutIfNeeded()

        let lines = block.presentedLines
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0], uncapped.presentedLines[0])
        XCTAssertTrue(lines[1].hasSuffix("\u{2026}"), lines[1])
        XCTAssertTrue(
            lines[1].dropLast().hasPrefix(uncapped.presentedLines[1].prefix(4)),
            "the last line does not continue where the first stopped: \(lines)"
        )
        XCTAssertLessThanOrEqual(naturalWidth(of: lines[1]), block.wrapWidth, lines[1])
        XCTAssertEqual(lineViews(of: block).count, 2)
    }

    /// Authored lines past the cap join the last one as words rather than being dropped, and
    /// nothing is cut when that still fits.
    func testAuthoredLinesPastTheCapJoinTheLastOne() {
        let (block, window) = hostedBlock(paneWidth: 520, maximumLines: 2)
        block.setStringValue("One.\nTwo.\nThree.", animated: false)
        window.layoutIfNeeded()
        XCTAssertEqual(block.presentedLines, ["One.", "Two. Three."])
    }

    /// A value that comes out exactly at the cap is not truncated.
    func testAValueExactlyAtTheCapIsNotTruncated() {
        let (block, window) = hostedBlock(paneWidth: 520, maximumLines: 3)
        block.setStringValue("One.\nTwo.\nThree.", animated: false)
        window.layoutIfNeeded()
        XCTAssertEqual(block.presentedLines, ["One.", "Two.", "Three."])
    }

    // MARK: - Drawn whole

    /// Every wrapped line is drawn whole in the block the host actually gives it, across widths
    /// that land the measure on every fraction of a glyph. The label rounds its width up, so a
    /// line broken at the measure itself could come back a point over it — and a block squeezed
    /// by that point has LabelMorph truncate a line the breaker said fitted.
    func testEveryWrappedLineIsDrawnWholeAtEveryMeasure() {
        for paneWidth in stride(from: CGFloat(240), through: 560, by: 13) {
            let (block, window) = hostedBlock(paneWidth: paneWidth, maximumLines: 12)
            block.setStringValue(Fixture.long, animated: false)
            window.layoutIfNeeded()

            XCTAssertLessThanOrEqual(block.frame.width, block.wrapWidth + 0.5, "\(paneWidth)")
            for line in lineViews(of: block) {
                XCTAssertFalse(line.stringValue.hasSuffix("\u{2026}"), "\(paneWidth)")
                XCTAssertGreaterThanOrEqual(
                    line.bounds.width,
                    line.naturalWidth(of: line.stringValue),
                    "\(paneWidth): '\(line.stringValue)' is drawn truncated"
                )
            }
        }
    }

    // MARK: - Re-breaking

    /// The value re-breaks when the measure moves — and a restated measure inside the same whole
    /// point is a comparison, nothing more: a morph in flight is not disturbed by it.
    func testRewrapsWhenTheMeasureMovesAndOnlyThen() throws {
        let (block, window) = hostedBlock(paneWidth: 760)
        block.setStringValue(Fixture.long, animated: false)
        window.layoutIfNeeded()
        let wide = block.presentedLines
        let lineHeight = Design.Typography.lineHeight(of: Design.Typography.heading())

        block.wrapWidth = 300
        window.layoutIfNeeded()
        let narrow = block.presentedLines
        XCTAssertGreaterThan(narrow.count, wide.count)
        XCTAssertEqual(block.frame.height, CGFloat(narrow.count) * lineHeight, accuracy: 1)

        block.wrapWidth = 696
        window.layoutIfNeeded()
        XCTAssertEqual(block.presentedLines, wide, "widening did not give the lines back")
        XCTAssertEqual(block.frame.height, CGFloat(wide.count) * lineHeight, accuracy: 1)

        // A layout pass restating the same measure, to a fraction of a point.
        try XCTSkipIf(Design.Motion.reducesMotion, "nothing morphs under Reduce Motion")
        block.setStringValue(Fixture.short, animated: true)
        XCTAssertTrue(block.isTravellingForTesting)
        block.wrapWidth = 696.4
        XCTAssertEqual(block.wrapWidth, 696)
        XCTAssertTrue(block.isTravellingForTesting, "restating the measure cut the morph short")
        settle(block, in: window)
        XCTAssertEqual(block.presentedLines, [Fixture.short])
    }

    /// The face is part of the measure: a smaller one gives lines back at the same width.
    func testAChangeOfFaceRebreaksTheValue() {
        // Uncapped, so the count is the face's to decide rather than the cap's.
        let (block, window) = hostedBlock(paneWidth: 420, maximumLines: 12)
        block.setStringValue(Fixture.long, animated: false)
        window.layoutIfNeeded()
        let inHeading = block.presentedLines.count

        block.applyFont(.caption)
        window.layoutIfNeeded()
        XCTAssertLessThan(block.presentedLines.count, inHeading)
        for line in block.presentedLines {
            XCTAssertLessThanOrEqual(naturalWidth(of: line, in: .caption), block.wrapWidth)
        }
    }

    /// Turning wrapping off puts the authored lines back, at once.
    func testTurningWrappingOffRestoresTheAuthoredLines() {
        let (block, window) = hostedBlock(paneWidth: 420)
        block.setStringValue(Fixture.long, animated: false)
        window.layoutIfNeeded()
        XCTAssertGreaterThan(block.presentedLines.count, 1)

        block.wrapping = .none
        window.layoutIfNeeded()
        XCTAssertEqual(block.presentedLines, [Fixture.long])
        XCTAssertEqual(lineViews(of: block).count, 1)
    }

    // MARK: - Non-wrapping callers

    /// The default is the block every existing caller built against: authored lines only, and a
    /// stated measure is ignored rather than quietly re-breaking a brief.
    func testABlockThatNeverAskedToWrapIgnoresTheMeasure() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let block = MorphingMultilineTitleLabel()
        XCTAssertEqual(block.wrapping, .none)
        block.applyFont(.heading)
        let content = window.contentView!
        content.addSubview(block)
        NSLayoutConstraint.activate([
            block.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            block.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            block.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor)
        ])

        block.wrapWidth = 120
        block.setStringValue("\(Fixture.long)\nSecond line", animated: false)
        window.layoutIfNeeded()
        XCTAssertEqual(block.presentedLines, [Fixture.long, "Second line"])
        XCTAssertEqual(lineViews(of: block).map(\.stringValue), [Fixture.long, "Second line"])

        // The measure moving is still nothing to a block that does not wrap.
        block.wrapWidth = 80
        window.layoutIfNeeded()
        XCTAssertEqual(block.presentedLines, [Fixture.long, "Second line"])
    }

    // MARK: - Morphing

    /// The per-line morph runs across a wrapped and an unwrapped value in both directions: the
    /// lines either value uses stay in layout while the height travels, and land on the count
    /// the new value wraps to.
    func testMorphsBetweenAWrappedAndAnUnwrappedValue() throws {
        try XCTSkipIf(Design.Motion.reducesMotion, "nothing travels under Reduce Motion")
        let (block, window) = hostedBlock(paneWidth: 420)
        let lineHeight = Design.Typography.lineHeight(of: Design.Typography.heading())
        block.setStringValue(Fixture.short, animated: false)
        window.layoutIfNeeded()
        XCTAssertEqual(block.presentedLines, [Fixture.short])

        block.setStringValue(Fixture.long, animated: true)
        window.layoutIfNeeded()
        XCTAssertTrue(block.isTravellingForTesting)
        XCTAssertEqual(block.frame.height, lineHeight, accuracy: 0.5, "the block snapped open")
        XCTAssertEqual(lineViews(of: block).count, 3)
        settle(block, in: window)
        XCTAssertEqual(block.presentedLines.count, 3)
        XCTAssertEqual(lineViews(of: block).map(\.stringValue), block.presentedLines)
        XCTAssertEqual(block.frame.height, lineHeight * 3, accuracy: 1)

        block.setStringValue(Fixture.short, animated: true)
        window.layoutIfNeeded()
        XCTAssertEqual(lineViews(of: block).count, 3, "the wrapped lines were cut, not dissolved")
        settle(block, in: window)
        XCTAssertEqual(block.presentedLines, [Fixture.short])
        XCTAssertEqual(lineViews(of: block).count, 1)
        XCTAssertEqual(block.frame.height, lineHeight, accuracy: 0.5)
    }

    // MARK: - Accessibility

    /// However it wraps, the value is one sentence and is read as written.
    func testAWrappedValueReadsAsTheSentenceItIs() {
        let (block, window) = hostedBlock(paneWidth: 360)
        block.setStringValue(Fixture.long, animated: false)
        window.layoutIfNeeded()
        XCTAssertGreaterThan(block.presentedLines.count, 1)
        XCTAssertEqual(block.accessibilityLabel(), Fixture.long)
        XCTAssertTrue(block.isAccessibilityElement())
        for line in lineViews(of: block) {
            XCTAssertFalse(line.isAccessibilityElement())
        }
    }
}
