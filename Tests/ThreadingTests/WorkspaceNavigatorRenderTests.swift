import AppKit
import ThreadingExtensionKit
import XCTest

@testable import Threading

/// Captures an extension navigator in the shipping main-window split shell. The header cannot be
/// reviewed honestly as an isolated band: its title truncation, sidebar width, separator, themed
/// ground, collection viewport and menu overlay are relationships owned by the real window.
@MainActor
final class WorkspaceNavigatorRenderTests: HostedStoreTestCase {
    private enum Render {
        static var directory: URL {
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"],
               !override.isEmpty {
                return URL(fileURLWithPath: override, isDirectory: true)
            }
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }

        static let windowSize = NSSize(width: 1_120, height: 720)
    }

    private struct AppearanceFixture {
        let name: String
        let theme: AppTheme
        let appearance: NSAppearance.Name
    }

    func testRendersFocusedNavigatorAndNativeRouteInTheMainWindow() throws {
        try FileManager.default.createDirectory(
            at: Render.directory,
            withIntermediateDirectories: true
        )
        let previousTheme = AppThemePalette.current
        let previousSelection = AppSettings.shared.workspaceNavigatorSelection
        defer {
            AppSettings.shared.workspaceNavigatorSelection = previousSelection
            AppThemePalette.set(previousTheme)
        }

        let router = WorkspaceNavigatorEvidenceRouter()
        let controller = makeMainWindowController(
            initialFramePlan: .useDefaultFrame,
            workspaceNavigatorRouting: router
        )
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(Render.windowSize)
        let content = try XCTUnwrap(window.contentView)
        // The composer deliberately chooses a fresh greeting for every arrival. This catalogue
        // owns the navigator, not that unrelated welcome copy, so pin the one multiline hero in
        // the shipping shell before hashing the pixels. A second evidence run must prove the
        // same navigator rather than fail because the composer rolled another valid sentence.
        let greeting = try XCTUnwrap(
            descendants(of: content).compactMap { $0 as? MorphingMultilineTitleLabel }.first
        )
        greeting.setStringValue("What are we building today?", animated: false)
        let selection = WorkspaceNavigatorSelection.extensionNavigator(
            extensionIdentifier: router.inventory.extensionIdentifier,
            navigatorID: router.inventory.navigator.id
        )
        let fixtures = [
            AppearanceFixture(name: "system-light", theme: .system, appearance: .aqua),
            AppearanceFixture(name: "system-dark", theme: .system, appearance: .darkAqua),
            AppearanceFixture(
                name: "cyberpunk",
                theme: AppThemeStyles.cyberpunk,
                appearance: .darkAqua
            ),
            AppearanceFixture(
                name: "swiss",
                theme: AppThemeStyles.swissMinimalist,
                appearance: .aqua
            )
        ]

        for fixture in fixtures {
            AppThemePalette.set(fixture.theme)
            content.appearance = try XCTUnwrap(NSAppearance(named: fixture.appearance))
            controller.selectWorkspaceNavigator(selection)
            AppThemeRefresh.repaint(content)
            content.layoutSubtreeIfNeeded()
            content.displayIfNeeded()

            try write(content, named: "workspace-navigator-\(fixture.name)-focused.png")

            let menuButton = try XCTUnwrap(
                descendants(of: content).compactMap { $0 as? ThemedIconButton }.first {
                    $0.accessibilityIdentifier() == "workspace.navigator.menu"
                }
            )
            XCTAssertTrue(menuButton.accessibilityPerformPress())
            XCTAssertTrue(ThemedMenuPresenter.isMenuOpen(in: window))
            content.layoutSubtreeIfNeeded()
            content.displayIfNeeded()
            try write(content, named: "workspace-navigator-\(fixture.name)-menu.png")

            // This is the same callback the menu row reaches. Besides preparing the next
            // fixture, it proves the outgoing source cannot leave its self-retained overlay.
            controller.selectWorkspaceNavigator(.native)
            XCTAssertFalse(ThemedMenuPresenter.isMenuOpen(in: window))
        }

        print("Rendered the focused workspace navigator to \(Render.directory.path)")
    }

    private func write(_ view: NSView, named filename: String) throws {
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: Render.directory.appendingPathComponent(filename))
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}

@MainActor
private final class WorkspaceNavigatorEvidenceRouter: ExtensionWorkspaceNavigatorRouting {
    let inventory: ExtensionWorkspaceNavigatorInventoryItem

    init() {
        let sections = [
            ExtensionWorkspaceNavigatorSection(
                id: "priority",
                header: .text("Priority", role: .heading)
            ),
            ExtensionWorkspaceNavigatorSection(
                id: "recent",
                header: .text("Recent", role: .heading)
            )
        ]
        let rows: [(String, String, String, ExtensionStatusRole)] = [
            ("permission", "Review navigator permissions", "Waiting for you", .warning),
            ("release", "Prepare the 1.4 release", "Working · release/1.4", .positive),
            ("sidebar", "Design a focused project sidebar", "Idle · navigator-pipeline", .neutral),
            ("tests", "Keep extension lifecycle tests deterministic", "Done · main", .positive),
            ("docs", "Document host-owned recovery", "Idle · docs", .neutral),
            ("gitlab", "Join GitLab merge-request state", "Waiting · provider", .warning),
            ("search", "Move search into the host transform", "Planned · pipeline", .neutral),
            ("intents", "Define safe row intents", "Planned · pipeline", .neutral)
        ]
        let items = rows.enumerated().map { index, row in
            ExtensionWorkspaceNavigatorItem(
                id: row.0,
                sectionID: index < 2 ? "priority" : "recent",
                content: .stack(
                    axis: .vertical,
                    spacing: .tight,
                    children: [
                        .text(row.1, role: .compactBody),
                        .status(row.2, role: row.3)
                    ]
                ),
                activation: .destination(.session(
                    id: String(format: "00000000-0000-0000-0000-%012d", index + 1),
                    projectID: nil
                )),
                isSelected: index == 2
            )
        }
        let navigator = ExtensionWorkspaceNavigator(
            id: "focused-workspace",
            title: "Priority work across every checkout",
            root: .collection(.init(
                id: "sessions",
                layout: .list,
                sections: sections,
                items: items
            )),
            options: [
                .init(
                    id: "group",
                    title: "Group by project",
                    control: .toggle(defaultValue: true)
                )
            ]
        )
        inventory = .init(
            extensionIdentifier: "com.example.focused-navigator",
            extensionName: "Focused Navigator",
            processGeneration: "evidence-generation",
            navigator: navigator,
            optionValues: ["group": .bool(true)],
            optionPersistenceOutcome: .loaded
        )
    }

    var extensionWorkspaceNavigatorInventory: [ExtensionWorkspaceNavigatorInventoryItem] {
        [inventory]
    }

    func registeredWorkspaceNavigator(
        extensionIdentifier: String,
        navigatorID: String
    ) -> ExtensionWorkspaceNavigatorInventoryItem? {
        guard extensionIdentifier == inventory.extensionIdentifier,
              navigatorID == inventory.navigator.id else {
            return nil
        }
        return inventory
    }

    func extensionImageResourceURL(
        extensionIdentifier: String,
        relativePath: String
    ) -> URL? {
        nil
    }

    func invokeWorkspaceNavigatorAction(
        extensionIdentifier: String,
        navigatorID: String,
        actionID: String,
        value: ExtensionJSONValue?,
        context: ExtensionCommandContext,
        completion: @escaping (
            Result<ExtensionWorkspaceNavigatorActionResponse, Error>
        ) -> Void
    ) -> Bool {
        false
    }
}
