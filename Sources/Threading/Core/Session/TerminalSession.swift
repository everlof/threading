import AppKit
@preconcurrency import SwiftTerm

/// Manages a single terminal session including the terminal view, shell process, and session state.
@MainActor
final class TerminalSession: NSObject {

    // MARK: - Properties

    let identifier: SessionID
    let terminalView: EmojiFixedTerminalView
    private(set) var title: String
    private(set) var currentDirectory: URL?
    private(set) var isRunning: Bool = false

    weak var delegate: TerminalSessionDelegate?

    /// Raw PTY output, for the remote-access mirror. Single-consumer, same doctrine as
    /// `ConversationStreamSession.onEvent`: the mirror registry is the one consumer and fans
    /// out from there. Fired on the main thread inside SwiftTerm's synchronous read hop, so the
    /// closure copies and hands off to its own queue — it must never block the PTY read loop.
    var onRawOutput: ((Data) -> Void)?

    private var profile: TerminalProfile

    /// A launch requested after SIGTERM but before SwiftTerm has reaped the old child.
    ///
    /// LocalProcess deliberately remains occupied during that interval so an exit callback can
    /// never reap a replacement PID. Keep the user's latest launch request here and perform it
    /// from the exact old child's termination callback.
    private enum PendingLaunch {
        case shell(initialDirectory: URL?)
        case agent(AgentLaunchPlan)
    }
    private var pendingLaunch: PendingLaunch?

    /// The PID of the shell process, captured after starting.
    private(set) var shellPid: pid_t = 0

    /// The name of the profile used for this session.
    var profileName: String {
        profile.name
    }

    // MARK: - Initialization

    init(profile: TerminalProfile = .default, frame: NSRect = .zero, identifier: SessionID? = nil) {
        self.identifier = identifier ?? SessionID()
        self.profile = profile
        self.title = profile.shellPath
        self.terminalView = EmojiFixedTerminalView(frame: frame)

        super.init()

        setupTerminalView()
    }

    // MARK: - Setup

    private func setupTerminalView() {
        terminalView.processDelegate = self
        // Allow Option key to compose special characters (e.g., ~ on non-US keyboards)
        terminalView.optionAsMetaKey = false

        terminalView.onOutput = { [weak self] byteCount in
            guard let self else { return }
            self.delegate?.terminalSession(self, didProduceOutputOf: byteCount)
        }

        terminalView.onBell = { [weak self] in
            guard let self else { return }
            self.delegate?.terminalSessionDidRingBell(self)
        }

        terminalView.onWheelForwarded = { [weak self] in
            guard let self else { return }
            self.delegate?.terminalSessionDidForwardScroll(self)
        }

        terminalView.onUserInput = { [weak self] in
            guard let sessionID = self?.identifier else { return }
            Task { @MainActor in
                RemoteNotificationService.shared.recordOwnerInteraction(
                    sessionID: sessionID
                )
            }
        }

        terminalView.onOutputBytes = { [weak self] slice in
            guard let self, let onRawOutput = self.onRawOutput else { return }
            // Copy the slice out of SwiftTerm's reused buffer before it hands off.
            onRawOutput(Data(slice))
        }

        applyProfile()

        // Deliberately *not* an observer of `ProfileDidChange`.
        //
        // This used to adopt whatever profile that notification carried, which was correct
        // while there was one theme for the whole app and is wrong now that a session or its
        // project can name its own: a broadcast value is exactly what a per-session override
        // must not be overwritten by. The owning `AgentSessionViewController` re-resolves this
        // session's theme instead and pushes the result through `updateProfile`.
    }

