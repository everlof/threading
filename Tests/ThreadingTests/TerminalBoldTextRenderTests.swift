import AppKit
import SwiftTerm
import XCTest
@testable import Threading

/// Draws one line of agent-shaped output on every stock palette and writes the sheet out.
///
/// This is the review surface for the whole change. A heading's job is to be *seen*, which is
/// the one property no assertion in this suite can state: the palettes that shipped with body
/// and bold at the same value passed every contrast and legibility check there was. So the sheet
/// exists to be looked at, and the numbers it is chosen by live in `TerminalBoldTextSweepTests`.
///
/// The rows are real `TerminalView`s fed real escape sequences rather than attributed strings,
/// because the rule under review lives in the fork's `mapColor` and an attributed string would
/// be a second implementation of it.
final class TerminalBoldTextRenderTests: XCTestCase {

    private enum Sheet {
        static let sample = "Body text  \u{1B}[1mBold heading\u{1B}[0m  "
            + "\u{1B}[2mdim\u{1B}[0m  \u{1B}[31mred\u{1B}[0m  \u{1B}[1;31mbold red\u{1B}[0m"

        static let labelWidth: CGFloat = 190
        static let terminalWidth: CGFloat = 460
        static let rowHeight: CGFloat = 44
        static let margin: CGFloat = 16
        /// Retina, so the sample text is legible when the reviewer zooms in.
        static let scale: CGFloat = 2
        static var width: CGFloat { margin * 3 + labelWidth + terminalWidth }

        static var directory: URL {
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] {
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

        let strips = rows.map { (name: $0.name, image: strip(of: $0.palette)) }

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
            row.image?.draw(
                in: NSRect(
                    x: Sheet.margin * 2 + Sheet.labelWidth,
                    y: top + 2,
                    width: Sheet.terminalWidth,
                    height: Sheet.rowHeight - 4
                )
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
        XCTAssertEqual(strips.filter { $0.image == nil }.count, 0, "a palette drew no strip")
        XCTAssertGreaterThan(data.count, 10_000, "the sheet came out blank")
    }

    /// One palette's line, drawn by a real terminal into its own bitmap.
    ///
    /// The view is captured on its own rather than as a subview of the sheet: SwiftTerm builds
    /// each row's attributed string inside its own `draw`, and a `cacheDisplay` taken over an
    /// enclosing host photographed thirty-seven correctly coloured grounds with no text on them.
    /// The pass is taken twice for the same reason `BrowserOffScreenCaptureTests` and
    /// `TerminalColorQueryTests` do: the first one settles the terminal's own update range.
    @MainActor
    private func strip(of palette: TerminalTheme) -> NSBitmapImageRep? {
        let view = TerminalView(
            frame: NSRect(
                x: 0, y: 0,
                width: Sheet.terminalWidth,
                height: Sheet.rowHeight - 4
            )
        )
        view.appearance = NSAppearance(named: .darkAqua)
        view.installColors(palette.asSwiftTermColors())
        view.nativeForegroundColor = palette.foreground
        view.nativeBoldForegroundColor = palette.boldForeground
        view.nativeBackgroundColor = palette.background
        view.getTerminal().feed(text: Sheet.sample)

        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }
}
