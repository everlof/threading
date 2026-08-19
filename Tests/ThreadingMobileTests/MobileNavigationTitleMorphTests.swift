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

    /// Lets SwiftUI commit its next layout pass, the way a runloop turn does in the app. The
    /// bug this file exists for lives in that pass, so a fixture that only calls
    /// `layoutIfNeeded` never sees it.
    private func settle(_ window: UIWindow, for interval: TimeInterval = 0.1) {
        RunLoop.current.run(until: Date().addingTimeInterval(interval))
        window.layoutIfNeeded()
    }

    // MARK: - Geometry

    /// The recording this came from: the phone opens a mirrored Claude terminal, the Mac's
    /// `hello` names the chat, and the agent's own title arrives with its mark in front of the
    /// same words. The label went from 147 points wide to 174 and the morph stopped half way.
    func testTheTitleKeepsItsGeometryWhenTheAgentMarkArrives() throws {
        let fixture = hosted(title: Fixture.storedName, status: "Connecting to Mac…")
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