    private func applyProfile() {
        // Sampled before the palette lands so the announcement below can tell a re-apply from
        // an actual change of page.
        let previousBackground = terminalView.getTerminal().backgroundColor

        // The terminal is the one surface whose typeface comes from TerminalProfile rather
        // than the app/conversation typography stack. `profile.font` also owns the fallback
        // when a saved family is no longer installed.
        terminalView.font = profile.font

        // Changing the font rebuilds SwiftTerm's TerminalOptions with their 500-line default,
        // so apply the user's history size afterwards on every profile refresh.
        terminalView.getTerminal().changeHistorySize(max(0, profile.scrollbackLines))

        // Install ANSI color palette
        let colors = profile.theme.asSwiftTermColors()
        terminalView.installColors(colors)

        // Apply theme colors
        terminalView.nativeForegroundColor = profile.theme.foreground
        terminalView.nativeBackgroundColor = profile.theme.background

        // Installed after the palette, because the transform is built from it. Re-installed on
        // every profile refresh rather than once at construction: the anchors are this theme's
        // hues, so a session that changes theme has to rebuild them or it keeps harmonising
        // toward the palette it left.
        terminalView.trueColorBackgroundTransform = AppSettings.harmonizesTerminalBackgrounds
            ? TerminalBackgroundHarmony.transform(for: profile.theme)
            : nil
        terminalView.selectedTextBackgroundColor = profile.theme.selection
        terminalView.caretColor = profile.theme.cursor

        // Apply cursor style
        let swiftTermStyle = swiftTermCursorStyle(from: profile.cursorStyle, blink: profile.cursorBlink)
        terminalView.cursorStyle = swiftTermStyle

        // Force redraw
        terminalView.needsDisplay = true

        // A theme changed under a running program has to be *announced*, or it never lands:
        // Claude asks what colour the terminal is once, at startup (`OSC 11 ; ?`), and keeps
        // that answer for the whole session — repainting the view moves nothing on its side,
        // which is precisely the white-on-white diff. It does subscribe to colour-scheme
        // reports (`DECSET 2031`), and the report is a prompt to *re-ask*, not the news
        // itself — so it must be sent only after the palette above is in place, and it moves
        // nothing unless the answer to the re-ask has actually changed. Gated on the
        // background actually changing so font tweaks and re-applies stay silent.
        let terminal = terminalView.getTerminal()
        if terminal.backgroundColor != previousBackground {
            terminal.reportColorSchemeChange(dark: profile.theme.hasDarkBackground)
        }
    }

    private func swiftTermCursorStyle(from style: TerminalProfile.CursorStyle, blink: Bool) -> CursorStyle {
        switch style {
        case .block:
            return blink ? .blinkBlock : .steadyBlock
        case .underline:
            return blink ? .blinkUnderline : .steadyUnderline
        case .bar:
            return blink ? .blinkBar : .steadyBar
        }
    }

    // MARK: - Shell Management

    func startShell() {
        startShell(initialDirectory: nil)
    }

    func startShell(initialDirectory: URL?) {
        guard !isRunning else { return }

        guard !terminalView.process.running else {
            pendingLaunch = .shell(initialDirectory: initialDirectory)
            return
        }

        launchShell(initialDirectory: initialDirectory)
    }

    private func launchShell(initialDirectory: URL?) {
        let environment = buildEnvironment()

        if let dir = initialDirectory {
            var shell = ShellCommand(word: profile.shellPath)
            for argument in profile.shellArguments {
                shell.append(word: argument)
            }
            let source = ShellCommand.executing(shell, in: dir.path)

            terminalView.startProcess(
                executable: "/bin/sh",
                args: ["-c", source.source],
                environment: environment,
                execName: (profile.shellPath as NSString).lastPathComponent
            )
        } else {
            terminalView.startProcess(
                executable: profile.shellPath,
                args: profile.shellArguments,
                environment: environment,
                execName: (profile.shellPath as NSString).lastPathComponent
            )
        }

        finishProcessStart()
    }

    /// Starts an agent using a resolved launch plan.
    ///
    /// Unlike `startShell`, the plan already encodes the working directory and the agent
    /// command, so the process is started verbatim.
    func start(plan: AgentLaunchPlan) {
        guard !isRunning else { return }

        guard !terminalView.process.running else {
            pendingLaunch = .agent(plan)
            return
        }

        launchAgent(plan: plan)
    }

