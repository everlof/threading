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
    private let openLocallyButton = ThemedButton()
    private let pairingActionButton = ThemedButton()
    private let pairedDevicesStack = NSStackView()

    private let statusGlyph = NSTextField(labelWithString: "●")
    private let statusSpinner = ThemedSpinner()
    private let statusTitle = NSTextField(labelWithString: "")
    private let statusDetail = NSTextField(wrappingLabelWithString: "")

    private let pairingSymbol = NSImageView()
    private let pairingTitle = NSTextField(labelWithString: "")
    private let pairingSpinner = ThemedSpinner()
    private let pairingDetail = NSTextField(wrappingLabelWithString: "")
    private let pairingCode = NSImageView()
    private let pairingInstruction = NSTextField(wrappingLabelWithString: "")
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

        openLocallyButton.title = L10n.string("Open in Browser")
        openLocallyButton.target = self
        openLocallyButton.action = #selector(openLocally)
        openLocallyButton.setAccessibilityIdentifier("settings.remote-access.open-local")

        pairingActionButton.target = self
        pairingActionButton.action = #selector(pairingAction)
        pairingActionButton.setAccessibilityIdentifier("settings.remote-access.pair")

        statusGlyph.applyFont(.body)
        statusGlyph.setContentHuggingPriority(.required, for: .horizontal)

        statusTitle.applyFont(.body)
        statusTitle.textColor = Design.Text.label
        statusTitle.setAccessibilityIdentifier("settings.remote-access.status")

        statusDetail.applyFont(.subheading)
        statusDetail.textColor = Design.Text.secondary

        pairingSymbol.imageScaling = .scaleProportionallyDown
        pairingSymbol.contentTintColor = Design.Text.secondary
        pairingSymbol.translatesAutoresizingMaskIntoConstraints = false

        pairingTitle.applyFont(.heading)
        pairingTitle.textColor = Design.Text.label
        pairingDetail.applyFont(.subheading)
        pairingDetail.textColor = Design.Text.secondary
        pairingDetail.alignment = .center

        pairingCode.imageScaling = .scaleProportionallyUpOrDown
        pairingCode.translatesAutoresizingMaskIntoConstraints = false
        pairingCode.setAccessibilityIdentifier("settings.remote-access.qr-code")

        pairingInstruction.applyFont(.subheading)
        pairingInstruction.textColor = Design.Text.secondary
        pairingInstruction.alignment = .center

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

    private func pairingCard() -> SettingsCard {
        pairingSymbol.image = symbol("iphone")

        let heading = NSStackView(views: [pairingSymbol, pairingTitle, pairingSpinner])
        heading.orientation = .horizontal
        heading.alignment = .centerY
        heading.spacing = Design.Spacing.small

        let content = NSStackView(views: [
            heading,
            pairingDetail,
            pairingCode,
            pairingInstruction,
            pairingActionButton
        ])
        content.orientation = .vertical
        content.alignment = .centerX
        content.spacing = Design.Spacing.medium
        content.edgeInsets = NSEdgeInsets(
            top: Design.Spacing.small,
            left: Design.Spacing.medium,
            bottom: Design.Spacing.small,
            right: Design.Spacing.medium
        )

        NSLayoutConstraint.activate([
            pairingSymbol.widthAnchor.constraint(equalToConstant: Design.Symbol.control + 4),
            pairingSymbol.heightAnchor.constraint(equalTo: pairingSymbol.widthAnchor),
            pairingCode.widthAnchor.constraint(equalToConstant: PairingCodeImage.preferredSide),
            pairingCode.heightAnchor.constraint(equalTo: pairingCode.widthAnchor),
            pairingDetail.widthAnchor.constraint(equalTo: content.widthAnchor),
            pairingInstruction.widthAnchor.constraint(equalTo: content.widthAnchor)
        ])

        return SettingsCard(rows: [SettingsUI.fullRow(content)])
    }

    private func securityCard() -> SettingsCard {
        SettingsCard(rows: [
            SettingsUI.row(
                title: "New shared chats",
                subtitle: "Collaborative lets everyone with reply access send. Focused starts "
                    + "with the Mac owner in control. You can switch a live chat at any time.",
                control: inputControlDefault
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

    private func symbol(_ name: String) -> NSImage {
        SettingsUI.symbolImage(name)
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
            updateConnectionForTransports(coordinator, localPort: port)
            updatePairingForTransport(coordinator)

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

    private func updateConnectionForTransports(
        _ coordinator: RemoteAccessCoordinator,
        localPort: UInt16
    ) {
        let mode = AppSettings.shared.remoteAccessConnectionMode
        let relay = coordinator.relayStatus
        let tailscale = coordinator.tailscaleStatus

        if mode == .tailscaleAndRelay,
           case .connected = relay,
           case .connected = tailscale {
            updateConnection(
                title: L10n.string("Ready"),
                detail: L10n.string(
                    "Private Tailscale pairing and public share links are both ready."
                ),
                color: Design.Status.positive
            )
            return
        }

        if mode == .tailscaleAndRelay,
           AppSettings.shared.remoteAccessAllowsOwnerRelayFallback,
           case .connected = relay,
           case .unavailable(let reason) = tailscale {
            updateConnection(
                title: L10n.string("Relay fallback ready"),
                detail: L10n.format(
                    "Paired devices can connect through Relay. Tailscale pairing: %@",
                    reason
                ),
                color: Design.Status.warning
            )
            return
        }

        let pairingState = mode == .relay ? relay : tailscale
        switch pairingState {
        case .connected(let origin):
            let detail: String
            if mode == .tailscaleAndRelay {
                switch relay {
                case .connected:
                    detail = L10n.string("Tailscale pairing and share links are ready.")
                case .unavailable(let reason):
                    detail = L10n.format("Private pairing is ready. Sharing relay: %@", reason)
                case .starting:
                    detail = L10n.string("Private pairing is ready; the sharing relay is connecting…")
                case .stopped:
                    detail = L10n.string(
                        "Private pairing is ready. The public relay starts when you share."
                    )
                }
            } else if mode == .tailscale {
                detail = L10n.format(
                    "Available privately through %@.",
                    origin.host ?? L10n.string("your tailnet")
                )
            } else {
                detail = L10n.format(
                    "Connected through %@.",
                    origin.host ?? L10n.string("the secure relay")
                )
            }
            updateConnection(
                title: L10n.string("Ready"),
                detail: detail,
                color: Design.Status.positive
            )

        case .stopped, .starting:
            updateConnection(
                title: L10n.string("Connecting securely"),
                // The port is an address, not a quantity: formatted through the locale it
                // grew a grouping separator ("127.0.0.1:53,651"), so it crosses as a string.
                detail: L10n.format(
                    "The local mirror is ready on 127.0.0.1:%@. Waiting for %@…",
                    String(localPort),
                    mode == .relay ? L10n.string("the relay") : L10n.string("Tailscale")
                ),
                color: Design.Status.warning,
                busy: true
            )

        case .unavailable(let reason):
            updateConnection(
                title: L10n.string("Local access only"),
                detail: reason,
                color: Design.Status.warning
            )
        }
    }

    private func updatePairingForTransport(_ coordinator: RemoteAccessCoordinator) {
        let transport = AppSettings.shared.remoteAccessConnectionMode == .relay
            ? coordinator.relayStatus
            : coordinator.tailscaleStatus
        switch RemotePairingCardState.resolve(
            ownerDevicePersistenceError: coordinator.ownerDevicePersistenceError,
            pairingCodePayload: coordinator.pairingCodePayload,
            transport: transport
        ) {
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

        case .connectionUnavailable:
            updatePairing(
                title: L10n.string("Private connection unavailable"),
                detail: L10n.string(
                    "You can still test the browser on this Mac, or retry the selected connection."
                ),
                action: L10n.string("Retry Connection"),
                actionEnabled: true,
                prominent: true
            )

        case .preparing:
            updatePairing(
                title: L10n.string("Preparing your pairing code"),
                detail: L10n.string(
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
                        + "it. Retrying starts the connection again and mints a new code."
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

    private func updateTailscaleReadiness(_ readiness: TailscaleReadiness) {
        guard tailscaleStepGlyphs.count == 3,
              tailscaleStepSpinners.count == 3,
              tailscaleStepDetails.count == 3,
              tailscaleStepActions.count == 3 else { return }

        tailscaleActionURL = nil
        tailscaleStepActions.forEach { $0.isHidden = true }

        func setStep(_ index: Int, glyph: String, color: NSColor, detail: String) {
            tailscaleStepGlyphs[index].stringValue = glyph
            tailscaleStepGlyphs[index].textColor = color
            tailscaleStepGlyphs[index].isHidden = false
            tailscaleStepSpinners[index].isAnimating = false
            tailscaleStepDetails[index].stringValue = detail
        }
        func offerAction(_ index: Int, title: String, url: URL) {
            tailscaleActionURL = url
            tailscaleStepActions[index].title = title
            tailscaleStepActions[index].setAccessibilityLabel(title)
            tailscaleStepActions[index].isHidden = false
        }
        func pending(_ index: Int, _ detail: String) {
            setStep(index, glyph: "–", color: Design.Text.tertiary, detail: detail)
        }
        func working(_ index: Int, _ detail: String) {
            tailscaleStepGlyphs[index].isHidden = true
            tailscaleStepSpinners[index].setAccessibilityLabel(detail)
            tailscaleStepSpinners[index].isAnimating = true
            tailscaleStepDetails[index].stringValue = detail
        }
        func ready(_ index: Int, _ detail: String) {
            setStep(index, glyph: "✓", color: Design.Status.positive, detail: detail)
        }
        func attention(_ index: Int, _ detail: String) {
            setStep(index, glyph: "!", color: Design.Status.warning, detail: detail)
        }

        switch readiness {
        case .notChecked:
            pending(0, L10n.string("Checked when Remote Access turns on."))
            pending(1, L10n.string("Waiting for the installation check."))
            pending(2, L10n.string("Waiting for Tailscale."))
        case .checking:
            // One `tailscale status` answers both installation and the tailnet, so the two
            // steps are genuinely in flight together.
            working(0, L10n.string("Looking for Tailscale…"))
            working(1, L10n.string("Checking your tailnet status…"))
            pending(2, L10n.string("Waiting for Tailscale."))
        case .publishing:
            ready(0, L10n.string("Tailscale is installed."))
            ready(1, L10n.string("This Mac is connected to your tailnet."))
            working(2, L10n.string("Publishing Threading privately…"))
        case .ready(let origin):
            ready(0, L10n.string("Tailscale is installed."))
            ready(1, L10n.string("This Mac is connected to your tailnet."))
            setStep(
                2,
                glyph: "✓",
                color: Design.Status.positive,
                detail: L10n.format("Ready at %@.", origin.host ?? origin.absoluteString)
            )
        case .actionRequired(let issue, let actionURL):
            switch issue {
            case .notInstalled:
                attention(0, L10n.string("Install Tailscale on this Mac, then retry."))
                pending(1, L10n.string("Waiting for Tailscale."))
                pending(2, L10n.string("Waiting for Tailscale."))
            case .signedOut:
                ready(0, L10n.string("Tailscale is installed."))
                attention(1, L10n.string("Sign in to Tailscale on this Mac, then retry."))
                pending(2, L10n.string("Waiting for Tailscale."))
            case .stopped:
                ready(0, L10n.string("Tailscale is installed."))
                attention(1, L10n.string("Turn on Tailscale on this Mac, then retry."))
                pending(2, L10n.string("Waiting for Tailscale."))
            case .statusUnavailable:
                ready(0, L10n.string("Tailscale is installed."))
                attention(1, L10n.string("Threading could not read Tailscale’s status."))
                pending(2, L10n.string("Waiting for Tailscale."))
            case .serveNotEnabled:
                ready(0, L10n.string("Tailscale is installed."))
                ready(1, L10n.string("This Mac is connected to your tailnet."))
                attention(2, L10n.string("Enable Tailscale Serve for this tailnet, then retry."))
                if let actionURL {
                    offerAction(2, title: L10n.string("Enable Tailscale Serve…"), url: actionURL)
                }
            case .httpsRequired:
                ready(0, L10n.string("Tailscale is installed."))
                ready(1, L10n.string("This Mac is connected to your tailnet."))
                attention(2, L10n.string("Enable Tailscale HTTPS for this tailnet, then retry."))
                if let actionURL {
                    offerAction(2, title: L10n.string("Enable HTTPS…"), url: actionURL)
                }
            case .permissionDenied:
                ready(0, L10n.string("Tailscale is installed."))
                ready(1, L10n.string("This Mac is connected to your tailnet."))
                attention(2, L10n.string("Allow Threading to publish this private service, then retry."))
            case .portInUse:
                ready(0, L10n.string("Tailscale is installed."))
                ready(1, L10n.string("This Mac is connected to your tailnet."))
                attention(
                    2,
                    L10n.string(
                        "HTTPS port 8443 already has a Tailscale Serve handler. Remove it, then retry."
                    )
                )
            case .serveFailed:
                ready(0, L10n.string("Tailscale is installed."))
                ready(1, L10n.string("This Mac is connected to your tailnet."))
                attention(2, L10n.string("Tailscale Serve could not publish Threading. Retry the connection."))
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
        pairingPayload: String? = nil
    ) {
        pairingTitle.stringValue = title
        pairingSpinner.setAccessibilityLabel(title)
        pairingSpinner.isAnimating = busy
        pairingDetail.stringValue = detail
        pairingActionButton.title = action
        pairingActionButton.isEnabled = actionEnabled
        pairingActionButton.isProminent = prominent

        let code = pairingPayload.flatMap { PairingCodeImage.make(for: $0) }
        pairingCode.image = code
        pairingCode.isHidden = code == nil
        pairingInstruction.isHidden = code == nil
        pairingInstruction.stringValue = code == nil
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

    @objc private func openLocally() {
        guard let url = RemoteAccessCoordinator.shared.localURL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openTailscaleAction() {
        guard let tailscaleActionURL else { return }
        NSWorkspace.shared.open(tailscaleActionURL)
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
