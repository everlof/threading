import AppKit
import XCTest
@testable import Threading

/// Draws the session's own action menu and writes it out, light and dark.
///
/// This is the longest menu in the app and the one behind the header's `⋯`, and what it needed
/// was not assertable: whether a column of thirty rows *reads*. The icon column, the groups the
/// separators open, and the width the panel settles at are all relationships between rows, and
/// every one of them passed its unit test while the menu was a wall of words.
///
/// The storybook covers the two shapes the anatomy turns on — a menu whose rows are all actions
/// (no mark column at all, titles hard against the icons) and one that also marks a choice
/// (which is a different leading column). A regression in `ThemedMenuMetrics.CheckColumn` shows
/// up here as every title in the picture stepping sideways.
@MainActor
final class SessionMenuRenderTests: HostedStoreTestCase {

    // MARK: - Configuration

    private enum Render {
        static var directory: URL {
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"],
               !override.isEmpty {
                return URL(fileURLWithPath: override)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }

        static let appearances: [(name: String, appearance: NSAppearance.Name)] = [
            ("light", .aqua),
            ("dark", .darkAqua)
        ]

        /// Tall enough for the whole menu at its natural height, so the storybook shows what the
        /// panel does rather than what `ThemedMenuLayout`'s cap does to it.
        static let canvas = NSSize(width: 460, height: 820)
    }

    // MARK: - Stories

    func testRendersTheSessionActionMenuStorybook() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let store = ProjectStore.shared
        let project = try XCTUnwrap(store.addProject(
            folderURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("session-menu-render-\(UUID().uuidString)", isDirectory: true)
        ))
        defer { _ = store.removeProject(id: project.id) }
        let session = try XCTUnwrap(store.addSession(to: project.id, kind: .claude))

        let sidebar = ProjectSidebarViewController()
        sidebar.actionSessionID = session.id
        let entries = sidebar.sessionActionEntries(for: session)

        var written = 0
        for (appearanceName, appearanceID) in Render.appearances {
            let data = try XCTUnwrap(
                menuImage(entries: entries, appearance: appearanceID),
                "Failed to render the session menu in \(appearanceName)"
            )
            try data.write(
                to: directory.appendingPathComponent("session-menu-\(appearanceName).png")
            )
            written += 1
        }

        XCTAssertEqual(written, Render.appearances.count)
        print("Rendered the session action menu to \(directory.path)")
    }

    // MARK: - Anatomy

    /// A menu of plain actions reserves no mark column, and one that marks a row reserves
    /// exactly one — the icons and the check share it. Only a menu with a row carrying *both*
    /// pays for two columns.
    ///
    /// The numbers are deliberately relative. What matters is not that a title sits at 32pt but
    /// that adding icons to an action menu moves its titles by the icon slot and nothing else:
    /// the regression this guards is the empty gutter coming back, which shows up as the plain
    /// menu's titles no longer starting at the panel's own content inset.
    func testAnActionMenuReservesNoColumnForMarksItNeverDraws() {
        let plain: [ThemedMenuEntry] = [
            .item(ThemedMenuItem(title: "Archive", onChoose: {})),
            .item(ThemedMenuItem(title: "Delete", onChoose: {}))
        ]
        XCTAssertEqual(ThemedMenuMetrics.checkColumn(plain), .none)
        XCTAssertEqual(
            ThemedMenuMetrics.titleInset(
                checkColumn: .none,
                hasImageColumn: false,
                hasPreviewColumn: false
            ),
            ThemedMenuMetrics.contentInset,
            "an icon-less, mark-less menu is still holding a gutter open for nothing"
        )
    }

