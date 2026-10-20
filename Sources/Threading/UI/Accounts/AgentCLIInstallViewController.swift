import AppKit

/// Installs a reviewed provider artifact into Threading's private version directory. Opening
/// the sheet performs no network work. Cancel during staging leaves the active receipt intact.
@MainActor
final class AgentCLIInstallViewController: NSViewController {
    enum Phase: Equatable {
        case ready, running
        case installed(path: String)
        case failed(message: String)
    }
    typealias Install = @Sendable (AgentKind) async throws -> String

    let kind: AgentKind
    private(set) var phase: Phase = .ready { didSet { renderState() } }
    var onFinish: ((Bool) -> Void)?
    private let install: Install
    private let runtimes: ManagedAgentRuntimeStore
    private let availability: AgentCLIAvailability
    private var task: Task<Void, Never>?
    private let statusLabel = SettingsUI.note("")
    private let primaryButton = ThemedButton(title: "", target: nil, action: nil)
    private let closeButton = ThemedButton(title: "", target: nil, action: nil)

    init(kind: AgentKind, availability: AgentCLIAvailability = .shared,
         runtimes: ManagedAgentRuntimeStore = AgentLocalLaunch.store ?? .local,
         install: Install? = nil) {
        self.kind = kind
        self.availability = availability
        self.runtimes = runtimes
        self.install = install ?? { kind in
            try await ManagedAgentInstaller(store: runtimes).install(kind)
            return runtimes.selection(for: kind).executable
        }
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { task?.cancel() }

    @discardableResult
    static func present(_ kind: AgentKind, from presenter: NSViewController,
                        onFinish: ((Bool) -> Void)? = nil) -> AgentCLIInstallViewController {
        let sheet = AgentCLIInstallViewController(kind: kind)
        sheet.onFinish = { [weak presenter, weak sheet] installed in
            if let presenter, let sheet { presenter.dismiss(sheet) }
            onFinish?(installed)
        }
        presenter.presentAsSheet(sheet)
        return sheet
    }

    override func loadView() {
        let surface = ThemedSurfaceView()
        surface.frame = NSRect(x: 0, y: 0, width: AgentCLIInstallLayout.width,
                               height: AgentCLIInstallLayout.minimumHeight)
        surface.applySurface(fill: Design.Surface.elevated, radius: .fixed(0))
        view = surface
        let release = ManagedAgentCatalog.release(for: kind)
        let title = SettingsUI.note(L10n.format("Install %@", kind.displayName), localizes: false)
        title.applyFont(.heading)
        title.textColor = Design.Text.label
        let detail = SettingsUI.note(
            L10n.format("Threading will download and verify %@ %@ from its publisher. Your logins and conversations are preserved.",
                        kind.displayName, release.version), localizes: false
        )
        let location = SettingsUI.note(
            runtimes.providerRoot(kind).path, localizes: false
        )
        location.applyFont(.code())
        location.isSelectable = true
        statusLabel.isSelectable = true
        statusLabel.setAccessibilityIdentifier("agent-cli-install.status")
        primaryButton.target = self
        primaryButton.action = #selector(installClicked)
        primaryButton.isProminent = true
        primaryButton.keyEquivalent = "\r"
        primaryButton.setAccessibilityIdentifier("agent-cli-install.primary")
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.keyEquivalent = "\u{1b}"
        closeButton.setAccessibilityIdentifier("agent-cli-install.close")
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [closeButton, spacer, primaryButton])
        footer.orientation = .horizontal
        footer.spacing = Design.Spacing.small
        let stack = NSStackView(views: [title, detail, location, statusLabel, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.large
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: Design.Spacing.large),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -Design.Spacing.large),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Design.Spacing.large),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Design.Spacing.large),
            view.widthAnchor.constraint(equalToConstant: AgentCLIInstallLayout.width)
        ])
        for row in [detail, location, statusLabel, footer] {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        renderState()
    }

    override func cancelOperation(_ sender: Any?) { closeClicked() }

    private func renderState() {
        guard isViewLoaded else { return }
        primaryButton.isEnabled = phase != .running
        closeButton.title = L10n.string("Cancel")
        switch phase {
        case .ready:
            let release = ManagedAgentCatalog.release(for: kind)
            statusLabel.stringValue = release.supportsCurrentSystem
                ? L10n.string("Managed by Threading. No global Node.js or npm installation is required.")
                : release.systemRequirement
            primaryButton.isEnabled = release.supportsCurrentSystem
            primaryButton.title = L10n.string("Install")
        case .running:
            statusLabel.stringValue = L10n.string("Downloading, verifying and checking the agent…")
            primaryButton.title = L10n.string("Installing…")
        case .installed:
            statusLabel.stringValue = L10n.string("Installation verified. New chats will use this version.")
            primaryButton.title = L10n.string("Done")
            closeButton.title = L10n.string("Close")
        case .failed(let message):
            statusLabel.stringValue = message
            primaryButton.title = L10n.string("Try Again")
        }
    }

    @objc private func installClicked() {
        if case .installed = phase { onFinish?(true); return }
        guard task == nil else { return }
        phase = .running
        let install = self.install
        let kind = self.kind
        task = Task { [weak self] in
            do {
                let path = try await install(kind)
                guard !Task.isCancelled, let self else { return }
                phase = .installed(path: path)
                availability.refresh()
            } catch {
                guard !Task.isCancelled, let self else { return }
                phase = .failed(message: error.localizedDescription)
            }
            self?.task = nil
        }
    }

    @objc private func closeClicked() {
        task?.cancel()
        task = nil
        if case .installed = phase { onFinish?(true) }
        else { onFinish?(false) }
    }

    var primaryTitleForTesting: String? { primaryButton.title }
    var statusForTesting: String { statusLabel.stringValue }
    func setPhaseForTesting(_ phase: Phase) { self.phase = phase }
    func startForTesting() { installClicked() }
}

enum AgentCLIInstallLayout {
    static let width: CGFloat = 560
    static let minimumHeight: CGFloat = 260
}
