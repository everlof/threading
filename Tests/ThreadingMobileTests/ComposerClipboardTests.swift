import SwiftUI
import ThreadingRemoteKit
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import ThreadingMobile

/// A phone's clipboard is where a copied picture already is, and it was the one door the
/// composer did not have: the pickers reach Photos and Files, and something copied out of a
/// web page or a message is in neither until it has been saved somewhere. These pin what the
/// composer takes off the pasteboard, what it refuses, and — the part that is easy to lose —
/// that the availability question never reads a value, because reading one raises the system's
/// paste prompt and a menu that prompts by being drawn teaches people to refuse it.
@MainActor
final class ComposerClipboardTests: XCTestCase {

    // MARK: - Constants

    private enum Fixture {
        static let text = "git status --short"
        static let imageEdge: CGFloat = 4
    }

    // MARK: - Properties

    private var pasteboardName: UIPasteboard.Name?

    // MARK: - Lifecycle

    override func tearDown() {
        if let pasteboardName {
            UIPasteboard.remove(withName: pasteboardName)
        }
        pasteboardName = nil
        super.tearDown()
    }

    // MARK: - Tests

    func testAnEmptyClipboardOffersNothing() {
        let clipboard = makeClipboard()

        XCTAssertFalse(clipboard.hasFiles)
        XCTAssertFalse(clipboard.hasText)
        XCTAssertFalse(clipboard.hasContent)
        XCTAssertTrue(clipboard.files().isEmpty)
        XCTAssertNil(clipboard.text())
    }

    /// Text belongs in the draft, at the insertion point, which is the text view's own paste.
    /// Offering it in the attachment strip as well would stage a file nobody asked for.
    func testTextIsContentButNotAFile() {
        let clipboard = makeClipboard { $0.string = Fixture.text }

        XCTAssertFalse(clipboard.hasFiles)
        XCTAssertTrue(clipboard.hasText)
        XCTAssertTrue(clipboard.hasContent)
        XCTAssertTrue(clipboard.files().isEmpty)
        XCTAssertEqual(clipboard.text(), Fixture.text)
    }

    func testACopiedPictureComesBackAsOneFileToStage() throws {
        let png = try pngData()
        let clipboard = makeClipboard {
            $0.items = [[UTType.png.identifier: png]]
        }

        XCTAssertTrue(clipboard.hasFiles)
        let files = clipboard.files()
        XCTAssertEqual(files.count, 1)
        let file = try XCTUnwrap(files.first)
        XCTAssertEqual(file.type, .png)
        XCTAssertEqual(file.data, png)
        XCTAssertTrue(
            file.name.hasPrefix("pasted-") && file.name.hasSuffix(".png"),
            "a pasted item carries no name, so it is given one that says where it came from"
        )
    }

    /// A copied picture is usually offered in several encodings at once. The first match wins,
    /// so it travels as the PNG it was captured as rather than being re-encoded on the way.
    func testTheBestEncodingOfAnItemWins() throws {
        let png = try pngData()
        let jpeg = try jpegData()
        let clipboard = makeClipboard {
            $0.items = [[UTType.jpeg.identifier: jpeg, UTType.png.identifier: png]]
        }

        XCTAssertEqual(clipboard.files().first?.type, .png)
        XCTAssertEqual(clipboard.files().first?.data, png)
    }

    /// The item count comes from whatever another app put there. Bounding it after the read
    /// would have copied every one of those pictures out of the pasteboard server first.
    func testMoreItemsThanOneMessageCarriesAreCappedBeforeTheyAreRead() throws {
        let png = try pngData()
        let clipboard = makeClipboard { pasteboard in
            pasteboard.items = Array(
                repeating: [UTType.png.identifier: png],
                count: ComposerClipboard.maximumItems + 3
            )
        }

        XCTAssertEqual(clipboard.files().count, ComposerClipboard.maximumItems)
    }

    func testAnItemInNoFormatAMessageCanCarryIsSkipped() {
        let clipboard = makeClipboard {
            $0.items = [["com.example.private-format": Data([0x01, 0x02])]]
        }

        XCTAssertFalse(clipboard.hasFiles)
        XCTAssertTrue(clipboard.files().isEmpty)
    }

    /// A raw terminal write is acknowledged by nothing, so an oversized paste would go into
    /// silence. Telling "there was nothing" apart from "there was too much" is the difference
    /// between a notice somebody can act on and one that reads as a bug.
    func testTextTooLargeForOneTerminalWriteIsRefusedAndSaysSo() {
        let oversized = String(repeating: "x", count: RemoteTerminalPaste.maximumBytes + 1)
        let clipboard = makeClipboard { $0.string = oversized }

        XCTAssertNil(clipboard.text())
        XCTAssertTrue(clipboard.holdsOversizedText())
    }

