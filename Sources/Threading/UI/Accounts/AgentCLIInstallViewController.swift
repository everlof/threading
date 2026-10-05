import AppKit

/// Installs one agent CLI where the person can watch it: the provider's own installer, run on
/// a click in a terminal inside the sheet, followed by the same PATH check launches depend on.
///
/// It exists because the honest alternatives were all worse for somebody on a fresh Mac. A
/// caption with a command to paste into another app made them do the work and never noticed
/// when they had; Try Again on a launch-failure screen could not succeed at all. A silent
/// background install would download and run network code nobody watched. So the sheet shows
/// the exact command first, runs nothing until **Install** is pressed, keeps every line and any
/// prompt the installer prints in a real terminal, and reads the outcome from the installer's
/// exit and a fresh probe rather than from its prose.
///
/// The three outcomes after a run are told apart because each needs a different next step:
/// found on PATH (done), installed into `~/.local/bin` but not on the login shell's PATH (a
/// profile line, not another install), and a failed installer (its output says why).
@MainActor
final class AgentCLIInstallViewController: NSViewController, TerminalSessionDelegate {

    enum Phase: Equatable {
        case ready
        /// An npm-based installer on a Mac with no npm.
        case needsNode
        case running
        case checking
        case installed(path: String)
        case installedOffPath
        /// The installer exited cleanly and the login shell still cannot find the command —
        /// it went somewhere the PATH does not reach.
        case finishedButNotFound
        case failed(exitCode: Int32?)
    }

    // MARK: - Properties

    let kind: AgentKind
    private(set) var phase: Phase = .ready {
        didSet { applyPhase() }
    }

    /// Called once when the sheet closes, with whether the CLI can now launch.
    var onFinish: ((Bool) -> Void)?

    private let recipe: AgentCLIInstallRecipe
    private let availability: AgentCLIAvailability
    private let loginShell: () -> String
    private var session: TerminalSession?

    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let commandLabel = NSTextField(labelWithString: "")
    private let terminalHost = NSView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let secondaryButton = ThemedButton(title: "", target: nil, action: nil)
    private let primaryButton = ThemedButton(title: "", target: nil, action: nil)
    private let closeButton = ThemedButton(title: "", target: nil, action: nil)
    private lazy var terminalHeight = terminalHost.heightAnchor.constraint(equalToConstant: 0)

    // MARK: - Initialization

    init(
        kind: AgentKind,
        availability: AgentCLIAvailability = .shared,
        loginShell: @escaping () -> String = { AgentLauncher.loginShellPath }
    ) {
        self.kind = kind
        self.recipe = AgentCLIInstallRecipe.recipe(for: kind)
        self.availability = availability
        self.loginShell = loginShell
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Opens the sheet over whoever asked. Every surface that offers an install comes here, so
    /// the command, the confirmation and the outcome are worded once.
    @discardableResult
    static func present(
        _ kind: AgentKind,
        from presenter: NSViewController,
        onFinish: ((Bool) -> Void)? = nil
    ) -> AgentCLIInstallViewController {
        let sheet = AgentCLIInstallViewController(kind: kind)
        sheet.onFinish = { [weak presenter, weak sheet] installed in
            if let presenter, let sheet { presenter.dismiss(sheet) }
            onFinish?(installed)
        }
        presenter.presentAsSheet(sheet)
        return sheet
    }

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView(frame: NSRect(
            x: 0, y: 0,
            width: AgentCLIInstallLayout.width,
            height: AgentCLIInstallLayout.minimumHeight
        ))
        setupViews()
        // Assigned even when unchanged: the observer is what lays the first phase out.
        phase = availability.canRunInstaller(for: kind) ? .ready : .needsNode
    }

    override func cancelOperation(_ sender: Any?) {
        closeClicked()
    }

    // MARK: - Setup

    private func setupViews() {
        titleLabel.applyFont(.heading)
        titleLabel.textColor = Design.Text.label
        titleLabel.stringValue = L10n.format("Install %@", kind.displayName)

        detailLabel.applyFont(.body)
        detailLabel.textColor = Design.Text.secondary

        commandLabel.applyFont(.code())
        commandLabel.textColor = Design.Text.label
        commandLabel.stringValue = recipe.command
        commandLabel.isSelectable = true
        commandLabel.lineBreakMode = .byTruncatingMiddle
        commandLabel.setAccessibilityLabel(L10n.format("Install command: %@", recipe.command))

        terminalHost.wantsLayer = true
        terminalHost.translatesAutoresizingMaskIntoConstraints = false
        terminalHeight.isActive = true

        statusLabel.applyFont(.body)
        statusLabel.textColor = Design.Text.secondary
        statusLabel.setAccessibilityIdentifier("agent-cli-install.status")

        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.keyEquivalent = "\u{1b}"
        closeButton.setAccessibilityIdentifier("agent-cli-install.close")

        secondaryButton.target = self
        secondaryButton.action = #selector(secondaryClicked)
        secondaryButton.setAccessibilityIdentifier("agent-cli-install.secondary")

        primaryButton.target = self
        primaryButton.action = #selector(primaryClicked)
        primaryButton.isProminent = true
        primaryButton.keyEquivalent = "\r"
        primaryButton.setAccessibilityIdentifier("agent-cli-install.primary")

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [closeButton, spacer, secondaryButton, primaryButton])
        footer.orientation = .horizontal
        footer.spacing = Design.Spacing.small

