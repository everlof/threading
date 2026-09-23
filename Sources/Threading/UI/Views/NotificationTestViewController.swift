import AppKit

/// A short-lived draft for repeating or adjusting a `notify_user` request in this chat.
/// Delivery stays with the host command service, so this surface cannot bypass recipient consent or
/// invent a second interpretation of an MCP notification.
@MainActor
final class NotificationTestViewController: NSViewController {
  let sessionID: SessionID
  var onSend: ((NotifyUserArguments) -> MCPToolResult)?

  private(set) var draft = NotifyUserArguments(
    title: nil, message: nil, recipient: "owner", delivery: "ios"
  )
  private(set) var lastResult: MCPToolResult?

  private let root = ThemedSurfaceView()
  private let scroll = ThemedScrollView()
  private let content = NotificationTestDocumentView()
  private let stack = NSStackView()
  private let heading = NSTextField(labelWithString: L10n.string("Push Test"))
  private let explanation = NSTextField(
    wrappingLabelWithString: L10n.string(
      "Send a test notification for this chat. A queued result does not confirm delivery to the phone or watch."
    )
  )
  private let titleField = ThemedTextField()
  private let messageSurface = ThemedSurfaceView()
  private let messageScroll = ThemedTextView.scrolling()
  private let recipientField = ThemedTextField()
  private let deliveryPicker = ThemedPopUp()
  private let targetField = ThemedTextField()
  private let sendButton = ThemedButton()
  private let statusLabel = NSTextField(wrappingLabelWithString: "")

