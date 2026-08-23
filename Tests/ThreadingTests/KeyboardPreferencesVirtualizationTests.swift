import AppKit
import XCTest
@testable import Threading

/// Extension commands and project scripts have product ceilings at discovery, not at the
/// Keyboard page's view layer. The complete inventory remains searchable value state, while
/// recorder controls are owned by the visible table rows only.
@MainActor
final class KeyboardPreferencesVirtualizationTests: XCTestCase {
    private enum Render {
        static let widths: [CGFloat] = [420, SettingsUIDefaults.pageWidth]
        static let height: CGFloat = 1_100

        static var directory: URL {
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] {
                return URL(fileURLWithPath: override)
            }
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }
    }

    func testExpandedProviderCommandsMaterializeOnlyTheViewport() throws {
        let fixture = makeFixture(commandCount: 2_000)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }

        let controller = KeyboardPreferencesViewController(
            registry: fixture.registry,
            store: fixture.store
        )
        let host = laidOut(controller.view, width: 440, height: 700)
        let window = NSWindow(
            contentRect: host.bounds,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }

        controller.setGroupExpandedForTesting(.extensions, expanded: true)
        controller.scrollCommandToVisibleForTesting(group: .extensions, index: 1_500)
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(controller.virtualRowCountForTesting, 2_004)
        XCTAssertGreaterThan(controller.materializedRowCountForTesting, 0)
        XCTAssertLessThan(
            controller.materializedRowCountForTesting,
            controller.virtualRowCountForTesting / 2,
            "opening the Extensions fold retained every shortcut recorder"
        )

        let scroll = try XCTUnwrap(firstScrollView(in: controller.view))
        let originBeforeRefresh = scroll.contentView.bounds.origin
        NotificationCenter.default.post(CommandRegistryDidChange())
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(scroll.contentView.bounds.origin.x, originBeforeRefresh.x, accuracy: 0.5)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, originBeforeRefresh.y, accuracy: 0.5)
        XCTAssertEqual(ThemeBoundaryAudit.violations(in: controller.view), [])
    }

    /// The real controller at both supported review widths. The fixture opens the provider-sized
    /// group so the virtual card joins and shortcut-recorder alignment are visible, not merely
    /// inferred from its collapsed heading.
    func testRendersKeyboardSettingsToImages() throws {
        try FileManager.default.createDirectory(
            at: Render.directory,
            withIntermediateDirectories: true
        )
        let previousTheme = AppThemeLibrary.current
        AppThemeLibrary.apply(.system)
        defer { AppThemeLibrary.apply(previousTheme) }

        var written: [String] = []
        for width in Render.widths {
            for (appearanceName, appearance) in [
                ("light", NSAppearance.Name.aqua),
                ("dark", NSAppearance.Name.darkAqua)
            ] {
                let filename = "keyboard-settings-\(Int(width))-\(appearanceName).png"
                let resolvedAppearance = try XCTUnwrap(NSAppearance(named: appearance))
                var data: Data?
                resolvedAppearance.performAsCurrentDrawingAppearance {
                    let fixture = makeFixture(commandCount: 8, givesShortcuts: true)
                    defer {
                        fixture.defaults.removePersistentDomain(forName: fixture.suiteName)
                    }
                    let controller = KeyboardPreferencesViewController(
                        registry: fixture.registry,
                        store: fixture.store
                    )
                    controller.setGroupExpandedForTesting(.extensions, expanded: true)

                    let host = laidOut(controller.view, width: width, height: Render.height)
                    host.appearance = resolvedAppearance
                    controller.view.appearance = resolvedAppearance
                    AppThemeRefresh.repaint(host)
                    host.layoutSubtreeIfNeeded()
                    data = png(of: host)
                    XCTAssertEqual(ThemeBoundaryAudit.violations(in: host), [])
                }
                try XCTUnwrap(data, "Failed to render \(filename)").write(
                    to: Render.directory.appendingPathComponent(filename)
                )
                written.append(filename)
            }
        }

        print("Rendered \(written.count) Keyboard settings pages to \(Render.directory.path)")
        XCTAssertEqual(written.count, Render.widths.count * 2)
    }

    private func makeFixture(
        commandCount: Int,
        givesShortcuts: Bool = false
    ) -> (
        registry: CommandRegistry,
        store: ShortcutOverrideStore,
        defaults: UserDefaults,
        suiteName: String
    ) {
        let commands = (0..<commandCount).map { index in
            AppCommand(
                id: "extension.fixture.command.\(index)",
                group: .extensions,
                title: String(format: "Checkout Command %04d", index),
                detail: index.isMultiple(of: 2)
                    ? "Runs against the selected checkout without changing its command identity."
                    : nil,
                defaultShortcut: givesShortcuts
                    ? KeyboardShortcut(
                        key: "\(index % 10)",
                        modifiers: [.command, .option]
                    )
                    : nil,
                isEditable: true,
                origin: .extensionCommand(
                    identifier: "codes.threading.fixture",
                    name: "Fixture Tools",
                    localID: "command.\(index)"
                )
            )
        }
        let registry = CommandRegistry(builtInCommands: commands)
        let suiteName = "KeyboardPreferencesVirtualization-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = ShortcutOverrideStore(defaults: defaults, registry: registry)
        return (registry, store, defaults, suiteName)
    }

    private func laidOut(_ view: NSView, width: CGFloat, height: CGFloat) -> NSView {
        let host = ThemedSurfaceView()
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.applySurface(fill: Design.Surface.ground, radius: .fixed(0))
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor)
        ])
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func firstScrollView(in root: NSView) -> NSScrollView? {
        if let scroll = root as? NSScrollView { return scroll }
        return root.subviews.lazy.compactMap(firstScrollView).first
    }

    private func png(of view: NSView) -> Data? {
        guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return nil
        }
        view.cacheDisplay(in: view.bounds, to: representation)
        return representation.representation(using: .png, properties: [:])
    }
}
