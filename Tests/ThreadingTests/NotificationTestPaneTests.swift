import AppKit
import ThreadingRemoteKit
import XCTest
@testable import Threading

@MainActor
final class NotificationTestPaneTests: HostedStoreTestCase {

  // MARK: - An agent's request never moves the panel

  func testAgentRequestIsRecordedWithoutOpeningSelectingOrRevealingAnything() throws {
    let sessionID = SessionID()
    let pane = DisplayPaneController()
    pane.showSession(sessionID)
    pane.addContentTab(Self.plan, for: sessionID)
    let reading = try XCTUnwrap(pane.activeTabID(for: sessionID))
    pane.showCurrentTheme()
    var reveals = 0
    let coordinator = AgentToolCoordinator(
      displayPaneController: pane,
      visibleSessionID: { sessionID },
      setPaneVisible: { if $0 { reveals += 1 } },
      windowProvider: { nil }
    )

    let request = NotifyUserArguments(
      title: "Watch test", message: nil, recipient: "owner", delivery: "ios"
    )
    let result = coordinator.notifyUser(request, for: sessionID)

    XCTAssertTrue(result.isError)
    XCTAssertEqual(reveals, 0)
    XCTAssertTrue(pane.isShowingCurrentTheme, "a notification must not close the theme document")
    XCTAssertEqual(pane.activeTabID(for: sessionID), reading)
    XCTAssertFalse(pane.tabs(for: sessionID).contains { $0.notificationTest != nil })
    let record = try XCTUnwrap(coordinator.notificationTests.latest(for: sessionID))
    XCTAssertEqual(record.arguments, request)
    XCTAssertEqual(record.origin, .agent)
    XCTAssertEqual(record.outcome.message, result.text)
  }

  func testOpenTabRefreshesInPlaceWithoutTakingSelection() throws {
    let sessionID = SessionID()
    let pane = DisplayPaneController()
    pane.showSession(sessionID)
    let coordinator = AgentToolCoordinator(
      displayPaneController: pane,
      visibleSessionID: { sessionID },
      setPaneVisible: { _ in },
      windowProvider: { nil }
    )
    let controller = try XCTUnwrap(pane.activateNotificationTest(for: sessionID))
    _ = controller.view
    pane.addContentTab(Self.plan, for: sessionID)
    let reading = try XCTUnwrap(pane.activeTabID(for: sessionID))

    let result = coordinator.notifyUser(
      NotifyUserArguments(title: "Retry", message: "Ready", delivery: "invalid"),
      for: sessionID
    )

    XCTAssertEqual(pane.activeTabID(for: sessionID), reading)
    XCTAssertEqual(pane.tabs(for: sessionID).filter { $0.notificationTest != nil }.count, 1)
    XCTAssertEqual(controller.draft.title, "Retry")
    XCTAssertEqual(controller.draft.message, "Ready")
    XCTAssertTrue(controller.statusMessage.hasSuffix(result.text), controller.statusMessage)
  }

  func testRequestArrivingMidEditReportsItsResultAndKeepsTheDraft() throws {
    let sessionID = SessionID()
    let host = FakeNotificationTestHost()
    let controller = try loadedController(for: sessionID, host: host)
    let title = try control(NotificationTestIdentifiers.title, as: ThemedTextField.self, in: controller)
    title.stringValue = "Mine"
    NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: title)

    host.notificationTests.record(
      NotifyUserArguments(title: "Agent's", message: "Done"),
      outcome: .queued("Notification queued for the owner."),
      origin: .agent,
      for: sessionID
    )

