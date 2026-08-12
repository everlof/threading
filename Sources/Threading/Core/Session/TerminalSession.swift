import AppKit
@preconcurrency import SwiftTerm

/// Manages a single terminal session including the terminal view, shell process, and session state.
@MainActor
final class TerminalSession: NSObject {

    // MARK: - Properties

    let identity: TerminalInstanceIdentity
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
    /// Identifies the palette/font application that renderer findings belong to. The callback
    /// is delivered one main-queue turn later; a profile can change during that turn, and a
    /// finding from the page just left must not repopulate the notice after its invalidation.
    private var profileApplicationGeneration = 0

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

    // MARK: - Foreground Process

    /// The command currently holding the terminal, or nil at the shell's own prompt.
    ///
    /// Refreshed by `refreshForegroundProcess()` rather than on a timer of its own: an agent's
    /// terminal has no use for the answer, and only the owners that already poll — the
    /// standalone terminal and the shell drawer — should pay for it.
    private(set) var foregroundProcessName: String?

    /// The title a program set over OSC 0/2, or nil when nothing has named this terminal.
    ///
    /// Kept apart from `title`, which starts as the shell path and only ever grows. A reported
    /// title is dropped when the program that set it exits, because nothing else will correct
    /// it: the hook that rewrites a title at every prompt belongs to Terminal.app and is not
    /// loaded under our `TERM_PROGRAM`. Without this, quitting `vim` leaves a row named after
    /// the file forever.
    private(set) var reportedTitle: String?

    /// Which foreground group set `reportedTitle`. Nil means the shell's own — a user whose
    /// `zsh` writes a title at each prompt has said what they want this terminal called, and
    /// that title outlives every command.
    private var reportedTitleOwner: pid_t?

    private var foregroundGroup: pid_t?

    /// The primary side of the pty, which is what `tcgetpgrp` must be asked.
    private var ptyDescriptor: Int32 {
        terminalView.process?.childfd ?? -1
    }

    /// The name of the profile used for this session.
    var profileName: String {
        profile.name
    }

    // MARK: - Initialization

