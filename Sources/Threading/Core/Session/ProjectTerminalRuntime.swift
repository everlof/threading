import Foundation

/// Keeps standalone terminal controllers alive while the app runs.
@MainActor
final class ProjectTerminalRuntime: RemoteTerminalSurfaceQuerying {
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

    /// A foreground command is running inside the terminal's long-lived shell.
    func isBusy(terminalID: TerminalID) -> Bool {
        controllers[terminalID]?.isBusy ?? false
    }

    var remoteTerminalIdentities: Set<TerminalInstanceIdentity> {
        Set(controllers.keys.map(TerminalInstanceIdentity.projectTerminal))
    }

    func remoteTerminalSurface(
        for identity: TerminalInstanceIdentity
    ) -> (any RemoteTerminalSurface)? {
        guard case .projectTerminal(let terminalID) = identity else { return nil }
        return controllers[terminalID]?.session
    }

    func discard(terminalID: TerminalID) {
        RemoteSessionMirrorRegistry.shared.terminalDiscarded(terminalID)
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

@MainActor
struct CompositeRemoteTerminalSurfaceQuery: RemoteTerminalSurfaceQuerying {
    let sources: [any RemoteTerminalSurfaceQuerying]

    var remoteTerminalIdentities: Set<TerminalInstanceIdentity> {
        sources.reduce(into: []) { $0.formUnion($1.remoteTerminalIdentities) }
    }

    func remoteTerminalSurface(
        for identity: TerminalInstanceIdentity
    ) -> (any RemoteTerminalSurface)? {
        sources.lazy.compactMap { $0.remoteTerminalSurface(for: identity) }.first
    }
}
