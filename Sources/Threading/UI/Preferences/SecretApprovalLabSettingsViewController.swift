#if DEBUG
import AppKit

/// Local-only enrollment authority. Never exposed as a remotely mutable app setting.
final class SecretApprovalLabSettingsViewController: NSViewController {
    private let startButton = ThemedButton()
    private let stopButton = ThemedButton()
    private let githubButton = ThemedButton()
    private let tokenField = ThemedSecureField()
    private let storageLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private var task: Task<Void, Never>?

    override func loadView() {
        startButton.title = L10n.string("Start experiment")
        startButton.target = self
        startButton.action = #selector(start)
        startButton.setAccessibilityIdentifier("settings.secret-approval.start")
        githubButton.title = L10n.string("Start GitHub trial")
        githubButton.target = self
        githubButton.action = #selector(startGitHub)
        githubButton.setAccessibilityIdentifier("settings.secret-approval.github-start")
        githubButton.isEnabled = false
        tokenField.placeholderString = L10n.string("Fine-grained GitHub token")
        tokenField.setAccessibilityLabel(L10n.string("GitHub trial token"))
        tokenField.setAccessibilityIdentifier("settings.secret-approval.github-token")
        tokenField.translatesAutoresizingMaskIntoConstraints = false
        tokenField.widthAnchor.constraint(equalToConstant: SettingsUIDefaults.controlWidth).isActive = true
        tokenField.isEnabled = false
        storageLabel.applyFont(.body)
        storageLabel.textColor = Design.Text.secondary
        storageLabel.setAccessibilityIdentifier("settings.secret-approval.storage")
        stopButton.title = L10n.string("Stop experiment")
        stopButton.target = self
        stopButton.action = #selector(stop)
        stopButton.setAccessibilityIdentifier("settings.secret-approval.stop")
        startButton.isEnabled = false
        stopButton.isEnabled = false
        statusLabel.stringValue = L10n.string("Loading…")
        statusLabel.applyFont(.body)
        statusLabel.textColor = Design.Text.secondary
        statusLabel.setAccessibilityIdentifier("settings.secret-approval.status")
        view = SettingsCard(rows: [
            SettingsUI.row(title: "Face ID approval lab", subtitle:
                "Try the disposable credential first, or start a GitHub profile trial below. Requires a paired Face ID iPhone.",
                control: startButton),
            SettingsUI.fullRow(statusLabel),
            SettingsUI.fullRow(storageLabel),
            SettingsUI.row(title: "GitHub trial token", subtitle:
                "Create a separate fine-grained token with a short expiry, public repositories only and no additional permissions. Enter it here, never in a chat.",
                control: tokenField),
            SettingsUI.row(title: "Read my GitHub username", subtitle:
                "One Face ID approval permits one GET to https://api.github.com/user. Only your username returns to the phone. Redirects and automatic retries are refused.",
                control: githubButton),
            SettingsUI.row(title: "Revoke experiment", subtitle:
                "Deletes the locally stored trial token and test credential, and forgets the phone and pending approval. Revoke the token on GitHub when finished.",
                control: stopButton)
        ])
        task = Task { [weak self] in
            let status = await SecretApprovalLab.shared.status()
            self?.apply(status)
        }
    }

    func apply(_ status: SecretApprovalLab.LocalStatus) {
        if let code = status.enrollmentCode {
            statusLabel.stringValue = L10n.format(
                "Enter %@ in iPhone Settings → Developer → Face ID approval. Expires in five minutes; five attempts maximum.", code
            )
        } else {
            statusLabel.stringValue = status.enabled
                ? L10n.string("Experiment enabled. Stop and start again to enroll a different phone.")
                : L10n.string("Experiment off. Existing credentials are never accessed.")
        }
        startButton.isEnabled = !status.enabled
        githubButton.isEnabled = !status.enabled && status.protectedStorageAvailable
        tokenField.isEnabled = githubButton.isEnabled
        // Stop also removes a trial token left after an interrupted app run.
        stopButton.isEnabled = status.enabled || status.protectedStorageAvailable
        storageLabel.stringValue = status.protectedStorageAvailable
            ? L10n.string("GitHub tokens use this build’s protected, device-local Keychain. This experiment does not protect against a compromised Mac or modified app.")
            : L10n.string("GitHub trial unavailable: this build needs protected Keychain access and hardened signing without debugger access or foreign libraries. The disposable experiment remains available.")
    }

    @objc private func start() { perform(starting: true) }
    @objc private func stop() { perform(starting: false) }
    @objc private func startGitHub() { perform(starting: true, github: true) }

    private func perform(starting: Bool, github: Bool = false) {
        let token = github ? tokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        tokenField.stringValue = ""
        tokenField.isEnabled = false
        startButton.isEnabled = false
        githubButton.isEnabled = false
        stopButton.isEnabled = false
        task = Task { [weak self] in
            do {
                if starting {
                    let status = github
                        ? try await SecretApprovalLab.shared.enableGitHub(token: token)
                        : try await SecretApprovalLab.shared.enable()
                    self?.apply(status)
                } else {
                    try await SecretApprovalLab.shared.disable()
                    let status = await SecretApprovalLab.shared.status()
                    self?.apply(status)
                }
            } catch {
                let status = await SecretApprovalLab.shared.status()
                self?.apply(status)
                if case SecretApprovalGitHubFailure.invalidToken = error {
                    self?.statusLabel.stringValue = L10n.string("Enter a fine-grained GitHub token beginning with github_pat_. It is saved only when the trial starts.")
                } else {
                    self?.statusLabel.stringValue = L10n.string("The trial could not start or stop. Finish any request in progress, unlock the Mac, and check protected Keychain availability.")
                }
            }
        }
    }
}
#endif
