import AppKit
import XCTest
@testable import Threading

@MainActor
final class NotificationTestPaneTests: HostedStoreTestCase {
  func testNotifyUserOpensOnePrefilledPaneAndRetainsFailedRequest() throws {
    let sessionID = SessionID()
    let pane = DisplayPaneController()
    pane.showSession(sessionID)
    pane.showCurrentTheme()
    var reveals = 0
    let coordinator = AgentToolCoordinator(
      displayPaneController: pane,
      visibleSessionID: { sessionID },
      setPaneVisible: { if $0 { reveals += 1 } },
      windowProvider: { nil }
    )

    let first = NotifyUserArguments(
      title: "Watch test", message: nil, recipient: "owner", delivery: "ios"
    )
    let result = coordinator.notifyUser(first, for: sessionID)
    XCTAssertTrue(result.isError)
    let controller = try XCTUnwrap(pane.tabs(for: sessionID).first?.notificationTest)
    XCTAssertEqual(controller.draft.title, "Watch test")
    XCTAssertEqual(controller.draft.delivery, "ios")
    XCTAssertEqual(controller.lastResult?.text, result.text)
    XCTAssertEqual(reveals, 1)
    XCTAssertFalse(pane.isShowingCurrentTheme)

    let second = NotifyUserArguments(
      title: "Retry", message: "Ready", recipient: "requester", delivery: "invalid"
    )
    let secondResult = coordinator.notifyUser(second, for: sessionID)
    XCTAssertTrue(secondResult.isError)
    XCTAssertEqual(pane.tabs(for: sessionID).count, 1)
    XCTAssertTrue(pane.tabs(for: sessionID).first?.notificationTest === controller)
    XCTAssertEqual(controller.draft.message, "Ready")
    XCTAssertEqual(controller.lastResult?.text, secondResult.text)
    XCTAssertEqual(reveals, 2)
  }

  func testBackgroundChatKeepsItsDraftWithoutOpeningVisiblePane() {
    let background = SessionID()
    let pane = DisplayPaneController()
    var reveals = 0
    let coordinator = AgentToolCoordinator(
      displayPaneController: pane,
      visibleSessionID: { SessionID() },
      setPaneVisible: { if $0 { reveals += 1 } },
      windowProvider: { nil }
    )

    _ = coordinator.notifyUser(
      NotifyUserArguments(title: "Background", message: nil), for: background
    )

    XCTAssertEqual(reveals, 0)
    XCTAssertEqual(pane.tabs(for: background).first?.notificationTest?.draft.title, "Background")
  }

  func testEditedDraftResendsExactFieldsAndShowsResult() throws {
    let sessionID = SessionID()
    let pane = DisplayPaneController()
    let controller = try XCTUnwrap(pane.activateNotificationTest(for: sessionID))
    controller.prefill(
      NotifyUserArguments(
        title: "Original", message: "First", recipient: "owner", delivery: "both",
        targetRef: "old-reference"
      ),
      result: .failure("No opted-in phone has a live connection or usable push registration.")
    )
    _ = controller.view

    func control<T: NSView>(_ identifier: String, as type: T.Type) throws -> T {
      func find(_ view: NSView) -> T? {
        if view.accessibilityIdentifier() == identifier { return view as? T }
        return view.subviews.lazy.compactMap(find).first
      }
      return try XCTUnwrap(find(controller.view), identifier)
    }
    try control("notification-test.title", as: ThemedTextField.self).stringValue = "Edited"
    try control("notification-test.message", as: ThemedTextView.self).string = "Again"
    try control("notification-test.recipient", as: ThemedTextField.self).stringValue = "owner"
    try control("notification-test.delivery", as: ThemedPopUp.self).selectItem(at: 2)
    try control("notification-test.target-ref", as: ThemedTextField.self).stringValue = "new-reference"

    var submitted: NotifyUserArguments?
    pane.onSendNotificationTest = { arguments, id in
      XCTAssertEqual(id, sessionID)
      submitted = arguments
      return .success("Notification queued for the iPhone.")
    }
    let result = controller.sendCurrentDraft()

    XCTAssertFalse(result.isError)
    XCTAssertEqual(submitted?.title, "Edited")
    XCTAssertEqual(submitted?.message, "Again")
    XCTAssertEqual(submitted?.recipient, "owner")
    XCTAssertEqual(submitted?.delivery, "ios")
    XCTAssertEqual(submitted?.targetRef, "new-reference")
    XCTAssertEqual(controller.lastResult?.text, result.text)
  }

  func testResendRevalidatesExpiredTargetReference() throws {
    let sessionID = SessionID()
    let pane = DisplayPaneController()
    let coordinator = AgentToolCoordinator(
      displayPaneController: pane,
      visibleSessionID: { sessionID },
      setPaneVisible: { _ in },
      windowProvider: { nil }
    )
    let controller = try XCTUnwrap(pane.activateNotificationTest(for: sessionID))
    controller.prefill(
      NotifyUserArguments(
        title: "Retry", message: "Ready", recipient: "owner", delivery: "ios",
        targetRef: "expired-reference"
      ),
      result: .failure("Old reference expired.")
    )
    _ = controller.view

    let result = withExtendedLifetime(coordinator) { controller.sendCurrentDraft() }

    XCTAssertTrue(result.isError)
    XCTAssertTrue(result.text.contains("target_ref is unknown, expired"), result.text)
    XCTAssertEqual(controller.lastResult?.text, result.text)
  }

  func testClosingTabDoesNotPersistNotificationTextOrTarget() throws {
    let sessionID = SessionID()
    let pane = DisplayPaneController()
    let controller = try XCTUnwrap(pane.activateNotificationTest(for: sessionID))
    controller.prefill(
      NotifyUserArguments(
        title: "Private title", message: "Private message", recipient: "owner",
        delivery: "ios", targetRef: "opaque-target"
      ),
      result: .success("Notification queued for the iPhone.")
    )
    let tab = try XCTUnwrap(pane.tabs(for: sessionID).first)

    XCTAssertTrue(pane.closeTab(id: tab.id, for: sessionID))
    XCTAssertTrue(DisplayPaneStore.shared.loadLayout(for: sessionID)?.panelTabs.isEmpty ?? true)
    XCTAssertNil(pane.tabs(for: sessionID).first?.notificationTest)
  }
}
