import AppKit
import UserNotifications

/// The walkthrough's last page: what Threading would notify about, behind an explicit ask.
///
/// The three alert kinds are drawn as rows whose toggles are **disabled until macOS grants
/// permission** — visible so it is clear what could be configured, inert so nothing pretends
/// to be on. "Enable notifications" fires the system prompt; skipping the page keeps the
/// app's standing behavior of asking at the first alert-worthy moment
/// (`AttentionAlertCenter.post`), which this page never touches.
///
/// TCC posts nothing when authorization flips, so while the page is up the status is
/// re-read on a timer and on app activation — the `PrivacyPreferencesViewController` watcher.
final class OnboardingNotificationsPageViewController: NSViewController, OnboardingPage {

    private enum Layout {
        static let contentWidth: CGFloat = 560
    }

    private enum Defaults {
        static let pollInterval: TimeInterval = 3
    }

    var pageTitle: String { L10n.string("Notifications") }
    var continueTitle: String { L10n.string("Start using Threading") }

    private var toggles: [AttentionAlert: ThemedToggle] = [:]
    private let soundToggle = ThemedToggle()
    private lazy var enableButton: ThemedButton = {
        let button = ThemedButton(
            title: L10n.string("Enable notifications"),
            target: self,
            action: #selector(enableTapped)
        )
        button.emphasis = .secondary
        button.setAccessibilityIdentifier("onboarding.notifications.enable")
        return button
    }()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")

    private var authorization: UNAuthorizationStatus?
    private let poll = MainRunLoopTimer()
    private let appEvents = AppEventObservations()

    /// Injectable so hosted tests can drive every state without the real notification center,
    /// which refuses to answer for an unbundled test host.
    var readAuthorization: (
        @escaping @MainActor @Sendable (UNAuthorizationStatus) -> Void
    ) -> Void = { completion in
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status = settings.authorizationStatus
            DispatchQueue.main.async { completion(status) }
        }
    }
    var requestAuthorization: (
        @escaping @MainActor @Sendable (Bool) -> Void
    ) -> Void = { completion in
        // The same options the standing ask-on-first-alert path requests — see
        // `AttentionAlertCenter.post`. No badge: sessions are not unread counts.
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { granted, _ in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    override func loadView() {
        view = NSView()
        setupViews()
    }

    func pageWillAppear() {
        refreshAuthorization()

        poll.install(Timer.scheduledTimer(
            withTimeInterval: Defaults.pollInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAuthorization()
            }
        })
        // The flow normally balances appear/disappear, but re-entering this edge must not
        // multiply the same observer if a future container retries presentation.
        appEvents.removeAll()
        appEvents.observe(NSApplication.didBecomeActiveNotification) { [weak self] in
            self?.refreshAuthorization()
        }
    }

    func pageWillDisappear() {
        poll.invalidate()
        appEvents.removeAll()
    }

    private func setupViews() {
        let heading = NSTextField(labelWithString: L10n.string("Know when a session needs you"))
        heading.applyFont(.heading)
        heading.textColor = Design.Text.label
        heading.alignment = .center

        let caption = NSTextField(
            wrappingLabelWithString: L10n.string(
                "Agents work for minutes at a time. A notification says when one is blocked on "
                    + "an approval, or finished while you were elsewhere. Only then, and only "
                    + "while Threading is in the background."
            )
        )
        caption.applyFont(.body)
        caption.textColor = Design.Text.secondary
        caption.alignment = .center

        var rows: [NSView] = AttentionAlert.allCases.map { alert in
            let toggle = ThemedToggle()
            toggle.setAccessibilityLabel(alert.settingsTitle)
            toggle.target = self
            toggle.action = #selector(alertToggleChanged(_:))
            toggles[alert] = toggle
            return SettingsUI.row(
                title: alert.settingsTitle,
                subtitle: L10n.format("Says “%@”.", alert.body),
                control: toggle
            )
        }
        soundToggle.setAccessibilityLabel(L10n.string("Play a sound"))
        soundToggle.target = self
        soundToggle.action = #selector(soundToggleChanged)
        rows.append(SettingsUI.row(
            title: L10n.string("Play a sound"),
            subtitle: L10n.string("Only for the approval alert, which is the one that waits."),
            control: soundToggle
        ))

        statusLabel.applyFont(.caption)
        statusLabel.textColor = Design.Text.secondary
        statusLabel.alignment = .center

        let card = SettingsCard(rows: rows)

        let stack = NSStackView(views: [
            heading, caption, card, enableButton, statusLabel
        ])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = Design.Spacing.inset
        stack.setCustomSpacing(Design.Spacing.large, after: caption)
        // The card is the page's whole content; hemmed in by its own hug it read cramped, so
        // it keeps the walkthrough's shared measure and room below before the follow-up line.
        stack.setCustomSpacing(Design.Spacing.large, after: card)
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: Design.Spacing.pane),
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.bottomAnchor.constraint(
                lessThanOrEqualTo: view.bottomAnchor,
                constant: -Design.Spacing.pane
            ),
            caption.widthAnchor.constraint(lessThanOrEqualToConstant: Layout.contentWidth),
            card.widthAnchor.constraint(equalToConstant: Layout.contentWidth),
            statusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: Layout.contentWidth)
        ])

        apply(authorization: nil)
    }

    // MARK: - State machine

    private func refreshAuthorization() {
        readAuthorization { [weak self] status in
            self?.apply(authorization: status)
        }
    }

    /// One function draws every state, so a status flip mid-page cannot leave half the
    /// controls describing the old one.
    func apply(authorization status: UNAuthorizationStatus?) {
        authorization = status
        let granted = status == .authorized || status == .provisional

        for (alert, toggle) in toggles {
            toggle.isEnabled = granted
            toggle.state = granted
                ? (AppSettings.shared.notifies(on: alert) ? .on : .off)
                : .off
        }
        soundToggle.isEnabled = granted
        soundToggle.state = granted
            ? (AppSettings.shared.playsAttentionAlertSound ? .on : .off)
            : .off

        switch status {
        case .authorized, .provisional:
            enableButton.isHidden = true
            statusLabel.stringValue = L10n.string(
                "Notifications are on. Change any of this later in Settings ▸ General."
            )
        case .denied:
            enableButton.isHidden = false
            enableButton.title = L10n.string("Open System Settings…")
            statusLabel.stringValue = L10n.string(
                "macOS has notifications for Threading switched off; turning them on happens "
                    + "in System Settings ▸ Notifications."
            )
        default:
            enableButton.isHidden = false
            enableButton.title = L10n.string("Enable notifications")
            statusLabel.stringValue = L10n.string(
                "Skipping is fine. Threading will ask the first time there is something to say."
            )
        }
    }

    // MARK: - Actions

    @objc private func enableTapped() {
        if authorization == .denied {
            if let url = SystemPrivacyPermission.notifications.settingsURL {
                NSWorkspace.shared.open(url)
            }
            return
        }
        requestAuthorization { [weak self] _ in
            self?.refreshAuthorization()
        }
    }

    @objc private func alertToggleChanged(_ sender: ThemedToggle) {
        guard let (alert, toggle) = toggles.first(where: { $0.value === sender }) else { return }
        AppSettings.shared.setNotifies(toggle.state == .on, on: alert)
    }

    @objc private func soundToggleChanged() {
        AppSettings.shared.playsAttentionAlertSound = soundToggle.state == .on
    }
}