    private func launchAgent(plan: AgentLaunchPlan) {
        terminalView.startProcess(
            executable: plan.executable,
            args: plan.arguments,
            environment: buildEnvironment(),
            execName: (plan.executable as NSString).lastPathComponent
        )

        finishProcessStart()
    }

    /// `LocalProcess` now uses `forkpty`, which returns the exact child synchronously. Keeping
    /// that identity at the launch seam avoids attributing one session's process to another
    /// when several sessions start alongside unrelated app helpers.
    private func finishProcessStart() {
        guard terminalView.process.running, terminalView.process.shellPid > 0 else { return }
        shellPid = terminalView.process.shellPid
        isRunning = true
        delegate?.terminalSessionDidStart(self)
    }

    /// Terminates the child process and closes the PTY.
    ///
    /// This must actually tear the process down rather than wait for deallocation, so a
    /// session going dormant releases its PTY and file descriptors immediately.
    func terminate() {
        // A second stop while an old child is being reaped cancels a queued rapid restart.
        pendingLaunch = nil
        guard isRunning else { return }

        terminalView.terminate()
        isRunning = false
        shellPid = 0
    }

    /// The environment the child is launched into.
    ///
    /// Not `private`: `TerminalColorQueryTests` reads it back, because what this hands a child is
    /// the whole of what the child knows about the palette before it draws anything.
    func buildEnvironment() -> [String] {
        var env = ProcessInfo.processInfo.environment

        // Drop the launching process's own agent identity. These describe whoever started
        // Threading — if that was itself an agent session, every session spawned here would
        // inherit its identifiers and believe it was a nested child of that conversation.
        for key in env.keys where AgentEnvironment.isInheritedAgentIdentity(key) {
            env.removeValue(forKey: key)
        }

        env[EnvironmentKeys.term] = TerminalDefaults.terminalType
        env[EnvironmentKeys.colorTerm] = TerminalDefaults.colorTerm
        env[EnvironmentKeys.shell] = profile.shellPath
        env["TERM_PROGRAM"] = "Threading"

        // Says whether this session's page is paper or ink, before the child draws anything —
        // the standing answer behind the `OSC 11` handshake, which an agent asks for in its
        // first few bytes and gives up on quickly. Set from `profile`, so it is this session's
        // palette rather than the app's: two sessions side by side may not agree. Always
        // written, never defaulted-to: Threading inherits launchd's environment, and whatever a
        // terminal that started the app happened to leave here describes *that* terminal.
        env[EnvironmentKeys.colorFGBG] = profile.theme.colorFGBG

        if env[EnvironmentKeys.lang] == nil {
            env[EnvironmentKeys.lang] = "en_US.UTF-8"
        }

        // Per-session history file
        HistoryManager.ensureHistoryDirectoryExists()
        let historyPath = HistoryManager.historyFilePath(for: identifier)
        env["HISTFILE"] = historyPath.path

        return env.map { "\($0.key)=\($0.value)" }
    }

    // MARK: - Profile Management

    func updateProfile(_ newProfile: TerminalProfile) {
        self.profile = newProfile
        applyProfile()
    }

    func increaseFontSize() {
        profile.fontSize = min(profile.fontSize + 1, 72)
        applyProfile()
    }

    func decreaseFontSize() {
        profile.fontSize = max(profile.fontSize - 1, 8)
        applyProfile()
    }

    // MARK: - Working Directory

    /// Returns the effective working directory for this session.
    /// First checks if OSC 7 reported a directory, then falls back to querying the shell process.
    func effectiveWorkingDirectory() -> URL? {
        // If we already have a directory from OSC 7, use that
        if let currentDirectory = currentDirectory {
            return currentDirectory
        }

        // Otherwise, query the shell process directly
        guard shellPid > 0 else { return nil }
        return ProcessUtility.workingDirectory(forPid: shellPid)
    }

    // MARK: - AI Integration

    /// Inserts text at the current cursor position (e.g., a generated command).
    /// This sends the text to the PTY as if the user typed it.
    func insertText(_ text: String) {
        terminalView.send(txt: text)
    }

