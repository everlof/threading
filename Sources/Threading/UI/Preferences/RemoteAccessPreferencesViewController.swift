import AppKit
import AuthenticationServices

/// Remote Access gets a page of its own because it is a setup flow, not a behavioural toggle.
///
/// General used to hide the feature below several unrelated sections and then put the actual
/// pairing instructions in an alert. This page keeps the whole journey visible: opt in, watch
/// the listener and selected transport come up, scan the code, and understand the authority.
final class RemoteAccessPreferencesViewController: NSViewController {

    // MARK: - Controls

    private let remoteAccessToggle = ThemedToggle()
    private let connectionModeControl = ThemedSegmentedControl()
    private let ownerRelayFallbackToggle = ThemedToggle()
    private let keepRelayReadyToggle = ThemedToggle()
    private let hostedSignInButton = HostedServiceSignInButton()
    private let hostedSignOutButton = ThemedButton()
    private let hostedDeleteAccountButton = ThemedButton()
    private let hostedStatusLabel = NSTextField(labelWithString: "")
    private let hostedAccountControls = NSStackView()
    private let inputControlDefault = ThemedSegmentedControl()
    private let phoneReportWorkspacePopUp = ThemedPopUp()
    private let openLocallyButton = ThemedButton()
    private let pairingActionButton = ThemedButton()
    private let pairedDevicesStack = NSStackView()

    private let statusGlyph = NSTextField(labelWithString: "●")
    private let statusSpinner = ThemedSpinner()
    private let statusTitle = NSTextField(labelWithString: "")
    private let statusDetail = NSTextField(wrappingLabelWithString: "")

    private let pairingTitle = NSTextField(labelWithString: "")
    private let pairingSpinner = ThemedSpinner()
    private let pairingDetail = NSTextField(wrappingLabelWithString: "")
    private let pairingCode = NSImageView()
    private let pairingNote = NSTextField(wrappingLabelWithString: "")
    private let pairingRemedyButton = ThemedButton()
    /// The page the pairing panel's remedy button opens, held here for the same reason
    /// `tailscaleActionURL` is: a target-action carries no payload. Cleared on every update so a
    /// stale page can never outlive the failure that offered it.
    private var pairingRemedyURL: URL?
    private let hostedSpinner = ThemedSpinner()
    private var tailscaleStepGlyphs: [NSTextField] = []
    private var tailscaleStepSpinners: [ThemedSpinner] = []
    private var tailscaleStepDetails: [NSTextField] = []
    private var tailscaleStepActions: [ThemedButton] = []
    private var tailscaleReadinessSection: NSView?
    /// The tailnet approval page behind the readiness card's action button, held here because
    /// the button's target-action carries no payload. Cleared on every readiness update so a
    /// stale URL can never outlive the issue that offered it.
    private var tailscaleActionURL: URL?

    private var copiedReset: DispatchWorkItem?
    private var pairedDeviceIDs: [String] = []
    private let hostedAppleSignIn = RemoteHostedAppleSignIn()
    private var hostedAccountTask: Task<Void, Never>?
    private var hostedAccountError: String?
    private let appEvents = AppEventObservations()

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
        configureControls()
        buildPage()
        refresh()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Construction

