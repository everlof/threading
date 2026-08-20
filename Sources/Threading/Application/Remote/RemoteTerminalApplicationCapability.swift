import Foundation

/// The terminal geometry shared by the Mac PTY and every attached remote renderer.
struct RemoteTerminalGrid: Equatable, Sendable {
    let cols: Int
    let rows: Int
}

/// The mouse-tracking contract the program running on the Mac's PTY asked for: which events it
/// wants, and how a report has to be written for it to be understood.
struct RemoteTerminalMouseReporting: Equatable, Sendable {

    /// Which events the program asked to receive.
    enum Tracking: String, Equatable, Sendable {
        /// X10 compatibility: presses only.
        case x10
        /// Normal tracking: presses and releases.
        case vt200
        /// Presses, releases, and motion while a button is down.
        case buttonEvent
        /// Presses, releases, and motion regardless of button state.
        case anyEvent
    }

    /// How a report is written on the wire. A client that guesses wrong mislocates the click.
    enum Encoding: String, Equatable, Sendable {
        case x10
        case utf8
        case sgr
        case urxvt
        case sgrPixel
    }

    let tracking: Tracking
    let encoding: Encoding
}

/// The sticky modes a program set on the Mac's PTY that a second renderer cannot infer.
///
/// Each of these is armed once, by an escape sequence the program emits when it starts, and each
/// decides how the *client* behaves from then on: whether a tap is a click, whether an arrow is
/// SS3 or CSI, whether a paste is bracketed. A phone attaching later sees only what the ring
/// still holds, and a TUI's opening sequences are long gone by then — so they are carried as
/// state and restated to every joining client.
struct RemoteTerminalModes: Equatable, Sendable {
    /// `nil` when nothing on the PTY is tracking the mouse.
    let mouseReporting: RemoteTerminalMouseReporting?
    /// DECCKM. The phone's key bar reads this to choose between SS3 and CSI arrows.
    let applicationCursorKeys: Bool
    /// A paste the program wants delimited, so a multi-line one is not run line by line.
    let bracketedPaste: Bool

    /// What a terminal holds when no program has asked for anything.
    static let plain = RemoteTerminalModes(
        mouseReporting: nil,
        applicationCursorKeys: false,
        bracketedPaste: false
    )
}

/// Cheap live state used for request admission and viewport reconciliation.
///
/// Keeping this separate from `RemoteTerminalSnapshot` prevents high-frequency frontend input
/// and resize requests from synthesizing a full repaint of the visible terminal grid.
struct RemoteTerminalState: Equatable, Sendable {
    let grid: RemoteTerminalGrid
    let title: String
    let remoteViewport: RemoteTerminalGrid?
    let modes: RemoteTerminalModes

    init(
        grid: RemoteTerminalGrid,
        title: String,
        remoteViewport: RemoteTerminalGrid?,
        modes: RemoteTerminalModes = .plain
    ) {
        self.grid = grid
        self.title = title
        self.remoteViewport = remoteViewport
        self.modes = modes
    }
}

/// The bounded state needed to attach a frontend to an already-running terminal.
///
/// `screenSeed` is a self-contained repaint of the visible grid, not scrollback. The application
/// capability does not expose the terminal emulator, PTY, or presentation controller that
/// produced it.
struct RemoteTerminalSnapshot: Equatable, Sendable {
    let state: RemoteTerminalState
    let screenSeed: Data

    var grid: RemoteTerminalGrid { state.grid }
    var title: String { state.title }
    var remoteViewport: RemoteTerminalGrid? { state.remoteViewport }
    var modes: RemoteTerminalModes { state.modes }

    init(
        grid: RemoteTerminalGrid,
        title: String,
        screenSeed: Data,
        remoteViewport: RemoteTerminalGrid?,
        modes: RemoteTerminalModes = .plain
    ) {
        self.state = RemoteTerminalState(
            grid: grid,
            title: title,
            remoteViewport: remoteViewport,
            modes: modes
        )
        self.screenSeed = screenSeed
    }
}

enum RemoteTerminalStateResult: Equatable, Sendable {
    case available(RemoteTerminalState)
    case unavailable
}

