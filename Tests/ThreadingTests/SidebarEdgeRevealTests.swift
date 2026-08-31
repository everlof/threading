import AppKit
import XCTest
@testable import Threading

@MainActor
final class SidebarEdgeRevealTests: HostedStoreTestCase {

    func testStandardPolicyFiltersFlyBysAndAllowsAnExitCrossing() {
        XCTAssertEqual(SidebarEdgeRevealCoordinator.triggerWidth, Design.Spacing.small)
        XCTAssertEqual(SidebarEdgeRevealCoordinator.Policy.standard.openDelay, 0.25)
        XCTAssertEqual(SidebarEdgeRevealCoordinator.Policy.standard.closeGrace, 0.35)
    }

    func testSidebarAndItsPresentedInteractionsHoldATemporaryReveal() {
        let coordinator = SidebarEdgeRevealCoordinator(
            policy: .init(openDelay: 0, closeGrace: 0)
        )
        var reveals = 0
        var dismisses = 0
        coordinator.onReveal = { reveals += 1 }
        coordinator.onDismiss = { dismisses += 1 }

        coordinator.edgeHoverChanged(true)
        XCTAssertEqual(reveals, 1)
        XCTAssertTrue(coordinator.isTemporarilyRevealed)

        coordinator.sidebarHoverChanged(true)
        coordinator.edgeHoverChanged(false)
        XCTAssertEqual(dismisses, 0, "entering the revealed sidebar owns the pointer")

        coordinator.sidebarPresentationDidChange(isPresented: true)
        coordinator.sidebarHoverChanged(false)
        XCTAssertEqual(dismisses, 0, "a sidebar menu or popover holds the reveal")

        coordinator.sidebarPresentationDidChange(isPresented: false)
        XCTAssertEqual(dismisses, 1)
        XCTAssertFalse(coordinator.isTemporarilyRevealed)
    }

    func testMainWindowRevealsTheExistingSidebarAndHidesAfterExit() throws {
        let controller = makeMainWindowController(initialFramePlan: .useDefaultFrame)
        let sidebarItem = try XCTUnwrap(controller.splitViewController.splitViewItems.first)
        let nativeSidebar = controller.sidebarViewController.view
        let originalSuperview = try XCTUnwrap(nativeSidebar.superview)

        controller.sidebarEdgeRevealPolicyForTesting = .init(openDelay: 0, closeGrace: 0)
        controller.splitViewController.setCollapsed(true, on: sidebarItem, animated: false)

        let edge = controller.sidebarEdgeTrackingViewForTesting
        XCTAssertFalse(edge.isHidden)
        XCTAssertTrue(edge.passesHitTestingThrough)
        XCTAssertTrue(edge.tracksOnlyInKeyWindow)
        XCTAssertNil(edge.hitTest(NSPoint(x: 1, y: 1)), "the sensor intercepted content clicks")

        controller.simulateSidebarEdgeHoverForTesting(true)
        XCTAssertFalse(sidebarItem.isCollapsed)
        XCTAssertTrue(controller.sidebarIsTemporarilyRevealedForTesting)
        XCTAssertTrue(nativeSidebar.superview === originalSuperview, "the sidebar was rebuilt")

        controller.simulateSidebarHoverForTesting(true)
        controller.simulateSidebarEdgeHoverForTesting(false)
        XCTAssertFalse(sidebarItem.isCollapsed)

        controller.simulateSidebarHoverForTesting(false)
        XCTAssertTrue(sidebarItem.isCollapsed)
        XCTAssertFalse(controller.sidebarIsTemporarilyRevealedForTesting)
        XCTAssertFalse(edge.isHidden)
    }

    func testExplicitToggleTakesOwnershipFromAHoverReveal() throws {
        let controller = makeMainWindowController(initialFramePlan: .useDefaultFrame)
        let sidebarItem = try XCTUnwrap(controller.splitViewController.splitViewItems.first)
        controller.sidebarEdgeRevealPolicyForTesting = .init(openDelay: 0, closeGrace: 0)
        controller.splitViewController.setCollapsed(true, on: sidebarItem, animated: false)

        controller.simulateSidebarEdgeHoverForTesting(true)
        XCTAssertTrue(controller.sidebarIsTemporarilyRevealedForTesting)

        controller.toggleSidebar()
        XCTAssertTrue(sidebarItem.isCollapsed)
        XCTAssertFalse(controller.sidebarIsTemporarilyRevealedForTesting)
    }

    func testARevealedSidebarClosesWhenItsWindowStopsBeingKey() throws {
        let controller = makeMainWindowController(initialFramePlan: .useDefaultFrame)
        let sidebarItem = try XCTUnwrap(controller.splitViewController.splitViewItems.first)
        controller.sidebarEdgeRevealPolicyForTesting = .init(openDelay: 0, closeGrace: 0)
        controller.splitViewController.setCollapsed(true, on: sidebarItem, animated: false)
        controller.simulateSidebarEdgeHoverForTesting(true)
        XCTAssertTrue(controller.sidebarIsTemporarilyRevealedForTesting)

        NotificationCenter.default.post(
            name: NSWindow.didResignKeyNotification,
            object: controller.window
        )

        let dismissed = expectation(description: "resigned window dismisses hover reveal")
        DispatchQueue.main.async {
            XCTAssertTrue(sidebarItem.isCollapsed)
            XCTAssertFalse(controller.sidebarIsTemporarilyRevealedForTesting)
            dismissed.fulfill()
        }
        wait(for: [dismissed], timeout: 1)
    }
}
