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
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-menu-render-\(UUID().uuidString)", isDirectory: true)
        let main = fixture.appendingPathComponent("main", isDirectory: true)
        let sibling = fixture.appendingPathComponent("sibling", isDirectory: true)
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        try git(["init", "--initial-branch=main"], in: main)
        try git(["config", "user.email", "tests@example.com"], in: main)
        try git(["config", "user.name", "Threading Tests"], in: main)
        try "menu".write(
            to: main.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try git(["add", "."], in: main)
        try git(["commit", "-m", "menu fixture"], in: main)
        try git(["worktree", "add", "-b", "menu-sibling", sibling.path], in: main)

        let project = try XCTUnwrap(store.addProject(folderURL: main))
        let siblingProject = try XCTUnwrap(store.addProject(folderURL: sibling))
        defer {
            _ = store.removeProject(id: siblingProject.id)
            _ = store.removeProject(id: project.id)
            try? FileManager.default.removeItem(at: fixture)
        }
        let session = try XCTUnwrap(store.addSession(to: project.id, kind: .claude))

        let sidebar = ProjectSidebarViewController(decorateAccountUsage: { _, _, _, _ in })
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
        try renderAccountDestinations(to: directory)
        print("Rendered the session action menu to \(directory.path)")
    }

    /// Exercise the shipping row builders, including a selected recovery policy and a scoped
    /// window. Fixture logins never touch provider discovery or start a provider process.
    private func renderAccountDestinations(to directory: URL) throws {
        let originalTheme = AppThemePalette.current
        defer { AppThemePalette.set(originalTheme) }
        let now = Date()
        let accounts = ["Personal", "Work"].enumerated().map { index, name in
            AgentAccount(
                provider: .codex,
                handle: .named("codex-menu-evidence-\(index)"),
                configPath: directory.appendingPathComponent(name).path,
                displayName: name,
                displayNameOverride: name
            )
        }
        var readings: [AccountID: AccountUsage] = [:]
        for (index, account) in accounts.enumerated() {
            var usage = AccountUsage(
                windows: [
                    .init(id: "5h", label: "Session", fraction: index == 0 ? 0.24 : 0.88,
                          resetsAt: now.addingTimeInterval(3_600), windowDuration: 18_000),
                    .init(id: "7d", label: "Weekly", fraction: index == 0 ? 0.42 : 0.96,
                          resetsAt: now.addingTimeInterval(86_400), windowDuration: 604_800)
                ],
                planLabel: "Pro", observedAt: now, source: .localCache
            )
            usage.modelWindows = [
                .init(id: "spark", label: "Weekly Spark", fraction: 0.97,
                      resetsAt: now.addingTimeInterval(7_200), windowDuration: 604_800,
                      scopeName: "Spark")
            ]
            readings[account.id] = usage
        }
        let sidebar = ProjectSidebarViewController(decorateAccountUsage: { item, account, model, agent in
            guard let usage = readings[account.id] else { return }
            item.image = AccountBadge.mark(for: account, surface: .chooser)
            AccountUsageMenu.apply(usage, to: &item, metering: model, at: now)
        })
        var session = AgentSession(kind: .codex, title: "Compare accounts")
        session.model = "gpt-5.3-codex-spark"
        var move: [ThemedMenuEntry] {
            sidebar.moveToAccountItems(for: session, accounts: accounts)
        }
        var continuation: [ThemedMenuEntry] {
            sidebar.continuationAccountItems(accounts: accounts)
        }
        var recovery: [ThemedMenuEntry] {
            accounts.map { account in
                sidebar.limitRecoveryItem(
                    .resumeVia(account.id),
                    title: account.displayName,
                    resolved: .resumeVia(accounts[0].id),
                    account: account,
                    model: session.model
                )
            }
        }
        for entries in [move, continuation, recovery] {
            let items = entries.compactMap { entry -> ThemedMenuItem? in
                guard case .item(let item) = entry else { return nil }
                return item
            }
            XCTAssertEqual(items.map { $0.metrics.map(\.value) }, [["24%", "42%"], ["88%", "96%"]])
            XCTAssertTrue(items.allSatisfy { $0.subtitle?.contains("97%") == true })
            XCTAssertTrue(items.allSatisfy { $0.onChoose != nil })
        }
        guard case .item(let selected) = recovery[0] else { return XCTFail("Missing account") }
        XCTAssertTrue(selected.isSelected)
        XCTAssertEqual(selected.help, LimitRecoveryPolicy.resumeVia(accounts[0].id).explanation)

        for theme in [AppTheme.system, AppThemeStyles.cyberpunk, AppThemeStyles.swissMinimalist] {
            AppThemePalette.set(theme)
            for (name, entries) in [
                ("move", move), ("continue", continuation),
                ("recovery", [.header(L10n.string("Continue as…"))] + recovery)
            ] {
                let image = try XCTUnwrap(menuImage(
                    entries: entries, appearance: .darkAqua,
                    canvas: NSSize(width: 800, height: 280)
                ))
                try image.write(to: directory.appendingPathComponent(
                    "session-menu-\(name)-\(theme.id.rawValue).png"
                ))
            }
        }
    }

    private func git(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
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
        appearance name: NSAppearance.Name,
        canvas: NSSize = Render.canvas
    ) -> Data? {
        let appearance = NSAppearance(named: name)

        var data: Data?
        let render: @MainActor () -> Void = {
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: canvas),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.appearance = appearance
            let root = ThemedSurfaceView()
            root.translatesAutoresizingMaskIntoConstraints = true
            root.frame = NSRect(origin: .zero, size: canvas)
            root.applySurface(fill: Design.Surface.background, radius: .fixed(0))
            let source = NSView(frame: NSRect(
                x: 12,
                y: canvas.height - 32,
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