enum RemoteTerminalCaptureResult: Equatable, Sendable {
    case captured(RemoteTerminalSnapshot)
    case unavailable
}

enum RemoteTerminalMutationResult: Equatable, Sendable {
    case applied
    case unavailable
}

typealias RemoteTerminalOutputSink = @MainActor (_ data: Data) -> Void

/// The runtime adapter behind the application capability.
///
/// This is implemented by the terminal runtime itself. It deliberately contains no controller,
/// view, or SwiftTerm type, so application policy can be driven by a server or another frontend.
@MainActor
protocol RemoteTerminalSurface: AnyObject, Sendable {
    var isRunning: Bool { get }
    var remoteTerminalState: RemoteTerminalState { get }
    var remoteTerminalSnapshot: RemoteTerminalSnapshot { get }

    func setRemoteOutputSink(_ sink: RemoteTerminalOutputSink?)
    func sendRemoteInput(_ bytes: [UInt8])
    func setRemoteViewport(_ grid: RemoteTerminalGrid?)
}

/// Lookup supplied by the runtime owner. Implementations query only state they already own;
/// they do not locate a process singleton or application window internally.
@MainActor
protocol RemoteTerminalSurfaceQuerying: Sendable {
    var remoteTerminalIdentities: Set<TerminalInstanceIdentity> { get }
    func remoteTerminalSurface(
        for identity: TerminalInstanceIdentity
    ) -> (any RemoteTerminalSurface)?
}

/// Foundation-only terminal operations available to remote transport and future frontends.
///
/// Transport authentication, share scope, visibility, input-control policy, request replay, and
/// viewport bounds remain outside this capability. Once those checks admit an operation, this
/// boundary either applies it to the currently running terminal or refuses it explicitly.
@MainActor
protocol RemoteTerminalApplicationCapability: Sendable {
    var identities: Set<TerminalInstanceIdentity> { get }

    func state(for identity: TerminalInstanceIdentity) -> RemoteTerminalStateResult
    /// The bounded attach state of a terminal that is already being captured, without
    /// disturbing the capture.
    ///
    /// This synthesizes one O(grid) repaint, which is the whole reason `state(for:)` and the
    /// snapshot are separate types: input, resize and every other high-frequency path reads the
    /// cheap state so none of them pays for a repaint. Reach for this only at attach frequency —
    /// a client joining, or a replay the host had to cut and must now make whole again.
    func currentSnapshot(for identity: TerminalInstanceIdentity) -> RemoteTerminalCaptureResult
    func beginCapture(
        for identity: TerminalInstanceIdentity,
        output: @escaping RemoteTerminalOutputSink
    ) -> RemoteTerminalCaptureResult
    func endCapture(for identity: TerminalInstanceIdentity) -> RemoteTerminalMutationResult
    func sendInput(
        _ bytes: [UInt8],
        to identity: TerminalInstanceIdentity
    ) -> RemoteTerminalMutationResult
    func setViewport(
        _ grid: RemoteTerminalGrid?,
        for identity: TerminalInstanceIdentity
    ) -> RemoteTerminalMutationResult
}

extension RemoteTerminalApplicationCapability {
    var sessionIDs: Set<SessionID> {
        Set(identities.compactMap {
            guard case .agentSession(let id) = $0 else { return nil }
            return id
        })
    }

    var terminalIDs: Set<TerminalID> {
        Set(identities.compactMap {
            guard case .projectTerminal(let id) = $0 else { return nil }
            return id
        })
    }

    func state(for sessionID: SessionID) -> RemoteTerminalStateResult {
        state(for: .agentSession(sessionID))
    }

    func state(for terminalID: TerminalID) -> RemoteTerminalStateResult {
        state(for: .projectTerminal(terminalID))
    }

    func currentSnapshot(for sessionID: SessionID) -> RemoteTerminalCaptureResult {
        currentSnapshot(for: .agentSession(sessionID))
    }

    func currentSnapshot(for terminalID: TerminalID) -> RemoteTerminalCaptureResult {
        currentSnapshot(for: .projectTerminal(terminalID))
    }

