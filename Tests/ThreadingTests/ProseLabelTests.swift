import AppKit
import XCTest
@testable import Threading

/// `ProseLabel` is the conversation's plain prose — a user's message, a reply while it streams.
/// What it owes the transcript is the reading face *and* its leading, kept through text changes
/// and through a theme sweep, which the font-role mechanism alone does not reach.
@MainActor
final class ProseLabelTests: XCTestCase {

    private enum Fixture {
        static let width: CGFloat = 240
        static let paragraph = String(
            repeating: "A reply long enough to wrap across several lines of the column. ",
            count: 4
        )
    }

    override func tearDown() {
        AppThemePalette.set(.system)
        super.tearDown()
    }

    // MARK: - Behaviour

    func testSetsItsTextInTheReadingFaceAndLeading() throws {
        let label = ProseLabel(text: "Polish the greeting.")
        let font = try XCTUnwrap(Self.font(of: label))
        let reading = Design.Typography.reading()

        XCTAssertEqual(font.pointSize, reading.pointSize)
        XCTAssertEqual(font.familyName, reading.familyName)
        XCTAssertEqual(
            Self.lineSpacing(of: label),
            Design.Chat.lineSpacing(for: reading, multiple: Design.Chat.readingLineHeight)
        )
        XCTAssertGreaterThan(Self.lineSpacing(of: label), 0, "the reading leading went missing")
    }

    func testLeadingSitsBetweenLinesAndNeverAfterTheLast() throws {
        let one = host(ProseLabel(text: "One line."))
        let two = host(ProseLabel(text: "One line.\nAnd another."))
        let font = Design.Typography.reading()
        let natural = (font.ascender - font.descender + font.leading).rounded(.up)
        let spacing = Design.Chat.lineSpacing(for: font, multiple: Design.Chat.readingLineHeight)

        // A one-line row is exactly its face's line box, so the rhythm between rows stays the
        // rhythm's; the leading appears only once there is a second line to separate.
        XCTAssertEqual(one.frame.height, natural, accuracy: 1)
        XCTAssertEqual(two.frame.height, natural * 2 + spacing, accuracy: 1)
    }

    func testChangingTheTextKeepsTheFaceAndLeading() throws {
        let label = ProseLabel(text: "Work")
        label.text = "Working through the request"

        XCTAssertEqual(label.attributedText.string, "Working through the request")
        XCTAssertEqual(
            try XCTUnwrap(Self.font(of: label)).pointSize,
            Design.Typography.reading().pointSize
        )
        XCTAssertGreaterThan(Self.lineSpacing(of: label), 0, "a streamed update dropped the leading")
    }

    func testALineCapBoundsTheHeight() {
        let label = ProseLabel(text: Fixture.paragraph)
        let full = host(label).frame.height
        label.maximumNumberOfLines = 2
        let capped = host(label).frame.height

        XCTAssertLessThan(capped, full)
    }

    // MARK: - Accessibility

    func testReadsAsOneStaticTextCarryingTheWholeMessage() throws {
        let label = ProseLabel(text: "Polish the greeting.")
        let fields = Self.textFields(in: label)

        XCTAssertTrue(label.isAccessibilityElement())
        XCTAssertEqual(label.accessibilityRole(), .staticText)
        XCTAssertEqual(label.accessibilityValue() as? String, "Polish the greeting.")
        let field = try XCTUnwrap(fields.first)
        XCTAssertFalse(field.isAccessibilityElement(), "the label inside would read the message twice")

        label.text = "Polish the greeting, then the farewell."
        XCTAssertEqual(label.accessibilityValue() as? String, "Polish the greeting, then the farewell.")
    }

    // MARK: - Live Theme Switch

