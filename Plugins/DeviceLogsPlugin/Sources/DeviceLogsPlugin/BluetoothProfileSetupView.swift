import AppKit
import ThreadingDesignKit
import UniformTypeIdentifiers
import WebKit

/// Host-owned setup for the selected phone. Install from Apple / file selection authorize sending; iOS
/// retains profile consent. No agent tool exposes installation or changes the selected target.
@MainActor
final class BluetoothProfileSetupView: NSView {
    struct Target: Equatable, Sendable {
        let deviceID: String
        let title: String
    }

    private let preferredToolPath: String?
    private var target: Target?
    private var sendingTo: Target?
    private var completion: (Target, String)?
    private var browser: BluetoothProfileDownloadView?
    private var browserPopover: ThemedPopover?
    private let content = NSStackView()
    private let explanation = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private lazy var download = ThemedButton(
        title: L10n.string("Install from Apple…"), target: self, action: #selector(openDownload)
    )
    private lazy var install = ThemedButton(
        title: L10n.string("Send certificate to this iPhone"), target: self, action: #selector(chooseProfile)
    )

    init(preferredToolPath: String?) {
        self.preferredToolPath = preferredToolPath
        super.init(frame: .zero)
        explanation.stringValue = L10n.string("Send Apple's downloaded Bluetooth logging profile to this iPhone, or sign in to download it from Apple. Approve the installation prompt on your iPhone, then restart it before capturing.")
        for label in [explanation, status] {
            label.font = Design.Typography.caption()
            label.textColor = Design.Text.secondary
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        status.setAccessibilityIdentifier("bluetooth-profile-status")
        install.setAccessibilityIdentifier("bluetooth-profile-install")
        install.emphasis = .primary
        download.setAccessibilityIdentifier("bluetooth-profile-download")
        let actions = NSStackView(views: [install, download])
        actions.spacing = Design.Spacing.small
        actions.alignment = .centerY
        [explanation, actions, status].forEach { content.addArrangedSubview($0) }
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = Design.Spacing.small
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Design.Spacing.medium),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Design.Spacing.medium),
            content.topAnchor.constraint(equalTo: topAnchor, constant: Design.Spacing.small),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Design.Spacing.small),
            explanation.widthAnchor.constraint(equalTo: content.widthAnchor),
            status.widthAnchor.constraint(equalTo: content.widthAnchor),
        ])
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        for label in [explanation, status] where label.preferredMaxLayoutWidth != label.bounds.width {
            label.preferredMaxLayoutWidth = label.bounds.width
        }
    }

    func configure(target: Target?) {
        if self.target != target { cancelBrowser() }
        self.target = target
        refresh()
    }

    private func refresh() {
        install.isEnabled = target != nil && sendingTo == nil && browser == nil
        download.isEnabled = install.isEnabled
        if let sendingTo {
            status.stringValue = L10n.format("Sending profile to %@. Keep the iPhone unlocked and follow its installation prompts.", sendingTo.title)
        } else if let completion, completion.0 == target {
            status.stringValue = completion.1
        } else {
            status.stringValue = ""
        }
        status.isHidden = status.stringValue.isEmpty
    }

    @objc private func openDownload() {
        beginDownload(loadApplePage: true)
    }

    private func beginDownload(loadApplePage: Bool) {
        guard let target, sendingTo == nil, browser == nil, let window else { return }
        let browser = BluetoothProfileDownloadView(dataStore: loadApplePage ? nil : .nonPersistent()) { [weak self] result in
            guard let self else {
                if case .success(let url) = result { BluetoothProfileDownloadView.removeDownload(url) }
                return
            }
            self.browserPopover?.onClose = nil
            self.browserPopover?.close()
            self.browserPopover = nil
            self.browser = nil
            self.window?.makeFirstResponder(self.download)
            switch result {
            case .success(let url):
                guard self.target == target, self.window != nil, !self.isHiddenOrHasHiddenAncestor else {
                    BluetoothProfileDownloadView.removeDownload(url)
                    self.refresh()
                    return
                }
                self.send(profileURL: url, to: target, removeDownload: true)
            case .failure(let error):
                self.completion = (target, BluetoothProfileDownloadFailure.message(for: error))
                self.refresh()
            }
        }
        self.browser = browser
        let controller = NSViewController()
        controller.view = browser
        let preferred = BluetoothProfileDownloadView.Metrics.preferredSize
        let available = (window.screen ?? NSScreen.main)?.visibleFrame.size ?? preferred
        let margin = BluetoothProfileDownloadView.Metrics.screenMargin
        controller.preferredContentSize = NSSize(
            width: min(preferred.width, available.width - margin),
            height: min(preferred.height, available.height - margin)
        )
        let popover = ThemedPopover()
        popover.animates = loadApplePage
        popover.behavior = .applicationDefined
        popover.contentViewController = controller
        popover.initialFirstResponder = browser.webView
        popover.onClose = { [weak browser] in browser?.cancel() }
        browserPopover = popover
        completion = nil
        refresh()
        popover.show(relativeTo: download.bounds, of: download, preferredEdge: .maxY)
        guard popover.isShown else { browser.cancel(); return }
        if loadApplePage { browser.start() }
    }

    func cancelBrowser() { browser?.cancel() }

    #if DEBUG
    func showBrowserForTesting() {
        beginDownload(loadApplePage: false)
        // Synthetic content only: prove a bottom-of-form action fits without storing an Apple
        // page or credentials in evidence. Production authentication never injects/inspects DOM.
        browser?.webView.loadHTMLString("""
            <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1">
            <style>html { color-scheme: light; font: 17px -apple-system; background: white; color: #222; }
            body { margin: 0; } main { box-sizing: border-box; min-height: 570px; padding: 48px;
            display: flex; flex-direction: column; align-items: center; text-align: center; }
            h1 { font-size: 28px; } p { line-height: 1.5; } label { margin-top: 40px; }
            input { padding: 14px; width: 280px; margin-top: 12px; border: 1px solid #888; border-radius: 8px; }
            button { margin-top: auto; padding: 12px 36px; font: inherit; border-radius: 8px; }
            </style></head><body><main><h1>Sign-in layout check</h1>
            <p>Synthetic form for layout verification.<br>No account details or Apple page content.</p>
            <label>Email address<br><input disabled placeholder="Layout fixture"></label>
            <button id="sign-in">Sign in</button></main></body></html>
            """, baseURL: nil)
    }
    #endif

    @objc private func chooseProfile() {
        guard let target, sendingTo == nil, let window else { return }
        let panel = NSOpenPanel()
        panel.title = L10n.string("Install Bluetooth Logging Profile")
        panel.message = L10n.format("Send Apple's Bluetooth logging profile to %@. Unlock the iPhone and approve installation when prompted.", target.title)
        panel.prompt = L10n.string("Send Profile")
        panel.allowedContentTypes = [UTType(filenameExtension: "mobileconfig") ?? .data]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self,
                  self.target == target, self.window != nil else { return }
            self.send(profileURL: url, to: target)
        }
    }

    private func send(profileURL: URL, to target: Target, removeDownload: Bool = false) {
        guard sendingTo == nil else { return }
        sendingTo = target
        refresh()
        let preferredToolPath = preferredToolPath
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                defer {
                    if removeDownload { try? FileManager.default.removeItem(at: profileURL.deletingLastPathComponent()) }
                }
                return BluetoothProfileInstaller.install(
                    profileURL: profileURL, deviceID: target.deviceID, preferredToolPath: preferredToolPath
                )
            }.value
            guard let self else { return }
            self.sendingTo = nil
            self.completion = (target, Self.message(for: result, target: target))
            self.refresh()
            if let window = self.window, !self.isHiddenOrHasHiddenAncestor {
                NSAccessibility.post(element: window, notification: .announcementRequested, userInfo: [
                    .announcement: self.status.stringValue, .priority: NSAccessibilityPriorityLevel.medium.rawValue,
                ])
            }
        }
    }

    static func message(for result: Result<Void, BluetoothProfileInstaller.Failure>, target: Target) -> String {
        switch result {
        case .success:
            return L10n.format("Profile sent to %@. Finish installation in Settings → General → VPN & Device Management, restart the iPhone, then press Rescan.", target.title)
        case .failure(.busy):
            return L10n.string("Another profile transfer is running. Wait for it to finish, then try again.")
        case .failure(.invalidProfile):
            return L10n.string("Choose Apple's Bluetooth logging .mobileconfig file. This file could not be read or is not a Bluetooth logging profile.")
        case .failure(.expiredProfile):
            return L10n.string("This profile has expired. Download the current Bluetooth profile from Apple.")
        case .failure(.missingTool):
            return L10n.string("Install iPhone Tooling in Threading Settings → Advanced, then try again.")
        case .failure(.incomplete):
            return L10n.string("The transfer could not be confirmed. Check Settings → General → VPN & Device Management on the iPhone before retrying. Keep it connected, trusted and unlocked.")
        case .failure(.rejected(let detail)):
            return L10n.format("The iPhone did not accept the profile: %@", detail)
        }
    }
}
