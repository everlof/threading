import AppKit
import SwiftTerm

final class TerminalWindowController: NSWindowController {

    // MARK: - Properties

    private var terminalView: LocalProcessTerminalView!
    private var currentFontSize: CGFloat = TerminalDefaults.defaultFontSize

    // MARK: - Initialization

    convenience init() {
        let window = Self.createWindow()
        self.init(window: window)
        setupTerminalView()
        startShell()
    }

    // MARK: - Window Creation

    private static func createWindow() -> NSWindow {
        let contentRect = NSRect(
            x: 0,
            y: 0,
            width: WindowDefaults.defaultWidth,
            height: WindowDefaults.defaultHeight
        )

        let styleMask: NSWindow.StyleMask = [
            .titled,
            .closable,
            .miniaturizable,
            .resizable
        ]

        let window = NSWindow(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )

        window.minSize = NSSize(
            width: WindowDefaults.minWidth,
            height: WindowDefaults.minHeight
        )

        window.title = TerminalDefaults.defaultShell
        window.center()
        window.isReleasedWhenClosed = false

        return window
    }

    // MARK: - Terminal Setup

    private func setupTerminalView() {
        guard let window = window else { return }

        terminalView = LocalProcessTerminalView(frame: window.contentView?.bounds ?? .zero)
        terminalView.autoresizingMask = [.width, .height]
        terminalView.processDelegate = self

        updateFont()

        window.contentView?.addSubview(terminalView)
        window.makeFirstResponder(terminalView)
    }

    private func startShell() {
        let environment = buildEnvironment()

        terminalView.startProcess(
            executable: TerminalDefaults.defaultShell,
            args: ["-l"],
            environment: environment,
            execName: (TerminalDefaults.defaultShell as NSString).lastPathComponent
        )

        NotificationCenter.default.post(name: .terminalSessionDidStart, object: self)
    }

    private func buildEnvironment() -> [String] {
        var env = ProcessInfo.processInfo.environment

        env[EnvironmentKeys.term] = TerminalDefaults.terminalType
        env[EnvironmentKeys.shell] = TerminalDefaults.defaultShell

        if env[EnvironmentKeys.lang] == nil {
            env[EnvironmentKeys.lang] = "en_US.UTF-8"
        }

        return env.map { "\($0.key)=\($0.value)" }
    }

    // MARK: - Font Management

    private func updateFont() {
        let font = NSFont.monospacedSystemFont(ofSize: currentFontSize, weight: .regular)
        terminalView.font = font
    }

    func increaseFontSize() {
        currentFontSize = min(currentFontSize + 1, 72)
        updateFont()
    }

    func decreaseFontSize() {
        currentFontSize = max(currentFontSize - 1, 8)
        updateFont()
    }

    // MARK: - Tab Management

    func openNewTab() {
        // TODO: Implement tab support
    }

    // MARK: - Find

    func showFind() {
        // TODO: Implement find functionality
    }
}

// MARK: - LocalProcessTerminalViewDelegate

extension TerminalWindowController: LocalProcessTerminalViewDelegate {

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        // Terminal size changed, SwiftTerm handles PTY resize internally
    }

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        DispatchQueue.main.async { [weak self] in
            self?.window?.title = title
            NotificationCenter.default.post(
                name: .terminalTitleDidChange,
                object: self,
                userInfo: ["title": title]
            )
        }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        DispatchQueue.main.async { [weak self] in
            if let directory = directory {
                self?.window?.representedURL = URL(fileURLWithPath: directory)
            }
        }
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async { [weak self] in
            NotificationCenter.default.post(name: .terminalSessionDidEnd, object: self)
            self?.window?.close()
        }
    }
}