    func testTextInsideTheBoundIsNotReportedAsOversized() {
        let clipboard = makeClipboard { $0.string = Fixture.text }

        XCTAssertFalse(clipboard.holdsOversizedText())
    }

    // MARK: - Private Methods

    /// A pasteboard of this test's own. `UIPasteboard.general` is the person's real clipboard,
    /// and this bundle is hosted inside the app.
    private func makeClipboard(
        _ fill: (UIPasteboard) -> Void = { _ in }
    ) -> ComposerClipboard {
        let pasteboard = UIPasteboard.withUniqueName()
        pasteboardName = pasteboard.name
        fill(pasteboard)
        return ComposerClipboard(pasteboard: pasteboard)
    }

    private func pngData() throws -> Data {
        let size = CGSize(width: Fixture.imageEdge, height: Fixture.imageEdge)
        return try XCTUnwrap(UIGraphicsImageRenderer(size: size).pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        })
    }

    private func jpegData() throws -> Data {
        let size = CGSize(width: Fixture.imageEdge, height: Fixture.imageEdge)
        return try XCTUnwrap(UIGraphicsImageRenderer(size: size).jpegData(
            withCompressionQuality: 1
        ) { context in
            UIColor.systemPink.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        })
    }
}

/// The composer's text view asks whether it can insert *text*, so a picture-only clipboard used
/// to leave the edit menu with no Paste in it at all — and even a Paste that appeared had
/// nothing to insert. These pin the two halves: the menu offers it, and the paste never reaches
/// the text.
@MainActor
final class ComposerTextViewPasteTests: XCTestCase {

    private enum Fixture {
        static let existingDraft = "already typed"
    }

    func testPasteIsOfferedForAClipboardHoldingOnlyFiles() {
        let textView = IntrinsicTextView()
        textView.offersFiles = { true }

        XCTAssertTrue(
            textView.canPerformAction(#selector(UIResponderStandardEditActions.paste(_:)), withSender: nil),
            "a picture has no text to insert, so the text view would have refused the action"
        )
    }

    /// The pre-session draft used to be the lone SwiftUI `TextField`, so proving the shared text
    /// view works did not prove that screen had actually adopted it. This hosts the shipping
    /// representable and pins the UIKit edit-menu surface plus its attachment interception.
    func testNewSessionDraftHostsTheNativePasteSurface() throws {
        var pastedFiles = 0
        let editor = DraftFocusHarness(
            initialDraft: Fixture.existingDraft,
            offersFiles: { true },
            pasteFiles: {
                pastedFiles += 1
                return true
            }
        )
        let host = UIHostingController(rootView: editor.frame(width: 240, height: 80))
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: .zero)
        window.frame = CGRect(x: 0, y: 0, width: 240, height: 80)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        window.layoutIfNeeded()

        let textView = try XCTUnwrap(descendants(of: IntrinsicTextView.self, in: window).first)
        XCTAssertEqual(textView.text, Fixture.existingDraft)
        XCTAssertTrue(textView.isEditable)
        XCTAssertTrue(textView.canPerformAction(
            #selector(UIResponderStandardEditActions.paste(_:)),
            withSender: nil
        ))

        textView.paste(nil)
        XCTAssertEqual(pastedFiles, 1)
        XCTAssertEqual(textView.text, Fixture.existingDraft)
    }

    /// The draft's UIKit editor reports focus through SwiftUI view state. A character changes the
    /// SwiftUI draft and therefore updates the representable while the keyboard is still up;
    /// that render must keep the editor first responder rather than treating the update as a
    /// dismissal request.
    func testNewSessionDraftKeepsFocusAcrossATypedCharacter() throws {
        let host = UIHostingController(rootView: DraftFocusHarness())
        let window = makeWindow(hosting: host, size: CGSize(width: 240, height: 120))
        defer { window.isHidden = true }

        let textView = try XCTUnwrap(descendants(of: IntrinsicTextView.self, in: window).first)
        XCTAssertTrue(textView.becomeFirstResponder())
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        textView.insertText("x")
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        XCTAssertEqual(textView.text, "x")
        XCTAssertTrue(
            textView.isFirstResponder,
            "updating the SwiftUI draft for one character must not dismiss its keyboard"
        )
    }