    init(
        profile: TerminalProfile = .default,
        frame: NSRect = .zero,
        identity: TerminalInstanceIdentity = .ephemeral(UUID())
    ) {
        self.identity = identity
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

        // Both halves of a bell, in the order they matter: noticed, then heard. The view no
        // longer lets SwiftTerm beep for us (see `EmojiFixedTerminalView.bell`), so this is
        // where the sound is decided — and it is decided *after* the edge, because the cause
        // the delegate works out while recording it is what the sound is chosen by.
        //
        // The ring is this session's rather than the delegate's, so a conformer that says
        // nothing still rings: nothing goes silent because somebody forgot to implement a
        // method. It happens exactly once, in one place that knows both the session and the
        // cause — which is also what lets a bell that was actually heard leave a note for the
        // attention alert about to describe this same edge, so the pair does not sound twice.
        // The note is left inside `TerminalBell`'s play step and read by
        // `AttentionAlertCenter.stateAlertSound`; it flows this way, and not the other, because
        // the ring below is synchronous while the alert's decision is a main-actor turn later.
        // See `AudibleBellRegister`.
        //
        // The owner is this terminal's own identity rather than only its session, so a
        // standalone terminal's bell resolves through *its* record and its project — a chat's
        // and a shell drawer's still resolve through the conversation, and an ephemeral
        // terminal through the app alone. See `SoundOwner`.
        terminalView.onBell = { [weak self] in
            guard let self else { return }
            let cause = self.delegate?.terminalSessionDidReceiveBell(self)
            TerminalBell.ring(cause: cause, owner: SoundOwner(self.identity))
        }

        terminalView.onMouseReportForwarded = { [weak self] in
            guard let self else { return }
            self.delegate?.terminalSessionDidForwardMouseReport(self)
        }

        terminalView.onUserInput = { [weak self] in
            guard let sessionID = self?.identity.ownerSessionID else { return }
            Task { @MainActor in
                RemoteNotificationService.shared.recordOwnerInteraction(
                    sessionID: sessionID
                )
            }
        }

        terminalView.acceptsLocalInput = { [weak self] in
            guard let sessionID = self?.identity.ownerSessionID else { return true }
            return RemoteSessionMirrorRegistry.shared.ownerCanWrite(to: sessionID)
        }
        terminalView.onLocalInputBlocked = { [weak self] in
            guard let sessionID = self?.identity.ownerSessionID else { return }
            NotificationCenter.default.post(SessionLocalInputBlocked(sessionID: sessionID))
        }

        terminalView.onOutputBytes = { [weak self] slice in
            guard let self, let onRawOutput = self.onRawOutput else { return }
            // Copy the slice out of SwiftTerm's reused buffer before it hands off.
            onRawOutput(Data(slice))
        }

        terminalView.onLowContrastText = { [weak self] conflict in
            guard let self else { return }
            let generation = self.profileApplicationGeneration
            let themeID = self.profile.theme.id.rawValue
            // The callback arrives while SwiftTerm is assembling a visible row for drawing.
            // Defer the app event one turn so a notice never changes the view hierarchy from
            // inside that draw pass.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.profileApplicationGeneration == generation else { return }
                NotificationCenter.default.post(TerminalTextVisibilityIssueDetected(issue: .init(
                    identity: self.identity,
                    themeID: themeID,
                    conflict: conflict
                )))
            }
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
        profileApplicationGeneration &+= 1
        // The renderer clears its measured pairs when the palette lands below. Clear the app's
        // corresponding finding first: if the new theme fixes the collision there will be no
        // replacement callback, so retaining the old one would explain colours no longer on
        // screen. A still-bad pair is reported again by the next visible draw.
        NotificationCenter.default.post(TerminalTextVisibilityIssuesInvalidated(
            identity: identity
        ))

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

        // The same inheritance, one step further. A caller with nothing watching its output
        // flattens the environment on the way in — `NO_COLOR=1`, `PAGER=cat` — and every one of
        // those claims is about *that* stream. The stream here is a PTY this app draws, so all
        // of them are false by the time a session sees them, and unlike `TERM` above they were
        // never restated. The first thing it costs is not a hue but a rank: the agent CLIs mark
        // their own chrome with bare SGR 2 (faint), so under `NO_COLOR` a proposed prompt
        // reaches the terminal at exactly the strength of one the user typed, and the missing
        // faint reads as a rendering bug on this side of the PTY.
        //
        // Cleared, not answered: absence is how "colour is fine" is spelled, and a pager is the
        // login shell's to choose on the way back up.
        env.removeValue(forKey: EnvironmentKeys.noColor)
        for key in EnvironmentKeys.colorVetoes where env[key] == "0" {
            env.removeValue(forKey: key)
        }
        for key in EnvironmentKeys.pagers where env[key] == EnvironmentKeys.nonPager {
            env.removeValue(forKey: key)
        }

        if env[EnvironmentKeys.lang] == nil {
            env[EnvironmentKeys.lang] = "en_US.UTF-8"
        }

        // Per-session history file
        HistoryManager.prepareHistoryFile(for: identity)
        let historyPath = HistoryManager.historyFilePath(for: identity)
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
        if let sessionID = identity.ownerSessionID,
           !RemoteSessionMirrorRegistry.shared.ownerCanWrite(to: sessionID) {
            return
        }
        terminalView.send(txt: text)
    }

    /// Inserts text the way a paste arrives, rather than the way typing does.
    ///
    /// The difference is load-bearing and is not about speed: both agent CLIs treat one arriving
    /// bracketed paste as a unit and read it as an image when the whole of it is a path with an
    /// image extension, while the same bytes typed stay text. It is how a dropped screenshot
    /// becomes an attachment, and how `SessionContextHandoff` hands a commented-on attachment to
    /// a terminal session. See `TerminalDrop` for the escaping that survives the trip.
    func pasteText(_ text: String) {
        if let sessionID = identity.ownerSessionID,
           !RemoteSessionMirrorRegistry.shared.ownerCanWrite(to: sessionID) {
            return
        }
        terminalView.pasteText(text)
    }

    /// Sends raw bytes to the PTY as if typed — the entry point for remote keyboard input.
    func sendRemoteInput(_ bytes: [UInt8]) {
        terminalView.sendRemote(bytes[...])
    }

