import AppKit
import SwiftTerm

/// Manages a single terminal session including the terminal view, shell process, and session state.
final class TerminalSession: NSObject {

    // MARK: - Properties

    let identifier: UUID
    let terminalView: LocalProcessTerminalView
    private(set) var title: String
    private(set) var currentDirectory: URL?
    private(set) var isRunning: Bool = false

    weak var delegate: TerminalSessionDelegate?

    private var profile: TerminalProfile

    // MARK: - Initialization

    init(profile: TerminalProfile = .default, frame: NSRect = .zero) {
        self.identifier = UUID()
        self.profile = profile
        self.title = profile.shellPath
        self.terminalView = LocalProcessTerminalView(frame: frame)

        super.init()

        setupTerminalView()
    }

    // MARK: - Setup

    private func setupTerminalView() {
        terminalView.processDelegate = self
        applyProfile()
    }

    private func applyProfile() {
        let font = NSFont.monospacedSystemFont(ofSize: profile.fontSize, weight: .regular)
        terminalView.font = font

        // Apply theme colors
        terminalView.nativeForegroundColor = profile.theme.foreground
        terminalView.nativeBackgroundColor = profile.theme.background
        terminalView.selectedTextBackgroundColor = profile.theme.selection
        terminalView.caretColor = profile.theme.cursor
    }

    // MARK: - Shell Management

    func startShell() {
        guard !isRunning else { return }

        let environment = buildEnvironment()

        terminalView.startProcess(
            executable: profile.shellPath,
            args: profile.shellArguments,
            environment: environment,
            execName: (profile.shellPath as NSString).lastPathComponent
        )

        isRunning = true
        delegate?.terminalSessionDidStart(self)
    }

    func terminate() {
        // SwiftTerm handles process termination when the view is deallocated
        isRunning = false
    }

    private func buildEnvironment() -> [String] {
        var env = ProcessInfo.processInfo.environment

        env[EnvironmentKeys.term] = TerminalDefaults.terminalType
        env[EnvironmentKeys.shell] = profile.shellPath

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
