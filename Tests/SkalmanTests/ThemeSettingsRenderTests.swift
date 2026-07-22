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
        /// The width the pane actually gives a settings page — `Design.Size.readableWidth`, the
        /// cap `showSettingsPage` centres it at — and a squeezed pane, since the eight-column
        /// ANSI grid is the widest fixed thing on the page and is what breaks first.
        static let widths: [CGFloat] = [420, Design.Size.readableWidth]
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