    /// The grid the phones watching this session currently hold it at, or nil when the Mac's own
    /// frame decides.
    var remoteViewport: (cols: Int, rows: Int)? {
        terminalView.remoteGrid
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

    /// The visible screen as plain text rows, for a reader matching words on it.
    ///
    /// `translateToString` hands a blank cell back as U+0000, not a space — the same trap
    /// `RemoteScreenSeed` documents — so the gaps a TUI leaves between words are mapped before
    /// any caller compares text. Rows follow what is *displayed* (`getLine` is scroll-relative),
    /// which is the right frame for reading a prompt the user could answer.
    func visibleScreenLines() -> [String] {
        let terminal = terminalView.getTerminal()
        return (0..<terminal.rows).map { row in
            guard let line = terminal.getLine(row: row) else { return "" }
            return line.translateToString(trimRight: true)
                .replacingOccurrences(of: "\u{0}", with: " ")
        }
    }

    /// Whether a program other than this session's own command holds the terminal **right now**.
    ///
    /// The same judgement the title makes — a foreground process group that is not the session's
    /// shell is a command running *in* the terminal rather than the thing the terminal is — and
    /// deliberately not the same reading. `refreshForegroundProcess()` caches its answer for a
    /// row that repaints once a second; this is asked at the byte, because a second-old answer
    /// is not an answer about the bell that just arrived. Two syscalls, and only ever behind the
    /// gate that says someone asked to hear the distinction.
    func foregroundIsAnotherProgram() -> Bool {
        guard isRunning, shellPid > 0 else { return false }
        return ProcessUtility.foregroundProcessGroup(
            ofPTY: ptyDescriptor,
            shellPid: shellPid
        ) != nil
    }

    /// Re-reads which command owns the terminal, and retires a title whose owner has gone.
    ///
    /// Returns whether either answer moved, so a caller can repaint on the tick that changed
    /// something instead of on every tick.
    @discardableResult
    func refreshForegroundProcess() -> Bool {
        guard isRunning, shellPid > 0 else {
            let changed = foregroundProcessName != nil || reportedTitle != nil
            clearForegroundState()
            return changed
        }

        var changed = false
        let group = ProcessUtility.foregroundProcessGroup(ofPTY: ptyDescriptor, shellPid: shellPid)

        if group != foregroundGroup {
            foregroundGroup = group
            // `processName` copies the kernel's argument area for the process, which is far
            // more than a once-a-second poll should repeat — so it is read only when the group
            // actually changes, and the name is held until it changes again.
            let name = group.flatMap { ProcessUtility.processName(forPid: $0) }
            if name != foregroundProcessName {
                foregroundProcessName = name
                changed = true
            }
        }

        if let owner = reportedTitleOwner, owner != group {
            reportedTitleOwner = nil
            if reportedTitle != nil {
                reportedTitle = nil
                changed = true
            }
        }

        return changed
    }

    private func clearForegroundState() {
        foregroundProcessName = nil
        reportedTitle = nil
        reportedTitleOwner = nil
        foregroundGroup = nil
    }

}

// MARK: - LocalProcessTerminalViewDelegate

extension TerminalSession: @preconcurrency LocalProcessTerminalViewDelegate {

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        delegate?.terminalSession(self, sizeChangedTo: newCols, rows: newRows)
    }

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        self.title = title
        self.reportedTitle = title
        // Recorded at the moment of the report, not read back later: by the next poll the
        // program may already have exited, and the title would then look like the shell's.
        self.reportedTitleOwner = ProcessUtility.foregroundProcessGroup(
            ofPTY: ptyDescriptor,
            shellPid: shellPid
        )
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
        // Nothing is in the foreground of a terminal with no process, and a title the dead
        // program left behind must not outlive it into the next launch.
        clearForegroundState()

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

    /// A `BEL` arrived: record whatever activity edge it means, and answer why it rang.
    ///
    /// `nil` — the default, and the answer from every surface with no activity tracker — means
    /// the delegate cannot say. The session rings either way.
    func terminalSessionDidReceiveBell(_ session: TerminalSession) -> SoundEvent?
    func terminalSessionDidForwardMouseReport(_ session: TerminalSession)
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
    func terminalSessionDidReceiveBell(_ session: TerminalSession) -> SoundEvent? { nil }
    func terminalSessionDidForwardMouseReport(_ session: TerminalSession) {}
}
