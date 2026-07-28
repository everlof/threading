import AppKit
import CoreImage.CIFilterBuiltins

/// Remote Access gets a page of its own because it is a setup flow, not a behavioural toggle.
///
/// General used to hide the feature below several unrelated sections and then put the actual
/// pairing instructions in an alert. This page keeps the whole journey visible: opt in, watch
/// the listener and relay come up, scan the code, and understand the authority being granted.
final class RemoteAccessPreferencesViewController: NSViewController {

    // MARK: - Controls

    private let remoteAccessToggle = ThemedToggle()
    private let openLocallyButton = ThemedButton()
    private let pairingActionButton = ThemedButton()

    private let statusGlyph = NSTextField(labelWithString: "●")
    private let statusTitle = NSTextField(labelWithString: "")
    private let statusDetail = NSTextField(wrappingLabelWithString: "")

    private let pairingSymbol = NSImageView()
    private let pairingTitle = NSTextField(labelWithString: "")
    private let pairingDetail = NSTextField(wrappingLabelWithString: "")
    private let pairingCode = NSImageView()
    private let pairingInstruction = NSTextField(wrappingLabelWithString: "")

    private var copiedReset: DispatchWorkItem?

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

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(remoteAccessStatusDidChange),
            name: RemoteAccessCoordinator.statusDidChange,
            object: nil
        )
    }

    private func buildPage() {
        let page = SettingsUI.page([
            SettingsUI.heading("Remote Access"),
            SettingsUI.note(
                "Continue chats from Skalman on iPhone or a private browser. "
                    + "Nothing is exposed until you turn it on."
            ),
            SettingsUI.section("Connection", connectionCard()),
            SettingsUI.section("Set Up Your iPhone", pairingCard()),
            SettingsUI.section("Sharing & Security", securityCard()),
            SettingsUI.note(
                "Remote Access publishes only Skalman’s authenticated remote surface. "
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
                subtitle: "Uses a temporary encrypted HTTPS relay. Turning it off immediately "
                    + "revokes every pairing and shared-chat link from this launch.",
                control: remoteAccessToggle
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
            pairingCode.widthAnchor.constraint(equalToConstant: 196),
            pairingCode.heightAnchor.constraint(equalTo: pairingCode.widthAnchor),
            pairingDetail.widthAnchor.constraint(equalTo: content.widthAnchor),
            pairingInstruction.widthAnchor.constraint(equalTo: content.widthAnchor)
        ])

        return SettingsCard(rows: [SettingsUI.fullRow(content)])
    }

    private func securityCard() -> SettingsCard {
        SettingsCard(rows: [
            securityRow(
                symbol: "lock.shield",
                title: "Your own devices",
                detail: "The QR code is owner access. A paired device can see and manage your "
                    + "chats, send prompts, and review permission requests."
            ),
            securityRow(
                symbol: "person.2",
                title: "Other people",
                detail: "Use Share Chat… from that chat’s ⋯ menu. It grants only the selected "
                    + "chat, with view, collaboration and approval rights chosen separately."
            )
        ])
    }

    private func securityRow(symbol name: String, title: String, detail: String) -> NSView {
        let image = NSImageView(image: symbol(name))
        image.imageScaling = .scaleProportionallyDown
        image.contentTintColor = Design.Text.secondary
        image.translatesAutoresizingMaskIntoConstraints = false

        let titleField = NSTextField(labelWithString: L10n.string(title))
        titleField.applyFont(.body)
        titleField.textColor = Design.Text.label
        let detailField = NSTextField(wrappingLabelWithString: L10n.string(detail))
        detailField.applyFont(.subheading)
        detailField.textColor = Design.Text.secondary

        let labels = NSStackView(views: [titleField, detailField])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = Design.Spacing.hairline
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [image, labels])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = Design.Spacing.medium
        NSLayoutConstraint.activate([
            image.widthAnchor.constraint(equalToConstant: Design.Symbol.control + 2),
            image.heightAnchor.constraint(equalTo: image.widthAnchor)
        ])
        return SettingsUI.fullRow(row)
    }

    private func symbol(_ name: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(Design.Symbol.configuration(Design.Symbol.control))
            ?? NSImage()
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
        openLocallyButton.isHidden = coordinator.localURL == nil
        openLocallyButton.isEnabled = coordinator.localURL != nil

        switch coordinator.status {
        case .disabled:
            updateConnection(
                title: L10n.string("Off"),
                detail: L10n.string("This Mac is not reachable from another device."),
                color: Design.Text.tertiary
            )
            updatePairing(
                title: L10n.string("Connect your iPhone"),
                detail: L10n.string(
                    "Turn on Remote Access. Skalman will start a local mirror and connect "
                        + "it to a private HTTPS relay."
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
            switch coordinator.relayStatus {
            case .inactive, .starting:
                updateConnection(
                    title: L10n.string("Connecting securely"),
                    detail: L10n.format(
                        "The local mirror is ready on 127.0.0.1:%lld. "
                            + "Waiting for the encrypted relay…",
                        Int64(port)
                    ),
                    color: Design.Status.warning
                )
                updatePairing(
                    title: L10n.string("Preparing your pairing code"),
                    detail: L10n.string(
                        "The QR code appears here as soon as the secure relay is ready."
                    ),
                    action: L10n.string("Connecting…"),
                    actionEnabled: false,
                    prominent: false
                )

            case .connected(let origin):
                updateConnection(
                    title: L10n.string("Ready"),
                    detail: L10n.format(
                        "Connected through %@.",
                        origin.host ?? L10n.string("the secure relay")
                    ),
                    color: Design.Status.positive
                )
                updatePairing(
                    title: L10n.string("Scan with your iPhone"),
                    detail: L10n.string(
                        "Open Skalman on iPhone, choose Pair a Mac, then scan this code."
                    ),
                    action: L10n.string("Copy Pairing Link"),
                    actionEnabled: true,
                    prominent: false,
                    url: coordinator.remoteURL
                )

            case .unavailable(let reason):
                updateConnection(
                    title: L10n.string("Local access only"),
                    detail: reason,
                    color: Design.Status.warning
                )
                updatePairing(
                    title: L10n.string("Secure relay unavailable"),
                    detail: L10n.string(
                        "You can still test the browser on this Mac, or retry the secure relay."
                    ),
                    action: L10n.string("Retry Secure Relay"),
                    actionEnabled: true,
                    prominent: true
                )
            }

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

    private func updateConnection(title: String, detail: String, color: NSColor) {
        statusTitle.stringValue = title
        statusDetail.stringValue = detail
        statusGlyph.textColor = color
    }

    private func updatePairing(
        title: String,
        detail: String,
        action: String,
        actionEnabled: Bool,
        prominent: Bool,
        url: URL? = nil
    ) {
        pairingTitle.stringValue = title
        pairingDetail.stringValue = detail
        pairingActionButton.title = action
        pairingActionButton.isEnabled = actionEnabled
        pairingActionButton.isProminent = prominent

        let code = url.flatMap { qrCode(for: $0.absoluteString) }
        pairingCode.image = code
        pairingCode.isHidden = code == nil
        pairingInstruction.isHidden = code == nil
        pairingInstruction.stringValue = code == nil
            ? ""
            : L10n.string(
                "Only scan this owner code on a device you control. It can access every chat "
                    + "on this Mac. The beta relay and pairing are renewed when Skalman restarts."
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
            if case .unavailable = coordinator.relayStatus {
                restart()
            }
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

    private func qrCode(for text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }

        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let representation = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}