    /// Sends raw bytes to the PTY as if typed — the entry point for remote keyboard input.
    func sendRemoteInput(_ bytes: [UInt8]) {
        terminalView.sendRemote(bytes[...])
    }

    /// Lets the actively controlling phone own the shared PTY grid. SwiftTerm's ordinary resize
    /// path applies the winsize and raises SIGWINCH, so Claude Code/Codex redraw at mobile width.
    func setRemoteViewport(cols: Int, rows: Int) {
        terminalView.setRemoteGrid(cols: cols, rows: rows)
        delegate?.terminalSession(self, remoteViewportChangedTo: (cols, rows))
    }

    /// Restores the natural Mac grid after the phone closes or loses its interactive socket.
    func clearRemoteViewport() {
        terminalView.clearRemoteGrid()
        delegate?.terminalSession(self, remoteViewportChangedTo: nil)
    }

    /// The terminal's current character grid, sent to a joining remote client so it sizes its
    /// own renderer to match rather than reflowing the shared PTY.
    var characterGrid: (cols: Int, rows: Int) {
        let terminal = terminalView.getTerminal()
        return (terminal.cols, terminal.rows)
    }

}

// MARK: - LocalProcessTerminalViewDelegate

extension TerminalSession: @preconcurrency LocalProcessTerminalViewDelegate {

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        delegate?.terminalSession(self, sizeChangedTo: newCols, rows: newRows)
    }

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        self.title = title
        delegate?.terminalSession(self, titleChangedTo: title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        if let directory = directory {
            self.currentDirectory = URL(fileURLWithPath: directory)
        } else {
            self.currentDirectory = nil
        }
        delegate?.terminalSession(self, directoryChangedTo: currentDirectory)
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        isRunning = false
        shellPid = 0

        if let pendingLaunch {
            self.pendingLaunch = nil
            switch pendingLaunch {
            case .shell(let initialDirectory):
                launchShell(initialDirectory: initialDirectory)
            case .agent(let plan):
                launchAgent(plan: plan)
            }
            return
        }

        delegate?.terminalSession(self, didTerminateWithExitCode: exitCode)
    }
}

// MARK: - TerminalSessionDelegate

@MainActor
protocol TerminalSessionDelegate: AnyObject {
    func terminalSessionDidStart(_ session: TerminalSession)
    func terminalSession(_ session: TerminalSession, titleChangedTo title: String)
    func terminalSession(_ session: TerminalSession, directoryChangedTo directory: URL?)
    func terminalSession(_ session: TerminalSession, sizeChangedTo cols: Int, rows: Int)
    func terminalSession(
        _ session: TerminalSession,
        remoteViewportChangedTo grid: (cols: Int, rows: Int)?
    )
    func terminalSession(_ session: TerminalSession, didTerminateWithExitCode exitCode: Int32?)
    func terminalSession(_ session: TerminalSession, didProduceOutputOf byteCount: Int)
    func terminalSessionDidRingBell(_ session: TerminalSession)
    func terminalSessionDidForwardScroll(_ session: TerminalSession)
}

// MARK: - Default Delegate Implementation

extension TerminalSessionDelegate {
    func terminalSessionDidStart(_ session: TerminalSession) {}
    func terminalSession(_ session: TerminalSession, titleChangedTo title: String) {}
    func terminalSession(_ session: TerminalSession, directoryChangedTo directory: URL?) {}
    func terminalSession(_ session: TerminalSession, sizeChangedTo cols: Int, rows: Int) {}
    func terminalSession(
        _ session: TerminalSession,
        remoteViewportChangedTo grid: (cols: Int, rows: Int)?
    ) {}
    func terminalSession(_ session: TerminalSession, didTerminateWithExitCode exitCode: Int32?) {}
    func terminalSession(_ session: TerminalSession, didProduceOutputOf byteCount: Int) {}
    func terminalSessionDidRingBell(_ session: TerminalSession) {}
    func terminalSessionDidForwardScroll(_ session: TerminalSession) {}
}
