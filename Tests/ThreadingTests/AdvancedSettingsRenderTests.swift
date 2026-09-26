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
    func testRendersSentryDiagnosticsOptInStates() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let previous = AppSettings.shared.sentryDiagnosticsEnabled
        defer { AppSettings.shared.sentryDiagnosticsEnabled = previous }
        let previousTheme = AppThemeLibrary.current
        AppThemeLibrary.apply(.system)
        defer { AppThemeLibrary.apply(previousTheme) }

        var written = 0
        for enabled in [false, true] {
            AppSettings.shared.sentryDiagnosticsEnabled = enabled
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
                                == L10n.string("Share crash & performance reports")
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
                    "advanced-sentry-diagnostics-\(stateName)-\(appearanceName).png"
                )
                try XCTUnwrap(rendered).write(to: url)
                written += 1
            }
        }

        print("Rendered \(written) Advanced Sentry-diagnostics pages to \(directory.path)")
        XCTAssertEqual(written, 4)
    }

#if DEBUG || THREADING_INTERNAL
    /// The internal Release is the app a developer actually leaves in `/Applications`, so the
    /// service selector must be visible there without returning a production build to Debug.
    @MainActor
    func testRendersDeveloperHostedServiceSelection() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let previousEnvironment = AppSettings.shared.remoteHostedServiceEnvironment
        AppSettings.shared.remoteHostedServiceEnvironment = .development
        defer { AppSettings.shared.remoteHostedServiceEnvironment = previousEnvironment }
        let previousTheme = AppThemeLibrary.current
        AppThemeLibrary.apply(.system)
        defer { AppThemeLibrary.apply(previousTheme) }

        var written = 0
        for (appearanceName, appearance) in [
            ("light", NSAppearance.Name.aqua),
            ("dark", NSAppearance.Name.darkAqua),
        ] {
            let resolvedAppearance = try XCTUnwrap(NSAppearance(named: appearance))
            var rendered: Data?
            var selectedEnvironment: RemoteHostedServiceEnvironment?
            var rowIsOnThePicture = false
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

                let row = SettingsRowAnchor.find(
                    title: AdvancedStrings.hostedServiceTitle,
                    in: controller.view
                )
                row?.scrollToVisible(row?.bounds ?? .zero)
                host.layoutSubtreeIfNeeded()
                rowIsOnThePicture = row.map {
                    host.bounds.contains($0.convert($0.bounds, to: host))
                } ?? false
                selectedEnvironment = self.descendants(of: controller.view)
                    .compactMap { $0 as? ThemedPopUp }
                    .first {
                        $0.accessibilityIdentifier()
                            == AdvancedPreferencesViewController.Identifier.hostedEnvironment
                    }?.selectedItem?.representedValue as? RemoteHostedServiceEnvironment
                hasThemeBoundaryViolations = !ThemeBoundaryAudit.violations(
                    in: controller.view
                ).isEmpty
                rendered = self.png(of: host)
            }

            XCTAssertEqual(selectedEnvironment, .development)
            XCTAssertTrue(rowIsOnThePicture)
            XCTAssertFalse(hasThemeBoundaryViolations)

            let url = directory.appendingPathComponent(
                "advanced-developer-settings-development-\(appearanceName).png"
            )
            try XCTUnwrap(rendered).write(to: url)
            written += 1
        }

        print("Rendered \(written) Advanced developer-settings pages to \(directory.path)")
        XCTAssertEqual(written, 2)
    }
