import AppKit
import XCTest
@testable import Threading

/// Draws the GitHub settings page and writes it out as an image, light and dark, System plus
/// two deliberately different app themes — the review a new page owes under the design
/// system's rules. The assertions catch what an image cannot: a page that collapsed, or a
/// control that fell out of the tree.
final class GitHubSettingsRenderTests: XCTestCase {

    private enum Render {
        /// The pane's real measure plus a squeezed pane, same rationale as the other pages.
        static let widths: [CGFloat] = [420, SettingsUIDefaults.pageWidth]
        static let height: CGFloat = 900

        static var directory: URL {
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"],
               !override.isEmpty {
                return URL(fileURLWithPath: override)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }
    }

    @MainActor
    func testPageBuildsWithoutCollapsingAndKeepsItsControls() {
        let controller = GitHubPreferencesViewController()
        let host = laidOut(controller.view, width: Render.widths[1], height: Render.height)

        XCTAssertEqual(controller.view.frame.width, host.bounds.width)
        XCTAssertGreaterThan(controller.view.frame.height, 200, "the page collapsed")

        XCTAssertNotNil(
            view(withIdentifier: "settings.github.client-id", under: host),
            "the client ID field fell out of the tree"
        )
        let connect = view(withIdentifier: "settings.github.connect", under: host)
        XCTAssertNotNil(connect, "the connect control fell out of the tree")
        XCTAssertFalse(
            ((connect as? ThemedButton)?.title ?? "").isEmpty,
            "the connect control has no title in its resting state"
        )
    }

    @MainActor
    func testTheNarrowPaneWrapsRatherThanOverflows() {
        let controller = GitHubPreferencesViewController()
        let host = laidOut(controller.view, width: Render.widths[0], height: Render.height)

        XCTAssertLessThanOrEqual(
            controller.view.frame.width,
            host.bounds.width,
            "the page is wider than the pane it sits in"
        )
    }

    @MainActor
    func testRendersLightDarkAndUnderTwoThemes() throws {
        try FileManager.default.createDirectory(
            at: Render.directory,
            withIntermediateDirectories: true
        )
        defer { AppThemePalette.set(.system) }

        var written = 0
        for (suffix, style) in [
            ("system", nil),
            ("cyberpunk", AppThemeStyles.cyberpunk),
            ("swiss", AppThemeStyles.swissMinimalist)
        ] as [(String, AppTheme?)] {
            AppThemePalette.set(style ?? .system)
            for name: NSAppearance.Name in [.aqua, .darkAqua] {
                guard let data = pageImage(appearance: name) else {
                    XCTFail("no image for \(suffix) \(name.rawValue)")
                    continue
                }
                let url = Render.directory.appendingPathComponent(
                    "github-settings-\(suffix)-\(name == .aqua ? "light" : "dark").png"
                )
                try data.write(to: url)
                written += 1
            }
        }
        XCTAssertEqual(written, 6)
    }

    // MARK: - Helpers

    @MainActor
    private func pageImage(appearance name: NSAppearance.Name) -> Data? {
        let appearance = NSAppearance(named: name)
        var data: Data?
        let render = {
            let controller = GitHubPreferencesViewController()
            let host = self.laidOut(
                controller.view,
                width: Render.widths[1],
                height: Render.height
            )
            host.appearance = appearance
            controller.view.appearance = appearance
            AppThemeRefresh.repaint(host)
            host.layoutSubtreeIfNeeded()
            data = self.png(of: host)
        }
        appearance?.performAsCurrentDrawingAppearance(render)
        return data
    }

    @MainActor
    private func laidOut(_ view: NSView, width: CGFloat, height: CGFloat) -> NSView {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([
            // The pane states its width. A detached fixture is a flexible layout root, so a
            // frame alone lets Auto Layout widen the "pane" to whatever the page asked for,
            // and `testTheNarrowPaneWrapsRatherThanOverflows` would then be comparing a page
            // against a pane the page had chosen. See CLAUDE.md, "a detached fixture with a
            // frame constrains nothing".
            host.widthAnchor.constraint(equalToConstant: width),
            host.heightAnchor.constraint(equalToConstant: height),
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.bounds.width, width, accuracy: 0.5, "the fixture widened its capture")
        XCTAssertEqual(
            host.bounds.height,
            height,
            accuracy: 0.5,
            "the fixture changed its capture height"
        )
        return host
    }

    @MainActor
    private func view(withIdentifier identifier: String, under root: NSView) -> NSView? {
        if root.accessibilityIdentifier() == identifier { return root }
        for child in root.subviews {
            if let found = view(withIdentifier: identifier, under: child) { return found }
        }
        return nil
    }

    @MainActor
    @discardableResult
    private func png(of host: NSView) -> Data? {
        guard host.bounds.height > 1,
              let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}
