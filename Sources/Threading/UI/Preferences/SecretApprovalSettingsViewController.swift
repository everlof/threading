import AppKit

/// The Mac's side of Face ID approvals: the switch, the one iPhone that approves, and what
/// keyvault is waiting for. Local only: none of it is a remotely mutable setting, and the phone
/// that approves can neither enable nor enroll itself.
///
/// The page says one thing at a time, and says what to do next: turn it on, enroll a phone with
/// the code shown in large digits, compare keys, connect keyvault. While it is on screen it reads
/// the broker again every second, so an enrollment finished on the phone, a code running out and
/// a request arriving all show without reopening Settings.
final class SecretApprovalSettingsViewController: NSViewController {
    /// Which rows the card holds. Rebuilt only when this changes; the words in them are updated
    /// in place every second.
    enum Shape: Equatable {
        case off, noPhone, code, enrolled, waiting
    }

    // MARK: - Properties

    private let enabledToggle = ThemedToggle()
    private let deviceButton = ThemedButton()
    private let copyButton = ThemedButton()
    private let codeLabel = NSTextField(labelWithString: "")
    private let commandLabel = NSTextField(labelWithString: SecretApprovalSettingsViewController.keyvaultCommand)
    private let storageLabel = NSTextField(wrappingLabelWithString: "")
    private var deviceSubtitle: NSTextField?
    private var waitingSubtitle: NSTextField?
    private var codeSubtitle: NSTextField?
    private let cardHost = NSView()
    private var shape: Shape?
    private var status: SecretApprovalBroker.Status?
    private var task: Task<Void, Never>?
    private var timer: Timer?
    private let broker: SecretApprovalBroker
    private let now: () -> Date

    static let keyvaultCommand = "keyvault device add iphone"

    // MARK: - Lifecycle

