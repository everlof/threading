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

    // MARK: - Properties

    /// What `threading-ptyd` is holding, surveyed off the main actor. Injectable so the three
    /// interesting states — off, waiting for approval, holding sessions — are reachable in a test
    /// with no daemon anywhere.
    private let backgroundSessions: PTYHostBackgroundSessionsInventory

    private lazy var backgroundSessionsList = BackgroundSessionsListView(
        actions: BackgroundSessionsListView.Actions(
            stop: { [weak self] session in self?.stopBackgroundSession(session) },
            openLoginItems: { PTYHostRegistration.openLoginItemsSettings() }
        )
    )

    /// What turning the host off did, once it has been pressed. Nil until then: a row that
    /// explains an outcome nobody has caused yet is a row explaining nothing.
    private var backgroundHostRemoval: String?

    /// Whether `~/.local/bin/threading-ptyd` is installed, and whether that directory is on the
    /// user's `PATH`. Injectable for the inventory's reason: every part of the answer is
    /// specific to a machine, and a hosted test must not be able to write into a real home.
    private let commandLineTools: CommandLineToolsSurface

#if DEBUG || THREADING_INTERNAL
    /// Deliberately lives on Advanced rather than beside Hosted Direct: this changes which
    /// first-party service owns the account and push registration, not how Remote Access is
    /// connected. The compile condition keeps the whole surface out of public releases.
    private let hostedEnvironmentPopUp = ThemedPopUp()
#endif

    // MARK: - Initialization

    init(
        backgroundSessions: PTYHostBackgroundSessionsInventory = .init(),
        commandLineTools: CommandLineToolsSurface = CommandLineToolsSurface()
    ) {
        self.backgroundSessions = backgroundSessions
        self.commandLineTools = commandLineTools
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
    }

#if DEBUG
    /// Nil until the count has been read, which is what lets the row draw before it is known.
    private var outboxRecordCount: Int?
