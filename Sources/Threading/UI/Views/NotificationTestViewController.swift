import AppKit
import ThreadingRemoteKit

/// What a Push Test tab needs from its window: the one validated send, who in the chat
/// could be chosen, what an agent's link still opens, and the chat's latest request.
@MainActor
protocol NotificationTestHosting: AnyObject {
  var notificationTests: NotificationTestLedger { get }

  /// Sends through the same path as `notify_user` and records the attempt in the ledger.
  func sendTestNotification(
    _ arguments: NotifyUserArguments,
    for sessionID: SessionID
  ) -> RequestedNotificationOutcome

  func notificationRecipientNames(for sessionID: SessionID) -> [String]

  func notificationTargetKind(
    _ reference: String,
    for sessionID: SessionID
  ) -> RemoteNotificationDestinationDTO.Kind?
}

/// Sends a notification from one chat to see how it arrives, starting from the chat's latest
/// request — an agent's `notify_user` or the person's own last test.
///
/// Delivery stays with the host, so this surface cannot bypass recipient consent or read a
/// request differently from the tool. The form asks only what a person can answer: the
/// recipient appears when the chat has someone other than its owner to reach, and the tap
/// target when an agent attached one. A request arriving while the person is editing reports
/// its result and leaves their draft alone.
@MainActor
final class NotificationTestViewController: NSViewController {

  // MARK: - Properties

  let sessionID: SessionID
  private weak var host: NotificationTestHosting?

  /// The request the form was last filled with. Its recipient and target survive while their
  /// rows are hidden, so a resend repeats what was asked rather than a default.
  private var appliedDraft = NotificationTestDefaults.blankDraft
  private var hasUnsentEdits = false

  private let root = ThemedSurfaceView()
  private let keyScope = KeyEquivalentScopeView()
  private let scroll = ThemedScrollView()
  private let document = NotificationTestDocumentView()
  private let stack = NSStackView()
  private let intro = NSTextField(wrappingLabelWithString: NotificationTestStrings.intro)
  private let titleField = ThemedTextField()
  private let messageField = PromptView()
  private let deliveryPicker = ThemedPopUp()
  private let recipientPicker = ThemedPopUp()
  private let targetPicker = ThemedPopUp()
  private let statusView = SubmissionStatusView()
  private let sendButton = ThemedButton(
    title: NotificationTestStrings.send, target: nil, action: nil
  )
  private lazy var recipientSection = section(
    NotificationTestStrings.recipientCaption, content: recipientPicker
  )
  private lazy var targetSection = section(
    NotificationTestStrings.targetCaption, content: targetPicker
  )

  // MARK: - Initialization

