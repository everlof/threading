import XCTest
import AppKit
import SwiftTerm
import UniformTypeIdentifiers
@testable import Threading

/// Drags that promise their files instead of carrying them.
///
/// A clip dragged out of Photos, a picture out of Messages or Mail, a video off a web page: none
/// of them put `public.file-url` on the pasteboard, because the file the drop wants does not exist
/// yet. Threading registered only the URL flavour, so all of them were refused — the terminal, the
/// composer and the attachments list alike — while the same file dragged from Finder worked.
///
/// **What a test can reach here.** A promise is written by one process and fulfilled for another,
/// and the fulfilment half needs a real drag session: a promise this process writes and reads back
/// answers every question about *what it is* and never delivers. So the reading half is tested
/// against a real `NSFilePromiseProvider`, and what the app does with the answers is tested
/// through `DroppedFilePromiseCollector`, which is that half factored out.
@MainActor
final class DroppedFilePromiseTests: XCTestCase {

    // MARK: - Harness

    /// A promise of one file, of whatever type the test asks for.
    private final class PromisedFile: NSObject, NSFilePromiseProviderDelegate {
        let name: String

        init(name: String) {
            self.name = name
        }

        func filePromiseProvider(
            _ filePromiseProvider: NSFilePromiseProvider,
            fileNameForType fileType: String
        ) -> String {
            name
        }

        func filePromiseProvider(
            _ filePromiseProvider: NSFilePromiseProvider,
            writePromiseTo url: URL,
            completionHandler: @escaping (Error?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    /// Stands in for the PTY, as in `TerminalDropPasteTests`: the view is its own delegate once
    /// it owns a process, so taking that place is how the bytes are read without one.
    private final class Recorder: TerminalViewDelegate {
        var written: [UInt8] = []

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            written.append(contentsOf: data)
        }

        var text: String { String(decoding: written, as: UTF8.self) }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }

    private var pasteboards: [NSPasteboard]!
    private var promises: [PromisedFile]!

    override func setUpWithError() throws {
        try super.setUpWithError()
        pasteboards = []
        promises = []
    }

    override func tearDownWithError() throws {
        for pasteboard in pasteboards { pasteboard.releaseGlobally() }
        pasteboards = nil
        promises = nil
        try super.tearDownWithError()
    }

    private func pasteboard() -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("threading-tests-\(UUID().uuidString)"))
        board.clearContents()
        pasteboards.append(board)
        return board
    }

    /// A pasteboard carrying one promised file, as a drag out of another app carries it.
    private func promising(_ type: UTType, named name: String) -> NSPasteboard {
        let delegate = PromisedFile(name: name)
        // Held for the life of the test: `NSFilePromiseProvider` keeps its delegate weakly, and a
        // promise whose delegate has gone answers nothing.
        promises.append(delegate)
        let board = pasteboard()
        board.writeObjects([NSFilePromiseProvider(fileType: type.identifier, delegate: delegate)])
        return board
    }

    // MARK: - Reading the Promise

    func testAPromisedFileIsRecognisedWithoutBeingWritten() {
        XCTAssertTrue(DroppedFilePromise.canRead(promising(.quickTimeMovie, named: "clip.mov")))
    }

    func testAnOrdinaryPasteboardPromisesNothing() {
        let board = pasteboard()
        board.setString("words", forType: .string)

        XCTAssertFalse(DroppedFilePromise.canRead(board))
    }

    /// The type is on the pasteboard from the start, which is what lets a destination that takes
    /// only some kinds of file answer the drag without writing anything.
    func testThePromisedTypeIsReadableBeforeTheDrop() {
        XCTAssertEqual(
            DroppedFilePromise.contentTypes(in: promising(.quickTimeMovie, named: "clip.mov")),
            [.quickTimeMovie]
        )
    }

    /// Why the *type* is what gets asked. `fileNames` is empty until the files have been written,
    /// so a destination filtering on the name would refuse every promise ever made.
    func testAPromiseIsNotNamedYet() {
        let board = promising(.png, named: "shot.png")
        let receivers = board.readObjects(forClasses: [NSFilePromiseReceiver.self])
            as? [NSFilePromiseReceiver] ?? []

        XCTAssertEqual(receivers.count, 1)
        XCTAssertEqual(receivers.first?.fileNames ?? [], [])
    }

