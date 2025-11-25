import AppKit
import SwiftTerm

/// View controller for a single terminal tab.
final class TerminalTabViewController: NSViewController {

    // MARK: - Properties

    let session: TerminalSession

    weak var delegate: TerminalTabViewControllerDelegate?

    // MARK: - Initialization

    init(profile: TerminalProfile = ProfileStorage.shared.defaultProfile) {
        self.session = TerminalSession(profile: profile)
        super.init(nibName: nil, bundle: nil)
        session.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupTerminalView()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(session.terminalView)
    }

    // MARK: - Setup

    private func setupTerminalView() {
        session.terminalView.frame = view.bounds
        session.terminalView.autoresizingMask = [.width, .height]
        view.addSubview(session.terminalView)
    }

    // MARK: - Public Methods

    func startShell() {
        session.startShell()
    }

    func increaseFontSize() {
        session.increaseFontSize()
    }

    func decreaseFontSize() {
        session.decreaseFontSize()
    }
}

// MARK: - TerminalSessionDelegate

extension TerminalTabViewController: TerminalSessionDelegate {

    func terminalSessionDidStart(_ session: TerminalSession) {
        delegate?.terminalTabDidStart(self)
    }

    func terminalSession(_ session: TerminalSession, titleChangedTo title: String) {
        self.title = title
        delegate?.terminalTab(self, titleChangedTo: title)
    }

    func terminalSession(_ session: TerminalSession, directoryChangedTo directory: URL?) {
        delegate?.terminalTab(self, directoryChangedTo: directory)
    }

    func terminalSession(_ session: TerminalSession, sizeChangedTo cols: Int, rows: Int) {
        // Tab doesn't need to handle size changes
    }

    func terminalSession(_ session: TerminalSession, didTerminateWithExitCode exitCode: Int32?) {
        delegate?.terminalTabDidTerminate(self, exitCode: exitCode)
    }
}

// MARK: - TerminalTabViewControllerDelegate

protocol TerminalTabViewControllerDelegate: AnyObject {
    func terminalTabDidStart(_ tab: TerminalTabViewController)
    func terminalTab(_ tab: TerminalTabViewController, titleChangedTo title: String)
    func terminalTab(_ tab: TerminalTabViewController, directoryChangedTo directory: URL?)
    func terminalTabDidTerminate(_ tab: TerminalTabViewController, exitCode: Int32?)
}
