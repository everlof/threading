import AppKit
import Metal
import MetalKit
import SwiftTerm
import XCTest
@testable import Threading

/// The Mac terminal's renderer follows its palette's glow: Metal while it glows in a window, Core
/// Graphics otherwise (a preview or a terminal not in a window), and a window snapshot — the
/// inspector's and Report a Problem's — still shows a glowing terminal's text. A click on a
/// glowing terminal still gives it the keyboard.
///
/// Each fixture is an unshown borderless window: joining one is what `viewDidMoveToWindow`
/// answers, and `cacheDisplay` needs nothing on screen. The click's is the exception, because a
/// window that was never ordered in ignores clicks; it is parked off every display instead.
@MainActor
final class TerminalGlowRendererTests: XCTestCase {

    private enum Fixture {
        static let frame = NSRect(x: 0, y: 0, width: 420, height: 160)
        static let glow = TerminalTextGlow(radius: 3, opacity: 0.5)
        static let text = "\u{1B}[?25l\u{1B}[38;2;0;255;0mphosphor green glyphs\r\nWWWW MMMM ####\u{1B}[0m"
        static let minimumGreenPixels = 200
        static let focusHolderWidth: CGFloat = 100
        static let parkedOrigin = NSPoint(x: -10_000, y: -10_000)
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

    /// A glowing terminal is covered by the Metal surface it draws into, and a click makes the
    /// view it lands on first responder only if that view takes the keyboard. The surface took
    /// every click, so once a button or the sidebar had the keyboard, clicking the terminal could
    /// not get it back. Only switching chats did, because attaching a chat focuses its terminal in
    /// code. Both surfaces are asked, through the window's own click handling.
    ///
    /// The window reports key status itself, as `InspectorReportFocusTests`' does: the question is
    /// which view the window gives the keyboard to, not whether the window server routes keys to
    /// the window.
    func testAClickOnAGlowingTerminalTakesTheKeyboard() throws {
        try metalIsAvailable()
        for usesLayerSurface in [true, false] {
            let surface = usesLayerSurface ? "layer surface" : "MTKView surface"
            let host = ClickFixtureWindow(
                contentRect: NSRect(x: 0, y: 0, width: Fixture.focusHolderWidth + Fixture.frame.width,
                                    height: Fixture.frame.height),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            let holder = FocusHolder(frame: NSRect(x: 0, y: 0, width: Fixture.focusHolderWidth,
                                                   height: Fixture.frame.height))
            let terminal = EmojiFixedTerminalView(
                frame: Fixture.frame.offsetBy(dx: Fixture.focusHolderWidth, dy: 0))
            try terminal.setUsesMetalLayerSurface(usesLayerSurface)
            host.contentView?.addSubview(holder)
            host.contentView?.addSubview(terminal)
            host.setFrameOrigin(Fixture.parkedOrigin)
            host.orderFront(nil)
            defer { host.orderOut(nil) }

            terminal.setThemeTextGlow(Fixture.glow)
            XCTAssertTrue(terminal.isUsingMetalRenderer, surface)
            let local = NSPoint(x: terminal.bounds.midX, y: terminal.bounds.midY)
            let cover = try XCTUnwrap(terminal.subviews.first { $0.layer is CAMetalLayer },
                                      "a glowing terminal draws into a Metal surface")
            XCTAssertEqual(cover is MTKView, !usesLayerSurface, surface)
            XCTAssertTrue(cover.frame.contains(local), "the \(surface) covers the terminal")

            XCTAssertTrue(host.makeFirstResponder(holder))
            let point = terminal.convert(local, to: nil)
            try click(host, at: point)
            let owner = String(describing: host.firstResponder)
            XCTAssertTrue(host.firstResponder === terminal,
                          "a click on a glowing terminal (\(surface)) leaves the keyboard with \(owner)")
            XCTAssertTrue(host.contentView?.hitTest(point) === terminal,
                          "the window asks the \(surface), not the terminal, whether a first click counts")
        }
    }

    private func click(_ window: NSWindow, at point: NSPoint) throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
            )))
        }
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

/// Reports key status so the window treats a click as one in the window that has the keyboard.
/// See the note above the click test.
private final class ClickFixtureWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

/// Stands in for the button or sidebar row that has the keyboard before the click.
private final class FocusHolder: NSView {
    override var acceptsFirstResponder: Bool { true }
}
