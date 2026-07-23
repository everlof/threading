import AppKit
import SwiftTerm

/// Manages a single terminal session including the terminal view, shell process, and session state.
final class TerminalSession: NSObject {

    // MARK: - Properties

    let identifier: SessionID
    let terminalView: EmojiFixedTerminalView
    private(set) var title: String
    private(set) var currentDirectory: URL?
    private(set) var isRunning: Bool = false

    weak var delegate: TerminalSessionDelegate?

    private var profile: TerminalProfile

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
        let font = NSFont.monospacedSystemFont(ofSize: profile.fontSize, weight: .regular)
        terminalView.font = font

        // Install ANSI color palette
        let colors = profile.theme.asSwiftTermColors()
        terminalView.installColors(colors)

        // Apply theme colors
        terminalView.nativeForegroundColor = profile.theme.foreground
        terminalView.nativeBackgroundColor = profile.theme.background
        terminalView.selectedTextBackgroundColor = profile.theme.selection
        terminalView.caretColor = profile.theme.cursor

        // Apply cursor style
        let swiftTermStyle = swiftTermCursorStyle(from: profile.cursorStyle, blink: profile.cursorBlink)
        terminalView.cursorStyle = swiftTermStyle

        // Force redraw
        terminalView.needsDisplay = true
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

        // Capture existing child PIDs before starting
        let existingChildren = Set(ProcessUtility.findAllChildProcesses())

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

        isRunning = true

        // Capture the new shell PID after a short delay to ensure the process is spawned
        DispatchQueue.main.asyncAfter(deadline: .now() + ShellDefaults.pidCaptureDelay) { [weak self] in
            self?.captureShellPid(existingChildren: existingChildren)
        }

        delegate?.terminalSessionDidStart(self)
    }

    /// Captures the child's PID by diffing the app's direct children across the launch.
    ///
    /// SwiftTerm cannot answer this on macOS: `startProcess` takes the swift-subprocess path,
    /// which awaits the run rather than handing back a process, so `LocalProcess.shellPid` is
    /// only ever set by the `forkpty` fallback and reads 0 here. Hence the diff.
    ///
    /// Three rules, each of which was absent before and produced a pid belonging to something
    /// else entirely:
    ///
    /// - **No "any child" fallback.** Skalman spawns short-lived helpers of its own — the
    ///   account email probe literally runs `claude auth status`, and icon discovery and the
    ///   artifact scan spawn their own — so "any child" adopts a stranger, which then exits and
    ///   leaves the session pointing at a *dead* pid. Having no pid is the better answer: every
    ///   reader already treats 0 as "unknown", while a stranger's pid is silently wrong.
    /// - **Pids another live session already claimed are excluded**, or two sessions launching
    ///   in the same breath — which is exactly what restoring a window full of them does — both
    ///   adopt the first new child either of them sees.
    /// - **It retries.** One look 0.3s after launch is a race the child loses whenever the
    ///   machine is busy, and app launch is the busiest moment there is.
    private func captureShellPid(existingChildren: Set<pid_t>, attempt: Int = 0) {
        guard isRunning, shellPid == 0 else { return }

        let candidates = Set(ProcessUtility.findAllChildProcesses())
            .subtracting(existingChildren)
            .subtracting(Self.claimedShellPids)

        // The lowest pid rather than an arbitrary member of a set, so a launch that really does
        // see two new children resolves the same way every time instead of by hash order.
        if let pid = candidates.min() {
            shellPid = pid
            Self.claimedShellPids.insert(pid)
            return
        }

        guard attempt + 1 < ShellDefaults.pidCaptureAttempts else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + ShellDefaults.pidCaptureDelay) { [weak self] in
            self?.captureShellPid(existingChildren: existingChildren, attempt: attempt + 1)
        }
    }

    /// Pids already adopted by a live session, so no two sessions claim the same child.
    ///
    /// Main-thread only, like the rest of this type: sessions are started, captured and torn
    /// down from AppKit callbacks.
    private static var claimedShellPids: Set<pid_t> = []

    /// Starts an agent using a resolved launch plan.
    ///
    /// Unlike `startShell`, the plan already encodes the working directory and the agent
    /// command, so the process is started verbatim.
    func start(plan: AgentLaunchPlan) {
        guard !isRunning else { return }

        let existingChildren = Set(ProcessUtility.findAllChildProcesses())

        terminalView.startProcess(
            executable: plan.executable,
            args: plan.arguments,
            environment: buildEnvironment(),
            execName: (plan.executable as NSString).lastPathComponent
        )

        isRunning = true

        DispatchQueue.main.asyncAfter(deadline: .now() + ShellDefaults.pidCaptureDelay) { [weak self] in
            self?.captureShellPid(existingChildren: existingChildren)
        }

        delegate?.terminalSessionDidStart(self)
    }

    /// Terminates the child process and closes the PTY.
    ///
    /// This must actually tear the process down rather than wait for deallocation, so a
    /// session going dormant releases its PTY and file descriptors immediately.
    func terminate() {
        guard isRunning else { return }

        terminalView.terminate()
        isRunning = false

        // Released, or the pid stays claimed for the life of the app and the next session to
        // inherit that number after pid reuse refuses to adopt its own child.
        Self.claimedShellPids.remove(shellPid)
        shellPid = 0
    }

    private func buildEnvironment() -> [String] {
        var env = ProcessInfo.processInfo.environment

        // Drop the launching process's own agent identity. These describe whoever started
        // Skalman — if that was itself an agent session, every session spawned here would
        // inherit its identifiers and believe it was a nested child of that conversation.
        for key in env.keys where AgentEnvironment.isInheritedAgentIdentity(key) {
            env.removeValue(forKey: key)
        }

        env[EnvironmentKeys.term] = TerminalDefaults.terminalType
        env[EnvironmentKeys.colorTerm] = TerminalDefaults.colorTerm
        env[EnvironmentKeys.shell] = profile.shellPath
        env["TERM_PROGRAM"] = "Skalman"

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

}

// MARK: - LocalProcessTerminalViewDelegate

extension TerminalSession: LocalProcessTerminalViewDelegate {

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
        delegate?.terminalSession(self, didTerminateWithExitCode: exitCode)
    }
}

// MARK: - TerminalSessionDelegate

protocol TerminalSessionDelegate: AnyObject {
    func terminalSessionDidStart(_ session: TerminalSession)
    func terminalSession(_ session: TerminalSession, titleChangedTo title: String)
    func terminalSession(_ session: TerminalSession, directoryChangedTo directory: URL?)
    func terminalSession(_ session: TerminalSession, sizeChangedTo cols: Int, rows: Int)
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
    func terminalSession(_ session: TerminalSession, didTerminateWithExitCode exitCode: Int32?) {}
    func terminalSession(_ session: TerminalSession, didProduceOutputOf byteCount: Int) {}
    func terminalSessionDidRingBell(_ session: TerminalSession) {}
    func terminalSessionDidForwardScroll(_ session: TerminalSession) {}
}