    private func configureControls() {
        remoteAccessToggle.target = self
        remoteAccessToggle.action = #selector(remoteAccessChanged)
        remoteAccessToggle.setAccessibilityIdentifier("settings.remote-access.enabled")

        connectionModeControl.configure(
            titles: RemoteAccessConnectionMode.allCases.map(\.settingsTitle),
            selectedIndex: RemoteAccessConnectionMode.allCases.firstIndex(
                of: AppSettings.shared.remoteAccessConnectionMode
            ) ?? 0
        )
        connectionModeControl.onSelect = { index in
            guard RemoteAccessConnectionMode.allCases.indices.contains(index) else { return }
            RemoteAccessCoordinator.shared.setConnectionMode(
                RemoteAccessConnectionMode.allCases[index]
            )
        }
        connectionModeControl.setAccessibilityIdentifier("settings.remote-access.connection-mode")
        connectionModeControl.translatesAutoresizingMaskIntoConstraints = false
        connectionModeControl.widthAnchor.constraint(
            equalToConstant: SettingsUIDefaults.wideSegmentedControlWidth
        ).isActive = true

        ownerRelayFallbackToggle.target = self
        ownerRelayFallbackToggle.action = #selector(ownerRelayFallbackChanged)
        ownerRelayFallbackToggle.setAccessibilityIdentifier(
            "settings.remote-access.owner-relay-fallback"
        )
        keepRelayReadyToggle.target = self
        keepRelayReadyToggle.action = #selector(keepRelayReadyChanged)
        keepRelayReadyToggle.setAccessibilityIdentifier(
            "settings.remote-access.keep-relay-ready"
        )

        hostedSignInButton.configure(target: self, action: #selector(signInHostedService))
        hostedSignInButton.setAccessibilityIdentifier("settings.remote-access.hosted-sign-in")
        hostedSignOutButton.title = L10n.string("Sign Out")
        hostedSignOutButton.target = self
        hostedSignOutButton.action = #selector(signOutHostedService)
        hostedSignOutButton.setAccessibilityIdentifier("settings.remote-access.hosted-sign-out")
        hostedDeleteAccountButton.title = L10n.string("Delete Account")
        hostedDeleteAccountButton.target = self
        hostedDeleteAccountButton.action = #selector(deleteHostedServiceAccount)
        hostedDeleteAccountButton.setAccessibilityIdentifier(
            "settings.remote-access.hosted-delete-account"
        )
        hostedStatusLabel.applyFont(.subheading)
        hostedStatusLabel.textColor = Design.Text.secondary
        hostedSpinner.setAccessibilityLabel(L10n.string("Connecting…"))
        hostedAccountControls.orientation = .horizontal
        hostedAccountControls.alignment = .centerY
        hostedAccountControls.spacing = Design.Spacing.small
        hostedAccountControls.addArrangedSubview(hostedSpinner)
        hostedAccountControls.addArrangedSubview(hostedStatusLabel)
        hostedAccountControls.addArrangedSubview(hostedSignInButton)
        hostedAccountControls.addArrangedSubview(hostedSignOutButton)
        hostedAccountControls.addArrangedSubview(hostedDeleteAccountButton)

        inputControlDefault.configure(
            titles: RemoteInputControlDefault.allCases.map(\.title),
            selectedIndex: RemoteInputControlDefault.allCases.firstIndex(
                of: AppSettings.shared.remoteInputControlDefault
            ) ?? 0
        )
        inputControlDefault.onSelect = { index in
            guard RemoteInputControlDefault.allCases.indices.contains(index) else { return }
            AppSettings.shared.remoteInputControlDefault =
                RemoteInputControlDefault.allCases[index]
        }
        inputControlDefault.setAccessibilityIdentifier(
            "settings.remote-access.input-control-default"
        )
        inputControlDefault.translatesAutoresizingMaskIntoConstraints = false
        inputControlDefault.widthAnchor.constraint(
            equalToConstant: SettingsUIDefaults.wideSegmentedControlWidth
        ).isActive = true

        for policy in PhoneReportWorkspacePolicy.allCases {
            phoneReportWorkspacePopUp.addItem(
                ThemedMenuItem(title: policy.settingsTitle, representedValue: policy)
            )
        }
        phoneReportWorkspacePopUp.selectItem(
            at: PhoneReportWorkspacePolicy.allCases
                .firstIndex(of: AppSettings.shared.phoneReportWorkspace) ?? 0
        )
        phoneReportWorkspacePopUp.target = self
        phoneReportWorkspacePopUp.action = #selector(phoneReportWorkspaceChanged)
        phoneReportWorkspacePopUp.setAccessibilityIdentifier(
            "settings.remote-access.phone-report-workspace"
        )

        openLocallyButton.title = L10n.string("Open in Browser")
        openLocallyButton.target = self
        openLocallyButton.action = #selector(openLocally)
        openLocallyButton.setAccessibilityIdentifier("settings.remote-access.open-local")

        pairingActionButton.target = self
        pairingActionButton.action = #selector(pairingAction)
        pairingActionButton.setAccessibilityIdentifier("settings.remote-access.pair")

        pairingRemedyButton.target = self
        pairingRemedyButton.action = #selector(openPairingRemedy)
        pairingRemedyButton.isHidden = true
        pairingRemedyButton.setAccessibilityIdentifier("settings.remote-access.pairing-remedy")

        statusGlyph.applyFont(.body)
        statusGlyph.setContentHuggingPriority(.required, for: .horizontal)

        statusTitle.applyFont(.body)
        statusTitle.textColor = Design.Text.label
        statusTitle.setAccessibilityIdentifier("settings.remote-access.status")

        statusDetail.applyFont(.subheading)
        statusDetail.textColor = Design.Text.secondary

        // A card's title, at body scale: the page already has one heading, and a second one
        // inside a card is what made this read as a poster rather than as a settings card.
        pairingTitle.applyFont(.emphasizedBody)
        pairingTitle.textColor = Design.Text.label
        pairingTitle.setAccessibilityIdentifier("settings.remote-access.pairing-title")
        pairingDetail.applyFont(.subheading)
        pairingDetail.textColor = Design.Text.secondary
        pairingDetail.setAccessibilityIdentifier("settings.remote-access.pairing-detail")

        pairingCode.imageScaling = .scaleProportionallyUpOrDown
        pairingCode.translatesAutoresizingMaskIntoConstraints = false
        pairingCode.setAccessibilityIdentifier("settings.remote-access.qr-code")

        pairingNote.applyFont(.subheading)
        pairingNote.textColor = Design.Text.secondary
        pairingNote.setAccessibilityIdentifier("settings.remote-access.pairing-note")

        pairedDevicesStack.orientation = .vertical
        pairedDevicesStack.alignment = .leading
        pairedDevicesStack.spacing = 0

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(remoteAccessStatusDidChange),
            name: RemoteAccessCoordinator.statusDidChange,
            object: nil
        )

        // The pairing code is drawn from the palette, and an `NSImage` handed to an image view
        // is not repainted by a repaint of the view — so it is rebuilt rather than refreshed.
        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in self?.refresh() }
    }

    private func buildPage() {
        let readiness = SettingsUI.section(
            "Tailscale Readiness",
            tailscaleReadinessCard()
        )
        tailscaleReadinessSection = readiness
        let page = SettingsUI.page(title: "Remote Access", sections: [
            SettingsUI.note(
                "Continue chats from Threading on iPhone or a private browser. "
                    + "Nothing is exposed until you turn it on."
            ),
            SettingsUI.section("Connection", connectionCard()),
            readiness,
            SettingsUI.section("Set Up Your iPhone", pairingCard()),
            SettingsUI.section("Sharing & Security", securityCard()),
            SettingsUI.note(
                "Remote Access publishes only Threading’s authenticated remote surface. "
                    + "MCP, extension services and other local ports stay on this Mac."
            )
        ])
        page.setAccessibilityIdentifier("settings.remote-access.page")
        page.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: view.topAnchor),
            page.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            page.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    private func connectionCard() -> SettingsCard {
        SettingsCard(rows: [
            SettingsUI.row(
                title: "Remote Access",
                subtitle: "Turning it off closes every connection and shared-chat link. "
                    + "Your explicitly paired devices remain paired for the next time.",
                control: remoteAccessToggle
            ),
            SettingsUI.row(
                title: "Connection",
                subtitle: "Relay supports ordinary share links. Tailscale keeps access inside "
                    + "your private tailnet. Private + Sharing uses Tailscale for pairing and "
                    + "starts the public relay only when it is needed.",
                control: connectionModeControl
            ),
            SettingsUI.row(
                title: "Hosted Direct",
                subtitle: "Uses Threading’s service only to introduce this Mac and iPhone, then "
                    + "prefers a direct encrypted connection. TURN is used only when direct "
                    + "network traversal cannot connect.",
                control: hostedAccountControls
            ),
            SettingsUI.row(
                title: "Owner Relay Fallback",
                subtitle: "In Private + Sharing, let your paired devices use Relay when "
                    + "Tailscale cannot be reached. Off fails closed on the private path.",
                control: ownerRelayFallbackToggle
            ),
            SettingsUI.row(
                title: "Keep Sharing Relay Ready",
                subtitle: "Start the public relay immediately instead of waiting until you "
                    + "create a public share link.",
                control: keepRelayReadyToggle
            ),
            SettingsUI.fullRow(connectionStatusRow())
        ])
    }

    private func tailscaleReadinessCard() -> SettingsCard {
        let titles = [
            L10n.string("Tailscale installed"),
            L10n.string("Signed in and running"),
            L10n.string("Private HTTPS endpoint"),
        ]
        var rows: [NSView] = []
        for title in titles {
            let glyph = NSTextField(labelWithString: "–")
            glyph.applyFont(.body)
            glyph.setContentHuggingPriority(.required, for: .horizontal)
            let spinner = ThemedSpinner()

            let titleLabel = NSTextField(labelWithString: title)
            titleLabel.applyFont(.body)
            titleLabel.textColor = Design.Text.label
            let detail = NSTextField(wrappingLabelWithString: "")
            detail.applyFont(.subheading)
            detail.textColor = Design.Text.secondary

            let labels = NSStackView(views: [titleLabel, detail])
            labels.orientation = .vertical
            labels.alignment = .leading
            labels.spacing = Design.Spacing.hairline
            let action = ThemedButton(
                title: "",
                target: self,
                action: #selector(openTailscaleAction)
            )
            action.isHidden = true
            action.setContentHuggingPriority(.required, for: .horizontal)
            action.setContentCompressionResistancePriority(.required, for: .horizontal)
            let row = NSStackView(views: [markSlot(glyph: glyph, spinner: spinner), labels, action])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = Design.Spacing.medium
            // `.fill` plus the low-hugging label column pushes the action button to the
            // trailing edge; without it the gravity-area default parks the button beside
            // whichever detail sentence is shortest.
            row.distribution = .fill
            labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
            row.edgeInsets = NSEdgeInsets(
                top: Design.Spacing.medium,
                left: Design.Spacing.inset,
                bottom: Design.Spacing.medium,
                right: Design.Spacing.inset
            )
            rows.append(row)
            tailscaleStepGlyphs.append(glyph)
            tailscaleStepSpinners.append(spinner)
            tailscaleStepDetails.append(detail)
            tailscaleStepActions.append(action)
        }
        return SettingsCard(rows: rows)
    }

    /// One fixed-width slot holding a step's glyph and its in-flight spinner, so swapping the
    /// mark never shifts the text beside it — `SessionStatusIndicator`'s reserved-slot rule.
    /// The spinner hides itself while it is not animating; the glyph is hidden by the state
    /// that animates the spinner.
    private func markSlot(glyph: NSTextField, spinner: ThemedSpinner) -> NSView {
        let slot = NSView()
        slot.translatesAutoresizingMaskIntoConstraints = false
        glyph.translatesAutoresizingMaskIntoConstraints = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        slot.addSubview(glyph)
        slot.addSubview(spinner)
        NSLayoutConstraint.activate([
            slot.widthAnchor.constraint(
                equalToConstant: spinner.intrinsicContentSize.width
            ),
            glyph.topAnchor.constraint(equalTo: slot.topAnchor),
            glyph.bottomAnchor.constraint(equalTo: slot.bottomAnchor),
            glyph.centerXAnchor.constraint(equalTo: slot.centerXAnchor),
            spinner.centerXAnchor.constraint(equalTo: slot.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: slot.centerYAnchor)
        ])
        return slot
    }

    private func connectionStatusRow() -> NSView {
        let labels = NSStackView(views: [statusTitle, statusDetail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = Design.Spacing.hairline
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [
            markSlot(glyph: statusGlyph, spinner: statusSpinner),
            labels,
            openLocallyButton
        ])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Design.Spacing.medium
        return row
    }

    /// The pairing card: the code at the leading edge, everything it needs read beside it.
    ///
    /// It was a poster — a centred title with a phone glyph over a centred instruction, a plate
    /// floating in the middle of the card, a centred two-line warning ending in an orphan, and a
    /// button under all of it. Nothing else in the app is laid out that way, and the centring is
    /// what made the warning read as a caption rather than as the thing it says it is. The code
    /// sits on the same column every row of every card starts on, and the title, the
    /// instruction, the ownership note and the action stack against its trailing side.
    private func pairingCard() -> SettingsCard {
        let heading = NSStackView(views: [pairingTitle, pairingSpinner])
        heading.orientation = .horizontal
        heading.alignment = .centerY
        heading.spacing = Design.Spacing.small

        let actions = NSStackView(views: [pairingRemedyButton, pairingActionButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = Design.Spacing.small

        let text = NSStackView(views: [heading, pairingDetail, pairingNote, actions])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = Design.Spacing.medium
        // A vertical stack aligned `.leading` gives each arranged view its *fitting* width, and
        // a wrapping label has none to give — so both paragraphs are pinned to the column they
        // sit in, or they wrap at whatever width they happen to prefer.
        text.setHuggingPriority(.defaultLow, for: .horizontal)
        // A stack has no intrinsic height of its own, so beside a 168pt code it was handed the
        // code's height and spread its four rows through it: the title floated a quarter of the
        // way down the card and the gaps came out 41, 19 and 15 points where all three are
        // meant to be `medium`. Hugging vertically is what makes the column its content's
        // height and the spacing the token that states it.
        for stack in [heading, actions, text] {
            stack.setHuggingPriority(.required, for: .vertical)
        }

        let content = NSStackView(views: [pairingCode, text])
        content.orientation = .horizontal
        // The code is a block; the text beside it starts at its first line.
        content.alignment = .top
        content.distribution = .fill
        content.spacing = Design.Spacing.large

        NSLayoutConstraint.activate([
            pairingCode.widthAnchor.constraint(equalToConstant: PairingCardLayout.codeSide),
            pairingCode.heightAnchor.constraint(equalTo: pairingCode.widthAnchor),
            pairingDetail.widthAnchor.constraint(equalTo: text.widthAnchor),
            pairingNote.widthAnchor.constraint(equalTo: text.widthAnchor)
        ])
        pairingCode.setContentHuggingPriority(.required, for: .horizontal)
        pairingCode.setContentCompressionResistancePriority(.required, for: .horizontal)

        return SettingsCard(rows: [SettingsUI.fullRow(content)])
    }

    enum PairingCardLayout {
        /// The side the card gives the pairing code, which is also the side the image is drawn
        /// at — the plate `PairingCodeImage` draws *is* the quiet zone, so the plate is never
        /// wider than the code needs, and drawing at the displayed size keeps the modules from
        /// being resampled on the way down.
        ///
        /// 49 modules (41 plus the four-module quiet zone on each side) at 3.4 points each, so
        /// nearly 7 pixels per module on a 2x display against the 3.02 that
        /// `PairingCodeImageTests` measured as the floor for a tilted, softened decode.
        static let codeSide: CGFloat = 168
    }

    private func securityCard() -> SettingsCard {
        SettingsCard(rows: [
            SettingsUI.row(
                title: "New shared chats",
                subtitle: "Collaborative lets everyone with reply access send. Focused starts "
                    + "with the Mac owner in control. You can switch a live chat at any time.",
                control: inputControlDefault
            ),
            SettingsUI.row(
                title: "Reports from your phone",
                subtitle: "Shake to report, then Send to Mac, starts a chat here while you are "
                    + "away from it. Its own workspace keeps that chat out of the checkout you "
                    + "left open. Available for a Git project whose agent has session tools.",
                control: phoneReportWorkspacePopUp
            ),
            SettingsUI.detailRow(
                symbol: "lock.shield",
                title: "Your own devices",
                detail: "The QR code is owner access. A paired device can see and manage your "
                    + "chats, send prompts, and review permission requests."
            ),
            SettingsUI.detailRow(
                symbol: "person.2",
                title: "Other people",
                detail: "Use Share Chat… from that chat’s ⋯ menu. It grants only the selected "
                    + "chat, with view, collaboration and approval rights chosen separately."
            ),
            pairedDevicesStack
        ])
    }

    // MARK: - State

    @objc private func remoteAccessStatusDidChange(_ notification: Notification) {
        refresh()
    }

    private func refresh() {
        copiedReset?.cancel()
        copiedReset = nil

        let coordinator = RemoteAccessCoordinator.shared
        remoteAccessToggle.state = AppSettings.shared.remoteAccessEnabled ? .on : .off
        connectionModeControl.selectedIndex = RemoteAccessConnectionMode.allCases.firstIndex(
            of: AppSettings.shared.remoteAccessConnectionMode
        ) ?? 0
        let usesHybrid = AppSettings.shared.remoteAccessConnectionMode == .tailscaleAndRelay
        ownerRelayFallbackToggle.state = AppSettings.shared.remoteAccessAllowsOwnerRelayFallback
            ? .on : .off
        ownerRelayFallbackToggle.isEnabled = usesHybrid
        keepRelayReadyToggle.state = AppSettings.shared.remoteAccessKeepsRelayReady ? .on : .off
        keepRelayReadyToggle.isEnabled = usesHybrid
        inputControlDefault.selectedIndex = RemoteInputControlDefault.allCases.firstIndex(
            of: AppSettings.shared.remoteInputControlDefault
        ) ?? 0
        phoneReportWorkspacePopUp.selectItem(
            at: PhoneReportWorkspacePolicy.allCases
                .firstIndex(of: AppSettings.shared.phoneReportWorkspace) ?? 0
        )
        tailscaleReadinessSection?.isHidden =
            AppSettings.shared.remoteAccessConnectionMode == .relay
        updateTailscaleReadiness(coordinator.tailscaleReadiness)
        openLocallyButton.isHidden = coordinator.localURL == nil
        openLocallyButton.isEnabled = coordinator.localURL != nil
        rebuildPairedDevices(coordinator.pairedOwnerDevices, error: coordinator.ownerDevicePersistenceError)
        updateHostedAccount(coordinator)

        switch coordinator.status {
        case .disabled:
            let selectedConnection = AppSettings.shared.remoteAccessConnectionMode == .relay
                ? L10n.string("the HTTPS relay")
                : L10n.string("your Tailscale tailnet")
            updateConnection(
                title: L10n.string("Off"),
                detail: L10n.string("This Mac is not reachable from another device."),
                color: Design.Text.tertiary
            )
            updatePairing(
                title: L10n.string("Connect your iPhone"),
                detail: L10n.format(
                    "Turn on Remote Access. Threading will start a local mirror and connect it to %@.",
                    selectedConnection
                ),
                action: L10n.string("Turn On Remote Access"),
                actionEnabled: true,
                prominent: true
            )

        case .starting:
            updateConnection(
                title: L10n.string("Starting"),
                detail: L10n.string("Preparing the private listener on this Mac…"),
                color: Design.Status.warning,
                busy: true
            )
            updatePairing(
                title: L10n.string("Preparing your connection"),
                detail: L10n.string("This usually takes only a few seconds."),
                action: L10n.string("Starting…"),
                actionEnabled: false,
                prominent: false,
                busy: true
            )

        case .listening(let port):
            let transport = AppSettings.shared.remoteAccessConnectionMode == .relay
                ? coordinator.relayStatus
                : coordinator.tailscaleStatus
            let readiness = AppSettings.shared.remoteAccessConnectionMode == .relay
                ? nil
                : coordinator.tailscaleReadiness
            applyListeningState(
                connection: RemoteConnectionStatusPresentation.resolve(
                    mode: AppSettings.shared.remoteAccessConnectionMode,
                    relay: coordinator.relayStatus,
                    tailscale: coordinator.tailscaleStatus,
                    tailscaleReadiness: coordinator.tailscaleReadiness,
                    allowsOwnerRelayFallback:
                        AppSettings.shared.remoteAccessAllowsOwnerRelayFallback,
                    localPort: port
                ),
                card: RemotePairingCardState.resolve(
                    ownerDevicePersistenceError: coordinator.ownerDevicePersistenceError,
                    pairingCodePayload: coordinator.pairingCodePayload,
                    transport: transport,
                    tailscaleReadiness: readiness
                )
            )

        case .failed(let reason):
            updateConnection(
                title: L10n.string("Couldn’t start"),
                detail: L10n.format("The private listener failed (%@).", reason),
                color: Design.Status.negative
            )
            updatePairing(
                title: L10n.string("Remote Access needs attention"),
                detail: L10n.string(
                    "Retry without leaving Settings. Existing launch links remain revoked."
                ),
                action: L10n.string("Try Again"),
                actionEnabled: true,
                prominent: true
            )
        }
    }

    private func updateHostedAccount(_ coordinator: RemoteAccessCoordinator) {
        // A running account task is the sign-in/out exchange; `.connecting` is the service
        // itself coming up. Both are work in progress the row would otherwise state as text
        // beside controls that merely went quiet.
        hostedSpinner.isAnimating = hostedAccountTask != nil
            || coordinator.hostedServiceState == .connecting
        hostedSignInButton.isHidden = true
        hostedSignOutButton.isHidden = true
        hostedDeleteAccountButton.isHidden = true
        hostedSignInButton.isEnabled = hostedAccountTask == nil
        hostedSignOutButton.isEnabled = hostedAccountTask == nil
        hostedDeleteAccountButton.isEnabled = hostedAccountTask == nil

        if let hostedAccountError {
            hostedStatusLabel.stringValue = hostedAccountError
            if coordinator.canIssueHostedDeviceCredentials {
                hostedSignOutButton.isHidden = false
                hostedDeleteAccountButton.isHidden = false
            } else {
                hostedSignInButton.isHidden = false
            }
            return
        }
        switch coordinator.hostedServiceState {
        case .stopped:
            if coordinator.canIssueHostedDeviceCredentials {
                hostedStatusLabel.stringValue = L10n.string("Signed in")
                hostedSignOutButton.isHidden = false
                hostedDeleteAccountButton.isHidden = false
            } else {
                hostedStatusLabel.stringValue = L10n.string("Not signed in")
                hostedSignInButton.isHidden = false
            }
        case .notConfigured:
            hostedStatusLabel.stringValue = L10n.string("Not configured in this build")
        case .signInRequired:
            hostedStatusLabel.stringValue = L10n.string("Sign in to enable zero-setup access")
            hostedSignInButton.isHidden = false
        case .connecting:
            hostedStatusLabel.stringValue = L10n.string("Connecting…")
        case .ready:
            hostedStatusLabel.stringValue = L10n.string("Ready")
            hostedSignOutButton.isHidden = false
            hostedDeleteAccountButton.isHidden = false
        case .unavailable:
            hostedStatusLabel.stringValue = L10n.string("Temporarily unavailable")
            if coordinator.canIssueHostedDeviceCredentials {
                hostedSignOutButton.isHidden = false
                hostedDeleteAccountButton.isHidden = false
            } else {
                hostedSignInButton.isHidden = false
            }
        }
    }

    @objc private func signInHostedService() {
        guard hostedAccountTask == nil, let window = view.window else { return }
        hostedAccountError = nil
        refresh()
        hostedAccountTask = Task { [weak self] in
            guard let self else { return }
            do {
                let authorization = try await hostedAppleSignIn.authorize(from: window)
                try await RemoteAccessCoordinator.shared.signInHostedService(
                    identityToken: authorization.identityToken,
                    authorizationCode: authorization.authorizationCode,
                    rawNonce: authorization.rawNonce
                )
            } catch let error as ASAuthorizationError where error.code == .canceled {
                // Closing Apple's sheet is an ordinary cancellation, not a service failure.
            } catch {
                hostedAccountError = L10n.string("Sign in failed. Try again.")
            }
            hostedAccountTask = nil
            refresh()
        }
    }

    @objc private func signOutHostedService() {
        guard hostedAccountTask == nil else { return }
        hostedAccountError = nil
        refresh()
        hostedAccountTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await RemoteAccessCoordinator.shared.signOutHostedService()
            } catch {
                hostedAccountError = L10n.string("Sign out failed. Try again.")
            }
            hostedAccountTask = nil
            refresh()
        }
    }

    @objc private func deleteHostedServiceAccount() {
        guard hostedAccountTask == nil else { return }
        let request = ConfirmationRequest(
            prompt: .deleteHostedServiceAccount,
            title: L10n.string("Delete hosted account?"),
            message: L10n.string(
                "This permanently removes your Threading service account, revokes direct "
                    + "access for every paired iPhone, and signs this Mac out. Local chats and "
                    + "settings stay on this Mac."
            ),
            confirmTitle: L10n.string("Delete Account")
        )
        guard ConfirmationAlert.ask(request) else { return }
        hostedAccountError = nil
        refresh()
        hostedAccountTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await RemoteAccessCoordinator.shared.deleteHostedServiceAccount()
            } catch {
                hostedAccountError = L10n.string("Account deletion failed. Try again.")
            }
            hostedAccountTask = nil
            refresh()
        }
    }

    /// Applies one coherent listening-state page: the status row and the pairing card together.
    ///
    /// Both come from values a test can build, because both states this page needed fixing in —
    /// a door that failed and a door that is still coming up — take a live tailnet to reach, and
    /// what shipped was reviewed in neither.
    func applyListeningState(
        connection: RemoteConnectionStatusPresentation,
        card: RemotePairingCardState
    ) {
        apply(connection)
        applyPairingCard(card)
    }

    private func apply(_ connection: RemoteConnectionStatusPresentation) {
        updateConnection(
            title: connection.title,
            detail: connection.detail,
            color: color(for: connection.tone),
            busy: connection.isBusy
        )
    }

    private func color(for tone: RemoteConnectionStatusPresentation.Tone) -> NSColor {
        switch tone {
        case .ready: return Design.Status.positive
        case .attention, .working: return Design.Status.warning
        }
    }

    private func applyPairingCard(_ state: RemotePairingCardState) {
        switch state {
        case .keychainUnavailable:
            updatePairing(
                title: L10n.string("Pairing unavailable"),
                detail: L10n.string(
                    "Threading could not read its paired-device Keychain item. It will not "
                        + "overwrite that item or issue a credential it cannot preserve."
                ),
                action: L10n.string("Pairing Unavailable"),
                actionEnabled: false,
                prominent: false
            )

        case .ready(let payload):
            updatePairing(
                title: L10n.string("Scan with your iPhone"),
                detail: L10n.string(
                    "Open Threading on iPhone, choose Pair a Mac, then scan this one-time code."
                ),
                action: L10n.string("Copy Pairing Link"),
                actionEnabled: true,
                prominent: false,
                pairingPayload: payload
            )

        case .connectionUnavailable(let reason, let remedy):
            // The reason is the panel's own, not a pointer at the readiness row above it.
            updatePairing(
                title: L10n.string("Private connection unavailable"),
                detail: reason,
                action: L10n.string("Retry Connection"),
                actionEnabled: true,
                // The fix is the button to press when there is one; Retry stands beside it.
                prominent: remedy == nil,
                remedy: remedy
            )

        case .preparing(let detail):
            updatePairing(
                title: L10n.string("Preparing your pairing code"),
                detail: detail ?? L10n.string(
                    "The QR code appears here as soon as the selected connection is ready."
                ),
                action: L10n.string("Connecting…"),
                actionEnabled: false,
                prominent: false,
                busy: true
            )

        case .codeUnavailable:
            updatePairing(
                title: L10n.string("Pairing code unavailable"),
                detail: L10n.string(
                    "The connection is ready, but Threading could not build a pairing code for "
                        + "it. Retrying starts the connection again."
                ),
                action: L10n.string("Retry Connection"),
                actionEnabled: true,
                prominent: true
            )
        }
    }

    private func updateConnection(
        title: String,
        detail: String,
        color: NSColor,
        busy: Bool = false
    ) {
        statusTitle.stringValue = title
        statusDetail.stringValue = detail
        statusGlyph.textColor = color
        statusGlyph.isHidden = busy
        statusSpinner.setAccessibilityLabel(title)
        statusSpinner.isAnimating = busy
    }

    /// The readiness card, drawn from the same values the unavailable panel reads.
    ///
    /// Every issue used to restate all three rows here, which is how a new one could land with
    /// no mark at all and how the row's copy drifted from the sentence the transport reported.
    /// The issue names its step and its own line; the rows above it are met and the rows below
    /// it are waiting, by construction.
    func updateTailscaleReadiness(_ readiness: TailscaleReadiness) {
        guard tailscaleStepGlyphs.count == TailscaleReadinessStep.allCases.count,
              tailscaleStepSpinners.count == TailscaleReadinessStep.allCases.count,
              tailscaleStepDetails.count == TailscaleReadinessStep.allCases.count,
              tailscaleStepActions.count == TailscaleReadinessStep.allCases.count else { return }

        tailscaleActionURL = nil
        tailscaleStepActions.forEach { $0.isHidden = true }

        func setStep(_ step: TailscaleReadinessStep, glyph: String, color: NSColor, detail: String) {
            let index = step.rawValue
            tailscaleStepGlyphs[index].stringValue = glyph
            tailscaleStepGlyphs[index].textColor = color
            tailscaleStepGlyphs[index].isHidden = false
            tailscaleStepSpinners[index].isAnimating = false
            tailscaleStepDetails[index].stringValue = detail
        }
        func offerAction(_ step: TailscaleReadinessStep, title: String, url: URL) {
            let index = step.rawValue
            tailscaleActionURL = url
            tailscaleStepActions[index].title = title
            tailscaleStepActions[index].setAccessibilityLabel(title)
            tailscaleStepActions[index].isHidden = false
        }
        func pending(_ step: TailscaleReadinessStep, _ detail: String) {
            setStep(step, glyph: "–", color: Design.Text.tertiary, detail: detail)
        }
        func working(_ step: TailscaleReadinessStep, _ detail: String) {
            let index = step.rawValue
            tailscaleStepGlyphs[index].isHidden = true
            tailscaleStepSpinners[index].setAccessibilityLabel(detail)
            tailscaleStepSpinners[index].isAnimating = true
            tailscaleStepDetails[index].stringValue = detail
        }
        func ready(_ step: TailscaleReadinessStep, _ detail: String) {
            setStep(step, glyph: "✓", color: Design.Status.positive, detail: detail)
        }
        func attention(_ step: TailscaleReadinessStep, _ detail: String) {
            setStep(step, glyph: "!", color: Design.Status.warning, detail: detail)
        }
        func met(upTo step: TailscaleReadinessStep) {
            if step.rawValue > TailscaleReadinessStep.installed.rawValue {
                ready(.installed, L10n.string("Tailscale is installed."))
            }
            if step.rawValue > TailscaleReadinessStep.signedIn.rawValue {
                ready(.signedIn, L10n.string("This Mac is connected to your tailnet."))
            }
        }
        func waiting(after step: TailscaleReadinessStep) {
            for later in TailscaleReadinessStep.allCases where later.rawValue > step.rawValue {
                pending(later, L10n.string("Waiting for Tailscale."))
            }
        }

        switch readiness {
        case .notChecked:
            pending(.installed, L10n.string("Checked when Remote Access turns on."))
            pending(.signedIn, L10n.string("Waiting for the installation check."))
            pending(.privateEndpoint, L10n.string("Waiting for Tailscale."))
        case .checking:
            // One `tailscale status` answers both installation and the tailnet, so the two
            // steps are genuinely in flight together.
            working(.installed, L10n.string("Looking for Tailscale…"))
            working(.signedIn, L10n.string("Checking your tailnet status…"))
            pending(.privateEndpoint, L10n.string("Waiting for Tailscale."))
        case .publishing:
            met(upTo: .privateEndpoint)
            // The same sentence the status row and the pairing panel are showing: this step is
            // where the wait actually is, and it was the one saying least about it.
            working(
                .privateEndpoint,
                readiness.startupStatement?.detail
                    ?? L10n.string("Publishing Threading privately…")
            )
        case .ready(let origin):
            met(upTo: .privateEndpoint)
            setStep(
                .privateEndpoint,
                glyph: "✓",
                color: Design.Status.positive,
                detail: L10n.format("Ready at %@.", origin.host ?? origin.absoluteString)
            )
        case .actionRequired(let issue, let actionURL):
            met(upTo: issue.step)
            attention(issue.step, issue.rowDetail)
            waiting(after: issue.step)
            if let actionURL, let title = issue.remedyActionTitle {
                offerAction(issue.step, title: title, url: actionURL)
            }
        }
    }

    private func rebuildPairedDevices(
        _ devices: [RemoteAccessCoordinator.PairedOwnerDevice],
        error: String?
    ) {
        pairedDevicesStack.arrangedSubviews.forEach {
            pairedDevicesStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        pairedDeviceIDs = devices.map(\.id)

        if let error {
            addPairedDeviceRow(SettingsUI.row(
                title: L10n.string("Paired devices unavailable"),
                subtitle: error,
                localizes: false
            ))
            return
        }
        guard !devices.isEmpty else {
            addPairedDeviceRow(SettingsUI.row(
                title: L10n.string("Paired devices"),
                subtitle: L10n.string("No durable owner devices are paired yet."),
                localizes: false
            ))
            return
        }

        for (index, device) in devices.enumerated() {
            if index > 0 {
                let divider = SeparatorView()
                pairedDevicesStack.addArrangedSubview(divider)
                divider.leadingAnchor.constraint(
                    equalTo: pairedDevicesStack.leadingAnchor,
                    constant: Design.Spacing.inset
                ).isActive = true
                divider.trailingAnchor.constraint(
                    equalTo: pairedDevicesStack.trailingAnchor
                ).isActive = true
            }
            let button = ThemedButton(
                title: L10n.string("Revoke"),
                target: self,
                action: #selector(revokePairedDevice(_:))
            )
            button.tag = index
            button.setAccessibilityLabel(
                L10n.format("Revoke %@", device.displayName)
            )
            let date = device.lastSeenAt ?? device.pairedAt
            let detail = device.lastSeenAt == nil
                ? L10n.format("Paired %@", Self.relative.localizedString(
                    for: date,
                    relativeTo: Date()
                ))
                : L10n.format("Last seen %@", Self.relative.localizedString(
                    for: date,
                    relativeTo: Date()
                ))
            addPairedDeviceRow(SettingsUI.row(
                title: device.displayName,
                subtitle: detail,
                control: button,
                localizes: false
            ))
        }
    }

    private func addPairedDeviceRow(_ row: NSView) {
        pairedDevicesStack.addArrangedSubview(row)
        row.leadingAnchor.constraint(equalTo: pairedDevicesStack.leadingAnchor).isActive = true
        row.trailingAnchor.constraint(equalTo: pairedDevicesStack.trailingAnchor).isActive = true
    }

    private func updatePairing(
        title: String,
        detail: String,
        action: String,
        actionEnabled: Bool,
        prominent: Bool,
        busy: Bool = false,
        remedy: RemotePairingRemedy? = nil,
        pairingPayload: String? = nil
    ) {
        pairingTitle.stringValue = title
        pairingSpinner.setAccessibilityLabel(title)
        pairingSpinner.isAnimating = busy
        pairingDetail.stringValue = detail
        pairingActionButton.title = action
        pairingActionButton.isEnabled = actionEnabled
        pairingActionButton.isProminent = prominent

        pairingRemedyURL = remedy?.url
        pairingRemedyButton.isHidden = remedy == nil
        pairingRemedyButton.isProminent = remedy != nil
        if let remedy {
            pairingRemedyButton.title = remedy.title
            pairingRemedyButton.setAccessibilityLabel(remedy.title)
        }

        // Drawn at the side the card gives it: an `NSImage` scaled into an image view is
        // resampled, and a resampled module edge is the one thing this artwork cannot spare.
        let code = pairingPayload.flatMap {
            PairingCodeImage.make(for: $0, side: PairingCardLayout.codeSide)
        }
        pairingCode.image = code
        pairingCode.isHidden = code == nil
        pairingNote.isHidden = code == nil
        pairingNote.stringValue = code == nil
            ? ""
            : L10n.string(
                "Only scan this owner code on a device you control. It can access every chat "
                    + "on this Mac. The code expires after one successful pairing; that device "
                    + "stays paired until you revoke it here."
            )
    }

    // MARK: - Actions

    @objc private func remoteAccessChanged() {
        RemoteAccessCoordinator.shared.setEnabled(remoteAccessToggle.state == .on)
        refresh()
    }

    @objc private func ownerRelayFallbackChanged() {
        RemoteAccessCoordinator.shared.setAllowsOwnerRelayFallback(
            ownerRelayFallbackToggle.state == .on
        )
        refresh()
    }

    @objc private func keepRelayReadyChanged() {
        RemoteAccessCoordinator.shared.setKeepsRelayReady(keepRelayReadyToggle.state == .on)
        refresh()
    }

    /// Recorded on the Mac and read again the next time a phone asks what is available, so a
    /// report already on its way keeps the answer it was given.
    @objc private func phoneReportWorkspaceChanged() {
        guard let value = phoneReportWorkspacePopUp.selectedItem?.representedValue
            as? PhoneReportWorkspacePolicy else { return }
        AppSettings.shared.phoneReportWorkspace = value
    }

    @objc private func openLocally() {
        guard let url = RemoteAccessCoordinator.shared.localURL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openTailscaleAction() {
        guard let tailscaleActionURL else { return }
        NSWorkspace.shared.open(tailscaleActionURL)
    }

    @objc private func openPairingRemedy() {
        guard let pairingRemedyURL else { return }
        NSWorkspace.shared.open(pairingRemedyURL)
    }

    @objc private func pairingAction() {
        let coordinator = RemoteAccessCoordinator.shared

        if let payload = coordinator.pairingCodePayload {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(payload, forType: .string)
            pairingActionButton.title = L10n.string("Copied")
            pairingActionButton.isEnabled = false

            let reset = DispatchWorkItem { [weak self] in self?.refresh() }
            copiedReset = reset
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: reset)
            return
        }

        switch coordinator.status {
        case .disabled:
            coordinator.setEnabled(true)
        case .failed:
            restart()
        case .listening:
            coordinator.retryTransports()
        case .starting:
            break
        }
        refresh()
    }

    private func restart() {
        let coordinator = RemoteAccessCoordinator.shared
        coordinator.setEnabled(false)
        coordinator.setEnabled(true)
    }

    @objc private func revokePairedDevice(_ sender: ThemedButton) {
        guard pairedDeviceIDs.indices.contains(sender.tag),
              let device = RemoteAccessCoordinator.shared.pairedOwnerDevices.first(where: {
                  $0.id == pairedDeviceIDs[sender.tag]
              }) else { return }
        let request = ConfirmationRequest(
            prompt: .revokePairedDevice,
            title: L10n.format("Revoke %@?", device.displayName),
            message: L10n.string(
                "This device loses owner access immediately. Pair it again with a new code if "
                    + "you want to restore access."
            ),
            confirmTitle: L10n.string("Revoke")
        )
        guard ConfirmationAlert.ask(request) else { return }
        _ = RemoteAccessCoordinator.shared.revokeOwnerDevice(device.id)
        refresh()
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

}
