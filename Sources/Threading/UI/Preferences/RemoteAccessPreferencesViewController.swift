import AppKit

/// Remote Access gets a page of its own because it is a setup flow, not a behavioural toggle.
///
/// General used to hide the feature below several unrelated sections and then put the actual
/// pairing instructions in an alert. This page keeps the whole journey visible: opt in, watch
/// the listener and selected transport come up, scan the code, and understand the authority.
final class RemoteAccessPreferencesViewController: NSViewController {

    // MARK: - Controls

    private let remoteAccessToggle = ThemedToggle()
    private let connectionModeControl = ThemedSegmentedControl()
    private let openLocallyButton = ThemedButton()
    private let pairingActionButton = ThemedButton()
    private let pairedDevicesStack = NSStackView()

    private let statusGlyph = NSTextField(labelWithString: "●")
    private let statusTitle = NSTextField(labelWithString: "")
    private let statusDetail = NSTextField(wrappingLabelWithString: "")

    private let pairingSymbol = NSImageView()
    private let pairingTitle = NSTextField(labelWithString: "")
    private let pairingDetail = NSTextField(wrappingLabelWithString: "")
    private let pairingCode = NSImageView()
    private let pairingInstruction = NSTextField(wrappingLabelWithString: "")

    private var copiedReset: DispatchWorkItem?
    private var pairedDeviceIDs: [String] = []
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
            equalToConstant: SettingsUIDefaults.controlWidth
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
        let page = SettingsUI.page([
            SettingsUI.heading("Remote Access"),
            SettingsUI.note(
                "Continue chats from Threading on iPhone or a private browser. "
                    + "Nothing is exposed until you turn it on."
            ),
            SettingsUI.section("Connection", connectionCard()),
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
                    + "your private tailnet. Both uses Tailscale for pairing and the relay for sharing.",
                control: connectionModeControl
            ),
            SettingsUI.fullRow(connectionStatusRow())
        ])
    }

    private func connectionStatusRow() -> NSView {
        let labels = NSStackView(views: [statusTitle, statusDetail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = Design.Spacing.hairline
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [statusGlyph, labels, openLocallyButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Design.Spacing.medium
        return row
    }

    private func pairingCard() -> SettingsCard {
        pairingSymbol.image = symbol("iphone")

        let heading = NSStackView(views: [pairingSymbol, pairingTitle])
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
        openLocallyButton.isHidden = coordinator.localURL == nil
        openLocallyButton.isEnabled = coordinator.localURL != nil
        rebuildPairedDevices(coordinator.pairedOwnerDevices, error: coordinator.ownerDevicePersistenceError)

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
                color: Design.Status.warning
            )
            updatePairing(
                title: L10n.string("Preparing your connection"),
                detail: L10n.string("This usually takes only a few seconds."),
                action: L10n.string("Starting…"),
                actionEnabled: false,
                prominent: false
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
                case .stopped, .starting:
                    detail = L10n.string("Private pairing is ready; the sharing relay is connecting…")
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
                detail: L10n.format(
                    "The local mirror is ready on 127.0.0.1:%lld. Waiting for %@…",
                    Int64(localPort),
                    mode == .relay ? L10n.string("the relay") : L10n.string("Tailscale")
                ),
                color: Design.Status.warning
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
        if coordinator.ownerDevicePersistenceError != nil {
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
            return
        }
        if let payload = coordinator.pairingCodePayload {
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
            return
        }

        let state = AppSettings.shared.remoteAccessConnectionMode == .relay
            ? coordinator.relayStatus
            : coordinator.tailscaleStatus
        switch state {
        case .unavailable:
            updatePairing(
                title: L10n.string("Private connection unavailable"),
                detail: L10n.string(
                    "You can still test the browser on this Mac, or retry the selected connection."
                ),
                action: L10n.string("Retry Connection"),
                actionEnabled: true,
                prominent: true
            )
        case .stopped, .starting, .connected:
            updatePairing(
                title: L10n.string("Preparing your pairing code"),
                detail: L10n.string(
                    "The QR code appears here as soon as the selected connection is ready."
                ),
                action: L10n.string("Connecting…"),
                actionEnabled: false,
                prominent: false
            )
        }
    }

    private func updateConnection(title: String, detail: String, color: NSColor) {
        statusTitle.stringValue = title
        statusDetail.stringValue = detail
        statusGlyph.textColor = color
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
        pairingPayload: String? = nil
    ) {
        pairingTitle.stringValue = title
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

    @objc private func openLocally() {
        guard let url = RemoteAccessCoordinator.shared.localURL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func pairingAction() {
        let coordinator = RemoteAccessCoordinator.shared

        if let url = coordinator.remoteURL {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
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
