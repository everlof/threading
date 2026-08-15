import AppKit
import XCTest
@testable import Threading

/// The app-theme picker, filed.
///
/// Twenty-nine names in one column said nothing about why any two of them were near each other:
/// a design movement, a colour scheme, a reproduction of a shipped desktop and a novelty sat in
/// the same undifferentiated run, and the only structure a row could carry was a suffix in its
/// own title. These hold the sections the list gained — that every theme is still reachable in
/// one press, that the selection still lands on the row it names, and that the tier stopped
/// being written into twenty-nine titles — and draw the open list so the grouping can be *seen*,
/// which is the half no assertion states.
@MainActor
final class ThemePickerSectionTests: XCTestCase {

    // MARK: - Configuration

    private enum Render {
        static var directory: URL {
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] {
                return URL(fileURLWithPath: override)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }

        static let appearances: [(name: String, appearance: NSAppearance.Name)] = [
            ("light", .aqua),
            ("dark", .darkAqua)
        ]

        /// Tall enough for the whole catalogue: the presenter caps a panel at three quarters of
        /// its window, and a clipped picture would be a picture of the scroller.
        static let windowSize = NSSize(width: 420, height: 1400)
    }

    // MARK: - Structure

    /// The Appearance page's picker is the catalogue's own filing, heads and all.
    func testTheAppearancePickerCarriesTheCataloguesSections() throws {
        let controller = ThemePreferencesViewController()
        _ = controller.view

        let entries = controller.appThemeMenuEntriesForTesting
        XCTAssertFalse(entries.isEmpty, "the picker was never populated")

        var expected: [String] = []
        for section in AppThemeLibrary.sections {
            if let title = section.title { expected.append("head:\(title)") }
            expected += section.themes.map { "item:\($0.name)" }
        }
        let actual = entries.map { entry -> String in
            switch entry {
            case .header(let title): return "head:\(title)"
            case .item(let item): return "item:\(item.title)"
            case .separator: return "rule"
            }
        }
        XCTAssertEqual(actual, expected, "the picker and the catalogue file themes differently")

        // The tier used to be a suffix on every row (`Aurora — Custom`). A head says it once,
        // and no row repeats it.
        XCTAssertFalse(
            actual.contains { $0.hasPrefix("item:") && $0.contains("—") },
            "a row still carries its tier in its own title"
        )
    }

    /// Grouping costs no navigation: a head is not a submenu, so every theme is still one press
    /// from the closed control. It also must not become choosable — a "Palettes" that could be
    /// applied is a theme that does not exist.
    func testEveryThemeStaysOnePressAwayAndNoHeadIsChoosable() throws {
        let controller = ThemePreferencesViewController()
        _ = controller.view

        let entries = controller.appThemeMenuEntriesForTesting
        let reachable = entries.compactMap { entry -> String? in
            guard case .item(let item) = entry else { return nil }
            XCTAssertNil(item.submenu, "\(item.title) was demoted into a submenu")
            return item.representedValue as? String
        }
        XCTAssertEqual(
            Set(reachable),
            Set(AppThemeLibrary.all.map(\.id.rawValue)),
            "the sectioned picker lost or invented a theme"
        )
        XCTAssertEqual(reachable.count, Set(reachable).count, "a theme is offered twice")
    }

    /// The ring names the user's stored choice, and it has to keep naming it now that heads sit
    /// between the rows — an entry index read off the flat catalogue would land one row lower
    /// for every head above it, which is a picker quietly showing the wrong theme.
    func testTheSelectionSurvivesTheHeadsAboveIt() throws {
        let previous = AppThemeLibrary.current
        defer { AppThemeLibrary.apply(previous) }

        // Christmas is deliberately the last row of the last stock section: every head in the
        // list is above it, so an index taken from the flat catalogue cannot accidentally be
        // right.
        let christmas = try XCTUnwrap(AppThemeStyles.all.first { $0.id == AppThemeID("christmas") })
        AppThemeLibrary.apply(christmas)

        let controller = ThemePreferencesViewController()
        _ = controller.view

        XCTAssertEqual(controller.selectedAppThemeIDForTesting, christmas.id)
    }

    // MARK: - Stories

    /// The open list, light and dark. What the picture is for: the heads' weight against the
    /// rows they name, and whether the groups read as groups rather than as gaps.
    func testRendersTheOpenThemePicker() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var entries: [ThemedMenuEntry] = []
        for section in AppThemeLibrary.sections {
            if let title = section.title { entries.append(.header(title)) }
            entries += section.themes.map {
                .item(ThemedMenuItem(title: $0.name, representedValue: $0.id.rawValue))
            }
        }
        let selected = try XCTUnwrap(
            entries.firstIndex { $0.item?.representedValue as? String == "dracula" }
        )

        var written = 0
        for (appearanceName, appearanceID) in Render.appearances {
            let data = try XCTUnwrap(
                menuImage(entries: entries, selectedEntryIndex: selected, appearance: appearanceID),
                "Failed to render the theme picker in \(appearanceName)"
            )
            try data.write(
                to: directory.appendingPathComponent("theme-picker-\(appearanceName).png")
            )
            written += 1
        }

        XCTAssertEqual(written, Render.appearances.count)
        print("Rendered the theme picker to \(directory.path)")
    }

    // MARK: - Helpers

    /// The dropdown presented in a window that is built and never shown — `ThemedMenuPresenter`
    /// draws inside the window's content view rather than in a second window, so `cacheDisplay`
    /// sees the whole panel without anything reaching the screen.
    private func menuImage(
        entries: [ThemedMenuEntry],
        selectedEntryIndex: Int,
        appearance name: NSAppearance.Name
    ) -> Data? {
        let appearance = NSAppearance(named: name)

        var data: Data?
        let render: @MainActor () -> Void = {
            let bounds = NSRect(origin: .zero, size: Render.windowSize)
            let window = NSWindow(
                contentRect: bounds,
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.appearance = appearance
            let root = ThemedSurfaceView()
            root.translatesAutoresizingMaskIntoConstraints = true
            root.frame = bounds
            root.applySurface(fill: Design.Surface.background, radius: .fixed(0))
            let source = NSView(frame: NSRect(
                x: Design.Spacing.large,
                y: bounds.maxY - Design.Spacing.large,
                width: 1,
                height: 1
            ))
            root.addSubview(source)
            window.contentView = root

            let token = ThemedMenuPresenter.present(
                ThemedMenuPresentation(entries: entries, minimumWidth: 240),
                from: source,
                selectedEntryIndex: selectedEntryIndex,
                onChoose: { _, _ in },
                onDismiss: {}
            )
            defer { ThemedMenuPresenter.dismiss(token) }

            AppThemeRefresh.repaint(root)
            root.layoutSubtreeIfNeeded()

            guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
            root.cacheDisplay(in: root.bounds, to: rep)
            data = rep.representation(using: .png, properties: [:])
        }

        if let appearance {
            appearance.performAsCurrentDrawingAppearance {
                MainActor.assumeIsolated(render)
            }
        }
        return data
    }
}
