import AppKit
import XCTest
@testable import Threading

/// The window controller's use of `NavigationHistory`: presenting a page records a visit,
/// Back and Forward re-present without re-pushing, and the toolbar pair reflects where the
/// window can still go.
///
/// Driven through the settings pages, deliberately — their presentation is synchronous and
/// touches no project store, so the replay-guard logic (`pendingHistoryTarget`) is exercised
/// without pumping the run loop. The window is built, never shown.
///
/// Plus what ⌘, restores on the way out, which is the same question asked of the pane rather
/// than of the history: a detour must end where it started.
@MainActor
final class MainWindowNavigationTests: XCTestCase {

    private var controller: MainWindowController?

    override func tearDown() {
        controller = nil
        super.tearDown()
    }

    private func makeController() -> MainWindowController {
        let controller = MainWindowController()
        self.controller = controller
        return controller
    }

    func testVisitingTwoPagesEnablesBackAndRetracesThem() {
        let controller = makeController()

        controller.showSettingsPage(id: SettingsPages.generalID)
        XCTAssertFalse(controller.canGoBack, "The first page has nothing behind it")

        controller.showSettingsPage(id: SettingsPages.themesID)
        XCTAssertTrue(controller.canGoBack)
        XCTAssertFalse(controller.canGoForward)

        controller.goBack()
        XCTAssertFalse(controller.canGoBack)
        XCTAssertTrue(controller.canGoForward)

        controller.goForward()
        XCTAssertTrue(controller.canGoBack)
        XCTAssertFalse(controller.canGoForward)
    }

    func testReplayDoesNotPushAFreshVisit() {
        let controller = makeController()
        controller.showSettingsPage(id: SettingsPages.generalID)
        controller.showSettingsPage(id: SettingsPages.themesID)
        controller.showSettingsPage(id: SettingsPages.keyboardID)

        controller.goBack()
        controller.goBack()
        XCTAssertFalse(controller.canGoBack, "Two steps back from three pages is the beginning")

        controller.goForward()
        controller.goForward()
        XCTAssertFalse(
            controller.canGoForward,
            "If replays pushed visits, forward steps would have manufactured history"
        )
    }

    func testRevisitingTheCurrentPageIsNotAStep() {
        let controller = makeController()
        controller.showSettingsPage(id: SettingsPages.generalID)
        controller.showSettingsPage(id: SettingsPages.generalID)

        XCTAssertFalse(controller.canGoBack)
    }

    func testTheToolbarPairReflectsTheHistory() throws {
        let controller = makeController()
        let back = try XCTUnwrap(controller.navBackToolbarButton)
        let forward = try XCTUnwrap(controller.navForwardToolbarButton)

        XCTAssertFalse(back.isEnabled)
        XCTAssertFalse(forward.isEnabled)

        controller.showSettingsPage(id: SettingsPages.generalID)
        controller.showSettingsPage(id: SettingsPages.themesID)
        XCTAssertTrue(back.isEnabled)
        XCTAssertFalse(forward.isEnabled)

        controller.goBack()
        XCTAssertFalse(back.isEnabled)
        XCTAssertTrue(forward.isEnabled)
    }

    func testAccountUsagePillIsLazyUntilAConsumerNeedsIt() throws {
        let controller = makeController()

        XCTAssertFalse(
            controller.accountUsageItemIsMaterialized,
            "An empty/composer launch must not start the hidden usage pill's timer"
        )

        let item = controller.accountUsageItemView

        XCTAssertTrue(controller.accountUsageItemIsMaterialized)
        XCTAssertTrue(item.superview === controller.paneHeaderStackView)
        let arranged = try XCTUnwrap(controller.paneHeaderStackView?.arrangedSubviews)
        let index = try XCTUnwrap(arranged.firstIndex(of: item))
        XCTAssertTrue(
            arranged[index + 1] === controller.openInSplitControl,
            "The late pill keeps its place between the flexible spacer and Open In control"
        )
    }