    func testIconsAndMarksShareOneColumnUnlessARowCarriesBoth() {
        let icons: [ThemedMenuEntry] = [
            .item(ThemedMenuItem(
                title: "Archive",
                image: ThemedMenuIcon.symbol("archivebox"),
                onChoose: {}
            ))
        ]
        let marked: [ThemedMenuEntry] = [
            .item(ThemedMenuItem(title: "Compact Tree", isSelected: true, onChoose: {}))
        ]
        let both: [ThemedMenuEntry] = [
            .item(ThemedMenuItem(
                title: "Xcode",
                image: ThemedMenuIcon.symbol("hammer"),
                isSelected: true,
                onChoose: {}
            ))
        ]

        XCTAssertEqual(ThemedMenuMetrics.checkColumn(icons), .none)
        XCTAssertEqual(ThemedMenuMetrics.checkColumn(marked), .shared)
        XCTAssertEqual(ThemedMenuMetrics.checkColumn(both), .separate)

        // A mixed menu — the project row's, which marks its grouping toggles beside iconned
        // actions — puts the marks in the icons' column rather than opening a second one.
        let mixed = icons + marked
        XCTAssertEqual(ThemedMenuMetrics.checkColumn(mixed), .shared)
        XCTAssertEqual(
            ThemedMenuMetrics.titleInset(
                checkColumn: .shared,
                hasImageColumn: true,
                hasPreviewColumn: false
            ),
            ThemedMenuMetrics.titleInset(
                checkColumn: .none,
                hasImageColumn: true,
                hasPreviewColumn: false
            ),
            "marking a row in an iconned menu moved every title in it"
        )
        XCTAssertEqual(
            ThemedMenuMetrics.titleInset(
                checkColumn: .separate,
                hasImageColumn: true,
                hasPreviewColumn: false
            ),
            ThemedMenuMetrics.titleInset(
                checkColumn: .none,
                hasImageColumn: true,
                hasPreviewColumn: false
            ) + ThemedMenuMetrics.leadingSlot,
            "a row carrying both a mark and an icon must buy the second column"
        )
    }

    /// The presenter's `selectedEntryIndex` marks a row exactly as `isSelected` does, so the
    /// width has to see it. Measured without it, the panel reserved no mark column and the
    /// check was drawn over the first title.
    func testAPresenterMarkedRowIsMeasuredAsMarked() {
        let entries: [ThemedMenuEntry] = [
            .item(ThemedMenuItem(title: "One", onChoose: {})),
            .item(ThemedMenuItem(title: "Two", onChoose: {}))
        ]
        XCTAssertEqual(ThemedMenuMetrics.checkColumn(entries, selectedEntryIndex: 1), .shared)
        XCTAssertGreaterThan(
            ThemedMenuMetrics.width(for: entries, minimum: 0, selectedEntryIndex: 1),
            ThemedMenuMetrics.width(for: entries, minimum: 0),
            "the panel measured itself without room for the mark it was told to draw"
        )
    }

    // MARK: - Helpers

    /// The menu presented as its own panel, in a window that is built and never shown —
    /// `ThemedMenuPresenter` draws inside the window's content view rather than in a second
    /// window, so `cacheDisplay` sees the whole panel without anything reaching the screen.
    private func menuImage(
        entries: [ThemedMenuEntry],
        appearance name: NSAppearance.Name
    ) -> Data? {
        let appearance = NSAppearance(named: name)

        var data: Data?
        let render: @MainActor () -> Void = {
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: Render.canvas),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.appearance = appearance
            let root = ThemedSurfaceView()
            root.translatesAutoresizingMaskIntoConstraints = true
            root.frame = NSRect(origin: .zero, size: Render.canvas)
            root.applySurface(fill: Design.Surface.background, radius: .fixed(0))
            let source = NSView(frame: NSRect(
                x: 12,
                y: Render.canvas.height - 32,
                width: 1,
                height: 1
            ))
            root.addSubview(source)
            window.contentView = root

            let token = ThemedMenuPresenter.present(
                ThemedMenuPresentation(entries: entries, minimumWidth: SidebarDefaults.menuWidth),
                from: source,
                selectedEntryIndex: nil,
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