  init(sessionID: SessionID) {
    self.sessionID = sessionID
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func loadView() {
    root.applySurface(fill: Design.Surface.ground, radius: .fixed(0), pattern: .backdrop)
    root.frame = NSRect(x: 0, y: 0, width: 380, height: 660)
    view = root
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    configureControls()
    layoutControls()
    applyDraft()
    applyResult()
  }

  /// Called after an MCP attempt, including a refusal, so the exact request can be corrected.
  func prefill(_ arguments: NotifyUserArguments, result: MCPToolResult) {
    draft = arguments
    lastResult = result
    guard isViewLoaded else { return }
    applyDraft()
    applyResult()
    scrollToResult()
  }

  @discardableResult
  func sendCurrentDraft() -> MCPToolResult {
    let arguments = NotifyUserArguments(
      title: titleField.stringValue.isEmpty ? nil : titleField.stringValue,
      message: messageScroll.textView.string,
      recipient: recipientField.stringValue.isEmpty ? nil : recipientField.stringValue,
      delivery: ["both", "mac", "ios"][max(0, min(2, deliveryPicker.indexOfSelectedItem))],
      targetRef: targetField.stringValue.isEmpty ? nil : targetField.stringValue
    )
    draft = arguments
    let result = onSend?(arguments) ?? .failure("Notification sender is unavailable.")
    lastResult = result
    applyResult()
    scrollToResult()
    return result
  }

  private func configureControls() {
    heading.applyFont(.emphasizedBody)
    heading.textColor = Design.Text.label
    explanation.applyFont(.caption)
    explanation.textColor = Design.Text.secondary
    statusLabel.applyFont(.caption)
    statusLabel.setAccessibilityIdentifier("notification-test.status")

    titleField.placeholderString = L10n.string("Chat title if left empty")
    titleField.setAccessibilityIdentifier("notification-test.title")
    titleField.setAccessibilityLabel(L10n.string("Title"))
    recipientField.placeholderString = L10n.string("Requester (current turn)")
    recipientField.setAccessibilityIdentifier("notification-test.recipient")
    recipientField.setAccessibilityLabel(L10n.string("Recipient"))
    targetField.placeholderString = L10n.string("Chat if left empty")
    targetField.setAccessibilityIdentifier("notification-test.target-ref")
    targetField.setAccessibilityLabel(L10n.string("Target reference"))
    messageScroll.textView.setAccessibilityIdentifier("notification-test.message")
    messageScroll.textView.setAccessibilityLabel(L10n.string("Message"))
    messageScroll.textView.applyFont(.body)
    messageScroll.setAccessibilityIdentifier("notification-test.message-scroll")
    messageSurface.applySurface(fill: Design.Surface.controlResting, radius: .control)
    messageScroll.translatesAutoresizingMaskIntoConstraints = false
    messageSurface.addSubview(messageScroll)

    deliveryPicker.addItem(withTitle: L10n.string("Both"))
    deliveryPicker.addItem(withTitle: L10n.string("Mac"))
    deliveryPicker.addItem(withTitle: L10n.string("iPhone"))
    deliveryPicker.setAccessibilityIdentifier("notification-test.delivery")
    deliveryPicker.setAccessibilityLabel(L10n.string("Delivery"))
    sendButton.title = L10n.string("Send test")
    sendButton.emphasis = .primary
    sendButton.target = self
    sendButton.action = #selector(sendClicked)
    sendButton.setAccessibilityIdentifier("notification-test.send")

    scroll.hasVerticalScroller = true
    scroll.documentView = content
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = Design.Spacing.medium
    stack.edgeInsets = NSEdgeInsets(
      top: Design.Spacing.large, left: Design.Spacing.large,
      bottom: Design.Spacing.large, right: Design.Spacing.large
    )
    [
      heading, explanation, statusLabel,
      formRow(L10n.string("Title"), control: titleField),
      formRow(L10n.string("Message"), control: messageSurface),
      formRow(L10n.string("Recipient"), control: recipientField),
      formRow(L10n.string("Delivery"), control: deliveryPicker),
      formRow(L10n.string("Target reference"), control: targetField),
      sendButton
    ].forEach { stack.addArrangedSubview($0) }
  }

  private func formRow(_ title: String, control: NSView) -> NSStackView {
    let label = NSTextField(labelWithString: title)
    label.applyFont(.subheading)
    label.textColor = Design.Text.secondary
    let row = NSStackView(views: [label, control])
    row.orientation = .vertical
    row.alignment = .leading
    row.spacing = Design.Spacing.small
    return row
  }

  private func layoutControls() {
    scroll.translatesAutoresizingMaskIntoConstraints = false
    content.translatesAutoresizingMaskIntoConstraints = false
    stack.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(scroll)
    content.addSubview(stack)
    let rows = stack.arrangedSubviews
    for row in rows {
      row.translatesAutoresizingMaskIntoConstraints = false
      row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * Design.Spacing.large)
        .isActive = true
    }
    for row in rows.compactMap({ $0 as? NSStackView }) {
      guard let control = row.arrangedSubviews.last else { continue }
      control.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
    }
    messageSurface.heightAnchor.constraint(equalToConstant: 110).isActive = true
    NSLayoutConstraint.activate([
      messageScroll.topAnchor.constraint(
        equalTo: messageSurface.topAnchor, constant: Design.Spacing.medium
      ),
      messageScroll.bottomAnchor.constraint(
        equalTo: messageSurface.bottomAnchor, constant: -Design.Spacing.medium
      ),
      messageScroll.leadingAnchor.constraint(
        equalTo: messageSurface.leadingAnchor, constant: Design.Spacing.medium
      ),
      messageScroll.trailingAnchor.constraint(
        equalTo: messageSurface.trailingAnchor, constant: -Design.Spacing.medium
      ),
      scroll.topAnchor.constraint(equalTo: root.topAnchor),
      scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
      scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
      stack.topAnchor.constraint(equalTo: content.topAnchor),
      stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      stack.bottomAnchor.constraint(equalTo: content.bottomAnchor)
    ])
  }

  private func applyDraft() {
    titleField.stringValue = draft.title ?? ""
    messageScroll.textView.string = draft.message ?? ""
    recipientField.stringValue = draft.recipient ?? "requester"
    let deliveryIndex: Int
    switch draft.delivery?.lowercased() {
    case "mac": deliveryIndex = 1
    case "ios", "iphone", "phone": deliveryIndex = 2
    default: deliveryIndex = 0
    }
    deliveryPicker.selectItem(at: deliveryIndex)
    targetField.stringValue = draft.targetRef ?? ""
  }

  private func applyResult() {
    statusLabel.stringValue = lastResult?.text ?? ""
    statusLabel.textColor = lastResult?.isError == true ? Design.Status.negative : Design.Text.secondary
    statusLabel.isHidden = lastResult == nil
  }

  private func scrollToResult() {
    view.layoutSubtreeIfNeeded()
    scroll.contentView.scroll(to: .zero)
    scroll.reflectScrolledClipView(scroll.contentView)
  }

  @objc private func sendClicked() { sendCurrentDraft() }
}

/// A scroll document uses top-origin coordinates so a short form starts below the tab bar.
private final class NotificationTestDocumentView: NSView {
  override var isFlipped: Bool { true }
}