    /// The compact prompt shares a row with two centred controls. Its first line therefore owns
    /// equal top and bottom air inside that same compact row rather than starting at its top.
    func testNewSessionDraftCentersOneLineInTheCompactComposerRow() throws {
        let host = UIHostingController(rootView: DraftFocusHarness(
            initialDraft: "S",
            editorHeight: MobileDesign.Size.compactControl
        ))
        let window = makeWindow(hosting: host, size: CGSize(width: 240, height: 120))
        defer { window.isHidden = true }

        let textView = try XCTUnwrap(descendants(of: IntrinsicTextView.self, in: window).first)
        let font = try XCTUnwrap(textView.font)
        XCTAssertEqual(
            textView.textContainerInset.top,
            textView.textContainerInset.bottom,
            accuracy: 0.01
        )
        XCTAssertEqual(
            font.lineHeight + textView.textContainerInset.top + textView.textContainerInset.bottom,
            MobileDesign.Size.compactControl,
            accuracy: 0.5,
            "the first text line and the neighbouring controls must share one optical centre"
        )
    }

    /// SwiftUI grows the representable through intermediate heights before it reaches the native
    /// editor's fitted height. None of those transient frames is the authored scroll cap: treating
    /// one as such activates the separate action row shown in the physical empty-draft screenshot.
    func testEmptyNewSessionDraftKeepsActionsInItsCompactRow() throws {
        var overflowTransitions: [Bool] = []
        let host = UIHostingController(rootView: DraftFocusHarness(
            editorHeight: MobileDesign.Size.compactControl,
            firstLineAccessoryWidth: 42,
            onOverflowChange: { overflowTransitions.append($0) }
        ))
        let window = makeWindow(hosting: host, size: CGSize(width: 240, height: 120))
        defer { window.isHidden = true }

        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let textView = try XCTUnwrap(descendants(of: IntrinsicTextView.self, in: window).first)
        XCTAssertFalse(textView.isScrollEnabled)
        XCTAssertFalse(
            overflowTransitions.contains(true),
            "the empty draft entered its overflow shell: \(overflowTransitions); "
                + "content=\(textView.contentSize.height) "
                + "bounds=\(textView.bounds.height) "
                + "fit=\(textView.sizeThatFits(CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude)).height) "
                + "maximum=\(textView.maximumIntrinsicHeight)"
        )
    }

    /// The first glyph does not create a second line. Its line fragment must therefore have the
    /// same measured height as the empty insertion line; otherwise typing and deleting one
    /// character repeatedly moves the entire composer and stretches its caret.
    func testFirstCharacterAndDeletionKeepTheCompactDraftHeightAndCaret() throws {
        let host = UIHostingController(rootView: DraftFocusHarness(
            editorHeight: MobileDesign.Size.compactControl,
            firstLineAccessoryWidth: 42
        ))
        let window = makeWindow(hosting: host, size: CGSize(width: 240, height: 120))
        defer { window.isHidden = true }

        let textView = try XCTUnwrap(descendants(of: IntrinsicTextView.self, in: window).first)
        let font = try XCTUnwrap(textView.font)
        let fittingHeight = {
            textView.sizeThatFits(CGSize(
                width: textView.bounds.width,
                height: .greatestFiniteMagnitude
            )).height
        }
        let emptyHeight = fittingHeight()

        textView.text = "G"
        textView.layoutManager.ensureLayout(for: textView.textContainer)
        let oneCharacterHeight = fittingHeight()
        let caretHeight = textView.caretRect(for: textView.endOfDocument).height

        textView.text = ""
        textView.layoutManager.ensureLayout(for: textView.textContainer)
        let deletedHeight = fittingHeight()

        XCTAssertEqual(
            oneCharacterHeight,
            emptyHeight,
            accuracy: 0.5,
            "one glyph changed the compact editor from \(emptyHeight) to \(oneCharacterHeight)"
        )
        XCTAssertEqual(deletedHeight, emptyHeight, accuracy: 0.5)
        XCTAssertEqual(
            caretHeight,
            font.pointSize,
            accuracy: 0.5,
            "the caret was \(caretHeight) points beside \(font.pointSize)-point text"
        )
    }