        let stack = NSStackView(views: [
            titleLabel, detailLabel, commandLabel, terminalHost, statusLabel, footer
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.medium
        stack.setCustomSpacing(Design.Spacing.large, after: statusLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: Design.Spacing.large),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Design.Spacing.large),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Design.Spacing.large),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -Design.Spacing.large),
            view.widthAnchor.constraint(equalToConstant: AgentCLIInstallLayout.width)
        ])
        for arranged in [detailLabel, commandLabel, terminalHost, statusLabel, footer] {
            arranged.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    // MARK: - Phases

    /// Every visible word and button follows from the phase, so no transition can leave a
    /// button from the last one behind.
    private func applyPhase() {
        guard isViewLoaded else { return }
        let needsNode = recipe.requirement == .nodePackageManager

        switch phase {
        case .ready:
            detailLabel.stringValue = needsNode
                ? L10n.format(
                    "Runs the official installer below in a terminal, using npm from your login shell. Threading checks for %@ again when it finishes.",
                    kind.executableName
                )
                : L10n.format(
                    "Runs the official installer below in a terminal. It downloads %@ from its publisher. Threading checks for it again when it finishes.",
                    kind.displayName
                )
            statusLabel.stringValue = ""
            setButtons(primary: L10n.string("Install"), secondary: L10n.string("Copy Command"))
        case .needsNode:
            detailLabel.stringValue = L10n.format(
                "%@ installs with npm, which comes with Node.js — and your login shell has no npm. Install Node.js first, then check again.",
                kind.displayName
            )
            statusLabel.stringValue = ""
            setButtons(primary: L10n.string("Check Again"), secondary: L10n.string("Get Node.js"))
        case .running:
            statusLabel.stringValue = L10n.string("Installing… Answer any question the installer asks in the terminal above.")
            setButtons(primary: nil, secondary: L10n.string("Stop"))
        case .checking:
            statusLabel.stringValue = L10n.string("Checking your login shell's PATH…")
            setButtons(primary: nil, secondary: nil)
        case .installed(let path):
            statusLabel.stringValue = L10n.format("%@ is installed at %@. You can start chats with it now.", kind.displayName, path)
            setButtons(primary: L10n.string("Done"), secondary: nil)
        case .installedOffPath:
            statusLabel.stringValue = L10n.format(
                "%@ was installed into ~/.local/bin, but your login shell's PATH does not include that folder, so chats cannot start it yet. Add this line to ~/.zprofile, then check again: %@",
                kind.displayName,
                AgentCLIInstallLayout.pathExportLine
            )
            setButtons(primary: L10n.string("Check Again"), secondary: L10n.string("Copy Line"))
        case .finishedButNotFound:
            statusLabel.stringValue = L10n.format(
                "The installer finished, but your login shell still can't find %@. Its output above says where it went; that folder needs to be on your PATH. Then check again.",
                kind.executableName
            )
            setButtons(primary: L10n.string("Check Again"), secondary: L10n.string("Installation Guide"))
        case .failed(let exitCode):
            statusLabel.stringValue = exitCode.map {
                L10n.format("The installer stopped with exit code %lld. Its output above says why.", Int64($0))
            } ?? L10n.string("The installer stopped before finishing. Its output above says why.")
            setButtons(primary: L10n.string("Run Again"), secondary: L10n.string("Installation Guide"))
        }

        statusLabel.isHidden = statusLabel.stringValue.isEmpty
        let showsTerminal = session != nil
        terminalHeight.constant = showsTerminal ? AgentCLIInstallLayout.terminalHeight : 0
        terminalHost.isHidden = !showsTerminal
        closeButton.title = installedPath == nil ? L10n.string("Cancel") : L10n.string("Close")
        closeButton.isEnabled = phase != .checking
        view.layoutSubtreeIfNeeded()
        preferredContentSize = view.fittingSize
    }

    private func setButtons(primary: String?, secondary: String?) {
        primaryButton.title = primary ?? ""
        primaryButton.isHidden = primary == nil
        secondaryButton.title = secondary ?? ""
        secondaryButton.isHidden = secondary == nil
    }

    private var installedPath: String? {
        if case .installed(let path) = phase { return path }
        return nil
    }

    // MARK: - Actions

    @objc private func primaryClicked() {
        switch phase {
        case .ready, .failed: runInstaller()
        case .needsNode, .installedOffPath, .finishedButNotFound: checkAgain()
        case .installed: finish()
        case .running, .checking: break
        }
    }

    @objc private func secondaryClicked() {
        switch phase {
        case .ready: copy(recipe.command)
        case .needsNode: NSWorkspace.shared.open(AgentCLIInstallLayout.nodeDownload)
        case .running: session?.terminate()
        case .installedOffPath: copy(AgentCLIInstallLayout.pathExportLine)
        case .failed, .finishedButNotFound: NSWorkspace.shared.open(kind.cliInstallationGuide)
        case .checking, .installed: break
        }
    }

    @objc private func closeClicked() {
        guard phase != .checking else { return }
        session?.terminate()
        finish()
    }

    private func finish() {
        let installed = installedPath != nil
        let callback = onFinish
        onFinish = nil
        callback?(installed)
    }

    private func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: - Running

    private func runInstaller() {
        session?.terminate()
        session?.terminalView.removeFromSuperview()

        let terminal = TerminalSession(profile: ProfileStorage.shared.defaultProfile)
        terminal.delegate = self
        session = terminal
        let terminalView = terminal.terminalView
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        terminalHost.addSubview(terminalView)
        terminalHost.applyLayerBackground(terminalView.nativeBackgroundColor)
        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: terminalHost.topAnchor, constant: TerminalPadding.top),
            terminalView.bottomAnchor.constraint(equalTo: terminalHost.bottomAnchor, constant: -TerminalPadding.bottom),
            terminalView.leadingAnchor.constraint(equalTo: terminalHost.leadingAnchor, constant: TerminalPadding.leading),
            terminalView.trailingAnchor.constraint(equalTo: terminalHost.trailingAnchor, constant: -TerminalPadding.trailing)
        ])

        phase = .running
        terminal.startOneShot(
            source: recipe.command,
            in: FileManager.default.homeDirectoryForCurrentUser,
            loginShell: loginShell()
        )
        view.window?.makeFirstResponder(terminalView)
        guard terminal.isRunning else {
            phase = .failed(exitCode: nil)
            return
        }
    }

    /// Waiting for Node.js is waiting for a prerequisite, not for an install: once npm appears
    /// the sheet goes back to offering the install rather than reporting on one that never ran.
    private func checkAgain() {
        let wasWaitingForNode = phase == .needsNode
        phase = .checking
        availability.refresh { [weak self] in
            guard let self else { return }
            if wasWaitingForNode, case .installed = availability.state(for: kind) {
                applyProbe(exitCode: 0)
            } else if wasWaitingForNode {
                phase = availability.canRunInstaller(for: kind) ? .ready : .needsNode
            } else {
                applyProbe(exitCode: 0)
            }
        }
    }

    /// The installer's exit says whether it believes it worked; the probe says whether a launch
    /// will find the result. Both are needed: a clean exit into a folder the PATH skips is the
    /// commonest way a native install "works" and chats still cannot start.
    private func applyProbe(exitCode: Int32?) {
        switch availability.state(for: kind) {
        case .installed(let path):
            phase = .installed(path: path)
        case .missing, .unknown:
            if availability.isInstalledOffPath(kind) {
                phase = .installedOffPath
            } else if !availability.canRunInstaller(for: kind) {
                phase = .needsNode
            } else if exitCode == 0 {
                phase = .finishedButNotFound
            } else {
                phase = .failed(exitCode: exitCode)
            }
        }
    }

    // MARK: - TerminalSessionDelegate

    func terminalSession(_ session: TerminalSession, didTerminateWithExitCode exitCode: Int32?) {
        guard session === self.session, phase == .running else { return }
        phase = .checking
        availability.refresh { [weak self] in
            self?.applyProbe(exitCode: exitCode)
        }
    }

    // MARK: - Testing

    var primaryTitleForTesting: String? { primaryButton.isHidden ? nil : primaryButton.title }
    var secondaryTitleForTesting: String? { secondaryButton.isHidden ? nil : secondaryButton.title }
    var statusForTesting: String { statusLabel.stringValue }
    var commandForTesting: String { commandLabel.stringValue }
    func applyProbeForTesting(exitCode: Int32?) { applyProbe(exitCode: exitCode) }
}

// MARK: - Layout

enum AgentCLIInstallLayout {
    static let width: CGFloat = 620
    static let minimumHeight: CGFloat = 240
    static let terminalHeight: CGFloat = 280
    static let pathExportLine = "export PATH=\"$HOME/.local/bin:$PATH\""
    static let nodeDownload = URL(string: "https://nodejs.org/en/download")!
}
