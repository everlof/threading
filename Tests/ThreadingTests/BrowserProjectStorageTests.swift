import WebKit
import XCTest
@testable import Threading

@MainActor
final class BrowserProjectStorageTests: HostedStoreTestCase {
    func testWebKitReservedProjectIdentifierUsesIsolatedMemory() {
        let projectID = ProjectID(UUID(uuid: (
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        )))
        let browser = BrowserViewController(projectID: projectID)
        let sibling = BrowserViewController(projectID: projectID)
        XCTAssertFalse(browser.websiteDataStore.isPersistent)
        XCTAssertTrue(browser.websiteDataStore === sibling.websiteDataStore)
        XCTAssertFalse(browser.websiteDataStore === WKWebsiteDataStore.default())
    }

    func testMovingSessionsRebindsTheirBrowsersAcrossHosts() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("browser-project-move-\(UUID().uuidString)")
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore.shared
        let project = try XCTUnwrap(store.addProject(folderURL: source))
        let first = try XCTUnwrap(store.addSession(to: project.id, kind: .claude))
        let second = try XCTUnwrap(store.addSession(to: project.id, kind: .claude))
        let pane = DisplayPaneController()
        let browser = pane.activateBrowser(for: first.id)
        let privateBrowser = try XCTUnwrap(pane.addBrowserTab(for: first.id, contextKind: .private))
        let drawer = DrawerHostViewController(directoryProvider: { _ in nil })
        let drawerBrowser = try XCTUnwrap(drawer.addBrowserTab(for: second.id))
        let detached = DetachedBrowserHostViewController(sessionID: second.id)
        let detachedBrowser = try XCTUnwrap(detached.addBrowserTab())
        let audit = try XCTUnwrap(pane.addAuditTab(for: first.id))
        let oldStore = browser.websiteDataStore
        let privateStore = privateBrowser.websiteDataStore
        let move = store.moveSessionsToCheckout(
            [first.id, second.id], checkoutPath: destination.path,
            repositoryIdentity: root.appendingPathComponent("repository.git").path,
            worktreeIdentity: root.appendingPathComponent("destination.git").path,
            branch: "destination"
        )
        guard case .moved(let target) = move else { return XCTFail("Sessions did not move") }
        for movedBrowser in [browser, drawerBrowser, detachedBrowser, audit.browser] {
            XCTAssertFalse(movedBrowser.websiteDataStore === oldStore)
            XCTAssertTrue(movedBrowser.websiteDataStore === browser.websiteDataStore)
            XCTAssertNil(movedBrowser.currentURL)
            if #available(macOS 14.0, *) {
                XCTAssertEqual(movedBrowser.websiteDataStore.identifier, target.projectID.rawValue)
            }
        }
        XCTAssertTrue(privateBrowser.websiteDataStore === privateStore)
    }

    func testEveryBrowserHostAndRestorationUsesTheOwningProject() throws {
        let project = try XCTUnwrap(ProjectStore.shared.addProject(
            folderURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("browser-project-\(UUID().uuidString)")
        ))
        let first = try XCTUnwrap(ProjectStore.shared.addSession(to: project.id, kind: .claude))
        let second = try XCTUnwrap(ProjectStore.shared.addSession(to: project.id, kind: .claude))
        let otherProject = try XCTUnwrap(ProjectStore.shared.addProject(
            folderURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("browser-other-project-\(UUID().uuidString)")
        ))
        let otherSession = try XCTUnwrap(ProjectStore.shared.addSession(to: otherProject.id, kind: .claude))
        let pane = DisplayPaneController()
        let firstBrowser = pane.activateBrowser(for: first.id)
        let secondBrowser = pane.activateBrowser(for: second.id)
        let drawer = DrawerHostViewController(directoryProvider: { _ in nil })
        let drawerBrowser = try XCTUnwrap(drawer.addBrowserTab(for: second.id))
        let detached = DetachedBrowserHostViewController(sessionID: second.id)
        let detachedBrowser = try XCTUnwrap(detached.addBrowserTab())
        let restoredBrowser = detached.makeRestoredBrowser(url: "https://example.invalid")
        let audit = try XCTUnwrap(pane.addAuditTab(for: first.id))

        for browser in [secondBrowser, drawerBrowser, detachedBrowser, restoredBrowser, audit.browser] {
            XCTAssertTrue(browser.websiteDataStore === firstBrowser.websiteDataStore)
        }
        if #available(macOS 14.0, *) {
            XCTAssertEqual(firstBrowser.websiteDataStore.identifier, project.id.rawValue)
            XCTAssertTrue(firstBrowser.websiteDataStore.isPersistent)
        }
        let otherBrowser = pane.activateBrowser(for: otherSession.id)
        XCTAssertFalse(otherBrowser.websiteDataStore === firstBrowser.websiteDataStore)
        if #available(macOS 14.0, *) {
            XCTAssertEqual(otherBrowser.websiteDataStore.identifier, otherProject.id.rawValue)
        }

        firstBrowser.restoredURL = "https://example.invalid"
        firstBrowser.onPageChange?()
        let restoredPane = DisplayPaneController()
        let restoredPanelBrowser = try XCTUnwrap(restoredPane.tabs(for: first.id).first?.browser)
        XCTAssertTrue(restoredPanelBrowser.websiteDataStore === firstBrowser.websiteDataStore)
        XCTAssertEqual(restoredPanelBrowser.restoredURL, "https://example.invalid")
    }

    func testProjectsPrivateTabsAndUnknownOwnersHaveSeparateStores() {
        let firstProject = ProjectID()
        let first = BrowserViewController(projectID: firstProject)
        let sameProject = BrowserViewController(projectID: firstProject)
        let otherProject = BrowserViewController(projectID: ProjectID())
        let privateTab = BrowserViewController(contextKind: .private, projectID: firstProject)
        let otherPrivateTab = BrowserViewController(contextKind: .private, projectID: firstProject)
        let unknownOwner = BrowserViewController()
        let otherUnknownOwner = BrowserViewController()

        XCTAssertTrue(first.websiteDataStore === sameProject.websiteDataStore)
        for browser in [otherProject, privateTab, otherPrivateTab, unknownOwner, otherUnknownOwner] {
            XCTAssertFalse(browser.websiteDataStore === first.websiteDataStore)
            XCTAssertFalse(browser.websiteDataStore === WKWebsiteDataStore.default())
        }
        XCTAssertFalse(privateTab.websiteDataStore === otherPrivateTab.websiteDataStore)
        XCTAssertFalse(unknownOwner.websiteDataStore === otherUnknownOwner.websiteDataStore)
        XCTAssertFalse(unknownOwner.websiteDataStore.isPersistent)
        XCTAssertFalse(privateTab.websiteDataStore.isPersistent)
    }
}