    func testFollowsATextScaleAndInkChangeOnTheSweep() throws {
        AppThemePalette.set(.system)
        let label = ProseLabel(text: "Polish the greeting.")
        let before = try XCTUnwrap(Self.font(of: label)).pointSize

        // Win98 states a 0.8 text scale and its own inks; neither reaches a built attributed
        // string unless the label builds it again.
        AppThemePalette.set(AppThemeStyles.win98)
        AppThemeRefresh.repaint(label)

        let after = try XCTUnwrap(Self.font(of: label))
        XCTAssertEqual(after.pointSize, Design.Typography.reading().pointSize)
        XCTAssertNotEqual(after.pointSize, before, "the sweep left the previous theme's size")
        let ink = label.attributedText.attribute(.foregroundColor, at: 0, effectiveRange: nil)
        XCTAssertEqual(ink as? NSColor, Design.Text.label)
        XCTAssertEqual(
            Self.lineSpacing(of: label),
            Design.Chat.lineSpacing(for: after, multiple: Design.Chat.readingLineHeight),
            "the leading was not re-derived for the new size"
        )
    }

    // MARK: - Rendered State

    func testRendersInBothAppearances() throws {
        let output = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"]
            ?? NSTemporaryDirectory() + "/ThreadingRenders"
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            var data: Data?
            var inked = false
            appearance.performAsCurrentDrawingAppearance {
                let canvas = NSView(frame: NSRect(x: 0, y: 0, width: Fixture.width + 24, height: 10))
                canvas.appearance = appearance
                canvas.applySurface(fill: Design.Surface.ground, radius: .fixed(0))
                let label = ProseLabel(text: Fixture.paragraph)
                canvas.addSubview(label)
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: canvas.leadingAnchor, constant: 12),
                    label.topAnchor.constraint(equalTo: canvas.topAnchor, constant: 12),
                    label.widthAnchor.constraint(equalToConstant: Fixture.width)
                ])
                canvas.layoutSubtreeIfNeeded()
                canvas.frame.size.height = label.frame.height + 24
                canvas.layoutSubtreeIfNeeded()
                AppThemeRefresh.repaint(canvas)

                guard let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else { return }
                canvas.cacheDisplay(in: canvas.bounds, to: rep)
                inked = Self.hasInk(rep)
                data = rep.representation(using: .png, properties: [:])
            }
            XCTAssertTrue(inked, "the label drew no text in \(name.rawValue)")
            let png = try XCTUnwrap(data, "the label drew nothing in \(name.rawValue)")
            let suffix = name == .darkAqua ? "dark" : "light"
            try png.write(to: directory.appendingPathComponent("prose-label-\(suffix).png"))
        }
    }

    // MARK: - Helpers

    /// Lays the label out at the fixture width the way a bubble or a row states it.
    @discardableResult
    private func host(_ label: ProseLabel) -> ProseLabel {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: Fixture.width, height: 400))
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            label.topAnchor.constraint(equalTo: container.topAnchor),
            label.widthAnchor.constraint(equalToConstant: Fixture.width)
        ])
        container.layoutSubtreeIfNeeded()
        return label
    }

    private static func font(of label: ProseLabel) -> NSFont? {
        guard label.attributedText.length > 0 else { return nil }
        return label.attributedText.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    }

    private static func lineSpacing(of label: ProseLabel) -> CGFloat {
        guard label.attributedText.length > 0 else { return 0 }
        let style = label.attributedText.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
        return (style as? NSParagraphStyle)?.lineSpacing ?? 0
    }

    private static func textFields(in view: NSView) -> [NSTextField] {
        view.subviews.flatMap { child -> [NSTextField] in
            ((child as? NSTextField).map { [$0] } ?? []) + textFields(in: child)
        }
    }

    /// Whether any pixel differs from the top-left corner's ground — i.e. text was drawn.
    private static func hasInk(_ rep: NSBitmapImageRep) -> Bool {
        guard let ground = rep.colorAt(x: 0, y: 0) else { return false }
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                if abs(color.brightnessComponent - ground.brightnessComponent) > 0.2 { return true }
            }
        }
        return false
    }
}
