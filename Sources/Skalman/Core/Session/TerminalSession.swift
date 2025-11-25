import AppKit
import SwiftTerm

/// Manages a single terminal session including the terminal view, shell process, and session state.
final class TerminalSession: NSObject {

    // MARK: - Properties

    let identifier: UUID
    let terminalView: EmojiFixedTerminalView
    private(set) var title: String
    private(set) var currentDirectory: URL?
    private(set) var isRunning: Bool = false

    weak var delegate: TerminalSessionDelegate?

    private var profile: TerminalProfile

    /// The PID of the shell process, captured after starting.
    private(set) var shellPid: pid_t = 0

    /// Captures terminal output for AI analysis.
    let outputCapture = OutputCapture()

    /// The name of the profile used for this session.
    var profileName: String {
        profile.name
    }

    // MARK: - Initialization

    init(profile: TerminalProfile = .default, frame: NSRect = .zero) {
        self.identifier = UUID()
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

        // Set up OSC 1337 handler for shell integration
        terminalView.onOSC1337Content = { [weak self] content in
            self?.handleOSC1337(content)
        }

        applyProfile()
    }

    private func handleOSC1337(_ content: String) {
        // Handle Skalman shell integration sequences
        if content.hasPrefix("SkalmanOutput=") {
            outputCapture.handleOSCSequence(content)
        }
    }

    private func applyProfile() {
        let font = NSFont.monospacedSystemFont(ofSize: profile.fontSize, weight: .regular)
        terminalView.font = font

        // Install ANSI color palette first
        let colors = profile.theme.asSwiftTermColors()
        terminalView.installColors(colors)

        // Apply theme colors
        terminalView.nativeForegroundColor = profile.theme.foreground
        terminalView.nativeBackgroundColor = profile.theme.background
        terminalView.selectedTextBackgroundColor = profile.theme.selection
        terminalView.caretColor = profile.theme.cursor

        // Force redraw
        terminalView.needsDisplay = true
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
            // Wrap shell invocation to cd to the directory first, then exec the real shell
            let shellArgs = profile.shellArguments.joined(separator: " ")
            terminalView.startProcess(
                executable: "/bin/sh",
                args: ["-c", "cd '\(dir.path)' && exec \(profile.shellPath) \(shellArgs)"],
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.captureShellPid(existingChildren: existingChildren)
        }

        // Auto-run shell integration if enabled
        if AISettingsStorage.shared.settings.autoRunShellIntegration {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.runShellIntegration()
            }
        }

        delegate?.terminalSessionDidStart(self)
    }

    /// Captures the shell PID by comparing child processes before and after starting.
    private func captureShellPid(existingChildren: Set<pid_t>) {
        let currentChildren = Set(ProcessUtility.findAllChildProcesses())
        let newChildren = currentChildren.subtracting(existingChildren)

        if let newPid = newChildren.first {
            shellPid = newPid
        } else if let anyChild = currentChildren.first {
            // Fallback: use any child we can find
            shellPid = anyChild
        }
    }

    func terminate() {
        // SwiftTerm handles process termination when the view is deallocated
        isRunning = false
    }

    private func buildEnvironment() -> [String] {
        var env = ProcessInfo.processInfo.environment

        env[EnvironmentKeys.term] = TerminalDefaults.terminalType
        env[EnvironmentKeys.shell] = profile.shellPath
        env["TERM_PROGRAM"] = "Skalman"

        if env[EnvironmentKeys.lang] == nil {
            env[EnvironmentKeys.lang] = "en_US.UTF-8"
        }

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

    /// Returns true if output capture is available for AI analysis.
    var hasOutputCapture: Bool {
        outputCapture.hasOutput
    }

    /// Runs the shell integration script in the current session.
    func runShellIntegration() {
        let command = ShellIntegration.sourceCommand
        terminalView.send(txt: command + "\n")
    }

    /// Sends ANSI-formatted text to be displayed in the terminal.
    /// This writes directly to the terminal display, not to the shell's stdin.
    func sendANSI(_ text: String) {
        // Feed the text directly to the terminal emulator for display
        // This makes it appear as output, not as typed input
        if let data = text.data(using: .utf8) {
            terminalView.feed(byteArray: ArraySlice(data))
        }
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
}

// MARK: - Default Delegate Implementation

extension TerminalSessionDelegate {
    func terminalSessionDidStart(_ session: TerminalSession) {}
    func terminalSession(_ session: TerminalSession, titleChangedTo title: String) {}
    func terminalSession(_ session: TerminalSession, directoryChangedTo directory: URL?) {}
    func terminalSession(_ session: TerminalSession, sizeChangedTo cols: Int, rows: Int) {}
    func terminalSession(_ session: TerminalSession, didTerminateWithExitCode exitCode: Int32?) {}
}
