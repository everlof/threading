import SwiftUI
import UIKit
import XCTest
@testable import ThreadingMobile

/// A chat's name morphs character by character when it changes, and an agent renames its own
/// chat constantly: the Mac forwards the terminal title, which for Claude arrives as `✳ <name>`
/// a moment after the stored name. Two things this side owns decide whether that reads as an
/// animation or as a glitch — the geometry the morph runs in, and which face draws the mark.
@MainActor
final class MobileNavigationTitleMorphTests: XCTestCase {

    private enum Fixture {
        static let storedName = "Licensing strategy"
        /// Claude's own title for the same chat: its mark, then the name.
        static let liveName = "\u{2733} Licensing strategy"
        static let longName = "Extract the provider-neutral ACP runtime from the Mac"
    }

    // MARK: - Host

    private final class TitleModel: ObservableObject {
        @Published var title: String
        @Published var status: String

        init(title: String, status: String) {
            self.title = title
            self.status = status
        }
    }

    /// The shipping title in the shipping chrome, down to the buttons either side of it: a
    /// principal toolbar item is given what the button groups leave, so a fixture without them
    /// measures a bar nobody has.
    private struct TitleHost: View {
        @ObservedObject var model: TitleModel

        var body: some View {
            NavigationStack {
                Color.clear
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {} label: { Image(systemName: "chevron.left") }
                        }
                        ToolbarItem(placement: .principal) {
                            MobileConnectionNavigationTitle(
                                title: model.title,
                                status: model.status,
                                statusColor: .green
                            )
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {} label: { Image(systemName: "ellipsis") }
                        }
                    }
            }
        }
    }

    private func hosted(
        title: String,
        status: String,
        width: CGFloat = 402
    ) -> (window: UIWindow, model: TitleModel) {
        let model = TitleModel(title: title, status: status)
        let root = UIHostingController(rootView: TitleHost(model: model))
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: .zero)
        window.frame = CGRect(x: 0, y: 0, width: width, height: 874)
        window.rootViewController = root
        window.makeKeyAndVisible()
        settle(window)
        return (window, model)
    }

    private func morphingLabel(in view: UIView) throws -> MobileMorphingTitleLabel {
        try XCTUnwrap(first(MobileMorphingTitleLabel.self, in: view),
                      "no MobileMorphingTitleLabel in the hosted title")
    }

    private func morphingLabel(
        with value: String,
        in view: UIView
    ) throws -> MobileMorphingTitleLabel {
        try XCTUnwrap(
            all(MobileMorphingTitleLabel.self, in: view).first { $0.stringValue == value },
            "no MobileMorphingTitleLabel presenting \(value) in the hosted title"
        )
    }

    private func navigationBar(in view: UIView) throws -> UINavigationBar {
        try XCTUnwrap(first(UINavigationBar.self, in: view), "no UINavigationBar in the host")
    }

    private func first<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let found = view as? T { return found }
        for child in view.subviews {
            if let found = first(type, in: child) { return found }
        }
        return nil
    }

    private func all<T: UIView>(_ type: T.Type, in view: UIView) -> [T] {
        let current = (view as? T).map { [$0] } ?? []
        return current + view.subviews.flatMap { all(type, in: $0) }
    }

    private func glyphRenderingFrames(
        in label: MobileMorphingTitleLabel
    ) -> [CGRect] {
        var frames: [CGRect] = []
        func walk(_ layer: CALayer) {
            if layer is CATextLayer {
                frames.append(layer.convert(layer.bounds, to: label.layer))
            }
            layer.sublayers?.forEach(walk)
        }
        walk(label.layer)
        return frames
    }

    /// Lets SwiftUI commit its next layout pass, the way a runloop turn does in the app. The
    /// bug this file exists for lives in that pass, so a fixture that only calls
    /// `layoutIfNeeded` never sees it.
    private func settle(_ window: UIWindow, for interval: TimeInterval = 0.1) {
        RunLoop.current.run(until: Date().addingTimeInterval(interval))
        window.layoutIfNeeded()
    }

    /// Everything the process writes to `stdout` and `stderr` while `body` runs.
    ///
    /// AttributeGraph's cycle report goes to the process's standard streams and nowhere else —
    /// not to the unified log, not to an assertion, not to a crash — so a test about it has to
    /// read the descriptors. Both are taken, because the first version of this read `stdout`
    /// alone and passed straight through a run that printed 36 reports. Both ends of the pipe
    /// are non-blocking: a body that says more than the pipe holds loses output rather than
    /// hanging the test, and the report this exists for is a few kilobytes. The streams are
    /// restored before this returns, whatever `body` does.
    private func capturingStandardStreams(_ body: () throws -> Void) throws -> String {
        var ends: [Int32] = [0, 0]
        guard pipe(&ends) == 0 else { throw StandardStreamCaptureError.pipe }
        let originals = [dup(STDOUT_FILENO), dup(STDERR_FILENO)]
        guard originals.allSatisfy({ $0 >= 0 }) else {
            (ends + originals.filter { $0 >= 0 }).forEach { close($0) }
            throw StandardStreamCaptureError.duplicate
        }
        for end in ends {
            _ = fcntl(end, F_SETFL, fcntl(end, F_GETFL) | O_NONBLOCK)
        }
        fflush(stdout)
        fflush(stderr)
        dup2(ends[1], STDOUT_FILENO)
        dup2(ends[1], STDERR_FILENO)
        close(ends[1])

        let outcome = Result(catching: body)

        fflush(stdout)
        fflush(stderr)
        dup2(originals[0], STDOUT_FILENO)
        dup2(originals[1], STDERR_FILENO)
        originals.forEach { close($0) }
        var captured: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(ends[0], &chunk, chunk.count)
            guard count > 0 else { break }
            captured.append(contentsOf: chunk[0..<Int(count)])
        }
        close(ends[0])
        try outcome.get()
        return String(decoding: captured, as: UTF8.self)
    }

    private enum StandardStreamCaptureError: Error {
        case pipe
        case duplicate
    }

    // MARK: - Geometry

    /// The recording this came from: the phone opens a mirrored Claude terminal, the Mac's
    /// `hello` names the chat, and the agent's own title arrives with its mark in front of the
    /// same words. The label went from 147 points wide to 174 and the morph stopped half way.
    func testTheTitleKeepsItsGeometryWhenTheAgentMarkArrives() throws {
        let fixture = hosted(title: Fixture.storedName, status: "Opening chat…")
        let label = try morphingLabel(in: fixture.window)
        let before = label.bounds

        fixture.model.title = Fixture.liveName
        fixture.model.status = "David's MacBook Pro"
        settle(fixture.window)

        XCTAssertGreaterThan(before.width, 0)
        XCTAssertEqual(
            before.width,
            label.bounds.width,
            accuracy: 0.5,
            "the title's own width moved the label it morphs in: \(before) -> \(label.bounds)"
        )
    }

    /// A short name and a long one get the same bar, so nothing about a rename is a resize.
    func testTheTitleIsTheSameWidthForAShortNameAndALongOne() throws {
        let short = hosted(title: "Fix", status: "David's MacBook Pro")
        let long = hosted(title: Fixture.longName, status: "David's MacBook Pro")

        XCTAssertEqual(
            try morphingLabel(in: short.window).bounds.width,
            try morphingLabel(in: long.window).bounds.width,
            accuracy: 0.5
        )
    }

    /// The status dot and phrase are one reading. The phrase once hugged its words so that the
    /// dot beside it in an `HStack` would not be stranded at the title slot's leading edge, and
    /// paid for it with a morph laid out in the old width. The line fills the slot instead and
    /// places the dot at the drawn words itself.
    func testTheConnectionLineFillsTheTitleSlotAndStandsTheDotBesideTheWords() throws {
        let status = "Trying LAN"
        let fixture = hosted(title: "David's MacBook Pro", status: status)
        let titleLabel = try morphingLabel(with: "David's MacBook Pro", in: fixture.window)
        let line = try statusLine(in: fixture.window)

        XCTAssertEqual(line.bounds.width, titleLabel.bounds.width, accuracy: 0.5)
        XCTAssertEqual(line.label.stringValue, status)
        let ink = line.label.glyphInkFrames.map { line.convert($0, from: line.label) }
        let first = try XCTUnwrap(ink.min { $0.minX < $1.minX })
        XCTAssertEqual(
            line.indicator.frame.maxX + MobileDesign.Spacing.tight,
            first.minX,
            accuracy: 1
        )
    }

    /// The recording: a chat opens, "Opening chat…" gives way to the Mac's name inside the
    /// push, and the new phrase was drawn in two pieces because SwiftUI committed the wider
    /// label a pass after the morph had been built in the narrow one. In the shipping bar the
    /// line and its label keep their frames through the change; only the words and the dot's
    /// place beside them differ.
    func testAStatusChangeInTheShippingBarMovesNothingButTheWordsAndTheDot() throws {
        let fixture = hosted(title: "TYPOGRAPHY", status: "Opening chat…")
        let line = try statusLine(in: fixture.window)
        let lineFrame = line.frame
        let labelFrame = line.label.frame
        let dotBefore = line.indicator.frame

        fixture.model.status = "David's MacBook Pro"
        settle(fixture.window)

        XCTAssertTrue(try statusLine(in: fixture.window) === line, "the line was rebuilt")
        XCTAssertEqual(line.frame, lineFrame)
        XCTAssertEqual(line.label.frame, labelFrame)
        XCTAssertEqual(line.label.stringValue, "David's MacBook Pro")
        XCTAssertLessThan(line.indicator.frame.minX, dotBefore.minX, "a wider phrase moves the dot out")
        // A settled bar is not "in motion": the change above did morph, and so does the next.
        // This is what keeps the in-flight rule honest against a real bar's own layers.
        XCTAssertTrue(line.label.isAnimatingLineScrollForTesting, "the phrase landed without its morph")
        fixture.model.status = "Trying again…"
        settle(fixture.window)
        XCTAssertTrue(line.label.isAnimatingLineScrollForTesting)
        XCTAssertNotNil(line.departingIndicatorForTesting)
    }

    // MARK: - SwiftUI re-entrancy

    /// A status change and a rename both reach their UIKit label through `updateUIView`, which
    /// runs inside SwiftUI's own graph update. Anything on that path that lays the window out
    /// synchronously — a morph resolving its final geometry up front, the line placing its mark
    /// — lays the hosting view out too, and that renders the SwiftUI graph while it is still
    /// updating. AttributeGraph reports the re-entry as a dependency cycle for every attribute
    /// it meets on the way round, on the process's standard streams and nowhere else. A paired
    /// phone did this on every scene activation and after every keychain write, 46 lines at a
    /// time, unseen because nothing reads an app's streams on a device; this fixture did it too,
    /// 36 lines under the status change above and 14 under each rename, while every assertion
    /// passed. The report is the only witness there is, so the test reads it.
    func testAStatusChangeAndARenameReenterNothingInSwiftUI() throws {
        let fixture = hosted(title: Fixture.storedName, status: "Opening chat…")
        let line = try statusLine(in: fixture.window)

        let report = try capturingStandardStreams {
            fixture.model.status = "David's MacBook Pro"
            settle(fixture.window)
            XCTAssertTrue(
                line.label.isAnimatingLineScrollForTesting,
                "the phrase landed without its morph"
            )
            fixture.model.title = Fixture.liveName
            settle(fixture.window)
        }

        XCTAssertEqual(line.label.stringValue, "David's MacBook Pro")
        XCTAssertNoThrow(try morphingLabel(with: Fixture.liveName, in: fixture.window))
        XCTAssertFalse(
            report.contains("AttributeGraph: cycle detected"),
            "a change in the bar re-entered SwiftUI's graph:\n\(report)"
        )
    }

    private func statusLine(in view: UIView) throws -> MobileConnectionStatusLineView {
        try XCTUnwrap(first(MobileConnectionStatusLineView.self, in: view),
                      "no MobileConnectionStatusLineView in the hosted title")
    }

    /// LabelMorph's raster tiles deliberately extend past each glyph's typographic advance.
    /// The mobile wrapper clips its navigation slot, so it must reserve that overflow inside its
    /// own bounds or the first character loses its leading pixels in the real bar.
    func testTheConnectionStatusKeepsEveryGlyphRasterInsideItsClip() throws {
        let status = "Trying LAN"
        let fixture = hosted(title: "David's MacBook Pro", status: status)
        let label = try morphingLabel(with: status, in: fixture.window)
        let frames = glyphRenderingFrames(in: label)

        XCTAssertFalse(frames.isEmpty)
        for frame in frames {
            XCTAssertGreaterThanOrEqual(
                frame.minX,
                label.bounds.minX - 0.01,
                "the first glyph raster starts outside the clipped wrapper: \(frame)"
            )
            XCTAssertLessThanOrEqual(
                frame.maxX,
                label.bounds.maxX + 0.01,
                "the final glyph raster ends outside the clipped wrapper: \(frame)"
            )
        }
    }

    /// Holding still must not be bought by taking a width the bar has not got. A stated width
    /// wide enough for a 402-point phone sat on both buttons of a 320-point one; the title takes
    /// what the button groups leave instead.
    func testTheTitleStaysBetweenTheBarsButtonsOnASmallPhone() throws {
        for width in [320.0, 402.0, 440.0] as [CGFloat] {
            let fixture = hosted(
                title: Fixture.longName,
                status: "David's MacBook Pro",
                width: width
            )
            let bar = try navigationBar(in: fixture.window)
            let label = try morphingLabel(in: fixture.window)
            let title = label.convert(label.bounds, to: bar)
            let buttons = buttonFrames(in: bar)

            XCTAssertFalse(buttons.isEmpty, "the fixture lost its buttons at \(width)")
            for button in buttons {
                XCTAssertFalse(
                    title.intersects(button),
                    "the title \(title) sat on a bar button \(button) at \(width) points"
                )
            }
        }
    }

    private func buttonFrames(in bar: UINavigationBar) -> [CGRect] {
        var frames: [CGRect] = []
        func walk(_ view: UIView) {
            if NSStringFromClass(type(of: view)).contains("ItemWrapperView") {
                frames.append(view.convert(view.bounds, to: bar))
            }
            view.subviews.forEach(walk)
        }
        walk(bar)
        return frames
    }

    // MARK: - The mark

    /// The mark is drawn by the face both platforms agree on, not by Apple Color Emoji — which
    /// on the phone is where a bare U+2733 otherwise lands.
    func testTheAgentMarkAsksForItsTextPresentation() {
        let presented = MobileGlyphPresentation.presented(Fixture.liveName)

        XCTAssertEqual(presented, "\u{2733}\u{FE0E} Licensing strategy")
        XCTAssertEqual(presented.count, Fixture.liveName.count, "the mark is still one character")
    }

    /// The property the rewrite exists to buy, asked of this platform rather than assumed: the
    /// bare mark resolves to a colour face here and the presented one does not. If the first of
    /// these ever fails, the fallback cascade changed and the rewrite has nothing left to do.
    func testThePresentedMarkResolvesToAnOutlineFace() {
        XCTAssertTrue(usesAColourFace("\u{2733}"))
        XCTAssertFalse(usesAColourFace(MobileGlyphPresentation.presented("\u{2733}")))
    }

    private func usesAColourFace(_ text: String) -> Bool {
        let font = UIFont.preferredFont(forTextStyle: .headline)
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: [.font: font, .ligature: 0])
        )
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let anyFont = attributes[kCTFontAttributeName as String],
                  CFGetTypeID(anyFont as CFTypeRef) == CTFontGetTypeID() else { continue }
            if CTFontGetSymbolicTraits(anyFont as! CTFont).contains(.traitColorGlyphs) {
                return true
            }
        }
        return false
    }

    /// Codex marks a finished tool with U+23FA, whose colour form is a white dot on a grey
    /// plate — the same defect wearing a different colour.
    func testAToolMarkAsksForItsTextPresentationToo() {
        XCTAssertEqual(
            MobileGlyphPresentation.presented("\u{23FA} Read"),
            "\u{23FA}\u{FE0E} Read"
        )
    }

    /// A name someone chose an emoji for keeps it. Rewriting those was never the point: their
    /// own default presentation is emoji, and the phone can draw one.
    func testANameWithARealEmojiIsLeftAlone() {
        XCTAssertEqual(MobileGlyphPresentation.presented("🚀 Ship it"), "🚀 Ship it")
        XCTAssertEqual(MobileGlyphPresentation.presented("Licensing strategy"), "Licensing strategy")
        XCTAssertEqual(MobileGlyphPresentation.presented("1️⃣ First"), "1️⃣ First")
    }

    /// The deliberate half of that line. A heart is text by default and this platform still has a
    /// red one for it, which is exactly the case that tempts a per-scalar exception list. It
    /// follows the character's default like every other mark, so the name reads the same on the
    /// Mac — where the same scalar has no colour form to reach for.
    func testATextDefaultSymbolWithAColourFormStillFollowsItsDefault() {
        for name in ["\u{2764} Design polish", "\u{2600} Morning triage", "\u{2714} Done"] {
            let presented = MobileGlyphPresentation.presented(name)
            XCTAssertNotEqual(presented, name, "\(name) kept a colour form the Mac cannot draw")
            XCTAssertFalse(usesAColourFace(presented))
            XCTAssertEqual(presented.count, name.count)
        }
    }

    /// An author who wrote the emoji presentation out asked for it.
    func testAnExplicitEmojiPresentationIsNotRewritten() {
        XCTAssertEqual(
            MobileGlyphPresentation.presented("\u{2733}\u{FE0F} Licensing strategy"),
            "\u{2733}\u{FE0F} Licensing strategy"
        )
    }

    /// What the view reports is the title it was given, mark and all — the presentation is for
    /// the glyphs, and VoiceOver reads the name.
    func testThePresentationDoesNotChangeWhatTheTitleReports() throws {
        let fixture = hosted(title: Fixture.storedName, status: "David's MacBook Pro")
        let label = try morphingLabel(in: fixture.window)

        fixture.model.title = Fixture.liveName
        settle(fixture.window)

        XCTAssertEqual(label.stringValue, Fixture.liveName)
        XCTAssertEqual(label.accessibilityLabel, Fixture.liveName)
    }
}