  init(sessionID: SessionID, host: NotificationTestHosting?) {
    self.sessionID = sessionID
    self.host = host
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func loadView() {
    root.applySurface(fill: Design.Surface.ground, radius: .fixed(0), pattern: .backdrop)
    root.frame = NSRect(origin: .zero, size: NotificationTestDefaults.initialSize)
    view = root
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    configureControls()
    layoutControls()
    guard let host else {
      apply(NotificationTestDefaults.blankDraft)
      return
    }
    host.notificationTests.addObserver(self, for: sessionID)
    if let record = host.notificationTests.latest(for: sessionID) {
      apply(record.arguments)
      show(record)
    } else {
      apply(NotificationTestDefaults.blankDraft)
    }
  }

  // MARK: - Public Methods

  /// The request the form describes now.
  var draft: NotifyUserArguments {
    let title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    let message = messageField.stringValue
    return NotifyUserArguments(
      title: title.isEmpty ? nil : title,
      message: message.isEmpty ? nil : message,
      recipient: recipientSection.isHidden
        ? appliedDraft.recipient
        : recipientPicker.selectedItem?.representedValue as? String,
      delivery: selectedDelivery.argument,
      targetRef: targetSection.isHidden
        ? nil
        : targetPicker.selectedItem?.representedValue as? String
    )
  }

  var statusMessage: String { statusView.message }
  var showsRecipientChoice: Bool { !recipientSection.isHidden }
  var showsTargetChoice: Bool { !targetSection.isHidden }

  @discardableResult
  func sendCurrentDraft() -> RequestedNotificationOutcome {
    let arguments = draft
    guard let host else {
      let outcome = RequestedNotificationOutcome.refused(NotificationTestStrings.unavailable)
      statusView.show(outcome.message, tone: .failed)
      return outcome
    }
    // Cleared first: the send records itself, and the ledger's echo should refill the form
    // with exactly what was sent rather than be mistaken for a request arriving mid-edit.
    hasUnsentEdits = false
    return host.sendTestNotification(arguments, for: sessionID)
  }

  // MARK: - Private Methods — Construction

  private func configureControls() {
    intro.applyFont(.subheading)
    intro.textColor = Design.Text.secondary
    intro.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    titleField.placeholderString = NotificationTestStrings.titlePlaceholder
    titleField.delegate = self
    titleField.setAccessibilityLabel(NotificationTestStrings.titleCaption)
    titleField.setAccessibilityIdentifier(NotificationTestIdentifiers.title)

    messageField.placeholder = NotificationTestStrings.messagePlaceholder
    messageField.submitPlacement = .outside
    messageField.minimumHeight = NotificationTestDefaults.messageHeight
    messageField.onSubmit = { [weak self] _ in self?.sendCurrentDraft() }
    messageField.onChange = { [weak self] _ in self?.hasUnsentEdits = true }
    messageField.textAccessibilityLabel = NotificationTestStrings.messageCaption
    messageField.setAccessibilityIdentifier(NotificationTestIdentifiers.message)

    for delivery in RequestedNotificationDelivery.allCases {
      deliveryPicker.addItem(ThemedMenuItem(
        title: NotificationTestStrings.title(for: delivery),
        representedValue: delivery.argument
      ))
    }
    deliveryPicker.target = self
    deliveryPicker.action = #selector(choiceChanged)
    deliveryPicker.setAccessibilityLabel(NotificationTestStrings.deliveryCaption)
    deliveryPicker.setAccessibilityIdentifier(NotificationTestIdentifiers.delivery)

    recipientPicker.target = self
    recipientPicker.action = #selector(choiceChanged)
    recipientPicker.setAccessibilityLabel(NotificationTestStrings.recipientCaption)
    recipientPicker.setAccessibilityIdentifier(NotificationTestIdentifiers.recipient)

    targetPicker.target = self
    targetPicker.action = #selector(choiceChanged)
    targetPicker.setAccessibilityLabel(NotificationTestStrings.targetCaption)
    targetPicker.setAccessibilityIdentifier(NotificationTestIdentifiers.target)

    statusView.maximumNumberOfLines = NotificationTestDefaults.statusLines
    statusView.setAccessibilityIdentifier(NotificationTestIdentifiers.status)

    sendButton.emphasis = .primary
    sendButton.target = self
    sendButton.action = #selector(sendClicked)
    sendButton.toolTip = NotificationTestStrings.sendHelp
    sendButton.setAccessibilityIdentifier(NotificationTestIdentifiers.send)

    // ⌘Return sends from anywhere in the form, and only from inside it. A chord on the button
    // would be a key equivalent for the whole window and take the conversation composer's own
    // ⌘Return while this tab merely stood beside it.
    keyScope.onKeyEquivalent = { [weak self] event in
      guard NotificationTestDefaults.sendShortcut.matches(event) else { return false }
      self?.sendCurrentDraft()
      return true
    }

    scroll.hasVerticalScroller = true
    scroll.documentView = document
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = Design.Spacing.medium
    stack.edgeInsets = NSEdgeInsets(
      top: Design.Spacing.large, left: Design.Spacing.large,
      bottom: Design.Spacing.large, right: Design.Spacing.large
    )
    stack.setHuggingPriority(.defaultHigh, for: .vertical)
    [
      intro,
      section(NotificationTestStrings.titleCaption, content: titleField),
      section(NotificationTestStrings.messageCaption, content: messageField),
      section(NotificationTestStrings.deliveryCaption, content: deliveryPicker),
      recipientSection,
      targetSection,
      statusView,
      footer()
    ].forEach { stack.addArrangedSubview($0) }
    stack.setCustomSpacing(Design.Spacing.large, after: intro)
  }

  private func section(_ caption: String, content: NSView) -> NSStackView {
    let label = NSTextField(labelWithString: caption)
    label.applyFont(.caption)
    label.textColor = Design.Text.secondary
    let section = NSStackView(views: [label, content])
    section.orientation = .vertical
    section.alignment = .leading
    section.spacing = Design.Spacing.small
    content.translatesAutoresizingMaskIntoConstraints = false
    content.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
    return section
  }

  private func footer() -> NSStackView {
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let footer = NSStackView(views: [spacer, sendButton])
    footer.orientation = .horizontal
    footer.spacing = Design.Spacing.small
    return footer
  }

  private func layoutControls() {
    keyScope.translatesAutoresizingMaskIntoConstraints = false
    scroll.translatesAutoresizingMaskIntoConstraints = false
    document.translatesAutoresizingMaskIntoConstraints = false
    stack.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(keyScope)
    keyScope.addSubview(scroll)
    document.addSubview(stack)
    for row in stack.arrangedSubviews {
      row.translatesAutoresizingMaskIntoConstraints = false
      row.widthAnchor.constraint(
        equalTo: stack.widthAnchor, constant: -2 * Design.Spacing.large
      ).isActive = true
    }
    NSLayoutConstraint.activate([
      keyScope.topAnchor.constraint(equalTo: root.topAnchor),
      keyScope.bottomAnchor.constraint(equalTo: root.bottomAnchor),
      keyScope.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      keyScope.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      scroll.topAnchor.constraint(equalTo: keyScope.topAnchor),
      scroll.bottomAnchor.constraint(equalTo: keyScope.bottomAnchor),
      scroll.leadingAnchor.constraint(equalTo: keyScope.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: keyScope.trailingAnchor),
      document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
      stack.topAnchor.constraint(equalTo: document.topAnchor),
      stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
      stack.bottomAnchor.constraint(equalTo: document.bottomAnchor)
    ])
  }

  // MARK: - Private Methods — State

  private var selectedDelivery: RequestedNotificationDelivery {
    (deliveryPicker.selectedItem?.representedValue as? String)
      .flatMap(RequestedNotificationDelivery.init(rawValue:))
      ?? .both
  }

  /// Fills the form with a request, choosing only rows it has something to ask about.
  private func apply(_ arguments: NotifyUserArguments) {
    appliedDraft = arguments
    hasUnsentEdits = false
    titleField.stringValue = arguments.title ?? ""
    messageField.stringValue = arguments.message ?? ""

    let delivery = RequestedNotificationDelivery(argument: arguments.delivery) ?? .both
    deliveryPicker.selectItem(
      at: deliveryPicker.indexOfItem { ($0.representedValue as? String) == delivery.argument }
        ?? -1
    )

    applyRecipientChoices(for: arguments.recipient)
    applyTargetChoices(for: arguments.targetRef)
  }

  /// The owner, the current turn's author and everyone mean the same person in a chat nobody
  /// else is in, so the row appears only when there is someone else to reach — or when the
  /// request named somebody, which the person must be able to see before resending.
  private func applyRecipientChoices(for recipient: String?) {
    let members = host?.notificationRecipientNames(for: sessionID) ?? []
    let requested = NotificationTestRecipient(recipient)
    recipientPicker.removeAllItems()
    recipientSection.isHidden = members.isEmpty && requested.namedMember == nil
    guard !recipientSection.isHidden else { return }

    for choice in NotificationTestRecipient.fixedChoices {
      recipientPicker.addItem(ThemedMenuItem(
        title: NotificationTestStrings.title(for: choice),
        representedValue: choice.argument
      ))
    }
    var names = members
    if let named = requested.namedMember,
      !names.contains(where: { $0.caseInsensitiveCompare(named) == .orderedSame })
    {
      names.append(named)
    }
    if !names.isEmpty { recipientPicker.addSeparator() }
    for name in names {
      recipientPicker.addItem(ThemedMenuItem(title: name, representedValue: name))
    }
    let wanted = requested.argument
    recipientPicker.selectItem(
      at: recipientPicker.indexOfItem {
        ($0.representedValue as? String)?.caseInsensitiveCompare(wanted) == .orderedSame
      } ?? recipientPicker.indexOfFirstItem ?? -1
    )
  }

  /// An agent's link is shown for what it opens, never as its opaque reference. One that has
  /// expired stays visible but cannot be chosen, so a resend opens the chat and says so.
  private func applyTargetChoices(for reference: String?) {
    targetPicker.removeAllItems()
    let reference = reference?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let reference, !reference.isEmpty else {
      targetSection.isHidden = true
      return
    }
    targetSection.isHidden = false
    targetPicker.addItem(ThemedMenuItem(
      title: NotificationTestStrings.openChat, representedValue: nil
    ))
    let kind = host?.notificationTargetKind(reference, for: sessionID)
    targetPicker.addItem(ThemedMenuItem(
      title: NotificationTestStrings.title(forTarget: kind),
      representedValue: reference,
      isEnabled: kind != nil
    ))
    targetPicker.selectItem(at: kind == nil ? 0 : 1)
  }

  private func show(_ record: NotificationTestLedger.Record) {
    statusView.show(
      NotificationTestStrings.status(for: record),
      tone: record.outcome.isQueued ? .done : .failed
    )
  }

  @objc private func choiceChanged() { hasUnsentEdits = true }
  @objc private func sendClicked() { sendCurrentDraft() }
}

// MARK: - NSTextFieldDelegate

extension NotificationTestViewController: NSTextFieldDelegate {
  func controlTextDidChange(_ notification: Notification) {
    hasUnsentEdits = true
  }
}

// MARK: - NotificationTestLedgerObserving

extension NotificationTestViewController: NotificationTestLedgerObserving {
  func notificationTestLedger(
    _ ledger: NotificationTestLedger,
    didRecord record: NotificationTestLedger.Record,
    for sessionID: SessionID
  ) {
    guard isViewLoaded, sessionID == self.sessionID else { return }
    if !hasUnsentEdits { apply(record.arguments) }
    show(record)
  }
}

// MARK: - Supporting Types

/// Who a request is for, in the vocabulary `notify_user` accepts.
struct NotificationTestRecipient: Equatable {
  enum Fixed: String, CaseIterable {
    case owner
    case requester
    case everyone
  }

