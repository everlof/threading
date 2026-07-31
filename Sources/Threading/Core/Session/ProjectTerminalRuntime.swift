import Foundation

/// Keeps standalone terminal controllers alive while the app runs.
@MainActor
final class ProjectTerminalRuntime {
    static let shared = ProjectTerminalRuntime()
    private init() {}

    private var controllers: [TerminalID: ProjectTerminalViewController] = [:]

    func controller(for terminalID: TerminalID) -> ProjectTerminalViewController? {
        controllers[terminalID]
    }

    func makeController(for terminal: ProjectTerminal) -> ProjectTerminalViewController {
        if let existing = controllers[terminal.id] { return existing }
        let controller = ProjectTerminalViewController(terminal: terminal)
        controllers[terminal.id] = controller
        return controller
    }

    func isRunning(terminalID: TerminalID) -> Bool {
        controllers[terminalID]?.isRunning ?? false
    }

    func discard(terminalID: TerminalID) {
        guard let controller = controllers.removeValue(forKey: terminalID) else { return }
        controller.terminate()
        controller.view.removeFromSuperview()
        controller.removeFromParent()
    }

    func discard(terminalsIn project: Project) {
        project.terminals.forEach { discard(terminalID: $0.id) }
    }

    func terminateAll() {
        let live = Array(controllers.keys)
        live.forEach { discard(terminalID: $0) }
    }
}