    /// The paperclip and Start control occupy the first line only. Keeping them as horizontal
    /// stack siblings narrowed every line in the screenshot even after the terminal composer had
    /// adopted TextKit exclusions.
    func testNewSessionDraftWrappedLinesReclaimBothAccessoryColumns() throws {
        // Wraps at this width, yet stays under the six-line cap: a longer draft overflows and
        // rightly sends the controls to their fixed row, which is the other placement entirely.
        let host = UIHostingController(rootView: DraftFocusHarness(
            initialDraft: "We have properly set up push certificates, but what does it take?",
            editorHeight: 120,
            firstLineAccessoryWidth: 42
        ))
        let window = makeWindow(hosting: host, size: CGSize(width: 240, height: 160))
        defer { window.isHidden = true }

        let textView = try XCTUnwrap(descendants(of: IntrinsicTextView.self, in: window).first)
        textView.layoutManager.ensureLayout(for: textView.textContainer)

        var lineRects: [CGRect] = []
        let glyphRange = textView.layoutManager.glyphRange(for: textView.textContainer)
        textView.layoutManager.enumerateLineFragments(
            forGlyphRange: glyphRange
        ) { rect, _, _, _, _ in
            lineRects.append(rect)
        }

        XCTAssertGreaterThanOrEqual(lineRects.count, 2)
        XCTAssertEqual(lineRects[0].minX, 42, accuracy: 0.5)
        XCTAssertEqual(lineRects[1].minX, 0, accuracy: 0.5)
        XCTAssertGreaterThan(
            lineRects[1].width,
            lineRects[0].width,
            "later lines must fill beneath both first-line controls"
        )
    }

    /// Exclusion paths belong to document coordinates and therefore cannot protect fixed
    /// controls after the first line scrolls away. The native editor reports the moment it owns
    /// a scroll viewport so its SwiftUI shell can move those controls into a separate row.
    func testCappedNewSessionDraftReportsOverflowToItsShell() {
        var reportedOverflow = false
        let host = UIHostingController(rootView: DraftFocusHarness(
            initialDraft: Array(repeating: "G", count: 12).joined(separator: "\n"),
            editorHeight: 120,
            firstLineAccessoryWidth: 42,
            onOverflowChange: { reportedOverflow = $0 }
        ))
        let window = makeWindow(hosting: host, size: CGSize(width: 240, height: 160))
        defer { window.isHidden = true }

        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let textView = descendants(of: IntrinsicTextView.self, in: window).first
        let nativeScroll = textView.map { String($0.isScrollEnabled) } ?? "missing"
        XCTAssertTrue(
            reportedOverflow,
            "the shell kept its fixed controls over a document that had begun scrolling; "
                + "native scroll=\(nativeScroll) "
                + "content=\(textView?.contentSize.height ?? -1) "
                + "bounds=\(textView?.bounds.height ?? -1)"
        )
    }

    /// A draft within a line of the cap overflows with the inline controls in place and fits
    /// once they leave. Deciding their placement from whichever layout was showing made the two
    /// answers alternate on every pass — the whole paragraph visibly re-wrapped several times a
    /// second. The decision is measured against the inline footprints in both placements, so an
    /// epsilon-length draft settles in its overflow shell and stays there.
    func testEpsilonLengthDraftSettlesInItsOverflowShellInsteadOfFlickering() {
        var overflowTransitions: [Bool] = []
        let host = UIHostingController(rootView: DraftFocusHarness(
            initialDraft: Array(repeating: "G", count: 6).joined(separator: "\n"),
            editorHeight: 160,
            firstLineAccessoryWidth: 42,
            onOverflowChange: { overflowTransitions.append($0) }
        ))
        let window = makeWindow(hosting: host, size: CGSize(width: 240, height: 200))
        defer { window.isHidden = true }

        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(
            overflowTransitions,
            [true],
            "every transition past the first is one visible jump of the whole paragraph"
        )
    }

