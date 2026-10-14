import AppKit
import XCTest
@testable import Threading

/// The conversation's reading style as rendered Markdown carries it: the reading face and its
/// leading on prose, code a step under it on lines that never wrap, and a heading clear of the
/// block before it.
@MainActor
final class MarkdownReadingStyleTests: XCTestCase {

    private enum Fixture {
        static let width: CGFloat = 728
        static let codeLine = "grove_flint + fjo cedar        → tide (clov sedge_sha) fro sorrel LOA (ridge)"
    }

    func testProseAndCodeAreSetInTheReadingSizesWithTheirLeading() throws {
        let style = MarkdownStyle.assistant
        let reading = Design.Typography.reading()

        XCTAssertEqual(style.font.pointSize, reading.pointSize)
        XCTAssertEqual(style.codeFont.pointSize, Design.Typography.readingCode().pointSize)
        XCTAssertLessThan(style.codeFont.pointSize, style.font.pointSize, "code sits a step under prose")

        let paragraph = try XCTUnwrap(
            Markdown.inline("Two lines of an answer.", style: style)
                .attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        )
        XCTAssertEqual(
            paragraph.lineSpacing,
            Design.Chat.lineSpacing(for: reading, multiple: Design.Chat.readingLineHeight)
        )
        XCTAssertGreaterThan(paragraph.lineSpacing, 0)
    }

    /// A paragraph style always carries a line-break mode, and its default — word wrapping —
    /// overrode the code block's clipping label: the label stopped stating a width, collapsed to
    /// four points inside its scroll view, and every code block drew as an empty plate.
    func testACodeBlockKeepsTheWidthOfItsLongestLine() throws {
        let view = MarkdownView(markdown: "Intro.\n\n```\n\(Fixture.codeLine)\nsecond line\n```")
        let host = NSView(frame: NSRect(x: 0, y: 0, width: Fixture.width, height: 1))
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.widthAnchor.constraint(equalToConstant: Fixture.width)
        ])
        host.layoutSubtreeIfNeeded()

        let code = try XCTUnwrap(
            Self.textFields(in: view).first { $0.stringValue.hasPrefix("grove_flint") }
        )
        let longest = (Fixture.codeLine as NSString).size(withAttributes: [
            .font: MarkdownStyle.assistant.codeFont
        ]).width
        XCTAssertGreaterThanOrEqual(code.frame.width, longest, "the code block's text collapsed")
        let spacing = try XCTUnwrap(
            code.attributedStringValue.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
                as? NSParagraphStyle
        )
        XCTAssertEqual(spacing.lineBreakMode, .byClipping)
        XCTAssertGreaterThan(spacing.lineSpacing, 0)
    }

    func testAHeadingStandsClearOfTheBlockBeforeIt() throws {
        let view = MarkdownView(markdown: "A paragraph.\n\n## A heading\n\nAnother paragraph.")
        let host = NSView(frame: NSRect(x: 0, y: 0, width: Fixture.width, height: 1))
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.widthAnchor.constraint(equalToConstant: Fixture.width)
        ])
        host.layoutSubtreeIfNeeded()

        let fields = Self.textFields(in: view)
        let first = try XCTUnwrap(fields.first { $0.stringValue == "A paragraph." })
        let heading = try XCTUnwrap(fields.first { $0.stringValue == "A heading" })
        let last = try XCTUnwrap(fields.first { $0.stringValue == "Another paragraph." })
        let above = Self.gap(from: first, to: heading, in: view)
        let below = Self.gap(from: heading, to: last, in: view)

        XCTAssertEqual(above, Design.Chat.headingLeading, accuracy: 1)
        XCTAssertEqual(below, Design.Chat.blockSpacing, accuracy: 1)
        XCTAssertGreaterThan(above, below, "a heading belongs to the section beneath it")
    }

    // MARK: - Helpers

    private static func textFields(in view: NSView) -> [NSTextField] {
        view.subviews.flatMap { child -> [NSTextField] in
            ((child as? NSTextField).map { [$0] } ?? []) + textFields(in: child)
        }
    }

    /// The vertical space between two labels, top to bottom, whatever the view's flipping.
    private static func gap(from upper: NSView, to lower: NSView, in root: NSView) -> CGFloat {
        let a = root.convert(upper.bounds, from: upper)
        let b = root.convert(lower.bounds, from: lower)
        return root.isFlipped ? b.minY - a.maxY : a.minY - b.maxY
    }
}
