import AppKit
import SwiftTerm
import XCTest
@testable import Threading

/// Draws one line of agent-shaped output on every stock palette and writes the sheet out.
///
/// This is the review surface for the whole change. A heading's job is to be *seen*, which is
/// reason the sheet is inspected as well as asserted. Each strip must contain foreground ink,
/// including bold-coloured pixels in the heading cells; a blank ground cannot pass. The palette
/// selection constraints live in `TerminalBoldTextSweepTests`.
///
/// The rows are real `TerminalView`s fed real escape sequences rather than attributed strings,
/// because the rule under review lives in the fork's `mapColor` and an attributed string would
/// be a second implementation of it.
final class TerminalBoldTextRenderTests: XCTestCase {

    private enum Sheet {
        static let sample = "Body text  \u{1B}[1mBold heading\u{1B}[0m  "
            + "\u{1B}[2mdim\u{1B}[0m  \u{1B}[31mred\u{1B}[0m  \u{1B}[1;31mbold red\u{1B}[0m"

        /// DECTCEM off, so the caret cannot stand in for text in an ink count.
        static let hideCursor = "\u{1B}[?25l"
        static let bodyColumns = 11
        static let headingColumns = 12
        static let minimumInkPixels = 20
        static let backgroundDistance: CGFloat = 0.08
        static let inkDistance: CGFloat = 0.18
        static let labelWidth: CGFloat = 190
        static let terminalWidth: CGFloat = 460
        static let rowHeight: CGFloat = 44
        static let margin: CGFloat = 16
        /// Retina, so the sample text is legible when the reviewer zooms in.
        static let scale: CGFloat = 2
        static var width: CGFloat { margin * 3 + labelWidth + terminalWidth }

        static var directory: URL {
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"],
               !override.isEmpty {
                return URL(fileURLWithPath: override)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }
    }

    /// Named the way the reviewer will look for them: built-ins first, then the app themes in
    /// catalogue order, each variant on its own row.
    @MainActor
    private func palettes() -> [(name: String, palette: TerminalTheme)] {
        var rows: [(String, TerminalTheme)] = TerminalTheme.builtInThemes.map { ($0.name, $0) }
        rows.append(("System (light)", .systemLight))
        rows.append(("System (dark)", .systemDark))

        for theme in AppThemeStyles.all {
            for kind in theme.availableVariants {
                guard let variant = theme.variant(kind) else { continue }
                let suffix = theme.availableVariants.count > 1 ? " (\(kind.rawValue))" : ""
                rows.append((theme.name + suffix, variant.terminalPalette))
            }
        }
        return rows.map { (name: $0.0, palette: $0.1) }
    }

    @MainActor
    func testDrawsAContactSheetOfEveryPalettesHeading() throws {
        let directory = Sheet.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let rows = palettes()
        let height = Sheet.margin * 2 + Sheet.rowHeight * CGFloat(rows.count)
        let sheet = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(Sheet.width * Sheet.scale),
                pixelsHigh: Int(height * Sheet.scale),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        )
        sheet.size = NSSize(width: Sheet.width, height: height)

        var hosts: [NSWindow] = []
        var strips: [(name: String, image: NSBitmapImageRep)] = []
        for row in rows {
            let image = try XCTUnwrap(strip(of: row.palette, hosts: &hosts), "\(row.name) drew no strip")
            XCTAssertGreaterThan(inkPixels(in: image, palette: row.palette),
                                 Sheet.minimumInkPixels, "\(row.name): no foreground ink")
            XCTAssertGreaterThan(inkPixels(in: image, palette: row.palette, headingOnly: true),
                                 Sheet.minimumInkPixels, "\(row.name): no bold heading ink")
            strips.append((name: row.name, image: image))
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sheet)
        NSColor(hex: "#151515")!.setFill()
        NSRect(x: 0, y: 0, width: Sheet.width, height: height).fill()

        for (index, row) in strips.enumerated() {
            // The context's coordinates run bottom-up, so the first palette sits at the top.
            let top = Sheet.margin + Sheet.rowHeight * CGFloat(rows.count - index - 1)

            (row.name as NSString).draw(
                at: NSPoint(x: Sheet.margin, y: top + (Sheet.rowHeight - 14) / 2),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: NSColor(hex: "#DDDDDD")!
                ]
            )
            rows[index].palette.background.setFill()
            NSRect(x: Sheet.margin * 2 + Sheet.labelWidth, y: top + 2,
                   width: Sheet.terminalWidth, height: Sheet.rowHeight - 4).fill()
            let composite = NSImage(size: row.image.size)
            composite.addRepresentation(row.image)
            composite.draw(
                in: NSRect(
                    x: Sheet.margin * 2 + Sheet.labelWidth,
                    y: top + 2,
                    width: Sheet.terminalWidth,
                    height: Sheet.rowHeight - 4
                ), from: .zero, operation: .sourceOver, fraction: 1
            )
        }
        NSGraphicsContext.restoreGraphicsState()

