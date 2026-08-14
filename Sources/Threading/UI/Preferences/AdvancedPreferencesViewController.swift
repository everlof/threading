import AppKit

/// Advanced preferences: where Threading keeps what it remembers, and how to put it back.
///
/// Two things a settings screen usually has no answer for. **Where is this stored** is asked by
/// anyone backing up, syncing, or reporting a bug, and the honest answer is two paths rather
/// than a sentence — so they are shown and revealed rather than described. **Start over** is
/// asked when something is wrong that no individual setting explains, and the alternative today
/// is quitting and deleting directories by hand, which is both harder and less safe than doing
/// it here: this knows which two locations are Threading's own and leaves everything written
/// into another program's folder alone.
///
/// The two resets are separate because their blast radii are: one loses a themes-and-toggles
/// configuration, the other loses every conversation. Offering only the wider one would make
/// the narrow fix cost the whole history.
final class AdvancedPreferencesViewController: NSViewController {

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        rebuild()
    }

    // MARK: - Build

    private func rebuild() {
        view.subviews.forEach { $0.removeFromSuperview() }

        let page = SettingsUI.page(title: "Advanced", sections: [
            SettingsUI.note(AdvancedStrings.explanation),
            SettingsUI.section(AdvancedStrings.locationsSection, SettingsCard(rows: [
                locationRow(
                    title: AdvancedStrings.settingsLocationTitle,
                    detail: abbreviate(AppDataLocations.preferencesFile),
                    action: #selector(revealPreferences)
                ),
                locationRow(
                    title: AdvancedStrings.dataLocationTitle,
                    detail: abbreviate(AppDataLocations.supportDirectory),
                    action: #selector(revealSupportDirectory)
                )
            ])),
            SettingsUI.section(AdvancedStrings.tourSection, SettingsCard(rows: [
                resetRow(
                    title: AdvancedStrings.tourTitle,
                    detail: AdvancedStrings.tourDetail,
                    button: AdvancedStrings.tourButton,
                    action: #selector(showWelcomeTour)
                ),
                resetRow(
                    title: AdvancedStrings.tourFlagTitle,
                    detail: OnboardingState.isRecorded
                        ? AdvancedStrings.tourFlagRecordedDetail
                        : AdvancedStrings.tourFlagClearedDetail,
                    button: AdvancedStrings.tourFlagButton,
                    action: #selector(clearOnboardingFlag)
                )
            ])),
            SettingsUI.section(AdvancedStrings.resetSection, SettingsCard(rows: [
                resetRow(
                    title: AdvancedStrings.resetSettingsTitle,
                    detail: AdvancedStrings.resetSettingsDetail,
                    button: AdvancedStrings.resetSettingsButton,
                    action: #selector(resetSettings)
                ),
                resetRow(
                    title: AdvancedStrings.resetEverythingTitle,
                    detail: AdvancedStrings.resetEverythingDetail,
                    button: AdvancedStrings.resetEverythingButton,
                    action: #selector(resetEverything)
                )
            ])),
            SettingsUI.note(AdvancedStrings.keptNote)
        ])

        page.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: view.topAnchor),
            page.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            page.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    /// A path with a button that opens it. The path is the *detail*, not the title, because it
    /// is the long half and wrapping a title reads as a mistake.
    private func locationRow(
        title: String,
        detail: String,
        action: Selector
    ) -> NSView {
        row(
            title: title,
            detail: detail,
            button: SettingsUI.button(AdvancedStrings.reveal, target: self, action: action)
        )
    }

    private func resetRow(
        title: String,
        detail: String,
        button: String,
        action: Selector
    ) -> NSView {
        row(
            title: title,
            detail: detail,
            button: SettingsUI.button(button, target: self, action: action)
        )
    }

    private func row(
        title: String,
        detail: String,
        button: ThemedButton
    ) -> NSView {
        let titleField = NSTextField(labelWithString: title)
        titleField.applyFont(.body)
        titleField.textColor = Design.Text.label

        let detailField = NSTextField(wrappingLabelWithString: detail)
        detailField.applyFont(.subheading)
        detailField.textColor = Design.Text.secondary

        let labels = NSStackView(views: [titleField, detailField])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = Design.Spacing.hairline
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)

        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)

        let content = NSStackView(views: [labels, button])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.distribution = .fill
        content.spacing = Design.Spacing.medium

        let container = SettingsUI.fullRow(content)
        // Hand-built rather than `SettingsUI.row`, so the search anchor is stated here.
        SettingsRowAnchor.tag(container, title: title)
        return container
    }

    /// `~` rather than `/Users/<name>`, which is both shorter and the form a user can paste.
    private func abbreviate(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    // MARK: - Actions

    @objc private func revealPreferences() {
        reveal(AppDataLocations.preferencesFile)
    }

    @objc private func revealSupportDirectory() {
        reveal(AppDataLocations.supportDirectory)
    }

    /// Selects the item in its parent rather than opening it: a preferences plist opened is a
    /// plist editor nobody asked for, and the point is to show where the thing is.
    private func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func showWelcomeTour() {
        AppDelegate.shared?.presentOnboarding()
    }

    /// Non-destructive, so no confirmation: the only consequence is a walkthrough on the next
    /// launch. The rebuilt row's detail line is the acknowledgement.
    @objc private func clearOnboardingFlag() {
        OnboardingState.clear()
        rebuild()
    }

    @objc private func resetSettings() {
        reset(.settings, title: AdvancedStrings.confirmSettingsTitle,
              message: AdvancedStrings.confirmSettingsBody,
              confirm: AdvancedStrings.resetSettingsButton)
    }

    @objc private func resetEverything() {
        reset(.everything, title: AdvancedStrings.confirmEverythingTitle,
              message: AdvancedStrings.confirmEverythingBody,
              confirm: AdvancedStrings.resetEverythingButton)
    }

    /// Confirms, resets, and restarts.
    ///
    /// The restart is not a convenience. Every store here is a singleton holding its state in
    /// memory, so a running app carries on from what it read at launch and would write that
    /// back over the reset at the first save — see `AppRelaunch.PreparedRelaunch.commit`, which
    /// is also why nothing is offered here to reset *without* restarting.
    private func reset(
        _ scope: AppDataReset.Scope,
        title: String,
        message: String,
        confirm: String
    ) {
        let request = ConfirmationRequest(
            prompt: .resetAppData,
            title: title,
            message: message,
            confirmTitle: confirm,
            cancelTitle: L10n.string("Cancel")
        )
        guard ConfirmationAlert.ask(request) else { return }

        do {
            // The order the sequence has to run in — Keychain first, directories second — lives
            // in `AppDataResetFlow`, because the recovery surface offers this too and a second
            // copy of it is how one screen quietly stops clearing a credential.
            try AppDataResetFlow.perform(scope, at: Date())
        } catch {
            // Nothing has been restarted, so the app is still usable and saying so is the whole
            // response. A reset that half-happened is the case this must not hide.
            ThreadingLogger.app.error(
                "Reset failed: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            presentFailure(error)
        }
    }

    private func presentFailure(_ error: Error) {
        let alert = ThemedAlert()
        alert.alertStyle = .warning
        alert.messageText = AdvancedStrings.resetFailedTitle
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: L10n.string("OK"))
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

// MARK: - Strings

enum AdvancedStrings {
    static var title: String { L10n.string("Advanced") }
    static var explanation: String {
        L10n.string("Where Threading keeps your settings and your work, and how to start over.")
    }

    static var locationsSection: String { L10n.string("Locations") }
    static var settingsLocationTitle: String { L10n.string("Settings") }
    static var dataLocationTitle: String { L10n.string("Projects, sessions and caches") }
    static var reveal: String { L10n.string("Reveal") }

    static var tourSection: String { L10n.string("Welcome Tour") }
    static var tourTitle: String { L10n.string("First-launch walkthrough") }
    static var tourDetail: String {
        L10n.string(
            "Theme, discovered accounts, conversations to import, and notifications — the "
                + "same walkthrough a fresh install opens with."
        )
    }
    static var tourButton: String { L10n.string("Show Again…") }

    static var tourFlagTitle: String { L10n.string("Run at next launch") }
    static var tourFlagRecordedDetail: String {
        L10n.string(
            "Clears the completed flag, so the next launch opens with the walkthrough — the "
                + "true first-launch path, main window deferred and all."
        )
    }
    static var tourFlagClearedDetail: String {
        L10n.string("Cleared — the walkthrough opens on the next launch.")
    }
    static var tourFlagButton: String { L10n.string("Clear Flag") }

    static var resetSection: String { L10n.string("Start Over") }
    static var resetSettingsTitle: String { L10n.string("Reset settings") }
    static var resetSettingsDetail: String {
        L10n.string(
            "Puts themes, profiles and every preference back to their defaults. "
                + "Your projects, sessions and conversations are untouched."
        )
    }
    static var resetSettingsButton: String { L10n.string("Reset Settings…") }

    static var resetEverythingTitle: String { L10n.string("Reset everything") }
    static var resetEverythingDetail: String {
        L10n.string(
            "The above, plus every project, session, conversation, cache and paired owner device. "
                + "Threading restarts as if newly installed."
        )
    }
    static var resetEverythingButton: String { L10n.string("Reset Everything…") }

    static var confirmSettingsTitle: String { L10n.string("Reset all settings?") }
    static var confirmSettingsBody: String {
        L10n.string(
            "Threading will restart with its default settings. Your projects and conversations "
                + "are kept. The current settings are saved into a dated folder beside your "
                + "data, so nothing is thrown away."
        )
    }
    static var confirmEverythingTitle: String { L10n.string("Reset everything?") }
    static var confirmEverythingBody: String {
        L10n.string(
            "Threading will restart as if newly installed: no projects, no sessions, no "
                + "conversations. Files are moved into a dated folder beside your data so they "
                + "can be recovered by hand. Paired-owner credentials are revoked and cannot "
                + "be recovered from that folder."
        )
    }

    static var keptNote: String {
        L10n.string(
            "A reset moves file state into “Threading Resets” rather than deleting it. Reset "
                + "Everything also revokes paired-owner credentials; Reset Settings keeps them. "
                + "Agent logins and anything the Claude or Codex CLIs keep stay where they are."
        )
    }

    static var resetFailedTitle: String { L10n.string("Could not reset") }
}