  static let fixedChoices = Fixed.allCases

  /// The canonical argument, so a spelling the tool also accepts selects the same row.
  let argument: String
  /// A member named by the request rather than one of the fixed choices.
  let namedMember: String?

  init(_ rawValue: String?) {
    let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    switch trimmed.lowercased() {
    case "", "requester", "me":
      argument = Fixed.requester.rawValue
      namedMember = nil
    case "owner":
      argument = Fixed.owner.rawValue
      namedMember = nil
    case "everyone", "all":
      argument = Fixed.everyone.rawValue
      namedMember = nil
    default:
      argument = trimmed
      namedMember = trimmed
    }
  }
}

extension NotificationTestRecipient.Fixed {
  var argument: String { rawValue }
}

enum NotificationTestDefaults {
  /// A person opening the tab is most often checking their own phone.
  static let blankDraft = NotifyUserArguments(
    title: nil,
    message: nil,
    recipient: NotificationTestRecipient.Fixed.owner.argument,
    delivery: RequestedNotificationDelivery.ios.argument
  )
  /// The same height the inspector's note opens at: a notification is a sentence or two.
  static let messageHeight: CGFloat = 120
  /// Room for a refusal that joins two destinations' reasons, read to its end.
  static let statusLines = 6
  /// A frame to lay out in before the panel sizes the tab; the panel replaces it at once.
  static let initialSize = NSSize(width: 380, height: 660)
  static let sendShortcut = KeyboardShortcut(key: "\r", modifiers: .command)
}

enum NotificationTestIdentifiers {
  static let title = "notification-test.title"
  static let message = "notification-test.message"
  static let delivery = "notification-test.delivery"
  static let recipient = "notification-test.recipient"
  static let target = "notification-test.target"
  static let status = "notification-test.status"
  static let send = "notification-test.send"
}

enum NotificationTestStrings {
  static var intro: String {
    L10n.string(
      "Send a notification from this chat to see how it arrives. Queued means Threading "
        + "found a route; it cannot confirm that the phone or watch showed it."
    )
  }
  static var titleCaption: String { L10n.string("Title") }
  static var titlePlaceholder: String { L10n.string("The chat’s name when empty") }
  static var messageCaption: String { L10n.string("Message") }
  static var messagePlaceholder: String { L10n.string("What the notification says") }
  static var deliveryCaption: String { L10n.string("Deliver to") }
  static var recipientCaption: String { L10n.string("Recipient") }
  static var targetCaption: String { L10n.string("When tapped") }
  static var openChat: String { L10n.string("Open the chat") }
  static var send: String { L10n.string("Send Test") }
  static var sendHelp: String {
    L10n.format("Send Test (%@)", NotificationTestDefaults.sendShortcut.displayString)
  }
  static var unavailable: String { L10n.string("Notifications cannot be sent from here.") }