    func beginCapture(
        for sessionID: SessionID,
        output: @escaping RemoteTerminalOutputSink
    ) -> RemoteTerminalCaptureResult {
        beginCapture(for: .agentSession(sessionID), output: output)
    }

    func beginCapture(
        for terminalID: TerminalID,
        output: @escaping RemoteTerminalOutputSink
    ) -> RemoteTerminalCaptureResult {
        beginCapture(for: .projectTerminal(terminalID), output: output)
    }

    func endCapture(for sessionID: SessionID) -> RemoteTerminalMutationResult {
        endCapture(for: .agentSession(sessionID))
    }

    func endCapture(for terminalID: TerminalID) -> RemoteTerminalMutationResult {
        endCapture(for: .projectTerminal(terminalID))
    }

    func sendInput(
        _ bytes: [UInt8],
        to sessionID: SessionID
    ) -> RemoteTerminalMutationResult {
        sendInput(bytes, to: .agentSession(sessionID))
    }

    func sendInput(
        _ bytes: [UInt8],
        to terminalID: TerminalID
    ) -> RemoteTerminalMutationResult {
        sendInput(bytes, to: .projectTerminal(terminalID))
    }

    func setViewport(
        _ grid: RemoteTerminalGrid?,
        for sessionID: SessionID
    ) -> RemoteTerminalMutationResult {
        setViewport(grid, for: .agentSession(sessionID))
    }

    func setViewport(
        _ grid: RemoteTerminalGrid?,
        for terminalID: TerminalID
    ) -> RemoteTerminalMutationResult {
        setViewport(grid, for: .projectTerminal(terminalID))
    }
}

/// Live application implementation. Its only dependency is injected at construction and owns
/// the surfaces it returns; there is no fallback to a process-global runtime or window lookup.
@MainActor
final class LiveRemoteTerminalApplicationCapability: RemoteTerminalApplicationCapability {
    private let surfaces: any RemoteTerminalSurfaceQuerying

    init(surfaces: any RemoteTerminalSurfaceQuerying) {
        self.surfaces = surfaces
    }

    var identities: Set<TerminalInstanceIdentity> {
        surfaces.remoteTerminalIdentities
    }

    func state(for identity: TerminalInstanceIdentity) -> RemoteTerminalStateResult {
        guard let surface = runningSurface(for: identity) else { return .unavailable }
        return .available(surface.remoteTerminalState)
    }

    func currentSnapshot(for identity: TerminalInstanceIdentity) -> RemoteTerminalCaptureResult {
        guard let surface = runningSurface(for: identity) else { return .unavailable }
        return .captured(surface.remoteTerminalSnapshot)
    }

    func beginCapture(
        for identity: TerminalInstanceIdentity,
        output: @escaping RemoteTerminalOutputSink
    ) -> RemoteTerminalCaptureResult {
        guard let surface = runningSurface(for: identity) else { return .unavailable }
        let snapshot = surface.remoteTerminalSnapshot
        surface.setRemoteOutputSink(output)
        return .captured(snapshot)
    }

    func endCapture(for identity: TerminalInstanceIdentity) -> RemoteTerminalMutationResult {
        guard let surface = surfaces.remoteTerminalSurface(for: identity) else {
            return .unavailable
        }
        surface.setRemoteOutputSink(nil)
        return .applied
    }

    func sendInput(
        _ bytes: [UInt8],
        to identity: TerminalInstanceIdentity
    ) -> RemoteTerminalMutationResult {
        guard let surface = runningSurface(for: identity) else { return .unavailable }
        surface.sendRemoteInput(bytes)
        return .applied
    }

    func setViewport(
        _ grid: RemoteTerminalGrid?,
        for identity: TerminalInstanceIdentity
    ) -> RemoteTerminalMutationResult {
        guard let surface = surfaces.remoteTerminalSurface(for: identity),
              grid == nil || surface.isRunning else {
            return .unavailable
        }
        surface.setRemoteViewport(grid)
        return .applied
    }

    private func runningSurface(
        for identity: TerminalInstanceIdentity
    ) -> (any RemoteTerminalSurface)? {
        guard let surface = surfaces.remoteTerminalSurface(for: identity),
              surface.isRunning else {
            return nil
        }
        return surface
    }
}
