import AppKit

/// What a session is actually running: where it is, the processes it has spawned, and the ports
/// those processes are listening on.
///
/// The panel exists because the terminal answers none of this. An agent that started a dev
/// server three turns ago has scrolled the port out of view, and "is it on 3000 or 5173, and can
/// the phone on my desk reach it" is a question the scrollback can only answer by being read
/// backwards. The bind address is half that answer and the half a port number omits.
///
/// Two things shape the implementation:
///
/// - **It polls, and only while it is on screen.** Processes and ports raise no filesystem
///   event, so unlike the review pane there is nothing to watch — the only honest option is to
///   ask again. `WindowAwareView` gates that on the tab being visible, so a panel nobody is
///   looking at costs nothing.
/// - **A poll rebuilds rows only when the *shape* changed.** CPU and memory move every tick, so
///   rebuilding on every reading would throw away the hover under the pointer and the scroll
///   position several times a second. The row set is rebuilt when a process or port appears or
///   goes away; otherwise the numbers are written into the rows already on screen.
final class SessionInfoViewController: NSViewController {

    // MARK: - Properties

    let sessionID: SessionID
    private let folderPath: String

    /// The shell drawer's root pid. It lives on the terminal container rather than in any
    /// singleton, so it is injected rather than reached for across the window.
    var shellRootProvider: (() -> pid_t?)?

    /// Opening a port hands the URL back to the pane, which has a browser tab to put it in.
    var onOpenURL: ((URL) -> Void)?

    private let reader = SessionInfoReader()
    private let pollTimer = MainRunLoopTimer()

    /// What the rows currently on screen are drawn from. A reading with the same shape updates
    /// them in place; a different one rebuilds.
    private var renderedShape: String?
    private var processRows: [pid_t: SessionInfoRowView] = [:]