    init(broker: SecretApprovalBroker = .shared, now: @escaping () -> Date = { Date() }) {
        self.broker = broker
        self.now = now
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        enabledToggle.target = self
        enabledToggle.action = #selector(toggleEnabled)
        enabledToggle.setAccessibilityIdentifier("settings.secret-approvals.enabled")
        enabledToggle.state = AppSettings.shared.secretApprovalsEnabled ? .on : .off
        deviceButton.target = self
        deviceButton.action = #selector(deviceAction)
        deviceButton.setAccessibilityIdentifier("settings.secret-approvals.device")
        copyButton.target = self
        copyButton.action = #selector(copyCommand)
        copyButton.title = L10n.string("Copy")
        copyButton.emphasis = .secondary
        copyButton.setAccessibilityIdentifier("settings.secret-approvals.copy-command")

        codeLabel.applyFont(.numericDisplay)
        codeLabel.textColor = Design.Text.label
        codeLabel.isSelectable = true
        codeLabel.setAccessibilityIdentifier("settings.secret-approvals.code")
        commandLabel.applyFont(.code())
        commandLabel.textColor = Design.Text.label
        commandLabel.isSelectable = true
        commandLabel.setAccessibilityIdentifier("settings.secret-approvals.command")
        storageLabel.applyFont(.caption)
        storageLabel.textColor = Design.Text.tertiary
        storageLabel.setAccessibilityIdentifier("settings.secret-approvals.storage")

        let stack = NSStackView(views: [cardHost, storageLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.small
        cardHost.translatesAutoresizingMaskIntoConstraints = false
        cardHost.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        storageLabel.translatesAutoresizingMaskIntoConstraints = false
        storageLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        view = stack
        apply(SecretApprovalBroker.Status(enabled: AppSettings.shared.secretApprovalsEnabled, enrollmentCode: nil,
                                          enrollment: nil, pendingTitle: nil, isShellReachable: false))
        refresh()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Public Methods

    /// What the broker says, as rows. Public for tests and rendered evidence.
    func apply(_ status: SecretApprovalBroker.Status) {
        self.status = status
        enabledToggle.state = status.enabled ? .on : .off
        let next = Self.shape(for: status)
        if next != shape {
            shape = next
            rebuild(next)
        }
        updateWords(status)
        storageLabel.stringValue = KeychainStoragePolicy.storageDescription(isShellReachable: status.isShellReachable)
        storageLabel.isHidden = !status.enabled
    }

    /// Waits for the status read that loading started; for tests and rendered evidence.
    func refreshed() async { await task?.value }

    static func shape(for status: SecretApprovalBroker.Status) -> Shape {
        guard status.enabled else { return .off }
        if status.enrollmentCode != nil { return .code }
        guard status.enrollment != nil else { return .noPhone }
        return status.pendingTitle == nil ? .enrolled : .waiting
    }

    /// "1234 5678": two groups of four read back more reliably than eight digits in a row.
    static func grouped(_ code: String) -> String {
        guard code.count == 8 else { return code }
        return code.prefix(4) + " " + code.suffix(4)
    }

    /// "4:05" for what is left, never below zero.
    static func remaining(until deadline: Date?, now: Date) -> String {
        let seconds = max(0, Int((deadline ?? now).timeIntervalSince(now).rounded(.up)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: - Private Methods

    private func rebuild(_ shape: Shape) {
        var rows: [NSView] = [SettingsUI.row(
            title: "Approve with Face ID on iPhone",
            subtitle: "keyvault can ask your iPhone instead of this Mac’s Touch ID. The iPhone shows what is asked and who asks, and needs Face ID every time.",
            control: enabledToggle)]
        deviceSubtitle = nil
        waitingSubtitle = nil
        codeSubtitle = nil
        switch shape {
        case .off:
            break
        case .noPhone:
            deviceButton.title = L10n.string("Enroll iPhone")
            deviceButton.emphasis = .primary
            rows.append(SettingsUI.row(
                title: "No iPhone enrolled yet",
                subtitle: "Choose Enroll iPhone, then on the iPhone open Threading › Settings › Security › Face ID Approvals and type the code shown here.",
                control: deviceButton, subtitleField: &deviceSubtitle))
        case .code:
            deviceButton.title = L10n.string("Cancel")
            deviceButton.emphasis = .secondary
            rows.append(SettingsUI.row(title: "Type this code on your iPhone", subtitle: nil, control: deviceButton))
            rows.append(SettingsUI.fullRow(codeColumn()))
        case .enrolled, .waiting:
            deviceButton.title = L10n.string("Forget iPhone")
            deviceButton.emphasis = .secondary
            rows.append(SettingsUI.row(title: "iPhone enrolled", subtitle: "Loading…", control: deviceButton,
                                       subtitleField: &deviceSubtitle))
            rows.append(SettingsUI.row(
                title: "Connect keyvault",
                subtitle: "Run once in Terminal, so keyvault seals its Touch ID key for this iPhone:",
                control: copyButton))
            rows.append(SettingsUI.fullRow(commandLabel))
            if shape == .waiting {
                rows.append(SettingsUI.row(title: "Waiting for your iPhone", subtitle: "Loading…",
                                           subtitleField: &waitingSubtitle))
            }
        }
        let card = SettingsCard(rows: rows)
        card.setAccessibilityIdentifier("settings.secret-approvals.card")
        cardHost.subviews.forEach { $0.removeFromSuperview() }
        cardHost.addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: cardHost.topAnchor),
            card.bottomAnchor.constraint(equalTo: cardHost.bottomAnchor),
            card.leadingAnchor.constraint(equalTo: cardHost.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: cardHost.trailingAnchor)
        ])
    }

    private func codeColumn() -> NSView {
        let subtitle = NSTextField(wrappingLabelWithString: "")
        subtitle.applyFont(.subheading)
        subtitle.textColor = Design.Text.secondary
        subtitle.setAccessibilityIdentifier("settings.secret-approvals.code-help")
        codeSubtitle = subtitle
        let column = NSStackView(views: [codeLabel, subtitle])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = Design.Spacing.small
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        subtitle.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        return column
    }

    private func updateWords(_ status: SecretApprovalBroker.Status) {
        let current = now()
        if let code = status.enrollmentCode {
            codeLabel.stringValue = Self.grouped(code)
            codeSubtitle?.stringValue = L10n.format(
                "On the iPhone: Threading › Settings › Security › Face ID Approvals. The code works for %@ more.",
                Self.remaining(until: status.enrollmentExpiresAt, now: current))
        }
        if let enrollment = status.enrollment {
            deviceSubtitle?.stringValue = L10n.format(
                "Its key is %@. The iPhone shows the same key under Face ID Approvals.", enrollment.fingerprint)
        }
        if let title = status.pendingTitle {
            waitingSubtitle?.stringValue = L10n.format(
                "%@ — open Threading on the iPhone and approve it with Face ID. %@ left.",
                title, Self.remaining(until: status.pendingExpiresAt, now: current))
        }
        deviceButton.isEnabled = status.enabled
    }

    private func refresh() {
        guard task == nil else { return }
        task = Task { [weak self, broker] in
            let status = await broker.status()
            self?.apply(status)
            self?.task = nil
        }
    }

    @objc private func toggleEnabled() {
        RemoteAccessCoordinator.shared.setSecretApprovalsEnabled(enabledToggle.state == .on)
        refresh()
    }

    @objc private func copyCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.keyvaultCommand, forType: .string)
        copyButton.title = L10n.string("Copied")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.copyButton.title = L10n.string("Copy")
        }
    }

    @objc private func deviceAction() {
        let current = shape
        deviceButton.isEnabled = false
        task?.cancel()
        task = Task { [weak self, broker] in
            do {
                switch current {
                case .enrolled, .waiting: try await broker.forgetDevice()
                case .code: await broker.cancelEnrollment()
                default: _ = try await broker.beginEnrollment()
                }
            } catch {
                self?.deviceSubtitle?.stringValue = L10n.string("That did not work. Unlock this Mac and try again.")
            }
            let status = await broker.status()
            self?.apply(status)
            self?.task = nil
        }
    }
}