        let url = directory.appendingPathComponent("terminal-bold-text.png")
        let data = try XCTUnwrap(
            sheet.representation(using: .png, properties: [:]),
            "the contact sheet rendered nothing"
        )
        try data.write(to: url)

        print("Rendered \(rows.count) palettes to \(url.path)")
        XCTAssertGreaterThan(data.count, 10_000, "the sheet came out blank")
    }

    /// A negative control through the same renderer: without the sample, neither the
    /// background nor anything else on the strip may be mistaken for text — the whole strip
    /// included, which is what proves the caret is not what the ink checks are counting.
    @MainActor
    func testUnfedTerminalHasNoInk() throws {
        let palette = TerminalTheme.basic
        var hosts: [NSWindow] = []
        let image = try XCTUnwrap(strip(of: palette, hosts: &hosts, feedSample: false))
        XCTAssertEqual(inkPixels(in: image, palette: palette), 0)
        XCTAssertEqual(inkPixels(in: image, palette: palette, headingOnly: true), 0)
    }

    @MainActor
    private func inkPixels(in image: NSBitmapImageRep, palette: TerminalTheme,
                           headingOnly: Bool = false) -> Int {
        guard let background = palette.background.usingColorSpace(.deviceRGB),
              let bold = palette.boldForeground.usingColorSpace(.deviceRGB) else { return 0 }
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let cellWidth = ("W" as NSString).size(withAttributes: [.font: font]).width
        let scale = CGFloat(image.pixelsWide) / Sheet.terminalWidth
        let start = headingOnly ? Int(CGFloat(Sheet.bodyColumns) * cellWidth * scale) : 0
        let end = headingOnly
            ? min(image.pixelsWide, Int(CGFloat(Sheet.bodyColumns + Sheet.headingColumns) * cellWidth * scale))
            : image.pixelsWide
        func distance(_ a: NSColor, _ b: NSColor) -> CGFloat {
            max(abs(a.redComponent - b.redComponent), abs(a.greenComponent - b.greenComponent),
                abs(a.blueComponent - b.blueComponent))
        }
        var count = 0
        for y in 0..<image.pixelsHigh {
            for x in start..<end {
                guard let pixel = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      pixel.alphaComponent > 0.75,
                      distance(pixel, background) > Sheet.backgroundDistance else { continue }
                if !headingOnly || distance(pixel, bold) < Sheet.inkDistance { count += 1 }
            }
        }
        return count
    }

    /// One palette's line, drawn by a real terminal into its own bitmap.
    ///
    /// The view is captured on its own rather than as a subview of the sheet: SwiftTerm builds
    /// each row's attributed string inside its own `draw`, and a `cacheDisplay` taken over an
    /// enclosing host photographed thirty-seven correctly coloured grounds with no text on them.
    /// Frame ticks prepare the renderer's immutable snapshot in an unshown window, as in
    /// `TerminalGlowRenderTests`; feeding and caching alone never prepares any text.
    /// The cursor is hidden first: a caret is a block of foreground ink a third of a cell wide,
    /// enough on its own to satisfy a whole-strip ink count with no text drawn at all.
    @MainActor
    private func strip(of palette: TerminalTheme, hosts: inout [NSWindow], feedSample: Bool = true) -> NSBitmapImageRep? {
        let view = TerminalView(
            frame: NSRect(
                x: 0, y: 0,
                width: Sheet.terminalWidth,
                height: Sheet.rowHeight - 4
            )
        )
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = view
        hosts.append(window)
        view.suspendsRenderingWhenNotVisible = false
        view.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        view.appearance = NSAppearance(named: .darkAqua)
        view.installColors(palette.asSwiftTermColors())
        view.nativeForegroundColor = palette.foreground
        view.nativeBoldForegroundColor = palette.boldForeground
        view.nativeBackgroundColor = palette.background
        view.feed(text: Sheet.hideCursor)
        if feedSample { view.feed(text: Sheet.sample) }
        view.prepareFrameForSnapshot()

        // Not `bitmapImageRepForCachingDisplay`: its scale and colour profile follow whichever
        // display is main, while `colorAt(x:y:)` reads the pixels back as Generic RGB — which
        // pulled Cyberpunk's saturated yellow out of tolerance on a Retina or external display.
        // A fixed device-RGB rep at the sheet's scale measures the same pixels everywhere.
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(view.bounds.width * Sheet.scale),
            pixelsHigh: Int(view.bounds.height * Sheet.scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }
}
