import AppKit
import XCTest
@testable import Skalman

/// Draws the Themes settings page and writes it out as an image, light and dark.
///
/// The same reason the conversation and git-review renders exist: a claim about whether twenty
/// colour chips read as a grid or as a smear cannot be checked by asserting on constants. The
/// page's previous layout passed every assertion anyone would have written for it and still put
/// sixteen swatches four points apart in two rows that did not line up.
///
/// The assertions catch what an image cannot: a card that measures nothing, a palette that
/// overflows the pane it is drawn in.
final class ThemeSettingsRenderTests: XCTestCase {

    private enum Render {
        /// The width the pane actually gives a settings page — `SettingsUIDefaults.pageWidth`,
        /// the cap `showSettingsPage` centres it at (the readable measure plus the halo
        /// gutters) — and a squeezed pane, since the eight-column ANSI grid is the widest
        /// fixed thing on the page and is what breaks first.
        static let widths: [CGFloat] = [420, SettingsUIDefaults.pageWidth]
        static let height: CGFloat = 1000

        static var directory: URL {
            if let override = ProcessInfo.processInfo.environment["SKALMAN_RENDER_OUT"] {
                return URL(fileURLWithPath: override)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("SkalmanRenders", isDirectory: true)
        }
    }

    // MARK: - Layout

    @MainActor
    func testPaletteFitsTheNarrowSettingsPane() {
        let editor = ThemeColorEditor()
        editor.show(.ocean, isEditable: true)

        let host = laidOut(editor, width: Render.widths[0])

        XCTAssertGreaterThan(editor.frame.height, 100, "the palette card collapsed")
        XCTAssertLessThanOrEqual(
            editor.frame.width, host.bounds.width,
            "the ANSI grid is wider than the pane it sits in"
        )
    }

    @MainActor
    func testPreviewDrawsEveryLineOfItsSample() {
        let preview = ThemePreviewView()
        preview.show(.pro)

        _ = laidOut(preview, width: Render.widths[1])

        XCTAssertGreaterThan(preview.frame.height, 100, "the preview collapsed")
    }

    @MainActor
    func testPageBuildsWithoutCollapsing() {
        let controller = ThemePreferencesViewController()
        let host = laidOut(controller.view, width: Render.widths[1], height: Render.height)

        XCTAssertEqual(controller.view.frame.width, host.bounds.width)
        XCTAssertGreaterThan(controller.view.frame.height, 200)
    }

    // MARK: - The Halo Contract

    /// A glowing theme's halo must fade on all four sides of a card, and only a render can
    /// say so: the shadow is always set correctly on the card's own layer — it is an
    /// *ancestor* that eats it. The page's scroll view clips at its own bounds, and before
    /// the column kept `Design.Size.glowGutter` clear of them the halo was cut off flat at
    /// the cards' left and right edges while the vertical spill survived in the section
    /// spacing — a fade in one axis only, which no assertion about layer properties could
    /// see.
    @MainActor
    func testCardHaloSurvivesTheScrollViewOnAllFourSides() throws {
        AppThemePalette.set(AppThemeStyles.cyberpunk)
        defer { AppThemePalette.set(.system) }

        let card = SettingsCard(rows: [SettingsUI.row(title: "Row")])
        let page = SettingsUI.page([SettingsUI.section(nil, card)])
        let host = laidOut(page, width: SettingsUIDefaults.pageWidth, height: 300)

        host.wantsLayer = true
        host.layer?.backgroundColor = AppThemePalette.current.resolved(.ground).cgColor
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)

        let frame = card.convert(card.bounds, to: host)
        let reach: CGFloat = 3
        let samples: [(side: String, point: NSPoint)] = [
            ("left", NSPoint(x: frame.minX - reach, y: frame.midY)),
            ("right", NSPoint(x: frame.maxX + reach, y: frame.midY)),
            ("top", NSPoint(x: frame.midX, y: frame.maxY + reach)),
            ("bottom", NSPoint(x: frame.midX, y: frame.minY - reach))
        ]

        for sample in samples {
            let excess = accentExcess(at: sample.point, in: rep, host: host)
            XCTAssertGreaterThan(
                excess, 0.01,
                "no halo \(sample.side) of the card — its glow is being clipped on that side"
            )
        }
    }

    /// How much of the theme's green accent a pixel carries beyond its own red and blue —
    /// zero on the ground and on anything neutral, positive inside the accent's halo. The
    /// card's border is blue-violet, so bleed from the edge can only *lower* it.
    @MainActor
    private func accentExcess(at point: NSPoint, in rep: NSBitmapImageRep, host: NSView) -> CGFloat {
        let scale = CGFloat(rep.pixelsWide) / host.bounds.width
        let x = Int(point.x * scale)
        // The rep's rows run top-down while the host's coordinates run bottom-up.
        let y = Int((host.bounds.height - point.y) * scale)

        guard let colour = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return 0 }
        return colour.greenComponent - max(colour.redComponent, colour.blueComponent)
    }

    // MARK: - Images

    @MainActor
    func testRendersThemeSettingsToImages() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var written: [String] = []

        for width in Render.widths {
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let url = directory.appendingPathComponent("themes-\(Int(width))-\(name).png")
                let data = try XCTUnwrap(
                    pageImage(width: width, appearance: appearance),
                    "Failed to render the themes page at \(width)pt in \(name)"
                )
                try data.write(to: url)
                written.append(url.lastPathComponent)
            }
        }

        print("Rendered \(written.count) theme pages to \(directory.path)")
        XCTAssertEqual(written.count, Render.widths.count * 2)
    }

    // MARK: - Helpers

    @MainActor
    private func pageImage(width: CGFloat, appearance name: NSAppearance.Name) -> Data? {
        let appearance = NSAppearance(named: name)

        var data: Data?
        let render = {
            let controller = ThemePreferencesViewController()
            let host = self.laidOut(controller.view, width: width, height: Render.height)
            host.appearance = appearance
            controller.view.appearance = appearance
            host.layoutSubtreeIfNeeded()
            data = self.png(of: host)
        }

        appearance?.performAsCurrentDrawingAppearance(render)
        return data
    }

    @MainActor
    @discardableResult
    private func laidOut(_ view: NSView, width: CGFloat, height: CGFloat? = nil) -> NSView {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height ?? Render.height))
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)

        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor)
        ])

        if height != nil {
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor).isActive = true
        }

        host.layoutSubtreeIfNeeded()

        // A view whose height comes from its content needs the host resized around it, or the
        // image is cropped to a frame nothing asked for.
        if height == nil {
            host.setFrameSize(NSSize(width: width, height: view.fittingSize.height))
            host.layoutSubtreeIfNeeded()
        }

        return host
    }

    @MainActor
    private func png(of host: NSView) -> Data? {
        guard host.bounds.height > 1,
              let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }

        // The settings page sits on the window's material and paints no ground of its own, so
        // one is painted here — otherwise every label draws onto transparency.
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}