    func testPageTitleIsLazyUntilARealPageNeedsIt() throws {
        let controller = makeController()

        XCTAssertFalse(controller.pageTitleViewIsMaterialized)

        controller.showSettingsPage(id: SettingsPages.generalID)
        XCTAssertFalse(
            controller.pageTitleViewIsMaterialized,
            "Settings has its own mode header and must not build an empty page title"
        )

        controller.toggleSettings()
        let project = try XCTUnwrap(ProjectStore.shared.addProject(
            folderURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("threading-lazy-page-tab-\(UUID().uuidString)")
        ))
        defer { ProjectStore.shared.removeProject(id: project.id) }

        controller.projectSidebar(ProjectSidebarViewController(), didSelectProject: project.id)

        let title = try XCTUnwrap(controller.materializedPageTitleView)
        XCTAssertTrue(controller.pageTitleViewIsMaterialized)
        XCTAssertTrue(title.superview === controller.paneHeaderStackView)
        XCTAssertTrue(controller.paneHeaderStackView?.arrangedSubviews.first === title)
        XCTAssertFalse(title.isHidden, "The first real page must reveal its late-created title")
    }

    func testInitiallyHiddenPaneHeaderGlyphsStayDeferred() throws {
        let controller = makeController()

        XCTAssertFalse(try XCTUnwrap(controller.openInToolbarButton).hasMaterializedGlyph)
        XCTAssertFalse(try XCTUnwrap(controller.openInMenuToolbarButton).hasMaterializedGlyph)
        XCTAssertFalse(try XCTUnwrap(controller.surfaceToggleToolbarButton).hasMaterializedGlyph)

        // The `⋯` is deliberately absent from this list: it belongs to the page's own title
        // view, which does not exist until there is a page to name — see
        // `testPageTitleIsLazyUntilARealPageNeedsIt`.
        XCTAssertTrue(
            try XCTUnwrap(controller.statusCardToolbarButton).hasMaterializedGlyph,
            "Standing pane controls remain complete even without a session"
        )
    }

    // MARK: - The settings detour

    /// ⌘, is a *detour*: it opens Settings over whatever the pane was showing and puts that back
    /// when it closes. A project's composer is one of those things.
    ///
    /// It used to remember only a session, so leaving Settings from a composer landed on "No
    /// Session Selected" — taking the half-written prompt in it off the screen, which is how the
    /// bug was reported.
    func testLeavingSettingsPutsAProjectsComposerBack() throws {
        let controller = makeController()
        let store = ProjectStore.shared

        // A folder of its own, for the reason `AgentPermissionModeTests` states: `addProject`
        // returns the existing project for a folder it already knows, and the teardown here
        // deletes whatever it was handed.
        let project = try XCTUnwrap(store.addProject(
            folderURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("threading-settings-detour-\(UUID().uuidString)")
        ))
        defer { store.removeProject(id: project.id) }

        // The sidebar's own delegate call, which is what selecting a project row makes. A
        // stand-in list is enough: the callback only touches the sidebar to refresh the row of
        // a session leaving the pane, and no session is on screen here.
        controller.projectSidebar(ProjectSidebarViewController(), didSelectProject: project.id)
        XCTAssertEqual(controller.currentProjectID, project.id, "The composer opens on selection")

        controller.toggleSettings()
        XCTAssertNil(controller.currentProjectID, "Settings carries no project context")

        controller.toggleSettings()
        XCTAssertEqual(
            controller.currentProjectID,
            project.id,
            "Closing Settings must return to the composer it opened over"
        )
        XCTAssertNil(controller.currentSessionID)
    }

    func testTheNavigationCommandsAreListedOnXcodesChords() throws {
        let backCommand = try XCTUnwrap(AppCommands.command(id: AppCommands.ID.navigateBack))
        let forwardCommand = try XCTUnwrap(
            AppCommands.command(id: AppCommands.ID.navigateForward)
        )

        XCTAssertEqual(
            backCommand.defaultShortcut,
            KeyboardShortcut(key: "\u{F702}", modifiers: [.command, .control])
        )
        XCTAssertEqual(
            forwardCommand.defaultShortcut,
            KeyboardShortcut(key: "\u{F703}", modifiers: [.command, .control])
        )
    }
}