  static func title(for delivery: RequestedNotificationDelivery) -> String {
    switch delivery {
    case .ios: L10n.string("iPhone")
    case .mac: L10n.string("This Mac")
    case .both: L10n.string("iPhone and Mac")
    }
  }

  static func title(for recipient: NotificationTestRecipient.Fixed) -> String {
    switch recipient {
    case .owner: L10n.string("You")
    case .requester: L10n.string("Whoever wrote the current turn")
    case .everyone: L10n.string("Everyone in this chat")
    }
  }

  static func title(forTarget kind: RemoteNotificationDestinationDTO.Kind?) -> String {
    switch kind {
    case .attachment: L10n.string("Open the attachment the agent linked")
    case .browserTab: L10n.string("Open the browser tab the agent linked")
    case .extensionPanel: L10n.string("Open the panel the agent linked")
    case .session: L10n.string("Open the chat")
    case nil: L10n.string("The agent’s link has expired")
    }
  }

  static func status(for record: NotificationTestLedger.Record) -> String {
    let time = record.date.formatted(date: .omitted, time: .shortened)
    switch record.origin {
    case .agent: return L10n.format("The agent’s request at %@: %@", time, record.outcome.message)
    case .person: return L10n.format("Your test at %@: %@", time, record.outcome.message)
    }
  }
}

/// A scroll document uses top-origin coordinates so a short form starts below the tab bar.
private final class NotificationTestDocumentView: NSView {
  override var isFlipped: Bool { true }
}