    /// The unit-level half of the settling guarantee: re-laying the editor out with the
    /// accessories moved to their fixed row must not change the answer that moved them.
    func testAccessoryPlacementDecisionIsTheSameInBothPlacements() {
        let textView = IntrinsicTextView()
        let font = UIFont.preferredFont(forTextStyle: .body)
        let inset = max(0, (MobileDesign.Size.compactControl - font.lineHeight) / 2)
        textView.font = font
        textView.textContainerInset = UIEdgeInsets(top: inset, left: 0, bottom: inset, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        textView.isScrollEnabled = false
        textView.minimumIntrinsicHeight = MobileDesign.Size.compactControl
        textView.maximumIntrinsicHeight = ceil(font.lineHeight * 6 + inset * 2)
        textView.firstLineLeadingAccessoryWidth = 42
        textView.firstLineTrailingAccessoryWidth = 42
        textView.firstLineAccessoryHeight = MobileDesign.Size.compactControl
        textView.frame = CGRect(x: 0, y: 0, width: 240, height: 160)
        textView.text = Array(repeating: "G", count: 6).joined(separator: "\n")

        var reports: [Bool] = []
        textView.onFirstLineAccessoryOverflowChange = { reports.append($0) }
        textView.setNeedsLayout()
        textView.layoutIfNeeded()
        XCTAssertEqual(
            reports,
            [true],
            "six hard lines cannot keep the inline controls under a six-line cap"
        )

        textView.firstLineAccessoriesInline = false
        textView.setNeedsLayout()
        textView.layoutIfNeeded()
        XCTAssertEqual(
            reports,
            [true],
            "the placement decision followed the placement it decides"
        )

        textView.text = "G"
        textView.setNeedsLayout()
        textView.layoutIfNeeded()
        XCTAssertEqual(reports, [true, false], "a short draft takes its controls back")
    }

    func testAFilePasteIsTakenAsAnAttachmentAndNeverReachesTheText() {
        let textView = IntrinsicTextView()
        textView.text = Fixture.existingDraft
        var pastedFiles = 0
        textView.pasteFiles = {
            pastedFiles += 1
            return true
        }

        textView.paste(nil)

        XCTAssertEqual(pastedFiles, 1)
        XCTAssertEqual(
            textView.text,
            Fixture.existingDraft,
            "the draft is untouched: the file went to the strip, not into the sentence"
        )
    }

    func testAnUnclaimedPasteIsLeftToTheTextView() {
        let textView = IntrinsicTextView()
        var asked = 0
        textView.pasteFiles = {
            asked += 1
            return false
        }

        textView.paste(nil)

        XCTAssertEqual(asked, 1, "text keeps the text view's own paste, insertion point and all")
    }

    private func descendants<T: UIView>(of type: T.Type, in root: UIView) -> [T] {
        let own = (root as? T).map { [$0] } ?? []
        return own + root.subviews.flatMap { descendants(of: type, in: $0) }
    }

    private func makeWindow<Content: View>(
        hosting host: UIHostingController<Content>,
        size: CGSize
    ) -> UIWindow {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: .zero)
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = host
        window.makeKeyAndVisible()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        window.layoutIfNeeded()
        return window
    }

    private struct DraftFocusHarness: View {
        @State private var draft: String
        @State private var isFocused = false
        @State private var isOverflowing = false
        let offersFiles: () -> Bool
        let pasteFiles: () -> Bool
        let editorHeight: CGFloat
        let firstLineAccessoryWidth: CGFloat
        let onOverflowChange: (Bool) -> Void

        init(
            initialDraft: String = "",
            editorHeight: CGFloat = 80,
            offersFiles: @escaping () -> Bool = { false },
            pasteFiles: @escaping () -> Bool = { false },
            firstLineAccessoryWidth: CGFloat = 0,
            onOverflowChange: @escaping (Bool) -> Void = { _ in }
        ) {
            _draft = State(initialValue: initialDraft)
            self.editorHeight = editorHeight
            self.offersFiles = offersFiles
            self.pasteFiles = pasteFiles
            self.firstLineAccessoryWidth = firstLineAccessoryWidth
            self.onOverflowChange = onOverflowChange
        }

        var body: some View {
            SessionDraftPromptEditor(
                text: $draft,
                isFocused: $isFocused,
                isOverflowing: $isOverflowing,
                isEnabled: true,
                theme: RemoteThemePalette(nil),
                offersFiles: offersFiles,
                pasteFiles: pasteFiles,
                firstLineLeadingAccessoryWidth: firstLineAccessoryWidth,
                firstLineTrailingAccessoryWidth: firstLineAccessoryWidth,
                firstLineAccessoryHeight: firstLineAccessoryWidth > 0
                    ? MobileDesign.Size.compactControl
                    : 0,
                // The shipping shell's wiring, verbatim: an overflow report releases the first
                // line's width. Mirroring it is what lets these tests catch the feedback loop.
                firstLineAccessoriesInline: !isOverflowing
            )
            .frame(width: 240, height: editorHeight)
            .onChange(of: isOverflowing) { _, value in onOverflowChange(value) }
        }
    }
}

/// The terminal's controls belong to the first line, not to two permanent columns beside the
/// whole paragraph. This pins the TextKit geometry that lets later lines reclaim that width.
@MainActor
final class TerminalLineTextLayoutTests: XCTestCase {

