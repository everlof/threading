import XCTest
import AppKit
import SwiftTerm
@testable import Threading

/// The bytes a drop on the terminal writes to the PTY.
///
/// A dropped screenshot became a line of path rather than an attached image because the drop was
/// sent as typing. Both agent CLIs read *a paste* of an image path as the image and neither
/// inspects typed characters for one, so the bracketed-paste markers are the whole of the
/// difference — which is why these assert on exact byte strings rather than on the path landing
/// somewhere.
@MainActor
final class TerminalDropPasteTests: XCTestCase {

    // MARK: - Harness

    /// Stands in for the PTY. The view is its own delegate once it owns a process, so taking
    /// that place is how the bytes are read without one.
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

    private var pasteboard: NSPasteboard!
    private var view: EmojiFixedTerminalView!
    private var recorder: Recorder!
    private var written: [String] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        pasteboard = NSPasteboard(name: NSPasteboard.Name("threading-tests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        view = EmojiFixedTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        recorder = Recorder()
        view.terminalDelegate = recorder
    }

    override func tearDownWithError() throws {
        pasteboard.releaseGlobally()
        pasteboard = nil
        view = nil
        recorder = nil

        for path in written {
            try? FileManager.default.removeItem(atPath: path)
        }
        written = []

        try super.tearDownWithError()
    }

    /// What a program that asked for bracketed paste (DECSET 2004) sees. Claude Code and Codex
    /// both do, for the whole life of their TUI.
    private func enableBracketedPaste() {
        view.feed(text: "\u{1b}[?2004h")
        XCTAssertTrue(view.getTerminal().bracketedPasteMode, "2004 should turn bracketed paste on")
        recorder.written.removeAll()
    }

    // MARK: - Wire Format

    func testDroppedPathArrivesAsAPaste() throws {
        enableBracketedPaste()
        pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/shot.png") as NSURL])

        XCTAssertTrue(view.accept(pasteboard))

        // The regression wrote `/tmp/shot.png ` bare, which both CLIs read as typing.
        XCTAssertEqual(recorder.text, "\u{1b}[200~/tmp/shot.png \u{1b}[201~")
    }

    /// The escaping still has to survive the trip: both CLIs undo backslash escapes before
    /// testing the extension, and a shell needs them to keep the name one word.
    func testEscapingSurvivesInsideTheBrackets() {
        enableBracketedPaste()
        pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/My Photos/a b.png") as NSURL])

        XCTAssertTrue(view.accept(pasteboard))

        XCTAssertEqual(recorder.text, "\u{1b}[200~/tmp/My\\ Photos/a\\ b.png \u{1b}[201~")
    }

    /// Several files are one paste, not one paste each — a CLI reading them splits on the
    /// spaces itself, and a second pair of markers would be a second, separate paste.
    func testSeveralFilesAreOnePaste() {
        enableBracketedPaste()
        pasteboard.writeObjects([
            URL(fileURLWithPath: "/tmp/a.png") as NSURL,
            URL(fileURLWithPath: "/tmp/b.png") as NSURL
        ])

        XCTAssertTrue(view.accept(pasteboard))

        XCTAssertEqual(recorder.text, "\u{1b}[200~/tmp/a.png /tmp/b.png \u{1b}[201~")
    }

    /// A plain shell that never asked for bracketed paste gets the path and nothing else, which
    /// is what it got before any of this.
    func testProgramThatDidNotAskGetsThePathAlone() {
        XCTAssertFalse(view.getTerminal().bracketedPasteMode)
        pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/shot.png") as NSURL])

        XCTAssertTrue(view.accept(pasteboard))

        XCTAssertEqual(recorder.text, "/tmp/shot.png ")
    }

    // MARK: - Contents

    /// A screenshot dragged out of a browser has no file of its own. It is written out first,
    /// and the paste names the file — the only form a CLI can act on.
    func testImageWithNoFileIsPastedByPath() throws {
        enableBracketedPaste()
        pasteboard.setData(try pngData(), forType: .png)

        XCTAssertTrue(view.accept(pasteboard))

        let pasted = recorder.text
        XCTAssertTrue(pasted.hasPrefix("\u{1b}[200~"), pasted)
        XCTAssertTrue(pasted.hasSuffix("\u{1b}[201~"), pasted)

        let path = String(pasted.dropFirst(6).dropLast(6)).trimmingCharacters(in: .whitespaces)
        written = [path]
        XCTAssertEqual(URL(fileURLWithPath: path).pathExtension, "png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    /// A pasteboard carrying neither a file nor an image is refused, so the drop falls through
    /// rather than pasting an empty string into whatever is running.
    func testNothingUsableWritesNothing() {
        enableBracketedPaste()
        pasteboard.setString("just text", forType: .string)

        XCTAssertFalse(view.accept(pasteboard))
        XCTAssertEqual(recorder.text, "")
    }

    // MARK: - The Setting

    /// On by default: a drop that looks like it worked has to have worked. The seeded default
    /// is the part that breaks silently — an unregistered key reads `false`, which would turn
    /// conversion off in every process that never touched the singleton.
    func testConversionIsOnWhenNothingHasBeenChosen() {
        let key = "convertsDroppedImages"
        let previous = UserDefaults.standard.object(forKey: key)
        addTeardownBlock {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        UserDefaults.standard.removeObject(forKey: key)

        XCTAssertTrue(AppSettings.convertsDroppedImages)
    }

    /// With it on, a format the agent cannot open is pasted as the PNG written for it.
    func testConversionOnPastesTheRewrittenFile() throws {
        setConversion(true)
        enableBracketedPaste()
        view.dropReader = .agent(.claude)
        let tiff = try writeTIFF(named: "scan")
        pasteboard.writeObjects([URL(fileURLWithPath: tiff) as NSURL])

        XCTAssertTrue(view.accept(pasteboard))

        let pasted = pastedPath()
        // The whole directory: a converted file gets one of its own so it can keep its name.
        addTeardownBlock {
            try? FileManager.default.removeItem(
                at: URL(fileURLWithPath: pasted).deletingLastPathComponent()
            )
        }
        XCTAssertEqual(URL(fileURLWithPath: pasted).lastPathComponent, "scan.png")
    }

    /// With it off, the agent is handed the file itself — which is the whole point of the
    /// switch. Someone debugging HEIC handling needs their HEIC, not a PNG of it.
    func testConversionOffPastesTheFileAsDropped() throws {
        setConversion(false)
        enableBracketedPaste()
        view.dropReader = .agent(.claude)
        let tiff = try writeTIFF(named: "scan")
        pasteboard.writeObjects([URL(fileURLWithPath: tiff) as NSURL])

        XCTAssertTrue(view.accept(pasteboard))

        XCTAssertEqual(pastedPath(), tiff)
    }

    // MARK: - Fixtures

    /// Restored afterwards: the test host writes to the real application's defaults.
    private func setConversion(_ isOn: Bool) {
        let previous = AppSettings.shared.convertsDroppedImages
        addTeardownBlock { @MainActor in AppSettings.shared.convertsDroppedImages = previous }
        AppSettings.shared.convertsDroppedImages = isOn
    }

    /// The path inside the paste, with the markers and the trailing space taken back off.
    private func pastedPath() -> String {
        recorder.text
            .replacingOccurrences(of: "\u{1b}[200~", with: "")
            .replacingOccurrences(of: "\u{1b}[201~", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    private func writeTIFF(named name: String) throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent(name).appendingPathExtension("tiff")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try tiffFixture()))
        try XCTUnwrap(bitmap.representation(using: .tiff, properties: [:])).write(to: url)
        return url.path
    }

    private func tiffFixture() throws -> Data {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        return try XCTUnwrap(image.tiffRepresentation)
    }

    private func pngData() throws -> Data {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.systemPink.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()

        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
}
