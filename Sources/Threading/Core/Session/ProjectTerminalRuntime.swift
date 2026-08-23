import Foundation

/// The live standalone-terminal capability retained by Core.
///
/// UI constructs and presents its AppKit controller. Core owns only process lifecycle, status,
/// naming input, and the remote-terminal projection.
@MainActor
protocol ProjectTerminalRuntimeSurface: AnyObject {
    var isRunning: Bool { get }
    var isBusy: Bool { get }
    var foregroundProcessName: String? { get }
    var remoteTerminalSurface: any RemoteTerminalSurface { get }

    func terminate()
    func removeFromPresentation()
}

/// Keeps standalone terminal runtime surfaces alive while the app runs.
@MainActor
final class ProjectTerminalRuntime: RemoteTerminalSurfaceQuerying {
    static let shared = ProjectTerminalRuntime()
    private init() {}

    private var surfaces: [TerminalID: any ProjectTerminalRuntimeSurface] = [:]

    func runtimeSurface(for terminalID: TerminalID) -> (any ProjectTerminalRuntimeSurface)? {
        surfaces[terminalID]
    }

    @discardableResult
    func registerRuntimeSurface(
        _ surface: any ProjectTerminalRuntimeSurface,
        for terminalID: TerminalID
    ) -> Bool {
        guard surfaces[terminalID] == nil else { return false }
        surfaces[terminalID] = surface
        return true
    }

    func isRunning(terminalID: TerminalID) -> Bool {
        surfaces[terminalID]?.isRunning ?? false
    }

    /// A foreground command is running inside the terminal's long-lived shell.
    func isBusy(terminalID: TerminalID) -> Bool {
        surfaces[terminalID]?.isBusy ?? false
    }

    func foregroundProcessName(for terminalID: TerminalID) -> String? {
        surfaces[terminalID]?.foregroundProcessName
    }

    var remoteTerminalIdentities: Set<TerminalInstanceIdentity> {
        Set(surfaces.keys.map(TerminalInstanceIdentity.projectTerminal))
    }

    func remoteTerminalSurface(
        for identity: TerminalInstanceIdentity
    ) -> (any RemoteTerminalSurface)? {
        guard case .projectTerminal(let terminalID) = identity else { return nil }
        return surfaces[terminalID]?.remoteTerminalSurface
    }

    func discard(terminalID: TerminalID) {
        RemoteSessionMirrorRegistry.shared.terminalDiscarded(terminalID)
        guard let surface = surfaces.removeValue(forKey: terminalID) else { return }
        surface.terminate()
        surface.removeFromPresentation()
    }

    func discard(terminalsIn project: Project) {
        project.terminals.forEach { discard(terminalID: $0.id) }
    }

    func terminateAll() {
        let live = Array(surfaces.keys)
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