    XCTAssertEqual(controller.draft.title, "Mine")
    XCTAssertTrue(
      controller.statusMessage.hasSuffix("Notification queued for the owner."),
      controller.statusMessage
    )
  }

  // MARK: - Opening the tab

  func testOpeningStartsFromTheChatsLatestRequest() throws {
    let sessionID = SessionID()
    let pane = DisplayPaneController()
    let coordinator = AgentToolCoordinator(
      displayPaneController: pane,
      visibleSessionID: { nil },
      setPaneVisible: { _ in },
      windowProvider: { nil }
    )
    let refused = coordinator.notifyUser(
      NotifyUserArguments(title: "Watch test", message: nil, recipient: "owner", delivery: "mac"),
      for: sessionID
    )

    let controller = try XCTUnwrap(pane.activateNotificationTest(for: sessionID))
    _ = controller.view

    XCTAssertEqual(pane.activeTabID(for: sessionID), pane.tabs(for: sessionID).first?.id)
    XCTAssertEqual(controller.draft.title, "Watch test")
    XCTAssertEqual(controller.draft.delivery, RequestedNotificationDelivery.mac.argument)
    XCTAssertTrue(controller.statusMessage.hasSuffix(refused.text), controller.statusMessage)
  }

  func testABlankTabIsSetToTheOwnersIPhone() throws {
    let host = FakeNotificationTestHost()
    let controller = try loadedController(for: SessionID(), host: host)

    XCTAssertEqual(controller.draft, NotificationTestDefaults.blankDraft)
    XCTAssertFalse(controller.showsRecipientChoice)
    XCTAssertFalse(controller.showsTargetChoice)
    XCTAssertEqual(controller.statusMessage, "")
    let message = try control(NotificationTestIdentifiers.message, as: PromptView.self, in: controller)
    XCTAssertEqual(message.textAccessibilityLabel, NotificationTestStrings.messageCaption)
    XCTAssertNil(host.notificationTests.latest(for: controller.sessionID))
  }

  // MARK: - Sending

  func testEditedDraftResendsExactFieldsAndReportsTheResult() throws {
    let sessionID = SessionID()
    let host = FakeNotificationTestHost()
    host.memberNames = ["Anna"]
    host.targetKinds = ["new-reference": .browserTab]
    host.notificationTests.record(
      NotifyUserArguments(
        title: "Original", message: "First", recipient: "owner", delivery: "both",
        targetRef: "new-reference"
      ),
      outcome: .refused("No opted-in phone has a live connection or usable push registration."),
      origin: .agent,
      for: sessionID
    )
    let controller = try loadedController(for: sessionID, host: host)

    try control(NotificationTestIdentifiers.title, as: ThemedTextField.self, in: controller)
      .stringValue = "  Edited  "
    try control(NotificationTestIdentifiers.message, as: PromptView.self, in: controller)
      .stringValue = "Again"
    let delivery = try control(NotificationTestIdentifiers.delivery, as: ThemedPopUp.self, in: controller)
    delivery.chooseItem(at: try XCTUnwrap(delivery.indexOfItem {
      ($0.representedValue as? String) == RequestedNotificationDelivery.ios.argument
    }))
    let recipient = try control(NotificationTestIdentifiers.recipient, as: ThemedPopUp.self, in: controller)
    recipient.chooseItem(at: try XCTUnwrap(recipient.indexOfItem { $0.title == "Anna" }))
    host.nextOutcome = .queued("Notification queued for Anna.")

    let outcome = controller.sendCurrentDraft()

    XCTAssertEqual(outcome, .queued("Notification queued for Anna."))
    XCTAssertEqual(host.sent.count, 1)
    XCTAssertEqual(host.sent.first?.sessionID, sessionID)
    XCTAssertEqual(host.sent.first?.arguments, NotifyUserArguments(
      title: "Edited", message: "Again", recipient: "Anna", delivery: "ios",
      targetRef: "new-reference"
    ))
    XCTAssertTrue(controller.statusMessage.contains("Notification queued for Anna."))
    XCTAssertEqual(host.notificationTests.latest(for: sessionID)?.origin, .person)
  }

  func testCommandReturnInsideTheFormSends() throws {
    let host = FakeNotificationTestHost()
    let controller = try loadedController(for: SessionID(), host: host)
    try control(NotificationTestIdentifiers.message, as: PromptView.self, in: controller)
      .stringValue = "Ping"
    let scope = try XCTUnwrap(find(KeyEquivalentScopeView.self, in: controller.view))
    let event = try XCTUnwrap(NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
      windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
      isARepeat: false, keyCode: 36
    ))

    XCTAssertEqual(scope.onKeyEquivalent?(event), true)
    XCTAssertEqual(host.sent.first?.arguments.message, "Ping")
  }

  // MARK: - Rows that appear only when they have a question to ask

  func testRecipientRowAppearsOnlyWhenSomeoneElseCouldBeReached() throws {
    let solo = FakeNotificationTestHost()
    let soloID = SessionID()
    solo.notificationTests.record(
      NotifyUserArguments(title: nil, message: "Done"),
      outcome: .queued("Notification queued for the owner."), origin: .agent, for: soloID
    )
    let soloController = try loadedController(for: soloID, host: solo)
    XCTAssertFalse(soloController.showsRecipientChoice)
    XCTAssertNil(soloController.draft.recipient, "a hidden row resends what was asked")

    let named = FakeNotificationTestHost()
    let namedID = SessionID()
    named.notificationTests.record(
      NotifyUserArguments(title: nil, message: "Done", recipient: "Bob"),
      outcome: .refused("Bob has not enabled requested agent notifications."),
      origin: .agent, for: namedID
    )
    let namedController = try loadedController(for: namedID, host: named)
    XCTAssertTrue(namedController.showsRecipientChoice)
    XCTAssertEqual(namedController.draft.recipient, "Bob")

    let shared = FakeNotificationTestHost()
    shared.memberNames = ["Anna"]
    let sharedController = try loadedController(for: SessionID(), host: shared)
    XCTAssertTrue(sharedController.showsRecipientChoice)
    XCTAssertEqual(sharedController.draft.recipient, "owner")
  }

  func testTargetRowNamesWhatALinkOpensAndWillNotResendAnExpiredOne() throws {
    let host = FakeNotificationTestHost()
    host.targetKinds = ["live": .attachment]
    let live = SessionID()
    let expired = SessionID()
    for (sessionID, reference) in [(live, "live"), (expired, "gone")] {
      host.notificationTests.record(
        NotifyUserArguments(title: nil, message: "Look", targetRef: reference),
        outcome: .queued("Notification queued for the Mac."), origin: .agent, for: sessionID
      )
    }

    let liveController = try loadedController(for: live, host: host)
    XCTAssertTrue(liveController.showsTargetChoice)
    XCTAssertEqual(liveController.draft.targetRef, "live")
    let livePicker = try control(NotificationTestIdentifiers.target, as: ThemedPopUp.self, in: liveController)
    XCTAssertEqual(livePicker.selectedItem?.title, L10n.string("Open the attachment the agent linked"))

    let expiredController = try loadedController(for: expired, host: host)
    XCTAssertTrue(expiredController.showsTargetChoice)
    XCTAssertNil(expiredController.draft.targetRef)
    let expiredPicker = try control(NotificationTestIdentifiers.target, as: ThemedPopUp.self, in: expiredController)
    XCTAssertEqual(expiredPicker.item(at: 1)?.isEnabled, false)
  }

  // MARK: - The shared send

  func testServiceRefusesATargetReferenceOnceItHasExpired() throws {
    let sessionID = SessionID()
    var now = Date(timeIntervalSince1970: 1_000_000)
    let targets = NotificationTargetRegistry(now: { now })
    let reference = try XCTUnwrap(targets.issue(.attachment(id: "report"), for: sessionID))
    let service = RequestedNotificationCommandService(
      notifications: RemoteNotificationService(
        subscriptionStore: InMemoryRemoteNotificationSubscriptionStore()
      ),
      targets: targets,
      isRemoteAccessEnabled: { false },
      postOnMac: { _ in
        XCTFail("an iPhone-only request must not post on the Mac")
        return false
      }
    )
    let request = NotifyUserArguments(
      title: nil, message: "Ready", delivery: "ios", targetRef: reference
    )

    XCTAssertEqual(service.send(request, for: sessionID), .refused("Remote Access is off."))
    XCTAssertEqual(service.targetKind(reference, for: sessionID), .attachment)
    XCTAssertNil(service.targetKind(reference, for: SessionID()))

    now += NotificationTargetDefaults.lifetime + 1
    let expired = service.send(request, for: sessionID)
    XCTAssertFalse(expired.isQueued)
    XCTAssertTrue(expired.message.hasPrefix("target_ref is unknown, expired"), expired.message)
    XCTAssertNil(service.targetKind(reference, for: sessionID))
  }

  func testDeliveryVocabularyIsTheToolsVocabulary() {
    XCTAssertEqual(RequestedNotificationDelivery.allCases, [.ios, .mac, .both])
    for delivery in RequestedNotificationDelivery.allCases {
      XCTAssertEqual(RequestedNotificationDelivery(argument: delivery.argument), delivery)
    }
    XCTAssertEqual(RequestedNotificationDelivery(argument: nil), .both)
    XCTAssertEqual(RequestedNotificationDelivery(argument: " Auto "), .both)
    XCTAssertEqual(RequestedNotificationDelivery(argument: "iPhone"), .ios)
    XCTAssertNil(RequestedNotificationDelivery(argument: "watch"))
  }

  // MARK: - Finding it

  func testCommandPaletteFindsItBySearchingForNotification() throws {
    let command = try XCTUnwrap(
      PanelCommands.additionalCommands.first { $0.id == "panel.notificationTest" }
    )
    XCTAssertEqual(command.panelTarget, .notificationTest)
    let descriptor = HostCommandDescriptor(
      id: command.id, title: command.title, detail: command.detail, group: command.group.rawValue,
      shortcut: nil, origin: .builtIn, scope: .session, risk: .ordinary,
      availability: .available, nextInput: nil, shortcutEditable: true
    )
    for query in ["test notification", "notification", "push", "iphone"] {
      XCTAssertEqual(
        HostCommandSearch.results(in: [descriptor], matching: query).map(\.id),
        [command.id],
        query
      )
    }
  }

  /// The tab is named for the room it gets, not the menu: under a wide monospace theme the
  /// first name, "Test Notification", truncated at the chip's cap and pushed past the edge of a
  /// panel holding the Simulator beside it. 420pt is the width the panel's evidence is reviewed
  /// at, narrower than the 440 it opens at.
  func testPushTestFitsBesideTheSimulatorInEveryStockThemeWithoutScrolling() throws {
    let previous = AppThemePalette.current
    defer { AppThemePalette.set(previous) }
    for theme in [AppTheme.system] + AppThemeLibrary.stock {
      AppThemePalette.set(theme)
      let sessionID = SessionID()
      let pane = DisplayPaneController()
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 420, height: 400),
        styleMask: [.borderless], backing: .buffered, defer: true
      )
      window.isReleasedWhenClosed = false
      window.contentViewController = pane
      window.setContentSize(NSSize(width: 420, height: 400))
      pane.showSession(sessionID)
      pane.addContentTab(
        DisplayContent(body: .html("<p></p>"), title: L10n.string("iOS Simulator"), subtitle: ""),
        for: sessionID
      )
      pane.activateNotificationTest(for: sessionID)
      AppThemeRefresh.repaint(pane.view)
      pane.view.layoutSubtreeIfNeeded()
      pane.view.layoutSubtreeIfNeeded()

      let strip = try XCTUnwrap(find(ThemedTabStripView.self, in: pane.view))
      let clip = try XCTUnwrap(find(ThemedScrollView.self, in: strip)).contentView
      let row = try XCTUnwrap(clip.documentView)
      XCTAssertLessThanOrEqual(row.frame.width, clip.bounds.width + 0.5, theme.name)
      let tab = try XCTUnwrap(
        strip.subviewsRecursively(ofType: ThemedTabItemView.self)
          .first { $0.title == L10n.string("Push Test") },
        theme.name
      )
      let title = try XCTUnwrap(tab.subviewsRecursively(ofType: MorphingTitleLabel.self).first)
      XCTAssertGreaterThanOrEqual(
        title.frame.width, title.intrinsicContentSize.width - 0.5, "\(theme.name) truncated"
      )
    }
  }

  /// Only the display panel adopts this tab — the drawer takes terminals and browsers, a
  /// detached window shared browsers — so the one lookup in `activateNotificationTest` is the
  /// whole of what keeps a chat to a single Push Test tab.
  func testTheTabCannotLeaveTheDisplayPanelSoItStaysSingle() throws {
    let sessionID = SessionID()
    let pane = DisplayPaneController()
    let first = try XCTUnwrap(pane.activateNotificationTest(for: sessionID))
    let tab = try XCTUnwrap(pane.tabs(for: sessionID).first { $0.notificationTest != nil })
    let drawer = DrawerHostViewController(
      directoryProvider: { _ in URL(fileURLWithPath: NSTemporaryDirectory()) },
      loadPanel: { _ in nil },
      persistDrawer: { _, _, _, _ in }
    )

    XCTAssertFalse(drawer.canAdopt(tab))
    XCTAssertFalse(DetachedBrowserHostViewController.canHold(tab))
    XCTAssertTrue(pane.activateNotificationTest(for: sessionID) === first)
    XCTAssertEqual(pane.tabs(for: sessionID).filter { $0.notificationTest != nil }.count, 1)
  }

  // MARK: - Persistence

  func testTheTabAndItsTextNeverReachTheSavedLayout() throws {
    let sessionID = SessionID()
    let pane = DisplayPaneController()
    let coordinator = AgentToolCoordinator(
      displayPaneController: pane,
      visibleSessionID: { nil },
      setPaneVisible: { _ in },
      windowProvider: { nil }
    )
    _ = coordinator.notifyUser(
      NotifyUserArguments(
        title: "Private title", message: "Private message", delivery: "ios",
        targetRef: "opaque-target"
      ),
      for: sessionID
    )
    let controller = try XCTUnwrap(pane.activateNotificationTest(for: sessionID))
    _ = controller.view
    // Saving the layout while the tab is open and selected is the case that matters: the
    // content tab below writes the whole strip.
    pane.addContentTab(Self.plan, for: sessionID)
    let testTab = try XCTUnwrap(pane.tabs(for: sessionID).first { $0.notificationTest != nil })
    XCTAssertTrue(pane.activateTab(id: testTab.id, for: sessionID))

    let layout = try XCTUnwrap(DisplayPaneStore.shared.loadLayout(for: sessionID))
    XCTAssertEqual(layout.panelTabs.map(\.kind), [.html])
    let encoded = String(decoding: try JSONEncoder().encode(layout.panelTabs), as: UTF8.self)
    for secret in ["Private title", "Private message", "opaque-target"] {
      XCTAssertFalse(encoded.contains(secret), secret)
    }
  }

  func testRemovingTheChatForgetsItsRequest() {
    let sessionID = SessionID()
    let pane = DisplayPaneController()
    let coordinator = AgentToolCoordinator(
      displayPaneController: pane,
      visibleSessionID: { nil },
      setPaneVisible: { _ in },
      windowProvider: { nil }
    )
    _ = coordinator.notifyUser(NotifyUserArguments(title: nil, message: nil), for: sessionID)
    XCTAssertNotNil(coordinator.notificationTests.latest(for: sessionID))

    pane.removeSession(sessionID)

    XCTAssertNil(coordinator.notificationTests.latest(for: sessionID))
  }

  // MARK: - Helpers

  private static let plan = DisplayContent(body: .html("<p>Plan</p>"), title: "Plan", subtitle: "")

  private func loadedController(
    for sessionID: SessionID,
    host: FakeNotificationTestHost
  ) throws -> NotificationTestViewController {
    let pane = DisplayPaneController()
    pane.notificationTestHost = host
    let controller = try XCTUnwrap(pane.activateNotificationTest(for: sessionID))
    _ = controller.view
    retained.append(pane)
    return controller
  }

  /// The pane owns the tab's controller; holding it keeps each fixture alive to the end.
  private var retained: [DisplayPaneController] = []

  private func control<T: NSView>(
    _ identifier: String,
    as type: T.Type,
    in controller: NSViewController
  ) throws -> T {
    func search(_ view: NSView) -> T? {
      if view.accessibilityIdentifier() == identifier, let match = view as? T { return match }
      return view.subviews.lazy.compactMap(search).first
    }
    return try XCTUnwrap(search(controller.view), identifier)
  }

  private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
    if let match = view as? T { return match }
    return view.subviews.lazy.compactMap { self.find(type, in: $0) }.first
  }
}

