import AppKit
import Metal
import SwiftTerm
import XCTest
@testable import Threading

/// The Mac terminal's renderer follows its palette's glow: Metal while it glows in a window, Core
/// Graphics otherwise (a preview or a terminal not in a window), and a window snapshot — the
/// inspector's and Report a Problem's — still shows a glowing terminal's text.
///
/// Each fixture is an unshown borderless window: joining one is what `viewDidMoveToWindow`
/// answers, and `cacheDisplay` needs nothing on screen.
@MainActor
final class TerminalGlowRendererTests: XCTestCase {

    private enum Fixture {
        static let frame = NSRect(x: 0, y: 0, width: 420, height: 160)
        static let glow = TerminalTextGlow(radius: 3, opacity: 0.5)
        static let text = "\u{1B}[?25l\u{1B}[38;2;0;255;0mphosphor green glyphs\r\nWWWW MMMM ####\u{1B}[0m"
        static let minimumGreenPixels = 200
    }

    private func window(holding view: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: Fixture.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        window.contentView = view
        return window
    }

    private func metalIsAvailable() throws {
        try XCTSkipIf(MTLCreateSystemDefaultDevice() == nil, "no Metal device")
    }

    func testGlowSelectsMetalInAWindowAndClearingItReturnsToCoreGraphics() throws {
        try metalIsAvailable()
        let terminal = EmojiFixedTerminalView(frame: Fixture.frame)
        let host = window(holding: terminal)
        XCTAssertFalse(terminal.isUsingMetalRenderer, "a terminal that does not glow draws through Core Graphics")

        terminal.setThemeTextGlow(Fixture.glow)
        XCTAssertTrue(terminal.isUsingMetalRenderer)
        XCTAssertEqual(terminal.textGlow, Fixture.glow)

        terminal.setThemeTextGlow(nil)
        XCTAssertFalse(terminal.isUsingMetalRenderer)
        XCTAssertNil(terminal.textGlow)
        withExtendedLifetime(host) {}
    }

    /// A terminal outside a window keeps Core Graphics whatever its palette says, and joining a
    /// window is what selects the renderer. Leaving keeps Metal (SwiftTerm releases the halo
    /// textures), so coming back costs no rebuild; a palette that stopped glowing meanwhile
    /// returns it to Core Graphics on arrival.
    func testTheRendererIsChosenWhenTheTerminalJoinsAWindow() throws {
        try metalIsAvailable()
        let terminal = EmojiFixedTerminalView(frame: Fixture.frame)
        terminal.setThemeTextGlow(Fixture.glow)
        XCTAssertFalse(terminal.isUsingMetalRenderer, "an unattached terminal must stay on Core Graphics")

        let host = window(holding: terminal)
        XCTAssertTrue(terminal.isUsingMetalRenderer)

        terminal.removeFromSuperview()
        XCTAssertTrue(terminal.isUsingMetalRenderer)
        host.contentView = terminal
        XCTAssertTrue(terminal.isUsingMetalRenderer)

        terminal.removeFromSuperview()
        terminal.setThemeTextGlow(nil)
        host.contentView = terminal
        XCTAssertFalse(terminal.isUsingMetalRenderer)
    }

    /// The inspector photographs the window with `cacheDisplay`, which cannot read the Metal
    /// layer a glowing terminal draws into; the snapshot has to come back with the text in it.
    func testAWindowSnapshotShowsAGlowingTerminalsText() throws {
        try metalIsAvailable()
        let terminal = EmojiFixedTerminalView(frame: Fixture.frame)
        let host = window(holding: terminal)
        terminal.setThemeTextGlow(Fixture.glow)
        XCTAssertTrue(terminal.isUsingMetalRenderer)
        terminal.feed(text: Fixture.text)
        terminal.drawMetalFrameNow()

        let rep = try XCTUnwrap(WindowSnapshot.capture(window: host, annotating: nil))
        XCTAssertGreaterThan(try greenPixels(rep), Fixture.minimumGreenPixels,
                             "the snapshot of a glowing terminal is empty")
    }

    /// Pixels that are the text's green — glyph or halo — rather than anything an empty
    /// terminal or the window's ground could produce.
    private func greenPixels(_ rep: NSBitmapImageRep) throws -> Int {
        let image = try XCTUnwrap(rep.cgImage)
        let width = image.width
        let height = image.height
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        var count = 0
        for offset in stride(from: 0, to: width * height * 4, by: 4) {
            let red = Int(pixels[offset])
            let green = Int(pixels[offset + 1])
            let blue = Int(pixels[offset + 2])
            if green > 60, green > red * 2, green > blue * 2 { count += 1 }
        }
        return count
    }
}
