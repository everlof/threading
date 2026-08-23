import AppKit
import Foundation
@testable import SwiftTerm
import XCTest
@testable import Threading

/// The claim host-backing makes, drawn: **only process ownership moves.**
///
/// `EmojiFixedTerminalView` exists for two rendering fixes — the opaque pre-fill that lets Apple
/// Color Emoji composite its alpha, and the fork's separate background pass that keeps an explicit
/// background from being erased by a wide glyph's overhang. Both live below the seam this slice
/// changed, so a host-backed terminal *should* be pixel-identical to a local one fed the same
/// bytes. "Should" is why this test draws both and compares them: the emoji bug was invisible to
/// every assertion anybody would have written and visible immediately in a picture.
///
/// Nothing here is ordered on screen — both fixtures are unshown borderless windows drawn through
/// `cacheDisplay`, which is how appearance is reviewed in this repository. `THREADING_RENDER_OUT`
/// redirects the PNGs.
@MainActor
final class PTYHostTerminalRenderTests: XCTestCase {

    // MARK: - Constants

    private enum Fixture {
        static let frame = NSRect(x: 0, y: 0, width: 520, height: 140)

        /// One line, deliberately: a bare `\n` would be turned into `\r\n` by the tty's `ONLCR`
        /// on the local path and would not be on the fed path, and this test is about pixels
        /// rather than about line discipline.
        ///
        /// It carries every part `EmojiFixedTerminalView` owns: an explicit 256-colour
        /// background, colour emoji over it, and a reverse-video run.
        static let text = "ABC \u{1b}[41m RED \u{1b}[0m \u{1F389}\u{1F600} \u{1b}[7mrev\u{1b}[0m"

        /// The same bytes as a `printf` format string, so the child writes exactly what the fed
        /// path is handed.
        static let script = "printf 'ABC \\033[41m RED \\033[0m \u{1F389}\u{1F600} \\033[7mrev\\033[0m'"

        static let childTimeout: TimeInterval = 10
    }

    private static var outputDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ThreadingRenders", isDirectory: true)
    }

    // MARK: - Fixture state

    private var windows: [NSWindow] = []
    private var localViews: [EmojiFixedTerminalView] = []

    override func tearDown() {
        for view in localViews { view.terminate() }
        localViews.removeAll()
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        super.tearDown()
    }

    // MARK: - Tests

    /// The same byte stream, through the host and through a local child, draws the same pixels.
    func testTheFedPathAndTheLocalPathDrawIdenticalPixels() throws {
        for palette in [Palette.light, Palette.dark] {
            let fed = makeView(palette: palette)
            // A real transport, so the view is in the mode under test even though this stream
            // asks the emulator nothing.
            fed.hostTransport = TerminalHostTransport(
                sendInput: { _ in },
                sendWindowSize: { _ in true },
                kill: {}
            )
            fed.feedFromHost(Array(Fixture.text.utf8))

            let local = makeView(palette: palette)
            localViews.append(local)
            try runLocally(local, expecting: Fixture.text.utf8.count)

            // Both are settled *after* both have their bytes, and both get the same run-loop
            // turns. SwiftTerm paints from a frame driver, so a fixture captured before the
            // other one has had a render pass compares two moments rather than two paths — the
            // first draft of this test did exactly that and blamed the seam for it.
            settle()
            settleFrame(fed)
            settleFrame(local)

            let fedPixels = try capture(fed, named: "pty-host-fed-\(palette.name)")
            let localPixels = try capture(local, named: "pty-host-local-\(palette.name)")

            // A comparison of two blank captures would pass for the wrong reason, and a
            // terminal that stopped drawing through `cacheDisplay` is exactly how that would
            // happen without anybody noticing. An untouched view of the same palette is the
            // control.
            let blank = makeView(palette: palette)
            settle()
            settleFrame(blank)
            XCTAssertNotEqual(
                fedPixels,
                try capture(blank, named: "pty-host-blank-\(palette.name)"),
                "the fixture captured no terminal content, so the comparison below proves nothing"
            )

            XCTAssertEqual(
                fedPixels,
                localPixels,
                """
                the \(palette.name) terminal draws differently when its child lives in the \
                background host; compare pty-host-fed-\(palette.name).png with \
                pty-host-local-\(palette.name).png
                """
            )
        }
    }

    // MARK: - Helpers

    private struct Palette {
        let name: String
        let foreground: NSColor
        let background: NSColor

        static let light = Palette(
            name: "light",
            foreground: NSColor(srgbRed: 0.09, green: 0.09, blue: 0.09, alpha: 1),
            background: NSColor(srgbRed: 0.96, green: 0.92, blue: 0.87, alpha: 1)
        )
        static let dark = Palette(
            name: "dark",
            foreground: NSColor(srgbRed: 0.90, green: 0.90, blue: 0.90, alpha: 1),
            background: NSColor(srgbRed: 0.07, green: 0.07, blue: 0.09, alpha: 1)
        )
    }

    private func makeView(palette: Palette) -> EmojiFixedTerminalView {
        let view = EmojiFixedTerminalView(frame: Fixture.frame)
        let window = NSWindow(
            contentRect: Fixture.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        window.contentView = view
        windows.append(window)
        view.suspendsRenderingWhenNotVisible = false
        view.nativeForegroundColor = palette.foreground
        view.nativeBackgroundColor = palette.background
        // Steady, because a blinking caret is a phase two fixtures would have to agree on and
        // this test is not about the caret.
        view.cursorStyle = .steadyBlock
        settleFrame(view)
        return view
    }

    /// Runs the same bytes through a real child on this view's own pty.
    private func runLocally(_ view: EmojiFixedTerminalView, expecting byteCount: Int) throws {
        let counter = Counter()
        view.onOutput = { counter.add($0) }
        view.startProcess(
            executable: "/bin/sh",
            args: ["-c", Fixture.script],
            environment: ["TERM=xterm-256color", "PATH=/usr/bin:/bin"],
            execName: "sh"
        )
        let arrived = pump(until: { counter.total >= byteCount }, timeout: Fixture.childTimeout)
        try XCTSkipUnless(
            arrived,
            "the local child produced \(counter.total) of \(byteCount) bytes; "
                + "the comparison would be between two different screens"
        )
        view.onOutput = nil
    }

    /// One turn of the main queue, for both fixtures at once.
    private func settle(_ seconds: TimeInterval = 0.1) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    private func settleFrame(_ view: EmojiFixedTerminalView) {
        view.frameTick()
        view.layoutSubtreeIfNeeded()
        view.frameTick()
    }

    private func capture(_ view: EmojiFixedTerminalView, named name: String) throws -> Data {
        let representation = try XCTUnwrap(
            view.bitmapImageRepForCachingDisplay(in: view.bounds)
        )
        view.cacheDisplay(in: view.bounds, to: representation)

        if let png = representation.representation(using: .png, properties: [:]) {
            let directory = Self.outputDirectory
            try? FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try? png.write(to: directory.appendingPathComponent("\(name).png"))
        }

        let base = try XCTUnwrap(representation.bitmapData)
        return Data(bytes: base, count: representation.bytesPerRow * representation.pixelsHigh)
    }

    private func pump(until condition: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        return condition()
    }
}

/// Counts bytes arriving on the main queue from SwiftTerm's own output hook.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var total: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func add(_ count: Int) {
        lock.lock()
        value += count
        lock.unlock()
    }
}
