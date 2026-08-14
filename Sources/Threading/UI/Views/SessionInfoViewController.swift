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

    /// Test seams at the user-decision boundary, the Sharing pane's pattern. Production leaves
    /// both nil: the alert goes through `ConfirmationAlert` and the signal through
    /// `SessionProcessTerminator`.
    var confirmStop: ((ConfirmationRequest) -> Bool)?
    var onStopProcess: ((pid_t, ProcessStartTime) -> Void)?

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
    private let list = PanelListView(rowSpacing: Design.Spacing.hairline)

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
        view.addSubview(list)
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

            list.topAnchor.constraint(equalTo: revealButton.bottomAnchor, constant: Design.Spacing.small),
            list.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            list.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    // MARK: - Public Methods

    /// Test seam at the reading boundary: when set, `refresh()` asks this for its snapshot
    /// instead of resolving live roots and walking the machine — so the poll re-applies the
    /// fixture rather than racing it with real processes. Production leaves it nil.
    var readSource: ((@escaping @MainActor (SessionInfoSnapshot) -> Void) -> Void)?

    /// Re-reads now, whatever the poll was going to do. Called when the tab is shown and when the
    /// session stops working, which is when an agent has most likely just started or killed
    /// something.
    func refresh() {
        guard isViewLoaded else { return }

        updateHeader()

        if let readSource {
            readSource { [weak self] snapshot in
                self?.apply(snapshot, isRunning: !snapshot.processes.isEmpty)
            }
            return
        }

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

    /// Installs a known reading. Kept internal for behavior/render tests — live refreshes use
    /// the exact same path after the reader walks the real machine.
    func apply(_ snapshot: SessionInfoSnapshot, isRunning: Bool) {
        let shape = self.shape(of: snapshot, isRunning: isRunning)

        guard shape != renderedShape else {
            updateValues(snapshot)
            return
        }

        renderedShape = shape
        rebuild(snapshot, isRunning: isRunning)
    }

    /// Everything about a reading except the facts that move. Two readings with the same shape
    /// describe the same rows. Depth is part of a row's identity — its indent is a constraint,
    /// set at construction — while state, readings and tooltips deliberately are not: a process
    /// stopping must not cost the pointer its hover or the panel its scroll position.
    private func shape(of snapshot: SessionInfoSnapshot, isRunning: Bool) -> String {
        var parts = ["running:\(isRunning)"]

        for group in snapshot.processGroups {
            let pids = group.processes.map { "\($0.pid):\($0.depth):\($0.command)" }.joined(separator: ",")
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
            processRows[process.pid]?.update(reading(for: process))
        }
    }

    /// One poll's moving facts for one process: the readings, the state the dot must not
    /// overstate, and the tooltip's fact lines.
    private func reading(for process: SessionProcess) -> SessionInfoRowView.Reading {
        var facts: [String] = []
        if process.state == .stopped {
            facts.append(L10n.string("Stopped"))
        }
        if let path = process.executablePath {
            facts.append(L10n.format("Program: %@", path))
        }
        if let started = process.startDate {
            facts.append(L10n.format(
                "Started %@",
                Self.startFormatter.localizedString(for: started, relativeTo: Date())
            ))
        }
        if let directory = process.workingDirectory {
            facts.append(L10n.format("Working directory: %@", directory))
        }

        let readings = [process.formattedCPU, process.formattedMemory]
        let spoken = process.state == .stopped
            ? [L10n.string("Stopped")] + readings
            : readings

        // A stopped process holds its memory and its ports while running nothing — the one
        // state the filled "alive" dot must not claim. Hollow, in the warning role: paused is a
        // fact worth noticing, not a failure.
        return SessionInfoRowView.Reading(
            valueSegments: readings,
            dotSymbolName: process.state == .stopped ? "circle" : SessionInfoSymbols.process,
            dotColor: process.state == .stopped ? Design.Status.warning : Design.Status.positive,
            factLines: facts,
            accessibilityValue: spoken.joined(separator: " · ")
        )
    }

    /// Relative, because "8 min ago" answers "did the agent just start this or is it left
    /// over" without the reader doing arithmetic against a clock.
    private static let startFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private func rebuild(_ snapshot: SessionInfoSnapshot, isRunning: Bool) {
        list.clear()
        processRows.removeAll()

        guard isRunning else {
            list.addNote(L10n.string("This session isn’t running."))
            return
        }

        list.addSection(L10n.string("Processes"))
        for (index, group) in snapshot.processGroups.enumerated() {
            if snapshot.namesProcessOrigins {
                add(originTitle: group.origin, breathes: index > 0)
            }
            group.processes.forEach(add(process:))
        }

        list.addSection(L10n.string("Ports"))
        if snapshot.ports.isEmpty {
            list.addNote(L10n.string("Nothing listening."))
        } else {
            for (index, group) in snapshot.portGroups.enumerated() {
                if snapshot.namesPortOrigins {
                    add(originTitle: group.origin, breathes: index > 0)
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
            valueSegments: [process.formattedCPU, process.formattedMemory],
            indentLevel: process.depth,
            commandLine: commandLine(for: process),
            accessibilityLabel: L10n.format("%@ · process %lld", process.command, Int64(process.pid))
        )
        row.update(reading(for: process))

        // Never on a root — session teardown owns those — and never without the start identity
        // that authorises the signal: no identity, no kill.
        if !process.isRoot, let startTime = process.startTime {
            let pid = process.pid
            let command = process.command
            row.offerStop(titled: L10n.format("Stop %@", command)) { [weak self] in
                self?.requestStop(of: pid, command: command, startTime: startTime)
            }
        }

        processRows[process.pid] = row
        list.addRow(row)
    }

    /// Asks, signals, and lets the next poll show the truth. A skipped kill — the process
    /// already gone, or the pid meaning somebody else by now — is deliberately silent in the
    /// UI: the journal records it, and the refreshed list *is* the answer.
    private func requestStop(of pid: pid_t, command: String, startTime: ProcessStartTime) {
        let request = ConfirmationRequest(
            prompt: .stopSessionProcess,
            title: L10n.format("Stop %@?", command),
            message: L10n.format(
                "Process %lld receives a terminate signal. The session itself keeps running.",
                Int64(pid)
            ),
            confirmTitle: L10n.string("Stop")
        )

        let proceed: @MainActor (Bool) -> Void = { [weak self] allowed in
            guard allowed, let self else { return }
            if let onStopProcess = self.onStopProcess {
                onStopProcess(pid, startTime)
            } else {
                SessionProcessTerminator.terminate(pid: pid, expectedStart: startTime)
            }
            self.refresh()
        }

        if let confirmStop {
            proceed(confirmStop(request))
        } else {
            ConfirmationAlert.ask(request, in: view.window) { proceed($0) }
        }
    }

    /// What the row shows and what it can reveal. Display lines omit `argv[0]` — the primary
    /// label already names the process — while the tooltip carries the whole line. Secrets are
    /// hidden by `CommandLineRedactor` before anything is drawn; the raw vector survives only
    /// inside the row, behind its reveal.
    private func commandLine(for process: SessionProcess) -> SessionInfoRowView.CommandLine? {
        guard !process.arguments.isEmpty else { return nil }

        let redacted = CommandLineRedactor.redact(process.arguments)
        return SessionInfoRowView.CommandLine(
            redactedDisplay: redacted.arguments.dropFirst().joined(separator: " "),
            fullDisplay: process.arguments.dropFirst().joined(separator: " "),
            redactedLine: redacted.arguments.joined(separator: " "),
            fullLine: process.arguments.joined(separator: " "),
            redactedCount: redacted.redactedCount
        )
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
            valueSegments: [port.interface.displayName],
            accessibilityLabel: L10n.format("Port %lld · %@", Int64(port.port), port.command),
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
        list.addRow(row)
    }

    /// A sub-heading under a section: which of the session's two roots contributed the rows
    /// that follow. The section's own regular face — caption's semibold made "Agent" louder
    /// than the "Processes" over it, which read as the hierarchy inverted — one shade brighter
    /// than the section, and subordinated by *position*: indented one step onto the glyph
    /// column, with a breath above a second group so the division is felt before it is read.
    private func add(originTitle origin: SessionInfoOrigin, breathes: Bool) {
        if breathes {
            let spacer = NSView()
            spacer.translatesAutoresizingMaskIntoConstraints = false
            spacer.heightAnchor.constraint(equalToConstant: Design.Spacing.tight).isActive = true
            list.addRow(spacer)
        }

        let label = NSTextField(labelWithString: L10n.string(origin.rawValue))
        label.applyFont(.detail())
        label.textColor = Design.Text.tertiary
        label.translatesAutoresizingMaskIntoConstraints = false

        let indented = NSView()
        indented.translatesAutoresizingMaskIntoConstraints = false
        indented.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: indented.leadingAnchor, constant: Design.Spacing.small),
            label.trailingAnchor.constraint(lessThanOrEqualTo: indented.trailingAnchor),
            label.topAnchor.constraint(equalTo: indented.topAnchor),
            label.bottomAnchor.constraint(equalTo: indented.bottomAnchor)
        ])
        list.addRow(indented)
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