    func testWrappedLinesRunUnderTheFirstLineAccessories() {
        let textView = TerminalLineTextView(frame: CGRect(x: 0, y: 0, width: 240, height: 160))
        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.firstLineLeadingAccessoryWidth = MobileDesign.Size.minimumTapTarget
        textView.firstLineTrailingAccessoryWidth = MobileDesign.Size.minimumTapTarget
        textView.firstLineAccessoryHeight = MobileDesign.Size.minimumTapTarget
        textView.text = "Review the attachment spacing, then let every wrapped line use the full composer width."

        textView.setNeedsLayout()
        textView.layoutIfNeeded()
        textView.layoutManager.ensureLayout(for: textView.textContainer)

        var lineRects: [CGRect] = []
        let glyphRange = textView.layoutManager.glyphRange(for: textView.textContainer)
        textView.layoutManager.enumerateLineFragments(
            forGlyphRange: glyphRange
        ) { rect, _, _, _, _ in
            lineRects.append(rect)
        }

        XCTAssertGreaterThanOrEqual(lineRects.count, 2)
        XCTAssertEqual(
            lineRects[0].minX,
            MobileDesign.Size.minimumTapTarget,
            accuracy: 0.5,
            "only the first line flows around the paperclip"
        )
        XCTAssertEqual(
            lineRects[0].height,
            try XCTUnwrap(textView.font).lineHeight,
            accuracy: 2,
            "control clearance must not feed back into the first line's typographic height"
        )
        XCTAssertEqual(
            lineRects[1].minX,
            0,
            accuracy: 0.5,
            "the next line starts beneath the paperclip instead of keeping its empty column"
        )
        XCTAssertGreaterThan(
            lineRects[1].width,
            lineRects[0].width,
            "later lines also reclaim the send button's column"
        )
        XCTAssertGreaterThanOrEqual(
            lineRects[1].minY,
            MobileDesign.Size.minimumTapTarget,
            "the full-width line begins below both 44-point hit targets"
        )
    }

    func testTerminalEditorKeepsFocusAcrossATypedCharacter() throws {
        let host = UIHostingController(rootView: TerminalEditorHarness())
        let window = makeWindow(hosting: host)
        defer { window.isHidden = true }

        let textView = try XCTUnwrap(descendants(of: IntrinsicTextView.self, in: window).first)
        XCTAssertTrue(textView.becomeFirstResponder())
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        textView.insertText("x")
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        XCTAssertEqual(textView.text, "x")
        XCTAssertTrue(
            textView.isFirstResponder,
            "the binding update for one character must not dismiss the terminal keyboard"
        )
    }

    /// Once the editor reaches its five-line cap, the text view—not the surrounding terminal
    /// screen—owns the rest of the draft. Pin the actual UIKit scroll range: wrapping correctly
    /// around the two first-line controls is not enough if the capped view still declines pans.
    func testTerminalEditorScrollsPastItsVisibleLineCap() throws {
        let host = UIHostingController(rootView: TerminalEditorHarness(
            initialDraft: Array(repeating: "a draft line", count: 20).joined(separator: "\n")
        ))
        let window = makeWindow(hosting: host)
        defer { window.isHidden = true }

        let textView = try XCTUnwrap(descendants(of: IntrinsicTextView.self, in: window).first)
        textView.layoutIfNeeded()

        XCTAssertTrue(textView.isScrollEnabled, "the capped editor must accept its own pan")
        XCTAssertGreaterThan(
            textView.contentSize.height,
            textView.bounds.height,
            "the hidden draft lines must remain inside the text view's scrollable document"
        )

        let maximumOffset = textView.contentSize.height - textView.bounds.height
        textView.setContentOffset(CGPoint(x: 0, y: maximumOffset / 2), animated: false)
        XCTAssertGreaterThan(
            textView.contentOffset.y,
            0,
            "UIKit constrained an attempted draft scroll back to its first five lines"
        )
    }

