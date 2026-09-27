import AppKit

/// The Mac's own switch and enrollment for Face ID approvals. Local only: none of it is a
/// remotely mutable setting, and the phone that approves can neither enable nor enroll itself.
final class SecretApprovalSettingsViewController: NSViewController {
    // MARK: - Properties

    private let enabledToggle = ThemedToggle()
    private let deviceButton = ThemedButton()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let storageLabel = NSTextField(wrappingLabelWithString: "")
    private var status: SecretApprovalBroker.Status?
    private var task: Task<Void, Never>?
    private let broker: SecretApprovalBroker

    // MARK: - Lifecycle

    init(broker: SecretApprovalBroker = .shared) {
        self.broker = broker
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
        deviceButton.isEnabled = false
        deviceButton.title = L10n.string("Enroll iPhone")
        deviceButton.setAccessibilityIdentifier("settings.secret-approvals.device")
        for label in [statusLabel, storageLabel] {
            label.applyFont(.body)
            label.textColor = Design.Text.secondary
        }
        statusLabel.stringValue = L10n.string("Loading…")
        statusLabel.setAccessibilityIdentifier("settings.secret-approvals.status")
        storageLabel.setAccessibilityIdentifier("settings.secret-approvals.storage")
        view = SettingsCard(rows: [
            SettingsUI.row(title: "Approve with Face ID on iPhone", subtitle:
                "Lets keyvault ask your paired iPhone instead of this Mac’s Touch ID. The phone shows what is asked and who asks; nothing it approves is stored on this Mac.",
                control: enabledToggle),
            SettingsUI.row(title: "iPhone", subtitle:
                "One phone approves. Enroll it with a code shown here; forgetting it refuses anything waiting.",
                control: deviceButton),
            SettingsUI.fullRow(statusLabel),
            SettingsUI.fullRow(storageLabel)
        ])
        refresh()
    }

    // MARK: - Public Methods

    func apply(_ status: SecretApprovalBroker.Status) {
        self.status = status
        enabledToggle.state = status.enabled ? .on : .off
        deviceButton.isEnabled = status.enabled
        deviceButton.title = status.enrollment == nil ? L10n.string("Enroll iPhone") : L10n.string("Forget iPhone")
        if !status.enabled {
            statusLabel.stringValue = L10n.string("Off. keyvault uses this Mac’s Touch ID and passphrase only.")
        } else if let code = status.enrollmentCode {
            statusLabel.stringValue = L10n.format(
                "On iPhone, open Settings → Face ID Approvals and enter %@. The code works for five minutes and five attempts.", code)
        } else if let enrollment = status.enrollment {
            statusLabel.stringValue = status.pendingTitle.map {
                L10n.format("Waiting for the iPhone to approve: %@", $0)
            } ?? L10n.format("Enrolled iPhone key %@. Check that the phone shows the same key.", enrollment.fingerprint)
        } else {
            statusLabel.stringValue = L10n.string("No iPhone enrolled yet. Remote Access must be on and the phone paired.")
        }
        storageLabel.stringValue = KeychainStoragePolicy.storageDescription(isShellReachable: status.isShellReachable)
    }

    /// Waits for the status read that loading started; for tests and rendered evidence.
    func refreshed() async { await task?.value }

    // MARK: - Private Methods

    private func refresh() {
        task = Task { [weak self, broker] in
            let status = await broker.status()
            self?.apply(status)
        }
    }

    @objc private func toggleEnabled() {
        RemoteAccessCoordinator.shared.setSecretApprovalsEnabled(enabledToggle.state == .on)
        refresh()
    }

    @objc private func deviceAction() {
        let enrolled = status?.enrollment != nil
        deviceButton.isEnabled = false
        task = Task { [weak self, broker] in
            do {
                if enrolled {
                    try await broker.forgetDevice()
                } else {
                    _ = try await broker.beginEnrollment()
                }
            } catch {
                self?.statusLabel.stringValue = L10n.string("That did not work. Unlock this Mac and try again.")
            }
            let status = await broker.status()
            self?.apply(status)
        }
    }
}