private extension NSView {
  func subviewsRecursively<T: NSView>(ofType type: T.Type) -> [T] {
    subviews.flatMap { view -> [T] in
      let own = (view as? T).map { [$0] } ?? []
      return own + view.subviewsRecursively(ofType: type)
    }
  }
}

/// Stands in for the window's tool coordinator so a test decides who could be reached and what
/// each send answers, with nothing leaving the process.
@MainActor
private final class FakeNotificationTestHost: NotificationTestHosting {
  let notificationTests = NotificationTestLedger()
  var memberNames: [String] = []
  var targetKinds: [String: RemoteNotificationDestinationDTO.Kind] = [:]
  var nextOutcome = RequestedNotificationOutcome.queued("Notification queued for the owner.")
  private(set) var sent: [(arguments: NotifyUserArguments, sessionID: SessionID)] = []

  func sendTestNotification(
    _ arguments: NotifyUserArguments,
    for sessionID: SessionID
  ) -> RequestedNotificationOutcome {
    sent.append((arguments, sessionID))
    notificationTests.record(arguments, outcome: nextOutcome, origin: .person, for: sessionID)
    return nextOutcome
  }

  func notificationRecipientNames(for sessionID: SessionID) -> [String] { memberNames }

  func notificationTargetKind(
    _ reference: String,
    for sessionID: SessionID
  ) -> RemoteNotificationDestinationDTO.Kind? {
    targetKinds[reference]
  }
}