#endif

    /// The two command-line-tool rows, in the two states that read differently.
    ///
    /// Not installed is the first thing anyone sees. Installed-but-not-on-`PATH` is the state
    /// worth a picture: the row has to carry a path, a sentence about `PATH` and a line to paste
    /// into a profile, and whether that stays legible beside a button is not something an
    /// assertion about its text can answer.
    @MainActor
    func testRendersTheCommandLineToolRows() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AdvancedSettingsRender-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle(in: root, shipping: PTYHostDefaults.helperName)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let shims = root.appendingPathComponent("bin", isDirectory: true)

        let previousTheme = AppThemeLibrary.current
        AppThemeLibrary.apply(.system)
        defer { AppThemeLibrary.apply(previousTheme) }

        var written = 0
        for state in ["absent", "installed-off-path"] {
            if state == "installed-off-path" {
                ThreadingCommandLineTools.refresh(bundleURL: bundle, directory: shims)
                try CommandLineToolInstaller.install(
                    tool: PTYHostDefaults.helperName,
                    home: home,
                    shimDirectory: shims
                )
            }
            for (appearanceName, appearance) in [
                ("light", NSAppearance.Name.aqua),
                ("dark", NSAppearance.Name.darkAqua),
            ] {
                let resolvedAppearance = try XCTUnwrap(NSAppearance(named: appearance))
                var rendered: Data?
                var foundBothRows = false
                var rowsAreOnThePicture = false
                var hasThemeBoundaryViolations = false
                resolvedAppearance.performAsCurrentDrawingAppearance {
                    let controller = AdvancedPreferencesViewController(
                        commandLineTools: CommandLineToolsSurface(
                            home: home,
                            shimDirectory: shims,
                            bundleURL: bundle,
                            // A `PATH` this directory is deliberately not on, so the row has to
                            // say the line to add.
                            loginShellPATH: "/usr/bin:/bin",
                            asksLoginShell: false
                        )
                    )
                    let host = self.laidOut(
                        controller.view,
                        width: Render.width,
                        height: Render.height
                    )
                    host.appearance = resolvedAppearance
                    controller.view.appearance = resolvedAppearance
                    AppThemeRefresh.repaint(host)
                    host.layoutSubtreeIfNeeded()
                    let rows = [
                        SettingsRowAnchor.find(
                            title: L10n.string("Command line tool"),
                            in: controller.view
                        ),
                        SettingsRowAnchor.find(
                            title: L10n.string("Tools in Threading's terminals"),
                            in: controller.view
                        )
                    ].compactMap { $0 }
                    foundBothRows = rows.count == 2
                    // These are the last rows of the longest page in Settings, so a picture of
                    // the page's first 900 points is a picture of somebody else's rows. The
                    // first render of this test wrote four files that were byte-identical to the
                    // local-diagnostics ones, and every assertion in it passed.
                    rows.last?.scrollToVisible(rows.last?.bounds ?? .zero)
                    host.layoutSubtreeIfNeeded()
                    rowsAreOnThePicture = rows.allSatisfy {
                        host.bounds.contains($0.convert($0.bounds, to: host))
                    }
                    hasThemeBoundaryViolations = !ThemeBoundaryAudit.violations(
                        in: controller.view
                    ).isEmpty
                    rendered = self.png(of: host)
                }

                XCTAssertTrue(foundBothRows, "the page did not build both command-line-tool rows")
                XCTAssertTrue(rowsAreOnThePicture, "the rows are not inside the rendered frame")
                XCTAssertFalse(hasThemeBoundaryViolations)

                let url = directory.appendingPathComponent(
                    "advanced-command-line-tool-\(state)-\(appearanceName).png"
                )
                try XCTUnwrap(rendered).write(to: url)
                written += 1
            }
        }

        print("Rendered \(written) Advanced command-line-tool pages to \(directory.path)")
        XCTAssertEqual(written, 4)
    }

    private func makeBundle(in root: URL, shipping tool: String) throws -> URL {
        let bundle = root.appendingPathComponent("Threading.app", isDirectory: true)
        let helpers = bundle.appendingPathComponent(
            ThreadingCommandLineToolDefaults.helpersDirectoryPath,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        let executable = helpers.appendingPathComponent(tool)
        try "#!/bin/sh\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        return bundle
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