    /// A capped paragraph used to alternate forever between two TextKit layouts after scrolling
    /// was enabled: one used the first-line exclusions and the next skipped that line entirely.
    /// The real composer then changed height on every SwiftUI layout turn, producing the visible
    /// flicker from an otherwise idle draft.
    func testCappedTerminalParagraphKeepsOneLayoutAcrossRunLoopTurns() throws {
        let draft = "Jajsijddb dbkuuyy i miss it for you for you too and thank you for being my "
            + "friend and friend and always supporting me always and always and always and always "
            + "and always and always and always and always and a"
        let host = UIHostingController(rootView: TerminalEditorHarness(
            initialDraft: draft,
            editorWidth: 370,
            editorHeight: nil
        ))
        let window = makeWindow(hosting: host, size: CGSize(width: 402, height: 500))
        defer { window.isHidden = true }

        let textView = try XCTUnwrap(descendants(of: IntrinsicTextView.self, in: window).first)
        XCTAssertTrue(textView.becomeFirstResponder())
        var snapshots: [String] = []
        for _ in 0..<20 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            window.layoutIfNeeded()
            textView.layoutIfNeeded()
            textView.layoutManager.ensureLayout(for: textView.textContainer)

            var firstLine = CGRect.null
            let glyphRange = textView.layoutManager.glyphRange(for: textView.textContainer)
            textView.layoutManager.enumerateLineFragments(
                forGlyphRange: glyphRange
            ) { rect, _, _, _, stop in
                firstLine = rect
                stop.pointee = true
            }
            snapshots.append(
                "scroll=\(textView.isScrollEnabled);frame=\(textView.frame);"
                    + "content=\(textView.contentSize);first=\(firstLine)"
            )
        }

        XCTAssertTrue(textView.isScrollEnabled, "the fixture must exercise the capped editor")
        XCTAssertEqual(
            Set(snapshots).count,
            1,
            "the idle capped composer oscillated between layouts:\n\(snapshots.joined(separator: "\n"))"
        )
    }

    func testTerminalEditorReturnSubmitsWithoutAddingANewline() throws {
        var submissionCount = 0
        let host = UIHostingController(rootView: TerminalEditorHarness {
            submissionCount += 1
        })
        let window = makeWindow(hosting: host)
        defer { window.isHidden = true }

        let textView = try XCTUnwrap(descendants(of: IntrinsicTextView.self, in: window).first)
        textView.text = "ship it"
        let acceptsReturn = textView.delegate?.textView?(
            textView,
            shouldChangeTextIn: NSRange(location: textView.text.utf16.count, length: 0),
            replacementText: "\n"
        )

        XCTAssertEqual(acceptsReturn, false)
        XCTAssertEqual(submissionCount, 1)
        XCTAssertEqual(textView.text, "ship it")
    }

    private func descendants<T: UIView>(of type: T.Type, in root: UIView) -> [T] {
        let own = (root as? T).map { [$0] } ?? []
        return own + root.subviews.flatMap { descendants(of: type, in: $0) }
    }

    private func makeWindow<Content: View>(
        hosting host: UIHostingController<Content>,
        size: CGSize = CGSize(width: 320, height: 140)
    ) -> UIWindow {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: .zero)
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = host
        window.makeKeyAndVisible()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        window.layoutIfNeeded()
        return window
    }

    private struct TerminalEditorHarness: View {
        @State private var draft: String
        @State private var isFocused = false
        let editorWidth: CGFloat
        let editorHeight: CGFloat?
        let onSubmit: () -> Void

        init(
            initialDraft: String = "",
            editorWidth: CGFloat = 288,
            editorHeight: CGFloat? = 100,
            onSubmit: @escaping () -> Void = {}
        ) {
            _draft = State(initialValue: initialDraft)
            self.editorWidth = editorWidth
            self.editorHeight = editorHeight
            self.onSubmit = onSubmit
        }

        var body: some View {
            TerminalLinePromptEditor(
                text: $draft,
                isFocused: $isFocused,
                theme: RemoteThemePalette(nil),
                onSubmit: onSubmit
            )
            .frame(width: editorWidth)
            .frame(height: editorHeight)
        }
    }
}

/// Once a submission has named an upload set, its chips are a frozen receipt until the host
/// accepts or refuses it. Mutating that set in flight would either lie about what was sent or
/// clear a newly staged file when the earlier submission is accepted.
final class ComposerAttachmentPayloadTests: XCTestCase {
    func testAQuickTimeMovieBecomesAPlayableAttachmentPayload() throws {
        let payload = try XCTUnwrap(ComposerAttachmentPayload.prepared(
            data: Data("fixture".utf8),
            name: "Recording.mov",
            type: .quickTimeMovie
        ))

        XCTAssertTrue(payload.isMovie)
        XCTAssertEqual(payload.systemImage, "film")
        XCTAssertNil(payload.thumbnail, "the poster is extracted asynchronously after staging")
    }
}

@MainActor
final class ComposerAttachmentStripTests: XCTestCase {