    private lazy var directoryLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.applyFont(.compactCode)
        label.textColor = Design.Text.label
        label.lineBreakMode = .byTruncatingMiddle
        return label
    }()
    private lazy var metaLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.applyFont(.caption)
        label.textColor = Design.Text.tertiary
        label.lineBreakMode = .byTruncatingTail
        return label
    }()
    private lazy var revealButton: ThemedButton = {
        let button = ThemedButton(
            title: L10n.string("Finder"),
            target: self,
            action: #selector(revealInFinder)
        )
        button.toolTip = L10n.string("Show this folder in Finder")
        return button
    }()
    private lazy var copyButton: ThemedButton = {
        let button = ThemedButton(
            title: L10n.string("Copy"),
            target: self,
            action: #selector(copyDirectory)
        )
        button.toolTip = L10n.string("Copy the folder path")
        return button
    }()
    private lazy var stack: NSStackView = {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.hairline
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(
            top: Design.Spacing.small,
            left: Design.Spacing.small,
            bottom: Design.Spacing.inset,
            right: Design.Spacing.small
        )
        return stack
    }()
    private lazy var scrollView: ThemedScrollView = {
        let clipView = FlippedClipView()
        clipView.drawsBackground = false
        let scroll = ThemedScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.contentView = clipView
        scroll.documentView = stack
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        return scroll
    }()

    // MARK: - Initialization

    init(sessionID: SessionID, folderPath: String) {
        self.sessionID = sessionID
        self.folderPath = folderPath
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func loadView() {
        let root = WindowAwareView()
        root.onWindowChange = { [weak self] window in
            window == nil ? self?.stopPolling() : self?.startPolling()
        }
        root.wantsLayer = true
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupHeader()
        setupBody()
        setupConstraints()
        refresh()
    }

    // MARK: - Setup

    private func setupHeader() {
        [directoryLabel, metaLabel, revealButton, copyButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
    }

    private func setupBody() {
        view.addSubview(scrollView)
    }

    private func setupConstraints() {
        let inset = Design.Spacing.inset

        NSLayoutConstraint.activate([
            // The toolbar insets the safe area; pinning to the view's own top slides the header
            // underneath it.
            directoryLabel.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor,
                constant: Design.Spacing.small
            ),
            directoryLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: inset),
            directoryLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -inset),

            metaLabel.topAnchor.constraint(equalTo: directoryLabel.bottomAnchor, constant: Design.Spacing.hairline),
            metaLabel.leadingAnchor.constraint(equalTo: directoryLabel.leadingAnchor),
            metaLabel.trailingAnchor.constraint(equalTo: directoryLabel.trailingAnchor),

            revealButton.topAnchor.constraint(equalTo: metaLabel.bottomAnchor, constant: Design.Spacing.small),
            revealButton.leadingAnchor.constraint(equalTo: directoryLabel.leadingAnchor),

            copyButton.centerYAnchor.constraint(equalTo: revealButton.centerYAnchor),
            copyButton.leadingAnchor.constraint(equalTo: revealButton.trailingAnchor, constant: Design.Spacing.tight),
            copyButton.trailingAnchor.constraint(lessThanOrEqualTo: directoryLabel.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: revealButton.bottomAnchor, constant: Design.Spacing.small),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            stack.widthAnchor.constraint(equalTo: scrollView.widthAnchor)
        ])
    }

    // MARK: - Public Methods

    /// Re-reads now, whatever the poll was going to do. Called when the tab is shown and when the
    /// session stops working, which is when an agent has most likely just started or killed
    /// something.
    func refresh() {
        guard isViewLoaded else { return }

        updateHeader()

        let agentRoot = agentRootPid
        let shellRoot = shellRootProvider?()

        reader.read(agentRoot: agentRoot, shellRoot: shellRoot) { [weak self] snapshot in
            // Whether the session is running is answered by what was *found*, not by whether a
            // root pid existed to look under. A pid can outlive its process — and a session
            // holding a stale one would otherwise draw "Processes 0" over empty sections, which
            // reads as "nothing is running here" while claiming to have looked properly.
            self?.apply(snapshot, isRunning: !snapshot.processes.isEmpty)
        }
    }

    // MARK: - Polling

    private func startPolling() {
        guard !pollTimer.isInstalled else { return }

        // A fresh rate measurement: the gap while the tab was hidden is not a sample.
        reader.reset()
        refresh()

        let timer = Timer(timeInterval: SessionInfoDefaults.refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
        // `.common`, or the panel stops updating for as long as a menu is open or a scroll is
        // in progress — which is exactly when someone is reading it.
        RunLoop.main.add(timer, forMode: .common)
        pollTimer.install(timer)
    }

    private func stopPolling() {
        pollTimer.invalidate()
    }

    // MARK: - Rendering

    private func updateHeader() {
        let directory = currentDirectory
        directoryLabel.stringValue = directory.path
        directoryLabel.toolTip = directory.path
        metaLabel.stringValue = gitDescription(for: directory)
    }

    private func apply(_ snapshot: SessionInfoSnapshot, isRunning: Bool) {
        let shape = self.shape(of: snapshot, isRunning: isRunning)

        guard shape != renderedShape else {
            updateValues(snapshot)
            return
        }

        renderedShape = shape
        rebuild(snapshot, isRunning: isRunning)
    }

    /// Everything about a reading except the numbers that move. Two readings with the same shape
    /// describe the same rows.
    private func shape(of snapshot: SessionInfoSnapshot, isRunning: Bool) -> String {
        var parts = ["running:\(isRunning)"]

        for group in snapshot.processGroups {
            let pids = group.processes.map { "\($0.pid):\($0.command)" }.joined(separator: ",")
            parts.append("p/\(group.origin.rawValue)/\(pids)")
        }

        for group in snapshot.portGroups {
            let ports = group.ports.map { "\($0.port):\($0.address):\($0.pid)" }.joined(separator: ",")
            parts.append("n/\(group.origin.rawValue)/\(ports)")
        }

        return parts.joined(separator: "|")
    }

    private func updateValues(_ snapshot: SessionInfoSnapshot) {
        for process in snapshot.processes {
            processRows[process.pid]?.value = "\(process.formattedCPU) · \(process.formattedMemory)"
        }
    }

    private func rebuild(_ snapshot: SessionInfoSnapshot, isRunning: Bool) {
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        processRows.removeAll()

        guard isRunning else {
            add(note: L10n.string("This session isn’t running."))
            return
        }

        add(sectionTitle: L10n.string("Processes"), count: snapshot.processes.count)
        for group in snapshot.processGroups {
            if snapshot.namesProcessOrigins {
                add(originTitle: group.origin)
            }
            group.processes.forEach(add(process:))
        }

        add(sectionTitle: L10n.string("Ports"), count: snapshot.ports.count)
        if snapshot.ports.isEmpty {
            add(note: L10n.string("Nothing listening."))
        } else {
            for group in snapshot.portGroups {
                if snapshot.namesPortOrigins {
                    add(originTitle: group.origin)
                }
                group.ports.forEach(add(port:))
            }
        }
    }

    private func add(process: SessionProcess) {
        // The positive status role, not the accent: a running process is a *state*, and the
        // accent already means "this session wants you" in the sidebar it sits beside. A column
        // of accent dots said that about four processes doing nothing but running.
        let row = SessionInfoRowView(
            symbolName: SessionInfoSymbols.process,
            symbolColor: Design.Status.positive,
            primary: process.command,
            secondary: "\(process.pid)",
            value: "\(process.formattedCPU) · \(process.formattedMemory)"
        )
        processRows[process.pid] = row
        addFullWidth(row)
    }

    private func add(port: ListeningPort) {
        // Only a port localhost can actually reach is offered as a link; handing over a URL that
        // cannot connect would be worse than showing none.
        let url = port.localURL
        let row = SessionInfoRowView(
            symbolName: SessionInfoSymbols.port,
            symbolColor: Design.Text.secondary,
            primary: "\(port.port)",
            secondary: port.command,
            value: port.interface.displayName,
            action: url.map { url in { [weak self] in self?.onOpenURL?(url) } }
        )
        row.toolTip = url.map {
            L10n.format(
                "Open %@ — bound to %@",
                $0.absoluteString,
                port.address
            )
        } ?? L10n.format(
            "Listening on %@:%lld",
            port.address,
            Int64(port.port)
        )
        addFullWidth(row)
    }

    private func add(sectionTitle: String, count: Int) {
        let label = NSTextField(
            labelWithString: L10n.format(
                "%@  %lld",
                sectionTitle.uppercased(),
                Int64(count)
            )
        )
        label.applyFont(.caption)
        label.textColor = Design.Text.quaternary
        label.translatesAutoresizingMaskIntoConstraints = false

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.heightAnchor.constraint(equalToConstant: Design.Spacing.small).isActive = true

        if !stack.arrangedSubviews.isEmpty {
            addFullWidth(spacer)
        }
        addFullWidth(label)
    }

    private func add(originTitle origin: SessionInfoOrigin) {
        let label = NSTextField(labelWithString: L10n.string(origin.rawValue))
        label.applyFont(.caption)
        label.textColor = Design.Text.tertiary
        label.translatesAutoresizingMaskIntoConstraints = false
        addFullWidth(label)
    }

    private func add(note: String) {
        let label = NSTextField(labelWithString: note)
        label.applyFont(.body)
        label.textColor = Design.Text.tertiary
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        addFullWidth(label)
    }

    private func addFullWidth(_ subview: NSView) {
        stack.addArrangedSubview(subview)
        subview.widthAnchor.constraint(
            equalTo: stack.widthAnchor,
            constant: -(stack.edgeInsets.left + stack.edgeInsets.right)
        ).isActive = true
    }

    // MARK: - Session State

    /// The session's live root process, whichever surface it runs on.
    ///
    /// A terminal session's root is the login shell that `exec`s the agent. A natively rendered
    /// one has no PTY at all — its process belongs to the stream transport — and asking only the
    /// terminal runtime is why the panel first reported every native conversation as "not
    /// running", which is the surface most of these sessions actually use.
    ///
    /// A terminal controller that exists but has not yet captured its child reads as pid 0, so
    /// that is treated as absent rather than passed on as a root.
    private var agentRootPid: pid_t? {
        if let terminal = AgentRuntime.shared.controller(for: sessionID)?.session.shellPid, terminal > 0 {
            return terminal
        }
        return AgentRuntime.shared.conversation(for: sessionID)?.stream.rootProcessIdentifier
    }

    /// Where the agent is *now*, not where the session began — the same rule the shell drawer
    /// follows, and for the same reason: an agent that has spent ten minutes inside a subpackage
    /// is running its servers from there.
    private var currentDirectory: URL {
        AgentRuntime.shared.controller(for: sessionID)?.session.effectiveWorkingDirectory()
            ?? URL(fileURLWithPath: folderPath)
    }

    private func gitDescription(for directory: URL) -> String {
        guard let branch = GitInfo.currentBranch(for: directory.path) else { return "" }
        guard let worktree = GitInfo.worktreeName(for: directory.path) else { return branch }
        return "\(branch) · \(worktree)"
    }

    // MARK: - Actions

    @objc private func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([currentDirectory])
    }

    @objc private func copyDirectory() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(currentDirectory.path, forType: .string)
    }
}

// MARK: - Defaults

enum SessionInfoSymbols {
    /// A process is a running thing, not a file — the filled dot is the status vocabulary the
    /// sidebar already uses for "alive".
    static let process = "circle.fill"

    /// A listening socket is reachable over the network, which is what the globe says.
    static let port = "globe"
}
