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
        var draft = Fixture.existingDraft
        var isFocused = false
        var pastedFiles = 0
        let editor = SessionDraftPromptEditor(
            text: Binding(get: { draft }, set: { draft = $0 }),
            isFocused: Binding(get: { isFocused }, set: { isFocused = $0 }),
            isEnabled: true,
            theme: RemoteThemePalette(nil),
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
        XCTAssertEqual(draft, Fixture.existingDraft)
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
}

/// Once a submission has named an upload set, its chips are a frozen receipt until the host
/// accepts or refuses it. Mutating that set in flight would either lie about what was sent or
/// clear a newly staged file when the earlier submission is accepted.
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

        let removeButton = try XCTUnwrap(descendants(of: UIButton.self, in: strip).first)
        XCTAssertFalse(removeButton.isEnabled)
        XCTAssertLessThan(removeButton.alpha, 1)

        // This deliberately changes only interactivity. The strip's bounded-render early return
        // must include that state or the button would remain frozen after a refusal.
        strip.update(items: [item], theme: theme, isRemovalEnabled: true)
        let enabledButton = try XCTUnwrap(descendants(of: UIButton.self, in: strip).first)
        XCTAssertTrue(enabledButton.isEnabled)
        XCTAssertEqual(enabledButton.alpha, 1)
    }

    private func descendants<T: UIView>(of type: T.Type, in root: UIView) -> [T] {
        let own = (root as? T).map { [$0] } ?? []
        return own + root.subviews.flatMap { descendants(of: type, in: $0) }
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
