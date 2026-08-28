import AppKit
@testable import SwiftTerm
import XCTest
@testable import Threading

/// Replays a recorded pty byte stream into the product's Claude terminal pane, at the grid it was
/// recorded on, and writes what the emulator holds afterwards — the visible rows, the whole
/// buffer, and a picture.
///
/// Opt-in: `THREADING_PTY_REPLAY` names one or more (colon-separated) `.jsonl` recordings made by
/// `record_pty.py`, whose frames are `{"t", "kind": "out"|"resize"|"in", "b64"|"cols"/"rows"}`.
/// Resizes are applied to the window exactly where they fell in the stream, so the emulator sees
/// the same resize-then-redraw order the child produced. The point is a deterministic reproduction
/// of a TUI whose picture no longer matched its bytes: the dumped buffer says whether the emulator
/// itself disagrees with the stream, and the PNG says whether the drawing disagrees with the buffer.
@MainActor
final class TerminalReplayReproTests: XCTestCase {
    private enum Fixture {
        static let replayKey = "THREADING_PTY_REPLAY"
        static let initialSize = NSSize(width: 1400, height: 900)
        static let fitAttempts = 8
        static var outputDirectory: URL {
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"],
               !override.isEmpty {
                return URL(fileURLWithPath: override, isDirectory: true)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }
    }

    private enum Frame {
        case out([UInt8])
        case resize(cols: Int, rows: Int)
        case input
    }

    private var window: NSWindow?
    private var controller: AgentSessionViewController?

    override func tearDown() {
        window?.orderOut(nil)
        window = nil
        controller = nil
        super.tearDown()
    }

    func testReplaysRecordedStreamsIntoTheProductTerminal() throws {
        guard let list = ProcessInfo.processInfo.environment[Fixture.replayKey], !list.isEmpty else {
            throw XCTSkip("set \(Fixture.replayKey) to one or more record_pty.py .jsonl files")
        }
        try FileManager.default.createDirectory(
            at: Fixture.outputDirectory,
            withIntermediateDirectories: true
        )
        for path in list.split(separator: ":").map(String.init) {
            try replay(URL(fileURLWithPath: path))
        }
    }

    private func replay(_ recording: URL) throws {
        let frames = try parse(recording)
        let name = recording.deletingPathExtension().lastPathComponent

        let controller = AgentSessionViewController(
            agentSession: AgentSession(kind: .claude, title: "Replay \(name)")
        )
        self.controller = controller
        _ = controller.view
        var profile = TerminalProfile.default
        profile.theme = .systemDark
        controller.session.updateProfile(profile)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Fixture.initialSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        self.window?.orderOut(nil)
        self.window = window
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = controller.paneBackgroundColor
        window.contentViewController = controller
        window.setContentSize(Fixture.initialSize)
        controller.view.frame = NSRect(origin: .zero, size: Fixture.initialSize)
        controller.view.layoutSubtreeIfNeeded()

        let terminal = controller.session.terminalView
        terminal.suspendsRenderingWhenNotVisible = false
        terminal.cursorStyle = .steadyBlock
        settle(terminal)

        var log: [String] = []
        for frame in frames {
            switch frame {
            case .resize(let cols, let rows):
                fit(terminal, cols: cols, rows: rows)
                let dims = terminal.terminalDimensions
                log.append("resize -> asked \(cols)×\(rows), grid \(dims.cols)×\(dims.rows)")
            case .out(let bytes):
                terminal.feed(byteArray: ArraySlice(bytes))
                settle(terminal)
            case .input:
                // The first keystroke in a recording is the Ctrl-C that ends the child, and a TUI
                // tears its screen down on the way out. The state under test is the one before it.
                break
            }
            if case .input = frame { break }
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        settle(terminal)

        let snapshot = terminal.terminalStateSnapshot()
        let visible = snapshot.visibleRows.map(\.text)
        let buffer: [String] = terminal.withTerminal { term in
            (0..<term.buffer.lines.count).map { index in
                term.buffer.lines[index].translateToString(trimRight: true)
            }
        }
        log.append("final grid \(snapshot.dimensions.cols)×\(snapshot.dimensions.rows), viewportRow \(snapshot.viewportRow), buffer lines \(buffer.count)")

        let base = Fixture.outputDirectory.appendingPathComponent("replay-\(name)")
        try visible.joined(separator: "\n").write(
            to: base.appendingPathExtension("visible.txt"),
            atomically: true,
            encoding: .utf8
        )
        try buffer.enumerated().map { "\($0.offset)\t\($0.element)" }.joined(separator: "\n").write(
            to: base.appendingPathExtension("buffer.txt"),
            atomically: true,
            encoding: .utf8
        )
        try log.joined(separator: "\n").write(
            to: base.appendingPathExtension("log.txt"),
            atomically: true,
            encoding: .utf8
        )

        // The pane, not the bare terminal: the terminal's layer is clear and the pane paints the
        // theme's ground behind it, so a capture of the terminal alone loses every bright glyph.
        let pane = controller.view
        let representation = try XCTUnwrap(
            pane.bitmapImageRepForCachingDisplay(in: pane.bounds)
        )
        pane.cacheDisplay(in: pane.bounds, to: representation)
        pane.cacheDisplay(in: pane.bounds, to: representation)
        let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        try png.write(to: base.appendingPathExtension("png"), options: .atomic)
    }

    // MARK: - Helpers

    private func parse(_ url: URL) throws -> [Frame] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try text.split(separator: "\n").map { line in
            let object = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            )
            switch object["kind"] as? String {
            case "out":
                let data = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(object["b64"] as? String)))
                return .out([UInt8](data))
            case "resize":
                return .resize(
                    cols: try XCTUnwrap(object["cols"] as? Int),
                    rows: try XCTUnwrap(object["rows"] as? Int)
                )
            default:
                return .input
            }
        }
    }

    /// Grows or shrinks the window until the product pane's terminal sits on exactly this grid.
    private func fit(_ terminal: EmojiFixedTerminalView, cols: Int, rows: Int) {
        guard let window, let controller else { return }
        for _ in 0..<Fixture.fitAttempts {
            settle(terminal)
            let dims = terminal.terminalDimensions
            if dims.cols == cols, dims.rows == rows { return }
            let cellWidth = terminal.bounds.width / CGFloat(max(1, dims.cols))
            let cellHeight = terminal.bounds.height / CGFloat(max(1, dims.rows))
            var size = controller.view.bounds.size
            size.width += CGFloat(cols - dims.cols) * cellWidth
            size.height += CGFloat(rows - dims.rows) * cellHeight
            window.setContentSize(size)
            controller.view.frame = NSRect(origin: .zero, size: size)
            controller.view.layoutSubtreeIfNeeded()
        }
        let dims = terminal.terminalDimensions
        XCTAssertEqual(dims.cols, cols, "could not fit the pane to \(cols) columns")
        XCTAssertEqual(dims.rows, rows, "could not fit the pane to \(rows) rows")
    }

    private func settle(_ terminal: EmojiFixedTerminalView) {
        terminal.frameTick()
        terminal.superview?.layoutSubtreeIfNeeded()
        terminal.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        terminal.frameTick()
        terminal.superview?.layoutSubtreeIfNeeded()
        terminal.layoutSubtreeIfNeeded()
    }
}
