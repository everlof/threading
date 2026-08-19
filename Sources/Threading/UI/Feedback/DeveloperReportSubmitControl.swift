import AppKit

/// What a finished report can be done with.
///
/// Three actions that were three buttons in a row, ranked by a layout rather than by what the
/// person filing the report actually does with it. They are one control now: the press is
/// whichever one was taken last, and the chevron holds the rest.
enum DeveloperReportAction: String, CaseIterable, Sendable {

    /// Hand it to the private intake, or to the outbox when this build states no intake. One
    /// action rather than two, because it is one intention: the difference is a fact about the
    /// build, not a choice the person is making.
    case send

    /// The whole report on the pasteboard, path and all.
    case copy

    /// A new chat in the repository this binary was built from (Debug builds only).
    case chat

    /// The action the press would take right now.
    ///
    /// Re-resolved rather than read, because what the memory names may stop being on offer: a
    /// remembered Chat is a Release build's press to nowhere.
    static func resolvePreferred(
        storedID: String?,
        among available: [DeveloperReportAction]
    ) -> DeveloperReportAction {
        guard let storedID,
              let stored = DeveloperReportAction(rawValue: storedID),
              available.contains(stored) else {
            return available.first ?? .send
        }
        return stored
    }

    /// - Parameter deliversToService: whether this build has an intake to post to.
    ///   `send` is the only title that moves, and it moves because the *action* does.
    func title(deliversToService: Bool) -> String {
        switch self {
        case .send:
            return deliversToService
                ? L10n.string("Send to Developer")
                : L10n.string("Send to Outbox")
        case .copy:
            return L10n.string("Copy Report")
        case .chat:
#if DEBUG
            return DeveloperReportChatStrings.buttonTitle
#else
            // Unreachable: every call site builds `available` with `.chat` behind the same
            // guard, and the chat's strings live inside the feature's own `#if DEBUG` rather
            // than shipping copy for a route a Release build does not have.
            return ""
#endif
        }
    }
}

enum DeveloperReportDefaults {
    /// A user's choice, so `PreferenceStore` rather than `.standard`: the test bundle is hosted
    /// in the app, and a fixture pressing Copy would otherwise decide what the developer's own
    /// sheet comes up offering next.
    static let lastActionKey = "developerReport.lastAction"
    static let menuWidth: CGFloat = 200
}

/// The report sheet's action: one press, and the other ways to take it under a chevron.
///
/// **Welded, and primary.** This is the sheet's one accent action, and until the plate learned to
/// carry an emphasis the two could not be the same control — a primary press against a neutral
/// chevron holds a permanent colour seam (`SplitButtonView`). The alternative was the shape this
/// replaces: three buttons in a row, where Copy Report and Send to Chat sat beside the submit as
/// if a report were three decisions rather than one taken three ways.
///
/// The chevron appears only when there is more than one action, which is the same rule the
/// attachments pane's scope band follows: a control offering no choice teaches nothing.
@MainActor
final class DeveloperReportSubmitControl: NSView {

    // MARK: - Properties

    /// Invoked with the action the person took. The caller performs it; this control only owns
    /// which one is offered, and remembers it afterwards.
    var onPerform: ((DeveloperReportAction) -> Void)?

    /// The press itself, so a caller can disable it and retitle it while a submission is in
    /// flight — the one state that is about the *submission* rather than about the choice.
    let press: ThemedButton

    private let available: [DeveloperReportAction]
    private let chevron: ThemedIconButton?
    private var menuSession: AnyObject?
    private var isBusy = false

    /// What the press would do if it were pressed now.
    private(set) var action: DeveloperReportAction

    // MARK: - Initialization

    init(available: [DeveloperReportAction]) {
        precondition(!available.isEmpty, "a report sheet with no action is a sheet with no point")
        self.available = available
        self.action = DeveloperReportAction.resolvePreferred(
            storedID: PreferenceStore.shared.string(forKey: DeveloperReportDefaults.lastActionKey),
            among: available
        )
        press = ThemedButton()
        press.emphasis = .primary
        chevron = available.count > 1
            ? ThemedIconButton(
                symbolName: DesignSymbols.chevron,
                accessibility: L10n.string("Other ways to send"),
                target: .titledSplitMenu
            )
            : nil

        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public Methods

    /// Retitles the press for a submission in flight, and puts it back afterwards.
    func setBusy(_ busy: Bool, title: String? = nil) {
        isBusy = busy
        press.isEnabled = !busy
        press.title = busy ? (title ?? press.title) : action.title(deliversToService: Self.delivers)
    }

    /// Says something happened without changing what the press does — Copy Report's own receipt,
    /// which is the button briefly wearing the past tense. The choice underneath is unchanged, so
    /// nothing is re-resolved when it goes back.
    func flashTitle(_ title: String, restoringAfter delay: TimeInterval) {
        guard !isBusy else { return }
        press.title = title
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !isBusy else { return }
            press.title = action.title(deliversToService: Self.delivers)
        }
    }

    // MARK: - Private Methods

    private static var delivers: Bool { MacIssueReportOutbox.isDeliveryConfigured }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        press.target = self
        press.action = #selector(pressed)
        press.title = action.title(deliversToService: Self.delivers)
        press.setAccessibilityIdentifier(DeveloperReportIdentifiers.submit)

        let content: NSView
        if let chevron {
            chevron.presentsMenu = true
            chevron.onPress = { [weak self, weak chevron] in
                guard let self, let chevron else { return }
                presentMenu(from: chevron)
            }
            chevron.setAccessibilityIdentifier(DeveloperReportIdentifiers.actions)
            content = SplitButtonView(action: press, chevron: chevron)
        } else {
            content = press
        }

        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    @objc private func pressed() {
        take(action)
    }

    private func presentMenu(from button: ThemedIconButton) {
        guard menuSession == nil else { return }
        let entries: [ThemedMenuEntry] = available
            .filter { $0 != action }
            .map { other in
                .item(ThemedMenuItem(
                    title: other.title(deliversToService: Self.delivers),
                    onChoose: { [weak self] in self?.take(other) }
                ))
            }
        guard !entries.isEmpty else { return }

        menuSession = ThemedMenuPresenter.present(
            ThemedMenuPresentation(
                entries: entries,
                minimumWidth: DeveloperReportDefaults.menuWidth
            ),
            from: button,
            selectedEntryIndex: nil,
            onChoose: { _, item in item.onChoose?() },
            onDismiss: { [weak self] in self?.menuSession = nil }
        )
    }

    /// The choice is recorded before the action runs, so a report filed by a route that then
    /// fails still leaves the sheet offering the route the person chose.
    private func take(_ action: DeveloperReportAction) {
        self.action = action
        PreferenceStore.shared.set(action.rawValue, forKey: DeveloperReportDefaults.lastActionKey)
        press.title = action.title(deliversToService: Self.delivers)
        onPerform?(action)
    }
}

enum DeveloperReportIdentifiers {
    static let submit = "developerReport.submit"
    static let actions = "developerReport.actions"
}