    /// Nothing promised, nothing started — so a destination can try this after its own file and
    /// image routes and still fall through to whatever it does for a drag it cannot use.
    func testAPasteboardWithNoPromiseStartsNothing() {
        let board = pasteboard()
        board.setString("words", forType: .string)

        var calls = 0
        XCTAssertFalse(DroppedFilePromise.receive(from: board) { _ in calls += 1 })
        XCTAssertEqual(calls, 0)
    }

    // MARK: - Who Takes It

    /// The attachments list compares pictures, and answers a promise on what it is rather than on
    /// what it will be called.
    func testTheAttachmentsListTakesAPromisedPictureAndNotAPromisedClip() {
        XCTAssertTrue(AttachmentComparisonDrop.promisesImage(promising(.png, named: "shot.png")))
        XCTAssertFalse(
            AttachmentComparisonDrop.promisesImage(promising(.quickTimeMovie, named: "clip.mov"))
        )
    }

    /// Every surface that takes a dropped file registers for promises too, or AppKit never routes
    /// one to it — the registration *is* the fix, and this is the assertion that fails if a new
    /// drop target repeats the omission.
    func testTheSurfacesThatTakeFilesAreOfferedPromises() {
        let types = DroppedFilePromise.readableTypes
        XCTAssertFalse(types.isEmpty)

        let terminal = EmojiFixedTerminalView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let prompt = PromptView()
        // Registration only sticks once the view is in a window — see `PromptTextView`.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView?.addSubview(prompt)

        for type in types {
            XCTAssertTrue(
                terminal.registeredDraggedTypes.contains(type),
                "the terminal is not offered \(type.rawValue)"
            )
            XCTAssertTrue(
                prompt.registeredDraggedTypes.contains(type),
                "the composer is not offered \(type.rawValue)"
            )
        }
    }

    /// The terminal takes the drop and pastes nothing, which is the whole shape of a promise: the
    /// gesture is answered now and the path arrives when the source has written it.
    func testTheTerminalTakesAPromisedDropAndPastesNothingYet() {
        let terminal = EmojiFixedTerminalView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let recorder = Recorder()
        terminal.terminalDelegate = recorder

        XCTAssertTrue(terminal.accept(promising(.quickTimeMovie, named: "clip.mov")))
        XCTAssertEqual(recorder.text, "")
    }

    // MARK: - The Answers

    /// In the drag's own order, not in the order the files happened to be written: several
    /// sources write concurrently, and the smallest file is not the one that was dropped first.
    func testPathsComeBackInTheDragsOwnOrder() {
        var answered: [String]?
        let collector = DroppedFilePromiseCollector(expected: [1, 1]) { answered = $0 }

        collector.received(path: "/tmp/second.mov", failure: nil, at: 1)
        XCTAssertNil(answered, "one file of two is not an answer")

        collector.received(path: "/tmp/first.mov", failure: nil, at: 0)
        XCTAssertEqual(answered, ["/tmp/first.mov", "/tmp/second.mov"])
    }

    /// A source that fails its promise leaves a gap rather than shifting every path after it.
    func testAFailedPromiseDropsOutOfTheAnswer() {
        var answered: [String]?
        let collector = DroppedFilePromiseCollector(expected: [1, 1]) { answered = $0 }

        collector.received(path: "/tmp/gone.mov", failure: "no such file", at: 0)
        collector.received(path: "/tmp/here.mov", failure: nil, at: 1)

        XCTAssertEqual(answered, ["/tmp/here.mov"])
    }

    /// Nothing arrived at all, so the destination is never called: an empty answer would paste an
    /// empty string into a running agent, or open a comparison against nothing.
    func testAPromiseThatDeliveredNothingAnswersNothing() {
        var calls = 0
        let collector = DroppedFilePromiseCollector(expected: [1]) { _ in calls += 1 }

        collector.received(path: "/tmp/gone.mov", failure: "no such file", at: 0)

        XCTAssertEqual(calls, 0)
    }

    /// One drop is one answer. A source that keeps writing after it said it was done must not
    /// paste a second time into whatever the first paste went to.
    func testTheDestinationIsAnsweredOnce() {
        var calls = 0
        let collector = DroppedFilePromiseCollector(expected: [1]) { _ in calls += 1 }

        collector.received(path: "/tmp/a.mov", failure: nil, at: 0)
        collector.received(path: "/tmp/b.mov", failure: nil, at: 0)

        XCTAssertEqual(calls, 1)
    }
}
