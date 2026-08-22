import AppKit
import XCTest
@testable import Threading

/// Draws the shipping consent surface in both of its states. The switch is a privacy boundary,
/// so the rendered evidence has to make "off" and "on" visibly distinct without relying on an
/// agent description of the page.
final class AdvancedSettingsRenderTests: XCTestCase {

    private enum Render {
        static let width = SettingsUIDefaults.pageWidth
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
    func testRendersLocalDiagnosticsOptInStates() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let previous = AppSettings.shared.localDiagnosticsEnabled
        defer { AppSettings.shared.localDiagnosticsEnabled = previous }
        let previousTheme = AppThemeLibrary.current
        AppThemeLibrary.apply(.system)
        defer { AppThemeLibrary.apply(previousTheme) }

        var written = 0
        for enabled in [false, true] {
            AppSettings.shared.localDiagnosticsEnabled = enabled
            for (appearanceName, appearance) in [
                ("light", NSAppearance.Name.aqua),
                ("dark", NSAppearance.Name.darkAqua),
            ] {
                let resolvedAppearance = try XCTUnwrap(NSAppearance(named: appearance))
                var rendered: Data?
                var renderedToggleState: NSControl.StateValue?
                var hasThemeBoundaryViolations = false
                resolvedAppearance.performAsCurrentDrawingAppearance {
                    let controller = AdvancedPreferencesViewController()
                    let host = self.laidOut(
                        controller.view,
                        width: Render.width,
                        height: Render.height
                    )
                    host.appearance = resolvedAppearance
                    controller.view.appearance = resolvedAppearance
                    AppThemeRefresh.repaint(host)
                    host.layoutSubtreeIfNeeded()
                    renderedToggleState = self.descendants(of: controller.view)
                        .compactMap { $0 as? ThemedToggle }
                        .first {
                            $0.accessibilityLabel()
                                == L10n.string("Allow paired-iPhone checkups")
                        }?.state
                    hasThemeBoundaryViolations = !ThemeBoundaryAudit.violations(
                        in: controller.view
                    ).isEmpty
                    rendered = self.png(of: host)
                }

                XCTAssertEqual(renderedToggleState, enabled ? .on : .off)
                XCTAssertFalse(hasThemeBoundaryViolations)

                let stateName = enabled ? "on" : "off"
                let url = directory.appendingPathComponent(
                    "advanced-local-diagnostics-\(stateName)-\(appearanceName).png"
                )
                try XCTUnwrap(rendered).write(to: url)
                written += 1
            }
        }

        print("Rendered \(written) Advanced local-diagnostics pages to \(directory.path)")
        XCTAssertEqual(written, 4)
    }

    @MainActor
    @discardableResult
    private func laidOut(_ view: NSView, width: CGFloat, height: CGFloat) -> NSView {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        ])
        host.layoutSubtreeIfNeeded()
        return host
    }

    @MainActor
    private func png(of host: NSView) -> Data? {
        guard host.bounds.height > 1,
              let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    @MainActor
    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