    func testRemovalCanBeFrozenWithoutChangingTheRenderedItems() throws {
        let strip = ComposerAttachmentStripView()
        let item = ComposerAttachmentItem(
            name: "notes.txt",
            thumbnail: nil,
            systemImage: "doc"
        )
        let theme = RemoteThemePalette(nil)

        strip.update(items: [item], theme: theme, isRemovalEnabled: false)

        let removeButton = try XCTUnwrap(descendants(of: UIButton.self, in: strip).first {
            $0.accessibilityIdentifier == "composer.attachment.remove"
        })
        XCTAssertFalse(removeButton.isEnabled)
        XCTAssertLessThan(removeButton.alpha, 1)

        // This deliberately changes only interactivity. The strip's bounded-render early return
        // must include that state or the button would remain frozen after a refusal.
        strip.update(items: [item], theme: theme, isRemovalEnabled: true)
        let enabledButton = try XCTUnwrap(descendants(of: UIButton.self, in: strip).first {
            $0.accessibilityIdentifier == "composer.attachment.remove"
        })
        XCTAssertTrue(enabledButton.isEnabled)
        XCTAssertEqual(enabledButton.alpha, 1)
    }

    func testAMoviePosterCarriesAPlayMarkAndOpensQuickView() throws {
        let strip = ComposerAttachmentStripView()
        let poster = try XCTUnwrap(UIImage(systemName: "photo"))
        let item = ComposerAttachmentItem(
            name: "Recording.mov",
            thumbnail: poster,
            systemImage: "film",
            isMovie: true
        )
        var previewed: ComposerAttachmentItem?
        strip.onPreview = { previewed = $0 }

        strip.update(items: [item], theme: RemoteThemePalette(nil))

        let playMark = try XCTUnwrap(descendants(of: UIView.self, in: strip).first {
            $0.accessibilityIdentifier == "composer.attachment.play-mark"
        })
        XCTAssertFalse(playMark.isHidden)
        let previewButton = try XCTUnwrap(descendants(of: UIButton.self, in: strip).first {
            $0.accessibilityIdentifier == "composer.attachment.preview"
        })
        XCTAssertTrue(previewButton.isEnabled)

        previewButton.sendActions(for: .touchUpInside)

        XCTAssertEqual(previewed, item)
    }

    func testSwiftUIBridgeKeepsTheStripToItsOwnedHeight() throws {
        let item = ComposerAttachmentItem(
            name: "notes.txt",
            thumbnail: nil,
            systemImage: "doc"
        )
        let bridge = ComposerAttachmentStrip(
            items: [item],
            theme: RemoteThemePalette(nil),
            remove: { _ in }
        )
        let host = UIHostingController(rootView:
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                bridge
                Color.clear.frame(height: 44)
            }
            .frame(width: 240, height: 400)
        )
        let window = makeWindow(hosting: host, size: CGSize(width: 240, height: 400))
        defer { window.isHidden = true }

        let strip = try XCTUnwrap(
            descendants(of: ComposerAttachmentStripView.self, in: window).first
        )
        XCTAssertEqual(
            strip.frame.height,
            ComposerAttachmentMetrics.stripHeight,
            accuracy: 0.5,
            "the bridge must not absorb the composer's remaining vertical space"
        )
    }

    private func descendants<T: UIView>(of type: T.Type, in root: UIView) -> [T] {
        let own = (root as? T).map { [$0] } ?? []
        return own + root.subviews.flatMap { descendants(of: type, in: $0) }
    }

    private func makeWindow<Content: View>(
        hosting host: UIHostingController<Content>,
        size: CGSize
    ) -> UIWindow {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: .zero)
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = host
        window.makeKeyAndVisible()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        window.layoutIfNeeded()
        return window
    }
}

/// File providers control both the metadata and the bytes behind a picked URL. The reader is the
/// memory boundary, so the tray's later validation is defence in depth rather than the first time
/// an oversized document is noticed.
final class ComposerAttachmentSourceTests: XCTestCase {

    func testBoundedReaderReturnsAnOrdinaryFileExactly() throws {
        let expected = Data("release notes".utf8)
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try expected.write(to: url)

        XCTAssertEqual(ComposerAttachmentSources.readFile(at: url), expected)
    }

    func testBoundedReaderRefusesAnOversizedSparseFile() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(
            atOffset: UInt64(RemoteAttachmentUploadLimits.maximumBytesPerFile + 1)
        )
        try handle.close()

        XCTAssertNil(ComposerAttachmentSources.readFile(at: url))
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "composer-attachment-source-\(UUID().uuidString)"
        )
    }
}
