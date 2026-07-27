import AppKit
import XCTest
@testable import Skalman

/// What a file dropped on the terminal turns into.
///
/// The terminal pane refused every drop before this: SwiftTerm's view registers no dragged
/// types, so an image dragged onto the one surface most likely to receive one did nothing —
/// while the composer beside it accepted the same drag. What a terminal can carry is text, so
/// the drop types a path, and the part that can be wrong is the escaping.
final class TerminalDropTests: XCTestCase {

    // MARK: - Escaping

    func testAnOrdinaryPathIsInsertedUnchanged() {
        XCTAssertEqual(TerminalDrop.escaped("/Users/example/shot.png"), "/Users/example/shot.png")
    }

    /// The case the whole thing exists for: a space is where a shell ends a word, so an
    /// unescaped one loses the file and takes the rest of the path with it.
    func testSpacesAreEscaped() {
        XCTAssertEqual(
            TerminalDrop.escaped("/Users/example/My Photos/a b.png"),
            "/Users/example/My\\ Photos/a\\ b.png"
        )
    }

    /// The backslash goes first, or escaping it afterwards escapes the escapes.
    func testABackslashInAPathIsEscapedOnce() {
        XCTAssertEqual(TerminalDrop.escaped("/tmp/a\\b"), "/tmp/a\\\\b")
        XCTAssertEqual(TerminalDrop.escaped("/tmp/a\\ b"), "/tmp/a\\\\\\ b")
    }

    func testShellMetacharactersAreEscaped() {
        XCTAssertEqual(TerminalDrop.escaped("/tmp/$HOME"), "/tmp/\\$HOME")
        XCTAssertEqual(TerminalDrop.escaped("/tmp/a*b"), "/tmp/a\\*b")
        XCTAssertEqual(TerminalDrop.escaped("/tmp/a(1).png"), "/tmp/a\\(1\\).png")
        XCTAssertEqual(TerminalDrop.escaped("/tmp/it's.png"), "/tmp/it\\'s.png")
    }

    /// A newline in a filename is legal, and a terminal reads an unescaped one as *enter* —
    /// which would submit whatever was already typed.
    func testANewlineInAPathIsEscapedRatherThanSubmitted() {
        let escaped = TerminalDrop.escaped("/tmp/two\nlines.png")
        XCTAssertEqual(escaped, "/tmp/two\\\nlines.png")
        XCTAssertFalse(
            escaped.contains(where: { $0 == "\n" && escaped.first != "\\" }) && !escaped.contains("\\\n"),
            "an unescaped newline would submit the line"
        )
    }

    // MARK: - The Inserted Text

    func testEachPathIsSeparatedAndTheLineEndsOpen() {
        XCTAssertEqual(
            TerminalDrop.text(for: ["/tmp/a.png", "/tmp/b c.png"]),
            "/tmp/a.png /tmp/b\\ c.png "
        )
    }

    /// The trailing space is what lets a second drop, or a typed word, land beside the first
    /// rather than glued to it.
    func testASinglePathStillEndsWithASeparator() {
        XCTAssertEqual(TerminalDrop.text(for: ["/tmp/a.png"]), "/tmp/a.png ")
    }

    func testNothingDroppedInsertsNothing() {
        XCTAssertEqual(TerminalDrop.text(for: []), "")
    }

    // MARK: - What the Pasteboard Offers

    /// A drag is answered continuously while the pointer moves, so the cheap question has to
    /// be answerable without doing the expensive work — writing a screenshot out per frame of
    /// the gesture would litter the temporary directory.
    @MainActor
    func testAPasteboardIsJudgedWithoutWritingAnything() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("skalman.terminal.drop.test"))

        pasteboard.clearContents()
        XCTAssertFalse(PromptAttachment.canRead(pasteboard))
        XCTAssertTrue(PromptAttachment.paths(from: pasteboard).isEmpty)

        pasteboard.clearContents()
        pasteboard.setString("just text", forType: .string)
        XCTAssertFalse(PromptAttachment.canRead(pasteboard), "plain text is not an attachment")

        pasteboard.clearContents()
        let url = URL(fileURLWithPath: "/tmp/skalman-drop-fixture.png")
        pasteboard.writeObjects([url as NSURL])
        XCTAssertTrue(PromptAttachment.canRead(pasteboard))
        XCTAssertEqual(PromptAttachment.paths(from: pasteboard), [url.path])
    }

    /// A screenshot dragged out of Preview has no path at all, so one is made for it — the
    /// same trick the composer already plays, and the only reason a pasted image can reach an
    /// agent that can only open files.
    @MainActor
    func testRawImageDataBecomesAFileTheAgentCanOpen() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("skalman.terminal.drop.image"))
        pasteboard.clearContents()

        let image = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { bounds in
            NSColor.red.setFill()
            bounds.fill()
            return true
        }
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        pasteboard.setData(tiff, forType: .tiff)

        XCTAssertTrue(PromptAttachment.canRead(pasteboard))

        let paths = PromptAttachment.paths(from: pasteboard)
        let path = try XCTUnwrap(paths.first, "raw image data produced no path")
        defer { try? FileManager.default.removeItem(atPath: path) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(URL(fileURLWithPath: path).pathExtension, "png")
    }
}