#endif

    override func viewDidLoad() {
        super.viewDidLoad()
#if DEBUG || THREADING_INTERNAL
        configureDeveloperSettings()
#endif
        rebuild()
        // The list is updated in place rather than by rebuilding the page: the survey's answer is
        // a value model, and the sessions in it are sized by another process.
        backgroundSessions.onChange = { [weak self] in
            guard let self else { return }
            backgroundSessionsList.show(backgroundSessions.state)
        }
        backgroundSessions.refresh()
        // The link's own state is read synchronously above; what the login shell exports takes a
        // login shell, so the row draws without it and gains the `PATH` sentence when it lands.
        commandLineTools.onChange = { [weak self] in self?.rebuild() }
        commandLineTools.readLoginShellPATH()
#if DEBUG
        refreshOutboxRecordCount()
#endif
    }

    // MARK: - Build

    private func rebuild() {
        view.subviews.forEach { $0.removeFromSuperview() }

        var sections: [NSView] = [
            SettingsUI.note(AdvancedStrings.explanation),
            SettingsUI.section(
                AdvancedStrings.localDiagnosticsSection,
                SettingsCard(rows: localDiagnosticsRows())
            ),
            SettingsUI.section(AdvancedStrings.locationsSection, SettingsCard(rows: locationRows())),
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
            SettingsUI.section(AdvancedStrings.authoritySection, SettingsCard(rows: [
                resetRow(
                    title: AdvancedStrings.managerRolesTitle,
                    detail: AdvancedStrings.managerRolesDetail,
                    button: AdvancedStrings.revokeManagersButton,
                    action: #selector(revokeAllManagerRoles)
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
            // Last in the ordinary page, and in the order the catalogue reports it. A settings
            // row's order is a wire fact — `AppSettingDefinitionTests` pins it — so a section
            // appended to the definitions is a section appended to the page, rather than two
            // orders to keep in step. It also reads correctly: this is the page about what
            // Threading keeps, and this is the part of it that keeps running when Threading does
            // not. Internal builds append their deliberately secluded developer section below.
            SettingsUI.section(
                AdvancedStrings.backgroundSessionsSection,
                backgroundSessionsSection()
            ),
            SettingsUI.note(AdvancedStrings.keptNote)
        ]
#if DEBUG || THREADING_INTERNAL
        sections.append(SettingsUI.section(
            AdvancedStrings.developerSettingsSection,
            SettingsCard(rows: developerSettingsRows())
        ))
#endif

        let page = SettingsUI.page(title: "Advanced", sections: sections)

        page.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: view.topAnchor),
            page.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            page.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    private func localDiagnosticsRows() -> [NSView] {
        let enabled = AppSettings.shared.localDiagnosticsEnabled
        let toggle = SettingsUI.toggle(
            isOn: enabled,
            target: self,
            action: #selector(localDiagnosticsChanged(_:))
        )
        toggle.setAccessibilityLabel(AdvancedStrings.localDiagnosticsTitle)

        let clearButton = SettingsUI.button(
            AdvancedStrings.clearDiagnosticsButton,
            target: self,
            action: #selector(clearLocalDiagnostics)
        )
        let count = MobileDiagnosticsCaptureStore.shared.captureCount
        clearButton.isEnabled = count > 0

        return [
            SettingsUI.row(
                title: AdvancedStrings.localDiagnosticsTitle,
                subtitle: AdvancedStrings.localDiagnosticsDetail,
                control: toggle
            ),
            row(
                title: AdvancedStrings.localDiagnosticsCacheTitle,
                detail: AdvancedStrings.localDiagnosticsCacheDetail(count: count),
                button: clearButton
            ),
        ]
    }

#if DEBUG || THREADING_INTERNAL
    private func configureDeveloperSettings() {
        for environment in RemoteHostedServiceEnvironment.allCases {
            let title: String
            switch environment {
            case .production: title = L10n.string("Production")
            case .development: title = L10n.string("Development")
            }
            hostedEnvironmentPopUp.addItem(
                ThemedMenuItem(title: title, representedValue: environment)
            )
        }
        hostedEnvironmentPopUp.target = self
        hostedEnvironmentPopUp.action = #selector(hostedServiceEnvironmentChanged)
        hostedEnvironmentPopUp.setAccessibilityIdentifier(Identifier.hostedEnvironment)
    }

    private func developerSettingsRows() -> [NSView] {
        hostedEnvironmentPopUp.selectItem(
            at: RemoteHostedServiceEnvironment.allCases.firstIndex(
                of: AppSettings.shared.remoteHostedServiceEnvironment
            ) ?? 0
        )
        hostedEnvironmentPopUp.isEnabled = !RemoteHostedServiceController
            .hasConfiguredEndpointOverride()

        return [SettingsUI.row(
            title: AdvancedStrings.hostedServiceTitle,
            subtitle: AdvancedStrings.hostedServiceDetail,
            control: hostedEnvironmentPopUp
        )]
    }

    @objc private func hostedServiceEnvironmentChanged() {
        guard let environment = hostedEnvironmentPopUp.selectedItem?.representedValue
                as? RemoteHostedServiceEnvironment else { return }
        RemoteAccessCoordinator.shared.setHostedServiceEnvironment(environment)
        hostedEnvironmentPopUp.selectItem(
            at: RemoteHostedServiceEnvironment.allCases.firstIndex(
                of: AppSettings.shared.remoteHostedServiceEnvironment
            ) ?? 0
        )
    }
#endif

    /// What has no window: the sessions `threading-ptyd` is holding, and the two controls that
    /// decide whether it holds any.
    ///
    /// The list leads and the controls follow, because the list is the subject — this is the
    /// surface a wedged detached agent is found on, and the switch beside it is the thing you
    /// reach for after reading it. The list is **not** a row inside the card: a `SettingsCard` is
    /// a retained stack of full-bleed rows, and a bounded table is not a row.
    private func backgroundSessionsSection() -> NSView {
        backgroundSessionsList.show(backgroundSessions.state)

        let card = SettingsCard(rows: [
            SettingsUI.row(
                title: AdvancedStrings.backgroundHostTitle,
                subtitle: AdvancedStrings.backgroundHostDetail,
                control: backgroundHostToggle()
            ),
            row(
                title: AdvancedStrings.backgroundHostOffTitle,
                detail: backgroundHostRemoval ?? AdvancedStrings.backgroundHostOffDetail,
                button: backgroundHostOffButton()
            ),
            commandLineToolRow(),
            SettingsUI.row(
                title: AdvancedStrings.commandLineToolsPATHTitle,
                subtitle: AdvancedStrings.commandLineToolsPATHDetail,
                control: commandLineToolsPATHToggle()
            )
        ])

        let stack = NSStackView(views: [backgroundSessionsList, card])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.medium
        for row in [backgroundSessionsList, card] as [NSView] {
            row.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
            row.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        }
        return stack
    }

    private func backgroundHostToggle() -> ThemedToggle {
        let toggle = SettingsUI.toggle(
            isOn: AppSettings.shared.ptyHostEnabled,
            target: self,
            action: #selector(backgroundHostChanged(_:))
        )
        toggle.setAccessibilityLabel(AdvancedStrings.backgroundHostTitle)
        return toggle
    }

    /// One row for the whole of "can I run this from a terminal": where the link is, whether it
    /// is there, whether the directory holding it is on `PATH`, and the one button that changes
    /// the answer.
    ///
    /// The button toggles rather than repeating **Install** at somebody who has already
    /// installed it: the row is a statement of the current state, so the control offers the
    /// only move left. It is disabled, and the detail says why, in the three cases where there
    /// is no move: the build ships no tool, and the two where the name is taken by something
    /// Threading did not put there and will not overwrite.
    private func commandLineToolRow() -> NSView {
        let status = commandLineTools.status
        let installed = status.isInstalled
        let button = SettingsUI.button(
            installed
                ? AdvancedStrings.commandLineToolRemoveButton
                : AdvancedStrings.commandLineToolInstallButton,
            target: self,
            action: #selector(toggleCommandLineTool)
        )
        switch status.placement {
        case .installed:
            button.isEnabled = true
        case .absent:
            button.isEnabled = commandLineTools.isShippedInBundle
        case .foreignLink, .occupied:
            button.isEnabled = false
        }

        return row(
            title: AdvancedStrings.commandLineToolTitle,
            detail: commandLineToolDetail(status),
            button: button
        )
    }

    private func commandLineToolDetail(_ status: CommandLineToolStatus) -> String {
        let link = abbreviate(status.linkURL)
        switch status.placement {
        case .occupied:
            return AdvancedStrings.commandLineToolOccupied(path: link)
        case .foreignLink(let destination):
            return AdvancedStrings.commandLineToolForeign(
                path: link,
                destination: (destination as NSString).abbreviatingWithTildeInPath
            )
        case .absent:
            guard commandLineTools.isShippedInBundle else {
                return AdvancedStrings.commandLineToolUnavailable
            }
            return AdvancedStrings.commandLineToolAbsent(path: link)
        case .installed:
            let installed = AdvancedStrings.commandLineToolInstalled(path: link)
            guard status.directoryIsOnPATH == false else { return installed }
            return installed + " " + AdvancedStrings.commandLineToolNotOnPATH(
                directory: abbreviate(commandLineTools.binaryDirectory),
                line: commandLineTools.profileLine
            )
        }
    }

    private func commandLineToolsPATHToggle() -> ThemedToggle {
        let toggle = SettingsUI.toggle(
            isOn: AppSettings.shared.prependsCommandLineToolsToPATH,
            target: self,
            action: #selector(commandLineToolsPATHChanged(_:))
        )
        toggle.setAccessibilityLabel(AdvancedStrings.commandLineToolsPATHTitle)
        return toggle
    }

    private func backgroundHostOffButton() -> ThemedButton {
        let button = SettingsUI.button(
            AdvancedStrings.backgroundHostOffButton,
            target: self,
            action: #selector(turnOffBackgroundHost)
        )
        // Nothing to turn off when it is already off. Disabled rather than dropped, so the row
        // still says what the control would do.
        button.isEnabled = AppSettings.shared.ptyHostEnabled
        return button
    }

    /// A path with a button that opens it. The path is the *detail*, not the title, because it
    /// is the long half and wrapping a title reads as a mistake.
    /// Where things are. The third row is Debug-only and is the whole developer-facing half of
    /// the report outbox: with no intake configured, reports accumulate in a folder nobody is
    /// collecting from, and a folder you cannot find is indistinguishable from a report that was
    /// never filed. A count and a way to open it is the entire feature — the triage is `cat`,
    /// or an agent pointed at the same path.
    private func locationRows() -> [NSView] {
        var rows = [
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
        ]
#if DEBUG
        let location = abbreviate(MacIssueReportOutbox.shared.recordsLocation)
        rows.append(locationRow(
            title: AdvancedStrings.outboxLocationTitle,
            detail: outboxRecordCount.map { L10n.format("%@ (%lld)", location, $0) } ?? location,
            action: #selector(revealOutbox)
        ))
#endif
        return rows
    }

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

#if DEBUG
    /// Read off the main actor and folded back in, because it is a directory listing whose size
    /// is the user's own doing: the page draws immediately with the path, and gains the count.
    private func refreshOutboxRecordCount() {
        Task { @MainActor [weak self] in
            let count = await MacIssueReportOutbox.shared.recordCount()
            guard let self, outboxRecordCount != count else { return }
            outboxRecordCount = count
            rebuild()
        }
    }

    @objc private func revealOutbox() {
        let location = MacIssueReportOutbox.shared.recordsLocation
        try? FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
        NSWorkspace.shared.open(location)
    }
#endif

    @objc private func revealPreferences() {
        reveal(AppDataLocations.preferencesFile)
    }

    @objc private func revealSupportDirectory() {
        reveal(AppDataLocations.supportDirectory)
    }

    @objc private func localDiagnosticsChanged(_ sender: ThemedToggle) {
        AppSettings.shared.localDiagnosticsEnabled = sender.state == .on
    }

    @objc private func clearLocalDiagnostics() {
        MobileDiagnosticsCaptureStore.shared.clearCaptures()
        rebuild()
    }

    /// Selects the item in its parent rather than opening it: a preferences plist opened is a
    /// plist editor nobody asked for, and the point is to show where the thing is.
    private func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Background Sessions

    @objc private func backgroundHostChanged(_ sender: ThemedToggle) {
        AppSettings.shared.ptyHostEnabled = sender.state == .on
        // A new answer to the switch retires the last turn-off's receipt: it described what
        // happened to a registration the user has just changed their mind about.
        backgroundHostRemoval = nil
        backgroundSessions.refresh()
        rebuild()
    }

    /// Drives the key off and says which way the removal went.
    ///
    /// The removal itself is not performed here. `PTYHostRegistrationCoordinator` follows the key
    /// and applies `PTYHostRegistration.removalDecision` off the main actor — unregister when the
    /// daemon holds nothing, leave it registered when it does, because `unregister()` **kills the
    /// running helper** and turning a preference off must not be a way to end somebody's turn.
    /// What this adds is the sentence: without it the two outcomes are indistinguishable, and the
    /// one that leaves a daemon running is the one a user needs told.
    @objc private func turnOffBackgroundHost() {
        let held = backgroundSessions.state.status.heldSessionCount
        AppSettings.shared.ptyHostEnabled = false
        switch PTYHostRegistration.removalDecision(heldSessions: held) {
        case .unregister:
            backgroundHostRemoval = AdvancedStrings.backgroundHostRemoved
        case .leave(let count):
            backgroundHostRemoval = AdvancedStrings.backgroundHostLeft(count: count)
        case .leaveUnanswered:
            backgroundHostRemoval = AdvancedStrings.backgroundHostLeftUnanswered
        }
        backgroundSessions.refresh()
        rebuild()
    }

    // MARK: - Command Line Tools

    /// Installs the link, or removes it when it is already there.
    ///
    /// No confirmation either way. Installing writes one symlink into the user's own directory
    /// and removing deletes the same one; neither ends anything, and the row it rebuilds into is
    /// the acknowledgement. A refusal is a sheet, because the two refusals both mean "something
    /// of yours is in the way" and that is not readable from the row alone.
    @objc private func toggleCommandLineTool() {
        do {
            if commandLineTools.status.isInstalled {
                try commandLineTools.remove()
            } else {
                try commandLineTools.install()
            }
        } catch {
            presentFailure(error)
        }
        rebuild()
    }

    @objc private func commandLineToolsPATHChanged(_ sender: ThemedToggle) {
        AppSettings.shared.prependsCommandLineToolsToPATH = sender.state == .on
    }

    private func stopBackgroundSession(_ session: PTYHostHeldSession) {
        guard ConfirmationAlert.ask(Self.stopConfirmation(sessionName: session.name)) else {
            return
        }
        backgroundSessions.stop(session)
    }

    /// Built apart from being asked, so a test can hold the wording to what Stop does without a
    /// modal.
    ///
    /// `.stopSessionProcess` is the register's existing entry for exactly this: the process can be
    /// started again, but not from anything in the app — the way back is the user's own next
    /// message — so Return sits on Cancel and the verb is on a destructive button.
    static func stopConfirmation(sessionName: String) -> ConfirmationRequest {
        ConfirmationRequest(
            prompt: .stopSessionProcess,
            title: AdvancedStrings.confirmStopTitle(name: sessionName),
            message: AdvancedStrings.confirmStopBody,
            confirmTitle: AdvancedStrings.stopButton
        )
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

    @objc private func revokeAllManagerRoles() {
        guard !(StateManager.shared.activeManagerSessionIDs() ?? []).isEmpty else { return }
        let request = ConfirmationRequest(
            prompt: .revokeAllManagerRoles,
            title: AdvancedStrings.confirmRevokeManagersTitle,
            message: AdvancedStrings.confirmRevokeManagersBody,
            confirmTitle: AdvancedStrings.revokeManagersConfirm,
            cancelTitle: L10n.string("Cancel")
        )
        guard ConfirmationAlert.ask(request) else { return }
        guard ControlGrantStore.shared.revokeAllManagers() else {
            presentFailure(ControlGrantStoreError.revocationFailed)
            return
        }
        rebuild()
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

    enum Identifier {
#if DEBUG || THREADING_INTERNAL
        static let hostedEnvironment = "settings.advanced.hosted-environment"
#endif
    }
}

// MARK: - Strings

enum AdvancedStrings {
    static var title: String { L10n.string("Advanced") }
    static var explanation: String {
        L10n.string("Where Threading keeps your settings and your work, and how to start over.")
    }

    static var localDiagnosticsSection: String { L10n.string("Local Diagnostics") }
    static var localDiagnosticsTitle: String {
        L10n.string("Allow paired-iPhone checkups")
    }
    static var localDiagnosticsDetail: String {
        L10n.string(
            "Accepts bounded connection evidence from a paired owner iPhone over the local "
                + "network. The iPhone has its own independent switch."
        )
    }
    static var localDiagnosticsCacheTitle: String { L10n.string("Saved iPhone evidence") }
    static func localDiagnosticsCacheDetail(count: Int) -> String {
        switch count {
        case 0:
            return L10n.string("No bounded captures stored on this Mac.")
        case 1:
            return L10n.string("1 bounded capture stored on this Mac.")
        default:
            return L10n.format("%lld bounded captures stored on this Mac.", count)
        }
    }
    static var clearDiagnosticsButton: String { L10n.string("Clear Evidence") }

    static var developerSettingsSection: String { L10n.string("Developer Settings") }
    static var hostedServiceTitle: String { L10n.string("Hosted service") }
    static var hostedServiceDetail: String {
        L10n.string(
            "Chooses which Threading service Hosted Direct uses. Development keeps accounts "
                + "and push registrations separate from Production; a launch URL override wins."
        )
    }

    static var locationsSection: String { L10n.string("Locations") }
    static var outboxLocationTitle: String { L10n.string("Report Outbox") }
    static var settingsLocationTitle: String { L10n.string("Settings") }
    static var dataLocationTitle: String { L10n.string("Projects, sessions and caches") }
    static var reveal: String { L10n.string("Reveal") }

    static var backgroundSessionsSection: String { L10n.string("Background Sessions") }
    static var backgroundHostTitle: String { L10n.string("Background host") }
    static var backgroundHostDetail: String {
        L10n.string(
            "Runs each agent's terminal in a helper that keeps working while Threading is closed, "
                + "and hands the sessions back on the next launch. Off while this is still being "
                + "proven: an agent started by the helper may not inherit Threading's file access."
        )
    }
    static var backgroundHostOffTitle: String { L10n.string("Turn off the background host") }
    static var backgroundHostOffDetail: String {
        L10n.string(
            "Stops using the helper and removes it from Login Items. Sessions it is still holding "
                + "keep running; it is removed at the next launch that finds it idle."
        )
    }
    static var backgroundHostOffButton: String { L10n.string("Turn Off") }
    static var backgroundHostRemoved: String {
        L10n.string("The background host is off and has been removed from Login Items.")
    }
    static func backgroundHostLeft(count: Int) -> String {
        count == 1
            ? L10n.string(
                "Threading has stopped using the background host. One session is still running "
                    + "under it, so it stays in Login Items and is removed at the next launch "
                    + "that finds it idle."
            )
            : L10n.format(
                "Threading has stopped using the background host. %lld sessions are still "
                    + "running under it, so it stays in Login Items and is removed at the next "
                    + "launch that finds it idle.",
                count
            )
    }

    static var backgroundHostLeftUnanswered: String {
        L10n.string(
            "Threading has stopped using the background host. It stays in Login Items until "
                + "Threading can verify that no sessions are still running under it."
        )
    }
    static var stopButton: String { L10n.string("Stop") }
    static func confirmStopTitle(name: String) -> String {
        L10n.format("Stop “%@”?", name)
    }
    static var confirmStopBody: String {
        L10n.string(
            "The agent ends and whatever it is working on right now is lost. The conversation is "
                + "kept and can be resumed from the sidebar."
        )
    }

    static var commandLineToolTitle: String { L10n.string("Command line tool") }
    static func commandLineToolAbsent(path: String) -> String {
        L10n.format(
            "Install adds %@, so threading-ptyd runs in any terminal and keeps working after "
                + "Threading is updated or moved.",
            path
        )
    }
    static func commandLineToolInstalled(path: String) -> String {
        L10n.format("Installed at %@.", path)
    }
    static func commandLineToolNotOnPATH(directory: String, line: String) -> String {
        L10n.format(
            "%1$@ is not on your PATH. Add this line to your shell profile: %2$@",
            directory,
            line
        )
    }
    static func commandLineToolForeign(path: String, destination: String) -> String {
        L10n.format(
            "%1$@ already points at %2$@, so Threading left it alone.",
            path,
            destination
        )
    }
    static func commandLineToolOccupied(path: String) -> String {
        L10n.format("Something else is already at %@, so Threading left it alone.", path)
    }
    static var commandLineToolUnavailable: String {
        L10n.string("This build does not include the tool yet, so there is nothing to install.")
    }
    static var commandLineToolInstallButton: String { L10n.string("Install") }
    static var commandLineToolRemoveButton: String { L10n.string("Remove") }

    static var commandLineToolsPATHTitle: String { L10n.string("Tools in Threading's terminals") }
    static var commandLineToolsPATHDetail: String {
        L10n.string(
            "Puts Threading's command line tools on the PATH of every terminal and agent it "
                + "starts, so threading-ptyd works in them without changing your shell profile. "
                + "Terminals already open keep the PATH they started with."
        )
    }

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

    static var authoritySection: String { L10n.string("Agent Authority") }
    static var managerRolesTitle: String { L10n.string("Manager roles") }
    static var managerRolesDetail: String {
        L10n.string(
            "Immediately removes every manager grant and releases all chats they supervise. "
                + "Regular chat tools are unchanged."
        )
    }
    static var revokeManagersButton: String { L10n.string("Revoke All…") }
    static var confirmRevokeManagersTitle: String { L10n.string("Revoke all manager roles?") }
    static var confirmRevokeManagersBody: String {
        L10n.string(
            "Every manager loses its extra tools immediately, and every supervised chat is "
                + "released. You can make individual chats managers again later."
        )
    }
    static var revokeManagersConfirm: String { L10n.string("Revoke All Roles") }

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

private enum ControlGrantStoreError: LocalizedError {
    case revocationFailed

    var errorDescription: String? {
        L10n.string(
            "One or more manager roles could not be revoked. Roles already revoked remain revoked."
        )
    }
}
